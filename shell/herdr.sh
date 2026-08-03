# herdr.sh - shell-side herdr integration
# Install: source ~/herdr.sh from .zshrc/.bashrc
#
# Reports the pane's git branch as herdr pane metadata (token "branch") on
# every prompt, so the agents sidebar can render it via the $branch token
# (see [ui.sidebar.agents] in herdr's config.toml). The token is only set
# when the branch differs from the worktree/repo directory name - with the
# wt.sh layout the directory IS the sanitized branch name, so the sidebar
# stays clean in the common case and $branch appears only when a pane's
# checkout diverges from what its tab name implies.

_herdr_report_branch() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0

  local branch top
  branch=$(git branch --show-current 2>/dev/null)
  top=$(git rev-parse --show-toplevel 2>/dev/null)
  # nothing to show: not a repo, detached HEAD, or branch matches dir name
  # (same sanitization as wt.sh: '/', ':', '.' become '-')
  if [ -z "$branch" ] \
     || [ "$(printf '%s' "$branch" | tr '/:.' '---')" = "$(basename "${top:-/}")" ]; then
    branch=""
  fi

  # skip the socket call when nothing changed since the last report
  [ "$HERDR_PANE_ID:$branch" = "${_HERDR_BRANCH_REPORTED:-}" ] && return 0
  _HERDR_BRANCH_REPORTED="$HERDR_PANE_ID:$branch"

  if [ -n "$branch" ]; then
    (herdr pane report-metadata "$HERDR_PANE_ID" --source shell \
       --token branch="$branch" >/dev/null 2>&1 &)
  else
    (herdr pane report-metadata "$HERDR_PANE_ID" --source shell \
       --clear-token branch >/dev/null 2>&1 &)
  fi
}

if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _herdr_report_branch
elif [ -n "${BASH_VERSION:-}" ]; then
  case ";${PROMPT_COMMAND:-};" in
    *";_herdr_report_branch;"*) ;;
    *) PROMPT_COMMAND="_herdr_report_branch${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi
