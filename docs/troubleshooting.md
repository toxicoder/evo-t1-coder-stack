# Troubleshooting

Deep, symptom-first list. The operational `dev-stack`/`prod-stack`, `search-check` and
`spark-verify` targets are described in [README.md](../README.md) and
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

`make prod-stack-up` (and `make stack-up`) run `--repair` first. Bare
`bash scripts/setup-host.sh` repairs leftovers and then installs any missing
host tools. `bash scripts/setup-host.sh --check` lists leftover paths without
writing.

### `Could not resolve host: github.com` -> Tailscale MagicDNS is the only nameserver

Cause: `/etc/resolv.conf` names only Tailscale MagicDNS (`100.100.100.100`).
Docker's iptables, and Kasm's privileged nested dockerd, can make that stub
unreachable. When it is, **every** lookup dies, including `github.com`, so
`git pull` over HTTPS fails. This is host DNS, not GitHub auth.

The stack never flips Tailscale for you. Keep a public resolver beside MagicDNS,
then retry `git pull`:

```sh
bash scripts/setup-host.sh --check
sudo tailscale set --accept-dns=false
```

`--check` prints which nameservers are in play and whether `github.com` resolves.
Other ways to keep a public resolver: add `1.1.1.1` / `8.8.8.8` as a global
nameserver in the Tailscale admin DNS page, or drop a systemd-resolved drop-in
(`DNS=1.1.1.1 8.8.8.8`) and restart `systemd-resolved`.

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
  them:

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
- `X-Evo-Proxy` names the `server_name` that matched here: `coder`, `litellm`, `kasm`
  or `homepage`. Its absence means the request never reached this box's nginx.
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

### Private-repo clone or push denied while a credential is present -> the grant, not the format

- The denial is about the **grant**, not the credential format. A
  connected-but-unscoped credential authenticates and is still refused: 403, or 404
  where GitHub hides a private repo's existence.
- Check the GitHub side first. The grant behind the credential - the GitHub OAuth app
  installation that the `primary-github` external-auth provider minted its token from -
  has to include the repository the workspace clones.
- Then check the URL scheme. That credential covers `https://github.com/...` remotes
  only, so a `git@github.com:` or `ssh://` URL gets neither helper nor askpass token
  and needs an SSH key you placed yourself, which this stack provisions nowhere.
- The doctor, from the stack host, names the credential each running workspace
  presents and says whether it is granted on the repo you pass:

```sh
bazelisk run //scripts:github-auth -- check [container] [repo-url]
```

- Or install a write-capable PAT into one workspace's gh auth store, on stdin:

```sh
bazelisk run //scripts:github-auth -- auth <container> - < PAT
```

  A manual PAT is legitimate in two cases: the workspace owner connected no Coder
  account, so nothing can be minted, or the minted/App credential was revoked or has
  expired. It REPLACES the per-start minted credential for that workspace, so treat it
  as a stand-in and rotate or remove it in GitHub -> Applications when the work ends.
- A PAT is never typed as an argument any more: argv is readable through `ps` and the
  token lands in shell history. Pipe it in (`echo "$TOKEN" | bazelisk run
  //scripts:github-auth -- auth <container> -`) or run `auth <container>` alone and
  answer the hidden prompt. In the line above, `-` is the only argument after the
  container and `< PAT` is a shell redirect, not an argument.

## UI and logins

### Kasm wizard gone after install -> expected

- The wizard only listens on `:3000` at first boot; after install, use `:4443`.
- Reset Kasm by removing the `kasm-data` volume, which destroys all Kasm config. Stop
  the stack first, and use the name your stack owns: `evo-t1-coder-stack_kasm-data` for
  the stable stack, `evo-t1-dev_kasm-data` for the dev one.

### Coder login problems -> the admin account, and `CODER_ACCESS_URL`

- The first registered account is the site admin.
- If the UI is unreachable, check that `CODER_ACCESS_URL` matches the address you are
  browsing from: the LAN IP by default, or the public coder name in public mode.
