# wt.sh — wrapper for bare-repo worktree workflow
# Install: source ~/wt.sh from .zshrc/.bashrc
#
#   wtclone <url> [dir]                 clone repo into a bare container
#   wtconvert [--name dir]             convert a normal repo into a container
#   wta <branch> [base] [--name dir]   create a worktree for a branch
#   wtshare add <file>... | sync       share gitignored files across worktrees
#   wtl [-a|dir]                       list worktrees: name + branch
#   wtcd [container] [name|branch]     cd into a worktree (any registered repo)
#   wtrm <name|branch> [-f]            remove a worktree
#   wtreg [name]                       register current container in the registry
#   wthelp                             print this usage guide

# machine-global container registry (name<TAB>path) lives next to the real
# script file so every shell shares it; override with WT_REGISTRY.
if [ -z "${WT_REGISTRY:-}" ]; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    WT_REGISTRY="$(dirname "$(readlink -f "${(%):-%x}")")/.wt-registry"
  elif [ -n "${BASH_VERSION:-}" ]; then
    WT_REGISTRY="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.wt-registry"
  else
    WT_REGISTRY="$HOME/.wt-registry"
  fi
fi

# --- helpers ---------------------------------------------------------------

_wt_root() {  # container root (directory holding .bare); self-registers it
  local common root
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { echo "✗ not inside a git repository" >&2; return 1; }
  root=$(dirname "$common")
  _wt_reg_add "$(basename "$root")" "$root"
  printf '%s\n' "$root"
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

# --- container registry ------------------------------------------------------
# Machine-global map of known containers (name<TAB>path in $WT_REGISTRY) so
# wtcd/wtl reach any repo from anywhere: `wtcd payx PAYX-1190`. Containers
# self-register on wtclone and whenever wt commands run inside them; only
# containers are stored — worktrees are always read live from git, so the
# registry can't go stale on branch churn. Same basename twice → last used wins.

_wt_reg_add() {  # (name, path) → upsert registry entry
  local name=$1 root=$2 tmp
  [ -n "$name" ] && [ -n "$root" ] || return 0
  grep -qxF "$name	$root" "$WT_REGISTRY" 2>/dev/null && return 0
  tmp="$WT_REGISTRY.tmp.$$"
  { [ -f "$WT_REGISTRY" ] && awk -F'\t' -v n="$name" '$1 != n' "$WT_REGISTRY"
    printf '%s\t%s\n' "$name" "$root"; } > "$tmp" && mv "$tmp" "$WT_REGISTRY"
}

_wt_reg_del() {  # (name) → drop registry entry
  local tmp="$WT_REGISTRY.tmp.$$"
  [ -f "$WT_REGISTRY" ] || return 0
  awk -F'\t' -v n="$1" '$1 != n' "$WT_REGISTRY" > "$tmp" && mv "$tmp" "$WT_REGISTRY"
}

_wt_reg_lookup() {  # (name) → container path; prunes entries whose path is gone
  local root
  [ -f "$WT_REGISTRY" ] || return 1
  root=$(awk -F'\t' -v n="$1" '$1 == n {print $2; exit}' "$WT_REGISTRY")
  [ -n "$root" ] || return 1
  [ -e "$root/.git" ] || {
    _wt_reg_del "$1"
    echo "⚠ dropped stale registry entry: $1 → $root" >&2
    return 1
  }
  printf '%s\n' "$root"
}

_wt_reg_ls() {  # print registered containers
  [ -f "$WT_REGISTRY" ] && awk -F'\t' '{printf "  %-20s %s\n", $1, $2}' "$WT_REGISTRY"
}

# --- shared gitignored-file store ------------------------------------------
# One container-level store, <container>/.shared, holds the REAL gitignored
# files; every worktree gets relative symlinks back to it, so edits persist
# across branches (like a single-folder repo). .shared/.manifest lists the
# shared paths (relative to a worktree root). Managed via `wtshare`.

_wt_git_exclude() {  # anchor /rel in info/exclude so a symlinked ignored *dir*
  local rel=$1 common ex                      # (e.g. node_modules) isn't seen as
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0               # untracked — trailing-slash .gitignore
  ex="$common/info/exclude"                   # patterns don't match symlinks.
  mkdir -p "$(dirname "$ex")"
  grep -qxF -- "/$rel" "$ex" 2>/dev/null || printf '/%s\n' "$rel" >> "$ex"
}

_wt_link_shared() {  # (store, wt, rel) → relative symlink wt/rel → store/rel
  local store=$1 wt=$2 rel=$3
  rel=${rel#/}; rel=${rel%/}
  [ -n "$rel" ] || return 0
  [ -e "$store/$rel" ] || { echo "  ⚠ not in store, skipping: $rel" >&2; return 0; }
  if [ -L "$wt/$rel" ]; then
    rm "$wt/$rel"
  elif [ -e "$wt/$rel" ]; then
    echo "  ⚠ skip $rel (real file exists in worktree)" >&2; return 0
  fi
  # one '../' per path segment in rel gets us from the link's dir to the
  # worktree root; '.shared' is a sibling of every worktree.
  local n; n=$(printf '%s' "$rel" | awk -F/ '{print NF}')
  local prefix="" i=0
  while [ "$i" -lt "$n" ]; do prefix="../$prefix"; i=$((i + 1)); done
  mkdir -p "$wt/$(dirname "$rel")"
  ln -s "${prefix}.shared/$rel" "$wt/$rel"
  _wt_git_exclude "$rel"
}

_wt_link_all() {  # (store, wt) → symlink every manifest entry into wt
  local store=$1 wt=$2 mf="$1/.manifest" rel
  [ -f "$mf" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] && _wt_link_shared "$store" "$wt" "$rel"
  done < "$mf"
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

  mkdir -p .shared                            # shared gitignored-file store
  _wt_reg_add "$(basename "$PWD")" "$PWD"
  echo "🌳 $name ready: worktree '$defbr' → branch $defbr"
  echo "   .shared/ store created — register files with: wtshare add <file>"
}

# --- 1b) convert ------------------------------------------------------------

wtconvert() {  # convert a normal (non-bare) repo into a container, in place
  local name=""
  while [ $# -gt 0 ]; do
    case $1 in
      --name)   name=$2; shift 2 ;;
      --name=*) name=${1#--name=}; shift ;;
      -h|--help) echo "usage: wtconvert [--name dir]   (run from inside the repo)"; return 0 ;;
      *) echo "✗ unknown argument: $1 (usage: wtconvert [--name dir])"; return 1 ;;
    esac
  done

  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "✗ not inside a git repository (with a work tree)"; return 1; }
  root=$(cd "$root" && pwd -P)
  [ -d "$root/.git" ] \
    || { echo "✗ $root/.git is not a directory — already a worktree or container?"; return 1; }
  git -C "$root" rev-parse --verify --quiet HEAD >/dev/null \
    || { echo "✗ repository has no commits yet"; return 1; }

  local branch
  branch=$(git -C "$root" symbolic-ref --quiet --short HEAD) \
    || { echo "✗ detached HEAD — check out a branch first"; return 1; }
  [ -n "$name" ] || name=$(_wt_sanitize "$branch")
  [ -e "$root/$name" ] \
    && { echo "✗ $root/$name already exists — pick a dir: wtconvert --name <dir>"; return 1; }
  [ -e "$root/.bare" ] && { echo "✗ $root/.bare already exists"; return 1; }

  if [ -f "$root/.gitmodules" ]; then
    printf "⚠ submodules detected; their .git links will break and need re-init after converting. Continue? [y/N] "
    local ans; read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "cancelled"; return 1; }
  fi

  local rel=${PWD#"$root"}  # land in the same spot inside the new worktree

  # the repo's .git dir becomes the bare store, same shape wtclone produces
  mv "$root/.git" "$root/.bare" || return 1
  printf 'gitdir: ./.bare\n' > "$root/.git"
  git -C "$root" config core.bare true
  git -C "$root" config --unset core.worktree 2>/dev/null

  # register the worktree without checking anything out, then move the old
  # working tree (incl. modified/untracked/ignored files) into it wholesale
  git -C "$root" worktree add --no-checkout "$root/$name" "$branch" >/dev/null \
    || { echo "✗ worktree registration failed — repo left bare at $root/.bare"; return 1; }
  local f
  while IFS= read -r f; do
    case "$(basename "$f")" in .git|.bare|"$name") continue ;; esac
    mv "$f" "$root/$name/" || return 1
  done < <(find "$root" -mindepth 1 -maxdepth 1)

  # reuse the old index so staged state (and stat cache) survives
  if [ -f "$root/.bare/index" ]; then
    mv "$root/.bare/index" "$root/.bare/worktrees/$name/index"
  else
    git -C "$root/$name" reset --quiet
  fi

  # origin plumbing, same as wtclone; tolerate being offline
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    git -C "$root" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$root" fetch origin --quiet 2>/dev/null
    git -C "$root" remote set-head origin --auto >/dev/null 2>&1
  else
    echo "⚠ no 'origin' remote — new branches will need an explicit base: wta <branch> <base>"
  fi

  mkdir -p "$root/.shared"
  _wt_reg_add "$(basename "$root")" "$root"
  echo "🌳 $(basename "$root") converted: worktree '$name' → branch $branch"
  echo "   .shared/ store created — register files with: wtshare add <file>"
  cd "$root/$name$rel" 2>/dev/null || cd "$root/$name" || return 1
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

  # link shared gitignored files (.env, secrets, node_modules, ...) from the
  # container store into the new worktree. Populate the store with `wtshare`.
  local store="$root/.shared"
  [ -d "$store" ] && _wt_link_all "$store" "$dir"

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

# --- 2b) shared gitignored files -------------------------------------------

wtshare() {
  local sub=${1:-}
  [ $# -gt 0 ] && shift
  case "$sub" in
    add)  _wtshare_add "$@" ;;
    sync) _wtshare_sync ;;
    ""|-h|--help|help)
      echo "usage: wtshare add <file>...   move file(s) into .shared, symlink back"
      echo "       wtshare sync            recreate this worktree's symlinks from .shared"
      [ "$sub" = "" ] && return 1 || return 0 ;;
    *)  echo "✗ unknown subcommand: $sub (try: wtshare add|sync)"; return 1 ;;
  esac
}

_wtshare_add() {
  [ -n "${1:-}" ] || { echo "usage: wtshare add <file>..."; return 1; }
  local root top store mf
  root=$(_wt_root) || return 1
  top=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "✗ not inside a worktree"; return 1; }
  top=$(cd "$top" && pwd -P)
  store="$root/.shared"; mkdir -p "$store"; mf="$store/.manifest"

  local f dir base abs rel
  for f in "$@"; do
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then echo "✗ no such file: $f"; continue; fi
    dir=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || { echo "✗ bad path: $f"; continue; }
    base=$(basename "$f"); abs="$dir/$base"
    case "$abs/" in
      "$top"/*) ;;
      *) echo "✗ $f is not inside the current worktree ($top)"; continue ;;
    esac
    rel=${abs#"$top"/}
    if [ -L "$abs" ]; then echo "= $rel already a symlink, skipping"; continue; fi
    if [ -e "$store/$rel" ]; then echo "✗ $rel already in store"; continue; fi
    mkdir -p "$store/$(dirname "$rel")"
    mv "$abs" "$store/$rel" || { echo "✗ move failed: $rel"; continue; }
    grep -qxF -- "$rel" "$mf" 2>/dev/null || printf '%s\n' "$rel" >> "$mf"
    _wt_link_shared "$store" "$top" "$rel"
    echo "→ shared $rel  (moved to .shared, symlinked here)"
  done
}

_wtshare_sync() {
  local root top store
  root=$(_wt_root) || return 1
  top=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "✗ not inside a worktree"; return 1; }
  top=$(cd "$top" && pwd -P)
  store="$root/.shared"
  [ -d "$store" ] || { echo "✗ no shared store at $store"; return 1; }
  _wt_link_all "$store" "$top"
  echo "✓ synced shared files into $(basename "$top")"
}

# --- 3) list ----------------------------------------------------------------

wtl() {  # [dir] — list that repo's worktrees; -a|--all — every registered container
  case "${1:-}" in
    -a|--all)
      [ -f "$WT_REGISTRY" ] || { echo "(no registered containers yet)"; return 0; }
      local name root
      while IFS='	' read -r name root; do
        printf '%s → %s\n' "$name" "$root"
        wtl "$root" | sed 's/^/  /'
      done < "$WT_REGISTRY"
      ;;
    *)
      git -C "${1:-.}" worktree list --porcelain 2>/dev/null | awk '
        /^worktree /  { path=$2; n=split(path, a, "/"); name=a[n] }
        /^bare$/      { name="" }
        /^branch /    { sub("refs/heads/", "", $2)
                        if (name != "") printf "%-28s %s\n", name, $2 }
        /^detached$/  { if (name != "") printf "%-28s %s\n", name, "(detached HEAD)" }
      '
      ;;
  esac
}

# --- find worktree ----------------------------------------------------------

_wt_find() {  # _wt_find <name|""> <branch|""> [container-dir] → worktree path
  local name=$1 branch=$2 dir=${3:-.}
  git -C "$dir" worktree list --porcelain 2>/dev/null | awk -v n="$name" -v b="$branch" '
    /^worktree /{p=$2; k=split(p, a, "/"); dir=a[k]}
    /^bare$/    {dir=""}
    /^branch /  {sub("refs/heads/", "", $2)
                 if (dir != "" && ((n != "" && dir == n) || (b != "" && $2 == b))) print p}
    /^detached$/{if (dir != "" && n != "" && dir == n) print p}
  ' | head -1
}

# --- 5) navigate ------------------------------------------------------------

wtcd() {
  local name="" branch="" arg="" repo=""
  while [ $# -gt 0 ]; do
    case $1 in
      --branch=*) branch=${1#--branch=}; shift ;;
      --name=*)   name=${1#--name=};     shift ;;
      --branch)   branch=$2; shift 2 ;;
      --name)     name=$2;   shift 2 ;;
      -*) echo "✗ unknown flag: $1"; return 1 ;;
      *)  if   [ -z "$arg"  ]; then arg=$1
          elif [ -z "$repo" ]; then repo=$arg; arg=$1
          else echo "✗ extra argument: $1"; return 1; fi
          shift ;;
    esac
  done
  [ -n "$name$branch$arg" ] || { echo "usage: wtcd [container] [--branch=b] [--name=n] [name|branch]"; return 1; }

  # two positionals → first is a registered container: search its worktrees
  # instead of the current repo's, so this works from anywhere on the machine.
  local root=""
  if [ -n "$repo" ]; then
    root=$(_wt_reg_lookup "$repo") \
      || { echo "✗ unknown container: $repo — registered:"; _wt_reg_ls; return 1; }
  fi

  # NB: not named 'path' — in zsh 'path' is tied to $PATH, so a local would
  # wipe PATH inside this function and break git/awk in subshells.
  local wt
  if [ -n "$name" ] || [ -n "$branch" ]; then
    wt=$(_wt_find "$name" "$branch" "$root")
  else
    wt=$(_wt_find "$arg" "$arg" "$root")   # positional: name OR branch
  fi

  # lone argument with no local match → maybe a registered container:
  # jump to its default-branch worktree (or the container root itself).
  if [ -z "$wt" ] && [ -z "$repo" ] && [ -n "$arg" ]; then
    root=$(_wt_reg_lookup "$arg" 2>/dev/null) && {
      local defbr
      defbr=$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
      defbr=${defbr#refs/remotes/origin/}
      [ -n "$defbr" ] && wt=$(_wt_find "$defbr" "$defbr" "$root")
      [ -n "$wt" ] || wt=$root
    }
  fi

  [ -n "$wt" ] || { echo "✗ worktree not found:"; wtl "$root"; return 1; }

  cd "$wt" || return 1

  # if we're in tmux — switch to the worktree's session, creating it first
  # if missing. Session name matches what wta creates: <container>/<worktree>.
  if [ -n "${TMUX:-}" ]; then
    local sess; sess=$(_wt_session "$(basename "$(dirname "$wt")")" "$(basename "$wt")")
    tmux has-session -t "=$sess" 2>/dev/null || tmux new-session -d -s "$sess" -c "$wt"
    tmux switch-client -t "=$sess"
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

# --- 7) register -------------------------------------------------------------

wtreg() {  # [name] — register the current container in $WT_REGISTRY
  local root name
  root=$(_wt_root) || return 1
  name=${1:-$(basename "$root")}
  _wt_reg_add "$name" "$root"
  echo "✓ registered: $name → $root"
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
  ├── .shared/     <- shared gitignored files (see wtshare)
  ├── main/        <- worktree, branch main
  └── feat-x/      <- worktree, branch feat-x

COMMANDS

  wtclone <url> [dir]
      Clone once: sets up the container + default-branch worktree.
        wtclone git@github.com:you/repo.git       # -> ./repo/ with main/
        wtclone git@github.com:you/repo.git app    # custom container name

  wtconvert [--name dir]
      Convert an existing NON-BARE repo into a container, in place (run
      from inside the repo). .git becomes .bare; the whole working tree —
      including uncommitted, untracked and ignored files — moves into a
      worktree named after the current branch. Auto-cd's into it.
        cd ~/code/app && wtconvert     # -> app/ container with <branch>/
        wtconvert --name main          # custom worktree dir name

  wta <branch> [base] [--name dir]
      Add a worktree (run from inside the container). Auto-cd's into it.
        wta feat-login             # new branch off default base, or reuse existing
        wta hotfix main            # new branch off main
        wta feat/foo --name foo    # dir 'foo' instead of 'feat-foo'
      Existing local branch -> reuse; only on origin -> tracking branch;
      nowhere -> create from base. Symlinks shared gitignored files from
      the container's .shared store (see wtshare) into the new worktree.

  wtshare add <file>...
      Move gitignored file(s) into the container's .shared store and
      replace them with symlinks. Shared across every worktree, so edits
      persist regardless of branch. Recorded in .shared/.manifest.
        wtshare add .env
        wtshare add .env node_modules   # whole dirs too
  wtshare sync
      (Re)create this worktree's symlinks from .shared — use after adding
      files elsewhere, or if a worktree's links went missing.

  wtl [-a|dir]
      List worktrees (name + branch). -a: every registered container.

  wtcd [container] [name|branch]
      Jump between worktrees — of this repo, or any registered one.
        wtcd feat-login            # by dir name OR branch (current repo)
        wtcd --branch=feat-login   # force branch match
        wtcd --name=foo            # force dir-name match
        wtcd payx PAYX-1190        # from anywhere: repo 'payx', wt 'PAYX-1190'
        wtcd payx                  # repo 'payx', default-branch worktree

  wtrm <name|branch> [-f]
      Remove a worktree. Branch is KEPT (never deleted). Prompts if dirty;
      -f skips the prompt.
        wtrm feat-login
        wtrm feat-login -f

  wtreg [name]
      Register the current container in the registry (run from the
      container folder or any of its worktrees). Default name = folder
      name; pass a name to register an alias.
        wtreg                      # register as folder name
        wtreg px                   # alias: wtcd px PAYX-1190

  wthelp
      Print this guide.

tmux: inside tmux, wta and wtcd both switch to the worktree's session
(named <container>/<worktree>), creating it if missing. Outside tmux,
ignored.

registry: containers self-register (on wtclone and whenever wt commands
run inside them) into $WT_REGISTRY — a name<TAB>path file next to the
real wt.sh — so wtcd/wtl -a work machine-wide. Only containers are
stored; worktrees are read live from git. Same dir name twice -> last
used wins. Override location: export WT_REGISTRY=... before sourcing.

TYPICAL FLOW
  wtclone git@github.com:you/repo.git   # once
  cd repo
  wta feat-x                            # work on a feature
  # ...code, commit, push...
  wtcd main                             # hop to main
  wtrm feat-x                           # done, drop worktree (branch stays)
EOF
}
