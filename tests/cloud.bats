#!/usr/bin/env bats
# cloud.bats -- cloud_snapshot usa paginacion (no trunca).

load helpers

setup() { setup_env; }

@test "cloud_snapshot: usa --paginate via gh api, no --limit" {
    cat > "$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Registrar los argumentos exactos para que el test los inspeccione.
printf '%s\n' "$@" > "$GH_ARGS"
# Emular salida paginada: tres repos.
printf 'repo1\nrepo2\nrepo3\n'
FAKE_GH
    chmod +x "$BIN/gh"
    export GH_ARGS="$BATS_TEST_TMPDIR/gh-args"
    source "$LIB_UT/status.sh"
    run cloud_snapshot "$BATS_TEST_TMPDIR/snap"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/snap" ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/snap")" -eq 3 ]
    grep -qx 'repo1' "$BATS_TEST_TMPDIR/snap"
    # Debe invocar gh api --paginate, no gh repo list --limit.
    grep -qx 'api' "$GH_ARGS"
    grep -qx -- '--paginate' "$GH_ARGS"
    ! grep -qx -- '--limit' "$GH_ARGS"
}
