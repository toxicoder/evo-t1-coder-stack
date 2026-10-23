#!/usr/bin/env bats
#
# ## coder-apps.bats — guardrails for the buttons Coder renders above an agent.
#
# Pins the two facts the troubleshooting and public-access pages describe. The
# editor button's icon is a private SVG inlined as a data URI, because Coder
# serves /icon/ only from its own bundled set and that set has no
# vscode-alt.svg; the same local also feeds coder_script.code_server, so
# dropping it moves the editor button and the script row together. The data
# URL has to stay at or under 256 characters: Coder v2.36 stores
# workspace_apps.icon as varchar(256), and a longer value fails templates
# push with pq: value too long for type character varying(256). The proxied
# apps ride the path form (/@<owner>/<ws>.<agent>/apps/<slug>) on the coder
# hostname: subdomain stays false because nothing on this box publishes a
# wildcard origin, and share stays owner, so a working <service>-name subdomain
# never proves a failing app link worked.
#
# Usage: bats tests/bats/coder-apps.bats
# Safety: reads templates/workspace/main.tf, templates/devcontainer/main.tf and
# templates/common/vscode-alt.svg; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
TEMPLATE_TWINS=()

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  TEMPLATE_TWINS=()
  local tpl
  for tpl in "${REPO_ROOT}/templates/workspace/main.tf" "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    [[ -f "${tpl}" ]] || skip "template payload is not reachable from ${REPO_ROOT}"
    TEMPLATE_TWINS+=("${tpl}")
  done
}

# Print the body of one coder_app block from one main.tf. An absent resource
# prints nothing, so every caller has to assert on the length as well as on the
# contents: a rename would otherwise read as a pass.
app_block() {
  sed -n "/^resource \"coder_app\" \"$2\" {/,/^}/p" "$1"
}

@test "icon: both twins build the editor icon from the common SVG copy" {
  # filebase64() reads beside main.tf, so the icon only resolves while
  # templates/common/vscode-alt.svg exists and push-template stages it there.
  [ -f "${REPO_ROOT}/templates/common/vscode-alt.svg" ]
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    run grep -F 'vscode_alt_icon = "data:image/svg+xml;base64,${filebase64("${path.module}/vscode-alt.svg")}"' "${tpl}"
    [ "${status}" -eq 0 ]
  done
}

@test "icon: the inlined data URL fits Coder's varchar(256) workspace_apps.icon column" {
  # filebase64() emits unwrapped standard base64 (4*ceil(n/3)); the prefix
  # data:image/svg+xml;base64, is 26 characters. A 5 KB SVG produced a ~7 k
  # character URL and died at insert agent app.
  local svg="${REPO_ROOT}/templates/common/vscode-alt.svg" bytes url_len
  [ -f "${svg}" ]
  bytes="$(wc -c <"${svg}")"
  bytes="${bytes//[!0-9]/}"
  url_len=$((4 * ((bytes + 2) / 3) + 26))
  [ "${url_len}" -le 256 ]
}

@test "icon: the editor button keeps its icon, not just the script row" {
  # coder_app and coder_script each carry an icon. Losing the one on
  # coder_app.code_server moves the editor button back to Coder's default
  # glyph while the script row keeps the SVG, which reads as a theme change.
  local tpl block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    block="$(app_block "${tpl}" code_server)"
    [ -n "${block}" ]
    printf '%s\n' "${block}" | grep -qE 'icon[[:space:]]*=[[:space:]]*local\.vscode_alt_icon'
  done
}

@test "app lane: the proxied apps stay on the path form" {
  # subdomain=true needs a wildcard origin, and this stack sets none, so
  # flipping it moves the app off the coder name instead of onto a subdomain.
  local tpl app block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    for app in code_server litellm; do
      block="$(app_block "${tpl}" "${app}")"
      [ -n "${block}" ]
      printf '%s\n' "${block}" | grep -qE 'subdomain[[:space:]]*=[[:space:]]*false'
      printf '%s\n' "${block}" | grep -qE 'share[[:space:]]*=[[:space:]]*"owner"'
    done
  done
}

@test "app lane: LiteLLM keeps dialling the host gateway from inside" {
  # The app link reaches the proxy through the workspace, never through
  # litellm-gmktecbeast. A literal published port would name one machine's
  # mapping instead of the private lane every supported shape shares.
  local tpl block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    block="$(app_block "${tpl}" litellm)"
    [ -n "${block}" ]
    printf '%s\n' "${block}" | grep -qF 'url          = "http://host.docker.internal:4000"'
    if printf '%s\n' "${block}" | grep -qE '8181|litellm-gmktecbeast'; then
      return 1
    fi
  done
}
