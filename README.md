# EVO-T1 Coder Stack

[![Docs](https://img.shields.io/badge/docs-toxicoder.github.io-2563eb)](https://toxicoder.github.io/evo-t1-coder-stack/latest/)

One `bazelisk run //scripts:prod-stack -- up` turns a GMKtec EVO-T1 (Intel Ultra 9
285H, Arc 140T iGPU, 96 GB DDR5) into a self-hosted dev-workspace server.

- **Coder** - the control plane: provisions one Docker container per workspace.
- **IPEX-LLM Ollama** - local models on the Arc 140T. **LiteLLM** is the one
  OpenAI-compatible door in front of them, plus optional NVIDIA Spark boxes.
- **Kasm Workspaces** - streams desktops. **Homepage** - the dashboard that links them
  all and shows live status.
- **Hermes** - on-device host assistant (official Web Dashboard on :9119, Chat tab
  with approval prompts). LAN `:9119` stays; the public name is opt-in with the
  other public hosts.
- **SearXNG** - the keyless metasearch lane.

The box runs **two isolated copies** of the stack on purpose: a *stable* one you work
in and a *dev* one you break. [Spin up the stack](#spin-up-the-stack) has the
commands; [Two stacks on one box](#two-stacks-on-one-box) explains the split.

Everything is a Bazel target, addressed as `bazelisk run //scripts:<stem> -- <args>`
(`<stem>` is the file name under `scripts/`). On the stack host,
`scripts/setup-host.sh` is the one script meant to run straight from a shell, and it
runs before Bazel exists. On a laptop, reopen this repo in the
[contributor dev container](docs/contribute/devcontainer.md) or run
`bazelisk run //scripts:test-in-image`.

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
   [Hermes host assistant](#hermes-host-assistant),
   [Memory budget](#memory-budget), [What not to run here](#what-not-to-run-here)
12. [Why this shape](#why-this-shape), [Repo layout](#repo-layout),
    [Troubleshooting](#troubleshooting)

The long version of each topic is a page of its own, published at
[toxicoder.github.io/evo-t1-coder-stack/latest](https://toxicoder.github.io/evo-t1-coder-stack/latest/)
and kept in `docs/` beside this file:
[coder-templates.md](docs/coder-templates.md), [dashboard.md](docs/dashboard.md),
[hermes.md](docs/hermes.md),
[grok-build-and-agents.md](docs/grok-build-and-agents.md),
[litellm-routing.md](docs/litellm-routing.md),
[public-access.md](docs/public-access.md), [config-updates.md](docs/config-updates.md),
[troubleshooting.md](docs/troubleshooting.md). Each page opens with what is on it and
what reading it lets you do.

That address only serves once the repository's **Settings → Pages → Source** is set to
`gh-pages` (root `/`) — a one-time flip, since the first successful *Deploy
Documentation* run is what creates the branch.

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
  |                  (default + role fallbacks), native web_search parked, and the
  |                  github, context7 and searxng MCP servers on by default
  |                * Cline / Kilo Code ---> host.docker.internal:4000
  |
  +-- :4000 ----> LiteLLM proxy (master key, model aliases)
  |                 +-- local:  http://ollama:11434 (compose network only)
  |                 +-- remote: SPARK1/2_OLLAMA_URL (Ollama aliases) and
  |                 |           SPARK1/2/3_OPENAI_URL (TensorFold on :8888 -
  |                 |           one `agent` group, one deployment per Spark box,
  |                 |           the only tool-capable path)
  |
  +-- :9119 ----> Hermes Web Dashboard (host assistant; Chat tab + approvals;
  |               basic auth). LAN port stays; the public name is opt-in and
  |               arrives through the :8080 router. Models via LiteLLM.
  |
  +-- (no host port) IPEX-LLM Ollama on the Arc 140T (/dev/dri)
  |
  +-- :8181 ----> SearXNG metasearch (loopback + LAN face) - keyless engines only,
  |               no key, no account, no request logging. A workspace reaches it
  |               through the host gateway, so the workspace networks stay untouched.
  |               Both templates render it into the workspace config.toml as the
  |               MCP server `searxng` (gated on `search_mcp`, default on), which is
  |               the search lane. Grok's native web_search is parked
  |               (`disable_web_search = true`): no transport here serves that tool
  |               type, so the proxy rejects it. Measure the SearXNG lane with
  |               `bazelisk run //scripts:search-check` (an empty answer is not
  |               an answered one).
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
   and stays intact when the five public names are on.
7. **Hermes publishes `:9119` with HTTP basic auth.** The public `hermes-*` name is
   the supported opt-in in that same list: Authelia in front, basic auth still on
   (LAN `:9119` and a matching Host on `:8080` never see Authelia), and the docker
   socket still root-equivalent. Traefik aims at `:8080`, not at `:9119`.

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
| 9119 | 19119 | Hermes | Host-assistant Web Dashboard (`HERMES_DASHBOARD_PORT`) - Chat tab + approvals; LAN listener with HTTP basic auth. The public name is opt-in and reaches it through the router on 8080 |
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

3. **Wire the control-plane chat agent.** `prod-stack` / `dev-stack` `up` already start
   this with `--wait` after compose is up, so registering the first account is enough:
   the seeder writes the `litellm` AI provider, the `agent` default plus
   `agent-low` / `agent-medium` / `agent-xhigh` thinking aliases and the `chat`
   fallback, the subagent lane pins, and the system-prompt addendum. No extra Coder UI
   setup. Re-run `--apply` if you skipped that, or print the plan first:

   ```sh
   bazelisk run //scripts:coder-agents -- --dry-run
   ```

   ```sh
   bazelisk run //scripts:coder-agents -- --apply
   ```

4. **Create a workspace.** The sample `REPO_URL` prefills this stack's own repo, so
   **VS Code Web** opens `~/workspace/evo-t1-coder-stack`. A different git URL still
   works from the create form, or:

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

That maps 3001 to 13001, 443 to 10443, 80 to 10080, 2112 to 12112 and 9119 to 19119.

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

The merge-gate runtime is the golden image in `images/dev/`. Open this checkout in the
[contributor dev container](docs/contribute/devcontainer.md), or run
`bazelisk run //scripts:test-in-image --` from a host that is not that container.
Native Darwin `bazelisk test` is a convenience path.

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
bazelisk test //:test-all
```

```sh
bazelisk run //scripts:install-hooks
```

```sh
bazelisk run //:fix
```

- `//:test-fast` is hermetic Bats plus two gates: every function under `scripts/` is
  named by a test, and every function has a `# @function` docstring. It builds no
  image and starts no Compose stack.
- `//:test-all` is the full gate a pull request is reviewed against: `//:test-fast`,
  `//:lint`, the npm-backed docs-site gates, and the measured coverage targets
  (`//tests:shell_coverage`, `//tests:py_coverage`, `//docs-site:unit_coverage`).
  `//:test-fast` only proves a function is *named* by a test; `//tests:shell_coverage`
  runs the suite against an instrumented mirror and proves it is *called*.
- `//scripts:install-hooks` points this checkout's `core.hooksPath` at `.githooks`,
  after which `.githooks/pre-commit` runs the hermetic gate on every commit and
  `.githooks/pre-push` runs `//:test-all` before anything is pushed. CI runs the
  same set again. `//scripts:pre-commit` is the same gate to invoke by hand.
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

From a **host** shell, in the checkout, one command pulls and deploys:

```sh
bazelisk run //scripts:update-stack
```

It runs the whole sequence in the order that makes each step land: fast-forwards
the checkout, re-enters the updated tree, runs the host repair, reconciles the env
files, converges the compose project, restarts the services whose bind-mounted
payload actually changed, pushes the Coder templates, reseeds the running
workspaces, and prints the stack status. It stops the project first when the pull
touched `docker-compose.yml` or an env file, because `up -d` leaves a service
deleted from the compose file running. The payload restart is the part no other
tool here does: editing `litellm/config.yaml` or `homepage/config/services.yaml`
changes the file behind an unchanged bind mount, so `up -d` reports success and
keeps the old process.

Useful flags: `--dry-run` prints the plan and changes nothing, `--stack dev`
drives the dev project, `--restart` forces a stop even for a docs-only pull,
`--pull-images` also runs `compose pull` (what advances the services pinned to a
mutable `:latest` tag), `--branch <name>` deploys another branch, and
`--skip-pull`, `--skip-repair`, `--skip-configs`, `--skip-templates`,
`--skip-workspaces` drop single steps. `--litellm-url` names a remapped
`LITELLM_PORT` for the reseed, the way `refresh-configs` does.

It refuses rather than guesses: a tree with uncommitted changes, a detached HEAD,
and a branch that cannot fast-forward all stop the run before anything reaches the
network (`--allow-dirty` is the way past the first). It never destroys a volume,
never reaches `reset`, and never passes `--force` to a reseed.

The steps it replaces, if you want to run them one at a time:

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

The default shape is LAN-only. Set the naming parts in `.env` (`STACK_DOMAIN_BASE`,
`STACK_SUBDOMAIN_SUFFIX`, `STACK_ENV_LABEL`, the per-service `STACK_*_NAME` keys) and
`STACK_PUBLIC_HOSTS=auto`, and `bazelisk run //scripts:bootstrap` composes the five
public names from them and serves the same five services over real TLS. A
comma-separated list in `STACK_PUBLIC_HOSTS` is still the way to pin a name by hand;
empty stays LAN-only. Full detail, including what `bootstrap` rewrites and how to check
the Traefik side, is in [docs/public-access.md](docs/public-access.md).

### The composed names

Under the shipped defaults (`overeazy.io` + `gmktecbeast`) `auto` composes:

| Name | Upstream |
|---|---|
| `gmktecbeast.overeazy.io` | `homepage:3000` |
| `coder-gmktecbeast.overeazy.io` | `coder:3000` - plain listener |
| `coder-dev-gmktecbeast.overeazy.io` | `coder:3000` - the dev stack's own name |
| `kasm-gmktecbeast.overeazy.io` | `https://kasm:4443` (TLS verify off) |
| `litellm-gmktecbeast.overeazy.io` | `litellm:4000` |
| `hermes-gmktecbeast.overeazy.io` | `hermes:9119` |

The dev row is what `bazelisk run //scripts:dev-stack -- up` composes: it applies
`STACK_ENV_LABEL=dev` for the `evo-t1-dev` project only, and only when neither the shell
nor the env file already sets a label. A label goes on every name, so that stack's
dashboard is `dev-gmktecbeast.overeazy.io` as well. `bazelisk run
//scripts:prod-stack -- up` never invents one.

The rules that make those names work, and what to check when one of them misbehaves,
are on
[docs/public-access.md](docs/public-access.md): the one-label-under-the-zone shape a
wildcard certificate allows, the `bootstrap` run that composes the names and rewrites
the card URLs, the recreate that applies it, the plain-HTTP hop to the `router` sidecar
on `:8080` (every name, including Hermes - not `:9119`), and why the interactive names
302 to Authelia while workspace agents never reach it and LiteLLM stays an API bypass.
The other machine needs one file: the paste-ready Traefik config - five routers, TLS
on all of them, `passHostHeader: true`, Authelia on the four interactive names and the
long-lived timeouts - is
[docs/public-access.md#traefik-configuration](docs/public-access.md#traefik-configuration).

## LiteLLM model aliases

Workspaces and desktops always talk to one base URL -
`http://host.docker.internal:4000/v1` with `LITELLM_MASTER_KEY` - and pick a model
alias. The internals (pinning TTLs, `least-busy`, the `agent` -> `coder` fallback, the
measured 30-request burst, the **Agent backend** card) are in
[docs/litellm-routing.md](docs/litellm-routing.md).

| Alias | Model | Backend | Structured tool calls |
|---|---|---|---|
| `agent` | `Qwen3.8-Flash-Next` | `SPARK1/2/3_OPENAI_URL` (TensorFold on :8888, optional); thinking `xhigh` by default, request can pick `low` / `medium` / `xhigh` | yes (measured) |
| `agent-low` | `Qwen3.8-Flash-Next` | same three Spark boxes as `agent`; thinking baked to `low` | yes (same as `agent`) |
| `agent-medium` | `Qwen3.8-Flash-Next` | same three Spark boxes as `agent`; thinking baked to `medium` | yes (same as `agent`) |
| `agent-xhigh` | `Qwen3.8-Flash-Next` | same three Spark boxes as `agent`; thinking baked to `xhigh` | yes (same as `agent`) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |

One measured fact decides what you can actually run: the Qwen2.5-Coder weights do not
emit structured tool calls on this box's IPEX-LLM Ollama, so agent mode needs the Spark
`agent` lane or the small `chat` model. The measurement, the TTL and `least-busy`
routing, the `agent` -> `coder` fallback, the burst that produced it, and the two
`docker compose restart litellm` commands (one per stack) are on
[docs/litellm-routing.md](docs/litellm-routing.md). `scripts/coder-agents.sh` registers
`agent` (default), the three thinking aliases, and `chat` as the Coder Agents chat
models, so an alias edited here moves in the Agents dropdowns too. There is no `high`
level on this runtime.

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

Why the push runs inside the coder container against `http://127.0.0.1:3000`, how its
short-lived Postgres-minted credential is scoped and deleted, and how the source travels
as a tar on stdin:
[docs/coder-templates.md](docs/coder-templates.md#how-push-template-works).

### Also worth knowing

- `templates/common/` exists once and both templates consume it:
  `GROK_BUILD_AGENTS.md` (the seed text the startup scripts inline),
  `vscode-alt.svg` (the editor icon) and `notes-setup.sh` (the library behind each
  clone's private `notes.md`), staged beside each staged `main.tf` and read
  there with `file()` / `filebase64()`. The SVG stays small enough that the
  inlined data URL fits Coder v2.36's 256-character `workspace_apps.icon` column.
  A push missing any payload, or an SVG that would overflow that column, fails
  early by design. Every other `.tftpl` payload is copied per template - edit both twins.
- `bootstrap.sh` calls the same push, and skips with a one-line reason while the coder
  or db container is down or nobody has registered yet.
- A template whose push or verification failed is counted in the
  `N of M template(s) did not reach an active version` line and makes the run exit
  non-zero, while every other template still gets its push attempt.

## Workspaces, terminals and agents

Deep detail: [docs/grok-build-and-agents.md](docs/grok-build-and-agents.md) and
[docs/coder-templates.md](docs/coder-templates.md).

### Create a new repository from the scaffold

`project-template/` is the repository template this stack ships: governance files,
pinned toolchain, three CI workflows, a test dispatcher, an agent contract, and
per-language lane overlays. `bazelisk run //scripts:new-repo -- <name>` renders it
(substituting `__PROJECT_*__` tokens in contents and paths), creates the GitHub
repository, applies the settings the template asks for, and can queue a Coder task so a
workspace exists the moment you open it.

Plan without touching GitHub:

```sh
bazelisk run //scripts:new-repo -- --dry-run demo-tool --lane shell
```

Deep detail: [docs/new-repo.md](docs/new-repo.md).

### Create a workspace from a git URL

`bazelisk run //scripts:new-workspace -- <git-url> [name]` picks the template by
shallow-cloning the repository on the host and looking for a dev container:
`.devcontainer/`, `.github/devcontainers/`, or a `devcontainer.json`/`.yml` anywhere in
the tree. Found: `devcontainer`. Not found: `workspace`. A tracked
`.devcontainer/contributor-env` is a miss even when `devcontainer.json` sits beside it,
so a Coder workspace of *this* repo stays on `workspace` (the `.devcontainer/` here is
the laptop/CI contributor env). Probe failed: `workspace`, with a warning.

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

### Terminals, Grok Build state and Coder Agents

The `tmux` terminal profiles and the app-bar buttons, what `grok doctor` should report
inside a workspace and which findings are expected there, the one `~/.grok` volume shared
per owner (and what `shared` vs `private` costs on a rebuild), the pre-installed MCP
servers and the `search_mcp` / `GITHUB_MCP` / `CONTEXT7_MCP` toggles, and the
control-plane Coder Agents chat that needs nothing enabled:
[docs/grok-build-and-agents.md](docs/grok-build-and-agents.md).

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

## Hermes host assistant

[Hermes Agent](https://github.com/nousresearch/hermes-agent) is the on-device assistant
for this host: the official Web Dashboard on `:9119` (dev `:19119`), Chat tab with
approval prompts, models through the existing LiteLLM `agent` alias. It mounts the
stack checkout at `STACK_HOST_PATH` and the docker socket (root-equivalent, same
standing as Coder), so approvals stay `manual`.

- **URL:** `http://<STACK_LAN_HOST>:9119` - plain HTTP, basic auth
  (`HERMES_DASHBOARD_USER` / `HERMES_DASHBOARD_PASSWORD` in `.env`). The LAN
  port stays. The public name (`hermes-<suffix>.<base>`, so
  `https://hermes-gmktecbeast.overeazy.io` under the shipped defaults) is
  opt-in with `STACK_PUBLIC_HOSTS=auto`: Authelia in front, the same basic
  auth behind it, Traefik pointed at `:8080`.
- **Approvals:** seeded `manual`; never `off`. `terminal.backend: local` keeps the
  dangerous-command checker on. The docker socket stays root-equivalent.

Full detail (mounts, skills, bootstrap, security): [docs/hermes.md](docs/hermes.md).

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
  nothing at all stands in front of Coder, LiteLLM, Hermes or Kasm until
  `STACK_PUBLIC_HOSTS` is set. Public Hermes is that supported opt-in: Authelia
  plus Hermes basic auth, Traefik aimed at this box's `:8080`, and the container
  still root-equivalent on the docker socket.
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
├── .env.sample            # canonical env template: ports + the public naming parts
│                          #   (.env.example is a copy)
├── .devcontainer/         # laptop/CI contributor env (probe sentinel keeps Coder on workspace)
│   ├── contributor-env    # new-workspace treats this as a miss; do not copy to other repos
│   └── devcontainer.json
├── hermes/                # Hermes seed: config.yaml, SOUL.md, skills (ro-mounted)
├── homepage/config/       # dashboard: services, widgets, settings, bookmarks, custom.css
├── homepage/assets/icons/ # dashboard wallpaper + header logo, served at /icons/
├── images/dev/            # golden workspace image
│   ├── Dockerfile
│   └── tool-versions.env  # every version pin, single source of truth
├── litellm/config.yaml    # model aliases
├── proxy/homepage.conf    # nginx TLS terminator for the dashboard
├── proxy/router.conf      # nginx Host-header router for the public subdomains (no cert):
│                          #   the render below, under the shipped defaults
├── proxy/router.conf.template # the same five vhosts with __EVO_HOST_*__ tokens; bootstrap
│                          #   renders them into proxy/router.gen.conf (gitignored), and
│                          #   STACK_ROUTER_CONF tells compose which one to mount
├── searxng/settings.yml   # SearXNG metasearch config, mounted read-only
├── scripts/
│   ├── bootstrap.sh          # .env + secrets + access URL + certs + router conf + checks
│   ├── build-dev-image.sh   # builds images/dev -> evo-t1-dev:latest
│   ├── coder-agents.sh      # wires the control-plane chat agent (LiteLLM + thinking models)
│   ├── dashboard-password.sh # rotate the dashboard login password and apply it
│   ├── dev-stack.sh         # up / down / status / logs / reset for one compose project
│   ├── github-auth.sh       # GitHub credential doctor
│   ├── hermes-bootstrap.sh  # seed Hermes /opt/data (config.yaml, SOUL.md)
│   ├── install-hooks.sh     # point this checkout's git hooks at .githooks
│   ├── lib/                 # sourced-only helpers (no Bazel target of their own)
│   ├── mcp-check.sh         # prove the Grok Build MCP lanes: binaries, creds, handshake
│   ├── new-repo.sh          # render project-template -> new GitHub repo + Coder task
│   ├── new-workspace.sh     # git URL -> workspace: picks the template + parameters
│   ├── pull-models.sh       # pulls OLLAMA_MODELS into the IPEX-LLM container
│   ├── pre-commit.sh        # the gate the hooks run: hermetic, --all, --image
│   ├── prod-stack.sh        # up / down / status / logs / reset for the stable stack

│   ├── push-template.sh     # pushes both templates from inside the coder container
│   ├── refresh-configs.sh   # re-materialize the tracked config seeds in a workspace
│   ├── search-check.sh      # probe the search lane, one GET per engine x query
│   ├── seed-dev-env.sh      # materialize grok/settings/notes into a laptop or CI home
│   ├── setup-host.sh        # stack-host bootstrap; the one script run straight from a shell
│   ├── spark-configure.sh   # assert the per-Spark setup; --apply writes the override file
│   ├── spark-verify.sh      # read-only fleet check
│   ├── storage-clean.sh     # interactive janitor for the persistent layer
│   ├── test-in-image.sh     # run the Bazel gates inside evo-t1-dev:latest
│   ├── update-configs.sh    # after a pull: port the env files, reseed workspace config
│   ├── update-stack.sh      # one step: git pull, then redeploy what the pull changed
│   └── validate.sh          # the local gate behind //:validate
└── templates/
    ├── common/                   # single-copy payloads, staged beside each main.tf
    │   ├── GROK_BUILD_AGENTS.md  # the seed text the startup scripts inline
    │   ├── notes-setup.sh        # the library that seeds each clone's private notes.md
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

The symptom-first list — the error string, the cause, the recipe, and what the fix costs
— is one page: [docs/troubleshooting.md](docs/troubleshooting.md). The four entries an
operator hits most:

- **Grok agent mode narrates instead of calling tools** - an Arc alias answered. Check
  the dashboard's **Agent backend** card, or probe the fleet with
  `bazelisk run //scripts:spark-verify -- --no-tests`.
- **Workspace stuck in *starting*** - startup is blocking by design, so the reason is in
  the workspace startup log (`coder logs <workspace>`).
- **Private-repo clone or push denied while a credential is present** - the grant is the
  problem, not the credential format. The doctor answers "can this credential WRITE to
  that repo?": `bazelisk run //scripts:github-auth -- check [container] [repo-url]` from
  a host shell, or the same command without the container slot from inside a workspace.
- **`Cannot connect to the Docker daemon at tcp://dind:2375`** - the sidecar is
  unhealthy, its image was never pulled, or the workspace was created with DinD off;
  read the *docker-in-docker* tile rather than the variable.
