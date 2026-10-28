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
#     -> invoca: nya run [--mode M] @all -- "<comando>"
#
# Lo que queda en ut (politica):
#   - que es "install": bash install.sh en el root del repo.
#
# Lo que va a nya (transporte):
#   - fan-out paralelo, modos, warm-up de multiplex, protocolo
#     .log/.rc, Ctrl-C en dos fases, retencion.
#
# sourced by ./ut; expects $TSV, $DST set by the entrypoint.
# depends on lib-ut/changelog.sh (log_change), lib-ut/query.sh (repo_dir,
# repos_for_target).

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
    # Record this node's post-pull HEAD in its own .ut-nodes/<alias>.tsv.
    # Inline (no new ut subcommand): resolves alias from the node's own
    # nina status and appends. Never fails the worker. The nested printf
    # is kept flat by pre-computing HEAD and timestamp into shell vars.
    printf 'if [ -d "$HOME/.tasks" ]; then\n'
    printf '  _ut_a="$(nina status 2>/dev/null | sed -n 1p | cut -d" " -f1)"\n'
    printf '  [ -n "$_ut_a" ] || _ut_a="$(hostname 2>/dev/null || echo unknown)"\n'
    printf '  mkdir -p "$HOME/.tasks/.ut-nodes"\n'
    printf '  _ut_h="$(git rev-parse HEAD)"\n'
    printf '  _ut_t="$(date +%%s)"\n'
    printf '  printf "%%s\\t%%s\\t%%s\\n" "%s" "$_ut_h" "$_ut_t" >> "$HOME/.tasks/.ut-nodes/$_ut_a.tsv" 2>/dev/null || true\n' "$_drc_repo"
    printf 'fi\n'

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
# cmd_distribute [--install] [--mix|--quiet|--panes] <repo>
#
# Un solo repo por invocacion. No hay "distribute all": si el usuario
# tiene varios repos, los nombra explicitos o arma un loop en su shell.
# Un fan-out implicito a N repos multiplica el blast radius sin aviso y
# no se puede revisar sin inundar el terminal (con 100 repos, 100
# install.sh por nodo). La politica es: una decision, un comando.
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
    [ -z "$_repo" ] && die "usage: ut distribute [--install] [--mix|--quiet|--panes] <repo>"

    if [ "$_repo" = "all" ]; then
        die "ut distribute all fue eliminado. Nombra cada repo explicito:
  ut distribute <repo1> && ut distribute <repo2>
El fan-out implicito multiplica el blast radius sin aviso."
    fi

    _distribute_one "$_repo" "$_install" "${_mode:-auto}" || return 1
    ok "distribute complete"
    return 0
}
