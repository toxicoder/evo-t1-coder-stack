#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## session-archive.sh - read the out-of-band Grok session archive from the host.
#
# The workspace templates mount one host-wide named volume, grok-session-archive, at
# /var/lib/grok-session-archive, and stage 9 of each startup script mirrors that
# workspace's ~/.grok/sessions into workspaces/<hostname>/ on it every 180 seconds.
# That copy exists for exactly one consumer: an operator, later, from outside the
# workspace that wrote it. Nothing inside a workspace reads it - no config key, no
# startup logic, no agent rule points at the path, and the hooks deny list refuses any
# agent command that names it. This CLI is the sanctioned reader, and it runs where the
# deny list does not: on the stack host, or in the Hermes container.
#
# Every verb reaches the volume through one read-only container mount, so the archive
# cannot be written from here either. There is no pruning verb on purpose: the volume
# grows until an operator removes it (`docker volume rm` after every workspace holding
# it is stopped), and a CLI that could delete session history would be the one thing
# this archive is supposed to protect against.
#
# Usage:
#   bazelisk run //scripts:session-archive [--volume NAME] [--image NAME]
#                                         [--timeout SECS] [-h|--help]
#                                         SUBCOMMAND [ARGS...]
#
# Subcommands:
#   list                      archived workspaces, with file count and size
#   show WORKSPACE            the session files archived for one workspace
#   export WORKSPACE [DIR]    copy one workspace leaf out (default DIR under /tmp)
#   check                     why another verb printed nothing (daemon, volume, image)
#
# Options: --volume NAME (default grok-session-archive, or $SESSION_ARCHIVE_VOLUME),
# --image NAME (default alpine, or $SESSION_ARCHIVE_IMAGE), --timeout SECS, -h|--help.
#
# Exit codes: 0 when the verb found something, 1 on a soft failure (no daemon, no
# volume, empty leaf), 2 on a usage error.
#
# Where to run it: the stack host, or any shell that can address the daemon holding the
# volume. From inside a Coder workspace `docker` addresses that workspace's own DinD
# sidecar, which has never seen this volume, so a workspace-side run reports the volume
# as missing - which is the correct answer from there, not a defect.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# DOCKER_BIN and stack_timeout come from the same library the other daemon-facing CLIs
# use, so this one caps and addresses docker the way the rest of the stack does.
# shellcheck source=lib/coder_api.sh disable=SC1091
source "${SELF_DIR}/lib/coder_api.sh"

# This CLI prints no JSON object, so the flag the report verbs key on has to go: a
# JSON_MODE left set by the environment would route ok: and warn: to stderr.
unset JSON_MODE

ARCHIVE_VOLUME="${SESSION_ARCHIVE_VOLUME:-grok-session-archive}"
ARCHIVE_IMAGE="${SESSION_ARCHIVE_IMAGE:-alpine}"
# Where the volume lands inside the throwaway container. Fixed, because the in-container
# bodies below read it from this exact environment variable.
ARCHIVE_ROOT="/archive"
TIMEOUT_SECS="${PROBE_TIMEOUT:-30}"
# An export streams a tar of a whole leaf, which is slower than a probe.
EXPORT_TIMEOUT_SECS="${SESSION_ARCHIVE_EXPORT_TIMEOUT:-300}"
VERB=""
TARGET=""
EXPORT_DIR=""

# @function usage
# Print the subcommand list, the flag list and the exit-code contract on stdout.
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
usage: bazelisk run //scripts:session-archive [--volume NAME] [--image NAME]
                    [--timeout SECS] [-h|--help] SUBCOMMAND [ARGS...]

Reads the host-wide grok-session-archive volume the workspace boot mirrors
~/.grok/sessions into. The archive is written by the workspace and read only
here: nothing inside a workspace uses it, and every verb mounts the volume
read-only, so this CLI cannot write it either.

Subcommands:
  list                      archived workspaces, with file count and size
  show WORKSPACE            the session files archived for one workspace
  export WORKSPACE [DIR]    copy one workspace leaf out (default /tmp/<name>)
  check                     why another verb printed nothing (daemon, volume, image)

Options: --volume NAME, --image NAME (default alpine), --timeout SECS, -h|--help.

Run this on the stack host or in Hermes. Inside a Coder workspace `docker`
addresses that workspace's DinD sidecar, which never held this volume.

Exit codes: 0 found, 1 soft failure (no daemon, no volume, empty leaf), 2 usage.
USAGE
}

# @function validate_leaf
# Refuse a workspace leaf name that is not one safe path segment, before it reaches the
# container's shell. The hostname the boot writes under is built from $(hostname) and
# lands as a single directory, so anything else here is a typo or an attempt.
# Globals:
#   None
# Arguments:
#   $1 - the candidate leaf name
# Outputs:
#   An error line on stderr when the name is refused
# Returns:
#   0 when the name is a safe single segment, 2 otherwise
validate_leaf() {
  local candidate="${1:-}"
  if [ -z "${candidate}" ] || [ "${candidate}" = "." ] || [ "${candidate}" = ".." ]; then
    err "a workspace leaf name is required (see: list)"
    return 2
  fi
  if [[ ! ${candidate} =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "refusing '${candidate}': a leaf name is one path segment of [A-Za-z0-9._-]"
    return 2
  fi
  return 0
}

# @function archive_run
# Run one command in a throwaway container over the archive volume, mounted read-only.
# The in-container bodies read the mount point from EVO_ARCHIVE_ROOT rather than
# hard-coding it, so ARCHIVE_ROOT stays the one place that name is set.
# Globals:
#   DOCKER_BIN ARCHIVE_VOLUME ARCHIVE_IMAGE ARCHIVE_ROOT TIMEOUT_SECS
# Arguments:
#   $@ - the command and arguments to run inside the container
# Outputs:
#   The container's stdout on stdout, its stderr on stderr
# Returns:
#   The container's status, or 124 when timeout cuts it off
archive_run() {
  # shellcheck disable=SC2086  # an empty-suffix DOCKER_BIN may legitimately be two words
  stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} run --rm \
    -v "${ARCHIVE_VOLUME}:${ARCHIVE_ROOT}:ro" \
    -e "EVO_ARCHIVE_ROOT=${ARCHIVE_ROOT}" \
    "${ARCHIVE_IMAGE}" "$@" </dev/null
}

# @function cmd_list
# Print one line per archived workspace leaf: name, file count, size.
# Globals:
#   ARCHIVE_ROOT
# Arguments:
#   None
# Outputs:
#   One "name  N files  SIZE" line per leaf, nothing when the archive is empty
# Returns:
#   0 when at least one leaf printed, 1 when the archive held nothing
cmd_list() {
  local rows
  section "archived workspaces in ${ARCHIVE_VOLUME}"
  rows="$(archive_run sh -c '
    root="$1"
    cd "${root}/workspaces" 2>/dev/null || exit 0
    for leaf in *; do
      [ -d "${leaf}" ] || continue
      files=$(find "${leaf}" -type f 2>/dev/null | wc -l | tr -d " ")
      size=$(du -sh "${leaf}" 2>/dev/null | cut -f1)
      printf "%s\t%s files\t%s\n" "${leaf}" "${files}" "${size:-unknown}"
    done
  ' sh "${ARCHIVE_ROOT}")"
  if [ -z "${rows}" ]; then
    warn "no workspace leaves in ${ARCHIVE_VOLUME} yet"
    note "the mirror starts at boot stage 9; a workspace that never booted archives nothing"
    return 1
  fi
  printf '%s\n' "${rows}" | while IFS=$'\t' read -r leaf files size; do
    printf '  %-40s %10s  %s\n' "${leaf}" "${files}" "${size}"
  done
  ok "archived leaves listed"
  return 0
}

# @function cmd_show
# Print the archived file list for one workspace leaf, paths relative to that leaf.
# Globals:
#   ARCHIVE_ROOT TARGET
# Arguments:
#   None (reads TARGET)
# Outputs:
#   One relative path per archived file, and a count line
# Returns:
#   0 when the leaf had files, 1 when it was missing or empty, 2 on a bad name
cmd_show() {
  validate_leaf "${TARGET}" || return 2
  local rows status=0
  section "archived sessions for ${TARGET}"
  rows="$(archive_run sh -c '
    root="$1"
    leaf="$2"
    dir="${root}/workspaces/${leaf}"
    [ -d "${dir}" ] || exit 0
    cd "${dir}" || exit 0
    find . -type f 2>/dev/null | sed "s|^\./||" | sort
  ' sh "${ARCHIVE_ROOT}" "${TARGET}")" || status=$?
  if [ "${status}" -ne 0 ]; then
    err "the archive container did not run (status ${status}); try: check"
    return 1
  fi
  if [ -z "${rows}" ]; then
    warn "no archived files under workspaces/${TARGET}"
    note "list shows what the volume does hold"
    return 1
  fi
  printf '%s\n' "${rows}" | sed 's/^/  /'
  printf '  %s files\n' "$(printf '%s\n' "${rows}" | grep -c .)"
  ok "listed workspaces/${TARGET}"
  return 0
}

# @function cmd_export
# Copy one workspace leaf out of the volume into a directory, through a tar stream.
# The mount stays read-only on the volume side; only the local directory is written.
# Globals:
#   DOCKER_BIN ARCHIVE_VOLUME ARCHIVE_IMAGE ARCHIVE_ROOT TARGET EXPORT_DIR
#   EXPORT_TIMEOUT_SECS
# Arguments:
#   None (reads TARGET and EXPORT_DIR)
# Outputs:
#   The extracted tree under EXPORT_DIR, and a line naming it
# Returns:
#   0 on success, 1 when the container or the local tar failed, 2 on a bad name
cmd_export() {
  validate_leaf "${TARGET}" || return 2
  [ -n "${EXPORT_DIR}" ] || EXPORT_DIR="/tmp/${TARGET}"
  if [ -e "${EXPORT_DIR}" ] && [ -n "$(ls -A "${EXPORT_DIR}" 2>/dev/null)" ]; then
    err "${EXPORT_DIR} exists and is not empty; pass a fresh destination"
    return 2
  fi
  mkdir -p "${EXPORT_DIR}" || {
    err "cannot create ${EXPORT_DIR}"
    return 1
  }
  section "exporting workspaces/${TARGET} into ${EXPORT_DIR}"
  # shellcheck disable=SC2086  # an empty-suffix DOCKER_BIN may legitimately be two words
  if ! stack_timeout "${EXPORT_TIMEOUT_SECS}" ${DOCKER_BIN} run --rm \
    -v "${ARCHIVE_VOLUME}:${ARCHIVE_ROOT}:ro" \
    "${ARCHIVE_IMAGE}" \
    tar -C "${ARCHIVE_ROOT}/workspaces/${TARGET}" -cf - . </dev/null |
    tar -xf - -C "${EXPORT_DIR}"; then
    err "the export failed; a leaf that list shows but tar cannot read is a broken mirror"
    return 1
  fi
  ok "exported workspaces/${TARGET} into ${EXPORT_DIR}"
  return 0
}

# @function cmd_check
# Answer the three questions a silent list leaves open: is the daemon reachable, does
# the volume exist, is the image pullable.
# Globals:
#   DOCKER_BIN ARCHIVE_VOLUME ARCHIVE_IMAGE TIMEOUT_SECS
# Arguments:
#   None
# Outputs:
#   One ok:/warning:/error: line per probe, and a closing summary
# Returns:
#   0 when all three probes passed, 1 otherwise
cmd_check() {
  local failed=0
  section "session archive probes"
  if stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} info >/dev/null 2>&1; then # shellcheck disable=SC2086
    ok "the daemon answers"
  else
    err "docker is not reachable from here (run this on the stack host, not in a workspace)"
    failed=1
  fi
  if [ -n "$(stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} volume ls -q -f "name=^${ARCHIVE_VOLUME}$" 2>/dev/null)" ]; then # shellcheck disable=SC2086
    ok "volume ${ARCHIVE_VOLUME} exists"
  else
    warn "volume ${ARCHIVE_VOLUME} is missing - it is created on the first workspace start that names it"
    failed=1
  fi
  if stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} image inspect "${ARCHIVE_IMAGE}" >/dev/null 2>&1; then # shellcheck disable=SC2086
    ok "image ${ARCHIVE_IMAGE} is present locally"
  else
    warn "image ${ARCHIVE_IMAGE} is not local; the first verb pulls it, so an offline host needs --image"
  fi
  [ "${failed}" -eq 0 ] || return 1
  return 0
}

# @function parse_args
# Read the leading options, then the verb, then the verb's own arguments.
# Globals:
#   VERB TARGET EXPORT_DIR ARCHIVE_VOLUME ARCHIVE_IMAGE TIMEOUT_SECS PROBE_TIMEOUT
# Arguments:
#   $@ - the CLI's argv
# Outputs:
#   The usage block on stderr, and an error line, when argv is malformed
# Returns:
#   0 when the globals hold a runnable verb, 2 on a usage error
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --volume)
        [ "$#" -ge 2 ] || {
          err "--volume needs a name"
          return 2
        }
        ARCHIVE_VOLUME="$2"
        shift
        ;;
      --image)
        [ "$#" -ge 2 ] || {
          err "--image needs a name"
          return 2
        }
        ARCHIVE_IMAGE="$2"
        shift
        ;;
      --timeout)
        [ "$#" -ge 2 ] || {
          err "--timeout needs a number"
          return 2
        }
        [[ $2 =~ ^[0-9]+$ ]] || {
          err "--timeout wants seconds, got '$2'"
          return 2
        }
        TIMEOUT_SECS="$2"
        PROBE_TIMEOUT="$2"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        err "unknown option '$1'"
        usage >&2
        return 2
        ;;
      *) break ;;
    esac
    shift
  done

  case "${1:-}" in
    list | show | export | check)
      VERB="$1"
      shift
      ;;
    *)
      err "unknown subcommand '${1:-}'"
      usage >&2
      return 2
      ;;
  esac

  case "${VERB}" in
    list | check)
      [ "$#" -eq 0 ] || {
        err "${VERB} takes no arguments"
        return 2
      }
      ;;
    show)
      [ "$#" -eq 1 ] || {
        err "show needs exactly one WORKSPACE"
        return 2
      }
      TARGET="$1"
      ;;
    export)
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
        err "export needs WORKSPACE and at most one destination directory"
        return 2
      }
      TARGET="$1"
      EXPORT_DIR="${2:-}"
      ;;
  esac
  return 0
}

# @function main
# Parse argv, run one verb, close the run with the report summary.
# Globals:
#   VERB
# Arguments:
#   $@ - the CLI's argv
# Outputs:
#   Whatever the chosen verb prints, plus the section and summary lines
# Returns:
#   The verb's status, or 2 on a usage error
main() {
  local status=0
  parse_args "$@" || status=$?
  if [ "${status}" -ne 0 ]; then
    summary
    return "${status}"
  fi
  case "${VERB}" in
    list) cmd_list || status=$? ;;
    show) cmd_show || status=$? ;;
    export) cmd_export || status=$? ;;
    check) cmd_check || status=$? ;;
  esac
  summary
  return "${status}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
