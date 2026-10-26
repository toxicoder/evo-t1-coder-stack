#!/usr/bin/env bats
#
# ## seed-dev-env.bats - hermetic coverage for scripts/seed-dev-env.sh
#
# The contract pinned here: a contributor home is seeded from the same
# workspace templates startup uses, a marker-free config stays user-owned
# unless --force is set, --dry-run writes nothing and does not call gh, and
# no GitHub token is ever written into a seeded file. Every invocation passes
# --home under BATS_TEST_TMPDIR and points REPO_ROOT at a payload copy that
# is not this checkout, so notes_materialize cannot touch the real tree.
#
# The whole suite skips while scripts/seed-dev-env.sh is absent: a suite for
# a script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_seed_dev_env_test   (from any cwd)
# Safety: reads the template payloads and the script; writes only under the
# per-test scratch tree. git, when used, is real and only on that scratch.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
SEED_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/seed-dev-env.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/seed-dev-env.sh is not in the tree"
  fi
  # CONTEXT7_API_KEY is a render input, not just a secret: a non-empty value keeps
  # the context7 lane in the rendered config. Clear it with the other pass-throughs
  # so the default-path assertions below see the keyless home.
  unset GH_TOKEN GITHUB_TOKEN CONTEXT7_API_KEY
  use_stubs gh
}

# payload_root — a checkout-shaped directory whose templates are this repo's,
# without this repo's .git, so a seed cannot materialize notes into the tree
# under test.
payload_root() {
  local dest
  dest="$(make_scratch)/repo"
  mkdir -p "${dest}"
  ln -s "${REPO_ROOT}/docker-compose.yml" "${dest}/docker-compose.yml"
  ln -s "${REPO_ROOT}/templates" "${dest}/templates"
  printf '%s' "${dest}"
}

# run_seed <home> [args...] — seed against an isolated payload root.
# SEED_ROOT is the payload root the invocation used.
run_seed() {
  local home="$1"
  shift
  SEED_ROOT="$(payload_root)"
  REPO_ROOT="${SEED_ROOT}" run bash "${SCRIPT}" --home "${home}" "$@"
}

# load_seed_api — pull every production function into this shell.
load_seed_api() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/config_seed.sh"
  # seed_render_grok_config looks up tftpl_strip_gates.awk next to SELF_DIR.
  SELF_DIR="${REPO_ROOT}/scripts"
  local name
  for name in \
    usage \
    resolve_repo_root \
    seed_render_grok_config \
    seed_write_helpers \
    seed_write_notes_lib \
    seed_link_vscode_settings \
    seed_write_grok_config \
    seed_write_bashrc_path \
    seed_setup_git_credential \
    seed_install_git_hooks \
    seed_dev_env; do
    load_shell_function "${SCRIPT}" "${name}"
  done
}

# file_mode <path> — the permission bits, portable across GNU and BSD stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
}

# assert_fixed <label> <path> <literal> — the file contains the literal text.
assert_fixed() {
  if ! grep -F -q -- "$3" "$2"; then
    printf 'FAIL: %s: %s lacks [%s]\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

# assert_not_fixed <label> <path> <literal> — the file does not contain it.
assert_not_fixed() {
  if grep -F -q -- "$3" "$2"; then
    printf 'FAIL: %s: %s unexpectedly contains [%s]\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

# assert_settings_link <dest> <shared> — dest is a symlink to shared.
assert_settings_link() {
  if [ ! -L "$1" ]; then
    printf 'FAIL: not a symlink: %s\n' "$1" >&2
    return 1
  fi
  assert_eq "link target" "$2" "$(readlink "$1")"
}

# assert_grok_config_base <path> <litellm-url> -- what every rendered config
# promises, whichever optional lanes it declares.
assert_grok_config_base() {
  local file="$1" url="$2"
  assert_file_exists "config.toml" "${file}"
  assert_fixed "marker" "${file}" "managed-by: evo-t1-coder-stack"
  assert_fixed "searxng" "${file}" "[mcp_servers.searxng]"
  assert_fixed "search url" "${file}" "SEARXNG_URL = \"http://host.docker.internal:8181\""
  assert_fixed "agent base url" "${file}" "base_url = \"${url}\""
  assert_fixed "default model" "${file}" 'default = "agent"'
  assert_fixed "affinity" "${file}" 'x-litellm-session-id" = "contributor"'
  assert_not_fixed "no if directive" "${file}" '%{if'
  assert_not_fixed "no endif directive" "${file}" '%{endif'
  assert_not_fixed "no github mcp" "${file}" '[mcp_servers.github]'
  assert_not_fixed "no ghp token" "${file}" 'ghp_'
  assert_not_fixed "no sk token" "${file}" 'sk-'
  assert_eq "config mode" "600" "$(file_mode "${file}")"
}

# assert_grok_config <path> <litellm-url> -- the contributor renderer contract
# for a home with no CONTEXT7_API_KEY: the docs lane stays dropped.
assert_grok_config() {
  local file="$1" url="$2"
  assert_grok_config_base "${file}" "${url}"
  assert_not_fixed "no context7 mcp" "${file}" '[mcp_servers.context7]'
}

# assert_grok_config_context7 <path> <home> -- the kept docs lane: declared, with
# its gate consumed, the key named but never valued, and the cache-proxy config
# path re-rooted under the seed home instead of the template's /home/coder.
assert_grok_config_context7() {
  local file="$1" home="$2"
  assert_fixed "context7 mcp" "${file}" '[mcp_servers.context7]'
  assert_fixed "context7 proxy binary" "${file}" \
    'command = "/opt/npm-global/bin/mcp-cache-proxy"'
  assert_fixed "context7 cache config" "${file}" \
    "args = [\"--config\", \"${home}/.grok/mcp-cache-proxy/config.json\"]"
  assert_fixed "context7 key unfolded" "${file}" \
    'env = { CONTEXT7_API_KEY = "$CONTEXT7_API_KEY" }'
  assert_not_fixed "no template home in the cache path" "${file}" \
    'args = ["--config", "/home/coder/.grok/mcp-cache-proxy/config.json"]'
  assert_not_fixed "doubled dollar not left behind" "${file}" '$${'
}

# assert_helpers <home> — both helpers exist, are executable, and unfolded.
assert_helpers() {
  local home="$1" helper
  for helper in grok-build-terminal vscode-terminal-tmux; do
    assert_file_exists "${helper}" "${home}/.grok/bin/${helper}"
    [ -x "${home}/.grok/bin/${helper}" ] || {
      printf 'FAIL: %s is not executable\n' "${helper}" >&2
      return 1
    }
    assert_fixed "unfolded folder" "${home}/.grok/bin/${helper}" '${folder}'
    assert_not_fixed "terraform dollar left doubled" "${home}/.grok/bin/${helper}" '$${folder}'
  done
}

# assert_contributor_home <home> <litellm-url> — the first-seed file set.
assert_contributor_home() {
  local home="$1" url="$2"
  assert_contains_file "tmux mouse" "${home}/.tmux.conf" 'set -g mouse on'
  assert_contains_file "tmux marker" "${home}/.tmux.conf" 'managed-by: evo-t1-coder-stack'
  assert_contains_file "settings marker" "${home}/.shared/vscode/settings.json" '__evoT1Stack'
  assert_fixed "settings url" "${home}/.shared/vscode/settings.json" "${url}"
  assert_file_exists "grok agents" "${home}/.grok/AGENTS.md"
  assert_file_exists "coder agents" "${home}/.coder/AGENTS.md"
  assert_file_exists "agents instructions" "${home}/.agents/INSTRUCTIONS.md"
  assert_file_exists "coder skill" "${home}/.coder/skills/grok-build-delegation/SKILL.md"
  assert_file_exists "agents skill" "${home}/.agents/skills/grok-build-delegation/SKILL.md"
  assert_helpers "${home}"
  assert_contains_file "notes lib" "${home}/.grok/notes-setup.sh" 'managed-by: evo-t1-coder-stack'
  assert_grok_config "${home}/.grok/config.toml" "${url}"
  assert_settings_link "${home}/.local/share/code-server/User/settings.json" \
    "${home}/.shared/vscode/settings.json"
  assert_settings_link "${home}/.config/Code/User/settings.json" \
    "${home}/.shared/vscode/settings.json"
  assert_contains_file "bashrc path" "${home}/.bashrc" 'grok/bin'
}

@test "seed-dev-env: usage, an unknown option, and a bare --litellm-url" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: bazelisk run //scripts:seed-dev-env --' "${output}"
  assert_match "pinned flags" '\[--home DIR\]' "${output}"

  run --separate-stderr bash "${SCRIPT}" -h
  [ "${status}" -eq 0 ]
  assert_match "short help" 'usage: bazelisk run //scripts:seed-dev-env --' "${output}"

  run --separate-stderr bash "${SCRIPT}" --bogus
  [ "${status}" -eq 1 ]
  assert_match "usage shown on a bad flag" 'usage: bazelisk run //scripts:seed-dev-env --' "${output}"
  assert_match "the bad flag is named" 'unknown option: --bogus' "${stderr}"

  run --separate-stderr bash "${SCRIPT}" --litellm-url
  [ "${status}" -eq 1 ]
  assert_match "missing url is a usage error" '--litellm-url needs a url' "${stderr}"
  assert_match "usage follows the missing url" 'usage: bazelisk run //scripts:seed-dev-env --' "${output}"

  load_shell_function "${SCRIPT}" usage
  run usage
  [ "${status}" -eq 0 ]
  assert_match "usage function" 'usage: bazelisk run //scripts:seed-dev-env --' "${output}"
}

@test "seed-dev-env: resolve_repo_root finds docker-compose.yml and rejects an unproven root" {
  load_shell_function "${SCRIPT}" resolve_repo_root

  local nowhere="${BATS_TEST_TMPDIR}/nowhere"
  local proven="${BATS_TEST_TMPDIR}/proven"
  mkdir -p "${nowhere}" "${proven}/scripts"
  printf 'x\n' >"${proven}/docker-compose.yml"

  REPO_ROOT=""
  GITHUB_WORKSPACE=""
  SELF_DIR="${nowhere}"
  cd "${nowhere}"

  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 5 ]
  assert_match "an unresolvable root is reported" 'unresolvable repo root' "${stderr}"
  assert_match "the marker it wanted is named" 'need docker-compose.yml' "${stderr}"

  cd "${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "the cwd marker is enough" "${proven}" "${output}"

  cd "${nowhere}"
  REPO_ROOT="${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "an explicit REPO_ROOT wins" "${proven}" "${output}"

  REPO_ROOT=""
  SELF_DIR="${proven}/scripts"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "the directory beside the script is enough" "${proven}/scripts/.." "${output}"
}

@test "seed-dev-env: --dry-run --home reports the plan and writes nothing" {
  local scratch home absent
  scratch="$(make_scratch)"
  home="${scratch}/home"
  mkdir -p "${home}"
  printf 'preexisting\n' >"${home}/keep.txt"
  local before_list="${scratch}/before.list" after_list="${scratch}/after.list"
  local before_sha="${scratch}/before.sha" after_sha="${scratch}/after.sha"
  (cd "${home}" && find . -print | sort) >"${before_list}"
  (cd "${home}" && find . -type f -exec sha256sum {} + | sort) >"${before_sha}"

  run_seed "${home}" --dry-run
  [ "${status}" -eq 0 ]
  assert_match "plan names a reseed" 'would re-materialize' "${output}"
  assert_match "helpers are part of the plan" 'grok-build-terminal: would re-materialize' "${output}"
  assert_match "notes lib is part of the plan" 'notes-setup.sh: would re-materialize' "${output}"
  assert_match "config is part of the plan" 'config.toml: would re-materialize' "${output}"
  [ "$(stub_log_count gh)" -eq 0 ]

  (cd "${home}" && find . -print | sort) >"${after_list}"
  (cd "${home}" && find . -type f -exec sha256sum {} + | sort) >"${after_sha}"
  cmp -s "${before_list}" "${after_list}"
  cmp -s "${before_sha}" "${after_sha}"

  absent="${scratch}/absent-home"
  run_seed "${absent}" --dry-run
  [ "${status}" -eq 0 ]
  [ ! -e "${absent}" ]
}

@test "seed-dev-env: a first seed into an empty home materializes the contributor set" {
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"
  [ ! -e "${home}" ]

  run_seed "${home}"
  [ "${status}" -eq 0 ]
  [ -d "${home}" ]
  assert_contributor_home "${home}" "http://host.docker.internal:4000/v1"
  # No origin on the payload root: the library is copied, the clone is not touched.
  [ ! -e "${SEED_ROOT}/notes.md" ]
  assert_match "origin skip is a note" 'notes.md left unmaterialized' "${output}"

  run_seed "${home}"
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'Grok Build CLI' "${home}/.bashrc")" -eq 1 ]
}

@test "seed-dev-env: --litellm-url is rendered into settings.json and config.toml" {
  local scratch home url
  scratch="$(make_scratch)"
  home="${scratch}/home"
  url="http://host.docker.internal:14000/v1"
  run_seed "${home}" --litellm-url "${url}"
  [ "${status}" -eq 0 ]
  assert_fixed "settings url" "${home}/.shared/vscode/settings.json" "${url}"
  assert_fixed "config url" "${home}/.grok/config.toml" "base_url = \"${url}\""
  assert_not_fixed "default port not baked in" "${home}/.grok/config.toml" "base_url = \"http://host.docker.internal:4000/v1\""
}

@test "seed-dev-env: a marker-free config.toml survives, and --force overwrites it" {
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"
  mkdir -p "${home}/.grok"
  printf 'user = true\n' >"${home}/.grok/config.toml"

  run_seed "${home}"
  [ "${status}" -eq 0 ]
  assert_fixed "user config kept" "${home}/.grok/config.toml" 'user = true'
  assert_not_fixed "marker not added" "${home}/.grok/config.toml" 'managed-by: evo-t1-coder-stack'
  assert_match "config skip names --force" 'config.toml: user-owned, left alone \(--force overrides\)' "${output}"

  run_seed "${home}" --force
  [ "${status}" -eq 0 ]
  assert_match "force names the overwrite" 'OVERWRITTEN under --force' "${output}"
  assert_grok_config "${home}/.grok/config.toml" "http://host.docker.internal:4000/v1"
  assert_not_fixed "user body replaced" "${home}/.grok/config.toml" 'user = true'
}

@test "seed-dev-env: a marker-free tmux.conf survives without --force" {
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"
  mkdir -p "${home}"
  printf 'set -g mouse off\n' >"${home}/.tmux.conf"

  run_seed "${home}"
  [ "${status}" -eq 0 ]
  assert_fixed "user tmux kept" "${home}/.tmux.conf" 'set -g mouse off'
  assert_not_fixed "stack tmux not written" "${home}/.tmux.conf" 'managed-by: evo-t1-coder-stack'
  assert_match "tmux skip names --force" 'user-owned, left alone \(--force overrides\)' "${output}"
}

@test "seed-dev-env: seed_render_grok_config drops gated blocks and unfolds" {
  load_seed_api
  local scratch out
  scratch="$(make_scratch)"
  out="${scratch}/config.toml"
  GH_TOKEN='SECRETVAL-ghp_example-sk-leak' \
    seed_render_grok_config "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" "${out}"
  assert_grok_config "${out}" "http://host.docker.internal:4000/v1"
  assert_not_fixed "token value not rendered" "${out}" 'SECRETVAL'
  assert_not_fixed "doubled dollar not left behind" "${out}" '$${'
  assert_not_fixed "no shell default left in toml" "${out}" '${SEARXNG_URL'

  SEARXNG_URL='http://host.docker.internal:18181' \
    seed_render_grok_config "${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl" "${out}"
  assert_fixed "SEARXNG_URL env wins" "${out}" 'SEARXNG_URL = "http://host.docker.internal:18181"'
  assert_not_fixed "default search assignment dropped" "${out}" \
    'SEARXNG_URL = "http://host.docker.internal:8181"'
}

@test "seed-dev-env: the context7 lane is kept when a key or --context7-mcp says so" {
  load_seed_api
  local scratch home out tpl
  scratch="$(make_scratch)"
  home="${scratch}/home"
  out="${scratch}/config.toml"
  tpl="${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl"

  # No key and no verdict: the keyless home keeps the context7-free file it
  # shipped with before the lane could be kept.
  seed_render_grok_config "${tpl}" "${out}" "${home}" 0
  assert_not_fixed "keyless home drops context7" "${out}" '[mcp_servers.context7]'

  # A key in the environment keeps the lane on its own, and the key stays a
  # reference the CLI expands from the agent environment.
  CONTEXT7_API_KEY='ctx7sk-SECRETVALUE-not-rendered' \
    seed_render_grok_config "${tpl}" "${out}" "${home}" 0
  assert_fixed "a key keeps the lane" "${out}" '[mcp_servers.context7]'
  assert_fixed "the proxy launches by absolute path" "${out}" \
    'command = "/opt/npm-global/bin/mcp-cache-proxy"'
  assert_fixed "the key stays a reference" "${out}" \
    'env = { CONTEXT7_API_KEY = "${CONTEXT7_API_KEY}" }'
  assert_fixed "the cache config is re-rooted at the seed home" "${out}" \
    "args = [\"--config\", \"${home}/.grok/mcp-cache-proxy/config.json\"]"
  assert_not_fixed "the key value never reaches the file" "${out}" 'SECRETVALUE'
  assert_not_fixed "no doubled dollar left behind" "${out}" '$${'
  assert_not_fixed "no if directive" "${out}" '%{if'
  assert_not_fixed "no endif directive" "${out}" '%{endif'
  assert_not_fixed "github stays dropped" "${out}" '[mcp_servers.github]'

  # The explicit verdict keeps it for a home that will get its key later.
  seed_render_grok_config "${tpl}" "${out}" "${home}" 1
  assert_fixed "the verdict keeps the lane with no key" "${out}" '[mcp_servers.context7]'

  # End to end through the CLI, the flag is what carries that verdict.
  run_seed "${home}" --context7-mcp
  [ "${status}" -eq 0 ]
  assert_fixed "the flag reaches the render" "${home}/.grok/config.toml" \
    '[mcp_servers.context7]'
  assert_not_fixed "the flag alone still drops github" "${home}/.grok/config.toml" \
    '[mcp_servers.github]'
}

@test "seed-dev-env: seed_write_helpers unfolds terraform dollars and dry-run writes nothing" {
  load_seed_api
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"
  mkdir -p "${home}"

  run seed_write_helpers "${home}" "${REPO_ROOT}" 1
  [ "${status}" -eq 0 ]
  assert_match "dry-run helper" 'would re-materialize' "${output}"
  [ ! -e "${home}/.grok" ]

  seed_write_helpers "${home}" "${REPO_ROOT}" 0
  assert_helpers "${home}"
}

@test "seed-dev-env: seed_write_notes_lib copies the library and materializes only with an origin" {
  load_seed_api
  local scratch home root
  scratch="$(make_scratch)"
  home="${scratch}/home"
  mkdir -p "${home}"
  root="$(payload_root)"

  run seed_write_notes_lib "${home}" "${root}" 1
  [ "${status}" -eq 0 ]
  assert_match "dry-run notes" 'would re-materialize' "${output}"
  [ ! -e "${home}/.grok/notes-setup.sh" ]

  seed_write_notes_lib "${home}" "${root}" 0
  assert_contains_file "copied marker" "${home}/.grok/notes-setup.sh" 'managed-by: evo-t1-coder-stack'
  [ ! -e "${root}/notes.md" ]

  git -C "${root}" init -q
  git -C "${root}" remote add origin "https://github.com/acme/notes-demo.git"
  seed_write_notes_lib "${home}" "${root}" 0
  assert_file_exists "clone notes" "${root}/notes.md"
  assert_file_exists "canonical notes" "${home}/.grok/notes/github.com/acme/notes-demo/notes.md"
  assert_fixed "stub landed" "${root}/notes.md" 'Private scratch notes'
}

@test "seed-dev-env: seed_link_vscode_settings moves a regular file aside and links both editors" {
  load_seed_api
  local scratch home shared
  scratch="$(make_scratch)"
  home="${scratch}/home"
  shared="${home}/.shared/vscode/settings.json"
  mkdir -p "${home}/.shared/vscode" \
    "${home}/.local/share/code-server/User" \
    "${home}/.config/Code/User"
  printf '{ "shared": true }\n' >"${shared}"
  printf 'OLD-CODE-SERVER\n' >"${home}/.local/share/code-server/User/settings.json"
  printf 'OLD-CODE\n' >"${home}/.config/Code/User/settings.json"

  run seed_link_vscode_settings "${home}" 1
  [ "${status}" -eq 0 ]
  assert_match "dry-run link" 'would link' "${output}"
  assert_fixed "dry-run left the regular file" \
    "${home}/.local/share/code-server/User/settings.json" 'OLD-CODE-SERVER'
  [ ! -L "${home}/.local/share/code-server/User/settings.json" ]

  seed_link_vscode_settings "${home}" 0
  assert_settings_link "${home}/.local/share/code-server/User/settings.json" "${shared}"
  assert_settings_link "${home}/.config/Code/User/settings.json" "${shared}"
  assert_fixed "code-server aside" \
    "${home}/.local/share/code-server/User/settings.json.pre-shared" 'OLD-CODE-SERVER'
  assert_fixed "code aside" \
    "${home}/.config/Code/User/settings.json.pre-shared" 'OLD-CODE'
}

@test "seed-dev-env: seed_write_grok_config carries [cli] and honors the marker" {
  load_seed_api
  local scratch home dest
  scratch="$(make_scratch)"
  home="${scratch}/home"
  dest="${home}/.grok/config.toml"
  mkdir -p "${home}/.grok"
  printf '%s\n' '# managed-by: evo-t1-coder-stack' 'default = "old"' '' '[cli]' 'installer = "kept"' >"${dest}"

  seed_write_grok_config "${home}" "${REPO_ROOT}" 0 0
  assert_grok_config "${dest}" "http://host.docker.internal:4000/v1"
  assert_fixed "cli carried" "${dest}" 'installer = "kept"'
  assert_not_fixed "old default dropped" "${dest}" 'default = "old"'

  local fresh="${scratch}/fresh"
  mkdir -p "${fresh}"
  run seed_write_grok_config "${fresh}" "${REPO_ROOT}" 1 0
  [ "${status}" -eq 0 ]
  assert_match "dry-run config" 'would re-materialize' "${output}"
  [ ! -e "${fresh}/.grok/config.toml" ]
}

@test "seed-dev-env: seed_write_bashrc_path appends once and dry-run writes nothing" {
  load_seed_api
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"
  mkdir -p "${home}"

  run seed_write_bashrc_path "${home}" 1
  [ "${status}" -eq 0 ]
  assert_match "dry-run bashrc" 'would append the grok bin PATH' "${output}"
  [ ! -e "${home}/.bashrc" ]

  seed_write_bashrc_path "${home}" 0
  assert_fixed "path line" "${home}/.bashrc" 'export PATH="$HOME/.grok/bin:$PATH"'
  seed_write_bashrc_path "${home}" 0
  [ "$(grep -c 'Grok Build CLI' "${home}/.bashrc")" -eq 1 ]
}

@test "seed-dev-env: seed_setup_git_credential calls gh only for a devcontainer with a token" {
  load_seed_api
  local home
  home="$(make_scratch)/home"
  mkdir -p "${home}"

  GH_TOKEN='SECRETVAL' seed_setup_git_credential "${home}" 0 0
  [ "$(stub_log_count gh)" -eq 0 ]

  GH_TOKEN='SECRETVAL' seed_setup_git_credential "${home}" 1 1
  [ "$(stub_log_count gh)" -eq 0 ]

  seed_setup_git_credential "${home}" 1 0
  [ "$(stub_log_count gh)" -eq 0 ]

  GH_TOKEN='SECRETVAL' seed_setup_git_credential "${home}" 1 0
  assert_match "setup-git argv" 'auth setup-git' "$(stub_log gh)"
  assert_not_match "token not in argv" 'SECRETVAL' "$(stub_log gh)"
  assert_eq "gh saw the target home" "${home}" "${HOME}"

  GITHUB_TOKEN='SECRETVAL' GH_TOKEN='' seed_setup_git_credential "${home}" 1 0
  [ "$(stub_log_count gh)" -eq 2 ]

  export STUB_GH_RC=1
  GH_TOKEN='SECRETVAL' run seed_setup_git_credential "${home}" 1 0
  [ "${status}" -eq 0 ]
  assert_match "failure is a note" 'gh auth setup-git failed - continuing' "${output}"
}

@test "seed-dev-env: seed_dev_env seeds one home tree and refuses a non-directory" {
  load_seed_api
  local scratch home root
  scratch="$(make_scratch)"
  home="${scratch}/home"
  root="$(payload_root)"
  seed_dev_env "${home}" "${root}" 0 0
  assert_contributor_home "${home}" "http://host.docker.internal:4000/v1"

  local notdir="${scratch}/notdir"
  printf 'x\n' >"${notdir}"
  run seed_dev_env "${notdir}" "${root}" 0 0
  [ "${status}" -eq 1 ]
  assert_match "non-directory home" 'not a directory' "${output}"
}

@test "seed-dev-env: --devcontainer calls gh auth setup-git, and dry-run does not" {
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"

  GH_TOKEN='SECRETVAL-ghp_example-sk-leak' run_seed "${home}" --devcontainer
  [ "${status}" -eq 0 ]
  assert_match "setup-git ran" 'auth setup-git' "$(stub_log gh)"
  assert_not_match "token not an argument" 'SECRETVAL' "$(stub_log gh)"
  assert_contributor_home "${home}" "http://host.docker.internal:4000/v1"
  assert_not_fixed "token absent from config" "${home}/.grok/config.toml" 'SECRETVAL'
  assert_not_fixed "token absent from settings" "${home}/.shared/vscode/settings.json" 'SECRETVAL'
  assert_not_fixed "token absent from grok helper" "${home}/.grok/bin/grok-build-terminal" 'SECRETVAL'
  assert_not_fixed "token absent from tmux helper" "${home}/.grok/bin/vscode-terminal-tmux" 'SECRETVAL'
  assert_not_fixed "ghp absent from config" "${home}/.grok/config.toml" 'ghp_'
  assert_not_fixed "sk absent from config" "${home}/.grok/config.toml" 'sk-'

  local home2="${scratch}/home-dry"
  mkdir -p "${home2}"
  GH_TOKEN='SECRETVAL' run_seed "${home2}" --devcontainer --dry-run
  [ "${status}" -eq 0 ]
  # The earlier call logged one gh line; this dry-run must not add another.
  [ "$(stub_log_count gh)" -eq 1 ]
  assert_match "dry-run says it skipped gh" 'not calling gh auth setup-git' "${output}"
}

@test "seed-dev-env: without --devcontainer gh is not called even when GH_TOKEN is set" {
  local scratch home
  scratch="$(make_scratch)"
  home="${scratch}/home"
  GH_TOKEN='SECRETVAL-ghp_example-sk-leak' run_seed "${home}"
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count gh)" -eq 0 ]
  assert_not_fixed "no token in config" "${home}/.grok/config.toml" 'SECRETVAL'
  assert_not_fixed "no ghp in settings" "${home}/.shared/vscode/settings.json" 'ghp_'
  assert_not_fixed "no sk in helper" "${home}/.grok/bin/grok-build-terminal" 'sk-'
}

@test "seed-dev-env: --devcontainer without gh on PATH notes and continues" {
  local scratch home saved
  scratch="$(make_scratch)"
  home="${scratch}/home"
  saved="${PATH}"
  PATH="/usr/bin:/bin"
  GH_TOKEN='SECRETVAL' run_seed "${home}" --devcontainer
  PATH="${saved}"
  [ "${status}" -eq 0 ]
  assert_match "missing gh is a note" 'gh is not on PATH - skipping gh auth setup-git' "${output}"
  assert_file_exists "seed still finished" "${home}/.tmux.conf"
  [ "$(stub_log_count gh)" -eq 0 ]
}

@test "seed-dev-env: a --home path that is not a directory is an error" {
  local scratch notdir
  scratch="$(make_scratch)"
  notdir="${scratch}/notdir"
  printf 'x\n' >"${notdir}"
  run_seed "${notdir}"
  [ "${status}" -eq 1 ]
  assert_match "die names the path" 'not a directory' "${output}"
}

@test "seed-dev-env: git hooks are armed only for a devcontainer checkout" {
  local root home
  root="$(make_scratch)"
  home="$(make_scratch)"
  command -v git >/dev/null 2>&1 || skip "git is not installed"
  # Loaded after the skip guard: common.sh defines its own skip.
  load_seed_api
  git init -q "${root}"
  mkdir -p "${root}/.githooks"
  printf '#!/usr/bin/env bash\n' >"${root}/.githooks/pre-commit"
  printf '#!/usr/bin/env bash\n' >"${root}/.githooks/pre-push"
  chmod 644 "${root}/.githooks/pre-commit" "${root}/.githooks/pre-push"

  # Not a devcontainer seed: a laptop or CI home keeps its own git config.
  seed_install_git_hooks "${root}" 0 0
  assert_eq "no hooksPath without --devcontainer" "" \
    "$(git -C "${root}" config --get core.hooksPath 2>/dev/null || true)"

  # Dry run reports and changes nothing.
  run seed_install_git_hooks "${root}" 1 1
  [ "${status}" -eq 0 ]
  assert_match "dry-run note" 'dry-run: not setting core.hooksPath' "${output}"
  assert_eq "dry-run wrote nothing" "" \
    "$(git -C "${root}" config --get core.hooksPath 2>/dev/null || true)"

  # The real arm sets the path and makes the hooks executable, because git skips
  # a hook it cannot run.
  run seed_install_git_hooks "${root}" 1 0
  [ "${status}" -eq 0 ]
  assert_eq "hooksPath armed" ".githooks" \
    "$(git -C "${root}" config --get core.hooksPath 2>/dev/null || true)"
  [ -x "${root}/.githooks/pre-commit" ] || fail "pre-commit left non-executable"
  [ -x "${root}/.githooks/pre-push" ] || fail "pre-push left non-executable"
}

@test "seed-dev-env: a root without .githooks or .git is a silent note, not a failure" {
  load_seed_api
  local root
  root="$(make_scratch)"

  # No .githooks at all: nothing to arm, and no noise.
  run seed_install_git_hooks "${root}" 1 0
  [ "${status}" -eq 0 ]
  assert_not_match "no note for a repo without hooks" 'git hooks' "${output}"

  # Hooks present but the root is not a checkout: say so, still succeed.
  mkdir -p "${root}/.githooks"
  : >"${root}/.githooks/pre-commit"
  : >"${root}/.githooks/pre-push"
  run seed_install_git_hooks "${root}" 1 0
  [ "${status}" -eq 0 ]
  assert_match "names the non-checkout" 'not a git checkout' "${output}"
}

@test "seed-dev-env: the contributor postCreate asks for the same lanes a workspace gets" {
  local dc="${REPO_ROOT}/.devcontainer/devcontainer.json"
  [ -f "${dc}" ] || skip "no contributor devcontainer in this tree"

  # The dev container is the laptop/CI twin of a workspace, and a workspace gets
  # the context7 docs lane by default. Without the flag the home is seeded
  # context7-free unless the environment happens to carry a key, which is how a
  # contributor ends up with a lane their workspaces have.
  run grep -o 'seed-dev-env\.sh[^"]*' "${dc}"
  [ "${status}" -eq 0 ]
  assert_match "postCreate seeds the home" 'seed-dev-env\.sh' "${output}"
  assert_match "as a devcontainer" '\-\-devcontainer' "${output}"
  assert_match "with the docs lane kept" '\-\-context7-mcp' "${output}"
}
