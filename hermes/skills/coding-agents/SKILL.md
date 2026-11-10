---
name: coding-agents
description: See, answer, tail, and launch the coding agents running inside Coder workspaces on the evo-t1 stack.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [evo-t1, coder, tmux, coding-agent, grok-build]
---

# coding-agents

Use when the operator asks what their coding agents are doing, asks to start or
stop one, asks you to answer a question one is waiting on, or asks for the state
of a repository they left an agent working on.

This is the door that matters from a phone: the operator has one screen and no
terminal, and the agent they launched hours ago is the thing they actually care
about.

## The one command

`scripts/coder-sessions.sh` is the whole interface. It is bash, docker, and tmux
only, so run it from this container against the mounted checkout — the image has
no bazelisk and no `jq`, and neither is needed:

```sh
CS="${STACK_HOST_PATH:-/opt/stack}/scripts/coder-sessions.sh"
bash "$CS" list
bash "$CS" show <workspace>
bash "$CS" tail <workspace> <session> 40
```

On a host shell the same thing is `bazelisk run //scripts:coder-sessions -- list`.

Global options go **before** the subcommand: `--json`, `--container NAME`,
`--timeout SECS`, `--dry-run`. Mutating verbs are `send`, `launch`, and `stop`;
everything else reads.

## What "the agent" is here

A coding agent is a detached tmux session inside a running workspace container,
named `grok-build-<folder>-<hash>` by `templates/common/grok-build-terminal.sh`.
The CLI finds workspaces by the `coder.workspace_id` label the templates stamp and
skips each workspace's `*-dind-sidecar`, and it enumerates tmux sockets per uid so
the operator's own sessions show up — that enumeration is why a plain
`docker exec <c> tmux ls` reports "no sessions" and is never the answer.

`show` classifies each session, and the words are load-bearing. They come from
`state_word` in the script, which reads the pane's foreground command, whether a
client is attached, and seconds since the pane last produced output:

| state | meaning | say |
|---|---|---|
| `running` | a foreground process has produced output recently | it is working; show the tail |
| `quiet` | an agent is loaded and has printed nothing for 30s | it finished or it is waiting on you; tail before you conclude either way |
| `waiting` | a client is attached and the foreground process is a plain shell | hands are already on that pane; do not type into it |
| `idle-shell` | a plain shell, nobody attached, used moments ago | nothing running there |
| `detached-shell` | a plain shell kept alive with nobody attached | it survived; a fine place to launch |
| `unknown` | the pane's activity could not be read | tail it; do not guess a state |

`quiet` is the one an operator means when they say "it's stuck": an agent parked on
an approval keeps its process in the foreground, so it reads `quiet` with a
question as its last line. Never report "the agent is done" from a state word
alone. Read the pane: `tail` the session and quote the last lines.

## Answering an agent that is stuck

This is the phone use case, so do it in one pass:

```sh
bash "$CS" show <workspace>
bash "$CS" tail <workspace> <session> 40     # read what it is asking
bash "$CS" send <workspace> <session> "yes"  # types it and presses Enter
```

`send` types literally (`send-keys -l`), so text with spaces, quotes, and flags
arrives as written. Use `--no-enter` when the operator wants the line staged at the
prompt but wants to press Enter themselves — that is the right answer for anything
irreversible.

## Starting an agent

```sh
bash "$CS" launch --dir /home/coder/<repo> <workspace>          # the shipped profile
bash "$CS" launch --dir /home/coder/<repo> <workspace> -- pytest -q
```

With no command it runs `grok --cwd DIR`, which is what the workspace's own terminal
profile runs, so a session this starts is one the operator can then open in the
editor and keep. `--name` overrides the derived session name; leave it alone unless
the operator named one.

Propose the directory and the command, get the yes, then run it. `--dry-run` prints
the exact `docker exec` without starting anything — use it when you are unsure the
target is right.

To end one, name it:

```sh
bash "$CS" stop <workspace> <session>
```

## "Wake me when it's done"

`watch` is the blocking half, and the reason a phone is enough:

```sh
bash "$CS" watch <workspace> <session> 1800   # up to 30 minutes
```

It returns 0 the moment the session stops working - `quiet`, `idle-shell`,
`detached-shell`, `waiting`, or gone - and 4 with the session still `running` when
the budget runs out. A session name that never existed is an error, so a typo cannot
read as "finished". `--json` prints one object with `state` and `waited`.

Then push the result if the operator has a channel:

```sh
hermes send --to "ntfy:<their-topic>" "myrepo: agent settled quiet - <one line>"
```

Quote what the pane actually said, taken from `tail`, rather than restating the state
word alone. If no push channel is configured, say so and leave the summary in the
chat - do not invent a topic or a URL.

Run `watch` when the operator asked to be told, or before you start something long
you were asked to report on. It is a read, but it blocks: keep the budget shorter
than the patience the operator asked for, and re-invoke rather than parking a
half-hour call nobody is waiting on.

## Do not

- Do not create, start, or stop a *workspace* from here. That is Coder's job:
  `coder-workspace` covers inspecting and restarting one, and provisioning happens
  in the Coder UI. This skill only drives sessions inside a workspace that is
  already running.
- Do not type into a session you have not tailed. Approving an unseen prompt is
  how a delete gets run. And do not type into a `waiting` session at all: that
  word means a person is already sitting in that pane.
- Do not `stop` a session the operator did not name, and never kill the tmux
  server: that takes their editor terminals with it.
- Do not reach for a Coder API token. This CLI deliberately answers from the
  Docker daemon so a chat turn never mints the root-equivalent credential; where
  a question genuinely belongs to Coder it prints the hand-off command, and you
  pass that to the operator.
- Do not treat an empty `list` as an outage. Inside a Coder workspace this shell
  talks to that workspace's own DinD sidecar, so run it on the stack host or here.
  `bash "$CS" check` names the cause.

## Related skills

`coder-workspace` for the workspace itself and its GitHub auth, `evo-stack-ops`
for the stack's services, `host-diagnostics` when a verb returns nothing and the
reason is unclear.
