#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## refresh-configs.sh - re-materialize the stack's managed workspace configs.
#
# Every workspace keeps live copies of the stack-owned config files (the
# shared ~/.grok/AGENTS.md and ~/.grok/config.toml family, the Coder Agents
# and Grok CLI copies under ~/.coder and ~/.agents, ~/.tmux.conf and the
# per-owner code-server settings.json). This script rewrites that set from
# the payload copies in THIS checkout into one or more running workspace
# containers, so an operator who changed the stack does not have to restart
# every workspace for the change to land. scripts/lib/config_seed.sh owns
# the reseed list; this script only chooses where to apply it.
#
# What this script never does:
#   - copy a dev-only file (anything under scripts/ or tests/) into a
#     workspace: the reseed list names only files the boot script seeds;
#   - overwrite a file the operator edited: a config file without the stack
#     marker is user-owned and stays untouched unless --force says
#     otherwise (a skipped file prints --force in its report line);
#   - start a helper container to move files (no docker run anywhere).
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:refresh-configs -- --dry-run
#   bazelisk run //scripts:refresh-configs -- --dry-run --json
#   bazelisk run //scripts:refresh-configs -- --force
#   bazelisk run //scripts:refresh-configs -- --container coder-demo --dry-run
#   bazelisk run //scripts:refresh-configs -- coder-demo coder-other
#
# Options (accepted anywhere in argv):
#   --dry-run            report the reseed plan without writing anything
#   --force              re-materialize user-owned files too (they stay
#                        untouched otherwise)
#   --json               one JSON object on stdout; the prose goes to stderr
#   --container <name>   reseed into this container instead of discovering
#                        the running coder-* containers; repeatable, and a
#                        bare word also names a container
#   --container-root <dir>  where config files live inside the target
#                        (default /home/coder; repoint it to dry-run against
#                        a scratch tree instead of a real workspace)
#   --home <dir>         treat this HOST directory as a workspace HOME tree
#                        (developer dry-runs and the Bats suites only)
#   --litellm-url <url>  the model-transport address to render into a reseeded
#                        settings.json; name it when this stack environment
#                        remapped LITELLM_PORT away from the default 4000
#   -h, --help           print the usage and exit 0
#
# Exit codes: 0 for a completed run and for every "nothing to do" skip
# (no docker CLI, no matching container); 1 for a usage error; 5 for an
# unresolvable repo root.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/config_seed.sh disable=SC1091
source "${SELF_DIR}/lib/config_seed.sh"

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
usage: bazelisk run //scripts:refresh-configs -- [--dry-run] [--force] [--json]
                       [--container <name> ...] [--home <dir> ...]
                       [--litellm-url <url>]

Rewrites the stack-owned workspace configs (the reseed list lives in
scripts/lib/config_seed.sh) from this checkout into the named containers;
without --container, every running coder-* container except the dind
sidecars is addressed. Files without the stack marker are user-owned and
stay untouched unless --force overrides that.

Options: --dry-run (report only), --force (overwrite user-owned files too),
--json (machine output on stdout, prose on stderr), --container <name>,
--container-root <dir> (path prefix inside the target, default /home/coder),
--home <dir> (host directory shaped like a workspace HOME; dev use),
--litellm-url <url> (the model-transport address rendered into a reseeded
settings.json; default http://host.docker.internal:4000/v1), -h/--help.

Examples (each line is the whole command, run from the repo root):
  bazelisk run //scripts:refresh-configs -- --dry-run
  bazelisk run //scripts:refresh-configs -- --force
  bazelisk run //scripts:refresh-configs -- --container coder-demo --dry-run
  bazelisk run //scripts:refresh-configs -- --litellm-url http://host.docker.internal:14000/v1
USAGE
}

# @function resolve_repo_root
# Print the repo root this run should read payloads from: the first
# candidate that holds docker-compose.yml (the marker of a real checkout).
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE
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

# @function main
# Parse argv, pick the reseed targets (containers, or a host HOME tree),
# and hand each one to seed_container_seed through one shared staging file.
# Globals:
#   JSON_MODE, STACK_LITELLM_URL (a --litellm-url argv wins over the default
#   carried from lib/config_seed.sh, and is assigned before the reseed loop)
# Arguments:
#   "$@" - the argv documented in the file header
# Outputs:
#   The reseed report on stdout; under --json one JSON object instead
# Returns:
#   0 when the plan ran or nothing addressed a target; 1 on a usage error;
#   5 when no repo root can be proven
main() {
  local -a targets=()
  local root="" stage="" stage_log="" t name target action first=1
  local CONTAINER_ROOT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --force) FORCE=1 ;;
      --json) JSON_MODE=1 ;;
      --container)
        if [ $# -lt 2 ]; then
          err "--container needs a container name"
          usage
          exit 1
        fi
        targets+=("c:$2")
        shift
        ;;
      --container-root)
        if [ $# -lt 2 ]; then
          err "--container-root needs a directory"
          usage
          exit 1
        fi
        CONTAINER_ROOT="$2"
        shift
        ;;
      --home)
        if [ $# -lt 2 ]; then
          err "--home needs a directory"
          usage
          exit 1
        fi
        targets+=("h:$2")
        shift
        ;;
      --litellm-url)
        if [ $# -lt 2 ]; then
          err "--litellm-url needs a url"
          usage
          exit 1
        fi
        # shellcheck disable=SC2034 # seed_render_settings (lib/config_seed.sh) is the reader
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
        targets+=("c:$1")
        ;;
    esac
    shift
  done

  root="$(resolve_repo_root)" || exit 5

  if [ "${#targets[@]}" -eq 0 ]; then
    if ! has_tool docker; then
      note "docker is not on PATH and no --home tree was named - nothing to reseed"
      exit 0
    fi
    while IFS= read -r name; do
      [ -n "${name}" ] && targets+=("c:${name}")
    done < <(seed_workspace_containers)
  fi
  if [ "${#targets[@]}" -eq 0 ]; then
    note "no coder-* workspace container is running - nothing to reseed"
    exit 0
  fi

  stage="$(mktemp -d "${TMPDIR:-/tmp}/evoT1Seed.XXXXXX")"
  stage_log="${stage}/decisions"
  : >"${stage_log}"

  if [ -n "${JSON_MODE:-}" ]; then
    printf '{"dry_run":%s,"force":%s,"entries":[' \
      "$([ "${DRY_RUN:-0}" = "1" ] && printf true || printf false)" \
      "$([ "${FORCE:-0}" = "1" ] && printf true || printf false)"
  fi

  for t in "${targets[@]}"; do
    case "${t}" in
      c:*)
        log "--- ${t#c:} ---"
        seed_container_seed "${t#c:}" "${CONTAINER_ROOT:-/home/coder}" "${root}" "${stage}" \
          "${DRY_RUN:-0}" "${FORCE:-0}" >"${stage_log}"
        if [ -z "${JSON_MODE:-}" ]; then
          cat "${stage_log}"
        fi
        ;;
      h:*)
        if [ ! -d "${t#h:}" ]; then
          warn "no ${t#h:} directory to reseed into - skipped"
          continue
        fi
        log "--- ${t#h:} (host directory) ---"
        seed_container_seed "" "${t#h:}" "${root}" "${stage}" \
          "${DRY_RUN:-0}" "${FORCE:-0}" >"${stage_log}"
        if [ -z "${JSON_MODE:-}" ]; then
          cat "${stage_log}"
        fi
        ;;
    esac

    if [ -n "${JSON_MODE:-}" ]; then
      while IFS= read -r line; do
        line="${line#  }"
        [ -n "${line}" ] || continue
        target="${line%%: *}"
        action="${line#*: }"
        if [ "${first}" -eq 1 ]; then
          first=0
        else
          printf ','
        fi
        printf '{"container":"%s","target":"%s","action":"%s"}' \
          "$(json_escape "${t#*:}")" "$(json_escape "${target}")" "$(json_escape "${action}")"
      done <"${stage_log}"
    fi
  done

  if [ -n "${JSON_MODE:-}" ]; then
    printf ']}\n'
  fi
  rm -rf "${stage}"
  return 0
}

main "$@"
