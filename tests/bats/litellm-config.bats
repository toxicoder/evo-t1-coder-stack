#!/usr/bin/env bats
#
# ## litellm-config.bats — guardrails for the `agent`-lane routing contract.
#
# Pins the seams the session-affinity feature rests on: the proxy config
# (session_affinity armed on top of the least-busy picker, no concurrency
# caps, the agent -> coder fallback, three unique per-box deployment ids)
# and the workspace-side header seam — both grok-config.toml.tftpl twins
# render the x-litellm-session-id header and both main.tf twins feed
# workspace_affinity_key into the templatefile call, so the pin cannot die
# silently by one side drifting.
#
# It also pins the thinking contract: `agent` bakes reasoning_effort xhigh, and
# the baked aliases agent-low / agent-medium / agent-xhigh are each their own
# group of three Spark deployments carrying that one effort, the same tool-calling
# flags, and their own hop to coder. Qwen3.8-Flash-Next takes no other effort.
#
# Usage: bazelisk test //tests:bats_litellm_config_test   (from any cwd)
# Safety: reads litellm/config.yaml and the two template dirs; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CONFIG=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CONFIG="${REPO_ROOT}/litellm/config.yaml"
  [[ -f "${CONFIG}" ]] || skip "litellm/config.yaml is not reachable from ${REPO_ROOT}"
}

# Print the model_list entries of one alias — from its `- model_name: <alias>`
# line up to the next entry or the first top-level key. Group-scoped assertions
# need this: a file-wide grep for `reasoning_effort: xhigh` cannot tell `agent`
# from `agent-xhigh`, and both have to carry it.
entries_for() {
  awk -v want="$1" '
    /^[[:space:]]*-[[:space:]]+model_name:/ {
      cur = $0
      sub(/^[[:space:]]*-[[:space:]]+model_name:[[:space:]]*/, "", cur)
      sub(/[[:space:]]*$/, "", cur)
      keep = (cur == want)
    }
    /^[^[:space:]#]/ { keep = 0 }
    keep { print }
  ' "${CONFIG}"
}

@test "routing: least-busy stays the picker and session_affinity stays armed" {
  run grep -F 'routing_strategy: least-busy' "${CONFIG}"
  [ "${status}" -eq 0 ]
  run grep -F 'optional_pre_call_checks: ["session_affinity"]' "${CONFIG}"
  [ "${status}" -eq 0 ]
}

@test "routing: no rpm/tpm/concurrency caps or strategy args were reintroduced" {
  # The cap chain (rpm -> max_parallel_requests) parks requests behind an
  # in-memory semaphore; least-busy's counter TTL is hardcoded, so a
  # routing_strategy_args block here is a paste from newer docs.
  run grep -Eq '^[[:space:]]*(rpm|tpm|max_parallel_requests):' "${CONFIG}"
  [ "${status}" -ne 0 ]
  run grep -Eq '^[[:space:]]*routing_strategy_args:' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "routing: agent degrades to coder through one acyclic hop" {
  run grep -Eq '^[[:space:]]*fallbacks:' "${CONFIG}"
  [ "${status}" -eq 0 ]
  run grep -F -- '- agent: ["coder"]' "${CONFIG}"
  [ "${status}" -eq 0 ]
}

@test "routing: the agent group keeps one deployment per box with unique ids" {
  # Health checks, cooldowns and the least-busy counters attribute per
  # deployment via model_info.id; duplicated ids blend the boxes together.
  total="$(grep -Ec '^[[:space:]]+id: agent-spark-[0-9]+' "${CONFIG}")"
  unique="$(grep -Eo 'id: agent-spark-[0-9]+' "${CONFIG}" | sort -u | grep -c '.' | tr -d ' ')"
  [[ "${total}" -eq 3 && "${unique}" -eq 3 ]]
}

@test "thinking: the default agent group bakes xhigh" {
  # Coder Agents and the CLI default to `agent`, so the hard thinking level has to
  # live in litellm_params; a client that sends its own reasoning_effort still wins.
  body="$(entries_for agent)"
  deps="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]*-[[:space:]]+model_name: agent$')"
  params="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+litellm_params:$')"
  efforts="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+reasoning_effort: xhigh$')"
  [[ "${deps}" -eq 3 && "${params}" -eq 3 && "${efforts}" -eq 3 ]] || {
    echo "agent: ${deps} entries, ${params} nested litellm_params, ${efforts} xhigh" >&2
    return 1
  }
}

@test "thinking: each baked alias is three boxes with its own effort and unique ids" {
  for level in low medium xhigh; do
    body="$(entries_for "agent-${level}")"
    deps="$(printf '%s\n' "${body}" | grep -Ec "^[[:space:]]*-[[:space:]]+model_name: agent-${level}$")"
    # Nested litellm_params per entry: a flat key is accepted as an extra and then
    # silently ignored, or hard-indexed and the proxy exits 3.
    params="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+litellm_params:$')"
    efforts="$(printf '%s\n' "${body}" | grep -Ec "^[[:space:]]+reasoning_effort: ${level}$")"
    # Same three boxes as `agent`, addressed by the same env pairs.
    bases="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+api_base: os.environ/SPARK[123]_OPENAI_URL$')"
    keys="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+api_key: os.environ/SPARK_[123]_API_KEY$')"
    # Same tool-calling flags and window as `agent`: 3 entries x 3 keys.
    flags="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+(supports_function_calling|supports_tool_choice|max_input_tokens): ')"
    ids="$(printf '%s\n' "${body}" | grep -Eo "id: agent-${level}-spark-[0-9]+" | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
    unique="$(printf '%s\n' "${body}" | grep -Eo "id: agent-${level}-spark-[0-9]+" | sort -u | grep -c '.' | tr -d ' ')"
    [[ "${deps}" -eq 3 ]] || { echo "agent-${level}: ${deps} deployments" >&2; return 1; }
    [[ "${params}" -eq 3 ]] || { echo "agent-${level}: ${params} nested litellm_params" >&2; return 1; }
    [[ "${efforts}" -eq 3 ]] || { echo "agent-${level}: ${efforts} lines bake ${level}" >&2; return 1; }
    [[ "${bases}" -eq 3 && "${keys}" -eq 3 ]] || { echo "agent-${level}: not the same three boxes (${bases} urls, ${keys} keys)" >&2; return 1; }
    [[ "${flags}" -eq 9 ]] || { echo "agent-${level}: ${flags} tool-calling/window flags, expected 9" >&2; return 1; }
    [[ "${unique}" -eq 3 ]] || { echo "agent-${level}: ids are ${ids}" >&2; return 1; }
    expected="id: agent-${level}-spark-1 id: agent-${level}-spark-2 id: agent-${level}-spark-3"
    [[ "${ids}" == "${expected}" ]] || { echo "agent-${level}: ids are ${ids}" >&2; return 1; }
  done
}

@test "thinking: every baked alias keeps its own hop to coder" {
  # Separate groups go down with the same Sparks but get no hop from `agent`.
  for level in low medium xhigh; do
    run grep -Eq "^[[:space:]]*-[[:space:]]+agent-${level}: \[\"coder\"\]" "${CONFIG}"
    [ "${status}" -eq 0 ] || { echo "agent-${level} has no coder fallback" >&2; return 1; }
  done
}

@test "thinking: no deployment asks for an effort the model does not take" {
  # Qwen3.8-Flash-Next accepts low / medium / xhigh only — never `high`.
  run grep -Eq '^[[:space:]]*reasoning_effort:[[:space:]]*(high|none|minimal)[[:space:]]*$' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "affinity: every grok-config twin renders the session-affinity header" {
  # Every template directory that exists, so renaming or dropping one cannot
  # leave this guard reading a path that is gone.
  checked=0
  for tpl in "${REPO_ROOT}"/templates/*/grok-config.toml.tftpl; do
    [[ -f "${tpl}" ]] || continue
    checked=$((checked + 1))
    run grep -F '"x-litellm-session-id" = "${workspace_affinity_key}"' "${tpl}"
    [ "${status}" -eq 0 ] || { echo "no session-affinity header in ${tpl}" >&2; return 1; }
  done
  [[ "${checked}" -gt 0 ]] || skip "no grok-config.toml.tftpl under ${REPO_ROOT}/templates"
}

@test "affinity: every main.tf twin feeds workspace_affinity_key to the template" {
  checked=0
  for tf in "${REPO_ROOT}"/templates/*/main.tf; do
    checked=$((checked + 1))
    run grep -F 'workspace_affinity_key = "ws-${data.coder_workspace.me.id}"' "${tf}"
    [ "${status}" -eq 0 ] || { echo "main.tf does not pass workspace_affinity_key: ${tf}" >&2; return 1; }
  done
  [[ "${checked}" -gt 0 ]] || skip "no main.tf under ${REPO_ROOT}/templates"
}
