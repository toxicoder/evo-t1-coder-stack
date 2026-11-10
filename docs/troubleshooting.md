---
title: Troubleshooting
description: "Symptom-first list of what breaks on this box: the error string, the cause, the recipe, and what the fix costs."
tags: [troubleshooting, operate, errors]
---

# Troubleshooting

**What's on this page**

- Stack bring-up: bootstrap, ports, containers that refuse to start
- The model lane: Spark boxes, LiteLLM, and the agent backends
- Workspaces: startup, the golden image, Grok Build (`/ez-learn`, MCP), the toolchain
- Docker-in-Docker, Terraform, and the host `coder` CLI
- Editor, credentials, the clone, UI logins, and the public names (`421`, Chat `4403`, Traefik)

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

### `error: .../.env not found` from `bazelisk run //scripts:dashboard-password` -> the runfiles copy has no working `.env`

Cause: an older target ran the runfiles copy of the script, so `$(dirname "$0")/..`
was the runfiles tree, and that tree ships only `//:stack_data`. The working `.env`
is untracked, so it exists only in the checkout, and the rotation reported a missing
file on a host that had one. The path in the message tells the two apart: a
`bazel-out/.../dashboard-password.runfiles/...` path is this entry. The same bug had
`pull-models` pulling its default list instead of the checkout's `OLLAMA_MODELS`,
`coder-agents` provisioning the compose placeholder `LITELLM_MASTER_KEY` instead of the
checkout's, and `spark-configure` / `spark-verify` writing `sparks/` output into a tree
Bazel recreates.

Fix: those six CLIs (`dashboard-password`, `pull-models`, `coder-agents`,
`spark-verify`, `spark-configure`, `build-dev-image`) resolve the checkout with
`resolve_checkout` (`scripts/lib/common.sh`) before they read or write anything, so
they honour `REPO_ROOT` and the `BUILD_WORKSPACE_DIRECTORY` that `bazel run` names.
When nothing proves out - no candidate holds `docker-compose.yml` outside a
`bazel-out/`, `bazel-bin/`, `execroot/`, or `*.runfiles` tree - the run exits `5` with one
`error: unresolvable repo root: ...` line instead of half-running against a copy. Re-run
from the stack host:

```sh
bazelisk run //scripts:dashboard-password
```

The `first boot? run bazelisk run //scripts:bootstrap to create it` hint alongside it
means the checkout has no `.env` at all: that is the bootstrap path. `DASHBOARD_ENV_FILE`
points the rotation at another file and exists for test harnesses; there is deliberately
no flag for it, because a flag that names a file this CLI overwrites is one mistype away.

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

### `./.env: line 188: qwen2.5-coder:14b: command not found` from `bazelisk run //scripts:pull-models` -> the model list was being parsed as shell

Cause: that target used to read `.env` with `. ./.env`, so the shell parsed the
operator's file as code. An unquoted value that holds a space is a variable
prefix followed by a COMMAND, and `set -e` ended the run on that line before a
single pull:

```sh
OLLAMA_MODELS=qwen2.5-coder:32b qwen2.5-coder:14b
```

The word the shell says it cannot find is the second tag. The same read would
also have executed anything written on a line of its own in that file, and it
exported every other key there (`LITELLM_MASTER_KEY` included) into the
environment of the `docker exec` calls.

Fix: the target now reads the one key it needs through `env_get`
(`scripts/lib/common.sh`), which takes the line as text. Quoted and unquoted
values behave the same, and nothing else in `.env` reaches the pull. A value
that is not a model tag - a stray `;`, a leftover quote, a trailing comment - is
refused by name before the daemon is asked and before any of the ~35 GB
download starts:

```sh
bazelisk run //scripts:pull-models
```

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

### The TensorFold log is full of warnings, or `resumed at 0` -> read the line shapes first

The server on each Spark box logs four shapes, and three of them are this stack's own
traffic rather than anything wrong with the box. Read the shape before you reach for
the box.

- `[tensorfold] done chatcmpl-... prompt=58 ... effort=xhigh tokens=16 finish=length`
  followed by `warning: a reply reached max_tokens while still thinking, so its content
  is empty`: that is the LiteLLM proxy's health check, not a user. At the pinned tag the
  proxy sends the deployment's whole `litellm_params` through a real `acompletion`, so
  the lane's baked `reasoning_effort` rides along, and it asks for the default
  `health_check_max_tokens` of 16. A thinking reply cannot finish its reasoning in 16
  tokens, so it returns empty content and the server warns about it. The reply is a
  healthy 200 and the deployment stays in the pool.

- `info: prompt cache: 80693 tokens, resumed at 79747, kept 1; 12 states, 6289 MiB and
  0 MiB spare of 6465 MiB (hits ..., evicted ...)`: the box is out of prompt-cache room.
  `resumed at N` is how much of the prompt it did not have to recompute, so a healthy
  conversation logs a number just under `tokens`. `resumed at 0` means it recomputed the
  whole prompt: something evicted that conversation's state. Watch `evicted` and the
  state count rather than any one line.

- `[tensorfold] ended chatcmpl-... reason=client-left prompt=... after=Ns`: whoever asked
  hung up. A tiny prompt abandoned at around 81 s was a health check queued behind
  longer work; a huge prompt abandoned at around 400 s is a client with its own timeout,
  and it re-prefills from zero if it retries.

Two things on this stack cause the evictions, and both are tuned here rather than on the
box:

- Probe cadence. `health_check_interval` and `health_check_concurrency` in
  `litellm/config.yaml` decide how often every Spark deployment gets a real generation.
  They sit at LiteLLM's own default of 300 s and a concurrency of 2 on purpose: at 30 s
  across five deployments a round was putting more probes on a box than user requests,
  and each one took a prompt-cache state from a conversation. Auto-recovery does not
  need 30 s -- a box that is actually down is pulled by `allowed_fails` and
  `cooldown_time` under live traffic, and the re-probe is what brings it back. If the
  warnings come back every few seconds, that is the first key to look at.

- The 195k needle. `//scripts:spark-verify` runs the recipe's `needle.py --length 195000`
  as the window proof, and a 195k prompt the server has never seen is the largest single
  eviction on the box. It now skips itself while `/health` reports `requests_running`
  above zero, so it does not land on a box that is serving:

```sh
bazelisk run //scripts:spark-verify -- 10.0.0.5            # needle waits for a quiet box
bazelisk run //scripts:spark-verify -- --needle 10.0.0.5   # force it: the box goes quiet first
```

  The window is still read passively on every run without the needle, from the server's
  own startup lines (`context_pairs` and `startup_estimate` in the report), so a box
  quietly rebuilt with a shorter window is still visible; the needle is the active
  confirmation of it. `--no-tests` skips all four recipe probes for a quick read-only
  pass, and that is what `//scripts:bootstrap` runs.

### Sessions log `compact failed: exceeded wall-clock budget 300s (runaway generation)` -> a compaction stream that never sent a token, bought three times

Cause: the auto-compaction summary hung before its first token and nothing abandoned it.
The CLI's 300 s wall-clock budget does not abort a call in flight - it is evaluated only
after the response returns - so at 300 s its entire effect was to reject a summary that
had already streamed in and make the session generate it again. Meanwhile the proxy
re-dispatched every hung attempt to the same session-pinned Spark box, so one hang cost
up to three `request_timeout` periods. Both halves are fixed here.

- Prove recurrence before you touch anything. The events are in each session's
  `updates.jsonl`, so one pass over the store counts attempts against outcomes. The
  store is the shared profile volume, so run it where the sessions are (inside a
  workspace), and leave the `~/.grok/sessions` path %-escaped as the CLI wrote it:

```sh
grep -rho --include=updates.jsonl \
  '"sessionUpdate":[[:space:]]*"auto_compact_[a-z]*"' ~/.grok/sessions |
  sort | uniq -c
```

  Read `auto_compact_failed` against `auto_compact_started`. Over the 11-day window this
  was investigated, the store held 82 failures across 15 sessions in 3 workspaces,
  escalating from a 39 per cent failure rate to 85 per cent (45 attempts in one day, 19
  of them in the worst single session), and 3 of the 15 sessions ended on a dangling
  `auto_compact_started` and were abandoned.

- Which sessions, worst first, with the same `head` cap so a busy store stays readable:

```sh
grep -rc --include=updates.jsonl \
  '"sessionUpdate":[[:space:]]*"auto_compact_failed"' ~/.grok/sessions |
  awk -F: '$NF+0 > 0 {print $NF, $0}' | sort -rn | head -5
```

Each link in the chain, measured:

- Auto-compaction always fired at about 75 per cent of the 262144-token window, the
  setting in force when this was measured: all 124 `auto_compact_started` events carried
  `tokens_used` between 196,636 and 214,585. Both template twins now ship
  `[session] auto_compact_threshold_percent` at 70, so a future sweep measures the
  events firing at a lower point than this.
- The summary call rides the **session model**, the `agent*` thinking family, and
  inherits its output ceiling: captured on the wire as `max_tokens: 32768`, alongside 25
  tool schemas and the workspace's `x-litellm-session-id` affinity header.
  `[models] session_summary` is **not** that lane - it serves titles and the session
  recap.
- In every one of the 79 wall-clock failures no first token ever arrived. Successful
  compactions do stream: their `elapsed_ms` spans 107 s to 1915 s, and 18 of the 36 ran
  past 300 s, which is the summary the budget was discarding.
- Nothing on the client aborts the hang. `signals.json` reports `inferenceIdleTimeouts`
  at 0 or 1 across the failing sessions, and no hung call was ever cut off at the idle
  deadline, so `inference_idle_timeout_secs` (then 1200 s) is not on this path. The key
  now ships at 1800 s in both template twins, which does not put it on this path either:
  the CLI still does not apply it to compaction. Reproduced directly: with an upstream
  held open and no byte sent, the CLI was still waiting at 3000 s.
- The only live bound was the proxy's `request_timeout: 1200`, multiplied by every
  attempt. Observed failure durations were 1366 s, about 2400 s and 3465 s - the deadline
  honoured once, twice and three times.
- Those re-dispatches came from this repo's own config. At the pinned tag
  `ghcr.io/berriai/litellm:v1.102.1` a stream that dies before its first chunk raises
  `MidStreamFallbackError`, which subclasses `ServiceUnavailableError`
  (`litellm/exceptions.py:1114`), and `get_num_retries_from_retry_policy` walks the
  exception MRO most-specific first, so it lands on `ServiceUnavailableErrorRetries` and
  never reaches `DefaultRetries`. A hung request never cools the box either: cooldown
  hard-excludes any exception whose string contains `APIConnectionError`, and
  `_deployment_ids_to_skip_on_retry` only skips deployments that answered a non-retryable
  int status code. Under the workspace-wide `x-litellm-session-id` pin every attempt
  therefore returned to the same saturated box.

What the fix changed, and how to land it:

```sh
grep -n 'ServiceUnavailableErrorRetries\|DefaultRetries' litellm/config.yaml
```

- `ServiceUnavailableErrorRetries` is 0, not 2, on each of the four Spark lanes (`agent`,
  `agent-low`, `agent-medium`, `agent-xhigh`): one attempt for a dead stream, so a hung
  request is bounded at 1200 s instead of up to 3465 s. `DefaultRetries: 2` is untouched
  on purpose - TensorFold's `NoRoom` refusal arrives as `APIConnectionError`, which is
  absent from `_RETRIES_BY_EXCEPTION_TYPE`, so that walk falls through to
  `DefaultRetries` and keeps its two attempts. The proxy reads the file at boot:

```sh
docker compose -p evo-t1-coder-stack -f docker-compose.yml restart litellm
```

- Both `templates/*/main.tf` twins carry `GROK_COMPACTION_WALL_CLOCK_SECS = "1200"` in
  the agent `env` merge, next to `GROK_MAX_MCP_OUTPUT_BYTES`. The CLI reads that budget
  from the environment only (resolver
  `crates/codegen/xai-grok-shell/src/util/config/resolve/compaction.rs`, remote-settings
  key `compaction_wall_clock_budget_secs`); no TOML table accepts it, so a line pasted
  into `grok-config.toml` is silently ignored, the same trap `[mcp] max_output_bytes`
  already documents. It is honoured: setting it to `1` makes `/compact` fail with
  `exceeded wall-clock budget 1s`. Push, then stop and start the workspace so the new
  agent env lands:

```sh
bazelisk run //scripts:push-template
```

What it deliberately does not do:

- It does not stop the upstream from hanging. It stops the hang being bought three times,
  and stops a finished summary being thrown away.
- `TimeoutErrorRetries: 0` would not help: the hang never becomes a `litellm.Timeout`.
- `ServiceUnavailableErrorRetries` is the only one of the two that can be zeroed; zeroing
  `DefaultRetries` breaks the `NoRoom` contract above.
- The lever, now pulled: `[session] auto_compact_threshold_percent` ships at 70 in both
  template twins, so auto-compaction fires near 183,500 tokens rather than the 197k-214k
  these events measured, and the ~200k-token summary input shrinks with it. The store
  shows no size threshold separating failure from success - the successes reach the same
  197k-214k range - so this is a load reduction, not a proven cure. Re-run the first
  command above to measure whether the ratio moved.

### Coder Agents chat refuses every prompt, or its model dropdown is empty -> no model config

Cause: that chat has no model config on this deployment, so there is nothing to route to.

- First run this to see the plan, then run it again without the flag to apply it:

```sh
bazelisk run //scripts:coder-agents -- --dry-run
```

```sh
bazelisk run //scripts:coder-agents -- --apply
```

- After a `stack up`, the seeder that runs it in the background keeps its output in
  `${TMPDIR:-/tmp}/coder-agents-seeder.log` (the `note:` line names the path). A chat
  that never got wired usually means that file holds a `skipped:` line: no coder
  container yet, no db container, or nobody had registered when the stack came up.
  Re-run the command above once the stack is up and somebody has signed in.

- It skips while the coder or db container is down, or nobody has registered yet, and
  re-running it repairs a provider that drifted and moves a model pin whose alias has
  since gone unhealthy.

- The closing summary counts the auxiliary lanes that carry a pin. A `warning:` naming a
  lane means that lane falls back to Coder's own pick, and `title_generation` and
  `compaction` are the two an operator notices first: conversations stop getting titles,
  then a long one stops at the compaction threshold. Re-run `--apply` once the alias
  behind that lane answers.

- A `warning:` that a stored model config is disabled, is not the default, or compacts
  against the wrong window names a row this script found already in place. It reads
  before it writes and this surface has no PATCH, so the correction is the one click in
  Admin -> Experiments -> Agent Chat the line names.

A chat that starts but narrates instead of calling tools is the no-Spark case above.

### Coder Agents offers a model that errors, or a chat never gets a title -> an alias with no healthy deployment

Cause: the LiteLLM alias behind that model has no deployment the router will use. The
Arc aliases (`chat`, `coder`, `coder-fast`) go unhealthy the moment their weights are
not in the IPEX-LLM container, which answers `model "..." not found, try pulling it
first`, and the Spark `agent` aliases go unhealthy when no box answers.

```sh
bazelisk run //scripts:prod-stack -- logs --tail 200 litellm
```

```sh
bazelisk run //scripts:pull-models
```

- `//scripts:coder-agents` reads that same health view before it registers anything, so
  once the weights are back, re-running it registers the alias and takes the
  `compaction` / `title_generation` pins off it. A `warning:` line names the alias it
  refused to register, and the closing `summary:` counts the warnings, so a run that
  quietly wired half the model list is visible.
- Titles that never appear and a long chat that dies at its context budget are the
  helper lanes pointing at a dead alias. Re-running the script moves them.

### Workspace cannot reach LiteLLM -> `CODER_ACCESS_URL`, or `host.docker.internal`

One lane reaches that port: a process inside the workspace. The two reads that matter
are the probe from inside the workspace and the liveliness probe from the stack host,
and those share nothing but the destination.

- The **model lane**: a process inside the workspace dials
  `http://host.docker.internal:4000/v1` directly. `host.docker.internal` is the docker
  bridge gateway (`172.17.0.1`), compose publishes the proxy's container port 4000 on
  host port 4000, and nothing between the two authenticates. `LITELLM_BASE_URL` and the
  coding CLIs use this lane.
- The **agent bar** keeps `:4000` off its own path: the workspace page's `litellm` tile
  is `coder_metadata` text (`value = var.litellm_url`), a read-out rather than a
  `coder_app`, so `litellm-gmktecbeast.` is never consulted here. Health-check the
  proxy with `curl http://host.docker.internal:4000/health/liveliness` on the stack
  host. The app lane under `A workspace app link answers Bad Gateway` below is the
  **VS Code Web** editor link and stays on 13337 inside the workspace.

The checks that apply:

- `CODER_ACCESS_URL` must be an `https://` URL: a LAN IP, or the public coder name in
  public mode. Never `localhost` and never `127.0.0.1`.
- The workspace container must resolve `host.docker.internal`; the model lane reaches
  LiteLLM through that host gateway, and so does `LITELLM_BASE_URL`.
- Agent traffic ignores that URL and dials `host.docker.internal:3002`; see the
  `coder_agent_url` template variable.

### Search never answers (or answers empty) -> prove the search lane before blaming the MCP hop

The self-hosted SearXNG MCP stdio server is the search lane, declared by default
(`search_mcp` defaults to true). Grok's native `web_search` is parked: the render sets
`disable_web_search = true`, because no model transport this box ships serves that
tool type - LiteLLM's `agent` group answers `tools of type 'web_search' are not
supported: this server runs function tools only` (HTTP 400) before anything is
fetched, and `supports_backend_search = false` does not route around it. An agent that
still spends a turn on a native search call and comes back with that message behaved
as configured; there is no native lane to fall back to. Two probes split a SearXNG
fault in half:

- `bazelisk run //scripts:search-check` (or `scripts/search-check.sh` from a shell that
  can reach the host gateway) dials the service directly. It reads `$SEARXNG_URL`
  before its `http://127.0.0.1:8181` default, and every workspace's agent env carries
  that key, so a workspace-side probe needs no `--url`. It separates engines that
  answered, engines that were unresponsive, and an empty result page, and it names
  each engine the instance has parked together with the reason the backend gave
  (`parked by its backend: google: access denied`). A park expires after
  `search.suspended_times` in `searxng/settings.yml`, so re-run before writing an
  engine off. `--json` adds `engines_parked` for a dashboard to trend.
- An agent whose searches come back empty while the service answers 200 is nearly
  always parked engines rather than a broken deployment: the general-purpose engines
  are the ones the public backends bot-wall first. The same query without an
  `engines` pin usually still returns results, which is why the guidance in
  `~/.grok/AGENTS.md` tells an agent to leave the engine choice to the instance.
- `grok mcp doctor searxng` inside the workspace probes the MCP hop. A healthy
  search-check plus a failed handshake points at the server, the URL or the port.
- `bazelisk run //scripts:mcp-check` covers both hops plus the config side in one
  pass: the declared lanes, whether each `command=` binary is there, whether
  `~/.grok/config.toml` is still stack-managed, whether the lane's credential is
  set, whether the search lane returns results for a plain lookup rather than just
  an HTTP 200, and each server's handshake. A missing binary prints the exact
  `npm i -g --prefix /opt/npm-global` command that puts it back.

There is no second lane behind this one, so run these probes before touching anything
else. A service that answers but a server that will not handshake is the MCP hop; a
server that cannot launch at all usually means no
`/opt/npm-global/bin/searxng-mcp-server`, and that binary is baked into the golden
image - an image that predates it needs a rebuild and a workspace recreate, not a
config edit. Park the lane with `search_mcp = false` on the next template push
(`SEARCH_MCP=false` in `.env` applies it to every new workspace) when a session should
have no search tool at all. To restore the native tool, flip `disable_web_search` to
false in both template twins and re-push - only for an endpoint that really serves the
tool, or the 400 comes straight back.

### Context7 or GitHub tools missing in Grok Build -> parked MCP block, or a handshake with nothing to authenticate

The three MCP servers (`github`, `context7`, `searxng`) ship by default, so a lane
missing from a session has one of three shapes: the block absent from the rendered
config, the `command=` binary absent from the golden image, or the credential absent.
Run `bazelisk run //scripts:mcp-check` first - it reports the declared lanes, their
binaries, their credentials and their handshake in one pass, and it names which shape
you are in (an undeclared lane is a failure, a missing binary a warning).
`grok mcp doctor` inside the workspace lists the declared servers and their handshake.
A *park* is deliberate and looks like this: `GITHUB_MCP=false` / `CONTEXT7_MCP=false` /
`SEARCH_MCP=false` in `.env` (relayed by `push-template.sh`) or
`--var github_mcp=false` / `--var context7_mcp=false` / `--var search_mcp=false` on a
template push. With none of those set, a missing block is a defect, not a park.

- A missing `[mcp_servers.github]` or `[mcp_servers.context7]` in
  `~/.grok/config.toml` means the last push passed `--var ...=false`, or the
  workspace started from an older template, or the file carries no stack marker at all
  (next bullet). Clear the gate and re-push, then re-materialize the file and restart
  the workspace so the managed `config.toml` re-renders. Two routes re-materialize it:
  `bazelisk run //scripts:refresh-configs -- --container coder-<owner>-<ws>` from the
  stack host, for a running workspace container, and
  `bazelisk run //scripts:seed-dev-env -- --home <dir>` for a host home (a laptop, CI,
  or the contributor container).
- A declared server whose `command=` the box cannot find is image drift: the
  templates declare a binary the running image never got, because it predates the
  npm bake in `images/dev/Dockerfile`. Rebuild `evo-t1-dev` and recreate the
  workspace, or install the pinned package into the running box (`npm i -g --prefix
  /opt/npm-global searxng-mcp-server@<pin>`, the pins live in
  `images/dev/tool-versions.env`).
- A `~/.grok/config.toml` carrying neither the `managed-by: evo-t1-coder-stack` line
  nor the `__evoT1Stack = true` key is a file the stack stopped managing, so neither
  the startup script nor the seed writes it again and its default lanes never arrive.
  The usual cause is not a hand edit: `grok mcp add` persists its own settings by
  rewriting that file and deletes every comment line, which used to revoke stack
  ownership by itself. The TOML key is what survives that write, so a config rendered
  by the current templates keeps its marker through `grok mcp add`. Take the file
  over deliberately by removing both lines. To give it back: delete the file and
  restart the workspace, or re-materialize it with
  `bazelisk run //scripts:seed-dev-env -- --force`.
- A declared github server that fails handshake: the owner has not connected
  GitHub External Auth, so `$GH_TOKEN` is empty. Use the **GitHub reauth** app,
  then start a new Grok session.
- A declared context7 server: an empty `CONTEXT7_API_KEY` is the shipped default and
  does *not* fail the handshake. With no value the server sends no `Authorization`
  header, so it handshakes and answers at the public rate limit, and only private
  libraries are out of reach. A key in `.env` plus a re-push fills the env. When a
  context7 handshake really fails the key is not the cause: run
  `bazelisk run //scripts:mcp-check` and it says which of the block, the binary, the
  cache config or the handshake is not OK.
- No `web_fetch` either, and that is not a misconfiguration: `features.web_fetch` is
  on, but on a non-xAI model endpoint that tool runs only through
  `toolset.web_fetch.proxy_endpoint` and this stack sets none. Route a URL already in
  hand to `searxng`'s `fetch_content`, anything else on the web to the `searxng`
  `search` tool, and a library, framework, CLI or setup question to `context7`
  (`resolve-library-id` first, then `query-docs` on that id).
- Discover live tool names with `search_tool`, then call `use_tool` with that
  schema. Do not hardcode MCP tool names from memory.

### A workspace app link answers `Bad Gateway` -> find who answered

The **VS Code Web** button is the one app this stack still proxies: its URL is
`/@<owner>/<ws>.<agent>/apps/code-server` on the coder hostname, because
`coder_app.code_server` sets `subdomain = false`. So a failing app link is an app-lane
failure, and a 200 from `litellm-gmktecbeast.` is not evidence about it.

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
  http://host.docker.internal:8080/@<owner>/<ws>.main/apps/code-server
```

`--noproxy '*'` matters: with a proxy set in the environment curl hands the name to the
proxy instead of resolving it, and `000` or a 5xx then describes the proxy.

- `000` on the first probe means nothing listened on 4000. A `200 application/json`
  means LiteLLM answered, so the model lane is healthy and the app lane failed
  somewhere else.
- `000` on the second probe means the private lane is down as well, so the public
  failure is not a cloud-side one. `421` means the Host header matched no
  `server_name` here, which is what a rewritten Host looks like. `STACK_ROUTER_CONF`
  in `.env` names the conf those `server_name` lines live in; the vhost side of it is
  in [UI and logins](#ui-and-logins).
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

### A stack skill command missing from Grok Build on code-server web -> the stack's own seed is what provides it

Covers all six stack-shipped skill commands: `/ez-learn`, `/ez-skillify`,
`/ez-create-skill`, `/ez-bazel-first`, `/ez-strong-types` and `/ez-trunk-based-repo`. The
diagnosis and the commands below are identical for each one; only the name changes, so read
`<name>` as whichever of the six you are chasing. The last three are the
repository-conversion family and ride `coder_script.stack_repo_skills` rather than
`coder_script.stack_skills`, so a missing one of those points at that body's log.

Cause: no published source names an upstream `/learn`, so there is none to miss. The
`xai-org/grok-build` built-in command table, all 240 pages of docs.x.ai, every
first-party changelog under `x.ai/cli/changelogs/`, and the public
`xai-org/plugin-marketplace` catalog all carry zero occurrences of it, so there is no
published copy to vendor in. The memory family
`/ez-learn` copies (`/flush`, `/dream`, `/remember`, `/memory`) is a different case:
those are upstream commands the CLI ships itself - `/flush`, `/dream` and `/memory` are
*built-in* registry entries gated behind cross-session memory, which is off by default
here, and `/remember` is a pager command with no such gate. The CLI does download its
bundled platform skills at runtime (`GROK_SKILLS_BASE_URL`, `cli-chat-proxy.grok.com`)
and that route needs an x.ai sign-in: from a workspace `api.x.ai` answers 404 and
`cli-chat-proxy.grok.com`
answers 401 anonymously, and a session started with `--sandbox off` still leaves
`~/.grok/bundled/` uncreated. LiteLLM is the sole model transport here, there is no
x.ai credential, and the fetch never runs. So each slash command this stack ships is its
own seed, written at workspace start by `coder_script.stack_skills` into
`~/.coder/skills/<name>/SKILL.md` with a twin copy at
`~/.agents/skills/<name>/SKILL.md`, and a missing command means that seed is
missing, not that the image is stale. Each carries its own `ez-` name to stay clear of
the upstream names: a user-scope skill overrides a same-named bundled one, so a seed
named `create-skill` would hide the CLI's bundled platform skill of that name on any
CLI that does sign in.

```sh
bash -lc 'command -v grok; grok --version'
grok inspect --json | grep -n '<name>'
ls ~/.grok/bundled/skills 2>/dev/null
ls ~/.agents/skills/<name>/SKILL.md ~/.coder/skills/<name>/SKILL.md
ls -d ~/.coder/skills/learn ~/.agents/skills/learn 2>/dev/null
```

- An entry for `<name>` with `userInvocable: true` in the `grok inspect --json` output is
  the pass condition: the slash command exists on that CLI, and the **Grok Build**
  terminal profile shows it because that profile execs the same binary.
- No `<name>` entry and both `ls` paths missing: the seed never landed, which means the
  workspace booted from templates pushed before the seed existed. Re-push the templates
  and restart the workspace, or reseed into the running container from the stack host:
  `bazelisk run //scripts:refresh-configs -- --container coder-<owner>-<ws>`.
- One of the six missing from both homes while the others landed points at the one body
  that seeds it: `coder_script.stack_skills` carries the authoring trio and
  `coder_script.stack_repo_skills` carries the repository-conversion family. That script's
  own log is where its seed body ran or failed, and the body is silent on a healthy
  workspace, so an empty
  log with a missing file means the body did not run at all (restart the workspace and
  read that script's log). The trio moved out of `startup.sh.tftpl` into that one body, so
  a startup-script log that says nothing no longer covers it. A `SKILL.md` that is present
  while its `scripts/*.py` helper is missing is the same story on the helper's own absent
  guard: the family seeds six payloads, each guarded on its own path.
- Both `ls` paths present but no `<name>` entry: the loader dropped the file. Frontmatter
  must start on line 1, so anything above the opening `---` silently kills the skill.
- A `learn` directory still listed by the last `ls` is a copy someone took over: the boot
  and the reseed delete that path only while it still carries the stack marker, and a
  marker-free file is user-owned, so it stays. A marker-carrying leftover is retired on
  the next boot or reseed, and that removal only finishes the rename: no published source
  names an upstream `/learn` for the name to free.
- A file you deleted or edited on purpose is not a fault. To keep your own version,
  edit it and delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free
  file is user-owned, and the seeder leaves it alone unless you pass `--force`. A
  deletion is undone - the workspace boot writes the file again whenever it is absent,
  and `refresh-configs` re-seeds an absent target, so the next boot restores the
  stack's copy. Copy the payload back from `templates/common/<name>.SKILL.md` to give
  the file back to the stack.
- `ls ~/.grok/bundled/skills` printing nothing is the expected answer, not a symptom:
  without the sign-in there is no bundled cache at all, on any version. Because a
  user-scope skill overrides a same-named bundled one, and the built-in memory names are
  the CLI's, this stack's seeds deliberately carry `ez-` names; the boot and the reseed
  retire a marker-carrying `skills/learn/SKILL.md` that predates the rename rather
  than relying on you to delete it, since deleting a seeded copy would not retire the
  old command name anyway - the boot and the reseed write it again. What works: keep a
  marker-free local copy only if you also stop the stack from seeding it, or disable
  the lane with `disabled = ["<name>"]` under `[skills]` in `~/.grok/config.toml`.
- `command -v grok` answering `~/.grok/bin/grok` is the normal answer, not a leftover
  installer copy: the workspace `PATH` lists `~/.grok/bin` before `/usr/local/bin`, and
  that entry is a symlink into `~/.grok/downloads/`, which holds one file per downloaded
  release and is where `grok update` installs - so moving it aside does not outlast the
  next self-update. Compare `command -v grok` and both `--version` outputs
  (`~/.grok/bin/grok --version`, `/usr/local/bin/grok --version`) against `GROK_VERSION`
  in `images/dev/tool-versions.env`: the profile copy follows `grok update`, the image
  copy follows the pin. Neither copy gates the three seeded commands, and the two
  disagreeing is never on
  its own a reason to rebuild the image.
- A golden image that predates a pin bump reports an older `/usr/local/bin/grok` than
  `GROK_VERSION` (1.0.77 at the time of writing), and rebuilding `images/dev`
  (`bazelisk run //scripts:build-dev-image`) is the CLI upgrade path - but the seeded skill commands
  work on either CLI, so this symptom alone never justifies an image rebuild.
- Pin notes and the seeding contract: [grok-build-and-agents.md](grok-build-and-agents.md).

### `grok doctor` flags `voice.no-input-device` or `terminal.limited-color` -> a headless container, and where you ran the command

Cause: both are properties of the environment. Neither points at a workspace that
needs repair, and neither is fixable from inside the container.

```sh
ls /dev/snd /proc/asound 2>&1 | head       # both absent: no capture device exists
echo "NO_COLOR=[${NO_COLOR-unset}]"         # set inside an agent tool command only
```

- `voice.no-input-device`: the container has no microphone and no recorder on
  PATH. The probe checks for a recorder binary, so installing `alsa-utils` makes
  Doctor answer `available` with nothing to record from; the image ships no
  recorder and the finding stays. The PulseAudio route that would make capture
  real: the voice bullet in [grok-build-and-agents.md](grok-build-and-agents.md).
- `terminal.limited-color`: a tool command spawned by a running Grok session
  inherits `NO_COLOR=1`. Rerun `grok doctor` from the terminal itself and the
  report reads `color truecolor` with `themes all`.
- A tmux finding that survives a reseed of `~/.tmux.conf` is a reload gap: a
  client reads `terminal-features` when it attaches. Run `tmux source-file
  ~/.tmux.conf`, detach, reattach, then `tmux display -p '#{client_termfeatures}'`
  and expect `RGB` and `extkeys` in the list.
- `terminal.ssh-wrap` asks to be run on the workstation you type `ssh` on:
  `grok doctor fix ssh-wrap` there. Nothing a workspace installs satisfies it.

### `The terminal process "/bin/bash '-lc', 'exec "$HOME/.grok/bin/grok-build-terminal"'" terminated with exit code: 1` -> something closed the tmux session under the tab

- Cause: that profile ends in `exec tmux new-session -A`, and tmux exits 1 whenever it
  refuses. When a running agent meets it, the usual cause is the agent's own cleanup
  sweep - `tmux kill-server`, `tmux kill-session`, `pkill -f tmux` - closing the session
  the agent is typing in. The tab's process is that session's client, so the command
  takes the agent, its tool call and the in-flight reply down together.
- Other refusals answer with the same exit code: `sessions should be nested with care`
  (a `TMUX` the tab inherited), `open terminal failed: not a terminal`, and `-c <dir>`
  naming a directory that is gone.

```sh
tmux ls                                         # what survived
tmux new-session -A -s probe; echo "exit=$?"    # replay the helper's exec by hand
```

- What the stack does about it: both config twins deny the self-teardown family, so an
  agent's `kill-server`, `kill-session` or `pkill*tmux` is refused before it runs. The
  `[permission]` bullets in [grok-build-and-agents.md](grok-build-and-agents.md) carry
  the whole list and what an agent uses instead.
- Reaching a shell once the sessions are gone: pick the **bash** profile from the
  terminal dropdown, which opens a shell no helper mediates. Then reseed from a host
  shell (`bazelisk run //scripts:update-configs -- workspace`) and restart the workspace,
  which is what re-renders its `~/.grok/config.toml`.

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

### `REPO_ROOT: unbound variable` from `push-template` -> the size guard read an ambient root

- Symptom: `bazelisk run //scripts:push-template` prints `== Preflight ==` and
  `== Variables ==`, then aborts inside `== Templates ==` with
  `push-template.sh: line 740: REPO_ROOT: unbound variable` and never prints a
  `summary:` line. Nothing was pushed.
- Cause: `startup_size_guard` looks up a payload the twin does not keep beside its
  own `main.tf` under `templates/common/`, and it did that by reading an ambient
  `REPO_ROOT`. Nothing in `scripts/` ever sets that variable: the checkout is the
  `root` the script resolved and `cd`'d into at startup. Under the script's own
  `set -u` the read aborts the run. It only fires for a template that inlines a
  canonical payload, which is why a twin carrying its own copy never showed it.
- Fix: the guard measures against the resolved `root`, and a parser it cannot open
  is now a hard stop rather than a silent "everything fits". Pull this commit onto
  the stack host and re-run:

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

### `Unexpanded count argument on block "coder_app.github_app_install"` -> apps were gated on start_count

Cause: `coder/preview` warns when a `coder_app` `count` is not expanded at
workspace-create preview. `start_count` is that value. The default is then
assumed to be 1. The only `coder_app` carrying a `count` today is
`coder_app.github_app_install`, and it counts on `github_auth_id`, which the
preview does expand.

Fix: `coder_app` resources are not gated on `start_count` (scripts, metadata
and the container still are). Push the templates; new creates stop showing the
warning. Existing workspaces pick it up on the next update to the new template
version.

```sh
bazelisk run //scripts:push-template
```

### `bash: -c: line 32: syntax error near unexpected token '('` after "Running code-server in the background" -> HCL `$$((` in the editor wait loop

Cause: Coder runs every `coder_script` as `bash -c`. HCL heredocs in `main.tf` only
escape `$${name}` to `${name}`; `$$((` is two literal dollars. The editor wait loop
then becomes `waited=<pid>((waited + 1))`, which is the syntax error. The echo
before the loop still prints. `already cloned, skipping` on the next line is the
concurrent clone stage, not the failure.

Fix: the increment is `waited=$((waited + 1))` (one dollar). Push the templates and
restart so the editor script relaunches.

```sh
bazelisk run //scripts:push-template
coder restart <workspace>
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

### A copy from an app inside a tmux pane never reaches the laptop clipboard in VS Code Web -> the browser build drops OSC 52

Cause: an app inside the pane - vim's `+` register, anything that emits OSC 52 -
pushes its copy out through the pane, `set-clipboard on` with
`allow-passthrough on` forwards it, and code-server's terminal hands the escape to
nobody. There is no setting for it: the shipped 4.145.0 registers no OSC 52 key,
and upstream
[microsoft/vscode#318254](https://github.com/microsoft/vscode/issues/318254) is
open with two unmerged fixes. Over ssh from Ghostty, kitty, WezTerm or iTerm2 the
same copy lands, which puts the drop in the browser and not in tmux.

```sh
tmux show-options -g mouse           # off: the client keeps the click, so a drag is yours
tmux show-options -g set-clipboard   # on: the tmux end of the pane app's OSC 52 route
```

Fix: there is nothing to turn on in tmux. Copy the text the way the rest of the tab
does - a plain drag is the client's own highlight, because tmux asks for no mouse
reporting (measured on the shipped tmux 3.4: an attach with `mouse on` writes
`ESC[?1000h`, `ESC[?1002h` and `ESC[?1006h` to the client, one with it off writes
none), and the settings seed's `terminal.integrated.copyOnSelection: true` puts
that highlight on the machine clipboard with no chord (the headless harness on
4.145.0 recorded `navigator.clipboard.writeText` firing on a client selection,
before this switch). Right-click pastes
it back (`terminal.integrated.rightClickBehavior: "copyPaste"` pastes when nothing
is selected) and middle-click pastes it too (`middleClickBehavior` pinned to
`"paste"`). tmux keeps no buffer of its own, so `Prefix-]` is unbound and there is
no `tmux show-buffer` to read: the machine clipboard is the only clipboard here.
`Prefix m` is the wheel switch, not a copy route: one press hands the wheel to tmux
for a long scroll, the next hands it back. Paste is `Ctrl+Shift+V` or right-click in
a bash terminal and a tmux pane alike, and `Ctrl+V` is not a paste on a secure
origin (the pane gets the `\x16` byte). Both directions, and what a pane app may
still do over ssh, are in
[Copy and paste between a tmux pane and the machine you type on](grok-build-and-agents.md#copy-and-paste-between-a-tmux-pane-and-the-machine-you-type-on).

- Output already scrolled off the screen: `Prefix-[` is a viewer, not a copier -
  walk up with `k`, `PPage` or `Ctrl-u` until the line is painted on the screen,
  select it with a client drag, then `q`. A selection made *inside* copy-mode is
  inert: every copy binding in `copy-mode-vi` is unbound, so nothing ends it.
- Copy and paste both dead, in both directions, a drag included: read the next
  entry. This one is a pane-app-only symptom, and a broken origin breaks the
  editor's own chords too.
- `history-limit` reads 100000 but a pane still forgets old output: tmux applies
  the option when the pane is created, so that pane keeps the limit it was born
  with. Open a new pane, or restart the server with `tmux kill-server`.

### Copy and paste both do nothing in VS Code Web -> the page is not a secure context

Cause: the browser exposes `navigator.clipboard` to a secure context only, and
Coder's LAN door is plain HTTP by default (`CODER_ACCESS_URL` is the LAN
address). Opened that way the editor has no clipboard API to call, so
right-click paste stops with VS Code's own toast - "This browser doesn't support
the clipboard.readText API needed to trigger a paste, try Ctrl+V instead." - and
`Ctrl+Shift+V` only works at all through the browser's native paste event. A
Clipboard site permission that was once denied does the same damage on an https
origin, and there VS Code answers `NotAllowedError: Read permission denied`.

```js
// In the editor tab's own devtools console:
window.isSecureContext            // false: the browser withheld the clipboard API
typeof navigator.clipboard        // "undefined" on http, "object" on https
```

Fix: open the editor on the TLS public name (the `coder-<host>.<domain>` door
Traefik holds a real certificate for) rather than `http://<LAN-address>`, and
give the site Clipboard permission - Chrome: the lock icon in the address bar,
Site settings, Clipboard, Allow. The templates are not the variable here: both
doors serve the same payload, so a workspace that pastes on one URL and does not
on the other is an origin problem. What still works on plain HTTP: copy with a
drag - the selection is the client's own, since tmux asks for no mouse reporting,
and `copyOnSelection`'s `document.execCommand('copy')` fallback really lands - and
paste with `Ctrl+V`, the browser's own paste event - which is exactly what VS Code's
toast tells you to do.

### VS Code Web tab in Chrome creeps to gigabytes, or freezes now and then -> every tab was another mirror of one pane

Cause: each client attached to a tmux session is a full xterm.js in its own
Chrome tab re-parsing the same stream, each with a scrollback buffer
preallocated from `terminal.integrated.scrollback` (VS Code preallocates the
buffer from the value, and xterm.js keeps 3 `Uint32` words per column per
line), plus a per-client encode in the tmux server and a re-wrap repaint for
every client each time any of them activates or resizes. Count the clients
against the panes:

```sh
tmux list-clients
tmux list-sessions -F '#{session_name} attached=#{session_attached}'
```

More clients than you have visible terminals means the tabs are mirrors.

Fix: the seed keeps one pane per visible terminal. `vscode-terminal-tmux`
reattaches a folder's session only while nothing is attached to it, and opens a
numbered sibling (`vscode-<folder>-<hash>-2`, `-3`, ...) beside live ones, so an
extra tab is a new pane rather than a mirror. Every session target in that
helper carries tmux's `=` exact-match prefix, because a bare name is also
answered by any session starting with it - once `foo` is closed, `foo-2` would
otherwise answer for it and put a second client on a live pane. And when tmux
3.4 does take a session down under a tab that is reopening it, the helper raises
a fresh one rather than letting the tab exit with it. The settings seed drops
`terminal.integrated.scrollback` to 2000 - the browser keeps a short viewport
and tmux's `history-limit 100000` behind `Prefix-[` holds the deep history - and
turns `cursorBlinking` off, and `templates/common/tmux.conf` sets
`set -s escape-time 10` and `set -g focus-events on`. The first is the freeze:
3.4 holds back any Escape it reads for 500 ms to decide whether a sequence
follows, so Alt and the arrow keys feel like dropped input and a focus-in can
wait that long - twice, with `set-timing` - before tmux repaints. Upstream cut
the default to 10 ms in 3.5, and 0 - the value vim guides suggest - is the one
to avoid: measured on this build, a throttled tab that delivers Esc and the next
character more than 10 ms apart loses its Alt chords, and 0 makes that far
likelier. `focus-events` is what gives tmux a focused client to work with at
all. `aggressive-resize` stays at its default on purpose: its own entry in
`options-table.c` scopes it to the `smallest` and `manual` `window-size` modes,
the shipped default is `latest`, and tmux(1) calls it "poor for interactive
programs such as shells". Both files reseed on the next start only while they
still carry the stack marker, so delete either one you edited by hand. Before
debugging a setting that will not take: tmux reads `~/.tmux.conf` and then
`$XDG_CONFIG_HOME/tmux/tmux.conf` and `~/.config/tmux/tmux.conf`, last file read
wins, so either of those quietly outranks everything the seed writes.
`focus-events` is read when a client attaches, so the tabs need to be gone for
it to land: close them all after the restart and reopen one per pane.

```sh
bazelisk run //scripts:push-template
coder restart <workspace>
```

- If a tab keeps dying on you and you want to know whether the pane's shell
  exited or tmux took the session down under the tab, run `tmux set -w
  remain-on-exit on` in it first: the pane then stays on screen with its exit
  status in `#{pane_dead_status}` instead of vanishing, which is what the
  [tmux FAQ](https://github.com/tmux/tmux/wiki/FAQ) recommends for exactly this
  question. Turn it back off afterwards - a dead pane is not yours to keep.

- Residual: a tab you hide rather than close keeps its xterm instance alive and
  still buffers whatever the pane prints, and nothing in the stack caps that.
  Neither does tmux: 3.4 has no per-client output limit, and an ordinary
  attached client that stops draining its pty is never dropped (measured here:
  one stayed attached past 15 minutes while the server kept serving commands).
  The only "too far behind" disconnect is in control mode, behind a hardcoded
  300 s age in `control.c`, which a VS Code tab never uses.
  [microsoft/vscode#327437](https://github.com/microsoft/vscode/issues/327437)
  is open (a heap snapshot showed ~38 live terminals holding ~80 MB of a 484 MB
  renderer heap) and
  [coder/code-server#6413](https://github.com/coder/code-server/discussions/6413)
  reports browser-tab RAM reaching several GB with a continuous-output terminal
  left running after the tab is closed; neither has a maintainer mitigation.
  Closing the tab is the mitigation, and the numbered sessions are what make the
  live set match the tabs you can see.

### GitHub token expired, or the workspace has no GitHub account -> GitHub reauth

- What you see: `git push` answers `remote: Invalid username or token. Password
  authentication is not supported for Git operations.`, or `gh auth status` calls the
  token invalid. An expired token and a never-connected account read the same from that
  message, so ask which one you have before you touch either.

```sh
bazelisk run //scripts:github-auth -- check [repo-url]
```

- What its answers mean here: `REJECTED` beside `env token (GITHUB_TOKEN/GH_TOKEN)` is an
  expired mint (401 refuses the credential itself, which is what an hour-old injected
  copy is); `NO GitHub credential in the chain slot` means nothing is connected and
  nothing can be minted; `PUSH-READY` means the credential is fine and you want
  [the push-denied entry](#private-repo-clone-or-push-denied-while-a-credential-is-present---the-grant-not-the-format)
  instead.
- The one command, whichever of the two it was:

```sh
bazelisk run //scripts:github-auth -- fix [repo-url]
```

  Inside a workspace it repairs that workspace; on the stack host `fix <container>
  [repo-url]` names the one workspace it repairs, and a host run with no container is
  refused for exactly that reason. It mints a live token through Coder external-auth (the
  injected pair is never trusted, because it is the frozen copy that expired), writes the
  gh auth store, points git's `github.com` and `gist.github.com` credential helper at that
  store through a form that clears the env pair first, then re-runs the write probe and
  prints the verdict again, so it proves itself. It is idempotent and it never prints a
  token.
- When nothing can be minted AND the store is empty its line begins `HANDOFF` and names
  the three clicks below. That line is the boundary: no command run in that workspace can
  do them.
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
  grant. `fix` makes git push work without the restart; the injected pair itself only
  changes when the workspace restarts or `gh_token_refresh` next runs.
- Existing workspaces pick up the buttons after `bazelisk run //scripts:push-template`
  and a workspace update to the new template version.
- How the credential is assembled, and what every slot in that report is, is one page:
  [GitHub credentials for a workspace](coder-templates.md#github-credentials-for-a-workspace).

### gh_token_refresh says gh would not store the minted token

- What you see, in that `coder_script`'s log, is its own two lines:

```text
gh would not store the minted GitHub token.
next: inside the workspace run: GH_TOKEN= GITHUB_TOKEN= gh auth status
```

- Cause: the refresh script inherits `GH_TOKEN`/`GITHUB_TOKEN` from the agent, and
  `gh auth login --with-token` refuses stdin while those names are set (`The value of the
  GH_TOKEN environment variable is being used for authentication`). Current templates
  unset the pair, log out, then log in with `--git-protocol https`, and print gh's
  stderr (token redacted) if that still fails - which is the line above.
- The one command does the same three steps and then proves them:

```sh
bazelisk run //scripts:github-auth -- fix [repo-url]
```

- Then read the store with the pair cleared, because `gh auth status` on its own reports
  the env pair rather than what is stored:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh auth status
```

- What each answer means: a store that now holds a token means git is repaired and the
  refresh script keeps it fresh (start, then every 20 minutes); `gh refused the token, so the
  store is unchanged` means the credential is revoked or the account disconnected, so run
  `check` to see what github.com says about it, then take the clicks from
  [the reauth entry](#github-token-expired-or-the-workspace-has-no-github-account---github-reauth);
  `cannot install the credential helper - gh is not installed` is
  [the gh-not-installed entry](#gh-command-not-found-inside-a-workspace---the-helper-needs-gh).
- `HANDOFF` means there is no credential anywhere in reach: click **GitHub reauth**,
  finish device-code login, install the Coder GitHub App if the reauth page says to, and
  restart. Those clicks are in
  [the reauth entry](#github-token-expired-or-the-workspace-has-no-github-account---github-reauth),
  and the script's own note on a workspace with no connected account points at the same
  two buttons.

### Private-repo clone or push denied while a credential is present -> the grant, not the format

- What you see is one of: `remote: Invalid username or token. Password authentication is
  not supported for Git operations.`, `remote: Repository not found.`, `fatal:
  Authentication failed for 'https://github.com/...'`, or `fatal: could not read Username
  for 'https://github.com'`. None of them names the token or its age, and the first is
  what a refused token plus a silent askpass looks like, not anything to do with
  passwords.
- The one command, run where the push was attempted, naming the repository:

```sh
bazelisk run //scripts:github-auth -- check [container] [repo-url] [--source=<slot>]
```

  It does not ask "is there a credential" and it does not trust the environment: it runs
  git's own configured helper the way git runs it, takes the password that would go on the
  wire, and probes THAT credential against the endpoint `git push` negotiates through -
  one GET of `<repo>.git/info/refs?service=git-receive-pack`. A read-only credential
  prints REFUSED-GRANT, never a pass; a healthy-but-shadowed one prints `push would FAIL`,
  never `ok`. Inside a workspace (or the contributor devcontainer) it runs SELF mode with
  no docker and prints one `self:` line per credential; on the stack host it enumerates
  the labeled workspace containers, or probes a named container alone. Flags may go before
  or after the positionals, and a path below `owner/repo` is refused rather than probed.
- The repair is also one command, and every `push would FAIL` line names it:

```sh
bazelisk run //scripts:github-auth -- fix [container] [repo-url]
```

- Read the report by its last line, then by these. `git would send this credential
  (source: <slots>)` is the credential a real push uses, in git's consult order; the same
  token held by several slots is named once, as one credential with several names. A plain
  `credential present (source: <slots>)` is a credential that exists and that git never
  reaches.
- `[shadowed: the credential above outranks this slot, ...]` is the most misread line in
  the report: the credential under it is healthy and git will not use it while the env
  pair stands. `env -u GH_TOKEN -u GITHUB_TOKEN <command>` makes git or gh use that slot
  for one command; `fix` makes it permanent for git. See
  [the Bad credentials entry](#gh-answers-bad-credentials---the-stale-env-pair-not-the-store).
- `NO GitHub credential in the <slot> slot (git will prompt and be refused)` means there
  is nothing to send, so the account comes first:
  [the reauth entry](#github-token-expired-or-the-workspace-has-no-github-account---github-reauth).
- The note line, `note: GIT_ASKPASS is set but answers no credential, which is what turns
  a refused token into "Password authentication is not supported for Git operations."; a
  working credential helper makes it moot`, is the second half of the story. The agent env
  exports `GIT_ASKPASS` pointing at the `coder` binary the agent staged under
  `/tmp/coder.<rand>/`, and in a measured workspace that binary answered every prompt, and
  `coder gitaskpass` itself, with `unrecognized subcommand` and no output, so git got no
  answer at all and fell through to prompting. Clearing `GH_TOKEN`/`GITHUB_TOKEN` helps
  only while the helper answers; with a silent helper it changes nothing.
- `push would WORK (the credential git consults writes <repo>)` and `push would FAIL` are
  the lines to gate on, keyed to the credential git would really send; `check` exits
  non-zero on FAIL so a script or an agent can refuse to push on it.
- The verdicts, and what each one costs you:
- `PUSH-READY` (200 advertising refs): a push would negotiate. If the push still fails,
  the credential is not the failing thing.
- `REFUSED-GRANT` (403): that credential authenticates and every write to the repo is
  denied, which is the push 403.
- `NOT VISIBLE` (404): a private repo hidden from it answers 404, and so does an absent
  one; clone and push would both fail.
- `REJECTED` (401): github.com refused the credential itself, as it refuses an expired or
  revoked token - the fate of the injected pair about an hour after start. `fix` re-mints.
- `no useful answer`: github.com gave nothing useful (offline? probe again). A 200 that
  does not advertise refs is this verdict too: a push is not proven.
- `--source=chain` (the default) probes every credential that could answer for that
  repository; `--source=env`, `--source=gh` or `--source=mint` answers one slot and says
  beside the answer that git and gh consult the env pair first.
- Reads prove nothing about push, so nothing here asks a read question: a public repo
  answers a read for any authenticated caller, so a credential that READS a repo can still
  be refused every WRITE to it. Go to the GitHub side only after the report says
  REFUSED-GRANT or NOT VISIBLE.
- The grant behind the credential - the GitHub App installation that the External Auth
  provider (id `github` by default) minted its token from - has to include the repository
  the workspace clones or pushes: GitHub -> Settings -> Applications -> `<app>` ->
  **Configure** -> Repository access.
- An empty [github.com/settings/apps](https://github.com/settings/apps) page is the usual
  surprise here: it means no App is installed under your account, so there is no
  **Configure** link to click and nothing to grant, while the provider itself stays
  configured and keeps minting tokens that authenticate. Install Coder's App from the
  workspace **Install GitHub App** button, or at
  [github.com/apps/coder/installations/new](https://github.com/apps/coder/installations/new),
  grant the repo, then restart. A private repository is never visible to a credential
  that was never granted it.
- Then check the URL scheme, which no probe can fix: that credential covers
  `https://github.com/...` remotes only, so a `git@github.com:` or `ssh://` URL gets
  neither helper nor askpass token and needs an SSH key you placed yourself, which this
  stack provisions nowhere.
- Then check **how** the credential is sent, because the two GitHub endpoints disagree
  about the scheme. `api.github.com` and `gh` accept `Authorization: Bearer <token>`. The
  git data endpoint refuses it: one token answered `/user` with `200` and
  `<repo>.git/info/refs?service=git-receive-pack` with `401` plus
  `remote: invalid credentials` while the token rode a bearer header. git has to send it
  as **Basic** auth with the token as the password. The username text is not checked
  (measured on Coder v2.36.6: `toxicoder`, `x-access-token`, `somebody-else` and `octocat`
  each returned `200`), but an empty username or an empty password is refused, and the
  empty password is what produces the misleading `Invalid username or token. Password
  authentication is not supported for Git operations.`
- Do not hand-roll a credential helper. Measured across 222 past sessions in this
  workspace: 29 hit a GitHub auth error (`Bad credentials` 19, `Password authentication is
  not supported` 11, `could not read Username` 5, `unrecognized subcommand` 4), and agents
  hand-rolled their own askpass scripts in 5 sessions and hand-edited `credential.helper`
  in 4. Both were wrong the same way: they fought the credential-helper precedence that
  `fix` repairs, and they put a live token where `ps` could read it, while the line that
  names the real cause was one `check` away. `fix` is idempotent, keeps every token off
  argv and out of any file it creates, and repairs the helper plus the store it reads.
- Your own credential stays gated on the report: install one only after `check` has
  answered `REFUSED-GRANT`, `NOT VISIBLE` or `REJECTED`. No verdict short of those
  justifies a pasted token, and the repo rule is that a workspace's GitHub credential
  comes from the External Auth provider alone. From the stack host (it drives `docker
  exec`, so it has no SELF path), on stdin:

```sh
bazelisk run //scripts:github-auth -- auth <container> - < PAT
```

  It installs that credential into that one workspace's gh auth store and then
  re-installs the env-proof helper that `gh auth setup-git` would otherwise leave behind,
  since that helper goes straight back to echoing a stale env pair over the token just
  pasted. A PAT is never typed as an argument: argv is readable through `ps` and the
  token lands in shell history. Pipe it in (`echo "$TOKEN" | bazelisk run
  //scripts:github-auth -- auth <container> -`) or run `auth <container>` alone and
  answer the hidden prompt. In the line above, `-` is the only argument after the
  container and `< PAT` is a shell redirect, not an argument. It REPLACES the per-start
  minted credential for that workspace, and while the account stays connected the next
  `gh_token_refresh` run rewrites the store, so treat a pasted PAT as a stand-in and
  rotate or remove it in GitHub -> Applications when the work ends.
- Full usage, verdict kinds and both argument orders:
  `bazelisk run //scripts:github-auth -- -h`.

### `gh` answers `Bad credentials` -> the stale env pair, not the store

- What you see, inside a workspace: `gh api /user`, `gh pr create` or `gh repo view`
  answers `Bad credentials` (HTTP 401) while the same command on the stack host works, and
  `gh auth status` still insists you are logged in. This is the most frequent GitHub
  failure here: 19 of 222 past sessions in this workspace hit `Bad credentials`.
- Cause: Coder injects `GH_TOKEN`/`GITHUB_TOKEN` into the agent environment when the
  workspace starts. That GitHub App user-to-server token expires about an hour later and
  the injected copy is never refreshed for the life of the workspace. `gh` consults that
  pair before it reads its own auth store, so it sends the dead token while the store
  beside it, re-minted by the `gh_token_refresh` coder_script, is healthy and unreachable.
- The answer for every `gh` call, for as long as that workspace lives:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh <args>
```

  No process can rewrite another process's environment, so the stale pair stays in the
  environment until the workspace restarts; the prefix is the permanent form, not a
  workaround you graduate from.
- `git` needs no prefix once `fix` has run, because the helper it installs clears the pair
  itself:

```sh
bazelisk run //scripts:github-auth -- fix [repo-url]
```

- You read the right line when `check` marks the healthy stored credential
  `[shadowed: ...]`: that label is this entry. If the credential `check` says `git would
  send` is the env token and it answers `REJECTED`, `fix` is the repair; if it answers
  `REFUSED-GRANT`, it is a grant and the clicks are in
  [the push-denied entry](#private-repo-clone-or-push-denied-while-a-credential-is-present---the-grant-not-the-format).

### `gh: command not found` inside a workspace -> the helper needs gh

- What you see is `gh: command not found`, or `fix` refusing with `cannot install the
  credential helper - gh is not installed in this environment; install gh (apt install gh,
  or the pinned copy the golden image ships) and run this again`. `check` reports the same
  hole honestly: with no gh there is no `gh stored login` slot to read, and a chain with
  nothing else in it prints `NO GitHub credential`.
- Why it blocks the repair rather than just the CLI: the helper `fix` installs is
  `gh auth git-credential` wrapped in `env -u GH_TOKEN -u GITHUB_TOKEN ...`, and the
  credential it points git at is the gh auth store. With no `gh` binary there is no
  env-proof helper to install and no store to write, so `fix` refuses and says so instead
  of leaving a half-repaired `~/.gitconfig` behind.
- Install gh, then run `fix` again. The golden image ships a pinned copy (`gh 2.101.0`,
  from the release tarball, at `/usr/local/bin/gh`); apt's `gh` is 2.45 and predates
  subcommands the agent experience uses, so the durable fix is the image, not the distro
  package. Rebuild the image, then rebuild the workspace: the image is fixed at create
  time.

```sh
bazelisk run //scripts:build-dev-image
```

- Whether you are looking at a missing tool or a missing credential, `check` is what tells
  them apart: a missing binary shows up as a slot that cannot answer, a missing grant
  shows up as `REFUSED-GRANT`.

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

The assistant also opens in your own terminal with
`bazelisk run //scripts:hermes-shell`. When you cannot tell whether the agent,
its volume, or the model lane is the broken part, start with the readiness
report — it launches nothing and names each blocker (daemon, container state,
seeded volume, model key set or still a placeholder, LiteLLM
`/health/liveliness`):

```sh
bazelisk run //scripts:hermes-shell -- check
```

### Public `hermes-gmktecbeast` answers `421` -> no vhost, a rewritten Host, or Traefik aimed past the router

Cause: this box's `router` answers `421` when the Host matches no `server_name`.
The hermes vhost is not typed by hand: `STACK_ROUTER_CONF` in `.env` names the conf
compose mounts (`proxy/router.gen.conf`, which bootstrap renders from
`proxy/router.conf.template`, or the checked-in `proxy/router.conf` while that key is
empty), and every `server_name` in it is composed from the naming parts. Under
`STACK_PUBLIC_HOSTS=auto` a missing or mistyped part is what produces a name nothing
answers. Traefik pointed at `:9119` never hits that file. A rewritten Host also
misses every block.

The public backend is the same hop as the other names. Replay it from a
workspace, which reaches the published router and skips Cloudflare, Traefik and
Authelia:

```sh
curl -sS --noproxy '*' -o /dev/null -D - -H 'Host: hermes-gmktecbeast.overeazy.io' \
  http://host.docker.internal:8080/
```

- `421` means this box has no vhost for that Host. `STACK_ROUTER_CONF` in `.env` is
  what tells you which conf compose actually mounted, so read that file's
  `server_name` lines first, then recreate `router` so it picks up the one that
  lists `server_name hermes-gmktecbeast.overeazy.io`.
- Anything else means the router matched (Hermes basic auth is `401` until you
  send credentials). A `421` only on the public URL, with this probe succeeding,
  is a rewritten Host or a Traefik backend that is not `:8080`.
- Under `auto` both sides come from the same parts, so a `421` on a name nobody
  recognises is a part problem, not a router problem: an empty `STACK_DOMAIN_BASE`
  composes nothing (the stack stays LAN-only) and a mistyped `STACK_SUBDOMAIN_SUFFIX`
  or `STACK_ENV_LABEL` composes a name no vhost, no DNS and no certificate serves.
  Read the composed list back from `STACK_PUBLIC_HOSTS` in `.env`, fix the part, and
  re-run `bazelisk run //scripts:bootstrap`, then recreate. Editing the rendered
  `proxy/router.gen.conf` instead only survives until the next bootstrap, which
  re-renders it from the parts.
- A part carrying an extra dot is the other failure this table cannot catch: the
  composed name sits more than one label under the zone, the wildcard does not cover
  it, and the browser aborts with `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` before Traefik
  is ever reached, so no `421` is ever printed.
- `STACK_PUBLIC_HOSTS` does not create the vhost. It is what bootstrap writes
  into `STACK_HERMES_URL` / `HERMES_DASHBOARD_PUBLIC_URL` for the Chat tab.
  `bootstrap` now also warns when a name in that list is missing from the
  conf it mounts.
- The paste-ready Traefik file (one backend at `:8080`, `passHostHeader: true`,
  Authelia on the four interactive names, LiteLLM without Authelia) is in
  [public-access.md#traefik-configuration](public-access.md#traefik-configuration).

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
