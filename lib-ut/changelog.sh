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
