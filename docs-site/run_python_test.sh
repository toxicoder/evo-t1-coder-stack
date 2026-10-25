#!/usr/bin/env bash
#
# Runs the nav generator's unittest suite, which lives beside the docs-site sources as
# test_gen_nav.py.
#
# Called by `bazelisk test //docs-site:nav_test`, and by the `docs` job of
# .github/workflows/ci.yml as `bash run_python_test.sh` from docs-site/.
set -euo pipefail

if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} && -d "${BUILD_WORKSPACE_DIRECTORY}/docs-site" ]]; then
  cd "${BUILD_WORKSPACE_DIRECTORY}/docs-site"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$SCRIPT_DIR"
fi

# -p pins the run to this one suite; test_gen_nav.py adds scripts/ to sys.path for `import gen_nav`.
exec python3 -m unittest discover -s . -p test_gen_nav.py -t . -v
