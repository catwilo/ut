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

cmd_status() {
    info "cmd: git -C \"$(dirname "$TSV")\" pull --rebase origin main"
    if [ -d "$(dirname "$TSV")/.git" ]; then
        git -C "$(dirname "$TSV")" pull --rebase origin main >/dev/null 2>&1 || true
    fi
    _tag="${1:-}"
    _tmp=$(mktemp); printf "0 0\n" > "$_tmp"
    _missing_file=$(mktemp); : > "$_missing_file"
    _cloud=$(mktemp); cloud_snapshot "$_cloud"
    _snap_dir="${TMPDIR:-/tmp}/ut-status"
    rm -rf "$_snap_dir"; mkdir -p "$_snap_dir"
    repos_for_target "$_tag" | while IFS= read -r repo; do
        read -r _t _i < "$_tmp"; _t=$((_t+1))
        target="$DST/$repo"
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
        _devices="${NOEMAP_HOME:-$HOME/.local/share/nina}/state/devices.db"
        if [ -f "$_devices" ]; then
            . "${NOEMAP_HOME:-$HOME/.local/share/nina}/lib/core/blockdb.sh" 2>/dev/null || true
            while IFS= read -r alias; do
                [ -z "$alias" ] && continue
                _mdblk="$(blockdb_get "$_devices" alias "$alias" 2>/dev/null)"
                [ -n "$_mdblk" ] || continue
                ip="$(blockdb_field "$_mdblk" ip 2>/dev/null)"
                is_local_ip "$ip" && continue
                info "cmd: nssh \"$alias\" \"cd ~/unix-toolkit-tools/$repo && git fetch --quiet origin && { git status --short; git branch -v --no-merged main; git log --oneline -5; } 2>/dev/null\""
                if nssh "$alias" "cd ~/unix-toolkit-tools/$repo 2>/dev/null && git fetch --quiet origin 2>/dev/null && { git status --short 2>/dev/null; git branch -v --no-merged main 2>/dev/null; git log --oneline -5 2>/dev/null; }" > "$_snap_dir/$repo/$alias" 2>/dev/null; then
                    :
                else
                    : > "$_snap_dir/$repo/$alias.unreach"
                fi
            done <<< "$(_devices_aliases "$_devices" 2>/dev/null)"
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
        [ -s "$_cloud" ] && ! grep -qx "$repo" "$_cloud" && _drift=1
        if [ "$_d" -eq 0 ] && [ "$_u" -eq 0 ] && [ "$_a" -eq 0 ] && [ "$_b" -eq 0 ] && [ "$_s" -eq 0 ] && [ "$_br" = "main" ] && [ -z "$_others" ] && [ "$_drift" -eq 0 ]; then
            ok "$repo  clean"
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
            if [ "$_d" -gt 0 ] || [ "$_u" -gt 0 ]; then
                git -C "$target" status --short 2>/dev/null | while IFS= read -r _line; do
                    [ -z "$_line" ] && continue
                    warn "  file:   $_line"
                done
            fi
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

# ── repo cleanliness check (used by deploy/distribute-only all) ────────────
#  _repo_is_dirty <target> -- prints reason if dirty/unmerged, empty if clean
_repo_is_dirty() {
    _t="$1"
    _others=$(git -C "$_t" branch --format='%(refname:short)' 2>/dev/null | grep -v '^main$' || true)
    _dirty=$(git -C "$_t" status --short 2>/dev/null)
    if [ -n "$_others" ]; then
        printf 'unmerged branch(es): %s' "$(printf '%s' "$_others" | tr '\n' ',' | sed 's/,$//')"
        return 0
    fi
    if [ -n "$_dirty" ]; then
        printf 'dirty working tree'
        return 0
    fi
    return 1
}
