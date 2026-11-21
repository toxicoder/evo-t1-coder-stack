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

# Where the operator stood when they typed the command, which is what a relative
# --repo is anchored to. Under `bazelisk run` the launcher starts with its cwd inside
# the runfiles tree, so $PWD alone would resolve `.` to a tree with no checkout in it.
INVOKE_DIR="${BUILD_WORKSPACE_DIRECTORY:-${PWD}}"

require_tool git

# @function main
# Resolve the checkout and run every audit over it.
# Globals:
#   REPO_ARG, TRUNK, SELF_DIR, INVOKE_DIR, EVO_T1_REPO, REMOTES
# Arguments:
#   None (argv is parsed by the caller)
# Outputs:
#   The section report and the closing summary
# Returns:
#   0 clean, 1 findings, 2 the audit could not run
main() {
  local root base
  # usage advertises $EVO_T1_REPO as the flag-free form, which is what a CI job sets
  # once instead of threading the path through every invocation. --repo still wins,
  # so the advertised promise and the explicit flag cannot disagree.
  REPO_ARG="${REPO_ARG:-${EVO_T1_REPO:-}}"
  if [ -n "${REPO_ARG}" ]; then
    root="$(resolve_repo_arg "${REPO_ARG}")" || {
      if [[ ${REPO_ARG} == /* ]]; then
        base=""
      else
        base="${INVOKE_DIR}/"
      fi
      err "cannot enter --repo ${REPO_ARG} (resolved to ${base}${REPO_ARG})"
      exit 2
    }
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

  # A --remote that names nothing audits zero refs and leaves the run to report a
  # clean tree: the one outcome worse than a false alarm is a green gate that looked
  # at nothing. Refuse it here, before the fetch, so the typo is named once and early.
  local wanted
  for wanted in ${REMOTES[@]+"${REMOTES[@]}"}; do
    [ -n "${wanted}" ] || continue
    git remote get-url "${wanted}" >/dev/null 2>&1 || {
      err "--remote ${wanted} is not a remote of ${root} (this checkout has: $(git remote | tr '\n' ' '))"
      exit 2
    }
  done

  if [ "${DO_FETCH}" -eq 1 ]; then
    section "Remotes"
    local remote
    for remote in $(selected_remotes); do
      phase "fetch ${remote}"
      # A fetch that will not complete is a warning, not a failure: the run still
      # reports what this clone last saw. git's own stderr has to go quiet with it,
      # or its `error: ...` line sits above the `warning:` and anything grepping for
      # ^error: calls this run a failure it counted as a warning.
      git remote update --prune "${remote}" >/dev/null 2>&1 ||
        warn "could not fetch ${remote}; its remote branches may be stale"
    done
  fi

  local current=""
  current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  section "Environment-named branches"
  # Both row lists are read once and reused by all three audits. A ref pointing at a
  # missing object makes git for-each-ref die with a bare `fatal:` and exit 128, so
  # the failure is caught and reported as this CLI's own verdict: 2, could not run.
  local local_rows remote_rows
  if ! local_rows="$(list_local 2>&1)"; then
    err "cannot read local branches: $(head -n 1 <<<"${local_rows}")"
    exit 2
  fi
  if ! remote_rows="$(list_remote 2>&1)"; then
    err "cannot read remote branches: $(head -n 1 <<<"${remote_rows}")"
    exit 2
  fi
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
