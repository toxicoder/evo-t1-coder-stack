---
title: Hermes host assistant
description: "The on-host assistant with the Web Dashboard on :9119: how to reach it, what it may touch, and how approvals gate a mutating command."
tags: [hermes, dashboard, operate, safety]
---

**What's on this page**

- How to reach the dashboard, and why it stays on the LAN
- Sign-in, and which password it uses
- The models it calls through LiteLLM
- What the container mounts, and what "be the host" costs
- Approval prompts, bootstrap seeding, and the skills directory

**What this enables**

- Running stack operations by conversation with a plan and an approval first
- Keeping the assistant off the public edge while the dashboard stays usable

Hermes is the Nous Research Hermes Agent running as the interactive assistant **on the
stack host itself**: not inside a workspace, not in a streamed desktop, but with the
checkout, the compose project and the docker socket in reach. It adds an official Web
Dashboard with a Chat tab that carries approval prompts, so the assistant can plan a
change, show the plan, and wait for you to approve it before it touches anything.

That is the whole point of the service: stack ops by conversation. "Recreate the dev
stack and tell me which container restarts", "why is the coder agent offline", "run the
gate and fix what it reports" - each one runs with a plan first and an approval card
before the mutating command.

Related: [dashboard.md](dashboard.md) (the card that links here),
[litellm-routing.md](litellm-routing.md) (the aliases Hermes calls),
[public-access.md](public-access.md) (why this one stays off the public edge),
[SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md).

## Access

- Dashboard on host port **9119**, from `HERMES_DASHBOARD_PORT`. The dev sandbox shifts
  it to **19119** the same way it shifts every other published port.
- `http://<STACK_LAN_HOST>:9119` - plain HTTP, exactly like LiteLLM on `:4000`. There is
  no self-signed cert for this port and no redirect to HTTPS.
- Sign-in is HTTP basic auth from `.env`: `HERMES_DASHBOARD_USER` (default `admin`) and
  `HERMES_DASHBOARD_PASSWORD`. Bootstrap generates the password; it is **not** the
  Homepage password, and `bazelisk run //scripts:dashboard-password` does not rotate it.
- The **Chat tab** is the primary UX. It embeds the Hermes TUI - a PTY over a WebSocket -
  so the terminal agent and the browser are the same process, and approval prompts
  render as cards in the chat rather than vanishing into a detached tty.
- The Homepage card in the **Host** group links here. Its `siteMonitor` is
  `http://hermes:9119/api/status`, which resolves over compose DNS, so the card stays
  correct whatever the LAN IP is. See [dashboard.md](dashboard.md).
- **LAN and Tailscale only.** There is no `hermes-*` public Traefik name and no
  `proxy/router.conf` server block for it, so the public edge has no upstream to reach it
  with. Do not add one and do not publish this port to the WAN.

## Auth

- Hermes since the June 2026 hardening refuses a non-loopback bind without a
  `DashboardAuthProvider`. Binding `0.0.0.0` with no provider is a boot error, not a
  warning.
- `HERMES_DASHBOARD_INSECURE` is a deprecated no-op. Setting it changes nothing and buys
  nothing.
- Compose supplies the provider: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`,
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` and `HERMES_DASHBOARD_BASIC_AUTH_SECRET`,
  interpolated from `.env` with the same non-empty fallbacks `.env.sample`
  carries (`admin` / `change-me-hermes` / `change-me-hermes-secret`). An empty
  interpolation default is a boot error on `0.0.0.0`: the plugin skips
  registration and the gateway refuses to bind.
- The result fails closed: no credentials, no dashboard. There is no unauthenticated
  read-only mode to fall back to.

## Models

- Hermes talks to the LiteLLM proxy the stack already runs: base URL
  `http://litellm:4000/v1`, model alias **`agent`**. That is the tool-capable Spark lane,
  which is what an agent loop needs.
- The key is `LITELLM_MASTER_KEY`, substituted from the environment into the seeded
  `config.yaml`. Do not copy the key into a Hermes file - one secret, one owner.
- Fallbacks, in the order worth trying them:
  - `chat` - `qwen2.5:7b` on the Arc, and it returns real `tool_calls`. The reliable
    degrade path when every Spark box is down.
  - `coder` / `coder-fast` - the Qwen2.5-Coder weights on the Arc. Chat is good, but
    those weights write the tool call into the message body as plain text, so agent
    turns silently lose their tools. See
    [litellm-routing.md](litellm-routing.md#tool-calls-the-measured-limitation).
- Switch it inside the container with `hermes config set model.model chat`, which edits
  the live config under `/opt/data`.
- Nous Portal is an optional upstream, not a default, and this page does not document it.
  Nothing here needs an account.

## Mounts and "be the host"

| Mount | Inside | Why |
|---|---|---|
| `hermes-data` (named volume) | `/opt/data` | config, sessions, memory, SQLite |
| `${STACK_HOST_PATH:-.}` | `${STACK_HOST_PATH:-/opt/stack}` | identical-path checkout |
| `./hermes/skills` | `/opt/stack-skills` (ro) | git-tracked skills |
| `/var/run/docker.sock` | `/var/run/docker.sock` | compose and container control |

- `/opt/data` is a **named volume on purpose**. Hermes keeps a SQLite database there in
  WAL mode, and WAL on a virtiofs bind mount is not safe. Bind-mounting that path is how
  you corrupt the assistant's own memory.
- `STACK_HOST_PATH` is the checkout's `pwd -P`. Compose bind-mounts that host path at
  the same path inside the container, so `docker compose -f $STACK_HOST_PATH/docker-compose.yml`
  talking through the socket names bind sources the daemon can find. Empty (CI
  `compose config`) falls back to `.:/opt/stack`. Seeded `terminal.cwd` is
  `${STACK_HOST_PATH}`, expanded from the same env.
- `hermes/skills/` is tracked in git. Add a skill by editing the repo, never by editing
  the volume; the volume copy is not the record.
- `group_add: ${DOCKER_GID}` plus the socket is the same credential the `coder` service
  already holds: root-equivalent on the host. Nothing new is exposed here that the Coder
  container does not already have - which is precisely why approvals, below, are the
  control rather than the mount list.
- `HERMES_UID` / `HERMES_GID` are set to the host operator, so a file Hermes writes into
  `$STACK_HOST_PATH` is yours to commit and not owned by uid 10000.
- `/home` is **not** mounted in v1. Hermes cannot see your dotfiles, your SSH keys or
  your shell history, and it should not need to.

## Approvals

- The seeded config sets `approvals.mode: manual`. `cron_mode` and `unattended_mode` are
  both `deny`, so a scheduled or unattended run cannot approve anything either.
- Never set the mode to `off`. That is `--yolo`: every mutating command executes on the
  host with no card.
- `terminal.backend: local` keeps the dangerous-command checker active. The `docker`
  backend skips that checker, because it treats the container as the safety boundary -
  and here the container is mounted onto the host, so that boundary is not real.
- Working agreement with the assistant: it explains the plan in chat, then waits for the
  approval card in the Chat tab before running anything mutating. If a run looks like it
  is acting without one, stop it and re-read the mode.

## Bootstrap and skills

- The first `compose up` runs `hermes-init`, which is the in-container equivalent of
  `bazelisk run //scripts:hermes-bootstrap`: it runs
  `scripts/hermes-bootstrap.sh --in-container` and copies `hermes/config.yaml` and
  `hermes/SOUL.md` into `/opt/data` **only when those files are missing**. Editing the
  copy in the volume is how an operator ends up with a config no one can reproduce.
- To reseed deliberately:

```sh
bazelisk run //scripts:hermes-bootstrap -- --data <mount> --force
```

- A skill is one directory: `hermes/skills/<name>/SKILL.md`, with
  [agentskills.io](https://agentskills.io) frontmatter for the name and description.
  Commit it, and the next `up` has it.
- A bind-mounted skill needs no recreate when the agent reloads skills from disk; start a
  **new Chat session** and the new skill is offered. Recreate only if it still does not
  show up, since `restart` keeps the old mounts.
- `SOUL.md` is the identity - voice and stance, a short persona. It is not a fork of
  [AGENTS.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/AGENTS.md): the repo's shell conventions stay in that file, where the
  writers and the linters read them.

## Security notes

- Local terminal + host mounts + the docker socket means this agent can affect the real
  host, not a sandbox. Treat its approvals the way you treat a root shell.
- Dashboard auth is mandatory on any non-loopback bind. It is a provider, not a toggle.
- Secrets live in gitignored `.env` and in the `hermes-data` volume. Never commit them,
  and never paste `LITELLM_MASTER_KEY` into a chat to prove a route works.
- Prefer structured commands - the existing Bazel scripts and `docker compose` - over
  ad-hoc shell. A script the repo owns is reviewable and test-covered; a one-liner the
  model invented is neither. See [AGENTS.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/AGENTS.md).
- No GitHub PAT in Hermes. GitHub auth in this stack is Coder External Auth only, and a
  token here would sit on a container that can both write to the checkout and drive the
  host daemon. See [SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md).

## Commands

Stable stack - `hermes` comes up with the rest:

```sh
bazelisk run //scripts:prod-stack -- up
```

Bootstrap options, including `--data` and `--force`:

```sh
bazelisk run //scripts:hermes-bootstrap -- --help
```

Dev sandbox, which puts the dashboard on 19119:

```sh
bazelisk run //scripts:dev-stack -- up
```

The stack runners take `up`, `down`, `status`, `logs`, `reset`; `status` and `logs` are
where a Hermes that will not bind its port is diagnosed first. Status across the whole
box, including this card, is in [dashboard.md](dashboard.md); the LAN-versus-public
routing rules are in [public-access.md](public-access.md), and the service inventory is
in [README.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/README.md).
