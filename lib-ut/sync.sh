#!/usr/bin/env bash
# lib-ut/sync.sh -- local git operations: sync, fetch, push, run, clone,
# install, diff, branch, ship
# sourced by ./ut; expects $TSV, $DST, $GITHUB_USER set by the entrypoint
# depends on lib-ut/changelog.sh (log_change, used by cmd_push)

cmd_sync() {
    _tag="${1:-}"
    info "cmd: git -C \"$(dirname \"$(realpath \"$0\")\")\" pull --rebase --autostash"
    info "ut — self-update..."
    _self="$(dirname "$(realpath "$0")")"
    _err=$(mktemp "${TMPDIR:-/tmp}/ut-selfupdate-err.XXXXXX")
    if git -C "$_self" pull --rebase --autostash 2>"$_err"; then
        ok "ut updated"
    else
        warn "ut self-update failed:"
        sed 's/^/    /' "$_err" >&2
    fi
    rm -f "$_err"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
    mkdir -p "$DST"
    errors=0
    repos_for_target "$_tag" | while IFS= read -r repo; do
        [ "$repo" = "unix-toolkit" ] && continue
        target="$DST/$repo"
        if [ -e "$target/.git" ]; then
            info "cmd: git -C \"$target\" pull --rebase --autostash"
            if ! git -C "$target" pull --rebase --autostash 2>/dev/null; then
                info "cmd: git -C \"$target\" branch --set-upstream-to=origin/main main"
                git -C "$target" branch --set-upstream-to=origin/main main 2>/dev/null \
                    && git -C "$target" pull --rebase --autostash 2>/dev/null \
                    && ok "$repo updated" \
                    || { err "$repo — pull failed"; errors=$((errors+1)); }
            else
                ok "$repo updated"
            fi
        else
            info "cmd: git clone git@github.com:$GITHUB_USER/$repo.git \"$target\""
            git clone "git@github.com:$GITHUB_USER/$repo.git" "$target" \
                && ok "$repo cloned" \
                || { err "$repo — clone failed"; errors=$((errors+1)); }
        fi
    done
    [ "$errors" -eq 0 ] && ok "all repos synced" || { err "$errors repo(s) failed"; exit 1; }
}

cmd_fetch() {
    _tag="${1:-}"
    _errfile=$(mktemp "${TMPDIR:-/tmp}/ut-fetch-err.XXXXXX")
    _outfile=$(mktemp "${TMPDIR:-/tmp}/ut-fetch-out.XXXXXX")
    printf '0' > "$_errfile"

    repos_for_target "$_tag" \
        | DST="$DST" xargs -P 8 -I{} sh -c \
            'if [ -d "$DST/{}/.git" ]; then
                git -C "$DST/{}" fetch --quiet 2>/dev/null \
                    && printf "ok {}\n" \
                    || printf "fail {}\n"
            fi' \
        > "$_outfile" 2>/dev/null

    while IFS= read -r _line; do
        case "$_line" in
            ok*)   ok  "${_line#ok }" ;;
            fail*) err "${_line#fail } — fetch failed" ;;
        esac
    done < "$_outfile"

    _errors=$(grep -c "^fail" "$_outfile" 2>/dev/null || true)
    _errors="${_errors:-0}"
    rm -f "$_errfile" "$_outfile"
    [ "$_errors" -eq 0 ] && ok "all repos fetched" || { err "${_errors} repo(s) failed"; exit 1; }
}

cmd_push() {
    _tag="${1:-}"
    _self="$(dirname "$(realpath "$0")")"
    # push self (ut) first
    _ahead=$(git -C "$_self" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    if [ "$_ahead" -gt 0 ]; then
        info "ut — pushing $_ahead commit(s)..."
        git -C "$_self" push && { ok "ut pushed"; log_change "ut" "push"; } || err "ut — push failed"
    fi
    # push all tool repos
    repos_for_target "$_tag" | while IFS= read -r repo; do
        target="$DST/$repo"
        [ -e "$target/.git" ] || continue
        _ahead=$(git -C "$target" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
        if [ "$_ahead" -gt 0 ]; then
            info "$repo — pushing $_ahead commit(s)..."
            git -C "$target" push && { ok "$repo pushed"; log_change "$repo" "push"; } || err "$repo — push failed"
        fi
    done
    # post-push status report
    echo ""
    cmd_status
}

cmd_run() {
    _cmd="${1:-}"
    [ -z "$_cmd" ] && die "usage: ut run '<comando>' [tag]"
    shift
    _tag="${1:-}"
    repos_for_target "$_tag" | while IFS= read -r repo; do
        target="$DST/$repo"
        [ -e "$target/.git" ] || { warn "$repo — not cloned, skipping"; continue; }
        bold "── $repo ──"
        (cd "$target" && eval "$_cmd") || err "$repo — command failed"
    done
}

cmd_clone() {
    gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
    mkdir -p "$DST"
    errors=0
    _clone_list() {
        if [ "$#" -eq 0 ]; then
            repos_for_target ""
        elif [ "$#" -eq 1 ]; then
            repos_for_target "$1"
        else
            for _a in "$@"; do repos_for_target "$_a"; done
        fi
    }
    _clone_list "$@" | while IFS= read -r repo; do
        target="$DST/$repo"
        if [ -e "$target/.git" ]; then
            info "$repo — already cloned, skipping"
        else
            info "cmd: git clone git@github.com:$GITHUB_USER/$repo.git \"$target\""
            git clone "git@github.com:$GITHUB_USER/$repo.git" "$target" \
                && ok "$repo cloned" \
                || { err "$repo — clone failed"; errors=$((errors+1)); }
        fi
    done
    [ "$errors" -eq 0 ] && ok "all repos cloned" || { err "$errors repo(s) failed"; exit 1; }
    printf '\n'; cmd_list local
}

cmd_install() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut install <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found in repos.tsv"
    target="$DST/$_repo"
    if [ -e "$target/.git" ]; then
        info "$_repo -- already cloned, nothing to do"
        return 0
    fi
    gh auth status >/dev/null 2>&1 || die "gh not authenticated -- run: gh auth login"
    mkdir -p "$DST"
    info "$_repo -- installing from cloud..."
    git clone "git@github.com:$GITHUB_USER/$_repo.git" "$target" \
        && ok "$_repo installed to $target" \
        || die "$_repo -- clone failed"
    printf '\n'; cmd_list local
}

cmd_diff() {
    _tag="${1:-}"
    _found=0
    repos_for_target "$_tag" | while IFS= read -r repo; do
        target="$DST/$repo"
        [ -e "$target/.git" ] || continue
        _dirty=$(git -C "$target" status --short 2>/dev/null)
        if [ -n "$_dirty" ]; then
            bold "── $repo ──"
            git -C "$target" diff --stat
            _found=1
        fi
    done
    [ "$_found" -eq 0 ] && ok "no uncommitted changes"
}

cmd_ship() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut ship <repo>"
    _target="$DST/$_repo"
    [ -e "$_target/.git" ] || die "$_repo not cloned at $_target"
    _branch=$(git -C "$_target" rev-parse --abbrev-ref HEAD)
    [ "$_branch" = "main" ] && die "already on main — nothing to ship"
    info "rebasing $_branch onto origin/main..."
    git -C "$_target" fetch origin || die "fetch failed"
    git -C "$_target" rebase origin/main || die "rebase failed — resolve conflicts then re-run"
    info "merging $_branch -> main..."
    git -C "$_target" checkout main || die "checkout main failed"
    git -C "$_target" merge "$_branch" --ff-only || die "merge failed"
    info "pushing main..."
    git -C "$_target" push origin main || die "push failed"
    info "deleting branch $_branch..."
    git -C "$_target" branch -d "$_branch" && ok "branch $_branch deleted"
    ok "$_repo shipped to origin/main"
}

cmd_branch() {
    _repo="${1:-}"; _name="${2:-}"
    [ -z "$_repo" ] || [ -z "$_name" ] && die "usage: ut branch <repo> <name>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found in repos.tsv"
    _target="$DST/$_repo"
    [ -e "$_target/.git" ] || die "$_repo not cloned at $_target"

    _stashed=0
    if [ -n "$(git -C "$_target" status --short 2>/dev/null)" ]; then
        _stash_msg="ut-branch-autostash-$(date +%s)"
        git -C "$_target" stash push -m "$_stash_msg" || die "stash failed"
        _stashed=1
        ok "stashed local changes: $_stash_msg"
    fi

    _cur_branch=$(git -C "$_target" branch --show-current 2>/dev/null || echo main)
    if ! git -C "$_target" pull --rebase --autostash origin "$_cur_branch"; then
        die "pull --rebase failed on $_repo"
    fi
    ok "pulled origin/$_cur_branch"

    git -C "$_target" checkout -b "$_name" || die "checkout -b failed"
    ok "on branch $_name"

    if [ "$_stashed" -eq 1 ]; then
        if git -C "$_target" stash pop; then
            ok "stash restored"
        else
            err "stash pop conflict -- resolve manually:"
            err "  git -C $_target stash list"
            err "  git -C $_target stash pop"
            exit 1
        fi
    fi

    ok "OK  on branch $_name"
}
