#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## build-dev-image.bats - hermetic coverage for the flag side of scripts/build-dev-image.sh
#
# The contract pinned here: GH_STACK_ENABLED is a build-time choice rather than
# a version pin, so it lives in the operator's environment rather than in
# images/dev/tool-versions.env, and scripts/build-dev-image.sh is the only place
# that can hand it to the guard in images/dev/Dockerfile. Every test runs the
# whole script against the docker CLI stub and asserts on the argv that reached
# `docker build`, so the flag is driven, not grepped:
#
#   - unset -> `--build-arg GH_STACK_ENABLED=false` and no note line, because an
#     off-by-default flag owes a normal build no noise;
#   - true  -> `--build-arg GH_STACK_ENABLED=true` plus one note naming the
#     github/gh-stack extension and the version it is pinned to;
#   - True, TRUE, yes, 1, on, or a typo -> still false. The Dockerfile guard
#     compares against the literal "true", so a flag that turns on for a near
#     miss is a flag that turns on by accident.
#
# The pins loop is asserted in passing: a GH_VERSION and a GH_STACK_VERSION
# build-arg beside the flag say the single-source-of-truth loop still forwards
# what tool-versions.env carries, flag or no flag.
#
# Usage: bazelisk test //tests:bats_build_dev_image_test   (from any cwd)
# Safety: drives the script with the docker tool stub (STUB_DOCKER_INSPECT=1
# answers the post-build tag check); no daemon, no registry, and nothing written
# outside the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/build-dev-image.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/build-dev-image.sh is not in the tree"
  fi
  use_stubs docker
  # The script inspects the tag it just built to prove it landed in the local
  # store; the stub answers only when told the image exists.
  export STUB_DOCKER_INSPECT=1
  # Never let a flag the harness happens to export decide a default-state test.
  unset GH_STACK_ENABLED
}

# gh_stack_pin - the GH_STACK_VERSION the on-path note has to name, read from the
# one file that carries it, so the suite never hardcodes a pin.
gh_stack_pin() {
  sed -n 's|^GH_STACK_VERSION=||p' "${REPO_ROOT}/images/dev/tool-versions.env" | tail -n 1
}

# build_with_flag <value> - run the script with GH_STACK_ENABLED exported to
# <value>, or with it unset when <value> is empty. bats `run` gives each call its
# own subshell, so the export cannot leak into the next test.
build_with_flag() {
  local value="${1-}"
  if [ -n "${value}" ]; then
    export GH_STACK_ENABLED="${value}"
  else
    unset GH_STACK_ENABLED
  fi
  bash "${SCRIPT}"
}

# build_arg_line - the `docker build` argv the stub recorded (the tag check that
# follows the build issues more docker calls, so take the build line by name).
build_arg_line() {
  stub_log docker | grep '^docker build ' | tail -n 1
}

@test "build-dev-image: the flag ships off and the build is handed false" {
  run build_with_flag ""
  [ "${status}" -eq 0 ]
  line="$(build_arg_line)"
  assert_match "docker build was the call" '^docker build ' "${line}"
  assert_match "the flag is forwarded off" '--build-arg GH_STACK_ENABLED=false' "${line}"
  assert_not_match "an off flag prints no note" 'gh-stack' "${output}"
}

@test "build-dev-image: the pins loop still forwards tool-versions.env" {
  run build_with_flag ""
  [ "${status}" -eq 0 ]
  line="$(build_arg_line)"
  assert_match "gh itself is pinned" '--build-arg GH_VERSION=[0-9]' "${line}"
  assert_match "the extension version is pinned too" '--build-arg GH_STACK_VERSION=[0-9v]' "${line}"
}

@test "build-dev-image: GH_STACK_ENABLED=true turns the extension on" {
  pin="$(gh_stack_pin)"
  [ -n "${pin}" ]

  run build_with_flag true
  [ "${status}" -eq 0 ]
  assert_match "the flag reaches docker as true" '--build-arg GH_STACK_ENABLED=true' "$(build_arg_line)"
  assert_match "one note names the extension" 'note:.*github/gh-stack' "${output}"
  assert_match "the note names the pin it installs" "pinned to ${pin}" "${output}"
  [ "$(printf '%s\n' "${output}" | grep -c 'gh-stack')" -eq 1 ]
}

@test "build-dev-image: only an exact true turns it on" {
  for value in True TRUE yes 1 on tr ue " true"; do
    run build_with_flag "${value}"
    [ "${status}" -eq 0 ]
    assert_match "[${value}] stays off" '--build-arg GH_STACK_ENABLED=false' "$(build_arg_line)"
    assert_not_match "[${value}] prints no note" 'gh-stack' "${output}"
  done
}
