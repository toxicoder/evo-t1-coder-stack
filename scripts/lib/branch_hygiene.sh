# shellcheck shell=bash
#
# ## branch_hygiene.sh - the branch-topology rules of docs/branching.md (sourced; never executed)
#
# docs/branching.md states three things as fact and nothing in the tree checked any of
# them: `main` is the only long-lived branch, `development` / `staging` / `production`
# are environments and never branches, and a work branch is deleted the moment it
# merges. All three are conventions a person or an agent can drift from silently, and
# drift is cheap to accumulate: a branch nobody rebases any more costs nothing to keep,
# so it stays, and the next person reads `origin/dev` as something to merge into. The
# predicates and audits here turn each of those sentences into a counted finding, and
# scripts/branch-hygiene.sh is the CLI that runs them over a checkout.
#
# The verdicts come in two weights. An environment-named branch is an error: the rule
# forbids the shape outright, and one that exists has already been merged from or
# deployed to by someone who read it as an environment. A merged-but-undeleted or stale
# branch is a warning: the branch may be deliberate, so --strict is what promotes
# warnings to failures for a gate that has to be exact.
#
# Nothing here mutates a repository. Deleting a branch is the operator's call - the
# working rules require a confirmation and a recorded tip SHA for each one - so
# plan_deletion prints the command and its tip SHA and runs nothing. The one write
# the CLI can make is --fetch, which runs `git remote update --prune`: it refreshes
# and prunes this checkout's own remote-tracking refs and touches no branch on the
# remote. Without it a run reports what this clone last saw, which is the honest
# default for a check an agent may be running unattended.
#
# Usage (from an entry script, after `set -euo pipefail` and the common.sh source):
#   # shellcheck source=lib/branch_hygiene.sh disable=SC1091
#   source "scripts/lib/branch_hygiene.sh"
# Environment words the rule forbids as branch names. Compared against the bare
# branch name and against its first path segment, so a bare `staging` and a
# `prod/hotfix-42` are both findings: a branch that carries an environment in its
# name is read as an environment by whoever meets it next, which is the harm the
# rule is against. The sanctioned work prefixes (feat/, fix/, docs/, test/, ...)
# are absent by design, so `test/2026-11-flakes` stays clean.
#
# Every key here has to be a name git will actually accept, because an entry git
# cannot name is a rule that never fires: the table once carried `dev - 1` and
# `pre - production`, and no branch could ever have matched them. Words are written
# exactly as they would appear in `git for-each-ref` output. `pre` on its own is
# deliberately absent - as a first path segment it would sweep in any branch someone
# started with `pre/`, which is a prefix, not an environment.
#
# -g is load-bearing, not decoration: a sourced file's `declare` is scoped to whatever
# function sourced it, so a plain `declare -A` made these tables disappear the moment
# the test helper loaded the lib from inside load_lib, and every lookup came back
# empty. A lib's tables are meant to be global in every case.
declare -gA ENVIRONMENT_WORDS
ENVIRONMENT_WORDS=(
  [dev]=1 [develop]=1 [development]=1
  [stage]=1 [staging]=1 [preprod]=1
  [prod]=1 [production]=1 [live]=1
  [uat]=1 [sit]=1 [qa]=1 [int]=1 [integration]=1 [accept]=1 [training]=1
  [sandbox]=1
)
# The two-word form is written with a separator git itself accepts. A branch name
# cannot hold a space, so an entry spelled with spaces is a rule that can never
# fire; this table once carried exactly that and silently covered nothing.
ENVIRONMENT_WORDS["pre-production"]=1

# Names reserved for a trunk rather than for an environment. A `master` beside
# `main` breaks a different sentence in docs/branching.md - only one branch is
# allowed to be long-lived - so it is kept out of the environment table and reported
# with its own words instead of being called an environment nobody promoted to a
# GitHub Environment.
declare -gA TRUNK_NAMES
TRUNK_NAMES=([master]=1)

# Branches that are long-lived by design and so never cleanup candidates.
# `gh-pages` is what //docs-site publishes through deploy-docs.yml and is an
# orphan history, not a branch that merges; --trunk names the trunk itself.
# Plain assignment, not readonly: this file is sourced, and a second source has to
# be a no-op rather than a "readonly variable" error.
ALWAYS_KEEP=(gh-pages)

REPO_ARG=""
TRUNK="main"
MAX_AGE_DAYS=14
STRICT=0
PLAN=0
DO_FETCH=0
declare -ga REMOTES=()

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
  --fetch         git remote update --prune over the selected remotes first
                  (needs network, and prunes stale remote-tracking refs locally)
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
# shellcheck disable=SC2034 # REPO_ARG and DO_FETCH are written here and read by main()
# in scripts/branch-hygiene.sh, which is the only consumer of this lib; shellcheck
# analyzes the lib alone and cannot see the reader.
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

# @function resolve_repo_arg
# Print --repo as a directory this process can actually enter.
# Under `bazelisk run` the launcher starts with its cwd inside the runfiles tree, so
# a relative --repo has to be anchored where the operator stood rather than against
# $PWD at the point of use; BUILD_WORKSPACE_DIRECTORY is what Bazel leaves behind for
# exactly that, and a plain shell run has neither and means its own cwd. The cd runs
# in the command substitution's subshell, so resolving never moves the caller.
# Globals:
#   INVOKE_DIR - the anchoring directory; defaults to the Bazel workspace or the cwd
# Arguments:
#   $1 - the --repo value as the operator typed it
# Outputs:
#   The absolute path on stdout, or nothing when the path does not resolve
# Returns:
#   0 with the path on stdout, 1 when it cannot be entered
resolve_repo_arg() {
  local given="$1" candidate
  local base="${INVOKE_DIR:-${BUILD_WORKSPACE_DIRECTORY:-${PWD}}}"
  if [[ ${given} == /* ]]; then
    candidate="${given}"
  else
    candidate="${base}/${given}"
  fi
  cd "${candidate}" 2>/dev/null || return 1
  pwd
}

# @function reserved_name_kind
# Classify a branch name against the two reserved tables and record what matched.
#
# A bare name is compared whole and a path is compared on its first segment, which is
# what separates the two shapes the rule is about: prod/hotfix-42 is the prod shape,
# while test/flake-fix is a sanctioned prefix and stays clean. A trunk word is matched
# on the bare name only, so a branch someone filed under master/ is not called a
# second trunk.
# Globals:
#   ENVIRONMENT_WORDS, TRUNK_NAMES, RESERVED_KIND, RESERVED_WORD
# Arguments:
#   $1 - the branch name as the rules read it, without the remote namespace
# Outputs:
#   Sets RESERVED_KIND to "environment" or "trunk" and RESERVED_WORD to the matched
#   word; clears both when nothing matched
# Returns:
#   0 when the name is reserved, 1 otherwise
reserved_name_kind() {
  local name="${1#refs/heads/}"
  name="${name#refs/remotes/}"
  local head_segment="${name%%/*}"
  local word
  RESERVED_KIND=""
  RESERVED_WORD=""
  if [ "${name}" = "${head_segment}" ]; then
    word="${name}"
  else
    word="${head_segment}"
  fi
  if [ -n "${ENVIRONMENT_WORDS[${word}]:-}" ]; then
    RESERVED_KIND="environment"
    RESERVED_WORD="${word}"
    return 0
  fi
  if [ "${name}" = "${head_segment}" ] && [ -n "${TRUNK_NAMES[${word}]:-}" ]; then
    RESERVED_KIND="trunk"
    RESERVED_WORD="${word}"
    return 0
  fi
  return 1
}

# @function is_environment_name
# Decide whether a branch name carries an environment word.
# Globals:
#   RESERVED_KIND (via reserved_name_kind)
# Arguments:
#   $1 - the branch name as the rules read it, without the remote namespace
# Outputs:
#   None
# Returns:
#   0 when the name is an environment shape, 1 otherwise (including the trunk shape,
#   which is a different rule and gets its own sentence)
is_environment_name() {
  reserved_name_kind "${1}" && [ "${RESERVED_KIND}" = "environment" ]
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

# @function selected_remotes
# Print one remote per line: the ones --remote named, or every configured remote
# when the operator named none. The fetch loop and the remote scan have to agree on
# this, or --remote upstream --fetch spends its network on origin and still reports
# origin's refs as possibly stale.
# Globals:
#   REMOTES
# Arguments:
#   None
# Outputs:
#   Remote names, one per line, empty entries dropped
# Returns:
#   0
selected_remotes() {
  local remote
  if [ "${#REMOTES[@]}" -gt 0 ]; then
    for remote in "${REMOTES[@]}"; do
      [ -n "${remote}" ] && printf '%s\n' "${remote}"
    done
  else
    git remote
  fi
  return 0
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
    # Outside a checkout there are no remotes to match, which is an answer rather
    # than an error; the CLI refuses a non-repo before any audit runs.
    for remote in $(git remote 2>/dev/null || true); do
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
  local kind="$1" rows="$2" name sha date rule_name reason
  while IFS=$'\t' read -r name sha date; do
    [ -n "${name}" ] || continue
    rule_name="$(branch_part "${kind}" "${name}")"
    if reserved_name_kind "${rule_name}"; then
      if [ "${RESERVED_KIND}" = "environment" ]; then
        reason="$(printf "'%s' is an environment name; docs/branching.md makes environments GitHub Environments, never branches" "${RESERVED_WORD}")"
      else
        reason="$(printf "'%s' is a second trunk name; docs/branching.md makes %s the only long-lived branch" "${RESERVED_WORD}" "${TRUNK}")"
      fi
      report_or_warn error \
        "$(printf '%s branch %s is reserved: %s (tip %s)' "${kind}" "${name}" "${reason}" "${sha}")"
    else
      ok "${kind} branch ${name} is not a reserved name"
    fi
  done <<<"${rows}"
  return 0
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
      if [ "${PLAN}" -eq 1 ]; then
        plan_deletion "${kind}" "${name}" "${sha}"
      fi
    else
      ok "${kind} branch ${name} carries work ${trunk_ref} does not have"
    fi
  done <<<"${rows}"
  # The function's verdict is "I reported what I found", not the status of the last
  # row: with --plan off, the last command of a merged row's body is a false test,
  # and that would reach the caller as a failure and stop the CLI under set -e.
  return 0
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
  return 0
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
    # The remote is taken from the row, never from a literal origin: a checkout with
    # a second remote would otherwise be told to delete a same-named branch on the
    # wrong one, and the tip SHA it recorded would belong to the ref it did not mean.
    phase "delete ${name} (record tip ${sha} first)"
    log "    git push ${name%%/*} --delete ${name#*/}"
  else
    phase "delete ${name} (record tip ${sha} first)"
    log "    git branch -d ${name}"
  fi
}
