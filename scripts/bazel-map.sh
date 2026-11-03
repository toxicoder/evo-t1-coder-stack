#!/usr/bin/env bash
#
# ## bazel-map.sh - answer "what depends on this?" from the target graph
#
# Every structural question about this repo already has a recorded answer: the maps in
# scripts/BUILD.bazel name the libs and payloads each CLI reads, the map in
# tests/BUILD.bazel names the payloads each Bats suite opens, and the root BUILD.bazel
# aggregates every payload filegroup into //:stack_data. That record is machine-readable
# on purpose, and //tests:bats_bazel_deps_test fails when it drifts from the sources, so
# a question like "which suites cover this script" has a ground truth sitting in the
# graph. Answering it by grepping, or by reading BUILD files and the checker's own
# source, re-derives what Bazel can print in one query.
#
# This CLI is the thin shell over that graph. It reads nothing and writes nothing: each
# verb is one `bazelisk query`, run from the real checkout, with its stderr kept so a
# miss is reported rather than swallowed. Labels go to stdout one per line, which is the
# shape `bazelisk test` consumes.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:bazel-map -- targets [pattern]
#   bazelisk run //scripts:bazel-map -- tests-for <path>...
#   bazelisk run //scripts:bazel-map -- owners <path>...
#   bazelisk run //scripts:bazel-map -- files <target>
#   bazelisk run //scripts:bazel-map -- twins <path>...
#   bazelisk run //scripts:bazel-map -- scope [--staged] [--untracked] [--ref <ref>]
#   bazelisk run //scripts:bazel-map -- unlisted <dir>...
#   bazelisk run //scripts:bazel-map -- [--json] [-h|--help]
#
# Options (accepted anywhere in argv):
#   --staged      scope reads the index instead of the working tree
#   --untracked   scope also counts untracked files
#   --ref <ref>   scope reads what this branch adds over <ref>
#   --all         tests-for and scope also take the aggregate suites, which the default
#                 kind filter drops (every test rule here, lint targets included, is
#                 already an sh_test)
#   --label-kind  targets prints each label with its rule class
#   --json        prose on stderr, so stdout stays a bare label list you can pipe
#   -h, --help    print the usage block and exit 0
#
# Verbs:
#   targets     real target names, so a target is never guessed. The optional
#               argument is a package specifier (default //...).
#   tests-for   the test targets that reach these files: the list to run while you
#               iterate on them. Paths are repo-relative.
#   owners      which filegroups claim these files - the answer to "is this payload
#               visible to the harness at all".
#   files       the source files one target reads, i.e. its declared runfiles.
#   twins       the counterpart copies of a template payload file across the two
#               template trees and templates/common, which must move together.
#   scope       the derived test list for the changes in this checkout: the loop
#               that replaces re-running the whole fast gate after every edit.
#   unlisted    files git tracks under these directories that no target reaches,
#               which is how a new payload directory stays invisible to the gates.
#
# Output: the house vocabulary - "== section ==", "-> phase", "ok:", "warning:",
#   "note:", "error:", and a closing "summary: N ok, W warnings, F failed". Under
#   --json that commentary all rides stderr and stdout carries only labels.
# Exit codes: 0 when every named thing resolved, 1 on a query failure, 2 on a usage
#   error (an unknown verb or flag, or a verb invoked without the argument it needs).
#
# A path the graph does not know is a warning naming that path, not a crash: the
# usual cause is a file you just created that no filegroup claims yet, which is the
# finding rather than an error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"

# The verbs, kept as one literal so --help and the usage guard read the same list.
readonly -a MAP_VERBS=(targets tests-for owners files twins scope unlisted)
readonly MAP_QUERY_TIMEOUT="${MAP_QUERY_TIMEOUT:-180}"

# @function usage
# Print the verb and flag list on stdout, so a typo prints something readable.
# Globals:
#   MAP_VERBS
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE_EOF'
Usage: bazelisk run //scripts:bazel-map -- <verb> [args] [--json] [-h|--help]

  targets [pattern]     real target names, so a target is never guessed
  tests-for <path>...   the test targets that reach these files
  owners <path>...      which filegroups claim these files
  files <target>        the source files one target reads (its runfiles)
  twins <path>...       the counterpart copies of a template payload file
  scope [--staged] [--untracked] [--ref <ref>]
                        the derived test list for the changes in this checkout
  unlisted <dir>...     git-tracked files under these dirs that no target reaches

Flags: --staged --untracked --ref <ref> --all --label-kind --json -h|--help
Labels go to stdout one per line; prose goes to stderr under --json.
USAGE_EOF
}

# @function graph_query
# Run one Bazel query from the checkout root and put its labels on stdout.
#
# Bazel writes progress and errors to stderr. Both are captured so a failed query
# reports what Bazel actually said: a discarded stderr is how a query-based check most
# often lies, since the empty result looks like "nothing depends on this".
# Globals:
#   MAP_QUERY_TIMEOUT
# Arguments:
#   $1 - the query expression
#   $* - extra flags for bazelisk query, such as --output=label_kind
# Outputs:
#   The result labels on stdout; Bazel's own complaint on stderr when it fails
# Returns:
#   0 on success, 1 when Bazel refused the expression
graph_query() {
  local expr="${1:-}"
  shift || true
  if [ -z "${expr}" ]; then
    err "graph_query needs a query expression"
    return 1
  fi
  local out err_file rc=0
  out="$(mktemp)"
  err_file="$(mktemp)"
  # `if ! cmd; then rc=$?; fi` would capture 0 here, because $? is the status of the
  # negated test. The || form is what actually records the command's own status, and
  # Bazel's ERROR line is checked as well: query can report a miss on stderr and still
  # leave the caller with an empty, successful-looking result.
  timeout "${MAP_QUERY_TIMEOUT}" bazelisk query "${expr}" "$@" >"${out}" 2>"${err_file}" || rc=$?
  if [ "${rc}" -ne 0 ] || grep -q '^ERROR' "${err_file}"; then
    err "query failed (status ${rc}): ${expr}"
    while IFS= read -r line; do
      err "  bazel: ${line}"
    done < <(grep -v '^Loading\|^Analyzing\|^INFO' "${err_file}" | head -4)
    rm -f "${out}" "${err_file}"
    return 1
  fi
  rm -f "${err_file}"
  cat "${out}"
  rm -f "${out}"
  return 0
}

# @function path_operand
# Turn a repo-relative path into a quoted query operand, or refuse it.
#
# Bazel accepts a workspace-relative path as a target shorthand, which is what makes a
# file-level rdeps work without knowing the file's package. A path carrying a double
# quote or a newline could break out of the quoted operand, so those are refused rather
# than escaped: no path in this repo needs either character.
# Globals:
#   None
# Arguments:
#   $1 - repo-relative path
# Outputs:
#   The quoted operand on stdout
# Returns:
#   0 when the path is usable, 1 when it is empty or carries an unsafe character
path_operand() {
  local path="${1:-}"
  if [ -z "${path}" ]; then
    err "an empty path is not a query operand"
    return 1
  fi
  case "${path}" in
    *'"'* | *$'\n'*)
      err "refusing a path with a quote or a newline: ${path}"
      return 1
      ;;
  esac
  printf '"%s"\n' "${path}"
}

# @function roots_expression
# Join repo-relative paths into one query union, so a batch costs a single query.
# Globals:
#   None
# Arguments:
#   $* - repo-relative paths
# Outputs:
#   The union expression on stdout, e.g. "a.sh" + "b.sh"
# Returns:
#   0 when every path was usable, 1 otherwise
roots_expression() {
  if [ $# -eq 0 ]; then
    err "no paths to query"
    return 1
  fi
  local -a operands=()
  local path operand joined=""
  for path in "$@"; do
    if ! operand="$(path_operand "${path}")"; then
      return 1
    fi
    operands+=("${operand}")
  done
  for operand in "${operands[@]}"; do
    if [ -z "${joined}" ]; then
      joined="${operand}"
    else
      joined="${joined} + ${operand}"
    fi
  done
  printf '%s\n' "${joined}"
}

# @function label_to_path
# Turn a source-file label into its repo-relative path.
#
# The graph speaks in labels (//templates/common:tmux.conf) and the working tree speaks
# in paths (templates/common/tmux.conf). A file lives in the nearest ancestor directory
# that holds a BUILD file, so a filegroup over a subdirectory keeps that subdirectory on
# the label's path half (//hermes:skills/host-diagnostics/SKILL.md). A root-package label
# carries an empty package (//:.github/workflows/ci.yml), whose colon leaves a leading
# slash behind. Converting labels to paths is therefore the one direction that needs no
# package map, and every comparison between the two goes through here.
# Globals:
#   None
# Arguments:
#   $1 - a source-file label
# Outputs:
#   The repo-relative path on stdout
# Returns:
#   0
label_to_path() {
  local label="${1:-}"
  label="${label#//}"
  label="${label/://}"
  printf '%s\n' "${label#/}"
}

# @function tests_filter
# Print the query template that scopes a change to the tests worth running.
#
# The kind filter is the whole point. rdeps alone also returns the aggregate suites, and
# //:test-fast reaches everything, so it matches every file and tells you nothing about
# what to run. Dropping test_suite leaves the suites you can actually invoke; --all puts
# them back. A function rather than a module constant, so a Bats unit test can load it
# on its own the way the house loader extracts one function at a time.
# Globals:
#   MAP_ALL
# Arguments:
#   None
# Outputs:
#   The query template on stdout, with %s where the roots expression goes
# Returns:
#   0
tests_filter() {
  if [ -n "${MAP_ALL:-}" ]; then
    printf '%s\n' 'kind("test", rdeps(//..., %s))'
  else
    printf '%s\n' 'kind("sh_test", rdeps(//..., %s)) except kind("test_suite", //...)'
  fi
}

# @function tests_for_paths
# Print the leaf test targets that reach these files.
# Globals:
#   MAP_ALL
# Arguments:
#   $* - repo-relative paths
# Outputs:
#   Target labels on stdout
# Returns:
#   0 on success, 1 when the query failed or a path was unsafe
tests_for_paths() {
  local roots filter
  roots="$(roots_expression "$@")" || return 1
  filter="$(tests_filter)"
  graph_query "${filter/\%s/${roots}}"
}

# @function isolate_bad_path
# Re-run a failed batch one path at a time and name the path the graph does not know.
#
# One query covers the whole batch, so a single unknown file would otherwise hide every
# other answer. Splitting only on failure keeps the common path at one query.
# Globals:
#   None
# Arguments:
#   $1 - the query template, with %s where the roots expression goes
#   $* - repo-relative paths
# Outputs:
#   Labels on stdout for the paths that resolved; one warning per path that did not
# Returns:
#   0 when every path resolved, 1 when at least one did not
isolate_bad_path() {
  local template="${1}"
  shift
  local -a good=()
  local path roots result failed=0
  for path in "$@"; do
    if roots="$(roots_expression "${path}")" &&
      result="$(graph_query "${template/\%s/${roots}}" 2>/dev/null)"; then
      good+=("${path}")
      [ -n "${result}" ] && printf '%s\n' "${result}"
    else
      warn "the graph does not know ${path}: no target declares it (a new file reaches the harness through a filegroup)"
      failed=1
    fi
  done
  if [ ${#good[@]} -eq 0 ]; then
    return 1
  fi
  return "${failed}"
}

# @function cmd_tests_for
# Verb: the test targets to run for the named files.
# Globals:
#   MAP_ALL
# Arguments:
#   $* - repo-relative paths
# Outputs:
#   Labels on stdout, plus the section and summary lines
# Returns:
#   0 on success, 2 when no path was given, 1 on a query failure
cmd_tests_for() {
  local -a paths=("$@")
  if [ ${#paths[@]} -eq 0 ]; then
    err "tests-for needs at least one repo-relative path"
    return 2
  fi
  section "tests for ${#paths[@]} path(s)"
  if ! tests_for_paths "${paths[@]}"; then
    isolate_bad_path "$(tests_filter)" "${paths[@]}" || return 1
  fi
  ok "tests-for"
  summary
  return 0
}

# @function cmd_owners
# Verb: which filegroups claim the named files.
# Globals:
#   None
# Arguments:
#   $* - repo-relative paths
# Outputs:
#   Labels on stdout, plus the section and summary lines
# Returns:
#   0 on success, 2 when no path was given, 1 on a query failure
cmd_owners() {
  local -a paths=("$@")
  if [ ${#paths[@]} -eq 0 ]; then
    err "owners needs at least one repo-relative path"
    return 2
  fi
  section "owners of ${#paths[@]} path(s)"
  local roots
  roots="$(roots_expression "${paths[@]}")" || return 1
  if ! graph_query "kind(\"filegroup\", rdeps(//..., ${roots}))"; then
    isolate_bad_path 'kind("filegroup", rdeps(//..., %s))' "${paths[@]}" || return 1
  fi
  note "an empty list means no filegroup carries this file, so test-fast and lint never see it"
  ok "owners"
  summary
  return 0
}

# @function cmd_targets
# Verb: the real target names, so a target is never guessed.
# Globals:
#   MAP_LABEL_KIND
# Arguments:
#   $1 - optional package specifier (default //...)
# Outputs:
#   Labels on stdout, each with its rule class under --label-kind
# Returns:
#   0 on success, 1 on a query failure
cmd_targets() {
  local spec="${1:-//...}"
  section "targets in ${spec}"
  if [ -n "${MAP_LABEL_KIND:-}" ]; then
    graph_query "kind(\"rule\", ${spec})" --output=label_kind || return 1
  else
    graph_query "kind(\"rule\", ${spec})" || return 1
  fi
  ok "targets"
  summary
  return 0
}

# @function cmd_files
# Verb: the source files one target reads.
# Globals:
#   None
# Arguments:
#   $1 - a target label
# Outputs:
#   File labels on stdout
# Returns:
#   0 on success, 2 when no target was given, 1 on a query failure
cmd_files() {
  local target="${1:-}"
  if [ -z "${target}" ]; then
    err "files needs one target label"
    return 2
  fi
  section "files read by ${target}"
  graph_query "kind(\"source file\", deps(${target}))" || return 1
  ok "files"
  summary
  return 0
}

# @function cmd_twins
# Verb: the counterpart copies of a template payload file.
#
# The two template trees keep independent payload copies that must move together, and
# templates/common holds the files both consume as one shared copy. The graph lists all
# three groups, so the twin set is a basename match over their union rather than a
# convention someone has to remember. A file with no same-named counterpart is reported
# against the group that claims it: a common file is the intentional single copy, while
# a per-tree file with no twin is the drift worth knowing about.
# Globals:
#   None
# Arguments:
#   $* - paths under a template tree
# Outputs:
#   A header per queried path, then the counterpart labels or the claiming group
# Returns:
#   0 on success, 2 when no path was given, 1 on a query failure
cmd_twins() {
  local -a paths=("$@")
  if [ ${#paths[@]} -eq 0 ]; then
    err "twins needs at least one path under a template tree"
    return 2
  fi
  section "twin copies of ${#paths[@]} path(s)"
  local pool
  if ! pool="$(graph_query 'kind("source file", deps(//templates/workspace:payload + //templates/devcontainer:payload + //templates/common:payload))')"; then
    err "the template payload groups did not resolve"
    return 1
  fi
  local rc=0 name label candidate found groups claimed
  for path in "${paths[@]}"; do
    name="${path##*/}"
    printf '== %s\n' "${path}"
    found=0
    while IFS= read -r label; do
      [ -n "${label}" ] || continue
      candidate="$(label_to_path "${label}")"
      if [ "${candidate##*/}" = "${name}" ] && [ "${candidate}" != "${path}" ]; then
        printf '%s\n' "${label}"
        found=1
      fi
    done <<<"${pool}"
    if [ "${found}" -eq 1 ]; then
      continue
    fi
    if ! groups="$(graph_query "kind(\"filegroup\", rdeps(//..., \"${path}\"))" 2>/dev/null)"; then
      warn "the graph does not know ${path}"
      rc=1
      continue
    fi
    claimed="$(printf '%s\n' "${groups}" |
      grep -E '^//templates/(workspace|devcontainer|common):payload$' | head -1 || true)"
    if [ "${claimed}" = "//templates/common:payload" ]; then
      note "one shared copy in //templates/common:payload, staged by both template twins"
    elif [ -n "${claimed}" ]; then
      warn "${path} exists only in ${claimed}; the sibling tree has no counterpart"
    else
      warn "${path} is not claimed by any template payload group"
    fi
  done
  ok "twins"
  summary
  return "${rc}"
}

# @function changed_paths
# List the repo-relative paths this checkout changes.
# Globals:
#   MAP_STAGED, MAP_UNTRACKED, MAP_REF
# Arguments:
#   None
# Outputs:
#   One path per line on stdout, deletions excluded
# Returns:
#   0 on success, 1 when git is unavailable
changed_paths() {
  if ! command -v git >/dev/null 2>&1; then
    err "git is not on PATH, so scope cannot read the working tree"
    return 1
  fi
  local -a lines=()
  if [ -n "${MAP_REF:-}" ]; then
    mapfile -t lines < <(git diff --name-only --diff-filter=d "${MAP_REF}...HEAD" 2>/dev/null || true)
  elif [ -n "${MAP_STAGED:-}" ]; then
    mapfile -t lines < <(git diff --name-only --cached --diff-filter=d 2>/dev/null || true)
  else
    mapfile -t lines < <(git diff --name-only --diff-filter=d HEAD 2>/dev/null || true)
  fi
  if [ -n "${MAP_UNTRACKED:-}" ]; then
    # mapfile has no append flag, so the untracked set lands in its own array first.
    local -a extra=()
    mapfile -t extra < <(git ls-files --others --exclude-standard 2>/dev/null || true)
    if [ ${#extra[@]} -gt 0 ]; then
      lines+=("${extra[@]}")
    fi
  fi
  local path
  for path in "${lines[@]}"; do
    [ -n "${path}" ] && printf '%s\n' "${path}"
  done
  return 0
}

# @function cmd_scope
# Verb: the derived test list for this checkout's changes.
#
# This is the loop-breaker. Re-running the whole fast gate after every edit pays for
# sixty suites to learn one thing about the files you touched; the graph names those
# suites directly. The full gate stays as the fallback: an empty result means the change
# touches nothing the graph tracks, which is exactly when running all of it is right.
# Globals:
#   MAP_STAGED, MAP_UNTRACKED, MAP_REF, MAP_ALL
# Arguments:
#   None
# Outputs:
#   Labels on stdout, plus the section and summary lines
# Returns:
#   0 on success, 1 on a query failure
cmd_scope() {
  section "test scope for this checkout"
  local -a paths=()
  mapfile -t paths < <(changed_paths)
  if [ ${#paths[@]} -eq 0 ]; then
    note "nothing changed against HEAD; run //:test-fast"
    ok "scope"
    summary
    return 0
  fi
  phase "${#paths[@]} changed path(s)"
  local -a wanted=()
  local path
  for path in "${paths[@]}"; do
    case "${path}" in
      *'"'*) warn "skipping an unquotable path: ${path}" ;;
      *) wanted+=("${path}") ;;
    esac
  done
  if [ ${#wanted[@]} -eq 0 ]; then
    note "no queryable path; run //:test-fast"
    ok "scope"
    summary
    return 0
  fi
  if ! tests_for_paths "${wanted[@]}"; then
    isolate_bad_path "$(tests_filter)" "${wanted[@]}" || return 1
  fi
  note "run them with: bazelisk test <labels>; keep one uncached //:test-fast pass before the PR"
  ok "scope"
  summary
  return 0
}

# @function cmd_unlisted
# Verb: files git tracks under these directories that no target reaches.
#
# A new top-level payload directory stays invisible to the fast gate until it joins a
# filegroup, and nothing says so out loud. Comparing git's list against the graph's list
# turns that omission into a one-line answer.
# Globals:
#   None
# Arguments:
#   $* - directories relative to the repo root
# Outputs:
#   The unclaimed paths on stdout, one per line
# Returns:
#   0 when every tracked file is claimed, 2 when no directory was given,
#   1 when some are unclaimed or a query failed
cmd_unlisted() {
  local -a dirs=("$@")
  if [ ${#dirs[@]} -eq 0 ]; then
    err "unlisted needs at least one directory"
    return 2
  fi
  section "unclaimed files under ${dirs[*]}"
  local tracked pool
  if ! tracked="$(git ls-files -- "${dirs[@]}" 2>/dev/null | sort -u)"; then
    err "git ls-files failed for ${dirs[*]}"
    return 1
  fi
  if [ -z "${tracked}" ]; then
    note "git tracks nothing under ${dirs[*]}"
    ok "unlisted"
    summary
    return 0
  fi
  if ! pool="$(graph_query 'kind("source file", deps(//...))')"; then
    err "the graph did not enumerate its source files"
    return 1
  fi
  local path label claimed_path rc=0
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    # Bazel reads its own declaration files implicitly, so a BUILD or .bzl file is only
    # ever in the graph when a package deliberately exports it as a :build_file group.
    # Counting them would flag every package in the repo instead of a real omission.
    case "${path}" in
      */BUILD.bazel | */*.bzl | BUILD.bazel | MODULE.bazel | MODULE.bazel.lock) continue ;;
    esac
    claimed_path=0
    while IFS= read -r label; do
      [ -n "${label}" ] || continue
      if [ "$(label_to_path "${label}")" = "${path}" ]; then
        claimed_path=1
        break
      fi
    done <<<"${pool}"
    if [ "${claimed_path}" -eq 0 ]; then
      printf '%s\n' "${path}"
      rc=1
    fi
  done <<<"${tracked}"
  if [ "${rc}" -eq 1 ]; then
    warn "these files reach no target, so test-fast and lint never open them"
  fi
  ok "unlisted"
  summary
  return "${rc}"
}

# @function parse_args
# Split argv into the verb, its positional args, and the flags.
# Globals:
#   MAP_VERBS, MAP_STAGED, MAP_UNTRACKED, MAP_REF, MAP_ALL, MAP_LABEL_KIND, JSON_MODE
# Arguments:
#   $* - the CLI arguments
# Outputs:
#   Sets the MAP_* flags and the VERB and VERB_ARGS globals
# Returns:
#   0 on success, 2 on an unknown verb or flag
parse_args() {
  VERB=""
  VERB_ARGS=()
  MAP_STAGED=""
  MAP_UNTRACKED=""
  MAP_REF=""
  MAP_ALL=""
  MAP_LABEL_KIND=""
  local want_json=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --json) want_json=1 ;;
      --staged) MAP_STAGED=1 ;;
      --untracked) MAP_UNTRACKED=1 ;;
      --all) MAP_ALL=1 ;;
      --label-kind) MAP_LABEL_KIND=1 ;;
      --ref)
        if [ $# -lt 2 ] || [[ ${2:-} == --* ]]; then
          err "--ref needs a value"
          return 2
        fi
        MAP_REF="$2"
        shift
        ;;
      --) ;;
      -*)
        err "unknown flag: $1"
        usage >&2
        return 2
        ;;
      *)
        if [ -z "${VERB}" ]; then
          VERB="$1"
        else
          VERB_ARGS+=("$1")
        fi
        ;;
    esac
    shift
  done
  if [ "${want_json}" = "1" ]; then
    # shellcheck disable=SC2034 # log() in scripts/lib/common.sh is the reader
    JSON_MODE=1
  fi
  local candidate found=0
  for candidate in "${MAP_VERBS[@]}"; do
    [ "${candidate}" = "${VERB}" ] && found=1
  done
  if [ "${found}" -ne 1 ]; then
    if [ -n "${VERB}" ]; then
      err "unknown verb: ${VERB}"
    fi
    usage >&2
    return 2
  fi
  return 0
}

# @function main
# Resolve the checkout, dispatch the verb, and close with the summary.
# Globals:
#   BUILD_WORKSPACE_DIRECTORY, VERB, VERB_ARGS
# Arguments:
#   $* - the CLI arguments
# Outputs:
#   The verb's report
# Returns:
#   The verb's exit status, or 2 on a usage error
main() {
  parse_args "$@" || return $?
  local root
  if ! root="$(resolve_checkout "${SELF_DIR}")"; then
    err "cannot find the checkout: run this through 'bazelisk run //scripts:bazel-map'"
    return 1
  fi
  cd "${root}" || return 1
  if ! command -v bazelisk >/dev/null 2>&1; then
    die "bazelisk is not on PATH, so the graph cannot be queried"
  fi
  case "${VERB}" in
    targets) cmd_targets "${VERB_ARGS[@]}" ;;
    tests-for) cmd_tests_for "${VERB_ARGS[@]}" ;;
    owners) cmd_owners "${VERB_ARGS[@]}" ;;
    files) cmd_files "${VERB_ARGS[@]}" ;;
    twins) cmd_twins "${VERB_ARGS[@]}" ;;
    scope) cmd_scope ;;
    unlisted) cmd_unlisted "${VERB_ARGS[@]}" ;;
  esac
}

main "$@"
