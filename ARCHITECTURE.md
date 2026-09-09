# Architecture — ut

Repo manager for unix-toolkit-tools. Single entrypoint `ut` sources lib-ut/ modules.

## Files

| File | Responsibility |
|---|---|
| `ut` | Entrypoint. Parses command, dispatches to cmd_* in modules. |
| `repos.tsv` | Registry. Tab-separated: name, tags, desc, state. Source of truth. |
| `ut-collect.sh` | POSIX collector. Emits per-repo git state for `ut machines diff`. |
| `install.sh` | Symlinks `ut` into PATH. Populates git hooks in all repos. |
| `git-templates/hooks/pre-commit` | Blocks direct commits on main/master. |
| `templates/` | biome.json + client-web-standard.md for new projects. |

## lib-ut/ modules

| File | Responsibility |
|---|---|
| `query.sh` | repo listing/filtering by tag or name. `repos_for_target()`. |
| `status.sh` | `cmd_status()`. Git state: fetch, snapshots local+remote, diff. |
| `sync.sh` | `cmd_sync()`. Pulls all repos, self-updates ut. |
| `registry.sh` | `cmd_add/rm/tag/pause/resume/archive/info`. Edits repos.tsv. |
| `admin.sh` | `cmd_clone/install`. Clones repos, SSH only. |
| `nodes.sh` | `cmd_machines/distribute/deploy`. Multi-node via nina/nssh. |
| `changelog.sh` | `log_change()`. Appends deploy/distribute events. |
| `identity.sh` | `is_local_ip()`. Node identity helpers (shared with noemap). |

## Flow

1. `ut branch <repo> <branch>` — pull+rebase, create branch (autostash).
2. Edit files.
3. `ut ship <repo>` — rebase+merge+push, delete branch.
4. `ut deploy <repo>` — install.sh local + distribute to nodes.
5. `miko sync` — task reconciliation after deploy.

## Status report

`ut status [repo]` runs per repo:

1. Pull ut repo (refresh registry).
2. Fetch origin in target repo.
3. Snapshot local: status --short + branch --no-merged + log -5.
4. Snapshot each remote node via nssh (same commands).
5. Diff local vs each remote. Report clean/diff/unreachable.

Snapshots stored in `$TMPDIR/ut-status/<repo>/`, removed after report.
