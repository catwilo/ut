#!/usr/bin/env bash
# lib-ut/nodes.sh -- inventario y estado de nodos remotos.
#
# RESPONSABILIDAD UNICA: enumerar los nodos conocidos y leer su estado.
# No muta nada. La distribucion (que si muta) vive en distribute.sh y
# distribute_modes.sh.
#
# Helpers compartidos: _nodes_db, _all_nodes_aliases, _devices_aliases,
# _wait_reachable. Cualquier modulo que itere "cada nodo" los usa; no
# consulta devices.db directamente (ut#--: tailscale-only peers
# silenciosamente saltados).
#
# sourced by ./ut; expects $TSV, $DST set by the entrypoint
# depends on lib-ut/changelog.sh

# _wait_reachable ip port -- tcp check with 1 retry + backoff, to avoid
# false negatives from a transient network blip (nc -z single-shot has no
# way to distinguish "node down" from "network slow right now").
# blockdb.sh is owned by nina (repo-separate); source the INSTALLED copy,
# never vendored, so this stays a single source of truth (ut#443).
_NODES_BLOCKDB="${NOEMAP_HOME:-$HOME/.local/share/nina}/lib/core/blockdb.sh"
[ -f "$_NODES_BLOCKDB" ] || _NODES_BLOCKDB="${NOEMAP_HOME:-$HOME/.local/share/nina}/lib/blockdb.sh"
[ -f "$_NODES_BLOCKDB" ] || die "blockdb.sh not found (nina not installed?): $_NODES_BLOCKDB"
# shellcheck source=/dev/null
. "$_NODES_BLOCKDB"

# _devices_aliases db_path -- prints every "alias" field, one per block.
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

# _nodes_db -- tailscale-first device table. Returns ts-devices.db whenever
# it exists and is non-empty (tailscale-first policy: devices.db is purged of
# WLAN rows when tailscale is active), falling back to devices.db otherwise.
# Consumers iterating "every known node" must use this and never devices.db
# directly (ut#--: distribute/machines silently skipped tailscale-only peers).
_nodes_db() {
    _ndb_dir="${NOEMAP_HOME:-$HOME/.local/share/nina}/state"
    if [ -f "$_ndb_dir/ts-devices.db" ] && [ -s "$_ndb_dir/ts-devices.db" ]; then
        printf '%s\n' "$_ndb_dir/ts-devices.db"
    else
        printf '%s\n' "$_ndb_dir/devices.db"
    fi
}

# _all_nodes_aliases -- every alias in the tailscale-first device table.
_all_nodes_aliases() {
    _andb="$(_nodes_db)"
    [ -f "$_andb" ] || return 0
    _devices_aliases "$_andb"
}

_wait_reachable() {
    _ip="$1" _p="$2"
    # nc is the fast path when present. When it is not, do not fail the
    # node: fall through to ssh, whose ConnectTimeout is the only
    # authoritative source of "reachable" without nc.
    if ! command -v nc >/dev/null 2>&1; then
        return 0
    fi
    nc -z -w5 "$_ip" "$_p" >/dev/null 2>&1 && return 0
    sleep 2
    nc -z -w5 "$_ip" "$_p" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# cmd_machines [diff] -- estado de cada nodo remoto.
# ---------------------------------------------------------------------------
cmd_machines() {
    [ "${1:-}" = diff ] && { cmd_machines_diff; return 0; }
    _devices="$(_nodes_db)"
    _hosts="${NOEMAP_HOME:-$HOME/.local/share/nina}/state/hosts.db"
    [ -f "$_devices" ] || die "device table not found: $_devices"
    [ -f "$_hosts" ]   || die "hosts.db not found: $_hosts"
    # Aliases come from fd 3, not fd 0: the remote command inherits fd 0
    # and can drain the here-string, silently truncating the loop after
    # the first non-local node. Explicit fd separates the loop's input
    # from the commands it runs.
    while IFS= read -r alias <&3; do
        [ -z "$alias" ] && continue
        _mblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_mblk" ] || continue
        ip="$(blockdb_field "$_mblk" ip)"
        _os=$(grep "^$ip|" "$_hosts" | cut -d'|' -f2)
        _os="${_os:-unknown}"
        bold "── $alias [$_os] ──"
        if nya "$alias" "ut status" 2>/dev/null; then
            true
        else
            err "$alias — unreachable"
        fi
    done 3< <(_all_nodes_aliases)
}

cmd_machines_diff() {
    info "cmd: nya <alias> \"sh -s\" < ut-collect.sh > tmp/utdiff/<alias>"
    _devices="$(_nodes_db)"
    [ -f "$_devices" ] || die "device table not found: $_devices"
    _collect="$(dirname "$(realpath "$0")")/ut-collect.sh"
    [ -f "$_collect" ] || die "ut-collect.sh not found: $_collect"
    mkdir -p "$HOME/tmp"; _out="$HOME/tmp/utdiff"; rm -rf "$_out"; mkdir -p "$_out"
    _nodes="local"
    sh "$_collect" > "$_out/local" 2>/dev/null
    # Aliases come from fd 3, not fd 0: the remote command inherits fd 0
    # and can drain the here-string, silently truncating the loop after
    # the first non-local node. Explicit fd separates the loop's input
    # from the commands it runs.
    while IFS= read -r alias <&3; do
        [ -z "$alias" ] && continue
        _mdblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_mdblk" ] || continue
        ip="$(blockdb_field "$_mdblk" ip)"
        is_local_ip "$ip" && continue
        if nya "$alias" "sh -s" < "$_collect" > "$_out/$alias" 2>/dev/null; then
            _nodes="$_nodes $alias"
        else
            : > "$_out/$alias"; printf 'UNREACH\n' > "$_out/$alias.flag"
            _nodes="$_nodes $alias"
        fi
    done 3< <(_all_nodes_aliases)

    # ------------------------------------------------------------------
    # Only out-of-sync repos are printed; a repo identical on every node is
    # noise, not information. Columns are fixed-width ASCII so they align in
    # any terminal font. Counts are accumulated in a temp file because the
    # repos_all pipe runs the loop in a subshell (vars would not survive).
    # ------------------------------------------------------------------
    _rw=28; _cw=20
    _tally="$_out/.tally"; : > "$_tally"
    _difflines="$_out/.difflines"; : > "$_difflines"

    info "cmd: repos_all | while read repo; do nya <alias> ... ; done"
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
                printf "${B}%-${_cw}s${Z}" "LOCAL"
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
        _width=$((_rw + _cw * $(printf '%s\n' "$_nodes" | wc -l)))
        printf '%s\n' "$(printf -- '-%.0s' $(seq 1 $_width))"
        cat "$_difflines"
        printf '\n'
        printf "${B}%s repos total | ${G}%s in sync${Z}${B} | ${Y}%s out of sync${Z}\n" \
            "$_total" "$((_total - _ndiff))" "$_ndiff"
    fi

    rm -rf "$_out"
}
