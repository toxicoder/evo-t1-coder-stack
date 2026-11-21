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
  [[ "${stderr}" == *"remote branch origin/staging is an environment name"* ]]
  # The tip SHA has to be on the line: it is the record the working rules want kept
  # before anyone deletes the branch.
  [[ "${stderr}" == *"origin/staging is an environment name (tip "* ]]
  # The branch exists on both sides of the remote boundary, and each is its own
  # finding: deleting origin/staging does not remove the local one.
  [ "$(occurrences 'is an environment name')" -eq 2 ]
  [[ "${output}" == *"summary: "*"2 failed"* ]]
}

@test "branch-hygiene: a local environment branch is an error too" {
  fixture_repo >/dev/null
  add_branch production
  audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"local branch production is an environment name"* ]]
  [[ "${output}" == *"remote branch origin/production is an environment name"* ]]
}

@test "branch-hygiene: an environment word below a namespace is still an environment branch" {
  fixture_repo >/dev/null
  add_branch prod/hotfix-42
  audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"origin/prod/hotfix-42 is an environment name"* ]]
}

@test "branch-hygiene: a sanctioned work prefix stays clean" {
  fixture_repo >/dev/null
  add_branch test/flake-fix
  add_branch feat/search-lane
  audit
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"local branch test/flake-fix is not an environment name"* ]]
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
  git -C "${FIXTURE}/work" switch -q feat/landed
  audit
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
  [[ "${stderr}" == *"remote branch backup/staging is an environment name"* ]]
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
  [[ "${output}" == *"remote branch backup/main is not an environment name"* ]]
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
