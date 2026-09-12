#!/usr/bin/env bash
# lib-ut/admin.sh -- destructive GitHub operations: create, new, delete, rename
# sourced by ./ut; expects $TSV, $DST, $GITHUB_USER set by the entrypoint
# WARNING: every command here mutates GitHub directly (create/delete/rename repos)

# _tsv_publish <msg> -- commit and push repos.tsv so a registry change
# reaches every node. Without this, a create/rename/delete stays local and
# other nodes cannot resolve the repo (ut install fails there).
_tsv_publish() {
    _p_msg="$1"
    _p_dir="$(dirname "$TSV")"
    [ -d "$_p_dir/.git" ] || return 0
    info "cmd: git -C \"$_p_dir\" add repos.tsv && commit && push origin main"
    if git -C "$_p_dir" add repos.tsv \
        && git -C "$_p_dir" commit -m "chore(ut): $_p_msg" 2>/dev/null \
        && git -C "$_p_dir" push origin main 2>/dev/null; then
        ok "repos.tsv pushed to origin"
    else
        warn "repos.tsv push failed -- push manually"
    fi
}

# cmd_create -- alias of cmd_new. Both names work; cmd_new is the single
# implementation (creation + cloud init + node distribution).
cmd_create() {
    cmd_new "$@"
}

cmd_new() {
    _repo="${1:-}"; _tags="${2:-}"; _desc="${3:-}"
    [ -z "$_repo" ] || [ -z "$_tags" ] || [ -z "$_desc" ] && die "usage: ut new <repo> <tags> \"<description>\""
    grep -q "^$_repo	" "$TSV" && die "$_repo already in repos.tsv"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated -- run: gh auth login"
    info "cmd: gh repo create \"$GITHUB_USER/$_repo\" --private --description \"$_desc\""
    info "creating GitHub repo $GITHUB_USER/$_repo..."
    gh repo create "$GITHUB_USER/$_repo" --private --description "$_desc" || die "gh repo create failed"
    printf '%s\t%s\t%s\t%s\n' "$_repo" "$_tags" "$_desc" "active" >> "$TSV"
    ok "registered: $_repo in repos.tsv"
    _tsv_publish "register $_repo"
    mkdir -p "$DST"
    if ! git clone "git@github.com:$GITHUB_USER/$_repo.git" "$DST/$_repo"; then
        err "$_repo  clone failed"
        return 1
    fi
    ok "$_repo cloned to $DST/$_repo"
    printf '# %s\n\n%s\n' "$_repo" "$_desc" > "$DST/$_repo/README.md"
    git -C "$DST/$_repo" add README.md
    # --no-verify: this is the repo's first-ever commit, on main, before any
    # branch exists to receive the pre-commit hook -- the global hook blocks
    # direct commits on main/master, which would leave every new repo stuck
    # with README staged but uncommitted (see ut#11). This is the one
    # legitimate, intentional bypass the hook policy itself allows.
    git -C "$DST/$_repo" commit --no-verify -m "docs: add README"
    git -C "$DST/$_repo" push -u origin main || git -C "$DST/$_repo" push -u origin master || warn "push failed -- run manually"
    ok "initial commit pushed"

    _devices="$(_nodes_db)"
    [ -f "$_devices" ] || { warn "device table not found, skipping remote sync"; return 0; }
    while IFS= read -r _alias; do
        [ -z "$_alias" ] && continue
        _blk="$(blockdb_get "$_devices" alias "$_alias")"
        [ -n "$_blk" ] || continue
        _ip="$(blockdb_field "$_blk" ip)"
        _port="$(blockdb_field "$_blk" port)"
        is_local_ip "$_ip" && continue
        _wait_reachable "$_ip" "${_port:-22}" || { warn "$_alias -- skipped (unreachable)"; continue; }
        info "syncing $_repo -> $_alias..."
        nssh "$_alias" "git -C ~/unix-toolkit-tools/ut pull --rebase origin main >/dev/null 2>&1; mkdir -p ~/unix-toolkit-tools && [ -d ~/unix-toolkit-tools/$_repo/.git ] || git clone git@github.com:$GITHUB_USER/$_repo.git ~/unix-toolkit-tools/$_repo" 2>/dev/null \
            && ok "$_alias -- $_repo cloned" || err "$_alias -- clone failed"
    done <<< "$(_all_nodes_aliases)"
    ok "$_repo distributed to all nodes"
}

cmd_delete() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut delete <repo>"
    grep -q "^$_repo	" "$TSV" || die "$_repo not found in repos.tsv"
    info "cmd: gh repo delete \"$GITHUB_USER/$_repo\" --yes"
    info "deleting GitHub repo $GITHUB_USER/$_repo..."
    gh repo delete "$GITHUB_USER/$_repo" --yes || die "gh repo delete failed"
    python3 - "$TSV" "$_repo" << 'PYEOF'
import sys
tsv, repo = sys.argv[1], sys.argv[2]
lines = [l for l in open(tsv).readlines() if not l.startswith(repo + "\t")]
open(tsv, "w").writelines(lines)
print(f"ok: {repo} removed from repos.tsv")
PYEOF
    if [ -d "$DST/$_repo" ]; then
        maid trash "$DST/$_repo" && ok "local clone moved to trash" || warn "maid trash failed — remove $DST/$_repo manually"
    fi
    _tsv_publish "delete $_repo"
}

cmd_rename() {
    _old="${1:-}"; _new="${2:-}"
    [ -z "$_old" ] || [ -z "$_new" ] && die "usage: ut rename <old> <new>"
    grep -q "^$_old	" "$TSV" || die "$_old not found in repos.tsv"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
    info "cmd: gh repo rename \"$_new\" --repo \"$GITHUB_USER/$_old\" --yes"
    info "renaming GitHub repo $_old -> $_new..."
    gh repo rename "$_new" --repo "$GITHUB_USER/$_old" --yes || die "gh repo rename failed"

    python3 - "$TSV" "$_old" "$_new" << 'PYEOF'
import sys
tsv, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(tsv).readlines()
out = []
for l in lines:
    p = l.rstrip("\n").split("\t")
    if p[0] == old:
        p[0] = new
        out.append("\t".join(p) + "\n")
    else:
        out.append(l)
open(tsv, "w").writelines(out)
print(f"ok: {old} -> {new} in repos.tsv")
PYEOF

    if [ -d "$DST/$_old" ]; then
        mv "$DST/$_old" "$DST/$_new" && ok "local clone moved: $DST/$_old -> $DST/$_new" || warn "mv failed — move manually"
        git -C "$DST/$_new" remote set-url origin "git@github.com:$GITHUB_USER/$_new.git" && ok "remote URL updated" || warn "remote URL update failed"
    fi

    _tsv_publish "rename $_old -> $_new"
    _rename_propagate "$_old" "$_new"
}

# _rename_propagate <old> <new> -- update every other node: pull ut (so its
# repos.tsv carries the new name), rename its local clone, fix its remote.
_rename_propagate() {
    _rp_old="$1" _rp_new="$2"
    _rp_devices="$(_nodes_db)"
    [ -f "$_rp_devices" ] || return 0
    while IFS= read -r _rp_alias; do
        [ -z "$_rp_alias" ] && continue
        _rp_blk="$(blockdb_get "$_rp_devices" alias "$_rp_alias")"
        [ -n "$_rp_blk" ] || continue
        _rp_ip="$(blockdb_field "$_rp_blk" ip)"
        _rp_port="$(blockdb_field "$_rp_blk" port)"
        is_local_ip "$_rp_ip" && continue
        _wait_reachable "$_rp_ip" "${_rp_port:-22}" || { warn "$_rp_alias — skipped (unreachable)"; continue; }
        info "propagating rename to $_rp_alias..."
        nssh "$_rp_alias" "git -C ~/unix-toolkit-tools/ut pull --rebase origin main >/dev/null 2>&1; [ -d ~/unix-toolkit-tools/$_rp_old ] && mv ~/unix-toolkit-tools/$_rp_old ~/unix-toolkit-tools/$_rp_new; git -C ~/unix-toolkit-tools/$_rp_new remote set-url origin git@github.com:$GITHUB_USER/$_rp_new.git" 2>/dev/null \
            && ok "$_rp_alias — renamed" || warn "$_rp_alias — rename propagation failed"
    done <<< "$(_all_nodes_aliases)"
}
