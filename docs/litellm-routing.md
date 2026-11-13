---
title: LiteLLM model routing
description: "The model lane: the aliases in `litellm/config.yaml`, how a request picks a backend, and what happens when a Spark box goes down."
tags: [litellm, models, routing, spark]
---

# LiteLLM model routing

**What's on this page**

- The one front door every client dials, and why nothing else is published
- The alias table, and which backend each alias resolves to
- Tool calls: the measured limitation and the path that supports them
- Thinking levels: what `agent` bakes, and what the baked aliases change
- Routing inside the `agent` group, the unpinned `agent-swarm` lane, and the `agent` to
  `coder` fallback
- Reading the routing back, and editing an alias safely

**What this enables**

- Moving a workload between the Arc iGPU and a Spark box without touching a workspace
- Diagnosing a wrong-backend answer from the routing rather than from the client

Deep reference for the model lane: the aliases in `litellm/config.yaml`, how a request
picks a backend, what a pinned conversation does, and what happens when a Spark box goes
down.

Short version lives in [README.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/README.md) ("LiteLLM model aliases"); this file is
the long version behind it. Symptom-first checks live in
[troubleshooting.md](troubleshooting.md).

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
- `fallbacks:` carries the degrade path `agent: ["coder"]`, repeated for each thinking
  alias, because those groups go down with exactly the same boxes.
- `allowed_fails: 40` and `cooldown_time: 5` decide when a box stops being a candidate.
- `background_health_checks: true`, with `health_check_interval: 300` and
  `health_check_concurrency: 2`, re-probe a box on their own, so recovery does not
  wait for user traffic to rediscover it. Those two keys have to sit in
  `general_settings:`; under `router_settings:` the proxy raises `ValueError` at boot.
  The interval is LiteLLM's own default and the concurrency is deliberately small:
  a probe is a real generation that carries the lane's baked `reasoning_effort`, and
  on a box whose prompt cache sits full it evicts a warm conversation to fit itself.
  See the TensorFold log section of [troubleshooting.md](troubleshooting.md).
- `num_retries: 2` covers a transient blip; moving off a busy box is routing's job, not
  the retry chain's. `request_timeout: 1200` is now the tightest deadline on the chain -
  the CLI's streaming idle allowance (`inference_idle_timeout_secs`) sits at 1800 s - so
  the proxy is the end that gives up first, at a full twenty minutes per attempt.
- `model_group_retry_policy:` gives the five agent lanes their own `RetryPolicy`. The
  reason it exists is narrow enough to be worth its own section below.

### When a box answers `NoRoom`

TensorFold on the Spark boxes refuses an over-admitted stream with the Zig error value
`NoRoom`, delivered as an HTTP 500 body. The OpenAI SDK hands that to LiteLLM with no
int `status_code`, which at the pinned `v1.102.1` puts it on the status-less branch of
`exception_mapping_utils`, so the router sees `APIConnectionError`.

`RetryPolicy` in that tag has no `APIConnectionErrorRetries` field. `DefaultRetries` is
the only field that can reach the error, which is why each agent lane declares one:

```yaml
model_group_retry_policy:
  agent:            # repeated for agent-low, agent-medium, agent-xhigh, agent-swarm
    DefaultRetries: 2
    ...
```

Read these three facts before changing the block:

- The five Spark groups are independent and none inherits `agent`, so each needs its own
  six keys. The zeros pin the exceptions `DefaultRetries` would otherwise reach; at this
  tag `NotFoundError` has no field of its own, so without a policy a typo'd model id is
  retried on `DefaultRetries`.
- The policy is scoped to the Spark lanes. `coder` (Arc) and `chat` keep the plain
  `num_retries` path.
- These retries are instant and stay on the same box. A status-less exception means
  `_deployment_ids_to_skip_on_retry` excludes nothing and `_time_to_sleep_before_retry`
  returns 0 while any deployment is healthy, and on the four pinned groups the
  workspace-wide `x-litellm-session-id` pin sends every subagent of a workspace to one
  box anyway. The block makes a refusal less likely to surface. Relocation comes from the
  box and the fan-out. `agent-swarm` is the exception: it has no pin, so its retry is
  re-placed by `least-busy` and can land on another box.

The two levers that actually move load off a shedding box:

1. The box-side reclaim switch. The recipe measured the same refusal going from
   "2 of 5 streams refused" to "5 of 5 admitted" once patch 0029 is live with
   `TF_FLASHNEXT_ADMIT_RECLAIM=1`. `//scripts:spark-configure --apply` owns the per-host
   override file those settings belong in, and `//scripts:spark-verify` already fails a
   box whose `streams.max` drifts from the fleet's `PARALLEL`. Asserting the
   admit-reclaim setting itself is still open work: neither script names that key today.
2. Keep in-flight fan-out at or under a box's `PARALLEL` (5) per workspace. The
   orchestrator cap of 4 is inside that budget.

Two knobs that look right and do nothing here: `retry_after` is only a `min_timeout` and
is never consulted while the group has healthy deployments, and `fallbacks_by_model`
does not exist in this tag (the proxy warns and ignores an unknown `router_settings`
key, so a config that looks correct silently does nothing, which is why
`//tests:bats_litellm_config_test` rejects it by name).

## The alias table

| Alias | Model | Backend | Structured tool calls |
|---|---|---|---|
| `agent` | `Qwen3.8-Flash-Next` | `SPARK1/2/3_OPENAI_URL` (TensorFold on :8888 - one deployment per Spark box, optional) | yes (measured) |
| `agent-low` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `low` | yes (same model and boxes as `agent`) |
| `agent-medium` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `medium` | yes (same model and boxes as `agent`) |
| `agent-xhigh` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `xhigh` | yes (same model and boxes as `agent`) |
| `agent-swarm` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `xhigh`, and the only group with no session pin, so each request is placed on the least-busy healthy box | yes (same model and boxes as `agent`) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |

### Reading the table

- The `agent` row is ONE model group with three deployments, one per Spark box,
  all equal.
- The three `agent-*` rows are that same lane with a thinking level baked into
  `litellm_params.reasoning_effort`. Qwen3.8-Flash-Next takes `low`, `medium` and
  `xhigh` and nothing else - there is no `high` - so the level is a name to pick
  rather than a knob to turn, and `agent-low` / `agent-medium` / `agent-xhigh` are
  how the level reaches Coder Agents: its model dropdown chooses an alias, not a
  request parameter.
- `agent` is not the unthinking default. It bakes `reasoning_effort: xhigh`, so a
  Coder Agents chat on the default alias thinks hard, and `agent-xhigh` asks the
  box for the same level by name. A `reasoning_effort` the client sends in the
  request still wins over the baked one.
- Those four groups reuse the same `SPARK1/2/3_OPENAI_URL` / `SPARK_n_API_KEY`
  pairs as `agent`. They are separate model groups on the same hardware, not four
  more boxes: routing state is per group, so least-busy's counters and the session
  pin are computed inside a group and two chats on different aliases can land on the
  same box at once. What does not change is the box - 5 full 262144-token streams in
  total, whichever aliases arrive on it. This is not the "two deployments on one
  box" mistake below, which is about a single group counting two URLs on one machine
  as two machines.
- `agent-swarm` differs from the four rows above in routing state only: same model,
  same three boxes, same baked `xhigh`, and no session pin. See
  [the swarm lane](#the-swarm-lane-agent-swarm).
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
- `scripts/coder-agents.sh` registers `agent` (the default, with `chat` standing in when the Spark lane is dark),
  `agent-low`/`agent-medium`/`agent-xhigh`, `agent-swarm`, and `chat` as Coder Agents chat
  model configs, for the same reason: an agent turn without callable tools cannot browse or
  edit, so registering `coder` or `coder-fast` would only add a visibly broken model to
  the pickers. The five Spark aliases all drive tools, so all five are registerable - the
  thinking aliases are there to make the level selectable from that picker.

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
  cooldown, and for any request with no session id. Every `agent-swarm` request is
  unpinned traffic, which is the whole of that lane.
- Health checks, cooldowns and those counters all attribute per deployment through
  `model_info.id`, which is why each box carries a unique id: `agent-spark-1`,
  `agent-spark-2`, `agent-spark-3`. Each thinking group and the swarm group has its own
  triple - `agent-low-spark-1/2/3`, `agent-medium-spark-1/2/3`,
  `agent-xhigh-spark-1/2/3`, `agent-swarm-spark-1/2/3` - so the same physical box is a
  separate deployment, with its own health state and its own in-flight counter, inside
  every group it belongs to.
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

### The swarm lane: `agent-swarm`

The fifth Spark group, and the only one with no pin. Same `openai/Qwen3.8-Flash-Next` on
the same three boxes, same baked `xhigh`, same tool-calling flags and 262144 window - the
difference is routing state only, so no pin resolves and every request goes to the global
`least-busy` picker, landing on the healthy box with the fewest requests in flight.

One key lifts the pin, and apart from the group's three deployment entries it is the only
thing in the config that differs:

```yaml
router_settings:
  model_group_affinity_config:
    agent-swarm: []
```

At the pinned `v1.102.1` tag that key is a real `Router.__init__` argument and is not in
`ROUTER_SETTINGS_MANAGED_OUTSIDE_CONFIG`, so `config.yaml` reaches it, and its valid flags
are exactly `deployment_affinity`, `responses_api_deployment_check`, `session_affinity`
and `encrypted_content_affinity`. An entry REPLACES the global flag list for the group it
names rather than adding to it, so the empty list means no affinity check of any kind runs
for `agent-swarm`. Every group absent from the map keeps falling back to the global
`["session_affinity"]`, which is why the four lanes a conversation rides still pin exactly
as they did. Setting the key also self-arms the affinity callback, so those groups keep
pinning.

This key is the opt-out; a client header is not. An empty or short `x-litellm-session-id`
does not skip the pin at this tag - that header is read verbatim at any length, and only
the generic `x-<vendor>-session-id` family is shape-checked - so a caller that tried to
spread by sending an empty value would collapse every swarm request onto one shared pin.

Two facts not to get wrong:

- It is the ONLY unpinned group, which makes it the wrong home for a long single-thread
  conversation. Pinning buys prefix-cache locality; without it the next turn may be
  prefilled on a different box and pay prefill again. A chat, an orchestrator, or
  anything whose turns share a warm prefix belongs on `agent`. The lane is for
  independent parallel work - subagents, batch edits, one-shot jobs.
- The spread is bought by removing a pin, not by adding a proxy queue or a cap. There is
  still no `rpm`, `tpm` or `max_parallel_requests` anywhere in the config, and
  `queue_class`, `queue_class_config` and `enable_queue` do not exist at this tag. A
  saturated box keeps shedding load in its own scheduler; the proxy parks nothing behind
  an in-memory semaphore.

That is the arithmetic the lane exists for: 3 boxes x `PARALLEL` 5 full-length streams is
15 concurrent streams, and a pinned workspace only ever reaches the 5 of the one box its
key resolves to.

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

## Fallback: the Spark lanes to `coder`

- When every Spark box is down, `router_settings.fallbacks` degrades `agent` straight to
  `coder`, which is text-only.
- Chat stays usable while agent mode quietly loses its tools. That is the point of the
  hop, not an accident.
- Each thinking alias carries the same hop of its own - `agent-low: ["coder"]`, and the
  same for `agent-medium` and `agent-xhigh`. Groups are independent, so none of them
  inherits `agent`'s entry, and the four pinned lanes go down with the same boxes.
- `agent-swarm` degrades one step further: `agent-swarm: ["agent", "coder"]`. Health
  state, cooldowns and in-flight counters are per group, so its own three deployments can
  all be cooled while the same boxes are still healthy under `agent`; `agent` is tried
  first, where `least-busy` may still have a box to pick, and Arc `coder` stays the last
  resort it is for every other Spark lane. The chain is acyclic: agent-swarm -> agent ->
  coder, and `coder` declares no hop of its own.
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
  `.env`, and compose builds both from the box's `SPARKn_HOST` plus `SPARK_HTTP_PORT`,
  so a card follows the hostname you set once and they answer without a key.

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

Neither stack runner has a `restart` subcommand (`up`, `down`, `status`, `logs`, `reset`
are the whole set), so the proxy restart stays a direct compose call. Stable stack:

```sh
docker compose -p evo-t1-coder-stack -f docker-compose.yml restart litellm
```

The dev sandbox takes the same restart with its own project name and env file:

```sh
docker compose -p evo-t1-dev --env-file dev-stack.env -f docker-compose.yml restart litellm
```

### Where an alias edit lands

- `scripts/coder-agents.sh` registers `agent` (the default, with `chat` standing in when the Spark lane is dark),
  `agent-low`/`agent-medium`/`agent-xhigh`, `agent-swarm`, and `chat` as the Coder Agents
  chat model configs, through `CODER_AGENTS_PROVIDER_URL`
  (default `http://litellm:4000/v1`). `agent-swarm` is registerable but is never picked
  for an auxiliary lane pin: the control-plane chat agent is one conversation, and one
  conversation wants the pin.
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
