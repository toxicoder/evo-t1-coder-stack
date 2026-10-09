#!/usr/bin/env bash
#
# ## validate
#
# Git-unaware local gate: Bazel test-fast, lint, then the compose and template
# checks from CONTRIBUTING. Nested Bazel is skipped when VALIDATE_INNER=1 so a
# `bazelisk run //:validate` does not recurse.
#
# Usage:
#   bazelisk run //:validate
#   ./scripts/validate.sh

set -euo pipefail

# @function main
# Run the test, lint, and config checks.
# Globals:
#   BUILD_WORKSPACE_DIRECTORY, VALIDATE_INNER, CI
# Arguments:
#   None
# Outputs:
#   Check progress on stdout
# Returns:
#   0 when every check passes
main() {
  local root bazel
  root="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  cd "${root}"
  if [[ ${VALIDATE_INNER:-} != "1" ]]; then
    bazel="$(command -v bazelisk 2>/dev/null || command -v bazel 2>/dev/null || true)"
    if [[ -n ${bazel} ]]; then
      echo "-> ${bazel} test //:test-fast //:lint --test_tag_filters=manual"
      VALIDATE_INNER=1 "${bazel}" test //:test-fast --config=ci
      VALIDATE_INNER=1 "${bazel}" test //:lint --config=ci --test_tag_filters=manual
    else
      echo "bazelisk is not on PATH" >&2
      return 1
    fi
  fi
  echo "-> docker compose config -q"
  docker compose config -q
  echo "-> cmp .env.sample .env.example"
  cmp .env.sample .env.example
  if command -v terraform >/dev/null 2>&1; then
    echo "-> terraform fmt -check"
    terraform -chdir=templates/docker-dev fmt -check
    terraform -chdir=templates/docker-devcontainer fmt -check
  else
    echo "-> terraform not on PATH, skipping fmt -check"
  fi
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "-> yaml parse"
    python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('homepage/config/*.yaml')+['litellm/config.yaml']]"
  else
    echo "-> PyYAML not installed, skipping yaml parse"
  fi
  echo "validate: ok"
}

main "$@"
