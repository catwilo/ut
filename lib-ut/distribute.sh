#!/usr/bin/env bash
# lib-ut/distribute.sh -- distribucion a nodos via nya.
#
# RESPONSABILIDAD UNICA: armar el comando remoto por repo (resolucion
# de path, pull, install opcional) y delegarlo al orquestador de nodos
# (nya run). Ut retiene su politica; nya retiene el transporte.
#
# Modelo:
#   ut distribute <repo> [--install] [--mix|--quiet|--panes]
#     -> arma el comando remoto por repo
#     -> corre install.sh local si --install
#     -> invoca: nya run --mode <mode> @all -- "<comando>"
#     -> log_change segun rc de nya
#
#   ut distribute all [--install] [--mode]
#     -> itera los repos core-tagged, mismo flujo por repo
#
# Lo que queda en ut (politica):
#   - que es "install": bash install.sh en el root del repo.
#   - que es "distribute all": solo repos core-tagged.
#   - _repo_is_dirty como gate.
#   - log_change: registro en .ut-changelog.
#   - _local_repo_names: como ut enumera repos.
#
# Lo que va a nya (transporte):
#   - fan-out paralelo, modos (panes/mix/quiet/json/grouped), warm-up
#     de multiplex, protocolo .log/.rc, Ctrl-C en dos fases, retencion.
#
# sourced by ./ut; expects $TSV, $DST set by the entrypoint.
# depends on lib-ut/changelog.sh (log_change), lib-ut/query.sh (repo_dir,
# repos_for_target), lib-ut/status.sh (_repo_is_dirty).

# ---------------------------------------------------------------------------
# _distribute_remote_cmd <repo> <do_install>
#   Arma el comando remoto que hace todo el trabajo por nodo:
#     1. resolver path con `ut path <repo>`; si no existe, `ut install`.
#     2. cd al path y `git pull --rebase origin main`.
#     3. si do_install=1 y hay install.sh, correrlo. Si el repo declara
#        .ut-install-root, correr con sudo. Sin TTY, sudo falla rapido
#        (mensaje claro) en vez de colgarse.
#   El comando va al worker de nya tal cual (nya no lo interpreta).
# ---------------------------------------------------------------------------
_distribute_remote_cmd() {
    _drc_repo="$1" _drc_install="$2"

    printf 'set -e\n'
    printf 'rpath="$(ut path %s 2>/dev/null || true)"\n' "$_drc_repo"
    printf 'if [ -z "$rpath" ] || [ ! -d "$rpath/.git" ]; then\n'
    printf '    ut install %s\n' "$_drc_repo"
    printf '    rpath="$(ut path %s)"\n' "$_drc_repo"
    printf 'fi\n'
    printf 'cd "$rpath"\n'
    printf 'git pull --rebase origin main\n'

    if [ "$_drc_install" = "1" ]; then
        printf 'if [ -f install.sh ]; then\n'
        printf '    if [ -f .ut-install-root ]; then\n'
        printf '        if sudo -n true 2>/dev/null; then\n'
        printf '            sudo bash install.sh\n'
        printf '        else\n'
        printf '            echo "install.sh requires root; sudo needs password and no TTY available" >&2\n'
        printf '            exit 1\n'
        printf '        fi\n'
        printf '    else\n'
        printf '        bash install.sh\n'
        printf '    fi\n'
        printf 'fi\n'
    fi
}

# ---------------------------------------------------------------------------
# _distribute_one <repo> <install:0|1> <mode>
#   Corre install.sh local si --install y delega el trabajo remoto a nya.
#   Ut confia en el rc agregado de nya: 0 si todos OK, 1 si alguno fallo.
# ---------------------------------------------------------------------------
_distribute_one() {
    _do_repo="$1" _do_install="$2" _do_mode="$3"

    case "$_do_install" in 0|1) ;; *) die "_distribute_one: _do_install must be 0 or 1, got: $_do_install" ;; esac
    case "$_do_mode" in auto|mix|panes|quiet) ;; *) die "_distribute_one: _do_mode must be auto, mix, panes or quiet, got: $_do_mode" ;; esac

    _target="$(repo_dir "$_do_repo")"
    [ -e "$_target/.git" ] || die "$_do_repo not cloned at $_target"

    if [ "$_do_install" = "1" ]; then
        if [ -f "$_target/install.sh" ]; then
            info "cmd: bash \"$_target/install.sh\""
            info "running install.sh on local..."
            if ! bash "$_target/install.sh"; then
                err "$_do_repo  local install.sh failed"
                return 1
            fi
            ok "local install complete"
        else
            warn "no install.sh for $_do_repo, skipping local install"
        fi
    fi

    _remote_cmd="$(_distribute_remote_cmd "$_do_repo" "$_do_install")"

    # Delegar a nya. Si _do_mode=auto, no pasamos --mode: nya aplica su
    # auto-deteccion (CLIPSO_ACTIVE + TMUX + TTY). Si el invocador fijo
    # un modo explicito (--mix/--panes/--quiet), lo pasamos tal cual.
    if [ "$_do_mode" = "auto" ]; then
        info "cmd: nya run @all -- <comando por nodo>  (mode=auto)"
        if nya run @all -- "$_remote_cmd"; then
            log_change "$_do_repo" "distribute"
            if [ "$_do_install" = "1" ]; then
                log_change "$_do_repo" "install"
            fi
            return 0
        fi
    else
        info "cmd: nya run --mode $_do_mode @all -- <comando por nodo>"
        if nya run --mode "$_do_mode" @all -- "$_remote_cmd"; then
            log_change "$_do_repo" "distribute"
            if [ "$_do_install" = "1" ]; then
                log_change "$_do_repo" "install"
            fi
            return 0
        fi
    fi

    err "$_do_repo  distribute failed (nya reported non-zero)"
    return 1
}

# ---------------------------------------------------------------------------
# _local_repo_names -- imprime los repos clonados localmente (uno por linea).
#   Standard location: scan $DST. Alternate: cualquier repos.tsv con path.
# ---------------------------------------------------------------------------
_local_repo_names() {
    {
        if [ -d "$DST" ]; then
            ( cd "$DST" && for _d in */; do
                _d="${_d%/}"
                [ -d "$_d/.git" ] && printf '%s\n' "$_d"
            done )
        fi
        awk -F'\t' 'NR>1 && $6 != "" {print $1}' "$TSV" | while IFS= read -r _r; do
            [ -z "$_r" ] && continue
            _p="$(repo_dir "$_r")"
            [ -d "$_p/.git" ] && printf '%s\n' "$_r"
        done
    } | sort -u
}

# ---------------------------------------------------------------------------
# cmd_distribute [--install] [--mix|--quiet|--panes] <repo|all>
# ---------------------------------------------------------------------------
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

    # Si el invocador no fijo modo, no elegimos uno: dejamos que nya lo
    # haga con su auto-deteccion ($CLIPSO_ACTIVE + $TMUX + TTY).
    _mode_arg=""
    [ -n "$_mode" ] && _mode_arg="--mode $_mode"

    if [ "$_repo" != "all" ]; then
        # shellcheck disable=SC2086
        _distribute_one "$_repo" "$_install" "${_mode:-auto}" || return 1
        ok "distribute complete"
        return 0
    fi

    # distribute all toca solo repos core-tagged.
    _skipped=$(mktemp); : > "$_skipped"
    _ok=$(mktemp); : > "$_ok"
    _corelist=$(mktemp); repos_for_target core | sort -u > "$_corelist"
    while IFS= read -r _r <&3; do
        [ -z "$_r" ] && continue
        grep -qxF "$_r" "$_corelist" || continue
        _target="$(repo_dir "$_r")"
        _reason=$(_repo_is_dirty "$_target") && {
            warn "$_r  skipped: $_reason"
            printf '%s\n' "$_r" >> "$_skipped"
            continue
        }
        if [ "$_install" = "1" ]; then
            info "cmd: ut distribute --install $_r"
        else
            info "cmd: ut distribute $_r"
        fi
        if _distribute_one "$_r" "$_install" "${_mode:-auto}"; then
            printf '%s\n' "$_r" >> "$_ok"
        else
            warn "$_r  skipped: distribute failed"
            printf '%s\n' "$_r" >> "$_skipped"
        fi
    done 3< <(_local_repo_names)
    rm -f "$_corelist"
    _nok=$(wc -l < "$_ok" | tr -d ' ')
    _nskip=$(wc -l < "$_skipped" | tr -d ' ')
    rm -f "$_ok" "$_skipped"
    if [ "$_install" = "1" ]; then
        bold "distribute all --install (core only): $_nok ok, $_nskip skipped"
    else
        bold "distribute all (core only): $_nok ok, $_nskip skipped"
    fi
    return 0
}
