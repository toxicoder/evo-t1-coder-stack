#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## host-state.bats - hermetic coverage for scripts/lib/host_state.sh.
#
# Two host leftovers this lib owns: a resolv.conf that only names Tailscale
# MagicDNS (git pull then dies with Could not resolve host: github.com), and a
# Docker-created directory or root-owned file in Bazel's runfiles tree (the
# next bazelisk run dies creating prod-stack.runfiles on evo-t1.svg).
#
# Usage: bats tests/bats/host-state.bats
# Safety: hermetic. Writes only under the per-test scratch; no daemon, no
# sudo, no real /etc/resolv.conf.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/host_state.sh"
}

@test "host_state: host_nameservers reads nameserver lines and skips comments" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"
  printf 'search example.test\nnameserver 100.100.100.100\n# nameserver 1.1.1.1\nnameserver 8.8.8.8\n' \
    >"${file}"

  run --separate-stderr host_nameservers "${file}"
  [ "${status}" -eq 0 ]
  assert_match "magicdns is listed" '^100\.100\.100\.100$' "${output}"
  assert_match "the public resolver is listed" '^8\.8\.8\.8$' "${output}"
  assert_not_match "a commented nameserver is ignored" '1\.1\.1\.1' "${output}"

  run --separate-stderr host_nameservers "${BATS_TEST_TMPDIR}/absent"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "host_state: host_dns_kind classifies MagicDNS-only from mixed" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"

  printf 'nameserver 100.100.100.100\nnameserver fd7a:115c:a1e0::53\n' >"${file}"
  run --separate-stderr host_dns_kind "${file}"
  assert_eq "only MagicDNS" 'magicdns-only' "${output}"

  printf 'nameserver 127.0.0.53\n' >"${file}"
  run --separate-stderr host_dns_kind "${file}"
  assert_eq "systemd stub" 'stub' "${output}"

  printf 'nameserver 100.100.100.100\nnameserver 1.1.1.1\n' >"${file}"
  run --separate-stderr host_dns_kind "${file}"
  assert_eq "MagicDNS plus a public resolver" 'mixed' "${output}"

  printf 'search lan\n' >"${file}"
  run --separate-stderr host_dns_kind "${file}"
  assert_eq "no nameserver line" 'empty' "${output}"

  printf 'nameserver 192.168.8.1\n' >"${file}"
  run --separate-stderr host_dns_kind "${file}"
  assert_eq "a LAN resolver" 'other' "${output}"
}

@test "host_state: host_can_resolve is overridable so a report never needs the network" {
  host_can_resolve() { return 1; } # shellcheck disable=SC2329
  run --separate-stderr host_can_resolve github.com
  [ "${status}" -eq 1 ]

  host_can_resolve() { return 0; } # shellcheck disable=SC2329
  run --separate-stderr host_can_resolve github.com
  [ "${status}" -eq 0 ]
}

@test "host_state: host_dns_report names MagicDNS when github.com does not resolve" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"
  printf 'nameserver 100.100.100.100\n' >"${file}"
  host_can_resolve() { return 1; } # shellcheck disable=SC2329

  run --separate-stderr host_dns_report "${file}" github.com
  [ "${status}" -eq 1 ]
  assert_match "the lookup failure is named" 'github.com did not resolve' "${output}"
  assert_match "Could not resolve host is quoted" 'Could not resolve host' "${output}"
  assert_match "MagicDNS is named" '100\.100\.100\.100' "${output}"
  assert_match "the repair command is named" 'tailscale set --accept-dns=false' "${output}"

  host_can_resolve() { return 0; } # shellcheck disable=SC2329
  run --separate-stderr host_dns_report "${file}" github.com
  [ "${status}" -eq 0 ]
  assert_match "a working lookup is a one-liner" 'github.com resolves' "${output}"
}

@test "host_state: runfiles_relpath strips the runfiles prefix" {
  run --separate-stderr runfiles_relpath \
    /tmp/out/bin/scripts/prod-stack.runfiles/_main/homepage/assets/icons/evo-t1.svg \
    /tmp/checkout
  assert_eq "runfiles payload" 'homepage/assets/icons/evo-t1.svg' "${output}"

  run --separate-stderr runfiles_relpath \
    /home/alx/.cache/bazel/_bazel_alx/hash/execroot/_main/bazel-out/k8-fastbuild/bin/scripts/prod-stack.runfiles/_main/homepage/assets/icons/evo-t1.svg \
    /home/alx/code/toxicoder/evo-t1-coder-stack
  assert_eq "the host cache spelling" 'homepage/assets/icons/evo-t1.svg' "${output}"

  run --separate-stderr runfiles_relpath \
    /tmp/checkout/homepage/assets/icons/evo-t1.svg \
    /tmp/checkout
  assert_eq "checkout path" 'homepage/assets/icons/evo-t1.svg' "${output}"
}

@test "host_state: repair_stale_path removes a Docker-created directory sitting on a file" {
  local root path
  root="$(make_scratch)"
  mkdir -p "${root}/homepage/assets/icons"
  printf '<svg/>\n' >"${root}/homepage/assets/icons/evo-t1.svg"
  path="${root}/bazel-out/k8/bin/scripts/prod-stack.runfiles/_main/homepage/assets/icons/evo-t1.svg"
  mkdir -p "${path}"

  run --separate-stderr repair_stale_path "${root}" "${path}" 0
  [ "${status}" -eq 0 ]
  assert_match "the leftover directory is named" 'removed leftover directory' "${output}"
  [ ! -e "${path}" ]
  [ -f "${root}/homepage/assets/icons/evo-t1.svg" ]
}

@test "host_state: repair_stale_runfiles restores an unwritable runfiles payload" {
  local root path
  root="$(make_scratch)"
  mkdir -p "${root}/homepage/assets/icons"
  printf '<svg/>\n' >"${root}/homepage/assets/icons/evo-t1.svg"
  path="${root}/bazel-out/k8/bin/scripts/prod-stack.runfiles/_main/homepage/assets/icons/evo-t1.svg"
  mkdir -p "$(dirname "${path}")"
  printf '<svg/>\n' >"${path}"
  chmod a-w "${path}"

  run --separate-stderr stale_runfiles_paths "${root}"
  assert_match "the unwritable copy is listed" 'evo-t1.svg' "${output}"

  run --separate-stderr report_stale_runfiles "${root}"
  assert_match "the leftover is counted" 'leftover path' "${output}"
  assert_match "the repair command is named" 'setup-host.sh --repair' "${output}"

  run --separate-stderr repair_stale_runfiles "${root}" 0
  [ "${status}" -eq 0 ]
  [ -w "${path}" ]
}

@test "host_state: report_stale_runfiles is quiet when nothing is leftover" {
  local root
  root="$(make_scratch)"
  mkdir -p "${root}/homepage" "${root}/proxy"

  run --separate-stderr report_stale_runfiles "${root}"
  [ "${status}" -eq 0 ]
  assert_match "a clean tree is a note" 'no leftover payload' "${output}"

  run --separate-stderr repair_stale_runfiles "${root}" 0
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
