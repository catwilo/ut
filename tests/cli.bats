#!/usr/bin/env bats
# cli.bats -- comportamiento observable del entrypoint ut.
#
# Nota: el entrypoint valida repos.tsv al arrancar aunque el comando no
# lo necesite (help, version). Bug registrado como tarea aparte. Los
# tests siembran un TSV vacio para no bloquearse en esa validacion.

load helpers

setup() { setup_env; }

# _ut <args> -- invocar el binario real con el entorno aislado.
_ut() { bash "$UT_BIN" "$@"; }

# _seed_empty_tsv -- repos.tsv con solo el header.
_seed_empty_tsv() {
    printf 'name\ttags\tdesc\tstate\towner\tpath\n' > "$TSV"
}

@test "ut help: exit 0 con las secciones LEER, SCOPE y GIT" {
    _seed_empty_tsv
    run _ut help
    [ "$status" -eq 0 ]
    [[ "$output" == *"LEER"* ]]
    [[ "$output" == *"SCOPE"* ]]
    [[ "$output" == *"GIT"* ]]
}

@test "ut help: seccion SCOPE describe --all y repos tocados" {
    _seed_empty_tsv
    run _ut help
    [ "$status" -eq 0 ]
    [[ "$output" == *"TOCADOS"* ]]
    [[ "$output" == *"--all"* ]]
}

@test "ut sin repos.tsv: exit != 0 con mensaje" {
    rm -f "$TSV"
    run _ut list
    [ "$status" -ne 0 ]
    [[ "$output" == *"repos.tsv not found"* ]]
}

@test "ut path <repo>: imprime ruta absoluta bajo DST" {
    _seed_tsv myrepo "core" "d" active
    run _ut path myrepo
    [ "$status" -eq 0 ]
    [ "$output" = "$UNIX_TOOLKIT_TOOLS/myrepo" ]
}

@test "ut path sin argumento: exit != 0 con usage" {
    _seed_empty_tsv
    run _ut path
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "ut comando desconocido: exit != 0 con usage" {
    _seed_empty_tsv
    run _ut noexiste
    [ "$status" -ne 0 ]
}

@test "ut list local: lista clones reales, no el registro entero" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _seed_clone a >/dev/null
    run _ut list local
    [ "$status" -eq 0 ]
    # El comando imprime el path del find, que contiene el TMPDIR de bats.
    # Verificar por linea exacta: solo '  a' aparece, '  b' no.
    [[ "$output" == *"  a"* ]]
    ! grep -qx '  b' <<< "$output"
}
