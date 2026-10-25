#!/usr/bin/env bats
#
# ## py_helpers.bats — unit coverage for scripts/lib/*.py helper programs
#
# Usage: bazelisk test //tests:bats_py_helpers_test   (from any cwd)
# Safety: no daemon, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

@test "json_copy_key: copies a present key and leaves an absent key alone" {
  local dest current
  dest="${BATS_TEST_TMPDIR}/dest.json"
  current="${BATS_TEST_TMPDIR}/current.json"
  printf '%s\n' '{"a":1,"cline.apiKey":"secret"}' >"${current}"
  printf '%s\n' '{"a":2}' >"${dest}"
  run python3 "${REPO_ROOT}/scripts/lib/json_copy_key.py" "${dest}" "${current}" "cline.apiKey"
  [ "${status}" -eq 0 ]
  grep -q '"cline.apiKey": "secret"' "${dest}"
  printf '%s\n' '{"a":3}' >"${dest}"
  run python3 "${REPO_ROOT}/scripts/lib/json_copy_key.py" "${dest}" "${current}" "missing"
  [ "${status}" -eq 0 ]
  grep -q '"a":3' "${dest}"
  run grep -F 'cline.apiKey' "${dest}"
  [ "${status}" -ne 0 ]
}

@test "json_copy_key: refuses invalid JSON" {
  local dest current
  dest="${BATS_TEST_TMPDIR}/dest.json"
  current="${BATS_TEST_TMPDIR}/bad.json"
  printf '%s\n' '{"ok":true}' >"${dest}"
  printf '%s\n' '{not json' >"${current}"
  run python3 "${REPO_ROOT}/scripts/lib/json_copy_key.py" "${dest}" "${current}" "ok"
  [ "${status}" -eq 1 ]
}

@test "parse_yaml: accepts valid files and refuses a broken one" {
  local good bad
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  good="${BATS_TEST_TMPDIR}/good.yaml"
  bad="${BATS_TEST_TMPDIR}/bad.yaml"
  printf '%s\n' 'a: 1' 'b: [2, 3]' >"${good}"
  run python3 "${REPO_ROOT}/scripts/lib/parse_yaml.py" "${good}"
  [ "${status}" -eq 0 ]
  printf '%s\n' 'a: [' >"${bad}"
  run python3 "${REPO_ROOT}/scripts/lib/parse_yaml.py" "${good}" "${bad}"
  [ "${status}" -eq 1 ]
}

@test "host_resolve: localhost succeeds and a reserved invalid name fails" {
  run python3 "${REPO_ROOT}/scripts/lib/host_resolve.py" localhost
  [ "${status}" -eq 0 ]
  run python3 "${REPO_ROOT}/scripts/lib/host_resolve.py" "no-such-host.invalid"
  [ "${status}" -eq 1 ]
  run python3 "${REPO_ROOT}/scripts/lib/host_resolve.py"
  [ "${status}" -eq 1 ]
}
