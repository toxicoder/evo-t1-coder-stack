#!/usr/bin/env bash
#
# ## fix
#
# Run trusted formatters (buildifier + shfmt).
#
# Usage:
#   bazelisk run //:fix
#   ./fix.sh
#
# @function main
# Format BUILD files and shell sources.
# Globals:
#   BUILD_WORKSPACE_DIRECTORY
# Arguments:
#   None
# Outputs:
#   Formatter progress on stdout
# Returns:
#   0
main() {
  local root
  root="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  cd "${root}" || exit 1
  echo "-> Running trusted formatters (//:fix)"
  if command -v buildifier >/dev/null 2>&1; then
    echo "   buildifier -mode=fix"
    find . -type f \( -name 'BUILD' -o -name 'BUILD.bazel' -o -name 'MODULE.bazel' -o -name '*.bzl' \) \
      ! -path '*/bazel-*/*' ! -path './.git/*' \
      -exec buildifier -mode=fix {} +
  else
    echo "   (buildifier not in PATH - skipping)"
  fi
  if command -v shfmt >/dev/null 2>&1; then
    echo "   shfmt -w -s -i 2 -ci"
    find scripts lints tests .github -name '*.sh' -type f \
      ! -path '*/tool_stubs/*' ! -path '*/bazel-*/*' \
      -exec shfmt -w -s -i 2 -ci {} +
    shfmt -w -s -i 2 -ci fix.sh
  else
    echo "   (shfmt not in PATH - skipping)"
  fi
  echo "fix complete (run 'bazelisk test //:lint --test_tag_filters=manual' for checks)"
}

main "$@"
