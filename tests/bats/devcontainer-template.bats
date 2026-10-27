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
# one common GROK_BUILD_AGENTS.md that the seed stage copies into place (line 1
# is still "# Role"; the managed-by marker sits on line 2 so a stack-owned copy
# reseeds), and the research lanes the seed and the config agree on: native
# web_search is parked by a top-level disable_web_search key set to true above
# the first table in both grok-config.toml.tftpl twins (no transport on this box
# serves that tool type), which leaves the gated [mcp_servers.searxng] block as
# the search lane, and the seed names that lane (searxng, $SEARXNG_URL,
# http://host.docker.internal:8181) next to context7 and the child digest
# contract. It also pins that both main.tf twins feed search_mcp/search_url
# into that render and carry SEARXNG_URL into the agent environment, and that
# both coder.tf twins declare the two template variables the pushes will pass. It
# also pins the context7 and github lanes: both gated MCP blocks exist
# identically in both grok-config.toml.tftpl twins, both coder.tf twins
# default github_mcp/search_mcp/context7_mcp to true, both main.tf twins feed
# context7_mcp/context7_api_key into that render and into the agent
# environment, and both startup.sh.tftpl twins seed the proxy config from an
# npx-free heredoc.
# Both main.tf twins pin public Docker DNS upstreams on the workspace and DinD
# containers so github.com does not SERVFAIL through host MagicDNS. It also
# pins the editor's agent_id: concat+splat of coder_devcontainer.repo so the
# ungated coder_app does not index [0] of an empty tuple during the stop plan.
# It also pins the two startup stages that make the default MCP lanes
# verifiable: the advisory probe that reads the RENDERED ~/.grok/config.toml,
# prints one warning per command= path the running golden image does not carry,
# and can never abort the boot, and the else-path note that tells a workspace
# left with an unmanaged config what it lost and how to get it back. Both twins
# have to carry both as identical text.
#
# Usage: bazelisk test //tests:bats_devcontainer_template_test   (from any cwd)
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
  run grep -F 'code-server.sh.tftpl' "${DC_TF}"
  [ "${status}" -eq 0 ]
  local cs="${REPO_ROOT}/templates/devcontainer/code-server.sh.tftpl"
  [ -f "${cs}" ]
  run grep -F 'FOLDER="${editor_folder}"' "${cs}"
  [ "${status}" -eq 0 ]
  run grep -F -- '--ignore-last-opened "$${FOLDER}"' "${cs}"
  [ "${status}" -eq 0 ]
  # The clone runs in the startup script while this script starts beside it, so
  # the folder is created first and the launch waits (at most 60 s) for the
  # clone's .git: a folder code-server cannot stat gets VS Code's "Workspace
  # does not exist" dialog instead of the repository. /home/coder stays exempt.
  run grep -F 'mkdir -p -- "$${FOLDER}"' "${cs}"
  [ "${status}" -eq 0 ]
  run grep -F 'if [ "$${FOLDER}" != "/home/coder" ]; then' "${cs}"
  [ "${status}" -eq 0 ]
  run grep -F 'while [ ! -e "$${FOLDER}/.git" ] && [ "$${waited}" -lt 60 ]; do' "${cs}"
  [ "${status}" -eq 0 ]
  # templatefile interpolates ${...}; $$(( is two dollars and bash -c expands
  # $$ to the PID. The increment has to be written with one dollar.
  run grep -F 'waited=$((waited + 1))' "${cs}"
  [ "${status}" -eq 0 ]
  run grep -F 'waited=$$((waited + 1))' "${cs}"
  [ "${status}" -ne 0 ]
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

@test "editor: code-server agent_id uses concat+splat instead of indexing repo[0] off use_dc" {
  # coder_devcontainer.repo is count-gated on use_dc AND start_count. Template
  # import's ephemeral (stop) plan is start_count=0, so the tuple is empty even
  # when use_dc is true (the default). Apps stay ungated (coder/preview plus
  # the stopped page), and a use_dc ? repo[0].subagent_id ternary then fails
  # with "Invalid index ... empty tuple". concat of the splat never indexes
  # an empty collection: the sub-agent wins when it exists, the parent agent
  # holds the button otherwise. Both the ungated app and the start_count-gated
  # script share that local so a later copy cannot reintroduce the ternary.
  run grep -F -- 'code_server_agent_id = concat(coder_devcontainer.repo[*].subagent_id, [coder_agent.main.id])[0]' "${DC_TF}"
  [ "${status}" -eq 0 ]
  n="$(grep -c -E 'agent_id[[:space:]]+=[[:space:]]+local\.code_server_agent_id' "${DC_TF}")"
  assert_eq "${DC_TF} wires code_server_agent_id on the script and the app" "2" "${n}"
  run grep -F 'coder_devcontainer.repo[0].subagent_id' "${DC_TF}"
  [ "${status}" -ne 0 ]
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
  # carry it. Two failures are pinned here: a line growing above "# Role"
  # (Grok reads that heading as the role), and either twin losing the
  # interpolation or the main.tf feed for it, which would leave the seed
  # stage writing an empty file. The managed-by marker sits on line 2 so
  # refresh-configs and the startup reseed can rewrite a stack-owned copy
  # without putting HTML above the heading. A marker-free hand edit is
  # left alone.
  local common_md="${REPO_ROOT}/templates/common/GROK_BUILD_AGENTS.md"
  [ -f "${common_md}" ] ||
    skip "no common GROK_BUILD_AGENTS.md payload under ${REPO_ROOT}/templates/common"
  run head -n 2 "${common_md}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "# Role" ]
  [ "${lines[1]}" = "<!-- managed-by: evo-t1-coder-stack -->" ]
  # The seed must not send the agent at the native tool any more: no transport
  # on this box serves a web_search-typed tool, so that instruction cost every
  # research question a wasted failing turn. "# Research lanes" (pinned in its
  # own test below) is what replaced it.
  run grep -F 'Use `web_search`' "${common_md}"
  [ "${status}" -ne 0 ]
  run grep -F 'search_tool' "${common_md}"
  [ "${status}" -eq 0 ]
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -F '${grok_build_agents}' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'if [ ! -f "$HOME/.grok/AGENTS.md" ]' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F '"$HOME/.grok/AGENTS.md"; then' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'grok_build_agents = chomp(file("${path.module}/GROK_BUILD_AGENTS.md"))' "${tpl_dir}/main.tf"
    [ "${status}" -eq 0 ]
    # Same single-copy rule for the per-repo notes library: a twin that lost
    # this feed fails the push outright, because templatefile() rejects the
    # now-undefined ${notes_setup} interpolation while rendering the script.
    run grep -F 'notes_setup = file("${path.module}/notes-setup.sh")' "${tpl_dir}/main.tf"
    [ "${status}" -eq 0 ]
  done
}

@test "search lane: both config twins carry the gated searxng block and the parked native-search key" {
  # search_mcp (template default: true) gates the [mcp_servers.searxng] block,
  # and push-template.sh passes its --var array to BOTH pushes, so the block and
  # its gate have to exist in each twin; a twin that lost the gate would render
  # the server unconditionally or never, depending on the pushed default. The
  # literal greps pin the block shape (absolute binary path, threaded
  # SEARXNG_URL) and the position rule for disable_web_search: native search is
  # PARKED because no transport in front of these boxes serves the tool type
  # (LiteLLM answers "tools of type 'web_search' are not supported"), so the key
  # is a top-level true, and a top-level key must land before the first [table]
  # header or the render is invalid TOML. With it parked, the comment the greps
  # below pin is what names searxng as the lane rather than a fallback, and the
  # two absence checks keep the twin from claiming native search is on again.
  local tpl dw ft
  for tpl in "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/grok-config.toml.tftpl"; do
    [[ -f "${tpl}" ]] || skip "config template not reachable from ${REPO_ROOT}"
    run grep -F '%{if search_mcp~}' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'command = "/opt/npm-global/bin/searxng-mcp-server"' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -A 4 -F '[mcp_servers.searxng]' "${tpl}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"enabled = true"* ]]
    run grep -F 'env = { SEARXNG_URL = "${search_url}" }' "${tpl}"
    [ "${status}" -eq 0 ]
    # -x anchors the key at column 0, so a comment that merely mentions the key
    # (the [models] note does) cannot satisfy the position rule on its own.
    dw="$(grep -n -m1 -Fx 'disable_web_search = true' "${tpl}" | cut -d: -f1)"
    ft="$(grep -n -m1 -e '^\[' "${tpl}" | cut -d: -f1)"
    [ -n "${dw}" ]
    [ -n "${ft}" ]
    [ "${dw}" -lt "${ft}" ]
    # The searxng block is the lane; the old copy called it a fallback and
    # called native search the lane already in use.
    run grep -F 'This is the search lane: native' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'Native search is already on' "${tpl}"
    [ "${status}" -ne 0 ]
    run grep -F 'the fallback lane' "${tpl}"
    [ "${status}" -ne 0 ]
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

@test "research lanes: the seed names the searxng lane, context7, and the parked native tool" {
  # Both config twins park native search and hand the web to the gated searxng
  # block (pinned above), and the seed is what tells the agent to go there
  # instead of spending a turn on the tool the transport rejects. So the seed
  # has to carry the same story as the config it ships beside: the lane's name,
  # the variable it dials, the context7 lane the config renders next to it, the
  # parked key, and the digest contract that keeps raw tool output in the child.
  # One common copy feeds both twins, so a lapse here is every workspace.
  local common_md="${REPO_ROOT}/templates/common/GROK_BUILD_AGENTS.md"
  [ -f "${common_md}" ] ||
    skip "no common GROK_BUILD_AGENTS.md payload under ${REPO_ROOT}/templates/common"
  run grep -F '# Research lanes' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F '# Tool output stays out of the parent context' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F 'the `searxng` MCP tools' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F '$SEARXNG_URL' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F 'http://host.docker.internal:8181' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F '`context7` first' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F 'disable_web_search = true' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F 'the digest contract' "${common_md}"
  [ "${status}" -eq 0 ]
  run grep -F 'source URL' "${common_md}"
  [ "${status}" -eq 0 ]
  # Stale instruction: the seed must not promise a native lane the config parks,
  # and must not downgrade searxng to a fallback behind it.
  run grep -F 'Native search is on by default' "${common_md}"
  [ "${status}" -ne 0 ]
  run grep -F 'the fallback lane' "${common_md}"
  [ "${status}" -ne 0 ]
}

@test "context7 lane: both config twins carry the gated cached context7 block" {
  # context7_mcp (template default: true) gates the [mcp_servers.context7]
  # block, and push-template.sh passes one --var array to BOTH pushes, so the
  # gate and the block have to exist in each twin; a twin that lost the gate
  # would render the server unconditionally or never, depending on the pushed
  # default. The greps pin the block shape: the mcp-cache-proxy wrapper by
  # absolute path, the proxy config it is pointed at, and the CONTEXT7_API_KEY
  # reference the CLI expands from the environment ($$ is the Terraform escape,
  # so the file itself spells the doubled dollars). npx is allowed only in the
  # comments that explain why it is wrong, so the ban is scoped to the heredoc
  # the startup twins use to seed that proxy config.
  local tpl st blob
  for tpl in "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/grok-config.toml.tftpl"; do
    [[ -f "${tpl}" ]] || skip "config template not reachable from ${REPO_ROOT}"
    run grep -F '%{if context7_mcp~}' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F '[mcp_servers.context7]' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'command = "/opt/npm-global/bin/mcp-cache-proxy"' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'args = ["--config", "/home/coder/.grok/mcp-cache-proxy/config.json"]' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'env = { CONTEXT7_API_KEY = "$${CONTEXT7_API_KEY}" }' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -A 6 -F '[mcp_servers.context7]' "${tpl}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"enabled = true"* ]]
  done
  # The seed names the real context7 binary, baked into the golden image, so a
  # new workspace never hits the npm registry on first boot.
  local proxy="${REPO_ROOT}/templates/common/mcp-cache-proxy.json"
  [ -f "${proxy}" ]
  run grep -F '"command": "/opt/npm-global/bin/context7-mcp"' "${proxy}"
  [ "${status}" -eq 0 ]
  if grep -Fq 'npx' "${proxy}"; then
    printf 'leak: templates/common/mcp-cache-proxy.json launches npx\n' >&2
    return 1
  fi
  for st in "${DC_STARTUP}" "${WS_STARTUP}"; do
    [[ -f "${st}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    run grep -F '${mcp_cache_proxy}' "${st}"
    [ "${status}" -eq 0 ]
  done
}

@test "context7 lane: both main.tf twins feed the gate and both coder.tf twins declare the variables" {
  # context7_mcp/context7_api_key are render-map keys in both main.tf twins
  # (the boolean arrives as a real Terraform bool, so coder.tf has to declare
  # it), and the key joins the agent environment only when it is non-empty -
  # that guard is what keeps a blank .env line from overriding the template
  # default. The startup twins carry the quoted heredoc that seeds the proxy
  # config, including the SQLite cache file the wrapper writes.
  local tf ctf st
  for tf in "${REPO_ROOT}/templates/workspace/main.tf" "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    run grep -Eq 'context7_mcp[[:space:]]+=[[:space:]]+var\.context7_mcp' "${tf}"
    [ "${status}" -eq 0 ]
    run grep -F 'CONTEXT7_API_KEY = var.context7_api_key' "${tf}"
    [ "${status}" -eq 0 ]
    run grep -F 'length(var.context7_api_key) > 0 ? { CONTEXT7_API_KEY = var.context7_api_key } : {}' "${tf}"
    [ "${status}" -eq 0 ]
  done
  for ctf in "${REPO_ROOT}/templates/workspace/coder.tf" "${REPO_ROOT}/templates/devcontainer/coder.tf"; do
    run grep -F 'variable "context7_mcp"' "${ctf}"
    [ "${status}" -eq 0 ]
    run grep -F 'variable "context7_api_key"' "${ctf}"
    [ "${status}" -eq 0 ]
  done
  for st in "${DC_STARTUP}" "${WS_STARTUP}"; do
    run grep -F "<<'MCP_CACHE_PROXY_EOF'" "${st}"
    [ "${status}" -eq 0 ]
    run grep -F '${mcp_cache_proxy}' "${st}"
    [ "${status}" -eq 0 ]
    # The script writes the file under $HOME (the coder user's own ~/.grok, so
    # a shared grok-profile volume reuses the cache); only the cache path the
    # proxy itself opens is spelled absolutely inside the payload.
    run grep -F 'cat >"$HOME/.grok/mcp-cache-proxy/config.json"' "${st}"
    [ "${status}" -eq 0 ]
  done
  run grep -F '/home/coder/.grok/mcp-cache-proxy/cache.db' \
    "${REPO_ROOT}/templates/common/mcp-cache-proxy.json"
  [ "${status}" -eq 0 ]
}

@test "mcp gates: github, searxng and context7 default on in both twins" {
  # All three MCP blocks ship unless a push passes --var <name>=false. The
  # coder.tf defaults are the contract push-template.sh relies on (it only
  # forwards an explicit false). A twin that flipped one default back to
  # false would drop that server from every workspace that did not also set
  # the matching .env key to true, which the push no longer does.
  local tpl ctf var
  for tpl in "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/grok-config.toml.tftpl"; do
    [[ -f "${tpl}" ]] || skip "config template not reachable from ${REPO_ROOT}"
    run grep -F '%{if github_mcp~}' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F '[mcp_servers.github]' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F 'url = "https://api.githubcopilot.com/mcp/"' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -A 4 -F '[mcp_servers.github]' "${tpl}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"enabled = true"* ]]
    run grep -F '%{if search_mcp~}' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F '[mcp_servers.searxng]' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F '%{if context7_mcp~}' "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F '[mcp_servers.context7]' "${tpl}"
    [ "${status}" -eq 0 ]
  done
  for ctf in "${REPO_ROOT}/templates/workspace/coder.tf" "${REPO_ROOT}/templates/devcontainer/coder.tf"; do
    for var in github_mcp search_mcp context7_mcp; do
      run grep -F "variable \"${var}\"" "${ctf}"
      [ "${status}" -eq 0 ]
      block="$(sed -n "/variable \"${var}\"/,/^}/p" "${ctf}")"
      [[ "${block}" == *"default     = true"* ]]
    done
  done
}

@test "mcp lanes: both twins probe every rendered command= against the image" {
  # Every [mcp_servers.*] block the config template writes names its binary by
  # the absolute path the golden image bakes (/opt/npm-global/bin/...), so the
  # rendered config and the running image are two artifacts that have to agree.
  # Measured failure: a workspace on an image built before that binary existed
  # booted with the search lane declared and no lane at all, silently, because
  # only the CLI's own MCP log knew. The advisory stage that follows the render
  # is the startup-log notice: grep/sed over the rendered file, deduped, one
  # warning per path that is not an executable, naming the image-remedy and the
  # npm-remedy at the version images/dev/tool-versions.env pins.
  local st l l_cfg l_stage l_ctx
  for st in "${DC_STARTUP}" "${WS_STARTUP}"; do
    [[ -f "${st}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    run grep -F 'MCP command reachability (advisory)' "${st}"
    [ "${status}" -eq 0 ]
    run grep -F 'check_mcp_commands() {' "${st}"
    [ "${status}" -eq 0 ]
    # The extraction shape: only a command= line, only a double-quoted value,
    # iterated over the unique sorted list.
    run grep -F '^[[:space:]]*command[[:space:]]*=' "${st}"
    [ "${status}" -eq 0 ]
    run grep -F '\([^"]*\)' "${st}"
    [ "${status}" -eq 0 ]
    run grep -F 'sort -u' "${st}"
    [ "${status}" -eq 0 ]
    # The line a stuck workspace has to be able to act on.
    run grep -F 'declares an MCP command that is not executable:' "${st}"
    [ "${status}" -eq 0 ]
    run grep -F 'npm i -g --prefix /opt/npm-global' "${st}"
    [ "${status}" -eq 0 ]
    run grep -F 'images/dev/tool-versions.env' "${st}"
    [ "${status}" -eq 0 ]
    # Position is the whole point: the probe runs on the file the stage above
    # just wrote, and before the cache-proxy seed beside it.
    l_cfg="$(grep -n -m1 -F '${grok_config}' "${st}" | cut -d: -f1)"
    l_stage="$(grep -n -m1 -F 'check_mcp_commands() {' "${st}" | cut -d: -f1)"
    l_ctx="$(grep -n -m1 -F 'Context7 cache-proxy config' "${st}" | cut -d: -f1)"
    for l in "${l_cfg}" "${l_stage}" "${l_ctx}"; do
      [ -n "${l}" ] || { echo "${st}: cannot locate the render/proxy stages" >&2; return 1; }
    done
    if [[ ! "${l_cfg}" -lt "${l_stage}" || ! "${l_stage}" -lt "${l_ctx}" ]]; then
      echo "${st}: the advisory stage is not between the config render and the cache-proxy seed" >&2
      return 1
    fi
  done
}

@test "mcp lanes: the advisory stage can never abort a boot" {
  # This runs on every workspace start, before the clone, so a probe that could
  # fail is worse than no probe: it would take the terminal and the editor down
  # with it. Everything optional is swallowed, a missing config returns early,
  # and the config is read as data (no eval) - then the generated script has to
  # parse, because a stray ${ or %{ ships verbatim out of templatefile() and
  # dies at boot rather than at a gate.
  local st n script
  for st in "${DC_STARTUP}" "${WS_STARTUP}"; do
    [[ -f "${st}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    run grep -E '^check_mcp_commands \|\| true$' "${st}"
    [ "${status}" -eq 0 ]
    n="$(grep -c -F 'check_mcp_commands || true' "${st}")"
    assert_eq "${st} calls the probe once and only guarded" "1" "${n}"
    run grep -F '[ -f "$mcp_cfg" ] || return 0' "${st}"
    [ "${status}" -eq 0 ]
    run grep -F '"$mcp_cfg" 2>/dev/null' "${st}"
    [ "${status}" -eq 0 ]
    run grep -Fw 'eval' "${st}"
    [ "${status}" -ne 0 ]
    # Render the way templatefile() would: no %{...} gate exists in these two
    # files, and every ${name} becomes one inert token.
    script="$(sed -E 's/\$\{[A-Za-z0-9_]+\}/RENDERED/g' "${st}")"
    [[ -n "${script}" ]] || { echo "${st}: rendered nothing" >&2; return 1; }
    if ! printf '%s\n' "${script}" | bash -n; then
      echo "${st}: rendered startup script is not valid bash" >&2
      return 1
    fi
  done
}

@test "mcp lanes: an unmanaged config says what it costs in both twins" {
  # The guard re-renders only while the file is absent, a fresh install, or
  # stack-marked; the else path used to be silent. A config that lost both
  # markers (or was hand-written) opts the workspace out of every default lane
  # and the model catalog forever, and nothing ever said so. Semantics must not
  # move: the same three conditions, with the marker condition now satisfied by
  # either spelling, plus one note naming the consequence and
  # the two ways back.
  local st s e block
  for st in "${DC_STARTUP}" "${WS_STARTUP}"; do
    [[ -f "${st}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    s="$(grep -n -m1 -F 'if [ ! -f "$HOME/.grok/config.toml" ]' "${st}" | cut -d: -f1)"
    e="$(grep -n -m1 -F 'check_mcp_commands || true' "${st}" | cut -d: -f1)"
    [[ -n "${s}" && -n "${e}" ]] || { echo "${st}: cannot locate the config render guard" >&2; return 1; }
    block="$(sed -n "${s},${e}p" "${st}")"
    [[ "${block}" == *'[ ! -f "$HOME/.grok/config.toml" ]'* ]] ||
      { echo "${st}: the render guard lost its absent-file condition" >&2; return 1; }
    [[ "${block}" == *'[ "$GROK_FRESH_INSTALL" = "1" ]'* ]] ||
      { echo "${st}: the render guard lost the fresh-install condition" >&2; return 1; }
    [[ "${block}" == *"grep -qFs -e 'managed-by: evo-t1-coder-stack' -e '__evoT1Stack = true'"* ]] ||
      { echo "${st}: the render guard lost one of the two marker conditions" >&2; return 1; }
    [[ "${block}" == *$'\nelse'$'\n'* ]] ||
      { echo "${st}: the render guard has no else path" >&2; return 1; }
    [[ "${block}" == *'WARNING: $HOME/.grok/config.toml carries neither stack marker'* ]] ||
      { echo "${st}: the unmanaged-config note is gone" >&2; return 1; }
    [[ "${block}" == *'running a config the stack does not manage'* ]] ||
      { echo "${st}: the note names no consequence" >&2; return 1; }
    [[ "${block}" == *'bazelisk run //scripts:seed-dev-env -- --force'* ]] ||
      { echo "${st}: the note names no remedy" >&2; return 1; }
  done
}

@test "config marker: both twins emit the key that survives a CLI rewrite" {
  # The comment marker alone does not last. The CLI persists its own settings by
  # rewriting ~/.grok/config.toml, and that write deletes every comment line, so
  # a stack-managed config used to fall into the user column with nobody touching
  # it and its default lanes never arrived again. A top-level key survives the same
  # write, so both config twins emit one; TOML needs top-level keys ahead of the
  # first table. And because a re-render replaces the file, both startup twins
  # carry the CLI-owned tables over: [ui] holds permission_mode, so adopting a
  # file back must never flip an operator from always-approve back to prompting.
  local tpl key_line models_line
  for tpl in "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/grok-config.toml.tftpl"; do
    [[ -f "${tpl}" ]] || skip "config template not reachable from ${REPO_ROOT}"
    key_line="$(grep -n -m1 -Fx '__evoT1Stack = true' "${tpl}" | cut -d: -f1)"
    [[ -n "${key_line}" ]] || { echo "${tpl}: no top-level ownership key" >&2; return 1; }
    models_line="$(grep -n -m1 -Fx '[models]' "${tpl}" | cut -d: -f1)"
    [[ "${key_line}" -lt "${models_line}" ]] || {
      echo "${tpl}: the ownership key sits at or after the first table" >&2
      return 1
    }
    grep -qF 'managed-by: evo-t1-coder-stack' "${tpl}" || {
      echo "${tpl}: the comment marker went away along with the key" >&2
      return 1
    }
  done

  local st
  for st in "${DC_STARTUP}" "${WS_STARTUP}"; do
    [[ -f "${st}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    grep -qF '(cli|ui|marketplace)' "${st}" || {
      echo "${st}: the re-render carries over fewer than [cli], [ui] and [marketplace]" >&2
      return 1
    }
  done
}

@test "mcp lanes: both twins carry the new stage and note as identical text" {
  # The twins are independent payload copies (repo rule: edit both when
  # changing one), so parity here is byte-for-byte on the two new blocks, not a
  # key string one twin could satisfy with drifted wording.
  local stage_ws stage_dc note_ws note_dc
  stage_ws="$(sed -n '/^# --- MCP command reachability/,/^check_mcp_commands || true$/p' "${WS_STARTUP}")"
  stage_dc="$(sed -n '/^# --- MCP command reachability/,/^check_mcp_commands || true$/p' "${DC_STARTUP}")"
  note_ws="$(sed -n '/WARNING: \$HOME\/\.grok\/config\.toml carries neither stack marker/,/>&2$/p' "${WS_STARTUP}")"
  note_dc="$(sed -n '/WARNING: \$HOME\/\.grok\/config\.toml carries neither stack marker/,/>&2$/p' "${DC_STARTUP}")"
  [[ -n "${stage_ws}" ]] || { echo "${WS_STARTUP}: no advisory stage to compare" >&2; return 1; }
  [[ -n "${note_ws}" ]] || { echo "${WS_STARTUP}: no note to compare" >&2; return 1; }
  if [ "${stage_ws}" != "${stage_dc}" ]; then
    printf 'drift: the advisory stage differs between the twins\n%s\n' \
      "$(diff <(printf '%s\n' "${stage_ws}") <(printf '%s\n' "${stage_dc}"))" >&2
    return 1
  fi
  if [ "${note_ws}" != "${note_dc}" ]; then
    printf 'drift: the unmanaged-config note differs between the twins\n%s\n' \
      "$(diff <(printf '%s\n' "${note_ws}") <(printf '%s\n' "${note_dc}"))" >&2
    return 1
  fi
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
