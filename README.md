# EVO-T1 Coder Stack

One `bazelisk run //scripts:prod-stack -- up` turns a GMKtec EVO-T1 (Intel Ultra 9
285H, Arc 140T iGPU, 96 GB DDR5) into a self-hosted dev-workspace server.

- **Coder** - the control plane: provisions one Docker container per workspace.
- **IPEX-LLM Ollama** - local models on the Arc 140T. **LiteLLM** is the one
  OpenAI-compatible door in front of them, plus optional NVIDIA Spark boxes.
- **Kasm Workspaces** - streams desktops. **Homepage** - the dashboard that links them
  all and shows live status.
- **SearXNG** - the keyless metasearch lane.

The box runs **two isolated copies** of the stack on purpose: a *stable* one you work
in and a *dev* one you break. [Spin up the stack](#spin-up-the-stack) has the
commands; [Two stacks on one box](#two-stacks-on-one-box) explains the split.

Everything is a Bazel target, addressed as `bazelisk run //scripts:<stem> -- <args>`
(`<stem>` is the file name under `scripts/`). `scripts/setup-host.sh` is the only
script meant to run straight from a shell, and it runs before Bazel exists.

## Read me first

1. [Hardware](#hardware) and [Shape](#shape)
2. [Spin up the stack](#spin-up-the-stack) - first boot, top to bottom
3. [Two stacks on one box](#two-stacks-on-one-box) - the dev/prod split and its commands
4. [Develop](#develop) - the gates a change has to pass
5. [After a git pull](#after-a-git-pull) - the two things that go stale, and the one
   command that refreshes them
6. [Ports](#ports)
7. [Public subdomains (optional)](#public-subdomains-optional)
8. [LiteLLM model aliases](#litellm-model-aliases)
9. [Coder workspace templates](#coder-workspace-templates)
10. [Workspaces, terminals and agents](#workspaces-terminals-and-agents)
11. [Kasm](#kasm), [Homepage dashboard](#homepage-dashboard),
   [Memory budget](#memory-budget), [What not to run here](#what-not-to-run-here)
12. [Why this shape](#why-this-shape), [Repo layout](#repo-layout),
    [Troubleshooting](#troubleshooting)

The long version of each topic sits in a page beside this one, linked where it applies:
[coder-templates.md](docs/coder-templates.md), [dashboard.md](docs/dashboard.md),
[grok-build-and-agents.md](docs/grok-build-and-agents.md),
[litellm-routing.md](docs/litellm-routing.md),
[public-access.md](docs/public-access.md), [config-updates.md](docs/config-updates.md),
[troubleshooting.md](docs/troubleshooting.md).

## Hardware

Target machine: **GMKtec EVO-T1**

| | |
|---|---|
| CPU | Intel Core Ultra 9 285H (Arrow Lake-H) |
| GPU | Intel Arc 140T iGPU (`/dev/dri`) |
| RAM | 96 GB DDR5 (CPU + iGPU unified) |

Sized for that machine: local models run on the iGPU through IPEX-LLM, and the 96 GB of
unified memory is what makes a 32B MoE coder model comfortable.

## Shape

```text
LAN clients (laptops, phones, the EVO-T1 itself)
  |
  +-- :80 / :443 -> homepage-proxy (nginx: TLS terminator; 80 redirects to https)
  |                  |
  |                  v
  |               Homepage dashboard (compose network only, password gate)
  |                 * links + live status for every service below
  |                 * host CPU / memory / disk / CPU temp in the header
  |
  +-- :3001 ----> Coder UI (HTTPS, control plane, Postgres-backed)
  |      :2112 ----> Coder /metrics (loopback-bound; for a scraper)
  |                   | provisions workspaces via /var/run/docker.sock
  |                   v
  |              Coder workspaces (Docker containers)
  |                * built from the golden image evo-t1-dev:latest
  |                * two templates: workspace (plain container) and devcontainer
  |                  (builds the cloned repo's .devcontainer on its own DinD
  |                  sidecar; toggle it off, or no devcontainer.json, and the
  |                  clone opens on the plain container)
  |                * both clone the create form's repo_url (empty = no clone);
  |                  code-server, the web terminal and the terminal profiles all
  |                  start on that clone
  |                * ~/.grok/config.toml rendered by the template: model aliases
  |                  (default + role fallbacks) plus the searxng MCP server declared
  |                  by default; github and context7 are opt-in
  |                * Cline / Kilo Code ---> host.docker.internal:4000
  |
  +-- :4000 ----> LiteLLM proxy (master key, model aliases)
  |                 +-- local:  http://ollama:11434 (compose network only)
  |                 +-- remote: SPARK1/2_OLLAMA_URL (Ollama aliases) and
  |                 |           SPARK1/2/3_OPENAI_URL (TensorFold on :8888 -
  |                 |           one `agent` group, one deployment per Spark box,
  |                 |           the only tool-capable path)
  |
  +-- (no host port) IPEX-LLM Ollama on the Arc 140T (/dev/dri)
  |
  +-- :8181 ----> SearXNG metasearch (loopback + LAN face) - keyless engines only,
  |               no key, no account, no request logging. A workspace reaches it
  |               through the host gateway, so the workspace networks stay untouched.
  |               Both templates render it into the workspace config.toml as the
  |               MCP server `searxng` (gated on `search_mcp`, default on); Grok's
  |               native web_search stays off by default as the secondary lane.
  |               Measure the lane with `bazelisk run //scripts:search-check`
  |               (an empty answer is not an answered one).
  |
  +-- :3000 ----> Kasm install wizard (first boot only)
  +-- :4443 ----> Kasm Workspaces UI (privileged DinD desktop streaming)
```

### Key properties

1. **Ollama is never published to the host.** It listens on 11434 inside the compose
   network. LiteLLM is the only gateway to the models, and it sits behind a master key.
2. **Workspaces reach models through the host** on `host.docker.internal:4000`
   (host-gateway), and their agents dial the plain listener on
   `host.docker.internal:3002`. `CODER_ACCESS_URL` is the LAN IP by default, or the
   public coder name in public mode; those two doors stay on the box either way.
3. **The control-plane chat agent dials `http://litellm:4000/v1`** from the server
   side over the compose network, with the same master key.
4. **Kasm owns :3000 and :4443**, so the Coder UI lives on :3001.
5. **The dashboard publishes no port of its own.** Homepage serves plain HTTP and
   cannot load a certificate, so the nginx sidecar owns :80 and :443 and proxies to it
   over the compose network.
6. **Public subdomains are opt-in and additive.** The LAN shape above is the default
   and stays intact when the four public names are on.

## Ports

Default numbers, plus the shifted set a dev stack uses when `dev-stack.env` exists. A
port binds once, so two stacks on one box need two sets.

| Host port | Dev port | Service | Purpose (env var) |
|---:|---:|---|---|
| 80 / 443 | 10080 / 10443 | Homepage | Dashboard - 80 redirects to HTTPS (`HOMEPAGE_HTTP_PORT` / `HOMEPAGE_HTTPS_PORT`) |
| 8080 | 18080 | Router | Plain-HTTP Host router for the public subdomains (`STACK_PROXY_HTTP_PORT`) - runs in both modes, Traefik is its only real client |
| 3001 | 13001 | Coder | Web UI + control plane over TLS (`CODER_HTTP_PORT`) |
| 3002 | 13002 | Coder | Second path to Coder's plain listener, for workspace agents via `host.docker.internal` (`CODER_AGENT_TUNNEL_PORT`) |
| 2112 | 12112 | Coder | Prometheus `/metrics` (`CODER_METRICS_PORT`) - bound to 127.0.0.1, so point a scraper at it from the stack host |
| 3000 | 13000 | Kasm | First-boot install wizard (`KASM_WIZARD_PORT`) |
| 4443 | 14443 | Kasm | Workspaces UI after install (`KASM_UI_PORT`) |
| 4000 | 14000 | LiteLLM | OpenAI-compatible proxy (`LITELLM_PORT`) |
| 8181 | 18181 | SearXNG | Metasearch (`STACK_SEARCH_PORT`) - published, because a workspace reaches the host through its gateway, where the compose network does not help. `push-template.sh` reads this key and pushes `--var searxng_url=http://host.docker.internal:<that port>`, so a remapped port reaches each new workspace's config |
| — | — | Homepage app | `3000` on the compose network only - reached through the proxy |
| — | — | Ollama | `11434` on the compose network only - deliberately not published |

Change a port in `.env` for the stable stack and in `dev-stack.env` for the dev one. A
dev stack still carrying the stable numbers cannot start beside it, and `.env` does not
reach the dev stack when `dev-stack.env` exists.

## Spin up the stack

### What names a stack

- The Compose **project name** namespaces one stack's volumes and networks, and the
  **env file** supplies its host ports.
- `//scripts:dev-stack` and `//scripts:prod-stack` name the project on every call and
  carry the compose file with it, so neither can land on the wrong stack by guessing the
  folder it was called from. `dev-stack` also picks the env file that belongs to the dev
  project; `prod-stack` passes none unless `-e` names one.
- The name each assumes is a sandbox: `evo-t1-dev` for `dev-stack`, `evo-t1-prod` for
  `prod-stack`. A stack brought up by hand sits under `evo-t1-coder-stack`, the checkout
  folder's name, so `--project-name` has to name that folder to address it.

### First boot

1. Clone the repo and change into it.

   ```sh
   git clone https://github.com/toxicoder/evo-t1-coder-stack.git ~/evo-t1-coder-stack
   ```

   ```sh
   cd ~/evo-t1-coder-stack
   ```

2. Create the env file - the one file holding real secrets - and lock it down. It
   stays mode 600 and never gets committed.

   ```sh
   cp .env.sample .env
   ```

   ```sh
   chmod 600 .env
   ```

3. Bootstrap the host: Bazelisk plus the lint toolchain. One-time, and the only step
   that runs straight from a shell.

   ```sh
   bash scripts/setup-host.sh
   ```

4. Check the box - read-only: missing tools, placeholder secrets, certs, images.

   ```sh
   bazelisk run //scripts:bootstrap -- --check
   ```

5. Prepare the box: rotate secrets, set `CODER_ACCESS_URL`, issue the self-signed
   certs, build `evo-t1-dev:latest`, pull `docker:29.8.1-dind`.

   ```sh
   bazelisk run //scripts:bootstrap
   ```

6. Start the **stable** (production) stack. `prod-stack` addresses it by default, as the
   compose project `evo-t1-prod`, on the default ports and with the `.env` beside the
   compose file read by compose itself. Postgres only honours `CODER_PG_PASSWORD` on
   first volume init; the db wrapper re-applies it on every start, so a later secret
   rotation does not leave Coder crash-looping on `password authentication failed`.

   ```sh
   bazelisk run //scripts:prod-stack -- up
   ```

   A stable stack you brought up by hand runs under the checkout folder's name instead.
   The project name travels, so this names it from any directory:

   ```sh
   bazelisk run //scripts:prod-stack -- up --project-name evo-t1-coder-stack
   ```

   Start the **dev** stack instead, or beside it - on ports shifted by 10000:

   ```sh
   bazelisk run //scripts:dev-stack -- up
   ```

7. Pull the models named by `OLLAMA_MODELS` in `.env` (a big download).

   ```sh
   bazelisk run //scripts:pull-models
   ```

### Notes on those commands

- **A Bazel target ships the files its script reads by path.** Running a script by path
  from a foreign working directory would not find them, which is why `dev-stack` always
  passes both `-f` and `-p`.
- **`bootstrap` is idempotent.** Re-run it after changing `docker-compose.yml`,
  `litellm/config.yaml`, `searxng/settings.yml` or `proxy/*.conf`, then start the stack
  again.
- Its expensive steps (golden image build, DinD pull, template push, Agents wiring) are
  **non-fatal when they cannot run yet** - a fresh clone has no Coder account, so the
  push and the wiring skip themselves and say why.
- Each has an off switch that `bootstrap` reads from the process environment, never
  from `.env`: `SKIP_DEV_IMAGE_BUILD=1`, `SKIP_TEMPLATE_PUSH=1`, `SKIP_CODER_AGENTS=1`,
  `SKIP_SPARKS=1`.

### Then, once Coder answers

1. **Register the first account** - that account becomes the site admin. Browsers only
   expose `crypto.randomUUID()` in a secure context, and plain `http://` on a LAN IP
   breaks pages like the template builder, hence HTTPS on :3001.

   ```sh
   coder login https://<host>:3001 \
     --first-user-email you@example.com \
     --first-user-username you \
     --first-user-password 'a-long-passphrase' \
     --first-user-trial=false
   ```

   Target the address the server itself answers on: `https://<host>:3001` on the LAN,
   or `http://127.0.0.1:3000` inside the coder container. Point it at a public
   subdomain in public mode and it fails before it can prompt - Authelia answers the
   CLI's unauthenticated first-user probe with its HTML sign-in page, which the CLI
   reports as `unexpected non-JSON response "text/html; charset=utf-8"`.
   `POST /api/v2/users/first` and `coder server create-admin-user` behave the same way.

2. **Push the workspace templates** - both, `workspace` first and `devcontainer` last.
   Name one to retry just that one. No `coder login` and no host coder CLI involved.

   ```sh
   bazelisk run //scripts:push-template
   ```

3. **Wire the control-plane chat agent.** Print the intended end state, then apply it.
   It creates the `litellm` AI provider, the two chat model configs, the subagent lane
   pins and the system-prompt addendum through the server API, leaves no credential
   behind, and repairs a drifted provider when re-run.

   ```sh
   bazelisk run //scripts:coder-agents -- --dry-run
   ```

   ```sh
   bazelisk run //scripts:coder-agents -- --apply
   ```

4. **Create a workspace** from a git URL. The same choice by hand is: create a
   workspace in the UI, pick the template, fill the **Git repository** field.

   ```sh
   bazelisk run //scripts:new-workspace -- https://github.com/org/repo.git
   ```

5. **Kasm:** run the install wizard once at `https://<host>:3000`, then use
   `https://<host>:4443` for the UI. Both ports serve TLS with the self-signed
   certificate Kasm's installer generates, so expect the same one-time browser warning
   the dashboard gives - plain `http://` reaches neither port.

6. **Dashboard:** `https://<host>/`, signed in with the `HOMEPAGE_AUTH_PASSWORD` that
   `bootstrap` printed.

## Two stacks on one box

The dev copy exists so a stack change gets tried out while the stable one keeps serving
you: a bad compose file, model alias or template change costs you a sandbox instead of
your working stack, and you keep a stack that still answers while you fix it.

They are separate Compose **projects**, so each gets its own volumes and networks, and
they sit on different host ports so both can bind at once.

| | stable (production) | dev (testing) |
|---|---|---|
| Compose project | `evo-t1-prod` (`prod-stack`'s default), or `evo-t1-coder-stack`, the checkout folder's name, for a stack brought up by hand | `evo-t1-dev` |
| Stack runner (default project) | `prod-stack` (`evo-t1-prod`) | `dev-stack` (`evo-t1-dev`) |
| Env file (host ports) | `.env`, which compose reads when `--env-file` names none | `dev-stack.env` |
| Volume prefix | `evo-t1-prod_`, or `evo-t1-coder-stack_` for a hand-raised stack | `evo-t1-dev_` |

`evo-t1-prod` and `evo-t1-coder-stack` are two projects, not two spellings of one:
`prod-stack` addresses the first unless `-p` names another.

### Bring either one up

The stable stack, from anywhere, because the project name travels. `prod-stack` names the
stable project for you - `evo-t1-prod` by default, and `-p` (or `PROD_PROJECT` on the
`make` shim) names another:

```sh
bazelisk run //scripts:prod-stack -- up
```

A stable stack you brought up by hand lives under the checkout folder's name, so name
that folder; `prod-stack` does not guess it, and `dev-stack` takes the same flag:

```sh
bazelisk run //scripts:prod-stack -- up --project-name evo-t1-coder-stack
```

The dev stack - the dev project, on ports shifted by 10000:

```sh
bazelisk run //scripts:dev-stack -- up
```

Stop either one and keep its volumes:

```sh
bazelisk run //scripts:prod-stack -- down
```

```sh
bazelisk run //scripts:dev-stack -- down
```

Check what is actually running before you destroy anything. Each runner reports its own
project, so ask both:

```sh
bazelisk run //scripts:prod-stack -- status
```

```sh
bazelisk run //scripts:dev-stack -- status
```

### Give the dev stack its own ports

It needs them to coexist with a running stable stack. Copy `.env`, keeping the secrets
and the LAN host, and move every published port by 10000:

```sh
awk -F= '{ if ($1 ~ /^[A-Z0-9_]*PORT$/ && $2 ~ /^[0-9]+$/) print $1 "=" $2 + 10000; else print }' .env > dev-stack.env
```

That maps 3001 to 13001, 443 to 10443, 80 to 10080 and 2112 to 12112.

### Rules that keep them apart

1. `docker-compose.yml` declares no top-level `name:` key, so the project name never
   comes from the file: pass `--project-name`, or run compose from the checkout root
   and let compose derive the name from that folder.
2. A hand-written `docker compose` call takes the name from its own folder, so away
   from the checkout root it needs `-f <path>/docker-compose.yml` and the name.
   `dev-stack` and `prod-stack` always pass both (`-p` and `-f`).
3. The env file comes with the project name: a run naming the dev project reads
   `dev-stack.env` when that file exists, and any other project gets no `--env-file`
   at all, so dev port numbers stay out of a run aimed at another stack. `prod-stack`
   names no env file unless `-e` says so, which leaves the stable stack on the `.env`
   beside the compose file.
4. **One port, one stack.** A dev run on the stable stack's ports cannot bind them
   twice, and a `dev-stack.env` still carrying the stable numbers isolates nothing.
5. `reset` and `down --volumes` destroy data, and naming the stable project there
   destroys the volumes your workspaces live in. `reset` asks for `--yes` first:

   ```sh
   bazelisk run //scripts:dev-stack -- reset --yes
   ```

6. **Scripts that run something inside a container pick the oldest match.**
   `pull-models`, `push-template`, `coder-agents` and `dashboard-password` look their
   service up by label across the whole daemon and use the oldest running container -
   the stable stack's, as long as it came up first. None of the four takes a project
   flag, so stop the stable stack first when a check has to run against the dev stack.
   `storage-clean` is the exception: its `--project-name` defaults to `evo-t1-dev`.

## Develop

Test a stack-affecting change on the dev stack before it becomes a pull request, then
hand its volumes back with `reset --yes`.

### The gates

```sh
bazelisk test //:test-fast
```

```sh
bazelisk test //:lint --test_tag_filters=manual
```

```sh
bazelisk run //:validate
```

```sh
bazelisk run //:fix
```

- `//:test-fast` is hermetic Bats plus two gates: every function under `scripts/` is
  named by a test, and every function has a `# @function` docstring. It builds no
  image and starts no Compose stack.
- `//:fix` reformats with shfmt; `//:lint` and `//:validate` also run shellcheck,
  buildifier, and the compose / YAML / terraform checks.
- Conventions: [docs/project-conventions.md](docs/project-conventions.md). Bazel
  itself: [docs/contribute/building-with-bazel.md](docs/contribute/building-with-bazel.md)
  and [docs/contribute/test-with-bazel.md](docs/contribute/test-with-bazel.md).

### The `make` shims

They delegate to the same targets (`test`, `lint`, `fix`, `validate`,
`stack-up`/`stack-down`/`stack-status`/`stack-logs`/`stack-reset` and the five
`prod-stack-*` twins). The `stack-*` shims pass `PROJECT` (default `evo-t1-dev`, the dev
stack) and the `prod-stack-*` shims pass `PROD_PROJECT` (default `evo-t1-prod`, the
stable stack, on default ports) as `--project-name`, so either family can be repointed
at another project:

```sh
make stack-up PROJECT=evo-t1-coder-stack
make prod-stack-up PROD_PROJECT=evo-t1-coder-stack
```

Bazelisk is still the ingress and the shim only saves typing the flag - the same call
is `bazelisk run //scripts:prod-stack -- up --project-name evo-t1-coder-stack`.

### Branching

`main` is the only long-lived branch and it stays green and deployable: every machine
is built from `main`, so a merge to `main` is by definition deployable to a stack host.
Feature work happens on short-lived `feat/`, `fix/`, `refactor/` and friends cut from
the tip of `main`, integrate by pull request into `main`, and are deleted on merge.
Rules, the branch protection behind them, and the commit prefixes are in
[CONTRIBUTING.md](CONTRIBUTING.md) and [docs/branching.md](docs/branching.md).

## After a git pull

From a **host** shell, in the checkout:

```sh
git pull
bash scripts/setup-host.sh --repair
bazelisk run //scripts:update-configs -- all
bazelisk run //scripts:prod-stack -- up
```

`--repair` is the recovery Bazel cannot do itself. Leftover Docker bind-mounts in
`bazel-out/.../prod-stack.runfiles` (a directory sitting where
`homepage/assets/icons/evo-t1.svg` belongs, or a root-owned copy) make the next
`bazelisk run //scripts:prod-stack` die with `FileAccessException ... Permission
denied` before the stack script starts. On Linux it also installs public DNS
(`1.1.1.1` / `8.8.8.8`) beside Tailscale MagicDNS so `git pull` still resolves
`github.com`. `make prod-stack-up` runs `--repair` first. `--check` lists
leftovers and whether `github.com` resolves, and writes nothing.

`update-configs env` on a TTY keeps every value you already set, reuses a sibling
env file (`.env` filling `dev-stack.env`) for a new key, and walks you through new
keys, placeholders (`change-me…`, `NOTSET`, `YOUR_LAN_IP`) and empty values.
`--dry-run` is the report-only shape. `workspace` re-materialises the stack-owned
copies inside running workspaces; a file you hand-edit is left alone. Run
`workspace` from a **host** shell - inside a workspace the `docker` CLI only reaches
that workspace's own DinD sidecar, which is why `status` there prints which daemon
it asked.

If `git pull` itself fails with `Could not resolve host: github.com`, Docker or
Kasm has made Tailscale MagicDNS (`100.100.100.100`) unreachable and it was the
only nameserver. Run the copy-paste under
[troubleshooting.md](docs/troubleshooting.md) (`Could not resolve host: github.com`)
on the current checkout, then `git pull`. After that, `bash scripts/setup-host.sh --repair`
is the durable path (Linux: resolved drop-in plus `tailscale set --accept-dns=false`,
MagicDNS kept for `ts.net`).

A dev stack that remapped `LITELLM_PORT` away from 4000 needs that address named
too: `bazelisk run //scripts:refresh-configs -- --litellm-url http://host.docker.internal:<PORT>/v1`
re-renders `settings.json` against that stack's own LiteLLM port, where the default
`http://host.docker.internal:4000/v1` names the stable stack's.
[config-updates.md](docs/config-updates.md) has both passes, the flags, and what the
tool refuses to do. [troubleshooting.md](docs/troubleshooting.md) quotes both error
strings.

## Public subdomains (optional)

The default shape is LAN-only. One extra `.env` variable, `STACK_PUBLIC_HOSTS`
(comma-separated), additionally serves the same four services on public names over real
TLS. Full detail, including what `bootstrap` rewrites and how to check the Traefik
side, is in [docs/public-access.md](docs/public-access.md).

### The four names

| Name | Upstream |
|---|---|
| `gmktecbeast.overeazy.io` | `homepage:3000` |
| `coder-gmktecbeast.overeazy.io` | `coder:3000` - plain listener |
| `kasm-gmktecbeast.overeazy.io` | `https://kasm:4443` (TLS verify off) |
| `litellm-gmktecbeast.overeazy.io` | `litellm:4000` |

### Get the naming right

- Each name is **one label under the zone**, and each service prefix joins it with a
  **hyphen**.
- A wildcard certificate covers exactly one label, so the dotted two-label form
  (`coder.gmktecbeast.`) has no certificate at the public edge - the browser aborts
  with `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` and Traefik never sees the request.
- TLS terminates at the main Traefik on the other machine, which forwards plain HTTP to
  the `router` sidecar on this box (`proxy/router.conf`, published on :8080). That
  container holds no certificate and only picks an upstream from the Host header; an
  unmatched Host answers `421` rather than a guess.
- Nothing here replaces the LAN routes: `https://<lan-ip>/` and
  `https://<lan-ip>:3001` keep working.

### Turn it on

1. Set the four names in `.env` - and in `dev-stack.env` too if a dev stack runs
   beside the stable one.

   ```text
   STACK_PUBLIC_HOSTS=gmktecbeast.overeazy.io,coder-gmktecbeast.overeazy.io,kasm-gmktecbeast.overeazy.io,litellm-gmktecbeast.overeazy.io
   ```

2. Re-run bootstrap:

   ```sh
   bazelisk run //scripts:bootstrap
   ```

3. Recreate the stack you are switching (both, if both are up). `prod-stack` names the
   stable project for you; `dev-stack` needs `--project-name` to reach it from away
   from the checkout root:

   ```sh
   bazelisk run //scripts:prod-stack -- up
   ```

   ```sh
   bazelisk run //scripts:dev-stack -- up --project-name evo-t1-coder-stack
   ```

   ```sh
   bazelisk run //scripts:dev-stack -- up
   ```

### Two things to know

- **Authelia:** the four names 302 to `https://authelia.overeazy.io/`, because those
  zones already have a policy in front of them. Put LiteLLM behind it and every client
  breaks - LiteLLM authenticates from the `Authorization` header, and header-carried
  API traffic cannot pass an interactive sign-in.
- **Workspace agents never reach Authelia either way:** the template rewrites the agent
  URL to `http://host.docker.internal:3002`, so agent traffic stays on the box.

## LiteLLM model aliases

Workspaces and desktops always talk to one base URL -
`http://host.docker.internal:4000/v1` with `LITELLM_MASTER_KEY` - and pick a model
alias. The internals (pinning TTLs, `least-busy`, the `agent` -> `coder` fallback, the
measured 30-request burst, the **Agent backend** card) are in
[docs/litellm-routing.md](docs/litellm-routing.md).

| Alias | Model | Backend | Structured tool calls |
|---|---|---|---|
| `agent` | `Qwen3.8-Flash-Next` | `SPARK1/2/3_OPENAI_URL` (TensorFold on :8888, optional) | yes (measured) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |

### The one fact that changes what you can run

**The Qwen2.5-Coder weights do not emit structured tool calls on this runtime.**
Measured against this box's IPEX-LLM Ollama (its bundled `ollama` 0.9.3): a request
with `tools` for `qwen2.5-coder:32b` and `:14b` comes back as plain text with
`finish_reason: "stop"` and no `tool_calls` field - the model writes the JSON call into
the message body, which no agent driver can consume. `qwen2.5:7b` on the same runtime
does return a real `tool_calls` array, so the limitation tracks the model, and agent
mode needs either the Spark `agent` lane or the small `chat` model. Grok Build, Cline,
Roo and Kilo therefore default to `agent`.

### Edit an alias

1. Edit `litellm/config.yaml`.
2. Restart the proxy on the stack you changed. Stable:

   ```sh
   docker compose -p evo-t1-coder-stack -f docker-compose.yml restart litellm
   ```

   Dev:

   ```sh
   docker compose -p evo-t1-dev --env-file dev-stack.env -f docker-compose.yml restart litellm
   ```

   Neither runner has a `restart` subcommand; `bazelisk run //scripts:prod-stack -- status`
   and `bazelisk run //scripts:prod-stack -- logs litellm` read the stable stack back
   before and after that call.

The two tool-capable aliases also back the control-plane chat: `scripts/coder-agents.sh`
registers `agent` (default) and `chat` as the Coder Agents chat model configs, so an
alias edited or deleted here moves in the Agents model dropdowns exactly as it does in
the CLI.

## Coder workspace templates

Two templates live under `templates/`, and the push covers both: `workspace` (the plain
dev container, `templates/workspace/`) goes first and `devcontainer` (the DinD-backed
one, `templates/devcontainer/`) last - a dependent template pushes last so a partial
failure leaves the base template usable. What each one puts inside a workspace, the
template variables and their defaults, and the create-form fields are in
[docs/coder-templates.md](docs/coder-templates.md).

### Push them

Both, in order:

```sh
bazelisk run //scripts:push-template
```

One of them, to retry just that one (an unknown name is an error that lists the known
names, so a typo cannot quietly do nothing):

```sh
bazelisk run //scripts:push-template -- devcontainer
```

### Three things to know before you edit one

1. **Everything Coder-facing runs inside the coder container**, against
   `http://127.0.0.1:3000` - the server's own plain listener, reached without crossing
   the reverse proxy, Authelia, or the WAN. That is deliberate: `coder login` on the
   host must reach the API *before* it has a credential, and in public mode the only
   URL it will use is `CODER_ACCESS_URL`, which Authelia gates. Loopback inside the
   container cannot be gated, and the push runs the image's own `coder` binary, so
   client and server are the same build. No host coder CLI and no `coder login` here.
2. **The credential is minted, used and deleted**: a short-lived row inserted into the
   stack's own Postgres - the same trust model as `coder reset-password`. It is scoped
   to minutes, deleted on the way out (including on a failed or interrupted run), never
   printed, and minted once for the whole run however many templates it covers.
3. **The source travels as a tar on stdin** (`templates push --directory -`), so
   nothing is copied into the container or its volumes - and a push is the only thing
   that registers a template, because Coder stores the source as a Filestore row, not
   as files it scans on disk.

### Also worth knowing

- `templates/common/` exists once and both templates consume it:
  `GROK_BUILD_AGENTS.md` (the seed text the startup scripts inline) and
  `vscode-alt.svg` (the editor icon), staged beside each staged `main.tf` and read
  there with `file()` / `filebase64()`. The SVG stays small enough that the
  inlined data URL fits Coder v2.36's 256-character `workspace_apps.icon` column.
  A push missing either payload, or an SVG that would overflow that column, fails
  early by design. Every other `.tftpl` payload is copied per template - edit both twins.
- `bootstrap.sh` calls the same push, and skips with a one-line reason while the coder
  or db container is down or nobody has registered yet.
- A template whose push or verification failed is counted in the
  `N of M template(s) did not reach an active version` line and makes the run exit
  non-zero, while every other template still gets its push attempt.

## Workspaces, terminals and agents

Deep detail: [docs/grok-build-and-agents.md](docs/grok-build-and-agents.md) and
[docs/coder-templates.md](docs/coder-templates.md).

### Create a workspace from a git URL

`bazelisk run //scripts:new-workspace -- <git-url> [name]` picks the template by
shallow-cloning the repository on the host and looking for a dev container:
`.devcontainer/`, `.github/devcontainers/`, or a `devcontainer.json`/`.yml` anywhere in
the tree. Found: `devcontainer`. Not found: `workspace`. Probe failed: `workspace`, with
a warning.

Decision only, creates nothing:

```sh
bazelisk run //scripts:new-workspace -- --dry-run https://github.com/foo/bar.git
```

Create it:

```sh
bazelisk run //scripts:new-workspace -- https://github.com/foo/bar.git
```

Force the plain template:

```sh
bazelisk run //scripts:new-workspace -- --plain git@git.example.com:org/private.git
```

Clone siblings beside the primary repository:

```sh
bazelisk run //scripts:new-workspace -- --additional-repos "url1,url2" https://github.com/foo/bar.git
```

### Flags and credentials

- `--` ends Bazel's own flags, so a URL that begins with a dash still reaches the script.
- Other flags: `--devcontainer`, `--template <name>`, `--plain`, `--dind`,
  `--additional-repos <list>`, `--name <name>`; anything else is an unknown option. A
  workspace name can also follow the URL (Coder names start with a letter; the derived
  default is the repo leaf).
- The clone is a plain `git clone` from the host, so it consults the host's own git
  credentials: a private repository needs a grant covering it on the machine you run
  this from.
- The script always hands `coder create` a `--no-wait`, so the create returns while the
  build runs in the background - watch it with `coder ls` / `coder logs <name>`. It
  passes no `--stop-after`, so a script-made workspace gets no autostop deadline.
- It never mints, reads or stores a token - unlike `push-template.sh`, which mints its
  own because a template push has no other credential path.

### One repository per workspace

- That is the default: one URL, cloned into one folder, and that folder is what
  code-server, the Web Terminal button and the Grok Build session open on. Inside a dev
  container, code-server sees the same folder under its mount target,
  `/workspaces/<repo-name>`.
- `--additional-repos` is the opt-in escape hatch for the service-and-the-library-it-uses
  case. The extras clone **beside** the primary, into sibling folders, by the same
  clone-once rule: a folder that already holds a `.git` is left alone on later starts,
  never pulled on.
- An extra folder never becomes the folder the tools open on, and a private extra
  repository still has to be GRANTED to the connected GitHub account, or its clone is
  refused - like the primary one.

The list format, the two clone paths, and what `--dry-run` prints:
[docs/coder-templates.md](docs/coder-templates.md#cloning-more-than-one-repository).

### Terminals

- The default profile is `tmux`, and the `tmux` profile re-joins one shared session per
  folder (`vscode-<folder>-<hash>`); the automation profile stays `bash`, so build and
  task commands never wait on tmux. With no tmux (offline first boot) the helper execs
  a plain login shell, so the default terminal still opens.
- **Grok Build** keeps its own session, `grok-build-<folder>-<hash>`, keyed off the
  repository root (`git rev-parse --show-toplevel`) and started with
  `grok --cwd <repo root>`.
- `display_apps.web_terminal` stays **off** - it would open a shell on the agent's
  working dir, `/home/coder`. The custom **Web Terminal** `coder_app` (`order = 6`,
  after **VS Code Web** at `order = 5`) takes that slot and `cd`s to the clone folder,
  so the terminal outside the editor starts inside the project too. **GitHub reauth**
  (`order = 7`) sits next to it and opens Coder's `/external-auth/<id>` page so a
  workspace can reconnect GitHub from the agent bar.

### Grok Build state: one shared profile per user

- `~/.grok` is a **second, nested** mount inside the per-workspace `/home/coder`
  volume: one Docker volume per person, `grok-profile-<owner-id>`, referenced by name
  rather than declared as a Terraform resource, mounted read-write at the same path by
  every workspace of that owner **while that workspace is in `shared` mode**.
  `config.toml`, `skills/`, `memory-v2/`, `sessions/` and a self-installed CLI under
  `~/.grok/bin` are all shared, so configuring the CLI once configures the rest of that
  account's workspaces.
- Two settings, two places: the template variable `grok_profile_mode` (default
  `shared`, from `GROK_PROFILE_MODE` in `.env`) and the create form's per-workspace
  **Grok profile** field. `private` gives one workspace its own `~/.grok` on its home
  volume, so it can sit outside the shared profile while its siblings stay inside.
- Switching modes needs a **rebuild** (the nested mount either exists or it does not),
  and a workspace that goes `shared` -> `private` starts on an empty profile: nothing
  is copied, and the shared volume is left alone.
- One shared profile is one `config.toml` for every workspace that owner owns, and the
  last boot to re-render it wins - which is also true of the SQLite memory and index
  files, so *roughly in sync* is the bar, not transactional sharing.
- Five offline MCP stdio servers ship pre-installed but stay undeclared by default, and
  `searxng` (host 8181) is the search lane, not a model transport:
  `bazelisk run //scripts:search-check` measures it. It reaches the agent as the
  `searxng` MCP stdio server, declared by default (`search_mcp` defaults to true;
  `SEARCH_MCP=false` in `.env` opts a whole stack out). Grok's native search lane
  stays off (`disable_web_search = true`) as the easy fallback when the self-hosted
  one is down.
- Two further servers are opt-in and off by default: `github` (`GITHUB_MCP=true`) and
  `context7` (`CONTEXT7_MCP=true`, then re-push templates). Context7 runs the official
  docs server behind `mcp-cache-proxy`, so the first lookup of a library needs network
  and `CONTEXT7_API_KEY` while repeats inside the 12 h TTL come from local SQLite. Long
  form: [docs/grok-build-and-agents.md](docs/grok-build-and-agents.md).

### Coder Agents (control-plane)

- A coding agent that lives in the Coder **server** - a chat UI and an API beside your
  workspaces, not inside one. Its tools (`read_file`, `edit_files`, `execute`,
  `spawn_agent`) run against a workspace over that workspace's agent connection, after
  it consults an **instructions** file and any **skills** it discovers.
- **Always on; nothing to enable.** `CODER_EXPERIMENTS` in `.env` (empty by default
  since 2026-10-08) has never gated anything about it - the old `agents` entry was not
  a recognized experiment name, so the server just logged `ignoring unknown experiment`
  on every boot. `workspace_external_agent` gates *external* agents (Claude Code,
  Codex, ...), and nothing here needs it.
- The delegation sketch lives in `templates/common/GROK_BUILD_AGENTS.md`.

## Kasm

- **First boot:** `https://<host>:3000` - run the install wizard once.
- **After install:** the UI is on `https://<host>:4443` (`KASM_UI_PORT`). That variable
  has to match on **both** sides of the port mapping: the daemon-side listener listens
  on that number, so `4443:4443` is the mapping, not `4443:443`.
- The image ships default users (`admin@kasm.local` / `user@kasm.local`) - change them
  during the wizard.
- Keep Kasm LAN-only unless you have decided who is allowed to reach the public name
  (see [SECURITY.md](SECURITY.md)).

Details, including how to reset it: [docs/dashboard.md](docs/dashboard.md).

## Homepage dashboard

The [Homepage](https://gethomepage.dev) dashboard is the landing page: a card per
service with live status from each service's own API (Coder version, LiteLLM health and
alias count, Ollama version), plus a header of boxed tiles - host CPU, memory, CPU
temperature, disk, `eth0` throughput - beside the clock, local weather (open-meteo,
keyless) and a DuckDuckGo search.

- **URL:** `https://<host>/` - self-signed cert, so expect a one-time browser warning;
  port 80 redirects to HTTPS.
- **Login:** homepage v2's built-in gate, with `HOMEPAGE_AUTH_PASSWORD`. Worth keeping:
  the dashboard lists every service on the box. Rotate it:

  ```sh
  bazelisk run //scripts:dashboard-password
  ```

  Or type your own:

  ```sh
  bazelisk run //scripts:dashboard-password -- --prompt
  ```

- **Config:** `homepage/config/*.yaml` plus `custom.css`, each bind-mounted read-only,
  so `git diff` stays the record of dashboard changes.
- **After a recreate, revalidate once** - v2.4.0 serves a prerendered page with the
  settings baked in, so a fresh container shows an empty default layout until the
  config is re-read. Click the refresh button in the header, or:

  ```sh
  curl -k -X POST https://<host>/api/revalidate
  ```

- **The docker socket stays unmounted.** Service status comes from each service's API,
  which avoids handing the dashboard a root-equivalent host credential.
- **Host stats caveat:** CPU, memory, CPU temp and disk are host-wide through `/proc`,
  but a network widget only sees the container's netns (`lo`/`eth0`), so that tile
  shows `eth0`.

Full detail (mounts, `custom.css`, widget URLs, the wallpaper trick):
[docs/dashboard.md](docs/dashboard.md).

## Memory budget

96 GB DDR5, CPU + iGPU unified. Only models you actually load are resident; Ollama
keeps them in RAM until they age out.

| Item | Typical footprint |
|---|---|
| `qwen2.5-coder:32b` (Q4) | ~20 GB weights + 4-8 GB KV cache / activations |
| `qwen2.5-coder:14b` | ~10 GB |
| `qwen2.5:7b` | ~5 GB |
| Each Coder workspace | 2-8 GB depending on toolchain |
| Coder + Postgres + LiteLLM | ~2-3 GB |
| Kasm desktop session | 4-16 GB (more for GPU apps) |
| Homepage + nginx sidecar | ~120 MB measured (`docker stats`: 100 + 18 MiB) |

## What not to run here

- **Training / fine-tuning.** This box is for inference and dev workspaces.
- **Public internet exposure beyond the optional mode above.** The default install
  assumes a trusted LAN or VPN: the dashboard has an nginx sidecar with a self-signed
  cert and its own password gate, which is far short of a real reverse proxy, and
  nothing at all stands in front of Coder, LiteLLM or Kasm.
- **Heavy video encode or render.** The Arc 140T is strong for LLM inference; do not
  plan media pipelines around it.
- **Multi-tenant teams.** A handful of trusted users, not an org-wide SaaS.
- **CI that downloads models.** No pipeline here pulls 40 GB of weights; model pulls
  are a manual `bazelisk run //scripts:pull-models`.

## Why this shape

- **IPEX-LLM over vanilla Ollama (CPU/Vulkan):** the IPEX-LLM runtime is Intel's XPU
  path (oneAPI / Level Zero) for the Arc stack. `OLLAMA_NUM_GPU=999` offloads every
  layer to the 140T, and the iGPU pulls weights straight out of the 96 GB DDR5.
  Vanilla Ollama on an Intel iGPU is effectively CPU-bound and several times slower on
  a 32B coder model. `runners=[ipex_llm]` in the ollama logs is that GPU backend
  confirming itself:

  ```sh
  bazelisk run //scripts:dev-stack -- logs --tail 200 ollama
  ```

- **MoE over dense:** `qwen2.5-coder:32b` is a Mixture-of-Experts model - 32B-class
  quality with far fewer active parameters per token, which is the sweet spot on a
  memory-rich but bandwidth-constrained iGPU.
- **One LiteLLM front door:** workspaces see a stable OpenAI-compatible URL and alias
  names, so you can flip `coder` from the local Arc to a Spark box, or add an alias,
  and no workspace setting has to change.
- **Kasm on the same box:** the 96 GB runs a desktop (X11 + GPU) beside the local
  models, so "open a full desktop when the editor is not enough" is one Kasm click away.

The full version of these three: [docs/litellm-routing.md](docs/litellm-routing.md#why-this-shape).

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
├── searxng/settings.yml   # SearXNG metasearch config, mounted read-only
├── scripts/
│   ├── bootstrap.sh          # .env + secrets + access URL + certs + checks
│   ├── build-dev-image.sh   # builds images/dev -> evo-t1-dev:latest
│   ├── coder-agents.sh      # wires the control-plane chat agent
│   ├── dashboard-password.sh # rotate the dashboard login password and apply it
│   ├── dev-stack.sh         # up / down / status / logs / reset for one compose project
│   ├── github-auth.sh       # GitHub credential doctor
│   ├── lib/                 # sourced-only helpers (no Bazel target of their own)
│   ├── new-workspace.sh     # git URL -> workspace: picks the template + parameters
│   ├── pull-models.sh       # pulls OLLAMA_MODELS into the IPEX-LLM container
│   ├── prod-stack.sh        # up / down / status / logs / reset for the stable stack
│   ├── push-template.sh     # pushes both templates from inside the coder container
│   ├── refresh-configs.sh   # re-materialize the tracked config seeds in a workspace
│   ├── search-check.sh      # probe the search lane, one GET per engine x query
│   ├── setup-host.sh        # the one script run straight from a shell
│   ├── spark-configure.sh   # assert the per-Spark setup; --apply writes the override file
│   ├── spark-verify.sh      # read-only fleet check
│   ├── storage-clean.sh     # interactive janitor for the persistent layer
│   ├── update-configs.sh    # after a pull: port the env files, reseed workspace config
│   └── validate.sh          # the local gate behind //:validate
└── templates/
    ├── common/                   # single-copy payloads, staged beside each main.tf
    │   ├── GROK_BUILD_AGENTS.md  # the seed text the startup scripts inline
    │   └── vscode-alt.svg        # the code-server editor icon
    ├── workspace                 # plain dev container (base template, pushed first)
    │   ├── main.tf
    │   ├── coder.tf
    │   ├── startup.sh.tftpl          # staged workspace bootstrap (blocking)
    │   ├── settings.json.tftpl       # editor-settings seed
    │   └── grok-config.toml.tftpl    # ~/.grok/config.toml
    └── devcontainer              # clones repo_url and, toggle on, builds its
                                   # .devcontainer on an always-on DinD sidecar;
                                   # pushed second
```

## Troubleshooting

One line each: the symptom and the first thing to check. The full entry for every line -
cause, recipe, and what a fix costs - is in
[docs/troubleshooting.md](docs/troubleshooting.md).

- **Grok agent mode narrates instead of calling tools** - an Arc alias answered. Check
  the dashboard's **Agent backend** card, or probe the fleet with
  `bazelisk run //scripts:spark-verify -- --no-tests`. Keep `SPARK_n_API_KEY`
  non-empty: an empty key fails every request inside the proxy before it reaches the box.
- **Coder Agents chat refuses every prompt, or its model dropdown is empty** - this
  deployment has no model config: `bazelisk run //scripts:coder-agents -- --dry-run`
  then `-- --apply`.
- **Workspace stuck in *starting*** - startup is blocking by design, so the reason is in
  the workspace startup log (`coder logs <workspace>`).
- **Image missing tools, or the build aborts mid-layer** - a pinned download failed and
  printed `curl: (22)`; compare `images/dev/tool-versions.env` with the upstream release.
- **`grok` or `docker`: `command not found` inside a workspace** - the container started
  on an older golden image. Rebuild it with `bazelisk run //scripts:build-dev-image`,
  then rebuild the workspace: the image is fixed at create time.
- **`Cannot connect to the Docker daemon at tcp://dind:2375`** - the sidecar is
  unhealthy, its image was never pulled, or the workspace was created with DinD off.
  `DOCKER_HOST` is only injected when the toggle is on under the `workspace`
  template, and always under `devcontainer`, so read the *docker-in-docker* tile
  rather than the variable. An absent image fails the build at **plan** time with
  `did not find docker image 'docker:29.8.1-dind'`.
- **`pq: value too long for type character varying(256)`** from `push-template` -
  `coder_app.code_server` inlined a `vscode-alt.svg` whose data URL overflowed
  Coder v2.36's `workspace_apps.icon` `varchar(256)` column. The SVG is a compact
  ribbon now, and `push-template` rejects a too-large copy locally. Pull the fix
  and re-run `bazelisk run //scripts:push-template` on the stack host.
- **`lookup registry.terraform.io on 127.0.0.11:53: server misbehaving`** from
  `push-template` - Terraform init inside `coder` cannot reach the provider
  registry because Docker's embedded DNS is forwarding to Tailscale MagicDNS.
  Recreate `coder` so compose's public DNS upstreams apply, then re-push:
  `bazelisk run //scripts:prod-stack -- up` and
  `bazelisk run //scripts:push-template`.
- **`Error: No configuration files`** from `push-template` - the tar stored
  runfiles symlinks and Coder unpacked them into an empty Terraform directory.
  Pull the fix and re-run `bazelisk run //scripts:push-template` on the stack host.
- **`... .terraform.lock.hcl is missing`** from `push-template` - a note, not a failure:
  no lockfile is committed under `templates/`.
- **`unexpected non-JSON response "text/html; charset=utf-8"`** from a host `coder`
  command - it is talking to a public subdomain and Authelia is answering its API calls
  with the sign-in page, which happens with a valid token too. Point the CLI at the
  container's loopback listener, which nothing can gate; `CODER_ACCESS_URL` itself stays
  the public name, because browsers need it.
- **Workspace cannot reach LiteLLM** - `CODER_ACCESS_URL` has to be an `https://` URL (a
  LAN IP, or the public coder name in public mode; never `localhost` / `127.0.0.1`) and
  the workspace has to resolve `host.docker.internal`. Agent traffic ignores that URL
  and dials `host.docker.internal:3002`. A failing **LiteLLM** button is the other
  lane: the app link rides the coder name on a `/@<owner>/<ws>.<agent>/apps/<slug>`
  path, so `curl` on the `litellm` subdomain tells you nothing about it.
- **Browser editor (code-server) stays unhealthy** - check the three in order: the
  install script's log in the Scripts/Log tab, `curl -fsS localhost:13337/healthz` from
  inside the workspace, and whether the browser is on `https://` with a trusted cert
  (plain `http://` is an insecure context, which is what breaks `crypto.randomUUID()`).
- **Private-repo clone or push denied while a credential is present** - the **grant**
  is the problem, not the credential format: a connected-but-unscoped credential
  authenticates and is still refused (403, or 404 where GitHub hides a private repo's
  existence). A public repo answers read probes for any authenticated caller, so a
  passing read proves nothing about push. It covers `https://github.com/...` remotes
  only, so a `git@github.com:` or `ssh://` URL needs an SSH key you placed yourself,
  which this stack provisions nowhere. Reconnect from the workspace page with
  **GitHub reauth**, then restart so `GH_TOKEN` matches the new grant. The doctor
  answers "can this credential WRITE to that repo?":
  `bazelisk run //scripts:github-auth -- check [container] [repo-url]`
  from a host shell, or the same command without the container slot from inside a
  workspace (SELF mode). It answers per credential and marks a credential that the
  agent env token outranks as `shadowed`, since git and gh consult that pair first.
- **Kasm wizard gone after install** - expected; use :4443. Reset means removing the
  `kasm-data` volume, which destroys all Kasm config.
- **Coder login problems** - the first registered account is the site admin. If the UI
  is unreachable, check `CODER_ACCESS_URL` matches the address you are browsing from
  (the LAN IP by default, or the public coder name in public mode).
