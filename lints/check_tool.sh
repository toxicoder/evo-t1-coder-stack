#!/usr/bin/env bash
#
# ## check_tool
#
# Host-tool probe for lint scripts. A missing tool skips locally and fails when
# CI=true or REQUIRE_LINT_TOOLS=1.

# @function check_tool
# Require a CLI on PATH, or skip/fail based on CI strictness.
# Globals:
#   CI, REQUIRE_LINT_TOOLS
# Arguments:
#   $1 - tool name
#   $2 - install hint
# Outputs:
#   Skip or error message
# Returns:
#   0 when present or when missing and not strict; exits 1 when strict
check_tool() {
  local tool="$1"
  local install_hint="${2:-install ${tool}}"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    if [[ ${CI:-} == "true" || ${REQUIRE_LINT_TOOLS:-} == "1" ]]; then
      echo "${tool} missing - required in CI (${install_hint})" >&2
      exit 1
    fi
    echo "${tool} missing - skipping (${install_hint})"
    exit 0
  fi
}

# @function bazel_checkout_root
# Echo the git checkout root, following Bazel runfiles symlinks.
# Globals:
#   BUILD_WORKSPACE_DIRECTORY
# Arguments:
#   None
# Outputs:
#   Absolute checkout path
# Returns:
#   0
bazel_checkout_root() {
  local real
  if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} && -d ${BUILD_WORKSPACE_DIRECTORY} ]]; then
    echo "${BUILD_WORKSPACE_DIRECTORY}"
    return 0
  fi
  real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  cd "$(dirname "${real}")/.." && pwd
}
