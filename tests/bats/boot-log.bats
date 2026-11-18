#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## boot-log.bats -- hermetic coverage for templates/common/boot-log.lib.sh
#
# The library is the vocabulary every workspace boot body narrates with, and a Coder
# start log is the only thing it produces: nothing parses a boot log for correctness,
# so an operator's eye is the consumer and this suite is the only machine that checks
# the words. Every test drives the shipped file through a real shell and compares
# bytes -- the seven shapes, the three counters, the (+Ns) stamp. Nothing sleeps: the
# clock is a stubbed date(1) and the start of the run is BOOT_T0, so an elapsed second
# is arithmetic the test picked rather than one the calendar happened to hand over.
#
# Two behaviours are pinned because a body leans on them and neither is loud when it
# breaks: the library must never exit the caller (a body owns its own failure policy,
# and bodies run under set -eu), and a clock it cannot read must degrade to 0 instead
# of aborting a boot that was otherwise going fine.
#
# The seam with tests/bats/test_helper.bash is pinned too: bats_strip_boot_lines has
# to recognise exactly what the verbs print, or every other suite's "this body printed
# nothing" claim quietly starts comparing narration instead.
#
# No daemon, no network, no terraform. Every fixture is under BATS_TEST_TMPDIR.
# Usage: bazelisk test //tests:bats_boot_log_test   (from any cwd)

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
BOOT_LIB=""
STUB_BIN=""

setup() {
  REPO_ROOT="$(bats_repo_root)" || skip "cannot locate the checkout from test_helper.bash"
  BOOT_LIB="${REPO_ROOT}/templates/common/boot-log.lib.sh"
  [ -f "${BOOT_LIB}" ] || skip "templates/common/boot-log.lib.sh is not in the tree"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"
  # The driver inherits this shell's environment and the library reads BOOT_* straight
  # out of it, so one counter or BOOT_T0 left over from a neighbouring test would move
  # the exact numbers this suite compares.
  unset BOOT_NAME BOOT_STAGES BOOT_T0 BOOT_OK BOOT_WARN BOOT_FAIL BOOT_STUB_NOW
  cd "${BATS_TEST_TMPDIR}" || return 1
}

# ------------------------------------------------------------------- the drivers

# stub_date <epoch|fail> -- put a date(1) in this test's bin/ that answers <epoch> on
# every call, or exits non-zero when <epoch> is `fail`. The drivers put that bin/ first
# on PATH, so an elapsed term is a number the test chose.
stub_date() {
  local epoch="${1:-}"
  [ -n "${epoch}" ] || { printf 'stub_date: <epoch|fail>\n' >&2; return 2; }
  if [ "${epoch}" = "fail" ]; then
    printf '%s\n' '#!/bin/sh' 'exit 1' >"${STUB_BIN}/date"
  else
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' '${epoch}'" >"${STUB_BIN}/date"
  fi
  chmod 755 "${STUB_BIN}/date"
}

# write_driver <dest> <line...> -- a boot body this suite owns: strict mode, the stub
# bin first on PATH, then the shipped library sourced the way main.tf splices it, then
# the caller's lines. `set -eu` is what the bodies run under, so a verb that fails or
# calls exit takes the driver down with it and the test goes red.
write_driver() {
  local dest="${1:-}"
  [ -n "${dest}" ] || { printf 'write_driver: <dest> <line...>\n' >&2; return 2; }
  shift
  {
    printf '%s\n' 'set -eu'
    printf '%s\n' "PATH=${STUB_BIN}:\$PATH" 'export PATH'
    printf '%s\n' ". \"${BOOT_LIB}\""
    printf '%s\n' "$@"
  } >"${dest}"
}

# write_scripted_shapes <dest> -- the one run every shape test compares against: each
# verb called once, in the order a body reaches for them. Every text is quoted because
# a verb reads exactly one argument; the one-arg test below pins what an unquoted text
# costs.
write_scripted_shapes() {
  write_driver "${1:-}" \
    'boot_begin demo 2' \
    "boot_stage 1 'clone the tree'" \
    "boot_phase 'fetching the tree'" \
    "boot_ok 'tools installed'" \
    "boot_warn 'cache cold'" \
    "boot_note 'second attempt'" \
    "boot_err 'npm exited 1'" \
    'boot_summary'
}

# write_expected_shapes -- the bytes that run owes: seven lines out, one of them on
# stderr, every stamp at zero because the clock is nailed to BOOT_T0.
write_expected_shapes() {
  cat >"${BATS_TEST_TMPDIR}/expected.out" <<'EOF'
== demo: start ==
== demo: stage 1/2: clone the tree == (+0s)
-> fetching the tree (+0s)
ok: tools installed
warning: cache cold
note: second attempt
summary: 1 ok, 1 warnings, 1 failed (+0s, demo)
EOF
  printf '%s\n' 'error: npm exited 1' >"${BATS_TEST_TMPDIR}/expected.err"
}

# drive_shapes <shell> -- run the scripted boot under <shell> and cmp both streams
# against the expected files. A non-zero driver trips bats' errexit, which is the
# exit-code half of the check; the byte comparison is the half that proves the shapes.
drive_shapes() {
  local shell="${1:?}" body="${BATS_TEST_TMPDIR}/body.sh"
  stub_date 1700000000
  write_scripted_shapes "${body}"
  write_expected_shapes
  "${shell}" "${body}" >"${BATS_TEST_TMPDIR}/out" 2>"${BATS_TEST_TMPDIR}/err"
  cmp "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/expected.out"
  cmp "${BATS_TEST_TMPDIR}/err" "${BATS_TEST_TMPDIR}/expected.err"
}

# ------------------------------------------------------------------ the shapes

@test "verbs: the scripted boot prints the seven shapes byte for byte" {
  drive_shapes bash
  # error: goes to stderr and nowhere near stdout, so the two counts are the proof.
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/out" | tr -d ' ')" -eq 7 ]
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/err" | tr -d ' ')" -eq 1 ]
}

@test "verbs: the text arrives verbatim, so a body can name a secret and the library never reads a value" {
  # The library prints what it is handed and nothing else: no expansion, no lookup. A
  # body that holds a token prints the word the body chose, which is the whole of its
  # secret policy.
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/verbatim.sh"
  write_driver "${body}" \
    "boot_phase '\$HOME \${BOOT_NOT_A_KEY}'" \
    'boot_ok "-n not a printf flag"' \
    'boot_note --'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = '-> $HOME ${BOOT_NOT_A_KEY} (+0s)' ]
  [ "${lines[1]}" = 'ok: -n not a printf flag' ]
  [ "${lines[2]}" = 'note: --' ]
}

@test "verbs: one call is one line and takes one argument, so an unquoted text loses its tail" {
  # Two halves of the same seam, both invisible in the log when they break. One line per
  # call: the Coder budget is one 1 MiB stream shared by every body on the agent and the
  # uploader drops the NEWEST lines, so a verb that printed twice per call is what makes
  # the end of a boot vanish. One argument: a body that writes `boot_stage 1 clone the
  # whole tree` keeps only `clone`, which is the trap a body writer hits first.
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/oneline.sh"
  write_driver "${body}" \
    'boot_begin demo 2 extra' \
    'boot_stage 1 clone the whole tree' \
    'boot_ok a b c' \
    'boot_summary'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "== demo: start ==" ]
  [ "${lines[1]}" = "== demo: stage 1/2: clone == (+0s)" ]
  [ "${lines[2]}" = "ok: a" ]
  [ "${lines[3]}" = "summary: 1 ok, 0 warnings, 0 failed (+0s, demo)" ]
}

# -------------------------------------------------------------------- counters

@test "counters: three ok, two warn and one err close as 3 ok, 2 warnings, 1 failed" {
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/count.sh"
  write_driver "${body}" \
    'boot_begin demo 1' \
    'boot_ok one' 'boot_ok two' 'boot_ok three' \
    'boot_warn soft' 'boot_warn softer' \
    'boot_note commentary' \
    'boot_err hard' \
    'boot_summary'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "summary: 3 ok, 2 warnings, 1 failed (+0s, demo)" ]
  [ "${stderr}" = "error: hard" ]
}

@test "counters: boot_begin zeroes what an earlier run raised" {
  # A body that re-begins owes a clean slate: the summary is read as the cost of the
  # run it closes, not of everything the shell has done since the container started.
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/rebegin.sh"
  write_driver "${body}" \
    'boot_begin first 1' 'boot_ok a' 'boot_warn b' 'boot_err c' \
    'boot_begin demo 3' \
    'boot_summary'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "summary: 0 ok, 0 warnings, 0 failed (+0s, demo)" ]
}

# ----------------------------------------------------------------------- clock

@test "clock: at t0 every stamp reads (+0s)" {
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/t0.sh"
  write_driver "${body}" \
    'boot_begin demo 2' 'boot_stage 1 clone' 'boot_phase fetch' 'boot_summary'
  run --separate-stderr bash "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "== demo: start ==" ]
  [ "${lines[1]}" = "== demo: stage 1/2: clone == (+0s)" ]
  [ "${lines[2]}" = "-> fetch (+0s)" ]
  [ "${lines[3]}" = "summary: 0 ok, 0 warnings, 0 failed (+0s, demo)" ]
}

@test "clock: the stamp grows when BOOT_T0 moves, so (+Ns) is elapsed and not decoration" {
  # One fixed clock, one moved start: 1700000042 - 1700000000 = 42 is the arithmetic
  # under test, so the suite pins the subtraction instead of racing a wall clock.
  stub_date 1700000042
  local body="${BATS_TEST_TMPDIR}/later.sh"
  write_driver "${body}" \
    'boot_begin demo 2' \
    'BOOT_T0=1700000000' \
    'boot_stage 1 clone' 'boot_phase fetch' 'boot_summary'
  run --separate-stderr bash "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[1]}" = "== demo: stage 1/2: clone == (+42s)" ]
  [ "${lines[2]}" = "-> fetch (+42s)" ]
  [ "${lines[3]}" = "summary: 0 ok, 0 warnings, 0 failed (+42s, demo)" ]
}

@test "clock: an exported BOOT_T0 is what the verbs measure from, before any boot_begin" {
  stub_date 1700000042
  local body="${BATS_TEST_TMPDIR}/envt0.sh"
  write_driver "${body}" 'boot_phase fetch' 'boot_summary'
  export BOOT_T0=1700000000
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "-> fetch (+42s)" ]
  [ "${lines[1]}" = "summary: 0 ok, 0 warnings, 0 failed (+42s, boot)" ]
}

@test "clock: a date(1) that fails degrades the stamp to 0 and the boot keeps printing" {
  # The bodies run under set -eu, so the `|| printf 0` behind every date call is what
  # keeps a box with a broken clock from dying mid-boot over a number.
  stub_date fail
  local body="${BATS_TEST_TMPDIR}/noclock.sh"
  write_driver "${body}" \
    'boot_begin demo 2' 'boot_stage 1 clone' 'boot_phase fetch' 'boot_ok a' 'boot_summary'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ] || fail "the unreadable clock aborted the boot (status ${status})"
  [ "${lines[0]}" = "== demo: start ==" ]
  [ "${lines[1]}" = "== demo: stage 1/2: clone == (+0s)" ]
  [ "${lines[2]}" = "-> fetch (+0s)" ]
  [ "${lines[3]}" = "ok: a" ]
  [ "${lines[4]}" = "summary: 1 ok, 0 warnings, 0 failed (+0s, demo)" ]
  [ "${stderr}" = "" ]
}

# ---------------------------------------------------------------------- set -u

@test "set -u: every verb runs clean with no prior state and prints its fallbacks" {
  # Nothing above the source line has run: no boot_begin, no counters, no name. Exact
  # equality is the proof -- an unbound read under set -u aborts the driver, truncates
  # stdout, and every comparison below goes red.
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/cold.sh"
  write_driver "${body}" \
    'boot_stage 2 deep' 'boot_phase fetch' 'boot_ok a' 'boot_warn b' \
    'boot_note c' 'boot_err d' 'boot_summary'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "== boot: stage 2/?: deep == (+0s)" ]
  [ "${lines[1]}" = "-> fetch (+0s)" ]
  [ "${lines[2]}" = "ok: a" ]
  [ "${lines[3]}" = "warning: b" ]
  [ "${lines[4]}" = "note: c" ]
  [ "${lines[5]}" = "summary: 1 ok, 1 warnings, 1 failed (+0s, boot)" ]
  [ "${stderr}" = "error: d" ]
}

@test "set -u: boot_summary before any boot_begin prints zeros instead of dying" {
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/orphan-summary.sh"
  write_driver "${body}" 'boot_summary'
  run --separate-stderr sh "${body}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "summary: 0 ok, 0 warnings, 0 failed (+0s, boot)" ]
}

# ----------------------------------------------------------------------- POSIX

@test "POSIX: sh parses the library and prints the same bytes as bash" {
  sh -n "${BOOT_LIB}"
  drive_shapes sh
}

@test "POSIX: dash parses the library and prints the same bytes as bash" {
  command -v dash >/dev/null 2>&1 ||
    skip "dash is not on PATH; the sh run above is the only POSIX shell this box has"
  dash -n "${BOOT_LIB}"
  drive_shapes dash
}

@test "the library never exits the caller: the body reaches its own last line and its own status" {
  # Every boot body sources this file and owns its own failure policy. A verb that
  # called exit, or left a status the caller could not override, would silently end
  # half a boot and still look like the body's own decision.
  stub_date 1700000000
  local body="${BATS_TEST_TMPDIR}/survive.sh" shell
  write_driver "${body}" \
    'boot_begin demo 1' 'boot_stage 1 work' 'boot_phase fetch' 'boot_ok a' \
    'boot_warn b' 'boot_note c' 'boot_err d' 'boot_summary' \
    'printf "caller-alive\n"' \
    'exit 7'
  for shell in bash sh; do
    run --separate-stderr "${shell}" "${body}"
    [ "${status}" -eq 7 ] || fail "${shell}: the library took the exit status (${status}, expected 7)"
    [ "${lines[${#lines[@]} - 1]}" = "caller-alive" ] ||
      fail "${shell}: the body never reached its own last line"
    [ "${stderr}" = "error: d" ]
  done
}

# ------------------------------------------------------------------- the seams

@test "the strip seam: bats_strip_boot_lines reduces the run to what a silent body must not print" {
  # The other suites claim their body printed nothing by stripping this narration first.
  # If a verb's shape drifts away from the strip pattern, those claims start comparing
  # the narration and stay green while doing it, so the pair is pinned from both sides:
  # the frame, the ok: and note: lines, and the summary must all fall out, while
  # warning: and error: deliberately survive.
  drive_shapes bash
  cat "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/err" >"${BATS_TEST_TMPDIR}/all"
  bats_strip_boot_lines "${BATS_TEST_TMPDIR}/all" >"${BATS_TEST_TMPDIR}/stripped"
  printf '%s\n' 'warning: cache cold' 'error: npm exited 1' >"${BATS_TEST_TMPDIR}/expected.stripped"
  cmp "${BATS_TEST_TMPDIR}/stripped" "${BATS_TEST_TMPDIR}/expected.stripped"
}

@test "the splice: a body that interpolates the library gets one copy and runs it under sh" {
  # Terraform hands a body the library by splicing ${boot_log_lib}, and the suites take
  # the same route through bats_render_tftpl. This drives a scratch body of the shape
  # L0 prescribes -- set -u, the splice, then the verbs -- rather than any writer's file.
  stub_date 1700000000
  local tpl="${BATS_TEST_TMPDIR}/body.tftpl" rendered="${BATS_TEST_TMPDIR}/rendered.sh"
  cat >"${tpl}" <<'EOF'
set -eu
${boot_log_lib}
boot_begin fixture 1
boot_stage 1 drive
boot_ok done
boot_summary
EOF
  bats_render_tftpl "${tpl}" "${rendered}"
  [ "$(grep -c '^boot_begin()' "${rendered}")" -eq 1 ] ||
    fail "the splice pasted the library more than once"
  PATH="${STUB_BIN}:${PATH}" sh "${rendered}" >"${BATS_TEST_TMPDIR}/out" 2>"${BATS_TEST_TMPDIR}/err"
  cat >"${BATS_TEST_TMPDIR}/expected.out" <<'EOF'
== fixture: start ==
== fixture: stage 1/1: drive == (+0s)
ok: done
summary: 1 ok, 0 warnings, 0 failed (+0s, fixture)
EOF
  cmp "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/expected.out"
  if [ -s "${BATS_TEST_TMPDIR}/err" ]; then
    fail "the spliced body wrote to stderr: $(cat "${BATS_TEST_TMPDIR}/err")"
  fi
}

# ------------------------------------------------- the wiring in both twins

# The list of narrating bodies is read out of the two main.tf files, never typed here: a
# body main.tf stops handing the library to drops out of these claims on its own, and a
# body wired in next week joins them without anyone editing a test. The awk walks each
# twin, remembers the templatefile() path it is inside of, and reports the path whenever a
# boot_log_lib key appears in the map that follows it.
boot_body_list() {
  local want="${1:-}" flavor tf name cand dir
  for flavor in workspace devcontainer; do
    [ -z "${want}" ] || [ "${flavor}" = "${want}" ] || continue
    tf="${REPO_ROOT}/templates/${flavor}/main.tf"
    [ -f "${tf}" ] || continue
    awk '
      match($0, /templatefile\( *"[^"]+"/) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*\//, "", s)
        gsub(/"/, "", s)
        last = s
      }
      /^[[:space:]]*boot_log_lib[[:space:]]*=/ { if (last != "") print last }
    ' "${tf}" | while IFS= read -r name; do
      for dir in "${REPO_ROOT}/templates/${flavor}" "${REPO_ROOT}/templates/common"; do
        cand="${dir}/${name}"
        if [ -f "${cand}" ]; then
          printf '%s\n' "${cand}"
          break
        fi
      done
    done
  done | sort -u
}

@test "wiring: every body main.tf gives boot_log_lib to interpolates it exactly once" {
  # A body that reads ${boot_log_lib} twice pastes the library twice and the second
  # definition wins, which is invisible until a verb changes under one of the two copies.
  # A body that stopped referencing it still receives the key and prints nothing: the
  # start log reads as a clean boot that did nothing.
  local bodies="${BATS_TEST_TMPDIR}/bodies" f refs
  # Each twin is floored on its own, and not at one shared number: a key dropped from the
  # workspace copy of a body that the devcontainer also declares would leave the union
  # intact and quietly un-narrate half the fleet. The floors are the shipped counts, so a
  # body wired in later only ever raises them, and a key dropped from either twin is red.
  local twin count
  for twin in workspace devcontainer; do
    count="$(boot_body_list "${twin}" | wc -l)"
    [ "${count}" -ge 11 ] || {
      boot_body_list "${twin}" >&2
      fail "templates/${twin}/main.tf hands boot_log_lib to ${count} bodies, under the 11 it must"
    }
  done
  boot_body_list >"${bodies}"
  while IFS= read -r f; do
    refs="$(grep -c '^\${boot_log_lib}$' "${f}")"
    [ "${refs}" -eq 1 ] || {
      printf '%s interpolates the library on %s lines\n' "${f#"${REPO_ROOT}/"}" "${refs}" >&2
      return 1
    }
    # A body carrying its own copy of a verb is the failure this whole test exists to
    # catch: it renders, it parses, it narrates, and it silently diverges the day the
    # shipped library gains a verb or fixes a counter. A definition sitting under a
    # command -v test is not that: it is a fallback for a suite that extracts one
    # function out of the body and runs it without the verbs (agents-seed's swap sweep,
    # tests/bats/config-swap-sweep.bats), and in the real boot the library is already
    # there so the fallback never fires. Anything unguarded is a private copy.
    awk -v name="${f#"${REPO_ROOT}/"}" '
      { line[NR] = $0 }
      match($0, /^[[:space:]]*_?boot_(say|t|begin|stage|phase|ok|warn|note|err|summary)[[:space:]]*\(\)[[:space:]]*\{/) {
        s = substr($0, RSTART, RLENGTH)
        verb = s
        gsub(/[^a-z_]/, "", verb)
        guarded = 0
        for (i = NR - 1; i >= 1 && i >= NR - 3; i--) {
          if (line[i] ~ "command -v " verb "( |$|>)") { guarded = 1; break }
        }
        if (!guarded) { printf "%s:%d defines %s with no command -v guard\n", name, NR, verb; bad = 1 }
      }
      END { exit bad }
    ' "${f}" || return 1
  done <"${bodies}"
}

@test "wiring: no body floods the agent log, which is one 1 MiB budget shared by them all" {
  # Coder caps each workspace agent's logs at 1048576 bytes and drops the newest lines
  # past it (coderd max_logs_length; codersdk/agentsdk/logs.go maxBytesQueued), and every
  # boot body on that agent draws from the same budget. The acceptance rule is about 40
  # narrated lines per body; the busiest shipped body (the startup script) sits at exactly
  # 40 verb calls, so the cap is that plus a small allowance for the stage a later change
  # legitimately adds. The fleet total is the tripwire on the aggregate: at a pessimistic
  # 120 bytes a line it is still a small fraction of the ceiling, and it exists so the sum
  # cannot drift upward while every member looks fine on its own.
  local bodies="${BATS_TEST_TMPDIR}/budget" f calls total=0
  local per_body=48 fleet_total=400
  boot_body_list >"${bodies}"
  while IFS= read -r f; do
    calls="$(grep -cE '^[[:space:]]*(boot_begin|boot_stage|boot_phase|boot_ok|boot_warn|boot_note|boot_err|boot_summary)([[:space:]]|$)' "${f}")"
    if [ "${calls}" -gt "${per_body}" ]; then
      printf '%s makes %s verb calls, over the %s a boot should spend\n' \
        "${f#"${REPO_ROOT}/"}" "${calls}" "${per_body}" >&2
      return 1
    fi
    total=$((total + calls))
  done <"${bodies}"
  if [ "${total}" -gt "${fleet_total}" ]; then
    printf 'the boot bodies make %s verb calls in total, over the %s the shared log budget allows\n' \
      "${total}" "${fleet_total}" >&2
    return 1
  fi
}
