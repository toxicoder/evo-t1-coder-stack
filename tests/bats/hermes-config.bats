#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## hermes-config.bats — guardrails for the Hermes host-assistant seed.
#
# Pins the seams the host-assistant feature rests on: approvals stay manual,
# the terminal backend stays local (so dangerous-command checks stay on),
# models go through LiteLLM's `agent` alias, the six git-tracked skills exist
# beside the seed with matching frontmatter, SOUL.md teaches both doors,
# compose interpolation defaults for dashboard
# basic-auth stay non-empty (v0.22.5 refuses 0.0.0.0 with no provider),
# HERMES_DASHBOARD_PUBLIC_URL comes from STACK_HERMES_URL, the seed trusts
# the router subnet, and proxy/router.conf vhosts the public hermes name.
# The live volume copy is out of scope; this suite reads the checkout
# payload, docker-compose.yml, and proxy/router.conf only.
#
# Usage: bazelisk test //tests:bats_hermes_config_test   (from any cwd)
# Safety: reads hermes/, docker-compose.yml, .env.sample, proxy/router.conf; writes nothing.

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

@test "hermes skills: every tracked skill exists with a matching name" {
  # The three stack skills plus the three host-operations skills that make the
  # assistant useful from a terminal: the mentor voice, the triage playbooks,
  # and the GitHub-to-running path.
  local skill path
  for skill in evo-stack-ops coder-workspace model-routing \
    host-linux-ops host-diagnostics deploy-from-github; do
    path="${REPO_ROOT}/hermes/skills/${skill}/SKILL.md"
    assert_file_exists "${skill}" "${path}"
    assert_contains_file "${skill} frontmatter name" "${path}" "^name: ${skill}\$"
  done
}

@test "hermes SOUL: names both doors, the deploy workspace, and the manual gate" {
  assert_contains_file "terminal door" "${SOUL}" 'scripts:hermes-shell'
  assert_contains_file "dashboard door" "${SOUL}" '9119'
  assert_contains_file "deploy workspace" "${SOUL}" 'STACK_DEPLOY_PATH'
  assert_contains_file "manual approvals stay" "${SOUL}" 'approvals\.mode. is .manual'
  assert_contains_file "one writer on /opt/data" "${SOUL}" 'second container'
}

@test "hermes compose: dashboard basic-auth interpolation defaults stay non-empty" {
  # An empty `${HERMES_DASHBOARD_PASSWORD:-}` interpolates to "" when .env
  # lacks the key; the bundled plugin then skips registration and the
  # gateway crash-loops on 0.0.0.0. Defaults must match .env.sample.
  local compose="${REPO_ROOT}/docker-compose.yml"
  local sample="${REPO_ROOT}/.env.sample"
  assert_file_exists "compose file" "${compose}"
  assert_file_exists "env sample" "${sample}"
  assert_contains_file "username fallback" "${compose}" \
    'HERMES_DASHBOARD_BASIC_AUTH_USERNAME: \$\{HERMES_DASHBOARD_USER:-admin\}'
  assert_contains_file "password fallback" "${compose}" \
    'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD: \$\{HERMES_DASHBOARD_PASSWORD:-change-me-hermes\}'
  assert_contains_file "secret fallback" "${compose}" \
    'HERMES_DASHBOARD_BASIC_AUTH_SECRET: \$\{HERMES_DASHBOARD_SECRET:-change-me-hermes-secret\}'
  assert_contains_file "sample password" "${sample}" \
    '^HERMES_DASHBOARD_PASSWORD=change-me-hermes$'
  assert_contains_file "sample secret" "${sample}" \
    '^HERMES_DASHBOARD_SECRET=change-me-hermes-secret$'
}

@test "hermes compose: public URL comes from STACK_HERMES_URL" {
  local compose="${REPO_ROOT}/docker-compose.yml"
  assert_file_exists "compose file" "${compose}"
  assert_contains_file "public url env" "${compose}" \
    'HERMES_DASHBOARD_PUBLIC_URL: \$\{STACK_HERMES_URL:-\}'
}

@test "hermes config: dashboard trusts the router subnet" {
  assert_contains_file "trusted proxies" "${CONFIG}" \
    'trusted_proxies: \["172\.16\.0\.0/12"\]'
}

@test "hermes router: public vhost proxies the dashboard" {
  local router="${REPO_ROOT}/proxy/router.conf"
  assert_file_exists "router conf" "${router}"
  assert_contains_file "hermes server name" "${router}" \
    'server_name hermes-gmktecbeast\.overeazy\.io'
  assert_contains_file "hermes upstream" "${router}" \
    'http://hermes:9119'
  assert_contains_file "forwarded host" "${router}" \
    'proxy_set_header X-Forwarded-Host'
}
