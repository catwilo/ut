#!/usr/bin/env bash
# lib-ut/nodes.sh -- multi-machine operations: machines, distribute
# sourced by ./ut; expects $TSV, $DST set by the entrypoint
# depends on lib-ut/changelog.sh (log_change) and lib-ut/status.sh (_repo_is_dirty)

# _wait_reachable ip port -- tcp check with 1 retry + backoff, to avoid
# false negatives from a transient network blip (nc -z single-shot has no
# way to distinguish "node down" from "network slow right now").
# blockdb.sh is owned by noemap (repo-separate); source the INSTALLED copy,
# never vendored, so this stays a single source of truth (ut#443).
_NODES_BLOCKDB="${NOEMAP_HOME:-$HOME/.local/share/nina}/lib/core/blockdb.sh"
[ -f "$_NODES_BLOCKDB" ] || _NODES_BLOCKDB="${NOEMAP_HOME:-$HOME/.local/share/nina}/lib/blockdb.sh"
[ -f "$_NODES_BLOCKDB" ] || die "blockdb.sh not found (nina not installed?): $_NODES_BLOCKDB"
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
    nc -z -w5 "$_ip" "$_p" >/dev/null 2>&1 && return 0
    sleep 2
    nc -z -w5 "$_ip" "$_p" >/dev/null 2>&1
}


cmd_machines_diff() {
    info "cmd: nssh <alias> \"sh -s\" < ut-collect.sh > tmp/utdiff/<alias>"
    _devices="$(_nodes_db)"
    [ -f "$_devices" ] || die "device table not found: $_devices"
    _collect="$(dirname "$(realpath "$0")")/ut-collect.sh"
    [ -f "$_collect" ] || die "ut-collect.sh not found: $_collect"
    mkdir -p "$HOME/tmp"; _out="$HOME/tmp/utdiff"; rm -rf "$_out"; mkdir -p "$_out"
    _nodes="local"
    sh "$_collect" > "$_out/local" 2>/dev/null
    # Aliases come from fd 3, not fd 0: nssh inherits fd 0 and the
    # remote git pull can drain the here-string, silently truncating
    # the loop after the first non-local node. Explicit fd separates
    # the loop's input from the commands it runs.
    while IFS= read -r alias <&3; do
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

    info "cmd: repos_all | while read repo; do nssh <alias> ... ; done"
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
    _devices="$(_nodes_db)"
    _hosts="${NOEMAP_HOME:-$HOME/.local/share/nina}/state/hosts.db"
    [ -f "$_devices" ] || die "device table not found: $_devices"
    [ -f "$_hosts" ]   || die "hosts.db not found: $_hosts"
    # Aliases come from fd 3, not fd 0: nssh inherits fd 0 and the
    # remote git pull can drain the here-string, silently truncating
    # the loop after the first non-local node. Explicit fd separates
    # the loop's input from the commands it runs.
    while IFS= read -r alias <&3; do
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
    done 3< <(_all_nodes_aliases)
}

# _remote_repo_path <alias> <repo> -- path to the repo on the remote node.
# Updates the remote ut first (so cmd_path exists) and asks it to resolve
# the path. Empty output means the remote cannot resolve it; caller treats
# that as "not cloned yet" and falls back to remote `ut install`.
_remote_repo_path() {
    _rrp_alias="$1" _rrp_repo="$2"
    # Ensure remote ut is current so cmd_path exists.
    nssh "$_rrp_alias" "git -C ~/unix-toolkit-tools/ut pull --rebase origin main" >/dev/null 2>&1 || true
    # `ut path` only resolves the configured location; it does not check
    # that the repo is actually present. We need a real .git to treat it
    # as cloned. If absent, print nothing so the caller falls through to
    # remote `ut install`.
    nssh "$_rrp_alias" "p=\$(ut path $_rrp_repo 2>/dev/null); [ -n \"\$p\" ] && [ -d \"\$p/.git\" ] && printf '%s' \"\$p\"" 2>/dev/null | tr -d '\r'
}

# _distribute_install_remote <repo> <alias> -- run install.sh on a remote node.
_distribute_install_remote() {
    _repo="$1" _alias="$2"
    _rpath="$(_remote_repo_path "$_alias" "$_repo")"
    if [ -z "$_rpath" ]; then
        warn "$_alias — cannot resolve repo path, skipping install"
        return 1
    fi
    info "cmd: nssh \"$_alias\" \"bash $_rpath/install.sh\""
    if ! nssh "$_alias" "bash $_rpath/install.sh"; then
        warn "$_alias — install.sh failed"
        return 1
    fi
    ok "$_alias — installed"
}

# _distribute_one <repo> <install:0|1> <byobu:0|1>
# Orchestrator entry point. Runs the local install.sh, then does the
# remote work. Two modes:
#
#   byobu=0 (default): detached tmux worker per node, no visible output
#                      from the remote command; results reported at end.
#   byobu=1 (-b/--bb): one visible tmux session with a horizontal pane
#                      per node (even-horizontal layout). Each pane runs
#                      the worker in foreground; the user sees live output
#                      from every node. Exit the viewer with Ctrl-b d.
#
# In both modes the work happens on each node's CPU; the local process
# only orchestrates.
_distribute_one() {
    _repo="$1" _do_install="$2" _byobu="${3:-0}"
    _target="$(repo_dir "$_repo")"
    [ -e "$_target/.git" ] || die "$_repo not cloned at $_target"

    # Quiet mode follows --no-bb only. It does NOT depend on TTY state
    # or on whether the stream is being captured by another tool: the
    # visible mode is the default behavior, silence is an explicit
    # choice the user makes with --no-bb.
    _quiet=0
    if [ "$_byobu" = "0" ]; then
        _quiet=1
    fi

    if [ "$_do_install" = "1" ]; then
        if [ -f "$_target/install.sh" ]; then
            if [ "$_quiet" = "1" ]; then
                _local_log="$HOME/.local/share/ut/distribute/$_repo-local.log"
                mkdir -p "$(dirname "$_local_log")"
                if ! bash "$_target/install.sh" > "$_local_log" 2>&1; then
                    err "$_repo  local install.sh failed (log: $_local_log)"
                    return 1
                fi
            else
                info "cmd: bash \"$_target/install.sh\""
                info "running install.sh on local..."
                bash "$_target/install.sh" || { err "$_repo  local install.sh failed"; return 1; }
                ok "local install complete"
            fi
        else
            warn "no install.sh for $_repo, skipping local install"
        fi
    fi

    _devices="$(_nodes_db)"
    [ -f "$_devices" ] || die "device table not found: $_devices"

    if ! command -v tmux >/dev/null 2>&1; then
        warn "tmux not found - falling back to sequential distribution"
        _distribute_one_sequential "$_repo" "$_do_install"
        return $?
    fi

    _log_dir="$HOME/.local/share/ut/distribute"
    mkdir -p "$_log_dir"
    _ut_bin="$(command -v ut)"

    # Collect remote aliases first so both modes share the same loop body.
    _aliases=()
    while IFS= read -r alias <&3; do
        [ -z "$alias" ] && continue
        _dblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_dblk" ] || continue
        ip="$(blockdb_field "$_dblk" ip)"
        is_local_ip "$ip" && continue
        _aliases+=("$alias")
    done 3< <(_all_nodes_aliases)

    if [ "${#_aliases[@]}" -eq 0 ]; then
        info "no remote nodes to distribute to"
        if [ "$_do_install" = "1" ]; then
            log_change "$_repo" "install"
        fi
        return 0
    fi

    if [ "$_byobu" = "1" ]; then
        _distribute_one_byobu "$_repo" "$_do_install" "$_log_dir" "$_ut_bin" "${_aliases[@]}"
        return $?
    fi

    # Detached mode: launch one session per node, then wait.
    for alias in "${_aliases[@]}"; do
        _session="ut-dist-$_repo-$alias"
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_log_dir/$_repo-$alias.rc"
        tmux kill-session -t "$_session" 2>/dev/null || true
        rm -f "$_rc"
        tmux new-session -d -s "$_session" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" > \"$_log\" 2>&1; echo \$? > \"$_rc\"'"
        if [ "$_quiet" = "0" ]; then
            info "launched: $_session"
            info "          attach: tmux attach -t $_session"
            info "          log:    $_log"
        fi
    done

    for _a in "${_aliases[@]}"; do
        _session="ut-dist-$_repo-$_a"
        while tmux has-session -t "$_session" 2>/dev/null; do
            sleep 1
        done
    done

    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "${_aliases[@]}"
    return $?
}

# _distribute_one_byobu <repo> <do_install> <log_dir> <ut_bin> <alias...>
# Visible mode. Builds one tmux session "ut-view-<repo>" with a pane per
# alias in even-horizontal layout. Each pane runs the worker in
# foreground; on exit it writes its rc to <log_dir>/<repo>-<alias>.rc and
# signals "ut-done-<repo>-<alias>" with tmux wait-for. The viewer is
# attached in the foreground; the user exits with Ctrl-b d. Afterwards
# the orchestrator waits for every signal and reports.
_distribute_one_byobu() {
    _repo="$1" _do_install="$2" _log_dir="$3" _ut_bin="$4"
    shift 4
    _aliases=("$@")

    _view="ut-view-$_repo"
    tmux kill-session -t "$_view" 2>/dev/null || true
    for _a in "${_aliases[@]}"; do
        tmux kill-session -t "ut-dist-$_repo-$_a" 2>/dev/null || true
        rm -f "$_log_dir/$_repo-$_a.rc"
    done

    _first="${_aliases[0]}"
    _log0="$_log_dir/$_repo-$_first.log"
    _rc0="$_log_dir/$_repo-$_first.rc"

    # Pane 0: the first alias. The inner shell runs the worker with its
    # stdout/stderr captured by tee to the log AND shown live in the pane,
    # then writes the worker's exit code to the rc file. The rc file is
    # the synchronization primitive: the orchestrator polls it below.
    tmux new-session -d -s "$_view" -n workers \
        "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$_first\" \"$_do_install\" 2>&1 | tee \"$_log0\"; echo \${PIPESTATUS[0]} > \"$_rc0\"'"

    # Remaining aliases: split-window -h creates horizontal panes (side by
    # side). even-horizontal is applied at the end so widths are equal.
    for alias in "${_aliases[@]:1}"; do
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_log_dir/$_repo-$alias.rc"
        tmux split-window -h -t "$_view:workers" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" 2>&1 | tee \"$_log\"; echo \${PIPESTATUS[0]} > \"$_rc\"'"
    done
    tmux select-layout -t "$_view:workers" even-horizontal

    # Attach whenever stdout is a terminal. No other tool's environment
    # variable changes this decision: visible mode is the default.
    if [ -t 1 ]; then
        info "viewer session: $_view (panes: ${#_aliases[@]})"
        info "  exit viewer:  Ctrl-b d   (workers keep running)"
        info "  attach later: tmux attach -t $_view"
        tmux attach -t "$_view" || true
    fi

    # Wait for every worker to finish. Poll the rc file instead of using
    # tmux wait-for: wait-for does not queue signals, so a worker that
    # finished before the wait started would leave the orchestrator
    # blocked forever. Polling the rc file is order-independent.
    for _a in "${_aliases[@]}"; do
        _rc_file="$_log_dir/$_repo-$_a.rc"
        while [ ! -f "$_rc_file" ]; do
            sleep 1
        done
    done

    # The viewer session is left alive so the user can re-attach and
    # inspect scrollback. Cleanup is the user's call (tmux kill-session).

    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "${_aliases[@]}"
    return $?
}

# _distribute_one_report <repo> <do_install> <log_dir> <alias...>
# Reads every rc file and prints a per-node ok/failed line. Shared by both
# modes. Returns 1 if any node reported non-zero.
_distribute_one_report() {
    _repo="$1" _do_install="$2" _log_dir="$3"
    shift 3
    _failed=0
    for _a in "$@"; do
        _rc_file="$_log_dir/$_repo-$_a.rc"
        _log_file="$_log_dir/$_repo-$_a.log"
        if [ -f "$_rc_file" ] && [ "$(cat "$_rc_file" 2>/dev/null)" = "0" ]; then
            ok "$_a - done (log: $_log_file)"
            log_change "$_repo" "distribute:$_a"
            if [ "$_do_install" = "1" ]; then
                log_change "$_repo" "install:$_a"
            fi
        else
            err "$_a - failed (log: $_log_file)"
            _failed=1
        fi
    done
    if [ "$_do_install" = "1" ]; then
        log_change "$_repo" "install"
    fi
    return $_failed
}

# _distribute_one_sequential <repo> <do_install> -- fallback used when
# tmux is not available. Same work as the parallel version, one node at a
# time, in the current shell.
_distribute_one_sequential() {
    _repo="$1" _do_install="$2"
    _devices="$(_nodes_db)"
    [ -f "$_devices" ] || die "device table not found: $_devices"
    while IFS= read -r alias <&3; do
        [ -z "$alias" ] && continue
        _dblk="$(blockdb_get "$_devices" alias "$alias")"
        [ -n "$_dblk" ] || continue
        ip="$(blockdb_field "$_dblk" ip)"
        is_local_ip "$ip" && continue
        _distribute_one_remote "$_repo" "$alias" "$_do_install" || true
    done 3< <(_all_nodes_aliases)
    return 0
}

# _distribute_one_remote <repo> <alias> <do_install> -- the worker for a
# single node. Runs inside its own tmux session (or inline when tmux is
# missing). Pulls the repo on the remote, verifies HEAD convergence, and
# runs install.sh there when requested.
_distribute_one_remote() {
    _repo="$1" _alias="$2" _do_install="$3"
    printf '=== %s on %s start at %s ===\n' "$_repo" "$_alias" "$(date '+%H:%M:%S')"
    _target="$(repo_dir "$_repo")"
    _devices="$(_nodes_db)"
    _dblk="$(blockdb_get "$_devices" alias "$_alias")"
    [ -n "$_dblk" ] || { err "$_alias - no block in device table"; return 1; }
    ip="$(blockdb_field "$_dblk" ip)"
    port="$(blockdb_field "$_dblk" port)"
    _port="${port:-22}"

    if ! _wait_reachable "$ip" "$_port"; then
        err "$_alias - unreachable: $ip:$_port"
        return 1
    fi

    _rpath="$(_remote_repo_path "$_alias" "$_repo")"
    if [ -z "$_rpath" ]; then
        info "$_alias - $_repo not resolved remotely, installing..."
        if ! nssh "$_alias" "ut install $_repo"; then
            err "$_alias - $_repo auto-install failed"
            return 1
        fi
        _rpath="$(_remote_repo_path "$_alias" "$_repo")"
        if [ -z "$_rpath" ]; then
            err "$_alias - ut cannot resolve path after install"
            return 1
        fi
    fi

    _local_head="$(git -C "$_target" rev-parse HEAD 2>/dev/null || printf '')"
    info "$_alias - pulling $_repo (path $_rpath)..."
    if ! nssh "$_alias" "git -C $_rpath pull --rebase origin main"; then
        err "$_alias - pull failed"
        return 1
    fi
    _remote_head="$(nssh "$_alias" "git -C $_rpath rev-parse HEAD" 2>/dev/null || printf '')"
    if [ -n "$_local_head" ] && [ "$_remote_head" != "$_local_head" ]; then
        err "$_alias - HEAD divergence (local=$_local_head remote=${_remote_head:-?})"
        return 1
    fi
    ok "$_alias - $_repo updated (HEAD $_remote_head)"

    if [ "$_do_install" = "1" ]; then
        _distribute_install_remote "$_repo" "$_alias" || return 1
    fi
    return 0
}

_local_repo_names() {
    {
        # Standard location: scan $DST for git dirs.
        if [ -d "$DST" ]; then
            ( cd "$DST" && for _d in */; do
                _d="${_d%/}"
                [ -d "$_d/.git" ] && printf '%s\n' "$_d"
            done )
        fi
        # Alternate locations: any repo whose repos.tsv row has a path.
        awk -F'\t' 'NR>1 && $6 != "" {print $1}' "$TSV" | while IFS= read -r _r; do
            [ -z "$_r" ] && continue
            _p="$(repo_dir "$_r")"
            [ -d "$_p/.git" ] && printf '%s\n' "$_r"
        done
    } | sort -u
}

cmd_distribute() {
    _install=0
    _byobu=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --install|-i) _install=1; shift ;;
            --no-bb)      _byobu=0;   shift ;;
            *)            break ;;
        esac
    done
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut distribute [--install] [--no-bb] <repo|all>"

    if [ "$_repo" != "all" ]; then
        _distribute_one "$_repo" "$_install" "$_byobu" || return 1
        ok "distribute complete"
        return 0
    fi

    # distribute all touches core-tagged repos only; non-core repos are
    # chosen consciously with 'ut distribute <repo>'.
    _skipped=$(mktemp); : > "$_skipped"
    _ok=$(mktemp); : > "$_ok"
    _corelist=$(mktemp); repos_for_target core | sort -u > "$_corelist"
    _local_repo_names | while IFS= read -r _r; do
        [ -z "$_r" ] && continue
        grep -qxF "$_r" "$_corelist" || continue
        _target="$(repo_dir "$_r")"
        _reason=$(_repo_is_dirty "$_target") && { warn "$_r  skipped: $_reason"; printf '%s\n' "$_r" >> "$_skipped"; continue; }
        if [ "$_install" = "1" ]; then
            info "cmd: ut distribute --install $_r"
        else
            info "cmd: ut distribute $_r"
        fi
        _distribute_one "$_r" "$_install" "$_byobu" && printf '%s\n' "$_r" >> "$_ok" || { warn "$_r  skipped: distribute failed"; printf '%s\n' "$_r" >> "$_skipped"; }
    done
    rm -f "$_corelist"
    _nok=$(wc -l < "$_ok" | tr -d ' '); _nskip=$(wc -l < "$_skipped" | tr -d ' ')
    rm -f "$_ok" "$_skipped"
    if [ "$_install" = "1" ]; then
        bold "distribute all --install (core only): $_nok ok, $_nskip skipped"
    else
        bold "distribute all (core only): $_nok ok, $_nskip skipped"
    fi
    return 0
}

