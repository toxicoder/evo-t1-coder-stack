#!/usr/bin/env bats
#
# ## entry-fns.bats — unit coverage for helpers that still live in entry scripts.
#
# Each test evals the production function (tests/extract_fn.py) and asserts on
# its result. docker, curl, ssh, psql and timeout are stubs.
#
# Usage: bats tests/bats/entry-fns.bats
# Safety: stub only. No daemon and no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout curl psql ssh
  export STUB_CURL_RC=0
  export STUB_CURL_OUT='ok'
}

load_fn() {
  load_shell_function "${REPO_ROOT}/$1" "$2"
}

@test "coder-agents: mask_secret follows the length bands" {
  load_fn scripts/coder-agents.sh mask_secret
  [ "$(mask_secret "abcdefghijklmnopqrst")" = "abcd...qrst" ]
  [ "$(mask_secret "1234567890")" = "12...90" ]
  [ "$(mask_secret "12345")" = "1...5" ]
  [ "$(mask_secret "1234")" = "..." ]
}

@test "coder-agents: api_read keeps the session token out of argv" {
  load_fn scripts/coder-agents.sh api_read
  session_token="secret-token-not-in-argv"
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  export STUB_CURL_OUT='{"providers":[]}'
  run api_read "/api/v2/ai/providers"
  [ "${status}" -eq 0 ]
  [ "${output}" = '{"providers":[]}' ]
  if grep -q 'secret-token-not-in-argv' "${STUB_LOG}/docker.log"; then
    fail "session token leaked into the host docker argv"
  fi
  assert_match "env pass-through" '-e CODER_SESSION_TOKEN' "$(stub_log_last docker)"
}

@test "coder-agents: api_write posts the JSON body" {
  load_fn scripts/coder-agents.sh api_write
  session_token="secret-token-not-in-argv"
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  export STUB_CURL_OUT='{"ok":true}'
  run api_write POST "/api/v2/ai/providers" '{"name":"litellm"}'
  [ "${status}" -eq 0 ]
  [ "${output}" = '{"ok":true}' ]
  assert_match "post path" '/api/v2/ai/providers' "$(stub_log_last curl)"
}

@test "coder-agents: model_config_id reads the uuid next to the model alias" {
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh model_config_id
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  export STUB_CURL_OUT='{"id":"d162f0a4-1111-4444-8888-121212121212","model":"agent"}'
  [ "$(model_config_id agent)" = "d162f0a4-1111-4444-8888-121212121212" ]
  export STUB_CURL_RC=22
  export STUB_CURL_OUT=""
  [ "$(model_config_id agent)" = "" ]
}

@test "coder-agents: create_model_config and pin_lane call the API" {
  load_fn scripts/coder-agents.sh log
  load_fn scripts/coder-agents.sh die
  load_fn scripts/coder-agents.sh json_escape
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh api_write
  load_fn scripts/coder-agents.sh create_model_config
  load_fn scripts/coder-agents.sh pin_lane
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  provider_id="prov-1"
  export STUB_CURL_OUT='{"model_config_id":""}'
  run create_model_config agent 'Coder "Agents"' 262144 true
  [ "${status}" -eq 0 ]
  run pin_lane general agent "d162f0a4-1111-4444-8888-121212121212"
  [ "${status}" -eq 0 ]
  assert_match "pinned" 'lane general: pinned' "${output}"
  run pin_lane general agent ""
  [ "${status}" -eq 0 ]
  assert_match "no target" 'skipped' "${output}"
}

@test "coder-agents: cleanup_token deletes the minted api_keys row" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
  load_fn scripts/coder-agents.sh cleanup_token
  TOKEN_NAME="stack-coder-agents"
  cleanup_token
  assert_match "delete" 'stack-coder-agents' "$(stub_log_last psql)"
}

@test "push-template: known_templates lists names in TEMPLATES_DEFAULT order" {
  load_fn scripts/push-template.sh known_templates
  TEMPLATES_DEFAULT=("docker-dev:templates/docker-dev" "docker-devcontainer:templates/docker-devcontainer")
  [ "$(known_templates)" = "docker-dev, docker-devcontainer" ]
}

@test "push-template: preset_desc_guard rejects a description over 128 bytes" {
  load_fn scripts/push-template.sh log
  load_fn scripts/push-template.sh die
  load_fn scripts/push-template.sh preset_desc_guard
  dir="${BATS_TEST_TMPDIR}/tpl"
  mkdir -p "${dir}"
  long="$(printf 'x%.0s' {1..129})"
  printf 'resource "coder_workspace_preset" "big" {\n  name = "big"\n  description = "%s"\n}\n' "${long}" >"${dir}/main.tf"
  run preset_desc_guard "${dir}"
  [ "${status}" -eq 1 ]
  assert_match "limit" '128' "${output}"
  printf 'resource "coder_workspace_preset" "ok" {\n  name = "ok"\n  description = "short"\n}\n' >"${dir}/main.tf"
  run preset_desc_guard "${dir}"
  [ "${status}" -eq 0 ]
}

@test "push-template: cleanup_token deletes the push token" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
  load_fn scripts/push-template.sh cleanup_token
  TOKEN_NAME="stack-template-push"
  cleanup_token
  assert_match "delete" 'stack-template-push' "$(stub_log_last psql)"
}

@test "dashboard-password: read, hash, write, and cleanup round-trip a hostile value" {
  load_fn scripts/dashboard-password.sh read_env_value
  load_fn scripts/dashboard-password.sh hash_of
  load_fn scripts/dashboard-password.sh write_env_line
  load_fn scripts/dashboard-password.sh cleanup
  [ "$(hash_of abc)" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]
  ENV_FILE="${BATS_TEST_TMPDIR}/.env"
  KEY="HOMEPAGE_AUTH_PASSWORD"
  printf '%s\n' 'OTHER=keep' "${KEY}=old" >"${ENV_FILE}"
  write_env_line 'p&a|s\s word'
  [ "$(read_env_value "${KEY}")" = 'p&a|s\s word' ]
  assert_match "untouched" '^OTHER=keep$' "$(cat "${ENV_FILE}")"
  TMP_FILE="${BATS_TEST_TMPDIR}/leftover"
  : >"${TMP_FILE}"
  cleanup
  [ ! -e "${TMP_FILE}" ]
}

@test "new-workspace: cleanup removes the temporary tree" {
  load_fn scripts/new-workspace.sh cleanup
  WORK="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${WORK}/repo"
  cleanup
  [ ! -d "${WORK}" ]
}

@test "spark-configure: want_value, live_value, and report_get" {
  load_fn scripts/spark-configure.sh want_value
  load_fn scripts/spark-configure.sh live_value
  load_fn scripts/spark-configure.sh report_get
  keys="PARALLEL=5 CONTEXT=262144"
  file="${BATS_TEST_TMPDIR}/host.env"
  printf '%s\n' 'PARALLEL=9' >"${file}"
  [ "$(want_value PARALLEL "${file}")" = "9" ]
  [ "$(want_value CONTEXT "${BATS_TEST_TMPDIR}/missing")" = "262144" ]
  SPARK_CFG_PORT=9999
  [ "$(want_value PORT "${BATS_TEST_TMPDIR}/missing")" = "9999" ]
  report="${BATS_TEST_TMPDIR}/report"
  printf '%s\n' 'inspect.PARALLEL=4' 'recipe.PARALLEL=5' 'inspect.CONTEXT=NOTSET' 'recipe.CONTEXT=8' >"${report}"
  [ "$(live_value PARALLEL "${report}")" = "4" ]
  [ "$(live_value CONTEXT "${report}")" = "8" ]
  [ "$(report_get inspect.PARALLEL "${report}" fallback)" = "4" ]
  [ "$(report_get missing "${report}" fallback)" = "fallback" ]
}

@test "spark-verify: fact_value reads the per-host facts file" {
  load_fn scripts/spark-verify.sh report_get
  load_fn scripts/spark-verify.sh fact_value
  work="${BATS_TEST_TMPDIR}/facts"
  mkdir -p "${work}"
  printf '%s\n' 'parallel=5' 'context=NOTSET' >"${work}/spark-1.facts"
  [ "$(fact_value spark-1 parallel)" = "5" ]
  [ "$(fact_value spark-1 context)" = "" ]
}

@test "spark-configure: ssh_run caps the ssh client" {
  load_fn scripts/spark-configure.sh ssh_run
  has_timeout=1
  ssh_port=2222
  timeout_s=30
  export STUB_SSH_OUT="remote-ok"
  run ssh_run "spark@10.0.0.5" "true" 9
  [ "${status}" -eq 0 ]
  [ "${output}" = "remote-ok" ]
  assert_match "port" '-p 2222' "$(stub_log_last ssh)"
}

@test "spark probes: say, fact, run_test, and probe_script" {
  load_fn scripts/spark-configure.sh say
  [ "$(say have_docker=present)" = "have_docker=present" ]
  load_fn scripts/spark-verify.sh say
  [ "$(say dri=present)" = "dri=present" ]
  load_fn scripts/spark-verify.sh fact
  cenv=$'PARALLEL=9\n'
  RECIPE_DIR="${BATS_TEST_TMPDIR}/no-such-recipe"
  [ "$(fact PARALLEL)" = "9" ]
  unset cenv
  RECIPE_DIR="${BATS_TEST_TMPDIR}/recipe"
  mkdir -p "${RECIPE_DIR}"
  printf '%s\n' 'PARALLEL=3' >"${RECIPE_DIR}/.env"
  [ "$(fact PARALLEL)" = "3" ]
  load_fn scripts/spark-verify.sh run_test
  have_timeout=""
  printf '%s\n' 'echo all-good' >"${RECIPE_DIR}/ok.sh"
  chmod +x "${RECIPE_DIR}/ok.sh"
  [ "$(run_test demo bash ./ok.sh)" = "demo: ok — all-good" ]
  load_fn scripts/spark-configure.sh probe_script
  run probe_script
  assert_match "configure probe ends" 'report_end' "${output}"
  load_fn scripts/spark-verify.sh probe_script
  run probe_script
  assert_match "verify probe defines fact" '^fact()' "${output}"
}

@test "spark-configure: probe_http prints a body and stays empty on failure" {
  load_fn scripts/spark-configure.sh probe_http
  has_timeout=""
  probe_tool=(curl -fsS -m 5)
  export STUB_CURL_OUT='{"ok":1}'
  [ "$(probe_http "http://spark.example:8888/health")" = '{"ok":1}' ]
  export STUB_CURL_RC=22
  export STUB_CURL_OUT=""
  [ "$(probe_http "http://spark.example:8888/health")" = "" ]
}
