# shellcheck shell=bash
#
# ## common.sh — shared shell helpers for scripts/*.sh (sourced; never executed)
#
# Invariants:
#   - Sourcing this file never changes shell options, cwd, or variables with side
#     effects; it deliberately omits `set -euo pipefail` and inherits the
#     caller's options, like every other file under scripts/lib/.
#   - Every helper reads its inputs from arguments, never from an implicit cwd or
#     a hardcoded `.env`; secrets stay data and never echo.
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
# Print a soft warning. Never a failure.
# Globals:
#   JSON_MODE (via log)
# Arguments:
#   $* - warning text, without the "warning: " prefix
# Outputs:
#   "warning: ..." via log
# Returns:
#   0
warn() { log "warning: $*"; }

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
#   None
# Arguments:
#   $* - message
# Outputs:
#   The message on stdout
# Returns:
#   Does not return; exits 0
skip() {
  printf '%s\n' "$*"
  exit 0
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
#   The value, or nothing
# Returns:
#   0
env_get() {
  local file="$1" key="$2"
  sed -n "s|^${key}=||p" "${file}" 2>/dev/null | tail -n 1 |
    sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|'
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
