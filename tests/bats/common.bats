#!/usr/bin/env bats
#
# ## common.bats — unit coverage for scripts/lib/common.sh
#
# Hermetic: timeout and docker resolve through tests/bats/tool_stubs.
# Usage: bazelisk test //tests:bats_common_test   (from any cwd)
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

@test "common: env_get answers empty without aborting a strict-mode caller" {
  # drive() runs under set -euo pipefail: the bare call substitution here
  # would abort the driver while env_get still failed (failing sed through
  # pipefail), which is exactly how a missing or unreadable env file once
  # killed dev-stack's report_urls in production.
  drive 'v="$(env_get nofile KEY)"; printf '[%s]' "${v}"'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[]" ]
  printf 'KEY=hidden\n' > "${BATS_TEST_TMPDIR}/locked.env"
  chmod 000 "${BATS_TEST_TMPDIR}/locked.env"
  drive 'v="$(env_get "${PWD}/locked.env" KEY)"; printf '[%s]' "${v}"'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[]" ]
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

@test "common: section, phase, and ok format grouping lines" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; section Bootstrap; phase checking docker; ok compose plugin"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'\n== Bootstrap ==\n-> checking docker\nok: compose plugin' ]
}

@test "common: summary counts ok/warn/fail and lists failures" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; ok one; warn two; fail_item boom; summary 'bazelisk run //scripts:prod-stack -- up'"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'ok: one\nwarning: two\nsummary: 1 ok, 1 warnings, 1 failed\n  failed: boom\nnext: bazelisk run //scripts:prod-stack -- up' ]
  [ "${stderr}" = "error: boom" ]
}

@test "common: section/phase/ok/summary go to stderr under JSON_MODE" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; JSON_MODE=1; export JSON_MODE; phase wait; ok ready; summary"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ "${stderr}" = $'-> wait\nok: ready\nsummary: 1 ok, 0 warnings, 0 failed' ]
}

@test "common: skip prints via log and exits 0, stderr under JSON_MODE" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; skip 'not yet'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "not yet" ]
  [ -z "${stderr}" ]
  run --separate-stderr bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; JSON_MODE=1; export JSON_MODE; skip 'not yet'"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ "${stderr}" = "not yet" ]
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

# ── resolve_checkout ────────────────────────────────────────────────────────
# Every CLI that reads the checkout's .env resolves the checkout through this
# helper, so the candidate order, the marker, and the refusals are the contract.
# The runfiles refusal is what stops `bazelisk run` from rewriting a throwaway
# copy of the repo while the checkout keeps the old bytes; the REPO_ROOT
# exemption is what lets the Bats runner name the copy under test as the root.

proven_checkout() {
  # Print a fresh directory that proves itself as a checkout.
  local dir="${BATS_TEST_TMPDIR?}/$1"
  mkdir -p "${dir}"
  : >"${dir}/docker-compose.yml"
  printf '%s' "${dir}"
}

clear_root_names() {
  # Drop every inherited checkout name and stand in a directory that holds no
  # marker: the runner exports REPO_ROOT and cds into the copy of the repo under
  # test, either of which would otherwise answer before the candidate under test.
  REPO_ROOT=""
  BUILD_WORKSPACE_DIRECTORY=""
  GITHUB_WORKSPACE=""
  cd "$(mktemp -d "${BATS_TEST_TMPDIR?}/nowhere.XXXXXX")"
}

@test "common: resolve_checkout takes REPO_ROOT first, then BUILD_WORKSPACE_DIRECTORY" {
  source_libs
  local a b c
  a="$(proven_checkout explicit-a)"
  b="$(proven_checkout explicit-b)"
  c="$(proven_checkout explicit-c)"
  clear_root_names
  REPO_ROOT="${a}"
  BUILD_WORKSPACE_DIRECTORY="${b}"
  GITHUB_WORKSPACE="${c}"
  run --separate-stderr resolve_checkout "${c}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${a}" ]
  REPO_ROOT=""
  run --separate-stderr resolve_checkout "${c}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${b}" ]
}

@test "common: resolve_checkout falls through to the cwd, then the script's own tree" {
  source_libs
  local pwdtree selfroot
  pwdtree="$(proven_checkout pwd-tree)"
  selfroot="$(proven_checkout self-tree)"
  mkdir -p "${selfroot}/scripts"
  clear_root_names
  cd "${pwdtree}"
  run --separate-stderr resolve_checkout "${selfroot}/scripts"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${pwdtree}" ]
  cd "$(mktemp -d "${BATS_TEST_TMPDIR}/empty.XXXXXX")"
  run --separate-stderr resolve_checkout "${selfroot}/scripts"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${selfroot}/scripts/.." ]
}

@test "common: a directory without the marker is refused and the marker is named" {
  source_libs
  local bare
  bare="$(mktemp -d "${BATS_TEST_TMPDIR?}/bare.XXXXXX")"
  clear_root_names
  REPO_ROOT="${bare}"
  BUILD_WORKSPACE_DIRECTORY="${bare}"
  GITHUB_WORKSPACE="${bare}"
  run --separate-stderr resolve_checkout "${bare}"
  [ "${status}" -eq 5 ]
  assert_match "the refusal is printed" 'unresolvable repo root' "${stderr}"
  assert_match "the marker it wanted is named" 'need docker-compose.yml' "${stderr}"
}

@test "common: the proof marker is the caller's choice" {
  source_libs
  local tree
  tree="$(mktemp -d "${BATS_TEST_TMPDIR?}/makefile-tree.XXXXXX")"
  : >"${tree}/Makefile"
  clear_root_names
  REPO_ROOT="${tree}"
  run --separate-stderr resolve_checkout "${tree}" Makefile
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tree}" ]
}

@test "common: a caller that names no directory of its own is refused" {
  source_libs
  clear_root_names
  run --separate-stderr resolve_checkout ""
  [ "${status}" -eq 5 ]
  assert_match "the refusal says why" "needs the calling script's own directory" "${stderr}"
}

@test "common: a Bazel copy is refused as derived, honoured as REPO_ROOT" {
  source_libs
  local tree
  tree="${BATS_TEST_TMPDIR?}/bazel-out/k8-fastbuild/bin/x.runfiles/_main"
  mkdir -p "${tree}"
  : >"${tree}/docker-compose.yml"
  clear_root_names
  BUILD_WORKSPACE_DIRECTORY="${tree}"
  run --separate-stderr resolve_checkout "${tree}/scripts"
  [ "${status}" -eq 5 ]
  assert_match "the refusal names what it found" 'runfiles copy' "${stderr}"
  REPO_ROOT="${tree}"
  BUILD_WORKSPACE_DIRECTORY=""
  run --separate-stderr resolve_checkout "${tree}/scripts"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tree}" ]
}

@test "common: a candidate that does not exist is skipped, not fatal" {
  source_libs
  local tree
  tree="$(proven_checkout after-ghost)"
  clear_root_names
  REPO_ROOT="${BATS_TEST_TMPDIR}/does-not-exist"
  BUILD_WORKSPACE_DIRECTORY="${tree}"
  run --separate-stderr resolve_checkout "${tree}/scripts"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tree}" ]
}

