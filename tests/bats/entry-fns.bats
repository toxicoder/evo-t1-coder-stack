#!/usr/bin/env bats
#
# ## entry-fns.bats — unit coverage for helpers that still live in entry scripts.
#
# Each test evals the production function (tests/extract_fn.py) and asserts on
# its result. docker, curl, ssh, psql and timeout are stubs.
#
# Usage: bazelisk test //tests:bats_entry_fns_test   (from any cwd)
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
  # api_read / api_write / cleanup_token call stack_timeout from coder_api.sh.
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
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
  load_fn scripts/coder-agents.sh model_config_chunk
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
  load_fn scripts/lib/common.sh log
  load_fn scripts/lib/common.sh err
  load_fn scripts/lib/common.sh die
  load_fn scripts/lib/common.sh warn
  load_fn scripts/lib/common.sh note
  load_fn scripts/coder-agents.sh json_escape
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh api_write
  load_fn scripts/coder-agents.sh create_model_config
  load_fn scripts/coder-agents.sh alias_is_live
  load_fn scripts/coder-agents.sh stack_config_ids
  load_fn scripts/coder-agents.sh dead_config_ids
  load_fn scripts/coder-agents.sh pin_lane
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  provider_id="prov-1"
  ALIASES_PROBED=0
  agent_id=""
  agent_low_id=""
  agent_medium_id=""
  agent_xhigh_id=""
  chat_id=""
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

@test "coder-agents: pin_lane re-pins a lane aimed at an alias the proxy calls dead" {
  load_fn scripts/lib/common.sh log
  load_fn scripts/lib/common.sh err
  load_fn scripts/lib/common.sh die
  load_fn scripts/lib/common.sh warn
  load_fn scripts/lib/common.sh note
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh api_write
  load_fn scripts/coder-agents.sh alias_is_live
  load_fn scripts/coder-agents.sh stack_config_ids
  load_fn scripts/coder-agents.sh dead_config_ids
  load_fn scripts/coder-agents.sh pin_lane
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  ALIASES_PROBED=1
  LIVE_ALIASES=$'agent\nagent-low'
  agent_id="11111111-1111-4111-8111-111111111111"
  agent_low_id=""
  agent_medium_id=""
  agent_xhigh_id=""
  chat_id="22222222-2222-4222-8222-222222222222"
  # The lane currently points at the Arc `chat` config, whose alias the proxy
  # holds unhealthy. Before the health gate this was "the admin's choice" and
  # was kept forever; compaction then had no model that could answer.
  export STUB_CURL_OUT="{\"model_config_id\":\"${chat_id}\"}"
  run pin_lane compaction "agent (tool-capable primary)" "${agent_id}"
  [ "${status}" -eq 0 ]
  assert_match "re-pin reason" 'reports unhealthy' "${output}"
  assert_match "re-pin lands" 'lane compaction: pinned to model config agent' "${output}"
  # The body travels on stdin (api_write --data-binary @-), so argv proves only
  # which lane was written.
  assert_match "PUT targets the lane" 'model-override/compaction' "$(stub_log_last curl)"
  [[ ${output} != *"leaving the admin's choice"* ]]
}

@test "coder-agents: pin_lane keeps an admin pin it did not write" {
  load_fn scripts/lib/common.sh log
  load_fn scripts/lib/common.sh err
  load_fn scripts/lib/common.sh die
  load_fn scripts/lib/common.sh warn
  load_fn scripts/lib/common.sh note
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh api_write
  load_fn scripts/coder-agents.sh alias_is_live
  load_fn scripts/coder-agents.sh stack_config_ids
  load_fn scripts/coder-agents.sh dead_config_ids
  load_fn scripts/coder-agents.sh pin_lane
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  ALIASES_PROBED=0
  agent_id="11111111-1111-4111-8111-111111111111"
  agent_low_id=""
  agent_medium_id=""
  agent_xhigh_id=""
  chat_id=""
  export STUB_CURL_OUT='{"model_config_id":"99999999-9999-4999-8999-999999999999"}'
  run pin_lane general "agent (tool-capable primary)" "${agent_id}"
  [ "${status}" -eq 0 ]
  assert_match "admin config" 'did not create' "${output}"
  [ "$(stub_log_count curl)" -eq 1 ]
}

@test "coder-agents: litellm_live_aliases drops only aliases with no healthy deployment" {
  load_fn scripts/coder-agents.sh litellm_live_aliases
  info='{"data":[{"model_name":"coder","litellm_params":{},"model_info":{"id":"aaa"}},{"model_name":"chat","litellm_params":{},"model_info":{"id":"bbb"}},{"model_name":"agent","litellm_params":{},"model_info":{"id":"agent-spark-1"}},{"model_name":"agent","litellm_params":{},"model_info":{"id":"agent-spark-2"}}]}'
  health='{"healthy_count":2,"healthy_endpoints":[{"model_id":"agent-spark-1"},{"model_id":"agent-spark-2"}],"unhealthy_count":2,"unhealthy_endpoints":[{"model_id":"aaa","error":"404"},{"model_id":"bbb","error":"404"}]}'
  run litellm_live_aliases "${info}" "${health}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "agent" ]
  # An alias the health body says nothing about is not a dead one: a proxy that
  # has not probed yet must not blank the dropdown, so the gate fails open.
  run litellm_live_aliases "${info}" '{"healthy_count":0,"unhealthy_count":0}'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  # One deployment healthy is enough: three Spark boxes, one dark, is a lane
  # that still serves.
  run litellm_live_aliases "${info}" '{"unhealthy_endpoints":[{"model_id":"agent-spark-2"}]}'
  [ "${status}" -eq 0 ]
  [[ ${output} == *agent* ]]
  # No usable /v1/model/info means no answer at all, and the caller falls back
  # to registering every alias.
  run litellm_live_aliases '' "${health}"
  [ "${status}" -eq 1 ]
}

@test "coder-agents: ensure_model_config refuses to register an alias the proxy calls dead" {
  load_fn scripts/lib/common.sh log
  load_fn scripts/lib/common.sh warn
  load_fn scripts/lib/common.sh err
  load_fn scripts/coder-agents.sh json_escape
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh api_write
  load_fn scripts/coder-agents.sh model_config_chunk
  load_fn scripts/coder-agents.sh model_config_id
  load_fn scripts/coder-agents.sh check_model_config_drift
  load_fn scripts/coder-agents.sh create_model_config
  load_fn scripts/coder-agents.sh alias_is_live
  load_fn scripts/coder-agents.sh ensure_model_config
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  provider_id="prov-1"
  ALIASES_PROBED=1
  LIVE_ALIASES=$'agent\nagent-low'
  export STUB_CURL_OUT='{"configs":[{"id":"d162f0a4-1111-4444-8888-121212121212","model":"agent","enabled":true,"is_default":true,"context_limit":262144}]}'
  # Called directly with output redirected, never through run or $(): both make a
  # subshell, and MODEL_CONFIG_ID is the contract this function returns through.
  local ensure_out="${BATS_TEST_TMPDIR}/ensure.log"
  ensure_model_config chat 'Coder Agents Arc' 32768 false >"${ensure_out}"
  [ "${MODEL_CONFIG_ID}" = "" ]
  assert_match "skipped dead alias" 'model config chat: skipped' "$(cat "${ensure_out}")"
  [ "$(stub_log_count curl)" -eq 1 ]
  # The live alias still registers, and the row that is already there is left alone.
  ensure_model_config agent 'Coder Agents Spark' 262144 true >"${ensure_out}"
  [ "${MODEL_CONFIG_ID}" = "d162f0a4-1111-4444-8888-121212121212" ]
  assert_match "pre-existing row" 'already present' "$(cat "${ensure_out}")"
}

@test "coder-agents: check_model_config_drift names what the create check would have missed" {
  load_fn scripts/lib/common.sh log
  load_fn scripts/lib/common.sh warn
  load_fn scripts/coder-agents.sh api_read
  load_fn scripts/coder-agents.sh model_config_chunk
  load_fn scripts/coder-agents.sh check_model_config_drift
  session_token=t
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CONTAINER_API_URL="http://127.0.0.1:3000"
  export STUB_CURL_OUT='{"configs":[{"id":"d162f0a4-1111-4444-8888-121212121212","model":"agent","enabled":false,"is_default":false,"context_limit":8192}]}'
  run check_model_config_drift agent 262144 true
  [ "${status}" -eq 0 ]
  assert_match "disabled" 'present but disabled' "${output}"
  assert_match "not default" 'not the deployment default' "${output}"
  assert_match "wrong window" 'context_limit is 8192' "${output}"
  # A row that matches raises nothing, so a healthy deployment stays quiet.
  export STUB_CURL_OUT='{"configs":[{"id":"d162f0a4-1111-4444-8888-121212121212","model":"agent","enabled":true,"is_default":true,"context_limit":262144}]}'
  run check_model_config_drift agent 262144 true
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "coder-agents: pick_live_config walks the preference list past a dead alias" {
  load_fn scripts/coder-agents.sh alias_is_live
  load_fn scripts/coder-agents.sh pick_live_config
  ALIASES_PROBED=1
  LIVE_ALIASES=$'agent'
  agent_id="11111111-1111-4111-8111-111111111111"
  agent_low_id=""
  agent_medium_id=""
  agent_xhigh_id=""
  chat_id="22222222-2222-4222-8222-222222222222"
  # compaction prefers chat, but chat is unhealthy, so agent wins and the caller
  # learns which alias it is labelling.
  run pick_live_config "chat agent"
  [ "${status}" -eq 0 ]
  [ "${output}" = "agent ${agent_id}" ]
  run pick_live_config "agent chat"
  [ "${output}" = "agent ${agent_id}" ]
  export LIVE_ALIASES=$'chat'
  run pick_live_config "chat agent"
  [ "${output}" = "chat ${chat_id}" ]
  # Nothing in the list qualifies: the caller stops rather than pin to nothing.
  export LIVE_ALIASES=$'agent-low'
  run pick_live_config "chat agent"
  [ "${output}" = "" ]
}

@test "coder-agents: litellm_get keeps the master key out of every argv" {  load_fn scripts/lib/common.sh log
  load_fn scripts/coder-agents.sh litellm_get
  API_TIMEOUT=5
  CODER_SERVICE=coder
  CODER_CONTAINER=stack-coder-1
  LITELLM_BASE_URL="http://litellm:4000"
  litellm_key="sk-health-probe-secret-0123456789"
  export STUB_CURL_OUT='{"data":[]}'
  run litellm_get "/v1/model/info"
  [ "${status}" -eq 0 ]
  assert_match "config from stdin" -- '--config' "$(stub_log_last curl)"
  assert_match "asks the health-backed list" '/v1/model/info' "$(stub_log_last curl)"
  if grep -q 'sk-health-probe-secret-0123456789' "${STUB_LOG}"/*.log; then
    fail "the master key reached a stub argv log"
  fi
}

@test "coder-agents: cleanup_token deletes the minted api_keys row" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
  load_fn scripts/coder-agents.sh cleanup_token
  TOKEN_NAME="stack-coder-agents"
  export DB_CONTAINER=stack-db-1 # psql_sql refuses to run without a resolved container
  cleanup_token
  assert_match "delete" 'stack-coder-agents' "$(stub_log_last psql)"
}

@test "push-template: known_templates lists names in TEMPLATES_DEFAULT order" {
  load_fn scripts/push-template.sh known_templates
  # A fixture, not the script's own list: this checks the joining, so the pair
  # here names the template directories the stack ships today (workspace first,
  # the devcontainer template second) and nothing more.
  TEMPLATES_DEFAULT=("workspace:templates/workspace" "devcontainer:templates/devcontainer")
  [ "$(known_templates)" = "workspace, devcontainer" ]
}

@test "push-template: preset_desc_guard rejects a description over 128 bytes" {
  load_fn scripts/lib/common.sh log
  load_fn scripts/lib/common.sh err
  load_fn scripts/lib/common.sh die
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

@test "push-template: github_auth_provider_id defaults to github and forwards a custom coder.env id" {
  load_fn scripts/lib/common.sh err
  load_fn scripts/lib/common.sh die
  load_fn scripts/push-template.sh github_auth_provider_id
  [ "$(github_auth_provider_id "${BATS_TEST_TMPDIR}/no-such.env")" = "github" ]
  : >"${BATS_TEST_TMPDIR}/empty.env"
  [ "$(github_auth_provider_id "${BATS_TEST_TMPDIR}/empty.env")" = "github" ]
  printf 'CODER_EXTERNAL_AUTH_0_ID=\n' >"${BATS_TEST_TMPDIR}/blank.env"
  [ "$(github_auth_provider_id "${BATS_TEST_TMPDIR}/blank.env")" = "github" ]
  printf 'CODER_EXTERNAL_AUTH_0_ID="primary-github"\n' >"${BATS_TEST_TMPDIR}/quoted.env"
  [ "$(github_auth_provider_id "${BATS_TEST_TMPDIR}/quoted.env")" = "primary-github" ]
  printf 'CODER_EXTERNAL_AUTH_0_ID=primary-github\n' >"${BATS_TEST_TMPDIR}/custom.env"
  [ "$(github_auth_provider_id "${BATS_TEST_TMPDIR}/custom.env")" = "primary-github" ]
  printf 'CODER_EXTERNAL_AUTH_0_ID=bad id\n' >"${BATS_TEST_TMPDIR}/bad.env"
  run github_auth_provider_id "${BATS_TEST_TMPDIR}/bad.env"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a Coder provider id"* ]]
  # Production always passes the path. A no-arg call is SC2120 (function
  # references $1 but none are ever passed) and fails //lints:shell on Linux.
  grep -Fq 'github_auth_id="$(github_auth_provider_id coder.env)"' "${REPO_ROOT}/scripts/push-template.sh"
}

@test "push-template: icon_data_url_guard rejects an SVG whose data URL exceeds 256 characters" {
  load_fn scripts/lib/common.sh err
  load_fn scripts/lib/common.sh die
  load_fn scripts/push-template.sh icon_data_url_guard
  svg="${BATS_TEST_TMPDIR}/vscode-alt.svg"
  # 172 bytes -> 4*ceil(172/3)+26 = 258, just over the column.
  printf 'x%.0s' {1..172} >"${svg}"
  run icon_data_url_guard "${svg}"
  [ "${status}" -eq 1 ]
  assert_match "varchar" '256' "${output}"
  printf '%s\n' '<svg/>' >"${svg}"
  run icon_data_url_guard "${svg}"
  [ "${status}" -eq 0 ]
  # A missing file is template_push_one's job, so this guard stays silent.
  run icon_data_url_guard "${BATS_TEST_TMPDIR}/no-such.svg"
  [ "${status}" -eq 0 ]
}

@test "push-template: cleanup_token deletes the push token" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
  load_fn scripts/push-template.sh cleanup_token
  TOKEN_NAME="stack-template-push"
  export DB_CONTAINER=stack-db-1 # psql_sql refuses to run without a resolved container
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
  # say/fact/run_test live in the extracted POSIX probe files; probe_script
  # stays on the entries and prints those files verbatim.
  load_fn scripts/lib/probes/spark-configure.sh say
  [ "$(say have_docker=present)" = "have_docker=present" ]
  load_fn scripts/lib/probes/spark-verify.sh say
  [ "$(say dri=present)" = "dri=present" ]
  load_fn scripts/lib/probes/spark-verify.sh fact
  cenv=$'PARALLEL=9\n'
  RECIPE_DIR="${BATS_TEST_TMPDIR}/no-such-recipe"
  [ "$(fact PARALLEL)" = "9" ]
  unset cenv
  RECIPE_DIR="${BATS_TEST_TMPDIR}/recipe"
  mkdir -p "${RECIPE_DIR}"
  printf '%s\n' 'PARALLEL=3' >"${RECIPE_DIR}/.env"
  [ "$(fact PARALLEL)" = "3" ]
  load_fn scripts/lib/probes/spark-verify.sh run_test
  have_timeout=""
  printf '%s\n' 'echo all-good' >"${RECIPE_DIR}/ok.sh"
  chmod +x "${RECIPE_DIR}/ok.sh"
  [ "$(run_test demo bash ./ok.sh)" = "demo: ok — all-good" ]
  # The entries cat the probe file by repo-root-relative path, which is what the
  # repo-root cd at the top of each script guarantees in production.
  cd "${REPO_ROOT}"
  load_fn scripts/spark-configure.sh probe_script
  run probe_script
  assert_match "configure probe ends" 'report_end' "${output}"
  load_fn scripts/spark-verify.sh probe_script
  run probe_script
  assert_match "verify probe defines fact" '^fact()' "${output}"
}

@test "spark: probe_http caps curl and keeps an unanswered probe empty" {
  # scripts/lib/spark.sh is the only probe_http now; both entries pass cap+url.
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/spark.sh"
  export STUB_CURL_OUT='{"ok":1}'
  [ "$(probe_http 5 "http://spark.example:8888/health")" = '{"ok":1}' ]
  assert_match "curl still sees its argv" 'curl -fsS -m 5 http://spark.example:8888/health' "$(stub_log_last curl)"
  [[ "$(stub_log_last timeout)" == timeout* ]]
  export STUB_CURL_RC=22
  export STUB_CURL_OUT=""
  [ "$(probe_http 5 "http://spark.example:8888/health")" = "" ]
}

# ── which checkout each CLI works in ─────────────────────────────────────────
# scripts/spark-verify.sh, scripts/spark-configure.sh and scripts/build-dev-image.sh
# read the checkout's .env, write sparks/ output, or use images/dev as a build
# context. Under `bazelisk run` all three used to act on the runfiles copy, where
# that state is missing or thrown away, so each has to resolve the checkout through
# resolve_checkout and stop rather than act on a tree it cannot prove.

orphan_copy() {
  # Print a directory holding one entry script plus scripts/lib/, with no compose
  # file: no candidate can call it a checkout, and nothing it does can reach the
  # real tree this suite runs from.
  local rel="$1" root="${BATS_TEST_TMPDIR?}/orphan"
  mkdir -p "${root}/scripts/lib"
  cp "${REPO_ROOT}/${rel}" "${root}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  printf '%s' "${root}"
}

run_orphan() {
  # Run an orphaned script from a directory that holds no marker either, with
  # every inherited checkout name cleared. Bazel's cwd is itself a copy of the
  # repo, so the inherited names and PWD all have to go for the refusal to be
  # the thing under test.
  local rel="$1" root
  root="$(orphan_copy "${rel}")"
  run --separate-stderr env -C "$(mktemp -d "${BATS_TEST_TMPDIR?}/nowhere.XXXXXX")" \
    REPO_ROOT= BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    bash "${root}/scripts/$(basename "${rel}")"
}

@test "spark-verify: an unprovable checkout stops before any probe" {
  run_orphan scripts/spark-verify.sh
  [ "${status}" -eq 5 ] || fail "an unprovable root exited ${status}: ${stderr}"
  assert_match "the refusal is printed" 'unresolvable repo root' "${stderr}"
  [ "$(stub_log_count ssh)" -eq 0 ] || fail "a probe left the box: $(stub_log ssh)"
  [ "$(stub_log_count curl)" -eq 0 ] || fail "a probe left the box: $(stub_log curl)"
}

@test "spark-configure: an unprovable checkout writes no sparks/ output" {
  run_orphan scripts/spark-configure.sh
  [ "${status}" -eq 5 ] || fail "an unprovable root exited ${status}: ${stderr}"
  assert_match "the refusal is printed" 'unresolvable repo root' "${stderr}"
  [ ! -e "${BATS_TEST_TMPDIR}/orphan/sparks" ] || fail "sparks/ was written outside a checkout"
  [ "$(stub_log_count ssh)" -eq 0 ] || fail "a probe left the box: $(stub_log ssh)"
}

@test "build-dev-image: an unprovable checkout stops before docker is asked" {
  run_orphan scripts/build-dev-image.sh
  [ "${status}" -eq 5 ] || fail "an unprovable root exited ${status}: ${stderr}"
  assert_match "the refusal is printed" 'unresolvable repo root' "${stderr}"
  [ "$(stub_log_count docker)" -eq 0 ] || fail "docker was called: $(stub_log docker)"
}
