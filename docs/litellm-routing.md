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
- Routing inside the `agent` group, the four unpinned lanes (`agent-swarm`,
  `agent-explore`, `agent-review`, `agent-swarm-fast`), and the `agent` to `coder`
  fallback
- What pulls a dead Spark box out of rotation, how it comes back on its own, and what
  the container's own healthcheck does not do
- The two fast-compaction lanes, and the proxy callback that moves one summary call of
  a session onto a cheaper tier
- Reading the routing back, and editing an alias safely

**What this enables**

- Moving a workload between the Arc iGPU and a Spark box without touching a workspace
- Diagnosing a wrong-backend answer from the routing rather than from the client

Deep reference for the model lane:

- the aliases in `litellm/config.yaml`
- how a request picks a backend
- what a pinned conversation does
- what happens when a Spark box goes down

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

#### The two top-level blocks

- `model_list:` is the alias list; `router_settings:` is the routing.
- `routing_strategy: least-busy` is the picker;
  `optional_pre_call_checks: ["session_affinity"]` is the pinning layer above it.

#### Fallbacks and the cooldown rule

- `fallbacks:` carries the degrade path `agent: ["coder"]`, repeated for each thinking
  alias, because those groups go down with exactly the same boxes. The four unpinned
  lanes and the two fast-compaction lanes hop one step further, through the lane that
  bakes their own level, so a lane that asked for `low` is not served an `xhigh` answer
  by its fallback.
- `cooldown_time: 60` is how long a box that tripped the rate rule sits out, and it is
  also the fail window that rule counts over.
- There is no `allowed_fails` key in the config, and the absence is deliberate: naming it
  with a non-default number selects the counting branch of the cooldown decision instead
  of the rate rule, and that branch counts inside a window of `cooldown_time`.
  - The `allowed_fails: 40` and `cooldown_time: 5` this replaced therefore asked for 41
    failures inside 5 s, which is why it never fired.
  - Without the key the vendor's rate rule decides when a box stops being a candidate; see
    [what `cooldown_time: 60` is for](#what-cooldown_time-60-is-for-now).

#### What the health sweep does

- `background_health_checks: true` and `enable_health_check_routing: true` do the
  re-probing and then make the result decide routing, so recovery does not wait for
  user traffic to rediscover it.
  - They sit beside `health_check_interval: 120`, `health_check_staleness_threshold: 900`
    and `health_check_concurrency: 2`.
  - Those keys have to sit in `general_settings:`; `health_check_interval` and
    `health_check_concurrency` under `router_settings:` make the proxy raise `ValueError`
    at boot.
  - The concurrency is deliberately small: a probe is a real generation that carries the
    lane's baked `reasoning_effort`, and on a box whose prompt cache sits full it evicts
    a warm conversation to fit itself. See the TensorFold log section of
    [troubleshooting.md](troubleshooting.md).
- `health_check_ignore_transient_errors: true` is load-bearing rather than tidy. A box
  that is merely busy can answer a 16-token probe with a 429 or a 408, and with the
  key on those endpoints are dropped before the state is written
  (`proxy_server.py:3971-3974`) and again before the cooldown loop takes them
  (`proxy_server.py:4002-4006`). Flipping it off would cost a session-pinned
  conversation its warm box and that box's prompt cache its next prefill, over one
  slow probe.
- The four Arc deployments - `coder`, `coder-fast`, `chat`, `compaction-fast` - carry
  `model_info.disable_background_health_check: true`, so the sweep drops them
  (`proxy_server.py:4116-4118`).
- A group's only deployment can never be pulled out by the health filter anyway - dropping
  it empties the candidate list, which is the `router.py:14177` fail-open - so the mark buys
  no routing, and it is not free: the same cycle cools what it marked
  (`proxy_server.py:4013`) and the cooldown list has no fail-open under this config, because
  the bypass at `router.py:12774` needs a policy the file refuses to set.
- `coder` is the terminal hop of every Spark lane, so a 401 or a 404 from a probe would park
  the fallback for `cooldown_time` with no user request having failed.
- Read the two functions in order and the family is exact: that pair clears
  `_is_cooldown_required` on its own named arms (`cooldown_handlers.py:239` and `:243`), and
  the arm at `:400-401` then cools it on the bare question of whether LiteLLM would retry
  the status, with no single-deployment guard -- `_should_retry` returns False for
  everything outside 408/409/429/5xx (`utils.py:6854-6880`).
- No other probe reply strands anything: 429 and 408 are skipped at the call site by
  `health_check_ignore_transient_errors` (`proxy_server.py:4001-4004`), any other 4xx is
  refused at `:248`, and a genuine 5xx clears the catch-all at `:252` only to fall through
  every base-case arm.
- That reading is the source's, not the harness's -- the arm which recorded
  `exception_status` 500 had the Arc unreachable, and `proxy_server.py:3999` derives the
  status with `getattr(original_exception,
  "status_code", 500)`, so a box answering no HTTP at all arrives pre-labelled retryable, and is
  vetoed at `:223-227` on its `APIConnectionError` text besides.
- The consequence that is measured, and which stands without the stranding argument: those
  four no longer appear in the cached `/health` report at all, and four of the 31 probes a
  cycle stop being paid.
- `health_check_staleness_threshold` has to be named because the shipped default does
  not follow the interval: it is `DEFAULT_HEALTH_CHECK_INTERVAL * 2`, 600 s whatever
  `health_check_interval` says (`router.py:993`), and it is the window the health filter
  trusts before it stops filtering. 900 s is what keeps a slow sweep from opening that
  window; see [how long it takes, and how it comes
  back](#how-long-it-takes-and-how-it-comes-back).

#### Retries and timeouts

- `num_retries: 2` covers a transient blip; moving off a busy box is routing's job, not
  the retry chain's. `request_timeout: 1200` is now the tightest deadline on the chain -
  the CLI's streaming idle allowance (`inference_idle_timeout_secs`) sits at 1800 s - so
  the proxy is the end that gives up first, at a full twenty minutes per attempt.
- `model_group_retry_policy:` gives the nine agent lanes their own `RetryPolicy`. The
  reason it exists is narrow enough to be worth its own section below.

### When a box answers `NoRoom`

#### Why the router sees a connection error

TensorFold on the Spark boxes refuses an over-admitted stream with the Zig error value
`NoRoom`, delivered as an HTTP 500 body.

The OpenAI SDK hands that to LiteLLM with no int
`status_code`, which at the pinned `v1.102.1` puts it on the status-less branch of
`exception_mapping_utils`, so the router sees `APIConnectionError`.

`RetryPolicy` in that tag has no `APIConnectionErrorRetries` field.

`DefaultRetries` is the only field that can reach the error,
which is why each agent lane declares one:

```yaml
model_group_retry_policy:
  # one block per Spark group: agent, agent-low, agent-medium, agent-xhigh,
  # agent-swarm, agent-explore, agent-review, agent-xhigh-fast, agent-swarm-fast
  agent:
    DefaultRetries: 2
    ...
```

#### What to read before changing the block

Read these three facts before changing the block:

- The nine Spark groups are independent and none inherits `agent`, so each needs its own
  six keys. The zeros pin the exceptions `DefaultRetries` would otherwise reach; at this
  tag `NotFoundError` has no field of its own, so without a policy a typo'd model id is
  retried on `DefaultRetries`.
- The policy is scoped to the Spark lanes. `coder` (Arc), `chat` and `compaction-fast`
  (the Arc group a summary hops to) keep the plain `num_retries` path.
- These retries are instant and stay on the same box. A status-less exception means
  `_deployment_ids_to_skip_on_retry` excludes nothing and `_time_to_sleep_before_retry`
  returns 0 while any deployment is healthy, and on the five pinned groups the
  workspace-wide `x-litellm-session-id` pin sends every subagent of a workspace to one
  box anyway. The block makes a refusal less likely to surface. Relocation comes from the
  box and the fan-out.
  - The four unpinned lanes - `agent-swarm`, `agent-explore`, `agent-review` and
    `agent-swarm-fast` - are the exception: with no pin to name a box, each of their
    retries is re-placed by `least-busy` and can land on another one.

#### The two levers that move load

The two levers that actually move load off a shedding box:

1. The box-side reclaim switch. The recipe measured the same refusal going from
   "2 of 5 streams refused" to "5 of 5 admitted" once patch 0029 is live with
   `TF_FLASHNEXT_ADMIT_RECLAIM=1`. `//scripts:spark-configure --apply` owns the per-host
   override file those settings belong in, and `//scripts:spark-verify` already fails a
   box whose `streams.max` drifts from the fleet's `PARALLEL`. Asserting the
   admit-reclaim setting itself is still open work: neither script names that key today.
2. Keep what one workspace puts on one box at or under that box's `PARALLEL` (5). A pinned
   lane sends the whole fan-out to the box its session key resolves to, so the width worth
   asking for there is 4: one box's streams, minus the parent's own request.
   - The unpinned `agent-swarm` lane is what the writers ride by default, and the one that
     can afford a wider wave - 15 subagents spread by `least-busy` over three boxes fill
     each box's `PARALLEL` exactly, which is the difference between buying wall-clock and
     buying queue depth.
   - That default asks every box for all of its streams, and it reserves nothing for the
     parent's own request the way the one-box width of 4 does. That is a deliberate trade
     rather than an oversight: the parent's conversation, the reader waves and the review
     pass all arrive on the same three boxes and share those `PARALLEL` streams, so at 15 a
     single busy workspace can have the fleet fully subscribed and the last arrivals wait.
   - What makes that survivable is `limit_behavior = "queue"` holding the overflow instead
     of failing the spawn, so the cost of overshoot is a subagent's latency.
   - That 15 is `grok_subagent_max_concurrent`'s own shipped default, the same on every lane
     whatever the operator picks there.
   - `grok_swarm_width` (3 boxes x `PARALLEL` 5) is the fleet's own ceiling, rendered as the
     `# fleet-width:` line beside `max_concurrent`, and the width a workspace gets only when
     it sets `grok_subagent_max_concurrent = null` on purpose. So an operator who shares the
     fleet shrinks it with two knobs, not one: `grok_swarm_width` moves the ceiling and
     `grok_subagent_max_concurrent` moves the width. Drop the first alone and the session
     still ships 15, and 15 streams over a 10-stream fleet is refused by the box with
     `NoRoom`.
   - The two reader lanes spread the same way, and each group counts its own in-flight
     requests, but the box's `PARALLEL` streams are one pool that every alias arriving on it
     shares. Past 15 across the fleet the boxes have no streams left to give, whatever the
     lane.
   - The same 15 is the budget of a whole tree, because `max_depth` (rendered from
     `grok_subagent_max_depth`, default 2, validated 1..3) lets a child spawn.
     - `reviewer`, `security-auditor` and `tester` name `spawn_subagent` in their `tools`,
       and every mapper such a child raises holds a stream the same way its parent does, so
       a parent sums the in-flight `1 + spawns` over every task and keeps that total at or
       below the fleet's stream count (`fleet:` in the plan, 15 by default,
       `templates/common/ez-micro-plan.plan_check.py:42`).
     - That checker refuses a wave whose cost passes the fleet, and the sum is a separate
       figure from the session cap `[subagents] max_concurrent` sets, because a grandchild
       opens its own session.
     - The box refuses an over-admitted stream the same way it refuses any other, with
       `NoRoom`.

#### Knobs that look right and do nothing

Two knobs that look right and do nothing here:

- `retry_after` is only a `min_timeout` and is never consulted while the group has healthy
  deployments.
- `fallbacks_by_model` does not exist in this tag (the proxy warns and ignores an unknown
  `router_settings` key, so a config that looks correct silently does nothing, which is why
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
| `agent-xhigh-fast` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent-xhigh`, as its own group; the same deployments, the same baked `xhigh`, the same session pin - this lane differs from its parent in one call of the conversation, which the proxy callback moves to `compaction-fast` | yes (same model and boxes as `agent`) |
| `agent-swarm-fast` | `Qwen3.8-Flash-Next` | the same three Spark boxes as `agent-swarm`, as its own group; baked `xhigh`, the same pin lift as `agent-swarm`, and the same summary hop to `compaction-fast` | yes (same model and boxes as `agent`) |
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) | no (measured) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama | no (measured) |
| `compaction-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama (Arc); the one deployment the two fast lanes' summary call hops to, and not a client choice - no `[model.*]` block and no `local.model_choices` entry names it | no (measured on these weights, as on `coder-fast`) |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama | yes (measured) |

### Reading the table

#### The Spark rows

- The `agent` row is ONE model group with three deployments, one per Spark box,
  all equal.
- The eight `agent-*` rows are that same lane with a thinking level baked into
  `litellm_params.reasoning_effort`. Qwen3.8-Flash-Next takes `low`, `medium` and `xhigh`
  and nothing else - there is no `high` - so the level is a name to pick rather than a knob
  to turn, and `agent-low` / `agent-medium` / `agent-xhigh` are how the level reaches Coder
  Agents: its model dropdown chooses an alias, not a request parameter.
- The `agent-explore` and `agent-review` rows are the same idea aimed at a fleet role rather
  than at a person in that dropdown - see
  [the fan-out lanes](#the-fan-out-lanes-agent-explore-and-agent-review).
- `agent` is not the unthinking default. It bakes `reasoning_effort: xhigh`, so a
  Coder Agents chat on the default alias thinks hard, and `agent-xhigh` asks the
  box for the same level by name. A `reasoning_effort` the client sends in the
  request still wins over the baked one.
- Those eight groups reuse the same `SPARK1/2/3_OPENAI_URL` / `SPARK_n_API_KEY` pairs as
  `agent`. They are separate model groups on the same hardware, not eight more boxes:
  routing state is per group, so least-busy's counters and the session pin are computed
  inside a group and two chats on different aliases can land on the same box at once.
- What does not change is the box - 5 full 262144-token streams in total, whichever aliases
  arrive on it. This is not the "two deployments on one box" mistake below, which is about a
  single group counting two URLs on one machine as two machines.
- The three rows after `agent-xhigh` differ from the four above them in routing state
  only: same model, same three boxes, the thinking level each row names, and no session
  pin. See
  [the swarm lane](#the-swarm-lane-agent-swarm) and
  [the fan-out lanes](#the-fan-out-lanes-agent-explore-and-agent-review).
- The two rows after those are not new lanes. `agent-xhigh-fast` is `agent-xhigh` and
  `agent-swarm-fast` is `agent-swarm`, deployment for deployment, and what differs is
  where one call of the conversation is answered - the CLI's summary request, which a
  proxy callback re-serves from `compaction-fast` on the Arc when the summary fits that
  window, and from a Spark group at thinking `low` when it does not. See
  [the fast-compaction lanes](#the-fast-compaction-lanes-agent-xhigh-fast-and-agent-swarm-fast).

#### The Arc summary row

- `compaction-fast` is that hop's small-summary target, and a row no template offers a client: no
  `reasoning_effort` line, no tool-calling flags, and `max_input_tokens: 32768` rather
  than the Spark rows' 262144, because a summary is prose and 32768 is the honest
  window of those weights.

#### What the backend has to match

- The Spark boxes serve TensorFold's OpenAI-compatible `/v1` and nothing else: Ollama
  runs on the Arc, so a Spark box never sees the Ollama protocol.
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
- `scripts/coder-agents.sh` registers `agent` (the default, with `chat` standing in when the
  Spark lane is dark), `agent-low`/`agent-medium`/`agent-xhigh`, `agent-swarm`, and `chat`
  as Coder Agents chat model configs, for the same reason: an agent turn without callable
  tools cannot browse or edit, so registering `coder` or `coder-fast` would only add a
  visibly broken model to the pickers.
- Nine Spark aliases drive tools, so nine could be registered; only the five above are - the
  thinking aliases are there to make the level selectable from that picker, while
  `agent-explore` and `agent-review` answer a parent's dispatch rather than a person at the
  dropdown, so registering them would add two names nobody types.
- The two fast-compaction lanes are absent for a mechanical reason of the same kind: the hop
  keys on the summary instruction the Grok CLI appends, and the aibridge behind this
  dropdown never sends one, so a chat on `agent-xhigh-fast` is a chat on `agent-xhigh`
  wearing a longer name.

## Routing inside the `agent` group

### One group, three deployments

- Three deployments, one per Spark box, and no `order:` tier. A tier would make the
  lower boxes unreachable while any tier-1 box stayed healthy.
- Spreading across every reachable box is the point of running three of them, five full
  262144-token streams each. Pinning only narrows the candidate list first.
- One endpoint per box, one box per endpoint. Never point two deployments, or two
  aliases, at the same physical machine: the proxy counts deployments, not machines.

### The picker: least-busy

- `least-busy` picks the deployment carrying the fewest in-flight requests out of a list
  that some filter already made healthy. It has no health input of its own, and that is
  the one thing to know before trusting it to spread load.
- Its counters are raised before the call (`router_strategy/least_busy.py:120`) and given
  back on the failure hook (`:129`, `:143`), so a box that refuses every request sits at
  zero -- and `_least_busy` (`:83`) returns the FIRST deployment at the minimum. A dead box
  listed first in a group is therefore the preferred target, not the avoided one:
  unfiltered, `least-busy` prefers it over a healthy box.
- What pulls it out is the health filter that runs ahead of the strategy, which is the whole
  subject of [when a Spark box goes down](#when-a-spark-box-goes-down-and-comes-back).
- Its counters are per deployment and expire after a hardcoded 3600 s; there is no
  `routing_strategy_args` block to set, and `ttl` there would be a paste from newer docs.
- It decides only for unpinned traffic: the affinity pin below resolves first, and
  `least-busy` runs when nothing is pinned, when the pinned deployment is unhealthy or in
  cooldown, and for any request with no session id. Every `agent-swarm`,
  `agent-explore`, `agent-review` and `agent-swarm-fast` request is unpinned traffic,
  which is the whole of those four lanes.
- Health checks, cooldowns and those counters all attribute per deployment through
  `model_info.id`, which is why each box carries a unique id: `agent-spark-1`,
  `agent-spark-2`, `agent-spark-3`.
- Each thinking group, the swarm group, the two fan-out groups and the two fast groups carry
  their own triple - `agent-low-spark-1/2/3`, `agent-medium-spark-1/2/3`,
  `agent-xhigh-spark-1/2/3`, `agent-swarm-spark-1/2/3`, `agent-explore-spark-1/2/3`,
  `agent-review-spark-1/2/3`, `agent-xhigh-fast-spark-1/2/3`, `agent-swarm-fast-spark-1/2/3`
  - so the same physical box is a separate deployment, with its own health state and its own
  in-flight counter, inside every group it belongs to.
- `compaction-fast` needs no triple: the Arc is one box and its single deployment is
  `compaction-fast-arc`.
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

#### Why this lane carries no pin

The fifth Spark group, and the first of the four that carry no pin. Same
`openai/Qwen3.8-Flash-Next` on the same three boxes, same baked `xhigh`, same tool-calling
flags and 262144 window - the
difference is routing state only, so no pin resolves and every request goes to the global
`least-busy` picker, landing on the healthy box with the fewest requests in flight.

#### The one key that lifts the pin

One key lifts the pin; apart from that key and the group's own deployment, retry-policy
and fallback entries, nothing in the config distinguishes it from the five pinned lanes:

```yaml
router_settings:
  model_group_affinity_config:
    agent-swarm: []
```

At the pinned `v1.102.1` tag that key is a real `Router.__init__` argument and is not in
`ROUTER_SETTINGS_MANAGED_OUTSIDE_CONFIG`, so `config.yaml` reaches it, and its valid flags
are exactly `deployment_affinity`, `responses_api_deployment_check`, `session_affinity`
and `encrypted_content_affinity`.

An entry REPLACES the global flag list for the group it names rather than adding to it, so
the empty list means no affinity check of any kind runs for `agent-swarm`. Every group
absent from the map keeps falling back to the global `["session_affinity"]`, which is why
the five lanes a conversation rides still pin exactly as they did. Setting the key also
self-arms the affinity callback, so those groups keep pinning.

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

#### Why a child does not need the pin

The sixth and seventh Spark groups, `agent-explore` and `agent-review`, lift the same pin
the swarm lane lifts, and for the same reason taken one step further: both serve a child
that answers once. The `explore` type and the seeded `explorer` agent dig for evidence and
return a digest; `reviewer` and `security-auditor` read what landed and return findings.

Neither carries a long warm prefix into a next turn, so the prefix-cache warmth the pin
protects is worth nothing here, while its cost is paid in full - the parent loop and every
child it spawns carry that workspace's one `x-litellm-session-id`, so a pinned wave of six
resolves to a single deployment and waits on that box's `PARALLEL` admission slots while
the other two boxes sit reachable and under-offered.

#### The review panel is a wave too

That check is a panel of three skeptics dispatched in one turn - the requirements angle,
the proof angle that re-runs the producers' own `done:` commands, and the adversary angle -
each riding `agent-review`, each owning no file, and each allowed up to three read-only
mappers of its own under `max_depth` 2.

Three spawners with three mappers each is twelve of
the fifteen streams the fleet owns, which fits beside a parent still holding its own
conversation, and the panel is cheap precisely because the writers have all landed by the
time it runs: the fleet is then idle, and both the skeptics and the mappers they spawn are
unpinned traffic that `least-busy` can place on all three boxes at once.

The baked level is the only thing that separates them. An explore child is a lookup, so it
takes `low` and answers fast; a review child is the check that a landed claim is actually
true, so it takes the `xhigh` `agent` itself carries. Each names itself with an empty flag
list beside the swarm lane's (`litellm/config.yaml:721-729`) and declares its own six-key
`model_group_retry_policy` block, because a group inherits nothing from its siblings.

#### What the lift costs

What the lift costs is what it costs the swarm lane, said plainly: a second turn of the
same conversation is not sticky, so it may be prefilled on a different box and pay prefill
again. For a child that answers once there is no second turn to pay for; point a
conversation at these aliases and there is.

A long single-thread chat, an orchestrator, or anything whose turns share a warm
prefix belongs on `agent`.

#### Rolling one lane back alone

Each reader lane is the default for its own role and is set by its own template
variable, so either rolls back alone without moving the other or the writers'
`agent-swarm` default:

| Lane | Role it carries | Default | `--var` that puts it back on a pinned lane |
|---|---|---|---|
| `agent-explore` | the built-in `explore` type and the seeded `explorer` | `agent-explore` | `--var grok_explore_lane=agent-low` keeps the level and the pin; `=agent` sends mapping work at full depth |
| `agent-review` | the seeded `reviewer` and `security-auditor`, which carry the independent review of a multi-file change | `agent-review` | `--var grok_review_lane=agent-xhigh` keeps the level and the pin; `=agent` matches the parent exactly |

#### Where the lane variables live

The variables are declared in `templates/workspace/coder.tf:24-52` and its devcontainer
twin, and they are what fills `[subagents.models]` in
`templates/workspace/grok-config.toml.tftpl`. The fan-out width rides a different variable
and does not follow any of these three: it is `grok_subagent_max_concurrent`'s own
shipped 15.

`main.tf` renders that through
`grok_subagent_max_concurrent = var.grok_subagent_max_concurrent != null ? var.grok_subagent_max_concurrent : var.grok_swarm_width`,
and the `: var.grok_swarm_width` arm of the ternary answers only a caller that passes null
on purpose - the quote is the opt-in, not the source of the width.

- `grok_swarm_width` (default 15) is the fleet's own ceiling, rendered as the
  `# fleet-width:` line beside `max_concurrent`.
- The lane decides placement, not width - what a pinned lane changes is where those 15
  land, and one box only ever admits `PARALLEL` (5) of them.
- The workspace side of that seam is
  [grok-build-and-agents.md](grok-build-and-agents.md#the-fan-out-seam).
- A contributor home names the same three lanes with `GROK_EXPLORE_LANE`, `GROK_PLAN_LANE`
  and `GROK_REVIEW_LANE` for `//scripts:seed-dev-env`.
- Neither lane is registered as a Coder Agents chat model, so a pin is the only way onto
  either one.

### The fast-compaction lanes: `agent-xhigh-fast` and `agent-swarm-fast`

The eighth and ninth Spark groups, and the only two that ask the proxy to answer one of
their calls somewhere else.

Everything else about each is its parent: `agent-xhigh-fast` is
`agent-xhigh` - three equal `openai/Qwen3.8-Flash-Next` deployments, `xhigh` baked, the
session pin kept - and `agent-swarm-fast` is `agent-swarm`, the same three boxes with the
pin lifted for it alone among the new lanes.

The nine Spark lane groups are now
`agent agent-low agent-medium agent-xhigh agent-swarm agent-explore agent-review
agent-xhigh-fast agent-swarm-fast`, plus the Arc group `compaction-fast`.

#### What the hop is

What the hop is: on those two aliases only, the proxy recognises the CLI's
conversation-summary call and re-serves it from somewhere cheaper than the Spark box it
arrived on - `compaction-fast`, the small Ollama-served coding weight on the Arc, when the
summary fits that window, and a Spark group thinking at `low` when it does not.

That is where the speed comes from - the Spark lane answers at xhigh thinking and a
summary does not need it.

The CLI appends its summary instruction as the last turn of the body - the
auto-compaction ask, or the `/compact` one wrapped in a `<summary_request>` tag - and the
callback matches a stable clause inside whichever one it sees,
`produce a faithful, concise summary of the conversation so far` and
`summarize the conversation so far`, in a turn short enough to be the instruction itself.

It reads that ask nowhere else in the body: the system prompt rides every turn of the
session, so matching there would move a whole conversation to the summary target the moment
an operator pasted one of those sentences into a workspace rulebook.

It reads it from whichever key the protocol carries the turns under - `messages` for
Chat Completions and Anthropic Messages, `input` for a model whose `api_backend` is
`responses` - so the hop does not quietly stop working on a protocol choice.

A recognized ask is
rewritten to the target model, with `tools`, `tool_choice` and `reasoning_effort` dropped
from it: a summary is prose, the schemas are dead weight to it, and a small model handed a
tool schema may answer with a call instead of a summary.

Every other call of the same conversation stays on its Spark box, and a session on any
other alias compacts exactly as it always has.

The hop is a property of the alias, not of the proxy: picking one of these
two aliases is the opt-in, and `EVO_T1_FAST_COMPACTION=0` is the kill switch beside it.

One residue is worth naming: a user turn whose entire content is a quoted ask looks like an ask,
and gets the summary target's answer.

#### It is not a client setting

What it is not: a client setting. The Grok Build CLI has no compaction-model key, so
there is nothing in `~/.grok/config.toml` that points that call anywhere, and
`[models] session_summary` is not the compaction lane either - it serves titles and the
session recap.

The whole remedy therefore lives server-side, and the measurement behind it
is the `compact failed: exceeded wall-clock budget 300s` section of
[troubleshooting.md](troubleshooting.md).

#### Why the extra config is worth it

Why the extra config is worth it: compactions that did succeed on the Spark lane took 107 s
to 1915 s, and 18 of the 36 sampled successes ran past the CLI's 300 s wall-clock budget -
they are the summaries that budget was discarding.

What the hop changes without a stopwatch
is who answers: a 14B Arc weight with no thinking level and no schemas in the prompt, rather
than a Spark box thinking at xhigh over the same request with its tool schemas attached.

No timing has been measured on the hop yet, so no speed-up figure is quoted here for either
tier; `docs/troubleshooting.md` names the one log line that shows it firing, and that line
is where a measurement starts.

#### Which tier answers, and what caps the guard

Which tier answers: the guard is `EVO_T1_FAST_COMPACTION_INPUT_LIMIT` (default 24000), and
it picks a tier rather than ending the hop.

Below it the summary goes to `compaction-fast`,
which is the right place for it, because those weights answer inside a 32768-token window
and Ollama clamps an over-long input instead of refusing it - a summary pushed in over that
comes back quietly truncated, and a truncated summary is worse than the slower one it would replace.

That window is also the ceiling the guard cannot raise past: the fork happens at the
smaller of `EVO_T1_FAST_COMPACTION_INPUT_LIMIT` and the `max_input_tokens` `config.yaml`
declares for the Arc target group, so `EVO_T1_FAST_COMPACTION_INPUT_LIMIT=100000` forks at
32768 and logs one `compaction router: EVO_T1_FAST_COMPACTION_INPUT_LIMIT=100000 is above
the 32768 tokens config.yaml declares for 'compaction-fast'; forking at the declared window
instead` line.

The declared window is a fact about the weights and the pinned LiteLLM has no
context-window check between the hook and Ollama, so a knob cannot reach past it; a target
group that declares no window leaves the guard whole, and prints one
`compaction router: 'compaction-fast' declares no max_input_tokens in config.yaml; forking at
EVO_T1_FAST_COMPACTION_INPUT_LIMIT alone` line rather than failing quietly.

#### The Spark tier and the token estimate

Above it the summary goes to `EVO_T1_FAST_COMPACTION_SPARK_TARGET` (default
`agent-low`): the same three Spark boxes, the 262144-token window a real summary needs, and
the thinking baked to `low` instead of `xhigh`.

Blank that knob, or name the lane the call
arrived on, and an oversized summary stays where it is, which is the pre-hop behaviour.

The estimate is counted over everything the backend prefills - each turn's text, the
payloads the text flattener cannot see, and every request-level schema key - and it
charges three classes of character separately:

- ASCII prose at four characters to a token
- a base64 payload at two
- anything outside ASCII at one

Reading those denser classes at the prose rate was
how a 90,000-character screenshot read as 22,500 tokens and went to a 32768-token model.

Every one of them errs toward the larger number, and the larger number means the Spark tier.

#### Where the guard sits against the client

Where the guard sits against the client: the shipped `[session]` block sets
`auto_compact_threshold_percent = 70` and both fast aliases declare a `context_window` of
262144 (`templates/workspace/grok-config.toml.tftpl:387`, and `:284` and `:301` for the two
aliases), so a session on either one reaches its auto-compaction at about 183,500 tokens -
over seven times the guard.

A summary that size cannot be read faithfully by a 32768-token
model, so the Arc tier was never going to serve it and the guard is what stops it trying: on
that estimate the call goes to `agent-low`, which keeps the window and drops the baked
`xhigh` thinking.

Pointing `EVO_T1_FAST_COMPACTION_TARGET` at `agent-low` is the lever that
covers a full-size summary even with the limit left alone, and it is a routing choice with
its own trade, not a free win: the summary is still a Spark call, holding a stream on a box
the writers want, at a thinking level turned down from the one the lane exists to bake.

#### The fallback on the Spark tier

The known limit on that tier is its fallback, and it is the stack's standing one: every
Spark group's last resort is the Arc, so `agent-low: ["coder"]`
(`litellm/config.yaml:862`, and the same shape under `agent-xhigh-fast: ["agent-xhigh",
"coder"]` and `agent-swarm-fast: ["agent-swarm", "coder"]`) means that when all three Sparks
are cooled an oversized summary lands on `coder` - a 32768-token group - and is answered
from a truncated reading, which is the outcome the fork exists to prevent.

Nothing here makes that worse: the pair's own chains end at `coder` too, and so does
`compaction-fast: ["agent-low", "coder"]`. The fork changes who tries first.

What an operator holds is the choice of who tries second: blank
`EVO_T1_FAST_COMPACTION_SPARK_TARGET` to leave the summary on the lane it arrived on,
point it at another Spark group, or edit the fallback list beside it in the same routing
file.

When the Sparks are unreachable the answer is the
one every agent lane already has - the working degraded mode is `chat`.

#### What has been measured so far

What has been measured is the old path, not the new one. The 107 s to 1915 s spread and
the 18 abandoned successes above are both from the Spark lane before the hop existed,
swept out of the session logs in [troubleshooting.md](troubleshooting.md).

Neither tier has a timing of its own yet: the hop has not served a summary on a running
stack, so no speed-up figure is claimed for either one.

`tests/python/test_compaction_router.py` proves which group each
request shape lands on; the operator's own log line is what will prove what it costs.

#### The five knobs

Everything a caller can tune is one of five environment variables, read in
`litellm/compaction_router.py` and nowhere else, which makes the litellm service's
`environment:` block in `docker-compose.yml` the whole policy:

| Knob | Default | What flipping it does |
|---|---|---|
| `EVO_T1_FAST_COMPACTION` | on; `0`, `false`, `off` disable it | the kill switch - off, every call of every lane stays where its alias routes it |
| `EVO_T1_FAST_COMPACTION_LANES` | `agent-xhigh-fast,agent-swarm-fast` | which groups may hop; name one to narrow the hop to it |
| `EVO_T1_FAST_COMPACTION_TARGET` | `compaction-fast` | the model group a summary under the guard is moved to; a name that is no `model_name:` in `config.yaml` is refused and the call stays put |
| `EVO_T1_FAST_COMPACTION_INPUT_LIMIT` | `24000` | the token estimate that decides which of the two tiers takes the call; a ceiling this module may lower and never raise, because the Arc target group's own `max_input_tokens` caps it and logs one line when it does |
| `EVO_T1_FAST_COMPACTION_SPARK_TARGET` | `agent-low` | where a summary above the guard goes, checked against `config.yaml` the same way; blank it, or name the lane it arrived on, and it stays there |

#### Three ways to land it and get nothing

Three ways to land this feature and get nothing.

The first is caught for you at the pinned
LiteLLM and the other two are silent, which is why the silent two are what the gates check:

- `litellm_settings.callbacks` must name the *instance*,
  `compaction_router.proxy_handler_instance`, never the class. `ProxyLogging` dispatches
  `async_pre_call_hook` only to a callback that IS a `CustomLogger` and overrides that hook
  in its own class dict.
  - At the pinned `v1.102.1` a class entry fails loudly:
    `litellm/proxy/common_utils/callback_utils.py` maps it to a `ValueError` that names
    `proxy_handler_instance` and the config does not load.
  - That check is recent, so the older wording you may find in a comment - a class boots
    clean, the lanes keep working, the hop never fires - describes what it used to do.
- The module is mounted as a single file,
  `./litellm/compaction_router.py:/app/compaction_router.py:ro`. A directory mount over
  `/app` hides `config.yaml` beside it, and it has to sit in the same directory as the
  config file because that is the directory the proxy resolves a callback's dotted name
  against - the bare module name in
  `callbacks` resolves no other way.
- A new group inherits neither the retry policy nor the affinity lift. Both fast lanes
  declare their own six-key `model_group_retry_policy` block, and only `agent-swarm-fast`
  joins `model_group_affinity_config` with `[]`; `agent-xhigh-fast` is absent from that map
  on purpose, so it keeps falling back to the global `["session_affinity"]` and stays
  pinned like its parent. That one key is the whole difference between the pinned twin and
  the spread one.

### What carries a session id

A value has to look like an id to count: alphanumerics, hyphens or underscores, 8
characters or more.

The sources, in order, are `x-litellm-trace-id`, then
`x-litellm-session-id`, then any `x-<vendor>-session-id`, then
`session-id`/`session_id`/`thread-id`/`conversation_id` (Codex style), then W3C
traceparent and baggage, plus `metadata.session_id` in the body.

- The Grok CLI forwards `extra_headers` verbatim.
- Both workspace templates render `x-litellm-session-id = "ws-<workspace-uuid>"` under
  `[models]` in `~/.grok/config.toml`, so one key covers every conversation of a
  workspace, subagent calls included.
- In `shared` profile mode that is one file per workspace, re-rendered on that workspace's own
  start, so two workspaces of one owner can carry different renders of that key.

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

## When a Spark box goes down and comes back

### What actually removes it

The health filter does, and it is the only mechanism that can.

Selection on the chat-completion path runs `async_get_available_deployment` (`router.py:13041`) ->
`async_get_healthy_deployments` (`router.py:12700`) ->
`_async_filter_health_check_unhealthy_deployments` (`router.py:14137`), and that last
call is a no-op unless `enable_health_check_routing` is set in `general_settings:`
(`router.py:14153`).

That is the key the config turns on for exactly this job.

Cooldown cannot do it, and that is not a tuning question. `_is_cooldown_required`
returns False as soon as the exception text contains `APIConnectionError`
(`litellm/router_utils/cooldown_handlers.py:223`, `ignored_strings`).

A refused connection, a dead engine, and a TensorFold `NoRoom` refusal all surface as
that exception, so the failure that most needs a box pulled is the one the cooldown path
is written to skip.

The probe loop writes the health state (`proxy_server.py:3981`)
*before* that veto can reach the same exception: the write sits behind the guard at
`proxy_server.py:3965` and above the routing-only bail at `proxy_server.py:3988-3989`,
so the mark is there whether or not the cooldown loop below it ever runs, which is why
the filter marks what cooldown never marks.

Three settings switch the filter off, and the config avoids all three:

- `enable_health_check_routing` off
- `health_check_interval` unset or <= 0, which returns from the probe loop before it ever
  starts (`proxy_server.py:4071`)
- a router-wide `allowed_fails_policy` with `background_health_check_model_groups` unset
  (`router.py:14161`)

That last one is why `router_settings:` carries no
`allowed_fails_policy` anywhere, and why one added there for an unrelated reason would
quietly disable the filter that keeps a dead box out of `least-busy`.

### What `cooldown_time: 60` is for now

With `allowed_fails` gone, cooldown uses the vendor's rate rule
(`cooldown_handlers.py:392-398`), guarded at `:395`: cool a deployment once it fails
more than `DEFAULT_FAILURE_THRESHOLD_PERCENT` (0.5, `constants.py:69`) of at least
`DEFAULT_FAILURE_THRESHOLD_MINIMUM_REQUESTS` (5, `constants.py:131`) requests in a rolling minute.

The counting branch is the `else` one line below at `:404-405`,
reached only when a router-wide policy is set or `allowed_fails` carries a
non-default number (`:363-366`), and this file names neither.

`SINGLE_DEPLOYMENT_TRAFFIC_FAILURE_THRESHOLD` is 1000, so the "all
requests failed" arm never fires at this fleet's volume.

That is the rule doing what cooldown was always the right tool for: a box that answers
badly - a 500, a timeout, a malformed completion - is parked for `cooldown_time`, 60 s,
and comes back on its own. The same 60 s is the period the probe loop cools a deployment
its previous cycle marked unhealthy (`proxy_server.py:4013`,
`time_to_cooldown=router.cooldown_time`, `:4018`); with routing on, that path runs now,
where it used to return early.

That 60 s is not confined to the probe path.

Both paths read the one `cooldown_time`
knob, so raising it off the 5 s default (`constants.py:75`) widens every group's
exclusion, the three-deployment Spark groups included: a box that fails 3 of 5
requests in a minute now sits out for a minute
instead of 5 s, and a minute without one of three boxes moves a session pin that was
warm there.

### How long it takes, and how it comes back

Detection is one sweep plus the interval, not the interval alone: the probe loop sleeps
`health_check_interval` *after* a sweep finishes (`proxy_server.py:4234`) rather than
firing on a clock.

A sweep is the 27 deployments that did not opt out pushed through
the `health_check_concurrency: 2` gate - the sweep drops every deployment carrying
`model_info.disable_background_health_check` (`proxy_server.py:4116-4118`), which is
four of the 31 - so the wait before a box is re-probed is one full sweep plus 120 s.

Recovery needs no operator and no restart.

A green probe overwrites the mark with
`is_healthy: True` (`health_check.py:683`), so a box is eligible again on the first
probe that succeeds after it comes back - no request has to fail first to rediscover it.

That is eligible, not proven serving: the same loop cooled what it marked
(`proxy_server.py:4013`), and that cooldown entry has to expire on its own clock, so
the first turn back can still land on another box.

The bound on that state is `health_check_staleness_threshold: 900`, and the filter fails
open: it returns the whole candidate list:

- when the health state is missing
- when it is older than that threshold
- when filtering would leave no candidate at all So a fleet whose probe state has gone
  stale routes to every box rather than to none - a stale sweep costs the filter, never
  the traffic.

The threshold is set explicitly because the
shipped default is `DEFAULT_HEALTH_CHECK_INTERVAL * 2` = 600 s whatever
`health_check_interval` says (`router.py:993`); left at the default it would not track
the 120 s interval this config asks for.

A restart of the proxy is itself a fail-open condition, and it is not logged.

No Redis is configured for this proxy, so the marks live in one process
(`router_utils/health_state_cache.py:32-36`) and every restart or redeploy clears
them until the first sweep finishes; the filter has no log line on any of its
fail-open exits, so nothing proves that window happened while it is open.

### What the filter does not cover

The filter sits on the chat-completion selection path.

The image, audio, embedding and rerank paths select through
`_async_get_healthy_deployments` (`router.py:8554`), which applies the cooldown filter
and the blocked flag only - a dead box stays a candidate there.

This fleet serves chat and streaming completions, so the limit is honest rather
than load-bearing, but it is the reason a new modality on these aliases needs its own
look before anyone calls it covered.

What covers a request already in flight is unchanged by this work and predates it:

- the two attempts the retry chain allows (`num_retries: 2` in `litellm_settings`, and
  `DefaultRetries: 2` inside each Spark lane's `model_group_retry_policy` block)
- the rest of that per-group policy
- the `fallbacks` chains

The filter changes where a retry lands, not whether the turn is retried.

### The container's own probe

The `litellm:` service in `docker-compose.yml` carries a `healthcheck:` block beside
these router settings, and it is a different check on a different thing: it asks whether
the proxy process answers, not whether a Spark box does.

Its `test:` is the JSON-array form invoking the image's own `/app/.venv/bin/python3` -
the image ships no `curl` and no `wget` - at a one-line `urllib` request to
`http://127.0.0.1:4000/health/liveliness` with `timeout=5`, exiting 0 only on a 200,
with `interval: 30s`, `timeout: 10s`, `retries: 3`, and `start_period: 60s` to cover the
boot that imports the config and builds 31 deployments before uvicorn binds.

`/health/liveliness` is the endpoint because it is unprotected and answers `I'm alive!`,
while `/health` sits behind `user_api_key_auth`
(`health_endpoints/_health_endpoints.py:1938` and `:1110`) and a probe on
it would need the master key in the container's own command line.

What it does not do: the compose daemon restarts a container that *exits*, not one that
goes unhealthy.

`restart: unless-stopped` stays the only thing that recovers a crashed
proxy, and this probe buys visibility instead - `dev-stack status` and
`docker compose ps` print (unhealthy), `docker inspect` carries the last three probes,
and the log tag ships the event to Loki.

It also buys a `service_healthy` wait that
nothing here takes: `hermes` keeps `depends_on: litellm: condition: service_started`
deliberately, because compose waits indefinitely for a healthy condition and a probe that
stopped passing would hold the host assistant down with the proxy.

## Fallback: the Spark lanes to `coder`

- When every Spark box is down, `router_settings.fallbacks` degrades `agent` straight to
  `coder`, which is text-only.
- Chat stays usable while agent mode quietly loses its tools. That is the point of the
  hop, not an accident.
- Each thinking alias carries the same hop of its own - `agent-low: ["coder"]`, and the
  same for `agent-medium` and `agent-xhigh`. Groups are independent, so none of them
  inherits `agent`'s entry, and the five pinned lanes go down with the same boxes.

### The per-lane fallback chains

- `agent-swarm` degrades one step further: `agent-swarm: ["agent", "coder"]`. Health
  state, cooldowns and in-flight counters are per group, so its own three deployments can
  all be cooled while the same boxes are still healthy under `agent`; `agent` is tried
  first, where `least-busy` may still have a box to pick, and Arc `coder` stays the last
  resort it is for every other Spark lane. The chain is acyclic: agent-swarm -> agent ->
  coder, and `coder` declares no hop of its own.
- The two fan-out lanes degrade the way the swarm lane does, one step further than the
  pinned lanes, and each hops through the lane that bakes its own level:
  - `agent-explore: ["agent-low", "coder"]` and `agent-review: ["agent-xhigh", "coder"]`
    (`litellm/config.yaml:882-883`).
  - The extra step is worth taking for the same reason - these groups' own three
    deployments can all be cooling while the same boxes are healthy under the pinned alias,
    since health state and cooldowns are kept per group - and the hop is chosen so a parent
    that dispatched an explore child at `low` gets a `low` answer from the fallback rather
    than an `xhigh` it did not ask for.
  - Both chains are acyclic and end at `coder`: agent-explore -> agent-low -> coder,
    agent-review -> agent-xhigh -> coder, and neither fallback lane names a lane that hops
    back here.
- Each fast lane hops to the lane it is the twin of:
  `- agent-xhigh-fast: ["agent-xhigh", "coder"]` and
  `- agent-swarm-fast: ["agent-swarm", "coder"]`
  (`litellm/config.yaml:887-888`). Same boxes, same baked level, same pin behaviour, so a
  session that lost its own group keeps everything except that group's routing state. Both
  chains are acyclic and end at `coder` like every other here: agent-xhigh-fast ->
  agent-xhigh -> coder, agent-swarm-fast -> agent-swarm -> coder.
- `compaction-fast` degrades to a Spark rather than to another Arc alias -
  `- compaction-fast: ["agent-low", "coder"]`
  (`litellm/config.yaml:893`) - and that direction is the point.
  - `coder`, `coder-fast` and `compaction-fast` all answer from the one Ollama container
    on the Arc, so a hop between them is a hop to whatever is already down. `agent-low` is
    the quickest answer the fleet has, which is what a summary was after on this lane in
    the first place.
  - Acyclic: compaction-fast -> agent-low -> coder. It is the one chain here that a user
    never picks: it belongs to the group the callback moves traffic to, not to an alias
    anyone types.

### History, caps, and what is deliberately absent

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

### Restart the proxy first

Order matters when an alias is new rather than changed: the proxy reads
`litellm/config.yaml` at boot and a workspace renders its catalog from that file when it
starts, so restart the proxy first and boot the workspace after it.

A workspace older than the proxy asks for an alias the config does not have, and the
router answers "No deployments available" rather than falling back.

The rollback is one variable per lane, and
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

- `scripts/coder-agents.sh` registers `agent` (the default, with `chat` standing in when
  the Spark lane is dark), `agent-low`/`agent-medium`/`agent-xhigh`, `agent-swarm`, and
  `chat` as the Coder Agents chat model configs, through `CODER_AGENTS_PROVIDER_URL`
  (default `http://litellm:4000/v1`). `agent-swarm` is registerable but is never picked
  for an auxiliary lane pin: the control-plane chat agent is one conversation, and one
  conversation wants the pin.
- The two fan-out lanes are absent from that list on purpose. `agent-explore` and
  `agent-review` exist to be pinned by `[subagents.models]`, not chosen from a picker, so
  editing them moves a fleet role's traffic and leaves the Agents dropdowns alone.
- The two fast-compaction lanes are absent for a mechanical reason of the same kind: the
  hop keys on the summary instruction the Grok CLI appends, and the aibridge behind those
  dropdowns never sends one, so an Agents chat on `agent-xhigh-fast` is a chat on
  `agent-xhigh` under a longer name. They are a CLI and a workspace-form choice instead.
- A new alias is a client catalog entry as well as a proxy entry. Both
  `templates/*/main.tf` twins carry one `{value, name, description}` object per alias in
  `local.model_choices`, which is what the workspace create form offers for
  `grok_default_model`, and both `templates/*/grok-config.toml.tftpl` twins carry its
  `[model."<alias>"]` block. An alias the config has and the twins do not is an alias no
  workspace ever lists.
- The editor roster is the third copy of the name. `__evoT1StackModels` in both
  `templates/*/settings.json.tftpl` twins is the alias list Cline and Roo/Kilo are
  offered, and that seed is copied onto the per-owner `vscode-settings-<owner-id>` volume
  only while the file is absent - a roster that gains an id never reaches an owner whose
  `settings.json` already exists, so re-seeding means deleting that volume's file.
- A routing hook adds two artifacts beyond the alias itself.
  `litellm/compaction_router.py` is a payload file beside the config, bind-mounted
  single-file as `./litellm/compaction_router.py:/app/compaction_router.py:ro` - never a
  directory mount over `/app`, which would hide `config.yaml` - and it is live only while
  `litellm_settings.callbacks` names `compaction_router.proxy_handler_instance`, the
  instance rather than the class.
- Both of those live in `docker-compose.yml` and `litellm/config.yaml` respectively, so
  they restart differently: `restart litellm` re-reads the config file, while a new mount
  and the five `EVO_T1_FAST_COMPACTION*` keys need the container recreated with the same
  compose invocation and `up -d litellm`.
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
