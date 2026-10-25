#!/usr/bin/env bats
#
# ## image.bats — pin check for the golden dev image, with no docker build.
#
# Usage: bazelisk test //tests:bats_image_test   (from any cwd)
# Safety: reads the repo Dockerfile and tool-versions.env; writes only under
# the bats temp directory.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/image.sh"
}

@test "image: every tool-versions key is a Dockerfile ARG" {
  source_libs
  run missing_version_pins \
    "${REPO_ROOT}/images/dev/Dockerfile" \
    "${REPO_ROOT}/images/dev/tool-versions.env"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "image: a continued ARG block counts, and a missing key is named" {
  source_libs
  dir="${BATS_TEST_TMPDIR}/img"
  mkdir -p "${dir}"
  printf '%s\n' 'ARG FOO=1 \' '  BAR=2' 'ARG BAZ=3' >"${dir}/Dockerfile"
  printf '%s\n' 'FOO=1' 'BAR=2' 'BAZ=3' 'QUX=9' >"${dir}/versions.env"
  names="$(dockerfile_arg_names "${dir}/Dockerfile")"
  [[ ${names} == *FOO* ]]
  [[ ${names} == *BAR* ]]
  [[ ${names} == *BAZ* ]]
  run missing_version_pins "${dir}/Dockerfile" "${dir}/versions.env"
  [ "${status}" -eq 0 ]
  [ "${output}" = "QUX" ]
}

@test "image: arg defaults match silently; a wrong and an absent default are named" {
  source_libs
  dir="${BATS_TEST_TMPDIR}/pins"
  mkdir -p "${dir}"
  printf '%s\n' 'ARG FOO=1' 'ARG BAR=2' 'ARG TARGETARCH' >"${dir}/Dockerfile"
  printf '%s\n' 'FOO=1' 'BAR=2' >"${dir}/matching.env"
  printf '%s\n' 'FOO=1' 'BAR=9' 'BAZ=3' >"${dir}/drift.env"

  run mismatched_arg_defaults "${dir}/Dockerfile" "${dir}/matching.env"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run mismatched_arg_defaults "${dir}/Dockerfile" "${dir}/drift.env"
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "BAR pin=9 dockerfile=2" ]
  [ "${lines[1]}" = "BAZ pin=3 dockerfile=" ]
}

@test "image: dockerfile_arg_defaults reads defaults across a continued ARG block" {
  source_libs
  dir="${BATS_TEST_TMPDIR}/cont"
  mkdir -p "${dir}"
  printf '%s\n' '# ARG COMMENTED=nope' 'ARG FOO=1 \' '  BAR=2' 'ARG TARGETARCH' >"${dir}/Dockerfile"
  printf '%s\n' 'FOO=1' 'BAR=3' >"${dir}/versions.env"

  run dockerfile_arg_defaults "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "BAR=2" ]
  [ "${lines[1]}" = "FOO=1" ]

  run mismatched_arg_defaults "${dir}/Dockerfile" "${dir}/versions.env"
  [ "${status}" -eq 0 ]
  [ "${output}" = "BAR pin=3 dockerfile=2" ]
}

@test "image: the real Dockerfile ARG defaults equal every tool-versions pin" {
  source_libs
  run mismatched_arg_defaults \
    "${REPO_ROOT}/images/dev/Dockerfile" \
    "${REPO_ROOT}/images/dev/tool-versions.env"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
