---
title: Hermes host assistant
description: "The on-host assistant with two doors - the Web Dashboard on :9119 and the host terminal via hermes-shell: how to reach it, what it may touch, and how approvals gate a mutating command from either."
tags: [hermes, dashboard, terminal, operate, safety]
---

# Hermes host assistant

**What's on this page**

- How to reach the dashboard, on the LAN and on the public name
- Opening the same assistant in your own terminal with `hermes-shell`
- Sign-in: HTTP basic auth, with Authelia in front of the public name
- The models it calls through LiteLLM
- Web research through the stack's own SearXNG, with the third-party fallback off
- What the container mounts, and what "be the host" costs
- Approval prompts, bootstrap seeding, and the skills directory

**What this enables**

- Running stack operations by conversation with a plan and an approval first
- Reaching the assistant on the LAN, and on the public name `auto` composes from the parts
- Asking from a terminal you already have - the right Linux command, a triage, a
  GitHub project deployed into the deploy workspace - with the same skills, memory
  and approval gate behind the answer

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

## From the host terminal

The Chat tab is the door for someone at a browser. The terminal door is for someone
already on the box, and it opens the **same** assistant - same `SOUL.md`, same seeded
`config.yaml`, same git-tracked skills, same LiteLLM lane, same memory, same manual
approval gate:

```sh
bazelisk run //scripts:hermes-shell                 # the agent, in this terminal
bazelisk run //scripts:hermes-shell -- check        # readiness report, launches nothing
bazelisk run //scripts:hermes-shell -- ask "why is coder offline"
bazelisk run //scripts:hermes-shell -- commands     # the CLI this image version spells
bazelisk run //scripts:hermes-shell -- shell        # a shell in its container
bazelisk run //scripts:hermes-shell -- --dry-run    # print the compose command, run nothing
```

- **Subcommands:** `chat` (the default), `ask TEXT` for one question and exit, `shell`
  for a shell with the container's mounts and socket, `check` for the readiness report,
  `commands` for the assistant's own help. Every word after the subcommand is handed to
  the assistant verbatim, so a flag this script has never heard of still works.
- **Options** (before the subcommand): `-p/--project-name` (`evo-t1-prod`; the dev
  sandbox is `evo-t1-dev`), `-f/--file`, `-e/--env-file`, `-m/--model <alias>` for one
  session, `-w/--writable <dir>`, `--one-shot`, `--dry-run`, `-h/--help`.
- **It enters the running container rather than starting a second one.** Hermes keeps
  its sessions and memory in a SQLite store under `/opt/data`, and two containers on one
  data directory is the documented way to corrupt it - the WAL sidecars and the lock
  only mean something inside one container. So while the gateway is up this is
  `docker compose exec`, and the terminal agent and the dashboard agent are literally
  the same process on the same store. Only when nothing is running does it
  `docker compose run --rm --no-deps` a lone container. `--one-shot` forces the second
  container anyway and says out loud what it risks.
- **`check` is the first thing to run when an answer looks impossible.** It reports the
  daemon, the compose CLI, the project, the container state, whether the service
  resolves, the image, whether the data volume is seeded, whether the model key is set
  or still a shipped placeholder, whether LiteLLM answers `/health/liveliness`, and the
  work directory. It prints key names and never a value, and it launches nothing.
- **Approvals are the same gate, inline.** A dangerous command stops in your tty with
  `[o]nce | [s]ession | [a]lways | [d]eny`, deny by default. There is no browser card
  here and nothing to approve elsewhere; the terminal door does not loosen
  `approvals.mode: manual`, and `--yolo` / `HERMES_YOLO_MODE` have no place in this
  stack. See [Approvals](#approvals).
- **An interactive session needs a real tty** (the TUI draws on a pty compose allocates
  from your terminal), so `chat` and `shell` refuse from a pipe or a cron line - that is
  what `ask` is for.
- **What it can see:** the checkout at `$STACK_HOST_PATH`, the deploy workspace at
  `${STACK_DEPLOY_PATH:-/opt/stack-deploy}`, `/opt/stack-skills`, the data volume, and
  the docker socket. **What it cannot:** `/home` is not mounted, so no dotfiles, SSH
  keys or shell history - by design. The image carries git and the Docker CLI but not
  bazelisk, so inside the container the same operations go through
  `docker compose -p evo-t1-prod -f "$STACK_HOST_PATH/docker-compose.yml"`.
- **`--writable` matters more than it looks.** The official image sets
  `HERMES_WRITE_SAFE_ROOT=/opt/data`, so a file-tool write anywhere else is refused
  outright and no approval card even appears. To have the assistant edit files on the
  host, name the directory: `--writable "${STACK_DEPLOY_PATH:-/opt/stack-deploy}"` or
  the checkout path.

## From a phone, or anywhere

The point of the assistant is that the operator leaves the desk and the box keeps
working for them. Four doors reach the same agent, the same seeded config, the same
skills and the same memory store; which one is open is a decision in `.env`, not a
rebuild.

| door | what it is | shipped state | open it with |
|---|---|---|---|
| Dashboard | browser chat + PTY, basic auth, LAN `:9119` or the public name | on | `STACK_PUBLIC_HOSTS` for remote |
| Terminal | `hermes-shell` on the host: `ask`, `chat`, `shell`, `check` | always | nothing |
| API server | `POST /v1/chat/completions`, `/v1/runs`, `/api/sessions/*` on `:8642` | **off** | `HERMES_API_SERVER_ENABLED=true` |
| Push | ntfy notifications to a phone app | **off** | keys in `/opt/data/.env` |

**The API server** is the headless door: an iOS Shortcut or a Tasker profile can
POST a prompt and read the answer with no browser and no dashboard login.

```sh
curl -sS -X POST "http://<host>:8642/v1/chat/completions" \
  -H "Authorization: Bearer $HERMES_API_SERVER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"hermes","messages":[{"role":"user","content":"what is running?"}]}'
```

It ships off and the published mapping binds **loopback**, because this server
"adds full access to the toolset, including terminal commands" per upstream, on a
container that holds the docker socket. Turning it on is two deliberate edits: the
flag, and `HERMES_API_BIND` if something off this host should reach it.
`API_SERVER_KEY` is generated by bootstrap with the other secrets and is required
whenever the server is on; upstream fails closed rather than serving unauthenticated.
`API_SERVER_MODEL_NAME` (default `hermes`) is what a model-listing frontend shows.
`API_SERVER_CORS_ORIGINS` stays unset: a browser calls the dashboard, not this port,
and an origin allowlist is only for a client you named on purpose.

**Push** is what makes a phone viable, because pull means opening a dashboard every
time. It rides upstream's ntfy adapter and is configured in the assistant's own
`/opt/data/.env`, not in compose:

```sh
bazelisk run //scripts:hermes-shell -- shell
printf '%s\n' 'NTFY_TOPIC=<a-topic-nobody-can-guess>' \
  'NTFY_PUBLISH_TOPIC=<the-same-topic>' \
  'NTFY_SERVER_URL=https://ntfy.<your-domain>' >> /opt/data/.env
```

Two reasons it lives on the volume: the gateway registers the adapter from the
*presence* of `NTFY_TOPIC`, so an empty `NTFY_TOPIC=` in compose would hand it a
half-configured platform, and a token in a container's environment is readable by
anyone who can `docker inspect` it. Leave `NTFY_ALLOWED_USERS` unset and the channel
is push-only - your phone gets the notices, and nobody can talk back to the agent
through the topic. Set it (to the topic name) only for inbound, and only on a topic
no one else can guess: upstream's own warning is that every publisher to a topic is
treated as the same user. `NTFY_SERVER_URL` defaults to `https://ntfy.sh`; a
self-hosted ntfy keeps the notices on your hardware.

**What to ask from a phone** is the same list you would run at the desk, and the
`coding-agents` skill is what teaches the assistant to answer it:

- *what are my agents doing* -> `//scripts:coder-sessions -- list` / `show`
- *what did it get stuck on* -> `tail <workspace> <session> 40`, then quote the pane
- *tell it yes* -> `send <workspace> <session> "yes"`
- *start one on repo X* -> `launch --dir /home/coder/<repo> <workspace>`
- *wake me when it finishes* -> `watch <workspace> <session> 1800`, then `hermes send`
  to the ntfy topic above
- *is the box healthy* -> `//scripts:hermes-shell -- check`, and the `host-diagnostics` skill

Session control needs no credential and no open browser: the verbs read the Docker
daemon by workspace label. See
[grok-build-and-agents.md](grok-build-and-agents.md#watching-those-sessions-from-anywhere).

## Audit and drift

`hermes-shell -- check` answers "can I open the assistant". It cannot answer "is this
still the assistant this repo describes", and the two come apart on a long-lived box:
an operator edits the config inside the volume, a recreate reads a stale `.env`, a
merge changes the seed and a seed-only-when-absent copy never takes it. `hermes-doctor`
answers the second question. It is read-only and prints key names with no value.

```sh
bazelisk run //scripts:hermes-doctor              # every check
bazelisk run //scripts:hermes-doctor -- posture   # security and privacy only
bazelisk run //scripts:hermes-doctor -- web       # the search lane and its guards
bazelisk run //scripts:hermes-doctor -- diff      # the volume copy against the seed
bazelisk run //scripts:hermes-doctor -- --check approvals --check web-lane
bazelisk run //scripts:hermes-doctor -- --dry-run # print the compose line, inspect nothing
```

- **What it reads:** the config the container actually loads, the environment it was
  created with, the mounts it was given, and the two seed files beside the checkout.
  The created environment is the fact and the `.env` beside the compose file is the
  intention: compose interpolated the former at create time, so a key can be right in
  the file and stale in the container until the next recreate. Every container-level
  fact comes from `docker inspect` or `docker compose ps`; nothing writes, restarts,
  recreates, or execs.
- **The fourteen checks:** `approvals` (manual, with cron and unattended both deny),
  `terminal-cwd`, `write-root`, `web-lane`, `keyless-egress`, `mcp-servers`,
  `seed-drift`, `mount-identity`, `image-pin`, `model-key`, `dashboard`, `memories`,
  `anywhere-door` (the API server's enabled/keyed/bound state and whether the push
  channel can be answered by strangers), and `agent-verbs` (whether the assistant can
  still reach `scripts/coder-sessions.sh` and the socket those verbs read). The last
  two are the ones that keep the phone story honest: an open door nobody configured,
  and a closed door nobody can find, are the same class of surprise.
- **It reports, it does not gate.** Exit 0 on a clean bill (warnings allowed), 1 when a
  check failed, 2 on a bad invocation, 5 when it cannot find a checkout.
  `hermes-shell -- check` stays the thing that decides whether to launch a session.
- **Three findings it exists to catch**, each one measured on a live box:
  `terminal.cwd` still carrying the `${STACK_HOST_PATH}` token (Hermes validates that
  value with `expanduser()` alone, so the token reads as a missing directory while
  `hermes config get` prints it looking healthy), `STACK_HOST_PATH` naming a directory
  with no checkout (compose mounts an empty directory over the repo and every
  container-level check still reads healthy), and a `web` block that stopped pinning
  `searxng` or flipped a keyless switch back on, which routes a search to a vendor's
  free tier while the config still looks local.
- **`--data DIR`** points the two volume checks at a directory instead of asking the
  daemon where the volume is mounted, so the audit can be run against a copy of one.
- **Run it before a `--force` re-seed and after a merge.** The drift check names the
  file that differs and prints the `hermes-bootstrap --data <mount> --force` line that
  would overwrite it, which is the pair an operator wants side by side.

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

## Web research

The assistant can look things up, and the query leaves through your own SearXNG.

- `web_search` goes to the stack's SearXNG container: the seeded config sets
  `web.search_backend: searxng`, and compose gives the container
  `SEARXNG_URL=${STACK_HERMES_SEARCH_URL:-http://searxng:8181}`. The variable's
  presence is what registers the provider (`plugins/web/searxng` reads
  `SEARXNG_URL` as its key env), and it is the only bundled web provider that
  needs no API key. The name resolves on the compose network, so this adds no
  published port.
- **Both keyless switches stay off, and that is the part that keeps the promise.**
  `agent/web_search_registry.py` resolves a backend in five steps, and its last
  one is an anonymous free-tier ring - `exa`, `parallel`, `firecrawl`,
  `keenable` - reached with no key at all. A seed that named no backend and left
  `web.keyless_fallback` and `web.keyless_rescue` at their shipped `true` would
  answer a search from a vendor's public endpoint while looking local. With both
  false, a query either goes to your instance or fails on the box.
- `web_extract` is deliberately unconfigured. SearXNG aggregates engine results
  and does not fetch pages, so the seed leaves `web.backend` and
  `web.extract_backend` empty and page extraction fails with "no extract provider
  configured". Set `web.extract_backend` yourself when you decide a fetch is
  worth a third-party extractor; nothing reaches one by default.
- Query the lane the same way the agent does:
  `bazelisk run //scripts:search-check` from a host shell counts results per
  engine, which is how an empty answer stays distinguishable from no answer.
  Inside the container,
  `curl -s -H 'Accept: application/json' "$SEARXNG_URL/search?q=hermes&format=json"`
  is the exact request the provider makes. The instance only answers JSON
  because `searxng/settings.yml` adds `json` to `search.formats`; without it the
  request is refused with 403 before the query is parsed.
- Re-point the lane with `STACK_HERMES_SEARCH_URL` in `.env` (a sibling box, say)
  and recreate. An operator who wants a keyed provider sets
  `web.search_backend` plus that vendor's key env in the container themselves -
  the seed carries neither, and adding one is a decision with a privacy cost.

## Mounts and "be the host"

| Mount | Inside | Why |
|---|---|---|
| `hermes-data` (named volume) | `/opt/data` | config, sessions, memory, SQLite |
| `${STACK_HOST_PATH:-.}` | `${STACK_HOST_PATH:-/opt/stack}` | identical-path checkout |
| `${STACK_DEPLOY_PATH:-/opt/stack-deploy}` | the same absolute path | the deploy workspace |
| `./hermes/skills` | `/opt/stack-skills` (ro) | git-tracked skills |
| `/var/run/docker.sock` | `/var/run/docker.sock` | compose and container control |

- `/opt/data` is a **named volume on purpose**. Hermes keeps a SQLite database there in
  WAL mode, and WAL on a virtiofs bind mount is not safe. Bind-mounting that path is how
  you corrupt the assistant's own memory.
- `STACK_HOST_PATH` is the checkout's `pwd -P`, or, from a subdirectory or a linked
  worktree, its git top-level. Compose bind-mounts that host path at
  the same path inside the container, so `docker compose -f $STACK_HOST_PATH/docker-compose.yml`
  talking through the socket names bind sources the daemon can find. Empty (CI
  `compose config`) falls back to `.:/opt/stack`. `bootstrap` refreshes the key only
  after checking the path holds this `docker-compose.yml`: compose mounts whatever the
  key names, so a stale value leaves the assistant working an empty directory while
  every container-level check still reads healthy.
- The working directory the agent runs in is `terminal.cwd`, and it has to be a literal
  path. Hermes validates it in `agent/runtime_cwd.py` with `expanduser()` alone, so a
  `${VAR}` left in the file is reported as `does not exist` and the agent works somewhere
  else, while `hermes config get terminal.cwd` still prints the token because the config
  *loader* does expand `${VAR}` - the two paths disagree, and only the runtime one runs
  commands. `hermes-bootstrap` renders the placeholder in the seeded `config.yaml` at
  seed time (`--cwd DIR` overrides what it renders), which is the part that fixes a
  long-lived box. compose also sets `TERMINAL_CWD` from the same key, as the backstop for
  a config that names no `terminal.cwd`: `apply_terminal_config_to_env` lets an explicit
  `terminal.cwd` in the file own that variable, so the file decides wherever it carries
  one. Re-seed a volume that predates the render with
  `hermes-bootstrap --data <mount> --force`.
- `hermes/skills/` is tracked in git. Add a skill by editing the repo, never by editing
  the volume; the volume copy is not the record.
- `STACK_DEPLOY_PATH` (default `/opt/stack-deploy`) is the **deploy workspace**: the one
  directory meant for clones, builds, and the compose project of a third-party project
  the assistant brings up. It is mounted at its own absolute path for the same reason
  `STACK_HOST_PATH` is - a bind source inside a project file the assistant writes has to
  resolve on the host daemon - and bootstrap fills it in without overwriting a path you
  set yourself. It is deliberately outside `/home`, so giving the assistant somewhere to
  work did not mean giving it your dotfiles. An existing container gains the mount on
  recreate, since `restart` keeps the old mounts.
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
- From the terminal door the same gate is inline in your tty: a dangerous command stops
  with `[o]nce | [s]ession | [a]lways | [d]eny` and does not proceed until you answer,
  with deny the default. An approval is scoped to the session you answer in, so a yes
  given over there does not cover a fresh session opened at this door.
  `--yolo` and `HERMES_YOLO_MODE` bypass the gate entirely; they have no place here.

## Bootstrap and skills

- The first `compose up` runs `hermes-init`, which is the in-container equivalent of
  `bazelisk run //scripts:hermes-bootstrap`: it runs
  `scripts/hermes-bootstrap.sh --in-container` and copies `hermes/config.yaml` and
  `hermes/SOUL.md` into `/opt/data` **only when those files are missing**. Editing the
  copy in the volume is how an operator ends up with a config no one can reproduce.
- The seed is a template for one key: `${STACK_HOST_PATH}` in `terminal.cwd` is rendered
  to a literal path on the way into the volume, from `--cwd`, then `STACK_HOST_PATH`,
  then `/opt/stack` (announced when it falls back). `${LITELLM_MASTER_KEY}` stays a token
  on purpose - Hermes expands it at boot, and a byte of the key in a volume copy is what
  [Mounts and "be the host"](#mounts-and-be-the-host) argues against.
- To reseed deliberately:

```sh
bazelisk run //scripts:hermes-bootstrap -- --data <mount> --force
```

`<mount>` is the host directory of the Hermes data volume (what compose mounts at
`/opt/data`). `--force` is how an existing volume picks up the seeded
`dashboard.trusted_proxies`, and `--cwd /absolute/path/to/checkout` is how a host re-seed
names the working directory when the shell running it carries no `STACK_HOST_PATH`.
Setting that key with `hermes config set` is the
in-container alternative. `HERMES_DASHBOARD_PUBLIC_URL` is not in the volume;
recreate the container and the env applies.

- A skill is one directory: `hermes/skills/<name>/SKILL.md`, with
  [agentskills.io](https://agentskills.io) frontmatter for the name and description.
  Commit it, and the next `up` has it.
- What ships, and which question each one answers: `evo-stack-ops` (pull, status,
  restart, logs for this stack), `coder-workspace` (workspaces and their GitHub auth),
  `coding-agents` (what the coding agents in those workspaces are doing right now,
  and how to answer, start, or stop one — the `//scripts:coder-sessions` verbs),
  `model-routing` (which LiteLLM alias, and how to switch it), `host-linux-ops` (the
  right Linux command, what each flag does, and the blast radius before it runs),
  `host-diagnostics` (read-only triage for a slow, hot, full or failing box),
  `web-research` (what is worth looking up, how to read an empty answer from the
  lane above, and what that lane refuses to do), and
  `deploy-from-github` (a named repository to running, with the read-first, pin-the-ref,
  isolate, preflight, health-check, keep-a-rollback order). The last four are what make
  the terminal door worth opening: they carry the mentoring stance - inspect, explain,
  propose, then act on the yes.
- A bind-mounted skill needs no recreate when the agent reloads skills from disk; start a
  **new session** - a fresh Chat tab, or a new `hermes-shell` run - and the new skill is
  offered. Recreate only if it still does not show up, since `restart` keeps the old
  mounts.
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
- The terminal door adds a way in for someone who already has a shell on this host, and
  opens no new listener, no new port and no new credential. `hermes-shell` authenticates
  nothing of its own: `docker` on that host is the credential, and it was always
  root-equivalent here. Its one guard is that the assistant's approvals stay `manual` on
  both doors.
- The API server is the widest door here and ships closed. It carries the same
  toolset as the dashboard, terminal included, and its only gate is the bearer key,
  so it is off in compose and its host mapping binds loopback until an operator
  names both. Treat `HERMES_API_SERVER_KEY` as a root credential: rotate it by
  editing `.env` and recreating the container, and give a phone a Shortcut that
  holds it rather than a URL that carries it.
- A push channel is an inbound door even when you only use it to listen. Every
  publisher to an ntfy topic is one identity to the gateway, so the push-only
  posture - `NTFY_TOPIC` and `NTFY_PUBLISH_TOPIC` set, `NTFY_ALLOWED_USERS` not -
  is the one this doc recommends, and the topic name is the secret.
- The deploy workspace is writable by the assistant's file tools only when you say so
  with `--writable`, and the file tools refuse anything outside the image's
  `HERMES_WRITE_SAFE_ROOT` (the official default is `/opt/data`) with no prompt at all.
  Name the narrowest directory that finishes the job.

## Commands

Open the assistant in your own terminal (subcommands `chat`, `ask`, `shell`, `check`,
`commands`; `--help` for the flags):

```sh
bazelisk run //scripts:hermes-shell -- check
bazelisk run //scripts:hermes-shell
```

Read-only audit of what the assistant was created with, and how far it has drifted from
this checkout (`report`, `posture`, `web`, `diff`; `--check` narrows to one):

```sh
bazelisk run //scripts:hermes-doctor -- posture
```

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
