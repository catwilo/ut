#!/bin/sh
# ut-collect.sh — emit per-repo git state for `ut machines diff`
# output (TAB-separated, one line per repo): repo	branch	hash	ahead	dirty
# POSIX sh: runs identically on Termux (busybox), Debian, macOS.
# invoked locally (sh ut-collect.sh) and remotely (nya <alias> "sh -s" < ut-collect.sh)

_tsv="$HOME/unix-toolkit-tools/ut/repos.tsv"
[ -f "$_tsv" ] || exit 0

tail -n +2 "$_tsv" | while IFS='	' read -r _name _rest; do
    [ -z "$_name" ] && continue
    if [ "$_name" = ut ]; then
        _dir="$HOME/unix-toolkit-tools/ut"
    else
        _dir="$HOME/unix-toolkit-tools/$_name"
    fi
    if [ ! -d "$_dir/.git" ]; then
        printf '%s\t-\t-\t0\t0\n' "$_name"
        continue
    fi
    _branch=$(git -C "$_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo -)
    _hash=$(git -C "$_dir" rev-parse --short HEAD 2>/dev/null || echo -)
    if git -C "$_dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        _ahead=$(git -C "$_dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    else
        _ahead=0
    fi
    _dirty=$(git -C "$_dir" status --short 2>/dev/null | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$_name" "$_branch" "$_hash" "$_ahead" "$_dirty"
done
