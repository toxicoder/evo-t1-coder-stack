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
# Usage: bazelisk test //tests:bats_coder_apps_test   (from any cwd)
# Safety: reads templates/workspace/main.tf, templates/devcontainer/main.tf,
# both startup.sh.tftpl twins and templates/common/vscode-alt.svg; writes
# nothing.

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

@test "github: both twins declare External Auth via var.github_auth_id" {
  # Coder CE injects a GitHub App whose id is "github" when coder.env is
  # absent. Hardcoding primary-github made templates push fail at activation
  # with "external auth provider primary-github is not configured".
  local tpl
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    grep -Fq 'id       = var.github_auth_id' "${tpl}"
    grep -Fq 'cron    = "0 0 */6 * * *"' "${tpl}"
    grep -Fq 'CODER_GITHUB_AUTH_ID = var.github_auth_id' "${tpl}"
    grep -Fq "coder external-auth access-token '\${var.github_auth_id}'" "${tpl}"
  done
  if grep -E 'id[[:space:]]*=[[:space:]]*"primary-github"' "${TEMPLATE_TWINS[@]}"; then
    return 1
  fi
}

@test "github: both twins surface a GitHub reauth button on the workspace page" {
  # Coder v2.36 serves connect/reauth at /external-auth/<id>. That page
  # needs the user's Coder browser session (OAuth redirect or device
  # flow), so the app is external and opens access_url, with the id the
  # templates already declare. A hardcoded /external-auth/github would
  # miss a custom OAuth app in coder.env. share is mutually exclusive
  # with external. The empty-token refresh note points at this button.
  local tpl block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    block="$(app_block "${tpl}" github_reauth)"
    [ -n "${block}" ]
    printf '%s\n' "${block}" | grep -qE 'display_name[[:space:]]*=[[:space:]]*"GitHub reauth"'
    printf '%s\n' "${block}" | grep -qE 'slug[[:space:]]*=[[:space:]]*"github-reauth"'
    printf '%s\n' "${block}" | grep -qE 'external[[:space:]]*=[[:space:]]*true'
    printf '%s\n' "${block}" | grep -qE 'open_in[[:space:]]*=[[:space:]]*"slim-window"'
    printf '%s\n' "${block}" | grep -qE 'icon[[:space:]]*=[[:space:]]*"/icon/github.svg"'
    printf '%s\n' "${block}" | grep -qF 'url          = "${data.coder_workspace.me.access_url}/external-auth/${var.github_auth_id}"'
    printf '%s\n' "${block}" | grep -qE 'order[[:space:]]*=[[:space:]]*7'
    if printf '%s\n' "${block}" | grep -qE 'share[[:space:]]*='; then
      return 1
    fi
    grep -Fq 'click GitHub reauth on this workspace in the Coder UI' "${tpl}"
  done
}

@test "github: both twins surface Install GitHub App for the injected Coder App" {
  # The injected provider omits AppInstallURL, so /external-auth/github
  # prints the empty-installations warning as unlinked plaintext. This
  # button is the clickable install path for slug coder. count is the
  # github_auth_id template variable (preview-safe), not start_count.
  # A custom OAuth id hides it; that slug is not coder.
  local tpl block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    grep -Fq 'coder_github_app_install_url = "https://github.com/apps/coder/installations/new"' "${tpl}"
    block="$(app_block "${tpl}" github_app_install)"
    [ -n "${block}" ]
    printf '%s\n' "${block}" | grep -qE 'count[[:space:]]*=[[:space:]]*var.github_auth_id == "github" \? 1 : 0'
    printf '%s\n' "${block}" | grep -qE 'display_name[[:space:]]*=[[:space:]]*"Install GitHub App"'
    printf '%s\n' "${block}" | grep -qE 'slug[[:space:]]*=[[:space:]]*"github-app-install"'
    printf '%s\n' "${block}" | grep -qE 'external[[:space:]]*=[[:space:]]*true'
    printf '%s\n' "${block}" | grep -qE 'open_in[[:space:]]*=[[:space:]]*"tab"'
    printf '%s\n' "${block}" | grep -qE 'icon[[:space:]]*=[[:space:]]*"/icon/github.svg"'
    printf '%s\n' "${block}" | grep -qE 'url[[:space:]]*=[[:space:]]*local.coder_github_app_install_url'
    printf '%s\n' "${block}" | grep -qE 'order[[:space:]]*=[[:space:]]*8'
    if printf '%s\n' "${block}" | grep -qE 'share[[:space:]]*='; then
      return 1
    fi
    if printf '%s\n' "${block}" | grep -q start_count; then
      echo "${tpl} coder_app.github_app_install still uses start_count" >&2
      return 1
    fi
  done
}

@test "github: both twins write the gh auth store with the env pair cleared" {
  # gh_token_refresh inherits GH_TOKEN/GITHUB_TOKEN from the agent, and
  # `gh auth login --with-token` refuses while those names are set. The
  # old swallowed-stderr note ("the minted token is valid but gh would
  # not take it") hid that. Unset, logout, --git-protocol https, then
  # login; on failure print gh's stderr (token redacted) and the App
  # install URL.
  local tpl
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    grep -Fq 'unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN' "${tpl}"
    grep -Fq 'gh auth logout --hostname github.com' "${tpl}"
    grep -Fq 'gh auth login --hostname github.com --git-protocol https --with-token' "${tpl}"
    grep -Fq 'gh auth setup-git' "${tpl}"
    grep -Fq 'gh would not store the minted GitHub token' "${tpl}"
    grep -Fq 'GH_TOKEN= GITHUB_TOKEN= gh auth status' "${tpl}"
    grep -Fq 'click Install GitHub App on this workspace' "${tpl}"
    if grep -Fq 'the minted token is valid but gh would not take it' "${tpl}"; then
      echo "${tpl} still swallows gh auth login stderr" >&2
      return 1
    fi
  done
}

@test "github: both twins default github_auth_id to Coder's injected App id" {
  local tf
  for tf in "${REPO_ROOT}/templates/workspace/coder.tf" "${REPO_ROOT}/templates/devcontainer/coder.tf"; do
    [ -f "${tf}" ]
    grep -Fq 'variable "github_auth_id"' "${tf}"
    sed -n '/variable "github_auth_id"/,/^}/p' "${tf}" | grep -Fq 'default     = "github"'
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

@test "app lane: coder_app resources are not gated on start_count" {
  # coder/preview warns "Unexpanded count argument on block coder_app.*" when
  # count is start_count: that value is not expanded at workspace-create
  # preview, so the parser assumes 1. Apps should exist while the workspace
  # is stopped. Scripts, metadata and the container stay gated.
  local tpl app block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    for app in code_server web_terminal github_reauth github_app_install litellm coder_ui; do
      block="$(app_block "${tpl}" "${app}")"
      [ -n "${block}" ]
      if printf '%s\n' "${block}" | grep -q start_count; then
        echo "${tpl} coder_app.${app} still uses start_count" >&2
        return 1
      fi
    done
  done
}

@test "editor: both twins pass editor_folder to code-server as a CLI argument" {
  # Path-based coder_app URLs drop the ?folder= query before the browser
  # sees it, and without --ignore-last-opened the last restored workspace
  # (often /home/coder) wins. The binary has to receive the folder itself.
  local tpl ws
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    grep -Fq 'FOLDER="${local.editor_folder}"' "${tpl}"
    grep -Fq -- '--ignore-last-opened "$${FOLDER}"' "${tpl}"
    grep -Fq 'folder=${urlencode(local.editor_folder)}' "${tpl}"
  done
  ws="${REPO_ROOT}/templates/workspace/main.tf"
  grep -Fq -- 'editor_folder = local.repo_set ? "/home/coder/workspace/${local.repo_folder}" : "/home/coder"' "${ws}"
}

@test "editor: both twins create the folder and wait out the clone before launching" {
  # The clone runs in the agent's startup script while this script starts
  # beside it, so a first boot can hand code-server a folder that does not
  # exist yet — VS Code answers that with "Workspace does not exist" and
  # restores the last window (/home/coder) instead of the clone. The script
  # mkdirs the folder so the path always resolves, then polls for the clone's
  # .git for at most 60 s, returning as soon as it lands. Both steps have to
  # sit between the FOLDER assignment and the launch line, and /home/coder has
  # to stay exempt: nothing clones there, so waiting on it would only delay
  # the editor by the whole timeout.
  local tpl l_folder l_mkdir l_wait l_guard l_launch
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    grep -Fq 'mkdir -p -- "$${FOLDER}"' "${tpl}"
    grep -Fq 'if [ "$${FOLDER}" != "/home/coder" ]; then' "${tpl}"
    grep -Fq 'while [ ! -e "$${FOLDER}/.git" ] && [ "$${waited}" -lt 60 ]; do' "${tpl}"
    grep -Fq 'waited=$$((waited + 1))' "${tpl}"
    # Order matters as much as presence: waiting after the launch is a no-op.
    l_folder="$(grep -n -F 'FOLDER="${local.editor_folder}"' "${tpl}" | head -n 1 | cut -d: -f1)"
    l_mkdir="$(grep -n -F 'mkdir -p -- "$${FOLDER}"' "${tpl}" | head -n 1 | cut -d: -f1)"
    l_wait="$(grep -n -F 'while [ ! -e "$${FOLDER}/.git" ]' "${tpl}" | head -n 1 | cut -d: -f1)"
    l_guard="$(grep -n -F 'if [ "$${FOLDER}" != "/home/coder" ]; then' "${tpl}" | head -n 1 | cut -d: -f1)"
    l_launch="$(grep -n -F -- '--ignore-last-opened "$${FOLDER}"' "${tpl}" | head -n 1 | cut -d: -f1)"
    for l in "${l_folder}" "${l_mkdir}" "${l_wait}" "${l_guard}" "${l_launch}"; do
      [ -n "${l}" ] || { echo "${tpl}: missing a line of the code-server launch" >&2; return 1; }
    done
    if [[ ! "${l_mkdir}" -gt "${l_folder}" || ! "${l_mkdir}" -lt "${l_launch}" ]]; then
      echo "${tpl}: the mkdir is not between the FOLDER assignment and the launch" >&2
      return 1
    fi
    if [[ ! "${l_guard}" -gt "${l_folder}" || ! "${l_wait}" -gt "${l_guard}" || ! "${l_wait}" -lt "${l_launch}" ]]; then
      echo "${tpl}: the .git wait is not between the FOLDER assignment and the launch" >&2
      return 1
    fi
  done
}

@test "editor: the clone stage pre-creates its target so the editor can open it early" {
  # The startup script owns the clone and the code-server script races it; the
  # folder has to exist on the clone side too, and be owned by the user git
  # runs as, or the editor opens an empty tree that the clone can never fill.
  local startup l_mkdir l_clone
  for startup in \
    "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"; do
    grep -Fq 'mkdir -p -- "$target"' "${startup}"
    # The folder a root agent creates stays writable for the workspace user's
    # git only if it is chowned alongside the parent.
    grep -Fq 'chown "$clone_owner" "$target" 2>/dev/null || true' "${startup}"
    # Creating the target must not turn the "not a git repository" guard into
    # a permanent skip: it tests for content, not just existence.
    grep -Fq '[ -e "$target" ] && [ -n "$(ls -A -- "$target" 2>/dev/null)" ]' "${startup}"
    # And the clone still runs.
    grep -Fq 'run_clone clone -- "$repo_url_raw" "$target"' "${startup}"
    # The mkdir has to precede the clone, or it saves the editor nothing.
    l_mkdir="$(grep -n -F 'mkdir -p -- "$target"' "${startup}" | head -n 1 | cut -d: -f1)"
    l_clone="$(grep -n -F 'run_clone clone -- "$repo_url_raw" "$target"' "${startup}" | head -n 1 | cut -d: -f1)"
    [ -n "${l_mkdir}" ] && [ -n "${l_clone}" ]
    if [[ ! "${l_mkdir}" -lt "${l_clone}" ]]; then
      echo "${startup}: the target mkdir runs after the clone" >&2
      return 1
    fi
  done
}

@test "editor: neither twin points coder_agent.dir at the clone folder" {
  # The agent chdirs into its dir before startup.sh runs, so a dir naming the
  # not-yet-cloned folder fails the agent itself — the clone would never start
  # and the editor would have nothing to open. The folder belongs to the
  # editor app and its script; the agent stays on the (unset) home dir, which
  # is also why display_apps keeps the built-in web_terminal off.
  local tpl block
  for tpl in "${TEMPLATE_TWINS[@]}"; do
    block="$(sed -n '/^resource "coder_agent" "main" {/,/^}/p' "${tpl}")"
    [ -n "${block}" ]
    if printf '%s\n' "${block}" | grep -qE '^[[:space:]]*dir[[:space:]]*='; then
      echo "${tpl}: coder_agent.main sets dir; the agent would fail before the clone" >&2
      return 1
    fi
  done
}
