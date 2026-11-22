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
# And it pins the fan-out lanes: `agent-swarm` is one of nine Spark groups whose three
# deployments are the same three boxes, and one of the FOUR groups the session pin
# does not cover -- `agent-explore` (baked low, the child that digs for evidence),
# `agent-review` (baked xhigh, the child that checks what landed) and
# `agent-swarm-fast` (the swarm lane carrying the compaction hop) join it, each its
# own group of three deployments over hardware the pinned lanes already use.
# model_group_affinity_config names all four with an empty flag list, which at this
# tag replaces the global flags for those groups alone and leaves least-busy to place
# every request on the box with the fewest in flight. The five conversation lanes
# stay absent from that map so they keep their pin, no twin tries to lift the pin
# with a client header (that is not an opt-out at this tag), and every fan-out lane
# degrades through a Spark alias rather than Arc-only.
#
# And it pins the fast-compaction pair: `agent-xhigh-fast` and `agent-swarm-fast` are
# their parents deployment for deployment -- same three boxes, same env pairs, xhigh
# baked, same nine tool-calling/window flags -- and differ only in what ONE call of the
# conversation does. The CLI's summary call is re-targeted by
# litellm/compaction_router.py to `compaction-fast`, one Arc Ollama deployment that
# bakes no thinking level and declares the 32768 window those weights actually hold.
# Each fast lane keeps its parent's pin behaviour, each hops to its parent and then to
# coder, and the hook is registered under litellm_settings.callbacks and bind-mounted
# read-only beside the config it gates.
#
# And it pins the NoRoom retry contract: each of the nine agent lanes declares the
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
# And it pins the failover that rides on top of that cadence: the health filter armed at
# all, a staleness threshold that outlives the sweep that wrote the mark, the two keys
# that must be ABSENT from router_settings for the filter to run, a cooldown window the
# probe loop can actually cool a marked box with, and a compose liveness probe that uses
# the image's own interpreter (the image ships no curl and no wget) against the port the
# service itself publishes.
#
# Usage: bazelisk test //tests:bats_litellm_config_test   (from any cwd)
# Safety: reads litellm/config.yaml, litellm/compaction_router.py, docker-compose.yml
# and the two template dirs; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CONFIG=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CONFIG="${REPO_ROOT}/litellm/config.yaml"
  # Not a skip: this file's whole subject is the shipped routing file, it arrives on the
  # suite's data edge as //litellm:config, and a run that could not see it would report
  # every assertion below as green.
  [[ -f "${CONFIG}" ]] || {
    echo "litellm/config.yaml is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
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

# Print each distinct model alias in model_list once. Group-scoped assertions that
# have to iterate over every group -- rather than over a list written here, which
# goes stale the day a lane is added -- start from this.
model_aliases() {
  sed -n 's/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*//p' "${CONFIG}" |
    sed -e 's/[[:space:]]*$//' | sort -u
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

# assert_spark_group_shape <group> <effort> - what every Spark group owes, read
# through entries_for so every assertion is group-scoped: three entries, three
# nested litellm_params, the level baked once per entry, the same three boxes
# addressed by the same env pairs, nine tool-calling/window flags, and three
# group-prefixed unique ids. One place slices the file, so a new group is a pair
# added to the loop below rather than another copy of these greps.
assert_spark_group_shape() {
  local group="$1" effort="$2"
  local body deps params efforts bases keys flags ids unique expected
  body="$(entries_for "${group}")"
  deps="$(printf '%s\n' "${body}" | grep -Ec "^[[:space:]]*-[[:space:]]+model_name: ${group}$")"
  # Nested litellm_params per entry: a flat key is accepted as an extra and then
  # silently ignored, or hard-indexed and the proxy exits 3.
  params="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+litellm_params:$')"
  efforts="$(printf '%s\n' "${body}" | grep -Ec "^[[:space:]]+reasoning_effort: ${effort}$")"
  # Same three boxes as `agent`, addressed by the same env pairs.
  bases="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+api_base: os.environ/SPARK[123]_OPENAI_URL$')"
  keys="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+api_key: os.environ/SPARK_[123]_API_KEY$')"
  # Same tool-calling flags and window as `agent`: 3 entries x 3 keys.
  flags="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+(supports_function_calling|supports_tool_choice|max_input_tokens): ')"
  ids="$(printf '%s\n' "${body}" | grep -Eo "id: ${group}-spark-[0-9]+" | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
  unique="$(printf '%s\n' "${body}" | grep -Eo "id: ${group}-spark-[0-9]+" | sort -u | grep -c '.' | tr -d ' ')"
  [[ "${deps}" -eq 3 ]] || { echo "${group}: ${deps} deployments" >&2; return 1; }
  [[ "${params}" -eq 3 ]] || { echo "${group}: ${params} nested litellm_params" >&2; return 1; }
  [[ "${efforts}" -eq 3 ]] || { echo "${group}: ${efforts} lines bake ${effort}" >&2; return 1; }
  [[ "${bases}" -eq 3 && "${keys}" -eq 3 ]] || { echo "${group}: not the same three boxes (${bases} urls, ${keys} keys)" >&2; return 1; }
  [[ "${flags}" -eq 9 ]] || { echo "${group}: ${flags} tool-calling/window flags, expected 9" >&2; return 1; }
  [[ "${unique}" -eq 3 ]] || { echo "${group}: ids are ${ids}" >&2; return 1; }
  expected="id: ${group}-spark-1 id: ${group}-spark-2 id: ${group}-spark-3"
  [[ "${ids}" == "${expected}" ]] || { echo "${group}: ids are ${ids}" >&2; return 1; }
}

@test "thinking: each baked alias is three boxes with its own effort and unique ids" {
  # The two fan-out lanes and the two fast-compaction twins bake a level too, so they
  # ride this loop instead of owning a copy of it: the level is all that separates
  # explore from review, the pin lift (asserted in the swarm section below) is all
  # that separates a spread lane from the pinned one beside it, and the compaction hop
  # (asserted in the compaction section below) is all that separates a fast twin from
  # the lane it is named after.
  local spec group effort
  for spec in "agent-low low" "agent-medium medium" "agent-xhigh xhigh" \
    "agent-explore low" "agent-review xhigh" \
    "agent-xhigh-fast xhigh" "agent-swarm-fast xhigh"; do
    group="${spec%% *}"
    effort="${spec##* }"
    assert_spark_group_shape "${group}" "${effort}" || return 1
  done
}

@test "thinking: every baked alias keeps its own hop to coder" {
  # Separate groups go down with the same Sparks but get no hop from `agent`. The
  # two fan-out lanes take the extra hop the swarm lane takes, through the pinned
  # lane that bakes their own level, so a parent gets the level it dispatched for
  # even when the fan-out group is fully cooling. Each fast lane hops to the lane it
  # is the twin of -- same boxes, same level, same pin behaviour -- and the summary
  # lane hops to a Spark rather than to another Arc alias, because coder, coder-fast
  # and chat are the same box it is. Every chain still ends at coder.
  local spec group chain
  for spec in 'agent-low ["coder"]' 'agent-medium ["coder"]' 'agent-xhigh ["coder"]' \
    'agent-explore ["agent-low", "coder"]' 'agent-review ["agent-xhigh", "coder"]' \
    'agent-xhigh-fast ["agent-xhigh", "coder"]' \
    'agent-swarm-fast ["agent-swarm", "coder"]' \
    'compaction-fast ["agent-low", "coder"]'; do
    group="${spec%% *}"
    chain="${spec#* }"
    run grep -F -- "- ${group}: ${chain}" "${CONFIG}"
    [ "${status}" -eq 0 ] || { echo "${group} has no ${chain} fallback" >&2; return 1; }
  done
}

@test "thinking: no deployment asks for an effort the model does not take" {
  # Qwen3.8-Flash-Next accepts low / medium / xhigh only — never `high`.
  run grep -Eq '^[[:space:]]*reasoning_effort:[[:space:]]*(high|none|minimal)[[:space:]]*$' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

# affinity_config_block — the model_group_affinity_config mapping, its own line plus
# every deeper-indented line, stopping at its first sibling key. Scoped the way
# retry_policy_block is: a grep over the whole file would also be satisfied by a
# same-named key living in another block.
affinity_config_block() {
  awk '
    BEGIN { depth = -1 }
    /^[[:space:]]*model_group_affinity_config:/ {
      depth = index($0, "model_group_affinity_config:") - 1
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

@test "swarm: the fan-out group is the same three boxes with unique ids" {
  # Routing state lives inside a model group, so another group over hardware the lanes
  # above already use costs no new box. Inside the group the standing rule
  # still holds: one deployment is one box, three distinct SPARKn urls, and three
  # unique model_info.id values for per-deployment health and least-busy counting.
  local body deps params efforts bases keys flags ids unique expected
  body="$(entries_for agent-swarm)"
  deps="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]*-[[:space:]]+model_name: agent-swarm$')"
  params="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+litellm_params:$')"
  # Same baked level as `agent`, so the lane is a drop-in for the agent loop.
  efforts="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+reasoning_effort: xhigh$')"
  bases="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+api_base: os.environ/SPARK[123]_OPENAI_URL$')"
  keys="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+api_key: os.environ/SPARK_[123]_API_KEY$')"
  flags="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+(supports_function_calling|supports_tool_choice|max_input_tokens): ')"
  ids="$(printf '%s\n' "${body}" | grep -Eo 'id: agent-swarm-spark-[0-9]+' | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
  unique="$(printf '%s\n' "${body}" | grep -Eo 'id: agent-swarm-spark-[0-9]+' | sort -u | grep -c '.' | tr -d ' ')"
  [[ "${deps}" -eq 3 ]] || { echo "agent-swarm: ${deps} deployments" >&2; return 1; }
  [[ "${params}" -eq 3 ]] || { echo "agent-swarm: ${params} nested litellm_params" >&2; return 1; }
  [[ "${efforts}" -eq 3 ]] || { echo "agent-swarm: ${efforts} lines bake xhigh" >&2; return 1; }
  [[ "${bases}" -eq 3 && "${keys}" -eq 3 ]] || { echo "agent-swarm: not the same three boxes (${bases} urls, ${keys} keys)" >&2; return 1; }
  [[ "${flags}" -eq 9 ]] || { echo "agent-swarm: ${flags} tool-calling/window flags, expected 9" >&2; return 1; }
  [[ "${unique}" -eq 3 ]] || { echo "agent-swarm: ids are ${ids}" >&2; return 1; }
  expected="id: agent-swarm-spark-1 id: agent-swarm-spark-2 id: agent-swarm-spark-3"
  [[ "${ids}" == "${expected}" ]] || { echo "agent-swarm: ids are ${ids}" >&2; return 1; }
}

# unpinned_lanes - the Spark groups the session pin does not cover, one per line.
# Both affinity assertions read this list, so a lane that opts out of the pin is
# named once and cannot be added to the map assertion while the closed-set
# assertion still believes the map holds only agent-swarm.
unpinned_lanes() {
  printf '%s\n' agent-explore agent-review agent-swarm agent-swarm-fast
}

@test "swarm: the session pin is lifted for the fan-out lanes and for no other group" {
  # One key buys the spread. At v1.102.1 model_group_affinity_config is a Router
  # argument reachable from router_settings, and an entry there REPLACES the global
  # optional_pre_call_checks flags for the group it names -- so the empty list is
  # what leaves this group unpinned and lets least-busy place every request on the
  # box with the fewest in flight. Both halves matter: a flag name pasted into that
  # list would quietly restore the pin, and a group left out of the map keeps the
  # global pin, which is exactly what the five conversation lanes want -- including
  # agent-xhigh-fast, the fast twin that asks for no lift.
  local block groups group expected
  block="$(affinity_config_block)"
  [ -n "${block}" ] || { echo "router_settings declares no model_group_affinity_config" >&2; return 1; }
  while read -r group; do
    [[ -n "${group}" ]] || continue
    assert_match "${group} opts out with an empty flag list" \
      "^[[:space:]]+${group}:[[:space:]]*\\[\\][[:space:]]*$" "${block}"
  done <<<"$(unpinned_lanes)"
  groups="$(printf '%s\n' "${block}" | grep -E '^[[:space:]]+[A-Za-z][A-Za-z-]+:' |
    sed -e 's/[[:space:]]//g' -e 's/:.*//' | sort -u | paste -sd, -)"
  expected="$(unpinned_lanes | sort | paste -sd, -)"
  assert_eq "the fan-out lanes are the only groups named" "${expected}" "${groups}"
  for group in agent agent-low agent-medium agent-xhigh agent-xhigh-fast; do
    assert_not_match "${group} keeps the global pin" "^[[:space:]]+${group}:" "${block}"
  done
}

# router_settings_block - everything under router_settings, comments dropped so a
# lane named in prose cannot satisfy an assertion. Same slice shape as
# general_settings_block below.
router_settings_block() {
  awk '
    /^router_settings:/ { keep = 1; next }
    /^[^[:space:]#]/ { keep = 0 }
    keep && $0 !~ /^[[:space:]]*#/ { print }
  ' "${CONFIG}"
}

@test "fan-out: the pin lift stops at the lanes that asked for it" {
  # An empty flag list is a group-wide switch, so the lift has to stay scoped to the
  # lanes that want spread. Each new lane is therefore named exactly three times
  # under router_settings, and every one of those three is a lane-scoped key: its
  # `[]` in model_group_affinity_config (the lift itself, asserted here), its own
  # model_group_retry_policy key and its own fallbacks entry (both pinned in the
  # sections below). A fourth mention is some other router key deciding affinity or
  # routing for that lane where no assertion has read it. Comments are stripped by
  # the slicer, so this file's own prose about the lanes cannot satisfy the count.
  local block group hits
  block="$(router_settings_block)"
  [ -n "${block}" ] || { echo "router_settings is missing" >&2; return 1; }
  for group in agent-explore agent-review agent-swarm-fast; do
    assert_match "${group} opts out of the pin with an empty flag list" \
      "^[[:space:]]+${group}:[[:space:]]*\\[\\][[:space:]]*$" "${block}"
    # Exactly one such line: a second key for the same group would carry a flag list
    # back, and the closed-set assertion above collapses duplicates with sort -u.
    hits="$(printf '%s\n' "${block}" | grep -Ec "^[[:space:]]+${group}:[[:space:]]*\\[\\][[:space:]]*$" || true)"
    assert_eq "${group} opts out exactly once" "1" "${hits}"
    hits="$(printf '%s\n' "${block}" | grep -c -- "${group}" || true)"
    assert_eq "${group} is named only by its own three lane-scoped keys" "3" "${hits}"
  done
}

# toml_model_keys <tpl> <model> - the key lines of one [model."<model>"] table in a
# grok-config twin: everything from its header up to the first blank line or the next
# table header, comments and blanks dropped. Two reasons to bound the slice rather
# than run it to a later fixed table: a lane inserted in between would otherwise
# decide this assertion, and a comment that only names a key cannot override it --
# the same rule the YAML slicers in this file follow.
toml_model_keys() {
  awk -v header="[model.\"$2\"]" '
    $0 == header { keep = 1; next }
    keep && ($0 ~ /^[[:space:]]*$/ || /^[[:space:]]*\[/) { exit }
    keep && $0 !~ /^[[:space:]]*#/ { print }
  ' "$1"
}

@test "swarm: a twin never tries to lift the pin with a client header" {
  # Not an opt-out at this tag: x-litellm-session-id is read verbatim at any
  # length, and only the generic x-<vendor>-session-id family is shape-checked, so
  # a per-model override that blanked the header would hand every swarm request the
  # SAME pin instead of none. The lane inherits the [models] header verbatim and the
  # proxy's group config does the work. Every lane that lifts the pin server-side rides
  # the same rule -- agent-explore, agent-review and the fast twin of the swarm lane --
  # so a guard that read the swarm table alone would let one of them quietly re-stick
  # its own wave.
  local tpl keys lane
  for tpl in "${REPO_ROOT}"/templates/*/grok-config.toml.tftpl; do
    [[ -f "${tpl}" ]] || continue
    for lane in agent-swarm agent-explore agent-review agent-swarm-fast; do
      run grep -Fx -- "[model.\"${lane}\"]" "${tpl}"
      [ "${status}" -eq 0 ] || { echo "the ${lane} lane is not declared in ${tpl}" >&2; return 1; }
      keys="$(toml_model_keys "${tpl}" "${lane}")"
      [ -n "${keys}" ] || { echo "the ${lane} table in ${tpl} declares no keys" >&2; return 1; }
      assert_not_match "the ${lane} lane overrides no header in ${tpl}" 'extra_headers' "${keys}"
    done
  done
}

@test "swarm: the lane degrades through a Spark alias before it reaches Arc" {
  # This group's own three deployments can all be cooling while the same boxes are
  # healthy under another alias, since health state, cooldowns and in-flight
  # counters are kept per group. So agent is tried first, where least-busy still
  # has a healthy box to pick, and Arc coder stays the last resort it is for every
  # Spark lane. The chain is acyclic: agent-swarm -> agent -> coder.
  run grep -Eq '^[[:space:]]*-[[:space:]]+agent-swarm: \["agent", "coder"\]' "${CONFIG}"
  [ "${status}" -eq 0 ] || { echo "agent-swarm has no agent-then-coder fallback" >&2; return 1; }
}

# litellm_settings_block - everything under litellm_settings, comments dropped so a
# callback named in prose cannot satisfy the registration assertion. Same slice shape
# as general_settings_block below.
litellm_settings_block() {
  awk '
    /^litellm_settings:/ { keep = 1; next }
    /^[^[:space:]#]/ { keep = 0 }
    keep && $0 !~ /^[[:space:]]*#/ { print }
  ' "${CONFIG}"
}

# lane_param_lines <group> - the lines that say what each deployment asks its box for,
# sorted so two groups can be compared as a set. Group-scoped through entries_for like
# every other slice here, so the fast twin is compared against its own parent and
# against nothing else in the file.
lane_param_lines() {
  entries_for "$1" | grep -E '^[[:space:]]+(model|api_base|api_key|reasoning_effort): ' || true
}

@test "compaction: the fast target is one Arc deployment that bakes no thinking level" {
  # One deployment because the Arc is one box, so there is no least-busy decision to
  # make and no pin to lift. The missing reasoning_effort line is the point of the
  # group: a summary answered at xhigh is the cost the fast lanes exist to stop
  # paying. 32768 is the honest window of these weights, and it is what
  # EVO_T1_FAST_COMPACTION_INPUT_LIMIT is measured against.
  local body deps params limits
  body="$(entries_for compaction-fast)"
  [ -n "${body}" ] || { echo "config.yaml declares no compaction-fast group" >&2; return 1; }
  deps="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]*-[[:space:]]+model_name: compaction-fast$' || true)"
  params="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+litellm_params:$' || true)"
  limits="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+max_input_tokens: 32768$' || true)"
  assert_eq "compaction-fast is one deployment" "1" "${deps}"
  assert_eq "compaction-fast nests its params" "1" "${params}"
  assert_eq "compaction-fast declares the 32768 window once" "1" "${limits}"
  assert_match "the target is the Arc coder weight" \
    '^[[:space:]]+model: ollama_chat/qwen2\.5-coder:14b$' "${body}"
  assert_match "the Arc is addressed in-network" \
    '^[[:space:]]+api_base: http://ollama:11434$' "${body}"
  assert_match "the Arc key is the local one" \
    '^[[:space:]]+api_key: local-arc$' "${body}"
  assert_match "the one deployment carries its own id" \
    '^[[:space:]]+id: compaction-fast-arc$' "${body}"
  # Not 3 like a Spark group, and not any other level either: zero thinking lines.
  local efforts
  efforts="$(printf '%s\n' "${body}" | grep -Ec '^[[:space:]]+reasoning_effort:' || true)"
  assert_eq "the summarizer bakes no thinking level" "0" "${efforts}"
}

@test "compaction: each fast lane is its parent lane deployment for deployment" {
  # The hop is a property of one call, not of the turn. A fast lane that drifted from
  # its parent -- another box, another key, another baked level, a tool flag dropped --
  # would be a different lane rather than the same lane with a cheaper summary, and a
  # session that picked it would lose thinking it asked for or keep thinking it did not.
  local spec child parent child_lines parent_lines
  for spec in "agent-xhigh-fast agent-xhigh" "agent-swarm-fast agent-swarm"; do
    child="${spec%% *}"
    parent="${spec##* }"
    # Three entries, three nested litellm_params, the level baked once per entry, the
    # same three boxes by the same env pairs, nine tool-calling/window flags, three
    # unique group-prefixed ids.
    assert_spark_group_shape "${child}" xhigh || return 1
    child_lines="$(lane_param_lines "${child}")"
    parent_lines="$(lane_param_lines "${parent}")"
    [ -n "${child_lines}" ] || { echo "${child} declares no model/url/key/effort lines" >&2; return 1; }
    assert_eq "${child} asks its boxes for exactly what ${parent} asks" \
      "${parent_lines}" "${child_lines}"
  done
}

@test "compaction: the hook is registered beside prometheus in litellm_settings" {
  # LiteLLM dispatches async_pre_call_hook only to a callback that IS a CustomLogger
  # and overrides the method in its own class dict, so the dotted path has to name the
  # module-level instance: a bare class name boots clean and never runs, which is the
  # silent failure this pins. prometheus stays registered -- /metrics is the only place
  # the hop's cost shows up.
  local block hits cbs
  block="$(litellm_settings_block)"
  [ -n "${block}" ] || { echo "litellm_settings is missing" >&2; return 1; }
  hits="$(printf '%s\n' "${block}" | grep -Ec '^[[:space:]]*callbacks:' || true)"
  assert_eq "callbacks is declared exactly once" "1" "${hits}"
  cbs="$(printf '%s\n' "${block}" | grep -E '^[[:space:]]*callbacks:' || true)"
  assert_match "prometheus still exposes /metrics" 'prometheus' "${cbs}"
  assert_match "the hop is registered as the module instance" \
    'compaction_router\.proxy_handler_instance' "${cbs}"
}

@test "compaction: compose mounts the hook beside the config, read-only" {
  # The proxy resolves a callback's dotted name against the directory holding the config
  # file, so the module has to sit beside the config for
  # the dotted callback path to import at all. Both mounts are read-only: the container
  # gets no route to rewriting the routing file or the hook that gates it.
  local compose="${REPO_ROOT}/docker-compose.yml"
  [[ -f "${compose}" ]] || {
    echo "docker-compose.yml is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
  run grep -F -- './litellm/config.yaml:/app/config.yaml:ro' "${compose}"
  [ "${status}" -eq 0 ] || { echo "the config is not mounted read-only at /app/config.yaml" >&2; return 1; }
  run grep -F -- './litellm/compaction_router.py:/app/compaction_router.py:ro' "${compose}"
  [ "${status}" -eq 0 ] || { echo "the hook is not mounted read-only at /app/compaction_router.py" >&2; return 1; }
}

@test "compaction: every knob the module reads is passed through with its default" {
  # The module is the only reader and compose the only place an operator can set these,
  # so a knob that exists in one file and not the other is a policy nobody can change --
  # or, the other way round, a compose entry the proxy never looks at. Both directions are
  # checked, and each passthrough has to carry the module's own default so an unset dotenv
  # boots the shipped policy rather than an empty one.
  local compose="${REPO_ROOT}/docker-compose.yml"
  local mod="${REPO_ROOT}/litellm/compaction_router.py"
  local sample="${REPO_ROOT}/.env.example"
  [[ -f "${compose}" ]] || {
    echo "docker-compose.yml is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
  [[ -f "${mod}" ]] || {
    echo "litellm/compaction_router.py is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
  [[ -f "${sample}" ]] || {
    echo ".env.example is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
  local names name line arg shipped want form
  names="$(grep -oE '_setting\("EVO_T1_FAST_COMPACTION[A-Z_]*"' "${mod}" \
    | sed -E 's/.*\("([^"]*)".*/\1/' | LC_ALL=C sort -u)"
  # Five, because a fourth tier would be a third target nobody declared, and because a
  # knob quietly dropped from this list is the same silent gap the loop below refuses.
  assert_eq "the module reads exactly five compaction knobs" "5" \
    "$(printf '%s\n' "${names}" | grep -c . || true)"
  for name in ${names}; do
    line="$(grep -E "^[[:space:]]+${name}: " "${compose}" || true)"
    [ -n "${line}" ] || { echo "compose passes no ${name}" >&2; return 1; }
    # Which reader a knob has decides the substitution it needs. _setting treats a blank
    # as unset, so the colon form is right. _target_setting reads a blank as "this tier
    # has nowhere to send the call" -- the one way an operator parks a tier -- and the
    # colon form substitutes its default for an empty value too, which would undo that.
    if grep -qE "_target_setting\(\"${name}\"" "${mod}"; then
      form="-"
      want='${'"${name}"'-'
    else
      form=":-"
      want='${'"${name}"':-'
    fi
    [[ "${line}" == *"${want}"* ]] || {
      echo "${name} is not passed as \${${name}${form}<default>}" >&2
      echo "  a target knob must let a blank reach the module as a blank; a knob that" >&2
      echo "  reads blank as unset takes the colon form, which substitutes on empty" >&2
      return 1
    }
    # The module names its default as a literal or as a DEFAULT_* constant, and either
    # way compose has to ship the same value: a compose default that drifted is the
    # policy the container actually boots, and nobody reading the module would know.
    arg="$(sed -n "s/.*_setting(\"${name}\", *\([^)]*\)).*/\1/p" "${mod}" | sed -n 1p)"
    arg="${arg#str(}"
    arg="${arg#\"}"
    arg="${arg%\"}"
    if [[ "${arg}" == DEFAULT_* ]]; then
      shipped="$(sed -n "s/^${arg}: *Final *= *\"\{0,1\}\([0-9A-Za-z,.:-]*\)\"\{0,1\}.*/\1/p" \
        "${mod}" | sed -n 1p)"
    else
      shipped="${arg}"
    fi
    [ -n "${shipped}" ] || { echo "the module gives ${name} no readable default" >&2; return 1; }
    [[ "${line}" == *"${want}${shipped}}"* ]] || {
      echo "${name}: compose defaults away from the module's ${shipped}" >&2
      return 1
    }
    # The dotenv twin is billed for the value and not just for the key's existence: the
    # line an operator copies is the policy they get, and a key sitting there with a
    # stale value reads as the shipped default while booting something else.
    run grep -E "^${name}=${shipped}[[:space:]]*$" "${sample}"
    [ "${status}" -eq 0 ] || {
      echo ".env.example does not show ${name}=${shipped}, the module's own default" >&2
      return 1
    }
  done
  # And nothing extra: a compose entry the module stopped reading reads as a live knob.
  local extra
  extra="$(grep -oE '^[[:space:]]+EVO_T1_FAST_COMPACTION[A-Z_]*:' "${compose}" \
    | tr -d ' :' | LC_ALL=C sort -u | comm -23 - <(printf '%s\n' "${names}"))"
  [ -z "${extra}" ] || { echo "compose passes knobs the module never reads: ${extra}" >&2; return 1; }
}

@test "compaction: the hop is armed by default and its kill switch names every off value" {
  # The alias is the opt-in and the flag is only the kill switch, so a deployment that
  # never sets EVO_T1_FAST_COMPACTION must still take the hop. The off values are read
  # in the module alone -- no compose entry, no template entry -- so the only place
  # they can be pinned is the module's own set.
  local mod default value disabled_line
  mod="${REPO_ROOT}/litellm/compaction_router.py"
  [[ -f "${mod}" ]] || {
    echo "litellm/compaction_router.py is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
  default="$(sed -n 's/.*_setting("EVO_T1_FAST_COMPACTION", "\([^"]*\)".*/\1/p' "${mod}" | head -n 1)"
  [ -n "${default}" ] || { echo "the module never reads EVO_T1_FAST_COMPACTION with a default" >&2; return 1; }
  case "${default}" in
    0 | false | off | no)
      fail "EVO_T1_FAST_COMPACTION defaults to ${default}: the hop must be armed unless the alias opts in"
      ;;
  esac
  disabled_line="$(grep -E '^DISABLED_VALUES[[:space:]]*:' "${mod}" || true)"
  [ -n "${disabled_line}" ] || { echo "the module names no DISABLED_VALUES set" >&2; return 1; }
  for value in 0 false off; do
    assert_match "EVO_T1_FAST_COMPACTION=${value} is a disabled value" "\"${value}\"" "${disabled_line}"
  done
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
  [[ "${checked}" -gt 0 ]] || {
    echo "no grok-config.toml.tftpl under ${REPO_ROOT}/templates" >&2
    return 1
  }
}

@test "affinity: every main.tf twin feeds workspace_affinity_key to the template" {
  checked=0
  for tf in "${REPO_ROOT}"/templates/*/main.tf; do
    checked=$((checked + 1))
    run grep -F 'workspace_affinity_key = "ws-${data.coder_workspace.me.id}"' "${tf}"
    [ "${status}" -eq 0 ] || { echo "main.tf does not pass workspace_affinity_key: ${tf}" >&2; return 1; }
  done
  [[ "${checked}" -gt 0 ]] || {
    echo "no main.tf under ${REPO_ROOT}/templates" >&2
    return 1
  }
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
  [[ "${checked}" -gt 0 ]] || {
    echo "no main.tf under ${REPO_ROOT}/templates" >&2
    return 1
  }
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
  [[ "${checked}" -gt 0 ]] || {
    echo "no grok-config.toml.tftpl under ${REPO_ROOT}/templates" >&2
    return 1
  }
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
  [[ "${checked}" -gt 0 ]] || {
    echo "no grok-config.toml.tftpl under ${REPO_ROOT}/templates" >&2
    return 1
  }
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

# spark_lane_groups - every Spark lane, one per line, in the order the config
# declares them. The retry assertions loop over this list and the closed-set
# assertion sorts it, so the policy can neither gain a lane the gate has not read
# nor lose one and leave it without the policy that reaches NoRoom.
spark_lane_groups() {
  printf '%s\n' agent agent-low agent-medium agent-xhigh agent-swarm \
    agent-explore agent-review agent-xhigh-fast agent-swarm-fast
}

@test "retry: every agent lane carries the policy that reaches NoRoom" {
  local group fields
  while read -r group; do
    [[ -n "${group}" ]] || continue
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
  done <<<"$(spark_lane_groups)"
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
  while read -r group; do
    [[ -n "${group}" ]] || continue
    fields="$(policy_fields_for "${group}")"
    assert_match "NoRoom still gets its two attempts on ${group}" 'DefaultRetries: 2' "${fields}"
    assert_match "a dead stream gets none on ${group}" 'ServiceUnavailableErrorRetries: 0' "${fields}"
  done <<<"$(spark_lane_groups)"
  # And TimeoutErrorRetries is the wrong answer to this problem: the hang never
  # becomes a litellm.Timeout, so a policy that zeroes only it changes nothing.
  run grep -Eq 'TimeoutErrorRetries' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "retry: the policy stays scoped to the Spark lanes" {
  local groups expected
  groups="$(retry_policy_block | grep -E '^[[:space:]]+[A-Za-z][A-Za-z-]+:[[:space:]]*$' |
    sed -e 's/[[:space:]]//g' -e 's/:$//' | sort | paste -sd, -)"
  expected="$(spark_lane_groups | sort | paste -sd, -)"
  assert_eq "only the agent groups are named" "${expected}" "${groups}"
  # coder (Arc) and chat keep today's plain num_retries path, and so does the summary
  # lane: it is the target the hop moves a call to, not a Spark lane.
  run retry_policy_block
  assert_not_match "coder is untouched" '^[[:space:]]+coder:' "${output}"
  assert_not_match "chat is untouched" '^[[:space:]]+chat:' "${output}"
  assert_not_match "compaction-fast is untouched" '^[[:space:]]+compaction-fast:' "${output}"
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

# --- failover: what takes a dead Spark box out of rotation --------------------
#
# Two mechanisms exclude a deployment and only one of them can see the failure this
# fleet actually gets. Cooldown is blind to a box that is simply gone:
# _is_cooldown_required returns False as soon as the exception text contains
# APIConnectionError (router_utils/cooldown_handlers.py:223, ignored_strings), and a
# refused connection, a dead engine, and a TensorFold NoRoom refusal all surface as
# that exception. The health filter is the one that removes such a box --
# async_get_available_deployment (router.py:13041) -> async_get_healthy_deployments
# (router.py:12700) -> _async_filter_health_check_unhealthy_deployments
# (router.py:14137) -- because the sweep writes the health state (proxy_server.py:3981)
# above the routing-only bail at :3988 and the cooldown loop at :3991, so a mark exists
# before the cooldown path can veto the same exception, and
# because least-busy has no health input of its own (a box failing everything sits at
# an in-flight count of zero and _least_busy, least_busy.py:83, returns the FIRST
# deployment at the minimum, :88). Each test below answers one way that filter can
# silently stop working. The cadence floor and the concurrency ceiling stay in the
# section above.

# litellm_service_block - the compose `litellm` service: its key line plus every
# deeper-indented line, stopping at its first sibling, comments dropped. Compose keys
# repeat across services, so a grep over the whole file would be satisfied by another
# container's healthcheck rather than by this service's.
litellm_service_block() {
  awk '
    BEGIN { depth = -1 }
    /^  litellm:[[:space:]]*$/ { depth = 2; print; next }
    depth >= 0 {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { next }
      if (match($0, /[^[:space:]]/) - 1 <= depth) { exit }
      print
    }
  ' "${REPO_ROOT}/docker-compose.yml"
}

# litellm_healthcheck_block - the healthcheck map of that service, sliced the same way:
# comments are already dropped upstream, so the block's own prose about curl and wget
# cannot reach an assertion below.
litellm_healthcheck_block() {
  litellm_service_block | awk '
    BEGIN { depth = -1 }
    /^[[:space:]]*healthcheck:/ { depth = match($0, /[^[:space:]]/) - 1; print; next }
    depth >= 0 {
      if ($0 ~ /^[[:space:]]*$/) { next }
      if (match($0, /[^[:space:]]/) - 1 <= depth) { exit }
      print
    }
  '
}

# litellm_healthcheck_test - the healthcheck `test:` value flattened onto one line. The
# shipped form is a JSON flow sequence broken over eight lines, so a line-by-line grep
# could not prove the interpreter and the URL belong to the SAME command: a probe whose
# python3 lives in `test:` and whose URL sits in some other key would pass both greps.
litellm_healthcheck_test() {
  litellm_healthcheck_block | awk '
    BEGIN { open = 0; on = 0; seen = 0; ti = -1 }
    /^[[:space:]]*test:/ && ti < 0 { on = 1; ti = match($0, /[^[:space:]]/) - 1; print; next }
    on {
      # Stop at the next sibling key: a test: written as a plain string carries no
      # bracket to close on, and the keys after it are not part of the command.
      if (match($0, /[^[:space:]]/) - 1 <= ti && $0 ~ /^[[:space:]]*[A-Za-z_]+:/) { exit }
      print
      line = $0
      n = gsub(/\[/, "[", line)
      line = $0
      m = gsub(/\]/, "]", line)
      open += n - m
      if (n > 0) { seen = 1 }
      if (seen && open <= 0) { exit }
    }
  ' | tr '\n' ' ' | tr -s ' ' |
    sed -e 's/^ //' -e 's/ $//' -e 's/^test:[[:space:]]*//'
}

# block_int <key> <block> - the single bare-integer value of one key, or nothing. A unit
# suffix is deliberately not parsed, so every caller's "exactly one integer" assertion
# turns `health_check_interval: 120s` into a failure instead of a silent 120.
block_int() {
  printf '%s\n' "$2" |
    sed -n "s/^[[:space:]]*$1:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\$/\1/p"
}

# block_secs <key> <block> - the same for a compose duration, which carries its unit.
# Only the plain `<n>s` form parses: compose also accepts 1m30s, but a probe cadence
# written any other way is a cadence the comparisons below cannot make.
block_secs() {
  printf '%s\n' "$2" |
    sed -n "s/^[[:space:]]*$1:[[:space:]]*\([0-9][0-9]*\)s\{0,1\}[[:space:]]*\$/\1/p"
}

# require_compose - the same guard the two compose tests above carry inline: a run that
# could not see the file would otherwise report every assertion below as green.
require_compose() {
  [[ -f "${REPO_ROOT}/docker-compose.yml" ]] || {
    echo "docker-compose.yml is not reachable from ${REPO_ROOT}" >&2
    return 1
  }
}

@test "failover: the health filter is armed, not merely configured" {
  # Every key in the two sections above is dead weight without this one:
  # _async_filter_health_check_unhealthy_deployments returns the candidate list
  # untouched unless enable_health_check_routing is true (router.py:14153). A config
  # that kept the cadence but lost this flag would still probe all 31 deployments,
  # still log every dead box, and still route to it -- the failure is invisible
  # because the probes look like they are working.
  local block hits
  block="$(general_settings_block)"
  [ -n "${block}" ] || { echo "general_settings is missing" >&2; return 1; }
  hits="$(printf '%s\n' "${block}" | grep -Ec '^[[:space:]]*enable_health_check_routing:[[:space:]]*true[[:space:]]*$' || true)"
  assert_eq "enable_health_check_routing is set true exactly once" "1" "${hits}"
}

@test "failover: the probe interval sits between the detection floor and the measured probe cost" {
  # Floor and ceiling both sit tight against the shipped number on purpose: a band
  # wide enough to admit 300 s cannot tell this config from the one before it, and
  # the interval is the dial the whole section argues about. Floor 120: the period is
  # one sweep plus the interval, because the loop sleeps health_check_interval AFTER a
  # sweep finishes (proxy_server.py:4234), and a sweep is the 27 deployments that did
  # not opt out through the concurrency-2 gate -- below this the fleet spends more on
  # probing than on serving. Ceiling 180: each probe is a real completion
  # (ahealth_check into acompletion with the default 16 health_check_max_tokens) on a
  # box whose prompt cache is already full, so waiting longer than this buys detection
  # latency nobody accepts. LiteLLM's own default is 600.
  local interval
  interval="$(block_int health_check_interval "$(general_settings_block)")"
  assert_eq "health_check_interval is exactly one integer" "1" "$(printf '%s\n' "${interval}" | grep -c .)"
  [[ "${interval}" -eq 120 ]] ||
    fail "health_check_interval is ${interval}: this file argues for 120 s specifically, and a band wide enough to let it drift to 300 s would pass over the value that predates the filter"
}

@test "failover: an unhealthy mark outlives the sweep that wrote it" {
  # The filter fails open -- it hands back the whole candidate list when the state is
  # older than health_check_staleness_threshold (and when it is missing, and when
  # filtering would leave nothing). So a threshold shorter than one sweep makes the
  # filter a no-op on schedule: the mark expires before the next sweep can refresh it
  # and the dead box is eligible again. Twice the interval is the minimum that keeps
  # one full cycle of marks alive; the cap is how long a box that stopped being probed
  # at all (proxy killed, loop starved) can still be steered around.
  local block interval staleness
  block="$(general_settings_block)"
  interval="$(block_int health_check_interval "${block}")"
  assert_eq "health_check_interval is exactly one integer" "1" "$(printf '%s\n' "${interval}" | grep -c .)"
  staleness="$(block_int health_check_staleness_threshold "${block}")"
  assert_eq "health_check_staleness_threshold is exactly one integer" "1" "$(printf '%s\n' "${staleness}" | grep -c .)"
  [[ "${staleness}" -ge $((interval * 2)) ]] ||
    fail "health_check_staleness_threshold is ${staleness}s against a ${interval}s interval: an unhealthy mark has to outlive the probe cycle that wrote it, and a stale mark makes the filter fail open onto the dead box (LiteLLM's own default is a flat 600 s whatever the interval says, router.py:993)"
  [[ "${staleness}" -le 1800 ]] ||
    fail "health_check_staleness_threshold is ${staleness}s: past 1800 s a deployment nobody is probing any more stays marked unhealthy, or unmarked, for longer than an operator has noticed"
}

@test "failover: router_settings carries no allowed_fails" {
  # Its absence is load-bearing in both directions. With the key unset, cooldown uses
  # the vendor's rate rule, the base-case arms at cooldown_handlers.py:392-398: cool
  # once a deployment fails
  # more than half of at least 5 requests in a rolling minute. Set it to any
  # non-default number and should_cooldown_based_on_allowed_fails_policy takes the
  # counting branch instead, whose fail window IS cooldown_time -- so the
  # `allowed_fails: 40` this config used to carry needed 41 failures inside 5 s and
  # never fired, while looking like a tuned threshold.
  local block
  block="$(router_settings_block)"
  [ -n "${block}" ] || { echo "router_settings is missing" >&2; return 1; }
  assert_not_match "router_settings sets no allowed_fails" '^[[:space:]]*allowed_fails:' "${block}"
}

@test "failover: router_settings carries no allowed_fails_policy, which would switch the filter off" {
  # The trap. A router-wide allowed_fails_policy with
  # background_health_check_model_groups unset disables the health filter outright
  # (router.py:14161) -- the one config edit that quietly unarms everything the section
  # above pays for, while every probe keeps running and every health page keeps looking
  # green. It reads as a tidier way to group the cooldown policy, which is why it needs
  # its own assertion rather than being covered by the one above.
  local block
  block="$(router_settings_block)"
  [ -n "${block}" ] || { echo "router_settings is missing" >&2; return 1; }
  assert_not_match "router_settings sets no allowed_fails_policy" '^[[:space:]]*allowed_fails_policy:' "${block}"
}

@test "failover: the cooldown window is one the probe loop can cool a marked box with" {
  # With the filter on, the probe loop also cools each deployment its last cycle marked
  # unhealthy, for exactly cooldown_time (proxy_server.py:4013 passes
  # time_to_cooldown=router.cooldown_time, :4018). That path only started running when
  # routing was switched on -- before it the writer returned early. Under 30 s a marked
  # box is eligible again before a client's own retry budget has even noticed; over
  # 300 s a box that recovered between sweeps (a green probe clears the mark,
  # proxy_health_check.py:683) is still shut out.
  local cooldown
  cooldown="$(block_int cooldown_time "$(router_settings_block)")"
  assert_eq "cooldown_time is exactly one integer" "1" "$(printf '%s\n' "${cooldown}" | grep -c .)"
  [[ "${cooldown}" -ge 30 ]] ||
    fail "cooldown_time is ${cooldown}s: the probe loop cools a marked-unhealthy deployment for exactly this long, and under 30 s it is back in rotation before the failure it was pulled for has been noticed"
  [[ "${cooldown}" -le 300 ]] ||
    fail "cooldown_time is ${cooldown}s: a box that came back between sweeps stays shut out for that long even though its green probe already cleared the mark"
}

@test "failover: the compose liveness probe runs on the interpreter the image actually ships" {
  # The pinned image has no curl and no wget -- the busybox applets are not enabled --
  # so a probe written against either exits 127 and the container reads unhealthy while
  # the proxy answers fine. The check is the venv's own python3 against
  # /health/liveliness, which is unprotected and answers "I'm alive!"
  # (_health_endpoints.py:1938); /health itself sits behind user_api_key_auth
  # (_health_endpoints.py:1110) and would need the master key in the container's command
  # line. Absence is checked as a plain substring: `curlpipe` would fail too, because a
  # probe that reaches for either binary by any spelling is the same broken probe.
  local hc_test
  require_compose || return 1
  hc_test="$(litellm_healthcheck_test)"
  [ -n "${hc_test}" ] || { echo "the litellm service declares no healthcheck test:" >&2; return 1; }
  assert_match "the probe is a plain command list, not a shell string" \
    '^\[[[:space:]]*"CMD",' "${hc_test}"
  assert_match "the probe runs the image's own interpreter" '/app/\.venv/bin/python3' "${hc_test}"
  assert_match "the probe asks the unprotected liveliness endpoint" \
    'http://127\.0\.0\.1:4000/health/liveliness' "${hc_test}"
  assert_not_match "the probe names no curl" 'curl' "${hc_test}"
  assert_not_match "the probe names no wget" 'wget' "${hc_test}"
}

@test "failover: the compose probe is paced so one stall is not a verdict" {
  # All four keys have to be present or compose silently falls back to its own defaults
  # (interval 30 s, timeout 30 s, retries 3) and the timeout can end up LONGER than the
  # interval, so probes stack on a stalled proxy instead of waiting it out. start_period
  # is the one that keeps a boot from reading as an outage: the proxy imports the config,
  # builds 31 deployments and mounts the two custom callbacks before uvicorn binds.
  local hc interval timeout retries start_period
  require_compose || return 1
  hc="$(litellm_healthcheck_block)"
  [ -n "${hc}" ] || { echo "the litellm service declares no healthcheck block" >&2; return 1; }
  interval="$(block_secs interval "${hc}")"
  timeout="$(block_secs timeout "${hc}")"
  retries="$(block_int retries "${hc}")"
  start_period="$(block_secs start_period "${hc}")"
  local key value
  for key in interval timeout retries start_period; do
    case "${key}" in
      interval) value="${interval}" ;;
      timeout) value="${timeout}" ;;
      retries) value="${retries}" ;;
      start_period) value="${start_period}" ;;
    esac
    assert_eq "healthcheck ${key} is exactly one integer" "1" "$(printf '%s\n' "${value}" | grep -c .)"
  done
  [[ "${retries}" -ge 1 ]] ||
    fail "healthcheck retries is ${retries}: a single stall marks the proxy unhealthy, and a proxy that stalls under one long stream is normal"
  [[ "${timeout}" -lt "${interval}" ]] ||
    fail "healthcheck timeout ${timeout}s is not shorter than interval ${interval}s: probes then overlap and stack on a stalled proxy instead of giving it the interval to answer"
}

@test "failover: the compose probe dials the port the service itself publishes" {
  # The probe runs INSIDE the container, so the port in its URL is the container-side
  # half -- the right-hand side of the ports: mapping -- and not the host-side half an
  # operator retunes with LITELLM_PORT. Read one from the other's text and the pair can
  # drift: a remapped uvicorn leaves a probe that answers on a port nothing listens on,
  # and the container reads healthy while serving nothing.
  local svc published hc_test probe_port
  require_compose || return 1
  svc="$(litellm_service_block)"
  [ -n "${svc}" ] || { echo "docker-compose.yml declares no litellm service" >&2; return 1; }
  published="$(printf '%s\n' "${svc}" |
    sed -n 's/^[[:space:]]*-[[:space:]]*"\{0,1\}[^"]*:\([0-9][0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' | sort -u)"
  [ -n "${published}" ] || { echo "the litellm service publishes no container port" >&2; return 1; }
  hc_test="$(litellm_healthcheck_test)"
  # Its own assertion, so a probe pointed at some other endpoint says that rather
  # than "names no port": the port regex below is anchored on the liveliness path, so
  # without this line a wrong path reports as a missing port and sends a reader to the
  # ports: mapping when the path is what broke.
  assert_match "the probe dials the liveliness endpoint" '/health/liveliness' "${hc_test}"
  probe_port="$(printf '%s\n' "${hc_test}" |
    sed -nE 's|.*127\.0\.0\.1:([0-9]+)/health/liveliness.*|\1|p' | head -1)"
  [ -n "${probe_port}" ] || { echo "the probe URL names no port after the host" >&2; return 1; }
  # Membership rather than equality: a service may publish more than one container
  # port, and what has to hold is that the probe dials one something listens on.
  if ! printf '%s\n' "${published}" | grep -qx -- "${probe_port}"; then
    fail "the probe dials 127.0.0.1:${probe_port}, which is not a container port the litellm service publishes (${published//$'\n'/ })"
  fi
}

@test "failover: every group of one sits out the probe sweep, and nothing else does" {
  # The filter can never exclude the only member of a group: dropping it empties the
  # candidate list, which is the fail-open (router.py:14177). A mark there therefore
  # buys no routing, and it is not free -- the same sweep cools what it marked
  # (proxy_server.py:4013, time_to_cooldown=cooldown_time at :4018), and the cooldown
  # list has no fail-open here because its only rescue (router.py:12774) needs an
  # allowed_fails_policy this config deliberately refuses. coder is the terminal hop
  # of every agent lane, so a probe that answers 404 -- a weights tag that went
  # missing -- would park the fallback with no user request having failed. The
  # assertion is derived from the file rather than from a list of Arc aliases
  # written here: a future single-deployment group has to opt out the same way, and
  # the count is pinned both directions so a Spark box cannot quietly join them.
  local alias deps solo_count=0 solo_missing="" opted
  while read -r alias; do
    [[ -n "${alias}" ]] || continue
    deps="$(grep -Ec "^[[:space:]]*-[[:space:]]+model_name:[[:space:]]*${alias}[[:space:]]*$" "${CONFIG}")"
    if [[ "${deps}" -eq 1 ]]; then
      solo_count=$((solo_count + 1))
      if ! entries_for "${alias}" |
        grep -Eq '^[[:space:]]*disable_background_health_check:[[:space:]]*true[[:space:]]*$'; then
        solo_missing="${solo_missing:+${solo_missing} }${alias}"
      fi
    fi
  done <<<"$(model_aliases)"
  [[ "${solo_count}" -ge 1 ]] ||
    fail "no single-deployment model group found: the alias scan is broken, not the config"
  [[ -z "${solo_missing}" ]] ||
    fail "these single-deployment groups are still in the probe sweep: ${solo_missing}"
  opted="$(grep -Ec '^[[:space:]]*disable_background_health_check:[[:space:]]*true[[:space:]]*$' "${CONFIG}")"
  assert_eq "only the groups of one opt out of probing" "${solo_count}" "${opted}"
}

@test "failover: a stalled probe still cannot mark a live box" {
  # Load-bearing now that the marks drive routing, and one keystroke from being a
  # flapping machine. A probe that stalls behind a long turn comes back as a 408, and
  # this key is what drops 429/408 out of the list the sweep marks
  # (proxy_server.py:3971) and out of the list it cools (:4002). Flip it to false and
  # one slow 16-token probe moves a session-pinned conversation off its warm box and
  # forces a full re-prefill for a cycle, which is the cost the 120 s cadence exists
  # to keep off the fleet.
  local hits
  hits="$(general_settings_block |
    grep -Ec '^[[:space:]]*health_check_ignore_transient_errors:[[:space:]]*true[[:space:]]*$' || true)"
  assert_eq "health_check_ignore_transient_errors is set true exactly once" "1" "${hits}"
}

@test "failover: background_health_check_model_groups stays unset, so the filter speaks for every group" {
  # Symmetric to the allowed_fails_policy assertion above, and the same kind of trap:
  # it reads as a probe-scope knob, but set it and the filter only excludes
  # deployments inside the listed groups (router.py:14174), so a group left off the
  # list stops being steered around while its probes keep running and its health page
  # keeps looking green. Nothing here wants that scoping; the per-deployment opt-out
  # is the narrower tool, and it is what the single-deployment groups use.
  local section
  for section in general_settings router_settings; do
    case "${section}" in
      general_settings) section="$(general_settings_block)" ;;
      router_settings) section="$(router_settings_block)" ;;
    esac
    assert_not_match "no background_health_check_model_groups" \
      '^[[:space:]]*background_health_check_model_groups:' "${section}"
  done
}
