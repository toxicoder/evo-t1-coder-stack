# EVO-T1 Coder Stack

One `docker compose up` turns a GMKtec EVO-T1 laptop into a self-hosted dev-workspace server: Coder workspaces that open a **Grok Build** terminal by default (with Cline and Kilo Code pre-wired to local models), Kasm Workspaces for full desktop streaming, IPEX-LLM Ollama running Qwen Coder on the Intel Arc 140T, a LiteLLM proxy that unifies the local iGPU with one or more NVIDIA Spark boxes behind a single OpenAI-compatible endpoint, and a [Homepage](https://gethomepage.dev) dashboard on the default web ports that links it all together with live status for each service.

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
  |                * Grok Build terminal (default; tmux session
  |                  grok-build-<folder>-<hash>, then `grok --cwd <folder>`)
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
./scripts/bootstrap.sh    # generates local secrets, fills CODER_ACCESS_URL
docker compose up -d
./scripts/build-dev-image.sh  # one-time: the polyglot workspace image (~a few GB)
./scripts/pull-models.sh  # pulls OLLAMA_MODELS (first run is a big download)
```

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

   The equivalent HTTP call is `POST /api/v2/users/first`, and `coder server
   create-admin-user` does the same from the server side. All three work on
   v2.36 — the browser is convenience.
2. Push the workspace template (section below).
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
existed need `coder templates push` plus a restart to pick up the template's `coder_agent_url` variable
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

```sh
export PATH="$PATH:$HOME/bin"          # if you installed the coder CLI locally
coder login https://<host>:3001
coder templates push ./templates/docker-dev --var image=evo-t1-dev:latest
```

`coder templates` is the canonical name (`template` is its alias). Build
`evo-t1-dev:latest` first with `./scripts/build-dev-image.sh` — the docker provider
resolves that name from the local image store and never attempts a registry pull,
which is what keeps workspace creation working with no internet.

The create form shows a **Workspace image** dropdown and two presets, *AI workspace*
(golden image, selected by default) and *Minimal shell* (bare Ubuntu, for when the
golden image is mid-rebuild). `--var image=` seeds the dropdown's default and is also
injected as its own option, so a custom tag still reaches the container while the form
stays honest about what it is building.

The template (`templates/docker-dev/`) creates one Docker container per workspace:

- the golden image from `images/dev/Dockerfile` (override with the `image`
  variable) — Node 22 + 24, Python 3.12 + 3.11, Go 1.24, Bazelisk/buildifier,
  Terraform/tflint/terragrunt, protoc and its Go plugins, kubectl/helm/kubeconform,
  shfmt/shellcheck/bats/ruff/mypy/prettier, the Coder CLI, and the five MCP servers
  pre-baked so a workspace needs no network to start a session
- persistent per-workspace home volume
- `host.docker.internal` → host-gateway, so workspaces reach the Coder server and LiteLLM
- a startup script that installs the **Grok Build CLI**, puts `~/.grok/bin` on PATH,
  renders `~/.grok/config.toml` and the VS Code settings (below), and warms the MCP
  servers in the background
- `startup_script_behavior = "blocking"`, so a workspace only reports *ready* once the
  toolchain is genuinely staged — no opening an editor mid-install
- in-IDE apps (VS Code, web terminal, port forwarding, SSH helper) via `display_apps`,
  memory and disk usage gauges, seven `coder stat` metadata tiles, and a **LiteLLM**
  tile that health-checks the proxy and is visible only to the workspace owner
- `coder_metadata.workspace_info` shows the image, the LiteLLM URL, the default Grok
  model and (redacted) which key is wired in, so a misconfigured workspace is visible
  in the UI without shell access

Template variables: `image` (seeds the **Workspace image** dropdown default),
`litellm_url` (default `http://host.docker.internal:4000/v1`),
`litellm_key` (sensitive — pass the LiteLLM master key when creating a workspace),
`grok_default_model` (default `agent`; the tool-capable Spark alias), `docker_socket`
(optional), `coder_agent_url` (default `http://host.docker.internal:3002` — the URL the agent
dials, kept on the local plain listener so a public `CODER_ACCESS_URL` does not hairpin agent
traffic through the reverse proxy; empty keeps the provider-rendered access URL).

Autostart, autostop and TTLs are template *metadata*, so set them once with the CLI
after pushing (they are deliberately absent from the Terraform, where they would
fight the UI):

```sh
coder templates edit docker-dev \
  --default-ttl 8h \
  --activity-bump 2h \
  --failure-ttl 24h
```

## Grok Build default terminal

New Coder workspaces open a **Grok Build** terminal by default:

- `terminal.integrated.defaultProfile.linux` is `"Grok Build"`; the automation profile stays `bash`, and plain `bash` and `tmux` remain available as extra profiles.
- The profile resumes (or starts) one tmux session per folder — `grok-build-<folder>-<hash>` — then runs `grok --cwd <folder>` inside it.
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
  `http://host.docker.internal:4000/v1`, master key from the `litellm_key` template
  variable, model alias `agent`, with `coder`/`coder-fast`/`chat` listed as
  alternates). If your extension build names its settings slightly differently, set
  the OpenAI-compatible endpoint + key in its settings UI — one field each.

## Kasm

- **First boot:** `http://<host>:3000` — run the install wizard once.
- **After install:** the Kasm UI is on `http://<host>:4443` (change with `KASM_UI_PORT`).
- The image ships default users (`admin@kasm.local` / `user@kasm.local`) — change them during the wizard.
- Kasm is a privileged Docker-in-Docker container; it is the only privileged service in this stack. Keep it LAN-only unless you have decided who is allowed to reach the public name (see SECURITY.md).

## Homepage dashboard

The [Homepage](https://gethomepage.dev) dashboard is the landing page for the stack: a card per
service with live status pulled from each service's own API (Coder version, LiteLLM health and alias
count, Ollama version), plus host CPU, memory, disk and CPU temperature in the header.

- **URL:** `https://<host>/` — a self-signed cert that `bootstrap.sh` issues, so expect a one-time
  browser warning. Port 80 redirects to HTTPS.
- **Login:** homepage v2's built-in gate; the password is `HOMEPAGE_AUTH_PASSWORD`, printed once by
  `bootstrap.sh`. It is worth keeping on: the dashboard lists every service on the box.
  Change it later with `./scripts/dashboard-password.sh` (generates one, or `--prompt` to type your
  own) — it rewrites `.env`, recreates the container and verifies the new value landed. homepage
  hashes that env var itself but still needs the plaintext, so the file has to carry it: the script's
  job is keeping it out of shell history, `ps` and git, and leaving `.env` mode 600.
- **Config:** `homepage/config/*.yaml`, each file bind-mounted read-only, so `git diff` stays the
  record of dashboard changes. Edit there and `docker compose restart homepage`. A new config file
  (`custom.css`, `kubernetes.yaml`, …) needs its own mount line in `docker-compose.yml`; the directory
  itself has to stay writable because the app creates `logs/` inside it.
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
├── homepage/config/       # dashboard: services, widgets, settings, bookmarks
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
│   └── pull-models.sh       # pulls OLLAMA_MODELS into the IPEX-LLM container
└── templates/docker-dev   # Coder template (`coder templates push`)
    ├── main.tf
    ├── coder.tf
    ├── startup.sh.tftpl     # staged workspace bootstrap (blocking)
    ├── settings.json.tftpl  # VS Code / Cline / Roo settings
    └── grok-config.toml.tftpl  # ~/.grok/config.toml — models + MCP servers
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
- `coder templates push` complains about the lockfile → commit
  `templates/docker-dev/.terraform.lock.hcl`; regenerate with
  `terraform -chdir=templates/docker-dev init -backend=false`.
- `coder server` logs `installed terraform version newer than expected` → harmless.
  The Coder image ships its own provisioner binary (`/usr/local/bin/terraform`,
  1.15.5 in `coder:v2.36.6`) and Coder caps the version it was tested against, so the
  pair is an upstream pin. Builds still succeed; verify with a workspace build before
  acting on it. Nothing in this repo's compose file sets the provisioner's Terraform.
- Workspace cannot reach LiteLLM → check `CODER_ACCESS_URL` is an `https://` URL (a LAN IP, or the public coder name in public mode — never `localhost` / `127.0.0.1`) and that the workspace container can resolve `host.docker.internal`. Agent traffic ignores that URL and dials `host.docker.internal:3002` (see the `coder_agent_url` template variable).
- Grok profile missing in a fresh workspace → the startup script runs before VS Code starts; check the workspace agent logs, then `ls ~/.grok/bin`.
- Kasm wizard gone after install → expected; use :4443. Reset Kasm by removing the `kasm-data` volume (destroys all Kasm config).
- Coder login problems → the first registered account is the site admin; if the UI is unreachable, check `CODER_ACCESS_URL` matches the address you're browsing from (LAN IP by default, the public coder name in public mode).
