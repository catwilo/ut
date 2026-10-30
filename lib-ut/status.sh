#!/usr/bin/env bash
# lib-ut/status.sh -- repo git state reporting and dirty/drift checks
# sourced by ./ut; expects $TSV, $DST, $GITHUB_USER set by the entrypoint

#  repo_state <target> -- single source of repo git state
#  echoes: "<branch> <ahead> <behind> <dirty> <untracked> <stash>"
repo_state() {
    _t="$1"
    if ! git -C "$_t" rev-parse --git-dir >/dev/null 2>&1; then
        printf 'ERROR 0 0 0 0 0\n'
        return 0
    fi
    _br=$(git -C "$_t" branch --show-current 2>/dev/null); _br="${_br:-?}"
    _ah=$(git -C "$_t" rev-list --count @{u}..HEAD 2>/dev/null); _ah="${_ah:-0}"
    _bh=$(git -C "$_t" rev-list --count "HEAD..@{u}" 2>/dev/null); _bh="${_bh:-0}"
    _dt=$(git -C "$_t" status --short 2>/dev/null | grep -vc '^??'); _dt="${_dt:-0}"
    _ut=$(git -C "$_t" status --short 2>/dev/null | grep -c '^??'); _ut="${_ut:-0}"
    _st=$(git -C "$_t" stash list 2>/dev/null | wc -l | tr -d ' '); _st="${_st:-0}"
    printf '%s %s %s %s %s %s\n' "$_br" "$_ah" "$_bh" "$_dt" "$_ut" "$_st"
}

# _status_node_drift <repo> <target> -- warn when a peer's last recorded
# commit for <repo> differs from origin/main. Reads ~/.tasks/.ut-nodes/*.tsv
# (one file per node, synced by miko). No SSH: the record is as fresh as the
# peer's last miko sync. Silent when no drift.
_status_node_drift() {
    _snd_repo="$1"; _snd_target="$2"
    _snd_dir="$HOME/.tasks/.ut-nodes"
    [ -d "$_snd_dir" ] || return 0
    _snd_origin="$(git -C "$_snd_target" rev-parse origin/main 2>/dev/null)" || return 0
    [ -n "$_snd_origin" ] || return 0
    _snd_me="$(_ut_node_alias)"
    for _snd_file in "$_snd_dir"/*.tsv; do
        [ -f "$_snd_file" ] || continue
        _snd_node="$(basename "$_snd_file" .tsv)"
        [ "$_snd_node" = "$_snd_me" ] && continue
        _snd_last="$(awk -F'\t' -v r="$_snd_repo" '$1==r{last=$2} END{print last}' "$_snd_file")"
        [ -n "$_snd_last" ] || continue
        [ "$_snd_last" = "$_snd_origin" ] && continue
        warn "  node $_snd_node: $_snd_repo at ${_snd_last:0:7}, origin/main ${_snd_origin:0:7}"
    done
    return 0
}

cmd_status() {
    # --remote is accepted as a no-op: the remote fetch/connectivity check
    # already runs unconditionally below. Kept for compatibility with the
    # flag documented in older help text and any script that passes it.
    case "${1:-}" in
        --remote) shift ;;
    esac
    info "cmd: git -C \"$(dirname "$TSV")\" pull --rebase origin main"
    if [ -d "$(dirname "$TSV")/.git" ]; then
        if ! git -C "$(dirname "$TSV")" pull --rebase origin main >/dev/null 2>&1; then
            warn "ut: pull of repos.tsv registry failed -- drift info may be stale"
        fi
    fi
    # Manifest pull: .ut-nodes/<alias>.tsv is written per node and
    # propagated through miko sync. Without this pull, a peer's fresh
    # state stays invisible until the next `miko sync` on this node.
    # Autostash: the local node usually has an uncommitted .ut-nodes edit
    # (its own latest state). git pull --rebase refuses to run with
    # unstaged changes; stash, pull, pop mirrors cmd_branch.
    if [ -d "$HOME/.tasks/.git" ]; then
        info "cmd: git -C ~/.tasks pull --rebase origin main"
        _st_tasks=0
        if [ -n "$(git -C "$HOME/.tasks" status --short 2>/dev/null)" ]; then
            if git -C "$HOME/.tasks" stash push -q -m "ut-status-autostash-$$" 2>/dev/null; then
                _st_tasks=1
            fi
        fi
        if ! git -C "$HOME/.tasks" pull --rebase origin main >/dev/null 2>&1; then
            warn "ut: pull of ~/.tasks failed -- node manifest may be stale"
        fi
        if [ "$_st_tasks" -eq 1 ]; then
            git -C "$HOME/.tasks" stash pop -q 2>/dev/null || \
                warn "ut: autostash pop of ~/.tasks conflicted -- resolve manually"
        fi
        # Local .ut-nodes/*.tsv changes not yet committed mean this node
        # recorded state that has not reached the others. Surface it: a
        # silent local edit is exactly the hole that hid tx2's manifest.
        if [ -d "$HOME/.tasks/.ut-nodes" ] && \
           [ -n "$(git -C "$HOME/.tasks" status --short -- .ut-nodes/ 2>/dev/null)" ]; then
            warn "ut: local .ut-nodes changes not propagated -- run: miko sync"
        fi
    fi
    _tag="${1:-}"
    _tmp=$(mktemp); printf "0 0\n" > "$_tmp"
    _missing_file=$(mktemp); : > "$_missing_file"
    _cloud=$(mktemp); cloud_snapshot "$_cloud"
    _snap_dir="${TMPDIR:-/tmp}/ut-status"
    rm -rf "$_snap_dir"; mkdir -p "$_snap_dir"
    repos_for_target "$_tag" | while IFS= read -r repo; do
        read -r _t _i < "$_tmp"; _t=$((_t+1))
        target="$(repo_dir "$repo")"
        if [ ! -e "$target/.git" ]; then
            warn "$repo  NOT CLONED"; _i=$((_i+1))
            printf '%s\n' "$repo" >> "$_missing_file"
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
        info "cmd: git -C \"$target\" fetch --quiet origin"
        if ! git -C "$target" fetch --quiet origin 2>/dev/null; then
            _rem=$(git -C "$target" remote get-url origin 2>/dev/null || echo "none")
            err "$repo  remote unreachable: $_rem"; _i=$((_i+1))
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
        mkdir -p "$_snap_dir/$repo"
        {
            git -C "$target" status --short 2>/dev/null
            git -C "$target" branch -v --no-merged main 2>/dev/null
            git -C "$target" log --oneline -5 2>/dev/null
        } > "$_snap_dir/$repo/local" 2>/dev/null
        _status_node_drift "$repo" "$target"
        _devices="${NOEMAP_HOME:-$HOME/.local/share/nina}/state/ts-devices.db"
        if [ -f "$_devices" ]; then
            . "${NOEMAP_HOME:-$HOME/.local/share/nina}/lib/core/blockdb.sh" 2>/dev/null || true
            # Aliases come from fd 3, not fd 0: the remote command
            # inherits fd 0 and can drain the here-string, silently
            # truncating the loop after the first non-local node.
            while IFS= read -r alias <&3; do
                [ -z "$alias" ] && continue
                _mdblk="$(blockdb_get "$_devices" alias "$alias" 2>/dev/null)"
                [ -n "$_mdblk" ] || continue
                ip="$(blockdb_field "$_mdblk" ip 2>/dev/null)"
                is_local_ip "$ip" && continue
                info "cmd: nya \"$alias\" \"cd ~/unix-toolkit-tools/$repo && git fetch --quiet origin && { git status --short; git branch -v --no-merged main; git log --oneline -5; } 2>/dev/null\""
                # Capture rc of nya separately: piping into sed would mask
                # it (sed always exits 0). Also strip the "[alias] " prefix
                # that -m mix adds per line.
                _nya_raw="$(mktemp)"
                # < /dev/null: nya/ssh inherits fd 0. Without it, the remote
                # command drains the pipe feeding `while read repo` and the
                # loop silently stops after the first repo in a multi-repo
                # list.
                if nya -m mix "$alias" "cd ~/unix-toolkit-tools/$repo 2>/dev/null && git fetch --quiet origin 2>/dev/null && { git status --short 2>/dev/null; git branch -v --no-merged main 2>/dev/null; git log --oneline -5 2>/dev/null; }" < /dev/null > "$_nya_raw" 2>/dev/null; then
                    sed "s/^\[$alias\] //" "$_nya_raw" > "$_snap_dir/$repo/$alias"
                else
                    sed "s/^\[$alias\] //" "$_nya_raw" > "$_snap_dir/$repo/$alias"
                    : > "$_snap_dir/$repo/$alias.unreach"
                fi
                rm -f "$_nya_raw"
            done 3< <(_devices_aliases "$_devices" 2>/dev/null)
        fi
        _state=$(repo_state "$target")
        _br=$(echo "$_state" | awk "{print \$1}")
        _a=$(echo "$_state" | awk "{print \$2}")
        _b=$(echo "$_state" | awk "{print \$3}")
        _d=$(echo "$_state" | awk "{print \$4}")
        _u=$(echo "$_state" | awk "{print \$5}")
        _s=$(echo "$_state" | awk "{print \$6}")
        if [ "$_br" = "ERROR" ]; then
            err "$repo  git read failed"; _i=$((_i+1))
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
        _others=$(git -C "$target" branch --format="%(refname:short)" 2>/dev/null | grep -v "^main$" || true)
        _drift=0
        _owner=$(awk -F'\t' -v r="$repo" '$1==r {print $5; exit}' "$TSV")
        [ "$_owner" = "$GITHUB_USER" ] || [ -z "$_owner" ] && {
            [ -s "$_cloud" ] && ! grep -qx "$repo" "$_cloud" && _drift=1
        }
        if [ "$_d" -eq 0 ] && [ "$_u" -eq 0 ] && [ "$_a" -eq 0 ] && [ "$_b" -eq 0 ] && [ "$_s" -eq 0 ] && [ "$_br" = "main" ] && [ -z "$_others" ] && [ "$_drift" -eq 0 ]; then
            ok "$repo  clean"
            info "  cmd: git log --oneline -5"
            git -C "$target" log --oneline -5 2>/dev/null | sed 's/^/    /'
        else
            _i=$((_i+1))
            bold "$repo"
            _flags=""
            [ "$_d" -gt 0 ] && _flags="${_flags}dirty:$_d "
            [ "$_u" -gt 0 ] && _flags="${_flags}untracked:$_u "
            [ "$_a" -gt 0 ] && _flags="${_flags}ahead:$_a "
            [ "$_b" -gt 0 ] && _flags="${_flags}behind:$_b "
            [ "$_s" -gt 0 ] && _flags="${_flags}stash:$_s "
            [ "$_br" != "main" ] && _flags="${_flags}branch:$_br "
            [ "$_drift" -eq 1 ] && _flags="${_flags}drift "
            [ -n "$_flags" ] && warn "  $_flags"
            info "  cmd: git status --short"
            git -C "$target" status --short 2>/dev/null | sed 's/^/    /'
            info "  cmd: git branch -v --no-merged main"
            git -C "$target" branch -v --no-merged main 2>/dev/null | sed 's/^/    /'
            info "  cmd: git log --oneline -5"
            git -C "$target" log --oneline -5 2>/dev/null | sed 's/^/    /'
            if [ -n "$_others" ]; then
                printf '%s\n' "$_others" | while IFS= read -r _b_name; do
                    [ -z "$_b_name" ] && continue
                    _n=$(git -C "$target" rev-list --count "main..$_b_name" 2>/dev/null); _n="${_n:-0}"
                    warn "  branch: $_b_name (+$_n)"
                done
            fi
        fi
        for _snap in "$_snap_dir/$repo"/*; do
            [ -f "$_snap" ] || continue
            _node=$(basename "$_snap")
            case "$_node" in local) continue ;; esac
            [ "$_node" = "local" ] && continue
            if [ -s "$_snap" ] && [ -f "$_snap.unreach" ]; then
                warn "  node $_node: unreachable"
                continue
            fi
            if ! diff -q "$_snap_dir/$repo/local" "$_snap" >/dev/null 2>&1; then
                warn "  node $_node: DIFF vs local"
                diff -u "$_snap_dir/$repo/local" "$_snap" 2>/dev/null | while IFS= read -r _dl; do
                    case "$_dl" in
                        ---*|+++*) continue ;;
                        @@*) continue ;;
                        -*) warn "    local:  ${_dl#-}" ;;
                        +*) warn "    $_node: ${_dl#+}" ;;
                    esac
                done
            else
                ok "  node $_node: in sync"
            fi
        done
        printf "%s %s\n" "$_t" "$_i" > "$_tmp"
    done
    read -r _total _issues < "$_tmp"; rm -f "$_tmp" "$_cloud"
    if [ -s "$_missing_file" ]; then
        bold "repos NOT clonados localmente:"
        sort "$_missing_file" | while IFS= read -r _m; do
            [ -n "$_m" ] && printf "  %s\n" "$_m"
        done
    fi
    rm -f "$_missing_file"
    rm -rf "$_snap_dir"
    _clean=$((_total - _issues))
    bold "[$_total repos]  $_clean clean   $_issues with problems"
}

#  cloud_snapshot <outfile> -- write GitHub repo names to outfile
#  used by health/status drift detection; empty file if gh unavailable
cloud_snapshot() {
    gh repo list "$GITHUB_USER" --limit 200 --json name --jq '.[].name' \
        2>/dev/null | sort -u > "$1"
}

