#!/usr/bin/env bash
# Purpose: shfmt -d on first-party shell.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check_tool.sh disable=SC1091
source "${SCRIPT_DIR}/check_tool.sh"
ROOT="$(bazel_checkout_root)"
check_tool shfmt "https://github.com/mvdan/sh"
cd "${ROOT}"

echo "Running shfmt -d..."
mapfile -d '' files < <(find scripts lints tests .github -name '*.sh' -type f \
  ! -path '*/tool_stubs/*' -print0)
files+=("${ROOT}/fix.sh")
shfmt -d -s -i 2 -ci "${files[@]}"
echo "shfmt check passed."
