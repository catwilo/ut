# Conventions -- unix-toolkit-tools

Standard shape shared by every tool in the ecosystem. Observed, not
aspirational. If a repo deviates, that is a bug in the repo, not a
missing rule here.

## Repo layout (root)

    README.md           usage: install, subcommands, model
    ARCHITECTURE.md     module map, flows, design decisions
    DECISIONS.md        ADR-lite, newest first (only when needed)
    err.md              known failure modes (only when needed)
    install.sh          idempotent symlink installer
    bin/<tool>          entrypoint (no extension)
    lib/ or lib-<tool>/ implementation modules, one concern per file
    tests/              (optional) self-describing test output
    config/             (optional) static config consumed at runtime

ARCHITECTURE.md lives at the repo root, never under docs/. A docs/
directory, when present, holds auxiliary material only.

## Naming

- Binaries have no extension. `bin/wifi`, `bin/nina`, `bin/mkit`.
- Private helpers are prefixed with `_` (`_dispatch_usage`, `_load`).
- Public entrypoints per layer:
  - dispatcher: `cmd_*` (ut) or `_cmd_*` (wifi, nina) -- one style per repo
  - modules: `<domain>_<action>` (`radio_up`, `nm_con_list`, `lan_status`)
- Globals in UPPER_SNAKE (`RADIO_STATE_FILE`, `STATE_DIR`).
- Every module starts with a header comment stating its SINGLE
  responsibility and what it requires from other modules.

## Shell

- bash: `set -Eeuo pipefail` + `IFS=$'\n\t'`.
- POSIX sh (nina): `set -eu`.
- `umask 077` in tools that create sensitive state (wifi-setup).
- ASCII-only in code, comments, patches, file content. Spanish prose
  (Spanish accented text) is produced at runtime through python3 or
  mkit, never embedded raw in a here-doc.
- ANSI colors gated by `[[ -t 1 ]]`; empty strings otherwise. No
  `--color=always` forcing.
- **Never** pipe or redirect that hides output. Forbidden without
  exception: `| head`, `| tail`, `| grep`, `| awk`, `| sed`,
  `2>/dev/null`, `2>&1`, `&>`, `> /dev/null`. A hidden signal is a
  lost diagnosis. Run every command raw; both stdout and stderr must
  reach the user's terminal untouched.
- Every state change is paired with its verification in the same
  block.

## Install

- **Symlink, never copy.** `install.sh` symlinks the entrypoint from
  the repo into PATH. The repo is the source of truth; deleting the
  repo intentionally breaks the install.
- Idempotent: re-running is always safe. Guard on observed state,
  never on a marker file alone.
- Honor `~/.local/bin` (Termux) or `$PREFIX/bin` when set.
- Every repo with an installable binary ships `install.sh`.
- No global Python installs. Dependencies go into `<repo>/.venv/`
  if the repo uses Python.

## Git

- `main` is the only merge target. No other branch is ever a ship
  target.
- Branches: `<type>/<name>` with `type` in
  `feat|fix|chore|refactor|docs`.
- Commits: `<type>(<scope>): <description>`, imperative, English,
  <= 60 chars.
- The pre-commit hook blocks direct commits on `main`/`master` in
  every repo. `--no-verify` is reserved for programmatic commits of
  tool-internal state (registry self-update, first-ever commit on a
  fresh repo) and is documented per case in DECISIONS.md.

## Deploy

Strict order per change:

    1. ut branch <repo> <branch>
    2. edit files (mkit)
    3. verify the change runs (observed, not asserted)
    4. ut ship <repo>              -- rebase, merge to main, push, delete branch
    5. ut distribute --install <repo>  -- pull to every node, run install.sh
    6. miko sync <repo>            -- reconcile tasks, scoped

Pull requests are not used for repos registered in ut. PRs exist only
for repos not in `repos.tsv`. Registered repos publish exclusively
through `ut ship`.

## Tasks

Tasks live in miko (`~/.tasks/<repo>/`), never in the repo. A repo is
fully onboarded once it is registered in `repos.tsv` (ut) AND has a
miko bucket. The two registrations are independent.

## Editing and destructive operations

- **Files**: edit atomically with `mkit write` / `mkit replace` /
  `mkit patch`. Never `cat >`, `sed -i`, `tee`, or `>>` appends.
- **Deletion**: use `maid trash`. Plain `rm` only on explicit
  in-the-moment request.
- **Git**: use `ut branch`, `ut ship`, `ut add`, `ut tag`. Never
  bare `git checkout -b`, `git push origin`, or hand-edited
  `repos.tsv`.
- **Remote**: `nssh` / `nscp`, never raw `ssh` / `scp`.

Rule: if a registered mechanism already performs an action, that
mechanism is the ONLY permitted way to perform it. "Faster to type
manually" is not an exception.

## Docs

- `README.md`: what the tool is, how to install, subcommands with
  one-line descriptions, model (how the pieces fit), known state.
- `ARCHITECTURE.md`: module map with one-line responsibilities, entry
  flows, invariants, non-obvious decisions. Updated on every session
  that touches the described subsystem.
- `DECISIONS.md`: ADR-lite, newest first. One entry per non-obvious
  choice. Format: date, context, decision, consequence.
- `err.md`: known failure modes. Present only when the repo has
  non-trivial failure modes worth writing down.

## Entry points

- One dispatcher per repo, no business logic in it. It parses,
  sources the correct module, calls a function, prints the result.
- Help lives in `lib/help.sh` (or equivalent) as `help_<sub>` per
  subcommand. The dispatcher routes `-h`/`--help` before touching
  business modules, so `wifi <sub> -h` works for every subcommand.
- If a repo has a `--help` per subcommand, the top-level
  `--help`/`help` prints the index and each subcommand's `-h`
  prints only its own section.
