#!/usr/bin/env bash
# lib-ut/changelog.sh -- append-only change log for repo mutations
# sourced by ./ut; used by sync.sh (cmd_push) and nodes.sh (distribute)

#  log_change <repo> <action> -- append a change record to ~/.tasks/.ut-changelog
#  format: repo<TAB>epoch<TAB>action -- called only after an observed success
#  lives in ~/.tasks (not $DST) so it propagates via miko sync's own git repo,
#  independent of unix-toolkit-tools/ dirty-state detection
log_change() {
    _lc_repo="$1"; _lc_action="$2"
    _lc_dir="$HOME/.tasks"
    [ -d "$_lc_dir" ] || return 0
    printf '%s\t%s\t%s\n' "$_lc_repo" "$(date +%s)" "$_lc_action" >> "$_lc_dir/.ut-changelog"
}

#  _ut_node_alias -- local node alias from nina status (first line, field 1).
#  Fallback: hostname. Never fails.
_ut_node_alias() {
    _una="$(nina status 2>/dev/null | awk 'NR==1 && NF>=4 {print $1; exit}')"
    printf '%s\n' "${_una:-$(hostname 2>/dev/null || echo unknown)}"
}

#  log_node_state <repo> -- record this node's current HEAD of <repo> in
#  ~/.tasks/.ut-nodes/<alias>.tsv. One file per node: no cross-node
#  conflicts, miko sync propagates them. Append-only; readers compact.
log_node_state() {
    _lns_repo="$1"
    [ -d "$HOME/.tasks" ] || return 0
    _lns_target="$(repo_dir "$_lns_repo" 2>/dev/null)" || return 0
    [ -n "$_lns_target" ] && [ -e "$_lns_target/.git" ] || return 0
    _lns_commit="$(git -C "$_lns_target" rev-parse HEAD 2>/dev/null)" || return 0
    _lns_alias="$(_ut_node_alias)"
    mkdir -p "$HOME/.tasks/.ut-nodes"
    printf '%s\t%s\t%s\n' "$_lns_repo" "$_lns_commit" "$(date +%s)" \
        >> "$HOME/.tasks/.ut-nodes/${_lns_alias}.tsv"
}

#  check_stale <repo> -- warn if this node's HEAD for <repo> differs from
#  the last recorded commit in .ut-nodes/<alias>.tsv. Purely informational:
#  ut branch runs git pull --rebase right after, so the repo is brought up
#  to date regardless.
check_stale() {
    _cs_repo="$1"
    _cs_target="$(repo_dir "$_cs_repo" 2>/dev/null)" || return 0
    [ -n "$_cs_target" ] && [ -e "$_cs_target/.git" ] || return 0
    _cs_local="$(git -C "$_cs_target" rev-parse --short HEAD 2>/dev/null)" || return 0
    _cs_alias="$(_ut_node_alias)"
    _cs_file="$HOME/.tasks/.ut-nodes/${_cs_alias}.tsv"
    [ -f "$_cs_file" ] || return 0
    _cs_last="$(awk -F'\t' -v r="$_cs_repo" '$1==r{last=$2} END{print last}' "$_cs_file")"
    [ -n "$_cs_last" ] || return 0
    [ "$_cs_last" = "$_cs_local" ] && return 0
    warn "$_cs_repo: HEAD local $_cs_local difiere del ultimo registro $_cs_last -- pull --rebase a continuacion"
}
