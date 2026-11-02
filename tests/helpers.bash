# helpers.bash -- shared setup for ut BATS tests.
#
# Aisla HOME, DST y TSV via las tres variables que el entrypoint respeta:
#   HOME                  -> ~/.tasks (manifiestos .ut-nodes)
#   UNIX_TOOLKIT_TOOLS    -> DST (donde viven los clones)
#   UT_HOME               -> directorio que contiene repos.tsv
# Nada del entorno real se toca.

setup_env() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$TMPDIR"

    export REPO="$BATS_TEST_DIRNAME/.."
    export UT_BIN="$REPO/ut"
    export LIB_UT="$REPO/lib-ut"

    export UNIX_TOOLKIT_TOOLS="$BATS_TEST_TMPDIR/clones"
    mkdir -p "$UNIX_TOOLKIT_TOOLS"

    export UT_HOME="$BATS_TEST_TMPDIR/registry"
    mkdir -p "$UT_HOME"
    export TSV="$UT_HOME/repos.tsv"

    mkdir -p "$HOME/.tasks/.ut-nodes"

    # ut sourcea blockdb.sh de nina en runtime (lib-ut/nodes.sh). Copiar
    # el real al HOME aislado para que el CLI corra sin tocar el HOME real.
    _nina_blockdb="$HOME/.local/share/nina/lib/core/blockdb.sh"
    mkdir -p "$(dirname "$_nina_blockdb")"
    cp "$REPO/../nina/lib/core/blockdb.sh" "$_nina_blockdb"

    # Stubs para que log_node_state no invoque nina real.
    export BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    cat > "$BIN/nina" <<'FAKE_NINA'
#!/usr/bin/env bash
[[ "${1:-}" == "status" ]] && printf 'tx2 100.0.0.2 u 8022 celular android\n'
exit 0
FAKE_NINA
    chmod +x "$BIN/nina"
    export PATH="$BIN:$PATH"

    # Replicar el contexto que el entrypoint ut construye antes de sourcear
    # los libs: globals y helpers de output. Sin esto, los libs llaman a
    # funciones y variables inexistentes.
    GITHUB_USER="test-user"
    DST="$UNIX_TOOLKIT_TOOLS"
    G=''; Y=''; R=''; C=''; B=''; Z=''
    ok()   { printf 'OK %s\n' "$*"; }
    warn() { printf 'WARN %s\n' "$*"; }
    err()  { printf 'ERR %s\n' "$*" >&2; }
    info() { printf 'INFO %s\n' "$*"; }
    bold() { printf '%s\n' "$*"; }
    die()  { err "$*"; exit 1; }

    # shellcheck source=/dev/null
    . "$LIB_UT/changelog.sh"
    # shellcheck source=/dev/null
    . "$LIB_UT/query.sh"
}

# _seed_tsv <name> <tags> <desc> <state> [path] -- append a repos.tsv row.
_seed_tsv() {
    if [ ! -f "$TSV" ]; then
        printf 'name\ttags\tdesc\tstate\towner\tpath\n' > "$TSV"
    fi
    printf '%s\t%s\t%s\t%s\tu\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$TSV"
}

# _reload_cache -- forzar a _ut_tsv_load a releer el TSV tras un seed.
_reload_cache() { _tsv_reload; }

# _seed_clone <name> -- crear un repo git real bajo DST.
_seed_clone() {
    local name="$1"
    local dir="$UNIX_TOOLKIT_TOOLS/$name"
    git init -q -b main "$dir"
    git -C "$dir" config user.email "t@t"
    git -C "$dir" config user.name "t"
    printf 'x\n' > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "init"
    printf '%s\n' "$dir"
}
