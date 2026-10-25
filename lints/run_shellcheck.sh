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
# templates/common holds the payloads the templates inline and source, so it is
# first-party shell too. It joins the scan only when present: these targets run
# against a lint target's runfiles, which carry scripts/ and lints/ only.
scan_dirs=(scripts lints tests .github)
if [ -d templates/common ]; then
  scan_dirs+=(templates/common)
else
  echo "templates/common not in this run's data - payload not scanned"
fi
files=()
while IFS= read -r -d '' file; do
  files+=("${file}")
done < <(find "${scan_dirs[@]}" -name '*.sh' -type f \
  ! -path '*/tool_stubs/*' -print0)
files+=("${ROOT}/fix.sh")
shellcheck -x --severity=warning "${files[@]}"
echo "Shell lint step finished."
