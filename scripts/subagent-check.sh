#!/usr/bin/env bash
#
# ## subagent-check.sh - prove the subagent width a session actually gets
#
# The stack renders [subagents] in every workspace's ~/.grok/config.toml from
# var.grok_swarm_width, so the width a fleet runs at is a template decision. A
# --parameter given to `coder start`/`coder update`, or a --var pinned on the
# template, outlives the run that passed it: it persists in the Coder database,
# every later start reuses it, and no agent inside the workspace can clear it.
# The render then carries a
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
#   bazelisk run //scripts:subagent-check -- --all [--json] [--strict]
#
# The --all form is the host sweep: it enumerates every workspace container on
# this host's docker daemon, reads each container's own rendered profile, and
# judges the same pair this CLI judges for one file - max_concurrent against the
# `# fleet-width:` the render wrote above it. A workspace created before the
# template default moved keeps the width Coder stored for it, and no agent
# inside that workspace can see or clear it, so only a host run can find them.
# For each offender it prints the one `coder update` command that clears the
# stale stored parameter. Like scripts/branch-hygiene.sh it reports and never
# writes: no container is touched, and no coder command is run.
#
# Options (accepted anywhere in argv):
#   --all             sweep every workspace container on this host's daemon
#                     instead of reading one profile. Needs the docker CLI and
#                     only runs on the stack host: inside a workspace or the
#                     contributor dev container docker addresses that
#                     container's own sidecar. Refused with --config, which
#                     names a single path.
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
# The sweep prints "== subagent width sweep ==", then one "-> <workspace>
#   (<container>)" phase line and exactly one verdict line per workspace, then
#   the same closing summary. Under --json it prints one flat object per
#   workspace on stdout, in the key order workspace, owner, container, running,
#   max_concurrent, fleet_width, verdict, remedy - and nothing else on stdout.
# Exit codes: 0 with no failures (warnings allowed unless --strict), 1 with at
#   least one failure (or a warning under --strict), 2 on a usage error. An
#   empty daemon is not a failure: "no workspace containers on this daemon"
#   closes with "summary: 0 ok, 0 warnings, 0 failed" and exits 0.
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

# The --all sweep is the only path that touches the daemon, and it addresses it
# exactly the way the other daemon-facing CLIs do: stack_timeout bounds every
# call and DOCKER_BIN may hold more than one word. The single-profile path never
# calls either, so it still needs no network and no docker.
CODER_API_LIB="$(find_lib coder_api.sh "${REPO_ROOT_RESOLVED}")" || {
  printf 'error: subagent-check cannot run without its helpers: no scripts/lib/coder_api.sh above\n' >&2
  exit 1
}
# shellcheck source=lib/coder_api.sh disable=SC1091
source "${CODER_API_LIB}"

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
# SWEEP_* hold the workspace the current sweep row is about. They are globals
# rather than arguments because every profile reader the sweep reuses is
# CONFIG-driven, and judge_width and sweep_finish both need the same row.
# SWEEP_RUNNING carries the JSON literals true and false, or nothing for a
# state docker did not report; SWEEP_REMEDY carries the coder update command, or
# nothing for "nothing to fix", which sweep_finish prints as null; SWEEP_JSON
# accumulates one object per workspace for the --json printout.
SWEEP_TMP=""
SWEEP_WORKSPACE=""
SWEEP_OWNER=""
SWEEP_CONTAINER=""
SWEEP_RUNNING=""
SWEEP_VERDICT=""
SWEEP_REMEDY=""
SWEEP_JSON=""

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
       bazelisk run //scripts:subagent-check -- --all [--json] [--strict]

Proves the subagent width a session gets: the rendered max_concurrent against
the fleet width the same render wrote above it, the writers' lane in
[subagents.models], and max_depth. The default path reads one file; it needs no
network and no docker.

--all sweeps instead: every workspace container on this host's docker daemon,
each judged against the fleet-width its own render wrote, with the one coder
update command that clears a stale stored parameter printed per offender. That
path needs the docker CLI and only runs on the stack host - inside a workspace
or the contributor dev container docker addresses that container's own sidecar.
It reports and never writes.

Options: --config (default $HOME/.grok/config.toml), --parallel (the LiteLLM
PARALLEL each Spark box serves, the useful width on a pinned lane; default 5),
--all (the host sweep; refused with --config), --strict (a warning fails the
run), --json (one flat object on stdout, prose on stderr; under --all that is
one object per workspace), -h/--help.

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
  # The --json contract is one object on stdout and nothing beside it, and a
  # caller that pipes stdout straight into a parser cannot strip a usage block
  # it was never told to expect; -h/--help still answers on stdout.
  usage >&2
  exit 2
}

# @function profile_table
# Print the body of one top-level table of the profile - the lines between its
# header and the next one - so every reader below asks about one table instead
# of about the whole file. TOML lets an operator pad the brackets, indent the
# line, or end it with a comment, and all three name the same table, so the
# header is compared only after the padding, the brackets and the comment come
# off it. That exact comparison is the point: an unanchored veto keeps
# [subagents.models] inside [subagents], and a key in another table reported as
# this session's setting is precisely the confident wrong number this CLI must
# never print.
# Globals:
#   CONFIG
# Arguments:
#   $1 - the table to slice
# Outputs:
#   The table's lines on stdout, nothing when the file or the table is absent
# Returns:
#   0, always: a failing reader would reach the caller's assignment through
#   pipefail and abort a strict-mode script over a file that has no such table
profile_table() {
  local want="${1:-}"
  [ -n "${want}" ] && [ -r "${CONFIG}" ] || return 0
  awk -v want="${want}" '
    /^[[:space:]]*\[/ {
      header = $0
      sub(/[[:space:]]*#.*$/, "", header)
      sub(/^[[:space:]]+/, "", header)
      sub(/[[:space:]]+$/, "", header)
      sub(/^\[/, "", header)
      sub(/\]$/, "", header)
      sub(/^[[:space:]]+/, "", header)
      sub(/[[:space:]]+$/, "", header)
      inside = (header == want)
      next
    }
    inside { print }
  ' "${CONFIG}" 2>/dev/null
  return 0
}

# @function profile_has_table
# Succeed when the profile opens that table at all. The width phase needs this
# to tell "the table is missing" from "the table is there and carries no such
# line": the first is a profile that predates the render and wants a restart,
# the second is a hand edit that a restart will not fix, and telling an operator
# to restart for the wrong one of the two is how a session is burned.
# Globals:
#   CONFIG
# Arguments:
#   $1 - the table to look for
# Outputs:
#   Nothing; the exit status is the answer
# Returns:
#   0 when the header is there, 1 when it is not
profile_has_table() {
  local want="${1:-}" found=""
  [ -n "${want}" ] && [ -r "${CONFIG}" ] || return 1
  # The same header normaliser as profile_table, kept in its own awk program so
  # each reader stays readable; the test over both fixtures is what keeps the two
  # copies of the normalisation from drifting apart.
  found="$(awk -v want="${want}" '
    /^[[:space:]]*\[/ {
      header = $0
      sub(/[[:space:]]*#.*$/, "", header)
      sub(/^[[:space:]]+/, "", header)
      sub(/[[:space:]]+$/, "", header)
      sub(/^\[/, "", header)
      sub(/\]$/, "", header)
      sub(/^[[:space:]]+/, "", header)
      sub(/[[:space:]]+$/, "", header)
      if (header == want) { print "y"; exit }
    }
  ' "${CONFIG}" 2>/dev/null)" || found=""
  [ "${found}" = "y" ]
}

# @function profile_line
# Print the value of one key inside the [subagents] table, and nothing when the
# table or the key is absent. The trailing class is [[:space:]] rather than
# end-of-line so a CRLF profile still reads, and a trailing TOML comment is
# allowed because hand-narrowing the width for a pinned lane is the documented
# operator move and annotating it is normal. A leading + is accepted for the same
# reason: it is valid TOML for a positive integer.
# Globals:
#   CONFIG
# Arguments:
#   $1 - the key to read; a bare word, since it is interpolated into the sed
# Outputs:
#   The digits on stdout, nothing when the key is absent
# Returns:
#   0, always: a failing reader would reach the caller's assignment through
#   pipefail and abort a strict-mode script over a file that has no such key
profile_line() {
  local key="${1:-}" value=""
  # The key lands inside an s/// expression, so it stays a bare word: every
  # caller passes a literal today, and a key carrying the delimiter would turn a
  # reader into a sed syntax error instead of a clean nothing.
  case "${key}" in
    "" | *[!A-Za-z0-9_]*) return 0 ;;
  esac
  value="$(profile_table subagents |
    sed -nE "s/^[[:space:]]*\"?${key}\"?[[:space:]]*=[[:space:]]*\+?([0-9][0-9]*)([[:space:]]*#.*)?[[:space:]]*\$/\1/p" |
    head -n 1)" || value=""
  # A hand-edited profile can carry 04. JSON has no leading zeros, and a numeric
  # test reads one as octal and dies on 08, so the digits leave here canonical.
  value="$(printf '%s' "${value}" | sed 's/^0*\([0-9]\)/\1/')"
  printf '%s' "${value}"
}

# @function profile_int
# Print one integer key of the profile's [subagents] table, or nothing. The value
# is constrained to digits, so a commented-out or stringified value cannot read as
# a width.
# Globals:
#   CONFIG
# Arguments:
#   $1 - the key to read
# Outputs:
#   The integer on stdout, nothing when the key is absent
# Returns:
#   0, always (see profile_line for why a reader here never fails)
profile_int() {
  profile_line "${1:-}"
}

# @function profile_fleet_width
# Print the integer on the `# fleet-width:` comment the render writes on the line
# directly above max_concurrent, or nothing. It is read from that one position on
# purpose: scoping to the table was not enough, because a stray copy of the same
# comment earlier in the table otherwise beat the render's own line and this
# function then ordered the operator to set the width to a number nobody chose.
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
  value="$(profile_table subagents |
    awk '
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*max_concurrent[[:space:]]*=/ { print prev; exit }
      { prev = $0 }
    ' |
    sed -nE 's/^[[:space:]]*#[[:space:]]*fleet-width:[[:space:]]*([0-9][0-9]*)([[:space:]]*#.*)?[[:space:]]*$/\1/p' |
    head -n 1)" || value=""
  value="$(printf '%s' "${value}" | sed 's/^0*\([0-9]\)/\1/')"
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
  value="$(profile_table subagents.models |
    sed -nE 's/^[[:space:]]*"?general-purpose"?[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' |
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
  # A file that exists but cannot be read has to be said here, once. Every reader
  # below swallows its EACCES and answers "absent", which would otherwise leave
  # this run printing a restart order for a file a restart cannot reach.
  if [ ! -r "${CONFIG}" ]; then
    MARKER_JSON=""
    fail_item "${CONFIG} is not readable by this user - fix its mode, a restart cannot"
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
    # Two different states, two different remedies: a profile the render never
    # wrote wants a restart, and a profile whose table lost one line wants an edit.
    # Ordering a restart for the second is how an operator burns a session.
    if profile_has_table subagents; then
      warn "the [subagents] table carries no 'max_concurrent' line - a hand edit, which no restart undoes"
    else
      warn "no 'max_concurrent' line - this profile has no [subagents] table; restart the workspace to re-materialize"
    fi
    return 0
  fi
  if [ -z "${FLEET_WIDTH}" ]; then
    warn "no '# fleet-width:' line above max_concurrent - this profile predates it; restart the workspace to re-materialize"
    return 0
  fi
  # Both numbers go straight into an arithmetic test. The template caps the
  # parameter at 32, so digits this long are a typo or a corrupted file, and bash
  # would print an error and let both comparisons fall through to the ok branch -
  # reporting an absurd width as the state a fleet should ship with.
  if [ "${#MAX_CONCURRENT}" -gt 4 ] || [ "${#FLEET_WIDTH}" -gt 4 ]; then
    warn "max_concurrent = ${MAX_CONCURRENT} against fleet-width = ${FLEET_WIDTH} is not a width this stack can mean (the parameter is capped at 32)"
    return 0
  fi
  if [ "${MAX_CONCURRENT}" -lt "${FLEET_WIDTH}" ]; then
    warn "max_concurrent = ${MAX_CONCURRENT} is below the fleet width ${FLEET_WIDTH}"
    # <workspace> stays a placeholder: this CLI cannot know which workspace the
    # profile came from, and on the stack host one run addresses many. The width is
    # a Coder parameter, so the CLI flag is --parameter; --var belongs to
    # `coder templates push` alone. Which of the two stored values this is - the
    # workspace's or the template version's default - is not visible from inside
    # the container, so the note says where to look and makes the next run of this
    # check the proof, rather than promising an effect it cannot observe.
    note "a rendered width below fleet-width is a value that outlived its template - on the stack host: coder start <workspace> --parameter grok_subagent_max_concurrent=${FLEET_WIDTH} starts it wide once, and coder update <workspace> --parameter ... or the Variables tab keeps it there; if the number is the template version's own default, //scripts:push-template re-pushes it without one, since that script passes no fan-out width of its own. Re-run this check after the restart - the number moving is the proof."
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

# @function host_guard
# Refuse the sweep from any shell that cannot see the stack daemon. Inside a
# Coder workspace or the contributor dev container the docker CLI addresses that
# container's own DinD sidecar, so the sweep would judge one sidecar and call it
# the fleet; and a host with no docker CLI cannot enumerate anything at all.
# Both refusals name the run the operator actually needs rather than returning
# an empty report that reads like a clean fleet.
# Globals:
#   CODER_WORKSPACE_ID, EVO_T1_DEVCONTAINER
# Arguments:
#   None
# Outputs:
#   One "error: ..." line on stderr when the run is refused
# Returns:
#   0 when this shell can address the stack daemon; exits 1 when it cannot
host_guard() {
  if [ -n "${CODER_WORKSPACE_ID:-}" ] || [ "${EVO_T1_DEVCONTAINER:-}" = "1" ]; then
    die "subagent-check --all is a stack-host run: this shell's docker addresses its own sidecar"
  fi
  command -v docker >/dev/null 2>&1 ||
    die "cannot list workspace containers - the docker CLI is not on this host"
  return 0
}

# @function workspace_rows
# Print one "workspace<TAB>owner<TAB>container<TAB>state" line per workspace
# container on this host's daemon, across every compose project it holds. Three
# details are load-bearing. The query goes to the daemon by label and never
# through `docker compose ps`, because a compose call resolves a project from
# the cwd, and under `bazelisk run` that cwd is a runfiles copy whose directory
# name is no project anywhere. `-a` is here because a stopped workspace is one
# of the states this sweep reports - plain `docker ps` would never enumerate it
# and its stale width would go unreported. And the DinD sidecar carries the same
# coder.workspace_id label as the workspace it serves, so it is dropped on its
# own container name, the third column of this row.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT
# Arguments:
#   None
# Outputs:
#   Tab-separated rows on stdout; docker's own error text when the call fails
# Returns:
#   0 when the daemon answered, the command's status otherwise
workspace_rows() {
  local tab=$'\t'
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  stack_timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} ps -a \
    --filter label=coder.workspace_id \
    --format '{{.Label "coder.workspace_name"}}'"${tab}"'{{.Label "coder.owner"}}'"${tab}"'{{.Names}}'"${tab}"'{{.State}}' \
    </dev/null 2>&1 |
    awk -F'\t' '$3 !~ /-dind-sidecar$/ && $1 != ""'
}

# @function read_profile
# Print one container's rendered ~/.grok/config.toml. The cat runs inside the
# container and its own redirect swallows the missing-file noise, so what leaves
# here as an exit status is the answer to "does that container have a profile at
# all". The stdin and stderr redirects are what keep one unreachable container
# from stopping the sweep: docker exec -i waits for EOF on a pipe `bazelisk run`
# never closes, and stack_timeout only bounds the wait.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT
# Arguments:
#   $1 - container name
# Outputs:
#   The profile bytes on stdout, nothing when the container has none
# Returns:
#   The exec status: 0 with a profile, non-zero when the container is
#   unreachable or the file is absent
read_profile() {
  local container="${1:-}"
  [ -n "${container}" ] || return 1
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  stack_timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} exec "${container}" \
    sh -c 'cat "${HOME:-/home/coder}/.grok/config.toml" 2>/dev/null' sh \
    </dev/null 2>/dev/null
}

# @function judge_width
# The sweep's verdict for one container: whether the max_concurrent its own
# render wrote equals the `# fleet-width:` above it. It reuses the single-profile
# width phase's readers and the same stack-marker grep, so the two paths cannot
# disagree about what a number means - the finding here is the same finding, read
# off the workspace whose render produced it. Below width is the persisted
# --var this CLI exists to catch, and because the sweep knows the workspace and
# its owner from the container labels, the remedy names the one command that
# clears it instead of pointing at a placeholder.
# Globals:
#   CONFIG, STACK_MARKER, STACK_MARKER_TOML, SWEEP_WORKSPACE, SWEEP_OWNER,
#   SWEEP_CONTAINER, MAX_CONCURRENT, FLEET_WIDTH, SWEEP_VERDICT, SWEEP_REMEDY,
#   SUMMARY_OK
# Arguments:
#   $1 - the label for this container's verdict line, its container name
# Outputs:
#   Exactly one verdict line, plus the remedy note on the below-width path
# Returns:
#   0, always: one odd profile must not abort the sweep, and the counters
#   decide the exit code
judge_width() {
  local label="${1:-${SWEEP_CONTAINER:-}}"
  SWEEP_VERDICT=""
  SWEEP_REMEDY=""
  MAX_CONCURRENT=""
  FLEET_WIDTH=""
  if ! grep -qsF -e "${STACK_MARKER}" -e "${STACK_MARKER_TOML}" "${CONFIG}"; then
    warn "${label} carries neither stack marker"
    SWEEP_VERDICT="warning"
    return 0
  fi
  MAX_CONCURRENT="$(profile_int max_concurrent)"
  FLEET_WIDTH="$(profile_fleet_width)"
  # An unreadably long digit run is not a width this stack can mean (the
  # parameter is capped at 32) and it is not comparable either: bash errors on
  # it and lets both tests fall through, which would report a corrupted file as
  # the shipped state. It leaves as the hand edit it is, with the number left
  # unmeasured rather than printed as a width.
  if [ "${#MAX_CONCURRENT}" -gt 4 ] || [ "${#FLEET_WIDTH}" -gt 4 ]; then
    MAX_CONCURRENT=""
  fi
  if [ -z "${MAX_CONCURRENT}" ]; then
    # Two states, two remedies, same rule as the single-profile path: a profile
    # the render never wrote wants a restart, a table that lost one line wants
    # an edit, and ordering a restart for the second burns a session.
    if profile_has_table subagents; then
      warn "the [subagents] table carries no 'max_concurrent' line - a hand edit, which no restart undoes"
    else
      warn "no 'max_concurrent' line - this profile has no [subagents] table; restart the workspace to re-materialize"
    fi
    SWEEP_VERDICT="warning"
    return 0
  fi
  if [ -z "${FLEET_WIDTH}" ]; then
    warn "no '# fleet-width:' line above max_concurrent - this profile predates it; restart the workspace to re-materialize"
    SWEEP_VERDICT="warning"
    return 0
  fi
  if [ "${MAX_CONCURRENT}" -lt "${FLEET_WIDTH}" ]; then
    warn "max_concurrent = ${MAX_CONCURRENT} is below the fleet width ${FLEET_WIDTH}"
    # The width is a Coder parameter, so the flag is --parameter; --var belongs
    # to `coder templates push` alone. This prints the command and stops: like
    # scripts/branch-hygiene.sh, the report is the deliverable and nothing here
    # touches the workspace. Re-running this sweep after the update is the proof.
    SWEEP_REMEDY="coder update ${SWEEP_OWNER}/${SWEEP_WORKSPACE} --parameter grok_subagent_max_concurrent=${FLEET_WIDTH}"
    note "${SWEEP_REMEDY}"
    SWEEP_VERDICT="warning"
  elif [ "${MAX_CONCURRENT}" -gt "${FLEET_WIDTH}" ]; then
    note "max_concurrent = ${MAX_CONCURRENT} is above the fleet width ${FLEET_WIDTH} - past the fleet's streams the extra spawns queue in LiteLLM"
    # Counted with the ok items, as the single-profile path counts it: it is
    # commentary, not a fault. note() prints without counting, so the count is
    # made here rather than by bending the wording.
    SUMMARY_OK=$((${SUMMARY_OK:-0} + 1))
    SWEEP_VERDICT="ok"
  else
    ok "max_concurrent = ${MAX_CONCURRENT}, the fleet's own width"
    SWEEP_VERDICT="ok"
  fi
  return 0
}

# @function sweep_workspaces
# The host sweep itself: one row per workspace container, one phase line, and
# exactly one verdict each. Each container's profile lands in its own temp file
# under TMPDIR because every reader this reuses is CONFIG-driven, and reusing
# them is the point - a second parser is how the sweep and the single-profile
# path start disagreeing about the same number. One dead container is a warning
# row, never an aborted sweep, so the loop keeps going whatever one exec
# returns. The per-workspace JSON object is accumulated here and printed by
# sweep_finish, which alone owns stdout under --json.
# Globals:
#   CONFIG, DOCKER_BIN, PROBE_TIMEOUT, TMPDIR, SWEEP_TMP, SWEEP_WORKSPACE,
#   SWEEP_OWNER, SWEEP_CONTAINER, SWEEP_RUNNING, SWEEP_VERDICT, SWEEP_REMEDY,
#   SWEEP_JSON, MAX_CONCURRENT, FLEET_WIDTH, SUMMARY_OK, SUMMARY_WARN
# Arguments:
#   None
# Outputs:
#   One phase line and one verdict line per workspace container
# Returns:
#   0, always; exits 1 when the daemon itself would not answer at all
sweep_workspaces() {
  local rows="" rc=0 state=""
  rows="$(workspace_rows)" ||
    die "cannot list containers - is the docker daemon reachable from this host?"
  if [ -z "${rows}" ]; then
    note "no workspace containers on this daemon - nothing to sweep"
    return 0
  fi
  # One temp per workspace, created mode 600 and removed as each row finishes.
  # The trap covers the rows that leave the loop before their own cleanup, so an
  # aborted sweep leaves nothing behind.
  SWEEP_TMP=""
  trap 'rm -f "${SWEEP_TMP:-}"' EXIT
  while IFS=$'\t' read -r SWEEP_WORKSPACE SWEEP_OWNER SWEEP_CONTAINER state; do
    [ -n "${SWEEP_CONTAINER}" ] || continue
    phase "${SWEEP_WORKSPACE} (${SWEEP_CONTAINER})"
    SWEEP_RUNNING=""
    SWEEP_VERDICT=""
    SWEEP_REMEDY=""
    MAX_CONCURRENT=""
    FLEET_WIDTH=""
    rc=0
    if [ "${state}" = "running" ]; then
      SWEEP_RUNNING=true
    elif [ -n "${state}" ]; then
      SWEEP_RUNNING=false
    fi
    if [ "${SWEEP_RUNNING}" = "false" ]; then
      # No exec on a stopped container: its filesystem is there but its profile
      # answers nothing, and the width it will get on the next start comes from
      # the stored parameter, which is exactly what this sweep reports.
      warn "${SWEEP_CONTAINER} is stopped (exited) - its profile is unreachable and its width comes from the stored parameter"
      SWEEP_VERDICT="warning"
    else
      # mktemp, not a name built from $$: TMPDIR is shared on a host, and this
      # file holds another user's rendered profile for the length of one row.
      SWEEP_TMP="$(mktemp "${TMPDIR:-/tmp}/subagent-check.$$.XXXXXX")" ||
        die "cannot create a sweep temp file under ${TMPDIR:-/tmp}"
      read_profile "${SWEEP_CONTAINER}" >"${SWEEP_TMP}" 2>/dev/null || rc=$?
      CONFIG="${SWEEP_TMP}"
      if [ "${rc}" -ne 0 ] || [ ! -s "${CONFIG}" ]; then
        warn "no profile at /home/coder/.grok/config.toml in ${SWEEP_CONTAINER} - the boot render has not run"
        SWEEP_VERDICT="warning"
      else
        judge_width "${SWEEP_CONTAINER}"
      fi
      rm -f "${SWEEP_TMP}"
    fi
    # The newline is appended outside the command substitution because $( ) strips
    # a trailing one, and these lines are the whole stdout contract under --json.
    SWEEP_JSON="${SWEEP_JSON}$(printf '{"workspace":"%s","owner":"%s","container":"%s","running":%s,"max_concurrent":%s,"fleet_width":%s,"verdict":"%s","remedy":%s}' \
      "$(json_escape "${SWEEP_WORKSPACE}")" "$(json_escape "${SWEEP_OWNER}")" \
      "$(json_escape "${SWEEP_CONTAINER}")" "${SWEEP_RUNNING:-null}" \
      "$(json_value "${MAX_CONCURRENT}")" "$(json_value "${FLEET_WIDTH}")" \
      "${SWEEP_VERDICT:-warning}" "$(json_value "${SWEEP_REMEDY}")")"$'\n'
  done <<<"${rows}"
  SWEEP_TMP=""
  return 0
}

# @function sweep_finish
# Close the sweep: the per-workspace objects first, alone on stdout under
# --json, then the house summary and the exit code. Every verdict already
# counted its one item, so nothing here re-judges anything - this only reports
# and chooses the code, which is the same contract finish answers for the
# single-profile path.
# Globals:
#   JSON_MODE, STRICT, SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL, SWEEP_JSON
# Arguments:
#   None
# Outputs:
#   One flat JSON object per workspace on stdout under --json, then the summary
# Returns:
#   Nothing: exits 0, or 1 on a failure (or a warning under --strict)
sweep_finish() {
  local line=""
  if [ -n "${JSON_MODE:-}" ]; then
    while IFS= read -r line; do
      if [ -n "${line}" ]; then
        printf '%s\n' "${line}"
      fi
    done <<<"${SWEEP_JSON}"
  fi
  summary
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    exit 1
  fi
  if [ "${STRICT}" = "1" ] && [ "${SUMMARY_WARN:-0}" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

# @function main
# Parse argv, then take one of two paths: the four phases under one section for
# a single profile, or the host sweep for --all. The two share the readers, the
# counters, and the exit rule, and never each other's printout.
# Globals:
#   CONFIG, PARALLEL, STRICT, JSON_MODE, DEFAULT_PARALLEL, TMPDIR,
#   CODER_WORKSPACE_ID, EVO_T1_DEVCONTAINER
# Arguments:
#   "$@" - the command line
# Outputs:
#   The report on stdout (stderr under --json), or the usage block
# Returns:
#   0 clean or warned, 1 on failure, 2 on a usage error
main() {
  local config="" parallel="" strict=0 all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [ $# -ge 2 ] || usage_error "--config needs a path"
        config="$2"
        shift 2
        ;;
      --all)
        all=1
        shift
        ;;
      --parallel)
        [ $# -ge 2 ] || usage_error "--parallel needs a number"
        # Judged where it is taken rather than after the loop: a present-but-empty
        # argument is indistinguishable from an omitted one once it is parked in
        # the same variable, and would silently mean the default.
        [[ $2 =~ ^[1-9][0-9]*$ ]] ||
          usage_error "--parallel wants a whole number of streams per box"
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

  # --config names one path and --all judges every workspace, so the two cannot
  # describe one run. Judged after the loop because either flag may come first.
  if [ "${all}" = "1" ] && [ -n "${config}" ]; then
    usage_error "--all judges every workspace, not one path"
  fi

  CONFIG="${config:-${HOME:-/home/coder}/.grok/config.toml}"
  PARALLEL="${parallel:-${DEFAULT_PARALLEL}}"
  STRICT="${strict}"

  # The sweep path never reaches the four phases or finish: its exact printout is
  # its own contract, and the single-profile report below stays byte-identical.
  # It runs after the assignments above because sweep_finish reads STRICT.
  if [ "${all}" = "1" ]; then
    host_guard
    section "subagent width sweep"
    sweep_workspaces
    sweep_finish
  fi

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
