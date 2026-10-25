#!/usr/bin/env bats
#
# ## github-auth.bats - the workspace GitHub credential doctor and one-line auth.
#
# Pins the seam added after the first desktop->workspace PR nearly shipped a
# PR-creating session onto a credential that cannot write, and then after a
# second session pasted a working PAT into the gh auth store and still got the
# push 403: git consults the env pair first, then the gh auth store, then the
# external-auth mint, and a credential that READS can still be refused every
# WRITE call. A public repo answers api.github.com /repos with 200 for any
# authenticated caller, so the read probe could print a false pass; the write
# probe keys on the HTTP status of the receive-pack ref advertisement instead
# (200-with-refs is PUSH-READY, 403 REFUSED-GRANT, 404 NOT VISIBLE, 401
# REJECTED) and answers it per credential, so a store copy that holds the same
# token as the env pair is named once and a store copy that holds a different
# one is answered beside it. STUB_CURL_STATUS plus STUB_CURL_OUT drive those
# verdicts through the shared curl stub. The docker/curl/timeout/coder/gh
# stubs keep this hermetic: running_workspaces, credential_probe,
# normalize_repo_path, slot_name, probe_self, probe_workspace, auth_workspace,
# and main all run against stubs only.
#
# Usage: bazelisk test //tests:bats_github_auth_test   (from any cwd)
# Safety: reads scripts/github-auth.sh and the stub bin; writes nothing outside
# the per-test scratch.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

# The write-probe body that a write-capable credential gets back from
# github.com (the literal advertisement start), and the body that proves the
# probe's discriminator is the status, not the wording.
AD_BODY="001f# service=git-receive-pack 00001234deadbeef HEAD agent=git/2.43.0"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/github-auth.sh"
  [[ -f "${SCRIPT}" ]] || skip "scripts/github-auth.sh not reachable from ${REPO_ROOT}"
  use_stubs docker curl timeout coder gh
  # Host-mode pin: on a dev box this env variable defines "inside a
  # workspace", where check must run SELF mode with zero docker calls.
  # Host-mode tests must therefore not inherit it; SELF tests set it.
  unset GH_TOKEN GITHUB_TOKEN CODER_GITHUB_AUTH_ID
  unset CODER_WORKSPACE_ID EVO_T1_DEVCONTAINER
}

@test "check: lists every labeled workspace and never invents a credential" {
  printf 'coder-alice-ws1\ncoder-alice-ws2\n' >"${BATS_TEST_TMPDIR}/ps.txt"
  STUB_COMPOSE_PS="${BATS_TEST_TMPDIR}/ps.txt" run bash "${SCRIPT}" check
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c 'NO GitHub credential' || true)" -eq 2 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep 'NO GitHub credential' || true)" == "coder-alice-ws1: NO GitHub credential"*"coder-alice-ws2: NO GitHub credential"* ]]
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
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=200 \
    STUB_CURL_OUT="${AD_BODY}" \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source: env token"* ]]
  [[ "${output}" == *"PUSH-READY"* ]]
  [[ "${output}" != *"SECRETVAL-do-not-leak"* ]]
  run stub_log curl
  [[ "${output}" == *"github.com/alx/notes.git/info/refs?service=git-receive-pack"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
}

@test "check: a read-only credential is named REFUSED-GRANT, with the grant fix pointer" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"REFUSED-GRANT on alx/notes"* ]]
  [[ "${output}" == *"Repository access"* ]]
  [[ "${output}" == *"https://github.com/apps/coder/installations/new"* ]]
  [[ "${output}" == *"Install GitHub App"* ]]
  [[ "${output}" == *"bazelisk run //scripts:github-auth -- auth coder-alice-ws1 -"* ]]
  [[ "${output}" != *"SECRETVAL-do-not-leak"* ]]
}

@test "check: a 403 body that reads differently still lands in REFUSED-GRANT" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com"}' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"REFUSED-GRANT"* ]]
}

@test "check: 404 means NOT VISIBLE, so clone and push would both fail" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=404 \
    STUB_CURL_OUT='Not Found' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"NOT VISIBLE"* ]]
  [[ "${output}" == *"clone and push would both fail"* ]]
}

@test "check: 401 means REJECTED, with the re-mint and reconnect hint" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=401 \
    STUB_CURL_OUT='Bad credentials' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"REJECTED"* ]]
  [[ "${output}" == *"re-mint"* ]]
  [[ "${output}" == *"GitHub reauth"* ]]
  [[ "${output}" == *"Coder UI"* ]]
}

@test "check: an offline probe says offline, never a false pass" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no useful answer"* ]]
  [[ "${output}" != *"PUSH-READY"* ]]
}

@test "check: a 200 whose body does not advertise refs is not a write pass" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=200 STUB_CURL_OUT='{}' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no useful answer"* ]]
  [[ "${output}" != *"PUSH-READY"* ]]
}

@test "check: the probe sends the credential through curl --config -, never through curl argv" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_DOCKER_EXEC_RUN=1 STUB_COMPOSE_PS="coder-alice-ws1" \
    STUB_CURL_STATUS=200 STUB_CURL_OUT="${AD_BODY}" \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PUSH-READY"* ]]
  assert_match "curl gets its credential from stdin" '--config -' "$(stub_log curl)"
  assert_match "probe hits the receive-pack endpoint" 'info/refs\?service=git-receive-pack' "$(stub_log curl)"
  assert_not_match "no token in curl argv" 'SECRETVAL' "$(stub_log curl)"
  assert_eq "one probe per container" "1" "$(stub_log_count curl)"
}

@test "check: inside a workspace, check probes this environment and never calls docker" {
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run env STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' | head -n 1)" == "self: "* ]]
  [[ "${output}" == *"REFUSED-GRANT"* ]]
  [[ "${output}" == *"Repository access"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
  assert_eq "one probe, run locally" "1" "$(stub_log_count curl)"
}

@test "check: SELF mode names the gh credential source and keeps token bytes unprinted" {
  export CODER_WORKSPACE_ID=ws-test
  run env STUB_GH_TOKEN='ghu_SECRETVAL-do-not-leak' STUB_CURL_STATUS=200 \
    STUB_CURL_OUT="${AD_BODY}" \
    bash "${SCRIPT}" check https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"self: credential present (source: gh stored login) and"* ]]
  [[ "${output}" == *"PUSH-READY"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
  assert_not_match "no token in curl argv" 'SECRETVAL' "$(stub_log curl)"
}

@test "check: SELF mode without a repo URL prints the local credential line and probes nothing" {
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run bash "${SCRIPT}" check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"self: credential present"* ]]
  [[ "${output}" == *"pass the repo URL to check its grants"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
  assert_eq "no probe without a repo URL" "0" "$(stub_log_count curl)"
}

@test "check: inside a workspace a named container argument is refused with a host pointer" {
  export CODER_WORKSPACE_ID=ws-test
  run bash "${SCRIPT}" check coder-bob-ws1 https://github.com/alx/notes
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"this is a workspace shell"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
}

@test "in_self_env: a contributor devcontainer is SELF without CODER_WORKSPACE_ID" {
  load_shell_function "${SCRIPT}" in_self_env
  unset CODER_WORKSPACE_ID EVO_T1_DEVCONTAINER
  run in_self_env
  [ "${status}" -ne 0 ]
  export CODER_WORKSPACE_ID=ws-test
  unset EVO_T1_DEVCONTAINER
  run in_self_env
  [ "${status}" -eq 0 ]
  unset CODER_WORKSPACE_ID
  export EVO_T1_DEVCONTAINER=1
  run in_self_env
  [ "${status}" -eq 0 ]
  export EVO_T1_DEVCONTAINER=0
  run in_self_env
  [ "${status}" -ne 0 ]
}

@test "check: EVO_T1_DEVCONTAINER=1 probes this environment and never calls docker" {
  export GH_TOKEN="SECRETVAL-do-not-leak" EVO_T1_DEVCONTAINER=1
  unset CODER_WORKSPACE_ID
  run env STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' | head -n 1)" == "self: "* ]]
  [[ "${output}" == *"REFUSED-GRANT"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
  assert_eq "one probe, run locally" "1" "$(stub_log_count curl)"
}

@test "check: EVO_T1_DEVCONTAINER=1 refuses a named container with a host pointer" {
  export EVO_T1_DEVCONTAINER=1
  unset CODER_WORKSPACE_ID
  run bash "${SCRIPT}" check coder-bob-ws1 https://github.com/alx/notes
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"this is a workspace shell"* ]]
  [[ "${output}" == *"EVO_T1_DEVCONTAINER"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
}

@test "check: a minted token uses github when CODER_GITHUB_AUTH_ID is unset" {
  unset GH_TOKEN GITHUB_TOKEN CODER_GITHUB_AUTH_ID
  STUB_COMPOSE_PS="coder-alice-ws1" STUB_CODER_OUT="minted-token-secret" \
    run bash "${SCRIPT}" check coder-alice-ws1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source: Coder external-auth minted token"* ]]
  [[ "${output}" != *"minted-token-secret"* ]]
  assert_match "default id is github" 'access-token github' "$(stub_log coder)"
}

@test "check: CODER_GITHUB_AUTH_ID overrides the minted provider id" {
  unset GH_TOKEN GITHUB_TOKEN
  export CODER_GITHUB_AUTH_ID=primary-github
  STUB_COMPOSE_PS="coder-alice-ws1" STUB_CODER_OUT="minted-token-secret" \
    run bash "${SCRIPT}" check coder-alice-ws1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source: Coder external-auth minted token"* ]]
  assert_match "custom id" 'access-token primary-github' "$(stub_log coder)"
  assert_not_match "does not also try github first" 'access-token github' "$(stub_log coder)"
}

@test "check: the chain answers every credential that could cover the repo" {
  # The trap this exists for: a pasted PAT in the gh auth store sits behind
  # the env pair, so answering only the first slot found hid the one
  # credential that might have been able to write.
  export GH_TOKEN="ghu_APPTOKEN" CODER_WORKSPACE_ID=ws-test
  run env STUB_GH_TOKEN='ghp_PATTOKEN' STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^self:' || true)" -eq 2 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' || true)" == "self: credential present (source: env token (GITHUB_TOKEN/GH_TOKEN)) but REFUSED-GRANT"*"self: credential present (source: gh stored login) [shadowed:"* ]]
  [[ "${output}" == *"GH_TOKEN= GITHUB_TOKEN= <command>"* ]]
  [[ "${output}" == *"classic personal access token"* ]]
  [[ "${output}" != *"APPTOKEN"* ]]
  [[ "${output}" != *"PATTOKEN"* ]]
  assert_eq "one probe per credential" "2" "$(stub_log_count curl)"
}

@test "check: one token held twice is one credential, answered once" {
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run env STUB_GH_TOKEN='SECRETVAL-do-not-leak' STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^self:' || true)" -eq 1 ]
  [[ "${output}" == *"REFUSED-GRANT"* ]]
  assert_eq "the store copy is not a second credential" "1" "$(stub_log_count curl)"
}

@test "check: --source names a slot the env pair outranks and says so" {
  export GH_TOKEN="ghu_APPTOKEN" CODER_WORKSPACE_ID=ws-test
  run env STUB_GH_TOKEN='ghp_PATTOKEN' STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check --source=gh https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' | head -n 1)" == "self: credential present (source: gh stored login) [shadowed:"* ]]
  [[ "${output}" == *"[shadowed: the env pair outranks this slot"* ]]
  assert_eq "one probe, of the named slot" "1" "$(stub_log_count curl)"
}

@test "check: --source=mint mints the token instead of reading the store" {
  # The minted token equals the env pair for a moment (a fresh start, or right
  # after gh_token_refresh), and that is the case where trusting the store
  # copy would be a different question, so the named slot still has to answer.
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run env STUB_CODER_OUT='minted-token-secret' STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check --source=mint https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"self: credential present (source: Coder external-auth minted token)"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  [[ "${output}" != *"minted-token-secret"* ]]
  assert_match "the mint was minted, not read" 'access-token github' "$(stub_log coder)"
}

@test "check: --source refuses a slot that does not exist" {
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run bash "${SCRIPT}" check --source=docker-key https://github.com/alx/notes
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--source takes chain (default), env, gh or mint"* ]]
  assert_eq "nothing was probed" "0" "$(stub_log_count curl)"
}

@test "check: a pasted browser URL still names the repository, slash and .git or not" {
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run env STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check https://github.com/alx/notes/
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"REFUSED-GRANT on alx/notes"* ]]
  run stub_log curl
  assert_match "the probe path keeps no trailing slash" 'github.com/alx/notes.git/info/refs' "${output}"
  assert_not_match "no doubled .git" 'notes/.git' "${output}"
}

@test "check: a path below the repository is refused, never probed" {
  # github.com serves no ref advertisement under a tree or blob path, so a
  # probe of one answers about an address that does not exist.
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run bash "${SCRIPT}" check https://github.com/alx/notes/tree/main/README.md
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"A path below owner/repo names no repository"* ]]
  assert_eq "nothing was probed" "0" "$(stub_log_count curl)"
}

@test "check: the scp-style and ssh:// remotes normalize to the same probe" {
  export GH_TOKEN="SECRETVAL-do-not-leak" CODER_WORKSPACE_ID=ws-test
  run env STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check git@github.com:alx/notes.git
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"REFUSED-GRANT on alx/notes "* ]]
  assert_eq "one probe" "1" "$(stub_log_count curl)"
}

@test "shape: every function block the docs promise is still there" {
  for fn in running_workspaces credential_probe normalize_repo_path probe_self probe_workspace auth_workspace in_self_env main; do
    grep -Fq "${fn}()" "${SCRIPT}" || {
      echo "github-auth.sh lost its ${fn} function" >&2
      return 1
    }
  done
  # The probe body (and with it slot_name) lives in the extracted payload file
  # that credential_probe cats; the entry keeps only the shell around it.
  grep -Fq 'slot_name()' "${REPO_ROOT}/scripts/lib/probes/github-auth.sh" || {
    echo "scripts/lib/probes/github-auth.sh lost its slot_name function" >&2
    return 1
  }
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

@test "auth: a piped token goes to gh on stdin and never to stdout" {
  # The STUB_DOCKER_EXEC_* pair travels as `env` arguments, not as `run`
  # prefix assignments: a prefix on a function call has no portable export
  # contract, and if it leaks the docker stub replays the in-container chain
  # on the HOST, where a CI runner's real docker/gh decide the verdict.
  run env STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    bash -c "printf 'ghp_SECRETVAL-do-not-leak\n' | bash '${SCRIPT}' auth coder-alice-ws1 -"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gh credential installed"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
  run stub_log docker
  [[ "${output}" == *"auth login"* ]]
  [[ "${output}" == *"unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN"* ]]
}

@test "auth: a bare container name still reads the piped token, and keeps it out of argv" {
  # Same `env`-pinned canned mode as the - form above: the outcome may not
  # depend on whether this runner can reach a real docker daemon or gh.
  run env STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_RC=0 \
    bash -c "printf 'ghp_SECRETVAL-do-not-leak\n' | bash '${SCRIPT}' auth coder-alice-ws1"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gh credential installed"* ]]
  assert_not_match "no token in the reply" 'SECRETVAL' "${output}"
  assert_match "gh still got the token on stdin" 'auth login' "$(stub_log docker)"
  assert_match "env pair cleared before login" 'unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN' "$(stub_log docker)"
  assert_not_match "no token in the docker argv log" 'SECRETVAL' "$(stub_log docker)"
  assert_eq "one docker call" "1" "$(stub_log_count docker)"
}
