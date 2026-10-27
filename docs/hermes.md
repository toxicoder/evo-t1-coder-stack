---
title: Hermes host assistant
description: "The on-host assistant with the Web Dashboard on :9119: how to reach it on the LAN and on its public name, what it may touch, and how approvals gate a mutating command."
tags: [hermes, dashboard, operate, safety]
---

**What's on this page**

- How to reach the dashboard, on the LAN and on the public name
- Sign-in: HTTP basic auth, with Authelia in front of the public name
- The models it calls through LiteLLM
- What the container mounts, and what "be the host" costs
- Approval prompts, bootstrap seeding, and the skills directory

**What this enables**

- Running stack operations by conversation with a plan and an approval first
- Reaching the assistant on the LAN, and on the public name `auto` composes from the parts

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
[public-access.md](public-access.md) (the public name, which `auto` composes),
[SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md).

## Access

- Dashboard on host port **9119**, from `HERMES_DASHBOARD_PORT`. The dev sandbox shifts
  it to **19119** the same way it shifts every other published port.
- **LAN:** `http://<STACK_LAN_HOST>:9119` - plain HTTP, exactly like LiteLLM on `:4000`.
  There is no self-signed cert for this port and no redirect to HTTPS. This URL stays
  when the public name is on. Tailscale reaches it the same way, on that port.
- **Public name, opt-in:** `hermes-<suffix>.<base>`, so
  `https://hermes-gmktecbeast.overeazy.io` under the shipped defaults, when
  `STACK_PUBLIC_HOSTS=auto` composes it or an explicit list names it. Bootstrap
  classifies `hermes-*` and `hermes.*` and writes `STACK_HERMES_URL`. The path is the
  same as the other public names: Cloudflare
  (orange cloud, WebSockets on by default), Traefik on the other LAN server (TLS
  `*.overeazy.io`, Authelia), the `router` on this box `:8080`, then
  `http://hermes:9119`, with the original Host preserved. Traefik's backend is
  `:8080`, not `:9119`. See [public-access.md](public-access.md).
- Sign-in is HTTP basic auth from `.env`: `HERMES_DASHBOARD_USER` (default `admin`) and
  `HERMES_DASHBOARD_PASSWORD`. Bootstrap generates the password; it is **not** the
  Homepage password, and `bazelisk run //scripts:dashboard-password` does not rotate it.
  That basic auth stays on every door. Hermes v0.22.5 refuses to bind `0.0.0.0` with no
  provider. On the public URL Authelia challenges first and basic auth challenges
  second; two logins are expected. LAN `:9119`, and LAN `:8080` with this name's Host
  header, never see Authelia, so basic auth is the credential on those paths.
- The **Chat tab** is the primary UX. It embeds the Hermes TUI - a PTY over WebSocket
  on `/api/pty` and `/api/ws` - so the terminal agent and the browser are the same
  process, and approval prompts render as cards in the chat rather than vanishing into
  a detached tty. Hermes sends a keepalive every 20 seconds. Traefik and Authelia have
  to pass the `Upgrade` hop. A close code **4403** is the Host / Origin / peer guard.
  Compose sets `HERMES_DASHBOARD_PUBLIC_URL` from `STACK_HERMES_URL` (the seed file
  does not carry `public_url`). The seeded `dashboard.trusted_proxies` is
  `["172.16.0.0/12"]`, which is what makes Hermes honour `X-Forwarded-Proto` from the
  router (the Secure cookie and `wss`). `HERMES_DASHBOARD_PUBLIC_URL` is environment
  and applies when the container is recreated. An existing `hermes-data` volume does
  not pick up `trusted_proxies` until a reseed or `hermes config set` - the volume
  seed is copy-once. The reseed command is below.
- The Homepage card in the **Host** group links to `STACK_HERMES_URL` (the public
  origin when set, otherwise the LAN URL). Its `siteMonitor` is
  `http://hermes:9119/api/status`, which resolves over compose DNS, so the card stays
  correct whatever the browser link is. See [dashboard.md](dashboard.md).

## Auth

- Hermes since the June 2026 hardening refuses a non-loopback bind without a
  `DashboardAuthProvider`. Binding `0.0.0.0` with no provider is a boot error, not a
  warning.
- `HERMES_DASHBOARD_INSECURE` is a deprecated no-op. Setting it changes nothing and buys
  nothing, and it is not how the public name is opened.
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
  which is what an agent loop needs, and it stays the default.
- `agent` also thinks hard by default: it bakes `reasoning_effort: xhigh`.
  **`agent-low`**, **`agent-medium`** and **`agent-xhigh`** are the thinking variants of
  it - the same Qwen3.8-Flash-Next on the same three Spark boxes, with real
  `tool_calls` and that level baked into the alias instead. Use one when a run needs a
  different level; Qwen3.8-Flash-Next takes `low`, `medium` and `xhigh` and nothing else.
- The key is `LITELLM_MASTER_KEY`, substituted from the environment into the seeded
  `config.yaml`. Do not copy the key into a Hermes file - one secret, one owner.
- Fallbacks, in the order worth trying them:
  - `chat` - `qwen2.5:7b` on the Arc, and it returns real `tool_calls`. The reliable
    degrade path when every Spark box is down.
  - `coder` / `coder-fast` - the Qwen2.5-Coder weights on the Arc. Chat is good, but
    those weights write the tool call into the message body as plain text, so agent
    turns silently lose their tools. See
    [litellm-routing.md](litellm-routing.md#tool-calls-the-measured-limitation).
- Switch it inside the container with `hermes config set model.model chat` (or
  `agent-medium` for a thinking level), which edits the live config under `/opt/data`.
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
  control rather than the mount list. A public Hermes name has that same standing as
  public Coder.
- `HERMES_UID` / `HERMES_GID` are set to the host operator, so a file Hermes writes into
  `$STACK_HOST_PATH` is yours to commit and not owned by uid 10000.
- `/home` is **not** mounted in v1. Hermes cannot see your dotfiles, your SSH keys or
  your shell history, and it should not need to.

## Approvals

- The seeded config sets `approvals.mode: manual`. `cron_mode` and `unattended_mode` are
  both `deny`, so a scheduled or unattended run cannot approve anything either.
- Leave the mode on `manual`. `off` is `--yolo`: every mutating command executes on the
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

`<mount>` is the host directory of the Hermes data volume (what compose mounts at
`/opt/data`). `--force` is how an existing volume picks up the seeded
`dashboard.trusted_proxies`. Setting that key with `hermes config set` is the
in-container alternative. `HERMES_DASHBOARD_PUBLIC_URL` is not in the volume;
recreate the container and the env applies.

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

- The public name is opt-in (`hermes-*`, which `auto` composes from the naming parts or
  an explicit list pins). It does not change what the container can do: local terminal,
  host mounts and the docker socket still mean this agent can affect the real host.
  Treat its approvals the way you treat a root shell. That is the same standing as
  public Coder.
- HTTP basic auth stays, including on the public URL. Authelia is the gate in front of
  that name only. LAN `:9119` and a matching Host on `:8080` bypass Authelia, so the
  basic-auth provider is load-bearing. It is a provider, not a toggle.
- `HERMES_DASHBOARD_INSECURE` does not remove that requirement. Leave
  `approvals.mode` on `manual`.
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
box, including this card, is in [dashboard.md](dashboard.md); the LAN and public
routing rules are in [public-access.md](public-access.md), and the service inventory is
in [README.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/README.md).
