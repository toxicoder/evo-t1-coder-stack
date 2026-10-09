#!/usr/bin/env bash
# Purpose: ShellCheck first-party shell at warning severity.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check_tool.sh disable=SC1091
source "${SCRIPT_DIR}/check_tool.sh"
ROOT="$(bazel_checkout_root)"
check_tool shellcheck "apt install shellcheck"
cd "${ROOT}"

echo "Running shellcheck..."
shellcheck --version
mapfile -d '' files < <(find scripts lints tests .github -name '*.sh' -type f \
  ! -path '*/tool_stubs/*' -print0)
files+=("${ROOT}/fix.sh")
shellcheck -x --severity=warning "${files[@]}"
echo "Shell lint step finished."
