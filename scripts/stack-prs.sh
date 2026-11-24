#!/usr/bin/env bash
#
# ## stack-prs.sh - drive the GitHub stacked-PR verbs for one repository
#
# The ingress for the stacked-PR rules in scripts/lib/stack_prs.sh: it names the
# repository, reads the flags, and runs one verb. Everything that decides what a
# stack *is* - the endpoints, the merge-async pair, the draft rule, the exit-9
# mapping - lives in the lib, where a Bats suite can reach each function alone.
#
# A stack is a chain of pull requests where each layer's base is the branch under it,
# and a chain is only worth having if the tool keeps it consistent: `create-stack`
# takes the layers bottom-first, `retarget` repairs a base that drifted off its parent,
# and `merge` lands bottom-up through the asynchronous merge endpoint only. The
# synchronous PUT /pulls/{n}/merge is refused by the lib rather than merely unused.
#
# Every GitHub call goes through `env -u GH_TOKEN -u GITHUB_TOKEN gh api`: the pair
# Coder injects at workspace start expires about an hour later and gh prefers it over
# the gh auth store the refresh job keeps live, so an un-unset pair fails every call
# with an error that names neither the token nor its age. The rules of the stack
# itself, including why a merge goes through merge-async and nothing else, are the
# "Stacked pull requests" section of docs/branching.md.
#
# Usage:
#   bazelisk run //scripts:stack-prs -- view --slug o/r
#   bazelisk run //scripts:stack-prs -- create-stack --prs 12,13,14 --open
#   bazelisk run //scripts:stack-prs -- add --stack 7 --pr 15 --open
#   bazelisk run //scripts:stack-prs -- retarget --stack 7
#   bazelisk run //scripts:stack-prs -- merge --stack 7 --dry-run
#   bazelisk run //scripts:stack-prs -- unstack --stack 7
#
# Exit codes: 0 the verb ran, 1 a call failed, 2 bad arguments or the repository could
# not be named, 3 stacks are not enabled for the repository (a human owes a setting).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

# shellcheck source=lib/stack_prs.sh disable=SC1091
source "${SELF_DIR}/lib/stack_prs.sh"

# Where the operator stood when they typed the command, which is what a relative
# --repo is anchored to. Under `bazelisk run` the launcher starts with its cwd inside
# the runfiles tree, so $PWD alone would resolve `.` to a tree with no checkout in it.
# shellcheck disable=SC2034 # written here, read by resolve_repo_dir in the lib below
INVOKE_DIR="${BUILD_WORKSPACE_DIRECTORY:-${PWD}}"

require_tool git
require_tool gh

# @function main
# Name the repository, run the verb, and close with the summary.
# Globals:
#   VERB, REPO_ARG, REPO_SLUG, STACKS_DISABLED, SELF_DIR, INVOKE_DIR, EVO_T1_REPO
# Arguments:
#   None (argv is parsed by the caller)
# Outputs:
#   The section report and the closing summary line
# Returns:
#   0 the verb ran, 1 a call failed, 2 the run could not start, 3 stacks are off
main() {
  section "Stacked PRs"
  if [ "${DRY_RUN}" -eq 1 ]; then
    note "dry run: no write is sent; every ok: below is what that call would report"
  fi

  phase "resolve the repository"
  if ! resolve_repo_slug; then
    exit 2
  fi
  ok "repository ${REPO_SLUG}"

  section "${VERB}"
  local rc=0
  run_verb || rc=$?
  if [ "${rc}" -eq 2 ]; then
    exit 2
  fi

  summary "${VERB} on ${REPO_SLUG}"
  # Exit 9 from the CLI is stacks-not-enabled: nothing an operator runs can fix it, so
  # it gets its own code rather than being counted as a failed call.
  [ "${STACKS_DISABLED}" -eq 1 ] && exit 3
  [ "${rc}" -eq 0 ] || exit 1
  [ "${SUMMARY_FAIL:-0}" -eq 0 ] || exit 1
}

parse_args "$@"
main
