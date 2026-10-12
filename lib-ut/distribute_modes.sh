#!/usr/bin/env bash
# lib-ut/distribute_modes.sh -- modos de presentacion del distribute.
#
# RESPONSABILIDAD UNICA: como se muestra el trabajo de cada worker
# remoto. Tres modos:
#   - panes:  tmux window con un panel por nodo (visible, foreground)
#   - mix:    stdout intercalado con prefijo [alias] por linea
#   - quiet:  workers en sesiones tmux detached; solo resumen final
# El trabajo remoto en si vive en distribute.sh; aqui solo se lanza,
# se espera y se reporta.
#
# sourced by ./ut; expects _sig_dir, _log_dir, _ut_bin set by the caller.

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

    local -a _sessions=()
    for alias in "${_aliases[@]}"; do
        _session="ut-quiet-$_repo-$alias"
        _sessions+=("$_session")
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_sig_dir/$alias.rc"
        tmux kill-session -t "$_session" 2>/dev/null || true
        tmux new-session -d -s "$_session" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" > \"$_log\" 2>&1; echo \$? > \"$_rc\"'"
    done

    local _wait_rc=0 _report_rc=0
    _wait_for_workers "$_sig_dir" "${_aliases[@]}" || _wait_rc=$?
    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}" || _report_rc=$?

    for _session in "${_sessions[@]}"; do
        tmux kill-session -t "$_session" 2>/dev/null || true
    done

    [ "$_wait_rc" -eq 0 ] && [ "$_report_rc" -eq 0 ]
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
        tmux set-option -w -t "$_win" remain-on-exit on

        local _wait_rc=0 _report_rc=0
        _wait_for_workers "$_sig_dir" "${_aliases[@]}" || _wait_rc=$?
        _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}" || _report_rc=$?

        # Automatic cleanup: kill the workers window. tmux returns the
        # user to the previous window when the current one dies.
        tmux kill-window -t "$_win" 2>/dev/null || true

        [ "$_wait_rc" -eq 0 ] && [ "$_report_rc" -eq 0 ]
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

        local _wait_rc=0 _report_rc=0
        _wait_for_workers "$_sig_dir" "${_aliases[@]}" || _wait_rc=$?
        _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}" || _report_rc=$?

        # Automatic cleanup: kill the viewer session.
        tmux kill-session -t "$_view" 2>/dev/null || true

        [ "$_wait_rc" -eq 0 ] && [ "$_report_rc" -eq 0 ]
        return $?
    fi

    # Case 3: silent mode. Run workers detached in individual sessions,
    # wait, report, then kill every session automatically. No attach is
    # attempted, no viewer session is left behind.
    local -a _sessions=()
    for alias in "${_aliases[@]}"; do
        _session="ut-dist-$_repo-$alias"
        _sessions+=("$_session")
        _log="$_log_dir/$_repo-$alias.log"
        _rc="$_sig_dir/$alias.rc"
        tmux kill-session -t "$_session" 2>/dev/null || true
        tmux new-session -d -s "$_session" \
            "bash -c '\"$_ut_bin\" _distribute-one \"$_repo\" \"$alias\" \"$_do_install\" > \"$_log\" 2>&1; echo \$? > \"$_rc\"'"
    done

    local _wait_rc=0 _report_rc=0
    _wait_for_workers "$_sig_dir" "${_aliases[@]}" || _wait_rc=$?
    _distribute_one_report "$_repo" "$_do_install" "$_log_dir" "$_sig_dir" "${_aliases[@]}" || _report_rc=$?

    for _session in "${_sessions[@]}"; do
        tmux kill-session -t "$_session" 2>/dev/null || true
    done

    [ "$_wait_rc" -eq 0 ] && [ "$_report_rc" -eq 0 ]
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
