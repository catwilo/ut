# ut

Repo manager for the unix-toolkit-tools ecosystem (Termux, Debian, macOS).

`ut` does ONE thing: manage git repositories registered in `repos.tsv`.
It does NOT manage tasks (that is `miko`) and does NOT manage websites
(that is `ksite`). Each tool owns its domain; they share only the repo
name as a key.

Source of truth for the repo registry: `repos.tsv`.
Source of truth for git state: `git` itself. `ut` never duplicates it.

## Installation

    git clone git@github.com:catwilo/ut.git ~/unix-toolkit-tools/ut
    sh ~/unix-toolkit-tools/ut/install.sh

`install.sh` symlinks `ut` into PATH, installs the git pre-commit hook
template globally (`init.templateDir`), and populates the hook in every
already-cloned repo. Idempotent.

## Usage

    ut <command> [args]

Run `ut` without args for the full command list with descriptions.

### Read (all repos)

    ut list                    list all registered repos
    ut list <tag>              filter by tag
    ut list local              only cloned repos
    ut list cloud              only repos that exist on GitHub
    ut list orphans            local clones not in repos.tsv
    ut status                  git state per repo (dirty/ahead/behind/branch)
    ut status --remote         same + reachability check to each node
    ut diff                    uncommitted changes across all repos
    ut fetch                   fetch all remotes

### Git (all repos)

    ut sync [tag]              update ut itself, sync repos (scoped recommended)
    ut push                    push repos ahead of their remote
    ut run '<cmd>' [tag]       run a shell command in each repo

Note: `ut sync` without tag touches EVERY repo. In daily work prefer
scoped sync via `miko sync -r <repo>` for tasks, and `ut ship <repo>`
for code. Global sync is for explicit manual use.

### Git (one repo)

    ut clone [tag]             clone all (or tagged) registered repos
    ut install <repo>          clone one registered repo not yet local
    ut branch <repo> <branch>  pull+rebase, create branch (autostash)
    ut ship <repo>             rebase+merge+push, delete branch

### Registry (edits repos.tsv)

    ut add <repo> <tags> '<desc>'    register a new repo
    ut untrack <repo>                remove from repos.tsv only
    ut unclone <repo>                move local clone to trash only
    ut tag <repo> +<tag>|-<tag>      add/remove a tag
    ut pause <repo>                  mark as paused
    ut resume <repo>                 mark as active
    ut archive <repo>                mark as archived
    ut info <repo>                   show metadata + git state

### GitHub (destructive)

    ut new <repo> <tags> '<desc>'      create + clone + distribute to nodes
    ut create <repo> <tags> '<desc>'   create on GitHub only (alias of new)
    ut delete <repo>                   delete on GitHub + untrack + trash
    ut rename <old> <new>              rename on GitHub + propagate to nodes

### Nodes (multi-machine)

    ut machines                ping all nodes
    ut machines diff           per-repo git state across nodes
    ut distribute <repo>       copy repo to all reachable nodes
    ut deploy <repo>           install.sh locally + distribute
    ut deploy all              deploy every repo tagged 'core'
    ut distribute --no-install <repo>   distribute without running install.sh

## Standard fix flow

    1. ut branch <repo> <type>/<name>
    2. edit files
    3. verify locally
    4. ut ship <repo>              rebase+merge+push to main, delete branch
    5. [optional] ut deploy <repo> run install.sh + distribute to nodes
    6. miko sync -r <repo>         reconcile task state (scoped)

Steps 5 and 6 are asked explicitly; never run them autonomously.

## repos.tsv

Tab-separated: `name / tags / description / state`. Edit via
`ut add`, `ut tag`, `ut untrack`, `ut pause|resume|archive`. Never
hand-edit unless recovering from an error.

## Tag vocabulary

    tool    CLI tool, daily use
    cli     command-line interface
    cfg     dotfiles / configuration
    util    small utility, no installer
    infra   infrastructure / provisioning
    net     networking
    sec     security / audit
    svc     background service
    core    foundational dependency
    client  client project (external)
    web     web frontend
    app     application (gui, mobile)
    audio   audio synthesis / processing
    docs    documentation
    arc     archived / reference only
    game    game or emulation
    fw      firmware / kernel driver
    bot     automation bot
    project multi-purpose project
    personal personal projects

## Integration

- `miko` owns tasks. `ut` does not know about tasks.
- `ksite` owns websites. `ut` does not know about Netlify/Cloudflare.
- `nina` provides node aliases. `ut machines` uses them via nssh.
- `gh` is required for GitHub operations (create, delete, rename).

## Documentation

- `ARCHITECTURE.md` -- module layout, flow, invariants.
- `DECISIONS.md` -- why things are the way they are (ADR-lite).
- `ai.md` -- LLM session spec (not for humans; ignore unless extending
  the AI contract).
- `PORTFOLIO.md` -- project index by tag.
- `err.md` -- known failure modes and recovery.
