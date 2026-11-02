#!/usr/bin/env bats
# sync.bats -- fan-out de cmd_sync / cmd_fetch / cmd_push / cmd_clone.
#
# Usa un stub de git que registra cada invocacion. Asi el test verifica
# el fan-out (que se invoque git para el repo correcto con los args
# correctos) sin tocar red ni depender de remotos reales.

load helpers

setup() { setup_env; }

# _install_git_stub [ahead_count] -- git falso que:
#   - registra "subcmd<TAB>path<TAB>args..." a $GIT_LOG
#   - "clone <url> <path>" crea $path/.git para simular exito
#   - "rev-list --count @{u}..HEAD" imprime ahead_count (default 0)
_install_git_stub() {
    local ahead="${1:-0}"
    export GIT_LOG="$BATS_TEST_TMPDIR/git.log"
    : > "$GIT_LOG"
    export GIT_AHEAD="$ahead"
    cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
_cmd=""
_path=""
_args=""
# Detectar -C <path>
if [ "\${1:-}" = "-C" ]; then
    _path="\$2"; shift 2
fi
_cmd="\${1:-}"
shift || true
case "\$_cmd" in
    clone)
        _url="\${1:-}"; _dst="\${2:-}"
        printf 'clone\t%s\t%s\n' "\$_dst" "\$_url" >> "\$GIT_LOG"
        mkdir -p "\$_dst/.git"
        exit 0
        ;;
    rev-list)
        for _a in "\$@"; do _args="\$_args \$_a"; done
        printf 'rev-list\t%s\t%s\n' "\$_path" "\$_args" >> "\$GIT_LOG"
        printf '%s\n' "\$GIT_AHEAD"
        exit 0
        ;;
    *)
        for _a in "\$@"; do _args="\$_args \$_a"; done
        printf '%s\t%s\t%s\n' "\$_cmd" "\$_path" "\$_args" >> "\$GIT_LOG"
        exit 0
        ;;
esac
STUB
    chmod +x "$BIN/git"
}

# _seed_cloned <name> -- crea un repo git fake bajo DST (sin git real).
_seed_cloned() {
    mkdir -p "$UNIX_TOOLKIT_TOOLS/$1/.git"
}

# _cloned_repos -- nombres de repos que recibieron 'clone <dst>'.
_cloned_repos() {
    awk -F'\t' '$1=="clone"{print $2}' "$GIT_LOG" | sed "s|$UNIX_TOOLKIT_TOOLS/||"
}

# _pulled <name> -- true si hubo 'git -C <path> pull' para ese repo.
_pulled() {
    grep -q "pull	$UNIX_TOOLKIT_TOOLS/$1	" "$GIT_LOG"
}

# _pushed <name> -- true si hubo 'git -C <path> push' para ese repo.
_pushed() {
    grep -q "push	$UNIX_TOOLKIT_TOOLS/$1	" "$GIT_LOG"
}

# --- cmd_fetch ---

@test "cmd_fetch: invoca git fetch para cada repo clonado" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    _seed_cloned a
    _seed_cloned b
    _install_git_stub 0
    run bash "$UT_BIN" fetch --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"all repos fetched"* ]]
    grep -q "fetch	$UNIX_TOOLKIT_TOOLS/a	" "$GIT_LOG"
    grep -q "fetch	$UNIX_TOOLKIT_TOOLS/b	" "$GIT_LOG"
}

# --- cmd_sync ---

@test "cmd_sync: pull en repos existentes, clone en ausentes" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    _seed_cloned a
    _install_git_stub 0
    run bash "$UT_BIN" sync --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"all repos synced"* ]]
    _pulled a
    _cloned_repos | grep -qx b
}

@test "cmd_sync: reporta fail y exit != 0 cuando pull falla" {
    _seed_tsv a "core" "d" active
    _reload_cache
    _seed_cloned a
    cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
    pull) exit 1 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$BIN/git"
    run bash "$UT_BIN" sync --all
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull failed"* ]]
    [[ "$output" == *"1 repo(s) failed"* ]]
}

# --- cmd_push ---

@test "cmd_push: pushea solo repos con commits pendientes" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    _seed_cloned a
    _seed_cloned b
    _install_git_stub 0
    # Forzar ahead solo para b: parchear el stub para leer un archivo.
    cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ]; then _p="\$2"; shift 2; fi
case "\${1:-}" in
    rev-list)
        if [ "\$_p" = "$UNIX_TOOLKIT_TOOLS/b" ]; then echo 1; else echo 0; fi
        exit 0
        ;;
    push)
        printf 'push\t%s\t\n' "\$_p" >> "$GIT_LOG"
        exit 0
        ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$BIN/git"
    run bash "$UT_BIN" push --all
    _pushed b
    ! _pushed a
}

# --- cmd_clone ---

@test "cmd_clone: clona solo repos ausentes, con URL y destino correctos" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    _seed_cloned a
    _install_git_stub 0
    run bash "$UT_BIN" clone
    [ "$status" -eq 0 ]
    [[ "$output" == *"already cloned"* ]]
    [[ "$output" == *"all repos cloned"* ]]
    local cloned
    cloned="$(_cloned_repos)"
    printf '%s\n' "$cloned" | grep -qx b
    ! printf '%s\n' "$cloned" | grep -qx a
}

@test "cmd_clone: el parser extrae path y url correctamente (regresion)" {
    _seed_tsv myrepo "core" "d" active
    _reload_cache
    _install_git_stub 0
    run bash "$UT_BIN" clone
    [ "$status" -eq 0 ]
    # El destino debe ser el path completo bajo DST, no el nombre del repo.
    grep -q "clone	$UNIX_TOOLKIT_TOOLS/myrepo	" "$GIT_LOG"
    # La URL debe ser completa (git@github.com:<owner>/<repo>.git), no
    # un fragmento con tabs pegados. _seed_tsv pone owner=u, asi que la
    # URL esperada lleva u.
    awk -F'\t' '$1=="clone"{print $3}' "$GIT_LOG" | grep -qx "git@github.com:u/myrepo.git"
}
