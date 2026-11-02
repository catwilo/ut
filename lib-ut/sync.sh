#!/usr/bin/env bash
# lib-ut/sync.sh -- local git operations: sync, fetch, push, run, clone,
# install, diff, branch, ship
# sourced by ./ut; expects $TSV, $DST, $GITHUB_USER set by the entrypoint
# depends on lib-ut/changelog.sh (log_change, used by cmd_push)

cmd_sync() {
    _tag="${1:-}"
    info "cmd: git -C $(dirname "$(realpath "$0")") pull --rebase --autostash"
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
    # Fan-out paralelo: mismo patron que cmd_fetch. La lista lleva
    # repo<TAB>target<TAB>url por linea para que cada worker no tenga
    # que resolver paths ni leer el TSV. TSV y GITHUB_USER se exportan
    # para que repo_url funcione dentro del worker sh.
    export TSV GITHUB_USER
    _pairs=$(repos_for_target "$_tag" | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        [ "$_r" = "unix-toolkit" ] && continue
        printf '%s\t%s\t%s\n' "$_r" "$(repo_dir "$_r")" "$(repo_url "$_r")"
    done)
    _outfile=$(mktemp "${TMPDIR:-/tmp}/ut-sync-out.XXXXXX")
    if [ -n "$_pairs" ]; then
        printf '%s\n' "$_pairs" | xargs -P 8 -d '\n' -I{} sh -c '
            _r="${1%%	*}"; _rest="${1#*	}"; _p="${_rest%%	*}"; _u="${_rest#*	}"
            if [ -e "$_p/.git" ]; then
                if git -C "$_p" pull --rebase --autostash >/dev/null 2>&1; then
                    printf "ok\\t%s\\tupdated\\n" "$_r"
                elif git -C "$_p" branch --set-upstream-to=origin/main main >/dev/null 2>&1 \
                    && git -C "$_p" pull --rebase --autostash >/dev/null 2>&1; then
                    printf "ok\\t%s\\tupdated\\n" "$_r"
                else
                    printf "fail\\t%s\\tpull failed\\n" "$_r"
                fi
            else
                if git clone "$_u" "$_p" >/dev/null 2>&1; then
                    printf "ok\\t%s\\tcloned\\n" "$_r"
                else
                    printf "fail\\t%s\\tclone failed\\n" "$_r"
                fi
            fi' _ {} > "$_outfile" 2>/dev/null
    fi
    errors=0
    while IFS=$'\t' read -r _st _r _what; do
        case "$_st" in
            ok)   ok "$_r $_what" ;;
            fail) err "$_r — $_what"; errors=$((errors+1)) ;;
        esac
    done < "$_outfile"
    rm -f "$_outfile"
    if [ "$errors" -ne 0 ]; then
        err "$errors repo(s) failed"; exit 1
    fi
    ok "all repos synced"
}

cmd_fetch() {
    _tag="${1:-}"
    _errfile=$(mktemp "${TMPDIR:-/tmp}/ut-fetch-err.XXXXXX")
    _outfile=$(mktemp "${TMPDIR:-/tmp}/ut-fetch-out.XXXXXX")
    printf '0' > "$_errfile"

    # Build a "name<TAB>path" list (repo_dir resolves custom paths), then
    # fan out the fetch across 8 workers. Path is baked into each line so
    # the parallel worker never has to look anything up.
    _pairs=$(repos_for_target "$_tag" | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        printf '%s\t%s\n' "$_r" "$(repo_dir "$_r")"
    done)
    if [ -n "$_pairs" ]; then
        printf '%s\n' "$_pairs" | xargs -P 8 -d '\n' -I{} sh -c \
            '_r="${1%%	*}"; _p="${1#*	}"
             if [ -d "$_p/.git" ]; then
                 git -C "$_p" fetch --quiet 2>/dev/null \
                     && printf "ok %s\n" "$_r" \
                     || printf "fail %s\n" "$_r"
             fi' _ {} \
            > "$_outfile" 2>/dev/null
    fi

    while IFS= read -r _line; do
        case "$_line" in
            ok*)   ok  "${_line#ok }" ;;
            fail*) err "${_line#fail } — fetch failed" ;;
        esac
    done < "$_outfile"

    _errors=$(grep -c "^fail" "$_outfile" 2>/dev/null || true)
    _errors="${_errors:-0}"
    rm -f "$_errfile" "$_outfile"
    if [ "$_errors" -ne 0 ]; then
        err "${_errors} repo(s) failed"; exit 1
    fi
    ok "all repos fetched"
}

cmd_push() {
    _tag="${1:-}"
    _self="$(dirname "$(realpath "$0")")"
    # push self (ut) first
    _ahead=$(git -C "$_self" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    if [ "$_ahead" -gt 0 ]; then
        info "ut — pushing $_ahead commit(s)..."
        if git -C "$_self" push; then
            ok "ut pushed"; log_change "ut" "push"
        else
            err "ut — push failed"
        fi
    fi
    # push all tool repos en paralelo. Mismo patron que cmd_fetch: la
    # lista lleva repo<TAB>target<TAB>ahead por linea, cada worker
    # pushea solo si hay commits pendientes, y log_change corre en el
    # padre (despues del fan-out) para no serializar el acceso al
    # archivo de changelog.
    _pairs=$(repos_for_target "$_tag" | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        _t="$(repo_dir "$_r")"
        [ -e "$_t/.git" ] || continue
        _a="$(git -C "$_t" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)"
        [ "${_a:-0}" -gt 0 ] || continue
        printf '%s\t%s\t%s\n' "$_r" "$_t" "$_a"
    done)
    _outfile=$(mktemp "${TMPDIR:-/tmp}/ut-push-out.XXXXXX")
    if [ -n "$_pairs" ]; then
        printf '%s\n' "$_pairs" | xargs -P 8 -d '\n' -I{} sh -c '
            _r="${1%%	*}"; _rest="${1#*	}"; _p="${_rest%%	*}"; _a="${_rest#*	}"
            info "$_r — pushing $_a commit(s)..."
            if git -C "$_p" push >/dev/null 2>&1; then
                printf "ok\\t%s\\n" "$_r"
            else
                printf "fail\\t%s\\n" "$_r"
            fi' _ {} > "$_outfile" 2>/dev/null
    fi
    while IFS=$'\t' read -r _st _r; do
        case "$_st" in
            ok)   ok "$_r pushed"; log_change "$_r" "push" ;;
            fail) err "$_r — push failed" ;;
        esac
    done < "$_outfile"
    rm -f "$_outfile"
    # post-push status report, scoped to the same target that was pushed.
    # With the new default (empty = touched repos), leaving this bare
    # would show a different set than the one just pushed.
    echo ""
    cmd_status "$_tag"
}

cmd_run() {
    _cmd="${1:-}"
    [ -z "$_cmd" ] && die "usage: ut run '<comando>' [tag]"
    shift
    _tag="${1:-}"
    repos_for_target "$_tag" | while IFS= read -r repo; do
        target="$(repo_dir "$repo")"
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
    # Fan-out paralelo (mismo patron que cmd_fetch/cmd_sync): la lista
    # lleva repo<TAB>target<TAB>url por linea. Solo se clonan los que
    # aun no existen en disco; los ya clonados se reportan como skip en
    # el padre, despues del fan-out, sin gastar un worker.
    export TSV GITHUB_USER
    _pairs=$( _clone_list "$@" | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        _t="$(repo_dir "$_r")"
        if [ -e "$_t/.git" ]; then
            printf 'skip\t%s\t%s\n' "$_r" "$_t"
        else
            printf 'clone\t%s\t%s\t%s\n' "$_r" "$_t" "$(repo_url "$_r")"
        fi
    done )
    _outfile=$(mktemp "${TMPDIR:-/tmp}/ut-clone-out.XXXXXX")
    _clone_pairs=$(printf '%s\n' "$_pairs" | awk -F'\t' '$1=="clone"')
    if [ -n "$_clone_pairs" ]; then
        printf '%s\n' "$_clone_pairs" | xargs -P 8 -d '\n' -I{} sh -c '
            _r="${1#clone	}"; _r="${_r%%	*}"
            _rest="${1#*	}"; _p="${_rest%%	*}"; _u="${_rest#*	}"
            if git clone "$_u" "$_p" >/dev/null 2>&1; then
                printf "ok\\t%s\\n" "$_r"
            else
                printf "fail\\t%s\\n" "$_r"
            fi' _ {} > "$_outfile" 2>/dev/null
    fi
    while IFS=$'\t' read -r _kind _r _rest; do
        case "$_kind" in
            skip)  info "$_r — already cloned, skipping" ;;
            ok)    ok "$_r cloned" ;;
            fail)  err "$_r — clone failed"; errors=$((errors+1)) ;;
        esac
    done < <(printf '%s\n' "$_pairs" | awk -F'\t' '$1=="skip"'; cat "$_outfile" 2>/dev/null)
    rm -f "$_outfile"
    if [ "$errors" -ne 0 ]; then
        err "$errors repo(s) failed"; exit 1
    fi
    ok "all repos cloned"
    printf '\n'; cmd_list local
}

cmd_install() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut install <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found in repos.tsv"
    target="$(repo_dir "$_repo")"
    if [ -e "$target/.git" ]; then
        info "$_repo -- already cloned, nothing to do"
        return 0
    fi
    gh auth status >/dev/null 2>&1 || die "gh not authenticated -- run: gh auth login"
    mkdir -p "$DST"
    _url="$(repo_url "$_repo")"
    info "$_repo -- installing from cloud..."
    if git clone "$_url" "$target"; then
        ok "$_repo installed to $target"
    else
        die "$_repo -- clone failed"
    fi
    printf '\n'; cmd_list local
}

cmd_diff() {
    _tag="${1:-}"
    _found=0
    while IFS= read -r repo; do
        target="$(repo_dir "$repo")"
        [ -e "$target/.git" ] || continue
        _dirty=$(git -C "$target" status --short 2>/dev/null)
        if [ -n "$_dirty" ]; then
            bold "── $repo ──"
            git -C "$target" diff --stat
            _found=1
        fi
    done < <(repos_for_target "$_tag")
    [ "$_found" -eq 0 ] && ok "no uncommitted changes"
}

cmd_ship() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut ship <repo>"
    _target="$(repo_dir "$_repo")"
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
    # Delete the remote branch on origin if it exists. ut branch never
    # pushes, but the user may push manually to test on another node
    # before ship; that remote branch must not outlive the merge.
    if git -C "$_target" rev-parse --verify "origin/$_branch" >/dev/null 2>&1; then
        info "deleting remote branch origin/$_branch..."
        if git -C "$_target" push origin --delete "$_branch"; then
            ok "remote branch origin/$_branch deleted"
        else
            warn "could not delete origin/$_branch -- delete manually: git -C $_target push origin --delete $_branch"
        fi
    fi
    log_node_state "$_repo"
    ok "$_repo shipped to origin/main"
}

cmd_branch() {
    _repo="${1:-}"; _name="${2:-}"
    { [ -z "$_repo" ] || [ -z "$_name" ]; } && die "usage: ut branch <repo> <name>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found in repos.tsv"
    _target="$(repo_dir "$_repo")"
    [ -e "$_target/.git" ] || die "$_repo not cloned at $_target"

    _stashed=0
    _stash_restored=0
    _restore_stash_on_exit() {
        [ "$_stashed" -eq 1 ] && [ "$_stash_restored" -eq 0 ] || return 0
        err "ut branch aborted — restoring stashed changes"
        if git -C "$_target" stash pop; then
            _stash_restored=1
            ok "stash restored after abort"
        else
            err "stash pop conflict — resolve manually:"
            err "  git -C $_target stash list"
            err "  git -C $_target stash pop"
        fi
    }
    trap '_restore_stash_on_exit' EXIT
    if [ -n "$(git -C "$_target" status --short 2>/dev/null)" ]; then
        _stash_msg="ut-branch-autostash-$(date +%s)"
        git -C "$_target" stash push -m "$_stash_msg" || die "stash failed"
        _stashed=1
        ok "stashed local changes: $_stash_msg"
    fi

    _cur_branch=$(git -C "$_target" branch --show-current 2>/dev/null || echo main)
    # If the current branch only exists locally (typical after a prior
    # `ut branch` that committed but never shipped), pulling it from origin
    # fails -- origin has no such ref. In that case rebase against
    # origin/main, which is the base every new branch starts from.
    if git -C "$_target" rev-parse --verify "origin/$_cur_branch" >/dev/null 2>&1; then
        _base_ref="$_cur_branch"
    else
        _base_ref="main"
        info "origin/$_cur_branch not found -- rebasing against origin/main"
    fi
    git -C "$_target" fetch --quiet origin || true
    check_stale "$_repo"
    if ! git -C "$_target" pull --rebase origin "$_base_ref"; then
        die "pull --rebase failed on $_repo"
    fi
    log_node_state "$_repo"
    ok "pulled $_base_ref"
    git -C "$_target" checkout -b "$_name" || die "checkout -b failed"
    ok "on branch $_name"

    if [ "$_stashed" -eq 1 ]; then
        _stash_restored=1   # claim responsibility: trap must not retry after this
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
