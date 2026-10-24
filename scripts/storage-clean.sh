#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## storage-clean.sh - sweep stale files and re-sync configs in workspace storage.
#
# The persistent layer of this stack is not the compose project but the
# volumes that survive it: one shared ~/.grok profile per owner, one
# code-server settings.json per owner, and each workspace's home volume.
# This script is the interactive janitor for that layer. Three sections:
#
#   1. a read-only disk report (docker system df + the dev project's and the
#      workspaces' named volumes);
#   2. a stale-file sweep: plain files older than --older-than days under
#      the workspace-HOME caches (~/.grok/logs, ~/.npm/_cacache, ~/.cache/uv);
#   3. a config re-sync: the reseed list from scripts/lib/config_seed.sh is
#      re-materialized into each running workspace container, on exactly the
#      boot script's rules (absent gets seeded, marker-carrying stays
#      stack-managed, marker-free is user-owned and stays untouched; this
#      tool never overrides that with a --force of its own).
#
# Destructive steps (2-delete and 3-write) need consent: --check (or
# --dry-run) means report-only, --yes means do it without asking, and
# without either the script asks once per workspace and reads the answer
# from stdin (EOF or any answer other than y/yes declines).
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:storage-clean -- --check
#   bazelisk run //scripts:storage-clean -- --check --older-than 14
#   bazelisk run //scripts:storage-clean -- --older-than 14 --yes
#   bazelisk run //scripts:storage-clean -- --project-name evo-t1-review --check
#   bazelisk run //scripts:storage-clean -- --container coder-demo
#
# Options (accepted anywhere in argv):
#   -c, --check           report only: list stale files, report config drift,
#                         change nothing (alias: --dry-run)
#   -y, --yes             skip the per-workspace y/N question and act
#   -o, --older-than <n>  age cutoff in days for the sweep, default 30
#   -p, --project-name <name>  dev compose project to report (default
#                              evo-t1-dev; dev-stack reset --yes tears a
#                              project down, this script only reports)
#   --container <name>    address this container instead of the running
#                         coder-* set; repeatable, bare words name too
#   --home <dir>          treat this HOST directory as a workspace HOME tree
#                         (developer dry-runs and the Bats suites only)
#   -h, --help            print the usage and exit 0
#
# Exit codes: 0 for a completed or skipped run; 1 for a usage error;
# 5 for an unresolvable repo root.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/config_seed.sh disable=SC1091
source "${SELF_DIR}/lib/config_seed.sh"

# @function usage
# Print the subcommand and flag list on stdout, so a typo prints something readable.
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
usage: bazelisk run //scripts:storage-clean -- [--check] [--yes] [--older-than <days>]
                     [--project-name <name>] [--container <name> ...]
                     [--home <dir> ...]

Reports workspace disk usage, sweeps files older than --older-than days
out of the workspace-HOME caches, and re-syncs the stack-owned config
files (same reseed list as refresh-configs; user-owned files are never
overwritten here). --check reports only; acting without --yes asks first.

Options: -c/--check (alias --dry-run), -y/--yes, -o/--older-than (default
30), -p/--project-name (default evo-t1-dev), --container <name>,
--home <dir> (dev use), -h/--help.

Examples (each line is the whole command, run from the repo root):
  bazelisk run //scripts:storage-clean -- --check
  bazelisk run //scripts:storage-clean -- --older-than 14 --yes
  bazelisk run //scripts:storage-clean -- --project-name evo-t1-review --check
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

# @function report_disk_usage
# Print one read-only disk report: what the Docker provider holds overall,
# which named volumes belong to the dev compose project, and which volume
# kinds the stack keeps. Listing only - tearing a project down is
# dev-stack's reset command, which is why this one has no --force.
# Globals:
#   None
# Arguments:
#   $1 - compose project name whose volumes are worth naming
# Outputs:
#   One heading line plus the listing lines on stdout
# Returns:
#   0, always (an unresponsive docker CLI is a report, not a failure)
report_disk_usage() {
  local project="${1:-evo-t1-dev}" df="" names="" name kind

  log "--- disk usage ---"
  if ! df="$(docker system df 2>/dev/null)"; then
    log "  docker system df did not answer - no daemon, no report"
    return 0
  fi
  if [ -n "${df}" ]; then
    printf '%s\n' "${df}" | sed 's/^/  /'
  fi
  names="$(docker volume ls -q --filter "name=${project}" 2>/dev/null)" || names=""
  if [ -n "${names}" ]; then
    log "  volumes named for the ${project} project:"
    while IFS= read -r name; do
      [ -n "${name}" ] || continue
      if kind="$(seed_volume_kind "${name}")"; then
        log "    ${name} (${kind})"
      else
        log "    ${name}"
      fi
    done <<<"${names}"
    log "  to tear the whole dev project down: bazelisk run //scripts:dev-stack -- reset --yes"
  fi
  return 0
}

# @function sweep_stale_files
# List (check mode) or sweep (acting mode) files older than the cutoff in
# one target's cache roots. Acting mode first lists, then removes.
# Globals:
#   None
# Arguments:
#   $1 - container name ("" for a host directory tree)
#   $2 - the target's HOME root
#   $3 - cutoff age in days
#   $4 - 1 = report only, 0 = sweep after listing
# Outputs:
#   One line per stale file found (and the swept-away note when sweeping)
# Returns:
#   0, always
sweep_stale_files() {
  local target="${1:-}" home="${2:-}" days="${3:-30}" check="${4:-1}"
  local -a roots=()
  local root listing=""

  for root in "${home}/.grok/logs" "${home}/.npm/_cacache" "${home}/.cache/uv"; do
    if [ -z "${target}" ] && [ ! -d "${root}" ]; then
      continue
    fi
    roots+=("${root}")
  done
  if [ "${#roots[@]}" -eq 0 ]; then
    return 0
  fi

  listing="$(seed_sweep_stale "${target}" "${days}" list "${roots[@]}")"
  if [ -n "${listing}" ]; then
    printf '%s\n' "${listing}" | sed 's/^/  stale: /'
  fi
  if [ "${check}" != "1" ]; then
    log "  sweeping those files now"
    seed_sweep_stale "${target}" "${days}" delete "${roots[@]}" >/dev/null 2>&1 ||
      warn "the sweep could not run there - left untouched"
  fi
  return 0
}

# @function main
# Parse argv, decide the targets, and drive report, sweep and re-sync per
# target - gated by --check/--yes/the per-target y/N question.
# Globals:
#   CHECK_ONLY, CONFIRMED
# Arguments:
#   "$@" - the argv documented in the file header
# Outputs:
#   The report on stdout (prose)
# Returns:
#   0 when the run completed or skipped; 1 on a usage error; 5 on an
#   unresolvable repo root
main() {
  local -a targets=()
  local root="" stage="" t home_root="" days=30 project="evo-t1-dev"
  local answer="" act=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --check | --dry-run) CHECK_ONLY=1 ;;
      --yes) CONFIRMED=1 ;;
      --older-than | -o)
        if [ $# -lt 2 ] || ! printf '%s' "$2" | grep -qxE '[0-9]+'; then
          err "--older-than needs a number of days"
          usage
          exit 1
        fi
        days="$2"
        shift
        ;;
      --project-name | -p)
        if [ $# -lt 2 ]; then
          err "--project-name needs a name"
          usage
          exit 1
        fi
        project="$2"
        shift
        ;;
      --container)
        if [ $# -lt 2 ]; then
          err "--container needs a container name"
          usage
          exit 1
        fi
        targets+=("c:$2")
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
      note "docker is not on PATH and no --home tree was named - nothing to clean"
      exit 0
    fi
    while IFS= read -r name; do
      [ -n "${name}" ] && targets+=("c:${name}")
    done < <(seed_workspace_containers)
  fi

  report_disk_usage "${project}"
  if [ "${#targets[@]}" -eq 0 ]; then
    note "no coder-* workspace container is running - nothing to sweep or re-sync"
    exit 0
  fi

  stage="$(mktemp -d "${TMPDIR:-/tmp}/evoT1Clean.XXXXXX")"
  for t in "${targets[@]}"; do
    case "${t}" in
      c:*) home_root="/home/coder" ;;
      h:*) home_root="${t#h:}" ;;
    esac
    if [ "${t#c:}" = "${t}" ] && [ ! -d "${home_root}" ]; then
      warn "no ${home_root} directory to clean - skipped"
      continue
    fi

    log "--- ${t#*:} ---"
    act=0
    if [ -n "${CHECK_ONLY:-}" ]; then
      log "  report only"
    elif [ -n "${CONFIRMED:-}" ]; then
      act=1
    else
      printf 'sweep stale files and re-sync configs in %s? [y/N] ' "${t#*:}"
      if [ -t 0 ]; then
        if ! IFS= read -r answer; then
          answer=""
        fi
      else
        # bazelisk run keeps stdin open with no EOF; without -t this waits forever.
        # A piped y/n (or </dev/null) still returns immediately.
        if ! IFS= read -r -t 15 answer; then
          answer=""
        fi
      fi
      case "${answer}" in
        [yY] | [yY][eE][sS])
          act=1
          ;;
        *)
          log "  left as it is (report only; --yes acts without asking)"
          ;;
      esac
    fi

    if [ "${act}" = "1" ]; then
      if [ "${t%%:*}" = "c" ]; then
        sweep_stale_files "${t#c:}" "${home_root}" "${days}" 0
        seed_container_seed "${t#c:}" "${home_root}" "${root}" "${stage}" 0 0
      else
        sweep_stale_files "" "${home_root}" "${days}" 0
        seed_container_seed "" "${home_root}" "${root}" "${stage}" 0 0
      fi
    else
      if [ "${t%%:*}" = "c" ]; then
        sweep_stale_files "${t#c:}" "${home_root}" "${days}" 1
        seed_container_seed "${t#c:}" "${home_root}" "${root}" "${stage}" 1 0
      else
        sweep_stale_files "" "${home_root}" "${days}" 1
        seed_container_seed "" "${home_root}" "${root}" "${stage}" 1 0
      fi
    fi
  done
  rm -rf "${stage}"
  return 0
}

main "$@"
