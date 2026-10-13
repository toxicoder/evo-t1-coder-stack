# EVO-T1 Coder Stack

One `docker compose up` turns a GMKtec EVO-T1 laptop into a self-hosted dev-workspace server: Coder workspaces whose default terminal re-joins the folder's persistent tmux session (with the Grok Build terminal on its own session, and Cline and Kilo Code pre-wired to local models), Kasm Workspaces for full desktop streaming, IPEX-LLM Ollama running Qwen Coder on the Intel Arc 140T, a LiteLLM proxy that unifies the local iGPU with one or more NVIDIA Spark boxes behind a single OpenAI-compatible endpoint, and a [Homepage](https://gethomepage.dev) dashboard on the default web ports that links it all together with live status for each service.

## Hardware

Target machine: **GMKtec EVO-T1**

| | |
|---|---|
| CPU | Intel Core Ultra 9 285H (Arrow Lake-H) |
| GPU | Intel Arc 140T iGPU (`/dev/dri`) |
| RAM | 96 GB DDR5 (CPU + iGPU unified) |

Everything in this stack is sized for that machine: local LLMs run on the iGPU via IPEX-LLM, and the 96 GB of unified memory is what makes a 32B MoE coder model comfortable.

## Architecture

```text
LAN clients (laptops, phones, the EVO-T1 itself)
  |
  +-- :80 / :443 -> homepage-proxy (nginx: TLS terminator)
  |                   | http:// redirects to https://
  |                   v
  |              Homepage dashboard (compose network only, password gate)
  |                * links + live status for every service below
  |                * host CPU / memory / disk / CPU temp in the header
  |
  +-- :3001 ----> Coder UI (HTTPS, control plane, Postgres-backed)
  |                 :2112 ----> Coder /metrics (loopback-bound; for a scraper)
  |                   | provisions workspaces via /var/run/docker.sock
  |                   v
  |              Coder workspaces (Docker containers)
  |                * built from the golden image evo-t1-dev:latest
  |                  (bazelisk run //scripts:build-dev-image)
  |                * two templates: workspace (plain container) and
  |                  devcontainer (builds the cloned repo's .devcontainer
  |                  on the workspace's own DinD sidecar; toggle off or no
  |                  devcontainer.json => the clone opens on the plain container)
  |                * both clone the create form's repo_url (empty = no clone);
  |                  code-server, the web terminal and the terminal profiles all
  |                  start on that clone, and //scripts:new-workspace picks the
  |                  template + parameters from a git URL
  |                * default terminal re-joins the folder's tmux session
  |                  (vscode-<folder>-<hash>); Grok Build runs `grok --cwd <repo root>`
  |                  inside its own session (grok-build-<folder>-<hash>, with the
  |                  repo root resolved from the terminal's folder by git rev-parse)
  |                * ~/.grok/config.toml rendered by the template: model
  |                  aliases + MCP servers (filesystem, memory,
  |                  sequential-thinking, git, time; github only when
  |                  `github_mcp` is on — its Bearer header names `$GH_TOKEN`,
  |                  which the workspace environment fills from External Auth)
  |                * Cline / Kilo Code ---> host.docker.internal:4000
  |
  +-- :4000 ----> LiteLLM proxy (master key, model aliases)
  |                   +-- local:  http://ollama:11434 (compose network only)
  |                   +-- remote: SPARK1/2_OLLAMA_URL (Ollama aliases) and
  |                   |           SPARK1/2/3_OPENAI_URL (TensorFold on :8888 —
  |                   |           the one `agent` group, one deployment per
  |                   |           Spark box, the only tool-capable path)
  |
  +-- (no host port) IPEX-LLM Ollama on the Arc 140T (/dev/dri)
  |
  +-- :8181 ----> SearXNG metasearch (loopback + LAN face) — the search lane:
  |               keyless engines only, no key, no account, no request logging.
  |               A workspace reaches it through the host gateway, so the
  |               workspace networks stay untouched. Measure the lane with
  |               `bazelisk run //scripts:search-check` (empty != answered).
  |
  +-- :3000 ----> Kasm install wizard (first boot only)
  +-- :4443 ----> Kasm Workspaces UI (privileged DinD desktop streaming)
```

Key properties:

- **Ollama is never published to the host.** It listens on 11434 inside the compose network; LiteLLM is the only gateway to the models, and it sits behind a master key.
- **Workspaces reach models through the host.** The Coder access URL is the LAN IP by default, or the
  public coder name once `STACK_PUBLIC_HOSTS` is set; workspaces reach LiteLLM via
  `host.docker.internal:4000` (host-gateway) and their agents dial the plain listener on
  `host.docker.internal:3002` either way.
- **The control-plane chat agent reaches models the same way, from the server side.** coderd
  dials `http://litellm:4000/v1` over the compose network — `scripts/coder-agents.sh` writes
  that provider, the `agent` + `chat` model configs, the lane pins and the system-prompt
  addendum, so the two doors into LiteLLM are the workspace CLI's `host.docker.internal:4000`
  and the chat agent's `litellm:4000`, with the same master key on both.
- **Kasm owns :3000 / :4443**, so the Coder UI lives on :3001.
- **The dashboard publishes no port of its own.** Homepage serves plain HTTP and cannot load a certificate, so the nginx sidecar owns :80 / :443 and proxies to it over the compose network.
- **Public subdomains are opt-in and purely additive.** The LAN shape above is the default and stays
  intact when the four public names are enabled through a second nginx sidecar (section "Public
  subdomains (optional)" below).

## Quick start

```sh
git clone https://github.com/toxicoder/evo-t1-coder-stack.git
cd evo-t1-coder-stack
cp .env.sample .env
bash scripts/setup-host.sh   # one-time host bootstrap: Bazelisk + the lint toolchain
bazelisk run //scripts:bootstrap -- --check   # read-only pass: reports missing tools, placeholder
                                              # secrets, certs and images, then writes nothing
bazelisk run //scripts:bootstrap   # secrets, CODER_ACCESS_URL, certs; also builds the golden
                                   # image and pulls docker:29.8.1-dind when either is missing
docker compose up -d
bazelisk run //scripts:pull-models  # pulls OLLAMA_MODELS (first run is a big download)
```

`bash scripts/setup-host.sh` is the one script in this repo meant to be run straight from a
shell: it installs Bazelisk and the lint toolchain, so it necessarily runs before Bazel exists.
Every other operation below is a Bazel target — `bazelisk run //scripts:<stem> -- <args>`, where
`<stem>` is the script's file name (`//scripts:dev-stack`, `//scripts:new-workspace`, …). Running
a script by path from a foreign working directory would not find the files it reads by path, so
the Bazel target ships them with it in runfiles.

`bootstrap.sh` also builds `evo-t1-dev:latest` when it is missing (several GB of
downloads, so a cold run takes minutes), pulls `docker:29.8.1-dind` for the opt-in
workspace DinD sidecar, pushes both workspace templates and wires the Coder Agents chat
model once a Coder account exists, and checks the Spark fleet. None of those is fatal:
a build that cannot download, or a push or wiring run with nobody registered yet, prints
why and bootstrap still finishes. All are retryable on their own —
`bazelisk run //scripts:build-dev-image`, `bazelisk run //scripts:push-template` (no arguments pushes both,
template names retry just the ones that failed; section "Coder workspace template"
below), and `bazelisk run //scripts:coder-agents -- --dry-run` / `bazelisk run //scripts:coder-agents -- --apply`
(section "Coder Agents"
below). `SKIP_DEV_IMAGE_BUILD=1` / `SKIP_TEMPLATE_PUSH=1` / `SKIP_CODER_AGENTS=1` /
`SKIP_SPARKS=1` restore the old print-only behaviour; bootstrap reads them from the
process environment only, never from `.env`.

Then:

1. Open `https://<host>:3001` and register the first account — that account becomes the site admin.
   `bootstrap.sh` issues a self-signed cert for Coder as well, so expect the same
   one-time browser warning the dashboard gives. The port is HTTPS because browsers
   only expose `crypto.randomUUID()` in secure contexts: plain `http://` on a LAN IP
   breaks pages like the template builder.
   To do it from a terminal instead, every prompt below also has a
   `CODER_FIRST_USER_*` / `CODER_URL` environment equivalent:

   ```sh
   coder login https://<host>:3001 \
     --first-user-email you@example.com \
     --first-user-username you \
     --first-user-password 'a-long-passphrase' \
     --first-user-trial=false
   ```

   Target the address the server itself answers on (`https://<host>:3001`, or
   `http://127.0.0.1:3000` inside the coder container). Point it at a public
   subdomain in public mode and it fails before it can prompt — Authelia answers the
   CLI's unauthenticated first-user probe with its HTML sign-in page, which the CLI
   reports as `unexpected non-JSON response "text/html; charset=utf-8"`.

   The equivalent HTTP call is `POST /api/v2/users/first`, and `coder server
   create-admin-user` does the same from the server side. All three work on
   v2.36 — the browser is convenience.
2. Push the workspace templates (section below) — `bazelisk run //scripts:push-template` does both
   once an account exists, which is why bootstrap runs it for you and says why it
   skipped when none does. It needs no `coder login` and no host coder CLI.
3. Wire the Coder Agents chat (section "Coder Agents (control-plane) + Grok Build
   delegation" below) — `bazelisk run //scripts:coder-agents -- --apply` creates the `litellm` AI
   provider, the two chat model configs, the subagent lane pins and the system-prompt
   addendum, through the server API and without leaving a credential behind. Bootstrap
   calls it the same way it calls the push, so a cold box skipped both; a stack that
   already runs picks them up on the next bootstrap run or with this one command.
   `--dry-run` prints the intended end state first.
4. Create a workspace from a git repository: `bazelisk run //scripts:new-workspace -- <git-url>`
   (add `--dry-run` to see the decision without creating anything, and
   `--additional-repos "url1,url2"` to clone siblings beside it). It shallow-clones
   the repo, probes it for a dev container, picks `workspace` or `devcontainer`
   accordingly, and drives `coder create` with the right template parameters — the same
   choice, by hand, is: create a workspace in the UI, pick the template, and fill the
   **Git repository** field.
5. Kasm: on first boot open `https://<host>:3000`, run the install wizard once, then use `https://<host>:4443` for the Kasm UI (full detail in section "Kasm" below). Both ports serve TLS with the self-signed certificate Kasm's own installer generates, so expect the same one-time browser warning the dashboard gives — plain `http://` reaches neither port.
6. Dashboard: open `https://<host>/` and sign in with the `HOMEPAGE_AUTH_PASSWORD` that `bootstrap.sh` printed.

## Development model

`main` is the only long-lived branch, and it stays green and deployable: every machine is
built from `main`, so a merge to `main` is by definition deployable to a stack host.
Feature work happens on short-lived `feat/…`, `fix/…` and `refactor/…` branches cut from
the current tip of `main`, integrates by pull request into `main` and nowhere else, and is
deleted the moment it merges. There are no environment branches (`dev`, `staging`,
`prod`, `uat`): each environment deploys *from* `main`, and a hotfix branches from `main`
and lands on `main` first. Rules, the branch-protection settings behind them and the
commit prefixes are in [CONTRIBUTING.md](CONTRIBUTING.md) and
[docs/branching.md](docs/branching.md).

## Testing changes locally

The dev stack is how a stack-affecting change gets checked before it becomes a pull
request:

```sh
bazelisk run //scripts:dev-stack -- up          # create/start the isolated stack
bazelisk run //scripts:dev-stack -- status      # what is up, and whether the daemon answers
bazelisk run //scripts:dev-stack -- logs        # last 100 lines per service (--follow to follow, --tail <n> to shorten, service names to narrow)
bazelisk run //scripts:dev-stack -- down        # stop it, keep the volumes
bazelisk run //scripts:dev-stack -- reset       # stop it and destroy its volumes
```

`up`, `down`, `status`, `logs` and `reset` all take `--project-name`, default
`evo-t1-dev`. That name is the Compose **project name** — `docker-compose.yml`
declares no top-level `name:` key, so every call has to supply one, and it is what
namespaces the dev stack's volumes and networks away from the stable stack's. Host
ports are the other half of the isolation: they are `${VAR:-default}`
interpolations in `docker-compose.yml` (`CODER_HTTP_PORT`, `LITELLM_PORT`,
`KASM_UI_PORT`, `HOMEPAGE_HTTP_PORT`, …), so a dev run also needs its own env file
with different port numbers — `dev-stack` supplies that pair, project name plus env
file, to `docker compose`. `reset` is the one that destroys those
volumes, so it stops and asks for a confirmation first — without the confirmation
flag it does nothing.

`status` is read-only and reports the Docker provider's reachability instead of failing
when no daemon is reachable.

## Develop

Bazelisk is how changes are tested. The `make` shims call the same targets:
`make test`/`lint`/`fix`/`validate`, plus `make stack-up`/`stack-down`/`stack-status`/
`stack-logs`/`stack-reset` for the dev stack (each passes `PROJECT` as `--project-name`;
the flags and the `evo-t1-dev` default are above).

```sh
bazelisk test //:test-fast
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:validate
bazelisk run //:fix
```

`//:test-fast` is hermetic Bats plus two gates: every function under `scripts/` is named by a test, and every function has a `# @function` docstring. It does not build the golden image or start Compose. Conventions: [docs/project-conventions.md](docs/project-conventions.md). Bazel itself: [docs/contribute/building-with-bazel.md](docs/contribute/building-with-bazel.md).

## Ports

| Host port | Service | Purpose |
|---:|---|---|
| 80 / 443 | Homepage | Dashboard — 80 redirects to HTTPS (`HOMEPAGE_HTTP_PORT` / `HOMEPAGE_HTTPS_PORT`) |
| 8080 | Router | Plain-HTTP Host router for the public subdomains (`STACK_PROXY_HTTP_PORT`) — runs in both modes, Traefik is its only real client |
| 3001 | Coder | Web UI + control plane over TLS (`CODER_HTTP_PORT`) |
| 3002 | Coder | Second path to Coder's plain listener, for workspace agents via `host.docker.internal` (`CODER_AGENT_TUNNEL_PORT`) |
| 3000 | Kasm | First-boot install wizard (`KASM_WIZARD_PORT`) |
| 4443 | Kasm | Workspaces UI after install (`KASM_UI_PORT`) |
| 4000 | LiteLLM | OpenAI-compatible proxy (`LITELLM_PORT`) |
| 2112 (loopback) | Coder | Prometheus `/metrics` for the control plane (`CODER_METRICS_PORT`) — bound to 127.0.0.1, so point a scraper at it from the stack host |
| — | Homepage app | `3000` on the compose network only — reached through the proxy |
| — | Ollama | `11434` on the compose network only — deliberately not published |

## Public subdomains (optional)

Everything above is the default, LAN-only shape. One extra `.env` variable, `STACK_PUBLIC_HOSTS`
(comma-separated), additionally serves the same four services on public names over real TLS:

| Name | `proxy/router.conf` upstream |
|---|---|
| `gmktecbeast.overeazy.io` | `homepage:3000` |
| `coder-gmktecbeast.overeazy.io` | `coder:3000` — plain listener |
| `kasm-gmktecbeast.overeazy.io` | `https://kasm:4443` (`proxy_ssl_verify off`) |
| `litellm-gmktecbeast.overeazy.io` | `litellm:4000` |

Every name is **one label under the zone** and each service prefix is joined with a **hyphen**. A
wildcard certificate covers exactly one label, so the dotted two-label form (`coder.gmktecbeast.`) has
no certificate at the public edge: the browser aborts the handshake with
`ERR_SSL_VERSION_OR_CIPHER_MISMATCH` and Traefik never sees the request. Verified against this box —
`coder-gmktecbeast.overeazy.io` completes the handshake with the zone's `*.overeazy.io` cert, while
`coder.gmktecbeast.overeazy.io` fails with a TLS alert 40 and presents no certificate at all.

TLS terminates at the main Traefik on the other machine, which forwards plain HTTP to a second nginx
sidecar on this box: compose service `router`, published `${STACK_PROXY_HTTP_PORT:-8080}:8080`, config
`proxy/router.conf`. That container holds no certificate — its whole job is picking an upstream from
the Host header, and an unmatched Host gets `421` rather than a guess, so a mistyped or rewritten Host
fails loudly instead of landing in the wrong service. Kasm is the only hop that speaks TLS to its
origin, and verification is off there because the cert is the one its installer generates and reissues.
Nothing in this path replaces the LAN routes: `https://<lan-ip>/` still serves the dashboard on the
self-signed cert and `https://<lan-ip>:3001` still serves Coder's own TLS listener.

To enable it, set the four names in `.env`:

```text
STACK_PUBLIC_HOSTS=gmktecbeast.overeazy.io,coder-gmktecbeast.overeazy.io,kasm-gmktecbeast.overeazy.io,litellm-gmktecbeast.overeazy.io
```

and re-run:

```sh
bazelisk run //scripts:bootstrap
docker compose up -d
```

bootstrap then derives `STACK_DASHBOARD_URL` (compose feeds it to `HOMEPAGE_EXTERNAL_URL`, so NextAuth
builds its redirects and Secure cookie from the public origin) plus `STACK_CODER_URL` /
`STACK_KASM_URL` / `STACK_LITELLM_URL` (the card `href`s, so remote users get links they can resolve),
upgrades `CODER_ACCESS_URL` to the public coder URL, extends `HOMEPAGE_ALLOWED_HOSTS`
(homepage validates the incoming Host against that exact-match list, so an unlisted name fails its host
check), and issues the Coder cert with the public DNS SANs alongside the existing ones. The LAN cert
keeps working — in public mode the browser never sees that cert at all, since Traefik presents real
ones.

On the Traefik machine (this repo cannot verify any of it — check it there):

- A router per name pointing at `http://<this-box-lan-ip>:8080`.
- The original Host header preserved. Traefik rewriting the Host matches no server block here and the
  request comes back as `421`.
- Any authentication is the Traefik router's middleware: the sidecar forwards what it receives and
  authenticates nothing, so a name whose router skips the auth middleware reaches its container the same
  way the LAN does.
- DNS records for all four names, each one label deep. The three service names
  (`coder-`, `kasm-`, `litellm-gmktecbeast`) and the `gmktecbeast` apex resolve Cloudflare-proxied and
  complete the TLS handshake, verified from this box. A missing record shows up as a DNS error, and a
  Host that Traefik rewrote shows up as `421`.

**Authelia.** `https://gmktecbeast.overeazy.io/` and the three hyphenated service names 302 to
`https://authelia.overeazy.io/` — those zones already have an Authelia policy in front of them (checked
from here; the policy itself lives on the Traefik side). Coverage of a newly-named host is purely an
Authelia-side config choice; nothing here adds or requires a policy. Note what happens if you do put
LiteLLM behind it: LiteLLM authenticates from the `Authorization` header, and header-carried API traffic
cannot pass an interactive sign-in, so every client breaks unless Authelia exempts that host — either
leave `litellm-gmktecbeast` outside any policy or add an explicit bypass. Then `LITELLM_MASTER_KEY` is
the only credential in front of an endpoint that was a LAN-only proxy and is now reachable WAN-wide (see
SECURITY.md). Workspace agents never reach Authelia either way: the template rewrites the agent URL to
`http://host.docker.internal:3002`, the plain listener published via `CODER_AGENT_TUNNEL_PORT`, so agent
traffic stays on the box.

One runtime follow-up, done by hand once and not by compose: workspaces created before the public mode
existed need `bazelisk run //scripts:push-template` plus a restart to pick up the template's `coder_agent_url` variable
(default `http://host.docker.internal:3002`), which is what keeps agents dialing the local plain
listener whatever the access URL says. Kasm likewise stores its connection endpoints in its own setup
database (first-boot wizard / admin UI), so that endpoint has to be updated there too or streams keep
dialing the LAN address.

## LiteLLM model aliases

Workspaces and desktops always talk to one base URL — `http://host.docker.internal:4000/v1` with `LITELLM_MASTER_KEY` — and pick a model alias:

| Alias | Model | Backend | Structured tool calls |
|---|---|---|---|
| `agent` | `Qwen3.8-Flash-Next` | `SPARK1/2/3_OPENAI_URL` (TensorFold on :8888 — one deployment per Spark box, optional) | yes (measured) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |

**The Qwen2.5-Coder weights do not emit structured tool calls on this runtime.**
Measured against this box's IPEX-LLM Ollama (its bundled `ollama` 0.9.3): a request
with `tools` for `qwen2.5-coder:32b` and `:14b` comes back as plain text with
`finish_reason: "stop"` and no `tool_calls` field — the model writes the JSON call
into the message body, which no agent driver can consume. `qwen2.5:7b` on the same
runtime does return a real `tool_calls` array, so the limitation tracks the model,
and agent mode needs either the Spark `agent` lane or the small `chat` model. Grok
Build, Cline, Roo and Kilo therefore default to `agent`: one model group, one
deployment per Spark box, chosen among the healthy boxes by `least-busy` when
nothing is pinned (in-flight load). Above that picker, `session_affinity`
(`router_settings.optional_pre_call_checks`, LiteLLM 1.102.1) is on: one
conversation from one client sticks to the box that answered its first turn
while that box stays healthy (1 h idle pin TTL, refreshed by every request; a
conversation that goes quiet longer than the TTL may move), so a busy pinned
box sheds its own overflow in its own scheduler instead of queueing inside the
proxy. Traffic with no session id — Cline/Roo editor traffic, and Coder Agents
chats (Coder's aibridge forwards model calls with the provider key only and
adds no per-conversation session id) — floats across healthy boxes by load,
and a cooled or unhealthy pinned box hands traffic back to that same
least-busy picker.

When every Spark box is down, `router_settings.fallbacks` degrades `agent`
straight to `coder` (text-only), which keeps chat usable while agent mode quietly
loses its tools. That one hop — no chain through `agent-fast` anymore, because
one group already covers every reachable box — is the failure the dashboard's
**Agent backend** card exists to surface: its per-box widgets go to error state
while `agent` still answers, and each response's `x-litellm-model-id` header
names the deployment that answered (with a pin, the pinned box; without one,
whichever box least-busy picked).

Measured on a harness boot of this config against the two live boxes, before
`session_affinity` existed: that 30-request burst was multi-session
fan-out-style traffic and spread 12/10/8 across the three deployments,
returning 30x 200 — with no concurrency cap configured, the proxy neither
queued nor shed inside itself, and a fully offered box absorbed the overflow
in its own scheduler. A single conversation pinned to one box now keeps its
streams on that box while it stays healthy.

Edit aliases in `litellm/config.yaml`, then `docker compose restart litellm`. The two
tool-capable aliases also back the control-plane chat: `scripts/coder-agents.sh`
registers `agent` (default) and `chat` as the Coder Agents chat model configs, so an
alias edited or deleted here moves in the Agents model dropdowns exactly as it does in
the CLI.

## Coder workspace template

Two templates live under `templates/`, and the push covers both: `workspace` (the plain dev
container, `templates/workspace/`) goes first and `devcontainer` (the DinD-backed one,
`templates/devcontainer/`) last — a dependent template pushes last so a partial failure leaves
the base template usable. Each template dir keeps its own independent copy of the `.tftpl`
payloads; `templates/common/` exists once instead, and both templates consume it:
`GROK_BUILD_AGENTS.md` (the seed text the startup scripts inline) and `vscode-alt.svg` (the
editor icon) are staged by the push plumbing beside each staged `main.tf` copy and read back
there with `file()` / `filebase64()`, so a push missing either payload fails early by design.
It happens on its own: `bootstrap.sh` calls the same push, which
then pushes when the coder and db containers are running and an active Coder account exists,
and otherwise prints a one-line reason and exits 0 (a fresh clone has none of those yet).
The same command is the manual path after you register, and its arguments are the retry path
for a single template:

```sh
bazelisk run //scripts:push-template                      # both, in that order
bazelisk run //scripts:push-template -- devcontainer      # just the one that failed
```

An unknown name is an error that lists the known names, not a silent no-op. Per template
the script checks `main.tf`, notes a missing `.terraform.lock.hcl` (no lockfile is committed
under `templates/`; each `main.tf` pins `coder/coder` `~> 2.18` and `kreuzwerker/docker`
`~> 4.6` in its `required_providers` block, and Coder pushes with a warning when the
lockfile beside them is absent), refuses a preset description over Coder's 128-character limit, streams the
source, confirms an **active** version, and then re-sends the template's own
description — the routing hint the Coder Agents chat reads when it picks a template to
provision (`templates push` carries none, so `templates edit --description` is the
write; both texts fit the same 128-byte ceiling, and a failed description edit only
adds a note to the output, never blocks the template) — and re-pins **Autostop** to
*Disabled* with `--default-ttl 0 --activity-bump 0`, also on `templates edit` and also
advisory. A template whose push or that
verification failed is counted in the `N of M template(s) did not reach an active
version` line and makes the run exit non-zero, while every other template still gets
its push attempt.

**Everything Coder-facing runs inside the coder container**, against
`http://127.0.0.1:3000` — the server's own plain listener (`CODER_HTTP_ADDRESS`),
reached without crossing the reverse proxy, Authelia, or the WAN. That is deliberate:
`coder login` on the host must reach the API *before* it has a credential, and in
public mode the only URL it will use is `CODER_ACCESS_URL`, which Authelia gates. Its
first unauthenticated call — the first-user check — gets the HTML sign-in page back,
and the CLI reports that as `unexpected non-JSON response "text/html;
charset=utf-8"`. Loopback inside the container cannot be gated, so the push cannot fail
that way, and it runs the image's own `coder` binary, so client and server are the same
build. No host coder CLI and no `coder login` are involved.

For credentials the script mints a short-lived token by inserting a row into the
stack's own Postgres — the same trust model as `coder reset-password`, which also
bypasses the API and talks to the database directly. The token is scoped to minutes,
deleted on the way out (including on a failed or interrupted run), never printed, and
minted once for the whole run however many templates it covers.
Template source travels as a tar on stdin (`coder templates push --directory -`), so
nothing is copied into the container or its volumes; a push is also the only thing that
registers a template, because Coder stores the source as a Filestore row, not as files
it scans on disk.

It reads `.env` for the variables it passes: `--var image=` from `DEV_IMAGE`,
`--var litellm_key=` from `LITELLM_MASTER_KEY` (only when that key is real, never the
sample placeholder), `--var coder_agent_url` only if `.env` defines it at all,
`--var grok_profile_mode=` from `GROK_PROFILE_MODE` (a `.env` still carrying the older
true/false key maps onto it — `true` → `shared`, `false` → `private`), and
`--var repo_url=` from `REPO_URL` only when that key is present and non-empty (it
prefills the Git repository field on both create forms; `workspace` defaults to no
clone and `devcontainer` to the coder/coder demo repo, which is why a blank
`REPO_URL=` line stays unpassed). Nothing else about GitHub travels in a `--var`: there is
no GitHub-token template variable, so no push ever carries a personal access token. A
workspace's GitHub credential comes from the external-auth broker, which is configured once
in `coder.env` and linked to both templates (see the credential note below). Then, per
template, it confirms an **active** template version — a push can exit 0 and still leave the
template inactive if its Terraform run failed, which shows up as the template missing from
the create dropdown. The equivalent raw command — what the script does for each template,
shown here for `workspace` alone, for reference or for pushing a tag `.env` does not carry
(the repo is not mounted into the container, so the directory has to
travel as a tar; `CODER_SESSION_TOKEN` is any token from the Coder **Tokens** page or
`coder tokens create`):

```sh
tar -C templates/workspace --exclude=./.terraform -cf - . | \
  docker compose exec -T -i \
    -e CODER_URL=http://127.0.0.1:3000 -e CODER_SESSION_TOKEN \
    coder coder templates push workspace --directory - --yes \
    --var image=evo-t1-dev:latest
```

The service appears twice by necessity: the first `coder` selects the compose service,
the second is the CLI binary inside it.

`coder templates` is the canonical name (`template` is its alias). Build
`evo-t1-dev:latest` first with `bazelisk run //scripts:build-dev-image` — the docker provider
resolves that name from the local image store and never attempts a registry pull,
which is what keeps workspace creation working with no internet.

The create form shows a **Workspace image** dropdown, a **Docker-in-docker** Yes/No
question, a **Git repository** input (`repo_url`, default empty, mutable — anything you
type is cloned into the workspace on the next start; see below), three Grok fields —
**Grok profile** (`grok_profile_mode`, default `shared`, immutable: `private` gives that
one workspace a private `~/.grok` on its own home volume, so a single workspace can sit
outside the shared profile while its siblings stay inside it, and switching needs a
rebuild), **Grok default model** (`grok_default_model`, one of the four LiteLLM aliases,
default `agent`) and **Grok config extras** (`grok_config_extra`, default empty, a
textarea; whatever you type is appended verbatim under a comment header into that
workspace's rendered `~/.grok/config.toml`, which is only observably per-workspace while
the profile mode is `private` — one shared profile is one file for every workspace that
owner owns and the last boot to re-render it wins) — and three presets: *AI workspace*
(golden image, selected by default), *Minimal shell* (bare Ubuntu, for when the
golden image is mid-rebuild), and *AI workspace + DinD* (golden image plus a
privileged Docker daemon, below). `--var image=` seeds the dropdown's default and is also
injected as its own option, so a custom tag still reaches the container while the form
stays honest about what it is building.

The template (`templates/workspace/`) creates one Docker container per workspace:

- the golden image from `images/dev/Dockerfile` (override with the `image`
  variable) — Node 22 + 24, Python 3.12 + 3.11, Go 1.24, Bazelisk/buildifier,
  Terraform/tflint/terragrunt, protoc and its Go plugins, kubectl/helm/kubeconform,
  shfmt/shellcheck/bats/ruff/mypy/prettier, the Coder CLI, the Docker **client**
  toolchain (`docker`, `docker buildx`, `docker compose` as CLI plugins under
  `/usr/local/lib/docker/cli-plugins` — no daemon: the build asserts `dockerd`,
  `containerd`, `runc` and `docker-proxy` are absent), the five MCP servers
  pre-baked next to the pinned Grok Build CLI (`/usr/local/bin/grok`), so a
  workspace needs no network to start a session
- persistent per-workspace home volume
- `host.docker.internal` → host-gateway, so workspaces reach the Coder server and LiteLLM
- a startup script that ensures the **Grok Build CLI** is on PATH — the golden
  image ships it, and the script's `https://x.ai/cli/install.sh` download runs
  only where `grok` is missing from PATH (the `ubuntu:24.04` image option, or a
  home volume that never received the CLI). It also puts `~/.grok/bin` on PATH,
  seeds the two terminal-profile tmux helpers, **clones a non-empty Git repository
  field** into `/home/coder/workspace/<repo-name>` (idempotent; runs as the
  workspace user so their git credentials are consulted; refuses to touch an
  existing non-git folder there), renders `~/.grok/config.toml`, and
  warms the MCP servers in the background. GitHub credentials arrive by one path only,
  opt-in and HTTPS-only (an `ssh://`/`git@` URL reaches nothing here — this
  stack provisions no SSH keys): Coder's external-auth broker, provider id
  `primary-github`. Create `coder.env` beside `docker-compose.yml` with the
  `CODER_EXTERNAL_AUTH_0_*` keys all filled (see `.env.example`; a defined-but-empty key
  crash-loops the server, which is why these keys live in `coder.env` and not `.env`),
  link that provider to **both** templates, then connect your GitHub account under
  Settings → Tokens / external auth, and every workspace's agent injects a
  `GIT_ASKPASS` helper that mints short-lived per-host tokens on demand, alongside a
  `GH_TOKEN`/`GITHUB_TOKEN` pair in the agent environment that the template's
  `gh_token_refresh` `coder_script` re-mints on start and every 6 hours. Nothing
  long-lived lives in any file, env or template, one connection covers every workspace,
  and `gh auth status` inside a workspace is how you check it landed. The same
  `~/.gitconfig` seeding now reads that environment: an idempotent
  `credential.https://github.com.helper = !gh auth git-credential` entry lets `git push`,
  `gh pr create` and `gh api` authenticate from the minted token rather than from a
  token stored in a file. `scripts/github-auth.sh` adds the per-workspace doctor:
  `check` names the credential each running workspace would present and says
  whether it is granted on the repo you point it at; `auth <container> - < PAT`
  installs a write-capable PAT into that workspace's gh auth store — the only
  credential for a workspace whose owner connected no account, and while an
  account is connected the next `gh_token_refresh` run rewrites that store with
  a minted pair (`gh auth logout`, or a rebuild, clears it either way).
  The `settings.json.tftpl` seed is copied once, the first time
  `~/.shared/vscode/settings.json` is missing, onto the per-owner volume
  `vscode-settings-<owner-id>`. code-server's User settings file is a symlink to
  that path, so every workspace that owner has opens the same file, and an edit
  (in any workspace, or from the host by mounting the volume) is not overwritten
  on the next start. Delete the file to reseed from the template. A built dev
  container sees neither the volume nor that symlink, so it is the one place the
  seed is merged instead of linked (see the code-server note below).
- `startup_script_behavior = "blocking"`, so a workspace only reports *ready* once the
  toolchain is genuinely staged — no opening an editor mid-install
- agent-bar buttons via `display_apps` (VS Code Desktop helper: a locally installed
  VS Code / Cursor / Windsurf plus the `coder.coder-remote` extension;
  port forwarding; SSH helper), a separate in-browser **code-server** editor
  (Coder's VS Code fork; no local VS Code), labelled **VS Code Web** with `order = 5`
  so it sorts before the LiteLLM and Coder UI buttons and reads apart from the
  **VS Code Desktop** helper (static helper buttons have no order/icon knobs in this
  Coder release — custom apps are ordered among themselves), a custom **Web Terminal**
  command-app (`order = 6`) for the terminal slot (section "Terminal defaults: tmux
  re-attach and Grok Build" below), memory and disk usage gauges, six `coder stat`
  metadata tiles, and a **LiteLLM** tile that health-checks the proxy and is visible
  only to the workspace owner
- Neither template installs code-server through the Registry. Each `main.tf` carries an
  inlined fork (`coder_script.code_server` + `coder_app.code_server`), because that
  upstream module hardcodes `/icon/code.svg` and has no icon input. The `workspace` fork
  installs code-server only when it is missing from `/home/coder/.local/share/code-server`
  and starts it with `--auth none --port 13337 --app-name "VS Code Web"`, passing no
  settings payload: the editor's settings live on the per-owner
  `vscode-settings-<owner-id>` volume seed, not in a per-start merge. The `devcontainer`
  fork has no persistent prefix to reuse - both toggle modes rebuild the container that
  hosts the editor - so it installs fresh under `/tmp/code-server` on every start. Both
  twins' `coder_app` opens on `http://localhost:13337/?folder=<urlencoded>` (the
  `coder_app` resource in `coder/coder` `~> 2.18` has no `folder` argument, so the
  folder rides in the URL), and the custom icon
  `templates/common/vscode-alt.svg` travels as a `data:image/svg+xml;base64` data URL
  read from `templates/common/` - Coder serves icons only from its bundled `/icon/*`
  set or a full `https`/`data` URL, and that icon is not bundled.
- `coder_metadata.workspace_info` shows the image, the cloned repository (or `none`
  when the Git repository field is empty), the LiteLLM URL, the default Grok
  model, whether DinD is `on (tcp://dind:2375)` or `off`, and (redacted) which key is
  wired in, so a misconfigured workspace is visible in the UI without shell access

Template variables: `image` (seeds the **Workspace image** dropdown default),
`litellm_url` (default `http://host.docker.internal:4000/v1`),
`litellm_key` (sensitive — pass the LiteLLM master key when creating a workspace),
`grok_default_model` (default `agent`; the tool-capable Spark lane — it is also a
per-workspace **Grok default model** dropdown on the create form, whose options are the
four aliases `agent`, `coder`, `coder-fast` and `chat` (each Spark box is a
deployment inside `agent`), plus a custom entry when the variable names another one), `docker_socket`
(optional), `coder_agent_url` (default `http://host.docker.internal:3002` — the URL the agent
dials, kept on the local plain listener so a public `CODER_ACCESS_URL` does not hairpin agent
traffic through the reverse proxy; empty keeps the provider-rendered access URL),
`dind` (default `false`; turns on the per-workspace privileged daemon described below),
`repo_url` (default `""` on `workspace`, `https://github.com/coder/coder` on
`devcontainer`; prefills the create form's **Git repository** field — both
templates clone that URL into the workspace on the first start (a later start leaves a
folder that already holds a `.git` alone, so re-fetching is your call), and `REPO_URL`
in `.env` overrides the default),
`additional_repos` (default empty; the **Git repositories (additional)** textarea under
the repository field — extra URLs cloned into their own folder beside `repo_url`; see
"Cloning more than one repository" below, which also shows the `--additional-repos`
form of `bazelisk run //scripts:new-workspace`),
`grok_profile_mode` (default `shared`; `shared` mounts the owner's shared `~/.grok`
profile volume, `private` gives that workspace a private `~/.grok` on its own home
volume — see "Grok Build state: one shared profile per user"). It is also the default
behind the create form's per-workspace **Grok profile** dropdown, and switching a live
workspace between the two modes needs a rebuild),
`github_mcp` (default `false`; wires the `github` MCP HTTP server into Grok's rendered
`config.toml`. Its `Authorization` header names `$GH_TOKEN` and nothing else, so no
token value is ever part of a template variable: the token arrives from the
`primary-github` External Auth provider at run time, and an owner who connected no
GitHub account gains a server that fails its handshake), and
`grok_config_extra` (default empty; the create form's **Grok config extras** textarea —
free-form TOML appended verbatim, under a comment header, to that workspace's rendered
`~/.grok/config.toml`).

**Docker-in-docker (opt-in).** The create form's **Docker-in-docker** Yes/No question
(preset *AI workspace + DinD*, template variable `dind`) provisions, per workspace, a
privileged `docker:29.8.1-dind` sidecar on a bridge network private to that workspace
(`coder-<wsid>-dind`, network alias `dind`), attaches the workspace to both `bridge` and
that network, and injects `DOCKER_HOST=tcp://dind:2375` into the agent
environment — absent when the toggle is off, so `docker` there fails the normal way
rather than against a daemon that does not exist. Then `docker build`, `docker run` and
`docker compose` work inside the workspace — the *AI workspace + DinD* preset is the
usual way to get this shape, since the client binaries ship only in the golden image.
Details that matter:

- The toggle is `mutable = false`: turning it on or off means a workspace **rebuild**,
  because a network, a volume and a second container appear or vanish. The preset makes
  that one click.
- The daemon's `/var/lib/docker` lives on its own volume (`coder-<wsid>-dind-lib`), so a
  workspace stop/start does not re-pull every image the builds used.
- `DOCKER_TLS_CERTDIR=` is deliberately empty, so the daemon serves plain
  `tcp://0.0.0.0:2375` with no TLS and no auth. Nothing is published to the host, and
  2375 is reachable only from that workspace's own network — which is also why the
  network is not `internal`: an internal network has no NAT and would break
  `host.docker.internal`, stranding the agent. See SECURITY.md.
- The daemon image is resolved with `data "docker_image"`, which inspects the host store
  and **never pulls**, so `docker:29.8.1-dind` must already be there. `bootstrap.sh`
  pre-arms it; manually: `docker pull docker:29.8.1-dind`. A missing image fails the
  workspace build at **plan** time, before anything is created (see "Troubleshooting").
- `DOCKER_CLI_VERSION` in `images/dev/tool-versions.env` and the `docker:29.8.1-dind` tag
  in `templates/workspace/main.tf` and `templates/devcontainer/main.tf` are the
  same engine line; bump all three together.

The second template (`templates/devcontainer/`) is that *AI workspace + DinD* shape,
always on, plus a repository that brings its own toolchain:

- one workspace container from the golden image — launcher and clone target only, though it
  still has to be the golden image because that is what ships the docker client the
  devcontainer flow talks through. The editor's real environment is whatever the repo
  builds, so `image` decides nothing about the toolchain inside it
- an always-on privileged `docker:29.8.1-dind` sidecar on a per-workspace bridge network
  (`coder-<wsid>-dind`, alias `dind`), with `DOCKER_HOST=tcp://dind:2375` injected
  unconditionally and `DOCKER_TLS_CERTDIR=` empty for the reasons above — and `internal`
  left false for the same one, or `host.docker.internal` resolves but never answers and the
  agent strands
- one host bind, `/srv/coder-devcontainers/<workspace-id>`, mounted at that *identical* path
  in both containers. The path has to match because the devcontainer CLI always bind-mounts
  the workspace folder into the dev container it creates, and a bind source is resolved by
  the daemon that runs that container — the sidecar, not the workspace's — so a clone the
  sidecar cannot see fails with `bind source path does not exist`. Named volumes cannot
  substitute: a volume is a daemon-local object and does not cross to the sidecar's daemon.
  Docker creates the missing host directory itself and `startup.sh.tftpl` chowns it.
  Inside a built dev container the same folder appears under `/workspaces/<repo-name>` —
  that is the devcontainer CLI's default mount target, and where the dev-container editor
  opens. `main.tf` therefore spells the editor's `folder` per hosting environment
  (`local.editor_folder`): `/workspaces/<repo-name>` inside the dev container,
  `/srv/coder-devcontainers/<workspace-id>/<repo-name>` on the plain container, and
  `/home/coder` when no repository was named. One host-side path for all three would
  open the editor on a folder that exists nowhere the editor runs — VS Code answers
  that with "Workspace does not exist. Please select another workspace to open."
- the create form asks two questions — **Git repository** (`repo_url`, mutable — switching
  repository is a re-clone plus a devcontainer build, not a new topology the way
  `workspace`'s DinD toggle is) and **Build repo's dev container** (`use_devcontainer`,
  a Yes/No radio, immutable — building a dev container or not is a different topology:
  with Yes the editor lives in the dev container, with No in the plain container, and
  the workspace presets *Devcontainer default* and *Plain clone* make each one a
  one-click workspace on the template's default repository) — and carries the same three
  Grok fields as `workspace` (**Grok profile**, **Grok default model**, **Grok config
  extras**), since this template mounts the profile volume and renders `config.toml` the
  same way. The mount covers the workspace container; a dev container built on the
  sidecar keeps its own home either way. A repository that ships no
  `devcontainer.json` gets no dev container and hence no editor with the toggle on;
  the toggle (or `bazelisk run //scripts:new-workspace -- <git-url>`, which reads the
  repository and picks for you) is how that case is meant to be handled
- `startup.sh.tftpl` clones the repo onto that bind in **both** toggle modes, and with
  the toggle on `coder_devcontainer` then builds the repo's own
  `.devcontainer/devcontainer.json` on the sidecar through the Coder agent
  (`@devcontainers/cli` is in the parent workspace container), which exposes the
  dev container as a sub-agent with its own terminal and apps. The in-browser editor
  attaches to that sub-agent, so it runs inside the dev container where the cloned
  repo's toolchain lives; with the toggle off — or on a repo that carries no
  devcontainer.json, where the build has nothing to build — it attaches to the plain
  workspace agent instead, opened on the same clone path. Either way `folder` is the
  clone, so code-server and its terminal profiles land on the repository, and the
  agent-bar **Web Terminal** button `cd`s there too. No `config_path` is set, so the
  CLI discovers the file the way VS Code does and a repo using the other legal
  locations behaves the same.

It reuses `workspace`'s variables (`repo_url` exists in both templates; `dind` does
not exist here — the sidecar is not optional here, a devcontainer workspace without a
daemon is nothing, and the plain-clone fallback still wants a daemon its `docker`
commands can reach), and carries its own copies of
`startup.sh.tftpl`, `settings.json.tftpl` (the shared editor-settings seed,
copied once onto the per-owner `vscode-settings-<owner-id>` volume and linked
from code-server's User settings; a built dev container mounts neither, so with
**Build repo's dev container** on the inlined `coder_script.code_server` fork
bakes that seed as base64 and merges it into the dev container's private User
settings copy) and
`grok-config.toml.tftpl`, so the tmux-default
terminal and LiteLLM wiring above apply to it too. **Treat the repository as untrusted
code**: everything it builds runs on a privileged daemon on this box, so a Dockerfile in
that repo is root-equivalent on the stack host — the create form's own description says so,
and only repositories you trust belong in the field.

### From a git URL: `bazelisk run //scripts:new-workspace`

The two questions above (which template, and whether to build the dev container) are
exactly what `bazelisk run //scripts:new-workspace -- <git-url> [name]` answers for you:

```sh
# every line is a whole command; `--` ends Bazel's own flags, so a URL that begins
# with a dash still reaches the script
bazelisk run //scripts:new-workspace -- --dry-run https://github.com/foo/bar.git    # decision only, creates nothing
bazelisk run //scripts:new-workspace -- https://github.com/foo/bar.git              # creates the workspace
bazelisk run //scripts:new-workspace -- --plain git@git.example.com:org/private.git # force the workspace template
bazelisk run //scripts:new-workspace -- --additional-repos "url1,url2" https://github.com/foo/bar.git
```

It shallow-clones the repo into a temp dir (a plain `git clone` from the host, so
it consults the host's own git credentials — a private repo therefore needs a
grant covering it on the machine you run this from), greps the
file listing for a dev container (`.devcontainer/`, `.github/devcontainers/`, or a
`devcontainer.json`/`.yml` anywhere in the tree), and picks `devcontainer` when
it finds one, `workspace` when it does not — the probe failing entirely is also a
`workspace` answer (with a warning). It then assembles `coder create` with the
template's parameters — `repo_url=<url>` always, `use_devcontainer=false` whenever
`devcontainer` was chosen but no dev container was found (forced with
`--devcontainer` onto a repo that has none, or a probe that could not check the repo —
the cases where leaving the toggle at its default would build nothing anyway),
`dind=true` on `--dind`, and `additional_repos=<comma-separated list>` whenever
`--additional-repos` named at least one extra URL (see *Cloning more than one
repository*) — and no `--stop-after`, so a script-made workspace gets no autostop
deadline. It either runs the command (`--no-wait`; watch with `coder ls` /
`coder logs <name>`) or, with no usable `coder` login, prints the same command to run by
hand and exits 0.
`--devcontainer` forces the devcontainer template, `--template <name>` overrides the
template choice outright, and a workspace name can follow the URL (Coder names
start with a letter; the derived default is the repo leaf). It never mints, reads, or
stores a token — unlike `push-template.sh`, which mints its own because a template
push has no other credential path.

Autostart, autostop and TTLs are template *metadata*, so they stay out of the Terraform
(where they would fight the UI) and travel on the CLI after pushing. **Autostop is
disabled by default.** Coder reads the template's **Default autostop** (its default TTL)
when it seeds a workspace — that field also decides whether the create form's **Enable
Autostop** arrives ticked — and it ships at 24 h, which is how a workspace would
otherwise start with a shutdown deadline nobody chose. A 0 default TTL leaves the
checkbox unchecked and leaves `coder create` with nothing to inherit, so a workspace runs
until its owner stops it. `--activity-bump` goes to `0` with it: a bump only extends a
deadline, and with no deadline there is nothing to extend. `push-template.sh` re-sends
both after every push, and `new-workspace.sh` names no `--stop-after`.

A workspace owner can still tick the box for one workspace: `allow_user_autostop` stays
on, because Community Edition has no switch for it.

```sh
export CODER_URL=http://127.0.0.1:3000 CODER_SESSION_TOKEN=<your-token>
docker compose exec -T -e CODER_URL -e CODER_SESSION_TOKEN coder \
  coder templates edit workspace \
    --default-ttl 0 \
    --activity-bump 0
```

Check it in the Coder UI: the template editor's **Default autostop** reads *Disabled*
(0 h) and a workspace's **Schedule** tab shows **Enable Autostop** unchecked.

`--failure-ttl` and `--allow-user-autostart=false` are rejected without a license
(the server names `--failure-ttl`, `--inactivityTTL`, `--allow-user-autostart=false`
and `--allow-user-autostop=false`), so leave them out of the CE stack.

## Cloning more than one repository

One repository per workspace is the default, and that is what `repo_url` and the create
form's **Git repository** field mean: one URL, cloned into one folder, and that folder is
what code-server, the Web Terminal button and the Grok Build session open on (inside a
dev container, code-server sees that same folder under its mount target,
`/workspaces/<repo-name>`). Keep it
that way unless a workspace genuinely needs two trees open at once.

`--additional-repos` is the opt-in escape hatch for the service-and-the-library-it-uses
case. It takes a comma-separated list — `"url1,url2"`, one URL per line works too, and
the spaces around each entry are trimmed — and joins it into one `additional_repos`
parameter, so `"a , b"` and `"a\nb"` both arrive in the template as `a,b`. Without the
flag the script passes exactly the parameters it used to pass and the create form's
**Git repositories (additional)** textarea stays empty:

```sh
bazelisk run //scripts:new-workspace -- --additional-repos "https://github.com/foo/lib.git,https://github.com/foo/tool.git" https://github.com/foo/bar.git
```

The extras are cloned **beside** the primary repository, into sibling folders, by the same
clone-once rule as the primary one (a folder that already holds a `.git` is left alone on
later starts, never pulled on): `workspace` keeps the clone tree under
`/home/coder/workspace/<repo-name>`, and
`devcontainer` under `/srv/coder-devcontainers/<workspace-id>/<repo-name>`. An extra
folder never becomes the folder the tools open on — the editor, the Web Terminal button
and the tmux helpers all stay on the primary clone — and a private extra repository
still has to be GRANTED to the connected GitHub account, or its clone is refused, just
like the primary one. `--dry-run` prints the list under `also:` before it creates
anything, so the decision is readable first.

## Terminal defaults: tmux re-attach and Grok Build

New Coder workspaces open a terminal that **re-attaches to a tmux session**:

- `terminal.integrated.defaultProfile.linux` is `"tmux"`; the automation profile stays `bash` (so build/tasks commands never wait on tmux), and plain `bash` and **Grok Build** remain available as extra profiles.
- The `tmux` profile re-joins (or starts) one shared session per folder — `vscode-<folder>-<hash>` — so a second terminal window, a browser reload, or `ssh` + `tmux attach -t <session>` from any client lands in the same session, and long jobs survive closing the tab. **Grok Build** keeps its own session: the helper first walks up from the terminal's folder to the repository root (`git rev-parse --show-toplevel`, falling back to the terminal's own `$PWD` outside a clone), and the session — `grok-build-<folder>-<hash>`, keyed off that root — runs `grok --cwd <repo root>` inside it. A terminal opened anywhere inside the clone therefore rejoins the one session the whole repository shares, and `grok` starts in the repository, not in the subfolder. `tmux ls` lists the names, `tmux attach -t <session>` re-joins from any other terminal.
- If tmux is absent (offline first boot), the helper execs a plain login shell, so the default terminal still opens. The agent-bar **Web Terminal** button is separate from all of this: `display_apps.web_terminal` is off (it would open a shell on the agent's working dir, which is `/home/coder` here), and a custom command-type `coder_app` named **Web Terminal** takes its slot: it `cd`s to the clone folder (empty `repo_url` keeps it on `/home/coder`) and execs a login shell, so the terminal outside the editor starts inside the project too. Like the built-in it reads no `terminal.integrated.*` settings.
- The golden image ships the Grok CLI at `/usr/local/bin/grok` (with an `agent`
  link beside it), pinned as `GROK_VERSION` in `images/dev/tool-versions.env` and
  deliberately OUTSIDE the home volume, so a rebuilt volume cannot lose it. The
  startup script probes `command -v grok` on every start and re-downloads from
  `https://x.ai/cli/install.sh` — bounded, with retries — only while `grok` is
  missing from PATH. A self-installed CLI under `~/.grok/bin` wins over the
  baked copy on the login-shell PATH.
- The startup script renders `~/.grok/config.toml` from
  `templates/workspace/grok-config.toml.tftpl` (and `templates/devcontainer/`'s own
  copy of the same payload): `[models] default` points at the
  `grok_default_model` alias (`agent` unless the template variable or the create form's
  **Grok default model** dropdown names another), the four aliases are defined with
  `base_url` set to `litellm_url` and `env_key = "LITELLM_API_KEY"` (the key is
  injected as an environment variable, so it never appears in a file), and the MCP
  servers, `[features]`, `[permission]` deny rules and `web_fetch` policy are set.
  `[models]` additionally carries `extra_headers` with the workspace's
  `x-litellm-session-id: ws-<workspace-id>` affinity key, which is what makes
  LiteLLM pin the workspace's traffic to one healthy Spark box; in `shared`
  profile mode the last-booted workspace's key wins for the whole fleet (same
  last-boot-wins caveat as default model and extras).
  `github_mcp` adds the `github` HTTP server (`https://api.githubcopilot.com/mcp/`,
  whose `Authorization` header references `${GH_TOKEN}` by name) to that same file, and
  `grok_config_extra` appends whatever the create form's **Grok config extras** field
  holds, under its own comment header. It is re-rendered idempotently and
  leaves a hand-edited config alone — the managed block is guarded by a
  `managed-by: evo-t1-coder-stack` marker.
- **Search lane:** `searxng` (SearXNG metasearch, host port 8181) is the search
  backend the stack runs for itself. It is not a model transport: `[models]
  web_search = "agent"` and `supports_backend_search = false` stay as they were, so the
  agent's own `web_search` tool still digests through the `agent` alias. Handing SearXNG
  to the agent as an MCP stdio server is a separate change, gated on what the probe
  measures. Run `bazelisk run //scripts:search-check` to see which engines answer from
  this box and with how many results (an empty result page and "no answer" are
  different answers, which is why the probe says which one it got).
- **MCP servers**: `filesystem`, `memory`, `sequential-thinking`, `git` and `time`,
  all pre-installed in the image (`npm -g` for the first three, `uv tool` for the
  Python two), and warmed at workspace startup so the first session does not pay the
  cold-start cost. Check them with `grok mcp doctor` inside a workspace. The `github`
  server is the opt-in exception: it needs a token and outbound network, so
  `github_mcp` (off by default) decides on its own whether the block is rendered, and
  its `Authorization` header names `$GH_TOKEN` — the agent environment fills that from
  the `primary-github` external-auth connection, so a workspace whose owner connected no
  account renders the block and pays one failed handshake per session.
- Cline and Roo/Kilo are pre-wired to the LiteLLM proxy (endpoint from
  `litellm_url`, default `http://host.docker.internal:4000/v1`, model alias `agent`,
  with `coder`/`coder-fast`/`chat` listed in `__evoT1StackModels`). The seed is
  `settings.json.tftpl`. It is copied onto the per-owner volume
  `vscode-settings-<owner-id>`, mounted at `~/.shared/vscode/settings.json`, only
  while that file is absent, and `~/.local/share/code-server/User/settings.json`
  is a symlink to it. Edits stick, and every workspace that owner has shares the
  file. Delete it to copy the template in again on the next start. From the host,
  the same file is the volume's `settings.json` (`docker run --rm -it -v vscode-settings-<owner-id>:/vscode alpine vi /vscode/settings.json`). The owner id is
  the workspace owner's. The git seed contains no API key and no desktop paths;
  when `LITELLM_API_KEY` is set the startup script writes it into the seed once,
  because Cline and Roo read the key from settings and have no environment-key
  field. Nothing is written to `~/.config/Code`. Only the dev-container build
  merges settings on every start, and only because it has no other way to see the
  seed: the inlined `coder_script.code_server` fork in `templates/devcontainer/main.tf`
  bakes a base64 copy of it and writes it over the dev container's private
  `User/settings.json`, or merges over a copy that survived a rebuild when `jq` is
  on PATH (without `jq` the existing file is kept). That container never mounts
  the shared volume, so a built dev container always starts from a fresh merged
  copy: edits inside it do not survive a rebuild and do not update the shared
  file. Everywhere else — the `workspace` template, and the `devcontainer`
  template with **Build repo's dev container** off — no settings map is passed
  at all, because a merge would replace the symlink.
  Installing Cline, Roo, the Red Hat YAML extension, and Material Icon Theme is a
  manual step in the Extensions panel (Open VSX by default). If an extension
  build names its settings differently, set the OpenAI-compatible endpoint and
  key in its UI.

## Grok Build state: one shared profile per user

Every workspace still gets its own `/home/coder` volume, and `~/.grok` is now a
**second, nested** mount inside it: a Docker volume named `grok-profile-<owner-id>`,
referenced by name rather than declared as a Terraform resource, that every workspace
belonging to that user mounts read-write at the same path **while that workspace is in
`shared` mode** (the default here, so a workspace gets it unless you turn the mode off).
Configure the CLI once and the rest of that account's workspaces inherit it.

- **What is shared:** in `shared` mode, `config.toml`, `skills/`, `memory-v2/`, `sessions/`, the warmed MCP
  caches, and a CLI you installed yourself under `~/.grok/bin`. In `private` mode that same
  list lives on the workspace's own home volume and belongs to that workspace alone.
- **Why:** the model catalog, the MCP servers and any skill get set up once. A `/learn`
  run or a hand-added skill written in one workspace is immediately visible in that user's
  other workspaces, and a rebuilt or recreated workspace starts on the existing profile
  instead of an empty one.
- **Two modes:** the mount is mode-gated, twice over. The template variable
  `grok_profile_mode` (default `shared`) picks the default for the template, and the create
  form's **Grok profile** field repeats that choice per workspace, defaulting to the
  variable — so one workspace can sit outside the shared profile while its siblings stay in
  it. `shared` is today's behaviour (one volume per owner); `private` mounts nothing, so
  that workspace's `~/.grok` — `config.toml` included — lives on its own home volume,
  differs from its siblings, and dies with the workspace, or survives a rebuild on the same
  volume. Changing the mode needs a rebuild, because the nested mount either exists or it
  does not, and a workspace that goes from `shared` to `private` starts on an empty
  profile: nothing is copied, and the shared volume is left alone. A per-workspace
  `config.toml` is what makes that difference mean anything — on a shared profile there is
  only one file for all of that owner's workspaces, and the last boot to re-render it wins.
- **Per-user privacy:** in `shared` mode, one volume per workspace **owner**, keyed by
  owner id — never host-wide and never cross-user. Another user's workspace has no mount
  that points at it, because its own profile volume carries a different name. A workspace
  in `private` mode shares nothing with anyone: its `~/.grok` is on its own volume only.
- **Caveats, honestly:** the memory and index files in there are SQLite and are opened
  live by every workspace holding the mount, so two workspaces writing memory at the same
  time can race — *roughly in sync* is the bar, not transactional sharing. A stop or start
  of a **different user's** workspace never sees the volume; it is keyed to the owner, not
  to the workspace. And the mode knob has two settings and two places: the template
  variable `grok_profile_mode` (`GROK_PROFILE_MODE=shared|private` in `.env`, which
  `scripts/push-template.sh` forwards as `--var grok_profile_mode`, or hand that `--var`
  to your own push) and the create form's **Grok profile** field for one workspace. Either
  way, switching needs a re-push or an edit plus a rebuild, and a workspace that goes to
  `private` starts on an empty `~/.grok`.

## Coder Agents (control-plane) + Grok Build delegation

**What this is.** Coder v2.36.6 ships *Coder Agents*: a coding agent that lives in the
Coder **server** — a chat UI and an API beside your workspaces, not inside one. A chat
runs its tools (`read_file`, `edit_files`, `execute`, `spawn_agent`) against a workspace
over that workspace's agent connection, and it consults two pieces of per-workspace
context first: an **instructions** file and any **skills** it discovers. This stack wires
that up (and teaches it, below); the agent itself is upstream Coder, not a home-grown
agent.

**Always on; nothing to enable.** The chat agent is compiled into coderd
unconditionally. `CODER_EXPERIMENTS` in `.env` (empty by default since 2026-10-08)
has never gated anything about it — the old `agents` default was not a recognized
experiment name, and the server just logged `ignoring unknown experiment` and ignored
it on every boot. `workspace_external_agent`, the entitlement the docs name, gates
*external* agents (Claude Code, Codex, …), not this one; nothing in this stack needs
it. If you know a real experiment you want (`chat-advisor`, `chat-virtual-desktop`, …),
list it in `.env` and restart the coder service; empty (the default) means no
experiments on.

**Model wiring (scripted, idempotent, re-runnable).** A chat turn needs an enabled
chat model config — the chat's own pick, else the deployment default, else it errors
before the first tool call — and that wiring is scripted:
`bazelisk run //scripts:coder-agents -- --apply`
(bootstrap calls it, quick start step 3 repeats it by hand; add `-- --dry-run` to print the
plan). It mints a short-lived admin API token straight from the stack's Postgres,
deleted on exit, the same trick `push-template.sh` uses, then drives the server's
experimental chat API (`/api/experimental` — v2.36.6 keeps the chat-model surface
there, with no stability guarantee, by design): an `openai-compat` AI provider named
`litellm`, base URL `http://litellm:4000/v1` — LiteLLM over the compose network,
*server-side*, authenticated with the `LITELLM_MASTER_KEY` value from `.env` (or the
`change-me-litellm` placeholder while `.env` leaves the key empty) — created when
absent, drift-patched when one exists with a drifted `base_url` or key; model
configs `agent` (context limit 262144, set as default) and `chat` (32768) for models
not already registered; pins for the four auxiliary lanes — `general`/`explore` take
`agent` and `compaction`/`title_generation` take `chat`, each falling back to the
other alias — written only for lanes that carry no pin, so an admin's own pins stay
in place; and a three-line system-prompt addendum, appended after Coder's default
prompt text (`include_default_system_prompt: true`), telling the agent to delegate
multi-file work through the grok-build-delegation skill and to never echo
`$LITELLM_API_KEY`/`$GH_TOKEN`/`$GITHUB_TOKEN`. Coder's optional AI Gateway proxy
stays off — LiteLLM remains the model transport, which is why no AI-Gateway keys
exist in `docker-compose.yml`.

**The delegation sketch.** Chat on the Agents page → if the ask needs more tooling than
chat has, Coder Agents provisions or uses a workspace through `execute` → big multi-file
tasks are *delegated inside* that workspace: a headless Grok Build CLI run, started
backgrounded and polled (`grok -p "<task brief with acceptance criteria>" --cwd <repo>
--permission-mode acceptEdits --max-turns <budget>`) → Coder Agents then reviews the
delegated diff, runs the project's tests, and commits. Subagents spawned by Coder
Agents cannot create workspaces — provisioning decisions stop at the top-level chat.

**What equips it.** Four context files seed into every new workspace, on first boot and
only while the file is absent: `~/.coder/AGENTS.md` and
`~/.coder/skills/grok-build-delegation/SKILL.md` — the Coder agent's *default* discovery
paths — plus `~/.agents/INSTRUCTIONS.md` and `~/.agents/skills/grok-build-delegation/SKILL.md`
twins, because the Grok Build CLI discovers its instructions and skills under `~/.agents`
(that is its convention, and the CLI is what `execute`-lane delegation drives; the chat
agent dedupes skills by name with first-match-wins, so an agent reading both trees loads
any one skill exactly once). The skill carries the delegation recipe — when to delegate,
how to review the delegated diff, the workaround for `execute`’s roughly-one-minute tool
timeout — and the instruction file handles small asks directly, routes big multi-file
work through the skill, and never prints `$LITELLM_API_KEY`. Both `main.tf` files
deliberately set **no** `CODER_AGENT_EXP_*` env keys on `coder_agent.main`: those keys
*replace* the agent's discovery defaults, and the defaults already cover exactly the
seeded paths — the `~/.coder` roots plus a working-dir-relative `.agents/skills`, which
resolves inside the agent's working dir (`/home/coder` in `workspace`; in
`devcontainer` with the toggle on, the cloned folder under
`/srv/coder-devcontainers/...`, where a dev container built on the sidecar carries its
own home and no seeded path is visible from inside it anyway). Each seeded file carries
the stack's `managed-by: evo-t1-coder-stack` marker (in `SKILL.md` directly under the
`---` frontmatter, since the agent's skill parser requires frontmatter on line 1) as a
seed-guard — delete a file to take it over, or edit it and the stack leaves it alone —
and the marker never reaches the model anyway: the agent strips HTML comments from
injected instruction text. The seeds live per-workspace, on that workspace's own home
volume: they are *not* on the shared `~/.grok` profile volume above, and seeding does
not care whether that mount exists.

**What this is not:** Coder Agents is control-plane-native. This stack does not wrap
Grok Build; the wiring above *teaches* (skill + instructions) and *equips* (the
workspace-side CLI with its LiteLLM alias) the native Coder agent to drive Grok Build
when work is too big to hand-drive — delegation is a taught habit, not the product.

## Kasm

- **First boot:** `https://<host>:3000` — run the install wizard once.
- **After install:** the Kasm UI is on `https://<host>:4443` (change with `KASM_UI_PORT`).
  Both are TLS with Kasm's own self-signed certificate, and `KASM_UI_PORT` has to match
  on both sides of the port mapping: the daemon-side listener listens on that number, so
  `4443:4443` is the mapping, not `4443:443`.
- The image ships default users (`admin@kasm.local` / `user@kasm.local`) — change them during the wizard.
- Kasm is a privileged Docker-in-Docker container and the only **always-on** privileged
  service in this stack; the other privileged container is the opt-in workspace DinD
  sidecar (section "Coder workspace template"). Keep Kasm LAN-only unless you have
  decided who is allowed to reach the public name (see SECURITY.md).

## Homepage dashboard

The [Homepage](https://gethomepage.dev) dashboard is the landing page for the stack: a card per
service with live status pulled from each service's own API (Coder version, LiteLLM health and alias
count, Ollama version), plus a header of boxed tiles — host CPU, memory and CPU temperature, disk,
`eth0` throughput — alongside the clock, local weather (open-meteo, keyless) and a DuckDuckGo search.

- **URL:** `https://<host>/` — a self-signed cert that `bootstrap.sh` issues, so expect a one-time
  browser warning. Port 80 redirects to HTTPS.
- **Login:** homepage v2's built-in gate; the password is `HOMEPAGE_AUTH_PASSWORD`, printed once by
  `bootstrap.sh`. It is worth keeping on: the dashboard lists every service on the box.
  Change it later with `bazelisk run //scripts:dashboard-password` (generates one, or
  add `-- --prompt` to type your own) — it rewrites `.env`, recreates the container and
  verifies the new value landed. homepage
  hashes that env var itself but still needs the plaintext, so the file has to carry it: the script's
  job is keeping it out of shell history, `ps` and git, and leaving `.env` mode 600.
- **Config:** `homepage/config/*.yaml` plus `custom.css`, each file bind-mounted read-only, so
  `git diff` stays the record of dashboard changes. Edit there and `docker compose restart homepage`.
  A new config file (`kubernetes.yaml`, …) needs its own mount line in `docker-compose.yml`; the
  directory itself has to stay writable because the app creates `logs/` inside it. `custom.css`
  lives in `/app/config` and is served by the allow-listed `/api/config/custom.css` route — it
  styles the sign-in page too, so keep internal hostnames out of it.
- **Look:** the layout follows the upstream README example — logo + greeting top-left, boxed
  resource tiles, clock / weather / search top-right, cards on a wallpaper. The wallpaper
  (`background.webp`) and logo (`evo-t1.svg`) live in `homepage/assets/icons/`, mounted at
  `/app/public/icons` and served as `/icons/…`. They sit under `icons/` because homepage's auth
  middleware exempts only that path from the sign-in redirect, which is what lets the same
  wallpaper render on the login page. New asset files need `docker compose up -d` (a recreate) —
  `restart` keeps the old mounts.
- **After a recreate, revalidate once.** v2.4.0 serves a prerendered page with the settings baked
  in, so a freshly created container shows an empty default layout (`initialSettings {}`) until
  the config is re-read. Click the refresh button in the header, or
  `curl -k -X POST https://<host>/api/revalidate`. A plain `restart` keeps the generated page, so
  day-to-day YAML edits do not need this.
- **Host stats caveat:** CPU, memory, CPU temp and disk are host-wide through `/proc`, but a
  network widget can only see the container's netns (`lo`/`eth0`) — `/sys/class/net` is
  namespaced, so the host Wi-Fi NIC is invisible even with `/sys` mounted. That tile shows `eth0`.
- **Wiring:** card `href`s come from `STACK_CODER_URL` / `STACK_KASM_URL` / `STACK_LITELLM_URL`, which
  default to LAN URLs built from `STACK_LAN_HOST` and the port variables, so links keep working when you
  change a port or re-detect the LAN IP, and follow the public names when `STACK_PUBLIC_HOSTS` is set.
  Widget `url`s use compose DNS (`http://coder:3000`, `http://litellm:4000`, `http://ollama:11434`) and
  never leave the network.
- **The docker socket stays unmounted.** Service status comes from each service's API, which avoids
  handing the dashboard a root-equivalent host credential.

## Memory budget (96 GB DDR5, CPU + iGPU unified)

| Item | Typical footprint |
|---|---|
| `qwen2.5-coder:32b` (Q4) | ~20 GB weights + 4–8 GB KV cache / activations |
| `qwen2.5-coder:14b` | ~10 GB |
| `qwen2.5:7b` | ~5 GB |
| Each Coder workspace | 2–8 GB depending on toolchain |
| Coder + Postgres + LiteLLM | ~2–3 GB |
| Kasm desktop session | 4–16 GB (more for GPU apps) |
| Homepage + nginx sidecar | ~120 MB measured (`docker stats`: 100 + 18 MiB) |

Only models you actually load are resident; Ollama keeps them in RAM until they age out.

## What not to run here

- **Training / fine-tuning.** This is an inference + dev-workspace box, not a training rig.
- **Public internet exposure beyond the optional mode above.** The default install assumes a trusted LAN
  / VPN: the dashboard has an nginx sidecar with a self-signed cert and its own password gate, which is
  far short of a real reverse proxy, and nothing at all stands in front of Coder, LiteLLM or Kasm.
  Publishing those through Traefik is supported as an explicit, opt-in choice (section "Public
  subdomains (optional)"), not as an incidental side effect of opening a port.
- **Heavy video encode/render.** The Arc 140T is strong for LLM inference; do not plan media pipelines around it.
- **Multi-tenant teams.** A handful of trusted users, not an org-wide SaaS.
- **CI that downloads models.** No pipeline in this repo pulls 40 GB of weights — model pulls are a manual `bazelisk run //scripts:pull-models`.

## Why this shape

- **IPEX-LLM over vanilla Ollama (CPU/Vulkan):** the IPEX-LLM runtime is Intel's XPU path (oneAPI / Level Zero) for the Arc stack. With `OLLAMA_NUM_GPU=999` every layer offloads to the 140T and the iGPU pulls weights straight out of the 96 GB DDR5. Vanilla Ollama on an Intel iGPU is effectively CPU-bound, which is several times slower on a 32B coder model. Watch for `runners=[ipex_llm]` in `docker compose logs ollama` — that line is the GPU backend confirming itself.
- **MoE over dense:** `qwen2.5-coder:32b` is a Mixture-of-Experts model — 32B-class quality with far fewer active parameters per token. On a memory-rich but bandwidth/latency-constrained iGPU that is the sweet spot; an equivalent dense model would move all parameters per token and run much slower at the same footprint.
- **One LiteLLM front door:** workspaces see a stable OpenAI-compatible URL and alias names; you can flip `coder` from the local Arc to a Spark box (or add a new alias) without touching workspace settings.
- **Kasm on the same box:** the EVO-T1's 96 GB is enough to run a desktop (X11 + GPU) alongside local models, so "open a full desktop when the editor is not enough" is one Kasm click away.

## Repo layout

```text
.
├── docker-compose.yml
├── .env.sample            # canonical env template (.env.example is a copy)
├── homepage/config/       # dashboard: services, widgets, settings, bookmarks, custom.css
├── homepage/assets/icons/ # dashboard wallpaper + header logo, served at /icons/
├── images/dev/            # golden workspace image
│   ├── Dockerfile
│   └── tool-versions.env  # every version pin, single source of truth
├── litellm/config.yaml    # model aliases
├── proxy/homepage.conf    # nginx TLS terminator for the dashboard
├── proxy/router.conf      # nginx Host-header router for the public subdomains (no cert)
├── searxng/settings.yml   # SearXNG metasearch config, mounted read-only into the container
├── scripts/
│   ├── bootstrap.sh         # .env + secrets + access URL + dashboard & Coder certs + checks
│   ├── build-dev-image.sh   # builds images/dev → evo-t1-dev:latest
│   ├── coder-agents.sh      # wires the control-plane chat agent: LiteLLM provider + model configs + lane pins + system prompt (bootstrap calls it)
│   ├── dashboard-password.sh # rotate the dashboard login password and apply it
│   ├── dev-stack.sh         # up / down / status / logs / reset for one compose project (--project-name, default evo-t1-dev)
│   ├── github-auth.sh       # GitHub credential doctor: probe what a workspace's git/gh would present, or install a PAT
│   ├── new-workspace.sh     # git URL → workspace: probes for a dev container, picks the template + params, drives `coder create`
│   ├── pull-models.sh       # pulls OLLAMA_MODELS into the IPEX-LLM container
│   ├── push-template.sh     # pushes both templates from inside the coder container (bootstrap calls it)
│   ├── refresh-configs.sh   # re-materialize the tracked config seeds (tmux.conf, settings.json, the AGENTS.md text, SKILL.md) into a workspace or container; --dry-run and --json; run as //scripts:refresh-configs
│   ├── search-check.sh      # probe the search lane: one HTTP GET per engine x query, so an empty answer names the engine that refused; --json; run as //scripts:search-check
│   ├── setup-host.sh        # the one script run straight from a shell: installs Bazelisk + the lint toolchain
│   └── storage-clean.sh     # interactive janitor for the persistent layer: disk report (docker system df, project and workspace volumes), sweep of stale cache files older than --older-than days under the workspace HOME caches, and a config re-sync of the reseed list into running workspace containers; report-only with --check or --dry-run; run as //scripts:storage-clean
└── templates/
    ├── common/              # single-copy payloads, staged beside each staged main.tf on a push
    │   ├── GROK_BUILD_AGENTS.md  # the seed text the startup scripts inline into AGENTS.md
    │   └── vscode-alt.svg        # the code-server editor icon, read as a base64 data URL
    ├── workspace            # Coder template (`coder templates push`; base template, pushed first)
    │   ├── main.tf
    │   ├── coder.tf
    │   ├── startup.sh.tftpl     # staged workspace bootstrap (blocking)
    │   ├── settings.json.tftpl  # editor-settings seed, copied once onto vscode-settings-<owner-id> and linked from code-server User settings
    │   └── grok-config.toml.tftpl  # ~/.grok/config.toml — models + MCP servers
    └── devcontainer         # Coder template that clones repo_url and (toggle on)
                              # builds its .devcontainer on an always-on DinD sidecar,
                              # or opens the clone on the plain container (toggle off); pushed second
```

## Troubleshooting

- `docker compose logs -f ollama` — IPEX-LLM startup; look for `runners=[ipex_llm]`.
- **Grok agent mode makes no tool calls** (it narrates actions and stops) → the request
  is being served by the Arc (no Spark box reachable). Check the dashboard's
  **Agent backend** card — its per-box widgets go to error state while `agent`
  still answers — or probe the boxes directly:

  ```sh
  curl -sS "${AGENT_MODEL_URL:-http://spark-2.lan:8888/v1/models}" | head -c 200
  # or the whole fleet at once, from the repo root — spark-verify.sh derives its host
  # list from the SPARK*_URL keys in .env (set SPARK_HOSTS="host1 host2 ..." only to
  # check a fleet your .env does not name):
  bazelisk run //scripts:spark-verify -- --no-tests
  ```

  If that fails, bring the TensorFold server up
  (`bazelisk run //scripts:spark-configure -- <host> --apply` writes the per-host
  override file the server runs) or point
  `SPARK1/2/3_OPENAI_URL` at a tool-capable OpenAI-compatible endpoint and
  `docker compose restart litellm` — and keep `SPARK_n_API_KEY` non-empty: an
  empty key fails every request inside the proxy before it reaches the box. The
  `agent` → `coder` fallback keeps chat working while a Spark is down, which is
  exactly when tools disappear.
- **Coder Agents chat** refuses every prompt, or its model dropdown is empty → the chat
  has no model config on this deployment: run
  `bazelisk run //scripts:coder-agents -- --dry-run` then
  `bazelisk run //scripts:coder-agents -- --apply` (it skips while the coder or db
  container is down or nobody has
  registered yet, and re-running it repairs a drifted provider). A chat that starts but
  narrates instead of calling tools is the no-Spark fallback again — the first bullet.
- Workspace stuck in *starting* → startup is blocking by design, so a failure there
  surfaces as a failed build with the reason in the workspace startup log
  (`coder logs <workspace>`); the container is not marked healthy until the toolchain
  is staged.
- Image missing tools, or the build aborts mid-layer → a pinned download returned an
  error; the layer prints `curl: (22)` and stops rather than shipping a partial image.
  Check the version in `images/dev/tool-versions.env` against the upstream release.
- `grok` → `command not found` inside a workspace → the container started before
  the CLI was baked into the image, or its start-time download failed.
  `bash -lc 'command -v grok'` (or `test -x ~/.grok/bin/grok`) answers nothing in
  that case; `/tmp/coder-startup-script.log` holds exactly one `curl: (28)` line.
  Fix now, from the stack host:
  `docker exec -u coder -i <workspace-container> sh -c 'curl -fsSL --http1.1 --retry 3 --retry-all-errors --retry-delay 3 --connect-timeout 15 --max-time 240 https://x.ai/cli/install.sh | bash'`
  and open a new terminal (PATH there already includes `~/.grok/bin`).
  Permanent fix: rebuild the image (`bazelisk run //scripts:build-dev-image`) and
  rebuild the workspace, which then starts from the image's copy.
- `docker` → `command not found` inside a workspace → that container was built from an
  image predating the Docker client toolchain (or from the bare-Ubuntu *Minimal shell*
  preset). Rebuild the image with `bazelisk run //scripts:build-dev-image`, then
  rebuild the workspace — the image is fixed at create time.
- Workspace `docker` commands fail with `Cannot connect to the Docker daemon at
  tcp://dind:2375` → the sidecar is unhealthy, or its image was never pulled, or the
  workspace was created with DinD off (`DOCKER_HOST` is only injected when it is on —
  check the workspace's *docker-in-docker* metadata tile). On the stack host:

  ```sh
  docker inspect --format '{{.State.Health.Status}}' coder-<wsid>-dind-sidecar
  docker logs --tail 100 coder-<wsid>-dind-sidecar
  docker pull docker:29.8.1-dind
  ```

  `no such container` from the first two means the workspace has no sidecar at all.
  An absent image fails the workspace build at **plan** time — before anything is
  created — with `did not find docker image 'docker:29.8.1-dind'`, in the workspace's
  build log rather than anywhere inside it.
- `bazelisk run //scripts:push-template` prints `… .terraform.lock.hcl is missing` → that
  is a note, not a failure: no lockfile is committed under `templates/`, and Coder pushes
  the directory without one. Run `terraform -chdir=templates/<name> init -backend=false`
  (name = `workspace` or `devcontainer`) only if you want to pin provider versions
  locally; the push goes ahead either way.
- `coder login` / any host `coder` command fails with
  `unexpected non-JSON response "text/html; charset=utf-8"` (usually wrapped in
  `Failed to check server "https://…" for first user, is the URL correct and is coder
  accessible from your browser?`) → the CLI is talking to a public subdomain and
  Authelia is answering its API calls with the sign-in page. This is not a broken
  credential — it happens with a valid token too, because Authelia gates every route.
  Point the CLI at the container's loopback listener instead (see
  "Coder workspace template"), which nothing can gate. `CODER_ACCESS_URL` itself stays
  the public name: browsers need it, only CLI traffic should not use it.
- `coder server` logs `installed terraform version newer than expected` → harmless.
  The Coder image ships its own provisioner binary (`/usr/local/bin/terraform`,
  1.15.5 in `coder:v2.36.6`) and Coder caps the version it was tested against, so the
  pair is an upstream pin. Builds still succeed; verify with a workspace build before
  acting on it. Nothing in this repo's compose file sets the provisioner's Terraform.
- Workspace cannot reach LiteLLM → check `CODER_ACCESS_URL` is an `https://` URL (a LAN IP, or the public coder name in public mode — never `localhost` / `127.0.0.1`) and that the workspace container can resolve `host.docker.internal`. Agent traffic ignores that URL and dials `host.docker.internal:3002` (see the `coder_agent_url` template variable).
- Grok profile missing in a fresh workspace → `startup_script` is blocking, so it
  has already finished before the agent reports ready and before code-server
  starts; check the workspace agent logs, then `bash -lc 'command -v grok'` — a
workspace on a current image answers `/usr/local/bin/grok`.
- Browser editor (code-server) stays unhealthy → check in this order: the
  code-server install script's log is green in the workspace's Scripts/Log tab;
  `curl -fsS localhost:13337/healthz` answers from inside the workspace; the
  browser is on `https://` with a trusted cert (plain `http://` is an insecure
  context, which is what breaks `crypto.randomUUID()` — see "Public subdomains
  (optional)" above). On `devcontainer` the dev container must build first
  (the repo needs `.devcontainer/devcontainer.json`); a repo that ships none wants the
  **Plain clone** preset or the dev-container toggle set to **No** at create time — that
  runs code-server on the plain workspace container and opens the clone there, and
  `bazelisk run //scripts:new-workspace -- <git-url>` decides this for you.
- Private-repo clone or push denied even though a credential exists → the denial is about the **grant**, not the credential format: a connected-but-unscoped credential authenticates and is still refused (403 — or 404, which GitHub returns to hide a private repo's existence). Check the GitHub side first: the grant behind the credential — the GitHub OAuth app installation the `primary-github` external-auth provider minted its token from — must include the repository the workspace clones. Then check the URL scheme: the credential works for `https://github.com/...` remotes only; a `git@github.com:`/`ssh://` URL gets neither helper nor askpass token and needs an SSH key you placed yourself — this stack provisions none. From the stack host, `bash scripts/github-auth.sh check [container] [repo-url]` names the credential each running workspace presents and whether it is granted on the repo; `bash scripts/github-auth.sh auth <container> - < PAT` installs a write-capable PAT into that workspace's gh auth store — the only credential when the workspace's owner connected no account (`gh auth logout`, or a rebuild, removes it).
- Kasm wizard gone after install → expected; use :4443. Reset Kasm by removing the `kasm-data` volume (destroys all Kasm config).
- Coder login problems → the first registered account is the site admin; if the UI is unreachable, check `CODER_ACCESS_URL` matches the address you're browsing from (LAN IP by default, the public coder name in public mode).
