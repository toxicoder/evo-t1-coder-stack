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

# A recipe clone with the four probes present and runnable, so the only thing a case
# varies is the gate. Each stub records its own name in ran.log, which is how a case
# proves a probe was not merely reported as skipped but never started.
make_recipe_clone() {
  local dir="$1" probe
  mkdir -p "${dir}/scripts"
  for probe in toolcheck needle visioncheck bench; do
    {
      printf '#!/bin/sh\n'
      printf 'printf "%%s\\n" "%s" >>"${RECIPE_DIR}/ran.log"\n' "${probe}"
      printf 'echo "%s ran"\n' "${probe}"
    } >"${dir}/scripts/${probe}.py"
    chmod +x "${dir}/scripts/${probe}.py"
  done
}

# Run the probe the way the caller runs it: container up, clone present, tests asked
# for. The needle gate is the argument under test, so it is the one the case passes,
# ahead of the fixed assignments because env wants its -u options first.
run_spark_probe() {
  local recipe="$1"
  shift
  run env "$@" STUB_COMPOSE_PS="tf-server running tensorfold/decode-native:0.6.1-cu130" \
    CONTAINER=tf-server RECIPE_DIR="${recipe}" RUN_TESTS=yes have_timeout="" \
    sh "${PROBES_DIR}/spark-verify.sh"
}

@test "probes/spark-verify: the 195k needle is held off a box that has work in flight" {
  local recipe="${BATS_TEST_TMPDIR}/recipe"
  make_recipe_clone "${recipe}"
  run_spark_probe "${recipe}" NEEDLE_WANTED=""
  [ "${status}" -eq 0 ]
  [ "$(last_line)" = "report_end" ]
  assert_match "the needle reports itself skipped" '^needle=skipped' "${output}"
  assert_match "the skip says how to force it" 'needle=skipped.*--needle' "${output}"
  if [ -e "${recipe}/ran.log" ]; then
    ! grep -qx needle "${recipe}/ran.log" ||
      fail "the 195k needle was started on a busy box; ran.log: $(tr '\n' ' ' <"${recipe}/ran.log")"
  fi
  # The other three are cheap and stay scheduled.
  grep -qx toolcheck "${recipe}/ran.log" || fail "toolcheck should still run: $(tr '\n' ' ' <"${recipe}/ran.log")"
}

@test "probes/spark-verify: NEEDLE_WANTED=yes runs the window proof" {
  local recipe="${BATS_TEST_TMPDIR}/recipe"
  make_recipe_clone "${recipe}"
  run_spark_probe "${recipe}" NEEDLE_WANTED=yes
  [ "${status}" -eq 0 ]
  assert_match "the needle ran" '^needle=needle\.py: ok' "${output}"
  grep -qx needle "${recipe}/ran.log" || fail "the needle never started"
}

@test "probes/spark-verify: an unset needle gate does not run the window proof" {
  # The destructive probe fails closed: a caller that forgot the assignment gets a skip.
  local recipe="${BATS_TEST_TMPDIR}/recipe"
  make_recipe_clone "${recipe}"
  run_spark_probe "${recipe}" -u NEEDLE_WANTED
  [ "${status}" -eq 0 ]
  assert_match "the needle reports itself skipped" '^needle=skipped' "${output}"
  if [ -e "${recipe}/ran.log" ] && grep -qx needle "${recipe}/ran.log"; then
    fail "the needle ran without being asked for"
  fi
}

# ── probes/seed-owner.sh ────────────────────────────────────────────────────

@test "probes/seed-owner: a path that is not there answers absent" {
  run sh "${PROBES_DIR}/seed-owner.sh" /no/such/file 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "absent" ]
}

@test "probes/seed-owner: the optional 4th marker reads a comment-free TOML config as managed" {
  # The CLI-dropped-comment bug, at the probe level: `grok mcp add` rewrites
  # ~/.grok/config.toml through a parse-and-write-back that deletes every
  # comment line, so the one marker such a file still carries is the TOML key.
  # A caller that hands the probe that 4th marker must get "managed".
  local cfg="${BATS_TEST_TMPDIR}/config.toml"
  printf 'model = "agent"\n[mcp_servers.searxng]\nenabled = true\n__evoT1Stack = true\n' >"${cfg}"
  run sh "${PROBES_DIR}/seed-owner.sh" "${cfg}" 'managed-by: evo-t1-coder-stack' \
    '"__evoT1Stack": true' '__evoT1Stack = true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "managed" ]

  # Three args is still the old probe: the marker list comes from the caller,
  # so the same file is user-owned when nobody asked about the TOML key.
  run sh "${PROBES_DIR}/seed-owner.sh" "${cfg}" 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "user" ]

  # And an empty 4th argument is no marker at all: grep -e "" matches every
  # file, which would hand "managed" to everything.
  run sh "${PROBES_DIR}/seed-owner.sh" "${cfg}" 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true' ''
  [ "${status}" -eq 0 ]
  [ "${output}" = "user" ]
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
