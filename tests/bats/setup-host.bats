#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## setup-host.bats - hermetic coverage for scripts/setup-host.sh.
#
# The host bootstrap is the one script that runs from a shell, and --repair is
# the recovery when bazelisk run cannot even start (leftover Docker bind-mounts
# in the runfiles tree). --check writes nothing; an unknown flag is an error.
#
# Usage: bats tests/bats/setup-host.bats
# Safety: hermetic. --repair is aimed at a scratch tree via SETUP_ROOT; --check
# is not run against the real /etc/resolv.conf from this suite (that path is
# covered by host-state.bats).

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/setup-host.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/setup-host.sh is not in the tree"
}

@test "setup-host: --help prints the usage, and an unknown flag is an error" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: bash scripts/setup-host.sh' "${output}"
  assert_match "--repair is documented" '--repair' "${output}"

  run --separate-stderr bash "${SCRIPT}" --bogus
  [ "${status}" -eq 1 ]
  assert_match "the bad flag is named" 'unknown argument --bogus' "${stderr}"
}

@test "setup-host: --repair restores a leftover runfiles directory on a scratch tree" {
  local root path
  root="$(make_scratch)"
  mkdir -p "${root}/homepage/assets/icons" "${root}/proxy" "${root}/scripts"
  printf '<svg/>\n' >"${root}/homepage/assets/icons/evo-t1.svg"
  path="${root}/bazel-out/k8/bin/scripts/prod-stack.runfiles/_main/homepage/assets/icons/evo-t1.svg"
  mkdir -p "${path}"

  run --separate-stderr env SETUP_ROOT="${root}" bash "${SCRIPT}" --repair
  [ "${status}" -eq 0 ]
  assert_match "the leftover directory is removed" 'removed leftover directory' "${output}"
  assert_match "repair finished" 'runfiles repair finished' "${output}"
  [ ! -e "${path}" ]
}

@test "setup-host: --repair on a clean scratch tree still exits 0" {
  local root
  root="$(make_scratch)"
  mkdir -p "${root}/homepage" "${root}/proxy"

  run --separate-stderr env SETUP_ROOT="${root}" bash "${SCRIPT}" --repair
  [ "${status}" -eq 0 ]
  assert_match "repair finished" 'runfiles repair finished' "${output}"
}
