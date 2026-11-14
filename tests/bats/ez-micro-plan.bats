#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ez-micro-plan.bats - hermetic coverage for the micro-plan dispatcher check
#
# templates/common/ez-micro-plan.plan_check.py decides, before a fleet is spawned,
# whether a micro-plan can actually dispatch. What is worth pinning is the eight
# ways that decision has most often lied: a document that never carries the
# `ez-micro-plan v1` marker read as a plan at all; a section that went missing
# silently instead of naming itself; a task block that dropped a key still counted
# as a task; two ready tasks sharing a file, which only stops being a collision once
# a `needs:` orders them; a cycle and an unknown id, both of which otherwise surface
# as a wave that is simply empty; a `calls:` budget that warns forever and never
# blocks; a first wave too narrow to fill the fleet, which is the whole point of the
# gate; and a Ledger that drifted from the task blocks in either direction. Each of
# those gets an asserting test below, driven over one eight-task, three-lane fixture
# that a helper writes into the test's own scratch directory, so the fixture lives in
# exactly one place and a variant mutates a row rather than repeating the document.
#
# Usage: bazelisk test //tests:bats_ez_micro_plan_test   (from any cwd)
# Safety: the suite writes only into its own scratch directory (make_scratch) and
# runs python3 over those files; no network, no docker, no bazelisk, and nothing
# outside the per-test tree is touched. The checker is read from the real checkout.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CHECKER=""
ROOT=""
PLAN=""
PLAN_DIR=""

# The fixture, in one place. A task row is
# id|summary|lane|role|owns|reads|needs|calls|done|report and a lane row is
# lane|owns|role|brief|notes; write_plan renders both tables, so a variant is a
# task_set away rather than a second copy of the document. Every calls: sits at 15
# or below so the clean case is warning-free and a stray warning is a finding.
TASK_ROWS=()
LANE_ROWS=()

# Ledger knobs for the drift tests: ids whose row reads `done`, ids whose row is
# withheld, and one extra row with no task block behind it.
LEDGER_DONE=""
LEDGER_SKIP=""
LEDGER_EXTRA=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CHECKER="${REPO_ROOT}/templates/common/ez-micro-plan.plan_check.py"
  [[ -f ${CHECKER} ]] || skip "templates/common/ez-micro-plan.plan_check.py is not in the tree"
  ROOT="$(make_scratch)/repo"
  PLAN_DIR="${ROOT}/.grok/plans/search-lane"
  PLAN="${PLAN_DIR}/plan.md"
  LEDGER_DONE=""
  LEDGER_SKIP=""
  LEDGER_EXTRA=""
  mkdir -p "${ROOT}" "${PLAN_DIR}/ctx" "${PLAN_DIR}/results"
  make_context_files
  make_repo_files
  reset_fixture
  write_plan
  # The checker resolves a task's repo-relative `reads:` against the cwd, so every
  # run is made from the scratch repo root, not from wherever bats was started.
  cd "${ROOT}"
}

# reset_fixture - the one copy of the plan's task and lane tables. Eight tasks over
# three lanes: two writers in src, two in tests, one read-only map task, one doc
# task, and T08, which needs the resolver T03 writes and carries the L2 brief.
reset_fixture() {
  LANE_ROWS=(
    "src|scripts/lib/search.sh|general-purpose|ctx/L1-src.md|resolver lives here"
    "tests|tests/bats/search.bats|general-purpose|ctx/L1-tests.md|bats suite"
    "map|-|explore|ctx/L1-map.md|context only"
  )
  TASK_ROWS=(
    "T01|add the lane resolver to scripts/lib/search.sh|src|general-purpose|scripts/lib/search.sh|L0, L1-src|none|12|\`bazelisk test //tests:bats_search_test\`|results/T01.md"
    "T02|add the result cache to scripts/lib/search-cache.sh|src|general-purpose|scripts/lib/search-cache.sh|L0, L1-src|none|10|\`bazelisk test //tests:bats_search_test\`|results/T02.md"
    "T03|add the lane table reader to scripts/lib/search-lane.sh|src|general-purpose|scripts/lib/search-lane.sh|L0, L1-src|none|14|\`bazelisk test //tests:bats_search_test\`|results/T03.md"
    "T04|cover the resolver in tests/bats/search.bats|tests|general-purpose|tests/bats/search.bats|L0, L1-tests, scripts/lib/search.sh:1-40|none|9|\`bazelisk test //tests:bats_search_test\`|results/T04.md"
    "T05|cover the cache in tests/bats/search-cache.bats|tests|general-purpose|tests/bats/search-cache.bats|L0, L1-tests|none|9|\`bazelisk test //tests:bats_search_cache_test\`|results/T05.md"
    "T06|map the search surface into the map lane brief|map|explore|-|L0, L1-map|none|8|ctx/L1-map.md names every file the src lane owns|results/T06.md"
    "T07|document the lane in docs/search-lane.md|src|general-purpose|docs/search-lane.md|L0, L1-src|none|6|\`grep -q swarm lane docs/search-lane.md\`|results/T07.md"
    "T08|cover the lane reader in tests/bats/search-lane.bats|tests|general-purpose|tests/bats/search-lane.bats|L0, L1-tests, L2-T08|T03|11|\`bazelisk test //tests:bats_search_lane_test\`|results/T08.md"
  )
}

# make_context_files - the layered ctx/ tree the plan cites: L0 for every child, one
# L1 per lane, and the L2 brief only T08 reads.
make_context_files() {
  printf '# L0 contract\n\nAdd the swarm search lane. Seams: resolve_lane(id) in\nscripts/lib/search.sh; the lane table in scripts/lib/search-lane.sh.\nNever touch tests/BUILD.bazel or docs/index.ts.\n' >"${PLAN_DIR}/ctx/L0.md"
  printf '# L1 src\n\nscripts/lib/search.sh holds the resolver; copy the reader in\nscripts/lib/search-core.sh. Prove it with //tests:bats_search_test.\n' >"${PLAN_DIR}/ctx/L1-src.md"
  printf '# L1 tests\n\nOne bats file per source file, load test_helper, no eval.\n' >"${PLAN_DIR}/ctx/L1-tests.md"
  printf '# L1 map\n\nRead only. Report the file map; write nothing.\n' >"${PLAN_DIR}/ctx/L1-map.md"
  printf '# L2 T08\n\nThe lane reader returns an empty list for an unknown id; assert that.\n' >"${PLAN_DIR}/ctx/L2-T08.md"
}

# make_repo_files - the checkout files a task reads to copy a pattern. Only files
# named in a `reads:` have to exist: `owns:` paths are what the child creates.
make_repo_files() {
  mkdir -p "${ROOT}/scripts/lib"
  printf '#!/usr/bin/env bash\n# Purpose: resolve a lane id to a model lane.\nset -euo pipefail\n' >"${ROOT}/scripts/lib/search.sh"
}

# task_get <id> <field> - one column of a task row (1 id, 2 summary, 3 lane, 4 role,
# 5 owns, 6 reads, 7 needs, 8 calls, 9 done, 10 report).
task_get() {
  local row
  for row in "${TASK_ROWS[@]}"; do
    if [[ ${row%%|*} == "$1" ]]; then
      awk -F'|' -v f="$2" '{print $f}' <<<"${row}"
      return 0
    fi
  done
  return 1
}

# task_set <id> <field> <value> - mutate one column of a task row. An empty value
# drops the key line entirely, which is how the missing-key test loses `done:`.
task_set() {
  local i row
  for i in "${!TASK_ROWS[@]}"; do
    row="${TASK_ROWS[$i]}"
    if [[ ${row%%|*} == "$1" ]]; then
      TASK_ROWS[$i]="$(awk -F'|' -v OFS='|' -v f="$2" -v v="$3" '{$f=v} 1' <<<"${row}")"
      return 0
    fi
  done
  return 1
}

# list_has <space-list> <item> - is <item> one of the words in <item list>.
list_has() {
  local -a items=()
  local item
  read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    [[ ${item} == "$2" ]] && return 0
  done
  return 1
}

# render_row <pipe-list> - a markdown row built from a pipe-delimited fixture row.
render_row() {
  awk -F'|' -v OFS=' | ' '{$1=$1} 1' <<<"$1"
}

# write_plan - render ${PLAN} from the fixture rows and the ledger knobs.
write_plan() {
  local row id state
  {
    cat <<'EOF'
# Micro-plan: search-lane

<!-- ez-micro-plan v1 -->

## Goal
Add the swarm search lane to the search helper, its bats suite, and its doc.
- A1: the resolver maps a lane id to a model lane -- check: `bazelisk test //tests:bats_search_test`
- A2: every lane brief names the files its lane owns -- check: `grep -c '^|' .grok/plans/search-lane/ctx/L1-src.md`

## Dispatch
- lane: agent-swarm
- slots: 4
- cap source: [subagents] max_concurrent
- parent keeps: tests/BUILD.bazel, docs/index.ts
- between waves: run the lane's own test target; keep the tree buildable

## Lanes
EOF
    printf '| lane | owns | role | brief | notes |\n'
    printf '|---|---|---|---|---|\n'
    for row in "${LANE_ROWS[@]}"; do
      printf '| %s |\n' "$(render_row "${row}")"
    done
    printf '\n## Tasks\n'
    for row in "${TASK_ROWS[@]}"; do
      id="${row%%|*}"
      printf '\n### %s -- %s\n' "${id}" "$(task_get "${id}" 2)"
      awk -F'|' '{
        if ($3 != "") printf "- lane: %s\n", $3
        if ($4 != "") printf "- role: %s\n", $4
        if ($5 != "") printf "- owns: %s\n", $5
        if ($6 != "") printf "- reads: %s\n", $6
        if ($7 != "") printf "- needs: %s\n", $7
        if ($8 != "") printf "- calls: %s\n", $8
        if ($9 != "") printf "- done: %s\n", $9
        if ($10 != "") printf "- report: %s\n", $10
      }' <<<"${row}"
    done
    printf '\n## Ledger\n'
    printf '| task | state | wave | slot | result | verified |\n'
    printf '|---|---|---|---|---|---|\n'
    for row in "${TASK_ROWS[@]}"; do
      id="${row%%|*}"
      list_has "${LEDGER_SKIP}" "${id}" && continue
      state="ready"
      list_has "${LEDGER_DONE}" "${id}" && state="done"
      printf '| %s | %s | - | - | - | no |\n' "${id}" "${state}"
    done
    if [[ -n ${LEDGER_EXTRA} ]]; then
      printf '| %s | ready | - | - | - | no |\n' "${LEDGER_EXTRA}"
    fi
    cat <<'EOF'

## Not doing
- no change to the LiteLLM config and no new model deployment
EOF
  } >"${PLAN}"
}

# drop_section <title> - remove a `## <title>` block from the written plan, which is
# how the section tests lose one heading without rewriting the document.
drop_section() {
  local body
  body="$(awk -v want="$1" 'BEGIN{keep=1} /^## / && !/^### / { keep = ($2 != want) } keep' "${PLAN}")"
  printf '%s\n' "${body}" >"${PLAN}"
}

# check <args...> - run the checker over the fixture plan, keeping stderr apart so a
# usage error can be told from a finding.
check() {
  run --separate-stderr python3 "${CHECKER}" "${PLAN}" "$@"
}

# report_status - fail with the whole report on the line, so a red test says why.
report_status() {
  printf 'status: %s\noutput:\n%s\nstderr:\n%s\n' "${status}" "${output}" "${stderr}"
  return 1
}

# ready_csv - the wave printed by the last --ready run, as a comma list, so an
# assertion about the whole wave fits on one line.
ready_csv() {
  local ids
  ids="$(printf '%s\n' "${output}" | grep -E '^T[0-9]+$' || true)"
  [[ -n ${ids} ]] && printf '%s' "${ids}" | paste -sd, -
}

@test "a well-formed plan passes and the summary reports no errors" {
  check
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "eight tasks over three lanes, wave four wide, nothing to fix" \
    "summary: 8 tasks | 3 lanes | 4 slots | wave width 4 | 0 errors, 0 warnings" \
    "${lines[0]}"
}

@test "--ready prints the tasks with no unmet need, capped at slots" {
  check --ready
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "the wave is the first four ready tasks" "T01,T02,T03,T04" "$(ready_csv)"
  assert_not_match "the task waiting on T03 was held back" '^T08$' "${output}"

  check --ready --slots 3
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "--slots is the cap on the wave" "T01,T02,T03" "$(ready_csv)"

  task_set T01 7 T07
  write_plan
  check --ready
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "T01 left the wave while T07 was open" "T02,T03,T04,T05" "$(ready_csv)"

  LEDGER_DONE="T07"
  write_plan
  check --ready
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "T01 re-entered the wave once T07 was done" "T01,T02,T03,T04" "$(ready_csv)"
}

@test "--json emits parseable JSON carrying ready, errors and warnings" {
  check --json
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "stdout parsed as JSON and carried the three finding keys" "True" \
    "$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(all(k in d for k in ("ready", "errors", "warnings")))' <<<"${output}")"
  assert_eq "the keys held the wave and an empty finding list" "T01,T02,T03,T04|" \
    "$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(",".join(d["ready"]) + "|" + ",".join(d["errors"]))' <<<"${output}")"
}

@test "a plan without the ez-micro-plan v1 marker is refused" {
  sed -i 's/ez-micro-plan v1/working draft/' "${PLAN}"
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the missing marker was named" 'ez-micro-plan v1` marker' "${output}"
}

@test "a plan with no ## Ledger section names the section" {
  drop_section Ledger
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the missing section was named" 'missing `## Ledger` section' "${output}"
}

@test "a task block missing a required key names the task and the key" {
  task_set T04 9 ""
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the task named itself" 'error: T04 is missing' "${output}"
  assert_match "and so did the key it lost" 'T04 is missing done' "${output}"
  assert_not_match "the clean tasks were not blamed" 'T01 is missing' "${output}"
}

@test "two ready tasks owning the same path are refused" {
  task_set T04 5 "$(task_get T02 5)"
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "both ids and the shared path were named" \
    'T02 and T04 both own scripts/lib/search-cache.sh and no dependency orders them' "${output}"
}

@test "the same two tasks are legal once a need orders them" {
  task_set T04 5 "$(task_get T02 5)"
  task_set T04 7 T02
  write_plan
  check
  [[ ${status} -eq 0 ]] || report_status
  assert_not_match "the shared path was no longer a collision" 'both own' "${output}"
  assert_eq "the plan dispatched clean" \
    "summary: 8 tasks | 3 lanes | 4 slots | wave width 4 | 0 errors, 0 warnings" \
    "${lines[0]}"
}

@test "a dependency cycle is refused" {
  task_set T02 7 T03
  task_set T03 7 T02
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the cycle was named by the tasks it runs through" \
    'error: dependency cycle through T[0-9]+' "${output}"
}

@test "a needs: naming an unknown task is refused" {
  task_set T05 7 T99
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the unknown id was named" 'T05 needs unknown task T99' "${output}"
}

@test "calls above 25 fails, 16 to 25 warns, and --strict makes the warning fail" {
  task_set T01 8 40
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the over-budget task was refused" 'T01 budgets 40 calls; split it \(max 25\)' "${output}"

  task_set T01 8 20
  write_plan
  check
  [[ ${status} -eq 0 ]] || report_status
  assert_match "the soft cap warned instead of refusing" \
    'warning: T01 budgets 20 calls; a micro task is 15 or fewer' "${output}"

  check --strict
  [[ ${status} -eq 1 ]] || report_status
  assert_match "strict mode turned the lone warning into a failure" \
    '0 errors, 1 warnings' "${output}"
}

@test "an explore task that owns a file is refused" {
  task_set T06 5 scripts/lib/search-map.sh
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the read-only role and its file were named" \
    'T06 is explore but owns scripts/lib/search-map.sh' "${output}"
}

@test "a first wave narrower than the slots is refused as an idling fleet" {
  task_set T02 7 T01
  task_set T03 7 T01
  task_set T04 7 T01
  task_set T05 7 T01
  write_plan
  check --slots 8
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the narrow wave and the idle fleet were named" \
    'wave 1 is 3 tasks wide against 8 slots; the fleet idles' "${output}"
}

@test "a task naming a lane ## Lanes does not list is refused" {
  task_set T05 3 docs
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the unknown lane was named" \
    'T05 names lane docs, which ## Lanes does not list' "${output}"
}

@test "a lane brief missing from disk is refused, and --no-files lets it through" {
  rm "${PLAN_DIR}/ctx/L1-tests.md"
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the missing brief was named" \
    'lane tests names brief ctx/L1-tests.md, which is missing' "${output}"

  check --no-files
  [[ ${status} -eq 0 ]] || report_status
  assert_eq "with the disk out of it the plan is dispatchable" \
    "summary: 8 tasks | 3 lanes | 4 slots | wave width 4 | 0 errors, 0 warnings" \
    "${lines[0]}"
}

@test "a ledger row with no task block, and a task with no row, are both refused" {
  LEDGER_EXTRA="T99"
  LEDGER_SKIP="T05"
  write_plan
  check
  [[ ${status} -eq 1 ]] || report_status
  assert_match "the orphan row was named" 'ledger row T99 has no task block' "${output}"
  assert_match "the unrowed task was named" 'T05 has no ledger row' "${output}"
}

@test "a missing plan path is a usage error on stderr" {
  run --separate-stderr python3 "${CHECKER}" "${ROOT}/.grok/plans/not-here/plan.md"
  [[ ${status} -eq 2 ]] || report_status
  assert_match "the error line went to stderr" '^error: no plan at ' "${stderr}"
  assert_eq "stdout stayed empty" "" "${output}"
}

@test "a repo file a task reads that is not in the checkout warns without failing" {
  task_set T04 6 "L0, L1-tests, scripts/lib/spark.sh:40-75"
  write_plan
  check
  [[ ${status} -eq 0 ]] || report_status
  assert_match "the unread file was named with its range" \
    'warning: T04 reads scripts/lib/spark.sh:40-75, which is not in the checkout' "${output}"
  # The findings print before the tally, so the one warning occupies the first line.
  assert_eq "one warning, no errors" \
    "summary: 8 tasks | 3 lanes | 4 slots | wave width 4 | 0 errors, 1 warnings" \
    "${lines[1]}"
}
