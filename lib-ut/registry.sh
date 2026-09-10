#!/usr/bin/env bash
# lib-ut/registry.sh -- edits repos.tsv: tag, add, untrack, unclone, pause,
# resume, archive, info
# sourced by ./ut; expects $TSV, $DST set by the entrypoint
#
# SCOPE TABLE -- three distinct operations, do not confuse them:
#   ut untrack <repo>  ->  repos.tsv ONLY. Leaves clone and GitHub intact.
#   ut unclone <repo>  ->  local clone moved to trash ONLY. Leaves repos.tsv
#                          and GitHub intact. Recoverable via maid restore.
#   ut delete  <repo>  ->  GitHub + repos.tsv + local clone (see admin.sh).
#                          Destructive and irreversible on GitHub.
# Legacy aliases (deprecated, keep working for one cycle):
#   ut rm     == ut untrack
#   ut remove == ut unclone

cmd_tag() {
    # ut tag <repo> <+tag|-tag>
    _repo="${1:-}"; _op="${2:-}"
    [ -z "$_repo" ] || [ -z "$_op" ] && die "usage: ut tag <repo> <+tag|-tag>"
    _addtag=""; _rmtag=""
    case "$_op" in
        +*) _addtag="${_op#+}" ;;
        -*) _rmtag="${_op#-}" ;;
        *)  die "op must start with + or -" ;;
    esac
    python3 - "$TSV" "$_repo" "$_addtag" "$_rmtag" << 'PYEOF'
import sys
tsv, repo, addtag, rmtag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(tsv).readlines()
out = []
found = False
for line in lines:
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3 and parts[0] == repo:
        tags = [t for t in parts[1].split(",") if t]
        if addtag and addtag not in tags:
            tags.append(addtag)
        if rmtag and rmtag in tags:
            tags.remove(rmtag)
        parts[1] = ",".join(tags)
        found = True
        out.append("\t".join(parts) + "\n")
    else:
        out.append(line)
if not found:
    print(f"error: repo '{repo}' not found in repos.tsv"); sys.exit(1)
open(tsv, "w").writelines(out)
print(f"ok: {repo} tags updated")
PYEOF
}

cmd_add() {
    # ut add <repo> <tags> <description>
    _repo="${1:-}"; _tags="${2:-}"; _desc="${3:-}"
    [ -z "$_repo" ] || [ -z "$_tags" ] || [ -z "$_desc" ] && die "usage: ut add <repo> <tags> <description>"
    grep -q "^$_repo	" "$TSV" && die "$_repo already in repos.tsv"
    printf '%s\t%s\t%s\n' "$_repo" "$_tags" "$_desc" >> "$TSV"
    ok "added: $_repo [$_tags]"
}

cmd_untrack() {
    # ut untrack <repo> -- removes repo from repos.tsv ONLY.
    # Does NOT touch the local clone and does NOT touch GitHub.
    # If you want to nuke everything, see: ut delete (admin.sh).
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut untrack <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found in repos.tsv"
    python3 - "$TSV" "$_repo" << 'PYEOF'
import sys
tsv, repo = sys.argv[1], sys.argv[2]
lines = [l for l in open(tsv).readlines() if not l.startswith(repo + "\t")]
open(tsv, "w").writelines(lines)
print(f"ok: {repo} removed from repos.tsv")
PYEOF
    warn "local clone NOT removed -- delete $DST/$_repo manually if needed"
}

# DEPRECATED: kept one cycle for backwards compatibility. Use 'ut untrack'.
cmd_rm() { warn "ut rm is deprecated, use: ut untrack"; cmd_untrack "$@"; }

cmd_unclone() {
    # ut unclone <repo> -- moves the LOCAL clone to trash ONLY.
    # Leaves repos.tsv and GitHub intact. Recoverable via maid restore.
    # If you want to nuke everything, see: ut delete (admin.sh).
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut unclone <repo>"
    target="$DST/$_repo"
    info "cmd: git -C \"$target\" status --short && maid trash \"$target\""
    [ -e "$target/.git" ] || die "$_repo not cloned locally at $target"
    _ahead=$(git -C "$target" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    _dirty=$(git -C "$target" status --short 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_ahead" -gt 0 ] || [ "$_dirty" -gt 0 ]; then
        warn "$_repo has $_ahead unpushed commit(s) and $_dirty uncommitted change(s)"
        printf "remove anyway? [y/N] "
        read -r _ans
        case "$_ans" in
            y|Y) : ;;
            *) info "aborted"; return 0 ;;
        esac
    fi
    maid trash "$target" && ok "$_repo removed locally (recoverable via maid restore) -- still in GitHub" || err "$_repo -- trash failed"
}

# DEPRECATED: kept one cycle for backwards compatibility. Use 'ut unclone'.
cmd_remove() { warn "ut remove is deprecated, use: ut unclone"; cmd_unclone "$@"; }

cmd_pause() {
    _repo="${1:-}"; [ -z "$_repo" ] && die "usage: ut pause <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found"
    python3 - "$TSV" "$_repo" pause << 'PYEOF'
import sys; tsv,repo,state=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(tsv).readlines()
out=[]
for l in lines:
    p=l.rstrip('\n').split('\t')
    if len(p)>=4 and p[0]==repo: p[3]=state; out.append('\t'.join(p)+'\n')
    else: out.append(l)
open(tsv,'w').writelines(out); print(f"ok: {repo} -> {state}")
PYEOF
}

cmd_resume() { _repo="${1:-}"; [ -z "$_repo" ] && die "usage: ut resume <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found"
    python3 - "$TSV" "$_repo" active << 'PYEOF'
import sys; tsv,repo,state=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(tsv).readlines()
out=[]
for l in lines:
    p=l.rstrip('\n').split('\t')
    if len(p)>=4 and p[0]==repo: p[3]=state; out.append('\t'.join(p)+'\n')
    else: out.append(l)
open(tsv,'w').writelines(out); print(f"ok: {repo} -> {state}")
PYEOF
}

cmd_archive() { _repo="${1:-}"; [ -z "$_repo" ] && die "usage: ut archive <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found"
    python3 - "$TSV" "$_repo" archived << 'PYEOF'
import sys; tsv,repo,state=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(tsv).readlines()
out=[]
for l in lines:
    p=l.rstrip('\n').split('\t')
    if len(p)>=4 and p[0]==repo: p[3]=state; out.append('\t'.join(p)+'\n')
    else: out.append(l)
open(tsv,'w').writelines(out); print(f"ok: {repo} -> {state}")
PYEOF
}

cmd_info() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut info <repo>"
    _row=$(grep "^$_repo	" "$TSV") || die "$_repo not found in repos.tsv"
    bold "── $_repo ──"
    printf '%s\n' "$_row" | awk -F'\t' '{printf "tags:  %s\ndesc:  %s\nstate: %s\n", $2, $3, $4}'
    _target="$DST/$_repo"
    if [ -e "$_target/.git" ]; then
        printf "remote: "; git -C "$_target" remote get-url origin
        printf "branch: "; git -C "$_target" rev-parse --abbrev-ref HEAD
        _ahead=$(git -C "$_target" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
        _dirty=$(git -C "$_target" status --short 2>/dev/null | wc -l | tr -d ' ')
        printf "ahead:  %s  dirty: %s\n" "$_ahead" "$_dirty"
        bold "recent commits:"
        git -C "$_target" log --oneline -5
    else
        warn "not cloned on this device"
    fi
}
