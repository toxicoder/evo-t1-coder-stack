#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## warmup.sh - fill the caches a fresh contributor container starts empty in.
#
# Started detached by library-scripts/configure.sh, so the editor is usable
# while it runs. It costs one cold gate run on a brand-new container and saves
# every later one: Bazel's external repositories, its analysis cache and the
# docs-site npm tree are all repo-version inputs, and none of them belongs in
# the image the Coder workspaces share.
#
# Order is deliberate: the Bazel run also pays for the Bazelisk download and the
# MODULE.bazel fetches, which is where a cold container actually spends its
# time. The npm install is last because //docs-site:* gates can install on
# demand and a contributor who never touches the docs site loses nothing if
# this step is slow.
#
# Not run from a shell. The status file says how it went:
#   running | ok | failed: <step>
#
# Environment:
#   EVO_T1_WARMUP_STATUS  status file (default /tmp/evo-t1-warmup.status)
#   EVO_T1_WARMUP_HOLD    seconds to wait for the checkout before giving up
#                         (default 60; covers a slow bind mount)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh disable=SC1091
source "${REPO_DIR}/scripts/lib/common.sh"
# This script has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave the log file empty.
unset JSON_MODE

WARMUP_STATUS="${EVO_T1_WARMUP_STATUS:-/tmp/evo-t1-warmup.status}"
WARMUP_HOLD="${EVO_T1_WARMUP_HOLD:-60}"

# @function write_status
# Record how the warm-up ended, so configure.sh can report it without a lock.
# Globals:
#   WARMUP_STATUS
# Arguments:
#   $1 - the status text
# Outputs:
#   The status file
# Returns:
#   0 always; a missing status file is not worth failing a warm-up over
write_status() {
  printf '%s\n' "${1:-ok}" >"${WARMUP_STATUS}" 2>/dev/null || true
}

# @function await_checkout
# Wait for the bind-mounted checkout to be readable before building in it.
# Globals:
#   REPO_DIR, WARMUP_HOLD
# Arguments:
#   None
# Outputs:
#   One note line when it had to wait
# Returns:
#   0 when docker-compose.yml appeared, 1 on timeout
await_checkout() {
  local waited=0
  while [ ! -f "${REPO_DIR}/docker-compose.yml" ]; do
    if [ "${waited}" -ge "${WARMUP_HOLD}" ]; then
      err "no checkout at ${REPO_DIR} after ${WARMUP_HOLD}s"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if [ "${waited}" -gt 0 ]; then
    note "waited ${waited}s for the checkout to mount"
  fi
  return 0
}

# @function warm_step
# Run one warm-up step, keeping going when it fails.
# Globals:
#   None
# Arguments:
#   $1 - step name
#   $* - the command to run
# Outputs:
#   The command's output into the log
# Returns:
#   0 when the step passed, 1 when it failed
warm_step() {
  local name="$1"
  shift
  phase "warm ${name}"
  if "$@"; then
    ok "warm ${name}"
    return 0
  fi
  warn "warm ${name} failed"
  return 1
}

# @function main
# Run every warm-up step and record the outcome.
# Globals:
#   REPO_DIR
# Arguments:
#   None
# Outputs:
#   Progress on stdout (the caller redirects it to the log) and the status file
# Returns:
#   0 when every step passed, 1 when any failed
main() {
  local failed=""
  cd "${REPO_DIR}" || {
    write_status "failed: checkout"
    return 1
  }
  if ! await_checkout; then
    write_status "failed: checkout"
    return 1
  fi
  if ! has_tool bazelisk; then
    err "bazelisk is not on PATH; the golden image is older than the templates"
    write_status "failed: bazelisk"
    return 1
  fi

  # --noshow_progress keeps the log a readable list of phase lines instead of a
  # progress-bar rewrite stream; the disk and repository caches from ~/.bazelrc
  # are what make this run pay for itself.
  warm_step "bazel gate" bazelisk test //:test-fast --noshow_progress ||
    failed="${failed:+${failed}, }test-fast"
  warm_step "docs-site deps" bazelisk run //docs-site:install ||
    failed="${failed:+${failed}, }docs-site"

  if [ -n "${failed}" ]; then
    write_status "failed: ${failed}"
    summary
    return 1
  fi
  write_status "ok"
  summary
  return 0
}

main
