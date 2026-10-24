#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## setup-host.bats - hermetic coverage for scripts/setup-host.sh.
#
# The host bootstrap is the one script that runs from a shell, and --repair is
# the recovery when bazelisk run cannot even start (leftover Docker bind-mounts
# in the runfiles tree). --check writes nothing; an unknown flag is an error.
#
# Usage: bazelisk test //tests:bats_setup_host_test   (from any cwd)
# Safety: hermetic. --repair is aimed at a scratch tree via SETUP_ROOT.
# setup() sets SETUP_SKIP_DNS=1 so existing --repair cases never touch host
# DNS or real Tailscale (`sudo tailscale` bypasses PATH stubs via secure_path).
# The public-DNS case uses SETUP_DNS_DRY_RUN plus scratch resolv/drop-in paths.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/setup-host.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/setup-host.sh is not in the tree"
  # Never let --repair reach the real host resolver or `sudo tailscale`.
  export SETUP_SKIP_DNS=1
}

@test "setup-host: --help prints the usage, and an unknown flag is an error" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: bash scripts/setup-host.sh' "${output}"
  assert_match "--repair is documented" '--repair' "${output}"
  assert_match "public DNS is documented" 'public DNS' "${output}"

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

@test "setup-host: --repair dry-run writes the resolved drop-in and logs accept-dns=false" {
  local root resolv dropin
  root="$(make_scratch)"
  mkdir -p "${root}/homepage" "${root}/proxy"
  resolv="${root}/resolv.conf"
  dropin="${root}/resolved.conf.d/evo-t1-public-dns.conf"
  printf 'nameserver 100.100.100.100\n' >"${resolv}"

  run --separate-stderr env \
    SETUP_SKIP_DNS=0 \
    SETUP_DNS_DRY_RUN=1 \
    SETUP_DNS_OS=Linux \
    SETUP_DNS_LOOKUP=1 \
    SETUP_ROOT="${root}" \
    SETUP_RESOLV_CONF="${resolv}" \
    SETUP_RESOLVED_DROPIN="${dropin}" \
    bash "${SCRIPT}" --repair
  [ "${status}" -eq 0 ]
  assert_match "drop-in is named" 'evo-t1-public-dns.conf' "${output}"
  assert_match "accept-dns is dry-run" 'would: tailscale set --accept-dns=false' "${output}"
  assert_match "runfiles finished" 'runfiles repair finished' "${output}"
  [ -f "${dropin}" ]
  grep -q 'DNS=1.1.1.1 8.8.8.8' "${dropin}"
  assert_not_match "dry-run does not append resolv.conf" '1\.1\.1\.1' "$(cat "${resolv}")"
}
