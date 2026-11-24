#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## stack-prs.bats - hermetic coverage for scripts/stack-prs.sh
#
# What this suite pins is the four things that make a stacked-PR CLI safe to point at
# a real repository:
#
#   - every call is an `env -u GH_TOKEN -u GITHUB_TOKEN gh api` call and nothing else:
#     the pair Coder injects expires about an hour later and gh prefers it over the
#     live gh auth store, so the fixture records whether either variable survived into
#     the invocation and one test fails the moment a verb forgets to clear them;
#   - a merge goes only through the asynchronous pair. The synchronous
#     PUT /pulls/{n}/merge is refused by the lib on its own, and after a full bottom-up
#     stack merge the call log is asserted to hold no synchronous merge at all;
#   - a stack merges bottom-up in the order the layers came back, because layer two
#     landing before layer one has actually landed is how a layer ends up merged onto a
#     base the trunk does not have;
#   - a repository with stacks turned off is not a failed call but a missing repository
#     setting, so it maps to its own exit code and to a HANDOFF line pointing at the
#     feature a human has to enable. The detection reads the HTTP status and the error
#     text of a /stacks call rather than an exit code: code 9 belongs to the `gh stack`
#     extension, and this CLI's only transport is `gh api`, for which no page gives 9 a
#     meaning, so one test pins that a bare 9 is an ordinary failed call.
#
# Hermetic by construction: `gh` is a fixture script this file writes into the test's
# own scratch bin, answering from canned bodies and an exit code the test chooses. No
# test opens a socket, and no credential is ever read, printed, or put in argv.
#
# Two layers, the way branch-hygiene.bats splits them: the predicates and the body
# builders are sourced from scripts/lib/stack_prs.sh into a subshell and called
# directly, and the verbs are driven end to end through scripts/stack-prs.sh so the
# section order, the summary line, and the exit codes live somewhere real.
#
# Usage: bazelisk test //tests:bats_stack_prs_test   (from any cwd)
#
# Safety: fixture only. Nothing here reaches github.com.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
STUB_BIN=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/stack-prs.sh"
  LIB="${REPO_ROOT}/scripts/lib/stack_prs.sh"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${LIB}" ]; then
    skip "scripts/stack-prs.sh or its lib is not in the tree"
  fi
  STUB_BIN="${BATS_TEST_TMPDIR?}/stubbin"
  STUB_LOG="${BATS_TEST_TMPDIR?}/stub-logs"
  mkdir -p "${STUB_BIN}" "${STUB_LOG}"
  write_gh_stub
  export STUB_LOG
  PATH="${STUB_BIN}:${PATH}"
  export PATH
}

# write_gh_stub - put a canned gh on this test's PATH.
#
# It answers by endpoint rather than by argument position, because a verb that reached
# the wrong URL would then get the wrong canned body and fail in a way that reads like
# a parsing bug. It records three things the tests assert on: the method and path of
# every call, the JSON body it was handed on stdin, and whether either of the two
# injected environment variables survived into its environment - which is the only way
# to see that the CLI removed them, since a stub cannot be asked afterwards what its
# caller unstored. STUB_GH_ERR is what it writes to stderr, which is how a test hands
# the CLI the `gh: ... (HTTP 404)` line the disabled-repository detection reads.
write_gh_stub() {
  cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
# shellcheck shell=bash
set -u
method="GET"
endpoint=""
want_input=0
argv=("$@")
i=0
while [ "${i}" -lt "$#" ]; do
  a="${argv[${i}]}"
  case "${a}" in
    --method)
      i=$((i + 1))
      method="${argv[${i}]}"
      ;;
    --input) want_input=1 ;;
    api | --jq) ;;
    /*) endpoint="${a}" ;;
  esac
  i=$((i + 1))
done
body=""
if [ "${want_input}" -eq 1 ]; then
  body="$(cat)"
fi
pair="clear"
if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  pair="present"
fi
printf 'gh api pair=%s %s %s\n' "${pair}" "${method}" "${endpoint}" >>"${STUB_LOG}/gh.log"
if [ -n "${body}" ]; then
  printf 'body %s %s\n' "${endpoint}" "${body}" >>"${STUB_LOG}/gh.log"
fi
out=""
if [ -n "${STUB_GH_POLL:-}" ] && [[ "${endpoint}" == */merge-async/* ]]; then
  out="${STUB_GH_POLL}"
elif [ -n "${STUB_GH_JOB:-}" ] && [[ "${endpoint}" == */merge-async ]]; then
  out="${STUB_GH_JOB}"
elif [ -n "${STUB_GH_BODY:-}" ] && [ -f "${STUB_GH_BODY}" ]; then
  out="$(cat "${STUB_GH_BODY}")"
else
  out="${STUB_GH_OUT:-}"
fi
[ -n "${out}" ] && printf '%s\n' "${out}"
if [ -n "${STUB_GH_ERR:-}" ]; then
  printf '%s\n' "${STUB_GH_ERR}" >&2
fi
exit "${STUB_GH_RC:-0}"
STUB
  chmod 755 "${STUB_BIN}/gh"
}

# stub_body <line...> - make the canned response body for this test.
stub_body() {
  local file="${BATS_TEST_TMPDIR?}/body.json"
  : >"${file}"
  local line
  for line in "$@"; do
    printf '%s\n' "${line}" >>"${file}"
  done
  export STUB_GH_BODY="${file}"
}

# The injected pair, set to a single inert character: its only job is to be present,
# so the stub can report whether the CLI removed it before invoking gh.
STALE_PAIR=x
export STALE_PAIR

# run_cli [args...] - drive the CLI with the injected pair present in its environment.
#
# --separate-stderr is the stronger form, because common.sh's err() and fail_item()
# write findings to stderr, so asserting on ${stderr} pins that a finding is an error
# line and not merely some text the run produced.
run_cli() {
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" \
    REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    EVO_T1_REPO= GH_TOKEN="${STALE_PAIR}" GITHUB_TOKEN="${STALE_PAIR}" \
    bash "${SCRIPT}" "$@"
}

# gh_log - the calls this test's CLI made, in order.
gh_log() {
  if [ -f "${STUB_LOG}/gh.log" ]; then
    cat "${STUB_LOG}/gh.log"
  fi
}

# lib_run <command...> - call one lib function with the lib and its helpers sourced.
# The source and the call run in a fresh bash: sourcing common.sh defines skip(), which
# would otherwise shadow the bats builtin for the rest of the test file. EVO_T1_SRC
# carries the scripts directory in, so no test interpolates a path into the -c body.
lib_run() {
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" EVO_T1_SRC="${REPO_ROOT}/scripts" \
    REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    GH_TOKEN="${STALE_PAIR}" GITHUB_TOKEN="${STALE_PAIR}" \
    bash -c 'set -euo pipefail; source "${EVO_T1_SRC}/lib/common.sh"; unset JSON_MODE; source "${EVO_T1_SRC}/lib/stack_prs.sh"; "$@"' _ "$@"
}

# lib_shell <script...> - run a short script against the sourced lib.
lib_shell() {
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" EVO_T1_SRC="${REPO_ROOT}/scripts" \
    REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    bash -c "$1"
}

# occurrences <needle> - how many log lines carry the needle.
occurrences() {
  gh_log | grep -F -- "$1" | wc -l | tr -d ' '
}

# -- the inventory: every production function is reachable from this file ----------

@test "the lib and the CLI declare exactly the functions this suite drives" {
  local fn
  for fn in usage require_value is_number set_pr_numbers parse_args resolve_repo_dir \
    parse_repo_slug resolve_repo_slug assert_async_only stacks_disabled_note gh_api \
    body_pull_requests open_layer verb_create_stack verb_add verb_view verb_retarget \
    verb_unstack merge_layer_async verb_merge run_verb; do
    assert_contains_file "lib defines ${fn}" "${LIB}" "^${fn}\(\) \{"
  done
  assert_contains_file "CLI defines main" "${SCRIPT}" "^main\(\) \{"
  assert_contains_file "CLI sources the lib" "${SCRIPT}" "lib/stack_prs\.sh"
  assert_contains_file "CLI sources common" "${SCRIPT}" "lib/common\.sh"
  assert_contains_file "CLI has no json mode" "${SCRIPT}" "unset JSON_MODE"
}

# -- argument parsing -------------------------------------------------------------

@test "usage lists all six verbs" {
  run_cli --help
  assert_eq "help exits 0" 0 "${status}"
  local verb
  for verb in create-stack add view retarget unstack merge; do
    assert_match "usage names ${verb}" "^  ${verb} " "${output}"
  done
}

@test "no verb is a usage error, not a silent no-op" {
  run_cli --slug o/r
  assert_eq "exit 2" 2 "${status}"
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  assert_match "names the verb list" "no verb" "${stderr}"
}

@test "an unknown verb is refused before any call" {
  run_cli destroy --slug o/r --stack 7
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the argument" "unknown argument: destroy" "${stderr}"
  assert_eq "no gh call was made" 0 "$(occurrences 'gh api')"
}

@test "--prs refuses anything that is not a pull request number" {
  run_cli create-stack --slug o/r --prs 12,nope
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the bad entry" "got: nope" "${stderr}"
}

@test "--method is limited to the three GitHub merge methods" {
  run_cli merge --slug o/r --pr 12 --method squash-everything
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the allowed set" "merge, squash, or rebase" "${stderr}"
}

@test "require_value refuses a flag that arrived without its value" {
  lib_run require_value --stack ""
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the flag" "needs a value" "${stderr}"
}

# -- the lib's predicates, called directly ---------------------------------------

@test "is_number accepts a number and rejects a path" {
  lib_run is_number 42
  assert_eq "42 is a number" 0 "${status}"
  lib_run is_number "../12"
  assert_eq "a traversal is not" 1 "${status}"
  lib_run is_number "0"
  assert_eq "zero is not a PR number" 1 "${status}"
}

@test "parse_repo_slug reads owner/repo out of every remote shape" {
  lib_run parse_repo_slug "https://github.com/toxicoder/ezrepo.git"
  assert_eq "https" "toxicoder/ezrepo" "${output}"
  lib_run parse_repo_slug "git@github.com:toxicoder/ezrepo.git"
  assert_eq "scp-like" "toxicoder/ezrepo" "${output}"
  lib_run parse_repo_slug "ssh://git@github.com/toxicoder/ezrepo"
  assert_eq "ssh url" "toxicoder/ezrepo" "${output}"
  lib_run parse_repo_slug "https://gitlab.com/toxicoder/ezrepo"
  assert_eq "a non-github remote is refused" 1 "${status}"
  assert_eq "and prints nothing" "" "${output}"
}

@test "set_pr_numbers keeps the operator's order, bottom-first" {
  lib_shell '
    set -euo pipefail
    source "${EVO_T1_SRC}/lib/common.sh"
    unset JSON_MODE
    source "${EVO_T1_SRC}/lib/stack_prs.sh"
    set_pr_numbers 14,12,13
    body_pull_requests
  '
  assert_eq "the order survives" '{"pull_requests":[14,12,13]}' "${output}"
}

@test "assert_async_only refuses the synchronous merge endpoint and allows the pair" {
  lib_run assert_async_only "/repos/o/r/pulls/12/merge"
  assert_eq "the sync endpoint is refused" 1 "${status}"
  assert_match "and says what to use instead" "merge-async" "${stderr}"

  lib_run assert_async_only "/repos/o/r/pulls/12/merge-async"
  assert_eq "the async queue is allowed" 0 "${status}"
  lib_run assert_async_only "/repos/o/r/pulls/12/merge-async/c0ffee-01"
  assert_eq "the async poll is allowed" 0 "${status}"
  lib_run assert_async_only "/repos/o/r/stacks"
  assert_eq "a stack endpoint is allowed" 0 "${status}"
}

@test "stacks_disabled_note hands the operator the clicks they owe" {
  lib_shell '
    set -euo pipefail
    source "${EVO_T1_SRC}/lib/common.sh"
    unset JSON_MODE
    source "${EVO_T1_SRC}/lib/stack_prs.sh"
    REPO_SLUG=toxicoder/ezrepo
    stacks_disabled_note
  '
  assert_eq "it prints" 0 "${status}"
  assert_match "a HANDOFF line" "HANDOFF: stacks are not enabled for toxicoder/ezrepo" "${stderr}"
  assert_match "the repository settings page" "settings" "${stderr}"
  assert_match "and the feature to find there" "stacked-pull-requests feature" "${stderr}"
  # The switch's own label is deliberately not pinned: no GitHub page in the cited set
  # names it, and asserting an invented label would pin a guess as though somebody had
  # verified a UI string.
}

@test "stacks_disabled_shape reads the missing setting from the status and the path" {
  lib_run stacks_disabled_shape "/repos/o/r/stacks" 1 "gh: Not Found (HTTP 404)"
  assert_eq "a bare 404 on the collection is" 0 "${status}"
  lib_run stacks_disabled_shape "/repos/o/r/stacks/7" 1 "gh: Not Found (HTTP 404)"
  assert_eq "and on one stack" 0 "${status}"
  lib_run stacks_disabled_shape "/repos/o/r/stacks" 1 "gh: Stacks are not enabled here (HTTP 422)"
  assert_eq "a 422 that names the feature is" 0 "${status}"
  lib_run stacks_disabled_shape "/repos/o/r/pulls/7" 1 "gh: Not Found (HTTP 404)"
  assert_eq "a 404 off the stacks paths is not" 1 "${status}"
  lib_run stacks_disabled_shape "/repos/o/r/stacks/7/unstack" 1 "gh: Not Found (HTTP 404)"
  assert_eq "a 404 on a stack that is not there is not" 1 "${status}"
  lib_run stacks_disabled_shape "/repos/o/r/stacks" 1 "gh: Validation Failed (HTTP 422)"
  assert_eq "an unrelated 422 is not" 1 "${status}"
  lib_run stacks_disabled_shape "/repos/o/r/stacks" 0 ""
  assert_eq "and a call that answered is not" 1 "${status}"
}

@test "resolve_repo_slug takes --slug verbatim and refuses a malformed one" {
  lib_shell '
    set -euo pipefail
    source "${EVO_T1_SRC}/lib/common.sh"
    unset JSON_MODE
    source "${EVO_T1_SRC}/lib/stack_prs.sh"
    REPO_SLUG=toxicoder/ezrepo
    resolve_repo_slug
    printf "%s" "${REPO_SLUG}"
  '
  assert_eq "the slug is kept" 0 "${status}"
  assert_eq "and returned" "toxicoder/ezrepo" "${output}"

  lib_shell '
    set -euo pipefail
    source "${EVO_T1_SRC}/lib/common.sh"
    unset JSON_MODE
    source "${EVO_T1_SRC}/lib/stack_prs.sh"
    REPO_SLUG=only-a-name
    resolve_repo_slug
  '
  assert_eq "a nameless slug is refused" 1 "${status}"
  assert_match "with the reason" "wants owner/repo" "${stderr}"
}

@test "resolve_repo_dir refuses a directory that is not there" {
  lib_run resolve_repo_dir "${BATS_TEST_TMPDIR}/nope"
  assert_eq "unresolvable" 1 "${status}"
  lib_run resolve_repo_dir "${BATS_TEST_TMPDIR}"
  assert_eq "resolvable" 0 "${status}"
}

# -- create-stack ------------------------------------------------------------------

@test "create-stack posts the layers bottom-first and prints the new number" {
  export STUB_GH_OUT="7"
  run_cli create-stack --slug toxicoder/ezrepo --prs 12,13,14
  assert_eq "exit 0" 0 "${status}"
  assert_eq "one stack call" 1 "$(occurrences 'POST /repos/toxicoder/ezrepo/stacks')"
  assert_match "with the ordered body" \
    'body /repos/toxicoder/ezrepo/stacks {"pull_requests":\[12,13,14\]}' "$(gh_log)"
  assert_match "and the number" "stack 7 created from 3 layers" "${output}"
  # Not "layers stay drafts": this CLI creates no pull requests, so it cannot claim a
  # draft default it never sets. It only declines to clear draft without --open.
  assert_match "layers keep whatever draft state they have" "keep the draft state" "${output}"
}

@test "create-stack --open marks every layer ready" {
  export STUB_GH_OUT="7"
  run_cli create-stack --slug o/r --prs 12,13 --open
  assert_eq "exit 0" 0 "${status}"
  assert_eq "both layers go ready" 2 "$(occurrences 'POST /repos/o/r/pulls/')"
  assert_match "first layer" "PR 12 is ready for review" "${output}"
  assert_match "second layer" "PR 13 is ready for review" "${output}"
}

# -- add ---------------------------------------------------------------------------

@test "add posts the layer onto the stack" {
  run_cli add --slug o/r --stack 7 --pr 15
  assert_eq "exit 0" 0 "${status}"
  assert_eq "the add endpoint" 1 "$(occurrences 'POST /repos/o/r/stacks/7/add')"
  assert_match "with the PR number" \
    'body /repos/o/r/stacks/7/add {"pull_request":15}' "$(gh_log)"
  assert_match "and the verdict" "PR 15 joined stack 7" "${output}"
}

@test "add without a stack or a PR is an argument error, not a bad URL" {
  run_cli add --slug o/r --pr 15
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the missing flag" "add needs --stack N" "${stderr}"
  assert_eq "no half-built URL reached gh" 0 "$(occurrences 'stacks//add')"
}

# -- view --------------------------------------------------------------------------

@test "view lists every stack when no stack number is given" {
  stub_body "7	3" "8	2"
  run_cli view --slug o/r
  assert_eq "exit 0" 0 "${status}"
  assert_eq "the list endpoint" 1 "$(occurrences 'GET /repos/o/r/stacks')"
  assert_match "first row" "7" "${output}"
  assert_match "second row" "8" "${output}"
}

@test "view renders one stack's layers, or says there are none" {
  stub_body "12	feat/a	main	true" "13	feat/b	feat/a	true"
  run_cli view --slug o/r --stack 7
  assert_eq "exit 0" 0 "${status}"
  assert_eq "the single-stack endpoint" 1 "$(occurrences 'GET /repos/o/r/stacks/7')"
  assert_match "bottom layer" "12.*feat/a.*main" "${output}"
  assert_match "top layer" "13.*feat/b.*feat/a" "${output}"

  unset STUB_GH_BODY
  run_cli view --slug o/r --stack 8
  assert_match "an empty stack is a note" "no stacks to show" "${output}"
  assert_eq "and not a failure" 0 "${status}"
}

# -- retarget ----------------------------------------------------------------------

@test "retarget moves a drifted layer onto its parent branch and leaves the bottom" {
  stub_body "12	feat/a	feat/wrong	true" "13	feat/b	feat/a	true" "14	feat/c	feat/a	true"
  run_cli retarget --slug o/r --stack 7
  assert_eq "exit 0" 0 "${status}"
  assert_eq "the drifted top layer is patched" 1 "$(occurrences 'PATCH /repos/o/r/pulls/14')"
  assert_match "onto its parent branch" \
    'body /repos/o/r/pulls/14 {"base":"feat/b"}' "$(gh_log)"
  assert_eq "an already-correct layer is untouched" 0 "$(occurrences 'PATCH /repos/o/r/pulls/13')"
  assert_eq "the bottom layer is never retargeted" 0 "$(occurrences 'PATCH /repos/o/r/pulls/12')"
  assert_match "and is warned about instead" "based on feat/wrong, not main" "${output}"
}

# -- unstack -----------------------------------------------------------------------

@test "unstack posts the unstack endpoint" {
  run_cli unstack --slug o/r --stack 7
  assert_eq "exit 0" 0 "${status}"
  assert_eq "the endpoint" 1 "$(occurrences 'POST /repos/o/r/stacks/7/unstack')"
  assert_match "and the verdict" "stack 7 unstacked" "${output}"
}

# -- merge -------------------------------------------------------------------------

@test "merge lands a stack bottom-up through the async pair only" {
  stub_body "12	feat/a	main	true" "13	feat/b	feat/a	true"
  export STUB_GH_JOB="c0ffee-01"
  export STUB_GH_POLL="success"
  run_cli merge --slug o/r --stack 7 --poll-interval 1 --poll-timeout 5
  assert_eq "exit 0" 0 "${status}"
  assert_eq "two layers queued" 2 "$(occurrences 'PUT /repos/o/r/pulls/')"
  assert_eq "two jobs polled" 2 "$(occurrences 'GET /repos/o/r/pulls/')"
  assert_match "the job id is polled" "GET /repos/o/r/pulls/12/merge-async/c0ffee-01" "$(gh_log)"
  assert_match "with the method" 'body /repos/o/r/pulls/12/merge-async {"merge_method":"merge"}' "$(gh_log)"
  assert_match "both layers land" "merged 2 layers of stack 7, bottom-up" "${output}"

  # The order is the whole point: layer 12 has to be queued before layer 13.
  local first second
  first="$(gh_log | grep -n 'PUT /repos/o/r/pulls/12/merge-async' | head -n 1 | cut -d: -f1)"
  second="$(gh_log | grep -n 'PUT /repos/o/r/pulls/13/merge-async' | head -n 1 | cut -d: -f1)"
  [ -n "${first}" ] && [ -n "${second}" ] && [ "${first}" -lt "${second}" ] ||
    fail "layer 12 was not queued before layer 13: $(gh_log)"

  # And nothing went through the synchronous endpoint.
  assert_eq "no synchronous merge anywhere" 0 \
    "$(gh_log | grep -Ec 'PUT /repos/[^ ]*/pulls/[0-9]+/merge$' || true)"
}

@test "a layer whose merge job fails stops the stack there" {
  stub_body "12	feat/a	main	true" "13	feat/b	feat/a	true"
  export STUB_GH_JOB="c0ffee-01"
  export STUB_GH_POLL="failure"
  run_cli merge --slug o/r --stack 7 --poll-interval 1 --poll-timeout 5
  assert_eq "exit 1" 1 "${status}"
  assert_match "names the reported status" "status: failure" "${stderr}"
  assert_eq "the bottom layer was queued once" 1 "$(occurrences 'PUT /repos/o/r/pulls/12/merge-async')"
  assert_eq "and nothing above it was queued" 0 "$(occurrences 'PUT /repos/o/r/pulls/13/merge-async')"
}

@test "a merge job that never settles times out instead of hanging" {
  stub_body "12	feat/a	main	true"
  export STUB_GH_JOB="c0ffee-01"
  export STUB_GH_POLL="pending"
  run_cli merge --slug o/r --pr 12 --poll-interval 1 --poll-timeout 0
  assert_eq "exit 1" 1 "${status}"
  assert_match "says it gave up" "still pending after 0s" "${stderr}"
}

@test "merge --dry-run reads the layers and sends no write" {
  stub_body "12	feat/a	main	true" "13	feat/b	feat/a	true"
  run_cli merge --slug o/r --stack 7 --dry-run
  assert_eq "exit 0" 0 "${status}"
  assert_eq "no write was sent" 0 "$(occurrences 'PUT ')"
  assert_eq "no merge job was queued" 0 "$(occurrences 'merge-async')"
  assert_eq "the layer list was still read" 1 "$(occurrences 'GET /repos/o/r/stacks/7')"
  assert_match "each write is printed instead" "would merge-async PR 12" "${output}"
  assert_match "in order" "would merge-async PR 13" "${output}"
}

# -- the injected pair and the missing setting -------------------------------------

@test "every call removes the stale injected pair before invoking gh" {
  run_cli view --slug o/r --stack 7
  assert_eq "exit 0" 0 "${status}"
  assert_eq "the stub saw nothing injected" 0 "$(occurrences 'pair=present')"
  assert_match "on a call that really ran" "pair=clear GET /repos/o/r/stacks/7" "$(gh_log)"
}

# The 404 on a /stacks path is the shape a repository without the feature answers, and
# it is the only thing the CLI keys the HANDOFF on. This replaced a pin on `gh` exit 9,
# which is the `gh stack` extension's documented code
# (docs: stacked-prs-cli-commands#exit-codes) and carries no documented meaning for the
# `gh api` transport this CLI uses.
@test "a 404 on a stacks path becomes a HANDOFF note and its own exit code" {
  export STUB_GH_RC=1
  export STUB_GH_ERR="gh: Not Found (HTTP 404)"
  run_cli view --slug toxicoder/ezrepo --stack 7
  assert_eq "exit 3" 3 "${status}"
  assert_match "the note is a HANDOFF" "HANDOFF: stacks are not enabled for toxicoder/ezrepo" "${stderr}"
  assert_match "and points at the feature" "stacked-pull-requests feature" "${stderr}"
  assert_match "with the settings path" "settings" "${stderr}"
}

@test "an undocumented exit 9 is an ordinary failed call, not the missing setting" {
  export STUB_GH_RC=9
  run_cli view --slug toxicoder/ezrepo --stack 7
  assert_eq "the verb fails as a call would" 1 "${status}"
  assert_match "naming the endpoint and the code" \
    "could not read /repos/toxicoder/ezrepo/stacks/7 \(exit 9\)" "${stderr}"
  assert_eq "without any HANDOFF note" 0 "$(grep -Ec 'HANDOFF' <<<"${stderr}" || true)"
}

@test "a failing call is exit 1 and a counted failure, not exit 2" {
  export STUB_GH_RC=1
  run_cli unstack --slug o/r --stack 7
  assert_eq "exit 1" 1 "${status}"
  assert_match "the endpoint is named" "could not unstack from stack 7" "${stderr}"
  assert_match "with the summary line" "^summary:" "${output}"
}

@test "a --repo that cannot be entered is exit 2 with no call" {
  run_cli view --repo "${BATS_TEST_TMPDIR}/no-such-dir"
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the path it tried" "cannot enter --repo" "${stderr}"
  assert_eq "no gh call" 0 "$(occurrences 'gh api')"
}

@test "a checkout with no origin remote is exit 2 with no call" {
  local bare="${BATS_TEST_TMPDIR}/no-origin"
  mkdir -p "${bare}"
  git -C "${bare}" init -q
  run_cli view --repo "${bare}"
  assert_eq "exit 2" 2 "${status}"
  assert_match "says what it tried" "no origin remote" "${stderr}"
  assert_match "and offers the way out" "pass --slug" "${stderr}"
  assert_eq "no gh call" 0 "$(occurrences 'gh api')"
}

@test "a non-github origin is refused rather than sent as a slug" {
  local bare="${BATS_TEST_TMPDIR}/gitlab-origin"
  mkdir -p "${bare}"
  git -C "${bare}" init -q
  git -C "${bare}" remote add origin https://gitlab.com/toxicoder/ezrepo.git
  run_cli view --repo "${bare}"
  assert_eq "exit 2" 2 "${status}"
  assert_match "names the remote it read" "is not a github.com repository" "${stderr}"
  assert_eq "no gh call" 0 "$(occurrences 'gh api')"
}
