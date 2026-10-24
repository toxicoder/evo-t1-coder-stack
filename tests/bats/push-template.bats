#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## push-template.bats — hermetic coverage for scripts/push-template.sh
#
# Hermetic by construction: docker, timeout, curl, psql and coder resolve to the
# tests/bats/tool_stubs/ copies (use_stubs), and every run happens inside a
# throwaway root built by fake_root (its own .env, its own template tree), so
# neither the checkout's real .env nor a live compose stack is consulted. The
# docker stub's `exec` passthrough (STUB_DOCKER_EXEC_RUN=1, the default)
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
# Usage: bazelisk test //tests:bats_push_template_test   (from any cwd)
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
  # bazelisk run exports BUILD_WORKSPACE_DIRECTORY; a leaked value would make
  # fake_root resolve the real checkout instead of the throwaway tree.
  unset BUILD_WORKSPACE_DIRECTORY GITHUB_WORKSPACE REPO_ROOT || true
  REPO_ROOT="$(bats_canonical_repo_root)"
}

# fake_root <script> [env-line...] — print a throwaway repo root holding the
# script under test, scripts/lib/ (the seams it sources after its own repo-root
# cd), a private .env, and the template tree: both template dirs plus their
# sibling common/ dir with the seed payloads every push stages. main.tf has to
# exist in a dir for that template to be selectable, the lockfile keeps the
# "missing lockfile" note out of the way unless a test wants it, and the
# common/ files have to exist because template_push_one refuses to push
# without each of them.
fake_root() {
  local root="${BATS_TEST_TMPDIR?}/root" script="${1}"
  shift
  mkdir -p "${root}/scripts/lib" "${root}/templates/workspace" "${root}/templates/devcontainer"
  mkdir -p "${root}/templates/common"
  : >"${root}/docker-compose.yml"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"${root}/.env"
  else
    : >"${root}/.env"
  fi
  printf '%s\n' 'resource "coder_workspace_preset" "x" {' '  name = "x"' '  description = "short"' \
    >"${root}/templates/workspace/main.tf"
  printf '%s\n' 'resource "coder_workspace_preset" "y" {' '  name = "y"' '  description = "short"' \
    >"${root}/templates/devcontainer/main.tf"
  : >"${root}/templates/workspace/.terraform.lock.hcl"
  : >"${root}/templates/devcontainer/.terraform.lock.hcl"
  printf '%s\n' '# Role' >"${root}/templates/common/GROK_BUILD_AGENTS.md"
  printf '%s\n' '<svg/>' >"${root}/templates/common/vscode-alt.svg"
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

# running_stack — answer the daemon-wide `docker ps` probe with both services
# (the "service|container" shape stack_ps prints), let the buildinfo probe answer
# (empty body, rc 0) and pretend the dev image exists, so a failing
# `docker image inspect` does not add its note to every expected output.
running_stack() {
  export STUB_COMPOSE_PS=$'db|stack-db-1\ncoder|stack-coder-1'
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

@test "push-template: skips when no service is running (empty daemon ps body)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS=''
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: bazelisk run //scripts:prod-stack -- up)" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: skips on a failed daemon ps probe (docker access, exit 22)" {
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
  export STUB_COMPOSE_PS='coder|stack-coder-1'
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the db service is not running, so no push token can be minted (start the stack with: bazelisk run //scripts:prod-stack -- up)" ]
}

@test "push-template: an unanswered buildinfo probe is a hard failure (curl 22)" {
  root="$(fake_root push-template.sh)"
  running_stack
  export STUB_CURL_RC=22
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container ()"* ]]
  [ "$(stub_log_last timeout)" = "timeout -k 2 20 docker exec -i stack-coder-1 curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last docker)" = "docker exec -i stack-coder-1 curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last curl)" = "curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
}

@test "push-template: an unknown name is a user error and lists the known ones" {
  root="$(fake_root push-template.sh)"
  running_stack
  run --separate-stderr bash "${root}/scripts/push-template.sh" nope
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: unknown template 'nope' (known: workspace, devcontainer)" ]
  # Names are validated before anything touches docker.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "push-template: --dry-run is not a flag here (arguments are names)" {
  root="$(fake_root push-template.sh)"
  running_stack
  run --separate-stderr bash "${root}/scripts/push-template.sh" --dry-run
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: unknown template '--dry-run' (known: workspace, devcontainer)" ]
}

@test "push-template: a missing main.tf stops the run (never a silent skip)" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  rm -f "${root}/templates/workspace/main.tf" "${root}/templates/devcontainer/main.tf"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: templates/workspace/main.tf not found (run this from the repo root)" ]
}

@test "push-template: a tree without the seed payload pushes nothing" {
  # Same never-a-silent-skip rule one level deeper: the seed payload is not
  # read by the CLI but by the server AFTER the push, so a tree that loses
  # templates/common/GROK_BUILD_AGENTS.md must fail locally instead of
  # shipping a copy whose Terraform apply dies on the missing file().
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  rm -f "${root}/templates/common/GROK_BUILD_AGENTS.md"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"GROK_BUILD_AGENTS.md is missing"* ]]
  [[ ${stderr} == *"2 of 2 template(s) did not reach an active version"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: a too-large vscode-alt.svg fails before templates push" {
  # Coder v2.36 stores workspace_apps.icon as varchar(256). A 5 KB SVG used
  # to survive every local check and die inside the provisioner with
  # pq: value too long. The guard has to fire before the CLI runs.
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  printf 'x%.0s' {1..200} >"${root}/templates/common/vscode-alt.svg"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"varchar(256)"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: a missing lockfile is a note, and the push still happens" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  rm -f "${root}/templates/workspace/.terraform.lock.hcl"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"note: templates/workspace/.terraform.lock.hcl is missing — regenerate it with:"* ]]
  [[ ${output} == *"      terraform -chdir=templates/workspace init -backend=false"* ]]
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
}

@test "push-template: the full chain reaches an ACTIVE version for both templates" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template devcontainer pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template workspace: description set (chat-agent routing hint)"* ]]
  [[ ${output} == *"autostop default set to disabled"* ]]
  [[ ${output} == *"litellm_key not passed (LITELLM_MASTER_KEY in .env is empty or still the sample placeholder)"* ]]
  # Every CLI line the seams build, with the token kept out of argv: the
  # passthrough resolves `coder` to the stub, so argv is the whole proof.
  grep -Fq -- 'coder templates push workspace --directory - --yes --var image=evo-t1-dev:latest' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var github_auth_id=github' "${STUB_LOG}/docker.log"
  [[ ${output} == *"github_auth_id=github"* ]]
  grep -Fq -- 'coder templates versions list workspace --column id --column active' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder templates edit workspace --description' "${STUB_LOG}/docker.log"
  # Autostop is pinned off on both templates, so a new workspace starts with no deadline.
  grep -Fq -- 'coder templates edit workspace --default-ttl 0 --activity-bump 0' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder templates edit devcontainer --default-ttl 0 --activity-bump 0' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder whoami' "${STUB_LOG}/docker.log"
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
  # The whole chain addresses the daemon directly: not one call may resolve a
  # compose project from the cwd (the class of bug this shape exists to kill).
  logs_absent 'docker compose' "${STUB_LOG}/docker.log"
}

@test "push-template: coder.env CODER_EXTERNAL_AUTH_0_ID is forwarded as github_auth_id" {
  root="$(fake_root push-template.sh)"
  printf '%s\n' 'CODER_EXTERNAL_AUTH_0_ID=primary-github' 'CODER_EXTERNAL_AUTH_0_CLIENT_SECRET=s3cret' >"${root}/coder.env"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"github_auth_id=primary-github"* ]]
  [[ ${output} != *"s3cret"* ]]
  grep -Fq -- '--var github_auth_id=primary-github' "${STUB_LOG}/docker.log"
  logs_absent 's3cret' "${STUB_LOG}"/*.log
}

@test "push-template: an empty CODER_EXTERNAL_AUTH_0_ID still declares github" {
  root="$(fake_root push-template.sh)"
  printf '%s\n' 'CODER_EXTERNAL_AUTH_0_ID=' >"${root}/coder.env"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  grep -Fq -- '--var github_auth_id=github' "${STUB_LOG}/docker.log"
}

@test "push-template: a garbage CODER_EXTERNAL_AUTH_0_ID fails before templates push" {
  root="$(fake_root push-template.sh)"
  printf '%s\n' 'CODER_EXTERNAL_AUTH_0_ID=not a valid id' >"${root}/coder.env"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"not a Coder provider id"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: no ACTIVE row counts both templates as failed (exit 1)" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  printf '%s\n' 'ID                                    ACTIVE' "${ACTIVE_ID}" >"${BATS_TEST_TMPDIR}/versions.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"error: pushed workspace but it has no active version"* ]]
  [[ ${stderr} == *"error: pushed devcontainer but it has no active version"* ]]
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
  # The stack probe answers (running_stack), so the first refused call is the
  # buildinfo exec: a daemon that will not answer the in-container calls reads
  # as an unreachable API — and nothing is pushed.
  [[ ${stderr} == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock"* ]]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container"* ]]
  [[ "$(stub_log docker)" == *"exec -i"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: a name filter pushes once, in TEMPLATES_DEFAULT order" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" devcontainer workspace devcontainer
  [ "${status}" -eq 0 ]
  # Three names, two pushes, and workspace first despite being named second.
  [ "$(grep -Fc 'coder templates push' <<<"$(stub_log docker)")" -eq 2 ]
  [[ "$(grep -F 'coder templates push' <<<"$(stub_log docker)")" == *"templates push workspace --directory"*"templates push devcontainer"* ]]
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template devcontainer pushed; active version ${ACTIVE_ID}"* ]]
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

@test "push-template: resolve_repo_root only accepts a directory holding docker-compose.yml" {
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" resolve_repo_root

  local nowhere="${BATS_TEST_TMPDIR}/nowhere"
  local proven="${BATS_TEST_TMPDIR}/proven"
  mkdir -p "${nowhere}" "${proven}/scripts"
  printf 'x\n' >"${proven}/docker-compose.yml"

  REPO_ROOT=""
  GITHUB_WORKSPACE=""
  BUILD_WORKSPACE_DIRECTORY=""
  SELF_DIR="${nowhere}"
  cd "${nowhere}"

  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 5 ]
  [[ ${stderr} == *"unresolvable repo root"* ]]
  [[ ${stderr} == *"need docker-compose.yml"* ]]

  cd "${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${proven}" ]

  cd "${nowhere}"
  REPO_ROOT="${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${proven}" ]

  SELF_DIR="${proven}/scripts"
  REPO_ROOT=""
  cd "${nowhere}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${proven}/scripts/.." ]
}

@test "push-template: resolve_repo_root prefers the script tree over PWD" {
  # bazelisk test sets cwd to a runfiles tree that also has docker-compose.yml.
  # Whole-script tests launch bash /fake-root/scripts/push-template.sh from
  # there and must still resolve the fake root, not the harness cwd.
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" resolve_repo_root
  script_tree="$(make_scratch)/script-tree"
  harness_cwd="$(make_scratch)/harness-cwd"
  mkdir -p "${script_tree}/scripts" "${harness_cwd}"
  printf 'x\n' >"${script_tree}/docker-compose.yml"
  printf 'x\n' >"${harness_cwd}/docker-compose.yml"
  REPO_ROOT=""
  unset GITHUB_WORKSPACE
  BUILD_WORKSPACE_DIRECTORY=""
  SELF_DIR="${script_tree}/scripts"
  cd "${harness_cwd}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${script_tree}/scripts/.." ]
}

@test "push-template: resolve_repo_root prefers BUILD_WORKSPACE_DIRECTORY over PWD" {
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" resolve_repo_root
  workspace="$(make_scratch)/workspace"
  runfiles="$(make_scratch)/runfiles"
  mkdir -p "${workspace}" "${runfiles}/scripts"
  printf 'x\n' >"${workspace}/docker-compose.yml"
  printf 'x\n' >"${runfiles}/docker-compose.yml"
  REPO_ROOT=""
  unset GITHUB_WORKSPACE
  BUILD_WORKSPACE_DIRECTORY="${workspace}"
  cd "${runfiles}"
  SELF_DIR="${runfiles}/scripts"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${workspace}" ]
}

@test "push-template: BUILD_WORKSPACE_DIRECTORY .env beats the script copy" {
  # bazelisk run launches the runfiles copy of the script; the live .env
  # lives in the checkout named by BUILD_WORKSPACE_DIRECTORY.
  root="$(fake_root push-template.sh 'LITELLM_MASTER_KEY=change-me-from-runfiles')"
  checkout="$(make_scratch)/checkout"
  mkdir -p "${checkout}/scripts/lib" "${checkout}/templates/workspace" \
    "${checkout}/templates/devcontainer" "${checkout}/templates/common"
  : >"${checkout}/docker-compose.yml"
  printf '%s\n' 'LITELLM_MASTER_KEY=sk-from-checkout-0123456789abcdef' >"${checkout}/.env"
  cp -R "${root}/templates/." "${checkout}/templates/"
  : >"${checkout}/templates/workspace/.terraform.lock.hcl"
  : >"${checkout}/templates/devcontainer/.terraform.lock.hcl"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  export BUILD_WORKSPACE_DIRECTORY="${checkout}"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"litellm_key passed from LITELLM_MASTER_KEY (value not shown)"* ]]
  [[ ${output} != *"sk-from-checkout-0123456789abcdef"* ]]
  grep -Fq -- '--var litellm_key=sk-from-checkout-0123456789abcdef' "${STUB_LOG}/docker.log"
}

@test "push-template: SEARCH_MCP=false passes --var search_mcp=false for both templates" {
  root="$(fake_root push-template.sh 'SEARCH_MCP=false')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"search_mcp=false passed from SEARCH_MCP"* ]]
  grep -Fq -- '--var search_mcp=false' "${STUB_LOG}/docker.log"
  # One vars array serves both pushes, so the off switch cannot reach one template
  # only; the port still travels with it because searxng_url is always passed.
  [ "$(grep -cF -- '--var search_mcp=false' "${STUB_LOG}/docker.log")" -eq 2 ]
  grep -Fq -- '--var searxng_url=http://host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: SEARCH_MCP=true or unset passes no search_mcp var and keeps the default port" {
  # Default-ON polarity: the template declares search_mcp = true, so anything other
  # than an explicit false must push nothing at all.
  root="$(fake_root push-template.sh 'SEARCH_MCP=true')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"search_mcp"* ]]
  # A push did happen, so the absence below proves the script passed nothing.
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'search_mcp' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var searxng_url=http://host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: STACK_SEARCH_PORT=18181 pushes the remapped search port" {
  # The dev stack may publish SearXNG somewhere other than 8181; the pushed URL has
  # to name that port or every workspace dials a port nothing listens on.
  root="$(fake_root push-template.sh 'STACK_SEARCH_PORT=18181')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"searxng_url=http://host.docker.internal:18181 passed from STACK_SEARCH_PORT in .env"* ]]
  grep -Fq -- '--var searxng_url=http://host.docker.internal:18181' "${STUB_LOG}/docker.log"
  logs_absent 'host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: a blank or non-numeric STACK_SEARCH_PORT falls back to 8181" {
  root="$(fake_root push-template.sh 'STACK_SEARCH_PORT=')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"searxng_url=http://host.docker.internal:8181 passed from the default"* ]]
  grep -Fq -- '--var searxng_url=http://host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: CONTEXT7_MCP=true passes --var context7_mcp=true for both templates" {
  root="$(fake_root push-template.sh 'CONTEXT7_MCP=true')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"context7_mcp passed from CONTEXT7_MCP"* ]]
  grep -Fq -- '--var context7_mcp=true' "${STUB_LOG}/docker.log"
  # One vars array serves both pushes, so the cached context7 server cannot be
  # turned on for one template only.
  [ "$(grep -cF -- '--var context7_mcp=true' "${STUB_LOG}/docker.log")" -eq 2 ]
}

@test "push-template: CONTEXT7_MCP=false passes no context7_mcp var and keeps the default" {
  # Default-OFF polarity: the templates declare context7_mcp = false, so only an
  # explicit true has to say anything; false (like unset) leaves the default
  # untouched rather than pushing a redundant off switch.
  root="$(fake_root push-template.sh 'CONTEXT7_MCP=false')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"context7_mcp"* ]]
  # A push did happen, so the absence below proves the script passed nothing.
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'context7_mcp' "${STUB_LOG}/docker.log"
}

@test "push-template: a Context7 key travels as a --var and is never printed" {
  root="$(fake_root push-template.sh 'CONTEXT7_API_KEY=ctx7-secret-test-0123456789abcdef')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"context7_api_key passed from CONTEXT7_API_KEY (value not shown)"* ]]
  [[ ${output} != *"ctx7-secret-test-0123456789abcdef"* ]]
  [[ ${stderr} != *"ctx7-secret-test-0123456789abcdef"* ]]
  # The key is a --var by design (visible in that one process's argv, inside the
  # container, for the length of the push). The session token never is.
  grep -Fq -- '--var context7_api_key=ctx7-secret-test-0123456789abcdef' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
}

@test "push-template: an empty Context7 key is not passed and never printed" {
  # A blank line in .env must not override the empty template default, and the
  # whole context7_api_key var must stay out of the push.
  root="$(fake_root push-template.sh 'CONTEXT7_API_KEY=')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"context7_api_key"* ]]
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'context7_api_key' "${STUB_LOG}/docker.log"
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
  mkdir -p "${BATS_TEST_TMPDIR}/tpl/.terraform" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "x" {}' > "${BATS_TEST_TMPDIR}/tpl/main.tf"
  printf 'junk' > "${BATS_TEST_TMPDIR}/tpl/.terraform/provider.cache"
  printf '%s\n' '# Role' > "${BATS_TEST_TMPDIR}/common/GROK_BUILD_AGENTS.md"
  printf '%s\n' '<svg/>' > "${BATS_TEST_TMPDIR}/common/vscode-alt.svg"
  export CONTAINER_API_URL="http://coder:3002"
  export session_token="kid-secret"
  export CODER_CONTAINER=stack-coder-1
  run --separate-stderr template_push_one tpl1 "${BATS_TEST_TMPDIR}/tpl" --var image=tag
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last docker)" == *"coder templates push tpl1 --directory - --yes --var image=tag"* ]]
  [[ "$(stub_log_last docker)" != *kid-secret* ]]
}

@test "template-push: an unresolved CODER_CONTAINER refuses before anything runs" {
  source_libs
  # A run that never resolved a container (daemon down, wrong service name)
  # must fail locally with a named cause — never stream a tar at nothing.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl-nopc" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "w" {}' > "${BATS_TEST_TMPDIR}/tpl-nopc/main.tf"
  printf '%s\n' '# Role' > "${BATS_TEST_TMPDIR}/common/GROK_BUILD_AGENTS.md"
  printf '%s\n' '<svg/>' > "${BATS_TEST_TMPDIR}/common/vscode-alt.svg"
  export CONTAINER_API_URL="http://coder:3002"
  export session_token="kid-secret"
  run --separate-stderr template_push_one tpl4 "${BATS_TEST_TMPDIR}/tpl-nopc"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"no coder container was resolved (CODER_CONTAINER is empty) - nothing was pushed"* ]]
  [ -z "$(stub_log docker)" ]
  [ -z "$(stub_log coder)" ]
}

@test "template-push: the seed payloads ride inside the pushed tar" {
  source_libs
  # The server-side Terraform reads GROK_BUILD_AGENTS.md (file(), into the
  # startup script) and vscode-alt.svg (filebase64(), into the editor icon)
  # from inside the pushed copy, so the staging must drop both common copies
  # into the tar and .terraform/ must stay out. The sink DOCKER_BIN stands in
  # for `docker exec -i`: it drains stdin into a file instead of
  # exec'ing the coder stub, which is how the tar stream becomes inspectable.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl/.terraform" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "x" {}' > "${BATS_TEST_TMPDIR}/tpl/main.tf"
  printf 'junk' > "${BATS_TEST_TMPDIR}/tpl/.terraform/provider.cache"
  printf '%s\n' '# Role' > "${BATS_TEST_TMPDIR}/common/GROK_BUILD_AGENTS.md"
  printf '%s\n' '<svg/>' > "${BATS_TEST_TMPDIR}/common/vscode-alt.svg"
  printf '%s\n' '#!/usr/bin/env bash' 'cat > "${STUB_LOG}/push.tar"' > "${BATS_TEST_TMPDIR}/bin/tar-sink"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/tar-sink"
  export DOCKER_BIN=tar-sink
  export CODER_CONTAINER=stack-coder-1
  template_push_one tpl1 "${BATS_TEST_TMPDIR}/tpl"
  if [ ! -f "${STUB_LOG}/push.tar" ]; then
    printf 'FAIL: no tar stream reached the sink\n' >&2
    return 1
  fi
  tar -tf "${STUB_LOG}/push.tar" > "${BATS_TEST_TMPDIR}/members.txt"
  grep -Fxq './main.tf' "${BATS_TEST_TMPDIR}/members.txt"
  grep -Fxq './GROK_BUILD_AGENTS.md' "${BATS_TEST_TMPDIR}/members.txt"
  grep -Fxq './vscode-alt.svg' "${BATS_TEST_TMPDIR}/members.txt"
  if grep -qF '.terraform' "${BATS_TEST_TMPDIR}/members.txt"; then
    printf 'leak: .terraform reached the pushed tar\n' >&2
    return 1
  fi
}

@test "template-push: runfiles symlinks land as regular files in the tar" {
  source_libs
  # bazelisk run materializes templates/** as symlinks into the execroot.
  # Coder unpacks the archive in an empty workdir and does not follow those
  # host paths, so a stored symlink plans as "No configuration files".
  mkdir -p "${BATS_TEST_TMPDIR}/real" "${BATS_TEST_TMPDIR}/runfiles/tpl" \
    "${BATS_TEST_TMPDIR}/runfiles/common"
  printf '%s\n' 'resource "coder_script" "x" {}' >"${BATS_TEST_TMPDIR}/real/main.tf"
  printf '%s\n' 'startup-body' >"${BATS_TEST_TMPDIR}/real/startup.sh.tftpl"
  printf '%s\n' '# Role' >"${BATS_TEST_TMPDIR}/real/GROK_BUILD_AGENTS.md"
  printf '%s\n' '<svg/>' >"${BATS_TEST_TMPDIR}/real/vscode-alt.svg"
  ln -s "${BATS_TEST_TMPDIR}/real/main.tf" "${BATS_TEST_TMPDIR}/runfiles/tpl/main.tf"
  ln -s "${BATS_TEST_TMPDIR}/real/startup.sh.tftpl" "${BATS_TEST_TMPDIR}/runfiles/tpl/startup.sh.tftpl"
  ln -s "${BATS_TEST_TMPDIR}/real/GROK_BUILD_AGENTS.md" "${BATS_TEST_TMPDIR}/runfiles/common/GROK_BUILD_AGENTS.md"
  ln -s "${BATS_TEST_TMPDIR}/real/vscode-alt.svg" "${BATS_TEST_TMPDIR}/runfiles/common/vscode-alt.svg"
  printf '%s\n' '#!/usr/bin/env bash' 'cat > "${STUB_LOG}/push.tar"' >"${BATS_TEST_TMPDIR}/bin/tar-sink"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/tar-sink"
  export DOCKER_BIN=tar-sink
  export CODER_CONTAINER=stack-coder-1
  template_push_one tpl-runfiles "${BATS_TEST_TMPDIR}/runfiles/tpl"
  if [ ! -f "${STUB_LOG}/push.tar" ]; then
    printf 'FAIL: no tar stream reached the sink\n' >&2
    return 1
  fi
  tar -tvf "${STUB_LOG}/push.tar" >"${BATS_TEST_TMPDIR}/listing.txt"
  if grep -E 'main\.tf|startup\.sh\.tftpl|GROK_BUILD_AGENTS\.md|vscode-alt\.svg' "${BATS_TEST_TMPDIR}/listing.txt" | grep -q ' -> '; then
    printf 'FAIL: archive stored a symlink instead of file contents:\n%s\n' "$(cat "${BATS_TEST_TMPDIR}/listing.txt")" >&2
    return 1
  fi
  mkdir -p "${BATS_TEST_TMPDIR}/extracted"
  tar -xf "${STUB_LOG}/push.tar" -C "${BATS_TEST_TMPDIR}/extracted"
  [ -f "${BATS_TEST_TMPDIR}/extracted/main.tf" ]
  [ ! -L "${BATS_TEST_TMPDIR}/extracted/main.tf" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/main.tf")" = 'resource "coder_script" "x" {}' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/startup.sh.tftpl")" = 'startup-body' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/GROK_BUILD_AGENTS.md")" = '# Role' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/vscode-alt.svg")" = '<svg/>' ]
}

@test "template-push: a tree without the seed payload is refused before the CLI runs" {
  source_libs
  # Without the seed the server-side Terraform would die on main.tf's file()
  # reference anyway; the point of the guard is that it fails locally, loudly,
  # and before the CLI runs, so the operator sees the missing file by name.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl-noseed"
  printf '%s\n' 'resource "coder_script" "y" {}' > "${BATS_TEST_TMPDIR}/tpl-noseed/main.tf"
  export CODER_CONTAINER=stack-coder-1
  run --separate-stderr template_push_one tpl2 "${BATS_TEST_TMPDIR}/tpl-noseed"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"common/GROK_BUILD_AGENTS.md is missing"* ]]
  [[ ${stderr} == *"common/vscode-alt.svg is missing"* ]]
  [ -z "$(stub_log docker)" ]
  [ -z "$(stub_log coder)" ]
}

@test "template-push: a half-filled common dir names only the payload that is gone" {
  source_libs
  # The guard lists the payloads, not the directory: with the seed text there
  # and the icon gone, only the icon may be named - and the run must still
  # refuse before the CLI runs.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl-nosvg" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "z" {}' > "${BATS_TEST_TMPDIR}/tpl-nosvg/main.tf"
  printf '%s\n' '# Role' > "${BATS_TEST_TMPDIR}/common/GROK_BUILD_AGENTS.md"
  export CODER_CONTAINER=stack-coder-1
  run --separate-stderr template_push_one tpl3 "${BATS_TEST_TMPDIR}/tpl-nosvg"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"common/vscode-alt.svg is missing"* ]]
  [[ ${stderr} != *"GROK_BUILD_AGENTS.md is missing"* ]]
  [ -z "$(stub_log docker)" ]
  [ -z "$(stub_log coder)" ]
}

@test "template-push: template_verify_active reads the ACTIVE row and fails without one" {
  source_libs
  export CODER_CONTAINER=stack-coder-1
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
  export CODER_CONTAINER=stack-coder-1
  template_set_description tpl1 ""
  [ "$(stub_log_count coder)" -eq 0 ]
  template_set_description tpl1 "General dev workspace"
  [ "$(stub_log_last coder)" = "coder templates edit tpl1 --description General dev workspace" ]
}

@test "template-push: template_set_autostop_off pins the default TTL and the activity bump" {
  source_libs
  export CODER_CONTAINER=stack-coder-1
  # Both halves of the pair travel on one `templates edit`: the default TTL is what
  # decides whether a new workspace starts with an autostop deadline, and the activity
  # bump only ever extends one.
  template_set_autostop_off tpl1
  [ "$(stub_log_last coder)" = "coder templates edit tpl1 --default-ttl 0 --activity-bump 0" ]
}
