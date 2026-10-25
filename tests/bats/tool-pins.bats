#!/usr/bin/env bats
#
# ## tool-pins.bats — unit coverage for scripts/lib/tool_pins.sh
#
# Usage: bazelisk test //tests:bats_tool_pins_test   (from any cwd)
# Safety: reads the pin file and a scratch copy; no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/tool_pins.sh"
}

@test "tool_pins: file path hangs off the repo root" {
  source_libs
  [ "$(tool_pins_file "${REPO_ROOT}")" = "${REPO_ROOT}/images/dev/tool-versions.env" ]
}

@test "tool_pins: get reads the last KEY=value and rejects a bad key" {
  source_libs
  dir="${BATS_TEST_TMPDIR}/pins"
  mkdir -p "${dir}"
  printf '%s\n' 'FOO=first' '# FOO=comment' 'FOO=second' 'BAR=keep' >"${dir}/pins.env"
  [ "$(tool_pins_get "${dir}/pins.env" FOO)" = "second" ]
  [ "$(tool_pins_get "${dir}/pins.env" BAR)" = "keep" ]
  run tool_pins_get "${dir}/pins.env" MISSING
  [ "${status}" -eq 1 ]
  run tool_pins_get "${dir}/pins.env" 'foo;bar'
  [ "${status}" -eq 1 ]
  run tool_pins_get "${dir}/nope.env" FOO
  [ "${status}" -eq 1 ]
}

@test "tool_pins: goarch maps uname and GOARCH spellings" {
  source_libs
  [ "$(tool_pins_goarch x86_64)" = "amd64" ]
  [ "$(tool_pins_goarch amd64)" = "amd64" ]
  [ "$(tool_pins_goarch aarch64)" = "arm64" ]
  [ "$(tool_pins_goarch arm64)" = "arm64" ]
  run tool_pins_goarch ppc64le
  [ "${status}" -eq 1 ]
}

@test "tool_pins: linux URLs carry the pin values from the repo file" {
  source_libs
  pins="$(tool_pins_file "${REPO_ROOT}")"
  bazelisk_ver="$(tool_pins_get "${pins}" BAZELISK_VERSION)"
  shfmt_ver="$(tool_pins_get "${pins}" SHFMT_ASSET_VERSION)"
  buildifier_ver="$(tool_pins_get "${pins}" BUILDIFIER_VERSION)"
  terraform_ver="$(tool_pins_get "${pins}" TERRAFORM_VERSION)"
  [ -n "${bazelisk_ver}" ]
  [ -n "${shfmt_ver}" ]
  [ -n "${buildifier_ver}" ]
  [ -n "${terraform_ver}" ]
  [ "$(tool_pins_linux_url "${pins}" bazelisk amd64)" = \
    "https://github.com/bazelbuild/bazelisk/releases/download/${bazelisk_ver}/bazelisk-linux-amd64" ]
  [ "$(tool_pins_linux_url "${pins}" shfmt arm64)" = \
    "https://github.com/mvdan/sh/releases/download/v${shfmt_ver}/shfmt_v${shfmt_ver}_linux_arm64" ]
  [ "$(tool_pins_linux_url "${pins}" buildifier amd64)" = \
    "https://github.com/bazelbuild/buildtools/releases/download/${buildifier_ver}/buildifier-linux-amd64" ]
  [ "$(tool_pins_linux_url "${pins}" terraform amd64)" = \
    "https://releases.hashicorp.com/terraform/${terraform_ver}/terraform_${terraform_ver}_linux_amd64.zip" ]
  run tool_pins_linux_url "${pins}" no-such-tool amd64
  [ "${status}" -eq 1 ]
  run tool_pins_linux_url "${pins}" bazelisk riscv
  [ "${status}" -eq 1 ]
}
