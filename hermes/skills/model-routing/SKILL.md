---
name: model-routing
description: Pick the right LiteLLM model alias for the task and switch the Hermes model without touching secrets.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [evo-t1, litellm, models, routing]
---

# model-routing

Use when the operator asks which model to use, why a model behaves oddly, or how
to switch the assistant's model.

## One door

LiteLLM is the sole model transport: `http://litellm:4000/v1`, authenticated with
`LITELLM_MASTER_KEY`. Hermes already points there. Everything below is an alias
behind that one base URL — never bypass it.

## Aliases

| Alias | Runs on | Tool calls | Use for |
| --- | --- | --- | --- |
| `agent` | Spark boxes, TensorFold `/v1` (3 deployments) | real `tool_calls` | the default; anything that runs tools |
| `agent-low` | same 3 Spark boxes, own group, effort baked to `low` | real `tool_calls` | an explicit low thinking level |
| `agent-medium` | same 3 Spark boxes, own group, effort baked to `medium` | real `tool_calls` | an explicit medium thinking level |
| `agent-xhigh` | same 3 Spark boxes, own group, effort baked to `xhigh` | real `tool_calls` | an explicit xhigh level — what `agent` already bakes |
| `agent-swarm` | same 3 Spark boxes, own group, effort baked to `xhigh`, no session pin | real `tool_calls` | a fan-out that should spread over all three boxes at once |
| `agent-xhigh-fast` | same 3 Spark boxes, own group, effort baked to `xhigh` | real `tool_calls` | not this session: a Grok Build thread on xhigh whose summary the proxy answers on the Arc |
| `agent-swarm-fast` | same 3 Spark boxes, own group, effort baked to `xhigh`, no session pin | real `tool_calls` | not this session: a Grok Build fan-out whose summary the proxy answers on the Arc |
| `agent-explore` | same 3 Spark boxes, own group, effort baked to `low`, no session pin | real `tool_calls` | not this session: the read-only mapper lane of a Grok Build fleet |
| `agent-review` | same 3 Spark boxes, own group, effort baked to `xhigh`, no session pin | real `tool_calls` | not this session: the independent-review lane of a Grok Build fleet |
| `coder` | Arc, `qwen2.5-coder:32b` | **plain text** | chat about code, summarising diffs |
| `coder-fast` | Arc, `qwen2.5-coder:14b` | **plain text** | cheap and quick, same limit |
| `chat` | Arc, `qwen2.5:7b` | real `tool_calls` | agent work while the Sparks are down |
| `compaction-fast` | Arc, `qwen2.5-coder:14b` | **plain text** | not this session: the group the two fast lanes hand their summary to |

Notes that matter:

- `agent` is one model group across three Spark boxes: session-pinned, then
  least-busy. With none reachable LiteLLM falls it back to `coder` — which cannot
  drive an agent loop, because Qwen2.5-Coder returns tool calls as text.
- So the working degraded mode is `chat`, not the fallback. If the Sparks are
  unreachable, say so and offer `chat`.
- The `agent-*` rows are thinking variants of `agent`: same model, same boxes, same
  tool calling, with the level baked into the alias. `agent` itself already bakes
  `xhigh`, so reach for one only when the operator asks for a specific level.
  Qwen3.8-Flash-Next takes `low`, `medium` and `xhigh` — there is no `high`.
- Those groups are independent: least-busy and the session pin are computed per
  group, so a chat on `agent-medium` can sit on the same box as one on `agent`. The
  box still serves 5 streams in total, which is why nothing here gets a cap.
- `agent-swarm` is the same model on the same three boxes, `xhigh` baked: only its
  routing state differs. It is one of the four groups the session pin does not cover (the
  other three are its fast twin below and the two fleet lanes), so every request goes to
  least-busy and lands on whichever healthy box has the fewest requests in flight.
- That is why a fan-out uses it and a long thread does not: independent parallel
  work reaches all 15 streams (5 on each of the three boxes), where a pinned
  session only ever reaches the 5 streams of the one box it was pinned to. The
  price is stickiness — the next turn may prefill on a different box — so a single
  long conversation stays on `agent`, which keeps the pin.
- Its degradation hop differs as well: `agent-swarm` falls back to `agent` and only
  then to `coder`, where each sibling Spark lane hops straight to `coder`. Health
  state is per group, so the swarm's own three deployments can all be cooled while
  the same boxes stay healthy under `agent`. The working degraded mode is still
  `chat`, for the same reason as above.
- The two `*-fast` rows are each the lane it is named after: `agent-xhigh-fast` is
  `agent-xhigh` and `agent-swarm-fast` is `agent-swarm` - same three boxes, same baked
  `xhigh`, and each keeps the pin its parent has. The one thing either adds is what
  happens to the conversation summary. When a session on one of those two aliases sends the Grok CLI's
  summary request - either of the two asks the CLI appends, read in the turn that asks and
  never in the rulebook that rides every turn - the LiteLLM proxy re-targets that one call to `compaction-fast` before
  the router picks a Spark box: the Arc's `qwen2.5-coder:14b`, the same weights
  `coder-fast` serves, held as its own group so a summary shares no routing state with that
  alias. Every other call of that conversation still runs on a Spark at `xhigh`.
- There is nothing to set beside it: the Grok CLI has no compaction-model setting, so
  picking one of those two aliases is the whole opt-in. A session on `agent`, `agent-xhigh`
  or `agent-swarm` compacts on its own Spark exactly as it always has.
- The hop has one guard, and it picks a tier. The Arc weights are a 32768-token model, so a
  summary whose estimated input is over `EVO_T1_FAST_COMPACTION_INPUT_LIMIT` (default 24000,
  kept under that window on purpose) goes to `agent-low` - a Spark group, so
  it keeps the 262144-token window a full-size summary needs, at thinking baked `low` rather
  than `xhigh` - instead of being truncated to fit the Arc. A slow summary beats a summary of
  half the conversation. Blank `EVO_T1_FAST_COMPACTION_SPARK_TARGET` and an oversized summary
  stays where it arrived, at the lane's own thinking level.
- Their degradation hops follow their parents, and the target carries its own:
  `agent-xhigh-fast` -> `agent-xhigh` -> `coder`, `agent-swarm-fast` -> `agent-swarm` ->
  `coder`, and `compaction-fast` -> `agent-low` -> `coder`. That last chain is deliberate:
  `coder`, `coder-fast` and `chat` all sit on the Arc box this group already shares, so a
  hop to one of them is a hop to whatever is already down, and `agent-low` is the quickest
  answer the fleet has.
- The two fan-out rows above are for a Grok Build fleet, not for this session: Hermes
  itself stays on `agent`, because a chat is one long conversation and that is exactly what
  the pin is for. Each serves a child that answers once, so there is no warm prefix for a
  pin to protect and the lift costs nothing here. The reader gets `low`, because mapping
  work is a lookup it returns as a digest; the skeptic gets `xhigh`, the level `agent`
  itself carries, because it is the check that what landed is actually true and it opens
  the files it judges rather than trusting the diff it was handed. Their degradation hop
  differs from the swarm's as well: each hops through the lane that bakes its own level
  before Arc (`agent-explore` -> `agent-low` -> `coder`, `agent-review` -> `agent-xhigh` ->
  `coder`), so a fleet that dispatched a reader at `low` gets a `low` answer back.
- `coder` / `coder-fast` cap at 32k context; `agent` is much larger.

## Switching the model

```sh
hermes config get model.model
hermes config set model.model chat     # or: agent, agent-medium, agent-swarm
```

Never write a key into `config.yaml` — `api_key` stays `${LITELLM_MASTER_KEY}`,
expanded from the environment.

## Do not

- Do not add rpm/tpm caps anywhere. No per-deployment limits — routing policy is
  `litellm/config.yaml` and nothing else.
- Do not call Ollama on `:11434` from here. It is unpublished on the Arc on
  purpose; LiteLLM reaches it over the compose network.
- Do not hand-edit `litellm/config.yaml` from this container to fix a model: that
  file is bind-mounted from the checkout, so edit it in git and recreate the
  `litellm` service.
- For a web lookup use the `web_search` tool: the seed pins `web.search_backend`
  to `searxng` and turns both keyless switches off, so the query goes to this
  stack's own instance and nowhere else. `web_extract` is left unconfigured on
  purpose, so a page fetch fails on the box rather than dialing an extractor.
  To see exactly what the instance returns, ask it directly:
  `curl -s "http://searxng:8181/search?q=<terms>&format=json"`. Do not add a vendor
  key or a `web.backend` for a third party to make an extract work - that is the
  operator's call, and it has a privacy cost worth naming first.
