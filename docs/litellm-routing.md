# LiteLLM model routing

Deep reference for the model lane: the aliases in `litellm/config.yaml`, how a request
picks a backend, what a pinned conversation does, and what happens when a Spark box goes
down.

Short version lives in [README.md](../README.md) ("LiteLLM model aliases"); this file is
the long version behind it. Symptom-first checks live in
[troubleshooting.md](troubleshooting.md).

Contents:

1. [One front door](#one-front-door)
2. [The alias table](#the-alias-table)
3. [Tool calls: the measured limitation](#tool-calls-the-measured-limitation)
4. [Routing inside the `agent` group](#routing-inside-the-agent-group)
5. [Fallback: `agent` to `coder`](#fallback-agent-to-coder)
6. [Reading the routing back](#reading-the-routing-back)
7. [Editing an alias](#editing-an-alias)
8. [Why this shape](#why-this-shape)

Related: [coder-templates.md](coder-templates.md) (the templates that render
`~/.grok/config.toml`), [grok-build-and-agents.md](grok-build-and-agents.md) (the CLI and
the control-plane chat), [project-conventions.md](project-conventions.md).

## One front door

### Two doors, one key

- Workspaces and desktops always talk to one base URL,
  `http://host.docker.internal:4000/v1`, and pick a model alias. That is the
  host-gateway door.
- The control-plane chat agent dials the same proxy at `http://litellm:4000/v1`, over the
  compose network, from inside the `coder` container. That is the server-side door.
- Both doors authenticate with the same `LITELLM_MASTER_KEY` value.
- Inside a workspace the key travels as the `LITELLM_API_KEY` environment variable, which
  `~/.grok/config.toml` references by `env_key`, so no key byte lands in a file.

### What an alias is

- An alias is a `model_name:` entry in `litellm/config.yaml`, not a model.
- Every alias is a stable name. A workspace setting never has to change when a backend
  moves behind one.
- A rename or deletion is the edit that can reach workspaces: both
  `templates/*/grok-config.toml.tftpl` twins render the alias list into
  `~/.grok/config.toml`, a running workspace keeps the copy it rendered at start, and
  the next start re-renders it.

### Config keys that gate all of this

- `model_list:` is the alias list; `router_settings:` is the routing.
- `routing_strategy: least-busy` is the picker;
  `optional_pre_call_checks: ["session_affinity"]` is the pinning layer above it.
- `fallbacks:` carries one hop, `agent: ["coder"]`, the degrade path.
- `allowed_fails: 40` and `cooldown_time: 5` decide when a box stops being a candidate.
- `background_health_checks: true`, with `health_check_interval: 30` and
  `health_check_concurrency: 5`, re-probe a box on their own, so recovery does not
  wait for user traffic to rediscover it. Those two keys have to sit in
  `general_settings:`; under `router_settings:` the proxy raises `ValueError` at boot.
- `num_retries: 2` covers a transient blip; moving off a busy box is routing's job, not
  the retry chain's. `request_timeout: 1200` matches the CLI's own streaming idle
  allowance, so a slow call may take a full twenty minutes before either end gives up.

## The alias table

| Alias | Model | Backend | Structured tool calls |
|---|---|---|---|
| `agent` | `Qwen3.8-Flash-Next` | `SPARK1/2/3_OPENAI_URL` (TensorFold on :8888 - one deployment per Spark box, optional) | yes (measured) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |

### Reading the table

- The `agent` row is ONE model group with three deployments, one per Spark box,
  all equal.
- The `spark-*` rows are a different thing: the same Qwen2.5-Coder and Qwen2.5
  weights, served over Ollama on the Spark boxes instead of on the Arc.
- `unverified` on the `spark-*` rows means exactly that: this box never ran them
  against a live Spark, so the column records the absence of a measurement, not a
  "no".
- `model:` is sent to the backend verbatim, so `Qwen3.8-Flash-Next` has to match the
  served id byte-for-byte, case and hyphens included.
- The `agent` lane deliberately carries the `openai/` provider prefix. `ollama_chat/`
  would route those boxes through the Ollama-specific code path, and `api_base` has to
  include `/v1`.

## Tool calls: the measured limitation

### What was measured

- The Qwen2.5-Coder weights do not emit structured tool calls on this runtime.
- Measured against this box's IPEX-LLM Ollama, whose bundled `ollama` is 0.9.3.
- A request carrying `tools` for `qwen2.5-coder:32b` or `:14b` comes back as plain text,
  `finish_reason: "stop"`, and no `tool_calls` field at all.
- It behaves that way on both `/api/chat` and `/v1/chat/completions`.
- The model writes the JSON call into the message body, which no agent driver can consume.
- `qwen2.5:7b` on the same runtime does return a real `tool_calls` array.
- So the limitation tracks the model, not the runtime.

### What agent mode needs

- Agent mode therefore needs either the Spark `agent` lane or the small `chat` model.
- Grok Build, Cline, Roo and Kilo all default to `agent`.
- `scripts/coder-agents.sh` registers only `agent` (default) and `chat` as Coder Agents
  chat model configs, for the same reason: an agent turn without callable tools cannot
  browse or edit, so registering `coder` or `coder-fast` would only add a visibly broken
  model to the pickers.

## Routing inside the `agent` group

### One group, three deployments

- Three deployments, one per Spark box, and no `order:` tier. A tier would make the
  lower boxes unreachable while any tier-1 box stayed healthy.
- Spreading across every reachable box is the point of running three of them, five full
  262144-token streams each. Pinning only narrows the candidate list first.
- One endpoint per box, one box per endpoint. Never point two deployments, or two
  aliases, at the same physical machine: the proxy counts deployments, not machines.

### The picker: least-busy

- `least-busy` picks the healthy deployment carrying the fewest in-flight requests.
- Its counters are per deployment and expire after a hardcoded 3600 s; there is no
  `routing_strategy_args` block to set, and `ttl` there would be a paste from newer docs.
- It decides only for unpinned traffic: the affinity pin below resolves first, and
  `least-busy` runs when nothing is pinned, when the pinned deployment is unhealthy or in
  cooldown, and for any request with no session id.
- Health checks, cooldowns and those counters all attribute per deployment through
  `model_info.id`, which is why each box carries a unique id: `agent-spark-1`,
  `agent-spark-2`, `agent-spark-3`.
- A cooled box therefore stays visibly out of `healthy_deployments` instead of blending
  into the group's aggregate stats.

### The pin: session_affinity

- `session_affinity` sits above the picker, in `router_settings.optional_pre_call_checks`,
  and it arms the router's `DeploymentAffinityCheck`. Checked on LiteLLM 1.102.1.
- One conversation from one client sticks to the box that answered its first turn, for as
  long as that box stays healthy.
- The pin idles out after 1 h (3600 s) without a request, and every request refreshes it.
  It bounds idle time between requests, not conversation length.
- A conversation that goes quiet for longer than the TTL may move.
- A busy pinned box sheds its own overflow in its own scheduler instead of queueing
  inside the proxy.
- The trade is deliberate: stickiness buys prefix-cache locality and one predictable box
  for the whole conversation, so one workspace's agent loop can sit on a busy box.

### What carries a session id

A value has to look like an id to count: alphanumerics, hyphens or underscores, 8
characters or more. The sources, in order, are `x-litellm-trace-id`, then
`x-litellm-session-id`, then any `x-<vendor>-session-id`, then
`session-id`/`session_id`/`thread-id`/`conversation_id` (Codex style), then W3C
traceparent and baggage, plus `metadata.session_id` in the body.

- The Grok CLI forwards `extra_headers` verbatim.
- Both workspace templates render `x-litellm-session-id = "ws-<workspace-uuid>"` under
  `[models]` in `~/.grok/config.toml`, so one key covers every conversation of a
  workspace, subagent calls included.
- In `shared` profile mode that is one file per user, re-rendered by the last-booted
  workspace, which then shares that key across that user's workspaces.

### What floats freely

- Cline and Roo editor traffic carries no session id: the extension settings have no
  custom-header field.
- Coder Agents chats carry none either. Coder's aibridge forwards model calls with the
  provider key only and adds no per-conversation session id.
- Both float across the healthy boxes by load.

### When a pinned box cools or goes unhealthy

1. That request routes elsewhere, to whichever box `least-busy` picks.
2. The pin itself is kept.
3. The conversation goes back to the box once it is healthy again.

## Fallback: `agent` to `coder`

- When every Spark box is down, `router_settings.fallbacks` degrades `agent` straight to
  `coder`, which is text-only.
- Chat stays usable while agent mode quietly loses its tools. That is the point of the
  hop, not an accident.
- It used to be a chain, `agent -> agent-fast -> coder`. `agent-fast` was a second alias
  for the same model on a second box with a lower output ceiling; one group of three equal
  deployments already covers every reachable box, so the chain collapsed to one acyclic
  hop.
- If a concurrency cap is ever reintroduced, its pairing is `fallbacks` plus
  `context_window_fallbacks`. Both, not one.
- There are no rpm, tpm or `max_parallel_requests` caps anywhere, on purpose. A cap parks
  requests behind an in-memory semaphore inside the proxy; without one, a fully offered
  box sheds load in its own scheduler.

## Reading the routing back

### The Agent backend card

- The dashboard's **Agent backend** card exists to surface exactly that failure.
- Its per-box widgets go to error state while `agent` still answers, because `agent`
  answers from the Arc while every Spark is down.
- The card and its per-box widgets read `AGENT_MODEL_URL` and `SPARKn_HEALTH_URL` from
  `.env`, so they follow the LAN, and they answer without a key.

### Which box answered

- The `x-litellm-model-id` response header names the deployment that answered.
- With a pin, it names the pinned box; without one, whichever box `least-busy` picked.
- The proxy's own `/health` lists every deployment, so trust it over the absence of
  boot errors.
- A wrong model id does not crash the proxy: 1.102.1 builds the Router with
  `ignore_invalid_deployments` forced to True, so a bad id drops that deployment at boot
  with one log line and later surfaces as "No deployments available".

### The measured burst

Measured on a harness boot of this config against the live Spark boxes, before
`session_affinity` existed.

- That 30-request burst was multi-session, fan-out-style traffic.
- It spread 12/10/8 across the three deployments and returned 30x 200.
- With no concurrency cap configured, the proxy neither queued nor shed inside itself,
  and a fully offered box absorbed the overflow in its own scheduler.
- A single conversation pinned to one box now keeps its streams on that box while it
  stays healthy - that is the behaviour the burst predates.

## Editing an alias

1. Edit `litellm/config.yaml`.
2. Restart the proxy on the stack you changed, so it re-reads that file.
3. Check that `SPARK_1_API_KEY`, `SPARK_2_API_KEY` and `SPARK_3_API_KEY` are still
   non-empty. An empty key fails every request inside the proxy, before it ever reaches
   the box.

Stable stack:

```sh
docker compose -p evo-t1-coder-stack -f docker-compose.yml restart litellm
```

The dev sandbox takes the same restart with its own project name and env file:

```sh
docker compose -p evo-t1-dev --env-file dev-stack.env -f docker-compose.yml restart litellm
```

### Where an alias edit lands

- `scripts/coder-agents.sh` registers `agent` (default) and `chat` as the Coder Agents
  chat model configs, through `CODER_AGENTS_PROVIDER_URL`
  (default `http://litellm:4000/v1`).
- So an alias edited or deleted in `litellm/config.yaml` moves in the Agents model
  dropdowns exactly as it does in the CLI.

## Why this shape

### IPEX-LLM over vanilla Ollama

- The IPEX-LLM runtime is Intel's XPU path (oneAPI / Level Zero) for the Arc stack.
- `OLLAMA_NUM_GPU=999` offloads every layer to the 140T, and the iGPU pulls its weights
  straight out of the 96 GB DDR5.
- Vanilla Ollama on an Intel iGPU is effectively CPU-bound, and several times slower on a
  32B coder model.
- `runners=[ipex_llm]` in the ollama logs is that GPU backend confirming itself.

### MoE over dense

- `qwen2.5-coder:32b` is treated here as a Mixture-of-Experts model: 32B-class quality
  with far fewer active parameters per token.
- On a memory-rich but bandwidth- and latency-constrained iGPU that is the sweet spot,
  because an equivalent dense model would move every parameter per token and run much
  slower at the same footprint.

### The one-front-door rule

- Workspaces see a stable OpenAI-compatible URL and stable alias names.
- So you can flip `coder` from the local Arc to a Spark box, or add a new alias, and no
  workspace setting has to change.
