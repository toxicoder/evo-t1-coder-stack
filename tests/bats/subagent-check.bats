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
  assert_not_match "no unpinned ok from another table" 'writers ride agent-swarm (unpinned' "${output}"
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
