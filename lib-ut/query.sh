#!/usr/bin/env bash
# lib-ut/query.sh -- repo listing and filtering by tag or name
# sourced by ./ut; expects $TSV set by the entrypoint

# by default: all except archive
# if tag given: only that tag
#  repos_all -- print all repo names from TSV, no filtering

# repo_dir <repo> -- resolve the on-disk path for a repo.
# Reads column 6 of repos.tsv ("path"). Empty/missing column means the
# standard location ($DST/<repo>). This is the single source of truth for
# locating a repo; callers must use this and never interpolate $DST
# directly (ut#repo-dir).
repo_dir() {
    _rd_repo="$1"
    [ -z "$_rd_repo" ] && { err "repo_dir: empty repo"; return 1; }
    _rd_path=$(awk -F'\t' -v r="$_rd_repo" '$1==r {print $6; exit}' "$TSV")
    if [ -n "$_rd_path" ]; then
        printf '%s\n' "$_rd_path"
    else
        printf '%s\n' "$DST/$_rd_repo"
    fi
}

repos_all() {
    tail -n +2 "$TSV" | while IFS='	' read -r name tags desc state owner; do
        [ -z "$name" ] && continue
        printf '%s\n' "$name"
    done
}

#  repos_active -- print repo names where state == active
repos_active() {
    tail -n +2 "$TSV" | while IFS='	' read -r name tags desc state owner; do
        [ -z "$name" ] && continue
        [ "$state" = "active" ] && printf '%s\n' "$name"
    done
}

#  repos_for_target -- repo names filtered by tag, or active repos if no tag given
repos_for_target() {
    _target="${1:-}"
    if [ -z "$_target" ]; then
        repos_active
        return
    fi
    case "$_target" in
        *,*)
            _seen=$(mktemp)
            _oldifs="$IFS"; IFS=','
            for _one in $_target; do
                IFS="$_oldifs"
                [ -z "$_one" ] && continue
                repos_for_target "$_one" | while IFS= read -r _r; do
                    grep -qxF "$_r" "$_seen" 2>/dev/null || { printf '%s\n' "$_r"; printf '%s\n' "$_r" >> "$_seen"; }
                done
                IFS=','
            done
            IFS="$_oldifs"
            rm -f "$_seen"
            return
            ;;
    esac
    _tmp_matched=$(mktemp)
    printf '0' > "$_tmp_matched"
    tail -n +2 "$TSV" | while IFS='	' read -r name tags desc state owner; do
        [ -z "$name" ] && continue
        case ",$tags," in
            *",$_target,"*)
                printf '%s\n' "$name"
                printf '1' > "$_tmp_matched"
                ;;
        esac
    done
    _matched=$(cat "$_tmp_matched"); rm -f "$_tmp_matched"
    if [ "$_matched" -eq 0 ]; then
        if grep -q "^${_target}	" "$TSV"; then
            printf '%s\n' "$_target"
        else
            die "unknown tag or repo: $_target -- intenta 'ut sync' primero si crees que deberia existir"
        fi
    fi
}

# ── subcommands ──────────────────────────────────────────────────────────────
cmd_list() {
    _tag="${1:-}"
    case "$_tag" in
        cloud)
            gh auth status >/dev/null 2>&1 || die "gh not authenticated -- run: gh auth login"
            info "cmd: gh repo list \"$GITHUB_USER\" --limit 200 --json name --jq '.[].name'"
            bold "repos en GitHub ($GITHUB_USER):"
            gh repo list "$GITHUB_USER" --limit 200 --json name --jq '.[].name' | sort | while IFS= read -r _r; do
                printf "  %s\n" "$_r"
            done
            return 0
            ;;
        local)
            # A repo is "local" if it is cloned somewhere on disk. Two
            # locations count: the standard $DST directory (legacy default)
            # and any path stored in repos.tsv column 6 (custom paths, e.g.
            # musical projects under ~/musiq/). Both are scanned and merged.
            info "cmd: find \"$DST\" -maxdepth 2 -name .git  +  repos.tsv column 6"
            bold "repos clonados localmente:"
            {
                # Standard location.
                if [ -d "$DST" ]; then
                    ( cd "$DST" && for _d in */; do
                        _d="${_d%/}"
                        [ -d "$_d/.git" ] && printf '%s\n' "$_d"
                    done )
                fi
                # Custom paths from repos.tsv column 6.
                awk -F'\t' 'NR>1 && $6 != "" {print $1}' "$TSV" | while IFS= read -r _r; do
                    [ -z "$_r" ] && continue
                    _p="$(repo_dir "$_r")"
                    [ -d "$_p/.git" ] && printf '%s\n' "$_r"
                done
            } | sort -u | while IFS= read -r _r; do
                printf "  %s\n" "$_r"
            done
            return 0
            ;;
        orphans)
            bold "clones locales no registrados en repos.tsv"
            info "cmd: find $DST -maxdepth 2 -name .git"
            [ -d "$DST" ] || { warn "no existe: $DST"; return 0; }
            _tmp_tsv=$(mktemp)
            tail -n +2 "$TSV" | cut -f1 | sort -u > "$_tmp_tsv"
            ( cd "$DST" && for _d in */; do
                _d="${_d%/}"
                [ -d "$_d/.git" ] && printf '%s\n' "$_d"
            done ) | sort -u | while IFS= read -r _r; do
                grep -qx "$_r" "$_tmp_tsv" || printf "  %s\n" "$_r"
            done
            rm -f "$_tmp_tsv"
            return 0
            ;;
        shared)
            gh auth status >/dev/null 2>&1 || die "gh not authenticated -- run: gh auth login"
            info "cmd: gh api \"/user/repos?affiliation=collaborator\" --paginate --jq '.[].full_name' | sort"
            bold "repos compartidos con $GITHUB_USER (colaborador):"
            gh api "/user/repos?affiliation=collaborator" --paginate --jq '.[].full_name' | sort | while IFS= read -r _r; do
                printf "  %s\n" "$_r"
            done
            return 0
            ;;
    esac
    if [ -n "$_tag" ] && ! grep -q ",$_tag," <(tail -n +2 "$TSV" | cut -f2 | sed 's/^/,/;s/$/,/') \
       && grep -q "^${_tag}	" "$TSV"; then
        bold "repos [repo: $_tag]:"
    tail -n +2 "$TSV" | while IFS='	' read -r name tags desc state owner; do
            case "$name" in "$_tag") printf "  %-35s ${C}%-10s${Z} %s\n" "$name" "$tags" "$desc" ;; esac
        done
        return 0
    fi
    bold "repos${_tag:+ [tag: $_tag]}:"
    tail -n +2 "$TSV" | while IFS='	' read -r name tags desc state owner; do
        [ -z "$name" ] && continue
        if [ -n "$_tag" ]; then
            case ",$tags," in *",$_tag,"*) printf "  %-35s ${C}%-10s${Z} %s\n" "$name" "$tags" "$desc" ;; esac
        else
            printf "  %-35s ${C}%-10s${Z} %s\n" "$name" "$tags" "$desc"
        fi
    done
}


# cmd_path <repo> -- print the resolved on-disk path for a repo.
# Machine-readable (no colors, no extra text): designed to be consumed
# by remote distribute / scripts. Uses repo_dir, so custom paths from
# repos.tsv column 6 are honored.
cmd_path() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut path <repo>"
    repo_dir "$_repo"
}
