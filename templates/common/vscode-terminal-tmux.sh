#!/bin/bash
folder=$(basename "$PWD")
hash=$(printf '%s' "$PWD" | cksum 2>/dev/null | awk '{print substr($1, 1, 6)}')
[ -n "$hash" ] || hash=$(printf '%s' "$PWD" | od -An -tx1 2>/dev/null | tr -d ' \n' | cut -c1-6)
[ -n "$hash" ] || hash="root"
session="vscode-${folder}-${hash}"
if ! command -v tmux >/dev/null 2>&1; then
  exec /bin/bash -l
fi
exec tmux -u new-session -A -s "$session" -c "$PWD"
