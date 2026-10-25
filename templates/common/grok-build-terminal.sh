#!/bin/bash
export PATH="$HOME/.grok/bin:$PATH"
# The project root, not $PWD: the editor opens on the clone's root, and a
# terminal opened in a subfolder must still rejoin that same session and agent
# run rather than starting a second one beside it.
repo_root="$PWD"
if command -v git >/dev/null 2>&1; then
  top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && repo_root="$top"
fi
folder=$(basename "$repo_root")
hash=$(printf '%s' "$repo_root" | cksum 2>/dev/null | awk '{print substr($1, 1, 6)}')
[ -n "$hash" ] || hash=$(printf '%s' "$repo_root" | od -An -tx1 2>/dev/null | tr -d ' \n' | cut -c1-6)
[ -n "$hash" ] || hash="root"
session="grok-build-${folder}-${hash}"
if command -v grok >/dev/null 2>&1; then
  exec tmux new-session -A -s "$session" -c "$PWD" -- grok --cwd "$repo_root"
fi
# Grok CLI missing (offline first boot): still resume the session as a shell.
exec tmux new-session -A -s "$session" -c "$PWD"
