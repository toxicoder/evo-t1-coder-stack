#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## branch-hygiene.bats - hermetic coverage for scripts/branch-hygiene.sh
#
# What this suite pins is the audit's three verdicts and its one hard limit:
#
#   - a branch that carries an environment word is an ERROR on both sides of the
#     remote boundary - `origin/staging` and a local `staging` - because
#     docs/branching.md makes environments GitHub Environments and never branches,
#     and the word is matched against the branch name with the remote namespace
#     stripped (matching `origin/staging` whole would test the word `origin` and
#     find nothing, which is the exact way this check could pass while blind);
#   - the sanctioned work prefixes stay clean, so `test/flake-fix` is not the same
#     shape as a bare `test`; only the environment words are reserved;
#   - a branch the trunk already contains is reported once, under the merged rule,
#     with its tip SHA, and is NOT then re-reported as stale: a second line calling
#     a merged branch "unmerged" states the opposite of what the ancestry test just
#     proved;
#   - an unmerged branch past --max-age is a warning, under --strict it is a
#     failure, and a branch inside the lifetime is no finding at all;
#   - `gh-pages`, the trunk, and the branch under your feet are exempt, and
#     `origin/HEAD` is a pointer rather than a branch, so it appears nowhere;
#   - the CLI never deletes. --plan prints the commands and every branch the run
#     named is still there afterwards, which is the property that makes an operator
#     willing to run it against a real remote.
#
# Hermetic by construction: each test builds its own throwaway clone with
# fixture_repo - a bare origin plus a working repo that pushes to it - so no test
# reads this checkout's branches, no test reaches the network, and a change to
# this repo's own branch list cannot turn this suite red or green.
#
# Two layers, because the rules live in scripts/lib/branch_hygiene.sh and the CLI is
# the ingress. The predicate tests source that lib and call each function directly:
# is_environment_name against names on both sides of the remote boundary, branch_part
# against a configured remote and one that is not, is_always_kept on a second remote's
# trunk, report_or_warn's two weights, and each audit over hand-built rows. The rest
# drive scripts/branch-hygiene.sh end to end and assert its exit codes, which is the
# only place the section order, the summary line, and the never-deletes promise live.
# A predicate only the CLI ever reached would satisfy neither the function inventory
# nor a reader asking whether the rule itself is tested.
#
# Usage: bazelisk test //tests:bats_branch_hygiene_test   (from any cwd)
#
# Safety: fixture only. Nothing here touches a real remote or deletes a branch.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/branch-hygiene.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/branch-hygiene.sh is not in the tree"
  fi
}

# fixture_repo - build a throwaway clone at $FIXTURE and print its path.
#
# The bare repo is the remote, so the working repo's refs/remotes/origin/* are real
# remote-tracking refs rather than something hand-written: the audit resolves them
# with git merge-base, and a fabricated ref would test the parser and not the rule.
# origin/HEAD is created explicitly with `set-head`, because `git push` never makes
# one and the filter that drops it would otherwise go unexercised.
fixture_repo() {
  FIXTURE="${BATS_TEST_TMPDIR?}/fixture"
  export FIXTURE_GIT=("${FIXTURE}/work")
  mkdir -p "${FIXTURE}"
  git init -q --bare "${FIXTURE}/origin.git"
  # git init --bare points HEAD at the platform default, which on a runner is not
  # necessarily main. `remote set-head -a` below reads that HEAD to build
  # origin/HEAD, and a HEAD naming a branch the bare repo never received fails the
  # whole fixture with "Cannot determine remote HEAD".
  git -C "${FIXTURE}/origin.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "${FIXTURE}/work"
  git -C "${FIXTURE}/work" init -q -b main
  git -C "${FIXTURE}/work" config user.name "Branch Hygiene Test"
  git -C "${FIXTURE}/work" config user.email "bats@example.invalid"
  git -C "${FIXTURE}/work" config commit.gpgsign false
  : >"${FIXTURE}/work/docker-compose.yml"
  git -C "${FIXTURE}/work" add docker-compose.yml
  git -C "${FIXTURE}/work" commit -q -m "seed"
  git -C "${FIXTURE}/work" remote add origin "${FIXTURE}/origin.git"
  git -C "${FIXTURE}/work" push -q -u origin main
  git -C "${FIXTURE}/work" remote set-head origin -a
  printf '%s' "${FIXTURE}/work"
}

# add_branch <name> [days-ago] - commit on a new branch off main and push it. The
# committer date is what for-each-ref reads, so GIT_COMMITTER_DATE on the commit is
# what makes a branch old; the file date would not move it. An empty commit keeps
# each branch one commit from main regardless of what other branches added.
add_branch() {
  local name="$1" days="${2:-0}" when
  when="$(date -d "-${days} days" +%Y-%m-%dT12:00:00Z 2>/dev/null ||
    date -v-"${days}"d +%Y-%m-%dT12:00:00Z)"
  git -C "${FIXTURE}/work" switch -q -c "${name}" main
  GIT_COMMITTER_DATE="${when}" GIT_AUTHOR_DATE="${when}" \
    git -C "${FIXTURE}/work" commit -q --allow-empty -m "work on ${name}"
  git -C "${FIXTURE}/work" push -q origin "${name}"
  git -C "${FIXTURE}/work" switch -q main
}

# add_layer <child> <base> [days-ago] - commit on a new branch cut from another
# branch rather than from main, which is the shape a stacked layer has: it carries
# its base's commits, so the trunk can never contain its tip while the base stays
# unmerged. The base is pushed first, so the child's remote-tracking ref resolves.
add_layer() {
  local name="$1" base="$2" days="${3:-0}" when
  when="$(date -d "-${days} days" +%Y-%m-%dT12:00:00Z 2>/dev/null ||
    date -v-"${days}"d +%Y-%m-%dT12:00:00Z)"
  git -C "${FIXTURE}/work" push -q origin "${base}"
  git -C "${FIXTURE}/work" switch -q -c "${name}" "${base}"
  GIT_COMMITTER_DATE="${when}" GIT_AUTHOR_DATE="${when}" \
    git -C "${FIXTURE}/work" commit -q --allow-empty -m "work on ${name}"
  git -C "${FIXTURE}/work" push -q origin "${name}"
  git -C "${FIXTURE}/work" switch -q main
}

# merge_into_main <name> - fast-forward main onto the branch, which is the shape a
# merged work branch has: its tip is an ancestor of main and it is still there.
merge_into_main() {
  git -C "${FIXTURE}/work" merge -q --ff-only "${1}"
}

# audit [args...] - run the CLI against the fixture.
#
# --separate-stderr is kept because it is the stronger form: common.sh's err() and
# fail_item() write findings to stderr, so asserting on ${stderr} pins that a finding
# is an error line and not merely some text the run produced.
audit() {
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= bash "${SCRIPT}" --repo "${FIXTURE}/work" "$@"
}

# occurrences <needle> - how many output lines carry the needle.
occurrences() {
  printf '%s\n' "${output}" | grep -F -- "$1" | wc -l | tr -d ' '
}

# load_lib - bring the rules into the test's own shell so each predicate can be
# called directly. common.sh comes first because the audit functions report through
# its log/ok/warn/fail_item, exactly as the CLI sources them in that order.
load_lib() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  unset JSON_MODE
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/branch_hygiene.sh"
}

# reset_counters - SUMMARY_* are globals that the lib's report_or_warn accumulates
# into, and bats reuses one shell across a test, so a unit test that asserts a count
# has to start from a known zero rather than from whatever a previous call left.
reset_counters() {
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  SUMMARY_FAIL_ITEMS=""
}

# deny <predicate> [args...] - assert a predicate does NOT match, in a form that can
# actually fail the run. A bare `! predicate` line cannot: `set -e` is switched off
# for any command whose status is inverted with `!`, so a regression there is printed
# and walked past, and the last command of the body decides the outcome. Proven by
# putting a deleted word back in the reserved table while the asserting test stayed
# green.
deny() {
  if "$@"; then
    echo "expected no match, but this succeeded: $*" >&2
    return 1
  fi
}

@test "branch-hygiene: is_environment_name reads the branch name, not the remote" {
  load_lib
  (is_environment_name staging)
  (is_environment_name production)
  (is_environment_name prod/hotfix-42)
  (is_environment_name pre-production)
  # The sanctioned prefixes stay clean, and a namespace that is not an environment
  # word does not become one because it happens to be a path. `pre` alone is not in
  # the table: as a first segment it would sweep in anything filed under pre/.
  deny is_environment_name feat/search-lane
  deny is_environment_name test/flake-fix
  deny is_environment_name chore/branch-hygiene-gate
  deny is_environment_name main
  deny is_environment_name pre/2026-11-migration
}

@test "branch-hygiene: every word in the reserved tables is a name git can produce" {
  # A table entry that git cannot name is a rule that never fires, and the table once
  # carried `dev - 1` and `pre - production` exactly that way: present, advertised,
  # and covering nothing. This test is what keeps the two tables honest.
  load_lib
  local word
  for word in "${!ENVIRONMENT_WORDS[@]}" "${!TRUNK_NAMES[@]}"; do
    [[ "${word}" != *" "* ]] || return 1
    # The substitution deletes every character outside printable ASCII, so a word
    # that comes back unchanged held nothing but ASCII. `dev - 1` comes back as
    # `dev-1`, which is how this catches a table entry git can never name.
    [[ "${word}" == "${word//[^!-~]/}" ]] || return 1
    git check-ref-format --branch "${word}" >/dev/null 2>&1 || return 1
  done
  (is_environment_name pre-production)
}

@test "branch-hygiene: reserved_name_kind separates an environment from a second trunk" {
  load_lib
  # Called directly, not in a subshell: the verdict lands in the RESERVED_* globals,
  # and a subshell would keep them and hand back only the exit status.
  reserved_name_kind staging
  [ "${RESERVED_KIND}" = "environment" ]
  [ "${RESERVED_WORD}" = "staging" ]
  # A legacy master is a broken "one long-lived branch" rule, not an environment
  # nobody promoted, so it must not be reported as one.
  reserved_name_kind master
  [ "${RESERVED_KIND}" = "trunk" ]
  [ "${RESERVED_WORD}" = "master" ]
  deny is_environment_name master
  # Only a bare name is a second trunk; a path below it is a namespace someone chose.
  deny reserved_name_kind master/legacy-import
}

@test "branch-hygiene: a second trunk is reported with its own sentence" {
  fixture_repo >/dev/null
  add_branch master
  audit
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"is reserved: 'master' is a second trunk name"* ]]
  # The clause is the point of the separate message: a second trunk breaks "main is
  # the only long-lived branch", and pinning only the prefix would let that sentence
  # drift back to calling it an environment nobody promoted.
  [[ "${stderr}" == *"'master' is a second trunk name; docs/branching.md makes main the only long-lived branch"* ]]
  [[ "${stderr}" != *"master'* is an environment name"* ]]
}

@test "branch-hygiene: the lib can be sourced twice without erroring" {
  # It is a sourced helper, so a second source has to be a no-op. A readonly table
  # made the second source die with "ENVIRONMENT_WORDS: readonly variable".
  load_lib
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; \
    source '${REPO_ROOT}/scripts/lib/branch_hygiene.sh'; \
    source '${REPO_ROOT}/scripts/lib/branch_hygiene.sh'; echo SOURCED-OK"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SOURCED-OK"* ]]
  [[ "${output}" != *"readonly variable"* ]]
}

@test "branch-hygiene: a lib sourced from inside a function keeps its tables global" {
  # The scope a sourced file's `declare` lands in is the sourcing function's, so a
  # plain `declare -A` here scoped the reserved tables to load_lib: every lookup came
  # back empty and is_environment_name called `staging` a clean name. `declare -g` is
  # what makes the lib behave the same whoever sources it.
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; unset JSON_MODE; \
    load_it() { source '${REPO_ROOT}/scripts/lib/branch_hygiene.sh'; }; \
    load_it; is_environment_name staging; echo rc=\$?"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"rc=0"* ]]
}

@test "branch-hygiene: selected_remotes follows --remote and falls back to all" {
  # --fetch has to spend its network on the remotes the run actually reports on.
  fixture_repo >/dev/null
  git -C "${FIXTURE}/work" remote add backup "${FIXTURE}/origin.git"
  cd "${FIXTURE}/work"
  load_lib
  REMOTES=()
  run selected_remotes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"origin"* ]]
  [[ "${output}" == *"backup"* ]]
  REMOTES=(backup)
  run selected_remotes
  [ "${output}" = "backup" ]
  # An empty --remote value is nothing to act on, and it must not reach git.
  REMOTES=("" backup)
  run selected_remotes
  [ "${output}" = "backup" ]
}

@test "branch-hygiene: branch_part strips a configured remote and nothing else" {
  fixture_repo >/dev/null
  cd "${FIXTURE}/work"
  load_lib
  [ "$(branch_part remote origin/staging)" = "staging" ]
  [ "$(branch_part remote origin/feat/two-segments)" = "feat/two-segments" ]
  # A local name is already the branch name, slashes and all.
  [ "$(branch_part local chore/foo)" = "chore/foo" ]
  # A leading segment that is not a configured remote is part of the name.
  [ "$(branch_part remote notes/not-a-remote)" = "notes/not-a-remote" ]
}

@test "branch-hygiene: is_always_kept exempts the trunk and gh-pages on any remote" {
  # The predicate decides on the branch part, and the branch part depends on which
  # remotes the repository actually has, so this needs a real one under it.
  fixture_repo >/dev/null
  git -C "${FIXTURE}/work" remote add backup "${FIXTURE}/origin.git"
  cd "${FIXTURE}/work"
  load_lib
  TRUNK=main
  (is_always_kept local main)
  (is_always_kept remote origin/main)
  # The remote's own name is not what makes the trunk the trunk.
  (is_always_kept remote backup/main)
  (is_always_kept local gh-pages)
  (is_always_kept remote origin/gh-pages)
  (is_always_kept remote backup/gh-pages)
  deny is_always_kept local feat/landed
  deny is_always_kept remote origin/feat/landed
  deny is_always_kept remote backup/feat/landed
}

@test "branch-hygiene: report_or_warn counts an error always and a warning only without --strict" {
  load_lib
  reset_counters
  STRICT=0
  report_or_warn warn "a warning"
  [ "${SUMMARY_WARN}" -eq 1 ]
  [ "${SUMMARY_FAIL}" -eq 0 ]
  STRICT=1
  report_or_warn warn "the same thing, now a finding"
  [ "${SUMMARY_FAIL}" -eq 1 ]
  STRICT=0
  report_or_warn error "an error is never a warning"
  [ "${SUMMARY_FAIL}" -eq 2 ]
}

@test "branch-hygiene: audit_environment flags the environment row and blesses the rest" {
  load_lib
  reset_counters
  audit_environment local \
    "$(printf 'staging\taaa1111\t2026-01-01\nfeat/ok\tbbb2222\t2026-01-01')"
  [ "${SUMMARY_FAIL}" -eq 1 ]
  [ "${SUMMARY_OK}" -eq 1 ]
}

@test "branch-hygiene: the row lists carry a real name, tip, and date, and drop origin/HEAD" {
  fixture_repo >/dev/null
  add_branch feat/listed
  cd "${FIXTURE}/work"
  load_lib
  run list_remote
  [[ "${output}" != *"origin/HEAD"* ]]
  local row
  row="$(printf '%s\n' "${output}" | grep -F 'origin/feat/listed' | head -1)"
  [ -n "${row}" ]
  [ "$(printf '%s' "${row}" | cut -f1)" = "origin/feat/listed" ]
  [ "$(printf '%s' "${row}" | cut -f2)" = "$(git rev-parse --short feat/listed)" ]
  [[ "$(printf '%s' "${row}" | cut -f3)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  run list_local
  [[ "${output}" == *"main"* ]]
}

@test "branch-hygiene: audit_merged names the merged row once and plans its deletion" {
  fixture_repo >/dev/null
  add_branch feat/landed
  merge_into_main feat/landed
  cd "${FIXTURE}/work"
  load_lib
  local rows
  rows="$(printf 'feat/landed\t%s\t2026-11-01' "$(git rev-parse --short feat/landed)")"
  reset_counters
  PLAN=0
  audit_merged local main "${rows}" "" ""
  [ "${SUMMARY_WARN}" -eq 1 ]
  # --plan is the only way a deletion command reaches the operator, and it prints
  # the tip SHA alongside it so the record exists before the command is run.
  reset_counters
  PLAN=1
  run audit_merged local main "${rows}" "" ""
  [[ "${output}" == *"git branch -d feat/landed"* ]]
  [[ "${output}" == *"record tip $(git rev-parse --short feat/landed) first"* ]]
}

@test "branch-hygiene: audit_stale skips what the trunk already has" {
  fixture_repo >/dev/null
  add_branch feat/landed
  add_branch feat/abandoned 90
  merge_into_main feat/landed
  cd "${FIXTURE}/work"
  load_lib
  MAX_AGE_DAYS=14
  reset_counters
  audit_stale local main \
    "$(printf 'feat/landed\t%s\t2000-01-01\nfeat/abandoned\t%s\t2000-01-02' \
      "$(git rev-parse --short feat/landed)" "$(git rev-parse --short feat/abandoned)")" ""
  # Only the unmerged one is stale: the merged row belongs to audit_merged, and a
  # second line calling it "unmerged" would contradict the ancestry test just run.
  [ "${SUMMARY_WARN}" -eq 1 ]
}

@test "branch-hygiene: parse_args fills every option and usage lists them" {
  load_lib
  parse_args --repo /tmp/somewhere --trunk master --max-age 3 --strict --plan --fetch \
    --remote origin
  [ "${REPO_ARG}" = "/tmp/somewhere" ]
  [ "${TRUNK}" = "master" ]
  [ "${MAX_AGE_DAYS}" -eq 3 ]
  [ "${STRICT}" -eq 1 ]
  [ "${PLAN}" -eq 1 ]
  [ "${DO_FETCH}" -eq 1 ]
  [ "${REMOTES[0]}" = "origin" ]
  run usage
  [[ "${output}" == *"--max-age DAYS"* ]]
  [[ "${output}" == *"--plan"* ]]
}

@test "branch-hygiene: plan_deletion prints the remote form without running it" {
  fixture_repo >/dev/null
  add_branch staging
  cd "${FIXTURE}/work"
  load_lib
  run plan_deletion remote origin/staging ddb08cb7
  [[ "${output}" == *"git push origin --delete staging"* ]]
  [[ "${output}" == *"record tip ddb08cb7 first"* ]]
  # The command is text. The branch it names is still there.
  [ -n "$(git -C "${FIXTURE}/work" rev-parse --verify --quiet refs/remotes/origin/staging)" ]
}

@test "branch-hygiene: plan_deletion names the row's own remote" {
  # A checkout carrying a second remote is the case a literal `origin` gets wrong:
  # the operator is told to delete a same-named branch on the wrong remote, and the
  # tip SHA they dutifully record belongs to the ref the plan did not mean.
  fixture_repo >/dev/null
  git -C "${FIXTURE}/work" remote add backup "${FIXTURE}/origin.git"
  cd "${FIXTURE}/work"
  load_lib
  run plan_deletion remote backup/legacy-import ddb08cb7
  [[ "${output}" == *"git push backup --delete legacy-import"* ]]
  [[ "${output}" != *"git push origin --delete"* ]]
  run plan_deletion local legacy-import ddb08cb7
  [[ "${output}" == *"git branch -d legacy-import"* ]]
}

@test "branch-hygiene: resolve_repo_arg anchors a relative path and refuses a dead one" {
  fixture_repo >/dev/null
  load_lib
  INVOKE_DIR="${FIXTURE}"
  [ "$(resolve_repo_arg work)" = "${FIXTURE}/work" ]
  # An absolute --repo is the operator's own answer and survives untouched.
  [ "$(resolve_repo_arg "${FIXTURE}/work")" = "${FIXTURE}/work" ]
  deny resolve_repo_arg no-such-dir
  # Refusing a path must not conjure it: a helper that "fixed" the miss with mkdir -p
  # would turn every typo'd --repo into a directory that then fails the git check with
  # a message about a repository rather than about the path the operator typed.
  [ ! -e "${FIXTURE}/no-such-dir" ]
}

@test "branch-hygiene: a relative --repo resolves against the Bazel workspace dir" {
  # `bazelisk run //scripts:branch-hygiene -- --repo .` starts its launcher inside
  # the runfiles tree, so $PWD is not where the operator typed the command. Bazel
  # leaves BUILD_WORKSPACE_DIRECTORY behind for exactly this, and a relative --repo
  # that ignored it failed with "is not a git repository" on a real run.
  fixture_repo >/dev/null
  mkdir -p "${BATS_TEST_TMPDIR}/runfiles"
  run --separate-stderr env -C "${BATS_TEST_TMPDIR}/runfiles" REPO_ROOT= \
    BUILD_WORKSPACE_DIRECTORY="${FIXTURE}" GITHUB_WORKSPACE= \
    bash "${SCRIPT}" --repo work
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"summary:"* ]]
  # The control: the same relative path with no anchor names a directory that is
  # not there, and the run has to say so and exit 2 rather than audit nothing.
  run --separate-stderr env -C "${BATS_TEST_TMPDIR}/runfiles" REPO_ROOT= \
    BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    bash "${SCRIPT}" --repo work
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"cannot enter --repo work"* ]]
}

@test "branch-hygiene: a trunk-only clone is clean and exits 0" {
  fixture_repo >/dev/null
  audit
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"summary: "* ]]
  [[ "${output}" != *"warning:"* ]]
  [[ "${output}" != *"error:"* ]]
}

@test "branch-hygiene: a remote environment branch is an error naming its tip" {
  fixture_repo >/dev/null
  add_branch staging
  audit
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"remote branch origin/staging is reserved"* ]]
  # The tip SHA has to be on the line: it is the record the working rules want kept
  # before anyone deletes the branch.
  [[ "${stderr}" == *"origin/staging is reserved: 'staging' is an environment name"* ]]
  local tip
  tip="$(git -C "${FIXTURE}/work" rev-parse --short refs/remotes/origin/staging)"
  [[ "${stderr}" == *"(tip ${tip})"* ]]
  # The branch exists on both sides of the remote boundary, and each is its own
  # finding: deleting origin/staging does not remove the local one.
  [ "$(occurrences 'is reserved:')" -eq 2 ]
  [[ "${output}" == *"summary: "*"2 failed"* ]]
}

@test "branch-hygiene: a local environment branch is an error too" {
  fixture_repo >/dev/null
  add_branch production
  audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"local branch production is reserved"* ]]
  [[ "${output}" == *"remote branch origin/production is reserved"* ]]
}

@test "branch-hygiene: an environment word below a namespace is still an environment branch" {
  fixture_repo >/dev/null
  add_branch prod/hotfix-42
  audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"origin/prod/hotfix-42 is reserved"* ]]
}

@test "branch-hygiene: a sanctioned work prefix stays clean" {
  fixture_repo >/dev/null
  add_branch test/flake-fix
  add_branch feat/search-lane
  audit
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"local branch test/flake-fix is not a reserved name"* ]]
  [[ "${stderr}" != *"environment name"* ]]
  [[ "${output}" == *"0 failed"* ]]
}

@test "branch-hygiene: gh-pages and the trunk are never cleanup candidates" {
  fixture_repo >/dev/null
  add_branch gh-pages
  merge_into_main gh-pages
  audit
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"gh-pages is merged"* ]]
  [[ "${output}" != *"main is merged"* ]]
}

@test "branch-hygiene: a merged local branch is warned about with its tip SHA" {
  fixture_repo >/dev/null
  add_branch feat/landed
  merge_into_main feat/landed
  audit
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"local branch feat/landed is merged into main and still present"* ]]
  [[ "${output}" == *"feat/landed is merged into main and still present (tip "* ]]
}

@test "branch-hygiene: a merged branch is not also reported as stale" {
  fixture_repo >/dev/null
  add_branch feat/old-and-landed 90
  merge_into_main feat/old-and-landed
  audit --max-age 14
  # Named once, under the rule that actually applies. The stale audit tests
  # ancestry for the same reason: a line calling this branch "unmerged" would
  # contradict the merge-base answer the section above just used.
  [[ "${output}" == *"is merged into main and still present"* ]]
  [[ "${output}" != *"feat/old-and-landed is unmerged"* ]]
  [[ "${stderr}" != *"feat/old-and-landed is unmerged"* ]]
  # Local and remote are each reported, and each exactly once.
  [ "$(occurrences 'feat/old-and-landed is merged into main')" -eq 2 ]
}

@test "branch-hygiene: an unmerged branch past the lifetime is a warning" {
  fixture_repo >/dev/null
  add_branch feat/abandoned 90
  audit --max-age 14
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"origin/feat/abandoned is unmerged and its last commit is"* ]]
  [[ "${output}" == *"older than the 14-day branch lifetime"* ]]
}

@test "branch-hygiene: a branch inside the lifetime is no finding" {
  fixture_repo >/dev/null
  add_branch feat/in-progress 2
  audit --max-age 14
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"feat/in-progress is unmerged"* ]]
  [[ "${output}" != *"warning:"* ]]
}

@test "branch-hygiene: a stack layer is not stale while its base branch is live" {
  fixture_repo >/dev/null
  add_branch feat/base-layer 30
  add_layer feat/top-layer feat/base-layer 30
  audit --max-age 14
  [ "${status}" -eq 0 ]
  # The base of the stack carries work main does not have and nothing exempts it, so
  # it is the row that answers for the whole stack: one warning, not two.
  [[ "${output}" == *"local branch feat/base-layer is unmerged and its last commit is"* ]]
  # The layer carries its base's commits, so the trunk can never contain its tip and
  # trunk-only ancestry would read it as abandoned in its own right.
  [ "$(occurrences 'feat/top-layer is unmerged')" -eq 0 ]
  [[ "${stderr}" != *"feat/top-layer is unmerged"* ]]
  # Merge the base and the layer loses the live branch that made it active: it is now
  # an unmerged branch of its own and a cleanup candidate like any other. The merged
  # base keeps its own verdict, so widening the layer's ancestry did not cost the
  # delete-on-merge rule anything.
  merge_into_main feat/base-layer
  audit --max-age 14
  [[ "${output}" == *"local branch feat/base-layer is merged into main and still present"* ]]
  [[ "${output}" == *"local branch feat/top-layer is unmerged and its last commit is"* ]]
  # --plan is unaffected by the layer rule: the merged base is still offered up with
  # its tip recorded first, and the layer is never offered, which is what a widened
  # test in audit_merged instead of audit_stale would have done.
  audit --max-age 14 --plan
  [[ "${output}" == *"git branch -d feat/base-layer"* ]]
  [[ "${output}" == *"record tip $(git -C "${FIXTURE}/work" rev-parse --short feat/base-layer) first"* ]]
  [[ "${output}" != *"git branch -d feat/top-layer"* ]]
}

@test "branch-hygiene: live_base_branches names the layer and keeps one row answerable" {
  fixture_repo >/dev/null
  add_branch feat/base
  add_layer feat/top feat/base 40
  cd "${FIXTURE}/work"
  load_lib
  local rows
  rows="$(printf 'feat/base\t%s\t2026-10-01\nfeat/top\t%s\t2026-10-02' \
    "$(git rev-parse --short feat/base)" "$(git rev-parse --short feat/top)")"
  run live_base_branches local main "${rows}" ""
  [ "${output}" = "feat/top" ]
  # Two rows at one tip contain each other, so an unguarded test would exempt both
  # and stop reporting a stale duplicate pair altogether. Equal tips exempt only the
  # later name, which leaves the earlier row as the candidate for the pair.
  git -C "${FIXTURE}/work" branch dup/aaa feat/base
  git -C "${FIXTURE}/work" branch dup/zzz feat/base
  rows="$(printf 'dup/aaa\t%s\t2026-10-01\ndup/zzz\t%s\t2026-10-01' \
    "$(git rev-parse --short dup/aaa)" "$(git rev-parse --short dup/zzz)")"
  run live_base_branches local main "${rows}" ""
  [ "${output}" = "dup/zzz" ]
}

@test "branch-hygiene: --strict promotes the stale warning to a failure" {
  fixture_repo >/dev/null
  add_branch feat/abandoned 90
  audit --max-age 14 --strict
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"feat/abandoned is unmerged"* ]]
  # Without --strict the same two branches are warnings and the run exits 0; here
  # they are counted, which is what a gate that has to be exact asks for.
  [[ "${output}" == *"0 warnings"* ]]
  [[ "${output}" == *"2 failed"* ]]
}

@test "branch-hygiene: --plan prints deletions and deletes nothing" {
  fixture_repo >/dev/null
  add_branch feat/landed
  merge_into_main feat/landed
  add_branch staging
  audit --plan
  [[ "${output}" == *"git push origin --delete "* ]]
  [[ "${output}" == *"git branch -d "* ]]
  # The whole safety property: naming a branch for deletion must not perform it.
  [ -n "$(git -C "${FIXTURE}/work" rev-parse --verify --quiet refs/heads/feat/landed)" ]
  [ -n "$(git -C "${FIXTURE}/work" rev-parse --verify --quiet refs/heads/staging)" ]
  [ -n "$(git -C "${FIXTURE}/work" rev-parse --verify --quiet refs/remotes/origin/staging)" ]
}

@test "branch-hygiene: origin/HEAD is a pointer and appears nowhere" {
  fixture_repo >/dev/null
  # Prove the pointer exists first, or this test would pass by never having one.
  [ -n "$(git -C "${FIXTURE}/work" rev-parse --verify --quiet refs/remotes/origin/HEAD)" ]
  audit
  [[ "${output}" != *"origin/HEAD"* ]]
}

@test "branch-hygiene: the checked-out branch is exempt from the merged list" {
  fixture_repo >/dev/null
  add_branch feat/landed
  merge_into_main feat/landed
  # Built after the merge so it descends from main's new tip and fast-forwards too.
  add_branch feat/also-landed
  merge_into_main feat/also-landed
  git -C "${FIXTURE}/work" switch -q feat/landed
  audit
  # The positive control belongs here. An assertion that names only what must be
  # absent is also satisfied by a run that reported nothing at all, which is exactly
  # the failure this exemption could hide.
  [[ "${output}" == *"local branch feat/also-landed is merged"* ]]
  [[ "${output}" != *"local branch feat/landed is merged"* ]]
}

@test "branch-hygiene: --remote limits the scan to that remote" {
  fixture_repo >/dev/null
  add_branch staging
  git -C "${FIXTURE}/work" remote add backup "${FIXTURE}/origin.git"
  git -C "${FIXTURE}/work" push -q backup staging
  audit --remote backup
  [ "${status}" -eq 1 ]
  # The named remote is the only one consulted, so its own spelling of the branch
  # is what the rules see, and no origin/ row appears at all.
  [[ "${stderr}" == *"remote branch backup/staging is reserved"* ]]
  [[ "${output}" != *"origin/"* ]]
  [[ "${stderr}" != *"origin/"* ]]
}

@test "branch-hygiene: a second remote's own trunk ref is exempt too" {
  fixture_repo >/dev/null
  git -C "${FIXTURE}/work" remote add backup "${FIXTURE}/origin.git"
  git -C "${FIXTURE}/work" push -q backup main
  audit --remote backup
  # The exemption is decided on the branch part, so `backup/main` reads as the trunk
  # the way `origin/main` does. Hardcoding origin/ here would report a second
  # remote's trunk as a branch that outlived its change.
  [[ "${output}" == *"remote branch backup/main is not a reserved name"* ]]
  [[ "${output}" != *"backup/main is merged"* ]]
}

@test "branch-hygiene: a directory that is not a git repo exits 2" {
  fixture_repo >/dev/null
  mkdir -p "${BATS_TEST_TMPDIR?}/not-a-repo"
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= bash "${SCRIPT}" --repo "${BATS_TEST_TMPDIR}/not-a-repo"
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"not a git repository"* ]]
}

@test "branch-hygiene: an unknown argument is refused with the usage block" {
  fixture_repo >/dev/null
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= bash "${SCRIPT}" --repo "${FIXTURE}/work" --delete-them-all
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"unknown argument: --delete-them-all"* ]]
  [[ "${stderr}" == *"Usage: branch-hygiene.sh"* ]]
}

@test "branch-hygiene: --max-age that is not a number is refused" {
  fixture_repo >/dev/null
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= bash "${SCRIPT}" --repo "${FIXTURE}/work" --max-age soon
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"--max-age wants a whole number of days"* ]]
}

@test "branch-hygiene: a clone with no trunk exits 2 rather than reporting a clean tree" {
  fixture_repo >/dev/null
  # Rename rather than add, so no branch called main survives on either side: a run
  # that quietly reported "0 failed" here would be a gate green on a checkout it
  # never actually read.
  git -C "${FIXTURE}/work" branch -m main trunk
  git -C "${FIXTURE}/work" push -q origin trunk
  # A bare repo denies deleting the branch its HEAD names, so move HEAD onto trunk
  # first - otherwise this setup line, not the CLI, decides the test's outcome.
  git -C "${FIXTURE}/origin.git" symbolic-ref HEAD refs/heads/trunk
  git -C "${FIXTURE}/work" push -q origin --delete main
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= bash "${SCRIPT}" --repo "${FIXTURE}/work"
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"no trunk branch main"* ]]
}

@test "branch-hygiene: a remote whose own name holds a slash is still a remote" {
  # git accepts `git remote add ns/x <url>`, and a first-path-segment split of the row
  # ns/x/staging reads the remote as `ns` and the branch as `x/staging`. The
  # environment rule then printed "ok" for a branch literally named staging.
  fixture_repo >/dev/null
  cd "${FIXTURE}/work"
  git remote add "ns/x" "${FIXTURE}/origin.git"
  git push -q "ns/x" main:staging
  git fetch -q "ns/x"
  audit
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"remote branch ns/x/staging is reserved: 'staging' is an environment name"* ]]
  # That remote's own trunk ref is a trunk, not a branch that outlived its change.
  [[ "${output}" != *"ns/x/main is merged"* ]]
}

@test "branch-hygiene: split_remote_ref takes the longest configured remote" {
  fixture_repo >/dev/null
  cd "${FIXTURE}/work"
  git remote add "ns/x" "${FIXTURE}/origin.git"
  load_lib
  # Longest match, not first segment: `ns` is not a remote here and `ns/x` is.
  split_remote_ref "ns/x/staging"
  [ "${SPLIT_REMOTE}" = "ns/x" ]
  [ "${SPLIT_BRANCH}" = "staging" ]
  split_remote_ref "origin/dev"
  [ "${SPLIT_REMOTE}" = "origin" ]
  [ "${SPLIT_BRANCH}" = "dev" ]
  # A branch whose own name carries a slash keeps every segment after the remote.
  split_remote_ref "origin/feat/landed-one"
  [ "${SPLIT_BRANCH}" = "feat/landed-one" ]
  # Nothing matched, and the previous answer has to be gone rather than left behind
  # for a caller that reads the globals without checking the status.
  deny split_remote_ref "nosuch/branch"
  [ -z "${SPLIT_REMOTE}" ]
  [ -z "${SPLIT_BRANCH}" ]
}

@test "branch-hygiene: plan_deletion splits a slash-named remote at the remote" {
  # The wrong split prints a command that deletes a branch nobody named on a remote
  # that does not exist, while the tip SHA it records belongs to neither.
  fixture_repo >/dev/null
  cd "${FIXTURE}/work"
  git remote add "ns/x" "${FIXTURE}/origin.git"
  load_lib
  run plan_deletion remote "ns/x/merged-thing" ddb08cb7
  [[ "${output}" == *"git push ns/x --delete merged-thing"* ]]
  [[ "${output}" != *"git push ns --delete"* ]]
}

@test "branch-hygiene: a local branch that borrows a remote namespace is audited" {
  # refs/heads/origin/staging is reachable by update-ref, and %(refname:short) hands
  # back `heads/origin/staging` once a refs/remotes/origin/* ref makes it ambiguous -
  # every rule then reads the word `heads` and the branch is invisible, while the
  # deletion plan it generates names a branch git cannot find.
  fixture_repo >/dev/null
  add_branch staging
  git -C "${FIXTURE}/work" update-ref refs/heads/origin/staging \
    "$(git -C "${FIXTURE}/work" rev-parse main)"
  audit --plan
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"local branch origin/staging is reserved: 'staging' is an environment name"* ]]
  [[ "${output}" != *"heads/origin/staging"* ]]
  # The plan line has to be a command git can actually run. Under the ambiguous short
  # name it read `git branch -d heads/origin/staging`, which git answers "not found",
  # so an operator following the plan would be left holding a command that does nothing.
  [[ "${output}" == *"git branch -d origin/staging"* ]]
  git -C "${FIXTURE}/work" rev-parse --verify --quiet refs/heads/origin/staging >/dev/null
}

@test "branch-hygiene: --trunk master does not offer the real trunk for deletion" {
  # Whichever trunk the run names, a trunk-shaped name is never a cleanup candidate.
  # This used to print `git push origin --delete main`, the one command this tool must
  # never put in front of an operator.
  fixture_repo >/dev/null
  add_branch master
  merge_into_main master
  add_branch feat/landed
  merge_into_main feat/landed
  # Move master up to where main is, so master is the trunk the ancestry test runs
  # against and main is one of the refs it already contains. With --trunk master this
  # is exactly the checkout that printed `git push origin --delete main`.
  git -C "${FIXTURE}/work" branch -f master main
  audit --trunk master --plan
  [[ "${output}" != *"--delete main"* ]]
  [[ "${output}" != *"git branch -d main"* ]]
  # The positive control: the guard above is not the whole run having given up.
  [[ "${output}" == *"git branch -d feat/landed"* ]]
  [[ "${output}" == *"git push origin --delete feat/landed"* ]]
}

@test "branch-hygiene: --remote naming a remote this checkout lacks exits 2" {
  # Auditing zero refs is a green gate that looked at nothing, which this CLI has to
  # refuse rather than report as a clean tree.
  fixture_repo >/dev/null
  add_branch staging
  audit --remote typo
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"--remote typo is not a remote"* ]]
  [[ "${output}" != *"summary:"* ]]
}

@test "branch-hygiene: require_value keeps a value and refuses the shapes that are not" {
  load_lib
  require_value --repo work
  [ "${VALUE}" = "work" ]
  # Empty and flag-shaped are both "the operator did not give a value": `--max-age
  # --strict` would otherwise take --strict as the number of days.
  run --separate-stderr require_value --repo ""
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"--repo needs a value"* ]]
  [[ "${stderr}" == *"Usage: branch-hygiene.sh"* ]]
  run --separate-stderr require_value --max-age --strict
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"--max-age needs a value"* ]]
}

@test "branch-hygiene: a flag that arrives without its value is refused" {
  # `shift 2` with one argument left fails, and under set -e that ended the run on
  # exit 1 - this CLI's "the audit found something" code - printing nothing at all.
  fixture_repo >/dev/null
  local flag
  for flag in --repo --trunk --remote --max-age; do
    run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
      GITHUB_WORKSPACE= bash "${SCRIPT}" "${flag}"
    [ "${status}" -eq 2 ] || return 1
    [[ "${stderr}" == *"${flag} needs a value"* ]] || return 1
    [[ "${stderr}" == *"Usage: branch-hygiene.sh"* ]] || return 1
  done
}

@test "branch-hygiene: --max-age outside the range is refused before the audit" {
  # An unbounded value reached date as `-999999999999 days`, which GNU date refuses and
  # the BSD fallback cannot parse on Linux: the run stopped mid-audit with no summary.
  fixture_repo >/dev/null
  audit --max-age 999999999999
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"--max-age wants at most 3650 days"* ]]
}

@test "branch-hygiene: EVO_T1_REPO picks the checkout and --repo outranks it" {
  # usage advertises the env-var form, which is what a CI job sets once instead of
  # threading a path through every invocation. Advertising it and ignoring it is worse
  # than not offering it: the job believes it audited a repository.
  fixture_repo >/dev/null
  add_branch staging
  # A name only this fixture has. Without it the assertions below are satisfiable by
  # the real checkout the CLI falls back to when no --repo arrives - and this repo
  # really does have an origin/staging, so the test stayed green with the env var
  # ignored entirely.
  add_branch feat/envvar-probe
  merge_into_main feat/envvar-probe
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= EVO_T1_REPO="${FIXTURE}/work" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"origin/staging is reserved"* ]]
  [[ "${output}" == *"feat/envvar-probe"* ]]
  # A decoy in the environment must not override the path the operator typed.
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= \
    GITHUB_WORKSPACE= EVO_T1_REPO="/nonexistent-decoy-dir" bash "${SCRIPT}" \
    --repo "${FIXTURE}/work"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"origin/staging is reserved"* ]]
  [[ "${output}" == *"feat/envvar-probe"* ]]
}

@test "branch-hygiene: a fetch that cannot complete warns and stays a warning" {
  # The documented behaviour is that --fetch failure costs the run its freshness, not
  # its verdict. git's own stderr has to be silenced with it, or its error: line sits
  # above the warning: and any caller grepping ^error: reads a failure the summary
  # counted as a warning.
  fixture_repo >/dev/null
  cd "${FIXTURE}/work"
  git remote add dead "${BATS_TEST_TMPDIR}/no-such-origin.git"
  audit --fetch --remote dead
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"warning: could not fetch dead"* ]]
  [[ "${stderr}" != *"error: could not fetch"* ]]
  # Stronger, and not coupled to git's phrasing: this run's own warning reaches the
  # operator on stdout through log(), so anything of git's that leaked to stderr would
  # name the remote whether it arrived as error:, fatal:, or hint:.
  [[ "${stderr}" != *"dead"* ]]
  [[ "${output}" == *", 0 failed"* ]]
}

@test "branch-hygiene: the tables stay clear of names that read as work first" {
  # int, accept and training were in the environment table and are gone: a branch
  # called int is an integer helper and training is a model feature, and an environment
  # finding is an error that exits 1 without --strict.
  load_lib
  deny is_environment_name int
  deny is_environment_name accept
  deny is_environment_name training
  deny is_environment_name int/bounds-check
  deny is_environment_name training/rerun
  # The vocabulary the rule is actually against stays covered.
  is_environment_name uat
  is_environment_name sit
  is_environment_name sandbox
  is_environment_name integration
}
