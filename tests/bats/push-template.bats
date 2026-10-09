#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## push-template.bats — hermetic coverage for scripts/push-template.sh
#
# Hermetic by construction: docker, timeout, curl, psql and coder resolve to the
# tests/bats/tool_stubs/ copies (use_stubs), and every run happens inside a
# throwaway root built by fake_root (its own .env, its own template tree), so
# neither the checkout's real .env nor a live compose stack is consulted. The
# docker stub's `compose exec` passthrough (STUB_DOCKER_EXEC_RUN=1, the default)
# drives the whole CLI chain: the exec'd `coder` resolves through the same
# shadowed PATH, so the push, the versions list and the description edit all
# answer from the coder stub. STUB_DOCKER_EXEC_RUN=0 with STUB_DOCKER_EXEC_RC and
# STUB_DOCKER_EXEC_OUT is the "the daemon answered, and it said No" case.
#
# Seeding psql: tool_stubs/psql prints a fixed body, and this script only walks
# off the token mint when that body equals the api_keys id it just minted
# (random per run), so the chain cases swap in
# fixtures/push-template/psql-token — a psql that echoes the id back out of the
# statement, the way `returning id` answers on a real server.
#
# Usage: bats tests/bats/push-template.bats   (from any cwd)
#
# Safety: stub only. Nothing here needs a daemon, a database or a network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
ACTIVE_ID="d162f0a4-1111-4444-8888-121212121212"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout curl psql coder
}

# fake_root <script> [env-line...] — print a throwaway repo root holding the
# script under test, scripts/lib/ (the seams it sources after its own repo-root
# cd), a private .env and both template dirs. main.tf has to exist in a dir for
# that template to be selectable, and the lockfile keeps the "missing lockfile"
# note out of the way unless a test wants it.
fake_root() {
  local root="${BATS_TEST_TMPDIR?}/root" script="${1}"
  shift
  mkdir -p "${root}/scripts/lib" "${root}/templates/docker-dev" "${root}/templates/docker-devcontainer"
  : >"${root}/docker-compose.yml"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"${root}/.env"
  else
    : >"${root}/.env"
  fi
  printf '%s\n' 'resource "coder_workspace_preset" "x" {' '  name = "x"' '  description = "short"' \
    >"${root}/templates/docker-dev/main.tf"
  printf '%s\n' 'resource "coder_workspace_preset" "y" {' '  name = "y"' '  description = "short"' \
    >"${root}/templates/docker-devcontainer/main.tf"
  : >"${root}/templates/docker-dev/.terraform.lock.hcl"
  : >"${root}/templates/docker-devcontainer/.terraform.lock.hcl"
  cp "${REPO_ROOT}/scripts/${script}" "${root}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  printf '%s' "${root}"
}

# psql_token_variant — swap the copied psql stub for the fixture that answers the
# api_keys INSERT with its `returning id` value, so the run reaches the push.
psql_token_variant() {
  cp "${BATS_TEST_DIRNAME?}/fixtures/push-template/psql-token" "${BATS_TEST_TMPDIR?}/bin/psql"
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/psql"
}

# running_stack — answer `docker compose ps` with both services, let the buildinfo
# probe answer (empty body, rc 0) and pretend the dev image exists, so a failing
# `docker image inspect` does not add its note to every expected output.
running_stack() {
  export STUB_COMPOSE_PS=$'db\ncoder'
  export STUB_COMPOSE_PS_RC=0
  export STUB_CURL_RC=0
  export STUB_DOCKER_INSPECT=1
}

# versions_answer <file> — feed the coder stub the table that `templates versions
# list --column id --column active` prints. The header row repeats the word
# ACTIVE, which is why the second row has to be spelled out too.
versions_answer() {
  printf '%s\n' 'ID                                    ACTIVE' "${ACTIVE_ID} Active" >"${1}"
  export STUB_CODER_OUT="${1}"
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

@test "push-template: skips when no service is running (empty compose ps)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS=''
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: docker compose up -d)" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: skips on a failed compose ps (docker access, exit 22)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS='coder'
  export STUB_COMPOSE_PS_RC=22
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "skipped: could not query the stack (coder) — this script needs docker access; run it with sudo, or add your user to the docker group" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: skips when only coder runs (no db means no push token)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS='coder'
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the db service is not running, so no push token can be minted (start the stack with: docker compose up -d)" ]
}

@test "push-template: an unanswered buildinfo probe is a hard failure (curl 22)" {
  root="$(fake_root push-template.sh)"
  running_stack
  export STUB_CURL_RC=22
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container ()"* ]]
  [ "$(stub_log_last timeout)" = "timeout 20 docker compose exec -T coder curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last docker)" = "docker compose exec -T coder curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last curl)" = "curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
}

@test "push-template: an unknown name is a user error and lists the known ones" {
  root="$(fake_root push-template.sh)"
  running_stack
  run --separate-stderr bash "${root}/scripts/push-template.sh" nope
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: unknown template 'nope' (known: docker-dev, docker-devcontainer)" ]
  # Names are validated before anything touches docker.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "push-template: --dry-run is not a flag here (arguments are names)" {
  root="$(fake_root push-template.sh)"
  running_stack
  run --separate-stderr bash "${root}/scripts/push-template.sh" --dry-run
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: unknown template '--dry-run' (known: docker-dev, docker-devcontainer)" ]
}

@test "push-template: a missing main.tf stops the run (never a silent skip)" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  rm -f "${root}/templates/docker-dev/main.tf" "${root}/templates/docker-devcontainer/main.tf"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: templates/docker-dev/main.tf not found (run this from the repo root)" ]
}

@test "push-template: a missing lockfile is a note, and the push still happens" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  rm -f "${root}/templates/docker-dev/.terraform.lock.hcl"
  run --separate-stderr bash "${root}/scripts/push-template.sh" docker-dev
  [ "${status}" -eq 0 ]
  [[ ${output} == *"note: templates/docker-dev/.terraform.lock.hcl is missing — regenerate it with:"* ]]
  [[ ${output} == *"      terraform -chdir=templates/docker-dev init -backend=false"* ]]
  [[ ${output} == *"template docker-dev pushed; active version ${ACTIVE_ID}"* ]]
}

@test "push-template: the full chain reaches an ACTIVE version for both templates" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"template docker-dev pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template docker-devcontainer pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template docker-dev: description set (chat-agent routing hint)"* ]]
  [[ ${output} == *"litellm_key not passed (LITELLM_MASTER_KEY in .env is empty or still the sample placeholder)"* ]]
  # Every CLI line the seams build, with the token kept out of argv: the
  # passthrough resolves `coder` to the stub, so argv is the whole proof.
  grep -Fq -- 'coder templates push docker-dev --directory - --yes --var image=evo-t1-dev:latest' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder templates versions list docker-dev --column id --column active' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder templates edit docker-dev --description' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder whoami' "${STUB_LOG}/docker.log"
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
}

@test "push-template: no ACTIVE row counts both templates as failed (exit 1)" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  printf '%s\n' 'ID                                    ACTIVE' "${ACTIVE_ID}" >"${BATS_TEST_TMPDIR}/versions.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"error: pushed docker-dev but it has no active version"* ]]
  [[ ${stderr} == *"error: pushed docker-devcontainer but it has no active version"* ]]
  [[ ${stderr} == *"2 of 2 template(s) did not reach an active version"* ]]
}

@test "push-template: a docker-exec that does not answer stops the whole run" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  export STUB_DOCKER_EXEC_RUN=0
  export STUB_DOCKER_EXEC_RC=1
  export STUB_DOCKER_EXEC_OUT='Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  # The buildinfo probe is the first docker exec, so a daemon that will not
  # answer reads as an unreachable API — and nothing is pushed.
  [[ ${stderr} == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock"* ]]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container"* ]]
  [[ "$(stub_log docker)" == *"compose exec"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: a name filter pushes once, in TEMPLATES_DEFAULT order" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" docker-devcontainer docker-dev docker-devcontainer
  [ "${status}" -eq 0 ]
  # Three names, two pushes, and docker-dev first despite being named second.
  [ "$(grep -Fc 'coder templates push' <<<"$(stub_log docker)")" -eq 2 ]
  [[ "$(grep -F 'coder templates push' <<<"$(stub_log docker)")" == *"templates push docker-dev --directory"*"templates push docker-devcontainer"* ]]
  [[ ${output} == *"template docker-dev pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template docker-devcontainer pushed; active version ${ACTIVE_ID}"* ]]
}

@test "push-template: the placeholder LiteLLM key is not passed and never printed" {
  root="$(fake_root push-template.sh 'LITELLM_MASTER_KEY=change-me-litellm-zzz9')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  if [ "${status}" -ne 0 ]; then
    printf 'status=%s\nstdout<<%s>>\nstderr<<%s>>\n' "${status}" "${output}" "${stderr}"
  fi
  [ "${status}" -eq 0 ]
  [[ ${output} == *"litellm_key not passed (LITELLM_MASTER_KEY in .env is empty or still the sample placeholder)"* ]]
  logs_absent 'change-me-litellm-zzz9' "${STUB_LOG}/docker.log"
  logs_absent 'change-me-litellm-zzz9' "${STUB_LOG}/coder.log"
}

@test "push-template: a real LiteLLM key travels as a --var and is never printed" {
  root="$(fake_root push-template.sh 'LITELLM_MASTER_KEY=sk-real-looking-0123456789abcdef')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"litellm_key passed from LITELLM_MASTER_KEY (value not shown)"* ]]
  [[ ${output} != *"sk-real-looking-0123456789abcdef"* ]]
  [[ ${stderr} != *"sk-real-looking-0123456789abcdef"* ]]
  # The key is a --var by design (visible in that one process's argv, inside the
  # container, for the length of the push). The session token never is.
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
}

# ── template-push.sh (moved from lib.bats; keep these assertions) ──────────

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/template-push.sh"
}

@test "template-push: template_push_one streams the dir and passes --var args through" {
  source_libs
  mkdir -p "${BATS_TEST_TMPDIR}/tpl/.terraform"
  printf '%s\n' 'resource "coder_script" "x" {}' > "${BATS_TEST_TMPDIR}/tpl/main.tf"
  printf 'junk' > "${BATS_TEST_TMPDIR}/tpl/.terraform/provider.cache"
  export CONTAINER_API_URL="http://coder:3002"
  export session_token="kid-secret"
  run --separate-stderr template_push_one tpl1 "${BATS_TEST_TMPDIR}/tpl" --var image=tag
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last docker)" == *"coder templates push tpl1 --directory - --yes --var image=tag"* ]]
  [[ "$(stub_log_last docker)" != *kid-secret* ]]
}

@test "template-push: template_verify_active reads the ACTIVE row and fails without one" {
  source_libs
  printf 'ID ACTIVE\ndeadbeef-1234-4abc-9999-aabbccddeeff Active\n' > "${BATS_TEST_TMPDIR}/out1.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/out1.txt"
  id="$(template_verify_active tpl1)"
  [ "${id}" = "deadbeef-1234-4abc-9999-aabbccddeeff" ]

  printf 'ID ACTIVE\nnone-active-here\n' > "${BATS_TEST_TMPDIR}/out2.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/out2.txt"
  rc=0
  template_verify_active tpl1 > "${BATS_TEST_TMPDIR}/got.txt" 2> "${BATS_TEST_TMPDIR}/got.err" || rc=$?
  [ "${rc}" -ne 0 ]
  grep -q "no active version" "${BATS_TEST_TMPDIR}/got.err"
}

@test "template-push: template_set_description skips empty text and pushes real text" {
  source_libs
  template_set_description tpl1 ""
  [ "$(stub_log_count coder)" -eq 0 ]
  template_set_description tpl1 "General dev workspace"
  [ "$(stub_log_last coder)" = "coder templates edit tpl1 --description General dev workspace" ]
}
