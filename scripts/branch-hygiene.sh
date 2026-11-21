#!/usr/bin/env bash
#
# ## branch-hygiene.sh - audit branch topology against docs/branching.md
#
# The machine check for the three sentences docs/branching.md states as fact: `main`
# is the only long-lived branch, `development` / `staging` / `production` are
# environments and never branches, and a work branch is deleted the moment it merges.
# The rules themselves live in scripts/lib/branch_hygiene.sh, where a Bats suite can
# reach each predicate; this file is the ingress that resolves a checkout and runs
# them over it.
#
# It reports and never mutates, and it prints each candidate's tip SHA, because a
# deletion is the operator's call and the working rules ask for that record to exist
# first. Offline by default: local refs answer the whole question, so a run costs no
# network. --fetch re-reads the remotes first, which is the answer to trust before
# acting on a deletion list.
#
# Usage:
#   bazelisk run //scripts:branch-hygiene
#   bazelisk run //scripts:branch-hygiene -- --repo DIR [--remote NAME]...
#   bazelisk run //scripts:branch-hygiene -- --strict --max-age 7 --fetch
#   bazelisk run //scripts:branch-hygiene -- --plan        # deletions, for a human
#
# Exit codes: 0 clean, 1 findings, 2 the audit could not run (no git, no checkout).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

# shellcheck source=lib/branch_hygiene.sh disable=SC1091
source "${SELF_DIR}/lib/branch_hygiene.sh"

require_tool git

# @function main
# Resolve the checkout and run every audit over it.
# Globals:
#   REPO_ARG, TRUNK, SELF_DIR
# Arguments:
#   None (argv is parsed by the caller)
# Outputs:
#   The section report and the closing summary
# Returns:
#   0 clean, 1 findings, 2 the audit could not run
main() {
  local root
  if [ -n "${REPO_ARG}" ]; then
    root="${REPO_ARG}"
  else
    root="$(resolve_checkout "${SELF_DIR}")" || {
      err "no checkout: pass --repo DIR or run this inside the clone"
      exit 2
    }
  fi
  cd "${root}" || {
    err "cannot enter ${root}"
    exit 2
  }
  git rev-parse --git-dir >/dev/null 2>&1 || {
    err "${root} is not a git repository"
    exit 2
  }

  local trunk_ref="${TRUNK}"
  git rev-parse --verify --quiet "${TRUNK}^{commit}" >/dev/null || {
    if git rev-parse --verify --quiet "origin/${TRUNK}^{commit}" >/dev/null; then
      trunk_ref="origin/${TRUNK}"
    else
      err "no trunk branch ${TRUNK} (or origin/${TRUNK}) in ${root}"
      exit 2
    fi
  }

  if [ "${DO_FETCH}" -eq 1 ]; then
    section "Remotes"
    local remote
    for remote in $(git remote); do
      phase "fetch ${remote}"
      git remote update --prune "${remote}" >/dev/null ||
        warn "could not fetch ${remote}; its remote branches may be stale"
    done
  fi

  local current=""
  current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  section "Environment-named branches"
  local local_rows remote_rows
  local_rows="$(list_local)"
  remote_rows="$(list_remote)"
  audit_environment local "${local_rows}"
  audit_environment remote "${remote_rows}"

  section "Branches that outlived their change"
  audit_merged local "${trunk_ref}" "${local_rows}" "${current}" ""
  audit_merged remote "${trunk_ref}" "${remote_rows}" "" "refs/remotes/"

  section "Branch lifetime"
  audit_stale local "${trunk_ref}" "${local_rows}" ""
  audit_stale remote "${trunk_ref}" "${remote_rows}" "refs/remotes/"

  summary "delete each named branch after recording its tip SHA; --plan prints the commands"
  [ "${SUMMARY_FAIL:-0}" -eq 0 ] || exit 1
}

parse_args "$@"
main
