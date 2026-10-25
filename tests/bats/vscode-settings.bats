#!/usr/bin/env bats
#
# ## vscode-settings.bats — the shared code-server User settings seed.
#
# The desktop settings dump is adapted for this stack and checked in. The
# seed must stay free of desktop paths and secrets, both template copies must
# stay byte-identical, and the startup twins each copy it once onto the
# per-owner volume, while the dev-container template's code-server fork
# merges it into the dev container's private copy only while the toggle is on.
#
# Usage: bazelisk test //tests:bats_vscode_settings_test   (from any cwd)
# Safety: reads the two template dirs; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

@test "settings: the two settings.json.tftpl copies are byte-identical" {
  local a="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  local b="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  [[ -f "${a}" && -f "${b}" ]]
  cmp -s "${a}" "${b}"
}

@test "settings: the seed is JSON once Terraform escapes are unfolded" {
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  # $${workspaceFolder} is how the tftpl emits a VS Code substitution.
  # ${litellm_url} is a real Terraform interpolation and stays as text here.
  local unfolded
  unfolded="$(sed 's/\$\${/${/g' "${seed}")"
  printf '%s' "${unfolded}" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "settings: no desktop paths, personal words, or API key in the seed" {
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
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
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
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

@test "settings: the model list names every alias the Grok config catalogues" {
  # The editor's model picker reads this array; it has to carry the Spark lane
  # and its three baked-thinking aliases alongside the Arc fallbacks, or the
  # extensions offer aliases the rendered ~/.grok/config.toml does not define.
  # `high` stays out of every spelling: Qwen3.8-Flash-Next does not answer it.
  local a b need unfolded models
  a="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  b="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  for need in \
    '"agent"' '"agent-low"' '"agent-medium"' '"agent-xhigh"' \
    '"coder"' '"coder-fast"' '"chat"'; do
    run grep -F "${need}" "${a}"
    [ "${status}" -eq 0 ] || { echo "missing ${need} in ${a}" >&2; return 1; }
  done
  run grep -F '"agent-high"' "${a}"
  [ "${status}" -ne 0 ] || { echo "agent-high is not a level this runtime answers" >&2; return 1; }
  # Same array, both copies, in the pinned order.
  unfolded="$(sed 's/\$\${/${/g' "${a}")"
  models="$(printf '%s' "${unfolded}" | python3 -c \
    'import json,sys; print(" ".join(json.load(sys.stdin)["__evoT1StackModels"]))')"
  assert_eq "the seed lists every stack alias" \
    "agent agent-low agent-medium agent-xhigh coder coder-fast chat" "${models}"
  cmp -s "${a}" "${b}"
  # The keys that make the editor open on the folder the script pins: no
  # restored window, no startup editor.
  for need in '"window.restoreWindows": "none"' '"workbench.startupEditor": "none"'; do
    run grep -F "${need}" "${a}"
    [ "${status}" -eq 0 ] || { echo "missing ${need} in the seed" >&2; return 1; }
  done
}

@test "settings: both startups seed once and both mains mount the shared volume" {
  local startup main
  for startup in \
    "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"; do
    run grep -F 'shared_settings="$HOME/.shared/vscode/settings.json"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'if [ ! -f "$shared_settings" ]; then' "${startup}"
    [ "${status}" -eq 0 ]
    # Empty named volumes are root:root 755; chown before the first write, and
    # do not run jq/python against a file the cat never created.
    run grep -F '$SUDO chown -R "$home_owner" "$HOME/.shared" "$HOME/.grok"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'if cat >"$shared_settings"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'the vscode-settings volume is not writable' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'ln -sfn "$shared_settings" "$user_settings"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F '$${user_settings}.pre-shared' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F '$${LITELLM_API_KEY:-}' "${startup}"
    [ "${status}" -eq 0 ]
  done
  for main in \
    "${REPO_ROOT}/templates/workspace/main.tf" \
    "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    run grep -F 'vscode-settings-${data.coder_workspace_owner.me.id}' "${main}"
    [ "${status}" -eq 0 ]
    run grep -F 'container_path = "/home/coder/.shared/vscode"' "${main}"
    [ "${status}" -eq 0 ]
    run grep -F 'litellm_key = var.litellm_key' "${main}"
    [ "${status}" -ne 0 ]
  done
}

@test "settings: workspace template does not hand the seed to the inlined code-server fork" {
  local main="${REPO_ROOT}/templates/workspace/main.tf"
  # The fork carries a seed (if any) in its script's SETTINGS_B64 line;
  # the workspace fork has none, because the startup script's shared-volume
  # symlink owns settings.json there.
  run grep -F 'SETTINGS_B64' "${main}"
  [ "${status}" -ne 0 ]
  run grep -F 'machine_settings' "${main}"
  [ "${status}" -ne 0 ]
}

@test "settings: devcontainer merges the seed only while the dev container is on" {
  local main="${REPO_ROOT}/templates/devcontainer/main.tf"
  local cs="${REPO_ROOT}/templates/devcontainer/code-server.sh.tftpl"
  # The seed rides in templatefile's settings_b64, empty (so the shell
  # skips the whole seed/merge block) when the toggle is off.
  run grep -F 'settings_b64' "${main}"
  [ "${status}" -eq 0 ]
  run grep -F 'base64encode(jsonencode(local.vscode_module_settings))' "${main}"
  [ "${status}" -eq 0 ]
  run grep -F "SETTINGS_B64='\${settings_b64}'" "${cs}"
  [ "${status}" -eq 0 ]
  run grep -F 'machine_settings' "${main}"
  [ "${status}" -ne 0 ]
}
