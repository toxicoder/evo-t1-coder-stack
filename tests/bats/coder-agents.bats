#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## coder-agents.bats — hermetic coverage for scripts/coder-agents.sh
#
# Hermetic by construction: docker, timeout, curl, psql and coder all resolve to
# the tests/bats/tool_stubs/ copies (use_stubs), and the script runs from a
# throwaway root built by fake_root with its own .env, so neither the checkout's
# real .env nor a live compose stack is consulted. The docker stub's `exec`
# passthrough (STUB_DOCKER_EXEC_RUN=1, the default) is what makes the
# in-container half of the chain testable: the exec'd binary resolves through the
# same shadowed PATH, so `… exec -i <container> curl …` lands on the curl stub.
#
# Seeding psql: tool_stubs/psql prints a fixed body, and the script only walks
# off the token mint when that body equals the api_keys id it just minted (which
# is random per run), so the chain cases swap in fixtures/coder-agents/psql-token
# — a psql that echoes the id back out of the statement, the way `returning id`
# answers on a real server.
#
# Usage: bazelisk test //tests:bats_coder_agents_test   (from any cwd)
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

# running_stack — answer the daemon-wide `docker ps` probe with both services
# (the "service|container" shape stack_ps prints), and let the buildinfo probe
# answer too (an empty body with rc 0 is an "answered" probe).
running_stack() {
  export STUB_COMPOSE_PS=$'db|stack-db-1\ncoder|stack-coder-1'
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

@test "coder-agents: skips when no service is running (empty daemon ps body)" {
  root="$(fake_root)"
  export STUB_COMPOSE_PS=''
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: bazelisk run //scripts:prod-stack -- up)" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "coder-agents: skips when only db runs (the coder service is checked first)" {
  root="$(fake_root)"
  export STUB_COMPOSE_PS='db|stack-db-1'
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: bazelisk run //scripts:prod-stack -- up)" ]
  [ "$(stub_log_count docker)" -eq 1 ]
}

@test "coder-agents: skips on a failed daemon ps probe (docker access, exit 22)" {
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
  [ "${#lines[@]}" -eq 11 ]
  [[ ${lines[0]} == *"probing the Coder API"* ]]
  [ "${lines[1]}" = "dry run (no changes; apply with: bazelisk run //scripts:coder-agents -- --apply):" ]
  [[ ${output} == *"ensure chat model config agent-low"* ]]
  [[ ${output} == *"ensure chat model config agent-medium"* ]]
  [[ ${output} == *"ensure chat model config agent-xhigh"* ]]
  [[ ${output} == *"pin model overrides general+explore -> agent"* ]]
  [[ ${output} == *"treat only the aliases with a healthy deployment as registerable"* ]]
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
  [ "${stderr}" = "error: usage: bazelisk run //scripts:coder-agents -- [--dry-run|--apply] [--wait[=SECONDS]] (default: --apply)" ]
}

@test "coder-agents: an unanswered buildinfo probe is a hard failure (curl 22, empty body)" {
  root="$(fake_root)"
  running_stack
  export STUB_CURL_RC=22
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container ()"* ]]
  [[ ${stderr} == *"check: bazelisk run //scripts:prod-stack -- logs --tail 100 coder"* ]]
  # The probe is capped, and it reaches curl through the docker-exec passthrough.
  [ "$(stub_log_last timeout)" = "timeout -k 2 20 docker exec -i stack-coder-1 curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last docker)" = "docker exec -i stack-coder-1 curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
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

@test "coder-agents: --wait=1 still skips when nobody has registered" {
  root="$(fake_root)"
  running_stack
  run --separate-stderr bash "${root}/scripts/coder-agents.sh" --apply --wait=1
  [ "${status}" -eq 0 ]
  [[ ${output} == *"waiting up to 1s for the first Coder owner"* ]]
  [[ ${output} == *"skipped: no active Coder account with the site owner role"* ]]
  # The window is a poll, not a note: the db is asked again after the sleep. The
  # budget starts when the db first answers "no owner", so a slow buildinfo probe
  # or a slow first query cannot spend it before the first look.
  [ "$(grep -c 'returning id' "${STUB_LOG}/psql.log")" -ge 2 ]
}

@test "coder-agents: a query slower than the budget cannot spend the --wait window" {
  root="$(fake_root)"
  running_stack
  # The shape that made the run above flake: a db that answers later than the
  # whole budget used to leave the seeder skipping with no note and no poll.
  export STUB_PSQL_DELAY=2
  run --separate-stderr bash "${root}/scripts/coder-agents.sh" --apply --wait=1
  [ "${status}" -eq 0 ]
  [[ ${output} == *"waiting up to 1s for the first Coder owner"* ]]
  [[ ${output} == *"skipped: no active Coder account with the site owner role"* ]]
}

@test "coder-agents: --wait with a non-numeric budget is a usage error" {
  root="$(fake_root)"
  running_stack
  run --separate-stderr bash "${root}/scripts/coder-agents.sh" --wait=abc
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [ "${stderr}" = "error: usage: bazelisk run //scripts:coder-agents -- [--dry-run|--apply] [--wait[=SECONDS]] (default: --apply)" ]
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
  # Host-side argv is what the seam is responsible for: the docker-exec line
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

# write_map FILE needle body [needle body...] — build a STUB_CURL_OUT_MAP so one
# run can be answered endpoint by endpoint. Order matters: the first needle that
# appears in the argv wins, so a longer path must be listed before its prefix.
write_map() {
  local map="$1"
  shift
  : >"${map}"
  while [ "$#" -gt 1 ]; do
    printf '%s\t%s\n' "$1" "$2" >>"${map}"
    shift 2
  done
}

@test "coder-agents: an unhealthy alias is not registered and never takes a pin" {
  root="$(fake_root)"
  running_stack
  psql_token_variant
  local agent_uuid="11111111-1111-4111-8111-111111111111"
  printf '%s' '{"name":"litellm","name":"litellm","base_url":"http://litellm:4000/v1","masked":"ch...lm","id":"11111111-2222-4333-8444-555555555555"}' \
    >"${BATS_TEST_TMPDIR}/providers.json"
  printf '%s' '{"configs":[{"id":"'"${agent_uuid}"'","model":"agent","enabled":true,"is_default":true,"context_limit":262144}]}' \
    >"${BATS_TEST_TMPDIR}/configs.json"
  write_map "${BATS_TEST_TMPDIR}/map" \
    '/api/v2/ai/providers' "${BATS_TEST_TMPDIR}/providers.json" \
    '/api/experimental/chats/model-configs' "${BATS_TEST_TMPDIR}/configs.json" \
    'model-override/' '{"model_config_id":""}' \
    'system-prompt' '{"system_prompt":"grok-build-delegation skill, then review its diff"}'
  export STUB_CURL_OUT_MAP="${BATS_TEST_TMPDIR}/map"
  # The Spark lane answers and the Arc chat alias does not — the state this box
  # is actually in when qwen2.5:7b has never been pulled.
  export CODER_AGENTS_LIVE_ALIASES='agent agent-low agent-medium agent-xhigh'
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"healthy aliases: agent agent-low agent-medium agent-xhigh"* ]]
  [[ ${output} == *"model config agent: already present (left untouched)"* ]]
  [[ ${output} == *"model config chat: skipped"* ]]
  [[ ${output} == *"compaction and title_generation go to agent"* ]]
  [[ ${output} == *"lane compaction: pinned to model config agent"* ]]
  [[ ${output} == *"lane title_generation: pinned to model config agent"* ]]
  [[ ${output} == *"system prompt: already carries the stack addendum"* ]]
  # The dead alias may never be POSTed, and the run may not report a clean pass.
  logs_absent '"model":"chat"' "${STUB_LOG}/curl.log"
  [[ ${output} == *"summary: "* ]]
  [[ ${output} != *"0 warnings"* ]]
}

@test "coder-agents: a dead pin on a helper lane is moved on the next run" {
  root="$(fake_root)"
  running_stack
  psql_token_variant
  local agent_uuid="11111111-1111-4111-8111-111111111111"
  local chat_uuid="22222222-2222-4222-8222-222222222222"
  printf '%s' '{"name":"litellm","name":"litellm","base_url":"http://litellm:4000/v1","masked":"ch...lm","id":"11111111-2222-4333-8444-555555555555"}' \
    >"${BATS_TEST_TMPDIR}/providers.json"
  printf '%s' '{"configs":[{"id":"'"${agent_uuid}"'","model":"agent","enabled":true,"is_default":true,"context_limit":262144},{"id":"'"${chat_uuid}"'","model":"chat","enabled":true,"is_default":false,"context_limit":32768}]}' \
    >"${BATS_TEST_TMPDIR}/configs.json"
  write_map "${BATS_TEST_TMPDIR}/map" \
    '/api/v2/ai/providers' "${BATS_TEST_TMPDIR}/providers.json" \
    '/api/experimental/chats/model-configs' "${BATS_TEST_TMPDIR}/configs.json" \
    'model-override/compaction' "{\"model_config_id\":\"${chat_uuid}\"}" \
    'model-override/' '{"model_config_id":""}' \
    'system-prompt' '{"system_prompt":"grok-build-delegation skill, then review its diff"}'
  export STUB_CURL_OUT_MAP="${BATS_TEST_TMPDIR}/map"
  export CODER_AGENTS_LIVE_ALIASES='agent agent-low agent-medium agent-xhigh'
  run --separate-stderr bash "${root}/scripts/coder-agents.sh"
  [ "${status}" -eq 0 ]
  # compaction was left pinned to the Arc chat config by an earlier run; that
  # config is now unhealthy, and the old check called it "the admin's choice".
  [[ ${output} == *"lane compaction: was pinned to a model config whose alias LiteLLM reports unhealthy"* ]]
  [[ ${output} == *"lane compaction: pinned to model config agent"* ]]
  [[ ${output} == *"lane general: unset, pinning"* ]]
}

@test "coder-agents: a real master key never reaches argv or the output" {  root="$(fake_root 'LITELLM_MASTER_KEY=sk-test-secret-0123456789abcdef')"
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
  [[ ${output} == *"listing AI providers at http://127.0.0.1:3000 (up to 20s)"* ]]
  [[ ${output} == *"creating AI provider litellm (base_url http://litellm:4000/v1)"* ]]
  logs_absent 'change-me-litellm' "${STUB_LOG}"/*.log
  # api_read is capped with --kill-after; without -k, docker exec -i under
  # bazelisk run waits forever on the open stdin pipe.
  [[ "$(stub_log timeout)" == *"timeout -k 2 20 docker exec -i"* ]]
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

source_coder_api() {
  # coder_api.sh alone, for the tests below that call `skip` as a guard:
  # common.sh defines its own `skip` (print + exit 0), which would shadow the
  # bats builtin and turn a guarded skip into a hard failure.
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
}

@test "coder_api: psql_sql builds a capped -i exec and merges psql's stderr" {
  source_libs
  export DB_CONTAINER=stack-db-1
  run --separate-stderr psql_sql "SELECT 1;"
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last timeout)" == "timeout -k 2 20 docker exec -i stack-db-1 psql "* ]]
  [[ "$(stub_log_last psql)" == *"ON_ERROR_STOP=1 -q -c SELECT 1;"* ]]

  export STUB_PSQL_RC=1
  run --separate-stderr psql_sql "SELECT 1;"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"psql: error: stub failure"* ]]
}

@test "coder_api: psql_query prints only the trimmed single-column value" {
  source_libs
  export DB_CONTAINER=stack-db-1
  export STUB_PSQL_OUT=" 1 "
  v="$(psql_query "select id from users limit 1;")"
  [ "${v}" = "1" ]
  [[ "$(stub_log_last psql)" == *" -q -tAc select id from users limit 1;"* ]]
}

@test "coder_api: coder_exec keeps the session token out of argv" {
  source_libs
  export CONTAINER_API_URL="http://coder:3002/api/private"
  export session_token="kid-secret"
  export CODER_CONTAINER=stack-coder-1
  run --separate-stderr coder_exec whoami
  [ "${status}" -eq 0 ]
  [ "$(stub_log_last docker)" = "docker exec -i -e CODER_URL -e CODER_SESSION_TOKEN stack-coder-1 coder whoami" ]
  [[ "$(stub_log_last docker)" != *kid-secret* ]]
}

@test "coder_api: stack_timeout prefixes GNU --kill-after so docker exec cannot pin bazelisk run" {
  source_coder_api
  run --separate-stderr stack_timeout 20 docker ps --format '{{.Names}}'
  [ "${status}" -eq 0 ]
  [ "$(stub_log_last timeout)" = "timeout -k 2 20 docker ps --format {{.Names}}" ]
}

@test "coder_api: DOCKER_BIN override (two words) still execs through timeout" {
  source_libs
  printf '#!/usr/bin/env bash\nshift\nexec docker "$@"\n' > "${BATS_TEST_TMPDIR}/bin/fakebin"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/fakebin"
  DOCKER_BIN="fakebin docker"
  export DB_CONTAINER=stack-db-1
  run --separate-stderr psql_sql "SELECT 1;"
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last docker)" == "docker exec -i stack-db-1 psql "* ]]
}

@test "coder_api: stack_ps asks the whole daemon and names no compose project" {
  source_coder_api
  run --separate-stderr stack_ps
  [ "${status}" -eq 0 ]
  # The probe must never resolve a compose project: no call may carry the
  # word "compose" as a subcommand (a project-resolved probe is exactly the
  # bug this seam exists to kill). The label KEY com.docker.compose.service
  # is allowed to appear — it is data, not addressing.
  [[ "$(stub_log_last docker)" == "docker ps --format "* ]]
  [[ "$(stub_log_last docker)" != *"docker compose "* ]]
  [[ "$(stub_log_last timeout)" == "timeout -k 2 20 docker ps --format "* ]]
}

@test "coder_api: stack_container picks the oldest container and matches whole fields" {
  source_coder_api
  # `docker ps` lists newest first, so a LATER line is the OLDER container:
  # with the dev stack up beside the stable one, the last match is the stable
  # service's copy, and that is the one every caller here means to address.
  local body='litellm|evo-t1-dev-litellm-1
coder|evo-t1-dev-coder-1
coder|evo-t1-coder-stack-coder-1'
  [ "$(stack_container "${body}" coder)" = "evo-t1-coder-stack-coder-1" ]
  # Whole-field matching on the LABEL column, never on names: a container
  # whose label merely contains the wanted service must not answer for it.
  local body2='xdb|other-db-1
coder|stack-coder-1'
  [ -z "$(stack_container "${body2}" db)" ]
  [ -z "$(stack_container "${body2}" xdbx)" ]
  [ -z "$(stack_container "" coder)" ]
}

@test "coder_api: stack_compose_target splits the project and file that built a container" {
  source_coder_api
  # A fake DOCKER_BIN replays whatever the two labels hold, so this pins the
  # contract dashboard-password.sh splits on: a real compose container answers
  # "project|file"; a docker-run container (or Coder-built workspace box,
  # hand-labelled) answers "|" with BOTH sides empty — and callers must treat
  # that as "cannot tell", never guess a project.
  printf '%s\n' '#!/usr/bin/env bash' 'printf '"'"'%s\n'"'"' "${FAKE_LABELS-}"' >"${BATS_TEST_TMPDIR}/bin/fakedocker"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/fakedocker"
  DOCKER_BIN=fakedocker
  export FAKE_LABELS='evo-t1-coder-stack|/home/alx/stack/docker-compose.yml'
  target="$(stack_compose_target stack-coder-1)"
  [ "${target%%|*}" = "evo-t1-coder-stack" ]
  [ "${target#*|}" = "/home/alx/stack/docker-compose.yml" ]
  export FAKE_LABELS='|'
  target="$(stack_compose_target dev-coder)"
  [ -z "${target%%|*}" ]
  [ -z "${target#*|}" ]
}

@test "coder_api: discovery crosses compose-project boundaries (live daemon)" {
  source_coder_api
  if [ -z "$(real_bin docker)" ] || [ -z "$(real_bin timeout)" ]; then
    skip "docker and timeout(1) must both be on PATH for this integration-tier test"
  fi
  # Integration tier: drop the stub bin from PATH so the seam talks to the
  # real daemon. The cwd plays no role any more — that is the point.
  local stripped
  stripped="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -vxF "${BATS_TEST_TMPDIR?}/bin" | paste -sd: -)"
  PATH="${stripped}"
  if ! docker info >/dev/null 2>&1; then
    skip "no reachable docker daemon"
  fi
  if ! docker image inspect alpine:3.20 >/dev/null 2>&1; then
    skip "alpine:3.20 is not in the local image store"
  fi
  # One throwaway container, labelled as if compose-managed but belonging to
  # NO compose project resolvable from this cwd: a project-scoped probe would
  # answer "nothing running" here, while the daemon-wide probe must not.
  local probe="bats-cross-proj-$$"
  docker rm -f "${probe}" >/dev/null 2>&1 || true
  if ! docker run -d --rm --name "${probe}" -l com.docker.compose.service=coder alpine:3.20 sleep 30 >/dev/null 2>&1; then
    skip "could not start a throwaway container on this daemon"
  fi
  local body=""
  if ! body="$(stack_ps)"; then
    docker rm -f "${probe}" >/dev/null 2>&1 || true
    skip "docker ps refused to answer"
  fi
  [[ "${body}" == *"coder|${probe}"* ]]
  [ "$(stack_container "${body}" coder)" = "${probe}" ]
  docker rm -f "${probe}" >/dev/null 2>&1
}

