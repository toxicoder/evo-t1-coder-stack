#!/usr/bin/env bash
#
# ## validate
#
# Git-unaware local gate: Bazel test-fast, lint, then the compose and template
# checks from CONTRIBUTING. Nested Bazel is skipped when VALIDATE_INNER=1 so a
# `bazelisk run //:validate` does not recurse. The template checks include the
# Terraform variable-type gate (scripts/lib/tf_types.awk), which holds both
# twins to a declared `type` on every `variable` block and refuses the broad
# `any` — see docs/contribute/strong-types.md.
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
  # The variable-type gate runs whether or not terraform is installed: it reads
  # HCL text, and a template that lost a `type` constraint is a plan-time bug
  # waiting for someone to pass the wrong -var, which is exactly what fmt cannot
  # see. scripts/lib/tf_types.awk prints one finding per line and nothing when
  # both twins conform, so an empty result is the pass condition.
  phase "terraform variable types"
  local tf_findings
  tf_findings="$(awk -f "${root}/scripts/lib/tf_types.awk" \
    templates/workspace/main.tf templates/workspace/coder.tf \
    templates/devcontainer/main.tf templates/devcontainer/coder.tf)"
  if [[ -n ${tf_findings} ]]; then
    while IFS=$'\t' read -r tf_file tf_line tf_rule tf_detail; do
      err "${tf_file}:${tf_line}: ${tf_rule}: ${tf_detail}"
    done <<<"${tf_findings}"
    return 1
  fi
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    # searxng/settings.yml belongs in this list: it is bind-mounted read-only
    # into the container, where a YAML error is a service that will not start,
    # and nothing else here parsed it. The three that were already listed fail
    # loudly in the same way.
    phase "yaml parse"
    python3 scripts/lib/parse_yaml.py homepage/config/*.yaml litellm/config.yaml hermes/config.yaml searxng/settings.yml
  else
    phase "PyYAML not installed, skipping yaml parse"
  fi
  log "validate: ok"
  ok "validate"
  summary
}

main "$@"
