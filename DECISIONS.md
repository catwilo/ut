# Decisions -- ut

ADR-lite. Each entry: date, context, decision, consequence.
Newest first. Add an entry whenever a non-obvious choice is made.

---

## 2026-09-13 -- Forbid stderr suppression, allow --no-verify for registry self-commit

**Context.** `_tsv_publish` (admin.sh) silently failed for a long time:
it ran `git commit` on `main` without `--no-verify`, the global
pre-commit hook blocked it, `2>/dev/null` hid the error, and the push
had nothing to send. `repos.tsv` stayed staged-but-uncommitted on every
node. The bug survived for days because the error was invisible.

**Decision.**

1. `_tsv_publish` uses `git commit --no-verify`. This is a programmatic
   commit of a single registry file during an administrative `ut`
   command -- the same legitimate case as the initial README commit in
   `cmd_new`. The hook policy targets development commits, not ut's own
   registry self-update.
2. `ai.md` now forbids `2>/dev/null` (and any pipe/redirection that
   discards stderr) as a critical rule for all code in the ecosystem.

**Consequence.** Registry updates now propagate correctly. Future silent
failures are visible by construction -- if a command's stderr is
suppressed, the code is wrong, not the environment.

---

## 2026-09-09 -- Ship merges to main only

**Context.** Some repos (VocesDelCampo, others) at one point had a
`production` branch that mirrored `main`. It was a leftover from an
older flow (deploy-from-branch on Netlify). With `ksite` and Netlify CLI
uploading a prebuilt `dist/`, branch identity is irrelevant to deploy.

**Decision.** `ut ship <repo>` always rebases onto `origin/main`, merges
into `main`, pushes `main`, and deletes the source branch. No other
branch is a valid ship target.

**Consequence.** Repos with vestigial branches (`production`,
`fix/*` never merged) become inconsistent with the ship flow. The right
move is to delete the vestigial branch (as done for VocesDelCampo on
2026-09-13) rather than teach `ut` about alternate targets.

---

## 2026-09-08 -- Split ut rm/remove into untrack/unclone

**Context.** `ut rm <repo>` was ambiguous: did it remove the registry
entry, the local clone, or both? Users guessed wrong.

**Decision.** Two explicit commands:

- `ut untrack <repo>` -- registry only. Local clone and GitHub intact.
- `ut unclone <repo>` -- local clone only (moved to trash via maid).
  Registry and GitHub intact.

`ut delete <repo>` remains the one destructive command that does all
three (GitHub + registry + local). It is explicit and irreversible.

**Consequence.** Three scopes, three commands, no ambiguity. The old
`ut rm`/`ut remove` are aliases for one cycle, then removed.

---

## 2026-09-07 -- `repos.tsv` as source of truth, not JSON

**Context.** The registry could be JSON, YAML, or TSV. JSON is
structured, YAML is human-friendly, TSV is line-based.

**Decision.** TSV, four columns, no quoting rules beyond "no tabs in
fields". Read with `awk -F'\t'`, edit with `python3`.

**Consequence.** Registry is greppable, diffable, and every tool in the
ecosystem can parse it with POSIX tools. Editing by hand is discouraged
(use `ut add`/`ut tag`/`ut untrack`), but never impossible -- a broken
registry is recoverable by opening the file in any editor.

---

## 2026-09-07 -- Hook blocks direct commits on main/master globally

**Context.** Working on `main` directly causes merge conflicts when
multiple nodes or developers sync. A branch-first flow keeps history
clean and reviewable.

**Decision.** `install.sh` sets `git config --global init.templateDir`
to `ut/git-templates/`, which contains a `pre-commit` hook that exits 1
if the current branch is `main` or `master`. The hook populates into
every existing clone on `install.sh` run and into every new repo on
`git init`.

**Consequence.** Direct commits on main are blocked by default. Legit
bypasses exist (`--no-verify`) and are documented per case (see the
2026-09-13 entry). Repos cloned with `git clone` (not `git init`) do
not get the hook automatically -- `install.sh` fixes them.

---

## 2026-09-06 -- ut does not manage tasks

**Context.** Early versions of `ut` had a `ctx` file per repo, and `ut
sync` regenerated context from miko buckets. That mixed two concerns:
git state (ut) and task state (miko). The coupling caused staleness.

**Decision.** `ut` owns git state only. `miko` owns tasks. The only
shared key is the repo name. `ut` never reads or writes a miko bucket.

**Consequence.** `ut sync` no longer touches tasks. Task reconciliation
is `miko sync -r <repo>` (scoped) or `miko sync` (explicit global).
Each tool can evolve without breaking the other.

---

## 2026-08-31 -- Symlink install, not copy

**Context.** `install.sh` could copy `ut` into `~/.local/bin/ut` or
symlink it. Copy is more robust to repo deletion; symlink is more
robust to updates.

**Decision.** Symlink. The repo is the source of truth; if it is
deleted, the install is intentionally broken. Updates are
`git pull` without reinstalling.

**Consequence.** Every other tool in the ecosystem follows the same
pattern (`ksite`, `miko`, `nina`, ...). Installers are idempotent and
re-running them is safe.
