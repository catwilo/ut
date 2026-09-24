# Architecture -- ut

Repo manager for unix-toolkit-tools. Single entrypoint `ut` sources
`lib-ut/*.sh` modules and dispatches to `cmd_*` functions.

## Scope

`ut` manages git repositories. It does NOT manage tasks (`miko`) and
does NOT manage websites (`ksite`). A repo registered in `ut` may or may
not have a miko bucket; a miko project may or may not have a repo. The
two systems are independent and share only the name.

## Files

| File | Responsibility |
|---|---|
| `ut` | Entrypoint. Parse command, source libs, dispatch. ~145 lines. |
| `repos.tsv` | Registry. TSV: name, tags, description, state. Source of truth. |
| `lib-ut/*.sh` | Command implementations, one concern per file. |
| `ut-collect.sh` | POSIX collector. Emits per-repo git state for `ut machines diff`. |
| `install.sh` | Symlinks `ut` into PATH; populates git hooks in all repos. |
| `git-templates/hooks/pre-commit` | Blocks direct commits on main/master. |
| `templates/` | `biome.json` + `client-web-standard.md` for new projects. |

## lib-ut/ modules

| File | Responsibility |
|---|---|
| `changelog.sh` | `log_change()`. Appends deploy/distribute events. |
| `query.sh` | Repo listing/filtering by tag or name. `repos_for_target()`. |
| `status.sh` | `cmd_status()`. Git state: fetch, snapshots local+remote, diff. |
| `sync.sh` | `cmd_sync()`. Pulls all repos, self-updates ut. |
| `registry.sh` | `cmd_add/untrack/unclone/tag/pause/resume/archive/info`. Edits repos.tsv. |
| `admin.sh` | `cmd_new/create/delete/rename`. Destructive GitHub operations. Also `_tsv_publish()`. |
| `nodes.sh` | `cmd_machines/distribute/deploy`. Multi-node via nina/nssh. |
| `identity.sh` | `is_local_ip()`. Node identity helpers. |

## Entrypoint flow

1. Resolve `$TSV` (from `$UT_HOME` or fallback to repo-local `repos.tsv`).
2. Source every module in `lib-ut/` (order matters: `changelog` first
   because others call `log_change()`).
3. Dispatch `$CMD` to the matching `cmd_*` function.

## Standard flow

1. `ut branch <repo> <branch>` -- pull+rebase, create branch (autostash).
2. Edit files.
3. Verify (local check, visual if UI).
4. `ut ship <repo>` -- rebase+merge+push to main, delete branch.
5. `ut deploy <repo>` -- run install.sh locally, distribute to nodes.
6. `miko sync <repo>` -- reconcile task state, scoped.

## Invariants

- **`main` is always the merge target.** `ut ship` rebases onto
  `origin/main`, merges there, pushes, deletes the source branch. No
  other branch is ever a merge target for ship.
- **The pre-commit hook blocks direct commits on main/master.** Only
  `--no-verify` with a documented reason (ut's own registry self-update,
  first-ever commit on a fresh repo) bypasses it. See DECISIONS.
- **`repos.tsv` changes propagate to nodes.** `ut add`, `ut delete`,
  `ut rename` call `_tsv_publish` which commits and pushes repos.tsv so
  all nodes converge.
- **No task or website knowledge in ut.** No files under `ut/` should
  reference miko buckets, Netlify tokens, or Cloudflare tunnels.
- **Destructive ops are explicit.** `ut delete` (GitHub), `ut unclone`
  (local, recoverable via maid), `ut untrack` (registry only) are three
  distinct scopes -- never confuse them.
- **Symlink install, never copy.** `install.sh` symlinks `ut` from the
  repo into PATH. Deleting the repo breaks the install by design (the
  repo is the source of truth).

## Status report

`ut status [repo]` runs per repo:

1. Pull the ut repo itself (refresh registry).
2. `git fetch origin` in the target repo.
3. Snapshot local: `status --short`, `branch -v --no-merged main`,
   `log --oneline -5`.
4. Snapshot each remote node via `nssh` (same commands).
5. Diff local vs each remote. Report clean / diff / unreachable.

Snapshots live in `$TMPDIR/ut-status/<repo>/`, cleaned after report.

## Multi-node distribution

`ut distribute <repo>` copies the repo to every reachable node:

1. Resolve node aliases via `nina status`.
2. For each remote alias: `nssh <alias> "git -C ~/unix-toolkit-tools/<repo> pull --rebase origin main"`.
3. If `--no-install` is NOT set and `install.sh` exists in the repo,
   run it locally first, then on each remote.

`ut deploy <repo>` = local `install.sh` + `ut distribute <repo>`.

## Hook population

`install.sh` sets `git config --global init.templateDir` to
`git-templates/`, then iterates every existing clone in
`~/unix-toolkit-tools/*` and copies the hook into `.git/hooks/` if
missing. Repos cloned before the install get the hook on next run.

## err.md

See `err.md` for known failure modes: registry drift, node
unreachable, hook not installed, `_tsv_publish` push failure.
