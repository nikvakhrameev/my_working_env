#!/usr/bin/env bash
# install.sh — link this repo's config into your home directory.
# Idempotent: safe to re-run. Existing real files are backed up to <file>.bak
# once; existing correct symlinks are left alone.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link() {  # link <source-in-repo> <target-in-home>
  local src="$REPO/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ]; then
    [ "$(readlink "$dst")" = "$src" ] && { echo "= $dst (already linked)"; return; }
    rm "$dst"
  elif [ -e "$dst" ]; then
    mv "$dst" "$dst.bak"
    echo "↩ backed up $dst -> $dst.bak"
  fi
  ln -s "$src" "$dst"
  echo "→ $dst -> $src"
}

echo "Repo: $REPO"

# --- symlinks --------------------------------------------------------------
link tmux/tmux.conf           "$HOME/.tmux.conf"
link tmux/session-preview.sh  "$HOME/.tmux/session-preview.sh"
link shell/wt.sh              "$HOME/wt.sh"
link shell/herdr.sh           "$HOME/herdr.sh"
link herdr/config.toml        "$HOME/.config/herdr/config.toml"

# --- wire the shell scripts into the shell rc -------------------------------
# Pick the rc file from the user's LOGIN shell ($SHELL), not the interpreter
# running this script — otherwise `bash install.sh` targets .bashrc for a zsh user.
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc"  ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="$HOME/.zshrc"  ;;   # default to zsh on macOS
esac

add_source() {  # add_source <line> <comment>
  if [ -f "$RC" ] && grep -qF "$1" "$RC"; then
    echo "= $RC already has '$1'"
  else
    printf '\n# %s\n%s\n' "$2" "$1" >> "$RC"
    echo "→ appended '$1' to $RC"
  fi
}
add_source 'source ~/wt.sh'    'bare-repo worktree helpers (my_working_env)'
add_source 'source ~/herdr.sh' 'herdr shell integration (my_working_env)'

# --- dependency check ------------------------------------------------------
echo
missing=0
for dep in tmux fzf git; do
  if command -v "$dep" >/dev/null 2>&1; then
    # tmux reports its version with -V, not --version.
    ver=$("$dep" --version 2>/dev/null || "$dep" -V 2>/dev/null); ver=$(printf '%s' "$ver" | head -1)
    echo "✓ $dep ($ver)"
  else
    echo "✗ $dep MISSING — install it (macOS: brew install $dep)"
    missing=1
  fi
done

echo
echo "Done. Next:"
echo "  • reload shell:  exec \$SHELL"
echo "  • reload tmux:   tmux source-file ~/.tmux.conf   (or prefix + r)"
[ "$missing" -eq 1 ] && echo "  • install the MISSING deps above first"
exit 0
