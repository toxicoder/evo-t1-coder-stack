#!/usr/bin/env bash
# Purpose: buildifier -mode=check on Starlark.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check_tool.sh disable=SC1091
source "${SCRIPT_DIR}/check_tool.sh"
ROOT="$(bazel_checkout_root)"
check_tool buildifier "https://github.com/bazelbuild/buildtools"
cd "${ROOT}"

echo "Running buildifier -mode=check..."
mapfile -d '' files < <(find . -type f \
  \( -name 'BUILD' -o -name 'BUILD.bazel' -o -name 'MODULE.bazel' -o -name '*.bzl' \) \
  ! -path './bazel-*/*' ! -path './.git/*' -print0)
buildifier -mode=check "${files[@]}"
echo "buildifier check passed."
