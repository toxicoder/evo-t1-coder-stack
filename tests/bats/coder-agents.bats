#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## coder-agents.bats — hermetic coverage for scripts/coder-agents.sh
#
# Hermetic by construction: docker, timeout, curl, psql and coder all resolve to
# the tests/bats/tool_stubs/ copies (use_stubs), and the script runs from a
# throwaway root built by fake_root with its own .env, so neither the checkout's
# real .env nor a live compose stack is consulted. The docker stub's `compose
# exec` passthrough (STUB_DOCKER_EXEC_RUN=1, the default) is what makes the
# in-container half of the chain testable: the exec'd binary resolves through the
# same shadowed PATH, so `… compose exec -T coder curl …` lands on the curl stub.
#
# Seeding psql: tool_stubs/psql prints a fixed body, and the script only walks
# off the token mint when that body equals the api_keys id it just minted (which
# is random per run), so the chain cases swap in fixtures/coder-agents/psql-token
# — a psql that echoes the id back out of the statement, the way `returning id`
# answers on a real server.
#
# Usage: bats tests/bats/coder-agents.bats   (from any cwd)
#
# Safety: stub only. Nothing here needs a daemon, a database or a network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout curl psql coder
}

# fake_root [env-line...] — print a throwaway repo root holding the script under
# test, scripts/lib/ (the seam it sources after its own repo-root cd) and a
# private .env. Without that cd target the script would read the checkout's .env.
fake_root() {
  local root="${BATS_TEST_TMPDIR?}/root"
  mkdir -p "${root}/scripts/lib"
  : >"${root}/docker-compose.yml"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"${root}/.env"
  else
    : >"${root}/.env"
  fi
  cp "${REPO_ROOT}/scripts/coder-agents.sh" "${root}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  printf '%s' "${root}"
}

# psql_token_variant — swap the copied psql stub for the fixture that answers the
# api_keys INSERT with its `returning id` value, so the run reaches the API phase.
psql_token_variant() {
  cp "${BATS_TEST_DIRNAME?}/fixtures/coder-agents/psql-token" "${BATS_TEST_TMPDIR?}/bin/psql"
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/psql"
}

# running_stack — answer `docker compose ps` with both services, and let the
# buildinfo probe answer too (an empty body with rc 0 is an "answered" probe).
running_stack() {
  export STUB_COMPOSE_PS=$'db\ncoder'
  export STUB_COMPOSE_PS_RC=0
  export STUB_CURL_RC=0
}

# logs_absent <regex> [log-file...] - fail unless no argv log line matches.
# A bare `! grep` cannot fail a bats test, so the negation lives in the helper.
logs_absent() {
  local pattern="$1"
  shift
  local f scanned=0
  for f in "$@"; do
    [ -e "${f}" ] || continue
    scanned=1
    if grep -qE -- "${pattern}" "${f}"; then
      printf 'leak: %s matches /%s/\n' "${f}" "${pattern}" >&2
      return 1
    fi
  done
  [ "${scanned}" -eq 1 ]
}

@test "coder-agents: skips when no service is running (empty compose ps)" {
  root="$(fake_root)"
  export STUB_COMPOSE_PS=''
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: docker compose up -d)" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "coder-agents: skips when only db runs (the coder service is checked first)" {
  root="$(fake_root)"
  export STUB_COMPOSE_PS='db'
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: docker compose up -d)" ]
  [ "$(stub_log_count docker)" -eq 1 ]
}

@test "coder-agents: skips on a failed compose ps (docker access, exit 22)" {
  root="$(fake_root)"
  export STUB_COMPOSE_PS='coder'
  export STUB_COMPOSE_PS_RC=22
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "skipped: could not query the stack (coder) — this script needs docker access; run it with sudo, or add your user to the docker group" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "coder-agents: --dry-run prints the intended end state and writes nothing" {
  root="$(fake_root)"
  running_stack
  run --separate-stderr bash "${root}/scripts/coder-agents.sh" --dry-run
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[0]}" = "dry run (no changes; rerun without --dry-run to apply):" ]
  [[ ${output} == *"pin model overrides general+explore -> agent"* ]]
  # The probes may read; nothing may be written: no token minted, no API call.
  [ "$(stub_log_count psql)" -eq 0 ]
  [ "$(stub_log_count coder)" -eq 0 ]
}

@test "coder-agents: an unknown flag is a usage error, not a skip" {
  root="$(fake_root)"
  running_stack
  run --separate-stderr bash "${root}/scripts/coder-agents.sh" --nonsense
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [ "${stderr}" = "error: usage: ${root}/scripts/coder-agents.sh [--dry-run|--apply] (default: --apply)" ]
}

@test "coder-agents: an unanswered buildinfo probe is a hard failure (curl 22, empty body)" {
  root="$(fake_root)"
  running_stack
  export STUB_CURL_RC=22
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container ()"* ]]
  [[ ${stderr} == *"check: docker compose logs --tail 100 coder"* ]]
  # The probe is capped, and it reaches curl through the docker-exec passthrough.
  [ "$(stub_log_last timeout)" = "timeout 20 docker compose exec -T coder curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last docker)" = "docker compose exec -T coder curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last curl)" = "curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
}

@test "coder-agents: a psql that refuses the statement is fatal, and quoted back" {
  root="$(fake_root)"
  running_stack
  export STUB_PSQL_RC=1
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == "error: could not clean up in db: psql: error: stub failure"* ]]
  [[ ${stderr} != *"could not mint an API token"* ]]
  [ "$(stub_log_count psql)" -eq 1 ]
}

@test "coder-agents: a psql that answers nothing skips (nobody has registered yet)" {
  root="$(fake_root)"
  running_stack
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"skipped: no active Coder account with the site owner role"* ]]
  [[ ${output} == *"https://<host>:3001"* ]]
}

@test "coder-agents: an answered psql still needs the id back (40-hex echo != id)" {
  root="$(fake_root)"
  running_stack
  export STUB_PSQL_OUT='019f373a604c62bd16ebc7776660fb1e83214a34'
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"could not mint an API token in coder.api_keys (exit 0)"* ]]
  # The statement travels as one -c argument, token_name and scopes included.
  [[ "$(stub_log psql)" == *"'{coder:all}'::api_key_scope[]"* ]]
  [[ "$(stub_log psql)" == *"and (rbac_roles && '{owner,template-admin}'::text[])"* ]]
  [ "$(stub_log_last psql)" = "psql -U coder -d coder -v ON_ERROR_STOP=1 -q -c delete from api_keys where token_name = 'stack-coder-agents';" ]
}

@test "coder-agents: the minted token never reaches argv, on either side of the seam" {
  root="$(fake_root)"
  running_stack
  psql_token_variant
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  # The mint succeeded (the fixture answered) and the API phase ran through the
  # docker-exec chain, so this is the run that could have leaked the token.
  [[ ${output} == *"creating AI provider litellm (base_url http://litellm:4000/v1)"* ]]
  # Host-side argv is what the seam is responsible for: the compose exec line
  # names CODER_SESSION_TOKEN without its value. (Under the exec passthrough the
  # in-container `sh -c` runs on the host, so curl.log does see the expanded
  # header — that mirrors the container-side argv, not the host's.)
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=' "${STUB_LOG}/docker.log"
  logs_absent '[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}/docker.log"
  # Three psql statements: drop the stale token, mint a fresh one, drop it again.
  [ "$(grep -c '^psql ' "${STUB_LOG}/psql.log")" -eq 3 ]
  [ "$(stub_log_last psql)" = "psql -U coder -d coder -v ON_ERROR_STOP=1 -q -c delete from api_keys where token_name = 'stack-coder-agents';" ]
}

@test "coder-agents: an already-configured provider is left untouched (API answers)" {
  root="$(fake_root)"
  running_stack
  psql_token_variant
  printf '%s' '{"name":"litellm","name":"litellm","base_url":"http://litellm:4000/v1","masked":"ch...lm","id":"11111111-2222-4333-8444-555555555555"}' \
    >"${BATS_TEST_TMPDIR}/providers.json"
  export STUB_CURL_OUT="${BATS_TEST_TMPDIR}/providers.json"
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"provider litellm: already configured (left untouched)"* ]]
  [[ ${output} == *"creating model config agent (context_limit 262144, default)"* ]]
  [[ ${stderr} == *"no chat model config could be registered or found"* ]]
  # api_read reaches curl INSIDE the coder container, capped, and the exec line
  # carries only the NAME of the token variable (never its value). The run stops
  # at the model-config sweep, so it never reaches the per-lane model override.
  grep -Fq -- '/api/experimental/chats/model-configs' "${STUB_LOG}/curl.log"
  logs_absent '/api/experimental/chats/config/model-override/general' "${STUB_LOG}/curl.log"
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}/docker.log"
}

@test "coder-agents: a real master key never reaches argv or the output" {
  root="$(fake_root 'LITELLM_MASTER_KEY=sk-test-secret-0123456789abcdef')"
  running_stack
  psql_token_variant
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"creating AI provider litellm (base_url http://litellm:4000/v1)"* ]]
  [[ ${stderr} != *"sk-test-secret-0123456789abcdef"* ]]
  # The provider body (with the key inside it) travels on stdin, not on argv.
  logs_absent 'sk-test-secret-0123456789abcdef' "${STUB_LOG}"/*.log
  logs_absent 'CODER_SESSION_TOKEN=' "${STUB_LOG}"/*.log
}

@test "coder-agents: the empty .env key falls back to the compose placeholder" {
  root="$(fake_root)"
  running_stack
  psql_token_variant
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"note: LITELLM_MASTER_KEY is empty in .env — using the compose interpolation default"* ]]
  [[ ${output} == *"creating AI provider litellm (base_url http://litellm:4000/v1)"* ]]
  logs_absent 'change-me-litellm' "${STUB_LOG}"/*.log
}

@test "coder-agents: CODER_AGENTS_USER narrows the mint, and a bad name is fatal" {
  root="$(fake_root)"
  running_stack
  run --separate-stderr env CODER_AGENTS_USER='a b' bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == "error: CODER_AGENTS_USER='a b' is not a valid Coder username"* ]]

  root="$(fake_root)"
  running_stack
  psql_token_variant
  run --separate-stderr env CODER_AGENTS_USER='someone' bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  [[ "$(stub_log psql)" == *"and username = 'someone'"* ]]
}

# ── coder_api.sh (moved from lib.bats; keep these assertions) ──────────────

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
}

@test "coder_api: psql_sql builds a capped -T exec and merges psql's stderr" {
  source_libs
  run --separate-stderr psql_sql "SELECT 1;"
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last timeout)" == "timeout 20 docker compose exec -T db psql "* ]]
  [[ "$(stub_log_last psql)" == *"ON_ERROR_STOP=1 -q -c SELECT 1;"* ]]

  export STUB_PSQL_RC=1
  run --separate-stderr psql_sql "SELECT 1;"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"psql: error: stub failure"* ]]
}

@test "coder_api: psql_query prints only the trimmed single-column value" {
  source_libs
  export STUB_PSQL_OUT=" 1 "
  v="$(psql_query "select id from users limit 1;")"
  [ "${v}" = "1" ]
  [[ "$(stub_log_last psql)" == *" -q -tAc select id from users limit 1;"* ]]
}

@test "coder_api: coder_exec keeps the session token out of argv" {
  source_libs
  export CONTAINER_API_URL="http://coder:3002/api/private"
  export session_token="kid-secret"
  run --separate-stderr coder_exec whoami
  [ "${status}" -eq 0 ]
  [ "$(stub_log_last docker)" = "docker compose exec -T -e CODER_URL -e CODER_SESSION_TOKEN coder coder whoami" ]
  [[ "$(stub_log_last docker)" != *kid-secret* ]]
}

@test "coder_api: DOCKER_BIN override (two words) still execs through timeout" {
  source_libs
  printf '#!/usr/bin/env bash\nshift\nexec docker "$@"\n' > "${BATS_TEST_TMPDIR}/bin/fakebin"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/fakebin"
  DOCKER_BIN="fakebin docker"
  run --separate-stderr psql_sql "SELECT 1;"
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last docker)" == "docker compose exec -T db psql "* ]]
}

