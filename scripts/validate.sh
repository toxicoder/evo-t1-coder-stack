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
  # shellcheck source=lib/common.sh disable=SC1091
  source "scripts/lib/common.sh"
  # This CLI has no --json mode: a leftover JSON_MODE would route every report
  # line to stderr and leave stdout empty.
  unset JSON_MODE
  section "Validate"
  if [[ ${VALIDATE_INNER:-} != "1" ]]; then
    bazel="$(command -v bazelisk 2>/dev/null || command -v bazel 2>/dev/null || true)"
    if [[ -n ${bazel} ]]; then
      phase "${bazel} test //:test-fast //:lint --test_tag_filters=manual"
      VALIDATE_INNER=1 "${bazel}" test //:test-fast --config=ci
      VALIDATE_INNER=1 "${bazel}" test //:lint --config=ci --test_tag_filters=manual
    else
      printf 'bazelisk is not on PATH\n' >&2
      return 1
    fi
  fi
  phase "docker compose config -q"
  docker compose config -q
  phase "cmp .env.sample .env.example"
  cmp .env.sample .env.example
  if command -v terraform >/dev/null 2>&1; then
    phase "terraform fmt -check"
    terraform -chdir=templates/workspace fmt -check
    terraform -chdir=templates/devcontainer fmt -check
  else
    phase "terraform not on PATH, skipping fmt -check"
  fi
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    phase "yaml parse"
    python3 scripts/lib/parse_yaml.py homepage/config/*.yaml litellm/config.yaml hermes/config.yaml
  else
    phase "PyYAML not installed, skipping yaml parse"
  fi
  log "validate: ok"
  ok "validate"
  summary
}

main "$@"
