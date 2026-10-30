#!/bin/bash
folder=$(basename "$PWD")
hash=$(printf '%s' "$PWD" | cksum 2>/dev/null | awk '{print substr($1, 1, 6)}')
[ -n "$hash" ] || hash=$(printf '%s' "$PWD" | od -An -tx1 2>/dev/null | tr -d ' \n' | cut -c1-6)
[ -n "$hash" ] || hash="root"
session="vscode-${folder}-${hash}"
if ! command -v tmux >/dev/null 2>&1; then
  exec /bin/bash -l
fi
# One pane per visible terminal. Clients attached to one tmux session share
# that session's current window, so concurrent tabs attaching the same
# session are mirrors: each pays for a full xterm.js in the browser
# re-parsing the same stream (with its own preallocated scrollback buffer),
# a per-client encode in the server, and a re-wrap repaint for every client
# each time any of them activates. So a terminal reuses one of this folder's
# sessions only while nothing is looking at it (that is the closed-tab
# rejoin: a tab that closed left its session behind unattached), preferring
# the oldest; a terminal opened next to live ones takes the next free
# numbered session instead. Two terminals opening in the same instant can
# still land on one session -- exactly the old mirror behavior, and rarer
# than a keystroke.

# Control calls only. A tmux server caught in its own teardown race stops
# answering commands, and a tab whose probe never returns is a terminal that
# never opens, so every question below gets a timeout and the caller falls back
# to creating (or to a plain shell). The attach itself stays unbounded: it is
# the tab's lifetime, not a round trip.
timeout_bin=$(command -v timeout 2>/dev/null)
tmux_q() {
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" -k 2 5 tmux -u "$@"
  else
    tmux -u "$@"
  fi
}
# One snapshot decides everything below. Three separate queries would let a tab
# that attaches between them answer "nothing is attached" and "here is an
# attached one" from different worlds, and a scan that times out answers with
# no lines at all, which would look exactly like a folder with no sessions and
# quietly leave an idle session orphaned while a new one is born. So: one read,
# retried once, and its exit status tells a failed scan from an empty one.
scan=""
scan_ok=0
attempt=0
while [ "${attempt}" -lt 2 ]; do
  attempt=$((attempt + 1))
  if scan=$(tmux_q list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null); then
    scan_ok=1
    break
  fi
done
folders() {
  printf '%s\n' "${scan}" |
    awk -v p="$session" '($2 == p || index($2, p "-") == 1) {print $1, $2}'
}
existing=""
if [ "${scan_ok}" = "1" ]; then
  if [ -z "$(folders | awk '$1 != 0')" ]; then
    existing=$(folders | head -n 1 | cut -d' ' -f2)
  else
    existing=$(folders | awk '$1 == 0' | head -n 1 | cut -d' ' -f2)
  fi
fi
# Every target below carries tmux's "=" exact-match prefix: a bare target-name
# is tried as an exact match, then as the start of a session name (tmux(1)), so
# once "foo" is gone "foo-2" answers for it -- which here would hand this tab a
# mirror of a live pane, the exact thing the numbering exists to prevent.
if [ -n "$existing" ] && tmux -u attach-session -t "=$existing"; then
  # Reaching here means the attach ended on its own without this shell being
  # signalled: closing the tab takes this process down with its client, so
  # nothing below runs in that case. Two ways are left for the client to exit
  # by itself. The pane's own shell ended (the operator typed exit) and tmux
  # took the session with it, or tmux 3.4 lost the session under this client.
  # Only the second is worth absorbing: raise a fresh session when the server
  # is still up and has lost just this one, and end quietly otherwise.
  # has-session cannot make that call alone, since it fails for a missing
  # session and for a missing server alike -- so much so that upstream declined
  # to add a check-server command over it (tmux#2523). The server gets its own
  # probe.
  # Under the default exit-empty a server that loses its last session goes with
  # it, so "server up" already means "some other session is live" -- exactly the
  # situation where a new one is the right answer. Re-raising against a dead
  # server would boot one for a tab nobody is looking at, which is also how a
  # closed tab leaks a server.
  tmux_q show-options -g status >/dev/null 2>&1 || exit 0
  tmux_q has-session -t "=$existing" 2>/dev/null && exit 0
fi
n=1
name="$session"
while tmux_q has-session -t "=$name" 2>/dev/null; do
  n=$((n + 1))
  name="$session-$n"
done
# Create detached, then attach in a second call. A session created by the
# foreground new-session of the very tab that brought the server up died along
# with that tab in 9 of 20 close-and-reopen rounds; with the split, 60 rounds in
# this workspace lost none. The rejoin above is the insurance for when tmux does
# take a session down under a reopening tab, because losing the tab is the worse
# failure, and nothing upstream documents why it happens: the option that would
# tear a session down when its last client leaves, destroy-unattached, is off by
# default, and tmux gives a session no grace period after that either --
# tmux#5821 is an open request for one. A second terminal that scans in the gap
# before this attach may claim
# the fresh session -- the same rare mirror as the same-instant open.
if ! tmux_q new-session -d -s "$name" -c "$PWD" </dev/null >/dev/null 2>&1 &&
  ! tmux_q has-session -t "=$name" 2>/dev/null; then
  # Lost the create race and the winner already closed, or the server went
  # away under this tab. Fall back to a plain shell: the obvious new-session
  # -A here is a foreground create, and a tab left in it while its terminal is
  # going away raises the server again and stays attached to it forever.
  exec /bin/bash -l
fi
exec tmux -u attach-session -t "=$name"
