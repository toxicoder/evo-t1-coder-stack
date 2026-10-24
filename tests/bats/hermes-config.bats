#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## hermes-config.bats — guardrails for the Hermes host-assistant seed.
#
# Pins the seams the host-assistant feature rests on: approvals stay manual,
# the terminal backend stays local (so dangerous-command checks stay on),
# models go through LiteLLM's `agent` alias, and the three git-tracked skills
# exist beside the seed. The live volume copy is out of scope; this suite
# reads the checkout payload only.
#
# Usage: bazelisk test //tests:bats_hermes_config_test   (from any cwd)
# Safety: reads hermes/; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CONFIG=""
SOUL=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CONFIG="${REPO_ROOT}/hermes/config.yaml"
  SOUL="${REPO_ROOT}/hermes/SOUL.md"
  [[ -f "${CONFIG}" ]] || skip "hermes/config.yaml is not reachable from ${REPO_ROOT}"
}

@test "hermes config: approvals stay manual and cron/unattended stay deny" {
  assert_contains_file "manual mode" "${CONFIG}" 'mode: manual'
  assert_contains_file "cron deny" "${CONFIG}" 'cron_mode: deny'
  assert_contains_file "unattended deny" "${CONFIG}" 'unattended_mode: deny'
  run grep -E '^[[:space:]]*mode:[[:space:]]*off' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "hermes config: terminal backend stays local" {
  assert_contains_file "local backend" "${CONFIG}" 'backend: local'
  run grep -E '^[[:space:]]*backend:[[:space:]]*docker' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "hermes config: models go through LiteLLM agent alias" {
  assert_contains_file "custom provider" "${CONFIG}" 'provider: custom'
  assert_contains_file "agent alias" "${CONFIG}" 'model: agent'
  assert_contains_file "litellm base_url" "${CONFIG}" 'base_url: http://litellm:4000/v1'
  assert_contains_file "env-expanded key" "${CONFIG}" 'api_key: \$\{LITELLM_MASTER_KEY\}'
}

@test "hermes config: cwd follows STACK_HOST_PATH and skills stay external" {
  assert_contains_file "cwd from env" "${CONFIG}" 'cwd: \$\{STACK_HOST_PATH\}'
  assert_contains_file "skills mount" "${CONFIG}" '/opt/stack-skills'
}

@test "hermes config: stack marker and SOUL.md are present" {
  assert_contains_file "config marker" "${CONFIG}" 'managed-by: evo-t1-coder-stack'
  assert_file_exists "SOUL.md" "${SOUL}"
  assert_contains_file "SOUL marker" "${SOUL}" 'managed-by: evo-t1-coder-stack'
}

@test "hermes skills: three tracked skills exist" {
  assert_file_exists "evo-stack-ops" "${REPO_ROOT}/hermes/skills/evo-stack-ops/SKILL.md"
  assert_file_exists "coder-workspace" "${REPO_ROOT}/hermes/skills/coder-workspace/SKILL.md"
  assert_file_exists "model-routing" "${REPO_ROOT}/hermes/skills/model-routing/SKILL.md"
}
