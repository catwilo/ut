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
| `repos.tsv` | Registry. TSV: name, tags, description, state, owner, path. Source of truth. Column 6 (path) is optional; empty means standard location. |
| `lib-ut/*.sh` | Command implementations, one concern per file. |
| `ut-collect.sh` | POSIX collector. Emits per-repo git state for `ut machines diff`. |
| `install.sh` | Symlinks `ut` into PATH; populates git hooks in all repos. |
| `git-templates/hooks/pre-commit` | Blocks direct commits on main/master. |
| `templates/` | `biome.json` + `client-web-standard.md` for new projects. |

## lib-ut/ modules

| File | Responsibility |
|---|---|
| `changelog.sh` | `log_change()`. Appends distribute/install events. |
| `query.sh` | Repo listing/filtering by tag or name (`repos_for_target()`). **`repo_dir()`** is the single source of truth for resolving a repo's on-disk path; **`cmd_path()`** exposes it as `ut path <repo>` for scripts and remote distribute. |
| `status.sh` | `cmd_status()`. Git state: fetch, snapshots local+remote, diff. |
| `sync.sh` | `cmd_sync()`. Pulls all repos, self-updates ut. |
| `registry.sh` | `cmd_add/untrack/unclone/tag/pause/resume/archive/info`. Edits repos.tsv. |
| `admin.sh` | `cmd_new/create/delete/rename`. Destructive GitHub operations. Also `_tsv_publish()`. |
| `nodes.sh` | `cmd_machines/distribute`. Multi-node via nina/nssh. |
| `identity.sh` | `is_local_ip()`, `node_id()`, `_own_devices_ip()` (reads the current node IP from `ts-devices.db`). Node identity helpers. |

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
5. `ut distribute [--install] <repo>` -- pull to all nodes; --install runs install.sh local + remote.
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
- **All repo path resolution goes through `repo_dir`.** No file under
  `lib-ut/` may hardcode `$DST/$repo` (except `query.sh` itself, where
  the fallback lives). The repo lives either at `$DST/<repo>` (col 6
  empty) or at the exact path stored in col 6. Commands that touch the
  filesystem -- `info`, `list local`, `install`, `branch`, `ship`,
  `distribute`, `unclone`, `rename` -- all call `repo_dir`. New commands
  must do the same; a grep for `$DST/` outside `query.sh` should return
  nothing.
- **Remote distribute resolves the path dynamically.** `_remote_repo_path`
  asks each remote to print `ut path <repo>` and checks that the result
  actually contains a `.git` before treating it as cloned. If it does
  not, the remote falls back to `ut install <repo>`, which honors the
  same column 6. Custom paths therefore work across nodes without any
  hardcoded knowledge on the origin side.

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

`ut distribute <repo>` updates the repo on every reachable REMOTE node.
The local node is always excluded from the remote worker list
(`is_local_ip` compares each candidate against the node's own canonical
IP, read from `ts-devices.db`).

Flow:

1. Resolve node aliases via `_all_nodes_aliases` (`lib-ut/nodes.sh`).
2. Filter out the local node (`is_local_ip`).
3. Run `install.sh` locally when `--install` is set.
4. Launch one worker per remote alias, in parallel, in the display mode
   chosen by the caller (see below).
5. Wait for every worker to finish (`_wait_for_workers`, with
   `UT_DISTRIBUTE_MAX_WAIT` seconds as the ceiling; default 3600).
6. Read the per-worker exit code from `$sig_dir/<alias>.rc` and print
   `ok`/`failed` per node.

`ut distribute --install <repo>` = local `install.sh` + remote workers run
`<path>/install.sh`.

### Display modes

Three modes. The default is chosen from context; a flag forces one.

| Mode    | Trigger                                                        |
|---------|----------------------------------------------------------------|
| `panes` | interactive TTY with no capture wrapper (or `--panes`)         |
| `mix`   | captured stdout (`CLIPSO_ACTIVE` set) with no tmux (or `--mix`) |
| `quiet` | explicit `--quiet` only (never automatic)                      |

`panes` creates a new tmux window `ut-workers` in the caller's session
(or a new session `ut-view-<repo>` when there is no surrounding tmux),
splits one pane per alias with `even-horizontal`, and attaches the caller.

`mix` runs each worker in a background subshell whose stdout/stderr is
piped through a per-line prefixer, then through `tee` to both the caller
stdout and `~/.local/share/ut/distribute/<repo>-<alias>.log`. The prefixer
tags each line `[<alias>]`, coloured when stdout is a TTY. Lines from
different workers arrive in the order produced (true parallel).

`quiet` runs the workers in detached tmux sessions; their output goes only
to the per-alias log file. The caller sees only the final summary. This is
the only mode that hides per-worker output; it is opt-in.

### Signals and wait

Every worker writes its exit code to `$sig_dir/<alias>.rc`, where
`$sig_dir` is a per-process `mktemp -d` created by `cmd_distribute` and
removed by an `EXIT` trap. A fresh directory per run means a stale `.rc`
from a previous invocation can never be mistaken for success.
`_wait_for_workers` polls the `rc` files (not tmux wait-for, which does
not queue signals) with a configurable ceiling.

## Hook population

`install.sh` sets `git config --global init.templateDir` to
`git-templates/`, then iterates every existing clone in
`~/unix-toolkit-tools/*` and copies the hook into `.git/hooks/` if
missing. Repos cloned before the install get the hook on next run.

## err.md

See `err.md` for known failure modes: registry drift, node
unreachable, hook not installed, `_tsv_publish` push failure.
