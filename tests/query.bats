#!/usr/bin/env bats
# query.bats -- repo_dir, repos_for_target, repos_touched, repos_active.

load helpers

setup() { setup_env; }

# --- repo_dir ---

@test "repo_dir: ruta por defecto bajo DST cuando no hay columna path" {
    _seed_tsv myrepo "core" "desc" active
    _reload_cache
    run repo_dir myrepo
    [ "$status" -eq 0 ]
    [ "$output" = "$UNIX_TOOLKIT_TOOLS/myrepo" ]
}

@test "repo_dir: columna path custom se usa cuando existe en disco" {
    custom="$BATS_TEST_TMPDIR/custom/myrepo"
    mkdir -p "$custom"
    _seed_tsv myrepo "core" "desc" active "$custom"
    _reload_cache
    run repo_dir myrepo
    [ "$status" -eq 0 ]
    [ "$output" = "$custom" ]
}

@test "repo_dir: path custom inexistente cae al default bajo DST" {
    _seed_tsv myrepo "core" "desc" active "/no/existe/myrepo"
    _reload_cache
    run repo_dir myrepo
    [ "$status" -eq 0 ]
    [ "$output" = "$UNIX_TOOLKIT_TOOLS/myrepo" ]
}

@test "repo_dir: nombre vacio falla" {
    run repo_dir ""
    [ "$status" -ne 0 ]
}

# --- repos_active ---

@test "repos_active: excluye repos archivados" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" archived
    _seed_tsv c "core" "d" active
    _reload_cache
    run repos_active
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" != *"b"* ]]
    [[ "$output" == *"c"* ]]
}

# --- repos_touched ---

@test "repos_touched: union de manifiestos, intersectado con active" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _seed_tsv z "core" "d" archived
    _reload_cache
    printf 'a\tabc\t1\n' > "$HOME/.tasks/.ut-nodes/tx2.tsv"
    printf 'b\tabc\t1\nz\tabc\t1\n' > "$HOME/.tasks/.ut-nodes/db1.tsv"
    run repos_touched
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" == *"b"* ]]
    [[ "$output" != *"z"* ]]
}

@test "repos_touched: sin manifiestos emite vacio" {
    _seed_tsv a "core" "d" active
    _reload_cache
    run repos_touched
    [ -z "$output" ]
}

# --- repos_for_target ---

@test "repos_for_target vacio: usa touched cuando hay manifiesto" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    printf 'a\tabc\t1\n' > "$HOME/.tasks/.ut-nodes/tx2.tsv"
    run repos_for_target ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" != *"b"* ]]
}

@test "repos_for_target vacio: fallback a active con warn cuando manifiesto vacio" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    run repos_for_target ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" == *"b"* ]]
    [[ "$output" == *"no .ut-nodes manifest entries"* ]]
}

@test "repos_for_target --all: todos los active, sin manifiesto" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _seed_tsv z "core" "d" archived
    _reload_cache
    run repos_for_target --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" == *"b"* ]]
    [[ "$output" != *"z"* ]]
}

@test "repos_for_target tag: solo repos con ese tag" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "tool" "d" active
    _reload_cache
    run repos_for_target core
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" != *"b"* ]]
}

@test "repos_for_target lista coma-separada: union sin duplicados" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    run repos_for_target "a,b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a"* ]]
    [[ "$output" == *"b"* ]]
}
