# my_working_env

My portable terminal setup: **tmux** config, an **fzf** session switcher with live
preview, and a **git worktree** workflow (`wta`, `wtl`, `wtcd`, `wtrm`, `wtclone`).

Clone onto any machine, run `./install.sh`, and get the same environment.

## Layout

```
my_working_env/
├── install.sh                  # symlinks everything into $HOME (idempotent)
├── tmux/
│   ├── tmux.conf               # → ~/.tmux.conf
│   └── session-preview.sh      # → ~/.tmux/session-preview.sh (fzf preview)
└── shell/
    └── wt.sh                   # → ~/wt.sh (worktree helpers, sourced by .zshrc)
```

## Prerequisites

| Tool | Why | Install (macOS) |
|------|-----|-----------------|
| `tmux` ≥ 3.2 | terminal multiplexer; `display-popup` used by the switcher | `brew install tmux` |
| `fzf`  ≥ 0.35 | fuzzy session picker (`FZF_PREVIEW_LINES` used for the preview) | `brew install fzf` |
| `git`  ≥ 2.20 | worktree workflow | `brew install git` |

Linux: use your package manager (`apt install tmux fzf git`, etc.).

## Install

```sh
git clone git@github.com:nikvakhrameev/my_working_env.git ~/my_working_env
cd ~/my_working_env
./install.sh
```

`install.sh`:

- symlinks `~/.tmux.conf`, `~/.tmux/session-preview.sh`, `~/wt.sh` → this repo
  (any existing real file is backed up once to `<file>.bak`),
- appends `source ~/wt.sh` to `~/.zshrc` (or `~/.bashrc`) if not already there,
- checks that `tmux`, `fzf`, `git` are installed.

Because it uses **symlinks**, editing a config later (`vim ~/.tmux.conf`) edits the
repo copy — commit and push to sync to other machines.

Then reload:

```sh
exec $SHELL                       # pick up wt.sh
tmux source-file ~/.tmux.conf     # or: prefix + r
```

## What you get

### tmux (`~/.tmux.conf`)

- **Prefix is `C-a`** (not `C-b`).
- `prefix + |` / `prefix + -` — split horizontal / vertical, keeping the cwd.
- `prefix + c` — new window in the current path.
- `prefix + h/j/k/l` — move between panes; `prefix + H/J/K/L` — resize.
- `Alt + ←/→` — previous / next window.
- `prefix + r` — reload config.
- Mouse on, vi copy-mode, copy to macOS clipboard (`pbcopy`), Nord-ish status bar
  showing session, window (process or pane title), path + git branch.

### fzf session switcher — `prefix + S`

Opens an fzf popup listing every **other** tmux session. Pick one → `switch-client`.
The right pane previews the highlighted session:

- `path` — the session's current directory,
- `git`  — current branch (if a repo),
- `wins` — its window list,
- a **live snapshot of the active pane**, tailed to the freshest lines and sized
  to the preview height so the latest output sits at the bottom.

Preview logic lives in `tmux/session-preview.sh`. Tunables inside it:
`-S -200` (scrollback depth captured) and the header line count. Popup size is set
on the `bind S display-popup -w 85% -h 80%` line in `tmux.conf`.

### git worktree workflow (`~/wt.sh`)

One bare repo, many worktrees — every branch checked out in its own directory,
side by side, no stash-and-switch.

```
myrepo/            <- container
├── .bare/         <- git data
├── .git           <- "gitdir: ./.bare"
├── main/          <- worktree, branch main
└── feat-x/        <- worktree, branch feat-x
```

| Command | Does |
|---------|------|
| `wtclone <url> [dir]` | clone once into a bare container + default-branch worktree |
| `wta <branch> [base] [--name dir]` | add a worktree (reuse / track / create), auto-`cd` in |
| `wtl` | list worktrees (name + branch) |
| `wtcd [name\|branch]` | jump between worktrees |
| `wtrm <name\|branch> [-f]` | remove a worktree (branch is **kept**) |
| `wthelp` | full built-in guide |

Inside tmux, `wta` spawns and switches to a session per worktree (named
`<container>/<worktree>`), and `wtcd` switches to it if it exists — pairs with the
`prefix + S` switcher above. `wta` also copies untracked `.env` / `.env.local` /
`docker-compose.override.yml` from the default worktree into the new one.

Typical flow:

```sh
wtclone git@github.com:you/repo.git   # once
cd repo
wta feat-x                            # work on a feature (new session + cd)
wtcd main                             # hop to main
wtrm feat-x                           # done — worktree gone, branch stays
```

## Updating

Edit files in place (they're symlinked), then:

```sh
cd ~/my_working_env
git add -A && git commit -m "tweak: ..." && git push
```

On another machine: `git pull` — symlinks already point here, so changes apply on
next shell / tmux reload.
