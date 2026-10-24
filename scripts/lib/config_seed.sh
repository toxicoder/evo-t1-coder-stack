#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## config_seed.sh - the reseed plumbing behind the two workspace-cleanup CLIs
# (sourced; never executed).
#
# One list of stack-owned payload files (the reseed set) plus the helpers that
# stage a payload, decide whether a workspace may receive a fresh copy, and
# transport the bytes. scripts/refresh-configs.sh and scripts/storage-clean.sh
# source this file so neither keeps a private copy of the reseed set.
#
# Invariants:
#   - Sourcing this file changes no shell options and no cwd; it inherits the
#     caller's `set -euo pipefail` like every other file under scripts/lib/,
#     and it sources common.sh (its helpers) when that has not been sourced
#     yet. Nothing here builds a command out of text with eval.
#   - Ownership contract, inherited from the two startup.sh.tftpl twins: a
#     stack-owned config file either carries `managed-by:
#     evo-t1-coder-stack` (comment marker) or the `"__evoT1Stack": true`
#     JSON key, or it is user-owned. A file that lost its marker was edited
#     by a human; reseeding leaves such a file alone unless --force is used.
#   - Container traffic is one `docker exec -i <name> sh -c <script> sh
#     <args...>` per probe or write. Probes close stdin (bazelisk run keeps
#     a pipe open, and docker exec -i waits for EOF on it); writes pass
#     --stdin and redirect the payload. No
#     `docker run`, no helper container, and no dev-only file ever lands in a
#     workspace volume. Paths and marker texts travel as separate argv words,
#     never interpolated into the script body, so the Bats docker stub can
#     replay a call and a test can point --container-root at a scratch tree.
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root cd):
#   SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/config_seed.sh disable=SC1091
#   source "${SELF_DIR}/lib/config_seed.sh"

if ! declare -f log >/dev/null 2>&1; then
  SELF_DIR="${SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  # shellcheck source=lib/common.sh disable=SC1091
  source "${SELF_DIR}/common.sh"
fi

# STACK_MARKER_TEXT / STACK_MARKER_JSON - the two spellings of the marker that
# marks a file as stack-owned. The comment form has to survive being embedded
# in a heredoc, and the JSON key carries the same promise inside settings.json.
STACK_MARKER_TEXT='managed-by: evo-t1-coder-stack'
STACK_MARKER_JSON='"__evoT1Stack": true'

# STACK_LITELLM_URL - the stack's one model-transport address as a workspace
# sees it. A workspace reaches LiteLLM through the host's published port, so
# the rendered editor settings must carry this exact spelling. The 4000 default
# is the stable stack's port: an env-file reseed for a dev stack that remapped
# LITELLM_PORT overrides it here (or with refresh-configs --litellm-url).
STACK_LITELLM_URL="${STACK_LITELLM_URL:-http://host.docker.internal:4000/v1}"

# @function seed_seed_targets
# Print the reseed set, one "<target path>\t<payload kind>:<source>" line per
# stack-owned target. Kinds: file (copy this repo file), block (lift the
# quoted-heredoc body out of the startup script), render (render this repo
# file, substituting ${litellm_url}, $${...} unfolds to ${...}, and carrying
# each target's own cline.apiKey / roo.openaiApiKey forward). Targets are
# home-relative (~/...) so --container-root can repoint them in a test.
# A twin pair is listed twice on purpose: the Coder Agents chat reads the
# ~/.coder copy, the Grok Build CLI reads the ~/.agents copy, and the two
# never dedupe each other.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One tab-separated line per reseed target
# Returns:
#   0
seed_seed_targets() {
  # The ~/... spellings below are home-relative KEYS, not tilde paths: the
  # readers strip the leading ~ and re-root the rest at $HOME or at the
  # --container-root, so nothing here must expand early.
  # shellcheck disable=SC2088
  printf '%s\n' \
    '~/.tmux.conf	block:templates/workspace/startup.sh.tftpl:TMUX_CONF_EOF' \
    '~/.shared/vscode/settings.json	render:templates/workspace/settings.json.tftpl' \
    '~/.grok/AGENTS.md	file:templates/common/GROK_BUILD_AGENTS.md' \
    '~/.coder/AGENTS.md	block:templates/workspace/startup.sh.tftpl:AGENT_INSTR_MD_EOF' \
    '~/.agents/INSTRUCTIONS.md	block:templates/workspace/startup.sh.tftpl:AGENT_INSTR_MD_EOF' \
    '~/.coder/skills/grok-build-delegation/SKILL.md	block:templates/workspace/startup.sh.tftpl:AGENT_SKILL_MD_EOF' \
    '~/.agents/skills/grok-build-delegation/SKILL.md	block:templates/workspace/startup.sh.tftpl:AGENT_SKILL_MD_EOF'
}

# @function seed_container_exec
# Run one POSIX sh snippet inside a running container with its arguments kept
# as separate argv words. With docker stubbed or absent this same argv shape
# runs on the host instead, which is how the Bats suites replay it. Stdin is
# closed unless the first argument is --stdin (payload writes).
# Globals:
#   None
# Arguments:
#   $1 - optional --stdin to inherit stdin; otherwise stdin is /dev/null
#   $1 or $2 - container name
#   $2 or $3 - the POSIX sh script body
#   remaining - the script's own arguments ($1, $2 ... inside it)
# Outputs:
#   Whatever the script printed
# Returns:
#   The script's status; 1 when the arguments are incomplete or the docker
#   CLI refused the exec
seed_container_exec() {
  local inherit_stdin=0 container script
  if [[ ${1:-} == --stdin ]]; then
    inherit_stdin=1
    shift
  fi
  container="${1:-}"
  script="${2:-}"
  shift 2
  if [[ -z ${container} || -z ${script} ]]; then
    return 1
  fi
  if [[ ${inherit_stdin} == 1 ]]; then
    docker exec -i "${container}" sh -c "${script}" sh "$@"
  else
    docker exec -i "${container}" sh -c "${script}" sh "$@" </dev/null
  fi
}

# @function seed_target_owner
# Ask one container (or one host directory standing in for one) who owns a
# config file right now.
# Globals:
#   STACK_MARKER_TEXT, STACK_MARKER_JSON
# Arguments:
#   $1 - container name ("" for a host path)
#   $2 - full path to the file
# Outputs:
#   One word on stdout: absent, managed, user or unreadable
# Returns:
#   0 unless the docker CLI refused to run the probe
seed_target_owner() {
  local target="${1:-}" path="${2:-}" state=""
  if [[ -z ${target} ]]; then
    if [[ ! -e ${path} ]]; then
      printf 'absent\n'
    elif [[ ! -r ${path} ]]; then
      printf 'unreadable\n'
    elif grep -qF -e "${STACK_MARKER_TEXT}" -e "${STACK_MARKER_JSON}" "${path}" 2>/dev/null; then
      printf 'managed\n'
    else
      printf 'user\n'
    fi
    return 0
  fi
  state="$(seed_container_exec "${target}" '
    if [ ! -e "${1}" ]; then printf "absent"; exit 0; fi
    if [ ! -r "${1}" ]; then printf "unreadable"; exit 0; fi
    if grep -qF -e "${2}" -e "${3}" "${1}" 2>/dev/null; then
      printf "managed"; exit 0
    fi
    printf "user"
  ' sh "${path}" "${STACK_MARKER_TEXT}" "${STACK_MARKER_JSON}")" || {
    return 1
  }
  case "${state}" in
    *absent*) printf 'absent\n' ;;
    *managed*) printf 'managed\n' ;;
    *unreadable*) printf 'unreadable\n' ;;
    *) printf 'user\n' ;;
  esac
  return 0
}

# @function seed_extract_tftpl_block
# Print the body of one quoted-heredoc block (the lines strictly between a
# line containing <<'DELIM' and the next lone DELIM line) from a .tftpl file.
# Globals:
#   None
# Arguments:
#   $1 - the .tftpl file to read
#   $2 - the heredoc delimiter, exactly as the file spells it
# Outputs:
#   The block body on stdout; one note on stderr when the block is not there
# Returns:
#   0 when a non-empty block was found, 1 when it is absent or empty or the
#   file cannot be read - never a crash either way
seed_extract_tftpl_block() {
  local file="${1:-}" delimiter="${2:-}" body=""
  if [[ ! -f ${file} ]]; then
    note "no ${file} to read a ${delimiter} block from - skipped"
    return 1
  fi
  body="$(awk -v opentext="<<'${delimiter}'" -v delim="${delimiter}" '
      !inside && index($0, opentext) { inside = 1; next }
      inside && $0 == delim { exit }
      inside { print }
    ' "${file}")"
  if [[ -z ${body} ]]; then
    note "no ${delimiter} block (or an empty one) in ${file} - skipped"
    return 1
  fi
  printf '%s\n' "${body}"
  return 0
}

# @function seed_key_value
# Print the last "key": "value" string value found in a JSON body, unquoted.
# Globals:
#   None
# Arguments:
#   $1 - the JSON text to read
#   $2 - the key to look for
# Outputs:
#   The value on stdout; nothing when the key is absent
# Returns:
#   0, always (a no-match sed stays invisible on purpose: it would otherwise
#   abort a strict-mode caller through pipefail)
seed_key_value() {
  printf '%s\n' "${1:-}" |
    sed -nE "s|.*\"${2}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*|\1|p" |
    tail -n 1
  return 0
}

# @function seed_render_settings
# Render a settings.json.tftpl into a staging file a workspace may receive:
# $${...} unfolds back to ${...}, ${litellm_url} becomes STACK_LITELLM_URL,
# and a cline.apiKey / roo.openaiApiKey the target already carries is copied
# forward (the seed in git carries no key; a workspace that was handed one on
# its first boot keeps it through a reseed).
# Globals:
#   STACK_LITELLM_URL
# Arguments:
#   $1 - the .tftpl source to render
#   $2 - the staging file to write
#   $3 - the target's current copy, when it has one ("" or absent otherwise)
# Outputs:
#   One note per refusal reason
# Returns:
#   1 (with the note) when nothing could be rendered or the carried key would
#   be lost; 0 when the staging file is ready
seed_render_settings() {
  local src="${1:-}" dest="${2:-}" current="${3:-}" rendered="" key=""
  if [[ ! -f ${src} ]]; then
    note "no ${src} to render - skipped"
    return 1
  fi
  rendered="$(mktemp "${TMPDIR:-/tmp}/evoT1Render.XXXXXX")" || {
    note "${src}: nowhere to stage the rendered copy - skipped"
    return 1
  }
  if ! sed -e 's/\$\${/${/g' -e "s|\${litellm_url}|${STACK_LITELLM_URL}|g" "${src}" \
    >"${rendered}"; then
    rm -f "${rendered}"
    note "${src}: rendering failed - skipped"
    return 1
  fi
  if [[ -n ${current} && -f ${current} ]]; then
    for key in cline.apiKey roo.openaiApiKey; do
      if grep -qE "\"${key}\"[[:space:]]*:" "${current}" 2>/dev/null; then
        if ! has_tool python3; then
          note "${current} carries ${key} but python3 is missing - the reseed stops short of dropping that key: skipped"
          rm -f "${rendered}"
          return 1
        fi
        if ! python3 - "${rendered}" "${current}" "${key}" <<'PY'; then
import json, sys
dest, current, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(current) as fh:
    old = json.load(fh)
if key not in old:
    sys.exit(0)
with open(dest) as fh:
    new = json.load(fh)
new[key] = old[key]
with open(dest, "w") as fh:
    json.dump(new, fh, indent=2)
    fh.write("\n")
PY
          note "${current} carries ${key} but is no longer valid JSON - the reseed stops short of guessing: skipped"
          rm -f "${rendered}"
          return 1
        fi
      fi
    done
  fi
  mv "${rendered}" "${dest}"
  return 0
}

# @function seed_volume_kind
# Classify one Docker volume name by what the stack keeps in it.
# Globals:
#   None
# Arguments:
#   $1 - volume name
# Outputs:
#   One word on stdout: grok-config, shared-config, home, docker-lib or nothing
# Returns:
#   0 when the kind is known, 1 when it is not
seed_volume_kind() {
  case "${1:-}" in
    grok-profile-*) printf 'grok-config\n' ;;
    vscode-settings-*) printf 'shared-config\n' ;;
    *-home) printf 'home\n' ;;
    *-dind-lib) printf 'docker-lib\n' ;;
    *) return 1 ;;
  esac
  return 0
}

# @function seed_workspace_containers
# Print the workspace containers a reseed or sweep may address: names from
# `docker ps` that start with coder-, minus the docker-in-docker sidecars.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One container name per line (none when no daemon answers)
# Returns:
#   0, always
seed_workspace_containers() {
  local names=""
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)" || return 0
  printf '%s\n' "${names}" | grep -E '^coder-' | grep -vE -- '-dind-sidecar$' || true
  return 0
}

# @function seed_sweep_stale
# List (action list) or remove (action delete) plain files that have not been
# modified in <days> days under each given root. Read-only under list.
# Globals:
#   None
# Arguments:
#   $1 - container name ("" for a host directory)
#   $2 - age cutoff in days, default 30
#   $3 - list or delete, default list
#   $4.. - absolute roots to sweep (nothing happens under an absent root)
# Outputs:
#   One line per listed or removed file
# Returns:
#   0 when the sweep ran (empty roots included), 1 on a bad action or an
#   exec the docker CLI refused
seed_sweep_stale() {
  local target="${1:-}" days="${2:-30}" action="${3:-list}"
  shift 3
  case "${action}" in
    list)
      if [[ -z ${target} ]]; then
        for root in "$@"; do
          [[ -d ${root} ]] || continue
          find "${root}" -type f -mtime +"${days}" -print
        done
        return 0
      fi
      seed_container_exec "${target}" '
        days="${1}"
        shift
        for root in "${@}"; do
          if [ -d "${root}" ]; then
            find "${root}" -type f -mtime +"${days}" -print
          fi
        done
      ' sh "${days}" "$@"
      ;;
    delete)
      if [[ -z ${target} ]]; then
        for root in "$@"; do
          [[ -d ${root} ]] || continue
          find "${root}" -type f -mtime +"${days}" -exec rm -f {} +
        done
        return 0
      fi
      seed_container_exec "${target}" '
        days="${1}"
        shift
        for root in "${@}"; do
          if [ -d "${root}" ]; then
            find "${root}" -type f -mtime +"${days}" -exec rm -f {} +
          fi
        done
      ' sh "${days}" "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

# @function seed_container_seed
# Re-materialize the whole reseed set into one target (a container name, a
# container's home-relative paths under a host directory standing in for one,
# or "" for the host itself). The decision per file belongs to the marker
# contract: absent gets a fresh seed, marker-carrying gets a reseed when the
# content drifted, marker-free stays untouched unless force is 1.
# Globals:
#   STACK_MARKER_TEXT, STACK_MARKER_JSON
# Arguments:
#   $1 - container name ("" for a host directory tree)
#   $2 - home root (where home-relative targets live)
#   $3 - repo root (where the payload sources live)
#   $4 - staging directory for one-file-at-a-time staging
#   $5 - 1 to report without writing anything (default 0)
#   $6 - 1 to overwrite user-owned files too (default 0)
# Outputs:
#   One line per reseed decision, one note per skipped payload
# Returns:
#   0, always
seed_container_seed() {
  local target="${1:-}" home="${2:-}" root="${3:-}" stage="${4:-}"
  local preview="${5:-0}" force="${6:-0}"
  local name kind source path staged current state verb forced=""

  [[ -d ${stage} ]] || return 0
  if [[ ${force} == "1" ]]; then
    forced=" (forced)"
  fi

  while IFS=$'\t' read -r path source; do
    [[ -n ${path} && -n ${source} ]] || continue
    name="${path#\~/}"
    kind="${source%%:*}"
    source="${source#*:}"
    path="${home}/${name}"
    staged="${stage}/staged"
    current="${stage}/current"
    rm -f "${staged}" "${current}"

    if [[ -z ${target} ]]; then
      state="$(seed_target_owner "" "${path}")"
    elif ! state="$(seed_target_owner "${target}" "${path}")"; then
      note "${target}:${name}: the probe could not run - skipped"
      continue
    fi

    if [[ ${state} == "user" || ${state} == "unreadable" ]]; then
      if [[ ${force} != "1" ]]; then
        printf '  %s: %s - user-owned, left alone (--force overrides)\n' "${name}" "${state}"
        continue
      fi
    fi

    if [[ ${state} != "absent" ]]; then
      if [[ -z ${target} ]]; then
        cat "${path}" >"${current}" 2>/dev/null || true
      else
        seed_container_exec "${target}" 'cat "${1}" 2>/dev/null' sh "${path}" >"${current}" || true
      fi
    fi

    case "${kind}" in
      file)
        if [[ ! -f "${root}/${source}" ]]; then
          note "${name}: ${source} is not in this checkout - skipped"
          continue
        fi
        printf '%s\n' "$(cat "${root}/${source}")" >"${staged}"
        ;;
      block)
        if ! seed_extract_tftpl_block "${root}/${source%:*}" "${source##*:}" >"${staged}"; then
          continue
        fi
        ;;
      render)
        if ! seed_render_settings "${root}/${source}" "${staged}" "${current}"; then
          continue
        fi
        ;;
      *)
        note "${name}: ${source} names no known payload kind - skipped"
        continue
        ;;
    esac

    if [[ ${state} != "absent" ]] && cmp -s "${current}" "${staged}"; then
      printf '  %s: already matches this checkout\n' "${name}"
      continue
    fi

    if [[ ${preview} == "1" ]]; then
      printf '  %s: would re-materialize%s\n' "${name}" "${forced}"
      continue
    fi

    verb="re-materialized"
    if [[ ${state} == "absent" ]]; then
      verb="seeded"
    elif [[ ${state} == "user" || ${state} == "unreadable" ]]; then
      verb="OVERWRITTEN under --force"
    fi

    if [[ -z ${target} ]]; then
      mkdir -p "$(dirname "${path}")"
      cp "${staged}" "${path}"
    elif ! seed_container_exec --stdin "${target}" '
        if [ ! -e "${1}" ]; then
          mkdir -p "$(dirname "${1}")" || exit 1
        fi
        cat > "${1}"
      ' sh "${path}" <"${staged}"; then
      printf '  %s: skipped (nothing could be written there)\n' "${name}"
      continue
    fi
    printf '  %s: %s\n' "${name}" "${verb}"
  done <<<"$(seed_seed_targets)"

  return 0
}
