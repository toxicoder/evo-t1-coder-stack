# shellcheck shell=bash
#
# ## common.sh — shared shell helpers for scripts/*.sh (sourced; never executed)
#
# Invariants:
#   - Sourcing this file never changes shell options, cwd, or variables with side
#     effects; it deliberately omits `set -euo pipefail` and inherits the
#     caller's options, like every other file under scripts/lib/.
#   - Every helper reads its inputs from arguments, never from an implicit cwd or
#     a hardcoded `.env`; secrets stay data and never echo. The one exception is
#     resolve_checkout, whose checkout-name candidates come from the environment
#     (REPO_ROOT / BUILD_WORKSPACE_DIRECTORY / GITHUB_WORKSPACE / PWD) because a
#     script cannot know them any other way; it still takes its own directory and
#     the proof marker as arguments.
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root `cd`):
#   # shellcheck source=lib/common.sh disable=SC1091
#   source "scripts/lib/common.sh"

# ── Messages ───────────────────────────────────────────────────────────────────

# @function log
# Print a status line. With JSON_MODE non-empty every prose line goes to stderr
# instead, so `--json` keeps stdout parseable and `2>/dev/null` still silences
# the commentary without losing it.
# Globals:
#   JSON_MODE
# Arguments:
#   $* - text to print
# Outputs:
#   The text on stdout, or on stderr when JSON_MODE is set
# Returns:
#   0
log() {
  if [ -n "${JSON_MODE:-}" ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi
}

# @function warn
# Print a soft warning. Never a failure. Counts toward summary.
# Globals:
#   JSON_MODE (via log), SUMMARY_WARN
# Arguments:
#   $* - warning text, without the "warning: " prefix
# Outputs:
#   "warning: ..." via log
# Returns:
#   0
warn() {
  log "warning: $*"
  SUMMARY_WARN=$((${SUMMARY_WARN:-0} + 1))
}

# @function note
# Print soft commentary. Never a failure.
# Globals:
#   JSON_MODE (via log)
# Arguments:
#   $* - note text, without the "note: " prefix
# Outputs:
#   "note: ..." via log
# Returns:
#   0
note() { log "note: $*"; }

# @function err
# Print an error line on stderr so pipes keep stdout clean.
# Globals:
#   None
# Arguments:
#   $* - error text, without the "error: " prefix
# Outputs:
#   "error: ..." on stderr
# Returns:
#   0
err() { printf 'error: %s\n' "$*" >&2; }

# @function die
# Print an error on stderr and exit 1.
# Globals:
#   None
# Arguments:
#   $* - error text, without the "error: " prefix
# Outputs:
#   "error: ..." on stderr
# Returns:
#   Does not return; exits 1
die() {
  err "$*"
  exit 1
}

# @function skip
# Print an expected non-error state and exit 0, so callers such as
# scripts/bootstrap.sh keep going.
# Globals:
#   JSON_MODE (via log)
# Arguments:
#   $* - message
# Outputs:
#   The message via log (stderr when JSON_MODE is set)
# Returns:
#   Does not return; exits 0
skip() {
  log "$*"
  exit 0
}

# @function section
# Print a grouping header so a multi-step CLI's phases stay visually separate.
# Globals:
#   JSON_MODE (via log)
# Arguments:
#   $* - section title
# Outputs:
#   A blank line, then "== title =="
# Returns:
#   0
section() {
  log ""
  log "== $* =="
}

# @function phase
# Print a phase line before a step that can take seconds.
# Globals:
#   JSON_MODE (via log)
# Arguments:
#   $* - what this step is doing
# Outputs:
#   "-> ..." via log
# Returns:
#   0
phase() { log "-> $*"; }

# @function ok
# Print a successful item and count it for summary.
# Globals:
#   JSON_MODE (via log), SUMMARY_OK
# Arguments:
#   $* - item text, without the "ok: " prefix
# Outputs:
#   "ok: ..." via log
# Returns:
#   0
ok() {
  log "ok: $*"
  SUMMARY_OK=$((${SUMMARY_OK:-0} + 1))
}

# @function fail_item
# Record a failure without exiting, so a CLI can keep going and summarize.
# Globals:
#   SUMMARY_FAIL, SUMMARY_FAIL_ITEMS
# Arguments:
#   $* - failure text, without the "error: " prefix
# Outputs:
#   "error: ..." on stderr
# Returns:
#   0
fail_item() {
  err "$*"
  SUMMARY_FAIL=$((${SUMMARY_FAIL:-0} + 1))
  if [ -n "${SUMMARY_FAIL_ITEMS:-}" ]; then
    SUMMARY_FAIL_ITEMS="${SUMMARY_FAIL_ITEMS}
$*"
  else
    SUMMARY_FAIL_ITEMS="$*"
  fi
}

# @function summary
# Print the run's counts, any recorded failures, and an optional next command.
# Globals:
#   JSON_MODE (via log), SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL, SUMMARY_FAIL_ITEMS
# Arguments:
#   $1 - optional next-step command, printed as "next: ..."
# Outputs:
#   "summary: N ok, W warnings, F failed", then one "  failed: ..." line per
#   fail_item, then "next: ..." when $1 is set
# Returns:
#   0
summary() {
  local line=""
  log "summary: ${SUMMARY_OK:-0} ok, ${SUMMARY_WARN:-0} warnings, ${SUMMARY_FAIL:-0} failed"
  if [ -n "${SUMMARY_FAIL_ITEMS:-}" ]; then
    while IFS= read -r line; do
      [ -n "${line}" ] && log "  failed: ${line}"
    done <<EOF
${SUMMARY_FAIL_ITEMS}
EOF
  fi
  if [ -n "${1:-}" ]; then
    log "next: $1"
  fi
}

# ── Repo root ────────────────────────────────────────────────────────────────

# @function resolve_checkout
# Print the checkout this run should work in. A script run through `bazelisk run`
# executes the runfiles copy of itself, so neither its cwd nor its own directory
# is the checkout: runfiles carries only what //:stack_data ships, and a working
# file that lives only in the checkout (the untracked .env, sparks/ output) is
# absent there. Candidates are tried in order and each has to prove itself.
# Globals:
#   REPO_ROOT (an explicit statement of the checkout, trusted as given),
#   BUILD_WORKSPACE_DIRECTORY, GITHUB_WORKSPACE, PWD (derived candidates)
# Arguments:
#   $1 - the calling script's own directory (its SELF_DIR), the last candidate
#   $2 - marker file a candidate must hold to count as a checkout; default
#        docker-compose.yml
# Outputs:
#   The root on stdout, or one "error: ..." line on stderr naming every
#   candidate it tried
# Returns:
#   0 with the root on stdout; 5 when the caller gave no directory or no
#   candidate proved out
resolve_checkout() {
  local self_dir="${1:-}" marker="${2:-docker-compose.yml}"
  local candidate physical explicit="" saw_runfiles=0
  if [ -z "${self_dir}" ]; then
    err "resolve_checkout needs the calling script's own directory"
    return 5
  fi
  local -a candidates=()
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
    explicit="${REPO_ROOT}"
  fi
  if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    candidates+=("${BUILD_WORKSPACE_DIRECTORY}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}" "${self_dir}/..")

  for candidate in "${candidates[@]}"; do
    [ -f "${candidate}/${marker}" ] || continue
    physical="$(cd "${candidate}" 2>/dev/null && pwd -P)" || continue
    if [ "${candidate}" != "${explicit}" ]; then
      # A Bazel copy of the repo holds a real docker-compose.yml, so the marker
      # alone cannot tell it apart from the checkout. Reading through it is
      # harmless; writing through it (a rotated password, a sparks/<host>.env)
      # would report success while the checkout kept the old bytes. REPO_ROOT is
      # exempt: it is a human or harness statement about where to work, and the
      # Bats runner points it at the copy of the repo under test on purpose.
      case "${physical}" in
        */bazel-out/* | */bazel-bin/* | */execroot/* | *.runfiles | *.runfiles/*)
          saw_runfiles=1
          continue
          ;;
      esac
    fi
    printf '%s\n' "${candidate}"
    return 0
  done
  if [ "${saw_runfiles}" = 1 ]; then
    err "unresolvable repo root: only a Bazel runfiles copy proved ${marker}; run this through bazelisk run (it names the checkout in BUILD_WORKSPACE_DIRECTORY) or set REPO_ROOT"
    return 5
  fi
  err "unresolvable repo root: no proven checkout in ${candidates[*]} (need ${marker})"
  return 5
}

# ── Key=value readers ──────────────────────────────────────────────────────────

# @function env_get
# Print the LAST assignment of a key in a file, outer double or single quotes
# stripped, empty when absent. Read with sed and never sourced: these files are
# user-editable, and a parse error or stray command substitution inside one
# must not abort the reader or execute anything.
# Globals:
#   None
# Arguments:
#   $1 - file path
#   $2 - key name
# Outputs:
#   The value, or nothing (missing or unreadable file included)
# Returns:
#   0, always: a failing sed would propagate through pipefail into the
#   caller's assignment and abort a strict-mode script, which this reader
#   promises to keep running
env_get() {
  local file="$1" key="$2"
  [ -f "${file}" ] || return 0
  sed -n "s|^${key}=||p" "${file}" 2>/dev/null | tail -n 1 |
    sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|' || true
}

# @function fact_get
# Read one key from a per-host key=value report file. An empty answer or the
# literal NOTSET means "never measured" and falls back to the default.
# Globals:
#   None
# Arguments:
#   $1 - report file
#   $2 - key name
#   $3 - default when missing, empty, or NOTSET
# Outputs:
#   The value or the default
# Returns:
#   0
fact_get() {
  local value=""
  if [ -s "$1" ] && [ -f "$1" ]; then
    value="$(sed -n "s|^${2}=||p" "$1" | tail -n 1)"
  fi
  case "${value}" in
    '' | NOTSET) printf '%s' "${3:-}" ;;
    *) printf '%s' "${value}" ;;
  esac
}

# @function first_line
# Print the first non-blank line of a blob so a tool's complaint can be quoted
# without dumping its whole stderr. The trailing `|| true` is load-bearing:
# with pipefail an all-blank input makes grep exit 1, and callers assign this
# under `set -e`.
# Globals:
#   None
# Arguments:
#   $1 - text blob
# Outputs:
#   The first non-blank line, or nothing
# Returns:
#   0
first_line() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

# @function truthy
# Succeed for on, 1, true, or yes, any case.
# Globals:
#   None
# Arguments:
#   $1 - candidate value
# Outputs:
#   None
# Returns:
#   0 when truthy, 1 otherwise
truthy() {
  case "${1:-}" in
    [Oo][Nn] | 1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── URLs and JSON ────────────────────────────────────────────────────────────

# @function canonical_url
# Strip the scheme, the port, and any path so two URLs compare by bare host.
# Globals:
#   None
# Arguments:
#   $1 - URL or host
# Outputs:
#   The bare host
# Returns:
#   0
canonical_url() {
  printf '%s' "${1:-}" | sed -E 's|^https?://||; s|[:/].*$||'
}

# JSON_ESCAPE_SED — one sed program, quoted: escape \ and " in one pass.
JSON_ESCAPE_SED='s/["\\]/\\&/g'

# @function json_escape
# Escape backslash and double quote, drop newlines, and clip to 180 characters
# so remote replies cannot close a JSON string.
# Globals:
#   JSON_ESCAPE_SED
# Arguments:
#   $1 - raw text
# Outputs:
#   The escaped, clipped text
# Returns:
#   0
json_escape() {
  local trimmed
  trimmed="$(printf '%s' "$1" | sed -E "${JSON_ESCAPE_SED}" | tr -d '\n\r')"
  printf '%s' "${trimmed:0:180}"
}

# @function json_value
# Format one JSON scalar: empty becomes null, a pure integer stays bare, and
# anything else becomes a quoted string. A check that never ran prints null.
# Globals:
#   None
# Arguments:
#   $1 - value, optional
# Outputs:
#   null, a bare integer, or a quoted string
# Returns:
#   0
json_value() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    printf 'null'
    return
  fi
  case "$1" in
    *[!0-9]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── Tool availability and timeouts ───────────────────────────────────────────

# @function has_tool
# Quiet presence check for one executable.
# Globals:
#   None
# Arguments:
#   $1 - command name
# Outputs:
#   None
# Returns:
#   0 when the command is on PATH, 1 otherwise
has_tool() { command -v "${1}" >/dev/null 2>&1; }

# @function require_tool
# A missing tool prints why and exits 0 (a "not yet" state), except when CI=true,
# where it exits 1. A gate that silently skipped is a gate that never ran.
# Globals:
#   CI
# Arguments:
#   $1 - command name
#   $2 - why text, optional
# Outputs:
#   The why text when the tool is missing
# Returns:
#   0 when present; exits 0 when missing and CI is not true; exits 1 when CI=true
require_tool() {
  local cmd="$1" why="${2:-${1} is not on PATH}"
  if ! has_tool "${cmd}"; then
    if [ "${CI:-false}" = "true" ]; then
      die "${why}"
    fi
    skip "${why}"
  fi
}

# @function capped_run
# Run one command with timeout(1) when timeout exists, uncapped when it does not.
# The cap is best-effort: a host without timeout(1) still runs the command.
# Globals:
#   None
# Arguments:
#   $1 - cap in seconds
#   $2... - command and arguments
# Outputs:
#   The command's own stdout and stderr
# Returns:
#   The command's status, or 124 when timeout cuts it off
capped_run() {
  local cap="$1"
  shift
  if has_tool timeout; then
    timeout "${cap}" "$@"
  else
    "$@"
  fi
}
