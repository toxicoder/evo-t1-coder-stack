#!/usr/bin/env bash
#
# ## subagent-check.sh - prove the subagent width a session actually gets
#
# The stack renders [subagents] in every workspace's ~/.grok/config.toml from
# var.grok_swarm_width, so the width a fleet runs at is a template decision. A
# --var handed to `coder start`, or pinned on the template, outlives the run that
# passed it: it persists in the Coder database, every later start reuses it, and
# no agent inside the workspace can clear it. The render then carries a
# max_concurrent below the fleet's stream count, a fan-out queues behind one
# parent's slots, and nothing in the workspace says so.
#
# The render writes its own diagnosis into the file: a `# fleet-width:` comment
# directly above max_concurrent, both fed from the same variable. A rendered
# `# fleet-width: 15` over `max_concurrent = 4` is the whole finding. This CLI
# reads that pair, the writers' lane in [subagents.models], and the depth, and
# answers what the fan-out of a session started from this profile would get.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:subagent-check -- [--config PATH] [--parallel N]
#                                            [--json] [--strict] [-h|--help]
#
# Options (accepted anywhere in argv):
#   --config <path>   the Grok config to read (default $HOME/.grok/config.toml)
#   --parallel <n>    the LiteLLM PARALLEL each Spark box serves, which is the
#                     useful width when the writers ride a pinned lane (default
#                     5, the recipe default in scripts/spark-configure.sh)
#   --strict          a warning is a failure (exit 1 on a warning too)
#   --json            one machine-readable object on stdout, prose on stderr
#   -h, --help        print the usage block and exit 0
#
# Output: the house vocabulary - "== subagent slots ==", "-> the profile",
#   "-> the width", "-> the lanes", "-> the depth", and a closing
#   "summary: N ok, W warnings, F failed". Under --json stdout is that one flat
#   object and every prose line goes to stderr.
# Exit codes: 0 with no failures (warnings allowed unless --strict), 1 with at
#   least one failure (or a warning under --strict), 2 on a usage error.
#
# A width below fleet-width is a warning, not a failure: the workspace works and
# the fan-out is only narrower than the fleet can carry, which is also what an
# operator who set the --var on purpose asked for. A profile carrying neither
# stack marker is a failure, because the render that owns those keys never
# reaches that file again and no restart fixes it.
#
# Related: scripts/mcp-check.sh (the same profile-read shape and the same two
#   stack markers), scripts/spark-configure.sh (the PARALLEL recipe default
#   --parallel takes), templates/{workspace,devcontainer}/grok-config.toml.tftpl
#   and scripts/seed-dev-env.sh (the two renders that write the fleet-width
#   line), docs/troubleshooting.md#the-rendered-width-is-below-fleet-width (the
#   runbook the below-width note answers).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function resolve_repo_root
# Print the checkout this run reads its pins from: the first candidate holding a
# docker-compose.yml marker. A Bazel sandbox holds a copy of the tree, so the
# probe is a marker file and never a cwd assumption.
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE, PWD, SELF_DIR
# Arguments:
#   None
# Outputs:
#   The root on stdout, or one complaint line on stderr
# Returns:
#   0 with the root, 5 when no candidate holds the marker
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}" "${SELF_DIR}" "${SELF_DIR}/..")
  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}/docker-compose.yml" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: unresolvable repo root: no proven checkout in %s (need docker-compose.yml)\n' \
    "${candidates[*]}" >&2
  return 5
}

# @function find_lib
# Print the path one helper is reachable from: the resolved root first, then this
# script's own directory, so a runfiles copy still finds both halves.
# Globals:
#   SELF_DIR
# Arguments:
#   $1 - helper file name, relative to the lib directory
#   $2 - resolved repo root, possibly empty
# Outputs:
#   The helper path on stdout, or one complaint line on stderr
# Returns:
#   0 when the helper was found, 1 otherwise
find_lib() {
  local name="$1" root="${2:-}" candidate
  local -a candidates=()
  if [ -n "${root}" ]; then
    candidates+=("${root}/scripts/lib/${name}")
  fi
  candidates+=("${SELF_DIR}/lib/${name}")
  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: %s is not reachable from %s\n' "${name}" "${candidates[*]}" >&2
  return 1
}

REPO_ROOT_RESOLVED="$(resolve_repo_root || true)"
COMMON_LIB="$(find_lib common.sh "${REPO_ROOT_RESOLVED}")" || {
  printf 'error: subagent-check cannot run without its helpers: no scripts/lib/common.sh above\n' >&2
  exit 1
}
# shellcheck source=/dev/null
source "${COMMON_LIB}"

# The LiteLLM PARALLEL a Spark box serves, from the recipe default in
# scripts/spark-configure.sh. It is the useful width once the writers ride a
# session-pinned lane, so the pinned warning names it instead of leaving the
# operator to go look it up.
DEFAULT_PARALLEL=5
# The aliases LiteLLM serves with the session pin lifted, so a fan-out on any one
# of them is placed over the least-busy box and spreads over the fleet. Every
# other alias rides the conversation's own pin, and one box's PARALLEL is then
# the whole width. Names from litellm/config.yaml; docs/litellm-routing.md has
# the routing arithmetic.
UNPINNED_LANES="agent-swarm agent-explore agent-review agent-swarm-fast"
# The two spellings of stack ownership, kept in step with STACK_MARKER_TEXT and
# STACK_MARKER_TOML in scripts/lib/config_seed.sh. The comment form is what the
# render writes; the plain key is what survives the CLI rewriting this file.
STACK_MARKER="managed-by: evo-t1-coder-stack"
STACK_MARKER_TOML="__evoT1Stack = true"

CONFIG=""
PARALLEL="${DEFAULT_PARALLEL}"
STRICT=0
# MARKER_JSON and PINNED_JSON hold the JSON literals true, false, or nothing for
# "never measured" (finish renders nothing as null), so the --json object answers
# the same two questions the prose verdicts answered.
MARKER_JSON=""
PINNED_JSON=""
MAX_CONCURRENT=""
FLEET_WIDTH=""
WRITERS_LANE=""
MAX_DEPTH=""

# @function finish
# Close the run: the summary line, the machine-readable object under --json, and
# the exit code that answers the same question both printouts just answered.
# Globals:
#   JSON_MODE, STRICT, SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL, CONFIG,
#   MARKER_JSON, PINNED_JSON, MAX_CONCURRENT, FLEET_WIDTH, WRITERS_LANE,
#   MAX_DEPTH
# Arguments:
#   None
# Outputs:
#   The summary, and one flat JSON object on stdout under --json
# Returns:
#   Nothing: exits 0, or 1 on a failure (or a warning under --strict)
finish() {
  summary
  if [ -n "${JSON_MODE:-}" ]; then
    local verdict="ok"
    [ "${SUMMARY_WARN:-0}" -gt 0 ] && verdict="warning"
    [ "${SUMMARY_FAIL:-0}" -gt 0 ] && verdict="error"
    printf '{"config":"%s","marker":%s,"max_concurrent":%s,"fleet_width":%s,"writers_lane":%s,"pinned":%s,"max_depth":%s,"verdict":"%s","ok":%d,"warnings":%d,"failed":%d}\n' \
      "$(json_escape "${CONFIG}")" "${MARKER_JSON:-null}" \
      "$(json_value "${MAX_CONCURRENT}")" "$(json_value "${FLEET_WIDTH}")" \
      "$(json_value "${WRITERS_LANE}")" "${PINNED_JSON:-null}" \
      "$(json_value "${MAX_DEPTH}")" "${verdict}" \
      "${SUMMARY_OK:-0}" "${SUMMARY_WARN:-0}" "${SUMMARY_FAIL:-0}"
  fi
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    exit 1
  fi
  if [ "${STRICT}" = "1" ] && [ "${SUMMARY_WARN:-0}" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

# @function usage
# Print how to run this CLI.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE'
usage: bazelisk run //scripts:subagent-check -- [--config PATH] [--parallel N]
                                              [--json] [--strict] [-h|--help]

Proves the subagent width a session gets: the rendered max_concurrent against
the fleet width the same render wrote above it, the writers' lane in
[subagents.models], and max_depth. Reads one file; needs no network and no
docker.

Options: --config (default $HOME/.grok/config.toml), --parallel (the LiteLLM
PARALLEL each Spark box serves, the useful width on a pinned lane; default 5),
--strict (a warning fails the run), --json (one flat object on stdout, prose on
stderr), -h/--help.

Exit: 0 clean or warned, 1 on any failure (or a warning under --strict),
2 on a usage error.
USAGE
}

# @function usage_error
# Print one usage complaint and exit 2, so a typo is never mistaken for a result.
# Globals:
#   None
# Arguments:
#   $1 - the complaint
# Outputs:
#   The complaint on stderr, plus the usage block on stdout
# Returns:
#   Nothing: exits 2
usage_error() {
  printf 'error: %s\n' "$1" >&2
  usage
  exit 2
}

# @function profile_int
# Print the first "<key> = <int>" line of the profile, or nothing. The line is
# anchored and the value constrained to digits, so a commented or stringified
# value cannot read as a width, and the last key of another table cannot be
# mistaken for the [subagents] one.
# Globals:
#   CONFIG
# Arguments:
#   $1 - the key to read
# Outputs:
#   The integer on stdout, nothing when the key is absent
# Returns:
#   0, always: a failing sed would reach the caller's assignment through
#   pipefail and abort a strict-mode script over a file that has no such key
profile_int() {
  local key="${1:-}" value=""
  [ -n "${key}" ] && [ -f "${CONFIG}" ] || return 0
  value="$(sed -n "s/^${key} = \([0-9][0-9]*\)$/\1/p" "${CONFIG}" 2>/dev/null |
    head -n 1)" || value=""
  printf '%s' "${value}"
}

# @function profile_fleet_width
# Print the integer on the `# fleet-width:` comment the render writes directly
# above max_concurrent, or nothing. The same sed the boot advisory in
# templates/*/startup.sh.tftpl runs, so the two can never disagree about what a
# fleet-width line is.
# Globals:
#   CONFIG
# Arguments:
#   None
# Outputs:
#   The integer on stdout, nothing when the line is absent
# Returns:
#   0, always (see profile_int for why a reader here never fails)
profile_fleet_width() {
  local value=""
  [ -f "${CONFIG}" ] || return 0
  value="$(sed -n 's/^# fleet-width: \([0-9][0-9]*\)$/\1/p' "${CONFIG}" 2>/dev/null |
    head -n 1)" || value=""
  printf '%s' "${value}"
}

# @function profile_writers_lane
# Print the value of general-purpose inside [subagents.models] - the lane a
# writer in a fan-out rides - or nothing when the block or the key is absent,
# which is the state where the writers inherit the parent's own pinned model.
# Globals:
#   CONFIG
# Arguments:
#   None
# Outputs:
#   The alias on stdout, nothing when nothing pins the writers
# Returns:
#   0, always (see profile_int for why a reader here never fails)
profile_writers_lane() {
  local value=""
  [ -f "${CONFIG}" ] || return 0
  value="$(awk '/^\[subagents\.models\]/{f=1} /^\[/ && !/subagents\.models/{f=0} f' \
    "${CONFIG}" 2>/dev/null |
    sed -n 's/^general-purpose[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)" || value=""
  printf '%s' "${value}"
}

# @function is_unpinned_lane
# Succeed for an alias LiteLLM serves with the session pin lifted, which is the
# only way a fan-out reaches more than one box.
# Globals:
#   UNPINNED_LANES
# Arguments:
#   $1 - the alias to judge
# Outputs:
#   None
# Returns:
#   0 when the alias is pin-lifted, 1 otherwise
is_unpinned_lane() {
  local lane="${1:-}" candidate
  for candidate in ${UNPINNED_LANES}; do
    if [ "${lane}" = "${candidate}" ]; then
      return 0
    fi
  done
  return 1
}

# @function check_profile
# The profile phase: is the file there at all, and does the stack render still
# own it. A file nobody owns is a failure rather than a warning, because the
# render that writes fleet-width, the width and the lane pins never touches it
# again, so a restart cannot fix what this phase just found.
# Globals:
#   CONFIG, STACK_MARKER, STACK_MARKER_TOML, MARKER_JSON
# Arguments:
#   None
# Outputs:
#   The phase line and its ok or error line
# Returns:
#   0 when there is a profile to read, 1 when there is none (the caller stops and
#   summarizes; the rest of the phases have nothing to read)
check_profile() {
  phase "the profile"
  if [ ! -f "${CONFIG}" ]; then
    MARKER_JSON=""
    fail_item "no profile at ${CONFIG}"
    return 1
  fi
  if grep -qsF -e "${STACK_MARKER}" -e "${STACK_MARKER_TOML}" "${CONFIG}"; then
    MARKER_JSON=true
    ok "stack-managed (the startup render still owns this file)"
  else
    MARKER_JSON=false
    fail_item "${CONFIG} carries neither stack marker"
  fi
  return 0
}

# @function check_width
# The width phase: the rendered max_concurrent against the fleet width the same
# render wrote above it. Equal is the shipped state. Below is the persisted
# --var this CLI exists to catch, so the note names the two commands that clear
# it. Above is not a fault - the extra spawns queue in LiteLLM - so it is a note
# and costs nothing.
# Globals:
#   CONFIG, MAX_CONCURRENT, FLEET_WIDTH
# Arguments:
#   None
# Outputs:
#   The phase line and the verdict for the pair it read
# Returns:
#   0, always (the counters decide the exit code)
check_width() {
  phase "the width"
  MAX_CONCURRENT="$(profile_int max_concurrent)"
  FLEET_WIDTH="$(profile_fleet_width)"
  if [ -z "${MAX_CONCURRENT}" ]; then
    warn "no 'max_concurrent' line - this profile has no [subagents] table; restart the workspace to re-materialize"
    return 0
  fi
  if [ -z "${FLEET_WIDTH}" ]; then
    warn "no '# fleet-width:' line - this profile predates it; restart the workspace to re-materialize"
    return 0
  fi
  if [ "${MAX_CONCURRENT}" -lt "${FLEET_WIDTH}" ]; then
    warn "max_concurrent = ${MAX_CONCURRENT} is below the fleet width ${FLEET_WIDTH}"
    # <workspace> stays a placeholder: this CLI cannot know which workspace the
    # profile came from, and on the stack host one run addresses many.
    note "a rendered width below fleet-width is a --var that outlived its template - on the stack host: coder start <workspace> --var grok_subagent_max_concurrent=${FLEET_WIDTH}, or //scripts:push-template for a template-level --var, then restart"
  elif [ "${MAX_CONCURRENT}" -gt "${FLEET_WIDTH}" ]; then
    note "max_concurrent = ${MAX_CONCURRENT} is above the fleet width ${FLEET_WIDTH} - past the fleet's streams the extra spawns queue in LiteLLM"
  else
    ok "max_concurrent = ${MAX_CONCURRENT}, the fleet's own width"
  fi
  return 0
}

# @function check_lanes
# The lanes phase: what the writers of a fan-out ride. The pin-lifted aliases are
# placed over the least-busy box, so the fleet's streams are the width; any other
# alias, and the missing key that leaves the writers on the parent's model, puts
# every writer on one box's PARALLEL.
# Globals:
#   CONFIG, PARALLEL, WRITERS_LANE, PINNED_JSON
# Arguments:
#   None
# Outputs:
#   The phase line, the lane verdict, and the remedy note on the pinned path
# Returns:
#   0, always (the counters decide the exit code)
check_lanes() {
  phase "the lanes"
  WRITERS_LANE="$(profile_writers_lane)"
  if [ -z "${WRITERS_LANE}" ]; then
    PINNED_JSON=true
    warn "writers ride the parent's model (session-pinned: one box's PARALLEL ${PARALLEL} is the useful width)"
    note "--var grok_subagents_lane=agent-swarm puts a fan-out on every box"
    return 0
  fi
  if is_unpinned_lane "${WRITERS_LANE}"; then
    PINNED_JSON=false
    ok "writers ride ${WRITERS_LANE} (unpinned: least-busy spreads over every box)"
  else
    PINNED_JSON=true
    warn "writers ride ${WRITERS_LANE} (session-pinned: one box's PARALLEL ${PARALLEL} is the useful width)"
    note "--var grok_subagents_lane=agent-swarm puts a fan-out on every box"
  fi
  return 0
}

# @function check_depth
# The depth phase: how deep a spawn tree may go. Reported, never judged - a
# depth-2 child is read-only by policy but holds a fleet stream like any other
# spawn, so it counts against the same width the width phase just measured.
# Globals:
#   CONFIG, MAX_DEPTH
# Arguments:
#   None
# Outputs:
#   The phase line, and the depth note when the profile states one
# Returns:
#   0, always
check_depth() {
  phase "the depth"
  MAX_DEPTH="$(profile_int max_depth)"
  if [ -n "${MAX_DEPTH}" ]; then
    note "max_depth = ${MAX_DEPTH} (a depth-2 child holds a fleet stream too)"
  fi
  return 0
}

# @function main
# Parse argv, walk the four phases under one section, summarize, and answer with
# the exit code.
# Globals:
#   CONFIG, PARALLEL, STRICT, JSON_MODE, DEFAULT_PARALLEL
# Arguments:
#   "$@" - the command line
# Outputs:
#   The report on stdout (stderr under --json), or the usage block
# Returns:
#   0 clean or warned, 1 on failure, 2 on a usage error
main() {
  local config="" parallel="" strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [ $# -ge 2 ] || usage_error "--config needs a path"
        config="$2"
        shift 2
        ;;
      --parallel)
        [ $# -ge 2 ] || usage_error "--parallel needs a number"
        parallel="$2"
        shift 2
        ;;
      --strict)
        strict=1
        shift
        ;;
      --json)
        JSON_MODE=1
        export JSON_MODE
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  [ -n "${JSON_MODE:-}" ] || unset JSON_MODE

  [ -z "${parallel}" ] || [[ ${parallel} =~ ^[1-9][0-9]*$ ]] ||
    usage_error "--parallel wants a whole number of streams per box"

  CONFIG="${config:-${HOME:-/home/coder}/.grok/config.toml}"
  PARALLEL="${parallel:-${DEFAULT_PARALLEL}}"
  STRICT="${strict}"

  section "subagent slots"
  if ! check_profile; then
    finish
  fi
  check_width
  check_lanes
  check_depth
  finish
}

main "$@"
