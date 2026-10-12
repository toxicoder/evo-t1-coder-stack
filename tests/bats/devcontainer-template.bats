#!/usr/bin/env bats
#
# ## devcontainer-template.bats — guardrails for the devcontainer template's
# "which folder does the editor open on" seam.
#
# Pins the seam behind VS Code's "Workspace does not exist. Please select
# another workspace to open." dialog: the code-server module bakes its
# folder argument into the app URL (?folder=<urlencoded>), so that folder
# must resolve INSIDE the environment that hosts code-server —
# /workspaces/<repo-name> inside the dev container (the devcontainer CLI's
# default mount target), /srv/coder-devcontainers/<ws-id>/<repo-name> on the
# plain workspace container (the host bind), /home/coder when no repository
# was named. Also pins the empty-URL clone guard both startup.sh.tftpl
# twins keep, and the truthful wording of the no-devcontainer.json warning.
#
# Usage: bats tests/bats/devcontainer-template.bats
# Safety: reads templates/devcontainer/main.tf and the two startup.sh.tftpl
# twins; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
DC_TF=""
DC_STARTUP=""
WS_STARTUP=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  DC_TF="${REPO_ROOT}/templates/devcontainer/main.tf"
  DC_STARTUP="${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"
  WS_STARTUP="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  [[ -f "${DC_TF}" && -f "${DC_STARTUP}" && -f "${WS_STARTUP}" ]] ||
    skip "template payload is not reachable from ${REPO_ROOT}"
}

@test "editor: code-server's folder names the per-mode editor_folder local" {
  run grep -F 'folder    = local.editor_folder' "${DC_TF}"
  [ "${status}" -eq 0 ]
  # The one-path shape is what caused the dialog: with the dev-container
  # toggle on, code-server runs inside the dev container, where the host
  # /srv/coder-devcontainers/... spelling names no folder.
  run grep -F 'folder    = local.project_folder' "${DC_TF}"
  [ "${status}" -ne 0 ]
}

@test "editor: editor_folder spells the dev-container mount target and the no-repo fallback" {
  # One host-side path for every mode would open the editor on a folder
  # that exists nowhere the editor runs; the three branches below are the
  # per-hosting-environment spellings main.tf derives.
  run grep -F -- 'editor_folder = local.repo_set ? (local.use_dc ? "/workspaces/${local.repo_folder}" : local.project_folder) : "/home/coder"' "${DC_TF}"
  [ "${status}" -eq 0 ]
  # An empty repo_url clones nothing, so there is no clone folder to open;
  # this guard is what routes that case to /home/coder.
  run grep -F 'repo_set = trimspace(data.coder_parameter.repo_url.value) != ""' "${DC_TF}"
  [ "${status}" -eq 0 ]
}

@test "editor: bind source and Web Terminal keep the host-side folder spelling" {
  # workspace_folder is where the devcontainer CLI reads the clone's
  # .devcontainer/devcontainer.json from, and the Web Terminal's cd runs on
  # the workspace container — both live where the /srv spelling is the real
  # one, so they keep project_folder while the editor moved to
  # editor_folder.
  run grep -F 'workspace_folder = local.project_folder' "${DC_TF}"
  [ "${status}" -eq 0 ]
  run grep -F -- 'cd ${local.project_folder} 2>/dev/null' "${DC_TF}"
  [ "${status}" -eq 0 ]
}

@test "startup: both twins stay quiet on an empty repository field" {
  # An empty field names nothing to clone. The dev-container twin stays out
  # of the clone chain by choice; the workspace twin wraps the chain in the
  # positive form. Either spelling keeps `git clone -- "" <target>` (and the
  # probe that would build a dev container against an empty folder) from
  # running on every start.
  run grep -F 'if [ -z "$repo_url_raw" ]; then' "${DC_STARTUP}"
  [ "${status}" -eq 0 ]
  run grep -F 'if [ -n "$repo_url_raw" ]; then' "${WS_STARTUP}"
  [ "${status}" -eq 0 ]
}

@test "startup: the no-devcontainer warning promises no editor fallback" {
  # With the toggle on and no devcontainer.json, there is no sub-agent to
  # attach code-server to, so the old "fall back to the plain workspace
  # container" sentence described a fallback that does not exist.
  run grep -F 'fall back to the plain workspace container' "${DC_STARTUP}"
  [ "${status}" -ne 0 ]
}
