#!/usr/bin/env bats
#
# ## grafana-agent-token.bats - hermetic coverage for scripts/grafana-agent-token.sh.
#
# The contract pinned here is the one an operator and an agent both depend on: the
# credential is written one line deep at 0600 so the query CLI can read it, a second run
# refuses rather than invalidating the token a live agent is holding, the account is
# Viewer and nothing else, and the credential appears nowhere the operator can leak it -
# not in stdout, not in stderr, not in the argv the transport stub recorded. That last
# assertion is the whole point of the config-file and mounted-body design, so it is
# asserted against the stub's own record of what was passed.
#
# Hermetic by construction. setup() writes one private `docker` stub into a bin/
# directory prepended to PATH: it records argv only, answers the three service-account
# endpoints from canned JSON, and writes each response body into the host directory the
# CLI bind-mounted. No test opens a socket, pulls an image, or needs the observability
# profile enabled anywhere. The two fixture values the plane and the operator supply are
# inert literals held in this test's environment, never in a file under the repo.
#
# Usage: bazelisk test //tests:bats_grafana_agent_token_test   (from any cwd)
# Safety: stubs and canned bodies only. No live service, no Docker, no network, no
# credential outside this test's tmpdir.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
SCRATCH=""
BIN=""
STUB_DIR=""
STUB_LOG=""
SENT_LOG=""
STUB_MINT_VALUE=""
STUB_ADMIN_VALUE=""
MINT_TARGET=""
BASH_BIN=""

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/grafana-agent-token.sh"
  LIB="${REPO_ROOT}/scripts/lib/grafana_agent_token.sh"
  [ -f "${SCRIPT}" ] || skip "scripts/grafana-agent-token.sh does not exist yet"
  [ -f "${LIB}" ] || skip "scripts/lib/grafana_agent_token.sh does not exist yet"

  SCRATCH="$(mktemp -d)"
  BIN="${SCRATCH}/bin"
  STUB_DIR="${SCRATCH}/stub"
  STUB_LOG="${STUB_DIR}/argv.log"
  SENT_LOG="${STUB_DIR}/sent-bodies.log"
  mkdir -p "${BIN}" "${STUB_DIR}"
  : >"${STUB_LOG}"
  : >"${SENT_LOG}"

  # Inert by construction, one literal each, so every "the credential never appears"
  # assertion scans for these exact bytes.
  STUB_MINT_VALUE="gatstub.Abc123_xyz-9.~T"
  STUB_ADMIN_VALUE="stub-admin-value-not-a-real-one"
  printf '%s' "${STUB_MINT_VALUE}" >"${STUB_DIR}/value"

  local compose_fixture="${SCRATCH}/docker-compose.yml"
  : >"${compose_fixture}"
  MINT_TARGET="${SCRATCH}/var/lib/evo-t1-observability/grafana-query-token"
  BASH_BIN="$(command -v bash)"

  write_docker_stub
  PATH="${BIN}:${PATH}"
  export PATH
  export STUB_DIR STUB_LOG SENT_LOG
  export STUB_SA_NAME="evo-t1-agent"
  export GRAFANA_ADMIN_USER="stackadmin"
  export GRAFANA_ADMIN_PASSWORD="${STUB_ADMIN_VALUE}"
  export COMPOSE_PROJECT_NAME="evotest"
}

teardown() {
  [ -n "${SCRATCH:-}" ] && [ -d "${SCRATCH:-}" ] && rm -rf "${SCRATCH}"
  return 0
}

# The one transport this CLI has. It records argv, never a body, so the argv log is the
# thing that proves a credential never became an argument; the bodies it "sends" are
# copied out separately so the role can be asserted without reading argv.
write_docker_stub() {
  cat >"${BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -u
log="${STUB_LOG:?}"
dir="${STUB_DIR:?}"
printf '%s\n' "$*" >>"${log}"

url="${!#}"
host=""
out="body.json"
sent=""
method=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --volume) host="${2%%:*}" ;;
    --request) method="$2" ;;
    -o) out="${2##*/}" ;;
    --data-binary) sent="${2##*/}" ;;
  esac
  shift
done

if [ -n "${sent}" ] && [ -r "${host}/${sent}" ]; then
  cat "${host}/${sent}" >>"${dir}/sent-bodies.log"
  printf '\n' >>"${dir}/sent-bodies.log"
fi

code=200
case "${url}" in
  */api/serviceaccounts/search*)
    if [ "${STUB_SA_EXISTS:-1}" = "1" ]; then
      printf '%s' "{\"totalCount\":1,\"page\":1,\"result\":[{\"id\":11,\"name\":\"${STUB_SA_NAME}\",\"role\":\"Viewer\"}]}" >"${host}/${out}"
    else
      printf '%s' '{"totalCount":0,"page":1,"result":[]}' >"${host}/${out}"
    fi
    ;;
  */api/serviceaccounts)
    printf '%s' "{\"id\":11,\"name\":\"${STUB_SA_NAME}\",\"role\":\"Viewer\"}" >"${host}/${out}"
    ;;
  */tokens)
    if [ "${method}" = "POST" ]; then
      if [ -n "${STUB_FAIL_MINT:-}" ]; then
        code=500
        printf '%s' '{"message":"mint refused"}' >"${host}/${out}"
      else
        printf '%s' "{\"id\":21,\"name\":\"${STUB_SA_NAME}-token\",\"key\":\"$(cat "${dir}/value")\"}" >"${host}/${out}"
      fi
    else
      printf '%s' '[{"id":21,"name":"first"},{"id":22,"name":"second"}]' >"${host}/${out}"
    fi
    ;;
  */tokens/*)
    printf '%s' '{"message":"Token deleted"}' >"${host}/${out}"
    ;;
  *)
    code=404
    printf '%s' '{"message":"not found"}' >"${host}/${out}"
    ;;
esac
printf '%s' "${code}"
STUB
  chmod +x "${BIN}/docker"
}

# -- the CLI surface ---------------------------------------------------------

@test "--help answers before anything else, with no docker on PATH" {
  run "${BASH_BIN}" "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ ${output} == *"grafana-agent-token.sh"* ]]
  [[ ${output} == *"--rotate"* ]]
  [[ ${output} == *"never printed"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "an unknown option is a usage error, answered before any request" {
  run "${BASH_BIN}" "${SCRIPT}" --nope
  [ "${status}" -eq 2 ]
  [[ ${output} == *"unknown option: --nope"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "--ttl, --account-name and --timeout are validated before anything runs" {
  run "${BASH_BIN}" "${SCRIPT}" --ttl soon --dry-run
  [ "${status}" -eq 2 ]
  [[ ${output} == *"--ttl"* ]]
  run "${BASH_BIN}" "${SCRIPT}" --account-name 'two words' --dry-run
  [ "${status}" -eq 2 ]
  run "${BASH_BIN}" "${SCRIPT}" --timeout 0 --dry-run
  [ "${status}" -eq 2 ]
  [ ! -s "${STUB_LOG}" ]
}

@test "--dry-run prints the plan: Viewer, the path, the refusal, and a summary line" {
  run "${BASH_BIN}" "${SCRIPT}" --dry-run --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"role Viewer"* ]]
  [[ ${output} == *"${MINT_TARGET}"* ]]
  [[ ${output} == *"would be refused"* ]]
  [[ ${output} == *"summary: 1 ok, 0 warnings, 0 failed"* ]]
  [ ! -e "${MINT_TARGET}" ]
  [ ! -s "${STUB_LOG}" ]
}

@test "the plan says --rotate replaces instead of refusing" {
  run "${BASH_BIN}" "${SCRIPT}" --dry-run --rotate --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"revoked and replaced"* ]]
}

# -- idempotence ------------------------------------------------------------

@test "a second run refuses to rotate a live credential without --rotate" {
  mkdir -p "$(dirname "${MINT_TARGET}")"
  printf '%s\n' "${STUB_MINT_VALUE}" >"${MINT_TARGET}"
  chmod 600 "${MINT_TARGET}"
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"error:"* ]]
  [[ ${output} == *"${MINT_TARGET}"* ]]
  [[ ${output} == *"--rotate"* ]]
  [[ ${output} == *"summary:"* ]]
  # Refusing means no request was made at all.
  [ ! -s "${STUB_LOG}" ]
}

@test "a stray file that is not a credential is repaired, not refused" {
  mkdir -p "$(dirname "${MINT_TARGET}")"
  printf 'not a token, just a placeholder\n' >"${MINT_TARGET}"
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"ok: wrote the read-only credential"* ]]
}

@test "a fresh box creates the account and writes one line at 0600" {
  export STUB_SA_EXISTS=0
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"created service account evo-t1-agent (id 11) with role Viewer"* ]]
  [[ ${output} == *"summary: 2 ok, 0 warnings, 0 failed"* ]]
}

@test "an existing account is reused rather than duplicated" {
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"reusing service account evo-t1-agent (id 11)"* ]]
  ! grep -q -- '--request POST /api/serviceaccounts ' "${STUB_LOG}"
}

@test "the mint writes one line at 0600 with the value the plane returned" {
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [ -f "${MINT_TARGET}" ]
  [ "$(cat "${MINT_TARGET}")" = "${STUB_MINT_VALUE}" ]
  [ "$(wc -l <"${MINT_TARGET}" | tr -d ' ')" -eq 1 ]
  [ "$(stat -c '%a' "${MINT_TARGET}")" = "600" ]
  [[ ${output} == *"summary: 2 ok, 0 warnings, 0 failed"* ]]
}

@test "--rotate revokes what the account holds before minting" {
  mkdir -p "$(dirname "${MINT_TARGET}")"
  printf '%s\n' "old.live.value-1" >"${MINT_TARGET}"
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}" --rotate
  [ "${status}" -eq 0 ]
  [ "$(cat "${MINT_TARGET}")" = "${STUB_MINT_VALUE}" ]
  [[ ${output} == *"summary: 3 ok, 0 warnings, 0 failed"* ]]
  [ "$(grep -c -- '--request DELETE' "${STUB_LOG}")" -eq 2 ]
  [[ ${output} == *"revoked 2 previous token(s)"* ]]
}

@test "the account is created as Viewer and nothing else" {
  export STUB_SA_EXISTS=0
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  grep -q -- '"role":"Viewer"' "${SENT_LOG}"
  grep -q -- '"name":"evo-t1-agent"' "${SENT_LOG}"
}

@test "the request rides the project network and a config file, never an argument" {
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  grep -q -- '--network evotest_default' "${STUB_LOG}"
  grep -q -- 'curlimages/curl:8.10.1' "${STUB_LOG}"
  grep -q -- '--config /mnt/evo-t1-mint/curlrc' "${STUB_LOG}"
  ! grep -q -- '-H ' "${STUB_LOG}"
  ! grep -q -- '-u ' "${STUB_LOG}"
}

# -- the credential stays in the file ---------------------------------------

@test "the minted value and the admin value appear in no output and no argv" {
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"${STUB_MINT_VALUE}"* ]]
  [[ ${output} != *"${STUB_ADMIN_VALUE}"* ]]
  ! grep -qF -- "${STUB_MINT_VALUE}" "${STUB_LOG}"
  ! grep -qF -- "${STUB_ADMIN_VALUE}" "${STUB_LOG}"
}

@test "a failing mint prints a redacted complaint and writes no credential" {
  export STUB_FAIL_MINT=1
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"error:"* ]]
  [[ ${output} == *"refused to mint"* ]]
  [[ ${output} != *"${STUB_MINT_VALUE}"* ]]
  [ ! -e "${MINT_TARGET}" ]
}

@test "a missing admin credential is an error that asks for nothing" {
  run env -u GRAFANA_ADMIN_USER -u GRAFANA_ADMIN_PASSWORD "${BASH_BIN}" \
    "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"GRAFANA_ADMIN_PASSWORD"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "the shipped placeholder password is a warning, not a fault" {
  export GRAFANA_ADMIN_PASSWORD="change-me-grafana"
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"warning:"* ]]
  [[ ${output} == *"placeholder"* ]]
}

@test "no docker on PATH is an error that names the transport" {
  rm -f "${BIN}/docker"
  if command -v docker >/dev/null 2>&1; then
    skip "a real docker is on PATH in this sandbox, so the absence cannot be staged"
  fi
  run "${BASH_BIN}" "${SCRIPT}" --token-file "${MINT_TARGET}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"docker is not on PATH"* ]]
}

# -- the rules in the lib ---------------------------------------------------

@test "gat_is_token_shape refuses anything that is not one token line" {
  # shellcheck source=/dev/null
  source "${LIB}"
  gat_is_token_shape "abc.DEF-123_x~y"
  ! gat_is_token_shape ""
  ! gat_is_token_shape "$(printf 'abc\ndef')"
  ! gat_is_token_shape "$(printf 'abc\r\ndef')"
  ! gat_is_token_shape "abc def"
  ! gat_is_token_shape 'abc"def'
}

@test "gat_refuses_overwrite keeps a live credential unless asked" {
  local existing="${SCRATCH}/live" missing="${SCRATCH}/none" stray="${SCRATCH}/stray"
  # shellcheck source=/dev/null
  source "${LIB}"
  gat_refuses_overwrite "${missing}" 0
  printf '%s\n' "${STUB_MINT_VALUE}" >"${existing}"
  ! gat_refuses_overwrite "${existing}" 0
  gat_refuses_overwrite "${existing}" 1
  printf '%s\n' 'a stray line that is not a token' >"${stray}"
  gat_refuses_overwrite "${stray}" 0
}

@test "gat_write_token_file refuses a value that is not a token" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local target="${SCRATCH}/deep/dir/value-file"
  ! gat_write_token_file "${target}" "$(printf 'two\nlines')"
  [ ! -e "${target}" ]
  gat_write_token_file "${target}" "clean.Token-1"
  [ "$(stat -c '%a' "${target}")" = "600" ]
  [ "$(cat "${target}")" = "clean.Token-1" ]
}

@test "gat_json_field reads the three scalars this CLI depends on" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local body="${SCRATCH}/body.json"
  printf '%s' '{"id":11,"name":"evo-t1-agent","role":"Viewer","key":"glsa.abc-123"}' >"${body}"
  [ "$(gat_json_field "${body}" id)" = "11" ]
  [ "$(gat_json_field "${body}" key)" = "glsa.abc-123" ]
  [ "$(gat_json_field "${body}" role)" = "Viewer" ]
  ! gat_json_field "${body}" absent
  ! gat_json_field "${body}" 'id; rm'
  ! gat_json_field "${SCRATCH}/nope" id
}

@test "gat_find_service_account_id matches the exact name only" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local body="${SCRATCH}/search.json"
  printf '%s' '{"totalCount":2,"result":[{"id":11,"name":"evo-t1-agent","role":"Viewer"},{"id":12,"name":"evo-t1-agent-backup","role":"Admin"}]}' >"${body}"
  [ "$(gat_find_service_account_id "${body}" "evo-t1-agent")" = "11" ]
  ! gat_find_service_account_id "${body}" "no-such-account"
}

@test "gat_list_token_ids lists ids one per line and tolerates an empty page" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local body="${SCRATCH}/tokens.json"
  printf '%s' '[{"id":21,"name":"a"},{"id":22,"name":"b"}]' >"${body}"
  [ "$(gat_list_token_ids "${body}" | tr '\n' ',')" = "21,22," ]
  printf '%s' '[]' >"${body}"
  [ -z "$(gat_list_token_ids "${body}")" ]
}

@test "gat_redact scrubs the credential out of anything about to be printed" {
  # shellcheck source=/dev/null
  source "${LIB}"
  GAT_TOKEN="${STUB_MINT_VALUE}"
  local scrubbed
  scrubbed="$(gat_redact "curl failed carrying ${STUB_MINT_VALUE} back")"
  [[ ${scrubbed} != *"${STUB_MINT_VALUE}"* ]]
  [[ ${scrubbed} == *"[redacted]"* ]]
}

@test "every function this pair ships is defined where it claims to be" {
  local fn
  for fn in gat_is_token_shape gat_refuses_overwrite gat_write_token_file \
    gat_curl_config gat_json_field gat_find_service_account_id \
    gat_list_token_ids gat_redact; do
    # shellcheck source=/dev/null
    source "${LIB}"
    declare -F "${fn}" >/dev/null
  done
  for fn in usage gat_usage_error gat_preflight gat_container_curl \
    gat_write_payload gat_ensure_service_account gat_revoke_existing_tokens \
    gat_mint_token gat_plan; do
    grep -q "^${fn}()" "${SCRIPT}"
  done
}
