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
# And it pins the NoRoom retry contract: each of the four agent lanes declares the
# six-field model_group_retry_policy whose DefaultRetries is the only field that
# can catch TensorFold's status-less refusal at this LiteLLM tag, the policy names
# the Spark lanes only, and no key the pinned tag lacks was pasted in.
#
# And it pins the split that fixes a hung compaction: DefaultRetries keeps its two
# attempts for the NoRoom refusal while ServiceUnavailableErrorRetries stays 0,
# because a stream that dies before its first chunk raises a ServiceUnavailableError
# subclass and is the one re-dispatched onto the same session-pinned box. It also
# pins that both main.tf twins raise the CLI's 300 s compaction wall-clock budget to
# the proxy's 1200 s through GROK_COMPACTION_WALL_CLOCK_SECS, and that the budget
# never gets pasted into the TOML twins, where no table reads it.
#
# And it pins the two client-side deadlines in the TOML twins: every
# inference_idle_timeout_secs copy (the global key and each model lane) carries
# 1800 s, sitting above the proxy's request_timeout of 1200 s so the proxy stays
# the end that abandons a hung stream, and [session] auto_compact_threshold_percent
# is 70, the load lever that fires compaction near 183,500 of the CLI's
# 262144-token window.
#
# And it pins the background health-check cadence: a probe is a real thinking generation
# on a GPU box whose prompt cache runs full, so the interval has a floor and the round
# has a concurrency ceiling, and the two keys stay under general_settings where the proxy
# accepts them.
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

@test "compaction: every main.tf twin raises the CLI's 300 s budget to the proxy's 1200 s" {
  # The budget is applied after the response returns, so at 300 s it discarded a
  # summary that had already streamed in and made the session regenerate it.
  # 1200 matches request_timeout above, the only live bound on this path:
  # inference_idle_timeout_secs does not reach the summary call, so its 1800 s
  # (pinned below) gates nothing here.
  checked=0
  for tf in "${REPO_ROOT}"/templates/*/main.tf; do
    checked=$((checked + 1))
    run grep -Eq '^[[:space:]]*GROK_COMPACTION_WALL_CLOCK_SECS = "1200"$' "${tf}"
    [ "${status}" -eq 0 ] || { echo "main.tf does not raise the compaction budget: ${tf}" >&2; return 1; }
  done
  [[ "${checked}" -gt 0 ]] || skip "no main.tf under ${REPO_ROOT}/templates"
}

@test "compaction: the budget stays out of the TOML twins" {
  # The CLI has a remote-settings key of this name and no TOML table that reads
  # it, so a config that looks right is silently ignored -- the same trap the
  # stack already documented for [mcp] max_output_bytes. It rides the env only.
  checked=0
  for tpl in "${REPO_ROOT}"/templates/*/grok-config.toml.tftpl; do
    [[ -f "${tpl}" ]] || continue
    checked=$((checked + 1))
    run grep -Eq 'compaction_wall_clock_budget_secs|GROK_COMPACTION_WALL_CLOCK_SECS[[:space:]]*=' "${tpl}"
    [ "${status}" -ne 0 ] || { echo "the budget was pasted into TOML, where nothing reads it: ${tpl}" >&2; return 1; }
  done
  [[ "${checked}" -gt 0 ]] || skip "no grok-config.toml.tftpl under ${REPO_ROOT}/templates"
}

@test "timeouts: every grok-config twin ships the 1800 s idle deadline and the 70 per cent threshold" {
  # Both keys are client-side, and the twins are independent payload copies, so
  # one side drifting would hand a dev container a different deadline than a
  # Coder workspace gets. The idle deadline deliberately sits ABOVE the proxy's
  # request_timeout: the proxy stays the end that abandons a stream producing no
  # bytes, and this key only has to stop the client abandoning a slow-but-flowing
  # one. The threshold is the load lever for the compaction path -- at 70 the
  # summary is generated from about 183,500 of the CLI's 262144-token window.
  checked=0
  for tpl in "${REPO_ROOT}"/templates/*/grok-config.toml.tftpl; do
    [[ -f "${tpl}" ]] || continue
    checked=$((checked + 1))
    # Every model lane pins its own copy and the file's contract is that each
    # equals the global one, so any other value is a lane on a shorter fuse.
    local strays
    strays="$(grep -E '^[[:space:]]*inference_idle_timeout_secs = [0-9]+$' "${tpl}" |
      grep -cvE ' = 1800$' || true)"
    [ "${strays}" -eq 0 ] || { echo "${strays} idle deadline(s) other than 1800 in ${tpl}" >&2; return 1; }
    run grep -E '^[[:space:]]*inference_idle_timeout_secs = 1800$' "${tpl}"
    [ "${status}" -eq 0 ] || { echo "no 1800 s idle deadline in ${tpl}" >&2; return 1; }
    # Global key plus per-model copies: a file that kept only one would pass the
    # check above while the lanes silently fell back to the CLI default.
    local pinned
    pinned="$(grep -cE '^[[:space:]]*inference_idle_timeout_secs = 1800$' "${tpl}" || true)"
    [ "${pinned}" -ge 2 ] || { echo "only ${pinned} copy of the 1800 s deadline in ${tpl}" >&2; return 1; }
    run grep -Eq '^[[:space:]]*auto_compact_threshold_percent = 70$' "${tpl}"
    [ "${status}" -eq 0 ] || { echo "auto-compaction threshold is not 70 in ${tpl}" >&2; return 1; }
  done
  [[ "${checked}" -gt 0 ]] || skip "no grok-config.toml.tftpl under ${REPO_ROOT}/templates"
  # The asymmetry is the point: raising the client must not have raised the proxy.
  run grep -Eq '^[[:space:]]*request_timeout: 1200$' "${CONFIG}"
  [ "${status}" -eq 0 ] || { echo "request_timeout no longer bounds the chain at 1200 s" >&2; return 1; }
}

# retry_policy_block — the model_group_retry_policy mapping, its own line plus
# every deeper-indented line, stopping at its first sibling key. Slicing it out
# is what makes the assertions below about the policy: a grep over the whole
# file would also be satisfied by a same-named field in another block.
retry_policy_block() {
  awk '
    BEGIN { depth = -1 }
    /^[[:space:]]*model_group_retry_policy:/ {
      depth = index($0, "model_group_retry_policy:") - 1
      print
      next
    }
    depth >= 0 {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { next }
      if (match($0, /[^[:space:]]/) - 1 <= depth) { depth = -1; next }
      print
    }
  ' "${CONFIG}"
}

# policy_fields_for <group> — the field lines of one group inside the policy.
# The group key must be followed by a colon and nothing else, so `agent` cannot
# match the `agent-low` entry.
policy_fields_for() {
  retry_policy_block | awk -v want="$1" '
    $0 ~ "^[[:space:]]*" want ":[[:space:]]*$" { keep = 1; next }
    /^[[:space:]]+[A-Za-z][A-Za-z-]*:[[:space:]]*$/ { keep = 0 }
    keep { print }
  '
}

@test "retry: every agent lane carries the policy that reaches NoRoom" {
  local group fields
  for group in agent agent-low agent-medium agent-xhigh; do
    fields="$(policy_fields_for "${group}")"
    assert_match "DefaultRetries is set for ${group}" 'DefaultRetries: 2' "${fields}"
    assert_match "500 is retried for ${group}" 'InternalServerErrorRetries: 2' "${fields}"
    # Not 2: this is the field a stream that died before its first chunk lands
    # on, and re-dispatching that to the same session-pinned box is the hang.
    # See the companion test below.
    assert_match "a dead stream is not re-dispatched for ${group}" \
      'ServiceUnavailableErrorRetries: 0' "${fields}"
    assert_match "400 is not retried for ${group}" 'BadRequestErrorRetries: 0' "${fields}"
    assert_match "401 is not retried for ${group}" 'AuthenticationErrorRetries: 0' "${fields}"
    assert_match "content policy is not retried for ${group}" \
      'ContentPolicyViolationErrorRetries: 0' "${fields}"
    # 2 matches num_retries: the policy adds a lane that can catch the
    # status-less APIConnectionError shape, it does not lengthen the chain.
    assert_eq "${group} declares exactly six fields" "6" "$(printf '%s\n' "${fields}" | grep -c ':')"
  done
}

@test "retry: the NoRoom retry and the dead-stream retry stay on separate fields" {
  # The whole fix rests on these two classes reaching two different fields, so
  # pin both halves. At v1.102.1 a TensorFold NoRoom refusal arrives as
  # APIConnectionError, which is absent from _RETRIES_BY_EXCEPTION_TYPE, so the
  # MRO walk in get_retry_from_policy.py falls through to DefaultRetries. A
  # stream that dies before its first chunk raises MidStreamFallbackError, which
  # subclasses ServiceUnavailableError, so the walk stops on
  # ServiceUnavailableErrorRetries and never reaches DefaultRetries. Zeroing the
  # second therefore cannot undo the first: 1200 s once, not three times.
  local group fields
  for group in agent agent-low agent-medium agent-xhigh; do
    fields="$(policy_fields_for "${group}")"
    assert_match "NoRoom still gets its two attempts on ${group}" 'DefaultRetries: 2' "${fields}"
    assert_match "a dead stream gets none on ${group}" 'ServiceUnavailableErrorRetries: 0' "${fields}"
  done
  # And TimeoutErrorRetries is the wrong answer to this problem: the hang never
  # becomes a litellm.Timeout, so a policy that zeroes only it changes nothing.
  run grep -Eq 'TimeoutErrorRetries' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "retry: the policy stays scoped to the Spark lanes" {
  local groups
  groups="$(retry_policy_block | grep -E '^[[:space:]]+[A-Za-z][A-Za-z-]+:[[:space:]]*$' |
    sed -e 's/[[:space:]]//g' -e 's/:$//' | sort | paste -sd, -)"
  assert_eq "only the four agent groups are named" \
    "agent,agent-low,agent-medium,agent-xhigh" "${groups}"
  # coder (Arc) and chat keep today's plain num_retries path.
  run retry_policy_block
  assert_not_match "coder is untouched" '^[[:space:]]+coder:' "${output}"
  assert_not_match "chat is untouched" '^[[:space:]]+chat:' "${output}"
}

@test "retry: no retry key from newer docs was pasted in" {
  # Verified absent from the v1.102.1 tag: the proxy warns and ignores these,
  # so a config that looks right would silently do nothing.
  run grep -Eq 'fallbacks_by_model|NotFoundErrorRetries|retry_after' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "retry: the chain-wide num_retries stays where it was" {
  # The policy complements num_retries; replacing it would change every lane.
  run grep -Eq '^[[:space:]]*num_retries: 2$' "${CONFIG}"
  [ "${status}" -eq 0 ]
}

# Print the general_settings block: everything after that top-level key up to the next
# one, comments dropped so a key named in prose cannot satisfy an assertion. Scoped so a
# health_check_interval elsewhere in the file cannot satisfy the pin.
general_settings_block() {
  awk '
    /^general_settings:/ { keep = 1; next }
    /^[^[:space:]#]/ { keep = 0 }
    keep && $0 !~ /^[[:space:]]*#/ { print }
  ' "${CONFIG}"
}

@test "health: the background probe loop is a loop and not a hammer" {
  # A probe is a real generation on the box: at v1.102.1 the proxy forwards the whole
  # litellm_params into acompletion, so the baked reasoning_effort rides along and the
  # probe asks for the default 16 max_tokens. A thinking reply cannot finish reasoning in
  # 16 tokens, so it returns empty content, logs a max_tokens warning, and still takes a
  # prompt-cache state on a box whose cache is already full ("0 MiB spare of 6465 MiB"),
  # evicting a warm prefix that then re-prefills from zero. Cadence is a load decision.
  local block interval concurrency
  block="$(general_settings_block)"

  interval="$(printf '%s\n' "${block}" |
    sed -n 's/^[[:space:]]*health_check_interval:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p')"
  assert_eq "health_check_interval is exactly one integer" "1" "$(printf '%s\n' "${interval}" | grep -c .)"
  [ "${interval}" -ge 120 ] ||
    fail "health_check_interval is ${interval}s: every round puts a real thinking generation on each Spark box and evicts warm prompt state; the floor is 120 and LiteLLM's own default is 300"

  concurrency="$(printf '%s\n' "${block}" |
    sed -n 's/^[[:space:]]*health_check_concurrency:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p')"
  assert_eq "health_check_concurrency is exactly one integer" "1" "$(printf '%s\n' "${concurrency}" | grep -c .)"
  [ "${concurrency}" -le 2 ] ||
    fail "health_check_concurrency is ${concurrency}: one round then takes that many streams off a box the fleet already routes five streams to"

  # Auto-recovery must stay armed, or a dead box never comes back on its own.
  assert_match "the loop itself stays on" '^[[:space:]]*background_health_checks: true$' "${block}"
}

@test "health: the two interval keys never drift out of general_settings" {
  # The proxy raises ValueError at boot when it finds these under router_settings, so
  # drift here stops the box rather than quietly retuning it.
  local router_block
  router_block="$(awk '
    /^router_settings:/ { keep = 1; next }
    /^[^[:space:]#]/ { keep = 0 }
    keep && $0 !~ /^[[:space:]]*#/ { print }
  ' "${CONFIG}")"
  assert_not_match "router_settings carries no health_check_interval" 'health_check_interval' "${router_block}"
  assert_not_match "router_settings carries no health_check_concurrency" 'health_check_concurrency' "${router_block}"
}
