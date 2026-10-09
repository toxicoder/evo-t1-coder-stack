#!/usr/bin/env bats
#
# ## image.bats — pin check for the golden dev image, with no docker build.
#
# Usage: bats tests/bats/image.bats
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
