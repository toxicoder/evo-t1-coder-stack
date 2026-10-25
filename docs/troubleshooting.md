---
title: Troubleshooting
description: "Symptom-first list of what breaks on this box: the error string, the cause, the recipe, and what the fix costs."
tags: [troubleshooting, operate, errors]
---

**What's on this page**

- Stack bring-up: bootstrap, ports, containers that refuse to start
- The model lane: Spark boxes, LiteLLM, and the agent backends
- Workspaces: startup, the golden image, the toolchain inside them
- Docker-in-Docker, Terraform, and the host `coder` CLI
- Editor, credentials, the clone, UI logins, and the public Hermes name (`421`, Chat `4403`)

**What this enables**

- Starting from the error text you actually saw and landing on one command
- Knowing the cost of a fix before running it, including what it destroys

Deep, symptom-first list. The operational `dev-stack`/`prod-stack`, `search-check` and
`spark-verify` targets are described in [README.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/README.md) and
[project-conventions.md](project-conventions.md).

Each fence below is one copy-paste action. A heading quotes the error string where there
is one, so start with `grep -n` on the text you saw.

Placeholders: `<wsid>` is a workspace id and `<ws>` a workspace name. The workspace
container is `coder-<owner>-<ws>` (so `coder-alx-self-coder`); the `<wsid>` form names
the DinD pieces around it - the sidecar `coder-<wsid>-dind-sidecar`, on the network
`coder-<wsid>-dind`, with its own `coder-<wsid>-dind-lib` volume. What runs "from the
stack host" needs a shell there: inside a workspace `docker` addresses that workspace's
own private daemon through `DOCKER_HOST=tcp://dind:2375`, so a `docker inspect` aimed at
the stack's `coder` or `router` container and run from inside a workspace queries the
wrong daemon and answers `no such container`. `bazelisk run //scripts:...` also runs
from the checkout.

## Stack bring-up

### `not a directory: Are you trying to mount a directory onto a file` -> missing compose bind-mount source

Cause: `docker compose` resolved `./proxy/homepage.conf` (or another file bind
mount) next to a compose file that did not have that file. Under `bazelisk run`
that file used to be the runfiles copy, which only holds `//:stack_data`. Docker
then created a directory at the source path and failed mounting it onto nginx's
`/etc/nginx/conf.d/default.conf`, which is a file in the image.

Fix: `homepage/**` and `proxy/*.conf` belong in `//:stack_data`, and the stack
runners prefer `BUILD_WORKSPACE_DIRECTORY` (the real checkout) so relative
mounts and bootstrap-issued `proxy/certs/` resolve there. Re-run from the stack
host:

```sh
bazelisk run //scripts:prod-stack -- up
```

The same command with `dev-stack` brings the dev project up. A leftover
`homepage-proxy` container from the failed create is recreated on that `up`.

A failed bind from an older runfiles compose file can also leave a **directory**
(or a root-owned file) at `homepage/assets/icons/evo-t1.svg` inside
`bazel-out/.../prod-stack.runfiles`. The next `bazelisk run` then dies before
the stack script starts; that spelling is the next heading.

### `FileAccessException` / `Permission denied` on `homepage/assets/icons/evo-t1.svg` -> leftover runfiles bind-mount

Cause: an older `bazelisk run` used the runfiles copy of `docker-compose.yml`, so
compose mounted `./homepage/assets/icons` from `bazel-out`. Docker then created a
directory where `evo-t1.svg` belongs, or the homepage container chowned those
files to root. Bazel cannot recreate `prod-stack.runfiles` over that leftover,
and the stack script never starts, so a repair inside `prod-stack` cannot help.

Fix: recover from a shell, then re-run. `--repair` uses sudo when chmod is not
enough:

```sh
bash scripts/setup-host.sh --repair
bazelisk run //scripts:prod-stack -- up
```

`bazelisk run //scripts:prod-stack -- up` is the command that pair recovers with; the
`make prod-stack-up` (and `make stack-up`) shims run `--repair` before calling that same
target. Bare `bash scripts/setup-host.sh` repairs leftovers and then installs any missing
host tools. `bash scripts/setup-host.sh --check` lists leftover paths without writing.

### `Could not resolve host: github.com` -> Tailscale MagicDNS is the only nameserver

Cause: `/etc/resolv.conf` names only Tailscale MagicDNS (`100.100.100.100`).
Docker's iptables, and Kasm's privileged nested dockerd, can make that stub
unreachable. When it is, **every** lookup dies, including `github.com`, so
`git pull` over HTTPS fails. This is host DNS, not GitHub auth.

On Linux, `bash scripts/setup-host.sh --repair` writes
`/etc/systemd/resolved.conf.d/evo-t1-public-dns.conf` (`DNS=1.1.1.1 8.8.8.8`),
runs `sudo tailscale set --accept-dns=false`, and keeps MagicDNS for `ts.net`
via `resolvectl` split-DNS. `--check` still writes nothing.

A checkout that does not yet contain that `--repair` (the usual case: `git pull`
is already failing) needs the same commands by hand, then pull:

```sh
sudo tailscale set --accept-dns=false
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=8.8.4.4 1.0.0.1\n' | sudo tee /etc/systemd/resolved.conf.d/evo-t1-public-dns.conf
sudo systemctl restart systemd-resolved
git pull
bash scripts/setup-host.sh --repair
```

`--check` prints which nameservers are in play and whether `github.com` resolves.
Other ways to keep a public resolver: add `1.1.1.1` / `8.8.8.8` as a global
nameserver in the Tailscale admin DNS page.

The same MagicDNS-only resolver is what makes Terraform inside the `coder`
container SERVFAIL `registry.terraform.io` (`127.0.0.11:53: server misbehaving`).
That spelling lives under "Terraform and the host `coder` CLI" below. Compose
pins public resolvers on `coder` so a template push does not wait on this host
fix.

## Model lane: Spark, LiteLLM, the agent backends

### How do I know the IPEX-LLM server came up? -> look for `runners=[ipex_llm]`

- The `ollama` service is IPEX-LLM on the Arc 140T, not Ollama from a registry.
- `runners=[ipex_llm]` in its logs is that GPU backend confirming itself.

Stable stack (`prod-stack` addresses the `evo-t1-prod` project by default; name
`--project-name evo-t1-coder-stack` to read a stack brought up by hand under the
checkout folder's own project name):

```sh
bazelisk run //scripts:prod-stack -- logs --follow --tail 200 ollama
```

The same command aimed at the dev stack, so with `dev-stack` and its default
project name (`evo-t1-dev`):

```sh
bazelisk run //scripts:dev-stack -- logs --tail 200 ollama
```

- Flags are accepted before or after `logs`; `--project-name` and `--tail` move either
  way. Only `logs` takes trailing service names, and here that trailing word is the
  service to read.

### Grok agent mode makes no tool calls (it narrates and stops) -> an Arc alias served it

Cause: no Spark box was reachable, so the Arc answered, and the Arc path returns tool
calls as plain text.

- Look at the dashboard's **Agent backend** card first: its per-box widgets go to error
  state while `agent` still answers.
- Probe that endpoint (the card reads the same URL, `AGENT_MODEL_URL` in `.env`):

```sh
curl -sS "${AGENT_MODEL_URL:-http://spark-2.lan:8888/v1/models}" | head -c 200
```

- Or check the whole fleet at once, from the checkout. `spark-verify.sh` takes `--json`
  and `--no-tests`; `--no-tests` skips the recipe's own probes (a 195k-token needle plus
  a 1/2/4/5-client sweep, minutes per box) and leaves the quick read-only check:

```sh
bazelisk run //scripts:spark-verify -- --no-tests
```

- Its host list comes from the `SPARK*_URL` keys in `.env` (`SPARKn_OLLAMA_URL` and
  `SPARKn_OPENAI_URL`), which is why the default run needs no arguments. Export
  `SPARK_HOSTS="host1 host2 ..."` in the process environment only to check a fleet that
  `.env` does not name. A host that does not answer is a skip, not a failure.

Fix, one of these:

- Bring the TensorFold server up on the box. `<host>` is what `.env` names, and `--apply`
  writes the per-host override file that server runs:

```sh
bazelisk run //scripts:spark-configure -- <host> --apply
```

- Or repoint `SPARK1_OPENAI_URL`, `SPARK2_OPENAI_URL` and `SPARK3_OPENAI_URL` in `.env`
  at a tool-capable OpenAI-compatible endpoint, then restart the proxy so it re-reads
  them. The stack runners have no `restart` subcommand, so this one stays a direct
  compose call:

```sh
docker compose -p evo-t1-coder-stack -f docker-compose.yml restart litellm
```

- Either way keep `SPARK_n_API_KEY` non-empty: `SPARK_1_API_KEY`, `SPARK_2_API_KEY`,
  `SPARK_3_API_KEY`. An empty key fails every request inside the proxy before it ever
  reaches the box.
- The `agent` -> `coder` fallback keeps chat answering while a Spark is down, which is
  exactly when tools disappear.

### Coder Agents chat refuses every prompt, or its model dropdown is empty -> no model config

Cause: that chat has no model config on this deployment, so there is nothing to route to.

- First run this to see the plan, then run it again without the flag to apply it:

```sh
bazelisk run //scripts:coder-agents -- --dry-run
```

```sh
bazelisk run //scripts:coder-agents -- --apply
```

- It skips while the coder or db container is down, or nobody has registered yet, and
  re-running it repairs a provider that drifted.

A chat that starts but narrates instead of calling tools is the no-Spark case above.

### Workspace cannot reach LiteLLM -> `CODER_ACCESS_URL`, or `host.docker.internal`

Two lanes reach that port and they share nothing but the destination, so a probe on one
answers nothing about the other.

- The **model lane**: a process inside the workspace dials
  `http://host.docker.internal:4000/v1` directly. `host.docker.internal` is the docker
  bridge gateway (`172.17.0.1`), compose publishes the proxy's container port 4000 on
  host port 4000, and nothing between the two authenticates. `LITELLM_BASE_URL` and the
  coding CLIs use this lane.
- The **app lane**: the **LiteLLM** button in the Coder dashboard, at
  `https://<coder name>/@<owner>/<ws>.<agent>/apps/litellm`. `coder_app.litellm` sets
  `subdomain = false`, so that path rides the *coder* name and `coder:3000`, and
  `litellm-gmktecbeast.` is never consulted. See the next heading.

The checks that apply to either lane:

- `CODER_ACCESS_URL` must be an `https://` URL: a LAN IP, or the public coder name in
  public mode. Never `localhost` and never `127.0.0.1`.
- The workspace container must resolve `host.docker.internal`; the model lane reaches
  LiteLLM through that host gateway, and so does `LITELLM_BASE_URL`.
- Agent traffic ignores that URL and dials `host.docker.internal:3002`; see the
  `coder_agent_url` template variable.

### Search never answers (or answers empty) -> prove the search lane before blaming the MCP hop

Search rides Grok's native `web_search` tool by default (`disable_web_search =
false`). The self-hosted SearXNG MCP stdio server is the fallback, declared by
default (`search_mcp` defaults to true). Two probes split a SearXNG fault in half:

- `bazelisk run //scripts:search-check` (or `scripts/search-check.sh` from a shell that
  can reach the host gateway) dials the service directly. It reads `$SEARXNG_URL`
  before its `http://127.0.0.1:8181` default, and every workspace's agent env carries
  that key, so a workspace-side probe needs no `--url`. It separates engines that
  answered, engines that were unresponsive, and an empty result page.
- `grok mcp doctor searxng` inside the workspace probes the MCP hop. A healthy
  search-check plus a failed handshake points at the server, the URL or the port.

If the SearXNG lane stays down, native search is already on. Park the failing
server with `search_mcp = false` on the next template push (`SEARCH_MCP=false` in
`.env` applies it to every new workspace). To park native search instead, set
`disable_web_search = true` in the workspace's `~/.grok/config.toml` and start a
new session.

### A workspace app link answers `Bad Gateway` -> find who answered

The **LiteLLM** and **Open VS Code Web** buttons are Coder *apps*: their URL is
`/@<owner>/<ws>.<agent>/apps/<slug>` on the coder hostname, because both `coder_app`
blocks set `subdomain = false`. So a failing app link is an app-lane failure, and a 200
from `litellm-gmktecbeast.` is not evidence about it.

Two hops can answer 502 on that path: this box's nginx, when `coder:3000` will not
resolve or connect, and Coder's own Go proxy, whose `ReverseProxy` ErrorHandler
fires when the app upstream answers nothing. Two reads tell them apart, both from
the stack host:

```sh
docker logs --tail 400 coder | grep -i 'failed to proxy request to application'
```

```sh
docker logs --tail 200 router | grep -Ei 'error|502|upstream'
```

- A hit in the first means Coder tried the upstream and gave up, so the fault sits on
  this box: check the devcontainer or workspace container first, then `DOCKER_HOST`.
- `X-Coder-Request-Id` on the response, beside `X-Coder-Build-Version`, means Coder's
  own Go proxy answered, so Traefik and Cloudflare let the request through and the
  fault sits behind them. Nothing on this box sets `Via` or `CF-RAY`.
- `X-Evo-Proxy` names the `server_name` that matched here: `coder`, `litellm`, `kasm`,
  `homepage` or `hermes`. Its absence means the request never reached this box's nginx.
- Neither header, and a `Server: cloudflare` with a `cf-ray` instead: Traefik or
  Cloudflare answered, and there is nothing on this box to read.

To take the same reading from inside the workspace, replay the path on `:8080`, the
published `router` port. That reaches `coder:3000` through the sidecar while
bypassing Traefik, Authelia and the WAN, so a reply there that differs from the
browser's `https://` URL names the cloud hops.

```sh
curl -sS --noproxy '*' -o /dev/null -w 'litellm %{http_code} %{content_type}\n' \
  http://host.docker.internal:4000/health/liveliness
```

```sh
curl -sS --noproxy '*' -o /dev/null -D - -H 'Host: coder-gmktecbeast.overeazy.io' \
  http://host.docker.internal:8080/@<owner>/<ws>.main/apps/litellm
```

`--noproxy '*'` matters: with a proxy set in the environment curl hands the name to the
proxy instead of resolving it, and `000` or a 5xx then describes the proxy.

- `000` on the first probe means nothing listened on 4000. A `200 application/json`
  means LiteLLM answered, so the model lane is healthy and the app lane failed
  somewhere else.
- `000` on the second probe means the private lane is down as well, so the public
  failure is not a cloud-side one. `421` means the Host header matched no
  `server_name` here, which is what a rewritten Host looks like.
- A `404` is what this stack answers for an unknown app slug or an agent that is not
  Connected; the agent is the text after the first `.` in `<ws>.<agent>`.
- Signed into Authelia with the link still failing puts the fault behind Authelia: the
  app path is gated by the same policy as the rest of the coder name.

## Workspaces: startup, images, the toolchain inside them

### Workspace stuck in *starting* -> startup is blocking

- `startup_script` is blocking by design, so a failure there surfaces as a **failed**
  build with the reason in the workspace startup log. The container is not marked
  healthy until the toolchain is staged.

```sh
coder logs <workspace>
```

### Image missing tools, or the build aborts mid-layer -> `curl: (22)`

- Cause: a pinned download returned an error. The layer prints `curl: (22)` and stops
  rather than shipping a partial image.
- Fix: check that version in `images/dev/tool-versions.env` against the upstream
  release, then rebuild the image.

### `grok` -> `command not found` inside a workspace -> the CLI was never installed

Cause: that container started before the CLI was baked into the image, or its
start-time download failed.

- Both of these answer nothing in that case; the first is the one to type:

```sh
bash -lc 'command -v grok'
```

- The same probe in the other spelling: `test -x ~/.grok/bin/grok`.
- `/tmp/coder-startup-script.log` holds exactly one `curl: (28)` line when the
  start-time download was what failed.
- One-off fix, from the stack host:

```sh
docker exec -u coder -i <workspace-container> sh -c 'curl -fsSL --http1.1 --retry 3 --retry-all-errors --retry-delay 3 --connect-timeout 15 --max-time 240 https://x.ai/cli/install.sh | bash'
```

- Then open a new terminal; `PATH` there already includes `~/.grok/bin`.
- Permanent fix: rebuild the image and the workspace, which then starts from the
  image's own copy. See the next two entries for the command.

### `docker` -> `command not found` inside a workspace -> an older image, or the wrong preset

- Cause: that container was built from an image predating the Docker client toolchain,
  or from the bare-Ubuntu *Minimal shell* preset.
- Rebuild the image, then rebuild the workspace; the image is fixed at create time.

```sh
bazelisk run //scripts:build-dev-image
```

### `Permission denied` / `jq: error: Could not open file` on `~/.shared/vscode/settings.json` -> empty named volume is root-owned

Cause: Docker creates an empty named volume as `root:root` 755. The
`vscode-settings-<owner-id>` volume is empty on first use (the image has no
files there to copy in), so `coder` cannot write `settings.json`. `jq` and
`python` then fail because the file was never created. `already cloned, skipping`
on the next line is informational: the clone already exists.

Fix: the template chowns that volume (and the shared `~/.grok` profile volume)
to the home owner before the seed, and skips `jq`/`python` when the write
fails. Push the templates and restart the workspace; there is nothing to delete.

```sh
bazelisk run //scripts:push-template
coder restart <workspace>
```

### Grok profile missing in a fresh workspace -> startup already finished, so read the log

- `startup_script` is blocking, so it finished before the agent reported ready and
  before code-server started. Check the workspace agent logs first.
- Then run `bash -lc 'command -v grok'`. A workspace on a current image answers
  `/usr/local/bin/grok`, so an empty answer means the CLI is missing, not the profile.

## Docker-in-docker

### `Cannot connect to the Docker daemon at tcp://dind:2375` -> the sidecar, or DinD off

Cause: the sidecar is unhealthy, its image was never pulled, or the workspace was
created with DinD off.

- `DOCKER_HOST` is injected per template, not per toggle. `templates/workspace` sets
  it only while the toggle is on; `templates/devcontainer` sets it always, because
  that template always provisions the sidecar and the `devcontainer` CLI has to
  reach its daemon either way. So a set `DOCKER_HOST` tells you the template; the
  *docker-in-docker* metadata tile tells you the state (the devcontainer template
  always reads `on (tcp://dind:2375)`, the workspace one reads `off` when unset).
- Three separate reads, from the stack host. The first prints `unhealthy` rather than
  an error when the daemon fails its own probe, and `no such container` when the
  workspace has no sidecar at all:

```sh
docker inspect --format '{{.State.Health.Status}}' coder-<wsid>-dind-sidecar
```

```sh
docker logs --tail 100 coder-<wsid>-dind-sidecar
```

```sh
docker pull docker:29.8.1-dind
```

- That probe only asks whether the daemon answers `docker version`. It says nothing
  about the workspace that used to reach it.

### `did not find docker image 'docker:29.8.1-dind'` -> plan-time failure, not runtime

- Cause: that image is not in the host's local image store, and Terraform never pulls
  it. The `docker_image` data source only inspects the store.
- So the workspace build fails at **plan** time, before anything is created, and it
  prints in the workspace's build log rather than anywhere inside the workspace.
- Fix with the `docker pull` above, or turn DinD off for that workspace.

## Terraform and the host `coder` CLI

### `lookup registry.terraform.io on 127.0.0.11:53: server misbehaving` from `push-template` -> coder cannot reach the Terraform registry

- Symptom: `bazelisk run //scripts:push-template` queues, then dies during
  "Initializing Terraform Directory". `workspace` cannot list versions for
  `coder/coder` and `kreuzwerker/docker` on `registry.terraform.io`;
  `devcontainer` cannot fetch `module "devcontainers_cli"` from
  `registry.coder.com`. Both lookups fail with
  `dial tcp: lookup … on 127.0.0.11:53: server misbehaving`. Coder itself
  stays up; `bazelisk run //scripts:prod-stack -- logs coder` repeats the same Terraform
  lines.
- Cause: provisionerd runs `terraform init` inside the `coder` container.
  Docker's embedded DNS (`127.0.0.11`) forwards names it does not know to
  the host resolver. When that resolver is Tailscale MagicDNS only, or
  Docker/Kasm iptables has made `100.100.100.100` unreachable from a
  container, every public lookup SERVFAILs. The host CLI is fine; only the
  provisioner job dies. The lockfile reuse lines (`Reusing previous version
  from the dependency lock file`) do not skip the registry: Terraform still
  fetches the discovery document.
- Fix: `docker-compose.yml` sets `dns: [1.1.1.1, 8.8.8.8]` on the `coder`
  service (embedded DNS still answers `db` and other compose names). Both
  templates pin the same resolvers on the workspace and DinD containers so
  a later `git clone` of `github.com` does not hit the same SERVFAIL. Recreate
  `coder` so the new upstreams apply, then push:

```sh
bazelisk run //scripts:prod-stack -- up
bazelisk run //scripts:push-template
```

Host `git pull` still needs a public resolver beside MagicDNS when the host
itself is MagicDNS-only (heading above; `setup-host --repair` on Linux).
Existing workspaces pick up the container DNS on the next start after this
template version is active.

### `pq: value too long for type character varying(256)` from `push-template` -> editor icon data URL

- Symptom: `coder templates push` plans, then dies during "Cleaning Up" with
  `internal provisionerserver error: execute transaction: insert resource: insert
  agent app: upsert app: pq: value too long for type character varying(256)`.
  Coder logs `coder_app's id was unexpectedly empty` and then that Postgres error
  at `inserting template import job resource`.
- Cause: both templates inline `templates/common/vscode-alt.svg` as a
  `data:image/svg+xml;base64` URL on `coder_app.code_server`. Coder v2.36 stores
  `workspace_apps.icon` as `varchar(256)`. A multi-kilobyte SVG produces a data
  URL thousands of characters long, and the insert fails. The provisioner
  reports it at `insert agent app: upsert app`.
- Fix: the SVG is a compact ribbon whose data URL fits the column, and
  `push-template` rejects a too-large copy locally before talking to the server.
  Pull this commit onto the stack host and re-run:

```sh
bazelisk run //scripts:push-template
```

### `Error: No configuration files` from `push-template` -> runfiles symlinks in the tar

- Symptom: both templates fail during "Detecting persistent resources" with
  `Terraform initialized in an empty directory!` / `Error: No configuration files`.
  Coder logs `unpacking source archive  size_bytes=30720` (tens of KB, not the
  ~120 KB of real `.tf` / `.tftpl` contents).
- Cause: `bazelisk run` executes from the runfiles tree, where `templates/**` are
  symlinks into the execroot. A tar that stores those links unpacks in the
  provisioner as dangling paths, so Terraform sees no `.tf` files. The two
  `templates/common/` payloads still land (copied with `cp`, which follows
  links), which is why the archive is small rather than empty.
- Fix: `push-template` now prefers `BUILD_WORKSPACE_DIRECTORY` (the live
  checkout) and stages with `tar -h` so the archive holds regular files. Pull
  this commit onto the stack host and re-run:

```sh
bazelisk run //scripts:push-template
```

### `.terraform.lock.hcl is missing` -> a note, not a failure

- `bazelisk run //scripts:push-template` prints it because no lockfile is committed
  under `templates/`, and Coder pushes the directory without one.
- Pin provider versions locally only if you want to, per template directory. The push
  goes ahead either way, and `workspace` and `devcontainer` are the two names:

```sh
terraform -chdir=templates/<name> init -backend=false
```

### `unexpected non-JSON response "text/html; charset=utf-8"` -> Authelia answered the CLI

The usual wrapper is `Failed to check server "https://..." for first user, is the URL
correct and is coder accessible from your browser?`

- Cause: the CLI is talking to a public subdomain, and Authelia answers its API calls
  with the sign-in page.
- This is not a broken credential. It happens with a valid token too, because Authelia
  gates every route.
- Fix: point the CLI at the container's loopback listener, `http://127.0.0.1:3000`,
  which nothing can gate. See "Coder workspace templates" in README.md.
- `CODER_ACCESS_URL` itself stays the public name: browsers need it, and only CLI
  traffic should not use it.

### `installed terraform version newer than expected` -> harmless

- Cause: an upstream pin. The Coder image ships its own provisioner binary at
  `/usr/local/bin/terraform` (1.15.5 in `coder:v2.36.6`) and Coder caps the version it
  was tested against.
- `coder server` logs it; the host `coder` CLI does not.
- Builds still succeed, so verify with a workspace build before acting on it. Nothing
  in this repo's compose file sets the provisioner's Terraform.

## Editor, credentials, the clone

### `Unexpanded count argument on block "coder_app.coder_ui"` -> apps were gated on start_count

Cause: `coder/preview` warns when a `coder_app` `count` is not expanded at
workspace-create preview. `start_count` is that value. The default is then
assumed to be 1.

Fix: `coder_app` resources are not gated on `start_count` (scripts, metadata
and the container still are). Push the templates; new creates stop showing the
warning. Existing workspaces pick it up on the next update to the new template
version.

```sh
bazelisk run //scripts:push-template
```

### VS Code Web opens `/home/coder` instead of the cloned repository -> last workspace won

Cause: path-based Coder apps drop the `?folder=` query before the browser sees
it, and code-server restores the last opened workspace (often `/home/coder`).
The clone itself is fine (`already cloned, skipping` is not a failure).

Fix: the inlined fork starts code-server with `--ignore-last-opened` and the
clone folder as a positional argument (`/home/coder/workspace/<repo>` on the
`workspace` template). Push the templates and restart so the editor process
relaunches.

```sh
bazelisk run //scripts:push-template
coder restart <workspace>
```

### Browser editor (code-server) stays unhealthy -> check these three, in order

- Check 1: the code-server install script's log is green in the workspace's Scripts/Log
  tab.
- Check 2: this answers from inside the workspace:

```sh
curl -fsS localhost:13337/healthz
```

- Check 3: the browser is on `https://` with a trusted cert. Plain `http://` is an
  insecure context, which is what breaks `crypto.randomUUID()`; see "Public subdomains
  (optional)" in README.md.

On `devcontainer`:

- The dev container must build first, and that needs `.devcontainer/devcontainer.json`
  in the cloned repository.
- A repo that ships none wants the **Plain clone** preset, or the dev-container toggle
  set to **No** at create time. Either one runs code-server on the plain workspace
  container and opens the clone there.
- `bazelisk run //scripts:new-workspace` decides that for you, per repo:

```sh
bazelisk run //scripts:new-workspace -- <git-url>
```

### GitHub token expired, or the workspace has no GitHub account -> GitHub reauth

- On the workspace page, click **GitHub reauth**. Coder opens `/external-auth/<id>`
  (device flow for the injected App, OAuth for a custom app in `coder.env`). If the
  page says you are already authenticated, click **Reauthenticate**.
- If that page says "You must install the GitHub App to clone private repositories"
  and lists no accounts, the device-flow login already succeeded. Click **Install
  GitHub App** on the workspace (or open
  [github.com/apps/coder/installations/new](https://github.com/apps/coder/installations/new)),
  grant the private repos, then restart. Coder's injected provider omits
  `AppInstallURL`, so the warning on `/external-auth/github` is unlinked plaintext.
- Restart the workspace afterwards so `GH_TOKEN` and the gh auth store match the new
  grant. `git` via `GIT_ASKPASS` remints without that restart.
- Existing workspaces pick up the buttons after `bazelisk run //scripts:push-template`
  and a workspace update to the new template version.

### gh_token_refresh says gh would not store the minted token

- The refresh script inherits `GH_TOKEN`/`GITHUB_TOKEN` from the agent. `gh auth
  login --with-token` refuses stdin while those names are set. Current templates
  unset the pair, log out, then log in with `--git-protocol https`, and print gh's
  stderr (token redacted) if that still fails.
- Inside the workspace, run `GH_TOKEN= GITHUB_TOKEN= gh auth status`. Then click
  **GitHub reauth**, finish device-code login, install the Coder GitHub App if the
  reauth page says to, and restart.

### Private-repo clone or push denied while a credential is present -> the grant, not the format

- The denial is about the **grant**, not the credential format. A
  connected-but-unscoped credential authenticates and is still refused: 403, or 404
  where GitHub hides a private repo's existence (a repo hidden from the credential
  answers 404, or 403, on the read lane and the write lane alike). And reads prove
  nothing about push: a public repo answers read probes for any authenticated
  caller, so a credential that READS a repo can still be refused every WRITE to it.
- Check the GitHub side first. The grant behind the credential - the GitHub App
  installation that the External Auth provider (id `github` by default) minted its token from -
  has to include the repository the workspace clones or pushes. An empty
  [github.com/settings/apps](https://github.com/settings/apps) page is the usual surprise
  here: it means no App is installed under your account, so there is no **Configure** link
  to click and nothing to grant, while the provider itself stays configured and keeps
  minting tokens that authenticate. Install Coder's App from the workspace **Install
  GitHub App** button, or at
  [github.com/apps/coder/installations/new](https://github.com/apps/coder/installations/new),
  grant the repo, then restart. A private repository is never visible to a credential
  that was never granted it.
- Then check the URL scheme. That credential covers `https://github.com/...` remotes
  only, so a `git@github.com:` or `ssh://` URL gets neither helper nor askpass token
  and needs an SSH key you placed yourself, which this stack provisions nowhere.
- The doctor, from a host shell or from inside a workspace, names the credentials a
  workspace's git and gh could present and answers "can this credential WRITE to the repo you
  pass?". It probes the endpoint `git push` negotiates through: one GET of
  `<repo>.git/info/refs?service=git-receive-pack`. A REFUSED-GRANT answer means the
  credential authenticates while every write to that repo is denied; NOT VISIBLE
  means the repo is hidden from the credential (or absent); REJECTED means github.com
  refuses the credential outright, as it does an expired mint:

```sh
bazelisk run //scripts:github-auth -- check [container] [repo-url] [--source=<slot>]
```

  On the host it enumerates the labeled workspace containers with docker and probes
  each (a named container checks just that one). Inside a workspace the docker CLI
  reaches only that workspace's DinD sidecar, so the same command runs SELF mode
  with no docker: one probe of this environment's own credential chain, printed as
  one `self:` line per credential. Pass only the repo URL there; a named container is
  refused and pointed at the host shell. The repo URL may be the clone URL or the
  browser URL, with or without a trailing slash and `.git`; a path below `owner/repo`
  is refused rather than probed, because it names no repository. Full usage:
  `bazelisk run //scripts:github-auth -- --help`.
- `--source=chain` (the default) probes every credential that could answer for that
  repository; `--source=env`, `--source=gh` or `--source=mint` answers one slot and
  labels the answer **shadowed** when the env pair outranks it. That label matters:
  while `GH_TOKEN`/`GITHUB_TOKEN` carry a token, git and gh consult that token and
  never reach the gh auth store, so a PAT you pasted into the store is not the
  credential a push would use. To check or use the stored credential anyway, clear
  the pair for that one command:

```sh
GH_TOKEN= GITHUB_TOKEN= git push -u origin <branch>
```

- Or install a write-capable PAT into one workspace's gh auth store, on stdin:

```sh
bazelisk run //scripts:github-auth -- auth <container> - < PAT
```

  A manual PAT is legitimate in two cases: the workspace owner connected no Coder
  account, so nothing can be minted, or the minted/App credential is missing the
  repository - revoked or expired counts the same way, because the answer that proves
  either is NOT VISIBLE or REJECTED, not a passing read. It REPLACES the per-start
  minted credential for that workspace, so treat it as a stand-in and rotate or remove
  it in GitHub -> Applications when the work ends.
- A PAT is never typed as an argument any more: argv is readable through `ps` and the
  token lands in shell history. Pipe it in (`echo "$TOKEN" | bazelisk run
  //scripts:github-auth -- auth <container> -`) or run `auth <container>` alone and
  answer the hidden prompt. In the line above, `-` is the only argument after the
  container and `< PAT` is a shell redirect, not an argument.

## UI and logins

### `Refusing to bind dashboard to 0.0.0.0` -> empty Hermes basic-auth env

Cause: Hermes v0.22.5 refuses a non-loopback bind when no
`DashboardAuthProvider` is registered. The bundled basic-auth plugin skips
registration when the password is empty. Compose interpolation
`${HERMES_DASHBOARD_PASSWORD:-}` (empty default) did that after a pull that
added the Hermes keys: `.env` never gained them, so `prod-stack up` without
`bootstrap` / `update-configs` crash-looped the gateway. The logs repeat
"no auth providers are registered" and do not mention `plugins.disabled`.

Fix: compose interpolation defaults now match `.env.sample`
(`change-me-hermes` / `change-me-hermes-secret`). Recreate the service:

```sh
bazelisk run //scripts:prod-stack -- up
```

Sign-in is `HERMES_DASHBOARD_USER` / `HERMES_DASHBOARD_PASSWORD` from `.env`
(default `admin` / `change-me-hermes` until bootstrap rotates the
placeholders). To fill missing keys and replace those placeholders:

```sh
bazelisk run //scripts:bootstrap --
bazelisk run //scripts:prod-stack -- up
```

`HERMES_DASHBOARD_INSECURE` is a no-op. Logs:
`bazelisk run //scripts:prod-stack -- logs hermes`.

The Chat tab is a PTY over WebSocket on the same port. Approvals render as
cards there; a mutating command that seems to hang is waiting for the card.
Seeded `approvals.mode` is `manual` — never `off`. `hermes-init` must exit 0
before `hermes` starts. If the gateway loops on a missing `config.yaml`, the
named volume was not seeded: run
`bazelisk run //scripts:hermes-bootstrap -- --help` and recreate. Full
access / mounts / socket-risk notes: [hermes.md](hermes.md).

### Public `hermes-gmktecbeast` answers `421` -> no vhost, a rewritten Host, or Traefik aimed past the router

Cause: this box's `router` answers `421` when the Host matches no `server_name`.
The hermes vhost lives in `proxy/router.conf` (hardcoded, like the other public
names). Traefik pointed at `:9119` never hits that file. A rewritten Host also
misses every block.

The public backend is the same hop as the other names. Replay it from a
workspace, which reaches the published router and skips Cloudflare, Traefik and
Authelia:

```sh
curl -sS --noproxy '*' -o /dev/null -D - -H 'Host: hermes-gmktecbeast.overeazy.io' \
  http://host.docker.internal:8080/
```

- `421` means this box has no vhost for that Host. Recreate `router` so it
  mounts the conf that lists `server_name hermes-gmktecbeast.overeazy.io`.
- Anything else means the router matched (Hermes basic auth is `401` until you
  send credentials). A `421` only on the public URL, with this probe succeeding,
  is a rewritten Host or a Traefik backend that is not `:8080`.
- `STACK_PUBLIC_HOSTS` does not create the vhost. It is what bootstrap writes
  into `STACK_HERMES_URL` / `HERMES_DASHBOARD_PUBLIC_URL` for the Chat tab.

### Chat tab never connects, or the socket closes `4403` -> public URL, trusted proxies, or a dropped Upgrade

Cause: the Chat tab is a WebSocket on `/api/pty` and `/api/ws`. Hermes sends a
keepalive every 20 seconds. Close code `4403` is the Host / Origin / peer guard.

- `HERMES_DASHBOARD_PUBLIC_URL` has to be the public origin. Bootstrap writes
  `STACK_HERMES_URL` from a `hermes-*` or `hermes.*` entry, and compose copies
  that into `HERMES_DASHBOARD_PUBLIC_URL`. The variable is environment: recreate
  the container after bootstrap.
- The seed sets `dashboard.trusted_proxies` to `["172.16.0.0/12"]` so Hermes
  honours `X-Forwarded-Proto` (Secure cookie and `wss`). A `hermes-data` volume
  from before that seed keeps the old file until you reseed. `<mount>` is the
  host directory of that volume:

```sh
bazelisk run //scripts:hermes-bootstrap -- --data <mount> --force
```

  `hermes config set` on `dashboard.trusted_proxies` is the in-container
  alternative. `HERMES_DASHBOARD_PUBLIC_URL` does not need that reseed.
- Traefik and Authelia have to pass `Upgrade`. Cloudflare's orange-cloud proxy
  has WebSockets on by default. A page that loads and a Chat tab that dies is
  this hop, not the basic-auth provider.

The `0.0.0.0` bind refusal above is a different failure: empty basic-auth env,
not this public path. Full notes: [hermes.md](hermes.md).

### Kasm wizard gone after install -> expected

- The wizard only listens on `:3000` at first boot; after install, use `:4443`.
- Reset Kasm by removing the `kasm-data` volume, which destroys all Kasm config. Stop
  the stack first, and use the name your stack owns: `evo-t1-coder-stack_kasm-data` for
  the stable stack, `evo-t1-dev_kasm-data` for the dev one.

### Coder login problems -> the admin account, and `CODER_ACCESS_URL`

- The first registered account is the site admin.
- If the UI is unreachable, check that `CODER_ACCESS_URL` matches the address you are
  browsing from: the LAN IP by default, or the public coder name in public mode.
