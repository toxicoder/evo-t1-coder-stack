#!/usr/bin/env bats
#
# ## bazel-map.bats - hermetic coverage for scripts/bazel-map.sh
#
# The CLI is a thin shell over `bazelisk query`, so what is worth pinning is
# everything between the argv and the report: which expression each verb sends,
# that a batch costs ONE query, that a query Bazel let go with an ERROR line on
# stderr is still a failure, and that under --json stdout stays a bare label
# list. Those are the four ways this CLI has most often lied: an unfiltered
# rdeps answers "everything", an empty successful-looking query reads as "nothing
# depends on this", a per-path fallback pays for every file, and prose mixed into
# stdout breaks the pipe into `bazelisk test`.
#
# Usage: bazelisk test //tests:bats_bazel_map_test   (from any cwd)
# Safety: bazelisk and git are per-test fakes written into the test's own bin
# directory, and timeout is the tests/bats/tool_stubs copy, so no real Bazel is
# ever invoked (a Bazel test sandbox has no MODULE.bazel in its runfiles, so a
# real query could not analyze), no daemon runs, and no network is touched. The
# CLI works inside a scratch directory it only reads.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
ROOT=""
# The environment every CLI run gets: no JSON_MODE inherited from the runner, and
# the scratch checkout as the root resolve_checkout proves. REPO_ROOT is the one
# candidate resolve_checkout trusts as given, which keeps the cwd the verbs shell
# git from deterministic.
RUN_ENV=()

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/bazel-map.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/bazel-map.sh is not in the tree"
  use_stubs timeout
  ROOT="$(fake_root)"
  RUN_ENV=(-u JSON_MODE -u MAP_QUERY_TIMEOUT REPO_ROOT="${ROOT}")
}

# fake_root - print a throwaway checkout: only the docker-compose.yml marker that
# resolve_checkout proves. The CLI reads nothing from it beyond that.
fake_root() {
  local root
  root="$(make_scratch)/checkout"
  mkdir -p "${root}"
  : >"${root}/docker-compose.yml"
  printf '%s' "${root}"
}

# fake_bazelisk - record argv and answer `query` from the canned pools the test
# exports. Every test drives the CLI through this: the real bazelisk must never
# run, because the sandbox holds no MODULE.bazel to analyze. STUB_BAZELISK_ERROR
# prints an ERROR line on stderr with whatever exit status the test asks for,
# which is the shape Bazel uses when it refuses an expression and still leaves the
# caller an empty, successful-looking result.
fake_bazelisk() {
  cat >"${BATS_TEST_TMPDIR?}/bin/bazelisk" <<'FAKE_BAZELISK'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'bazelisk %s\n' "$*" >>"${STUB_LOG}/bazelisk.log"; fi
emit() {
  local text="${1:-}"
  [ -n "${text}" ] || return 0
  printf '%s\n' "${text}"
}
[ "${1:-}" = "query" ] || exit "${STUB_BAZELISK_RC:-0}"
expr="${2:-}"
if [ -n "${STUB_BAZELISK_ERROR:-}" ]; then
  printf 'ERROR: %s\n' "${STUB_BAZELISK_ERROR}" >&2
  exit "${STUB_BAZELISK_RC:-0}"
fi
if [ -n "${STUB_BAZELISK_FAIL_MATCH:-}" ] &&
  [[ "${expr}" == *"${STUB_BAZELISK_FAIL_MATCH}"* ]]; then
  printf 'ERROR: no such target: %s\n' "${STUB_BAZELISK_FAIL_MATCH}" >&2
  exit "${STUB_BAZELISK_FAIL_RC:-1}"
fi
if [ -n "${STUB_BAZELISK_OUT:-}" ]; then
  emit "${STUB_BAZELISK_OUT}"
  exit "${STUB_BAZELISK_RC:-0}"
fi
case "${expr}" in
  *'kind("source file", deps(//templates/'*) emit "${STUB_TWINS_POOL:-}" ;;
  *'kind("filegroup", rdeps('*) emit "${STUB_CLAIM_OUT:-}" ;;
  *'kind("source file", deps(//...)'*) emit "${STUB_SOURCE_POOL:-}" ;;
  *) emit "${STUB_RDEPS_OUT:-}" ;;
esac
exit "${STUB_BAZELISK_RC:-0}"
FAKE_BAZELISK
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/bazelisk"
}

# fake_git - record argv and answer the three probes this CLI makes: `diff
# --name-only` for the changed set, `ls-files` for the tracked set, and
# `ls-files --others` for the untracked tail. The shared tool_stubs/git cannot
# answer those apart, so each answer is its own test's to choose.
fake_git() {
  cat >"${BATS_TEST_TMPDIR?}/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'git %s\n' "$*" >>"${STUB_LOG}/git.log"; fi
emit() {
  local text="${1:-}"
  [ -n "${text}" ] || return 0
  printf '%s\n' "${text}"
}
case "$*" in
  *'ls-files --others'*) emit "${STUB_GIT_UNTRACKED:-}" ;;
  *ls-files*) emit "${STUB_GIT_TRACKED:-}" ;;
  *) emit "${STUB_GIT_DIFF:-}" ;;
esac
exit 0
FAKE_GIT
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/git"
}

# load_map_fns <name...> - bring the named production functions into this shell.
load_map_fns() {
  local name
  for name in "$@"; do
    load_shell_function "${SCRIPT}" "${name}"
  done
}

# load_report_fns [name...] - the common.sh vocabulary the loaded functions print
# through, all of it or only what one function needs. Deliberately never `skip`:
# that one would shadow the Bats builtin.
load_report_fns() {
  local names=("$@")
  if [ ${#names[@]} -eq 0 ]; then
    names=(log err warn note section ok summary)
  fi
  local name
  for name in "${names[@]}"; do
    load_shell_function "${REPO_ROOT}/scripts/lib/common.sh" "${name}"
  done
}

# ---------------------------------------------------------------------------
# The stream split, which is what --json is for.
# ---------------------------------------------------------------------------

@test "bazel-map: --json puts the labels on stdout and every prose line on stderr" {
  fake_bazelisk
  export STUB_BAZELISK_OUT=$'//tests:bazel_map_test\n//:test-fast'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets --json
  [ "${status}" -eq 0 ]
  assert_eq "stdout is the bare label list, nothing else" \
    $'//tests:bazel_map_test\n//:test-fast' "${output}"
  assert_match "the section header rode stderr" '^== targets in //\.\.\. ==$' "${stderr}"
  assert_match "the ok line rode stderr" '^ok: targets$' "${stderr}"
  assert_match "the closing summary rode stderr" '^summary: 1 ok, 0 warnings, 0 failed$' "${stderr}"
  assert_eq "one query produced the whole report" "1" "$(stub_log_count bazelisk)"
}

@test "bazel-map: without --json the prose and the labels share stdout" {
  fake_bazelisk
  export STUB_BAZELISK_OUT='//tests:bazel_map_test'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets
  [ "${status}" -eq 0 ]
  assert_match "the section header is on stdout" '^== targets in //\.\.\. ==$' "${output}"
  assert_match "the label is on stdout too" '^//tests:bazel_map_test$' "${output}"
  assert_match "the verdict closes stdout" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
  assert_eq "nothing was diverted to stderr" "" "${stderr}"
}

# ---------------------------------------------------------------------------
# One verb, one expression.
# ---------------------------------------------------------------------------

@test "bazel-map: cmd_targets defaults the specifier to //... and filters to rules" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets
  [ "${status}" -eq 0 ]
  assert_eq "one query carried the default spec" \
    'bazelisk query kind("rule", //...)' "$(stub_log_last bazelisk)"
  assert_eq "it was the only query" "1" "$(stub_log_count bazelisk)"
}

@test "bazel-map: targets passes a named package specifier through untouched" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets '//scripts:all'
  [ "${status}" -eq 0 ]
  assert_eq "the spec reached the expression" \
    'bazelisk query kind("rule", //scripts:all)' "$(stub_log_last bazelisk)"
}

@test "bazel-map: targets --label-kind asks bazelisk for the rule class" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets //tests --label-kind
  [ "${status}" -eq 0 ]
  assert_eq "the output flag rides after the expression" \
    'bazelisk query kind("rule", //tests) --output=label_kind' "$(stub_log_last bazelisk)"
}

@test "bazel-map: files asks for the source files one target depends on" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" files '//tests:bazel_map_test'
  [ "${status}" -eq 0 ]
  assert_eq "the deps expression is the whole query" \
    'bazelisk query kind("source file", deps(//tests:bazel_map_test))' "$(stub_log_last bazelisk)"
  assert_match "the section names the target" '^== files read by //tests:bazel_map_test ==$' "${output}"
  assert_match "the verdict closed" '^ok: files$' "${output}"
}

@test "bazel-map: owners runs the filegroup rdeps query and says what an empty list means" {
  fake_bazelisk
  export STUB_CLAIM_OUT='//scripts:doc_sources'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" owners scripts/lib/common.sh
  [ "${status}" -eq 0 ]
  assert_match "the kind filter is filegroup" \
    'kind[(]"filegroup", rdeps[(]//\.\.\., "scripts/lib/common\.sh"[)]' "$(stub_log bazelisk)"
  assert_match "the claim was reported" '^//scripts:doc_sources$' "${output}"
  assert_match "an empty answer is explained" \
    '^note: an empty list means no filegroup carries this file, so test-fast and lint never see it$' "${output}"
}

@test "bazel-map: tests-for sends the kind-filtered rdeps expression for one path" {
  fake_bazelisk
  export STUB_RDEPS_OUT='//tests:bats_bazel_map_test'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" tests-for scripts/bazel-map.sh
  [ "${status}" -eq 0 ]
  local logged
  logged="$(stub_log_last bazelisk)"
  assert_match "the leaf-test filter is applied" 'kind[(]"sh_test",' "${logged}"
  assert_match "the roots are the named file" 'rdeps[(]//\.\.\., "scripts/bazel-map\.sh"[)]' "${logged}"
  assert_match "the aggregate suites are excluded" 'except kind[(]"test_suite", //\.\.\.[)]' "${logged}"
  assert_match "the answer rode stdout" '^//tests:bats_bazel_map_test$' "${output}"
  assert_match "the verdict closed" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
}

@test "bazel-map: tests-for --all widens the kind filter and drops the suite exclusion" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" tests-for --all scripts/bazel-map.sh
  [ "${status}" -eq 0 ]
  local logged
  logged="$(stub_log_last bazelisk)"
  assert_match "lint targets are now in scope" 'kind[(]"test", rdeps[(]' "${logged}"
  assert_not_match "the test_suite exclusion is gone" 'except kind[(]"test_suite"' "${logged}"
}

@test "bazel-map: a batch of two paths costs one query with the roots unioned" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" tests-for \
    scripts/lib/common.sh scripts/bazel-map.sh
  [ "${status}" -eq 0 ]
  assert_eq "the batch was a single query" "1" "$(stub_log_count bazelisk)"
  assert_match "both roots are in one union expression" \
    '"scripts/lib/common\.sh" \+ "scripts/bazel-map\.sh"' "$(stub_log bazelisk)"
  assert_match "the section counted the batch" '^== tests for 2 path\(s\) ==$' "${output}"
}

@test "bazel-map: an unknown path is a warning naming it and the batch re-queries per path" {
  fake_bazelisk
  export STUB_BAZELISK_FAIL_MATCH='scripts/never-declared.sh'
  export STUB_RDEPS_OUT='//tests:bats_bazel_map_test'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" tests-for \
    scripts/bazel-map.sh scripts/never-declared.sh
  [ "${status}" -eq 1 ]
  assert_eq "one batch query plus one per path" "3" "$(stub_log_count bazelisk)"
  assert_match "the unknown path is named" \
    '^warning: the graph does not know scripts/never-declared\.sh' "${output}"
  assert_not_match "a path nobody knows does not report success" '^ok: tests-for$' "${output}"
}

@test "bazel-map: a query that prints ERROR and exits 0 is still reported as a failed query" {
  # The regression pin. Bazel can refuse an expression on stderr and still leave
  # exit 0, which reads as an empty success; graph_query checks the ERROR line too.
  fake_bazelisk
  export STUB_BAZELISK_ERROR='no such package "//scripts:nope"'
  export STUB_BAZELISK_RC=0
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets //scripts:nope
  [ "${status}" -eq 1 ]
  assert_match "the failure is named as a query failure" '^error: query failed \(status 0\)' "${stderr}"
  assert_match "what bazel actually said is kept" 'bazel: ERROR: no such package "//scripts:nope"' "${stderr}"
  assert_not_match "an empty ERROR result is not a pass" '^ok: targets$' "${output}"
  assert_not_match "no verdict is printed for a failed query" 'summary:' "${output}"
}

# ---------------------------------------------------------------------------
# twins: the counterpart copies across the two template trees and common.
# ---------------------------------------------------------------------------

@test "bazel-map: twins returns the devcontainer counterpart of a workspace file" {
  fake_bazelisk
  export STUB_TWINS_POOL=$'//templates/workspace:main.tf\n//templates/devcontainer:main.tf\n//templates/common:tmux.conf'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" twins templates/workspace/main.tf
  [ "${status}" -eq 0 ]
  assert_match "the queried path heads its own block" '^== templates/workspace/main\.tf$' "${output}"
  assert_match "the twin is the other tree's copy" '^//templates/devcontainer:main\.tf$' "${output}"
  assert_not_match "the queried file is not its own twin" '^//templates/workspace:main\.tf$' "${output}"
  assert_match "a twin found is not a warning" '^ok: twins$' "${output}"
  assert_match "nothing was suspicious" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
}

@test "bazel-map: twins reports a templates/common file as the one shared copy" {
  fake_bazelisk
  export STUB_TWINS_POOL='//templates/workspace:main.tf'
  export STUB_CLAIM_OUT='//templates/common:payload'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" twins templates/common/tmux.conf
  [ "${status}" -eq 0 ]
  assert_match "the shared group is named" \
    '^note: one shared copy in //templates/common:payload, staged by both template twins$' "${output}"
  assert_not_match "a shared file is not a drift warning" 'warning:' "${output}"
}

@test "bazel-map: twins warns when a per-tree file has no sibling counterpart" {
  fake_bazelisk
  export STUB_TWINS_POOL='//templates/workspace:main.tf'
  export STUB_CLAIM_OUT='//templates/workspace:payload'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" twins templates/workspace/solo.tf
  [ "${status}" -eq 0 ]
  assert_match "the drift is a warning naming the claiming group" \
    '^warning: templates/workspace/solo\.tf exists only in //templates/workspace:payload; the sibling tree has no counterpart$' "${output}"
  assert_match "the warning is counted" '^summary: 1 ok, 1 warnings, 0 failed$' "${output}"
}

@test "bazel-map: twins on a file the graph does not know warns and fails" {
  fake_bazelisk
  export STUB_TWINS_POOL='//templates/workspace:main.tf'
  export STUB_BAZELISK_FAIL_MATCH='"templates/workspace/gone.tf"'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" twins templates/workspace/gone.tf
  [ "${status}" -eq 1 ]
  assert_match "the unknown path is named" \
    '^warning: the graph does not know templates/workspace/gone\.tf$' "${output}"
}

# ---------------------------------------------------------------------------
# unlisted: the filegroup-blind-spot finder.
# ---------------------------------------------------------------------------

@test "bazel-map: unlisted counts a filegroup src in a subdirectory as claimed" {
  # The false-positive this pins: the graph spells a subdir src as
  # //hermes:skills/host-diagnostics/SKILL.md, and a claim match that never
  # normalizes the label flags every skill file as reaching nothing.
  fake_bazelisk
  fake_git
  export STUB_GIT_TRACKED=$'hermes/config.yaml\nhermes/skills/host-diagnostics/SKILL.md'
  export STUB_SOURCE_POOL=$'//hermes:config.yaml\n//hermes:skills/host-diagnostics/SKILL.md'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" unlisted hermes
  [ "${status}" -eq 0 ]
  assert_not_match "the nested skill is claimed" 'SKILL\.md$' "${output}"
  assert_not_match "nothing was left unclaimed" '^warning:' "${output}"
  assert_match "the verb still reported" '^ok: unlisted$' "${output}"
  assert_eq "the tracked list came from git" \
    "git ls-files -- hermes" "$(stub_log_last git)"
}

@test "bazel-map: unlisted flags a tracked file no target reaches" {
  fake_bazelisk
  fake_git
  export STUB_GIT_TRACKED=$'hermes/config.yaml\nhermes/orphan.md'
  export STUB_SOURCE_POOL='//hermes:config.yaml'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" unlisted hermes
  [ "${status}" -eq 1 ]
  assert_match "the unclaimed path is printed" '^hermes/orphan\.md$' "${output}"
  assert_match "the reason is named" \
    '^warning: these files reach no target, so test-fast and lint never open them$' "${output}"
}

@test "bazel-map: unlisted skips the declaration files bazel reads implicitly" {
  fake_bazelisk
  fake_git
  export STUB_GIT_TRACKED=$'BUILD.bazel\nMODULE.bazel\nMODULE.bazel.lock\nhermes/BUILD.bazel\nhermes/lib/util.sh'
  export STUB_SOURCE_POOL='//hermes:lib/util.sh'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" unlisted .
  [ "${status}" -eq 0 ]
  assert_not_match "a package's own BUILD file is not a finding" 'BUILD\.bazel$' "${output}"
  assert_not_match "the module file is not a finding" 'MODULE\.bazel' "${output}"
  assert_match "the enumerated file was claimed" '^ok: unlisted$' "${output}"
}

@test "bazel-map: unlisted with no directory is a usage error" {
  fake_bazelisk
  fake_git
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" unlisted
  [ "${status}" -eq 2 ]
  assert_match "the refusal says what it needs" '^error: unlisted needs at least one directory$' "${stderr}"
  assert_eq "no query was attempted" "0" "$(stub_log_count bazelisk)"
}

# ---------------------------------------------------------------------------
# scope: the derived test list for this checkout.
# ---------------------------------------------------------------------------

@test "bazel-map: cmd_scope with nothing changed points at the fast gate and queries nothing" {
  fake_bazelisk
  fake_git
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" scope
  [ "${status}" -eq 0 ]
  assert_match "the fallback is named" '^note: nothing changed against HEAD; run //:test-fast$' "${output}"
  assert_match "the verdict is still a pass" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
  assert_eq "no query ran when there was nothing to scope" "0" "$(stub_log_count bazelisk)"
  assert_eq "the working tree was the source" \
    "git diff --name-only --diff-filter=d HEAD" "$(stub_log_last git)"
}

@test "bazel-map: cmd_scope with changed paths queries their union once" {
  fake_bazelisk
  fake_git
  export STUB_GIT_DIFF=$'scripts/lib/common.sh\nscripts/bazel-map.sh'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" scope
  [ "${status}" -eq 0 ]
  assert_eq "the whole scope was one query" "1" "$(stub_log_count bazelisk)"
  assert_match "the roots are unioned" \
    '"scripts/lib/common\.sh" \+ "scripts/bazel-map\.sh"' "$(stub_log bazelisk)"
  assert_match "the phase counts the changed files" '^-> 2 changed path\(s\)$' "${output}"
  assert_match "the uncached pass is still asked for" \
    '^note: run them with: bazelisk test <labels>; keep one uncached //:test-fast pass before the PR$' "${output}"
}

@test "bazel-map: scope --staged reads the index instead of the working tree" {
  fake_bazelisk
  fake_git
  export STUB_GIT_DIFF='scripts/bazel-map.sh'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" scope --staged
  [ "${status}" -eq 0 ]
  assert_eq "the diff was the cached one" \
    "git diff --name-only --cached --diff-filter=d" "$(stub_log_last git)"
  assert_match "the staged path was queried" '"scripts/bazel-map\.sh"' "$(stub_log bazelisk)"
}

@test "bazel-map: scope --untracked adds the untracked files to the roots" {
  fake_bazelisk
  fake_git
  export STUB_GIT_DIFF='scripts/bazel-map.sh'
  export STUB_GIT_UNTRACKED='scripts/lib/new-helper.sh'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" scope --untracked
  [ "${status}" -eq 0 ]
  assert_match "the untracked probe ran" 'git ls-files --others --exclude-standard' "$(stub_log git)"
  assert_match "both sets are in one union" \
    '"scripts/bazel-map\.sh" \+ "scripts/lib/new-helper\.sh"' "$(stub_log bazelisk)"
}

@test "bazel-map: scope --ref reads what the branch adds over that ref" {
  fake_bazelisk
  fake_git
  export STUB_GIT_DIFF='scripts/bazel-map.sh'
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" scope --ref main
  [ "${status}" -eq 0 ]
  assert_eq "the diff was taken against the named ref" \
    "git diff --name-only --diff-filter=d main...HEAD" "$(stub_log_last git)"
}

@test "bazel-map: scope --ref with no value is a usage error" {
  fake_bazelisk
  fake_git
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" scope --ref
  [ "${status}" -eq 2 ]
  assert_match "the missing value is named" '^error: --ref needs a value$' "${stderr}"
}

# ---------------------------------------------------------------------------
# Usage errors.
# ---------------------------------------------------------------------------

@test "bazel-map: an unknown verb exits 2 and prints the usage block" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" frobnicate scripts/bazel-map.sh
  [ "${status}" -eq 2 ]
  assert_match "the verb is named" '^error: unknown verb: frobnicate$' "${stderr}"
  assert_match "the usage block is printed" \
    '^Usage: bazelisk run //scripts:bazel-map -- <verb> \[args\] \[--json\] \[-h\|--help\]$' "${stderr}"
  assert_match "every verb is listed" '^  tests-for <path>\.\.\.' "${stderr}"
}

@test "bazel-map: an unknown flag exits 2 and prints the usage block" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" targets --turbo
  [ "${status}" -eq 2 ]
  assert_match "the flag is named" '^error: unknown flag: --turbo$' "${stderr}"
  assert_match "the usage block is printed" '^Usage: bazelisk run //scripts:bazel-map' "${stderr}"
  assert_eq "no query was attempted" "0" "$(stub_log_count bazelisk)"
}

@test "bazel-map: --help prints the usage block and exits 0" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "the usage block is on stdout" '^Usage: bazelisk run //scripts:bazel-map -- <verb>' "${output}"
  assert_match "the twin verb is listed" '^  twins <path>\.\.\.' "${output}"
  assert_eq "no query was attempted" "0" "$(stub_log_count bazelisk)"
}

@test "bazel-map: a verb that needs a path exits 2 rather than querying nothing" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" tests-for
  [ "${status}" -eq 2 ]
  assert_match "the refusal says what is missing" \
    '^error: tests-for needs at least one repo-relative path$' "${stderr}"
  assert_eq "no query was attempted" "0" "$(stub_log_count bazelisk)"
}

@test "bazel-map: files with no target is a usage error" {
  fake_bazelisk
  run --separate-stderr env "${RUN_ENV[@]}" bash "${SCRIPT}" files
  [ "${status}" -eq 2 ]
  assert_match "the refusal says what is missing" '^error: files needs one target label$' "${stderr}"
  assert_eq "no query was attempted" "0" "$(stub_log_count bazelisk)"
}

# ---------------------------------------------------------------------------
# Unit level: the helpers, loaded from the real file.
# ---------------------------------------------------------------------------

@test "bazel-map: usage prints the verb list and the flag line" {
  load_map_fns usage
  local out
  out="$(usage)"
  assert_match "targets has a line" '^  targets \[pattern\]' "${out}"
  assert_match "scope is listed" '^  scope \[--staged\] \[--untracked\] \[--ref <ref>\]' "${out}"
  assert_match "the flags are named once" \
    '^Flags: --staged --untracked --ref <ref> --all --label-kind --json -h\|--help$' "${out}"
  assert_match "the stream split is documented" \
    '^Labels go to stdout one per line; prose goes to stderr under --json\.$' "${out}"
}

@test "bazel-map: path_operand quotes a clean path and refuses an unsafe one" {
  load_map_fns path_operand
  load_report_fns err
  local out rc=0
  out="$(path_operand scripts/lib/common.sh)" || rc=$?
  assert_eq "the usable path became a quoted operand" 0 "${rc}"
  assert_eq "the operand is quoted" '"scripts/lib/common.sh"' "${out}"

  rc=0
  out="$(path_operand '' 2>/dev/null)" || rc=$?
  assert_eq "an empty path is refused" 1 "${rc}"
  assert_eq "an empty path prints nothing" "" "${out}"

  rc=0
  out="$(path_operand 'has"quote' 2>/dev/null)" || rc=$?
  assert_eq "a path that could break the operand is refused" 1 "${rc}"
  assert_eq "a refused path prints nothing" "" "${out}"
}

@test "bazel-map: roots_expression joins the batch into one union and refuses none" {
  load_map_fns roots_expression path_operand
  load_report_fns err
  local out rc=0
  out="$(roots_expression scripts/a.sh scripts/b.sh scripts/c.sh)" || rc=$?
  assert_eq "three paths made one expression" 0 "${rc}"
  assert_eq "the union is quoted and plus-joined" \
    '"scripts/a.sh" + "scripts/b.sh" + "scripts/c.sh"' "${out}"

  rc=0
  out="$(roots_expression 2>/dev/null)" || rc=$?
  assert_eq "an empty batch is refused" 1 "${rc}"

  rc=0
  out="$(roots_expression 'scripts/bad"name.sh' 2>/dev/null)" || rc=$?
  assert_eq "one unsafe path fails the whole batch" 1 "${rc}"
}

@test "bazel-map: label_to_path turns a source label into the repo-relative path" {
  load_map_fns label_to_path
  local out
  out="$(label_to_path '//hermes:skills/host-diagnostics/SKILL.md')"
  assert_eq "a subdir src keeps its path half" "hermes/skills/host-diagnostics/SKILL.md" "${out}"
  out="$(label_to_path '//templates/common:tmux.conf')"
  assert_eq "a package-root src is the file beside its BUILD file" "templates/common/tmux.conf" "${out}"
}

@test "bazel-map: graph_query runs one query, prints its labels, and needs an expression" {
  fake_bazelisk
  load_map_fns graph_query
  load_report_fns err
  export MAP_QUERY_TIMEOUT=5
  export STUB_RDEPS_OUT='//tests:bazel_map_test'
  local out rc=0
  out="$(graph_query 'kind("rule", //tests)')" || rc=$?
  assert_eq "the query succeeded" 0 "${rc}"
  assert_eq "the labels came back verbatim" "//tests:bazel_map_test" "${out}"
  assert_eq "the expression was the whole argv" \
    'bazelisk query kind("rule", //tests)' "$(stub_log_last bazelisk)"

  rc=0
  graph_query 'kind("rule", //tests)' --output=label_kind >/dev/null 2>&1 || rc=$?
  assert_eq "the flag form succeeded too" 0 "${rc}"
  assert_match "the flag reached bazelisk" ' --output=label_kind$' "$(stub_log_last bazelisk)"

  rc=0
  graph_query '' >/dev/null 2>&1 || rc=$?
  assert_eq "an empty expression is refused" 1 "${rc}"
  assert_eq "the refusal was not even a query" "2" "$(stub_log_count bazelisk)"
}

@test "bazel-map: graph_query reports the failure and keeps what bazel said" {
  fake_bazelisk
  load_map_fns graph_query
  load_report_fns err
  export MAP_QUERY_TIMEOUT=5
  export STUB_BAZELISK_ERROR='no such target "//nope"'
  local rc=0 err_text
  err_text="$(graph_query 'kind("rule", //nope)' 2>&1 >/dev/null)" || rc=$?
  assert_eq "a zero exit with an ERROR line is a failure" 1 "${rc}"
  assert_match "the expression is quoted back" 'query failed \(status 0\): kind\("rule", //nope\)' "${err_text}"
  assert_match "the bazel line is kept" 'bazel: ERROR: no such target "//nope"' "${err_text}"
}

@test "bazel-map: tests_for_paths widens the filter when MAP_ALL is set" {
  fake_bazelisk
  load_map_fns tests_for_paths tests_filter roots_expression path_operand graph_query
  load_report_fns err
  export MAP_QUERY_TIMEOUT=5
  export STUB_RDEPS_OUT='//tests:bazel_map_test'
  local out rc=0
  out="$(tests_for_paths scripts/bazel-map.sh)" || rc=$?
  assert_eq "the leaf filter succeeded" 0 "${rc}"
  assert_eq "the leaf filter was sent" \
    'bazelisk query kind("sh_test", rdeps(//..., "scripts/bazel-map.sh")) except kind("test_suite", //...)' \
    "$(stub_log_last bazelisk)"
  assert_eq "the labels came through" "//tests:bazel_map_test" "${out}"

  export MAP_ALL=1
  rc=0
  out="$(tests_for_paths scripts/bazel-map.sh scripts/lib/common.sh)" || rc=$?
  assert_eq "the wide filter succeeded" 0 "${rc}"
  assert_eq "lint targets are in scope and the exclusion is gone" \
    'bazelisk query kind("test", rdeps(//..., "scripts/bazel-map.sh" + "scripts/lib/common.sh"))' \
    "$(stub_log_last bazelisk)"
}

@test "bazel-map: isolate_bad_path keeps the answers it can get and warns per bad path" {
  fake_bazelisk
  load_map_fns isolate_bad_path roots_expression path_operand graph_query
  load_report_fns log warn err
  export MAP_QUERY_TIMEOUT=5
  # JSON_MODE here is what separates the two halves of the sweep: the labels a path
  # resolved to stay on stdout, the warning a path did not resolve to rides stderr.
  export JSON_MODE=1
  export STUB_BAZELISK_FAIL_MATCH='never-declared.sh'
  export STUB_RDEPS_OUT='//tests:bats_bazel_map_test'
  local out rc=0
  out="$(isolate_bad_path 'kind("sh_test", rdeps(//..., %s))' \
    scripts/bazel-map.sh scripts/never-declared.sh 2>"${BATS_TEST_TMPDIR?}/iso.err")" || rc=$?
  assert_eq "one bad path fails the sweep" 1 "${rc}"
  assert_eq "the good path still answered" "//tests:bats_bazel_map_test" "${out}"
  assert_contains_file "the bad path is named" "${BATS_TEST_TMPDIR?}/iso.err" \
    '^warning: the graph does not know scripts/never-declared\.sh'
  assert_eq "each path cost its own query" "2" "$(stub_log_count bazelisk)"
}

@test "bazel-map: isolate_bad_path fails when no path resolves" {
  fake_bazelisk
  load_map_fns isolate_bad_path roots_expression path_operand graph_query
  load_report_fns log warn err
  export MAP_QUERY_TIMEOUT=5
  export STUB_BAZELISK_ERROR='the graph is unavailable'
  local rc=0
  isolate_bad_path 'kind("sh_test", rdeps(//..., %s))' scripts/bazel-map.sh \
    >/dev/null 2>&1 || rc=$?
  assert_eq "nothing resolving is a failure" 1 "${rc}"
}

@test "bazel-map: changed_paths reads the tree, the index, or a ref, and adds untracked files" {
  fake_git
  load_map_fns changed_paths
  load_report_fns err
  local out
  export STUB_GIT_DIFF=$'scripts/bazel-map.sh\n\nscripts/lib/common.sh'
  MAP_STAGED='' MAP_UNTRACKED='' MAP_REF=''
  out="$(changed_paths)"
  assert_eq "blank lines are dropped and the order kept" \
    $'scripts/bazel-map.sh\nscripts/lib/common.sh' "${out}"
  assert_eq "the working tree diff was the probe" \
    "git diff --name-only --diff-filter=d HEAD" "$(stub_log_last git)"

  MAP_STAGED=1
  changed_paths >/dev/null
  assert_eq "the index diff was the probe" \
    "git diff --name-only --cached --diff-filter=d" "$(stub_log_last git)"

  MAP_STAGED=''
  MAP_REF='main'
  changed_paths >/dev/null
  assert_eq "the named ref was the base" \
    "git diff --name-only --diff-filter=d main...HEAD" "$(stub_log_last git)"

  MAP_REF=''
  MAP_UNTRACKED=1
  export STUB_GIT_UNTRACKED='scripts/lib/new-helper.sh'
  out="$(changed_paths)"
  assert_eq "the untracked file joined the list" \
    $'scripts/bazel-map.sh\nscripts/lib/common.sh\nscripts/lib/new-helper.sh' "${out}"
  assert_match "the untracked probe ran" 'git ls-files --others --exclude-standard' "$(stub_log git)"
}

@test "bazel-map: changed_paths refuses when git is not on PATH" {
  load_map_fns changed_paths
  load_report_fns err
  local saved_path="${PATH}" rc=0
  PATH="${BATS_TEST_TMPDIR?}/emptybin" changed_paths >/dev/null 2>&1 || rc=$?
  PATH="${saved_path}"
  assert_eq "no git is a refusal, not an empty list" 1 "${rc}"
}

@test "bazel-map: parse_args splits the verb, its arguments, and the flags" {
  load_map_fns parse_args usage
  load_report_fns err
  MAP_VERBS=(targets tests-for owners files twins scope unlisted)
  parse_args tests-for scripts/a.sh scripts/b.sh --json --all
  assert_eq "the verb is the first positional" "tests-for" "${VERB}"
  assert_eq "both paths are verb arguments" "2" "${#VERB_ARGS[@]}"
  assert_eq "the first path came through" "scripts/a.sh" "${VERB_ARGS[0]}"
  assert_eq "the second path came through" "scripts/b.sh" "${VERB_ARGS[1]}"
  assert_eq "--json set the stream split" "1" "${JSON_MODE}"
  assert_eq "--all set the wide filter" "1" "${MAP_ALL}"
  assert_eq "a flag nobody passed stays empty" "" "${MAP_LABEL_KIND}"
  assert_eq "the staged flag was not implied" "" "${MAP_STAGED}"
}

@test "bazel-map: parse_args takes the --ref value and refuses a missing one" {
  load_map_fns parse_args usage
  load_report_fns err
  MAP_VERBS=(targets tests-for owners files twins scope unlisted)
  parse_args scope --ref main
  assert_eq "the ref was taken" "main" "${MAP_REF}"

  local rc=0
  parse_args scope --ref --json >/dev/null 2>&1 || rc=$?
  assert_eq "a flag is not a ref value" 2 "${rc}"

  rc=0
  parse_args scope --ref >/dev/null 2>&1 || rc=$?
  assert_eq "a bare --ref is refused" 2 "${rc}"
}

@test "bazel-map: parse_args refuses an unknown verb and an unknown flag with 2" {
  load_map_fns parse_args usage
  load_report_fns err
  MAP_VERBS=(targets tests-for owners files twins scope unlisted)
  local rc=0
  parse_args nope scripts/a.sh >/dev/null 2>&1 || rc=$?
  assert_eq "an unknown verb is a usage error" 2 "${rc}"

  rc=0
  parse_args targets --nope >/dev/null 2>&1 || rc=$?
  assert_eq "an unknown flag is a usage error" 2 "${rc}"

  rc=0
  parse_args >/dev/null 2>&1 || rc=$?
  assert_eq "no verb at all is a usage error" 2 "${rc}"
}

@test "bazel-map: every verb that needs an argument refuses an empty argv with 2" {
  local fn rc
  for fn in cmd_tests_for cmd_owners cmd_files cmd_twins cmd_unlisted; do
    load_map_fns "${fn}"
    load_report_fns err
    rc=0
    "${fn}" >/dev/null 2>&1 || rc=$?
    assert_eq "${fn} refused an empty argv" 2 "${rc}"
  done
}
