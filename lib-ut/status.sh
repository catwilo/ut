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
    info "cmd: git -C \"$DST/<repo>\" status --short && git -C \"$DST/<repo>\" branch --format=%(refname:short)"
    _remote=0
    case "${1:-}" in --remote) _remote=1; shift ;; esac
    _tag="${1:-}"
    _tmp=$(mktemp); printf "0 0\n" > "$_tmp"
    _cloud=$(mktemp); cloud_snapshot "$_cloud"
    repos_for_target "$_tag" | while IFS= read -r repo; do
        read -r _t _i < "$_tmp"; _t=$((_t+1))
        target="$DST/$repo"
        if [ ! -e "$target/.git" ]; then
            warn "$repo  not cloned"; _i=$((_i+1))
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
        if [ "$_remote" -eq 1 ] && ! git -C "$target" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
            _rem=$(git -C "$target" remote get-url origin 2>/dev/null || echo "none")
            err "$repo  remote unreachable: $_rem"; _i=$((_i+1))
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
        read -r _br _a _b _d _u _s <<EOF
$(repo_state "$target")
EOF
        _a="${_a:-0}"; _b="${_b:-0}"; _d="${_d:-0}"; _u="${_u:-0}"; _s="${_s:-0}"; _br="${_br:-?}"
        if [ "$_br" = "ERROR" ]; then
            err "$repo  git read failed"; _i=$((_i+1))
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
        _others=$(git -C "$target" branch --format='%(refname:short)' 2>/dev/null | grep -v '^main$' || true)
        _drift=0
        [ -s "$_cloud" ] && ! grep -qx "$repo" "$_cloud" && _drift=1
        if [ "$_d" -eq 0 ] && [ "$_u" -eq 0 ] && [ "$_a" -eq 0 ] && [ "$_b" -eq 0 ] && [ "$_s" -eq 0 ] && [ "$_br" = "main" ] && [ -z "$_others" ] && [ "$_drift" -eq 0 ]; then
            printf "%s %s\n" "$_t" "$_i" > "$_tmp"; continue
        fi
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
        printf "%s %s\n" "$_t" "$_i" > "$_tmp"
    done
    read -r _total _issues < "$_tmp"; rm -f "$_tmp" "$_cloud"
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
