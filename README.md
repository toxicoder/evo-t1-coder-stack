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
  |                  (scripts/build-dev-image.sh)
  |                * two templates: docker-dev (plain container) and
  |                  docker-devcontainer (clones repo_url, builds its
  |                  .devcontainer on the workspace's own DinD sidecar)
  |                * default terminal re-joins the folder's tmux session
  |                  (vscode-<folder>-<hash>); Grok Build runs `grok --cwd <folder>`
  |                  inside its own session (grok-build-<folder>-<hash>)
  |                * ~/.grok/config.toml rendered by the template: model
  |                  aliases + MCP servers (filesystem, memory,
  |                  sequential-thinking, git, time)
  |                * Cline / Kilo Code ---> host.docker.internal:4000
  |
  +-- :4000 ----> LiteLLM proxy (master key, model aliases)
  |                   +-- local:  http://ollama:11434 (compose network only)
  |                   +-- remote: SPARK1/2_OLLAMA_URL (Ollama aliases) and
  |                   |           SPARK1/2_OPENAI_URL (vLLM — the `agent`
  |                   |           aliases, the only tool-capable path)
  |
  +-- (no host port) IPEX-LLM Ollama on the Arc 140T (/dev/dri)
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
./scripts/bootstrap.sh    # secrets, CODER_ACCESS_URL, certs; also builds the golden
                          # image and pulls docker:29.8.1-dind when either is missing
docker compose up -d
./scripts/pull-models.sh  # pulls OLLAMA_MODELS (first run is a big download)
```

`bootstrap.sh` also builds `evo-t1-dev:latest` when it is missing (several GB of
downloads, so a cold run takes minutes), pulls `docker:29.8.1-dind` for the opt-in
workspace DinD sidecar, and pushes both workspace templates once a Coder account exists.
None of those is fatal: a build that cannot download, or a push with nobody registered
yet, prints why and bootstrap still finishes. Both are retryable on their own —
`./scripts/build-dev-image.sh` and `./scripts/push-template.sh` (which takes no arguments
to push both, or template names to retry just the ones that failed; section "Coder
workspace template" below). `SKIP_DEV_IMAGE_BUILD=1` / `SKIP_TEMPLATE_PUSH=1` restore the
old print-only behaviour; bootstrap reads them from the process environment only, never
from `.env`.

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
2. Push the workspace templates (section below) — `./scripts/push-template.sh` does both
   once an account exists, which is why bootstrap runs it for you and says why it
   skipped when none does. It needs no `coder login` and no host coder CLI.
3. Kasm: on first boot open `http://<host>:3000`, run the install wizard once, then use `http://<host>:4443` for the Kasm UI.
4. Dashboard: open `https://<host>/` and sign in with the `HOMEPAGE_AUTH_PASSWORD` that `bootstrap.sh` printed.

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
./scripts/bootstrap.sh
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
existed need `./scripts/push-template.sh` plus a restart to pick up the template's `coder_agent_url` variable
(default `http://host.docker.internal:3002`), which is what keeps agents dialing the local plain
listener whatever the access URL says. Kasm likewise stores its connection endpoints in its own setup
database (first-boot wizard / admin UI), so that endpoint has to be updated there too or streams keep
dialing the LAN address.

## LiteLLM model aliases

Workspaces and desktops always talk to one base URL — `http://host.docker.internal:4000/v1` with `LITELLM_MASTER_KEY` — and pick a model alias:

| Alias | Model | Backend | Structured tool calls |
|---|---|---|---|
| `agent` | `qwen3.8-flash-next` | `SPARK1_OPENAI_URL` (Spark vLLM, optional) | yes (measured) |
| `agent-fast` | `qwen3.8-flash-next` | `SPARK2_OPENAI_URL` (Spark vLLM, optional) | yes (measured) |
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
and agent mode needs either a Spark `agent` alias or the small `chat` model. Grok
Build, Cline, Roo and Kilo therefore default to `agent`, the Spark vLLM alias.

If both Sparks are unreachable, `router_settings.fallbacks` first retries `agent` on
the other Spark via `agent-fast` and only then degrades to `coder`, which still
streams text and keeps chat usable while agent mode quietly loses its tools. That
last hop is the failure the dashboard's **Agent backend** card exists to surface.

Edit aliases in `litellm/config.yaml`, then `docker compose restart litellm`.

## Coder workspace template

Two templates live under `templates/`, and the push covers both. It happens on its own:
`bootstrap.sh` calls `./scripts/push-template.sh`, which then pushes when the coder and db
containers are running and an active Coder account exists, and otherwise prints a one-line
reason and exits 0 (a fresh clone has none of those yet). `docker-dev` goes first and
`docker-devcontainer` last — a dependent template pushes last so a partial failure leaves
the base template usable — and `templates/docker-devcontainer/` is in the default list only
while its `main.tf` exists. The same script is the manual path after you register, and its
arguments are the retry path for a single template:

```sh
./scripts/push-template.sh                           # both, in that order
./scripts/push-template.sh docker-devcontainer       # just the one that failed
```

An unknown name is an error that lists the known names, not a silent no-op. Per template
the script checks `main.tf`, notes a missing `.terraform.lock.hcl` (each template directory
keeps its own committed lockfile; both pin `coder/coder` `~> 2.18` and `kreuzwerker/docker`
`~> 4.6`), refuses a preset description over Coder's 128-character limit, streams the
source, and then confirms an **active** version. A template whose push or that verification
failed is counted in the `N of M template(s) did not reach an active version` line and makes
the run exit non-zero, while every other template still gets its push attempt.

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
sample placeholder) and `--var coder_agent_url` only if `.env` defines it at all. Then, per
template, it confirms an **active** template version — a push can exit 0 and still leave the
template inactive if its Terraform run failed, which shows up as the template missing from
the create dropdown. The equivalent raw command — what the script does for each template,
shown here for `docker-dev` alone, for reference or for pushing a tag `.env` does not carry
(the repo is not mounted into the container, so the directory has to
travel as a tar; `CODER_SESSION_TOKEN` is any token from the Coder **Tokens** page or
`coder tokens create`):

```sh
tar -C templates/docker-dev --exclude=./.terraform -cf - . | \
  docker compose exec -T -i \
    -e CODER_URL=http://127.0.0.1:3000 -e CODER_SESSION_TOKEN \
    coder coder templates push docker-dev --directory - --yes \
    --var image=evo-t1-dev:latest
```

The service appears twice by necessity: the first `coder` selects the compose service,
the second is the CLI binary inside it.

`coder templates` is the canonical name (`template` is its alias). Build
`evo-t1-dev:latest` first with `./scripts/build-dev-image.sh` — the docker provider
resolves that name from the local image store and never attempts a registry pull,
which is what keeps workspace creation working with no internet.

The create form shows a **Workspace image** dropdown and three presets: *AI workspace*
(golden image, selected by default), *Minimal shell* (bare Ubuntu, for when the
golden image is mid-rebuild), and *AI workspace + DinD* (golden image plus a
privileged Docker daemon, below). `--var image=` seeds the dropdown's default and is also
injected as its own option, so a custom tag still reaches the container while the form
stays honest about what it is building.

The template (`templates/docker-dev/`) creates one Docker container per workspace:

- the golden image from `images/dev/Dockerfile` (override with the `image`
  variable) — Node 22 + 24, Python 3.12 + 3.11, Go 1.24, Bazelisk/buildifier,
  Terraform/tflint/terragrunt, protoc and its Go plugins, kubectl/helm/kubeconform,
  shfmt/shellcheck/bats/ruff/mypy/prettier, the Coder CLI, the Docker **client**
  toolchain (`docker`, `docker buildx`, `docker compose` as CLI plugins under
  `/usr/local/lib/docker/cli-plugins` — no daemon: the build asserts `dockerd`,
  `containerd`, `runc` and `docker-proxy` are absent), and the five MCP servers
  pre-baked so a workspace needs no network to start a session
- persistent per-workspace home volume
- `host.docker.internal` → host-gateway, so workspaces reach the Coder server and LiteLLM
- a startup script that installs the **Grok Build CLI**, puts `~/.grok/bin` on PATH,
  seeds the two terminal-profile tmux helpers, renders `~/.grok/config.toml`, and
  warms the MCP servers in the background. The `settings.json.tftpl` payload does not
  pass through the script: it goes to the `code_server` module, which merges it into
  code-server's User+Machine settings on every start (below)
- `startup_script_behavior = "blocking"`, so a workspace only reports *ready* once the
  toolchain is genuinely staged — no opening an editor mid-install
- agent-bar buttons via `display_apps` (VS Code Desktop helper: a locally installed
  VS Code / Cursor / Windsurf plus the `coder.coder-remote` extension; web terminal;
  port forwarding; SSH helper), a separate in-browser **code-server** editor
  (Coder's VS Code fork; no local VS Code), labelled **VS Code Web** with `order = 5`
  so it sorts before the LiteLLM and Coder UI buttons and reads apart from the
  **VS Code Desktop** helper (static helper buttons have no order/icon knobs in this
  Coder release — custom apps are ordered among themselves), memory and disk usage
  gauges, six `coder stat` metadata tiles, and a **LiteLLM** tile that health-checks
  the proxy and is visible only to the workspace owner
- `coder_metadata.workspace_info` shows the image, the LiteLLM URL, the default Grok
  model, whether DinD is `on (tcp://dind:2375)` or `off`, and (redacted) which key is
  wired in, so a misconfigured workspace is visible in the UI without shell access

Template variables: `image` (seeds the **Workspace image** dropdown default),
`litellm_url` (default `http://host.docker.internal:4000/v1`),
`litellm_key` (sensitive — pass the LiteLLM master key when creating a workspace),
`grok_default_model` (default `agent`; the tool-capable Spark alias), `docker_socket`
(optional), `coder_agent_url` (default `http://host.docker.internal:3002` — the URL the agent
dials, kept on the local plain listener so a public `CODER_ACCESS_URL` does not hairpin agent
traffic through the reverse proxy; empty keeps the provider-rendered access URL),
`dind` (default `false`; turns on the per-workspace privileged daemon described below).

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
  pre-arms it; manually: `docker pull docker:29.8.1-dind`. A missing image fails at
  **plan** time — before anything is created — with
  `did not find docker image 'docker:29.8.1-dind'`.
- `DOCKER_CLI_VERSION` in `images/dev/tool-versions.env` and the `docker:29.8.1-dind` tag
  in `templates/docker-dev/main.tf` and `templates/docker-devcontainer/main.tf` are the
  same engine line; bump all three together.

The second template (`templates/docker-devcontainer/`) is that *AI workspace + DinD* shape,
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
- the create form asks a single question, **Git repository** (`repo_url`, mutable — switching
  repository is a re-clone plus a dev image build, not a new topology the way `docker-dev`'s
  DinD toggle is), and one preset makes the template's default repository a one-click
  workspace
- `startup.sh.tftpl` clones the repo onto that bind, and `coder_devcontainer` then builds the
  repo's own `.devcontainer/devcontainer.json` on the sidecar through the Coder agent
  (`@devcontainers/cli` is in the parent workspace container), which exposes the
  dev container as a sub-agent with its own terminal and apps. The in-browser editor
  attaches to that sub-agent, so it runs inside the dev container where the cloned
  repo's toolchain lives. No `config_path` is set, so the CLI discovers the file the
  way VS Code does and a repo using the other legal locations behaves the same.

It reuses `docker-dev`'s variables plus `repo_url`, minus `dind` (the sidecar is not optional
here — a devcontainer workspace without a daemon is nothing), and carries its own copies of
`startup.sh.tftpl`, `settings.json.tftpl` (the shared editor-settings payload,
merged into each dev container's code-server User+Machine settings by the
`code_server` module) and
`grok-config.toml.tftpl`, so the tmux-default
terminal and LiteLLM wiring above apply to it too. **Treat the repository as untrusted
code**: everything it builds runs on a privileged daemon on this box, so a Dockerfile in
that repo is root-equivalent on the stack host — the create form's own description says so,
and only repositories you trust belong in the field.

Autostart, autostop and TTLs are template *metadata*, so set them once per template with the
CLI after pushing (they are deliberately absent from the Terraform, where they would
fight the UI). Run it against the container's loopback API as above — a token from the
Coder **Tokens** page, and the public URL is gated by Authelia:

```sh
export CODER_URL=http://127.0.0.1:3000 CODER_SESSION_TOKEN=<your-token>
docker compose exec -T -e CODER_URL -e CODER_SESSION_TOKEN coder \
  coder templates edit docker-dev \
    --default-ttl 8h \
    --activity-bump 2h
```

`--failure-ttl` and `--allow-user-autostart=false` are rejected without a license
(the server names `--failure-ttl`, `--inactivityTTL`, `--allow-user-autostart=false`
and `--allow-user-autostop=false`), so leave them out of the CE stack.

## Terminal defaults: tmux re-attach and Grok Build

New Coder workspaces open a terminal that **re-attaches to a tmux session**:

- `terminal.integrated.defaultProfile.linux` is `"tmux"`; the automation profile stays `bash` (so build/tasks commands never wait on tmux), and plain `bash` and **Grok Build** remain available as extra profiles.
- The `tmux` profile re-joins (or starts) one shared session per folder — `vscode-<folder>-<hash>` — so a second terminal window, a browser reload, or `ssh` + `tmux attach -t <session>` from any client lands in the same session, and long jobs survive closing the tab. **Grok Build** keeps its own session (`grok-build-<folder>-<hash>`, running `grok --cwd <folder>` inside it); `tmux ls` lists the names, `tmux attach -t <session>` re-joins from any other terminal.
- If tmux is absent (offline first boot), the helper execs a plain login shell, so the default terminal still opens. The Coder **web-terminal** button is separate from all of this: it streams a plain login shell over the agent's reconnecting PTY with its own reconnection token and reads no `terminal.integrated.*` settings.
- The workspace startup script installs the Grok CLI from `https://x.ai/cli/install.sh` (once) and adds `~/.grok/bin` to PATH.
- The startup script renders `~/.grok/config.toml` from
  `templates/docker-dev/grok-config.toml.tftpl`: `[models] default` points at the
  `agent` alias, the five aliases are defined with `base_url` set to `litellm_url`
  and `env_key = "LITELLM_API_KEY"` (the key is injected as an environment variable,
  so it never appears in a file), and the MCP servers, `[features]`, `[permission]`
  deny rules and `web_fetch` policy are set. It is re-rendered idempotently and
  leaves a hand-edited config alone — the managed block is guarded by a
  `managed-by: evo-t1-coder-stack` marker.
- **MCP servers**: `filesystem`, `memory`, `sequential-thinking`, `git` and `time`,
  all pre-installed in the image (`npm -g` for the first three, `uv tool` for the
  Python two), and warmed at workspace startup so the first session does not pay the
  cold-start cost. Check them with `grok mcp doctor` inside a workspace.
- Cline and Roo/Kilo are pre-wired to the LiteLLM proxy (endpoint
  `http://host.docker.internal:4000/v1`, master key from the `litellm_key`
  template variable, model alias `agent`, with `coder`/`coder-fast`/`chat` listed as
  alternates) through the `code_server` module's `settings` and `machine_settings`
  inputs, which merge the payload key-by-key into code-server's User and Machine
  settings under `~/.local/share/code-server` on every start — user-edited keys
  there survive, and nothing is written to the unread `~/.config/Code` path any
  more. Installing Cline/Roo itself is a manual step in either editor's Extensions
  panel (Open VSX by default). If your extension build names its settings slightly
  differently, set the OpenAI-compatible endpoint + key in its settings UI — one
  field each.

## Kasm

- **First boot:** `http://<host>:3000` — run the install wizard once.
- **After install:** the Kasm UI is on `http://<host>:4443` (change with `KASM_UI_PORT`).
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
  Change it later with `./scripts/dashboard-password.sh` (generates one, or `--prompt` to type your
  own) — it rewrites `.env`, recreates the container and verifies the new value landed. homepage
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
- **CI that downloads models.** No pipeline in this repo pulls 40 GB of weights — model pulls are a manual `./scripts/pull-models.sh`.

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
├── scripts/
│   ├── bootstrap.sh         # .env + secrets + access URL + dashboard & Coder certs + checks
│   ├── build-dev-image.sh   # builds images/dev → evo-t1-dev:latest
│   ├── dashboard-password.sh # rotate the dashboard login password and apply it
│   ├── pull-models.sh       # pulls OLLAMA_MODELS into the IPEX-LLM container
│   └── push-template.sh     # pushes both templates from inside the coder container (bootstrap calls it)
└── templates/
    ├── docker-dev            # Coder template (`coder templates push`; base template, pushed first)
    │   ├── main.tf
    │   ├── coder.tf
    │   ├── startup.sh.tftpl     # staged workspace bootstrap (blocking)
    │   ├── settings.json.tftpl  # editor settings (Cline / Roo / terminal profiles), merged into code-server's User+Machine settings
    │   └── grok-config.toml.tftpl  # ~/.grok/config.toml — models + MCP servers
    └── docker-devcontainer   # Coder template that clones repo_url and builds its
                              # .devcontainer on an always-on DinD sidecar (pushed second)
```

## Troubleshooting

- `docker compose logs -f ollama` — IPEX-LLM startup; look for `runners=[ipex_llm]`.
- **Grok agent mode makes no tool calls** (it narrates actions and stops) → the request
  is being served by the Arc. Check the dashboard's **Agent backend** card, or:

  ```sh
  curl -sS "${AGENT_MODEL_URL:-http://spark-2.lan:8888/v1}/models" | head -c 200
  ```

  If that fails, either bring the Spark vLLM server up or point
  `SPARK1_OPENAI_URL` / `SPARK2_OPENAI_URL` at a tool-capable OpenAI-compatible
  endpoint and `docker compose restart litellm`. The `agent` → `coder` fallback keeps
  chat working while a Spark is down, which is exactly when tools disappear.
- Workspace stuck in *starting* → startup is blocking by design, so a failure there
  surfaces as a failed build with the reason in the workspace startup log
  (`coder logs <workspace>`); the container is not marked healthy until the toolchain
  is staged.
- Image missing tools, or the build aborts mid-layer → a pinned download returned an
  error; the layer prints `curl: (22)` and stops rather than shipping a partial image.
  Check the version in `images/dev/tool-versions.env` against the upstream release.
- `docker` → `command not found` inside a workspace → that container was built from an
  image predating the Docker client toolchain (or from the bare-Ubuntu *Minimal shell*
  preset). Rebuild the image with `./scripts/build-dev-image.sh`, then rebuild the
  workspace — the image is fixed at create time.
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
- `./scripts/push-template.sh` notes a missing lockfile → each template dir keeps
  its own committed `templates/<name>/.terraform.lock.hcl`; regenerate it with
  `terraform -chdir=templates/<name> init -backend=false` (name = `docker-dev` or
  `docker-devcontainer`) and commit the result.
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
  starts; check the workspace agent logs, then `ls ~/.grok/bin`.
- Browser editor (code-server) stays unhealthy → check in this order: the
  code-server install script's log is green in the workspace's Scripts/Log tab;
  `curl -fsS localhost:13337/healthz` answers from inside the workspace; the
  browser is on `https://` with a trusted cert (plain `http://` is an insecure
  context, which is what breaks `crypto.randomUUID()` — see "Public subdomains
  (optional)" above). On `docker-devcontainer` the dev container must build first
  (the repo needs `.devcontainer/devcontainer.json`).
- Kasm wizard gone after install → expected; use :4443. Reset Kasm by removing the `kasm-data` volume (destroys all Kasm config).
- Coder login problems → the first registered account is the site admin; if the UI is unreachable, check `CODER_ACCESS_URL` matches the address you're browsing from (LAN IP by default, the public coder name in public mode).
