#!/usr/bin/env bash
#
# Bazel entry point for the nav generator's unittest suite, which lives beside the
# docs-site sources as test_gen_nav.py.
#
# Usage (from a bazel run): run_python_test.sh
set -euo pipefail

if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} && -d "${BUILD_WORKSPACE_DIRECTORY}/docs-site" ]]; then
  cd "${BUILD_WORKSPACE_DIRECTORY}/docs-site"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$SCRIPT_DIR"
fi

# discover keeps the package dir importable so the tests can `import gen_nav` etc.
# out of scripts/.
exec python3 -m unittest discover -s . -p test_gen_nav.py -t . -v
