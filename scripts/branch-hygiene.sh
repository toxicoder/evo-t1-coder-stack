#!/usr/bin/env bash
#
# ## branch-hygiene.sh - audit branch topology against docs/branching.md
#
# docs/branching.md states three things as fact and nothing in the gate checks any
# of them: `main` is the only long-lived branch, `development` / `staging` /
# `production` are environments and never branches, and a work branch is deleted
# the moment it merges. All three are conventions a person or an agent can drift
# from silently, and drift is cheap to accumulate: a branch nobody rebases any more
# costs nothing to keep, so it stays, and the next person reads `origin/dev` as
# something to merge into. This CLI turns each sentence into a counted finding.
#
# It reports and never mutates. Deleting a branch is the operator's call - the
# working rules in AGENTS.md require a confirmation and a recorded tip SHA for each
# one - so the deletion commands this prints are for a human to run, and --plan
# prints them without running anything. Tip SHAs are printed for every candidate
# so that record exists before the deletion, which is what makes an accidental one
# recoverable through the reflog.
#
# Findings come in two weights. An environment-named branch is an error: the rule
# forbids the shape outright, and one that exists has already been merged from or
# deployed to by someone who read it as an environment. A merged-but-undeleted or
# stale branch is a warning: the branch may be deliberate, so --strict is what
# promotes warnings to failures for a gate that has to be exact.
#
# Offline by default. Local refs are what a checkout carries, and `git for-each-ref`
# answers the whole question from them, so a run costs no network and works behind a
# bot wall. A stale local view of the remote then reads as a branch that no longer
# exists; --fetch re-reads the remotes first and prunes what they deleted, which is
# the answer to trust before acting on a deletion list.
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

require_tool git

# Environment words the rule forbids as branch names. Compared against the bare
# branch name and against its first path segment, so a bare `staging` and a
# `prod/hotfix-42` are both findings: a branch that carries an environment in its
# name is read as an environment by whoever meets it next, which is the harm the
# rule is against. The sanctioned work prefixes (feat/, fix/, docs/, test/, ...)
# are absent by design, so `test/2026-11-flakes` stays clean. `master` is here as
# the legacy trunk shape: a `master` beside `main` is a second trunk, and only one
# branch is allowed to be long-lived.
readonly -A ENVIRONMENT_WORDS=(
  [dev]=1 [develop]=1 [development]=1 [dev - 1]=1
  [stage]=1 [staging]=1 [preprod]=1 [pre - production]=1 [pre]=1
  [prod]=1 [production]=1 [live]=1 [master]=1
  [uat]=1 [sit]=1 [qa]=1 [int]=1 [integration]=1 [accept]=1 [training]=1
  [sandbox]=1
)

# Branches that are long-lived by design and so never cleanup candidates.
# `gh-pages` is what //docs-site publishes through deploy-docs.yml and is an
# orphan history, not a branch that merges; --trunk names the trunk itself.
readonly -a ALWAYS_KEEP=(gh-pages)

REPO_ARG=""
TRUNK="main"
MAX_AGE_DAYS=14
STRICT=0
PLAN=0
DO_FETCH=0
declare -a REMOTES=()

# @function usage
# Print the invocation summary and the flag list.
# Globals:
#   none
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'EOF'
Usage: branch-hygiene.sh [--repo DIR] [--trunk NAME] [--remote NAME]...
                         [--max-age DAYS] [--fetch] [--strict] [--plan]

  --repo DIR      audit this checkout instead of resolving one (also $EVO_T1_REPO)
  --trunk NAME    the trunk branch; default main
  --remote NAME    limit the remote scan to this remote; repeatable, default all
  --max-age DAYS  an unmerged branch older than this is stale; default 14
  --fetch         git remote update --prune each remote first (needs network)
  --strict        promote every warning to a failure
  --plan          print the deletion commands instead of only naming the branches
EOF
}

# @function parse_args
# Fill the run's options from argv, refusing anything unrecognized.
# Globals:
#   REPO_ARG, TRUNK, MAX_AGE_DAYS, STRICT, PLAN, DO_FETCH, REMOTES
# Arguments:
#   $@ - the CLI arguments
# Outputs:
#   One "error: ..." line on stderr for a bad argument
# Returns:
#   0 on success; 2 on a bad argument (handled by the caller's exit)
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        REPO_ARG="${2:-}"
        shift 2
        ;;
      --repo=*)
        REPO_ARG="${1#*=}"
        shift
        ;;
      --trunk)
        TRUNK="${2:-}"
        shift 2
        ;;
      --trunk=*)
        TRUNK="${1#*=}"
        shift
        ;;
      --remote)
        REMOTES+=("${2:-}")
        shift 2
        ;;
      --remote=*)
        REMOTES+=("${1#*=}")
        shift
        ;;
      --max-age)
        MAX_AGE_DAYS="${2:-}"
        shift 2
        ;;
      --max-age=*)
        MAX_AGE_DAYS="${1#*=}"
        shift
        ;;
      --fetch)
        DO_FETCH=1
        shift
        ;;
      --strict)
        STRICT=1
        shift
        ;;
      --plan)
        PLAN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done
  [[ ${MAX_AGE_DAYS} =~ ^[0-9]+$ ]] ||
    {
      err "--max-age wants a whole number of days, got: ${MAX_AGE_DAYS}"
      exit 2
    }
  [ -n "${TRUNK}" ] || {
    err "--trunk needs a branch name"
    exit 2
  }
}

# @function is_environment_name
# Decide whether a branch name carries an environment word.
# Globals:
#   ENVIRONMENT_WORDS
# Arguments:
#   $1 - the branch's short name, without any remote/ directory prefix
# Outputs:
#   None
# Returns:
#   0 when the name is an environment shape, 1 otherwise
is_environment_name() {
  local name="${1#refs/heads/}"
  name="${name#refs/remotes/}"
  local head_segment="${name%%/*}"
  if [ "${name}" = "${head_segment}" ]; then
    [ -n "${ENVIRONMENT_WORDS[${name}]:-}" ] && return 0
    return 1
  fi
  [ -n "${ENVIRONMENT_WORDS[${head_segment}]:-}" ] && return 0
  return 1
}

# @function is_always_kept
# Decide whether a branch is long-lived by design.
# The comparison is against the branch part, so the exemption holds for whatever
# the remote happens to be called: hardcoding origin/ would leave a second remote's
# own trunk ref to be reported as a merged branch that outlived its change.
# Globals:
#   ALWAYS_KEEP, TRUNK
# Arguments:
#   $1 - "local" or "remote"; $2 - the row's name
# Outputs:
#   None
# Returns:
#   0 when the branch is exempt from cleanup, 1 otherwise
is_always_kept() {
  local kind="$1" name="$2" keep rule
  rule="$(branch_part "${kind}" "${name}")"
  [ "${rule}" = "${TRUNK}" ] && return 0
  for keep in "${ALWAYS_KEEP[@]}"; do
    [ "${rule}" = "${keep}" ] && return 0
  done
  return 1
}

# @function report_or_warn
# Count one finding at the weight its rule deserves.
# Globals:
#   STRICT (via fail_item and warn)
# Arguments:
#   $1 - "error" or "warn"; $2 - the finding text
# Outputs:
#   "error: ..." on stderr, or "warning: ..." on stdout
# Returns:
#   0
report_or_warn() {
  if [ "$1" = "error" ]; then
    fail_item "$2"
  elif [ "${STRICT}" -eq 1 ]; then
    fail_item "$2"
  else
    warn "$2"
  fi
}

# @function list_local
# Print one TAB-separated row per local branch: name, tip SHA, commit date.
# Globals:
#   none
# Arguments:
#   None
# Outputs:
#   "name<TAB>sha<TAB>YYYY-MM-DD" per refs/heads entry, oldest first
# Returns:
#   0
list_local() {
  git for-each-ref --format='%(refname:short)%09%(objectname:short)%09%(committerdate:short)' \
    --sort=committerdate refs/heads/
}

# @function list_remote
# Print one TAB-separated row per remote-tracking branch: name, tip SHA, date.
# The remote HEAD symbolic ref is dropped, because it is a pointer and not a
# branch, and a row for it would be counted as a duplicate of its target.
# Globals:
#   REMOTES
# Arguments:
#   None
# Outputs:
#   "remote/name<TAB>sha<TAB>YYYY-MM-DD" per refs/remotes entry, oldest first
# Returns:
#   0
list_remote() {
  local -a refs=()
  local remote
  if [ "${#REMOTES[@]}" -gt 0 ]; then
    for remote in "${REMOTES[@]}"; do
      [ -n "${remote}" ] && refs+=("refs/remotes/${remote}/")
    done
  else
    refs=("refs/remotes/")
  fi
  git for-each-ref --format='%(refname:lstrip=2)%09%(objectname:short)%09%(committerdate:short)' \
    --sort=committerdate "${refs[@]}" |
    awk -F '\t' '$1 !~ /\/HEAD$/ { print }'
}

# @function branch_part
# Print the branch name as the rules read it, with the remote directory stripped.
# A remote-tracking row arrives as origin/dev, and matching the rules against that
# string would test the word `origin` and find nothing: the remote is a namespace,
# not part of the branch name. Only a leading segment that is a configured remote
# is removed, so a branch whose own name carries a slash keeps all of it.
# Globals:
#   none
# Arguments:
#   $1 - "local" or "remote"; $2 - the row's name
# Outputs:
#   The name to match rules against, on stdout
# Returns:
#   0
branch_part() {
  local kind="$1" name="$2" remote head
  if [ "${kind}" = "remote" ]; then
    head="${name%%/*}"
    for remote in $(git remote); do
      if [ "${head}" = "${remote}" ]; then
        printf '%s' "${name#*/}"
        return 0
      fi
    done
  fi
  printf '%s' "${name}"
}

# @function audit_environment
# Fail on any branch, local or remote, that carries an environment word.
# Globals:
#   none
# Arguments:
#   $1 - the label to print with a finding ("local" or "remote")
#   $2 - the branch rows, one per line
# Outputs:
#   One counted finding per offending branch, plus ok: lines when none offend
# Returns:
#   0; findings are recorded, not returned
audit_environment() {
  local kind="$1" rows="$2" name sha date rule_name
  while IFS=$'\t' read -r name sha date; do
    [ -n "${name}" ] || continue
    rule_name="$(branch_part "${kind}" "${name}")"
    if is_environment_name "${rule_name}"; then
      report_or_warn error \
        "$(printf '%s branch %s is an environment name (tip %s); docs/branching.md makes environments GitHub Environments, never branches' "${kind}" "${name}" "${sha}")"
    else
      ok "${kind} branch ${name} is not an environment name"
    fi
  done <<<"${rows}"
}

# @function audit_merged
# Warn on a branch whose tip the trunk already contains: the rule is to delete it
# the moment it merges, so one that survives is a finding with a recorded tip SHA.
# Globals:
#   TRUNK, PLAN
# Arguments:
#   $1 - the label to print with a finding ("local" or "remote")
#   $2 - the trunk ref to test ancestry against
#   $3 - the branch rows
#   $4 - the branch currently checked out, or empty (exempt: it is the working branch)
#   $5 - the ref prefix that turns a row's name into a resolvable ref: empty for
#        refs/heads rows (whose %(refname:short) already is the ref, slashes and
#        all) and refs/remotes/ for remote rows. A name is never split on its
#        first slash here: chore/foo is one branch name, and stripping to foo
#        would resolve it against the wrong namespace.
# Outputs:
#   One counted warning per merged branch, plus the deletion line under --plan
# Returns:
#   0
audit_merged() {
  local kind="$1" trunk_ref="$2" rows="$3" current="${4:-}" ref_prefix="${5:-}"
  local name sha date
  while IFS=$'\t' read -r name sha date; do
    [ -n "${name}" ] || continue
    is_always_kept "${kind}" "${name}" && continue
    [ "${name}" = "${current}" ] && continue
    if git merge-base --is-ancestor "${ref_prefix}${name}" "${trunk_ref}" 2>/dev/null; then
      report_or_warn warn \
        "$(printf '%s branch %s is merged into %s and still present (tip %s, %s); the rule is to delete it on merge' "${kind}" "${name}" "${trunk_ref}" "${sha}" "${date}")"
      [ "${PLAN}" -eq 1 ] && plan_deletion "${kind}" "${name}" "${sha}"
    else
      ok "${kind} branch ${name} carries work ${trunk_ref} does not have"
    fi
  done <<<"${rows}"
}

# @function audit_stale
# Warn on an unmerged branch whose last commit is older than the branch lifetime.
# A branch this old is not a change in progress, and the longer it sits the less
# anyone can say whether it is still wanted, which is when it stops being cheap.
# A branch the trunk already contains is skipped: audit_merged names it once, under
# the rule that actually applies, and repeating it here as "unmerged" would state
# something the ancestry test just proved false.
# Globals:
#   MAX_AGE_DAYS, TRUNK
# Arguments:
#   $1 - the label to print ("local" or "remote")
#   $2 - the trunk ref the ancestry test needs
#   $3 - the branch rows
#   $4 - the ref prefix that turns a row's name into a resolvable ref, as in
#        audit_merged
# Outputs:
#   One counted warning per stale branch
# Returns:
#   0
audit_stale() {
  local kind="$1" trunk_ref="$2" rows="$3" ref_prefix="${4:-}"
  local cutoff name sha date
  cutoff="$(date -d "-${MAX_AGE_DAYS} days" +%Y-%m-%d 2>/dev/null ||
    date -v-"${MAX_AGE_DAYS}"d +%Y-%m-%d)"
  while IFS=$'\t' read -r name sha date; do
    [ -n "${name}" ] || continue
    is_always_kept "${kind}" "${name}" && continue
    [ -n "${date}" ] || continue
    git merge-base --is-ancestor "${ref_prefix}${name}" "${trunk_ref}" 2>/dev/null && continue
    if [[ ${date} < ${cutoff} ]]; then
      report_or_warn warn \
        "$(printf '%s branch %s is unmerged and its last commit is %s, older than the %s-day branch lifetime (tip %s)' "${kind}" "${name}" "${date}" "${MAX_AGE_DAYS}" "${sha}")"
    fi
  done <<<"${rows}"
}

# @function plan_deletion
# Print the commands that would remove one branch, for an operator to run.
# This function never runs them: a deletion needs the operator's confirmation, and
# AGENTS.md requires the tip SHA to be recorded first, which is what this prints.
# Globals:
#   none
# Arguments:
#   $1 - "local" or "remote"; $2 - branch name; $3 - tip SHA to record
# Outputs:
#   One "-> delete ..." phase line and the git command it stands for
# Returns:
#   0
plan_deletion() {
  local kind="$1" name="$2" sha="$3"
  if [ "${kind}" = "remote" ]; then
    phase "delete ${name} (record tip ${sha} first)"
    log "    git push origin --delete ${name#*/}"
  else
    phase "delete ${name} (record tip ${sha} first)"
    log "    git branch -d ${name}"
  fi
}

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
