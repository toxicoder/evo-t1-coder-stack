#!/usr/bin/env bats
#
# ## mypy-lint.bats — the Python type gate is wired, aimed, and unreachable by Any
#
# //lints:mypy is the Python half of this repo's strong-types rule, and like the
# other lint runners it is only as good as its wiring: a runner that is not a
# member of //lints:all never runs in CI, a target list that names a deleted file
# checks nothing and still exits 0, and a profile that quietly loses
# disallow_any_explicit turns the one rule this gate exists to hold back. These
# tests pin all four failure modes from the artefacts themselves rather than
# trusting the runner's own stdout, which is the same shape //lints:shell and
# //lints:shfmt are trusted not to have.
#
# The runner is a lint tool wrapper, so check_tool is what decides skip-versus-
# fail; pinning that it is sourced keeps a local machine without mypy green and a
# CI run without it red, which is the contract every sibling runner has.
#
# Usage: bazelisk test //tests:bats_mypy_lint_test   (from any cwd)
# Safety: reads the tree and runs mypy --version only; writes nothing outside the
# bats temp directory.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
RUNNER=""
LINTS_BUILD=""
MYPY_INI=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  RUNNER="${REPO_ROOT}/lints/run_mypy.sh"
  LINTS_BUILD="${REPO_ROOT}/lints/BUILD.bazel"
  MYPY_INI="${REPO_ROOT}/mypy.ini"
  [ -f "${RUNNER}" ]
}

# runner_targets — print the `targets` array entries, one per line, quotes out.
runner_targets() {
  awk '/^targets=\(/ { inside = 1; next }
       inside && /^\)/ { exit }
       inside && /^[[:space:]]*#/ { next }
       inside && NF { gsub(/^[[:space:]]*|["[:space:]]*$/, ""); print }' "${RUNNER}"
}

# ── the profile is the rule ─────────────────────────────────────────────────

@test "mypy.ini is the strict profile, named option by option" {
  assert_contains_file "untyped defs are refused" "${MYPY_INI}" 'disallow_untyped_defs = True'
  assert_contains_file "half-annotated defs are refused" "${MYPY_INI}" 'disallow_incomplete_defs = True'
  assert_contains_file "untyped calls are refused" "${MYPY_INI}" 'disallow_untyped_calls = True'
  assert_contains_file "bodies of unannotated functions are checked" "${MYPY_INI}" 'check_untyped_defs = True'
  assert_contains_file "a returned Any is a warning" "${MYPY_INI}" 'warn_return_any = True'
  assert_contains_file "a stale ignore is an error" "${MYPY_INI}" 'warn_unused_ignores = True'
  assert_contains_file "an implicit Optional is an error" "${MYPY_INI}" 'no_implicit_optional = True'
}

@test "mypy.ini refuses the broad type in both directions" {
  # The two options this repo adds on top of --strict. They are the whole point of
  # the gate, so a change here is a change to the rule and must be deliberate.
  assert_contains_file "an explicit Any is an error" "${MYPY_INI}" 'disallow_any_explicit = True'
  assert_contains_file "a bare generic is an error" "${MYPY_INI}" 'disallow_any_generics = True'
}

@test "mypy.ini relaxes nothing wholesale" {
  # A follow-up that wants an exemption takes it per module, the way the [mypy-yaml.*]
  # section does. An unscoped disable would erase the rule for every file.
  run grep -E '^[[:space:]]*disable_error_code[[:space:]]*=' "${MYPY_INI}"
  [ "${status}" -ne 0 ]
  run grep -E '^[[:space:]]*(disallow_untyped_defs|disallow_any_explicit|check_untyped_defs)[[:space:]]*=[[:space:]]*False' "${MYPY_INI}"
  [ "${status}" -ne 0 ]
}

# ── the gate is reachable from CI ───────────────────────────────────────────

@test "lints:all lists :mypy so //:lint and //:test-all reach it" {
  # :all is the single place a lint runner joins //:lint, //:test-all, and the
  # `--test_tag_filters=manual` run in the bazel job of ci.yml.
  local block
  block="$(awk '/^test_suite\(/ { buf = "" } { buf = buf $0 ORS } /name = "all"/ { found = 1 } /^\)/ { if (found) { printf "%s", buf; exit } }' "${LINTS_BUILD}")"
  assert_contains_file ":all lists :mypy" "${LINTS_BUILD}" '":mypy",'
  [ -n "${block}" ]
}

@test "the :mypy target carries the runner, the profile, and the Python it checks" {
  assert_contains_file "the runner is the source" "${LINTS_BUILD}" 'src = "run_mypy.sh"'
  assert_contains_file "the profile is in runfiles" "${LINTS_BUILD}" '//:mypy_config'
  assert_contains_file "the scripts Python is in runfiles" "${LINTS_BUILD}" '//scripts:py_programs'
  assert_contains_file "the tests Python is in runfiles" "${LINTS_BUILD}" '//tests:python_sources'
  assert_contains_file "the docs-site Python is in runfiles" "${LINTS_BUILD}" '//docs-site:python_sources'
}

@test "the :mypy target is tagged like its siblings so the manual filter keeps it" {
  assert_contains_file "lint tag" "${LINTS_BUILD}" '"lint",'
  assert_contains_file "manual tag" "${LINTS_BUILD}" '"manual",'
  assert_contains_file "no-sandbox tag" "${LINTS_BUILD}" '"no-sandbox",'
  # The tool-name tag is what --test_tag_filters= can select a single runner by.
  assert_contains_file "the runner is selectable by tool name" "${LINTS_BUILD}" '"mypy",'
}

@test "run_mypy.sh is declared to the shell linters that scan lints/" {
  # run_shellcheck.sh and run_shfmt.sh find every .sh under lints/, so a runner
  # missing from _LINT_SHELL_SOURCES is linted in a normal checkout and skipped
  # under a sandboxed run.
  assert_contains_file "the runner joins the lint source list" "${LINTS_BUILD}" '"run_mypy.sh",'
}

@test "the runner probes for its host tool the way its siblings do" {
  assert_contains_file "it sources the tool probe" "${RUNNER}" 'source .*check_tool\.sh'
  assert_contains_file "it requires mypy through check_tool" "${RUNNER}" 'check_tool mypy'
  assert_contains_file "it resolves the checkout root itself" "${RUNNER}" 'bazel_checkout_root'
  assert_contains_file "it reads the repo profile, not a flag soup" "${RUNNER}" '--config-file mypy.ini'
}

# ── the target list aims at real, complete coverage ─────────────────────────

@test "every target the runner names exists in the tree" {
  # The failure this pins: a file renamed, the array left alone, and a gate that
  # still prints its closing line and exits 0 over nothing.
  local t
  local -a found=()
  while IFS= read -r t; do
    [ -n "${t}" ] || continue
    [ -e "${REPO_ROOT}/${t}" ] || { printf 'FAIL: runner target %s does not exist\n' "${t}" >&2; return 1; }
    found+=("${t}")
  done < <(runner_targets)
  [ "${#found[@]}" -ge 6 ]
}

@test "the runner covers every first-party Python file and claims no stray one" {
  # Completeness, the other direction: a new .py that lands outside the runner's
  # list is unchecked Python that looks gated. tests/bats/fixtures is the one
  # sanctioned exclusion - that tree is scaffold payload typed in the repository
  # it is copied into.
  local f rel
  local -a strays=()
  while IFS= read -r f; do
    rel="${f#"${REPO_ROOT}"/}"
    case "${rel}" in
      scripts/lib/*.py|tests/bazel_deps.py|tests/extract_fn.py|tests/coverage/*.py|tests/python/*.py|docs-site/scripts/gen_nav.py|docs-site/test_gen_nav.py) ;;
      *) strays+=("${rel}") ;;
    esac
  done < <(find "${REPO_ROOT}/scripts" "${REPO_ROOT}/tests" "${REPO_ROOT}/docs-site" \
              -name '*.py' -type f ! -path '*/tests/bats/*' ! -path '*/__pycache__/*' 2>/dev/null | sort)
  if [ "${#strays[@]}" -gt 0 ]; then
    printf 'FAIL: Python outside the //lints:mypy target list: %s\n' "${strays[*]}" >&2
    return 1
  fi
}

@test "the runner's array matches what //lints:mypy ships in runfiles" {
  # The BUILD comment says the list and the data edge are kept equal; this makes
  # the claim checkable instead of aspirational. Each array entry has to live
  # under one of the four declared groups.
  local t covered
  while IFS= read -r t; do
    [ -n "${t}" ] || continue
    covered=0
    case "${t}" in
      scripts/*) [ -d "${REPO_ROOT}/scripts/lib" ] && covered=1 ;;
      tests/*) covered=1 ;;
      docs-site/*) covered=1 ;;
    esac
    [ "${covered}" -eq 1 ] || { printf 'FAIL: target %s is under no declared data group\n' "${t}" >&2; return 1; }
  done < <(runner_targets)
}

# ── the rule holds on the code, not just the config ─────────────────────────

@test "no first-party Python under the gate reaches for Any" {
  # mypy already refuses this; the grep is the second, independent look that keeps
  # the rule true even if the profile is edited. `Any` in a comment or a docstring
  # explaining the rule is fine, so only import and annotation positions count.
  run grep -rnE '(^|[^A-Za-z0-9_.])(from typing import[^#]*\bAny\b|import[^#]*\bAny\b|:[[:space:]]*Any\b|->[[:space:]]*Any\b|cast\([[:space:]]*Any\b)' \
    "${REPO_ROOT}/scripts/lib" \
    "${REPO_ROOT}/tests/bazel_deps.py" \
    "${REPO_ROOT}/tests/extract_fn.py" \
    "${REPO_ROOT}/tests/coverage" \
    "${REPO_ROOT}/tests/python" \
    "${REPO_ROOT}/docs-site/scripts/gen_nav.py" \
    "${REPO_ROOT}/docs-site/test_gen_nav.py" \
    --include='*.py'
  [ "${status}" -ne 0 ]
}

@test "mypy is either installed or the gate says so and skips" {
  if ! command -v mypy >/dev/null 2>&1; then
    skip "mypy is not on PATH; check_tool makes that a skip locally and a failure under CI=true"
  fi
  run mypy --version
  [ "${status}" -eq 0 ]
}
