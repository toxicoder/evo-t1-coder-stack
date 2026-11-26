#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## host-state.bats - hermetic coverage for scripts/lib/host_state.sh.
#
# Three host leftovers this lib owns: a resolv.conf that only names Tailscale
# MagicDNS (git pull then dies with Could not resolve host: github.com), a
# Docker-created directory or root-owned file in Bazel's runfiles tree (the
# next bazelisk run dies creating prod-stack.runfiles on evo-t1.svg), and a host
# that ships no /etc/timezone or /etc/localtime while the coder service
# bind-mounts both read-only with create_host_path: false (compose up then dies
# mid-create with bind source path does not exist, which names no remedy).
#
# Usage: bazelisk test //tests:bats_host_state_test   (from any cwd)
# Safety: hermetic. Writes only under the per-test scratch; no daemon, no
# sudo, no real /etc/resolv.conf, no real /etc/timezone or /etc/localtime.

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
  unset SETUP_SKIP_DNS SETUP_DNS_DRY_RUN SETUP_DNS_OS SETUP_DNS_LOOKUP \
    SETUP_RESOLV_CONF SETUP_RESOLVED_DROPIN || true
  # The clock checks take their three paths from these, so a HOST_* the developer's
  # own shell happens to export must never point a case at a tree it never built.
  unset HOST_TIMEZONE_FILE HOST_LOCALTIME_LINK HOST_ZONEINFO_DIR || true
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
  assert_match "setup-host --repair is named" 'setup-host.sh --repair' "${output}"

  host_can_resolve() { return 0; } # shellcheck disable=SC2329
  run --separate-stderr host_dns_report "${file}" github.com
  [ "${status}" -eq 0 ]
  assert_match "a working lookup is a one-liner" 'github.com resolves' "${output}"
}

@test "host_state: public_dns_servers prints the pair --repair installs" {
  run --separate-stderr public_dns_servers
  [ "${status}" -eq 0 ]
  assert_match "cloudflare" '^1\.1\.1\.1$' "${output}"
  assert_match "google" '^8\.8\.8\.8$' "${output}"
}

@test "host_state: resolved_dropin_body is a systemd-resolved [Resolve] fragment" {
  run --separate-stderr resolved_dropin_body
  [ "${status}" -eq 0 ]
  assert_match "section" '\[Resolve\]' "${output}"
  assert_match "DNS pair" 'DNS=1\.1\.1\.1 8\.8\.8\.8' "${output}"
  assert_match "FallbackDNS" 'FallbackDNS=8\.8\.4\.4 1\.0\.0\.1' "${output}"
  assert_match "names this repo" 'evo-t1-coder-stack' "${output}"
}

@test "host_state: host_has_public_nameserver ignores MagicDNS and the stub" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"

  printf 'nameserver 100.100.100.100\n' >"${file}"
  run --separate-stderr host_has_public_nameserver "${file}"
  [ "${status}" -eq 1 ]

  printf 'nameserver 127.0.0.53\n' >"${file}"
  run --separate-stderr host_has_public_nameserver "${file}"
  [ "${status}" -eq 1 ]

  printf 'nameserver 100.100.100.100\nnameserver 1.1.1.1\n' >"${file}"
  run --separate-stderr host_has_public_nameserver "${file}"
  [ "${status}" -eq 0 ]

  printf 'search lan\n' >"${file}"
  run --separate-stderr host_has_public_nameserver "${file}"
  [ "${status}" -eq 1 ]
}

@test "host_state: write_resolved_dropin writes the drop-in under a scratch path" {
  local dest="${BATS_TEST_TMPDIR}/resolved.conf.d/evo-t1-public-dns.conf"

  run --separate-stderr write_resolved_dropin "${dest}" 0
  [ "${status}" -eq 0 ]
  [ -f "${dest}" ]
  assert_match "path is named" 'evo-t1-public-dns.conf' "${output}"
  grep -q 'DNS=1.1.1.1 8.8.8.8' "${dest}"
  grep -q 'FallbackDNS=8.8.4.4 1.0.0.1' "${dest}"
}

@test "host_state: append_public_nameservers fills a regular MagicDNS-only file and skips a symlink" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"
  local real="${BATS_TEST_TMPDIR}/real-resolv.conf"
  local link="${BATS_TEST_TMPDIR}/link-resolv.conf"

  printf 'nameserver 100.100.100.100\n' >"${file}"
  run --separate-stderr append_public_nameservers "${file}" 0
  [ "${status}" -eq 0 ]
  assert_match "append is named" 'appended public nameservers' "${output}"
  grep -q 'nameserver 1.1.1.1' "${file}"
  grep -q 'nameserver 8.8.8.8' "${file}"

  run --separate-stderr append_public_nameservers "${file}" 0
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  printf 'nameserver 100.100.100.100\n' >"${real}"
  ln -s "${real}" "${link}"
  run --separate-stderr append_public_nameservers "${link}" 0
  [ "${status}" -eq 0 ]
  assert_not_match "symlink is not rewritten" '1\.1\.1\.1' "$(cat "${real}")"
}

@test "host_state: ensure_host_public_dns dry-run writes the drop-in and does not rewrite resolv.conf" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"
  local dropin="${BATS_TEST_TMPDIR}/resolved.conf.d/evo-t1-public-dns.conf"
  printf 'nameserver 100.100.100.100\n' >"${file}"

  export SETUP_DNS_OS=Linux SETUP_DNS_DRY_RUN=1 SETUP_DNS_LOOKUP=1
  unset SETUP_SKIP_DNS
  run --separate-stderr ensure_host_public_dns "${file}" "${dropin}" 0
  [ "${status}" -eq 0 ]
  [ -f "${dropin}" ]
  grep -q 'DNS=1.1.1.1 8.8.8.8' "${dropin}"
  assert_match "accept-dns is dry-run" 'would: tailscale set --accept-dns=false' "${output}"
  assert_match "resolved restart is dry-run" 'would: systemctl restart systemd-resolved' "${output}"
  assert_match "split-DNS is dry-run" 'would: resolvectl domain tailscale0 ts.net' "${output}"
  assert_not_match "resolv.conf is not appended in dry-run" 'appended public nameservers' "${output}"
  assert_not_match "MagicDNS stays the only NS" 'nameserver 1\.1\.1\.1' "$(cat "${file}")"
}

@test "host_state: ensure_host_public_dns skips Darwin and SETUP_SKIP_DNS" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"
  local dropin="${BATS_TEST_TMPDIR}/skip.d/evo-t1-public-dns.conf"
  printf 'nameserver 100.100.100.100\n' >"${file}"

  export SETUP_SKIP_DNS=1 SETUP_DNS_OS=Linux SETUP_DNS_DRY_RUN=1
  run --separate-stderr ensure_host_public_dns "${file}" "${dropin}" 0
  [ "${status}" -eq 0 ]
  [ ! -e "${dropin}" ]
  [ -z "${output}" ]

  unset SETUP_SKIP_DNS
  export SETUP_DNS_OS=Darwin SETUP_DNS_DRY_RUN=1 SETUP_DNS_LOOKUP=1
  run --separate-stderr ensure_host_public_dns "${file}" "${dropin}" 0
  [ "${status}" -eq 0 ]
  [ ! -e "${dropin}" ]
  assert_match "Darwin is a no-op" 'Linux-only' "${output}"
}

@test "host_state: ensure_host_public_dns skips a working stub resolver" {
  local file="${BATS_TEST_TMPDIR}/resolv.conf"
  local dropin="${BATS_TEST_TMPDIR}/stub.d/evo-t1-public-dns.conf"
  printf 'nameserver 127.0.0.53\n' >"${file}"

  export SETUP_DNS_OS=Linux SETUP_DNS_LOOKUP=1 SETUP_DNS_DRY_RUN=1
  unset SETUP_SKIP_DNS
  run --separate-stderr ensure_host_public_dns "${file}" "${dropin}" 0
  [ "${status}" -eq 0 ]
  [ ! -e "${dropin}" ]
  assert_match "no repair" 'public DNS repair not needed' "${output}"
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

# The coder service bind-mounts /etc/timezone and /etc/localtime read-only with
# create_host_path: false, so a host that ships neither gets a refused create mid-up
# naming no remedy. These cases pin the three functions that replace that daemon line:
# compose_binds_host_path decides whether a compose file asks for the bind at all,
# host_clock_zone_name reads the zone the host already answers (timezone file first,
# the localtime link second, the order templates/common/tz.sh walks), and
# host_clock_files_report names the path and the one host command that is safe to paste.

@test "host_state: compose_binds_host_path answers for the two bind spellings only" {
  # This predicate is what keeps the clock check out of a bring-up it has nothing to
  # say about, so it has to fire on exactly the two ways compose writes a bind source
  # and on nothing else. A target: record names the CONTAINER side, and a commented-out
  # mount is not a mount: neither asks the daemon to bind a host path, and a check that
  # read either one as a bind would refuse a create nobody asked for.
  local compose="${BATS_TEST_TMPDIR}/compose.yml"
  local want="${BATS_TEST_TMPDIR}/etc/timezone"

  printf '    volumes:\n      - type: bind\n        source: %s\n        target: /etc/timezone\n        read_only: true\n' \
    "${want}" >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]

  printf '    volumes:\n      - %s:/etc/timezone:ro\n' "${want}" >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 0 ]

  printf '    volumes:\n      - type: bind\n        target: %s\n' "${want}" >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]

  printf '# - %s:/etc/timezone:ro\n' "${want}" >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]

  # The host side sitting behind someone else's mount in a trailing comment is still
  # only a comment; the cut at ` #` is what keeps it out of the comparison.
  printf '      - /srv/other:/etc/timezone:ro # bind %s\n' "${want}" >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]
}

@test "host_state: compose_binds_host_path refuses a source it cannot resolve" {
  # An unresolvable interpolation must NOT count as a bind: `${VAR:-/etc/timezone}`
  # cuts to `${VAR` at the first colon and a bare `${VAR}` stays itself, so answering 1
  # is what stops the pre-flight blocking a bring-up over a spelling only compose and
  # the daemon can read. A named volume's host side is a volume name, not a path, and a
  # compose file this shell cannot read is no evidence about the daemon either.
  local compose="${BATS_TEST_TMPDIR}/compose.yml"
  local want="${BATS_TEST_TMPDIR}/etc/timezone"

  printf '        source: ${TZ_FILE:-%s}\n' "${want}" >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]

  printf '        source: ${TZ_FILE}\n' >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]

  # A named volume is not a bind of either clock path: its host side is a volume name,
  # so the clock check has to stay out of a bring-up whose only volumes are `coder-home`
  # and the like. Adding the real bind beside it is what flips the answer.
  printf '    volumes:\n      - coder-home:/home/coder\n' >"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]
  printf '      - %s:/etc/localtime:ro\n' "${want}" >>"${compose}"
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 0 ]

  run --separate-stderr compose_binds_host_path "${BATS_TEST_TMPDIR}/absent.yml" "${want}"
  [ "${status}" -eq 1 ]
  run --separate-stderr compose_binds_host_path "" "${want}"
  [ "${status}" -eq 1 ]
  run --separate-stderr compose_binds_host_path "${compose}" ""
  [ "${status}" -eq 1 ]

  : >"${compose}"
  chmod 000 "${compose}"
  if [[ -r ${compose} ]]; then
    skip "this runtime reads a 000 file, so no unreadable compose file can be built here"
  fi
  run --separate-stderr compose_binds_host_path "${compose}" "${want}"
  [ "${status}" -eq 1 ]
}

@test "host_state: host_clock_files_report is silent when both clock sources exist" {
  # Silence is the whole contract on a healthy host: a pre-flight that narrates every
  # up trains the operator to ignore the one line that means compose will refuse.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local compose="${BATS_TEST_TMPDIR}/compose.yml"

  mkdir -p "${zi}/America" "$(dirname "${tz}")"
  printf 'TZif2\n' >"${zi}/America/Chicago"
  printf 'America/Chicago\n' >"${tz}"
  ln -s "${zi}/America/Chicago" "${link}"
  printf 'services:\n  coder:\n    volumes:\n      - type: bind\n        source: %s\n      - type: bind\n        source: %s\n' \
    "${tz}" "${link}" >"${compose}"

  run --separate-stderr host_clock_files_report "${compose}" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]
}

@test "host_state: host_clock_files_report prints the tee that grows a missing timezone file" {
  # This is the case the check exists for (Fedora, Arch, an alpine-based host): the
  # daemon's bind source path does not exist line lands mid-up and names no fix, so
  # the pre-flight has to name both the path and the exact printf | tee that works,
  # carrying the zone the host's own localtime link already answers.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local fix_line

  mkdir -p "${zi}/America" "$(dirname "${tz}")"
  printf 'TZif2\n' >"${zi}/America/Chicago"
  ln -s "${zi}/America/Chicago" "${link}"

  run --separate-stderr host_clock_files_report "" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  assert_match "the error names the refused create" \
    'does not exist on this host, and the coder service bind-mounts it read-only with create_host_path: false, so docker compose will refuse the create' \
    "${stderr}"
  [[ "${stderr}" == *"error: ${tz} does not exist on this host"* ]]
  assert_match "the tzdata route is offered" 'dpkg-reconfigure tzdata writes both files' "${output}"
  assert_not_match "a file that exists is not complained about" 'etc/localtime' "${stderr}"

  fix_line="$(grep -F 'Fix on the host:' <<<"${output}" | head -n 1)"
  assert_eq "the write line carries the zone the link names" \
    "note: Fix on the host: printf '%s\\n' America/Chicago | sudo tee ${tz} >/dev/null" \
    "${fix_line}"
}

@test "host_state: host_clock_files_report skips a path the compose file never binds" {
  # A custom compose file that mounts neither clock path must not be blocked by a host
  # with no /etc/timezone: the question is what compose will actually be told to bind,
  # so a target: record and a commented-out mount that only MENTION the path keep the
  # check out of the bring-up (a bare grep would have called both a bind).
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local compose="${BATS_TEST_TMPDIR}/compose.yml"

  mkdir -p "${zi}/America" "$(dirname "${tz}")"
  printf 'TZif2\n' >"${zi}/America/Chicago"
  ln -s "${zi}/America/Chicago" "${link}"
  printf 'services:\n  coder:\n    volumes:\n      # - %s:/etc/timezone:ro (host has no such file)\n      - type: bind\n        target: %s\n        read_only: true\n' \
    "${tz}" "${tz}" >"${compose}"

  run --separate-stderr host_clock_files_report "${compose}" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]

  # The same scratch, once the file spells a real bind source: the silence above was
  # the bind parser saying nobody asked for this path, not the check deciding the host
  # is fine.
  printf '      - type: bind\n        source: %s\n' "${tz}" >>"${compose}"
  run --separate-stderr host_clock_files_report "${compose}" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"error: ${tz} does not exist on this host"* ]]

  # A compose file this shell cannot read is compose's own problem, not a host clock
  # problem: compose cannot read it either and its error is the one the operator needs,
  # so the pre-flight prints nothing rather than sending them off to fix tzdata for a
  # bring-up that never started (a hand-removed -f file included).
  run --separate-stderr host_clock_files_report "${BATS_TEST_TMPDIR}/no-such-compose.yml" \
    "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]
}

@test "host_state: host_clock_files_report orders the leftover removal before the write" {
  # The short KEY:TARGET:ro form left a root-owned DIRECTORY at the path on a host
  # that had no such file, and that leftover outlives compose down and misleads the
  # next dpkg-reconfigure tzdata. Telling the operator to tee over a directory they
  # were never told to remove is a second failure they have to diagnose alone.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local rm_line fix_line rm_at=0 fix_at=0 i=0 line

  mkdir -p "${zi}/America" "${tz}" "$(dirname "${link}")"
  printf 'TZif2\n' >"${zi}/America/Chicago"
  ln -s "${zi}/America/Chicago" "${link}"

  run --separate-stderr host_clock_files_report "" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  assert_match "the error says what sits there" \
    'is a directory, which is what the short KEY:TARGET:ro form leaves behind on a host that had no such file' \
    "${stderr}"

  rm_line="$(grep -F 'Remove the leftover first:' <<<"${output}" | head -n 1)"
  fix_line="$(grep -F 'Fix on the host:' <<<"${output}" | head -n 1)"
  assert_eq "the removal names the leftover" "note: Remove the leftover first: sudo rm -rf ${tz}" "${rm_line}"
  assert_eq "the write line still carries the zone" \
    "note: Fix on the host: printf '%s\\n' America/Chicago | sudo tee ${tz} >/dev/null" \
    "${fix_line}"

  while IFS= read -r line; do
    i=$((i + 1))
    if [[ ${line} == *"Remove the leftover first:"* ]]; then rm_at=${i}; fi
    if [[ ${line} == *"Fix on the host:"* ]]; then fix_at=${i}; fi
  done <<<"${output}"
  [ "${rm_at}" -gt 0 ]
  [ "${fix_at}" -gt 0 ]
  [ "${rm_at}" -lt "${fix_at}" ]
}

@test "host_state: host_clock_files_report answers for both paths and prints no link at a placeholder" {
  # A tzdata-less image has neither file and nothing on the box to read a zone from, so
  # the report has to answer for both paths in one pass rather than make the operator
  # run the up twice. And it must NOT hand out `sudo ln -sfn <tree>/Area/City`: that
  # link is dangling, glibc answers UTC for a dangling /etc/localtime, and a silently
  # UTC container is the exact clock failure this seam exists to keep off the stack.
  # The tee line keeps Area/City as the prompt docs/coder-templates.md uses it, because
  # the workspace resolver re-validates that file's contents; the link path gets told
  # what it needs instead of a command that would make things worse.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local tz_fix lt_note

  mkdir -p "${zi}" "$(dirname "${tz}")"

  run --separate-stderr host_clock_files_report "" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  [ "$(grep -c '^error: ' <<<"${stderr}")" -eq 2 ]
  [[ "${stderr}" == *"error: ${tz} does not exist on this host"* ]]
  [[ "${stderr}" == *"error: ${link} does not exist on this host"* ]]

  tz_fix="$(grep -F "| sudo tee ${tz} >/dev/null" <<<"${output}" | head -n 1)"
  lt_note="$(grep -F 'needs a link at a real file under' <<<"${output}" | head -n 1)"
  assert_eq "the timezone fix carries the placeholder zone" \
    "note: Fix on the host: printf '%s\\n' Area/City | sudo tee ${tz} >/dev/null" \
    "${tz_fix}"
  assert_eq "the link path is told what it needs, not handed a dead link" \
    "note: ${link} needs a link at a real file under ${zi}; sudo dpkg-reconfigure tzdata writes both files." \
    "${lt_note}"
  assert_not_match "no paste-able link at a zone nobody named" 'ln -sfn' "${output}"
  [ "$(grep -c 'dpkg-reconfigure tzdata writes both files; setting TZ' <<<"${output}")" -eq 1 ]
}

@test "host_state: host_clock_zone_name rejects a POSIX rule string and a name outside the tree" {
  # The zone in the fix line has to be a zone. A hand-edited timezone file can carry a
  # POSIX rule string (TZ="EST5EDT"), and there is no zoneinfo/EST5EDT to link at, so
  # with no tree to ask the answer must be nothing. With a tree, only a real file in it
  # counts -- including a single-segment zone, which a plain name test would drop.
  # The timezone file is asked first and the link second, the order
  # templates/common/tz.sh walks, so both orders are pinned here.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"

  mkdir -p "$(dirname "${tz}")"
  printf 'EST5EDT\n' >"${tz}"
  run --separate-stderr host_clock_zone_name "${tz}" "${link}" "${BATS_TEST_TMPDIR}/no-zoneinfo"
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]

  mkdir -p "${zi}/America"
  printf 'TZif2\n' >"${zi}/UTC"
  printf 'TZif2\n' >"${zi}/America/Chicago"
  printf 'Mars/Olympus_Mons\n' >"${tz}"
  run --separate-stderr host_clock_zone_name "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]

  printf 'UTC\n' >"${tz}"
  run --separate-stderr host_clock_zone_name "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 0 ]
  assert_eq "a single-segment zone in the tree is accepted" 'UTC' "${output}"

  # With no tree to ask, a multi-segment name is still trusted (it reads as a zoneinfo
  # path), which is what lets the fix line name a real zone on a cut-down host.
  printf 'America/Denver\n' >"${tz}"
  run --separate-stderr host_clock_zone_name "${tz}" "${link}" "${BATS_TEST_TMPDIR}/no-zoneinfo"
  [ "${status}" -eq 0 ]
  assert_eq "a multi-segment name needs no tree" 'America/Denver' "${output}"

  # The file first, the link second: a box whose tzdata postinst wrote the file is told
  # the zone it was configured to run, not wherever a stale link happens to point.
  printf 'America/Chicago\n' >"${tz}"
  ln -s "${zi}/UTC" "${link}"
  run --separate-stderr host_clock_zone_name "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 0 ]
  assert_eq "the timezone file outranks the link" 'America/Chicago' "${output}"

  # And an empty timezone file falls through to the link rather than answering nothing.
  : >"${tz}"
  run --separate-stderr host_clock_zone_name "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 0 ]
  assert_eq "an empty file falls through to the link" 'UTC' "${output}"
}

@test "host_state: host_clock_files_report names a gone symlink target and only links at a real zone" {
  # A dangling /etc/localtime is neither "missing" nor "a directory", and the operator
  # who deleted the tzdata package needs to be told the link is what broke. It also has
  # to earn its own remedy line: the ln -sfn line appears only when the resolved zone
  # names a real file under the tree, because the other half of the time there is no
  # such file to link at and a paste-able command would only create a second dangling
  # link (glibc reads that as UTC).
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local note_line fix_line

  mkdir -p "${zi}/America" "$(dirname "${tz}")"
  printf 'TZif2\n' >"${zi}/America/Chicago"
  # A rule string in the file: it is not a zone, so the box has nothing to name and the
  # dangling link is the only thing under discussion.
  printf 'EST5EDT\n' >"${tz}"
  ln -s "${zi}/America/Nowhere" "${link}"

  run --separate-stderr host_clock_files_report "" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  [ "$(grep -c '^error: ' <<<"${stderr}")" -eq 1 ]
  assert_match "the error names the gone target" \
    'is a symlink whose target is gone, and the coder service bind-mounts it read-only with create_host_path: false, so docker compose will refuse the create' \
    "${stderr}"
  [[ "${stderr}" == *"error: ${link} is a symlink whose target is gone"* ]]
  assert_not_match "the gone link is never called a missing file" \
    "error: ${link} does not exist on this host" "${stderr}"
  assert_match "no zone readable, so no link line" 'needs a link at a real file under' "${output}"
  assert_not_match "no ln -sfn without a real zone file" 'ln -sfn' "${output}"

  note_line="$(grep -F 'needs a link at a real file under' <<<"${output}" | head -n 1)"
  assert_eq "the note names the path and the tree to look in" \
    "note: ${link} needs a link at a real file under ${zi}; sudo dpkg-reconfigure tzdata writes both files." \
    "${note_line}"

  # Now the same broken link with a zone this host can actually name: the paste-able
  # ln -sfn line is the right advice and has to come back.
  printf 'America/Chicago\n' >"${tz}"
  run --separate-stderr host_clock_files_report "" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"error: ${link} is a symlink whose target is gone"* ]]
  fix_line="$(grep -F 'Fix on the host:' <<<"${output}" | head -n 1)"
  assert_eq "a real zone earns the link command" \
    "note: Fix on the host: sudo ln -sfn ${zi}/America/Chicago ${link}" \
    "${fix_line}"
}

@test "host_state: host_clock_files_report links localtime into the caller's zoneinfo dir" {
  # The remedy has to point at the tree the caller named, not at a hardcoded
  # /usr/share/zoneinfo: on a host that keeps the tree elsewhere, the printed link
  # would land on nothing and the operator would still be stuck at the same daemon line.
  # This is also the positive half of the rule that the ln -sfn line appears only for a
  # zone that names a real file under that tree.
  local zi="${BATS_TEST_TMPDIR}/tzdata/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local fix_line

  mkdir -p "${zi}/America" "$(dirname "${tz}")"
  printf 'TZif2\n' >"${zi}/America/Denver"
  printf 'America/Denver\n' >"${tz}"

  run --separate-stderr host_clock_files_report "" "${tz}" "${link}" "${zi}"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"error: ${link} does not exist on this host"* ]]
  assert_not_match "the file that exists is not complained about" 'etc/timezone does not exist' "${stderr}"

  fix_line="$(grep -F 'Fix on the host:' <<<"${output}" | head -n 1)"
  assert_eq "the link targets the caller's tree and the zone it holds" \
    "note: Fix on the host: sudo ln -sfn ${zi}/America/Denver ${link}" \
    "${fix_line}"
}

@test "host_state: the clock helpers take their paths from the HOST_* seams" {
  # The three HOST_* variables are how an operator points the check at another root and
  # how these cases aim it at a scratch tree. setup() clears them, so this is the one
  # case that sets them, to prove the defaults come from the environment and not /etc.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local tz="${BATS_TEST_TMPDIR}/etc/timezone"
  local link="${BATS_TEST_TMPDIR}/etc/localtime"
  local fix_line

  mkdir -p "${zi}/Europe" "$(dirname "${tz}")"
  printf 'TZif2\n' >"${zi}/Europe/Berlin"
  printf 'Europe/Berlin\n' >"${tz}"
  ln -s "${zi}/Europe/Berlin" "${link}"
  export HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${link}" HOST_ZONEINFO_DIR="${zi}"

  run --separate-stderr host_clock_zone_name
  [ "${status}" -eq 0 ]
  assert_eq "no argument still reads the seam" 'Europe/Berlin' "${output}"

  run --separate-stderr host_clock_files_report
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]

  rm -f "${tz}"
  run --separate-stderr host_clock_files_report
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"error: ${tz} does not exist on this host"* ]]
  assert_not_match "the real /etc path is never named" 'tee /etc/timezone' "${output}"

  fix_line="$(grep -F 'Fix on the host:' <<<"${output}" | head -n 1)"
  assert_eq "the fix line names the seam path and the zone the seam link holds" \
    "note: Fix on the host: printf '%s\\n' Europe/Berlin | sudo tee ${tz} >/dev/null" \
    "${fix_line}"
}

@test "host_state: host_clock_files_report speaks once when both seams name one path" {
  # An operator who points both HOST_* overrides at one file (a chroot probe, a container
  # that only carries /etc/localtime) describes ONE bind, not two. Answering twice would
  # print the same error and the same fix twice and read as two things to repair.
  local zi="${BATS_TEST_TMPDIR}/usr/share/zoneinfo"
  local one="${BATS_TEST_TMPDIR}/etc/localtime"
  local err_count fix_count fix_line

  mkdir -p "${zi}" "$(dirname "${one}")"

  run --separate-stderr host_clock_files_report "" "${one}" "${one}" "${zi}"
  [ "${status}" -eq 1 ]
  err_count="$(grep -c '^error: ' <<<"${stderr}" || true)"
  fix_count="$(grep -c 'Fix on the host:' <<<"${output}" || true)"
  assert_eq "one error line for one bind" "1" "${err_count}"
  assert_eq "one fix line for one bind" "1" "${fix_count}"
  [[ "${stderr}" == *"error: ${one} does not exist on this host"* ]]

  # The timezone pass is the one that spoke, so the advice is the tee that grows a file
  # the resolver re-reads -- which is also what proves the second pass was skipped
  # rather than both passes printing an identical pair of lines.
  fix_line="$(grep -F 'Fix on the host:' <<<"${output}" | head -n 1)"
  assert_eq "the surviving line is the write, not a link" \
    "note: Fix on the host: printf '%s\\n' Area/City | sudo tee ${one} >/dev/null" \
    "${fix_line}"
  assert_not_match "no second path diagnosis" 'needs a link at a real file under' "${output}"

  # Same once it is the Docker-made directory: one error, one removal, one write.
  mkdir -p "${one}"
  run --separate-stderr host_clock_files_report "" "${one}" "${one}" "${zi}"
  [ "${status}" -eq 1 ]
  assert_eq "still one error line" "1" "$(grep -c '^error: ' <<<"${stderr}" || true)"
  assert_eq "one removal" "1" "$(grep -c 'Remove the leftover first:' <<<"${output}" || true)"
  assert_eq "one write" "1" "$(grep -c 'Fix on the host:' <<<"${output}" || true)"
}
