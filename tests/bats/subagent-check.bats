#!/usr/bin/env bats
#
# ## subagent-check.bats - hermetic coverage for scripts/subagent-check.sh
#
# The contract pinned here: the two numbers the render writes next to each other
# decide the verdict (equal is the shipped state, below is the persisted --var
# this CLI exists to catch, above is commentary that costs nothing), the writers'
# lane comes only from general-purpose inside [subagents.models], the exit code
# answers the same question the printout does (a failure is 1, a warning is 1 only
# under --strict, a usage error is its own code), and --json reports the eleven
# keys the prose just answered with. Nothing here reads anyone's real profile:
# every run gets a fixture under BATS_TEST_TMPDIR and an explicit --config, and
# HOME is pinned to the same scratch so the default path resolves to nothing.
#
# Usage: bazelisk test //tests:bats_subagent_check_test   (from any cwd)
# Safety: reads the script and scripts/lib/common.sh; writes only under the
# per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/subagent-check.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "subagent-check is not in the tree"
  fi
  # --config defaults to $HOME/.grok/config.toml, so HOME has to be the per-test
  # scratch or a run would judge the developer's own profile and print its width.
  export HOME="${BATS_TEST_TMPDIR}"
}

# write_profile <path> [width] [fleet] [lane] [marker] [depth] - the [subagents]
# block as templates/*/grok-config.toml.tftpl renders it, which is the pair this
# CLI reads: the `# fleet-width:` comment directly above max_concurrent, both fed
# from var.grok_swarm_width. Each argument takes `-` to mean "this file never got
# that line", which is how the missing-key branches get a fixture without a
# second helper per shape. marker takes 1 (the comment the render writes), key
# (only the plain TOML key, which is what survives the CLI rewriting the file) or
# 0 (no ownership marker at all).
write_profile() {
  local path="$1" width="${2:-15}" fleet="${3:-15}" lane="${4:-agent-swarm}"
  local marker="${5:-1}" depth="${6:-2}"
  {
    case "${marker}" in
      1) printf '# managed-by: evo-t1-coder-stack\n' ;;
      key) printf '__evoT1Stack = true\n' ;;
    esac
    printf '[subagents]\n'
    printf 'enabled = true\n'
    [ "${fleet}" = "-" ] || printf '# fleet-width: %s\n' "${fleet}"
    [ "${width}" = "-" ] || printf 'max_concurrent = %s\n' "${width}"
    [ "${depth}" = "-" ] || printf 'max_depth = %s\n' "${depth}"
    printf 'limit_behavior = "queue"\n'
    if [ "${lane}" != "-" ]; then
      printf '\n[subagents.models]\n'
      printf 'general-purpose = "%s"\n' "${lane}"
      printf 'explore = "agent-explore"\n'
      printf 'reviewer = "agent-review"\n'
    fi
  } >"${path}"
}

# run_check <config> [args...] - run the CLI the way an operator does, with HOME
# pinned so nothing reaches for a real profile.
run_check() {
  local config="$1"
  shift
  run env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${config}" "$@"
}

# check_stdout_only <config> [args...] - print only the CLI's stdout, so a test
# that judges the --json object can never be satisfied by a prose line that
# leaked onto the wrong channel.
check_stdout_only() {
  local config="$1"
  shift
  env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${config}" "$@" 2>/dev/null
}

# load_cli_functions <name...> - source the house vocabulary the phases call into
# and eval the named production functions into this test shell, with the CLI's
# own globals at the state main() would have left them in. A test that calls a
# phase directly reads the counters, so none of them may carry over from a
# previous call. common.sh defines its own skip, so this runs after every guard
# that would otherwise want the bats builtin.
load_cli_functions() {
  local name assign
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # The CLI's top-level string constants are what its helpers compare against, and
  # the extractor carries functions only, so each is read off the script itself
  # rather than restated here: a lane or a marker added in the CLI has to reach
  # these tests in the same commit, and cannot be quietly re-pinned to a copy.
  while IFS= read -r assign; do
    printf -v "${assign%%=*}" '%s' "${assign#*=}"
  done < <(sed -n 's/^\([A-Z_][A-Z0-9_]*\)="\(.*\)"$/\1=\2/p' "${SCRIPT}")
  for name in "$@"; do
    # The report vocabulary (phase/ok/warn/note/fail_item/summary) arrives with
    # common.sh above; only the CLI's own functions have to be pulled out of the
    # script, and asking for a name neither place defines stays a hard failure.
    if ! declare -F "${name}" >/dev/null; then
      load_shell_function "${SCRIPT}" "${name}"
    fi
  done
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  JSON_MODE="" STRICT=0 PARALLEL=5
  MARKER_JSON="" PINNED_JSON="" MAX_CONCURRENT="" FLEET_WIDTH=""
  WRITERS_LANE="" MAX_DEPTH=""
}

# -- the report an operator reads, end to end ------------------------------------

@test "subagent-check: the shipped pair reports the whole report, in order" {
  local cfg="${BATS_TEST_TMPDIR}/match.toml" expected
  write_profile "${cfg}" 15 15 agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  expected="$(printf '%s\n' \
    '' \
    '== subagent slots ==' \
    '-> the profile' \
    'ok: stack-managed (the startup render still owns this file)' \
    '-> the width' \
    "ok: max_concurrent = 15, the fleet's own width" \
    '-> the lanes' \
    'ok: writers ride agent-swarm (unpinned: least-busy spreads over every box)' \
    '-> the depth' \
    'note: max_depth = 2 (a depth-2 child holds a fleet stream too)' \
    'summary: 3 ok, 0 warnings, 0 failed')"
  assert_eq "the four phases and their verdicts are exactly the contract" \
    "${expected}" "${output}"
}

@test "subagent-check: a width below fleet-width warns and names both ways to clear it" {
  local cfg="${BATS_TEST_TMPDIR}/narrow.toml"
  write_profile "${cfg}" 4 15 agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the warning names both numbers" \
    'warning: max_concurrent = 4 is below the fleet width 15' "${output}"
  assert_match "the note calls it a value that outlived its template" \
    'a rendered width below fleet-width is a value that outlived its template' "${output}"
  assert_match "the note gives the workspace start that overrides it, at the fleet width" \
    'coder start <workspace> --parameter grok_subagent_max_concurrent=15' "${output}"
  # The remedy has to be a command that exists. `coder start` has no --var, and
  # //scripts:push-template accepts none from a caller either. What makes the
  # re-push half of the advice sound is that the script never names this
  # parameter at all, and that condition is pinned on its own two tests below
  # rather than asserted by this comment.
  assert_match "and the template-level alternative" '//scripts:push-template re-pushes it without one' "${output}"
  assert_match "and makes the next run the proof" 'Re-run this check after the restart' "${output}"
  assert_not_match "no --var is ever handed to coder start" 'coder start [^ ]* --var' "${output}"
  assert_match "the number moving is what it asks to be shown" 'the number moving is the proof' "${output}"
  assert_match "a narrow fleet is a warning, not a failure" '2 ok, 1 warnings, 0 failed' "${output}"
  assert_not_match "the width is not also reported as healthy" \
    "ok: max_concurrent = 4, the fleet's own width" "${output}"
}

@test "subagent-check: --strict promotes a narrow width to a failure without recounting it" {
  local cfg="${BATS_TEST_TMPDIR}/narrow.toml"
  write_profile "${cfg}" 4 15 agent-swarm 1 2

  run_check "${cfg}" --strict
  [ "${status}" -eq 1 ]
  assert_match "the same counts, now a non-zero exit" '2 ok, 1 warnings, 0 failed' "${output}"
  assert_match "the warning is still the finding" \
    'warning: max_concurrent = 4 is below the fleet width 15' "${output}"

  # The clean profile has nothing to promote, so --strict changes no exit code.
  write_profile "${BATS_TEST_TMPDIR}/match.toml" 15 15 agent-swarm 1 2
  run_check "${BATS_TEST_TMPDIR}/match.toml" --strict
  [ "${status}" -eq 0 ]
}

@test "subagent-check: a width above the fleet is commentary, not a fault" {
  local cfg="${BATS_TEST_TMPDIR}/above.toml"
  write_profile "${cfg}" 20 15 agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the note says where the extra spawns go" \
    'note: max_concurrent = 20 is above the fleet width 15 - past the fleet.s streams the extra spawns queue in LiteLLM' \
    "${output}"
  assert_match "nothing was counted as a warning or a failure" '2 ok, 0 warnings, 0 failed' "${output}"
  assert_not_match "above the fleet is never a warning" \
    'warning: max_concurrent = 20' "${output}"
}

@test "subagent-check: a profile with no fleet-width line says it predates it" {
  local cfg="${BATS_TEST_TMPDIR}/no-fleet-width.toml"
  write_profile "${cfg}" 4 - agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the warning is the contract's, verbatim" \
    "warning: no '# fleet-width:' line above max_concurrent - this profile predates it; restart the workspace to re-materialize" \
    "${output}"
  assert_match "and the width is not silently compared to nothing" '2 ok, 1 warnings, 0 failed' "${output}"
  assert_not_match "no below-width remedy without the number to compare against" \
    'a rendered width below fleet-width' "${output}"
}

@test "subagent-check: a profile with no max_concurrent line warns instead of guessing" {
  local cfg="${BATS_TEST_TMPDIR}/no-width.toml"
  write_profile "${cfg}" - 15 agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "it names the table that is there and the line that is not" \
    "warning: the \[subagents\] table carries no 'max_concurrent' line - a hand edit, which no restart undoes" "${output}"
  assert_not_match "and it does not order a restart for a hand edit" 'restart the workspace' "${output}"
  assert_match "no width verdict is printed for a width that is not there" \
    '2 ok, 1 warnings, 0 failed' "${output}"
}

@test "subagent-check: a width that is not an integer is no width at all" {
  # The render writes a bare integer. A stringified one is what a hand edit or a
  # CLI rewrite leaves behind, and reading it as 4 would report a width the
  # session never gets.
  local cfg="${BATS_TEST_TMPDIR}/stringified.toml"
  write_profile "${cfg}" 4 15 agent-swarm 1 2
  sed -i 's/^max_concurrent = 4$/max_concurrent = "4"/' "${cfg}"

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the quoted value does not read as a width" \
    "the \[subagents\] table carries no 'max_concurrent' line" "${output}"
  assert_not_match "and nothing claims a width of 4" 'max_concurrent = 4' "${output}"
}

@test "subagent-check: writers on a pinned alias warn, with the fan-out remedy" {
  local cfg="${BATS_TEST_TMPDIR}/pinned.toml"
  write_profile "${cfg}" 15 15 agent 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the warning names the lane and the width that actually binds" \
    'warning: writers ride agent \(session-pinned: one box.s PARALLEL 5 is the useful width\)' \
    "${output}"
  assert_match "the note names the --var that lifts the pin" \
    'note: --var grok_subagents_lane=agent-swarm puts a fan-out on every box' "${output}"
  assert_match "it is a warning, so the run still exits clean" '2 ok, 1 warnings, 0 failed' "${output}"
}

@test "subagent-check: --parallel is the number a pinned lane is measured against" {
  local cfg="${BATS_TEST_TMPDIR}/pinned.toml"
  write_profile "${cfg}" 15 15 agent 1 2

  run_check "${cfg}" --parallel 4
  [ "${status}" -eq 0 ]
  assert_match "the recipe default is replaced" \
    'writers ride agent \(session-pinned: one box.s PARALLEL 4 is the useful width\)' "${output}"
  assert_not_match "and the default 5 does not also print" 'PARALLEL 5' "${output}"

  # An unpinned lane is measured against the fleet, so PARALLEL is not in its text
  # at all: the box count is what bounds that fan-out, not one box's streams.
  write_profile "${BATS_TEST_TMPDIR}/swarm.toml" 15 15 agent-swarm 1 2
  run_check "${BATS_TEST_TMPDIR}/swarm.toml" --parallel 4
  [ "${status}" -eq 0 ]
  assert_not_match "the unpinned verdict carries no PARALLEL" 'PARALLEL' "${output}"
}

@test "subagent-check: every pin-lifted alias is an ok that names itself" {
  local cfg lane
  for lane in agent-swarm agent-explore agent-review agent-swarm-fast; do
    cfg="${BATS_TEST_TMPDIR}/lane-${lane}.toml"
    write_profile "${cfg}" 15 15 "${lane}" 1 2

    run_check "${cfg}"
    [ "${status}" -eq 0 ]
    assert_match "${lane} is judged unpinned" \
      "ok: writers ride ${lane} \(unpinned: least-busy spreads over every box\)" "${output}"
    assert_match "${lane} costs no warning" '3 ok, 0 warnings, 0 failed' "${output}"
    assert_not_match "no remedy printed for an unpinned lane" 'grok_subagents_lane=' "${output}"
  done
}

@test "subagent-check: no models block leaves the writers on the parent's model" {
  local cfg="${BATS_TEST_TMPDIR}/no-models.toml"
  write_profile "${cfg}" 15 15 - 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the missing pin is the same warning shape" \
    "warning: writers ride the parent's model \(session-pinned: one box.s PARALLEL 5 is the useful width\)" \
    "${output}"
  assert_match "with the same remedy" 'grok_subagents_lane=agent-swarm' "${output}"
}

@test "subagent-check: only general-purpose in [subagents.models] is the writers' lane" {
  # The decoy is the line the reader must ignore: a general-purpose outside the
  # models table pins nothing, and reading it would report an unpinned fan-out for
  # a session whose writers inherit the parent's model.
  local cfg="${BATS_TEST_TMPDIR}/decoy.toml"
  write_profile "${cfg}" 15 15 - 1 2
  {
    printf '\n[model."agent-swarm"]\n'
    printf 'general-purpose = "agent-swarm"\n'
  } >>"${cfg}"

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the decoy does not read as a pin" "writers ride the parent's model" "${output}"
  assert_not_match "no unpinned ok from another table" 'writers ride agent-swarm \(unpinned' "${output}"
}

@test "subagent-check: a profile with neither stack marker is a failure that keeps talking" {
  local cfg="${BATS_TEST_TMPDIR}/foreign.toml"
  write_profile "${cfg}" 15 15 agent-swarm 0 2

  run_check "${cfg}"
  [ "${status}" -eq 1 ]
  assert_match "it names the file and what is missing" \
    "error: ${cfg} carries neither stack marker" "${output}"
  assert_match "the failed item is echoed under the summary" \
    '  failed: '"${cfg}"' carries neither stack marker' "${output}"
  # The run keeps going: the operator still sees what the unowned file says, which
  # is the point of judging a file the render no longer reaches.
  assert_match "the width is still read" "ok: max_concurrent = 15, the fleet's own width" "${output}"
  assert_match "the lane is still read" 'writers ride agent-swarm' "${output}"
  assert_match "and the depth too" 'note: max_depth = 2' "${output}"
  assert_match "one failure, the rest still judged" '2 ok, 0 warnings, 1 failed' "${output}"
}

@test "subagent-check: the TOML key alone counts as stack ownership" {
  local cfg="${BATS_TEST_TMPDIR}/key-only.toml"
  write_profile "${cfg}" 15 15 agent-swarm key 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the plain key is the second spelling of ownership" \
    'ok: stack-managed \(the startup render still owns this file\)' "${output}"
  assert_not_match "no marker failure" 'carries neither stack marker' "${output}"
}

@test "subagent-check: no profile at all stops the run and says where it looked" {
  run_check "${BATS_TEST_TMPDIR}/absent.toml"
  [ "${status}" -eq 1 ]
  assert_match "the error names the path" \
    'error: no profile at '"${BATS_TEST_TMPDIR}"'/absent.toml' "${output}"
  assert_match "and the run still summarizes" 'summary: 0 ok, 0 warnings, 1 failed' "${output}"
  # The three later phases read that file, so printing their headers would claim a
  # verdict about a profile this run never opened.
  assert_not_match "the width phase never runs" '-> the width' "${output}"
  assert_not_match "nor the lanes phase" '-> the lanes' "${output}"
  assert_not_match "nor the depth phase" '-> the depth' "${output}"
  assert_not_match "a missing file is not called unmanaged" 'carries neither stack marker' "${output}"
}

@test "subagent-check: the default config path is the one under the pinned HOME" {
  local cfg="${BATS_TEST_TMPDIR}/.grok/config.toml"
  mkdir -p "${BATS_TEST_TMPDIR}/.grok"
  write_profile "${cfg}" 15 15 agent-swarm 1 2

  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_match "HOME is what decides the default, so the fixture was the file read" \
    "ok: max_concurrent = 15, the fleet's own width" "${output}"

  # Nothing at that path is the state an operator on an unrendered home hits, and
  # it is the one failure that must not be confused with an unowned file.
  rm -f "${cfg}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  assert_match "it says no profile at that default" 'error: no profile at ' "${output}"
}

# -- the machine-readable channel --------------------------------------------------

@test "subagent-check: --json is exactly one object carrying the eleven pinned keys" {
  local cfg="${BATS_TEST_TMPDIR}/narrow.toml" stdout lines keys verdict

  write_profile "${cfg}" 4 15 agent-swarm 1 2
  stdout="$(check_stdout_only "${cfg}" --json)"
  lines="$(printf '%s\n' "${stdout}" | grep -c .)"
  assert_eq "stdout is one line and nothing else" "1" "${lines}"
  printf '%s\n' "${stdout}" | python3 -m json.tool >/dev/null

  keys="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(",".join(sorted(d)))')"
  assert_eq "the key set is exactly the contract's, with nothing beside it" \
    "config,failed,fleet_width,marker,max_concurrent,max_depth,ok,pinned,verdict,warnings,writers_lane" \
    "${keys}"

  verdict="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
flat = all(not isinstance(v, (dict, list)) for v in d.values())
print("%s|%s|%s|%s|%s|%s|%s" % (
    flat, d["marker"], d["max_concurrent"], d["fleet_width"],
    d["writers_lane"], d["pinned"], d["verdict"]))')"
  assert_eq "flat object, the two booleans, the two integers, the lane, the verdict" \
    "True|True|4|15|agent-swarm|False|warning" "${verdict}"
}

@test "subagent-check: --json counts are the counts the prose printed" {
  local cfg="${BATS_TEST_TMPDIR}/narrow.toml" json summary_line counts rc

  write_profile "${cfg}" 4 15 agent 1 2
  json="$(check_stdout_only "${cfg}" --json)"
  summary_line="$(env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${cfg}" |
    grep '^summary: ')"
  counts="$(printf '%s\n' "${json}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("%d ok, %d warnings, %d failed" % (d["ok"], d["warnings"], d["failed"]))')"
  assert_eq "the object answers with the same three numbers" "${summary_line#summary: }" "${counts}"

  # The prose moves to stderr under --json rather than vanishing, so an operator
  # reading the object still gets the remedy text.
  rc=0
  env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${cfg}" --json \
    >"${BATS_TEST_TMPDIR}/json.out" 2>"${BATS_TEST_TMPDIR}/json.err" || rc=$?
  assert_eq "a warning is not a failure without --strict" "0" "${rc}"
  assert_contains_file "the section heading went to stderr" "${BATS_TEST_TMPDIR}/json.err" \
    '== subagent slots =='
  assert_contains_file "and so did the remedy note" "${BATS_TEST_TMPDIR}/json.err" \
    'grok_subagents_lane=agent-swarm'
  assert_not_match "stdout carries no prose" '==' "$(cat "${BATS_TEST_TMPDIR}/json.out")"
}

@test "subagent-check: --json nulls what a missing profile never let it measure" {
  local stdout verdict
  stdout="$(check_stdout_only "${BATS_TEST_TMPDIR}/absent.toml" --json)" || true

  printf '%s\n' "${stdout}" | python3 -m json.tool >/dev/null
  verdict="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("%s|%s|%s|%s|%s|%d" % (
    d["marker"], d["max_concurrent"], d["fleet_width"],
    d["writers_lane"], d["verdict"], d["failed"]))')"
  assert_eq "never measured is null, not zero and not an empty string" \
    "None|None|None|None|error|1" "${verdict}"

  run_check "${BATS_TEST_TMPDIR}/absent.toml" --json
  [ "${status}" -eq 1 ]
}

@test "subagent-check: the unmanaged profile is an error verdict in json too" {
  local cfg="${BATS_TEST_TMPDIR}/foreign.toml" verdict
  write_profile "${cfg}" 15 15 agent-swarm 0 2

  verdict="$(check_stdout_only "${cfg}" --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("%s|%s|%s|%d" % (d["marker"], d["verdict"], d["config"], d["failed"]))')"
  assert_eq "marker false, error verdict, the path it read echoed back" \
    "False|error|${cfg}|1" "${verdict}"
}

# -- argv and the exit codes that answer for it ------------------------------------

@test "subagent-check: --help prints the usage block and exits 0" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "the usage line names the Bazel entry point" \
    'usage: bazelisk run //scripts:subagent-check' "${output}"
  assert_match "names the config flag" '--config' "${output}"
  assert_match "names the parallel flag and what it is" 'PARALLEL' "${output}"
  assert_match "names strict" '--strict' "${output}"
  assert_match "names the exit codes" '2 on a usage error' "${output}"

  run bash "${SCRIPT}" -h
  [ "${status}" -eq 0 ]
  assert_match "the short form is the same block" 'usage: bazelisk run //scripts:subagent-check' "${output}"
}

@test "subagent-check: an unknown option is a usage error, not a result" {
  run bash "${SCRIPT}" --bogus
  [ "${status}" -eq 2 ]
  assert_match "names the flag that is not one" 'error: unknown option: --bogus' "${output}"
  assert_match "and prints the block so the fix is visible" \
    'usage: bazelisk run //scripts:subagent-check' "${output}"
  assert_not_match "a usage error never reports a width" 'max_concurrent = ' "${output}"
}

@test "subagent-check: a missing or malformed option value is a usage error" {
  run bash "${SCRIPT}" --config
  [ "${status}" -eq 2 ]
  assert_match "complains about the path" '--config needs a path' "${output}"

  run bash "${SCRIPT}" --parallel
  [ "${status}" -eq 2 ]
  assert_match "complains about the number" '--parallel needs a number' "${output}"

  run bash "${SCRIPT}" --parallel abc
  [ "${status}" -eq 2 ]
  assert_match "rejects a width that is not a whole number" \
    '--parallel wants a whole number of streams per box' "${output}"

  # Zero is not a narrower fleet, it is a typo: it would make every pinned-lane
  # warning claim a useful width of zero.
  run bash "${SCRIPT}" --parallel 0
  [ "${status}" -eq 2 ]
  assert_match "zero is refused, not obeyed" '--parallel wants a whole number' "${output}"
}

@test "subagent-check: options are accepted in any order and after the config" {
  local cfg="${BATS_TEST_TMPDIR}/narrow.toml"
  write_profile "${cfg}" 4 15 agent 1 2

  run bash "${SCRIPT}" --strict --config "${cfg}" --parallel 3
  [ "${status}" -eq 1 ]
  assert_match "strict took effect whatever the order" '2 warnings' "${output}"
  assert_match "so did parallel" 'PARALLEL 3' "${output}"

  # --json is order-independent the same way, and its object carries the same
  # counters the prose just did -- the pair is what proves the parser stored the
  # flags rather than merely accepting them.
  local json
  json="$(env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${cfg}" --strict --json --parallel 3 2>/dev/null || true)"
  assert_match "the reordered --json run reports the same warning count" \
    '"warnings":2' "${json}"
}

# -- the pieces the CLI is built from, tested where they are defined ---------------
#
# The runs above prove the exit code and the printout; these pin the helpers that
# decide *what* an operator reads: where the root and the helpers come from, what
# counts as a width line, which alias counts as unpinned, and what each phase
# counts.

@test "subagent-check: resolve_repo_root prints the first candidate holding the marker" {
  local root="${BATS_TEST_TMPDIR}/root" out
  mkdir -p "${root}/scripts/lib"
  : >"${root}/docker-compose.yml"
  load_cli_functions profile_table profile_has_table resolve_repo_root

  out="$(REPO_ROOT="${root}" GITHUB_WORKSPACE="" SELF_DIR="${root}" resolve_repo_root)"
  assert_eq "an explicit REPO_ROOT wins" "${root}" "${out}"
  out="$(REPO_ROOT="" GITHUB_WORKSPACE="${root}" SELF_DIR="${root}" resolve_repo_root)"
  assert_eq "CI's workspace variable is the next candidate" "${root}" "${out}"

  # No candidate holds the marker: the run has to say which places it tried rather
  # than guess a root and read a profile off a sandbox tree.
  local empty="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "${empty}/lib"
  local rc=0
  out="$( (cd "${empty}" && REPO_ROOT="" GITHUB_WORKSPACE="" SELF_DIR="${empty}" \
    resolve_repo_root 2>&1) )" || rc=$?
  assert_eq "an unresolvable root is its own return code" "5" "${rc}"
  assert_match "and it names the candidates it tried" \
    'unresolvable repo root: no proven checkout in' "${out}"
  assert_match "it says what a root has to hold" 'need docker-compose.yml' "${out}"
}

@test "subagent-check: find_lib reaches a helper from the root or from its own directory" {
  local root="${BATS_TEST_TMPDIR}/libroot" out rc=0
  mkdir -p "${root}/scripts/lib" "${root}/self"
  printf '#!/usr/bin/env bash\n' >"${root}/scripts/lib/common.sh"
  load_cli_functions profile_table profile_has_table find_lib

  out="$(find_lib common.sh "${root}")"
  assert_eq "the resolved root is the first place it looks" \
    "${root}/scripts/lib/common.sh" "${out}"

  # The runfiles copy: no root, only this script's own directory beside it.
  mkdir -p "${root}/self/lib"
  printf '#!/usr/bin/env bash\n' >"${root}/self/lib/spark.sh"
  SELF_DIR="${root}/self"
  out="$(find_lib spark.sh "")"
  assert_eq "SELF_DIR/lib is the fallback" "${root}/self/lib/spark.sh" "${out}"

  out="$(find_lib nowhere.sh "${root}" 2>&1)" || rc=$?
  assert_eq "a helper that is not there is not found" "1" "${rc}"
  assert_match "and the complaint names both places it tried" \
    'nowhere.sh is not reachable from' "${out}"
}

@test "subagent-check: profile_int reads only an anchored integer line" {
  local cfg="${BATS_TEST_TMPDIR}/int.toml"
  write_profile "${cfg}" 15 15 agent-swarm 1 2
  # profile_int is the public name and profile_line the reader it delegates to;
  # a test that loads only the first gets a 127 and an empty answer.
  load_cli_functions profile_table profile_has_table profile_line profile_int
  CONFIG="${cfg}"

  assert_eq "the rendered width reads" "15" "$(profile_int max_concurrent)"
  assert_eq "so does the depth" "2" "$(profile_int max_depth)"
  assert_eq "a key the file does not carry is nothing" "" "$(profile_int no_such_key)"

  {
    printf '# max_concurrent = 9\n'
    printf '   max_concurrent = 8\n'
    printf 'max_concurrent = "7"\n'
    printf 'max_concurrent = 6x\n'
  } >>"${cfg}"
  CONFIG="${BATS_TEST_TMPDIR}/commented.toml"
  {
    printf '# max_concurrent = 9\n'
    printf '   max_concurrent = 8\n'
    printf 'max_concurrent = "7"\n'
    printf 'max_concurrent = 6x\n'
  } >"${CONFIG}"
  assert_eq "a comment, an indent, a quote or a suffix is not a width" "" "$(profile_int max_concurrent)"

  CONFIG="${cfg}/absent"
  assert_eq "a file that is not there reads as nothing, not an error" "" "$(profile_int max_concurrent)"
}

@test "subagent-check: profile_fleet_width reads only the render's own comment" {
  local cfg="${BATS_TEST_TMPDIR}/fleet.toml"
  write_profile "${cfg}" 4 15 agent-swarm 1 2
  load_cli_functions profile_table profile_has_table profile_fleet_width
  CONFIG="${cfg}"

  assert_eq "the line the render writes above the width is the fleet width" \
    "15" "$(profile_fleet_width)"

  CONFIG="${BATS_TEST_TMPDIR}/near-misses.toml"
  {
    printf '#fleet-width: 9\n'
    printf '## fleet-width: 8\n'
    printf '# fleet-width: fifteen\n'
    printf '# fleet-width: 7 (the Arc)\n'
  } >"${CONFIG}"
  assert_eq "a comment that is not the render's shape is no fleet width" \
    "" "$(profile_fleet_width)"

  CONFIG="${cfg}/absent"
  assert_eq "an absent profile has no fleet width either" "" "$(profile_fleet_width)"
}

@test "subagent-check: profile_writers_lane is scoped to [subagents.models]" {
  local cfg="${BATS_TEST_TMPDIR}/lane.toml" other="${BATS_TEST_TMPDIR}/other.toml"
  write_profile "${cfg}" 15 15 agent-swarm 1 2
  load_cli_functions profile_table profile_has_table profile_writers_lane
  CONFIG="${cfg}"

  assert_eq "general-purpose in the models table is the writers' lane" \
    "agent-swarm" "$(profile_writers_lane)"

  {
    printf '[model."agent-swarm"]\n'
    printf 'general-purpose = "elsewhere"\n'
  } >"${other}"
  CONFIG="${other}"
  assert_eq "the same key in another table pins nothing" "" "$(profile_writers_lane)"

  {
    printf '[subagents.models]\n'
    printf 'general-purpose = "agent-swarm"\n'
    printf '[subagents]\n'
    printf 'general-purpose = "shadowed"\n'
  } >"${other}"
  CONFIG="${other}"
  assert_eq "and the reader stops at the next table" "agent-swarm" "$(profile_writers_lane)"

  CONFIG="${cfg}/absent"
  assert_eq "an absent profile pins nothing" "" "$(profile_writers_lane)"
}

@test "subagent-check: is_unpinned_lane accepts exactly the four aliases the proxy lifts" {
  local lane
  load_cli_functions profile_table profile_has_table is_unpinned_lane

  for lane in agent-swarm agent-explore agent-review agent-swarm-fast; do
    is_unpinned_lane "${lane}"
    assert_eq "${lane} is pin-lifted" "0" "$?"
  done
  for lane in agent agent-low agent-medium agent-xhigh chat '' agent-swarm-other; do
    if is_unpinned_lane "${lane}"; then
      return 1
    fi
  done
}

@test "subagent-check: check_profile counts a missing file as a failure and stops" {
  local out="${BATS_TEST_TMPDIR}/profile.out" rc=0
  load_cli_functions profile_table profile_has_table phase ok fail_item check_profile
  CONFIG="${BATS_TEST_TMPDIR}/absent.toml"

  check_profile >"${out}" 2>&1 || rc=$?
  assert_eq "the caller is told there is nothing to read" "1" "${rc}"
  assert_contains_file "it opened the profile phase" "${out}" '-> the profile'
  assert_contains_file "and named the path it looked at" "${out}" 'error: no profile at '
  assert_eq "one failure, nothing else" "1" "${SUMMARY_FAIL}"
  assert_eq "and no verdict about a marker it never got to read" "" "${MARKER_JSON}"

  CONFIG="${BATS_TEST_TMPDIR}/foreign.toml"
  write_profile "${CONFIG}" 15 15 agent-swarm 0 2
  SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS="" rc=0
  check_profile >"${out}" 2>&1 || rc=$?
  assert_eq "an unowned file is judged but still readable" "0" "${rc}"
  assert_eq "and it is the failure that carries the exit code" "1" "${SUMMARY_FAIL}"
  assert_eq "the object reports the marker it did not find" "false" "${MARKER_JSON}"
}

@test "subagent-check: check_width counts the pair it read" {
  local out="${BATS_TEST_TMPDIR}/width.out"
  load_cli_functions profile_table profile_has_table phase ok warn note profile_line profile_int profile_fleet_width check_width

  CONFIG="${BATS_TEST_TMPDIR}/match.toml"
  write_profile "${CONFIG}" 15 15 agent-swarm 1 2
  check_width >"${out}" 2>&1
  assert_contains_file "equal is the shipped state" "${out}" \
    "ok: max_concurrent = 15, the fleet's own width"
  assert_eq "and it is an ok" "1" "${SUMMARY_OK}"

  SUMMARY_OK=0
  CONFIG="${BATS_TEST_TMPDIR}/narrow.toml"
  write_profile "${CONFIG}" 4 15 agent-swarm 1 2
  check_width >"${out}" 2>&1
  assert_contains_file "below is a warning" "${out}" \
    'warning: max_concurrent = 4 is below the fleet width 15'
  assert_eq "one warning" "1" "${SUMMARY_WARN}"
  assert_eq "the pair it read is what the object will carry" "4" "${MAX_CONCURRENT}"
  assert_eq "both of them" "15" "${FLEET_WIDTH}"

  SUMMARY_WARN=0
  CONFIG="${BATS_TEST_TMPDIR}/above.toml"
  write_profile "${CONFIG}" 20 15 agent-swarm 1 2
  check_width >"${out}" 2>&1
  assert_contains_file "above is a note, which counts for nothing" "${out}" \
    'note: max_concurrent = 20 is above the fleet width 15'
  assert_eq "no warning was counted" "0" "${SUMMARY_WARN}"
}

@test "subagent-check: check_lanes sets the pinned flag the object answers with" {
  local out="${BATS_TEST_TMPDIR}/lanes.out"
  load_cli_functions profile_table profile_has_table phase ok warn note profile_writers_lane is_unpinned_lane check_lanes

  CONFIG="${BATS_TEST_TMPDIR}/pinned.toml"
  write_profile "${CONFIG}" 15 15 agent 1 2
  check_lanes >"${out}" 2>&1
  assert_contains_file "a pinned lane is a warning" "${out}" \
    'warning: writers ride agent \(session-pinned'
  assert_eq "and the object says pinned" "true" "${PINNED_JSON}"
  assert_eq "one warning" "1" "${SUMMARY_WARN}"

  SUMMARY_WARN=0
  CONFIG="${BATS_TEST_TMPDIR}/swarm.toml"
  write_profile "${CONFIG}" 15 15 agent-swarm 1 2
  check_lanes >"${out}" 2>&1
  assert_contains_file "an unpinned lane is an ok" "${out}" \
    'ok: writers ride agent-swarm \(unpinned'
  assert_eq "and the object says not pinned" "false" "${PINNED_JSON}"
  assert_eq "nothing counted as a warning" "0" "${SUMMARY_WARN}"
  assert_eq "the lane it read is the lane it prints" "agent-swarm" "${WRITERS_LANE}"

  SUMMARY_WARN=0
  CONFIG="${BATS_TEST_TMPDIR}/no-models.toml"
  write_profile "${CONFIG}" 15 15 - 1 2
  check_lanes >"${out}" 2>&1
  assert_contains_file "no pin at all is pinned, because the writers inherit the parent" "${out}" \
    "warning: writers ride the parent's model"
  assert_eq "and the object says pinned" "true" "${PINNED_JSON}"
}

@test "subagent-check: check_depth reports a depth and stays silent without one" {
  local out="${BATS_TEST_TMPDIR}/depth.out"
  load_cli_functions profile_table profile_has_table phase note profile_line profile_int check_depth

  CONFIG="${BATS_TEST_TMPDIR}/depth.toml"
  write_profile "${CONFIG}" 15 15 agent-swarm 1 2
  check_depth >"${out}" 2>&1
  assert_contains_file "a stated depth is a note" "${out}" \
    'note: max_depth = 2 \(a depth-2 child holds a fleet stream too\)'
  assert_eq "a depth costs no verdict" "0" "${SUMMARY_WARN}"

  CONFIG="${BATS_TEST_TMPDIR}/no-depth.toml"
  write_profile "${CONFIG}" 15 15 agent-swarm 1 -
  : >"${out}"
  check_depth >"${out}" 2>&1
  assert_contains_file "the phase line still prints" "${out}" '-> the depth'
  assert_not_match "and nothing else prints for a key the file omits" 'max_depth = ' \
    "$(cat "${out}")"
  assert_eq "nothing was measured" "" "${MAX_DEPTH}"
}

@test "subagent-check: finish decides the exit code from the counters, both channels" {
  local out rc=0
  load_cli_functions profile_table profile_has_table summary finish

  SUMMARY_OK=3 SUMMARY_WARN=1 SUMMARY_FAIL=0
  out="$( (finish) 2>&1)" || rc=$?
  assert_eq "a warning alone is clean" "0" "${rc}"
  assert_match "with the counts" 'summary: 3 ok, 1 warnings, 0 failed' "${out}"

  SUMMARY_FAIL=1
  SUMMARY_FAIL_ITEMS="the profile carries neither stack marker"
  rc=0
  out="$( (finish) 2>&1)" || rc=$?
  assert_eq "a failure is a non-zero exit" "1" "${rc}"
  assert_match "and the item is echoed for a human skimming the log" \
    '  failed: the profile carries neither stack marker' "${out}"

  SUMMARY_FAIL=0
  SUMMARY_FAIL_ITEMS=""
  STRICT=1
  rc=0
  out="$( (finish) 2>&1)" || rc=$?
  assert_eq "under --strict a warning is the same non-zero answer" "1" "${rc}"
  STRICT=0

  # The json channel: one object on stdout, the prose on stderr, the same verdict
  # both printouts just answered with.
  JSON_MODE=1
  rc=0
  out="$( (finish >"${BATS_TEST_TMPDIR}/f.out" 2>"${BATS_TEST_TMPDIR}/f.err") )" || rc=$?
  assert_eq "a warning under --json is still clean" "0" "${rc}"
  assert_contains_file "the object is on stdout" "${BATS_TEST_TMPDIR}/f.out" '"verdict":"warning"'
  assert_not_match "and the summary is not" 'summary: ' "$(cat "${BATS_TEST_TMPDIR}/f.out")"
  assert_contains_file "the summary went to stderr" "${BATS_TEST_TMPDIR}/f.err" \
    'summary: 3 ok, 1 warnings, 0 failed'
}

@test "subagent-check: usage_error complains, prints the block, and exits 2" {
  local out rc=0
  load_cli_functions profile_table profile_has_table usage usage_error

  out="$( (usage) 2>&1)"
  assert_match "the block stands on its own" 'usage: bazelisk run //scripts:subagent-check' "${out}"
  assert_match "and states the exit codes" '2 on a usage error' "${out}"

  out="$( (usage_error 'unknown option: --nope' 2>&1) )" || rc=$?
  assert_eq "a usage error is its own exit code" "2" "${rc}"
  assert_match "the complaint comes first" 'error: unknown option: --nope' "${out}"
  assert_match "with the block under it" 'Options: --config' "${out}"
}

# -- the profiles that fooled it once ------------------------------------------------
#
# Each case here is a file a person can honestly hand the CLI, found by attacking the
# readers rather than by reading them. They are kept because every one of them used to
# print a confident wrong answer -- a bad diagnosis, a number from another table, or a
# --json object no parser accepts.

@test "subagent-check: a leading zero is read as the number it means" {
  local cfg="${BATS_TEST_TMPDIR}/leading-zero.toml" stdout
  write_profile "${cfg}" 04 15 agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the width is the number, not the digits" \
    'warning: max_concurrent = 4 is below the fleet width 15' "${output}"
  assert_not_match "and it is not also reported as healthy by an octal misread" \
    '04' "${output}"

  # 08 is the case a numeric test dies on when the digits are not canonicalised.
  write_profile "${cfg}" 08 15 agent-swarm 1 2
  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "a zero no digit can read as octal still compares" \
    'warning: max_concurrent = 8 is below the fleet width 15' "${output}"

  stdout="$(check_stdout_only "${cfg}" --json)"
  printf '%s\n' "${stdout}" | python3 -m json.tool >/dev/null
  assert_match "and the object carries a JSON integer" '"max_concurrent":8' "${stdout}"
}

@test "subagent-check: a CRLF profile is judged on its width, not called a missing table" {
  local cfg="${BATS_TEST_TMPDIR}/crlf.toml"
  printf '# managed-by: evo-t1-coder-stack\r\n[subagents]\r\nenabled = true\r\n# fleet-width: 15\r\nmax_concurrent = 4\r\nmax_depth = 2\r\n\r\n[subagents.models]\r\ngeneral-purpose = "agent-swarm"\r\n' \
    >"${cfg}"

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the width is read despite the carriage returns" \
    'warning: max_concurrent = 4 is below the fleet width 15' "${output}"
  assert_not_match "the profile is not dismissed as having no table" \
    "this profile has no \[subagents\] table" "${output}"
  assert_not_match "the ceiling is not dismissed as predating the render" \
    "no '# fleet-width:' line" "${output}"
}

@test "subagent-check: a key in another table is not this session's width" {
  local cfg="${BATS_TEST_TMPDIR}/other-table.toml"
  {
    printf '# managed-by: evo-t1-coder-stack\n'
    printf '[litellm_extra]\nmax_concurrent = 999\n'
    printf '# fleet-width: 100\n'
    printf '[subagents]\nenabled = true\n# fleet-width: 15\nmax_concurrent = 15\nmax_depth = 2\n'
    printf '\n[subagents.models]\ngeneral-purpose = "agent-swarm"\n'
  } >"${cfg}"

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the [subagents] pair is what gets judged" \
    "ok: max_concurrent = 15, the fleet's own width" "${output}"
  assert_not_match "the foreign key never reads as the width" '999' "${output}"
  assert_not_match "and the foreign ceiling never outranks the render's line" \
    'fleet width 100' "${output}"
}

@test "subagent-check: --json keeps stdout to the object even on a usage error" {
  local cfg="${BATS_TEST_TMPDIR}/narrow.toml" stdout err rc=0
  write_profile "${cfg}" 15 15 agent-swarm 1 2

  stdout="$(env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${cfg}" --json --nope 2>/dev/null)" || rc=$?
  err="$(env HOME="${BATS_TEST_TMPDIR}" bash "${SCRIPT}" --config "${cfg}" --json --nope 2>&1 >/dev/null)" || rc=$?
  assert_eq "the usage error still answers with its own code" "2" "${rc}"
  assert_eq "and stdout carries no prose for a parser to trip over" "" "${stdout}"
  assert_match "the complaint is on stderr" 'error: unknown option: --nope' "${err}"
  assert_match "with the block beside it, where a human reads it" 'usage:.*subagent-check|--config' "${err}"
}

@test "subagent-check: profile_line scopes to the table and canonicalises" {
  local cfg="${BATS_TEST_TMPDIR}/scoped.toml"
  load_cli_functions profile_table profile_has_table profile_line profile_int profile_fleet_width

  {
    printf '# managed-by: evo-t1-coder-stack\n'
    printf '[other]\nmax_concurrent = 7\n'
    printf '[subagents]\n'
    printf '# fleet-width: 015\n'
    printf 'max_concurrent = 0012 \n'
    printf '[tail]\nmax_concurrent = 3\n'
  } >"${cfg}"
  CONFIG="${cfg}"

  assert_eq "only the [subagents] key is read, trailing space and all" "12" "$(profile_int max_concurrent)"
  assert_eq "the ceiling line is read from inside the table only" "15" "$(profile_fleet_width)"
  assert_eq "profile_int is the same reader under another name" "12" "$(profile_int max_concurrent)"
  assert_eq "a key the table does not carry prints nothing" "" "$(profile_int max_depth)"
}

# -- stage 6's own advisory -------------------------------------------------------
#
# The same comparison runs at every workspace start, inside the rendered startup
# script, so an operator who never runs this CLI still hears about a narrowed
# width. Those four lines live in the template, which no bats file executes, so
# they are pulled out and run here: the awk program below cuts the hunk from
# `sub_w="$(` to the `fi` that closes the advisory, and it travels verbatim. It
# carries no Terraform token, which is the only reason that is possible - a hunk
# that ever gains a `${...}` stops being runnable and this section goes red, which
# is the right answer rather than a silently skipped one.

# width_hunk <tftpl> - the advisory hunk, byte for byte as the template holds it.
width_hunk() {
  awk '/^  # fleet-width advisory/ {f=1} f {print} f && /^  fi$/ {exit}' "$1"
}

# boot_width_note <tftpl> <width> [fleet] - run that hunk against a fixture
# profile and print what the startup log would carry. boot_note is stubbed to the
# one line it really prints (templates/common/boot-log.lib.sh owns the real one,
# and its own suite proves the prefix).
boot_width_note() {
  local tftpl="$1" width="$2" fleet="${3:-15}"
  local home="${BATS_TEST_TMPDIR}/hunk-home" driver="${BATS_TEST_TMPDIR}/hunk.sh"
  mkdir -p "${home}/.grok"
  write_profile "${home}/.grok/config.toml" "${width}" "${fleet}" agent-swarm 1 2
  {
    printf 'boot_note() { printf "note: %%s\\n" "$1"; }\n'
    width_hunk "${tftpl}"
  } >"${driver}"
  HOME="${home}" bash "${driver}"
}

@test "subagent-check: the startup hunk is there to be extracted from both twins" {
  local workspace="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  local devcontainer="${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"

  assert_match "the workspace twin carries the readers and the advisory" \
    'sub_w="\$\(awk' "$(width_hunk "${workspace}")"
  assert_match "and so does the devcontainer twin" \
    'sub_f="\$\(awk' "$(width_hunk "${devcontainer}")"
  assert_match "the hunk carries its own table slicer, not a bare-file reader" \
    'sub_prog=' "$(width_hunk "${workspace}")"
  # The twins are independent payload copies everywhere except in a hunk a single
  # fault has to answer the same way in both.
  assert_eq "both twins carry the identical hunk" \
    "$(width_hunk "${workspace}")" "$(width_hunk "${devcontainer}")"
}

@test "subagent-check: the startup hunk says so when the render narrowed the width" {
  local out
  out="$(boot_width_note "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" 4 15)"
  assert_eq "a width under the ceiling is exactly one note" \
    "note: subagents width 4 is below the fleet's 15 - a value that outlived its template, unless you set it on purpose (docs/troubleshooting.md#the-rendered-width-is-below-fleet-width)" \
    "${out}"
}

@test "subagent-check: the startup hunk keeps quiet on every state that is not narrow" {
  local hunk="${REPO_ROOT}/templates/workspace/startup.sh.tftpl" out
  local home="${BATS_TEST_TMPDIR}/hunk-home" driver="${BATS_TEST_TMPDIR}/hunk.sh"

  out="$(boot_width_note "${hunk}" 15 15)"
  assert_eq "the shipped pair boots in silence" "" "${out}"

  out="$(boot_width_note "${hunk}" 20 15)"
  assert_eq "a width above the ceiling is the CLI's commentary, not a boot note" "" "${out}"

  out="$(boot_width_note "${hunk}" - 15)"
  assert_eq "no width line means nothing to compare" "" "${out}"

  out="$(boot_width_note "${hunk}" 4 -)"
  assert_eq "and no ceiling line means no claim to make" "" "${out}"

  # The reader anchored its pattern with [[:space:]]*$ for a reason: a profile
  # edited on a Windows host carries \r, and the old anchor called that whole
  # table missing, which silenced the note on exactly the file worth warning about.
  mkdir -p "${home}/.grok"
  {
    printf '# managed-by: evo-t1-coder-stack\r\n'
    printf '[subagents]\r\n'
    printf '# fleet-width: 15\r\n'
    printf 'max_concurrent = 4\r\n'
  } >"${home}/.grok/config.toml"
  {
    printf 'boot_note() { printf "note: %%s\\n" "$1"; }\n'
    width_hunk "${hunk}"
  } >"${driver}"
  out="$(HOME="${home}" bash "${driver}")"
  assert_match "a CRLF profile still gets its note" \
    "note: subagents width 4 is below the fleet's 15" "${out}"
}

# -- the hand-edited profile, which is the one that actually happens -------------
#
# The render writes a shape this suite already covers. The profiles below are the
# ones an operator produces afterwards, and every one of them was observed, during
# review, to make the CLI print a wrong verdict or the boot advisory go silent.
# TOML accepts all of them: `python3 -c 'import tomllib; tomllib.load(...)'` reads
# each as the same integer the render would have written.

# write_raw_profile <path> <content> - a profile exactly as handed over, with no
# helper shaping it on the way.
write_raw_profile() {
  printf '%s' "$2" >"$1"
}

# boot_hunk_note <tftpl> <profile-content> - boot the advisory against a profile
# written verbatim, and print what the startup log would carry.
boot_hunk_note() {
  local tftpl="$1" body="$2"
  local home="${BATS_TEST_TMPDIR}/raw-home" driver="${BATS_TEST_TMPDIR}/raw-hunk.sh"
  mkdir -p "${home}/.grok"
  write_raw_profile "${home}/.grok/config.toml" "${body}"
  {
    printf 'boot_note() { printf "note: %%s\\n" "$1"; }\n'
    width_hunk "${tftpl}"
  } >"${driver}"
  HOME="${home}" bash "${driver}"
}

@test "subagent-check: a padded header and an annotated key read as the render they are" {
  local cfg="${BATS_TEST_TMPDIR}/padded.toml"
  load_cli_functions profile_table profile_has_table profile_line profile_int profile_fleet_width

  write_raw_profile "${cfg}" '[ subagents ]
# fleet-width: 15
max_concurrent = 4 # narrowed for the pinned lane
'
  CONFIG="${cfg}"
  assert_eq "padding inside the brackets is the same table" "4" "$(profile_int max_concurrent)"
  assert_eq "and a TOML comment after the digits is the same number" "15" "$(profile_fleet_width)"
  profile_has_table subagents
  assert_eq "the table is found, so the missing-key branch stays silent" "0" "$?"

  write_raw_profile "${cfg}" '[subagents]
# fleet-width: 15
  max_concurrent = 4
'
  CONFIG="${cfg}"
  assert_eq "an indented key is the same key" "4" "$(profile_int max_concurrent)"

  write_raw_profile "${cfg}" '[subagents]
# fleet-width: 15
"max_concurrent" = 4
'
  CONFIG="${cfg}"
  assert_eq "a quoted key is the same key" "4" "$(profile_int max_concurrent)"

  write_raw_profile "${cfg}" '[subagents]
# fleet-width: 15
max_concurrent = +4
'
  CONFIG="${cfg}"
  assert_eq "TOML writes a positive integer with a plus, and that is a width" "4" "$(profile_int max_concurrent)"

  write_raw_profile "${cfg}" '[subagents] # grouped under the header comment
# fleet-width: 15
max_concurrent = 4
'
  CONFIG="${cfg}"
  assert_eq "a comment after the header is still that header" "4" "$(profile_int max_concurrent)"
}

@test "subagent-check: the boot advisory still fires on a hand-edited profile" {
  local hunk="${REPO_ROOT}/templates/workspace/startup.sh.tftpl" out

  out="$(boot_hunk_note "${hunk}" '[ subagents ]
# fleet-width: 15
max_concurrent = 4 # narrowed for the pinned lane
')"
  assert_match "a padded header and an inline comment do not silence the note" \
    "note: subagents width 4 is below the fleet's 15" "${out}"

  out="$(boot_hunk_note "${hunk}" '[subagents]
# fleet-width: 0015
max_concurrent = 04
')"
  assert_eq "the boot log prints the numbers the CLI prints, not the raw zeros" \
    "note: subagents width 4 is below the fleet's 15 - a value that outlived its template, unless you set it on purpose (docs/troubleshooting.md#the-rendered-width-is-below-fleet-width)" \
    "${out}"

  # The comparison has to survive a value bash's integer test cannot hold, without
  # writing an error line into every boot of that workspace.
  out="$(boot_hunk_note "${hunk}" '[subagents]
# fleet-width: 15
max_concurrent = 999999999999999999999
')"
  assert_eq "an absurd width prints no note and no shell error" "" "${out}"
}

@test "subagent-check: the ceiling is read from the one line the render writes" {
  local cfg="${BATS_TEST_TMPDIR}/stray.toml"
  load_cli_functions profile_table profile_line profile_int profile_fleet_width

  # The same comment, twice: the render's own line above max_concurrent, and a
  # copy the operator left above another key. head -1 over the whole table used to
  # take the copy, and the tool then ordered the fleet's width to be 100.
  write_raw_profile "${cfg}" '[subagents]
enabled = true
# fleet-width: 100
max_depth = 2
# fleet-width: 15
max_concurrent = 4
'
  CONFIG="${cfg}"
  assert_eq "the ceiling above max_concurrent wins, by position" "15" "$(profile_fleet_width)"
  assert_eq "and the width is still the width" "4" "$(profile_int max_concurrent)"

  write_raw_profile "${cfg}" '[subagents]
enabled = true
# fleet-width: 15
'
  CONFIG="${cfg}"
  assert_eq "a fleet-width comment with no width under it is not a ceiling" "" "$(profile_fleet_width)"
}

@test "subagent-check: a lost line and a missing table get different orders" {
  local cfg="${BATS_TEST_TMPDIR}/keyless.toml" out
  write_raw_profile "${cfg}" '# managed-by: evo-t1-coder-stack
[subagents]
enabled = true
max_depth = 2
'
  run_check "${cfg}"
  assert_match "a table that lost its width line is called a hand edit" \
    "the \[subagents\] table carries no 'max_concurrent' line - a hand edit, which no restart undoes" \
    "${output}"
  assert_not_match "and is not sent off for a restart" 'restart the workspace' "${output}"

  write_raw_profile "${cfg}" '# managed-by: evo-t1-coder-stack
[litellm]
max_concurrent = 4
'
  run_check "${cfg}"
  assert_match "a profile with no table at all still wants the restart" \
    "no 'max_concurrent' line - this profile has no \[subagents\] table; restart the workspace" \
    "${output}"
}

@test "subagent-check: an absurd width is never called the shipped state" {
  local cfg="${BATS_TEST_TMPDIR}/huge.toml"
  write_profile "${cfg}" 999999999999999999999 15 agent-swarm 1 2

  run_check "${cfg}"
  assert_match "the pair is reported as impossible rather than compared" \
    'is not a width this stack can mean' "${output}"
  assert_not_match "no bash integer error reaches the operator" \
    'integer expression expected' "${output}"
  assert_not_match "and it is not the ok the fall-through used to print" \
    "ok: max_concurrent = 999999999999999999999" "${output}"
  assert_match "a warning is what counts" '1 warnings' "${output}"
}

@test "subagent-check: an unreadable profile gets one order, and it is not a restart" {
  local cfg="${BATS_TEST_TMPDIR}/noread.toml"
  write_profile "${cfg}" 15 15 agent-swarm 1 2
  chmod 000 "${cfg}"
  # Running as a user that can read everything makes the case unreachable; skip
  # rather than pass on a state the run never produced.
  if [ -r "${cfg}" ]; then
    skip "this run can read a 000 file, so the unreadable branch cannot be reached"
  fi

  run_check "${cfg}"
  assert_match "one error names the mode" 'is not readable by this user' "${output}"
  assert_not_match "and no second line orders a restart that cannot fix it" \
    'restart the workspace' "${output}"
  assert_eq "the run fails, so a gate still catches it" "1" "${status}"
  chmod 644 "${cfg}"
}

@test "subagent-check: a lane key in a nested table is not the writers lane" {
  local cfg="${BATS_TEST_TMPDIR}/laneleak.toml"
  load_cli_functions profile_table profile_has_table profile_writers_lane

  write_raw_profile "${cfg}" '[subagents.models]
explore = "agent-explore"
[subagents.models.extra]
general-purpose = "chat"
'
  CONFIG="${cfg}"
  assert_eq "the nested table's key never reaches the lane verdict" "" "$(profile_writers_lane)"

  write_raw_profile "${cfg}" '[subagents.models]
general-purpose = "agent-swarm"
'
  CONFIG="${cfg}"
  assert_eq "the real table still answers" "agent-swarm" "$(profile_writers_lane)"
}

@test "subagent-check: --parallel given nothing is a usage error, not the default" {
  local cfg="${BATS_TEST_TMPDIR}/parallel.toml"
  write_profile "${cfg}" 15 15 agent-swarm 1 2

  run_check "${cfg}" --parallel ""
  assert_eq "an empty argument is refused, not read as the default 5" "2" "${status}"
  assert_match "and the complaint names the option" 'whole number of streams' "${output}"

  run_check "${cfg}" --parallel 0x5
  assert_eq "a non-decimal width is refused too" "2" "${status}"

  run_check "${cfg}" --parallel 3
  assert_eq "a real width still parses" "0" "${status}"
}

@test "subagent-check: the re-push remedy stands on push-template never naming the width" {
  local hits
  # The note tells an operator to re-push the template to drop a template-level
  # width. That is sound only while the pushing script never sends that parameter
  # itself: a re-push carrying the narrow number would recreate the fault. Pin the
  # condition the advice rests on, so relaying a dotenv key into a --var there
  # reddens this suite instead of quietly making the printed command wrong.
  hits="$(grep -c 'grok_subagent_max_concurrent' "${REPO_ROOT}/scripts/push-template.sh" || true)"
  assert_eq "push-template.sh never names the width parameter" "0" "${hits}"
  hits="$(grep -c 'grok_swarm_width' "${REPO_ROOT}/scripts/push-template.sh" || true)"
  assert_eq "and it never names the fleet width either" "0" "${hits}"
}

# -- the host sweep: --all, on a daemon made of stubs ------------------------------
#
# --all is the CLI's only path that reaches for a docker daemon, so everything below
# shadows two binaries and nothing else: a file-local docker stub, because the shipped
# tests/bats/tool_stubs/docker answers `docker compose ps` and cannot carry the four
# tab-separated columns workspace_rows parses, and the shipped
# tests/bats/tool_stubs/timeout, because stack_timeout execs timeout(1) itself. No test
# here asks the host's docker, nor the network, nor a live stack: every listing, exec
# and daemon error is canned by the very test that asserts on it.
#
# The container-side profile is real bytes rather than a canned string. The stub hands
# read_profile's in-container `cat` a HOME of ${STUB_EXEC_HOME_DIR}/<container>, so the
# fixtures the single-profile tests already write with write_profile are what each
# container "has" on disk, and a container with no such file fails the way a workspace
# whose boot render never ran fails - which is why the no-profile row needs no stub of
# its own.

# SWEEP_TAB is the column separator workspace_rows emits. A literal tab inside a
# fixture line is invisible to whoever reads this file next, so every row is built
# from this instead.
SWEEP_TAB=$'\t'

# write_docker_stub <path> - the two verbs the sweep issues, and nothing else. Every
# argv is appended tab-separated to ${STUB_LOG}/docker, so a test can hold the CLI to
# the exact `docker ps` filter and format rather than to a result that happens to look
# right. `ps` prints ${STUB_PS_OUT} verbatim on stdout and ${STUB_PS_ERR:-} on stderr,
# which is how a test puts a `sudo docker` notice on the stream the sweep deliberately
# keeps off its answer, and exits ${STUB_PS_RC:-0}. `version` exits
# ${STUB_VERSION_RC:-0}; `exec` refuses any form but
# `exec <container> sh -c <script> sh` - the one form read_profile issues - with exit
# 9, so a rewrite of that call site lands as a failure here instead of as a silently
# canned profile. Otherwise it runs that script for real, on this host's PATH, under
# the container's own fixture HOME.
write_docker_stub() {
  local path="${1}"
  cat >"${path}" <<'STUB'
#!/usr/bin/env bash
{
  printf 'docker'
  for a in "$@"; do printf '\t%s' "${a}"; done
  printf '\n'
} >>"${STUB_LOG}/docker"
cmd="${1:-}"
shift || true
case "${cmd}" in
  version) exit "${STUB_VERSION_RC:-0}" ;;
  ps)
    if [ -n "${STUB_PS_OUT:-}" ]; then printf '%s\n' "${STUB_PS_OUT}"; fi
    if [ -n "${STUB_PS_ERR:-}" ]; then printf '%s\n' "${STUB_PS_ERR}" >&2; fi
    exit "${STUB_PS_RC:-0}"
    ;;
  exec)
    if [ "${1:-}" = "--" ]; then shift; fi
    container="${1:-}"
    shift || true
    if [ "${1:-}" != "sh" ] || [ "${2:-}" != "-c" ]; then
      printf 'stub docker: unexpected exec form: %s\n' "$*" >&2
      exit 9
    fi
    script="${3}"
    shift 3
    if [ "${1:-}" = "sh" ]; then shift; fi
    if [ "${STUB_EXEC_RC:-0}" != "0" ]; then exit "${STUB_EXEC_RC}"; fi
    if [ -n "${STUB_EXEC_HOME_DIR:-}" ]; then
      HOME="${STUB_EXEC_HOME_DIR}/${container}" sh -c "${script}" sh "$@"
    else
      sh -c "${script}" sh "$@"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
  chmod 755 "${path}"
}

# use_sweep_stubs - shadow docker and timeout on this test's PATH and open the farm of
# per-container homes. Called per sweep test and deliberately not from setup(): the
# single-profile tests below must keep a PATH of their own, and one of them proves the
# missing-docker refusal by taking the stub back off it.
use_sweep_stubs() {
  use_stubs timeout
  write_docker_stub "${BATS_TEST_TMPDIR?}/bin/docker"
  STUB_EXEC_HOME_DIR="${BATS_TEST_TMPDIR?}/container-homes"
  export STUB_EXEC_HOME_DIR
  mkdir -p "${STUB_EXEC_HOME_DIR}"
}

# sweep_row <workspace> <owner> <container> <state> - one docker ps row, no trailing
# newline, so rows are joined with $'\n' the way the daemon's own output is.
sweep_row() {
  printf '%s%s%s%s%s%s%s' "$1" "${SWEEP_TAB}" "$2" "${SWEEP_TAB}" "$3" "${SWEEP_TAB}" "$4"
}

# sweep_home <container> [width] [fleet] [marker] - the profile one container's boot
# render left behind, written by the suite's own write_profile so the sweep judges the
# very bytes the single-profile tests judge. No models block and no depth: judge_width
# reads neither, and a fixture carries only what the verdict depends on. marker takes
# 0 for the profile no render reaches any more.
sweep_home() {
  local container="$1" width="${2:-15}" fleet="${3:-15}" marker="${4:-1}"
  local path="${STUB_EXEC_HOME_DIR?}/${container}/.grok/config.toml"
  mkdir -p "${path%/*}"
  write_profile "${path}" "${width}" "${fleet}" agent-swarm "${marker}" -
}

# sweep_home_raw <container> <content> - one container's profile exactly as its operator
# left it, with no helper shaping it, for the shapes write_profile cannot express: a
# table that was deleted whole, a header padded by hand.
sweep_home_raw() {
  local path="${STUB_EXEC_HOME_DIR?}/${1}/.grok/config.toml"
  mkdir -p "${path%/*}"
  write_raw_profile "${path}" "${2}"
}

# run_sweep <ps-out> [args...] - the host sweep, with this test's daemon listing. The
# two sentinels are unset and not merely emptied: host_guard reads either one as "this
# shell is a workspace, and its docker addresses its own sidecar", and the ambient
# environment of the very container this suite runs in carries one.
run_sweep() {
  local ps_out="$1"
  shift
  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER \
    HOME="${BATS_TEST_TMPDIR}" STUB_PS_OUT="${ps_out}" \
    bash "${SCRIPT}" --all "$@"
}

# sweep_stdout <ps-out> [args...] - only the sweep's stdout, which under --json has to
# be nothing but the per-workspace objects.
sweep_stdout() {
  local ps_out="$1"
  shift
  env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER \
    HOME="${BATS_TEST_TMPDIR}" STUB_PS_OUT="${ps_out}" \
    bash "${SCRIPT}" --all "$@" 2>/dev/null
}

# sweep_ps_argv - the one docker ps line the stub recorded, tab-separated as logged.
sweep_ps_argv() {
  awk -F'\t' '$2 == "ps" {print; exit}' "${STUB_LOG}/docker" 2>/dev/null || true
}

# sweep_exec_targets - the containers the sweep actually exec'd into, one per line.
sweep_exec_targets() {
  # The sweep passes `--` before the container so an option-looking label cannot
  # become a docker flag; the target is the field after it when it is there.
  awk -F'\t' '$2 == "exec" { print ($3 == "--" ? $4 : $3) }' "${STUB_LOG}/docker" 2>/dev/null || true
}

@test "subagent-check: --all sweeps two workspaces and prints the contract exactly" {
  local rows expected
  use_sweep_stubs
  sweep_home coder-alice-evo 15 15
  sweep_home coder-alice-narrow 4 7
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'"$(sweep_row narrow alice coder-alice-narrow running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  expected="$(printf '%s\n' \
    '' \
    '== subagent width sweep ==' \
    '-> evo (coder-alice-evo)' \
    "ok: max_concurrent = 15, the fleet's own width" \
    '-> narrow (coder-alice-narrow)' \
    'warning: max_concurrent = 4 is below the fleet width 7' \
    'note: coder update alice/narrow --parameter grok_subagent_max_concurrent=7' \
    'summary: 1 ok, 1 warnings, 0 failed')"
  assert_eq "one section, one phase line and one verdict per workspace, then the summary" \
    "${expected}" "${output}"
  assert_not_match "the sweep never prints the four single-profile phases" \
    '^-> the (profile|width|lanes|depth)$' "${output}"

  # The listing behind that printout, byte-exact, because every piece of it is
  # load-bearing: -a is what makes a stopped workspace enumerable at all, the label is
  # what finds workspaces across every compose project without resolving one from the
  # cwd, and the four columns are the ones the row parser splits on.
  local want
  want="$(printf 'docker\tps\t-a\t--filter\tlabel=coder.workspace_id\t--format\t{{.Label "coder.workspace_name"}}\t{{.Label "coder.owner"}}\t{{.Names}}\t{{.State}}')"
  assert_eq "one bounded docker ps, in the exact form the contract pins" \
    "${want}" "$(sweep_ps_argv)"
  assert_match "and every probe is bounded by timeout(1) with a kill-after" \
    '^timeout -k 2 20 docker ps ' "$(cat "${STUB_LOG}/timeout.log")"
}

@test "subagent-check: each offender's remedy carries that workspace's own fleet width" {
  local rows
  use_sweep_stubs
  # Two offenders rendered at two different widths is what makes this case bite: a
  # remedy that hard-coded the shipped 15 (or any other single number) can satisfy one
  # of these two lines and cannot satisfy both.
  sweep_home coder-alice-seven 4 7
  sweep_home coder-bob-eleven 6 11
  rows="$(sweep_row seven alice coder-alice-seven running)"$'\n'"$(sweep_row eleven bob coder-bob-eleven running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the seven-wide workspace is told to set seven" \
    'note: coder update alice/seven --parameter grok_subagent_max_concurrent=7' \
    "$(printf '%s\n' "${output}" | grep '^note: coder update alice/')"
  assert_eq "and the eleven-wide one is told to set eleven" \
    'note: coder update bob/eleven --parameter grok_subagent_max_concurrent=11' \
    "$(printf '%s\n' "${output}" | grep '^note: coder update bob/')"
  assert_not_match "no shipped default is relayed instead of the render's own number" \
    'grok_subagent_max_concurrent=15' "${output}"
  assert_match "both offenders, counted once each" 'summary: 0 ok, 2 warnings, 0 failed' "${output}"
}

@test "subagent-check: --all never judges the DinD sidecar the label also returns" {
  local rows
  use_sweep_stubs
  sweep_home coder-alice-evo 15 15
  # The sidecar carries coder.workspace_id too, so the daemon does enumerate it: the
  # exclusion is the sweep's own, on the container name, and nothing else can tell it
  # apart from a workspace. A judged sidecar would report a profile nobody renders and
  # order an update for a parameter no workspace owns.
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'"$(sweep_row evo alice coder-alice-evo-dind-sidecar running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the sidecar gets no phase line and no verdict" \
    "$(printf '%s\n%s' '-> evo (coder-alice-evo)' "ok: max_concurrent = 15, the fleet's own width")" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning|note): ')"
  assert_eq "one workspace counted, nothing for the sidecar" \
    'summary: 1 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
  assert_not_match "the sidecar name reaches neither a filter nor an exec" 'dind' \
    "$(cat "${STUB_LOG}/docker")"
  assert_eq "so exactly one container was read" "coder-alice-evo" "$(sweep_exec_targets)"
}

@test "subagent-check: --all reports a stopped container once and never execs into it" {
  local rows
  use_sweep_stubs
  rows="$(sweep_row down alice coder-alice-down exited)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the stopped row is exactly the contract's one line" \
    'warning: coder-alice-down is stopped (exited) - its profile is unreachable and its width comes from the stored parameter' \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_eq "and it is counted exactly once" "1" \
    "$(printf '%s\n' "${output}" | grep -c '^warning: coder-alice-down')"
  assert_eq "one warning, no ok, no failure" 'summary: 0 ok, 1 warnings, 0 failed' \
    "${output##*$'\n'}"
  assert_eq "a stopped container is never exec'd into" "" "$(sweep_exec_targets)"
}

@test "subagent-check: --all refuses to sweep from inside a workspace or the dev container" {
  local rows
  use_sweep_stubs
  sweep_home coder-alice-evo 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"

  # Both sentinels mean the same thing here: this shell's docker addresses its own
  # sidecar, so a sweep would judge one container and call it the fleet.
  run env -u EVO_T1_DEVCONTAINER CODER_WORKSPACE_ID=1 \
    HOME="${BATS_TEST_TMPDIR}" STUB_PS_OUT="${rows}" bash "${SCRIPT}" --all
  [ "${status}" -eq 1 ]
  assert_eq "the refusal says where the run belongs" \
    "error: subagent-check --all is a stack-host run: this shell's docker addresses its own sidecar" \
    "$(printf '%s\n' "${output}" | grep '^error: ')"
  assert_not_match "and it refuses before it prints a section or calls anything" '--== subagent width sweep ==' \
    "${output}"

  run env -u CODER_WORKSPACE_ID HOME="${BATS_TEST_TMPDIR}" EVO_T1_DEVCONTAINER=1 \
    STUB_PS_OUT="${rows}" bash "${SCRIPT}" --all
  [ "${status}" -eq 1 ]
  assert_match "the contributor dev container is refused the same way" \
    'subagent-check --all is a stack-host run' "${output}"

  assert_eq "neither refusal listed a single container" "" "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
}

@test "subagent-check: --all on an empty daemon is a note and a clean exit" {
  use_sweep_stubs

  run_sweep ""
  [ "${status}" -eq 0 ]
  assert_eq "a host with no workspaces says so, and stops" \
    'note: no workspace containers on this daemon - nothing to sweep' \
    "$(printf '%s\n' "${output}" | grep '^note: ')"
  assert_eq "and the summary carries three zeros" 'summary: 0 ok, 0 warnings, 0 failed' \
    "${output##*$'\n'}"
  assert_eq "an empty listing is not a failure" "0" "${status}"
  assert_eq "the listing was asked for, and nothing else" "1" \
    "$(awk -F'\t' '$2 == "ps"' "${STUB_LOG}/docker" | grep -c .)"
  assert_eq "so nothing was exec'd" "" "$(sweep_exec_targets)"
}

@test "subagent-check: --all with --config is a usage error on either ordering" {
  use_sweep_stubs

  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
    bash "${SCRIPT}" --all --config "${BATS_TEST_TMPDIR}/x.toml"
  [ "${status}" -eq 2 ]
  assert_match "it says why the two cannot describe one run" \
    'error: --all judges every workspace, not one path' "${output}"
  assert_match "with the block beside it, where a human reads it" \
    'usage: bazelisk run //scripts:subagent-check' "${output}"

  # Same refusal, flag order reversed: the parser judges the pair after the loop, so a
  # --config that arrives second is refused exactly as the first one is.
  local stdout rc=0
  stdout="$(env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
    bash "${SCRIPT}" --config "${BATS_TEST_TMPDIR}/x.toml" --all 2>/dev/null)" || rc=$?
  assert_eq "the reversed order is refused with its own code" "2" "${rc}"
  assert_eq "and stdout carries no prose for a parser to trip over" "" "${stdout}"
  assert_eq "a refused sweep never reached the daemon" "" "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
}

@test "subagent-check: --all --json is one flat object per workspace and nothing beside it" {
  local rows stdout lines keys shape line rc=0
  use_sweep_stubs
  sweep_home coder-alice-evo 15 15
  sweep_home coder-alice-narrow 4 7
  mkdir -p "${STUB_EXEC_HOME_DIR}/coder-carol-gone"
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  rows="${rows}$(sweep_row narrow alice coder-alice-narrow running)"$'\n'
  rows="${rows}$(sweep_row gone carol coder-carol-gone exited)"

  stdout="$(sweep_stdout "${rows}" --json)" || true
  while IFS= read -r line; do
    if [ -n "${line}" ]; then
      printf '%s\n' "${line}" | python3 -m json.tool >/dev/null || rc=$?
    fi
  done <<<"${stdout}"
  assert_eq "every line is one object a parser accepts" "0" "${rc}"
  lines="$(printf '%s\n' "${stdout}" | grep -c .)"
  assert_eq "one object per workspace, one per line, and nothing else" "3" "${lines}"
  assert_not_match "no section heading leaked onto the machine channel" '^==' "${stdout}"
  assert_not_match "no phase line did either" '^-> ' "${stdout}"
  assert_not_match "nor a verdict" '^(ok|warning|note): ' "${stdout}"
  assert_not_match "nor the summary" '^summary: ' "${stdout}"

  keys="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        flat = all(not isinstance(v, (dict, list)) for v in d.values())
        print(",".join(d.keys()) + "|" + str(flat))')"
  assert_eq "every object is flat and carries the eight keys in the pinned order" \
    "$(printf '%s\n' \
      'workspace,owner,container,running,max_concurrent,fleet_width,verdict,remedy|True' \
      'workspace,owner,container,running,max_concurrent,fleet_width,verdict,remedy|True' \
      'workspace,owner,container,running,max_concurrent,fleet_width,verdict,remedy|True')" \
    "${keys}"

  shape="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        print("%s|%s|%s|%s|%s|%s|%s" % (
            d["workspace"], d["owner"], d["container"],
            "%s:%s" % (d["running"], type(d["running"]).__name__),
            d["max_concurrent"], d["fleet_width"], d["verdict"]))')"
  assert_eq "running is a JSON boolean, the widths are numbers, the verdict is the word" \
    "$(printf '%s\n' \
      'evo|alice|coder-alice-evo|True:bool|15|15|ok' \
      'narrow|alice|coder-alice-narrow|True:bool|4|7|warning' \
      'gone|carol|coder-carol-gone|False:bool|None|None|warning')" \
    "${shape}"
  assert_match "the below-width object carries the very command the prose printed" \
    '"remedy":"coder update alice/narrow --parameter grok_subagent_max_concurrent=7"' "${stdout}"
  assert_eq "and an object with nothing to fix carries null, not an empty string" \
    "2" "$(printf '%s\n' "${stdout}" | grep -c '"remedy":null')"
  assert_eq "the width a stopped container never yielded is null, not zero and not the stored guess" \
    "1" "$(printf '%s\n' "${stdout}" | grep -c '"max_concurrent":null')"
  assert_eq "and its ceiling is null with it" \
    "1" "$(printf '%s\n' "${stdout}" | grep -c '"fleet_width":null')"

  # The prose the object cannot carry - the remedy text and the counts - still has to
  # reach a human, so it goes to stderr rather than vanishing.
  local errf="${BATS_TEST_TMPDIR}/sweep.err" rc=0
  env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
    STUB_PS_OUT="${rows}" bash "${SCRIPT}" --all --json 2>"${errf}" >/dev/null || rc=$?
  assert_eq "a warning is not a failure without --strict" "0" "${rc}"
  assert_contains_file "the section heading went to stderr" "${errf}" '== subagent width sweep =='
  assert_contains_file "the phase line went to stderr" "${errf}" \
    '\-> narrow \(coder-alice-narrow\)'
  assert_contains_file "and so did the counts" "${errf}" 'summary: 1 ok, 2 warnings, 0 failed'
}

@test "subagent-check: --all calls a container with no profile an unrendered boot" {
  local rows
  use_sweep_stubs
  # The home farm exists but holds no .grok/config.toml, which is the state the stub's
  # real in-container cat answers with a non-zero exit, not a canned one.
  mkdir -p "${STUB_EXEC_HOME_DIR}/coder-alice-fresh"
  rows="$(sweep_row fresh alice coder-alice-fresh running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "it names the path inside the container and what is missing" \
    'warning: no profile at /home/coder/.grok/config.toml in coder-alice-fresh - the boot render has not run' \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_eq "counted once, as a warning" 'summary: 0 ok, 1 warnings, 0 failed' \
    "${output##*$'\n'}"
  assert_not_match "a file that is not there is not called unmanaged" 'carries neither stack marker' \
    "${output}"
  assert_not_match "and no restart is ordered for a boot that never ran" 'restart the workspace' \
    "${output}"
}

@test "subagent-check: --all calls a lost width line a hand edit, and does not order a restart" {
  local rows
  use_sweep_stubs
  sweep_home coder-alice-lost - 15
  rows="$(sweep_row lost alice coder-alice-lost running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the table is there and the line is not, which no restart undoes" \
    "warning: the [subagents] table carries no 'max_concurrent' line - a hand edit, which no restart undoes" \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_not_match "and an operator is not sent off for a restart that cannot fix it" \
    'restart the workspace' "${output}"
  assert_eq "its own count" 'summary: 0 ok, 1 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all sends a profile with no [subagents] table to a restart" {
  local rows
  use_sweep_stubs
  # The other half of the pair above: a profile the render never wrote at all, told
  # apart from the hand edit by the header alone, and answered with the opposite order.
  sweep_home_raw coder-alice-notable '# managed-by: evo-t1-coder-stack
[litellm]
max_concurrent = 4
'
  rows="$(sweep_row notable alice coder-alice-notable running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "a profile the render never wrote wants the render back" \
    "warning: no 'max_concurrent' line - this profile has no [subagents] table; restart the workspace to re-materialize" \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_not_match "and it is not called a hand edit" 'hand edit' "${output}"
  assert_eq "its own count" 'summary: 0 ok, 1 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all warns about a missing marker where one profile fails on it" {
  local rows cfg
  use_sweep_stubs
  sweep_home coder-alice-foreign 15 15 0
  rows="$(sweep_row foreign alice coder-alice-foreign running)"

  run_sweep "${rows}"
  # The contrast is the finding, so it is asserted from both paths below. The
  # single-profile path calls an unowned file a failure, because it can name the path an
  # operator has to go fix; the sweep judges a container it cannot point anyone at, so
  # the same finding leaves as a warning and the run stays clean.
  [ "${status}" -eq 0 ]
  assert_eq "the sweep's verdict names the container, not a path" \
    'warning: coder-alice-foreign carries neither stack marker' \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_eq "counted as a warning, not a failure" 'summary: 0 ok, 1 warnings, 0 failed' \
    "${output##*$'\n'}"
  assert_not_match "nothing is recorded as a failure by the sweep" 'error: ' "${output}"
  assert_not_match "and no width is claimed for a file the render never reaches" \
    'max_concurrent = 15' "${output}"

  # The same profile shape through the single-profile path: there the identical finding
  # is a failure with its own exit code, which is what the two paths disagree on.
  cfg="${BATS_TEST_TMPDIR}/foreign.toml"
  write_profile "${cfg}" 15 15 agent-swarm 0 2
  run_check "${cfg}"
  [ "${status}" -eq 1 ]
  assert_match "the single-profile path fails on the same missing marker" \
    "error: ${cfg} carries neither stack marker" "${output}"
  assert_match "and counts it as a failure, not a warning" '0 warnings, 1 failed' "${output}"
}

@test "subagent-check: --all says so when the render never wrote the fleet-width line" {
  local rows
  use_sweep_stubs
  sweep_home coder-alice-nofleet 4 -
  rows="$(sweep_row nofleet alice coder-alice-nofleet running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the ceiling is missing, which is a pre-render profile" \
    "warning: no '# fleet-width:' line above max_concurrent - this profile predates it; restart the workspace to re-materialize" \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_not_match "a width is not compared against nothing" 'is below the fleet width' "${output}"
  assert_not_match "and no coder update is printed for a number nobody chose" 'coder update' "${output}"
  assert_eq "its own count" 'summary: 0 ok, 1 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all counts an above-fleet width with the oks" {
  local rows
  use_sweep_stubs
  sweep_home coder-alice-wide 20 15
  rows="$(sweep_row wide alice coder-alice-wide running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "above the fleet is commentary, and it says where the extra spawns go" \
    "note: max_concurrent = 20 is above the fleet width 15 - past the fleet's streams the extra spawns queue in LiteLLM" \
    "$(printf '%s\n' "${output}" | grep '^note: ')"
  assert_eq "note() prints without counting, so the sweep counts it here" \
    'summary: 1 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
  assert_not_match "and it is never a warning" 'warning: max_concurrent = 20' "${output}"
}

@test "subagent-check: --all says the daemon is unreachable when the listing fails" {
  local rows
  use_sweep_stubs
  rows="$(sweep_row evo alice coder-alice-evo running)"
  export STUB_PS_RC=1

  run_sweep "${rows}"
  [ "${status}" -eq 1 ]
  assert_eq "one error names the question an operator can actually answer" \
    'error: cannot list containers - is the docker daemon reachable from this host?' \
    "$(printf '%s\n' "${output}" | grep '^error: ')"
  # die, not fail_item: a run that never got a listing has no rows to count, and a
  # summary would read as a fleet this sweep had actually looked at.
  assert_not_match "no summary stands where the rows should be" 'summary: ' "${output}"
  assert_not_match "and no verdict is invented for a daemon that never answered" '^-> ' "${output}"
}

@test "subagent-check: --all refuses a host with no docker CLI instead of reporting an empty fleet" {
  local stripped rows
  use_sweep_stubs
  sweep_home coder-alice-evo 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"
  # The stub is on PATH, so "no docker" has to mean a PATH with the stub's directory
  # and every other directory holding a docker taken out of it.
  if ! stripped="$(path_without_exe docker)"; then
    skip "no usable PATH is left without docker, so the missing-CLI branch cannot be reached"
  fi

  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER PATH="${stripped}" \
    HOME="${BATS_TEST_TMPDIR}" STUB_PS_OUT="${rows}" bash "${SCRIPT}" --all
  [ "${status}" -eq 1 ]
  assert_eq "it says what is missing and where" \
    'error: cannot list workspace containers - the docker CLI is not on this host' \
    "$(printf '%s\n' "${output}" | grep '^error: ')"
  assert_not_match "an absent CLI is not reported as a clean fleet" 'nothing to sweep' "${output}"
  assert_not_match "and no empty summary stands in for a sweep" 'summary: ' "${output}"
}

@test "subagent-check: --all --strict fails a narrow sweep on the very same counts" {
  local rows plain strict_plain
  use_sweep_stubs
  sweep_home coder-alice-narrow 4 15
  rows="$(sweep_row narrow alice coder-alice-narrow running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  plain="${output##*$'\n'}"
  assert_eq "a narrow fleet is a warning the operator can walk away from" \
    'summary: 0 ok, 1 warnings, 0 failed' "${plain}"

  run_sweep "${rows}" --strict
  [ "${status}" -eq 1 ]
  strict_plain="${output##*$'\n'}"
  assert_eq "and a gate can fail on it, with no recounting" "${plain}" "${strict_plain}"
  assert_match "the warning itself is unchanged by the flag" \
    'warning: max_concurrent = 4 is below the fleet width 15' "${output}"

  # A sweep with nothing to warn about is clean under --strict too: the flag promotes
  # warnings, it does not demand a finding.
  sweep_home coder-alice-evo 15 15
  run_sweep "$(sweep_row evo alice coder-alice-evo running)" --strict
  [ "${status}" -eq 0 ]
  assert_match "the clean fleet stays clean" 'summary: 1 ok, 0 warnings, 0 failed' "${output}"
}

@test "subagent-check: --all absent still prints the four phases and never the daemon" {
  local cfg
  use_sweep_stubs
  cfg="${BATS_TEST_TMPDIR}/solo.toml"
  write_profile "${cfg}" 15 15 agent-swarm 1 2

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the single-profile report is byte-for-byte the report it was" \
    '== subagent slots ==' "${output}"
  assert_eq "all four phases, in order" \
    "$(printf '%s\n' '-> the profile' '-> the width' '-> the lanes' '-> the depth')" \
    "$(printf '%s\n' "${output}" | grep '^-> ')"
  assert_not_match "the sweep section never prints without its flag" 'subagent width sweep' "${output}"
  assert_not_match "nor one of its per-container phase lines" '^-> .*\(coder-' "${output}"
  assert_not_match "nor one of its verdicts, which name a container" 'warning: coder-' "${output}"
  assert_eq "the default path asked the stubbed daemon for nothing" "" \
    "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
}

@test "subagent-check: --all keeps the container when the owner label is absent" {
  local rows
  use_sweep_stubs
  # The home exists and is a perfectly ordinary below-width profile: the only oddity
  # in this row is an empty owner column, which is how docker prints a container whose
  # coder.owner label is absent. Tab is IFS whitespace, so the old
  # `IFS=$'\t' read -r workspace owner container state` collapsed the two tabs that
  # sit side by side here, shifted every later column left, and had the sweep exec a
  # container named after the state column while reporting the real one as missing.
  sweep_home c-noowner 4 7
  rows="$(sweep_row wno '' c-noowner running)"

  # --json is what makes the owner visible as a field rather than as prose, and the
  # prose still rides stderr in the same run, so one run answers both channels and
  # leaves exactly one exec behind to check.
  run_sweep "${rows}" --json
  [ "${status}" -eq 0 ]
  assert_eq "the empty owner is its own column and shifts nothing" \
    "$(printf '%s\n%s\n%s' \
      '-> wno (c-noowner)' \
      'warning: max_concurrent = 4 is below the fleet width 7' \
      'note: no coder.owner label on c-noowner - run coder update <owner>/wno --parameter grok_subagent_max_concurrent=7')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(warning|note): ')"
  # The row keeps its verdict and its count, and both channels leave the target as a
  # placeholder: `coder update /wno` names no workspace, so an object that carried it
  # would hand the operator a command that cannot run. The prose says which label is
  # missing, which is the one thing the placeholder alone cannot say.
  assert_eq "the object reports the owner as the empty value it is" \
    '{"workspace":"wno","owner":"","container":"c-noowner","running":true,"max_concurrent":4,"fleet_width":7,"verdict":"warning","remedy":null}' \
    "$(printf '%s\n' "${output}" | grep '^{')"
  assert_not_match "and no unrunnable target reaches either channel" \
    'coder update /wno' "${output}"
  assert_eq "and the sweep read that container, not the state column" \
    "c-noowner" "$(sweep_exec_targets)"
  assert_eq "the state word never became a container name" "0" \
    "$(awk -F'\t' '$2 == "exec"' "${STUB_LOG}/docker" | grep -c running || true)"
  assert_eq "counted once" 'summary: 0 ok, 1 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all keeps an owner carrying a quote or a backslash valid JSON" {
  local rows stdout line rc=0 parsed
  use_sweep_stubs
  # Both offenders are below fleet, so each carries a remedy, and the remedy is the
  # one field the sweep assembles out of label text by hand before quoting it. An
  # owner that closes its own string there takes the whole object down with it, so
  # both of the characters json_escape exists for are in play on the same run.
  sweep_home coder-alice-quote 4 7
  sweep_home coder-bside-backslash 6 11
  rows="$(sweep_row narrow 'al"ice' coder-alice-quote running)"$'\n'
  rows="${rows}$(sweep_row bsided 'al\ice' coder-bside-backslash running)"

  stdout="$(sweep_stdout "${rows}" --json)" || true
  while IFS= read -r line; do
    if [ -n "${line}" ]; then
      printf '%s\n' "${line}" | python3 -m json.tool >/dev/null || rc=$?
    fi
  done <<<"${stdout}"
  assert_eq "every line is still one object a parser accepts" "0" "${rc}"
  assert_eq "one object per offender, neither lost to a stray quote" "2" \
    "$(printf '%s\n' "${stdout}" | grep -c .)"
  assert_eq "the bytes on the wire carry the escapes, so no string closes early" \
    "$(printf '%s\n%s' \
      '{"workspace":"narrow","owner":"al\"ice","container":"coder-alice-quote","running":true,"max_concurrent":4,"fleet_width":7,"verdict":"warning","remedy":"coder update al\"ice/narrow --parameter grok_subagent_max_concurrent=7"}' \
      '{"workspace":"bsided","owner":"al\\ice","container":"coder-bside-backslash","running":true,"max_concurrent":6,"fleet_width":11,"verdict":"warning","remedy":"coder update al\\ice/bsided --parameter grok_subagent_max_concurrent=11"}')" \
    "$(printf '%s\n' "${stdout}")"
  # The round trip is the real question: an escape that survived onto the wire but
  # never came back would leave an operator with the wrong owner in the command they
  # are about to run.
  parsed="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        print("%s|%s" % (d["owner"], d["remedy"]))')"
  assert_eq "and each owner comes back exactly as the label wrote it, in the remedy too" \
    "$(printf '%s\n%s' \
      'al"ice|coder update al"ice/narrow --parameter grok_subagent_max_concurrent=7' \
      'al\ice|coder update al\ice/bsided --parameter grok_subagent_max_concurrent=11')" \
    "${parsed}"
}

@test "subagent-check: --all keeps a long remedy whole in the JSON channel" {
  local rows long_owner want json_line note remedy rc=0
  use_sweep_stubs
  # The remedy is the one field the sweep composes itself, and it is the one field
  # json_escape's 180 default was clipping: the prose note printed the whole command
  # while the object beside it carried the first 180 characters of it, so the two
  # channels disagreed about the thing the operator is meant to paste, and the pasted
  # one failed. An owner long enough to push the command past 180 is what makes that
  # disagreement loud; 200 characters of owner is what a real Coder owner name plus a
  # workspace name can reach.
  long_owner="o$(printf 'x%.0s' {1..200})"
  want="coder update ${long_owner}/evo --parameter grok_subagent_max_concurrent=7"
  sweep_home coder-longowner-evo 4 7
  rows="$(sweep_row evo "${long_owner}" coder-longowner-evo running)"

  run_sweep "${rows}" --json
  [ "${status}" -eq 0 ]
  json_line="$(printf '%s\n' "${output}" | grep '^{')"
  note="$(printf '%s\n' "${output}" | grep '^note: ')"
  assert_eq "one object and one note, so the two lines compare like for like" "1" \
    "$(printf '%s\n' "${output}" | grep -c '^{')"

  printf '%s\n' "${json_line}" | python3 -m json.tool >/dev/null || rc=$?
  assert_eq "an uncut remedy does not take the object down with it" "0" "${rc}"
  remedy="$(printf '%s\n' "${json_line}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read())["remedy"])')"

  assert_eq "the object carries the command in full" "${want}" "${remedy}"
  assert_eq "so it is past the 180 the default clip would have stopped it at" "yes" \
    "$([ "${#remedy}" -gt 180 ] && echo yes || echo no)"
  assert_eq "and it still ends with the flag the operator has to run" "yes" \
    "$([[ "${remedy}" == *"--parameter grok_subagent_max_concurrent=7" ]] && echo yes || echo no)"
  assert_eq "the two channels are one string: the JSON remedy is the prose note verbatim" \
    "${note#note: }" "${remedy}"
}

@test "subagent-check: --all calls a hung exec a container that did not answer, not an unrendered boot" {
  local rows
  use_sweep_stubs
  # Both profiles are there and readable: the only thing that goes wrong is the exec
  # never coming back. The stub's own STUB_EXEC_RC is the knob, and it exits before
  # the in-container cat runs, so the status the sweep reads is the cap biting the way
  # timeout(1) reports it. A hung container is not a workspace whose boot never
  # rendered, and ordering a restart for one burns a session chasing a render that
  # already ran. The cap is pinned per run so the seconds in the wording are this
  # caller's number rather than whatever the ambient environment happens to carry.
  sweep_home coder-alice-hang 15 15
  sweep_home coder-alice-killed 15 15
  rows="$(sweep_row hang alice coder-alice-hang running)"
  export STUB_EXEC_RC=124

  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
    STUB_PS_OUT="${rows}" PROBE_TIMEOUT=7 bash "${SCRIPT}" --all
  [ "${status}" -eq 0 ]
  assert_eq "it says the container never answered, and bounds it by the caller's cap" \
    'warning: coder-alice-hang did not answer within 7s - the sweep cannot read its profile' \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_not_match "a container that hung is not called an unrendered boot" \
    'the boot render has not run' "${output}"
  assert_not_match "and no restart is ordered for a render that already ran" \
    'restart the workspace' "${output}"
  assert_eq "the exec was bounded by the same cap it just named" "1" \
    "$(grep -c '^timeout -k 2 7 docker exec -- coder-alice-hang ' "${STUB_LOG}/timeout.log" || true)"
  assert_eq "counted once, as a warning" 'summary: 0 ok, 1 warnings, 0 failed' \
    "${output##*$'\n'}"

  # The other half of the same branch: timeout(1) escalates to 137 when the exec
  # ignores SIGTERM, and that is the same finding said once.
  rows="$(sweep_row killed alice coder-alice-killed running)"
  export STUB_EXEC_RC=137
  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
    STUB_PS_OUT="${rows}" PROBE_TIMEOUT=7 bash "${SCRIPT}" --all
  [ "${status}" -eq 0 ]
  assert_eq "a killed exec is the same verdict, not a missing profile" \
    'warning: coder-alice-killed did not answer within 7s - the sweep cannot read its profile' \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_not_match "and it says nothing about a boot that never ran" \
    'the boot render has not run' "${output}"
  assert_eq "both hung containers, each read exactly once" \
    "$(printf '%s\n%s' 'coder-alice-hang' 'coder-alice-killed')" "$(sweep_exec_targets)"
}

@test "subagent-check: --all says so when docker refuses the exec" {
  local rows
  use_sweep_stubs
  # 126 is docker itself refusing - a paused container, a revoked permission - and it
  # is neither of the two states the sweep already distinguishes: the profile may be
  # sitting right there, readable the moment docker answers. Only cat's own 1 and 2
  # mean "that file is not there", so anything else has to say it could not be read
  # rather than sending the operator to restart a workspace whose boot ran fine.
  sweep_home coder-alice-refused 15 15
  rows="$(sweep_row refused alice coder-alice-refused running)"
  export STUB_EXEC_RC=126

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "it names the refusal and the status docker gave back" \
    'warning: coder-alice-refused could not be read (docker exec returned 126) - its profile says nothing' \
    "$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_not_match "a refused exec is not reported as a boot that never rendered" \
    'the boot render has not run' "${output}"
  assert_not_match "it is not called a missing profile at all" 'no profile at' "${output}"
  assert_not_match "and no restart is ordered for a refusal" 'restart the workspace' \
    "${output}"
  assert_eq "counted once, as a warning" 'summary: 0 ok, 1 warnings, 0 failed' \
    "${output##*$'\n'}"
  assert_eq "the sweep asked that container, and only that one" \
    "coder-alice-refused" "$(sweep_exec_targets)"
}

@test "subagent-check: --all drops a row that is not four columns instead of guessing at it" {
  local rows short_row
  use_sweep_stubs
  # A truncated listing line has no state column. Guessing at it is not harmless:
  # with the state missing, the parser hands the container name to the state slot,
  # reads "not running", and reports a container that is up as stopped. sweep_workspaces
  # drops the row on the field count, so it earns no phase line, no verdict, no count,
  # and above all no exec into a container whose state nobody actually read. It is not
  # swallowed either: the sweep counts what the daemon listed against what it judged
  # and prints the difference, so a row lost to its shape is said aloud at the foot of
  # the report rather than leaving a fleet of one where a fleet of two was listed. The
  # profile exists on purpose: the row is dropped for its shape, not for its bytes.
  sweep_home coder-alice-evo 15 15
  sweep_home coder-alice-short 15 15
  short_row="short${SWEEP_TAB}alice${SWEEP_TAB}coder-alice-short"
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'"${short_row}"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "only the complete row is judged, exactly once, and the drop is counted" \
    "$(printf '%s\n%s\n%s' '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      'note: 1 of the 2 rows this daemon listed were not judged - a DinD sidecar row is expected among them, and anything else is a row that was not four usable columns')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning|note): ')"
  assert_not_match "the short row earns no phase line" 'short \(coder-alice-short\)' \
    "${output}"
  assert_not_match "and no verdict, least of all a stopped one" 'coder-alice-short' \
    "${output}"
  assert_eq "a container whose state nobody read is never exec'd into" \
    "coder-alice-evo" "$(sweep_exec_targets)"
  assert_eq "the dropped row is counted as neither ok, warning, nor failure" \
    'summary: 1 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all drops a four-column row whose state column is empty" {
  local rows stateless_row
  use_sweep_stubs
  # The field count alone left this hole open. docker prints an empty {{.State}} for a
  # container it never classified, and that row carries all four columns, so it clears
  # NF == 4 and reaches the loop - where it is neither running nor stopped, which is
  # the one state the sweep has no reading for. Exec-ing into it and reporting what
  # comes back would print a verdict built on a state nobody read. sweep_workspaces
  # requires every one of the four fields to carry something, so this row goes the way
  # of the short one above - and is counted by the same note, because a row the daemon
  # listed and the sweep silently skipped is indistinguishable from a workspace nobody
  # enumerated. The profile exists on purpose: the row is dropped for the
  # empty column, not for its bytes, and a container that would have answered is the
  # point - only the state can say whether it should be asked.
  sweep_home coder-alice-evo 15 15
  sweep_home c-z 4 7
  stateless_row="w3${SWEEP_TAB}carol${SWEEP_TAB}c-z${SWEEP_TAB}"
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'"${stateless_row}"

  run_sweep "${rows}" --json
  [ "${status}" -eq 0 ]
  assert_eq "only the row carrying a state is judged, exactly once, and the drop is counted" \
    "$(printf '%s\n%s\n%s' '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      'note: 1 of the 2 rows this daemon listed were not judged - a DinD sidecar row is expected among them, and anything else is a row that was not four usable columns')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning|note): ')"
  assert_eq "and the object is the surviving row's alone" \
    '{"workspace":"evo","owner":"alice","container":"coder-alice-evo","running":true,"max_concurrent":15,"fleet_width":15,"verdict":"ok","remedy":null}' \
    "$(printf '%s\n' "${output}" | grep '^{')"
  # Escaped because assert_not_match hands the pattern to grep -E, where bare
  # parentheses are grouping and would never match the literal ones phase() prints.
  assert_not_match "the stateless row earns no phase line" 'w3 \(c-z\)' "${output}"
  assert_not_match "its workspace name reaches neither channel" 'w3' "${output}"
  assert_not_match "nor its owner" 'carol' "${output}"
  assert_not_match "nor its container, which is the name an exec would have used" 'c-z' \
    "${output}"
  assert_eq "a container with no state to judge is never exec'd into" \
    "coder-alice-evo" "$(sweep_exec_targets)"
  assert_eq "the dropped row is counted as neither ok, warning, nor failure" \
    'summary: 1 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all blames the caller for a corrupted PROBE_TIMEOUT, not the daemon" {
  local rows
  use_sweep_stubs
  # The cap is checked before anything reaches timeout(1), because a non-numeric one
  # makes the binary itself fail and the sweep would then tell the operator the daemon
  # will not answer. That is the caller's environment talking, and the refusal has to
  # say so by name and value before a single container is listed.
  rows="$(sweep_row evo alice coder-alice-evo running)"

  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
    STUB_PS_OUT="${rows}" PROBE_TIMEOUT=abc bash "${SCRIPT}" --all
  [ "${status}" -eq 1 ]
  assert_eq "it names the variable and the value it cannot use" \
    "error: PROBE_TIMEOUT='abc' is not a whole number of seconds" \
    "$(printf '%s\n' "${output}" | grep '^error: ')"
  assert_not_match "the daemon is not blamed for the caller's own environment" \
    'docker daemon reachable' "${output}"
  assert_not_match "nor is any listing failure claimed at all" 'cannot list containers' \
    "${output}"
  assert_not_match "and no section heading stands where a report never started" \
    '== subagent width sweep ==' "${output}"
  assert_eq "the daemon was never asked for a listing" "" \
    "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
  assert_eq "so no container was read either" "" "$(sweep_exec_targets)"
}

@test "subagent-check: --all refuses a PROBE_TIMEOUT that caps nothing" {
  local rows v
  use_sweep_stubs
  # All digits is not the same thing as a cap. timeout(1) reads 0 as "no limit", so a
  # caller that set PROBE_TIMEOUT=0 would get an unbounded sweep while believing every
  # docker call was bounded - and a daemon that stops answering would hang the run
  # rather than report one. That value passes the non-numeric arm above untouched, so
  # host_guard has to answer it separately, before the listing. 00 travels the same
  # path: it is all digits and zero to the comparison, so it is refused with the same
  # words, and it is what catches an off-by-one in that comparison.
  rows="$(sweep_row evo alice coder-alice-evo running)"

  for v in 0 00; do
    run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER HOME="${BATS_TEST_TMPDIR}" \
      STUB_PS_OUT="${rows}" PROBE_TIMEOUT="${v}" bash "${SCRIPT}" --all
    [ "${status}" -eq 1 ]
    assert_eq "a cap of '${v}' is refused as the no-limit it is, by name and value" \
      "error: PROBE_TIMEOUT='${v}' sets no cap: timeout(1) reads 0 as unlimited" \
      "$(printf '%s\n' "${output}" | grep '^error: ')"
    assert_not_match "the digits arm is not what answered, so the caller is not told" \
      'is not a whole number' "${output}"
    assert_not_match "no section heading stands where a report never started" \
      '== subagent width sweep ==' "${output}"
    assert_not_match "and the daemon is not blamed for the caller's own environment" \
      'docker daemon reachable' "${output}"
    assert_eq "the daemon was never asked for a listing" "" \
      "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
    assert_eq "so no container was read either" "" "$(sweep_exec_targets)"
  done
}

@test "subagent-check: --all says so when every row the daemon listed was unusable" {
  local rows
  use_sweep_stubs
  # A tab inside coder.workspace_name is only bytes to docker, so it reaches the sweep as
  # a five-field row and the four-column filter drops it. With nothing left, the old
  # silence printed the empty-daemon line, which is a different fact: this host does hold
  # workspaces, the sweep just could not read any of them, and an operator sent to check
  # whether the daemon is up is being asked to look at the wrong thing.
  sweep_home coder-alice-weird 15 15
  rows="we${SWEEP_TAB}ird${SWEEP_TAB}alice${SWEEP_TAB}coder-alice-weird${SWEEP_TAB}running"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the note counts the rows the daemon named, none of them judged" \
    'note: the daemon listed 1 row(s), none of which was a workspace this sweep could judge' \
    "$(printf '%s\n' "${output}" | grep '^note: ')"
  assert_not_match "and the empty-daemon line is not the answer here" 'nothing to sweep' "${output}"
  assert_not_match "nor is the partial note fired on top of it, since nothing was judged" \
    'were not judged' "${output}"
  assert_eq "no row was judged, so the report carries no phase line at all" "" \
    "$(printf '%s\n' "${output}" | grep '^-> ')"
  assert_not_match "the unusable row earns no verdict" 'coder-alice-weird' "${output}"
  assert_eq "and no container was exec'd into on the strength of a row nobody parsed" "" \
    "$(sweep_exec_targets)"
  assert_eq "an unusable row counts as neither ok, warning, nor failure" \
    'summary: 0 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all counts a label that split its own row across two lines" {
  local rows
  use_sweep_stubs
  # docker prints label bytes as they are, so a newline inside coder.workspace_name
  # arrives as two lines: an orphan field, then the tail of the row carrying all four
  # columns. The tail is judgeable and is judged; the orphan is dropped. The count is the
  # finding - a report that said nothing would leave the operator with one workspace
  # where the daemon named a container, and no way to tell the two apart.
  sweep_home coder-alice-two 15 15
  rows="two"$'\n'"lines${SWEEP_TAB}alice${SWEEP_TAB}coder-alice-two${SWEEP_TAB}running"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the surviving half is judged, and the orphan is counted by the note" \
    "$(printf '%s\n%s\n%s' \
      '-> lines (coder-alice-two)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      'note: 1 of the 2 rows this daemon listed were not judged - a DinD sidecar row is expected among them, and anything else is a row that was not four usable columns')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning|note): ')"
  assert_not_match "the orphan field earned no phase line of its own" '^-> two (' "${output}"
  assert_eq "exactly the judgeable container was read" "coder-alice-two" "$(sweep_exec_targets)"
  assert_eq "the judged row is counted once and the dropped row not at all" \
    'summary: 1 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all does not count the DinD sidecar among the rows it failed to judge" {
  local rows
  use_sweep_stubs
  # Load-bearing, and the reason the note is allowed to exist at all: the sidecar carries
  # coder.workspace_id, so the daemon lists it on every host that runs one. If it were
  # counted as listed but unjudged, this note would print at the foot of every sweep on
  # every healthy host, and the one line that says something went wrong would be noise.
  # It is excluded from the count and from the loop by the same name test.
  sweep_home coder-alice-evo 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  rows="${rows}$(sweep_row evo alice coder-alice-evo-dind-sidecar running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "a fleet with nothing wrong with it prints no note at all" "" \
    "$(printf '%s\n' "${output}" | grep '^note: ')"
  assert_not_match "the sidecar is not counted as a row this sweep failed to judge" \
    'were not judged' "${output}"
  assert_eq "one workspace judged, listed and judged in equal measure" \
    'summary: 1 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
  assert_eq "and the workspace behind that sidecar was still read" "coder-alice-evo" \
    "$(sweep_exec_targets)"
}

@test "subagent-check: --all does not count a docker stderr notice as a row it failed to judge" {
  local rows
  use_sweep_stubs
  # The listing is read on stdout alone. Merging the daemon's stderr onto it was the
  # defect: a CLI or `sudo docker` notice landing on the same stream as the table was
  # tallied by the "is this line non-empty" counter as a container this sweep failed to
  # judge, so the one note that announces a problem printed on a fleet with nothing
  # wrong with it - the dishonesty the note exists to catch, manufactured out of noise.
  # The notice still has to be heard, because a daemon that refused is the thing an
  # operator has to be told about, so it rides stderr and the counters read rows only.
  sweep_home coder-alice-evo 15 15
  sweep_home coder-alice-narrow 4 15
  sweep_home coder-alice-weird 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  rows="${rows}$(sweep_row narrow alice coder-alice-narrow running)"
  export STUB_PS_ERR='WARNING: bridge-nf-call-iptables is disabled'

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_match "the notice is still printed, on the channel the operator reads" \
    'bridge-nf-call-iptables' "${output}"
  # This is the assertion that notices the merge coming back. Captured into the
  # answer, the notice was never printed at all, so a run with 2>&1 restored dies
  # here rather than two lines further down. The next one keeps the report's own
  # stdout to its verdicts: the daemon's noise belongs to stderr, and the note the
  # merge used to fabricate belongs to neither stream.
  assert_not_match "and it never lands on the report's own stdout" \
    'bridge-nf-call-iptables' "$(sweep_stdout "${rows}")"
  assert_not_match "and it earned no place among the rows this sweep failed to judge" \
    'were not judged' "${output}"
  assert_eq "both workspaces were judged, exactly as if the notice had never printed" \
    "$(printf '%s\n%s\n%s\n%s' \
      '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      '-> narrow (coder-alice-narrow)' \
      'warning: max_concurrent = 4 is below the fleet width 15')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning): ')"
  assert_eq "and the summary counts the fleet it judged, not the noise beside it" \
    'summary: 1 ok, 1 warnings, 0 failed' "${output##*$'\n'}"

  # The guard has to keep a real note alive: with one genuinely unusable row among the
  # two good ones, the note prints and says 1 of 3, which is the arithmetic only a
  # row-shaped counter can produce. Before the guard it said 2 of 4 here.
  rows="${rows}"$'\n'"we${SWEEP_TAB}ird${SWEEP_TAB}alice${SWEEP_TAB}coder-alice-weird${SWEEP_TAB}running"
  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_match "one unusable row out of three listed, the stderr line excluded from both" \
    'note: 1 of the 3 rows this daemon listed were not judged - a DinD sidecar row is expected among them, and anything else is a row that was not four usable columns' \
    "${output}"
  assert_eq "the two good rows still carry their verdicts" \
    'summary: 1 ok, 1 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all does not count a blank line the daemon printed as a named row" {
  local rows
  use_sweep_stubs
  # docker's --format cannot print a line of nothing but blanks, but a wrapper CLI on
  # the other side of DOCKER_BIN can, and the listed counter reads the answer line by
  # line. A blank it tallied would print the same fabricated note the stderr merge
  # used to print - the sweep accusing itself of dropping a container it never had.
  # A row the daemon really named still has to be counted, garbled or not, so the
  # exclusion is of blanks and not of anything the counter does not like.
  sweep_home coder-alice-evo 15 15
  sweep_home coder-alice-narrow 4 15
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  rows="${rows}$(sweep_row narrow alice coder-alice-narrow running)"$'\n'
  rows="${rows} 	   "

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_not_match "a line of blanks is not a container this sweep failed to judge" \
    'were not judged' "${output}"
  assert_eq "both real rows were still judged, blanks or no blanks" \
    "$(printf '%s\n%s\n%s\n%s' \
      '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      '-> narrow (coder-alice-narrow)' \
      'warning: max_concurrent = 4 is below the fleet width 15')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning): ')"
  assert_eq "and the summary counts two workspaces, not three" \
    'summary: 1 ok, 1 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all drops a field past any length a Coder label can reach" {
  local rows long_owner long_ws own255 own256 blob_owner blob_ws
  use_sweep_stubs
  # A field past 255 characters is no Coder name, and letting one through would paste the
  # blob straight into a phase line and a JSON string. The bound is the finding as much
  # as the drop is: 255 is the longest label the sweep must keep, 256 the first it must
  # drop, and the note has to count what it dropped rather than lose it.
  long_owner="o$(printf 'x%.0s' {1..300})"
  long_ws="w$(printf 'y%.0s' {1..300})"
  own255="o$(printf 'z%.0s' {1..254})"
  own256="o$(printf 'z%.0s' {1..255})"
  blob_owner="$(printf 'x%.0s' {1..60})"
  blob_ws="$(printf 'y%.0s' {1..60})"
  sweep_home coder-alice-evo 15 15
  sweep_home c-longowner 15 15
  sweep_home c-longws 15 15
  sweep_home c-own255 15 15
  sweep_home c-own256 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  rows="${rows}$(sweep_row ws "${long_owner}" c-longowner running)"$'\n'
  rows="${rows}$(sweep_row "${long_ws}" bob c-longws running)"$'\n'
  rows="${rows}$(sweep_row w255 "${own255}" c-own255 running)"$'\n'
  rows="${rows}$(sweep_row w256 "${own256}" c-own256 running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "the three over-long rows are counted, the two within the bound are judged" \
    "$(printf '%s\n%s\n%s\n%s\n%s' \
      '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      '-> w255 (c-own255)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      'note: 3 of the 5 rows this daemon listed were not judged - a DinD sidecar row is expected among them, and anything else is a row that was not four usable columns')" \
    "$(printf '%s\n' "${output}" | grep -E '^-> |^(ok|warning|note): ')"
  assert_not_match "no 300-character owner blob reaches the report" "${blob_owner}" "${output}"
  assert_not_match "and no 300-character workspace blob does either" "${blob_ws}" "${output}"
  assert_eq "a field nobody parsed is never exec'd into" \
    "$(printf '%s\n%s' 'coder-alice-evo' 'c-own255')" "$(sweep_exec_targets)"
  assert_eq "the two bound-respecting rows are the only ones counted" \
    'summary: 2 ok, 0 warnings, 0 failed' "${output##*$'\n'}"
}

@test "subagent-check: --all puts the container behind -- so a label is never a docker flag" {
  local rows
  use_sweep_stubs
  # read_profile runs `docker exec -- <container>`. The -- is not decoration: the
  # container name here is a label value, and docker reads an option-looking one as its
  # own flag, so the exec would address a different container while the sweep printed the
  # profile it read as this workspace's verdict. The stub takes either form, so only the
  # argv it recorded can pin the -- down. -rf is the shape that would be eaten.
  sweep_home coder-alice-evo 15 15
  sweep_home "-rf" 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"$'\n'"$(sweep_row dash bob "-rf" running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  assert_eq "every exec carries -- in the field docker reads as the container name" "2" \
    "$(awk -F'\t' '$2 == "exec" && $3 == "--"' "${STUB_LOG}/docker" | grep -c .)"
  assert_eq "and no exec was issued without it" "0" \
    "$(awk -F'\t' '$2 == "exec" && $3 != "--"' "${STUB_LOG}/docker" | grep -c . || true)"
  assert_eq "the container follows the --, name and all, even one that starts with a dash" \
    "$(printf '%s\n%s' 'exec | -- | coder-alice-evo' 'exec | -- | -rf')" \
    "$(awk -F'\t' '$2 == "exec" { print $2 " | " $3 " | " $4 }' "${STUB_LOG}/docker")"
  assert_eq "the same argv is what timeout(1) bounded, -- included" "1" \
    "$(grep -c '^timeout -k 2 20 docker exec -- coder-alice-evo ' "${STUB_LOG}/timeout.log")"
  assert_eq "so both containers really were read, the option-shaped one included" \
    "$(printf '%s\n%s' 'coder-alice-evo' '-rf')" "$(sweep_exec_targets)"
}

@test "subagent-check: --all refuses a host with no timeout(1) instead of blaming the daemon" {
  local rows isolated
  use_sweep_stubs
  # Every daemon call goes through timeout(1). On a host without it the binary is missing,
  # every probe dies with "command not found", and the sweep reports an unreachable
  # daemon - which sends the operator to restart something that is answering perfectly.
  # The refusal has to name the binary that is not there.
  #
  # A non-executable decoy on the PATH is not the way to reach this branch: bash reports a
  # non-executable file it finds on PATH from `command -v`, decoys included (the same
  # behaviour tests/bats/common.bats pins for capped_run), so the host under test gets a
  # PATH holding no timeout file at all, plus the two binaries the CLI needs to get as far
  # as the guard and its own docker.
  isolated="${BATS_TEST_TMPDIR}/no-timeout"
  mkdir -p "${isolated}"
  write_docker_stub "${isolated}/docker"
  ln -s "$(command -v bash)" "${isolated}/bash"
  ln -s "$(command -v dirname)" "${isolated}/dirname"
  assert_eq "the PATH this run hands the CLI holds no timeout(1) anywhere" "" \
    "$(PATH="${isolated}" bash -c 'command -v timeout' 2>/dev/null || true)"

  sweep_home coder-alice-evo 15 15
  rows="$(sweep_row evo alice coder-alice-evo running)"

  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER PATH="${isolated}" \
    HOME="${BATS_TEST_TMPDIR}" STUB_PS_OUT="${rows}" bash "${SCRIPT}" --all
  [ "${status}" -eq 1 ]
  assert_eq "it names the binary that is missing, and what it bounds" \
    'error: cannot bound any daemon call - timeout(1) is not on this host' \
    "$(printf '%s\n' "${output}" | grep '^error: ')"
  assert_not_match "the daemon is not blamed for a missing coreutils binary" \
    'docker daemon reachable' "${output}"
  assert_not_match "and no listing failure is claimed at all" 'cannot list containers' "${output}"
  assert_not_match "the docker CLI is not the thing reported missing" \
    'the docker CLI is not on this host' "${output}"
  assert_not_match "no section heading stands where a report never started" \
    '== subagent width sweep ==' "${output}"
  assert_eq "the daemon was never asked for a listing" "" \
    "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
  assert_eq "so no container was read either" "" "$(sweep_exec_targets)"
}

@test "subagent-check: --all and --config give one absurd width the very same verdict" {
  local rows cfg sweep_a sweep_b solo_a solo_b stdout rc=0
  use_sweep_stubs
  # The parameter is capped at 32, so a digit run of twenty is a typo or a corrupted
  # file - and it is not comparable either: bash errors on the arithmetic test and lets
  # both branches fall through, which reported a corrupted profile as the shipped state.
  # Clearing the digits instead was worse, because the missing-line branch then told the
  # operator their max_concurrent is absent when it sits there plainly. The two paths
  # share this verdict word for word, which is the whole reason the sweep reuses the
  # single-profile readers rather than carrying its own parser.
  sweep_home coder-alice-hugefw 4 99999999999999999999
  sweep_home coder-alice-hugecw 99999999999999999999 15
  rows="$(sweep_row hugefw alice coder-alice-hugefw running)"$'\n'
  rows="${rows}$(sweep_row hugecw alice coder-alice-hugecw running)"

  run_sweep "${rows}"
  [ "${status}" -eq 0 ]
  sweep_a="$(printf '%s\n' "${output}" | grep '^warning: ' | head -n 1)"
  sweep_b="$(printf '%s\n' "${output}" | grep '^warning: ' | tail -n 1)"
  assert_eq "a ceiling this long gets its own verdict, verbatim, on the sweep" \
    'warning: max_concurrent = 4 against fleet-width = 99999999999999999999 is not a width this stack can mean (the parameter is capped at 32)' \
    "${sweep_a}"
  assert_eq "and so does a max_concurrent this long" \
    'warning: max_concurrent = 99999999999999999999 against fleet-width = 15 is not a width this stack can mean (the parameter is capped at 32)' \
    "${sweep_b}"
  assert_not_match "a line that is present is not reported as absent" \
    "carries no 'max_concurrent' line" "${output}"
  assert_not_match "and a ceiling that is present is not reported as one that predates it" \
    "no '# fleet-width:' line" "${output}"
  assert_eq "both rows are warnings and neither is an ok" \
    'summary: 0 ok, 2 warnings, 0 failed' "${output##*$'\n'}"

  # The same two profiles through the single-profile path, and the two answers compared.
  cfg="${BATS_TEST_TMPDIR}/huge-fleet.toml"
  write_profile "${cfg}" 4 99999999999999999999 agent-swarm 1 -
  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  solo_a="$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_eq "the two paths say the identical thing about the identical bytes" \
    "${sweep_a}" "${solo_a}"

  cfg="${BATS_TEST_TMPDIR}/huge-width.toml"
  write_profile "${cfg}" 99999999999999999999 15 agent-swarm 1 -
  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  solo_b="$(printf '%s\n' "${output}" | grep '^warning: ')"
  assert_eq "and the same holds for the other number in the pair" \
    "${sweep_b}" "${solo_b}"

  # The machine channel gets nulls, not the absurd digits: an object that carried
  # 99999999999999999999 as max_concurrent would hand a dashboard the corrupted file as
  # the width a fleet really has.
  stdout="$(sweep_stdout "${rows}" --json)" || rc=$?
  assert_eq "a sweep of absurd widths is still a clean run without --strict" "0" "${rc}"
  assert_eq "both objects carry null for a pair that was never a width" "2" \
    "$(printf '%s\n' "${stdout}" | grep -c '"max_concurrent":null,"fleet_width":null')"
}

@test "subagent-check: --all keeps one control byte from taking the JSON channel down" {
  local rows stdout line rc=0 parsed
  use_sweep_stubs
  # A coder.workspace_name label is operator-typed text. One raw 0x01 in it used to make
  # every line of the --json stdout unparseable, so a fleet of forty workspaces vanished
  # from the machine channel over one byte in one label: RFC 8259 forbids a raw C0 control
  # byte inside a string, and json_escape emits no escape for one, so the byte has to go
  # and the line still has to parse. Below fleet width on purpose, so the label rides the
  # remedy as well and both fields the sweep composes out of it are in play.
  sweep_home coder-alice-ctl 4 7
  rows="$(printf 'a\001b\talice\tcoder-alice-ctl\trunning')"

  stdout="$(sweep_stdout "${rows}" --json)" || true
  while IFS= read -r line; do
    if [ -n "${line}" ]; then
      printf '%s\n' "${line}" | python3 -m json.tool >/dev/null || rc=$?
    fi
  done <<<"${stdout}"
  assert_eq "the object is still one a parser accepts, byte stripped and all" "0" "${rc}"
  assert_eq "and the workspace is not lost from the machine channel" "1" \
    "$(printf '%s\n' "${stdout}" | grep -c .)"
  assert_eq "the control byte is gone from both label fields, not left raw in either" \
    '{"workspace":"ab","owner":"alice","container":"coder-alice-ctl","running":true,"max_concurrent":4,"fleet_width":7,"verdict":"warning","remedy":"coder update alice/ab --parameter grok_subagent_max_concurrent=7"}' \
    "${stdout}"
  parsed="$(printf '%s\n' "${stdout}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print("%s|%s" % (d["workspace"], d["remedy"]))')"
  assert_eq "and it comes back gone through the parser, in the command too" \
    "ab|coder update alice/ab --parameter grok_subagent_max_concurrent=7" "${parsed}"
}

@test "subagent-check: the six sweep functions each answer for one row" {
  local out rc=0 jsonf="${BATS_TEST_TMPDIR}/sweep.json" errf="${BATS_TEST_TMPDIR}/sweep.err"
  use_sweep_stubs
  load_cli_functions profile_table profile_has_table profile_line profile_int \
    profile_fleet_width host_guard workspace_rows read_profile judge_width \
    sweep_workspaces sweep_finish
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"

  # The two daemon reads, called for themselves. workspace_rows is the listing with
  # nothing taken off it - the daemon's own answer, sidecar row and nameless row
  # included - because filtering moved into sweep_workspaces, which has to count what
  # the daemon named and what it could judge out of the very same answer. One `docker
  # ps` is the whole truth for both numbers; a second call could see a different fleet.
  export STUB_PS_OUT
  STUB_PS_OUT="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  STUB_PS_OUT="${STUB_PS_OUT}$(sweep_row evo alice coder-alice-evo-dind-sidecar running)"$'\n'
  STUB_PS_OUT="${STUB_PS_OUT}$(sweep_row '' alice coder-alice-namless running)"
  assert_eq "workspace_rows prints the daemon's answer exactly as the daemon printed it" \
    "${STUB_PS_OUT}" "$(workspace_rows)"
  # The daemon's words and the daemon's table are two different things, and the
  # counters below read the second one line by line. Merging them was the defect: a
  # `sudo docker` notice on the answer's stream was tallied as a container this sweep
  # failed to judge, so the one note that announces a problem fired on a healthy host.
  export STUB_PS_ERR
  STUB_PS_ERR='WARNING: bridge-nf-call-iptables is disabled'
  local merged="" noticed=""
  merged="$(workspace_rows 2>"${BATS_TEST_TMPDIR}/ps.err")"
  noticed="$(cat "${BATS_TEST_TMPDIR}/ps.err")"
  assert_eq "the answer stays the three rows, with nothing of the notice in it" \
    "${STUB_PS_OUT}" "${merged}"
  assert_match "and the notice reaches the operator on stderr, where it belongs" \
    'bridge-nf-call-iptables' "${noticed}"
  unset STUB_PS_ERR
  sweep_home coder-alice-evo 15 15
  assert_eq "read_profile prints the container's own rendered profile, bytes for bytes" \
    "$(cat "${STUB_EXEC_HOME_DIR}/coder-alice-evo/.grok/config.toml")" \
    "$(read_profile coder-alice-evo)"
  rc=0
  read_profile coder-alice-nosuchcontainer >/dev/null 2>&1 || rc=$?
  [ "${rc}" -ne 0 ]

  # judge_width reads CONFIG, which is exactly how sweep_workspaces drives it: one row,
  # one verdict line, one count, and the remedy recorded for the --json object.
  CONFIG="${BATS_TEST_TMPDIR}/judge.toml"
  write_profile "${CONFIG}" 4 7 agent-swarm 1 -
  SWEEP_WORKSPACE="narrow"
  SWEEP_OWNER="alice"
  SWEEP_CONTAINER="coder-alice-narrow"
  SWEEP_VERDICT=""
  SWEEP_REMEDY=""
  out="${BATS_TEST_TMPDIR}/judge.out"
  judge_width "coder-alice-narrow" >"${out}" 2>&1
  assert_eq "the warning and its remedy note, and nothing else" \
    "$(printf '%s\n%s' \
      'warning: max_concurrent = 4 is below the fleet width 7' \
      'note: coder update alice/narrow --parameter grok_subagent_max_concurrent=7')" \
    "$(cat "${out}")"
  assert_eq "one warning, no ok, no failure" "1" "${SUMMARY_WARN}"
  assert_eq "no ok" "0" "${SUMMARY_OK}"
  assert_eq "no failure" "0" "${SUMMARY_FAIL}"
  assert_eq "the verdict the object will carry" "warning" "${SWEEP_VERDICT}"
  assert_eq "the note printed is the remedy recorded, the same string both channels" \
    "coder update alice/narrow --parameter grok_subagent_max_concurrent=7" "${SWEEP_REMEDY}"

  # sweep_finish only reports: the counters were made by the rows, and it chooses the
  # channel and the code. In a subshell, because it closes the run with exit.
  JSON_MODE=1 STRICT=0
  SWEEP_JSON='{"workspace":"narrow","owner":"alice","container":"coder-alice-narrow","running":true,"max_concurrent":4,"fleet_width":7,"verdict":"warning","remedy":"coder update alice/narrow --parameter grok_subagent_max_concurrent=7"}'$'\n'
  rc=0
  ( sweep_finish >"${jsonf}" 2>"${errf}" ) || rc=$?
  assert_eq "a warning is clean without --strict" "0" "${rc}"
  assert_contains_file "the object stands alone on stdout" "${jsonf}" '"verdict":"warning"'
  assert_not_match "and the summary is not on stdout with it" 'summary: ' "$(cat "${jsonf}")"
  assert_contains_file "the counts went to stderr, where the prose always goes" "${errf}" \
    'summary: 0 ok, 1 warnings, 0 failed'
  STRICT=1
  rc=0
  ( sweep_finish >/dev/null 2>&1 ) || rc=$?
  assert_eq "the same counters, promoted under --strict" "1" "${rc}"
  STRICT=0
  JSON_MODE=""

  # sweep_workspaces: one phase line and one verdict per row, whatever the row says. In
  # a subshell, because it arms an EXIT trap for its temp files.
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  SWEEP_JSON=""
  sweep_home coder-alice-evo 15 15
  sweep_home coder-alice-narrow 4 7
  export STUB_PS_OUT
  STUB_PS_OUT="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  STUB_PS_OUT="${STUB_PS_OUT}$(sweep_row narrow alice coder-alice-narrow running)"
  out="${BATS_TEST_TMPDIR}/loop.out"
  rc=0
  ( sweep_workspaces >"${out}" 2>&1 ) || rc=$?
  assert_eq "the loop never exits the sweep on a row" "0" "${rc}"
  assert_eq "one phase line per row, and exactly one verdict each" \
    "$(printf '%s\n%s\n%s\n%s' \
      '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      '-> narrow (coder-alice-narrow)' \
      'warning: max_concurrent = 4 is below the fleet width 7')" \
    "$(grep -E '^-> |^(ok|warning): ' "${out}")"
  assert_eq "and each row's own temp file is gone when its row is" "0" \
    "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'subagent-check.*' -type f 2>/dev/null | grep -c . || true)"

  # The other half of the split: the listing above was the daemon's raw answer, and this
  # is the same answer run through the filter. The sidecar is excluded on its name (and
  # excluded from the count with it, which is why the note says one and not two), the
  # row whose name column is empty is not four usable columns, and one row survives.
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  SWEEP_JSON=""
  : >"${STUB_LOG}/docker"
  STUB_PS_OUT="$(sweep_row evo alice coder-alice-evo running)"$'\n'
  STUB_PS_OUT="${STUB_PS_OUT}$(sweep_row evo alice coder-alice-evo-dind-sidecar running)"$'\n'
  STUB_PS_OUT="${STUB_PS_OUT}$(sweep_row '' alice coder-alice-namless running)"
  out="${BATS_TEST_TMPDIR}/filtered.out"
  rc=0
  ( sweep_workspaces; sweep_finish ) >"${out}" 2>&1 || rc=$?
  assert_eq "the filter judges the one usable row and counts the row it dropped" \
    "$(printf '%s\n%s\n%s' \
      '-> evo (coder-alice-evo)' \
      "ok: max_concurrent = 15, the fleet's own width" \
      'note: 1 of the 2 rows this daemon listed were not judged - a DinD sidecar row is expected among them, and anything else is a row that was not four usable columns')" \
    "$(grep -E '^-> |^(ok|warning|note): ' "${out}")"
  assert_eq "so exactly one container was exec'd into, and it is not the sidecar" \
    "coder-alice-evo" "$(sweep_exec_targets)"
  assert_eq "and a row dropped for its shape is neither ok, warning, nor failure" \
    'summary: 1 ok, 0 warnings, 0 failed' "$(tail -n 1 "${out}")"
  assert_eq "which is a clean sweep, so the closed run exits clean on it" "0" "${rc}"

  # host_guard is the gate in front of all of it. In a subshell, because die exits.
  rc=0
  ( CODER_WORKSPACE_ID=1 host_guard ) >"${out}" 2>&1 || rc=$?
  assert_eq "a workspace shell is turned away with its own code" "1" "${rc}"
  assert_contains_file "and told why" "${out}" \
    'error: subagent-check --all is a stack-host run'
  rc=0
  ( unset CODER_WORKSPACE_ID; EVO_T1_DEVCONTAINER=1 host_guard ) >"${out}" 2>&1 || rc=$?
  assert_eq "so is the contributor container" "1" "${rc}"
  CODER_WORKSPACE_ID="" EVO_T1_DEVCONTAINER="" host_guard
  assert_eq "and a host shell holding a docker CLI is let through" "0" "$?"
}

@test "subagent-check: --config still answers when scripts/lib/coder_api.sh is gone" {
  local copy="${BATS_TEST_TMPDIR}/no-daemon-lib" cfg
  use_sweep_stubs
  # scripts/lib/coder_api.sh is the daemon-side helper: stack_timeout bounds every docker
  # call and DOCKER_BIN may hold more than one word, and the single-profile path calls
  # neither. Sourced at the top of the script it made every one-file read depend on a
  # helper that read never needs, so a tree missing that one file could not answer the
  # question a workspace boot actually asks. It is sourced inside the --all branch now,
  # and this is the shape that pins it: the helper gone, both paths run, and only the one
  # that needs it refuses. The copy carries exactly what the CLI can reach - the scripts
  # tree find_lib walks and the marker resolve_repo_root probes for - and it runs from
  # there, never from the checkout.
  mkdir -p "${copy}/scripts"
  cp -a "${REPO_ROOT}/scripts/." "${copy}/scripts/"
  cp -a "${REPO_ROOT}/docker-compose.yml" "${copy}/docker-compose.yml"
  rm -f "${copy}/scripts/lib/coder_api.sh"
  assert_eq "the copy really has no daemon helper to source" "no" \
    "$([ -e "${copy}/scripts/lib/coder_api.sh" ] && echo yes || echo no)"
  assert_eq "and it keeps the one helper both paths do need" "yes" \
    "$([ -f "${copy}/scripts/lib/common.sh" ] && echo yes || echo no)"

  cfg="${BATS_TEST_TMPDIR}/copy.toml"
  write_profile "${cfg}" 15 15 agent-swarm 1 2

  # REPO_ROOT is named because resolve_repo_root tries it before anything else and the
  # Bats runner exports its own: left set, the copy would resolve its helpers out of the
  # real checkout and the run would prove nothing.
  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER REPO_ROOT="${copy}" \
    HOME="${BATS_TEST_TMPDIR}" bash "${copy}/scripts/subagent-check.sh" --config "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the one-profile path never notices the missing daemon helper" \
    '== subagent slots ==' "${output}"
  assert_match "and it still judges the width it was handed" \
    "ok: max_concurrent = 15, the fleet's own width" "${output}"
  assert_match "closing with the summary the contract owes" \
    'summary: 3 ok, 0 warnings, 0 failed' "${output}"
  assert_not_match "and no daemon helper is missed on the way" 'coder_api.sh' "${output}"

  # The sweep is the path that needs the helper, and it refuses by name rather than
  # half-sweeping a fleet with an unbounded docker call.
  run env -u CODER_WORKSPACE_ID -u EVO_T1_DEVCONTAINER REPO_ROOT="${copy}" \
    HOME="${BATS_TEST_TMPDIR}" STUB_PS_OUT="$(sweep_row evo alice coder-alice-evo running)" \
    bash "${copy}/scripts/subagent-check.sh" --all
  [ "${status}" -eq 1 ]
  assert_match "the sweep says what it cannot do and why" \
    'error: cannot sweep the fleet: no scripts/lib/coder_api.sh above' "${output}"
  assert_eq "and that is the last word it speaks" \
    'error: cannot sweep the fleet: no scripts/lib/coder_api.sh above' \
    "$(printf '%s\n' "${output}" | grep '^error: ' | tail -n 1)"
  assert_match "the search stayed inside the copy, where the helper is gone" \
    "${copy}/scripts/lib/coder_api.sh" "${output}"
  assert_not_match "no sweep section printed for a sweep that never started" \
    '== subagent width sweep ==' "${output}"
  assert_not_match "and no summary stands where a report never ran" 'summary: ' "${output}"
  assert_eq "the daemon was never addressed at all" "" \
    "$(cat "${STUB_LOG}/docker" 2>/dev/null || true)"
}
