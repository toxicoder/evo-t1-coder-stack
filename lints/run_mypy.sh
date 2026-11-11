#!/usr/bin/env bash
# Purpose: Type-check the first-party Python under the repo's strict mypy profile.
#
# The profile lives in mypy.ini at the repo root: --strict plus
# disallow_any_explicit and disallow_any_generics, which is this repo's strong-
# types rule for Python. A broad type is the thing the annotations exist to
# remove, so an explicit `Any` fails the gate the same way a missing one does.
#
# The binary comes from the golden dev image (images/dev/Dockerfile installs the
# MYPY_VERSION pin from images/dev/tool-versions.env), and check_tool keeps a
# developer machine without mypy running this as a skip rather than a failure,
# the way the shellcheck and shfmt runners do. Under CI=true or
# REQUIRE_LINT_TOOLS=1 a missing mypy is an error.
#
# The list below is the first-party Python this repo ships or gates on. It is
# kept equal, entry for entry, to the data edge on :mypy in lints/BUILD.bazel:
# a runner that scans a directory the target never declared passes in a normal
# checkout and loses its honesty under a sandboxed run. tests/bazel_deps.py
# re-derives nothing about this list, so the comment is the only thing holding
# the two together — change one side, change the other.
#
# docs-site/scripts/gen_nav.py and docs-site/test_gen_nav.py are named rather
# than globbed because scripts/ under docs-site also holds .mjs and .sh runners
# that are not Python and are covered by //docs-site:typecheck and //lints:shell.
# tests/bats/fixtures/ is excluded on purpose: those .py files are scaffold
# payload that gets copied into a brand-new repository and are typed and tested
# there, not here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check_tool.sh disable=SC1091
source "${SCRIPT_DIR}/check_tool.sh"
ROOT="$(bazel_checkout_root)"
check_tool mypy "uv tool install mypy (pin: MYPY_VERSION in images/dev/tool-versions.env)"
cd "${ROOT}"

echo "Running mypy..."
mypy --version
targets=(
  scripts/lib
  tests/bazel_deps.py
  tests/extract_fn.py
  tests/homepage_config_check.py
  tests/owned_files_check.py
  tests/coverage
  tests/python
  docs-site/scripts/gen_nav.py
  docs-site/test_gen_nav.py
)
# The cache goes outside the checkout: a gate that leaves a cache directory
# behind is one a developer then has to reason about when it is stale, and this
# tree is small enough that a cold run costs about a second.
mypy --config-file mypy.ini --cache-dir "${TMPDIR:-/tmp}/evo-t1-mypy-cache" "${targets[@]}"
echo "Python type lint step finished."
