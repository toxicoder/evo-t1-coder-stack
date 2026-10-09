# shellcheck shell=bash
#
# ## test_helpers.sh — assertion helpers for BATS suites and bash gates (sourced;
# never executed)
#
# Invariants:
#   - Sourcing this file changes no shell options and no state. Every helper
#     prints to stderr and returns non-zero on failure, and none of them
#     requires a BATS builtin — the same file works inside `bats` suites and
#     inside plain `bash` gate scripts that source it.
#   - Under BATS this file redefines the `fail` builtin with compatible
#     semantics (print, then fail): `cmd || fail "…"` reads the same in either
#     host, and a bare failing assert inside a @test body still fails the test.
#
# Usage:
#   .bats suite:   load 'test_helper'   (test_helper.bash sources this file)
#   bash gate:     source "tests/test_helpers.sh"

# fail [message] — print a failure line and return non-zero.
fail() {
  printf 'FAIL: %s\n' "${1:-assertion failed}" >&2
  return 1
}

# assert_eq <label> <expected> <actual> — exact string equality.
assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

# load_shell_function <file> <name> — eval one production function into this shell.
# The body is the function text from <file>, not a copy kept in the test.
load_shell_function() {
  local file="$1" name="$2" body helper_dir
  helper_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  body="$(python3 "${helper_dir}/extract_fn.py" "${file}" "${name}")" || return 1
  # shellcheck disable=SC2294
  eval "${body}"
}

# assert_match <label> <regex> <text> — <text> must contain a match for <regex>.
assert_match() {
  if ! printf '%s' "$3" | grep -Eq -- "$2"; then
    printf 'FAIL: %s: expected a match for /%s/, got [%s]\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

# assert_not_match <label> <regex> <text> — <text> must contain no match.
assert_not_match() {
  if printf '%s' "$3" | grep -Eq -- "$2"; then
    printf 'FAIL: %s: unexpected match for /%s/ in [%s]\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

# assert_file_exists <label> <path> — the file must exist and be a regular file.
assert_file_exists() {
  if [ ! -f "$2" ]; then
    printf 'FAIL: %s: missing file: %s\n' "$1" "$2" >&2
    return 1
  fi
}

# assert_file_not_exists <label> <path> — the path must not exist at all.
assert_file_not_exists() {
  if [ -e "$2" ]; then
    printf 'FAIL: %s: path exists: %s\n' "$1" "$2" >&2
    return 1
  fi
}

# assert_contains_file <label> <path> <regex> — the file must contain a match.
assert_contains_file() {
  if ! grep -Eq -- "$3" "$2" 2>/dev/null; then
    printf 'FAIL: %s: %s has no line matching /%s/\n' "$1" "$2" "$3" >&2
    return 1
  fi
}
