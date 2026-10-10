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
    _repo="$1" _do_install="$2" _mode="${3:-panes}" _sig_dir="$4"
    case "$_do_install" in 0|1) ;; *) die "_do_install must be 0 or 1, got: $_do_install" ;; esac
    case "$_mode" in panes|mix|quiet) ;; *) die "_mode must be panes, mix or quiet, got: $_mode" ;; esac
    [ -n "$_sig_dir" ] && [ -d "$_sig_dir" ] || die "_sig_dir missing or not a directory"
    _target="$(repo_dir "$_repo")"
    [ -e "$_target/.git" ] || die "$_repo not cloned at $_target"

    if [ "$_do_install" = "1" ]; then
        if [ -f "$_target/install.sh" ]; then
            info "cmd: bash \"$_target/install.sh\""
            info "running install.sh on local..."
            bash "$_target/install.sh" || { err "$_repo  local install.sh failed"; return 1; }
            ok "local install complete"
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
    # Purge logs older than 7 days; keeps the directory bounded without a
    # full rotation system. Non-fatal on failure, but the reason is
    # printed: a permission problem on the log dir is worth knowing.
    if ! find "$_log_dir" -type f -mtime +7 -delete; then
        warn "could not purge old distribute logs under $_log_dir (reason above)"
    fi
    _ut_bin="$(command -v ut)"
    [ -n "$_ut_bin" ] || die "ut not found in PATH"

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

    case "$_mode" in
        quiet)
            _distribute_one_quiet "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "$_ut_bin" "${_aliases[@]}"
            ;;
        mix)
            _distribute_one_mix "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "$_ut_bin" "${_aliases[@]}"
            ;;
        panes|*)
            _distribute_one_panes "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "$_ut_bin" "${_aliases[@]}"
            ;;
    esac
    return $?
}

# _distribute_one_mix <repo> <do_install> <log_dir> <sig_dir> <ut_bin> <alias...>
# Parallel mode with interleaved output. Every alias runs in its own
# background subshell; its stdout/stderr is piped through a per-line
# prefixer that writes "[alias] <line>" (with a deterministic colour
# when stdout is a terminal). Lines from different aliases arrive in
# whatever order the workers produce them; the tag identifies the origin.
# The exit code of each worker is captured from PIPESTATUS before the
# pipeline's subshell exits and written to <sig_dir>/<alias>.rc.
_distribute_one_mix() {
    _repo="$1" _do_install="$2" _log_dir="$3" _sig_dir="$4" _ut_bin="$5"
    shift 5
    _aliases=("$@")

    # Palette and reset are resolved here, not at module load: a library
    # sourced once at startup cannot know whether the eventual command's
    # stdout is a terminal. The decision is per invocation.
    _palette=(36 35 32 33 34 31)
    if [ -t 1 ]; then
        _reset=$'\033[0m'
    else
        _reset=""
    fi

    _pids=()
    _idx=0
    for alias in "${_aliases[@]}"; do
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_sig_dir/$alias.rc"
        : > "$_log"

        # Colour assigned by position in the list: first alias gets the
        # first palette entry, second the second, and so on. Cycle when
        # the list outgrows the palette. Automatic: no per-node config.
        if [ -n "$_reset" ]; then
            _color=$(printf '\033[%sm' "${_palette[$(( _idx % ${#_palette[@]} ))]}")
        else
            _color=""
        fi
        _idx=$(( _idx + 1 ))

        # Pipeline shape, end to end, all in one background job:
        #
        #   { worker ; echo rc } | prefix each line | tee to log AND stdout
        #
        # The worker's stdout and stderr go into the first pipe. The
        # prefixer reads line by line and writes each line tagged with
        # `[alias]` to the second pipe. `tee` splits that pipe: one copy
        # to the caller's stdout (so the invocation sees it live), one
        # copy to <log_dir>/<repo>-<alias>.log (so the file exists even
        # when stdout is captured). Nothing goes to /dev/null: the
        # caller's stdout is the real output, and the file is a persisted
        # mirror of the same bytes.
        #
        # The whole pipeline is backgrounded at once. `wait` below joins
        # on all of them.
        {
            "$_ut_bin" _distribute-one "$_repo" "$alias" "$_do_install" 2>&1
            printf '%s\n' "$?" > "$_rc"
        } \
        | while IFS= read -r _line; do
            if [ -n "$_color" ]; then
                printf '%b[%s]%b %s\n' "$_color" "$alias" "$_reset" "$_line"
            else
                printf '[%s] %s\n' "$alias" "$_line"
            fi
        done \
        | tee -a "$_log" &

        _pids+=("$!")
    done

    for _p in "${_pids[@]}"; do
        wait "$_p" || true
    done

    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}"
    return $?
}

# _distribute_one_quiet <repo> <do_install> <log_dir> <sig_dir> <ut_bin> <alias...>
# Quiet mode. Workers run in detached tmux sessions; their stdout and
# stderr go straight to <log_dir>/<repo>-<alias>.log. Only the final
# summary reaches the caller's stdout. No pane is created, no session
# is attached, no per-worker line is echoed.
#
# This is the only mode that hides worker output entirely, so it is
# opt-in (--quiet); it is never picked automatically. Any caller that
# wants to see the workers in real time uses panes or mix.
_distribute_one_quiet() {
    _repo="$1" _do_install="$2" _log_dir="$3" _sig_dir="$4" _ut_bin="$5"
    shift 5
    _aliases=("$@")

    for alias in "${_aliases[@]}"; do
        _session="ut-quiet-$_repo-$alias"
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_sig_dir/$alias.rc"
        tmux kill-session -t "$_session" 2>/dev/null || true
        tmux new-session -d -s "$_session" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" > \"$_log\" 2>&1; echo \$? > \"$_rc\"'"
    done

    _wait_for_workers "$_sig_dir" "${_aliases[@]}"

    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}"
    return $?
}

# _distribute_one_panes <repo> <do_install> <log_dir> <sig_dir> <ut_bin> <alias...>
# Visible mode. Two contexts:
#
#   1. Inside the user's tmux ($TMUX set): a NEW WINDOW named ut-workers
#      is created in the current session and split into one pane per
#      alias (even-horizontal). The user's current window is untouched.
#      tmux switches to the new window automatically, so the user sees
#      the panes without doing anything. remain-on-exit keeps the panes
#      open after workers finish so scrollback is readable.
#
#   2. Outside tmux, real TTY, no capture wrapper: create a new detached
#      session ut-view-<repo> and attach it in the foreground. tmux attach
#      writes only to /dev/tty, so the attach cannot leak into any
#      redirected stdout/stderr.
#
#   3. Outside tmux with UT_NO_ATTACH set or no TTY: silent mode. Only
#      the final summary reaches stdout; worker sessions are detached.
_distribute_one_panes() {
    _repo="$1" _do_install="$2" _log_dir="$3" _sig_dir="$4" _ut_bin="$5"
    shift 5
    _aliases=("$@")

    # Case 1: inside the user's tmux. Create a new window in the current
    # session so the user's current window/layout is not disturbed.
    if [ -n "${TMUX:-}" ]; then
        _win="ut-workers"
        # Kill any previous window with the same name to start clean.
        tmux kill-window -t "$_win" 2>/dev/null || true

        _first="${_aliases[0]}"
        _log0="$_log_dir/$_repo-$_first.log"
        _rc0="$_sig_dir/$_first.rc"

        tmux new-window -n "$_win" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$_first\" \"$_do_install\" 2>&1 | tee \"$_log0\"; echo \${PIPESTATUS[0]} > \"$_rc0\"'"

        for alias in "${_aliases[@]:1}"; do
            _log="$_log_dir/$_repo-$alias.log"
            _rc="$_sig_dir/$alias.rc"
            tmux split-window -h -t "$_win" \
                "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" 2>&1 | tee \"$_log\"; echo \${PIPESTATUS[0]} > \"$_rc\"'"
        done
        tmux select-layout -t "$_win" even-horizontal
        # Keep panes readable after workers exit.
        tmux set-option -w -t "$_win" remain-on-exit on

        _wait_for_workers "$_sig_dir" "${_aliases[@]}"
        _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}"
        return $?
    fi

    # Cases 2 and 3: outside tmux.
    if [ -z "${UT_NO_ATTACH:-}" ] && [ -t 1 ]; then
        _view="ut-view-$_repo"
        tmux kill-session -t "$_view" 2>/dev/null || true

        _first="${_aliases[0]}"
        _log0="$_log_dir/$_repo-$_first.log"
        _rc0="$_sig_dir/$_first.rc"

        tmux new-session -d -s "$_view" -n workers \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$_first\" \"$_do_install\" 2>&1 | tee \"$_log0\"; echo \${PIPESTATUS[0]} > \"$_rc0\"'"

        for alias in "${_aliases[@]:1}"; do
            _log="$_log_dir/$_repo-$alias.log"
            _rc="$_sig_dir/$alias.rc"
            tmux split-window -h -t "$_view:workers" \
                "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" 2>&1 | tee \"$_log\"; echo \${PIPESTATUS[0]} > \"$_rc\"'"
        done
        tmux select-layout -t "$_view:workers" even-horizontal
        tmux set-option -w -t "$_view:workers" remain-on-exit on

        info "viewer session: $_view (panes: ${#_aliases[@]})"
        info "  exit viewer:  Ctrl-b d   (workers keep running)"
        info "  attach later: tmux attach -t $_view"
        # Let tmux use its default fds (the caller's stdin/stdout/stderr).
        # An explicit `</dev/tty >/dev/tty` breaks on Termux: the client
        # cannot open the controlling terminal through an explicit path
        # ("open terminal failed: can't use /dev/tty"). Without the
        # redirection the client inherits the pty it was launched from.
        if ! tmux attach -t "$_view"; then
            warn "tmux attach failed; workers keep running in session $_view"
            warn "  re-attach with: tmux attach -t $_view"
        fi

        _wait_for_workers "$_sig_dir" "${_aliases[@]}"
        _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}"
        return $?
    fi

    # Case 3: silent mode. Run workers detached in individual sessions,
    # wait, report. No attach is attempted, no viewer session is created.
    for alias in "${_aliases[@]}"; do
        _session="ut-dist-$_repo-$alias"
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_sig_dir/$alias.rc"
        tmux kill-session -t "$_session" 2>/dev/null || true
        tmux new-session -d -s "$_session" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" > \"$_log\" 2>&1; echo \$? > \"$_rc\"'"
    done

    _wait_for_workers "$_sig_dir" "${_aliases[@]}"
    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}"
    return $?
}

# _wait_for_workers <sig_dir> <alias...>
# Polls <sig_dir>/<alias>.rc until every alias has one, or until
# UT_DISTRIBUTE_MAX_WAIT seconds have elapsed (default 3600). Timeout is
# reported as a failure; a node that never finishes is not silently
# treated as success.
_wait_for_workers() {
    _sig_dir="$1"
    shift
    _max_wait="${UT_DISTRIBUTE_MAX_WAIT:-3600}"
    _elapsed=0
    while :; do
        _pending=0
        for _a in "$@"; do
            [ -f "$_sig_dir/$_a.rc" ] || _pending=$(( _pending + 1 ))
        done
        [ "$_pending" -eq 0 ] && return 0
        if [ "$_elapsed" -ge "$_max_wait" ]; then
            err "timeout after ${_max_wait}s waiting for: $_pending worker(s)"
            return 1
        fi
        sleep 2
        _elapsed=$(( _elapsed + 2 ))
    done
}

# _distribute_one_report <repo> <do_install> <log_dir> <sig_dir> <alias...>
# Reads every rc file and prints a per-node ok/failed line. Shared by all
# modes. Returns 1 if any node reported non-zero.
_distribute_one_report() {
    _repo="$1" _do_install="$2" _log_dir="$3" _sig_dir="$4"
    shift 4
    _failed=0
    for _a in "$@"; do
        _rc_file="$_sig_dir/$_a.rc"
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
    _mode=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --install|-i) _install=1; shift ;;
            --mix)        _mode="mix";   shift ;;
            --quiet)      _mode="quiet"; shift ;;
            --panes)      _mode="panes"; shift ;;
            *)            break ;;
        esac
    done
    _repo="${1:-}"
    [ -z "$_repo" ] && die "usage: ut distribute [--install] [--mix|--quiet|--panes] <repo|all>"

    # Mode selection when the caller did not force one:
    #
    #   captured (CLIPSO_ACTIVE set) + NOT inside tmux  ->  mix
    #   anything else                                    ->  panes
    #
    # Why mix in that one case: under clipso, clipso owns the PTY and
    # captures everything ut writes to stdout. Panes need a terminal they
    # can paint on that clipso does not capture; the only such terminal
    # is a tmux session started OUTSIDE clipso ($TMUX set at the moment
    # the distribution runs). When clipso runs with no surrounding tmux,
    # there is no such terminal, and the only way to show the workers'
    # output at all is to interleave it on ut's own stdout. mix does
    # exactly that, with a coloured `[alias]` tag per line.
    #
    # With clipso + tmux, and without clipso in any context, panes are
    # available and are the default.
    if [ -z "$_mode" ]; then
        if [ -n "${CLIPSO_ACTIVE:-}" ] && [ -z "${TMUX:-}" ]; then
            _mode="mix"
        else
            _mode="panes"
        fi
    fi

    # Signals directory: one per process, shared across every repo this
    # invocation handles (`distribute all` calls _distribute_one N times).
    # A single trap cleans it up on exit; workers write <sig_dir>/<alias>.rc
    # and the orchestrator polls those files.
    _sig_dir="$(mktemp -d "${TMPDIR:-/tmp}/ut-dist.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_sig_dir'" EXIT

    if [ "$_repo" != "all" ]; then
        _distribute_one "$_repo" "$_install" "$_mode" "$_sig_dir" || return 1
        ok "distribute complete"
        return 0
    fi

    # distribute all touches core-tagged repos only; non-core repos are
    # chosen consciously with 'ut distribute <repo>'.
    _skipped=$(mktemp); : > "$_skipped"
    _ok=$(mktemp); : > "$_ok"
    _corelist=$(mktemp); repos_for_target core | sort -u > "$_corelist"
    # Process substitution keeps the loop in the current shell: _sig_dir,
    # the trap, and the exit code of _distribute_one all stay in scope.
    # A `| while` would run the body in a subshell and lose that context.
    while IFS= read -r _r <&3; do
        [ -z "$_r" ] && continue
        grep -qxF "$_r" "$_corelist" || continue
        _target="$(repo_dir "$_r")"
        _reason=$(_repo_is_dirty "$_target") && { warn "$_r  skipped: $_reason"; printf '%s\n' "$_r" >> "$_skipped"; continue; }
        if [ "$_install" = "1" ]; then
            info "cmd: ut distribute --install $_r"
        else
            info "cmd: ut distribute $_r"
        fi
        _distribute_one "$_r" "$_install" "$_mode" "$_sig_dir" && printf '%s\n' "$_r" >> "$_ok" || { warn "$_r  skipped: distribute failed"; printf '%s\n' "$_r" >> "$_skipped"; }
    done 3< <(_local_repo_names)
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

