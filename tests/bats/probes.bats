#!/usr/bin/env bats
#
# ## probes.bats — unit coverage for the sh payloads under scripts/lib/probes/
#
# These are the probe bodies that used to travel inside quoted heredocs and in
# inline `sh -c` strings. They run under `sh` on a remote host or through
# `docker exec sh -c`, so every case here runs them with sh and never sources
# them: a payload that only works when the caller's bash env is already set up
# would pass here and fail on the far end.
# Hermetic: docker resolves through tests/bats/tool_stubs.
# Usage: bazelisk test //tests:bats_probes_test   (from any cwd)
# Safety: no daemon, no network, no ssh, no Spark box.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
PROBES_DIR=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PROBES_DIR="${REPO_ROOT}/scripts/lib/probes"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker
}

last_line() {
  printf '%s\n' "${output}" | tail -n 1
}

# ── probes/github-auth.sh ───────────────────────────────────────────────────

@test "probes/github-auth: credential probe names its slots and its push verdict" {
  grep -Eq '^slot_name\(\) \{' "${PROBES_DIR}/github-auth.sh"
  grep -q 'PUSH-READY' "${PROBES_DIR}/github-auth.sh"
}

# ── probes/spark-configure.sh ───────────────────────────────────────────────

@test "probes/spark-configure: the report ends with report_end" {
  grep -q '^say report_end$' "${PROBES_DIR}/spark-configure.sh"
}

@test "probes/spark-configure: no clone and no container still answers a full report" {
  run env -u CONTAINER -u RUN_TESTS RECIPE_DIR="${BATS_TEST_TMPDIR}/no-such-recipe" \
    sh "${PROBES_DIR}/spark-configure.sh"
  [ "${status}" -eq 0 ]
  [ "$(last_line)" = "report_end" ]
  [[ "${output}" == *"clone=missing"* ]]
}

# ── probes/spark-verify.sh ──────────────────────────────────────────────────

@test "probes/spark-verify: the report helpers are defined at column 0" {
  grep -Eq '^say\(\) \{' "${PROBES_DIR}/spark-verify.sh"
  grep -Eq '^fact\(\) \{' "${PROBES_DIR}/spark-verify.sh"
  grep -Eq '^run_test\(\) \{' "${PROBES_DIR}/spark-verify.sh"
}

@test "probes/spark-verify: a box with no recipe clone still closes its report" {
  run env -u CONTAINER -u RUN_TESTS RECIPE_DIR="${BATS_TEST_TMPDIR}/no-such-recipe" \
    sh "${PROBES_DIR}/spark-verify.sh"
  [ "${status}" -eq 0 ]
  [ "$(last_line)" = "report_end" ]
}

# ── probes/seed-owner.sh ────────────────────────────────────────────────────

@test "probes/seed-owner: a path that is not there answers absent" {
  run sh "${PROBES_DIR}/seed-owner.sh" /no/such/file 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "absent" ]
}

# ── probes/seed-find-mtime.sh and probes/seed-rm-mtime.sh ───────────────────

@test "probes/seed-*-mtime: the sweep lists what it would delete, then deletes it" {
  root="${BATS_TEST_TMPDIR}/stale"
  mkdir -p "${root}"
  printf 'old' > "${root}/old.txt"
  printf 'new' > "${root}/new.txt"
  touch -t 202001010000 "${root}/old.txt"
  run sh "${PROBES_DIR}/seed-find-mtime.sh" 30 "${root}" "${BATS_TEST_TMPDIR}/no-such-root"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${root}/old.txt" ]
  run sh "${PROBES_DIR}/seed-rm-mtime.sh" 30 "${root}"
  [ "${status}" -eq 0 ]
  [ ! -e "${root}/old.txt" ]
  [ -f "${root}/new.txt" ]
}

# ── probes/seed-write.sh ────────────────────────────────────────────────────

@test "probes/seed-write: stdin lands at the named path, parent created" {
  dest="${BATS_TEST_TMPDIR}/deep/inner/config.toml"
  printf 'hi' | sh "${PROBES_DIR}/seed-write.sh" "${dest}"
  [ -f "${dest}" ]
  [ "$(cat "${dest}")" = "hi" ]
}
