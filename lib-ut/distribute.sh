#!/usr/bin/env bash
# lib-ut/distribute.sh -- orquestador de distribucion a nodos.
#
# RESPONSABILIDAD UNICA: coordinar el trabajo remoto de un repo sobre
# cada nodo. Los modos de presentacion (panes/mix/quiet) viven en
# distribute_modes.sh; aqui vive el trabajo en si (pull + install) y la
# logica de dispatch.
#
# sourced by ./ut; expects $TSV, $DST set by the entrypoint
# depends on lib-ut/changelog.sh (log_change), lib-ut/query.sh (repo_dir,
# repos_all, repos_for_target), lib-ut/nodes.sh (_nodes_db, _all_nodes_aliases,
# _wait_reachable), lib-ut/distribute_modes.sh (_distribute_one_*).

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
#
# If the repo declares .ut-install-root at its root, install.sh requires
# root. In that case we run with "nssh -t" so a TTY is allocated on the
# remote and sudo can prompt for the password there. sudo reads the
# password from the TTY, never from stdin/argv/env, so it never lands in
# logs, process tables or shell history. If no TTY is available (quiet
# mode, backgrounded), install.sh fails fast with an actionable message
# instead of hanging on a sudo prompt.
_distribute_install_remote() {
    _repo="$1" _alias="$2"
    _rpath="$(_remote_repo_path "$_alias" "$_repo")"
    if [ -z "$_rpath" ]; then
        warn "$_alias — cannot resolve repo path, skipping install"
        return 1
    fi
    if nssh "$_alias" "test -f \"$_rpath/.ut-install-root\"" 2>/dev/null; then
        info "cmd: nssh -t \"$_alias\" \"bash $_rpath/install.sh\"  (requires root)"
        if ! nssh -t "$_alias" "bash $_rpath/install.sh"; then
            warn "$_alias — install.sh failed"
            return 1
        fi
    else
        info "cmd: nssh \"$_alias\" \"bash $_rpath/install.sh\""
        if ! nssh "$_alias" "bash $_rpath/install.sh"; then
            warn "$_alias — install.sh failed"
            return 1
        fi
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
        if _distribute_one "$_r" "$_install" "$_mode" "$_sig_dir"; then
            printf '%s\n' "$_r" >> "$_ok"
        else
            warn "$_r  skipped: distribute failed"
            printf '%s\n' "$_r" >> "$_skipped"
        fi
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
