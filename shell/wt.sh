# wt.sh — wrapper for bare-repo worktree workflow
# Install: source ~/wt.sh from .zshrc/.bashrc
#
#   wtclone <url> [dir]                 clone repo into a bare container
#   wta <branch> [base] [--name dir]   create a worktree for a branch
#   wtl                                list worktrees: name + branch
#   wtcd [--branch=b|--name=n|arg]     cd into a worktree
#   wtrm <name|branch> [-f]            remove a worktree
#   wthelp                             print this usage guide

# --- helpers ---------------------------------------------------------------

_wt_root() {  # container root (directory holding .bare)
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { echo "✗ not inside a git repository" >&2; return 1; }
  dirname "$common"
}

_wt_default_base() {  # origin/<default-branch>, e.g. origin/main
  local ref
  ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
  if [ -z "$ref" ]; then
    git remote set-head origin --auto >/dev/null 2>&1
    ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
  fi
  [ -n "$ref" ] && echo "${ref#refs/remotes/}" || echo "origin/main"
}

_wt_sanitize() {  # directory/tmux-session name from a branch name
  printf '%s' "$1" | tr '/:.' '---'
}

_wt_session() {  # tmux session name: <container>/<worktree>
  # tmux forbids '.'/':' in session names but allows '/', so keep '/' as the
  # separator and only sanitize those two chars within each component.
  printf '%s/%s' "$(printf '%s' "$1" | tr ':.' '--')" \
                 "$(printf '%s' "$2" | tr ':.' '--')"
}

# --- 1) clone --------------------------------------------------------------

wtclone() {
  [ -n "$1" ] || { echo "usage: wtclone <url> [dir]"; return 1; }
  local url=$1 name=${2:-$(basename "$url" .git)}

  mkdir -p "$name" && cd "$name" || return 1
  git clone --bare "$url" .bare || return 1
  echo "gitdir: ./.bare" > .git

  # a bare clone doesn't create origin/* refs by default — fix that
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git fetch origin --quiet
  git remote set-head origin --auto >/dev/null 2>&1

  local def; def=$(_wt_default_base)          # origin/main
  local defbr=${def#origin/}                  # main
  git worktree add "$defbr" "$defbr" >/dev/null || return 1
  echo "🌳 $name ready: worktree '$defbr' → branch $defbr"
}

# --- 2) create worktree -----------------------------------------------------

wta() {
  local branch="" base="" name=""
  while [ $# -gt 0 ]; do
    case $1 in
      --name) name=$2; shift 2 ;;
      --name=*) name=${1#--name=}; shift ;;
      -*) echo "✗ unknown flag: $1"; return 1 ;;
      *)  if   [ -z "$branch" ]; then branch=$1
          elif [ -z "$base"   ]; then base=$1
          else echo "✗ extra argument: $1"; return 1; fi
          shift ;;
    esac
  done
  [ -n "$branch" ] || { echo "usage: wta <branch> [base] [--name dir]"; return 1; }

  local root; root=$(_wt_root) || return 1
  [ -n "$name" ] || name=$(_wt_sanitize "$branch")
  local dir="$root/$name"
  [ -e "$dir" ] && { echo "✗ directory $dir already exists"; return 1; }

  git fetch origin --quiet

  # branch already taken by another worktree? (exact branch match)
  local used; used=$(_wt_find "" "$branch")
  if [ -n "$used" ]; then
    echo "✗ branch '$branch' is already checked out in worktree '$(basename "$used")' ($used)"
    return 1
  fi

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    # local branch exists → pull from origin if possible
    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      if git merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/origin/$branch"; then
        git update-ref "refs/heads/$branch" "refs/remotes/origin/$branch"
        echo "↻ $branch updated to origin/$branch"
      elif ! git merge-base --is-ancestor "refs/remotes/origin/$branch" "refs/heads/$branch"; then
        echo "⚠ local '$branch' has diverged from origin/$branch (both local and remote commits exist)."
        printf "  Create worktree from the LOCAL version of the branch? [y/N] "
        local ans; read -r ans
        [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "cancelled"; return 1; }
      fi  # local is ahead of origin — silently take the local one
    fi
    git worktree add "$dir" "$branch" || return 1

  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    # no local branch, but it exists on origin → tracking branch
    git worktree add "$dir" -b "$branch" --track "refs/remotes/origin/$branch" || return 1

  else
    # branch doesn't exist anywhere → create it from base
    local from
    if [ -n "$base" ]; then
      if git show-ref --verify --quiet "refs/remotes/origin/$base"; then
        from="origin/$base"
      elif git rev-parse --verify --quiet "$base" >/dev/null; then
        from=$base
      else
        echo "✗ base '$base' not found (neither locally nor on origin)"; return 1
      fi
    else
      from=$(_wt_default_base)
    fi
    git worktree add "$dir" -b "$branch" "$from" || return 1
    echo "＋ created branch $branch from $from"
  fi

  # local configs from the default worktree that aren't tracked in git
  local defbr; defbr=$(_wt_default_base); defbr=${defbr#origin/}
  local f
  for f in .env .env.local docker-compose.override.yml; do
    [ -f "$root/$defbr/$f" ] && [ ! -f "$dir/$f" ] && cp "$root/$defbr/$f" "$dir/"
  done

  echo "🌳 $dir"
  cd "$dir" || return 1

  # if we're in tmux — spin up a session for the worktree right away.
  # session name is <container>/<worktree> (see _wt_session).
  if [ -n "${TMUX:-}" ]; then
    local sess; sess=$(_wt_session "$(basename "$root")" "$name")
    tmux new-session -d -s "$sess" -c "$dir" 2>/dev/null
    tmux switch-client -t "=$sess"
  fi
}

# --- 3) list ----------------------------------------------------------------

wtl() {
  git worktree list --porcelain | awk '
    /^worktree /  { path=$2; n=split(path, a, "/"); name=a[n] }
    /^bare$/      { name="" }
    /^branch /    { sub("refs/heads/", "", $2)
                    if (name != "") printf "%-28s %s\n", name, $2 }
    /^detached$/  { if (name != "") printf "%-28s %s\n", name, "(detached HEAD)" }
  '
}

# --- find worktree ----------------------------------------------------------

_wt_find() {  # _wt_find <name|""> <branch|""> → worktree path
  local name=$1 branch=$2
  git worktree list --porcelain | awk -v n="$name" -v b="$branch" '
    /^worktree /{p=$2; k=split(p, a, "/"); dir=a[k]}
    /^bare$/    {dir=""}
    /^branch /  {sub("refs/heads/", "", $2)
                 if (dir != "" && ((n != "" && dir == n) || (b != "" && $2 == b))) print p}
    /^detached$/{if (dir != "" && n != "" && dir == n) print p}
  ' | head -1
}

# --- 5) navigate ------------------------------------------------------------

wtcd() {
  local name="" branch="" arg=""
  while [ $# -gt 0 ]; do
    case $1 in
      --branch=*) branch=${1#--branch=}; shift ;;
      --name=*)   name=${1#--name=};     shift ;;
      --branch)   branch=$2; shift 2 ;;
      --name)     name=$2;   shift 2 ;;
      -*) echo "✗ unknown flag: $1"; return 1 ;;
      *)  arg=$1; shift ;;
    esac
  done
  [ -n "$name$branch$arg" ] || { echo "usage: wtcd [--branch=b] [--name=n] [name|branch]"; return 1; }

  # NB: not named 'path' — in zsh 'path' is tied to $PATH, so a local would
  # wipe PATH inside this function and break git/awk in subshells.
  local wt
  if [ -n "$name" ] || [ -n "$branch" ]; then
    wt=$(_wt_find "$name" "$branch")
  else
    wt=$(_wt_find "$arg" "$arg")   # positional: name OR branch
  fi
  [ -n "$wt" ] || { echo "✗ worktree not found:"; wtl; return 1; }

  cd "$wt" || return 1

  # if we're in tmux and a session for this worktree exists — switch to it.
  # session name is built the same way wta creates it: <container>/<worktree>.
  if [ -n "${TMUX:-}" ]; then
    local sess; sess=$(_wt_session "$(basename "$(dirname "$wt")")" "$(basename "$wt")")
    tmux has-session -t "=$sess" 2>/dev/null && tmux switch-client -t "=$sess"
  fi
}

# --- 4) remove --------------------------------------------------------------

wtrm() {
  local target="" force=""
  while [ $# -gt 0 ]; do
    case $1 in
      -f|--force) force=1; shift ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || { echo "usage: wtrm <name|branch> [-f]"; return 1; }

  # find path: by directory name or by branch.
  # NB: not named 'path' — in zsh 'path' is tied to $PATH, so a local would
  # wipe PATH inside this function and break git/awk in subshells.
  local wt
  wt=$(_wt_find "$target" "$target")
  [ -n "$wt" ] || { echo "✗ worktree '$target' not found:"; wtl; return 1; }

  # dirty-check → y/n
  if [ -z "$force" ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then
    printf "⚠ %s has uncommitted changes. Remove permanently? [y/N] " "$wt"
    local ans; read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "cancelled"; return 1; }
    force=1
  fi

  # don't saw off the branch we're sitting on
  case "$PWD/" in "$wt"/*) cd "$(_wt_root)" ;; esac

  # remove only the worktree; the branch (and tmux session) stay untouched.
  # git worktree remove releases the branch checkout itself — no detach needed.
  git worktree remove ${force:+--force} "$wt" || return 1
  echo "✓ removed worktree $wt (branch kept)"
}

# --- 6) help ----------------------------------------------------------------

wthelp() {
  cat <<'EOF'
wt.sh — bare-repo worktree workflow

One repo, many worktrees. Each branch = its own directory, all checked out
at once, side by side. No stash-and-switch. Layout:

  myrepo/          <- container
  ├── .bare/       <- the actual git data
  ├── .git         <- file: "gitdir: ./.bare"
  ├── main/        <- worktree, branch main
  └── feat-x/      <- worktree, branch feat-x

COMMANDS

  wtclone <url> [dir]
      Clone once: sets up the container + default-branch worktree.
        wtclone git@github.com:you/repo.git       # -> ./repo/ with main/
        wtclone git@github.com:you/repo.git app    # custom container name

  wta <branch> [base] [--name dir]
      Add a worktree (run from inside the container). Auto-cd's into it.
        wta feat-login             # new branch off default base, or reuse existing
        wta hotfix main            # new branch off main
        wta feat/foo --name foo    # dir 'foo' instead of 'feat-foo'
      Existing local branch -> reuse; only on origin -> tracking branch;
      nowhere -> create from base. Copies .env / .env.local /
      docker-compose.override.yml from the default worktree.

  wtl
      List worktrees (name + branch).

  wtcd [name|branch]
      Jump between worktrees.
        wtcd feat-login            # by dir name OR branch
        wtcd --branch=feat-login   # force branch match
        wtcd --name=foo            # force dir-name match

  wtrm <name|branch> [-f]
      Remove a worktree. Branch is KEPT (never deleted). Prompts if dirty;
      -f skips the prompt.
        wtrm feat-login
        wtrm feat-login -f

  wthelp
      Print this guide.

tmux: inside tmux, wta spawns + switches to a session per worktree (named
<container>/<worktree>), and wtcd switches to it if it exists. Outside
tmux, ignored.

TYPICAL FLOW
  wtclone git@github.com:you/repo.git   # once
  cd repo
  wta feat-x                            # work on a feature
  # ...code, commit, push...
  wtcd main                             # hop to main
  wtrm feat-x                           # done, drop worktree (branch stays)
EOF
}
