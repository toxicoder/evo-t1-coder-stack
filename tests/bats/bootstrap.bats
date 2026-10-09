#!/usr/bin/env bats
#
# ## bootstrap.bats — unit coverage for scripts/lib/bootstrap.sh
#
# Hermetic: curl is the stub. openssl and sed are the host tools, pointed at
# scratch files. The entry script is not executed here (it provisions certs
# and may build an image).
# Usage: bats tests/bats/bootstrap.bats

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs curl
  cd "${BATS_TEST_TMPDIR}"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/bootstrap.sh"
}

@test "bootstrap: gen_secret prints 32 hex characters" {
  secret="$(gen_secret)"
  [[ "${secret}" =~ ^[0-9a-f]{32}$ ]]
}

@test "bootstrap: sed_inplace rewrites a file in place" {
  printf 'A=1\n' > .env
  sed_inplace 's|^A=.*|A=2|' .env
  [ "$(cat .env)" = "A=2" ]
}

@test "bootstrap: set_secret replaces a placeholder and names the key" {
  printf 'CODER_PG_PASSWORD=change-me\n' > .env
  run --separate-stderr set_secret CODER_PG_PASSWORD
  [ "${status}" -eq 0 ]
  [ "${output}" = "generated CODER_PG_PASSWORD" ]
  value="$(sed -n 's|^CODER_PG_PASSWORD=||p' .env)"
  [[ "${value}" =~ ^[0-9a-f]{32}$ ]]
}

@test "bootstrap: upsert_env appends, replaces, and stays quiet when equal" {
  printf 'K=old\n' > .env
  run upsert_env K new
  [ "${output}" = "set K=new" ]
  [ "$(sed -n 's|^K=||p' .env)" = "new" ]
  run upsert_env K new
  [ -z "${output}" ]
  run upsert_env OTHER v
  [ "${output}" = "set OTHER=v" ]
  grep -qx 'OTHER=v' .env
}

@test "bootstrap: probe_agent_endpoint warns on an empty URL and on silence" {
  run probe_agent_endpoint SPARK1_OPENAI_URL ""
  [ "${status}" -eq 0 ]
  [ "${output}" = "warning: SPARK1_OPENAI_URL is empty — the agent aliases cannot route." ]
  run probe_agent_endpoint SPARK1_OPENAI_URL "http://10.255.255.1:8888/v1"
  [[ "${output}" == warning:*10.255.255.1:8888* ]]
}

@test "bootstrap: probe_agent_endpoint reports a host that answers" {
  export STUB_CURL_OUT="ok"
  export STUB_CURL_RC=0
  run probe_agent_endpoint SPARK1_OPENAI_URL "http://10.0.0.9:8888/v1"
  [ "${output}" = "agent endpoint reachable: 10.0.0.9:8888" ]
}

@test "bootstrap: classify_public_entry sorts service names and rejects junk" {
  [ "$(classify_public_entry coder-box.example)" = "ok coder https://coder-box.example" ]
  [ "$(classify_public_entry kasm.example)" = "ok kasm https://kasm.example" ]
  [ "$(classify_public_entry litellm-box.example)" = "ok litellm https://litellm-box.example" ]
  [ "$(classify_public_entry box.example)" = "ok dashboard https://box.example" ]
  [ "$(classify_public_entry 'https://box.example')" = "skip url" ]
  [ "$(classify_public_entry 'bad_name')" = "skip dns" ]
}

@test "bootstrap: dind_image_ref reads the terraform pin and falls back" {
  printf '  dind_image = "docker:29.8.1-dind"\n' > main.tf
  [ "$(dind_image_ref main.tf)" = "docker:29.8.1-dind" ]
  [ "$(dind_image_ref missing.tf)" = "docker:29.8.1-dind" ]
}
