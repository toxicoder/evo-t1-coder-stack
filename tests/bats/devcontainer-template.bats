#!/usr/bin/env bats
#
# ## devcontainer-template.bats — guardrails for the devcontainer template's
# "which folder does the editor open on" seam.
#
# Pins the seam behind VS Code's "Workspace does not exist. Please select
# another workspace to open." dialog: the inlined code-server fork bakes its
# folder argument into the app URL (?folder=<urlencoded>) and as a positional
# CLI argument with --ignore-last-opened, so that folder
# must resolve INSIDE the environment that hosts code-server —
# /workspaces/<repo-name> inside the dev container (the devcontainer CLI's
# default mount target), /srv/coder-devcontainers/<ws-id>/<repo-name> on the
# plain workspace container (the host bind), /home/coder when no repository
# was named. Also pins the empty-URL clone guard both startup.sh.tftpl
# twins keep, the truthful wording of the no-devcontainer.json warning, and the
# one common GROK_BUILD_AGENTS.md that the seed stage copies into place. It also
# pins the search lane: the gated [mcp_servers.searxng] block and the
# disable_web_search key exist identically in both grok-config.toml.tftpl
# twins, both main.tf twins feed search_mcp/search_url into that render and
# carry SEARXNG_URL into the agent environment, and both coder.tf twins
# declare the two template variables the pushes will pass. Both main.tf twins
# pin public Docker DNS upstreams on the workspace and DinD containers so
# github.com does not SERVFAIL through host MagicDNS.
#
# Usage: bats tests/bats/devcontainer-template.bats
# Safety: reads templates/devcontainer/main.tf, the two startup.sh.tftpl
# twins, the two grok-config.toml.tftpl twins, the two main.tf twins, the two
# coder.tf twins and templates/common/GROK_BUILD_AGENTS.md; writes nothing.

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

@test "editor: code-server's folder URL names the per-mode editor_folder local" {
  # The inlined code-server fork carries the folder as the ?folder=
  # query on the app URL (coder_app has no folder argument) and as a
  # positional CLI argument with --ignore-last-opened.
  run grep -F 'folder=${urlencode(local.editor_folder)}' "${DC_TF}"
  [ "${status}" -eq 0 ]
  run grep -F 'FOLDER="${local.editor_folder}"' "${DC_TF}"
  [ "${status}" -eq 0 ]
  run grep -F -- '--ignore-last-opened "$${FOLDER}"' "${DC_TF}"
  [ "${status}" -eq 0 ]
  # The one-path shape is what caused the dialog: with the dev-container
  # toggle on, code-server runs inside the dev container, where the host
  # /srv/coder-devcontainers/... spelling names no folder, so the URL must
  # never interpolate project_folder directly.
  run grep -F 'urlencode(local.project_folder)' "${DC_TF}"
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

@test "agents seed: the orchestration protocol travels from one common GROK_BUILD_AGENTS.md" {
  # The protocol text used to be an inline heredoc body in both startup
  # twins, then one identical copy per template dir. It now lives once, in
  # templates/common/, and push-template stages that copy into each
  # template's pushed tar - a template travels as its own tarball and the
  # server reads the payload from inside the pushed copy, so every copy must
  # carry it. Two failures are pinned here: the payload growing a second
  # line above its content (the seeded ~/.grok/AGENTS.md must start at
  # "# Role" - the managed-by marker stayed out on purpose), and either twin
  # losing the interpolation or the main.tf feed for it, which would leave
  # the seed stage writing an empty file.
  local common_md="${REPO_ROOT}/templates/common/GROK_BUILD_AGENTS.md"
  [ -f "${common_md}" ] ||
    skip "no common GROK_BUILD_AGENTS.md payload under ${REPO_ROOT}/templates/common"
  run head -n 1 "${common_md}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "# Role" ]
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -F '${grok_build_agents}' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'grok_build_agents = chomp(file("${path.module}/GROK_BUILD_AGENTS.md"))' "${tpl_dir}/main.tf"
    [ "${status}" -eq 0 ]
  done
}

@test "search lane: both config twins carry the gated searxng block and the off-key for native search" {
  # search_mcp (template default: true) gates the [mcp_servers.searxng] block,
  # and push-template.sh passes its --var array to BOTH pushes, so the block and
  # its gate have to exist in each twin; a twin that lost the gate would render
  # the server unconditionally or never, depending on the pushed default. The
  # literal greps pin the block shape (absolute binary path, threaded
  # SEARXNG_URL) and the position rule for disable_web_search: it is a
  # top-level key, so the file must emit it before the first [table] header or
  # the render is invalid TOML.
  local tpl dw ft
  for tpl in "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/grok-config.toml.tftpl"; do
    [[ -f "${tpl}" ]] || skip "config template not reachable from ${REPO_ROOT}"
    run grep -F '%{if search_mcp~}' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'command = "/opt/npm-global/bin/searxng-mcp-server"' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'env = { SEARXNG_URL = "${search_url}" }' "${tpl}"
    [ "${status}" -eq 0 ]
    dw="$(grep -n -m1 -F 'disable_web_search = true' "${tpl}" | cut -d: -f1)"
    ft="$(grep -n -m1 -e '^\[' "${tpl}" | cut -d: -f1)"
    [ -n "${dw}" ]
    [ -n "${ft}" ]
    [ "${dw}" -lt "${ft}" ]
  done
}

@test "search lane: the main.tf twins feed the gate and the probe agrees with the lane" {
  # search_mcp/search_url are render-map keys in both main.tf twins (the
  # boolean arrives as a real Terraform bool, so coder.tf has to declare it),
  # and searxng_url also travels into the coder agent env as SEARXNG_URL, so
  # search-check.sh (which reads $SEARXNG_URL first) probes the same port the
  # rendered [mcp_servers.searxng] block dials.
  local tf ctf
  for tf in "${REPO_ROOT}/templates/workspace/main.tf" "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    run grep -Eq 'search_mcp[[:space:]]+=[[:space:]]+var\.search_mcp' "${tf}"
    [ "${status}" -eq 0 ]
    run grep -Eq 'search_url[[:space:]]+=[[:space:]]+var\.searxng_url' "${tf}"
    [ "${status}" -eq 0 ]
    run grep -F 'SEARXNG_URL = var.searxng_url' "${tf}"
    [ "${status}" -eq 0 ]
  done
  for ctf in "${REPO_ROOT}/templates/workspace/coder.tf" "${REPO_ROOT}/templates/devcontainer/coder.tf"; do
    run grep -F 'variable "search_mcp"' "${ctf}"
    [ "${status}" -eq 0 ]
    run grep -F 'variable "searxng_url"' "${ctf}"
    [ "${status}" -eq 0 ]
  done
}

@test "dns: both templates pin public Docker DNS upstreams on workspace and dind containers" {
  # Host MagicDNS-only resolv.conf is what made terraform init inside coder
  # SERVFAIL registry.terraform.io; the same lookup fails github.com from a
  # workspace. Compose pins the pair on coder; the twins pin it on every
  # terraform-created container so a later git clone does not need a second
  # host DNS fix. MagicDNS is not a container nameserver.
  local tf n
  for tf in "${REPO_ROOT}/templates/workspace/main.tf" "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    [[ -f "${tf}" ]] || skip "template not reachable from ${REPO_ROOT}"
    run grep -F 'container_dns = ["1.1.1.1", "8.8.8.8"]' "${tf}"
    [ "${status}" -eq 0 ]
    n="$(grep -c -F 'dns = local.container_dns' "${tf}")"
    assert_eq "${tf} applies container_dns twice (dind + workspace)" "2" "${n}"
    run grep -F 'dns = ["100.100.100.100"' "${tf}"
    [ "${status}" -ne 0 ]
  done
}
