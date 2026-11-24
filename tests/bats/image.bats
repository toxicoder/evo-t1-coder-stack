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

# -- gh-stack: the optional stacked-pull-request extension --------------------
# Both flag states are driven, not just grepped: the guarded RUN body is lifted
# out of the Dockerfile and run under bash with gh and chown stubbed inside the
# bats temp directory, so "off" is proven by the stub log staying empty and
# "on" by the argv the stub recorded carrying the pin from tool-versions.env.

GH_STACK_TMP=""
GH_STACK_HOME=""
GH_STACK_CALL_LOG=""

gh_stack_setup() {
  GH_STACK_TMP="${BATS_TEST_TMPDIR}/gh-stack"
  GH_STACK_HOME="${GH_STACK_TMP}/home"
  GH_STACK_CALL_LOG="${GH_STACK_TMP}/gh-calls"
  mkdir -p "${GH_STACK_TMP}/bin" "${GH_STACK_HOME}"
  : >"${GH_STACK_CALL_LOG}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"${GH_STACK_CALL_LOG}"' >"${GH_STACK_TMP}/bin/gh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${GH_STACK_TMP}/bin/chown"
  chmod +x "${GH_STACK_TMP}/bin/gh" "${GH_STACK_TMP}/bin/chown"
}

gh_stack_body() {
  # Docker strips comment lines inside a continued instruction and plain bash
  # does not, so the extraction strips them too, drops the ARG line, and rewrites
  # the coder home into the temp directory: the run touches nothing else.
  sed -n '/^ARG GH_STACK_ENABLED=/,/^$/p' "${REPO_ROOT}/images/dev/Dockerfile" |
    grep -v '^ARG GH_STACK_ENABLED=' |
    grep -vE '^[[:space:]]*#' |
    sed -e 's/^RUN //' -e "s|/home/coder|${GH_STACK_HOME}|g"
}

gh_stack_pin() {
  sed -n 's|^GH_STACK_VERSION=||p' "${REPO_ROOT}/images/dev/tool-versions.env" | tail -n 1
}

gh_stack_run() {
  # The two ARGs a build supplies: the flag on the command line, the pin through
  # --build-arg the way scripts/build-dev-image.sh forwards every pin. bash -u
  # then fails the run if the layer ever reaches for anything else.
  GH_STACK_CALL_LOG="${GH_STACK_CALL_LOG}" GH_STACK_ENABLED="$1" \
    GH_STACK_VERSION="$(gh_stack_pin)" \
    PATH="${GH_STACK_TMP}/bin:${PATH}" \
    bash -euo pipefail -c "$(gh_stack_body)"
}

@test "image: gh-stack ships off and the layer installs nothing" {
  run grep -cE '^ARG GH_STACK_ENABLED=false$' "${REPO_ROOT}/images/dev/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = "1" ]

  gh_stack_setup
  gh_stack_run false
  [ ! -s "${GH_STACK_CALL_LOG}" ]
  [ ! -d "${GH_STACK_HOME}/.local/share/gh" ]
}

@test "image: gh-stack on installs exactly the pinned extension" {
  pin="$(gh_stack_pin)"
  [ -n "${pin}" ]

  gh_stack_setup
  gh_stack_run true
  [ -d "${GH_STACK_HOME}/.local/share/gh" ]
  mapfile -t calls <"${GH_STACK_CALL_LOG}"
  [ "${calls[0]}" = "extension install github/gh-stack --pin ${pin}" ]
  [ "${calls[1]}" = "extension list" ]
}
