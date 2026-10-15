#!/usr/bin/env bats
#
# ## github-auth.bats — the workspace GitHub credential doctor and one-line auth.
#
# Pins the seam added after the first desktop->workspace PR nearly shipped a
# PR-creating session onto a credential that cannot write: git consults the
# env token, then gh, then the external-auth mint, and an unscoped credential
# authenticates while still being denied (403 Resource not accessible). The
# docker/curl/timeout/coder/gh stubs keep this hermetic — probe_workspace,
# running_workspaces, auth_workspace, and main all run against stubs only.
#
# Usage: bats tests/bats/github-auth.bats
# Safety: reads scripts/github-auth.sh and the stub bin; writes nothing outside
# the per-test scratch.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/github-auth.sh"
  [[ -f "${SCRIPT}" ]] || skip "scripts/github-auth.sh not reachable from ${REPO_ROOT}"
  use_stubs docker curl timeout coder gh
  unset GH_TOKEN GITHUB_TOKEN
}

@test "check: lists every labeled workspace and never invents a credential" {
  printf 'coder-alice-ws1\ncoder-alice-ws2\n' >"${BATS_TEST_TMPDIR}/ps.txt"
  STUB_COMPOSE_PS="${BATS_TEST_TMPDIR}/ps.txt" run bash "${SCRIPT}" check
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "coder-alice-ws1: NO GitHub credential"* ]]
  [[ "${lines[1]}" == "coder-alice-ws2: NO GitHub credential"* ]]
}

@test "check: no containers means nothing to check, not a failure" {
  STUB_COMPOSE_PS="" run bash "${SCRIPT}" check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no running workspace containers"* ]]
}

@test "check: a dead docker daemon is a failure with a pointer" {
  STUB_COMPOSE_PS="coder-alice-ws1" STUB_COMPOSE_PS_RC=1 run bash "${SCRIPT}" check
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"docker daemon"* ]]
}

@test "check: the env token is reported by source and never printed" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_OUT='{"full_name":"alx/notes"}' \
    run bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source: env token"* ]]
  [[ "${output}" == *"readable through it"* ]]
  [[ "${output}" != *"SECRETVAL-do-not-leak"* ]]
  run stub_log curl
  [[ "${output}" == *"api.github.com/repos/alx/notes"* ]]
}

@test "check: a connected-but-unscoped credential is named, not swallowed" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  STUB_COMPOSE_PS="coder-alice-ws1" \
    STUB_CURL_OUT='{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com"}' \
    run bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"NOT GRANTED on alx/notes"* ]]
  [[ "${output}" == *"scripts/github-auth.sh auth"* ]]
}

@test "check: an offline probe says offline, never a false pass" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_OUT="" STUB_CURL_RC=22 \
    run bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no useful answer"* ]]
}

@test "check: the probe sends the header through curl --config -, never through curl argv" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  STUB_COMPOSE_PS="coder-alice-ws1" STUB_DOCKER_EXEC_RUN=1 \
    STUB_CURL_OUT='{"full_name":"alx/notes"}' \
    run bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"readable through it"* ]]
  assert_match "curl gets its header from stdin" '--config -' "$(stub_log curl)"
  assert_not_match "no token in curl argv" 'SECRETVAL' "$(stub_log curl)"
  assert_eq "one probe per container" "1" "$(stub_log_count curl)"
}

@test "auth: an empty piped token is refused without touching docker" {
  STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    run bash -c "printf '\n' | bash '${SCRIPT}' auth coder-alice-ws1 -"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"empty PAT"* ]]
  run stub_log docker
  [[ "${output}" != *"auth login"* ]]
}

@test "auth: a token in argv is refused, and nothing the container runs can see it" {
  STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    run bash -c "bash '${SCRIPT}' auth coder-alice-ws1 ghp_SECRETVAL-do-not-leak"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"never an argument"* ]]
  [[ "${output}" == *"auth coder-alice-ws1 -"* ]]
  assert_not_match "no token in the reply" 'SECRETVAL' "${output}"
  assert_eq "no docker call at all" "0" "$(stub_log_count docker)"
  assert_not_match "no token in the docker argv log" 'SECRETVAL' "$(stub_log docker)"
}

@test "auth: a token after the - is refused too (three arguments install nothing)" {
  STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    run bash -c "bash '${SCRIPT}' auth coder-alice-ws1 - ghp_SECRETVAL-do-not-leak"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"never an argument"* ]]
  assert_eq "no docker call at all" "0" "$(stub_log_count docker)"
}

@test "shape: every function block the docs promise is still there" {
  for fn in running_workspaces probe_workspace auth_workspace main; do
    grep -Fq "${fn}()" "${SCRIPT}" || {
      echo "github-auth.sh lost its ${fn} function" >&2
      return 1
    }
  done
}

@test "auth: a piped token goes to gh on stdin and never to stdout" {
  STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    run bash -c "printf 'ghp_SECRETVAL-do-not-leak\n' | bash '${SCRIPT}' auth coder-alice-ws1 -"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gh credential installed"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  run stub_log docker
  [[ "${output}" == *"auth login"* ]]
}

@test "auth: a bare container name still reads the piped token, and keeps it out of argv" {
  STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    run bash -c "printf 'ghp_SECRETVAL-do-not-leak\n' | bash '${SCRIPT}' auth coder-alice-ws1"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gh credential installed"* ]]
  assert_not_match "no token in the reply" 'SECRETVAL' "${output}"
  assert_match "gh still got the token on stdin" 'auth login' "$(stub_log docker)"
  assert_not_match "no token in the docker argv log" 'SECRETVAL' "$(stub_log docker)"
  assert_eq "one docker call" "1" "$(stub_log_count docker)"
}
