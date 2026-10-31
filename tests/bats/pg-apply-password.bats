#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## pg-apply-password.bats — hermetic coverage for scripts/lib/pg-apply-password.sh.
#
# The official postgres image ignores POSTGRES_PASSWORD after the first
# volume init. This wrapper is the db entrypoint that ALTER USER's the role
# to the current env value, and the stack runners source the same file to
# bounce a crash-looping coder. docker, psql and the in-test
# docker-entrypoint.sh / pg_isready stand-ins are stubs; nothing here starts
# a database.
#
# Usage: bazelisk test //tests:bats_pg_apply_password_test   (from any cwd)

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
LIB=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  LIB="${REPO_ROOT}/scripts/lib/pg-apply-password.sh"
  if [ ! -f "${LIB}" ]; then
    skip "scripts/lib/pg-apply-password.sh is not in the tree"
  fi
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  # Pin the seeder log into this test's tree: left alone it defaults to
  # ${TMPDIR:-/tmp}, and a suite that writes to a host-wide path can collide with
  # a parallel run and with a real stack's log on the stack host.
  export CODER_AGENTS_SEED_LOG="${BATS_TEST_TMPDIR}/coder-agents-seeder.log"
  use_stubs psql
  # shellcheck source=/dev/null
  source "${LIB}"
}

@test "pg-apply-password: compose bind-mounts the wrapper as the db entrypoint" {
  local compose="${REPO_ROOT}/docker-compose.yml"
  assert_file_exists "compose file" "${compose}"
  assert_match "entrypoint" 'pg-apply-password\.sh' "$(cat "${compose}")"
  # Overriding entrypoint clears the image CMD; without this the wrapper
  # is exec'd with no args and the container exits 0 without starting postgres.
  assert_match "command postgres" 'command: \["postgres"\]' "$(cat "${compose}")"
  assert_match "tcp healthcheck uses PGPASSWORD" 'PGPASSWORD=' "$(cat "${compose}")"
  assert_file_exists "wrapper is a regular file" "${LIB}"
}

@test "pg-apply-password: pg_password_dollar_tag skips a tag that appears in the password" {
  run --separate-stderr pg_password_dollar_tag "secret"
  [ "${status}" -eq 0 ]
  assert_eq "default tag" "evoT1pw" "${output}"

  run --separate-stderr pg_password_dollar_tag "xxevoT1pwyy"
  [ "${status}" -eq 0 ]
  assert_eq "collision bumped" "evoT1pw1" "${output}"

  run --separate-stderr pg_password_dollar_tag "evoT1pwevoT1pw1"
  [ "${status}" -eq 0 ]
  assert_eq "second collision" "evoT1pw2" "${output}"
}

@test "pg-apply-password: pg_password_alter_sql dollar-quotes the password and quotes the role" {
  run --separate-stderr pg_password_alter_sql coder "s3cret'with-quote"
  [ "${status}" -eq 0 ]
  assert_match "role" 'ALTER USER "coder" WITH PASSWORD' "${output}"
  assert_match "dollar tag" '\$evoT1pw\$' "${output}"
  assert_match "password body" "s3cret'with-quote" "${output}"

  run --separate-stderr pg_password_alter_sql 'coder"admin' "pw"
  [ "${status}" -eq 0 ]
  assert_match "embedded quote doubled" 'ALTER USER "coder""admin" WITH PASSWORD' "${output}"
}

@test "pg-apply-password: pg_apply_role_password skips an empty password and does not call psql" {
  run --separate-stderr pg_apply_role_password coder "" coder
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count psql)" -eq 0 ]

  run --separate-stderr pg_apply_role_password "" "secret" coder
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "pg-apply-password: pg_wait_ready succeeds as soon as pg_isready does" {
  cat >"${BATS_TEST_TMPDIR}/bin/pg_isready" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "${BATS_TEST_TMPDIR}/bin/pg_isready"
  run --separate-stderr pg_wait_ready coder
  [ "${status}" -eq 0 ]
}

@test "pg-apply-password: pg_apply_role_password sends ALTER USER through psql on stdin" {
  run --separate-stderr pg_apply_role_password coder "new-secret" coder
  [ "${status}" -eq 0 ]
  assert_match "psql user" 'psql -U coder -d coder -v ON_ERROR_STOP=1 -q$' "$(stub_log_last psql)"
}

@test "pg-apply-password: compose_up_or_diagnose_db is a no-op failure without run_compose" {
  unset -f run_compose 2>/dev/null || true
  run --separate-stderr compose_up_or_diagnose_db
  [ "${status}" -eq 1 ]
}

@test "pg-apply-password: compose_up_or_diagnose_db prints db logs when up fails" {
  local logf="${STUB_LOG}/run_compose.log"
  : >"${logf}"
  run_compose() {
    printf 'run_compose %s\n' "$*" >>"${STUB_LOG}/run_compose.log"
    if [[ $* == *up* ]]; then
      return 1
    fi
    if [[ $* == *logs* ]]; then
      printf '%s\n' 'db: exec /usr/local/bin/pg-apply-password.sh: empty argv, exited 0'
    fi
    return 0
  }

  run --separate-stderr compose_up_or_diagnose_db
  [ "${status}" -eq 1 ]
  assert_match "note" 'last db logs follow' "${stderr}"
  assert_match "db log body" 'empty argv, exited 0' "${output}"
  assert_match "asked up" 'up -d' "$(cat "${logf}")"
  assert_match "asked db logs" 'logs --tail 80 db' "$(cat "${logf}")"
}

@test "pg-apply-password: restart_coder_if_pg_auth_failed is a no-op without run_compose" {
  unset -f run_compose 2>/dev/null || true
  run --separate-stderr restart_coder_if_pg_auth_failed
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "pg-apply-password: restart_coder_if_pg_auth_failed bounces coder only when logs show auth failure" {
  local logf="${STUB_LOG}/run_compose.log"
  : >"${logf}"
  run_compose() {
    printf 'run_compose %s\n' "$*" >>"${STUB_LOG}/run_compose.log"
    if [[ $* == *logs* ]]; then
      printf '%s\n' "${FAKE_LOGS:-}"
    fi
    return 0
  }
  log() { printf '%s\n' "$*"; }

  FAKE_LOGS='coder started'
  run --separate-stderr restart_coder_if_pg_auth_failed
  [ "${status}" -eq 0 ]
  assert_match "read logs" 'logs --tail 30 coder' "$(cat "${logf}")"
  assert_not_match "no bounce" 'restart coder' "$(cat "${logf}")"

  : >"${logf}"
  FAKE_LOGS='pq: password authentication failed for user "coder"'
  run --separate-stderr restart_coder_if_pg_auth_failed
  [ "${status}" -eq 0 ]
  assert_match "announced" 'restarting coder' "${output}"
  assert_match "bounced" 'restart coder' "$(cat "${logf}")"
}

@test "pg-apply-password: start_coder_agents_wait is a no-op when the seeder is missing" {
  run --separate-stderr start_coder_agents_wait "${BATS_TEST_TMPDIR}/no-such-root"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "pg-apply-password: start_coder_agents_wait honours SKIP_CODER_AGENTS" {
  SKIP_CODER_AGENTS=1 run --separate-stderr start_coder_agents_wait "${REPO_ROOT}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"SKIP_CODER_AGENTS is set"* ]]
}

@test "pg-apply-password: start_coder_agents_wait backgrounds the seeder when it exists" {
  local root="${BATS_TEST_TMPDIR}/seed-root" args="${BATS_TEST_TMPDIR}/seeder.args"
  mkdir -p "${root}/scripts"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\n' "${args}" >"${root}/scripts/coder-agents.sh"
  chmod 755 "${root}/scripts/coder-agents.sh"
  CODER_AGENTS_WAIT_SECS=12 run --separate-stderr start_coder_agents_wait "${root}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"waits up to 12s for the first owner"* ]]
  i=0
  while [ ! -f "${args}" ] && [ "${i}" -lt 20 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "${args}" ]
  [[ $(cat "${args}") == *"--apply --wait=12"* ]]
}

@test "pg-apply-password: the seeder keeps its output in a log the operator can read" {
  local root="${BATS_TEST_TMPDIR}/seed-log-root" logf="${BATS_TEST_TMPDIR}/seeder.log"
  local i=0
  mkdir -p "${root}/scripts"
  # `skip` exits 0 and prints one line, so a discarded stdout is what let a
  # stack come up with a dead Agents chat and look healthy.
  printf '#!/bin/sh\nprintf "skipped: the coder service is not running yet\\n"\n' \
    >"${root}/scripts/coder-agents.sh"
  chmod 755 "${root}/scripts/coder-agents.sh"
  CODER_AGENTS_SEED_LOG="${logf}" run --separate-stderr start_coder_agents_wait "${root}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"log: ${logf}"* ]]
  while [ "${i}" -lt 40 ] && ! grep -q 'skipped: the coder service' "${logf}" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  grep -q 'skipped: the coder service' "${logf}"
  grep -q '== coder-agents seeder ==' "${logf}"
  grep -q 'started: ' "${logf}"
}

@test "pg-apply-password: an unwritable seeder log warns and still starts the seeder" {
  local root="${BATS_TEST_TMPDIR}/seed-nowrite-root" args="${BATS_TEST_TMPDIR}/seeder-nowrite.args"
  mkdir -p "${root}/scripts"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\n' "${args}" >"${root}/scripts/coder-agents.sh"
  chmod 755 "${root}/scripts/coder-agents.sh"
  CODER_AGENTS_SEED_LOG='/proc/no-such-dir/coder-agents-seeder.log' \
    run --separate-stderr start_coder_agents_wait "${root}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"warning: the Coder Agents seeder log"* ]]
  local i=0
  while [ ! -f "${args}" ] && [ "${i}" -lt 40 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "${args}" ]
  [[ $(cat "${args}") == *"--apply"* ]]
}

@test "pg-apply-password: pg_apply_password_entrypoint applies POSTGRES_PASSWORD once postgres is ready" {
  cat >"${BATS_TEST_TMPDIR}/bin/docker-entrypoint.sh" <<'EOF'
#!/bin/sh
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "docker-entrypoint $*" >> "${STUB_LOG}/docker-entrypoint.sh.log"; fi
exit 0
EOF
  cat >"${BATS_TEST_TMPDIR}/bin/pg_isready" <<'EOF'
#!/bin/sh
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "pg_isready $*" >> "${STUB_LOG}/pg_isready.log"; fi
exit 0
EOF
  chmod 755 "${BATS_TEST_TMPDIR}/bin/docker-entrypoint.sh" "${BATS_TEST_TMPDIR}/bin/pg_isready"
  export POSTGRES_USER=coder
  export POSTGRES_PASSWORD=rotated-secret
  export POSTGRES_DB=coder

  run --separate-stderr bash "${LIB}" postgres
  [ "${status}" -eq 0 ]
  assert_match "applied" 'aligned role coder with POSTGRES_PASSWORD' "${output}"
  assert_match "psql user" 'psql -U coder -d coder -v ON_ERROR_STOP=1 -q$' "$(stub_log_last psql)"
  assert_match "image cmd" 'docker-entrypoint postgres' "$(cat "${STUB_LOG}/docker-entrypoint.sh.log")"
}

@test "pg-apply-password: pg_apply_password_entrypoint defaults empty argv to postgres" {
  cat >"${BATS_TEST_TMPDIR}/bin/docker-entrypoint.sh" <<'EOF'
#!/bin/sh
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "docker-entrypoint $*" >> "${STUB_LOG}/docker-entrypoint.sh.log"; fi
exit 0
EOF
  cat >"${BATS_TEST_TMPDIR}/bin/pg_isready" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "${BATS_TEST_TMPDIR}/bin/docker-entrypoint.sh" "${BATS_TEST_TMPDIR}/bin/pg_isready"
  export POSTGRES_USER=coder
  export POSTGRES_PASSWORD=rotated-secret
  export POSTGRES_DB=coder

  run --separate-stderr bash "${LIB}"
  [ "${status}" -eq 0 ]
  assert_match "defaulted cmd" 'docker-entrypoint postgres' "$(cat "${STUB_LOG}/docker-entrypoint.sh.log")"
}
