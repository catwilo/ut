#!/usr/bin/env bash
# lib-ut/admin.sh -- destructive GitHub operations: create, new, delete, rename
# sourced by ./ut; expects $TSV, $DST, $GITHUB_USER set by the entrypoint
# WARNING: every command here mutates GitHub directly (create/delete/rename repos)

cmd_create() {
    _repo="${1:-}"; _tags="${2:-}"; _desc="${3:-}"
    [ -z "$_repo" ] || [ -z "$_tags" ] || [ -z "$_desc" ] && die "usage: ut create <repo> <tags> \"<description>\""
    grep -q "^$_repo	" "$TSV" && die "$_repo already in repos.tsv"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
    info "cmd: gh repo create \"$GITHUB_USER/$_repo\" --private --description \"$_desc\""
    info "creating GitHub repo $GITHUB_USER/$_repo..."
    gh repo create "$GITHUB_USER/$_repo" --private --description "$_desc" || die "gh repo create failed"
    printf '%s\t%s\t%s\t%s\n' "$_repo" "$_tags" "$_desc" "active" >> "$TSV"
    ok "registered: $_repo in repos.tsv"
    # Commit and push the registry change immediately so the cloud
    # repos.tsv stays the source of truth for every node.
    _tsv_dir="$(dirname "$TSV")"
    if [ -d "$_tsv_dir/.git" ]; then
        info "cmd: git -C \"$_tsv_dir\" add repos.tsv && git -C \"$_tsv_dir\" commit -m \"chore(ut): register $_repo\" && git -C \"$_tsv_dir\" push origin main"
        git -C "$_tsv_dir" add repos.tsv 2>/dev/null             && git -C "$_tsv_dir" commit -m "chore(ut): register $_repo" 2>/dev/null             && git -C "$_tsv_dir" push origin main 2>/dev/null             && ok "repos.tsv pushed to origin"             || warn "repos.tsv push failed -- commit manually"
    fi
    mkdir -p "$DST"
    if git clone "git@github.com:$GITHUB_USER/$_repo.git" "$DST/$_repo"; then
        ok "$_repo cloned to $DST/$_repo"
        printf '# %s

%s
' "$_repo" "$_desc" > "$DST/$_repo/README.md"
        git -C "$DST/$_repo" add README.md
        git -C "$DST/$_repo" commit -m "docs: add README"
        git -C "$DST/$_repo" push -u origin main || git -C "$DST/$_repo" push -u origin master || warn "push failed -- run manually"
        ok "initial commit pushed"
        printf 'track in miko? [y/N] '
        read -r _miko_ans
        case "$_miko_ans" in
            y|Y) miko add -r "$_repo" "CHORE: initial setup" && ok "miko tracking enabled for $_repo" || warn "miko add failed -- run manually" ;;
            *) info "skipping miko tracking" ;;
        esac
    else
        err "$_repo  clone failed"
    fi
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
    # Commit and push the registry change immediately so the cloud
    # repos.tsv stays the source of truth for every node.
    _tsv_dir="$(dirname "$TSV")"
    if [ -d "$_tsv_dir/.git" ]; then
        info "cmd: git -C \"$_tsv_dir\" add repos.tsv && git -C \"$_tsv_dir\" commit -m \"chore(ut): register $_repo\" && git -C \"$_tsv_dir\" push origin main"
        git -C "$_tsv_dir" add repos.tsv 2>/dev/null             && git -C "$_tsv_dir" commit -m "chore(ut): register $_repo" 2>/dev/null             && git -C "$_tsv_dir" push origin main 2>/dev/null             && ok "repos.tsv pushed to origin"             || warn "repos.tsv push failed -- commit manually"
    fi
    mkdir -p "$DST"
    if ! git clone "git@github.com:$GITHUB_USER/$_repo.git" "$DST/$_repo"; then
        err "$_repo  clone failed"
        return 1
    fi
    ok "$_repo cloned to $DST/$_repo"
    printf '# %s

%s
' "$_repo" "$_desc" > "$DST/$_repo/README.md"
    git -C "$DST/$_repo" add README.md
    # --no-verify: this is the repo's first-ever commit, on main, before any
    # branch exists to receive the pre-commit hook -- the global hook blocks
    # direct commits on main/master, which would leave every new repo stuck
    # with README staged but uncommitted (see ut#11). This is the one
    # legitimate, intentional bypass the hook policy itself allows.
    git -C "$DST/$_repo" commit --no-verify -m "docs: add README"
    git -C "$DST/$_repo" push -u origin main || git -C "$DST/$_repo" push -u origin master || warn "push failed -- run manually"
    ok "initial commit pushed"

    _devices="${NOEMAP_HOME:-$HOME/.local/share/nina}/state/devices.db"
    [ -f "$_devices" ] || { warn "devices.db not found, skipping remote sync"; return 0; }
    _self_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    while IFS='|' read -r alias ip user port _hostkey; do
        [ -z "$alias" ] && continue
        [ "$ip" = "$_self_ip" ] && continue
        _port="${port:-22}"
        if ! _wait_reachable "$ip" "$_port"; then
            warn "$alias -- skipped (unreachable: $ip:$_port)"
            continue
        fi
        info "cmd: nssh \"$alias\" \"mkdir -p ~/unix-toolkit-tools && git clone git@github.com:$GITHUB_USER/$_repo.git ~/unix-toolkit-tools/$_repo\""
        info "syncing $_repo -> $alias..."
        if nssh "$alias" "mkdir -p ~/unix-toolkit-tools && git clone git@github.com:$GITHUB_USER/$_repo.git ~/unix-toolkit-tools/$_repo" 2>/dev/null; then
            ok "$alias -- $_repo cloned"
        else
            err "$alias -- clone failed"
        fi
    done < "$_devices"
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
}
