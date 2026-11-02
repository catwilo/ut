#!/usr/bin/env bats
# changelog.bats -- log_node_state (compactacion), check_stale.

load helpers

setup() { setup_env; }

@test "log_node_state: crea el manifiesto cuando no existe" {
    _seed_tsv myrepo "core" "d" active
    _reload_cache
    _seed_clone myrepo >/dev/null
    log_node_state myrepo
    [ -f "$HOME/.tasks/.ut-nodes/tx2.tsv" ]
    grep -q "^myrepo" "$HOME/.tasks/.ut-nodes/tx2.tsv"
}

@test "log_node_state: compacta antes de append (una fila por repo)" {
    _seed_tsv myrepo "core" "d" active
    _reload_cache
    _seed_clone myrepo >/dev/null
    printf 'myrepo\told1\t111\n' > "$HOME/.tasks/.ut-nodes/tx2.tsv"
    printf 'myrepo\told2\t222\n' >> "$HOME/.tasks/.ut-nodes/tx2.tsv"
    log_node_state myrepo
    n="$(grep -c '^myrepo' "$HOME/.tasks/.ut-nodes/tx2.tsv")"
    [ "$n" -eq 1 ]
}

@test "log_node_state: preserva filas de otros repos al compactar" {
    _seed_tsv a "core" "d" active
    _seed_tsv b "core" "d" active
    _reload_cache
    _seed_clone a >/dev/null
    _seed_clone b >/dev/null
    printf 'a\told1\t111\nb\toldb\t222\n' > "$HOME/.tasks/.ut-nodes/tx2.tsv"
    log_node_state a
    grep -q '^b' "$HOME/.tasks/.ut-nodes/tx2.tsv"
    [ "$(grep -c '^a' "$HOME/.tasks/.ut-nodes/tx2.tsv")" -eq 1 ]
}

@test "log_node_state: no escribe si el repo no esta clonado" {
    _seed_tsv myrepo "core" "d" active
    _reload_cache
    log_node_state myrepo
    [ ! -f "$HOME/.tasks/.ut-nodes/tx2.tsv" ]
}

@test "log_node_state: no escribe si el alias no resuelve" {
    _seed_tsv myrepo "core" "d" active
    _reload_cache
    _seed_clone myrepo >/dev/null
    # Sobrescribir el stub de nina para que devuelva vacio.
    cat > "$BIN/nina" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$BIN/nina"
    log_node_state myrepo
    [ ! -f "$HOME/.tasks/.ut-nodes/tx2.tsv" ]
}
