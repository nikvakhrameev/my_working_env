# herdr.sh - shell-side herdr integration
# Install: source ~/herdr.sh from .zshrc/.bashrc
#
# Shows each pane's git branch in the agents sidebar (config token $branch,
# see [ui.sidebar.agents] in herdr's config.toml). The branch is reported as
# pane metadata and only set when it differs from the pane's tab label - so
# it appears exactly when the tab name is misleading about what's checked out.
#
# Two reporters keep it fresh:
#   - a precmd/PROMPT_COMMAND hook: instant update whenever a prompt returns
#   - a per-pane background poller: picks up branch switches made by a
#     running agent (no prompt returns while an agent works), using the
#     pane's foreground cwd as tracked by herdr

: "${HERDR_BRANCH_POLL_SECS:=5}"

_herdr_report_branch() {  # [dir] - report/clear this pane's branch token.
  # dir defaults to the pane's foreground cwd as seen by herdr.
  local pane dir label branch
  pane=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null) || return 0
  dir=${1:-$(printf '%s' "$pane" \
             | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty')}
  label=$(herdr tab get "$(printf '%s' "$pane" | jq -r '.result.pane.tab_id // empty')" \
            2>/dev/null | jq -r '.result.tab.label // empty')
  branch=""
  [ -d "$dir" ] && branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  # hide when there is no branch or it matches the tab label (also allowing
  # for wt.sh dir-name sanitization: '/', ':', '.' become '-')
  if [ -z "$branch" ] || [ "$branch" = "$label" ] \
     || [ "$(printf '%s' "$branch" | tr '/:.' '---')" = "$label" ]; then
    herdr pane report-metadata "$HERDR_PANE_ID" --source shell \
      --clear-token branch >/dev/null 2>&1
  else
    herdr pane report-metadata "$HERDR_PANE_ID" --source shell \
      --token branch="$branch" >/dev/null 2>&1
  fi
}

_herdr_branch_precmd() { ( _herdr_report_branch "$PWD" & ) }

_herdr_branch_poller() {  # ($1: parent shell pid) - stops when the shell exits
  while kill -0 "$1" 2>/dev/null; do
    _herdr_report_branch
    sleep "$HERDR_BRANCH_POLL_SECS"
  done
}

if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] \
   && command -v herdr >/dev/null 2>&1; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠ herdr.sh: branch reporting needs jq (brew install jq)" >&2
  else
    if [ -n "${ZSH_VERSION:-}" ]; then
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd _herdr_branch_precmd
    elif [ -n "${BASH_VERSION:-}" ]; then
      case ";${PROMPT_COMMAND:-};" in
        *";_herdr_branch_precmd;"*) ;;
        *) PROMPT_COMMAND="_herdr_branch_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
      esac
    fi
    # one poller per pane; exported so nested shells don't start a second one
    if [ -z "${_HERDR_BRANCH_POLLER:-}" ]; then
      export _HERDR_BRANCH_POLLER=1
      ( _herdr_branch_poller $$ >/dev/null 2>&1 & )
    fi
  fi
fi
