#!/usr/bin/env bash
# lib-ut/nodes.sh -- multi-machine operations: machines, distribute, deploy
# sourced by ./ut; expects $TSV, $DST set by the entrypoint
# depends on lib-ut/changelog.sh (log_change) and lib-ut/status.sh (_repo_is_dirty)

# _wait_reachable ip port -- tcp check with 1 retry + backoff, to avoid
# false negatives from a transient network blip (nc -z single-shot has no
# way to distinguish "node down" from "network slow right now").
# blockdb.sh is owned by noemap (repo-separate); source the INSTALLED copy,
# never vendored, so this stays a single source of truth (ut#443).
_NODES_BLOCKDB="${NOEMAP_HOME:-$HOME/.local/share/noemap}/lib/core/blockdb.sh"
[ -f "$_NODES_BLOCKDB" ] || _NODES_BLOCKDB="${NOEMAP_HOME:-$HOME/.local/share/noemap}/lib/blockdb.sh"
[ -f "$_NODES_BLOCKDB" ] || die "blockdb.sh not found (noemap not installed?): $_NODES_BLOCKDB"
# shellcheck source=/dev/null
. "$_NODES_BLOCKDB"


# _devices_aliases db_path -- prints every "alias" field, one per block/line.
_devices_aliases() {
    blockdb_list "$1" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    '
}

_wait_reachable() {
    _ip="$1" _p="$2"
    nc -z -w5 "$_ip" "$_p" >/dev/null 2>&1 && return 0
    sleep 2
    nc -z -w5 "$_ip" "$_p" >/dev/null 2>&1
}


cmd_machines_diff() {
    _devices="${NOEMAP_HOME:-$HOME/.local/share/noemap}/state/devices.db"
    [ -f "$_devices" ] || die "devices.db not found: $_devices"
    _collect="$(dirname "$(realpath "$0")")/ut-collect.sh"
    [ -f "$_collect" ] || die "ut-collect.sh not found: $_collect"
    mkdir -p "$HOME/tmp"; _out="$HOME/tmp/utdiff"; rm -rf "$_out"; mkdir -p "$_out"
    _nodes="local"
    sh "$_collect" > "$_out/local" 2>/dev/null
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        _mdblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_mdblk" ] || continue
        ip="$(blockdb_field "$_mdblk" ip)"
        is_local_ip "$ip" && continue
        if nssh "$alias" "sh -s" < "$_collect" > "$_out/$alias" 2>/dev/null; then
            _nodes="$_nodes $alias"
        else
            : > "$_out/$alias"; printf 'UNREACH\n' > "$_out/$alias.flag"
            _nodes="$_nodes $alias"
        fi
    done <<< "$(_devices_aliases "$_devices")"

    # ------------------------------------------------------------------
    # Only out-of-sync repos are printed; a repo identical on every node is
    # noise, not information. Columns are fixed-width ASCII so they align in
    # any terminal font. Counts are accumulated in a temp file because the
    # repos_all pipe runs the loop in a subshell (vars would not survive).
    # ------------------------------------------------------------------
    _rw=28; _cw=20
    _tally="$_out/.tally"; : > "$_tally"
    _difflines="$_out/.difflines"; : > "$_difflines"

    repos_all | while IFS= read -r _repo; do
        [ -z "$_repo" ] && continue

        _cells=""
        _local_cell=""
        _all_match=1
        _any_unreach=0

        for _n in $_nodes; do
            if [ -f "$_out/$_n.flag" ]; then
                _cells="$_cells|UNREACH"
                _any_unreach=1
                continue
            fi
            _line=$(grep "^$_repo	" "$_out/$_n" 2>/dev/null || true)
            if [ -z "$_line" ]; then
                _cells="$_cells|-"
                [ "$_n" = local ] || _all_match=0
                continue
            fi
            _br=$(printf '%s' "$_line" | cut -f2)
            _h=$(printf '%s' "$_line" | cut -f3)
            _a=$(printf '%s' "$_line" | cut -f4)
            _y=$(printf '%s' "$_line" | cut -f5)
            _cell="$_h"
            [ "$_br" != main ] && [ "$_br" != - ] && _cell="$_br:$_h"
            [ "$_a" != 0 ] && _cell="$_cell+$_a"
            [ "$_y" != 0 ] && _cell="$_cell*$_y"
            _cells="$_cells|$_cell"

            if [ "$_n" = local ]; then
                _local_cell="$_cell"
            elif [ "$_cell" != "$_local_cell" ]; then
                _all_match=0
            fi
        done

        printf 'x\n' >> "$_tally"
        [ "$_any_unreach" = 0 ] && [ "$_all_match" = 1 ] && continue

        if [ "$_any_unreach" = 1 ]; then
            _status="${R}[UNREACH]${Z}"
        else
            _status="${Y}[DIFF]${Z}"
        fi

        {
            printf "%-${_rw}s" "$_repo"
            _cells="${_cells#|}"
            _oldifs="$IFS"; IFS='|'
            for _c in $_cells; do
                printf "%-${_cw}s" "$_c"
            done
            IFS="$_oldifs"
            printf ' %b\n' "$_status"
        } >> "$_difflines"
    done

        printf "${B}%-${_rw}s${Z}" "REPO"
        for _n in $_nodes; do
            if [ "$_n" = "local" ]; then
                printf "${B}%-${_cw}s${Z}" "$_n <-- this"
            else
                printf "${B}%-${_cw}s${Z}" "$_n"
            fi
        done
        printf '\n'
    _total=${_total:-0}; _ndiff=${_ndiff:-0}

    if [ "$_ndiff" -eq 0 ]; then
        printf "${G}all %s repos in sync across: %s${Z}\n" "$_total" "$_nodes"
    else
        printf "${B}%-${_rw}s${Z}" "REPO"
        for _n in $_nodes; do printf "${B}%-${_cw}s${Z}" "$_n"; done
        printf '\n'
        _width=$((_rw + _cw * $(printf '%s\n' $_nodes | wc -l)))
        printf '%s\n' "$(printf -- '-%.0s' $(seq 1 $_width))"
        cat "$_difflines"
        printf '\n'
        printf "${B}%s repos total | ${G}%s in sync${Z}${B} | ${Y}%s out of sync${Z}\n" \
            "$_total" "$((_total - _ndiff))" "$_ndiff"
    fi

    rm -rf "$_out"
}

cmd_machines() {
    [ "${1:-}" = diff ] && { cmd_machines_diff; return 0; }
    _devices="${NOEMAP_HOME:-$HOME/.local/share/noemap}/state/devices.db"
    _hosts="${NOEMAP_HOME:-$HOME/.local/share/noemap}/state/hosts.db"
    [ -f "$_devices" ] || die "devices.db not found: $_devices"
    [ -f "$_hosts" ]   || die "hosts.db not found: $_hosts"
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        _mblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_mblk" ] || continue
        ip="$(blockdb_field "$_mblk" ip)"
        _os=$(grep "^$ip|" "$_hosts" | cut -d'|' -f2)
        _os="${_os:-unknown}"
        bold "── $alias [$_os] ──"
        if nssh "$alias" "ut status" 2>/dev/null; then
            true
        else
            err "$alias — unreachable"
        fi
    done <<< "$(_devices_aliases "$_devices")"
}

cmd_deploy_one() {
    _repo="$1"
    _target="$DST/$_repo"
    [ -e "$_target/.git" ] || die "$_repo not cloned at $_target"
    if [ -f "$_target/install.sh" ]; then
        info "running install.sh on local..."
        bash "$_target/install.sh" || { err "$_repo  local install.sh failed"; return 1; }
        ok "local install complete"
        log_change "$_repo" "deploy"
    else
        warn "no install.sh for $_repo, skipping local install"
    fi
    cmd_distribute "$_repo"
}

_local_repo_names() {
    [ -d "$DST" ] || return 0
    ( cd "$DST" && for _d in */; do
        _d="${_d%/}"
        [ -d "$_d/.git" ] && printf '%s\n' "$_d"
    done ) | sort
}

cmd_deploy() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut deploy <repo|all>"
    if [ "$_repo" != "all" ]; then
        cmd_deploy_one "$_repo"
        return 0
    fi
    # deploy all installs core-tagged repos only by default (ut#472 pt.2);
    # non-core repos are installed consciously via 'ut deploy <repo>'.
    _skipped=$(mktemp); : > "$_skipped"
    _ok=$(mktemp); : > "$_ok"
    _corelist=$(mktemp); repos_for_target core | sort -u > "$_corelist"
    _local_repo_names | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        grep -qxF "$_r" "$_corelist" || continue
        _target="$DST/$_r"
        _reason=$(_repo_is_dirty "$_target") && { warn "$_r  skipped: $_reason"; printf '%s\n' "$_r" >> "$_skipped"; continue; }
        info "deploying $_r..."
        cmd_deploy_one "$_r" && printf '%s\n' "$_r" >> "$_ok" || { warn "$_r  skipped: deploy failed"; printf '%s\n' "$_r" >> "$_skipped"; }
    done
    rm -f "$_corelist"
    _nok=$(wc -l < "$_ok" | tr -d ' '); _nskip=$(wc -l < "$_skipped" | tr -d ' ')
    rm -f "$_ok" "$_skipped"
    bold "deploy all (core only): $_nok deployed, $_nskip skipped"
}

cmd_distribute() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut distribute <repo>"
    _rbase="unix-toolkit-tools/$_repo"
    _devices="${NOEMAP_HOME:-$HOME/.local/share/noemap}/state/devices.db"
    [ -f "$_devices" ] || die "devices.db not found: $_devices"
    _self_alias=""
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        _dblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_dblk" ] || continue
        ip="$(blockdb_field "$_dblk" ip)"
        user="$(blockdb_field "$_dblk" user)"
        port="$(blockdb_field "$_dblk" port)"
        is_local_ip "$ip" && { _self_alias="$alias"; continue; }
        _port="${port:-22}"
        if ! _wait_reachable "$ip" "$_port"; then
            warn "$alias — skipped (unreachable: $ip:$_port)"
            continue
        fi
        info "distributing $_repo -> $alias..."
        if ! nssh "$alias" "[ -d ~/$_rbase/.git ]" 2>/dev/null; then
            info "$alias — $_repo not cloned, installing..."
            if ! nssh "$alias" "ut install $_repo" 2>/dev/null; then
                warn "$alias — $_repo auto-install failed, skipping"
                continue
            fi
        fi
        nssh "$alias" "git -C ~/$_rbase pull --rebase origin main && { [ ! -f ~/$_rbase/install.sh ] || ~/$_rbase/install.sh; }" \
            && { ok "$alias — $_repo updated"; log_change "$_repo" "distribute:$alias"; } \
            || err "$alias — distribution failed"
    done <<< "$(_devices_aliases "$_devices")"
    ok "distribute complete"
}

cmd_distribute_only_one() {
    _repo="$1"
    _rbase="unix-toolkit-tools/$_repo"
    _devices="${NOEMAP_HOME:-$HOME/.local/share/noemap}/state/devices.db"
    [ -f "$_devices" ] || die "devices.db not found: $_devices"
    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        _doBlk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_doBlk" ] || continue
        ip="$(blockdb_field "$_doBlk" ip)"
        user="$(blockdb_field "$_doBlk" user)"
        port="$(blockdb_field "$_doBlk" port)"
        is_local_ip "$ip" && continue
        _port="${port:-22}"
        if ! _wait_reachable "$ip" "$_port"; then
            warn "$alias — skipped (unreachable: $ip:$_port)"
            continue
        fi
        info "distributing $_repo -> $alias (no install)..."
        if ! nssh "$alias" "[ -d ~/$_rbase/.git ]" 2>/dev/null; then
            info "$alias — $_repo not cloned, installing..."
            if ! nssh "$alias" "ut install $_repo" 2>/dev/null; then
                warn "$alias — $_repo auto-install failed, skipping"
                continue
            fi
        fi
        nssh "$alias" "git -C ~/$_rbase pull --rebase origin main" \
            && { ok "$alias — $_repo updated (not installed)"; log_change "$_repo" "distribute:$alias"; } \
            || err "$alias — distribution failed"
    done <<< "$(_devices_aliases "$_devices")"
    ok "distribute-only complete"
}

cmd_distribute_only() {
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut distribute-only <repo|all>"
    if [ "$_repo" != "all" ]; then
        cmd_distribute_only_one "$_repo"
        return 0
    fi
    _skipped=$(mktemp); : > "$_skipped"
    _ok=$(mktemp); : > "$_ok"
    _local_repo_names | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        _target="$DST/$_r"
        _reason=$(_repo_is_dirty "$_target") && { warn "$_r  skipped: $_reason"; printf '%s\n' "$_r" >> "$_skipped"; continue; }
        cmd_distribute_only_one "$_r" && printf '%s\n' "$_r" >> "$_ok" || { warn "$_r  skipped: distribute failed"; printf '%s\n' "$_r" >> "$_skipped"; }
    done
    _nok=$(wc -l < "$_ok" | tr -d ' '); _nskip=$(wc -l < "$_skipped" | tr -d ' ')
    rm -f "$_ok" "$_skipped"
    bold "distribute-only all: $_nok distributed, $_nskip skipped"
}
