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
| `coder` | Arc, `qwen2.5-coder:32b` | **plain text** | chat about code, summarising diffs |
| `coder-fast` | Arc, `qwen2.5-coder:14b` | **plain text** | cheap and quick, same limit |
| `chat` | Arc, `qwen2.5:7b` | real `tool_calls` | agent work while the Sparks are down |

Notes that matter:

- `agent` is one model group across three Spark boxes: session-pinned, then
  least-busy. With none reachable LiteLLM falls it back to `coder` — which cannot
  drive an agent loop, because Qwen2.5-Coder returns tool calls as text.
- So the working degraded mode is `chat`, not the fallback. If the Sparks are
  unreachable, say so and offer `chat`.
- `coder` / `coder-fast` cap at 32k context; `agent` is much larger.

## Switching the model

```sh
hermes config get model.model
hermes config set model.model chat     # or: agent
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
- For web lookups there is no MCP server configured; query SearXNG directly:
  `curl -s "http://searxng:8181/search?q=…&format=json"`.
