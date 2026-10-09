#!/usr/bin/env bats
#
# ## common.bats — unit coverage for scripts/lib/common.sh
#
# Hermetic: timeout and docker resolve through tests/bats/tool_stubs.
# Usage: bats tests/bats/common.bats
# Safety: no daemon, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs timeout docker curl
}

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
}

drive() {
  local f="${BATS_TEST_TMPDIR}/driver.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
      "source '${REPO_ROOT}/scripts/lib/common.sh'" \
      "cd '${BATS_TEST_TMPDIR}'"
    printf '%s\n' "$@"
  } > "${f}"
  chmod +x "${f}"
  run --separate-stderr bash "${f}"
}

@test "test_helpers: assert_match passes and fails the way gates expect" {
  run bash -c "source '${REPO_ROOT}/tests/test_helpers.sh'; assert_match x 'b+c' 'abcd'"
  [ "${status}" -eq 0 ]
  run bash -c "source '${REPO_ROOT}/tests/test_helpers.sh'; assert_match x 'zz' 'abc'"
  [ "${status}" -eq 1 ]
}

# ── common.sh ───────────────────────────────────────────────────────────────

@test "common: env_get reads the LAST assignment and strips wrapping quotes" {
  source_libs
  printf '%s\n' 'KEY=first' 'KEY="dq"' "KEY='sq'" > "${BATS_TEST_TMPDIR}/.envx"
  v="$(env_get "${BATS_TEST_TMPDIR}/.envx" KEY)"
  [ "${v}" = "sq" ]
  [ "$(env_get "${BATS_TEST_TMPDIR}/.envx" MISSING)" = "" ]
  [ "$(env_get "${BATS_TEST_TMPDIR}/nofile" KEY)" = "" ]
}

@test "common: fact_get falls back for empty and NOTSET and passes real values" {
  source_libs
  printf '%s\n' 'G=hope' 'T=NOTSET' > "${BATS_TEST_TMPDIR}/fact"
  [ "$(fact_get "${BATS_TEST_TMPDIR}/fact" G nope)" = "hope" ]
  [ "$(fact_get "${BATS_TEST_TMPDIR}/fact" T nope)" = "nope" ]
  [ "$(fact_get "${BATS_TEST_TMPDIR}/fact" M 9)" = "9" ]
}

@test "common: first_line quotes the first complaint line and never aborts the caller" {
  drive 'a="$(first_line "line one
line two")"; b="$(first_line "   ")"; printf "[%s][%s]" "${a}" "${b}"'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[line one][]" ]
}

@test "common: truthy accepts on/1/true/yes and rejects everything else" {
  source_libs
  if ! (truthy on && truthy ON && truthy 1 && truthy TRUE && truthy Yes); then
    fail "truthy rejected a truthy spelling"
  fi
  if truthy off || truthy maybe; then
    fail "truthy accepted a falsy spelling"
  fi
}

@test "common: canonical_url strips scheme, port and path" {
  source_libs
  [ "$(canonical_url "http://h:8888/v1")" = "h" ]
  [ "$(canonical_url "https://h.lan:11434")" = "h.lan" ]
  [ "$(canonical_url "h.lan")" = "h.lan" ]
}

@test "common: json_escape escapes and clips; json_value types correctly" {
  source_libs
  esc="$(json_escape 'a"b\c')"
  [ "${esc}" = 'a\"b\\c' ]
  long="$(printf 'x%.0s' {1..200})"
  clipped="$(json_escape "${long}")"
  [ "${#clipped}" -eq 180 ]
  [ "$(json_value)" = "null" ]
  [ "$(json_value "42")" = "42" ]
  [ "$(json_value "abc")" = "\"abc\"" ]
}

@test "common: log goes to stdout, or to stderr when JSON_MODE is on" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; log plain"
  [ "${status}" -eq 0 ]
  [ "${output}" = "plain" ]
  [ -z "${stderr}" ]
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; JSON_MODE=1; export JSON_MODE; log jsonified"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ "${stderr}" = "jsonified" ]
}

@test "common: warn, note, and err keep their prefixes" {
  source_libs
  run --separate-stderr warn "soft"
  [ "${status}" -eq 0 ]
  [ "${output}" = "warning: soft" ]
  run --separate-stderr note "aside"
  [ "${output}" = "note: aside" ]
  run --separate-stderr err "bad"
  [ "${stderr}" = "error: bad" ]
  has_tool bash
}

@test "common: die prints on stderr and exits 1" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; die 'boom here'"
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: boom here" ]
}

@test "common: require_tool skips missing tools locally and is fatal under CI=true" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_tool nosuchtool123; exit 7"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nosuchtool123 is not on PATH"* ]]
  run --separate-stderr bash -c "CI=true; export CI; source '${REPO_ROOT}/scripts/lib/common.sh'; require_tool nosuchtool123 'missing under CI'; exit 7"
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: missing under CI" ]
}

@test "common: capped_run runs under timeout(1) when present, and uncapped when absent" {
  source_libs
  run --separate-stderr capped_run 5 docker compose exec -T db echo hi
  [ "${status}" -eq 0 ]
  [ "${output}" = "hi" ]
  [ "$(stub_log_last timeout)" = "timeout 5 docker compose exec -T db echo hi" ]
  [ "$(stub_log_last docker)" = "docker compose exec -T db echo hi" ]

  # Uncapped fallback: when timeout(1) is nowhere on PATH the command still
  # runs, uncapped (this is how a macOS host without coreutils keeps
  # working). PATH is pinned to a dir holding ONLY the curl stub plus the
  # bash/env its shebang needs — no timeout(1) anywhere (a non-executable
  # decoy file would NOT be skipped by `command -v` here, verified) — so
  # has_tool must report absence and capped_run must exec the tool directly.
  plain_bin="$(mktemp -d "${BATS_TEST_TMPDIR}/plain.XXXXXX")"
  cp "${STUB_BIN_DIR}/curl" "${plain_bin}/curl"
  # The checkout may store the stub as mode 100644. command -v still finds it,
  # but the kernel will not exec it, so the uncapped path would return 126
  # instead of the stub's 22.
  chmod 755 "${plain_bin}/curl"
  ln -s "$(command -v bash)" "${plain_bin}/bash"
  ln -s "$(command -v env)" "${plain_bin}/env"
  run --separate-stderr bash -c "export PATH='${plain_bin}'; export STUB_LOG='${STUB_LOG}'; source '${REPO_ROOT}/scripts/lib/common.sh'; if has_tool timeout; then exit 7; fi; capped_run 5 curl -s http://10.255.255.1:11434/version"
  [ "${status}" -eq 22 ]
  [ -z "${output}" ]
}

