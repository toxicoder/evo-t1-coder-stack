#!/usr/bin/env bats
#
# ## vscode-settings.bats — the shared code-server User settings seed.
#
# The desktop settings dump is adapted for this stack and checked in. The
# seed must stay free of desktop paths and secrets, both template copies must
# stay byte-identical, and both templates must copy it once onto the per-owner
# volume instead of merging it on every start.
#
# Usage: bats tests/bats/vscode-settings.bats
# Safety: reads the two template dirs; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

@test "settings: the two settings.json.tftpl copies are byte-identical" {
  local a="${REPO_ROOT}/templates/docker-dev/settings.json.tftpl"
  local b="${REPO_ROOT}/templates/docker-devcontainer/settings.json.tftpl"
  [[ -f "${a}" && -f "${b}" ]]
  cmp -s "${a}" "${b}"
}

@test "settings: the seed is JSON once Terraform escapes are unfolded" {
  local seed="${REPO_ROOT}/templates/docker-dev/settings.json.tftpl"
  # $${workspaceFolder} is how the tftpl emits a VS Code substitution.
  # ${litellm_url} is a real Terraform interpolation and stays as text here.
  local unfolded
  unfolded="$(sed 's/\$\${/${/g' "${seed}")"
  printf '%s' "${unfolded}" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "settings: no desktop paths, personal words, or API key in the seed" {
  local seed="${REPO_ROOT}/templates/docker-dev/settings.json.tftpl"
  local banned
  for banned in \
    '/Users/' \
    'homebrew' \
    'parallels' \
    'kilo-code' \
    'toxicoder' \
    '/home/vscode' \
    'continue.continue' \
    'app.kilo.ai' \
    'prlctl' \
    'litellm_key' \
    'profiles.osx' \
    'spark0'; do
    run grep -F "${banned}" "${seed}"
    [ "${status}" -ne 0 ] || { echo "banned string ${banned} is in the seed" >&2; return 1; }
  done
}

@test "settings: coder terminal profiles and the LiteLLM endpoint stay" {
  local seed="${REPO_ROOT}/templates/docker-dev/settings.json.tftpl"
  local need
  for need in \
    'grok-build-terminal' \
    'vscode-terminal-tmux' \
    '${litellm_url}' \
    '"terminal.integrated.defaultProfile.linux": "tmux"' \
    '"python.defaultInterpreterPath": "/usr/bin/python3"' \
    '"chat.disableAIFeatures": true' \
    '$${workspaceFolder}'; do
    run grep -F "${need}" "${seed}"
    [ "${status}" -eq 0 ] || { echo "missing ${need} in the seed" >&2; return 1; }
  done
}

@test "settings: both startups seed once and both mains mount the shared volume" {
  local startup main
  for startup in \
    "${REPO_ROOT}/templates/docker-dev/startup.sh.tftpl" \
    "${REPO_ROOT}/templates/docker-devcontainer/startup.sh.tftpl"; do
    run grep -F 'shared_settings="$HOME/.shared/vscode/settings.json"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'if [ ! -f "$shared_settings" ]; then' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'ln -sfn "$shared_settings" "$user_settings"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F '$${user_settings}.pre-shared' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F '$${LITELLM_API_KEY:-}' "${startup}"
    [ "${status}" -eq 0 ]
  done
  for main in \
    "${REPO_ROOT}/templates/docker-dev/main.tf" \
    "${REPO_ROOT}/templates/docker-devcontainer/main.tf"; do
    run grep -F 'vscode-settings-${data.coder_workspace_owner.me.id}' "${main}"
    [ "${status}" -eq 0 ]
    run grep -F 'container_path = "/home/coder/.shared/vscode"' "${main}"
    [ "${status}" -eq 0 ]
    run grep -F 'litellm_key = var.litellm_key' "${main}"
    [ "${status}" -ne 0 ]
  done
}

@test "settings: docker-dev does not hand the seed to the code-server module" {
  local main="${REPO_ROOT}/templates/docker-dev/main.tf"
  run grep -F 'settings         = jsondecode(local.vscode_settings)' "${main}"
  [ "${status}" -ne 0 ]
  run grep -F 'machine_settings' "${main}"
  [ "${status}" -ne 0 ]
}

@test "settings: devcontainer merges the seed only while the dev container is on" {
  local main="${REPO_ROOT}/templates/docker-devcontainer/main.tf"
  run grep -F 'local.use_dc ? jsonencode(local.vscode_module_settings) : "{}"' "${main}"
  [ "${status}" -eq 0 ]
  run grep -F 'machine_settings' "${main}"
  [ "${status}" -ne 0 ]
}
