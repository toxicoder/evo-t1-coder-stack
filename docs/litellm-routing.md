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
- Routing inside the `agent` group, the three unpinned lanes (`agent-swarm`,
  `agent-explore`, `agent-review`), and the `agent` to `coder` fallback
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
  alias, because those groups go down with exactly the same boxes. The three unpinned
  lanes hop one step further, through the pinned alias that bakes their own level, so a
  lane that asked for `low` is not served an `xhigh` answer by its fallback.
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
- `model_group_retry_policy:` gives the seven agent lanes their own `RetryPolicy`. The
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
  agent:            # repeated for agent-low, agent-medium, agent-xhigh, agent-swarm,
                    # agent-explore and agent-review
    DefaultRetries: 2
    ...
```

Read these three facts before changing the block:

- The seven Spark groups are independent and none inherits `agent`, so each needs its own
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
  box and the fan-out. The three unpinned lanes - `agent-swarm`, `agent-explore` and
  `agent-review` - are the exception: with no pin to name a box, each of their retries is
  re-placed by `least-busy` and can land on another one.

The two levers that actually move load off a shedding box:

1. The box-side reclaim switch. The recipe measured the same refusal going from
   "2 of 5 streams refused" to "5 of 5 admitted" once patch 0029 is live with
   `TF_FLASHNEXT_ADMIT_RECLAIM=1`. `//scripts:spark-configure --apply` owns the per-host
   override file those settings belong in, and `//scripts:spark-verify` already fails a
   box whose `streams.max` drifts from the fleet's `PARALLEL`. Asserting the
   admit-reclaim setting itself is still open work: neither script names that key today.
2. Keep what one workspace puts on one box at or under that box's `PARALLEL` (5). A
   pinned lane sends the whole fan-out to the box its session key resolves to, so the
   width worth asking for there is 4: one box's streams, minus the parent's own request.
   The unpinned `agent-swarm` lane is what the writers ride by default, and the one that
   can afford a wider wave - 15 subagents spread by `least-busy` over three boxes fill each
   box's `PARALLEL` exactly, which is the
   difference between buying wall-clock and buying queue depth. That default asks every box
   for all of its streams, and it reserves nothing for the parent's own request the way
   the one-box width of 4 does. That is a deliberate trade rather than an
   oversight: the parent's conversation, the reader waves and the review pass all arrive
   on the same three boxes and share those `PARALLEL` streams, so at 15 a single busy
   workspace can have the fleet fully subscribed and the last arrivals wait. What makes
   that survivable is `limit_behavior = "queue"` holding the overflow instead of failing
   the spawn, so the cost of overshoot is a subagent's latency. That 15 is
   `grok_swarm_width` (3 boxes x `PARALLEL` 5), the default on every lane whatever the
   operator picks there; drop it when several workspaces share the fleet, or set
   `grok_subagent_max_concurrent` to hold a width outright. The
   two reader lanes
   spread the same way, and each group counts its own in-flight requests, but the box's
   `PARALLEL` streams are one pool that every alias arriving on it shares.
   Past 15 across the fleet the boxes have no
   streams left to give, whatever the lane.
   The same 15 is the budget of a whole tree, because `max_depth` (rendered from
   `grok_subagent_max_depth`, default 2, validated 1..3) lets a child spawn. `reviewer`,
   `security-auditor` and `tester` name `spawn_subagent` in their `tools`, and every mapper
   such a child raises holds a stream the same way its parent does, so a parent sums the
   in-flight `1 + spawns` over every task and keeps that total at or below the fleet's
   stream count (`fleet:` in the plan, 15 by default,
   `templates/common/ez-micro-plan.plan_check.py:42`). That checker refuses a wave whose
   cost passes the fleet, and the sum is a separate figure from the session cap
   `[subagents] max_concurrent` sets, because a grandchild opens its own session. The box
   refuses an over-admitted stream the same way it refuses any other, with `NoRoom`.

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
| `agent-swarm` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `xhigh`, and the first group with no session pin, so each request is placed on the least-busy healthy box; the default `grok_subagents_lane`, so the writer types fan out here | yes (same model and boxes as `agent`) |
| `agent-explore` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `low`, and no pin here either, so a wave of one-shot read-only children is placed across the fleet rather than queueing behind one box; the default `grok_explore_lane` | yes (same model and boxes as `agent`) |
| `agent-review` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent`, as its own group; thinking baked to `xhigh` like `agent`, and the same pin lift as `agent-explore`, so a wave of reviewers spreads the same way; the default `grok_review_lane` | yes (same model and boxes as `agent`) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) | unverified |

### Reading the table

- The `agent` row is ONE model group with three deployments, one per Spark box,
  all equal.
- The six `agent-*` rows are that same lane with a thinking level baked into
  `litellm_params.reasoning_effort`. Qwen3.8-Flash-Next takes `low`, `medium` and
  `xhigh` and nothing else - there is no `high` - so the level is a name to pick
  rather than a knob to turn, and `agent-low` / `agent-medium` / `agent-xhigh` are
  how the level reaches Coder Agents: its model dropdown chooses an alias, not a
  request parameter. The last two rows are the same idea aimed at a fleet role rather
  than at a person in that dropdown - see
  [the fan-out lanes](#the-fan-out-lanes-agent-explore-and-agent-review).
- `agent` is not the unthinking default. It bakes `reasoning_effort: xhigh`, so a
  Coder Agents chat on the default alias thinks hard, and `agent-xhigh` asks the
  box for the same level by name. A `reasoning_effort` the client sends in the
  request still wins over the baked one.
- Those six groups reuse the same `SPARK1/2/3_OPENAI_URL` / `SPARK_n_API_KEY`
  pairs as `agent`. They are separate model groups on the same hardware, not six
  more boxes: routing state is per group, so least-busy's counters and the session
  pin are computed inside a group and two chats on different aliases can land on the
  same box at once. What does not change is the box - 5 full 262144-token streams in
  total, whichever aliases arrive on it. This is not the "two deployments on one
  box" mistake below, which is about a single group counting two URLs on one machine
  as two machines.
- The three rows after `agent-xhigh` differ from the four above them in routing state
  only: same model, same three boxes, the thinking level each row names, and no session
  pin. See
  [the swarm lane](#the-swarm-lane-agent-swarm) and
  [the fan-out lanes](#the-fan-out-lanes-agent-explore-and-agent-review).
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
  the pickers. Seven Spark aliases drive tools, so seven could be registered; only the
  five above are - the thinking aliases are there to make the level selectable from that
  picker, while `agent-explore` and `agent-review` answer a parent's dispatch rather than
  a person at the dropdown, so registering them would add two names nobody types.

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
  cooldown, and for any request with no session id. Every `agent-swarm`,
  `agent-explore` and `agent-review` request is unpinned traffic, which is the whole of
  those three lanes.
- Health checks, cooldowns and those counters all attribute per deployment through
  `model_info.id`, which is why each box carries a unique id: `agent-spark-1`,
  `agent-spark-2`, `agent-spark-3`. Each thinking group, the swarm group and the two
  fan-out groups carry their own triple - `agent-low-spark-1/2/3`,
  `agent-medium-spark-1/2/3`,
  `agent-xhigh-spark-1/2/3`, `agent-swarm-spark-1/2/3`,
  `agent-explore-spark-1/2/3`, `agent-review-spark-1/2/3` - so the same physical box is a
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

The fifth Spark group, and the first of the three that carry no pin. Same
`openai/Qwen3.8-Flash-Next` on the same three boxes, same baked `xhigh`, same tool-calling
flags and 262144 window - the
difference is routing state only, so no pin resolves and every request goes to the global
`least-busy` picker, landing on the healthy box with the fewest requests in flight.

One key lifts the pin; apart from that key and the group's own deployment, retry-policy
and fallback entries, nothing in the config distinguishes it from the four pinned lanes:

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

- It has no pin, and that is what makes it the wrong home for a long single-thread
  conversation. Pinning buys prefix-cache locality; without it the next turn may be
  prefilled on a different box and pay prefill again. A chat, an orchestrator, or
  anything whose turns share a warm prefix belongs on `agent`. The lane is for
  independent parallel work - subagents, batch edits, one-shot jobs, which is also why
  the two reader lanes below lift the pin the same way.
- The spread is bought by removing a pin, not by adding a proxy queue or a cap. There is
  still no `rpm`, `tpm` or `max_parallel_requests` anywhere in the config, and
  `queue_class`, `queue_class_config` and `enable_queue` do not exist at this tag. A
  saturated box keeps shedding load in its own scheduler; the proxy parks nothing behind
  an in-memory semaphore.

That is the arithmetic the lane exists for: 3 boxes x `PARALLEL` 5 full-length streams is
15 concurrent streams, and a pinned workspace only ever reaches the 5 of the one box its
key resolves to.

### The fan-out lanes: `agent-explore` and `agent-review`

The sixth and seventh Spark groups, `agent-explore` and `agent-review`, lift the same pin
the swarm lane lifts, and for the same reason taken one step further: both serve a child
that answers once. The `explore` type and the seeded `explorer` agent dig for evidence and
return a digest; `reviewer` and `security-auditor` read what landed and return findings.
Neither carries a long warm prefix into a next turn, so the prefix-cache warmth the pin
protects is worth nothing here, while its cost is paid in full - the parent loop and every
child it spawns carry that workspace's one `x-litellm-session-id`, so a pinned wave of six
resolves to a single deployment and waits on that box's `PARALLEL` admission slots while
the other two boxes sit reachable and under-offered.

That check is a panel of three skeptics dispatched in one turn - the requirements angle,
the proof angle that re-runs the producers' own `done:` commands, and the adversary angle -
each riding `agent-review`, each owning no file, and each allowed up to three read-only
mappers of its own under `max_depth` 2. Three spawners with three mappers each is twelve of
the fifteen streams the fleet owns, which fits beside a parent still holding its own
conversation, and the panel is cheap precisely because the writers have all landed by the
time it runs: the fleet is then idle, and both the skeptics and the mappers they spawn are
unpinned traffic that `least-busy` can place on all three boxes at once.

The baked level is the only thing that separates them. An explore child is a lookup, so it
takes `low` and answers fast; a review child is the check that a landed claim is actually
true, so it takes the `xhigh` `agent` itself carries. Each names itself with an empty flag
list beside the swarm lane's (`litellm/config.yaml:583-586`) and declares its own six-key
`model_group_retry_policy` block, because a group inherits nothing from its siblings.

What the lift costs is what it costs the swarm lane, said plainly: a second turn of the
same conversation is not sticky, so it may be prefilled on a different box and pay prefill
again. For a child that answers once there is no second turn to pay for; point a
conversation at these aliases and there is. A long single-thread chat, an orchestrator, or
anything whose turns share a warm prefix belongs on `agent`.

Each reader lane is the default for its own role and is set by its own template
variable, so either rolls back alone without moving the other or the writers'
`agent-swarm` default:

| Lane | Role it carries | Default | `--var` that puts it back on a pinned lane |
|---|---|---|---|
| `agent-explore` | the built-in `explore` type and the seeded `explorer` | `agent-explore` | `--var grok_explore_lane=agent-low` keeps the level and the pin; `=agent` sends mapping work at full depth |
| `agent-review` | the seeded `reviewer` and `security-auditor`, which carry the independent review of a multi-file change | `agent-review` | `--var grok_review_lane=agent-xhigh` keeps the level and the pin; `=agent` matches the parent exactly |

The variables are declared in `templates/workspace/coder.tf:24-52` and its devcontainer
twin, and they are what fills `[subagents.models]` in
`templates/workspace/grok-config.toml.tftpl`. The fan-out width rides a different variable
and does not follow any of these three: `grok_swarm_width` (default 15) is the width on
every lane, and `main.tf` renders it as exactly
`grok_subagent_max_concurrent = var.grok_subagent_max_concurrent != null ? var.grok_subagent_max_concurrent : var.grok_swarm_width`.
The lane decides placement, not width - what a pinned lane changes is where those 15 land,
and one box only ever admits `PARALLEL` (5) of them. The workspace side of that seam is
[grok-build-and-agents.md](grok-build-and-agents.md#the-fan-out-seam). A contributor home
names the same three lanes with `GROK_EXPLORE_LANE`, `GROK_PLAN_LANE` and
`GROK_REVIEW_LANE` for `//scripts:seed-dev-env`. Neither lane is registered as a Coder
Agents chat model, so a pin is the only way onto either one.

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
- The two fan-out lanes degrade the way the swarm lane does, one step further than the
  pinned lanes, and each hops through the lane that bakes its own level:
  `agent-explore: ["agent-low", "coder"]` and `agent-review: ["agent-xhigh", "coder"]`
  (`litellm/config.yaml:722-723`). The extra step is worth taking for the same reason -
  these groups' own three deployments can all be cooling while the same boxes are healthy
  under the pinned alias, since health state and cooldowns are kept per group - and the
  hop is chosen so a parent that dispatched an explore child at `low` gets a `low` answer
  from the fallback rather than an `xhigh` it did not ask for. Both chains are acyclic and
  end at `coder`: agent-explore -> agent-low -> coder, agent-review -> agent-xhigh ->
  coder, and neither fallback lane names a lane that hops back here.
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

Order matters when an alias is new rather than changed: the proxy reads
`litellm/config.yaml` at boot and a workspace renders its catalog from that file when it
starts, so restart the proxy first and boot the workspace after it. A workspace older than
the proxy asks for an alias the config does not have, and the router answers "No
deployments available" rather than falling back. The rollback is one variable per lane, and
it does not need the proxy at all: `--var grok_subagents_lane=agent` re-pins the writers to
one box, and `--var grok_explore_lane=agent-low` and `--var grok_review_lane=agent` put each
reader role back on a pinned alias that every config version already carries.

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
- The two fan-out lanes are absent from that list on purpose. `agent-explore` and
  `agent-review` exist to be pinned by `[subagents.models]`, not chosen from a picker, so
  editing them moves a fleet role's traffic and leaves the Agents dropdowns alone.
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
