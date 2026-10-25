#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## setup-host.bats - hermetic coverage for scripts/setup-host.sh.
#
# The host bootstrap is the one script that runs from a shell, and --repair is
# the recovery when bazelisk run cannot even start (leftover Docker bind-mounts
# in the runfiles tree). --check writes nothing; an unknown flag is an error.
#
# The Linux fetch branch must take its release URLs from images/dev/
# tool-versions.env through scripts/lib/tool_pins.sh — the golden image's pins —
# so these suites pin the URL helper against the pin file itself and assert no
# release version is hardcoded in the script any more. Terraform's asset is a
# zip, so its member extraction is covered too.
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

# Load the pin lib plus the script's own URL helper into this shell: the helper
# is the seam between setup-host.sh and the golden-image pins, and the test asks
# it the same question the Linux install branch asks it.
load_url_helper() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/tool_pins.sh"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" setup_host_tool_url
}

@test "setup-host: every Linux fetch URL is the pin file's URL, not a hardcoded one" {
  load_url_helper
  local pins tool
  pins="$(tool_pins_file "${REPO_ROOT}")"
  [[ -f ${pins} ]] || skip "images/dev/tool-versions.env is not in the tree"

  for tool in bazelisk shfmt buildifier terraform; do
    run setup_host_tool_url "${pins}" "${tool}" amd64
    [ "${status}" -eq 0 ]
    assert_eq "${tool} url is tool_pins_linux_url's" \
      "$(tool_pins_linux_url "${pins}" "${tool}" amd64)" "${output}"
  done

  # The version in the URL is the pin value, so bumping the pin moves this script.
  run setup_host_tool_url "${pins}" bazelisk amd64
  assert_match "bazelisk carries BAZELISK_VERSION" \
    "/$(tool_pins_get "${pins}" BAZELISK_VERSION)/bazelisk-linux-amd64$" "${output}"
  run setup_host_tool_url "${pins}" shfmt arm64
  assert_match "shfmt carries SHFMT_ASSET_VERSION" \
    "/v$(tool_pins_get "${pins}" SHFMT_ASSET_VERSION)/shfmt_v$(tool_pins_get "${pins}" SHFMT_ASSET_VERSION)_linux_arm64$" \
    "${output}"
  run setup_host_tool_url "${pins}" buildifier arm64
  assert_match "buildifier carries BUILDIFIER_VERSION" \
    "/$(tool_pins_get "${pins}" BUILDIFIER_VERSION)/buildifier-linux-arm64$" "${output}"

  # An arch or a tool the pin file cannot answer for is an error, not a guess.
  run setup_host_tool_url "${pins}" bazelisk riscv64
  [ "${status}" -eq 1 ]
  run setup_host_tool_url "${pins}" shellcheck amd64
  [ "${status}" -eq 1 ]
  run setup_host_tool_url "${BATS_TEST_TMPDIR}/no-pins.env" bazelisk amd64
  [ "${status}" -eq 1 ]
}

@test "setup-host: terraform is fetched as the pinned zip, not skipped for the HashiCorp apt" {
  load_url_helper
  local pins body
  pins="$(tool_pins_file "${REPO_ROOT}")"
  [[ -f ${pins} ]] || skip "images/dev/tool-versions.env is not in the tree"

  run setup_host_tool_url "${pins}" terraform amd64
  [ "${status}" -eq 0 ]
  assert_match "the asset is the pinned zip" \
    "^https://releases\.hashicorp\.com/terraform/$(tool_pins_get "${pins}" TERRAFORM_VERSION)/terraform_.*_linux_amd64\.zip$" \
    "${output}"

  body="$(cat "${SCRIPT}")"
  assert_match "the fetch path extracts the zip" 'setup_host_extract_member' "${body}"
  assert_not_match "the apt-repository skip is gone" 'HashiCorp apt' "${body}"
}

@test "setup-host: the terraform zip yields its member, never the archive" {
  if ! command -v unzip >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
    skip "no unzip or bsdtar to read the test archive"
  fi
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" setup_host_extract_member

  local dir zip out
  dir="${BATS_TEST_TMPDIR}/tf-zip"
  mkdir -p "${dir}"
  printf 'the-terraform-binary\n' >"${dir}/terraform"
  printf 'MPL\n' >"${dir}/LICENSE.txt"
  zip="${dir}/terraform.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "${dir}" && zip -q terraform.zip terraform LICENSE.txt)
  else
    (cd "${dir}" && python3 -m zipfile -c terraform.zip terraform LICENSE.txt)
  fi
  assert_file_exists "the test archive was built" "${zip}"

  out="${BATS_TEST_TMPDIR}/terraform.bin"
  run setup_host_extract_member "${zip}" terraform "${out}"
  [ "${status}" -eq 0 ]
  assert_eq "only the named member is written" 'the-terraform-binary' "$(cat "${out}")"
  assert_file_not_exists "no staging file is left behind" "${out}.extracted"

  run setup_host_extract_member "${zip}" no-such-member "${out}.missing"
  [ "${status}" -eq 1 ]
  assert_file_not_exists "a missing member writes nothing" "${out}.missing"

  run setup_host_extract_member "${dir}/absent.zip" terraform "${out}.absent"
  [ "${status}" -eq 1 ]
  assert_file_not_exists "an absent zip writes nothing" "${out}.absent"
}

@test "setup-host: the Linux branch reads its versions from the pin file" {
  local body
  body="$(cat "${SCRIPT}")"
  assert_match "the pins lib is sourced" 'source "\$\{SELF_DIR\}/lib/tool_pins\.sh"' "${body}"
  assert_match "URLs come from tool_pins_linux_url" 'tool_pins_linux_url' "${body}"
  assert_match "the arch comes from tool_pins_goarch" 'tool_pins_goarch' "${body}"
  assert_match "the pin file is resolved from SETUP_ROOT" \
    'tool_pins_file "\$\{SETUP_ROOT\}"' "${body}"

  # The skew this removes: versions baked into the script.
  assert_not_match "no hardcoded bazelisk release" 'v1\.29\.0' "${body}"
  assert_not_match "no hardcoded shfmt release" 'shfmt_v3\.11\.0' "${body}"
  assert_not_match "no hardcoded buildifier release" 'v8\.2\.0' "${body}"
  assert_not_match "no inline uname-to-goarch case" 'goarch=arm64' "${body}"
}
