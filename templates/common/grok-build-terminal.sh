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
# No tmux, no multiplexer: this profile still has to open a terminal. The
# attach helper does the same thing for the same reason -- a profile that
# execs a binary which is not there leaves the tab with nothing in it.
if ! command -v tmux >/dev/null 2>&1; then
  exec /bin/bash -l
fi

# Control calls only, each with a timeout, for the reason the attach helper
# spells out: a server caught in its own teardown race stops answering, and a
# tab whose probe never returns is a terminal that never opens. The attach
# itself stays unbounded -- it is the tab's lifetime, not a round trip.
timeout_bin=$(command -v timeout 2>/dev/null)
tmux_q() {
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" -k 2 5 tmux -u "$@"
  else
    tmux -u "$@"
  fi
}

# One agent run per repository is the point of this profile, so a second tab
# here is a second pair of eyes on the same pane rather than a new pane. That
# makes the stale-viewer count the whole cost: code-server's pty host keeps the
# pty open after the browser side goes away, so the client stays attached and
# stops draining. Measured on this workspace's live server, 8 clients were
# attached to one grok pane and 7 of them received 0 bytes across a 4 s window
# of continuous output while the 2 tabs really on screen each received all
# 12858 -- the quiet ones had reported no input for 30 minutes to 36 hours.
# They are invisible in the browser and each one is still a client the server
# renders for. Detach them on the way in. Scoped to this repository's own
# session, and a client whose activity tmux never filled in is left alone; the
# grace is the one variable, 6 hours clearing a lunch and a meeting while
# staying under every stale client the measurement found. Set
# EVO_TMUX_STALE_AFTER (seconds) to move it.
now=$(date +%s 2>/dev/null || true)
case "${now}" in '' | *[!0-9]*) now=0 ;; esac
stale_grace=${EVO_TMUX_STALE_AFTER:-21600}
case "${stale_grace}" in '' | *[!0-9]*) stale_grace=21600 ;; esac
if [ "${now}" -gt 0 ]; then
  # Target by tty, not pid: this tmux (3.4) answers detach-client -t for a
  # client's tty path and refuses a pid with "can't find client", and it has no
  # kill-client at all. The tty is fixed-width and holds no spaces so it can sit
  # in a field; the session name goes last and is recovered by offset, because a
  # repository directory may hold spaces and a name read as a field would be
  # only its first word, which makes the sweep match nothing and say nothing.
  # Requiring a /dev/ tty also keeps a control client (tmux -C, no tty) out of
  # reach.
  client_rows=$(tmux_q list-clients -F '#{client_activity} #{client_tty} #{session_name}' 2>/dev/null)
  if [ -n "${client_rows}" ]; then
    printf '%s\n' "${client_rows}" |
      awk -v p="$session" -v now="$now" -v grace="$stale_grace" '
        { name = substr($0, length($1) + length($2) + 3) }
        (name == p || index(name, p "-") == 1) &&
        $1 ~ /^[0-9]+$/ && $1 > 0 && $2 ~ /^\/dev\// &&
        (now - $1) > grace { print $2 }
      ' |
      while read -r stale_tty; do
        [ -n "${stale_tty}" ] || continue
        tmux_q detach-client -t "${stale_tty}" >/dev/null 2>&1
      done
  fi
fi

# The agent command, if the CLI is there. Offline on a first boot it is not,
# and the session still opens as a plain shell. tmux takes new-session's
# trailing shell-command as one string and hands it to /bin/sh, so the root is
# quoted here rather than passed as loose argv words: passed loose, tmux joins
# them back with spaces and a repository under a path with a space in it
# arrives at grok as two arguments.
if command -v grok >/dev/null 2>&1; then
  q_root=${repo_root//\'/\'\\\'\'}
  set -- -- "grok --cwd '${q_root}'"
else
  set --
fi

# Create detached, then attach in a second call -- the shape the attach helper
# settled on after 9 of 20 close-and-reopen rounds lost the session of the tab
# that had created it in the foreground, and none of 60 rounds with the split.
# It matters more here than it does there: this pane carries a running agent,
# so the tab that happens to bring the server up is the one that would take the
# whole agent run down with it. Every target carries tmux's "=" exact-match
# prefix, because a bare name is also answered by any session that starts with
# it -- see the same rule in the attach helper and in coder-sessions.sh.
created=0
if tmux_q new-session -d -s "$session" -c "$PWD" "$@" >/dev/null 2>&1; then
  created=1
fi
if [ "${created}" != "1" ]; then
  # Either the session already exists, which is the rejoin this profile wants,
  # or the create failed. Only has-session tells those apart, and only the
  # second one still has an answer below it.
  if ! tmux_q has-session -t "=$session" 2>/dev/null; then
    exec /bin/bash -l
  fi
fi
# A tab that cannot attach still owes the operator a terminal. The pane can go
# before this client reaches it -- an agent that exits straight away (a bad
# token, a model the transport will not serve) takes its pane and its session
# with it -- so one bounded re-try covers a pane still coming up and a plain
# shell covers everything else. Handing back a dead tab is the worse failure.
if tmux -u attach-session -t "=$session"; then
  exit 0
fi
tmux_q new-session -d -s "$session" -c "$PWD" "$@" >/dev/null 2>&1
tmux -u attach-session -t "=$session" || true
exec /bin/bash -l
