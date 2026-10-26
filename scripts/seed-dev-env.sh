#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## seed-dev-env.sh - seed a contributor home from the workspace templates (entry point).
#
# Materializes the same stack-owned Grok, editor, notes, tmux, and agent
# instruction files a Coder workspace writes at startup, into a laptop or CI
# home (and the devcontainer postCreate that calls this). Workspaces of this
# repo stay on the workspace template; this script does not rewrite those
# startup twins and it never talks to docker.
#
# What this script never does:
#   - write a secret, a GitHub token, or a PAT (gh auth setup-git is given
#     no token argument, and only when --devcontainer is set);
#   - overwrite a marker-free config unless --force says so (the helpers and
#     notes-setup.sh are the exception: startup rewrites those every boot);
#   - install the Grok CLI (the golden image already has /usr/local/bin/grok).
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:seed-dev-env -- [--home DIR] [--litellm-url URL] [--devcontainer] [--force] [--dry-run] [-h|--help]
#
# Options (accepted anywhere in argv):
#   --home <dir>         host directory shaped like a HOME tree (default $HOME).
#                        Created when absent. An existing non-directory is an error.
#   --litellm-url <url>  model-transport address rendered into settings.json
#                        and ~/.grok/config.toml (default
#                        http://host.docker.internal:4000/v1)
#   --devcontainer       after a successful write, if GH_TOKEN or GITHUB_TOKEN
#                        is set and gh is on PATH, run `gh auth setup-git`
#                        (best effort). Does not write EVO_T1_DEVCONTAINER.
#   --force              re-materialize user-owned files too
#   --dry-run            report the plan, write nothing, do not call gh
#   -h, --help           print the usage and exit 0
#
# Exit codes: 0 when the seed finished (a missing gh or a missing git origin
# is a note, not a failure); 1 for a usage error or a --home path that exists
# and is not a directory; 5 when no repo root can be proven.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/config_seed.sh disable=SC1091
source "${SELF_DIR}/lib/config_seed.sh"
# This CLI has no --json mode: a leftover JSON_MODE would send the report to stderr.
unset JSON_MODE

# @function usage
# Print the flag list on stdout, so a typo prints something readable.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE'
usage: bazelisk run //scripts:seed-dev-env -- [--home DIR] [--litellm-url URL] [--devcontainer] [--force] [--dry-run] [-h|--help]

Seeds a contributor HOME (laptop, CI, or a devcontainer postCreate) from the
same templates Coder workspace startup uses: tmux, editor settings, Grok
AGENTS.md, the Coder and Grok agent instruction twins, the terminal helpers,
notes-setup.sh, and ~/.grok/config.toml. Files without the stack marker are
user-owned and stay untouched unless --force overrides that. The helpers and
notes-setup.sh are rewritten on every run, the way startup cats them.

Options: --home <dir> (default $HOME; created when absent), --litellm-url
<url> (model-transport address; default http://host.docker.internal:4000/v1),
--devcontainer (best-effort `gh auth setup-git` when a token is in the
environment and gh is on PATH; never writes the token), --force (overwrite
user-owned files too), --dry-run (report only; do not call gh), -h/--help.

Examples (each line is the whole command, run from the repo root):
  bazelisk run //scripts:seed-dev-env -- --dry-run --home /tmp/contributor-home
  bazelisk run //scripts:seed-dev-env -- --home "${HOME}"
  bazelisk run //scripts:seed-dev-env -- --litellm-url http://host.docker.internal:14000/v1
  bazelisk run //scripts:seed-dev-env -- --devcontainer
USAGE
}

# @function resolve_repo_root
# Print the repo root this run should read payloads from: the first
# candidate that holds docker-compose.yml (the marker of a real checkout).
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE, SELF_DIR
# Arguments:
#   None
# Outputs:
#   The root on stdout, or one complaint line on stderr
# Returns:
#   The root on stdout; prints the complaint and returns 5 when none is proven
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}")
  candidates+=("${SELF_DIR}/..")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}/docker-compose.yml" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: unresolvable repo root: no proven checkout in %s (need docker-compose.yml)\n' \
    "${candidates[*]}" >&2
  return 5
}

# @function seed_render_grok_config
# Render grok-config.toml.tftpl for a contributor home. Contributor defaults
# are fixed here (no Coder Terraform variables): github, context7, and
# grok_config_extra blocks are dropped; the search block is kept; ${litellm_url}
# becomes STACK_LITELLM_URL; the model default is agent; the affinity key is
# contributor. Substitutions are sed, never eval. A doubled dollar unfolds
# to one dollar before the template variables are replaced.
# Globals:
#   STACK_LITELLM_URL, SEARXNG_URL (search URL default
#   http://host.docker.internal:8181, written as a concrete TOML string)
# Arguments:
#   $1 - the grok-config.toml.tftpl source
#   $2 - the destination file to write
# Outputs:
#   The rendered file at $2; one note per refusal
# Returns:
#   0 when the destination is ready; 1 when the source is missing or the
#   render failed
seed_render_grok_config() {
  local src="${1:-}" dest="${2:-}" rendered="" lbrace="" dollar='$' search=""
  # Octal keeps a literal brace out of this file so extract_fn's brace scan
  # stays balanced. The sed below unfolds a doubled dollar into one.
  lbrace="$(printf '\173')"
  search="${SEARXNG_URL:-http://host.docker.internal:8181}"
  if [[ -z ${src} || -z ${dest} ]]; then
    note "seed_render_grok_config needs a source and a destination"
    return 1
  fi
  if [[ ! -f ${src} ]]; then
    note "no ${src} to render - skipped"
    return 1
  fi
  rendered="$(mktemp "${TMPDIR:-/tmp}/evoT1Grok.XXXXXX")" || {
    note "${src}: nowhere to stage the rendered grok config - skipped"
    return 1
  }
  # Drop the gated blocks a contributor seed does not turn on. The search
  # block's own if/endif lines go too, but its body stays. Every endif is
  # consumed so a kept block does not leave a directive behind.
  # SELF_DIR is the entry's scripts/ dir; extracted-function tests set it too.
  if ! awk -f "${SELF_DIR:-${REPO_ROOT}/scripts}/lib/tftpl_strip_gates.awk" "${src}" | sed \
    -e "s|\\\$\\\$${lbrace}|${dollar}${lbrace}|g" \
    -e "s|\${litellm_url}|${STACK_LITELLM_URL}|g" \
    -e 's|\${grok_default_model}|agent|g' \
    -e 's|\${workspace_affinity_key}|contributor|g' \
    -e "s|\${search_url}|${search}|g" \
    >"${rendered}"; then
    rm -f "${rendered}"
    note "${src}: rendering the grok config failed - skipped"
    return 1
  fi
  mv "${rendered}" "${dest}"
  return 0
}

# @function seed_write_helpers
# Rewrite the two terminal helpers startup cats on every boot. They carry no
# ownership marker. Copied from templates/common/ (the same files startup
# interpolates via file()). --dry-run reports and writes nothing.
# Globals:
#   None
# Arguments:
#   $1 - home directory
#   $2 - repo root (payload source)
#   $3 - 1 to report without writing (default 0)
# Outputs:
#   One line per helper; one note when a payload file is missing
# Returns:
#   0, always
seed_write_helpers() {
  local home="${1:-}" root="${2:-}" preview="${3:-0}"
  local src="" name="" path=""
  for name in grok-build-terminal vscode-terminal-tmux; do
    src="${root}/templates/common/${name}.sh"
    path="${home}/.grok/bin/${name}"
    if [[ ! -f ${src} ]]; then
      note "no ${src} to copy - skipped"
      continue
    fi
    if [[ ${preview} == "1" ]]; then
      printf '  .grok/bin/%s: would re-materialize\n' "${name}"
      continue
    fi
    mkdir -p "${home}/.grok/bin"
    if ! cp "${src}" "${path}"; then
      note "could not write ${path} - skipped"
      rm -f "${path}"
      continue
    fi
    chmod +x "${path}"
    printf '  .grok/bin/%s: re-materialized\n' "${name}"
  done
  return 0
}

# @function seed_write_notes_lib
# Copy templates/common/notes-setup.sh to ~/.grok/notes-setup.sh (always
# rewritten; the file is stack-owned). When not a dry-run, source that copy
# with HOME pointed at the target home and, if the repo has an origin, call
# notes_materialize. A missing origin is a note, not a failure.
# Globals:
#   HOME (set to the target home before the library is sourced)
# Arguments:
#   $1 - home directory
#   $2 - repo root (payload source and the clone notes_materialize may touch)
#   $3 - 1 to report without writing (default 0)
# Outputs:
#   One decision line; one note when origin is absent or the library will not source
# Returns:
#   0, always
seed_write_notes_lib() {
  local home="${1:-}" root="${2:-}" preview="${3:-0}"
  local src="" dest="" origin="" ceiling=""
  src="${root}/templates/common/notes-setup.sh"
  dest="${home}/.grok/notes-setup.sh"
  if [[ ! -f ${src} ]]; then
    note "no ${src} to copy - skipped"
    return 0
  fi
  if [[ ${preview} == "1" ]]; then
    printf '  .grok/notes-setup.sh: would re-materialize\n'
    return 0
  fi
  mkdir -p "${home}/.grok"
  cp "${src}" "${dest}"
  printf '  .grok/notes-setup.sh: re-materialized\n'
  HOME="${home}"
  export HOME
  # shellcheck disable=SC1090
  if ! source "${dest}"; then
    note "could not source ${dest} - notes left unmaterialized"
    return 0
  fi
  # Stop git walking into a parent checkout. A payload directory that merely
  # lives inside another repo is not that repo, and must not inherit its origin.
  ceiling="$(cd "$(dirname "${root}")" && pwd -P)"
  if origin="$(GIT_CEILING_DIRECTORIES="${ceiling}" git -C "${root}" remote get-url origin 2>/dev/null)"; then
    GIT_CEILING_DIRECTORIES="${ceiling}" notes_materialize "${root}" "${origin}" || true
  else
    note "no git origin on ${root} - notes.md left unmaterialized"
  fi
  return 0
}

# @function seed_link_vscode_settings
# Point code-server and VS Code at the shared settings.json. A regular file
# already at either path is moved aside to settings.json.pre-shared once, then
# replaced with a symlink. --dry-run reports and writes nothing.
# Globals:
#   None
# Arguments:
#   $1 - home directory
#   $2 - 1 to report without writing (default 0)
# Outputs:
#   One line per link, or one note when the shared file is absent
# Returns:
#   0, always
seed_link_vscode_settings() {
  local home="${1:-}" preview="${2:-0}"
  local shared="" dest=""
  shared="${home}/.shared/vscode/settings.json"
  if [[ ${preview} == "1" ]]; then
    printf '  .local/share/code-server/User/settings.json: would link\n'
    printf '  .config/Code/User/settings.json: would link\n'
    return 0
  fi
  if [[ ! -f ${shared} ]]; then
    note "no ${shared} to link editor settings to - skipped"
    return 0
  fi
  mkdir -p "${home}/.local/share/code-server/User" "${home}/.config/Code/User"
  for dest in \
    "${home}/.local/share/code-server/User/settings.json" \
    "${home}/.config/Code/User/settings.json"; do
    if [[ -e ${dest} && ! -L ${dest} ]]; then
      mv "${dest}" "${dest}.pre-shared"
    fi
    ln -sfn "${shared}" "${dest}"
  done
  printf '  editor settings: linked to .shared/vscode/settings.json\n'
  return 0
}

# @function seed_write_grok_config
# Write ~/.grok/config.toml when it is absent or still stack-owned. A
# marker-free file is left alone unless --force is set. An existing [cli]
# table is carried forward the way startup does. The written file is mode 600.
# Globals:
#   STACK_MARKER_TEXT, STACK_LITELLM_URL (via seed_render_grok_config)
# Arguments:
#   $1 - home directory
#   $2 - repo root
#   $3 - 1 to report without writing (default 0)
#   $4 - 1 to overwrite a user-owned file (default 0)
# Outputs:
#   One decision line; one note when the render fails
# Returns:
#   0, always
seed_write_grok_config() {
  local home="${1:-}" root="${2:-}" preview="${3:-0}" force="${4:-0}"
  local src="" dest="" state="absent" staged="" cli_block="" forced=""
  src="${root}/templates/workspace/grok-config.toml.tftpl"
  dest="${home}/.grok/config.toml"
  if [[ ${force} == "1" ]]; then
    forced=" (forced)"
  fi
  if [[ -e ${dest} ]]; then
    if grep -qF "${STACK_MARKER_TEXT}" "${dest}" 2>/dev/null; then
      state="managed"
    else
      state="user"
    fi
  fi
  if [[ ${state} == "user" && ${force} != "1" ]]; then
    printf '  .grok/config.toml: user-owned, left alone (--force overrides)\n'
    return 0
  fi
  if [[ ${preview} == "1" ]]; then
    printf '  .grok/config.toml: would re-materialize%s\n' "${forced}"
    return 0
  fi
  staged="$(mktemp "${TMPDIR:-/tmp}/evoT1Grok.XXXXXX")"
  cli_block="$(mktemp "${TMPDIR:-/tmp}/evoT1Cli.XXXXXX")"
  if ! seed_render_grok_config "${src}" "${staged}"; then
    rm -f "${staged}" "${cli_block}"
    return 0
  fi
  if [[ -f ${dest} ]]; then
    awk '/^\[cli\][[:space:]]*$/{f=1;print;next} /^\[/{f=0} f' \
      "${dest}" >"${cli_block}" 2>/dev/null || : >"${cli_block}"
  else
    : >"${cli_block}"
  fi
  mkdir -p "${home}/.grok"
  {
    cat "${staged}"
    if [[ -s ${cli_block} ]]; then
      printf '\n'
      cat "${cli_block}"
    fi
  } >"${dest}"
  chmod 600 "${dest}"
  rm -f "${staged}" "${cli_block}"
  if [[ ${state} == "absent" ]]; then
    printf '  .grok/config.toml: seeded\n'
  elif [[ ${state} == "user" ]]; then
    printf '  .grok/config.toml: OVERWRITTEN under --force\n'
  else
    printf '  .grok/config.toml: re-materialized%s\n' "${forced}"
  fi
  return 0
}

# @function seed_write_bashrc_path
# Append the Grok bin PATH line to ~/.bashrc when that file does not already
# name grok/bin. An absent bashrc is created empty first. --dry-run reports
# and writes nothing. This does not install the Grok CLI.
# Globals:
#   None
# Arguments:
#   $1 - home directory
#   $2 - 1 to report without writing (default 0)
# Outputs:
#   One decision line, or one note when .bashrc is not a regular file
# Returns:
#   0, always
seed_write_bashrc_path() {
  local home="${1:-}" preview="${2:-0}"
  local rc=""
  rc="${home}/.bashrc"
  if [[ ${preview} == "1" ]]; then
    if [[ -f ${rc} ]] && grep -q 'grok/bin' "${rc}"; then
      printf '  .bashrc: already names grok/bin\n'
    else
      printf '  .bashrc: would append the grok bin PATH\n'
    fi
    return 0
  fi
  if [[ ! -e ${rc} ]]; then
    : >"${rc}"
  elif [[ ! -f ${rc} ]]; then
    note ".bashrc is not a regular file - skipped"
    return 0
  fi
  if grep -q 'grok/bin' "${rc}"; then
    printf '  .bashrc: already names grok/bin\n'
    return 0
  fi
  printf '\n# Grok Build CLI\nexport PATH="$HOME/.grok/bin:$PATH"\n' >>"${rc}"
  printf '  .bashrc: grok bin PATH appended\n'
  return 0
}

# @function seed_setup_git_credential
# Best-effort `gh auth setup-git` for --devcontainer, and only when GH_TOKEN
# or GITHUB_TOKEN is set. The token is never passed in argv and never written
# by this function. A missing gh, a dry-run, or a failing gh is a note (or a
# silent no-op); the seed still succeeds. HOME is pointed at the target home
# so gh does not edit some other home's gitconfig.
# Globals:
#   GH_TOKEN, GITHUB_TOKEN, HOME
# Arguments:
#   $1 - home directory gh should treat as HOME
#   $2 - 1 when --devcontainer was set (default 0)
#   $3 - 1 to report without calling gh (default 0)
# Outputs:
#   One note when a call is skipped or gh fails; nothing on the no-op paths
# Returns:
#   0, always
seed_setup_git_credential() {
  local home="${1:-}" devcontainer="${2:-0}" preview="${3:-0}"
  if [[ ${devcontainer} != "1" ]]; then
    return 0
  fi
  if [[ -z ${GH_TOKEN:-}${GITHUB_TOKEN:-} ]]; then
    return 0
  fi
  if [[ ${preview} == "1" ]]; then
    note "dry-run: not calling gh auth setup-git"
    return 0
  fi
  if ! has_tool gh; then
    note "gh is not on PATH - skipping gh auth setup-git"
    return 0
  fi
  if [[ -n ${home} ]]; then
    HOME="${home}"
    export HOME
  fi
  if ! gh auth setup-git; then
    note "gh auth setup-git failed - continuing"
  fi
  return 0
}

# @function seed_install_git_hooks
# Point this checkout's git hooks at .githooks, so a contributor container gets
# the commit and push gates without anyone remembering to install them. Scoped to
# --devcontainer for the same reason gh auth setup-git is: a laptop or CI home is
# not a place to change someone's git config unasked. Best-effort and idempotent;
# a missing git, a bare (non-checkout) root, or a failing git config is a note and
# the seed still succeeds.
# Globals:
#   None
# Arguments:
#   $1 - repository root to configure
#   $2 - 1 when --devcontainer was set (default 0)
#   $3 - 1 to report without calling git (default 0)
# Outputs:
#   One phase or note line; nothing on the no-op paths
# Returns:
#   0, always
seed_install_git_hooks() {
  local root="${1:-}" devcontainer="${2:-0}" preview="${3:-0}"
  if [[ ${devcontainer} != "1" ]]; then
    return 0
  fi
  if [[ -z ${root} || ! -d ${root}/.githooks ]]; then
    return 0
  fi
  if [[ ! -d ${root}/.git ]]; then
    note "${root} is not a git checkout - skipping the git hooks"
    return 0
  fi
  if [[ ${preview} == "1" ]]; then
    note "dry-run: not setting core.hooksPath"
    return 0
  fi
  if ! has_tool git; then
    note "git is not on PATH - skipping core.hooksPath"
    return 0
  fi
  # git skips a hook it cannot execute, and a contents-API checkout carries the
  # hooks as 100644, so the mode bit is set here as well as by //scripts:install-hooks.
  if ! chmod 755 "${root}/.githooks/pre-commit" "${root}/.githooks/pre-push" 2>/dev/null; then
    note "could not make .githooks executable - skipping core.hooksPath"
    return 0
  fi
  if ! git -C "${root}" config core.hooksPath .githooks; then
    note "git config core.hooksPath failed - continuing"
  fi
  return 0
}

# @function seed_dev_env
# Seed one home tree: the shared reseed set, then the contributor extras
# (helpers, notes library, editor symlinks, grok config, bashrc PATH).
# Globals:
#   None (callees read STACK_LITELLM_URL and the marker texts)
# Arguments:
#   $1 - home directory
#   $2 - repo root
#   $3 - 1 to report without writing (default 0)
#   $4 - 1 to overwrite user-owned files (default 0)
# Outputs:
#   The reseed report on stdout
# Returns:
#   0 when the home was seeded or reported; 1 when home or root is unusable
seed_dev_env() {
  local home="${1:-}" root="${2:-}" preview="${3:-0}" force="${4:-0}"
  local stage=""
  if [[ -z ${home} || -z ${root} ]]; then
    err "seed_dev_env needs a home directory and a repo root"
    return 1
  fi
  if [[ -e ${home} && ! -d ${home} ]]; then
    err "--home ${home} exists and is not a directory"
    return 1
  fi
  # A dry-run must not create the home either: "write nothing" includes the
  # directory itself. The real seed creates it so a first boot has somewhere
  # to land.
  if [[ ${preview} != "1" ]]; then
    mkdir -p -- "${home}"
  fi
  section "contributor home"
  log "--- ${home} (contributor home) ---"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/evoT1Seed.XXXXXX")"
  phase "writing helpers, notes, and editor links"
  seed_container_seed "" "${home}" "${root}" "${stage}" "${preview}" "${force}"
  seed_write_helpers "${home}" "${root}" "${preview}"
  seed_write_notes_lib "${home}" "${root}" "${preview}"
  seed_link_vscode_settings "${home}" "${preview}"
  phase "rendering grok config"
  seed_write_grok_config "${home}" "${root}" "${preview}" "${force}"
  phase "writing bashrc PATH"
  seed_write_bashrc_path "${home}" "${preview}"
  rm -rf "${stage}"
  if [[ ${preview} == "1" ]]; then
    ok "planned contributor home ${home}"
  else
    ok "contributor home ${home}"
  fi
  return 0
}

# @function main
# Parse argv and seed one contributor home from this checkout.
# Globals:
#   STACK_LITELLM_URL (a --litellm-url argv wins over the default carried
#   from lib/config_seed.sh and is assigned before the seed)
# Arguments:
#   "$@" - the argv documented in the file header
# Outputs:
#   The seed report on stdout
# Returns:
#   0 when the seed finished; 1 on a usage error or a non-directory --home;
#   5 when no repo root can be proven
main() {
  local home="${HOME:-}"
  local devcontainer=0
  local preview=0
  local force=0
  local root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) preview=1 ;;
      --force) force=1 ;;
      --devcontainer) devcontainer=1 ;;
      --home)
        if [[ $# -lt 2 ]]; then
          err "--home needs a directory"
          usage
          exit 1
        fi
        home="$2"
        shift
        ;;
      --litellm-url)
        if [[ $# -lt 2 ]]; then
          err "--litellm-url needs a url"
          usage
          exit 1
        fi
        # shellcheck disable=SC2034 # seed_render_settings and seed_render_grok_config read it
        STACK_LITELLM_URL="$2"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --*)
        err "unknown option: $1"
        usage
        exit 1
        ;;
      *)
        err "unexpected argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  root="$(resolve_repo_root)" || exit 5

  if [[ -z ${home} ]]; then
    err "--home needs a directory"
    usage
    exit 1
  fi
  if [[ -e ${home} && ! -d ${home} ]]; then
    die "--home ${home} exists and is not a directory"
  fi

  seed_dev_env "${home}" "${root}" "${preview}" "${force}" || exit 1
  seed_setup_git_credential "${home}" "${devcontainer}" "${preview}"
  seed_install_git_hooks "${root}" "${devcontainer}" "${preview}"
  summary
  return 0
}

main "$@"
