#!/usr/bin/env bash
# Preview a tmux session for the fzf session switcher.
# Arg $1 = session name. Shows cwd, git branch, window list, live pane snapshot.
s="$1"
[ -z "$s" ] && exit 0

path=$(tmux display-message -p -t "${s}:" '#{pane_current_path}' 2>/dev/null)
printf '\033[1;36mpath\033[0m  %s\n' "$path"

branch=$(cd "$path" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$branch" ] && printf '\033[1;33mgit\033[0m   %s\n' "$branch"

printf '\033[1;35mwins\033[0m  '
tmux list-windows -t "$s" -F '#I:#W' 2>/dev/null | paste -sd ' ' -

printf '\033[2m%s\033[0m\n' "────────────────────────────────"
# Fit capture to preview height so the freshest line lands at the bottom.
# Header above used 4 lines (path, git, wins, divider); fzf exports FZF_PREVIEW_LINES.
avail=${FZF_PREVIEW_LINES:-40}
body=$(( avail - 4 ))
[ "$body" -lt 5 ] && body=5
# Capture last 200 lines incl. scrollback, drop trailing blank lines, show latest that fit.
tmux capture-pane -ep -S -200 -t "${s}:" 2>/dev/null | awk '
  { lines[NR] = $0 }
  END {
    last = 0
    for (i = 1; i <= NR; i++) {
      t = lines[i]
      gsub(/\033\[[0-9;]*m/, "", t)   # strip ANSI
      gsub(/[ \t]/, "", t)            # strip whitespace
      if (t != "") last = i          # remember last non-blank
    }
    for (i = 1; i <= last; i++) print lines[i]
  }' | tail -n "$body"
