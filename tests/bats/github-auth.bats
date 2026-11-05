#!/usr/bin/env bats
#
# ## github-auth.bats - the workspace GitHub credential doctor and one-line auth.
#
# Pins the seam added after the first desktop->workspace PR nearly shipped a
# PR-creating session onto a credential that cannot write, and then after a
# second session pasted a working PAT into the gh auth store and still got the
# push 403. Both had the same root: Coder injects GH_TOKEN/GITHUB_TOKEN when
# the workspace STARTS, that pair expires about an hour later, git never reads
# the variable itself (it asks its credential helper, and the stack's helper is
# `!gh auth git-credential`, which ECHOES the pair), so git keeps sending a
# dead token while the gh auth store beside it stays healthy and git never
# reaches it. So the doctor does not ask the environment, it asks git: it runs
# the configured helper the way git runs it, takes the password that would go
# on the wire, probes THAT credential against <repo>.git/info/refs?service=git-
# receive-pack, and answers `push would WORK` / `push would FAIL` keyed to the
# credential git would really send. The verdict lines, not the word PUSH-READY
# anywhere in the report, are what check counts and what it exits on: a
# credential that is healthy but shadowed is a finding, never an ok. A public
# repo answers api.github.com /repos with 200 for any authenticated caller, so
# the read probe could print a false pass; the write probe keys on the HTTP
# status of the receive-pack advertisement instead (200-with-refs is PUSH-READY,
# 403 REFUSED-GRANT, 404 NOT VISIBLE, 401 REJECTED) and answers it per
# credential, so a store copy that holds the same token as the env pair is
# named once and a store copy that holds a different one is answered beside it.
# STUB_CURL_STATUS plus STUB_CURL_OUT drive those verdicts through the shared
# curl stub. `fix` is the repair: it mints through Coder, writes the gh auth
# store, and points git's github.com and gist.github.com helper at the store
# through a form that clears the injected pair first, then re-proves itself.
#
# The docker/curl/timeout/coder/gh stubs keep this hermetic: running_workspaces,
# credential_probe, credential_fix, normalize_repo_path, slot_name, probe_self,
# probe_workspace, repair_self, repair_workspace, auth_workspace, split_flags,
# report_push_verdict and main all run against stubs only. setup() also pins
# HOME, GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM to per-test scratch: the read
# probe asks `git config --get-all credential.https://github.com.helper` and
# the repair writes credential keys into a git config file, so a suite that
# inherited the developer's ~/.gitconfig would both read a real helper and
# rewrite a real one.
#
# Usage: bazelisk test //tests:bats_github_auth_test   (from any cwd)
# Safety: reads scripts/github-auth.sh and the stub bin; writes nothing outside
# the per-test scratch (the repair writes only the scratch git config and the
# scratch gh store).

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
COMMON=""

# The write-probe body that a write-capable credential gets back from
# github.com (the literal advertisement start), and the body that proves the
# probe's discriminator is the status, not the wording.
AD_BODY="001f# service=git-receive-pack 00001234deadbeef HEAD agent=git/2.43.0"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/github-auth.sh"
  COMMON="${REPO_ROOT}/scripts/lib/common.sh"
  [[ -f "${SCRIPT}" ]] || skip "scripts/github-auth.sh not reachable from ${REPO_ROOT}"
  use_stubs docker curl timeout coder gh
  # Hermetic git. The read probe asks git which credential helper answers for
  # github.com, and the repair installs one with `git config --file`, so both
  # have to resolve against scratch: without this a run reads the developer's
  # real helper (which echoes the real token) and the repair rewrites the
  # developer's real ~/.gitconfig.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"
  export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_ASKPASS EVO_T1_GITCONFIG EVO_T1_FIX_MODE
  # Host-mode pin: on a dev box this env variable defines "inside a
  # workspace", where check must run SELF mode with zero docker calls.
  # Host-mode tests must therefore not inherit it; SELF tests set it.
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN CODER_GITHUB_AUTH_ID
  unset CODER_WORKSPACE_ID EVO_T1_DEVCONTAINER
}

# use_gh_shim <stored-token> - put a gh that models the one behaviour this CLI
# exists to repair ahead of the gh stub, point its store at scratch, and seed
# it. That behaviour: `gh auth git-credential` ECHOES GH_TOKEN/GITHUB_TOKEN
# while either stands and only then reads the auth store. The shared gh stub
# answers `auth token` and nothing else, so the helper the repair installs
# would answer nothing and the shadowing could never be shown. The store is
# $SHIM_GH_STORE, and argv is recorded where the gh stub records it, so
# stub_log gh still reads. Sets GH_SHIM to the shim path; it must not run in a
# command substitution, because the PATH it prepends has to stick.
use_gh_shim() {
  local tok
  tok="${1:-}"
  GH_SHIM="${BATS_TEST_TMPDIR}/ghshim/gh"
  mkdir -p "${BATS_TEST_TMPDIR}/ghshim"
  cat >"${GH_SHIM}" <<'SHIM'
#!/bin/sh
set -u
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "gh $*" >>"${STUB_LOG}/gh.log"; fi
store="${SHIM_GH_STORE:-/no-such-gh-store}"
pair="${GITHUB_TOKEN:-}${GH_TOKEN:-}"
tok=""
if [ -n "${pair}" ]; then
  tok="${GITHUB_TOKEN:-${GH_TOKEN}}"
elif [ -s "${store}" ]; then
  tok="$(cat "${store}")"
fi
case "$*" in
  'auth token') [ -n "${tok}" ] && printf '%s\n' "${tok}" ;;
  'auth git-credential get')
    [ -n "${tok}" ] || exit 0
    printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' "${tok}"
    ;;
  *'auth login'*'--with-token'*) cat >"${store}" ;;
esac
exit 0
SHIM
  chmod 755 "${GH_SHIM}"
  export SHIM_GH_STORE="${BATS_TEST_TMPDIR}/gh-store"
  if [ -n "${tok}" ]; then printf '%s\n' "${tok}" >"${SHIM_GH_STORE}"; fi
  PATH="${BATS_TEST_TMPDIR}/ghshim:${PATH}"
  export PATH
}

# installed_helper - print the non-empty git credential helper for github.com
# out of the scratch git config, the same way the probe reads it.
installed_helper() {
  git config --file "${EVO_T1_GITCONFIG}" --get-all credential.https://github.com.helper |
    grep -v '^[[:space:]]*$' | tail -n 1
}

# ask_git_the_helper_question <helper-value> - run one helper value the way git
# runs a `!`-prefixed helper: through sh -c, with `get` appended and the lookup
# on stdin. Prints the password line only.
ask_git_the_helper_question() {
  local hlp="$1"
  printf 'protocol=https\nhost=github.com\n\n' | sh -c "${hlp#!} get" 2>/dev/null |
    sed -n 's/^password=//p' | head -n 1
}

@test "check: lists every labeled workspace and never invents a credential" {
  printf 'coder-alice-ws1\ncoder-alice-ws2\n' >"${BATS_TEST_TMPDIR}/ps.txt"
  STUB_COMPOSE_PS="${BATS_TEST_TMPDIR}/ps.txt" run bash "${SCRIPT}" check
  # Nothing to send is a push that would fail, so the run must not exit 0.
  [ "${status}" -eq 1 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c 'NO GitHub credential' || true)" -eq 2 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep 'NO GitHub credential' || true)" == "coder-alice-ws1: NO GitHub credential"*"coder-alice-ws2: NO GitHub credential"* ]]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c 'push would FAIL (no credential to send)' || true)" -eq 2 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^error: ' || true)" -eq 2 ]
  [[ "${output}" == *"summary: 0 ok, 0 warnings, 2 failed"* ]]
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
  # A credential that cannot write this repo is a push that would fail.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
  [[ "${output}" == *"Repository access"* ]]
  [[ "${output}" == *"https://github.com/apps/coder/installations/new"* ]]
  [[ "${output}" == *"Install GitHub App"* ]]
  [[ "${output}" == *"bazelisk run //scripts:github-auth -- auth coder-alice-ws1 -"* ]]
  [[ "${output}" != *"SECRETVAL-do-not-leak"* ]]
  # The repository is still the thing that was asked about, on the wire.
  run stub_log curl
  [[ "${output}" == *"github.com/alx/notes.git/info/refs?service=git-receive-pack"* ]]
  [[ "${output}" != *"SECRETVAL"* ]]
}

@test "check: a 403 body that reads differently still lands in REFUSED-GRANT" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com"}' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
}

@test "check: 404 means NOT VISIBLE, so clone and push would both fail" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=404 \
    STUB_CURL_OUT='Not Found' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"but NOT VISIBLE"* ]]
  [[ "${output}" == *"clone and push would both fail"* ]]
}

@test "check: 401 means REJECTED, with the re-mint and reconnect hint" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=401 \
    STUB_CURL_OUT='Bad credentials' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"but REJECTED"* ]]
  [[ "${output}" == *"re-mint"* ]]
  [[ "${output}" == *"GitHub reauth"* ]]
  [[ "${output}" == *"Coder UI"* ]]
}

@test "check: an offline probe says offline, never a false pass" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  # An unproven push is not a pass either: check still exits 1.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no useful answer"* ]]
  [[ "${output}" != *"PUSH-READY"* ]]
  [[ "${output}" == *"push would FAIL"* ]]
}

@test "check: a 200 whose body does not advertise refs is not a write pass" {
  export GH_TOKEN="SECRETVAL-do-not-leak"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CURL_STATUS=200 STUB_CURL_OUT='{}' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no useful answer"* ]]
  [[ "${output}" != *"PUSH-READY"* ]]
  [[ "${output}" == *"push would FAIL"* ]]
  [[ "${output}" != *"ok: "* ]]
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
  [ "${status}" -eq 1 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' | head -n 1)" == "self: "* ]]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
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
  # The store is the only credential here, so it is the one git would send.
  [[ "${output}" == *"self: git would send this credential (source: gh stored login)"* ]]
  [[ "${output}" == *"PUSH-READY"* ]]
  [[ "${output}" == *"self: push would WORK"* ]]
  [[ "${output}" == *"ok: this environment can push"* ]]
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
  [ "${status}" -eq 1 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' | head -n 1)" == "self: "* ]]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
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
  # The env pair is what git would send, and it cannot write: that is a failure.
  [ "${status}" -eq 1 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^self: \(git would send\|credential present\)' || true)" -eq 2 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' || true)" == "self: git would send this credential (source: env token (GITHUB_TOKEN/GH_TOKEN)) but REFUSED-GRANT"*"self: credential present (source: gh stored login) [shadowed:"* ]]
  [[ "${output}" == *"env -u GH_TOKEN -u GITHUB_TOKEN <command>"* ]]
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
  [ "${status}" -eq 1 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^self: \(git would send\|credential present\)' || true)" -eq 1 ]
  [[ "${output}" == *"source: env token (GITHUB_TOKEN/GH_TOKEN), gh stored login)"* ]]
  [[ "${output}" == *"the same token the gh stored login holds"* ]]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
  assert_eq "the store copy is not a second credential" "1" "$(stub_log_count curl)"
}

@test "check: --source probes only the named slot, whatever the environment holds" {
  # The named-slot lens asks one slot one question. The env pair is present
  # and would be what a real push sends; the point of this case is that the
  # probe still answers for the slot it was pointed at, and for nothing else.
  export GH_TOKEN="ghu_APPTOKEN" CODER_WORKSPACE_ID=ws-test
  run env STUB_GH_TOKEN='ghp_PATTOKEN' STUB_CURL_STATUS=403 \
    STUB_CURL_OUT='Permission to alx/notes.git denied to alx.' \
    bash "${SCRIPT}" check --source=gh https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^self:' | head -n 1)" == "self: "*"(source: gh stored login)"* ]]
  [[ "${output}" != *"env token (GITHUB_TOKEN/GH_TOKEN)"* ]]
  [[ "${output}" == *"classic personal access token"* ]]
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
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"self: "*"(source: Coder external-auth minted token)"* ]]
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
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
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
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
  assert_eq "one probe" "1" "$(stub_log_count curl)"
  run stub_log curl
  assert_match "the same repository path" 'github.com/alx/notes.git/info/refs\?service=git-receive-pack' "${output}"
}

@test "shape: every function block the docs promise is still there" {
  for fn in running_workspaces credential_probe normalize_repo_path probe_self probe_workspace auth_workspace in_self_env main; do
    grep -Fq "${fn}()" "${SCRIPT}" || {
      echo "github-auth.sh lost its ${fn} function" >&2
      return 1
    }
  done
  # The new CLI-side blocks the header spec promises.
  for fn in credential_fix report_push_verdict split_flags repair_self repair_workspace; do
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

@test "probe: the write probe sends the credential the way the git endpoint reads it" {
  # Measured against github.com: the receive-pack advertisement answers 200 for Basic
  # auth with any non-empty username, and 401 for the Authorization: Bearer scheme that
  # api.github.com and gh accept. A probe "modernized" onto a bearer header would print
  # every push-capable credential as REJECTED and send the operator chasing a grant that
  # is fine, so the transport is pinned here rather than left to the reader.
  local probe="${REPO_ROOT}/scripts/lib/probes/github-auth.sh"
  grep -Fq -- 'user = "x-access-token:' "${probe}" || {
    echo "the write probe no longer sends the token as Basic auth" >&2
    return 1
  }
  grep -Fq -- '--config -' "${probe}" || {
    echo "the write probe no longer hands curl the credential on stdin, where ps cannot see it" >&2
    return 1
  }
  if grep -Eq 'Authorization:[[:space:]]*Bearer' "${probe}"; then
    echo "the write probe must not carry a bearer header: the git endpoint refuses that scheme" >&2
    return 1
  fi
}

@test "credential_fix: the CLI prints the shipped repair probe verbatim" {
  # The far end must run exactly the file this repo tests, so the CLI may not
  # wrap, rewrite or quote it on the way out.
  load_shell_function "${SCRIPT}" credential_fix
  local printed="${BATS_TEST_TMPDIR}/fix-printed.sh"
  # credential_fix resolves the payload beside the entry script, which the
  # extracted body cannot know without the caller.
  SELF_DIR="${REPO_ROOT}/scripts"
  credential_fix >"${printed}"
  cmp -s "${printed}" "${REPO_ROOT}/scripts/lib/probes/github-auth-fix.sh" ||
    fail "credential_fix no longer prints scripts/lib/probes/github-auth-fix.sh verbatim"
  assert_contains_file "the repair names the helper it installs" "${printed}" \
    'credential\.https://\$\{host\}\.helper'
}

@test "report_push_verdict: a shadowed credential answered PUSH-READY is an error, never an ok" {
  # The headline regression. Coder injects GH_TOKEN/GITHUB_TOKEN at workspace
  # start; the pair expires about an hour later; the stack's helper is
  # `!gh auth git-credential`, which echoes that pair, so the credential git
  # actually sends is dead while the store copy beside it answers PUSH-READY.
  # Counting PUSH-READY anywhere in the report printed `ok: this environment
  # can push` and sent agents hunting a repository grant for an hour. Only the
  # machine-checkable push line may decide, so this output must count a failure
  # and print no ok.
  load_shell_function "${COMMON}" log
  load_shell_function "${COMMON}" ok
  load_shell_function "${COMMON}" warn
  load_shell_function "${COMMON}" err
  load_shell_function "${COMMON}" fail_item
  load_shell_function "${SCRIPT}" report_push_verdict
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  SUMMARY_FAIL_ITEMS=""
  CHECK_RC=0
  local out="${BATS_TEST_TMPDIR}/probe-out.txt"
  cat >"${out}" <<'PROBE'
coder-alice-ws1: git would send this credential (source: env token (GITHUB_TOKEN/GH_TOKEN)) but REJECTED (github.com refused the credential itself, as it refuses an expired or revoked token): re-mint it with coder external-auth access-token github from a workspace shell, or click GitHub reauth on the workspace in the Coder UI
coder-alice-ws1: credential present (source: gh stored login) [shadowed: the credential above outranks this slot, so git and gh consult that token first; env -u GH_TOKEN -u GITHUB_TOKEN <command> is how you make them use this slot instead] and alx/notes answered PUSH-READY (the receive-pack advertisement came back through this classic personal access token, so a push would negotiate)
coder-alice-ws1: push would FAIL now (the credential git consults answered REJECTED; run bazelisk run //scripts:github-auth -- fix coder-alice-ws1)
PROBE
  local stdout="${BATS_TEST_TMPDIR}/verdict-out.txt"
  local stderr="${BATS_TEST_TMPDIR}/verdict-err.txt"
  report_push_verdict "$(cat "${out}")" "coder-alice-ws1" \
    "bazelisk run //scripts:github-auth -- fix coder-alice-ws1" >"${stdout}" 2>"${stderr}"
  assert_eq "the healthy-but-shadowed credential counts one failure" "1" "${SUMMARY_FAIL}"
  assert_eq "and no success is counted" "0" "${SUMMARY_OK}"
  assert_eq "and check is told to exit non-zero" "1" "${CHECK_RC}"
  assert_contains_file "the finding is printed as an error" "${stderr}" '^error: coder-alice-ws1 cannot push'
  assert_contains_file "the error names the repair" "${stderr}" 'run bazelisk run //scripts:github-auth -- fix coder-alice-ws1'
  assert_not_match "no ok line is printed" '^ok: ' "$(cat "${stdout}")"
}

@test "report_push_verdict: WORK counts one ok, a missing verdict counts a failure, a missing repo URL only warns" {
  load_shell_function "${COMMON}" log
  load_shell_function "${COMMON}" ok
  load_shell_function "${COMMON}" warn
  load_shell_function "${COMMON}" err
  load_shell_function "${COMMON}" fail_item
  load_shell_function "${SCRIPT}" report_push_verdict
  local stdout="${BATS_TEST_TMPDIR}/v-out.txt" stderr="${BATS_TEST_TMPDIR}/v-err.txt"

  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  CHECK_RC=0
  report_push_verdict "ws1: push would WORK (the credential git consults writes alx/notes)" "ws1" "fix ws1" \
    >"${stdout}" 2>"${stderr}"
  assert_eq "a WORK verdict counts one ok" "1" "${SUMMARY_OK}"
  assert_eq "and no failure" "0" "${SUMMARY_FAIL}"
  assert_eq "and the run may exit 0" "0" "${CHECK_RC}"
  assert_contains_file "the ok names who can push" "${stdout}" '^ok: ws1 can push'

  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  CHECK_RC=0
  report_push_verdict "ws1: something else entirely" "ws1" "fix ws1" >"${stdout}" 2>"${stderr}"
  assert_eq "a report with no push line is not a pass" "1" "${SUMMARY_FAIL}"
  assert_eq "and it fails the run" "1" "${CHECK_RC}"
  assert_contains_file "and says so" "${stderr}" 'the probe returned no push verdict'

  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  CHECK_RC=0
  report_push_verdict "ws1: push cannot be answered (pass a repo URL to ask the write question)" "ws1" "fix ws1" \
    >"${stdout}" 2>"${stderr}"
  assert_eq "an unasked question warns, it does not fail" "1" "${SUMMARY_WARN}"
  assert_eq "and the run still exits 0" "0" "${CHECK_RC}"
  assert_eq "with nothing counted failed" "0" "${SUMMARY_FAIL}"
}

@test "split_flags: a --source= flag after the positional still selects the slot" {
  # The flag loop used to stop at the first non-flag, so this exact order read
  # no flag at all and blamed the operator for a repository it had not looked
  # at, while the docs always showed the flag last.
  export GH_TOKEN="ghu_APPTOKEN"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_GH_TOKEN='ghp_PATTOKEN' \
    STUB_CURL_STATUS=403 STUB_CURL_OUT='denied' \
    bash "${SCRIPT}" check coder-alice-ws1 https://github.com/alx/notes --source=env
  [ "${status}" -eq 1 ]
  assert_eq "only the env slot was probed" "1" "$(stub_log_count curl)"
  [[ "${output}" == *"(source: env token (GITHUB_TOKEN/GH_TOKEN))"* ]]
  [[ "${output}" != *"gh stored login"* ]]
  [[ "${output}" != *"unknown flag"* ]]
}

@test "split_flags: the flag before the positional selects the same slot" {
  export GH_TOKEN="ghu_APPTOKEN"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_GH_TOKEN='ghp_PATTOKEN' \
    STUB_CURL_STATUS=403 STUB_CURL_OUT='denied' \
    bash "${SCRIPT}" check --source=env coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  assert_eq "the same single probe as the flag-last order" "1" "$(stub_log_count curl)"
  [[ "${output}" == *"(source: env token (GITHUB_TOKEN/GH_TOKEN))"* ]]
}

@test "split_flags: an unknown flag dies with the usage message wherever it sits" {
  # Before and after the positional: a flag that is silently swallowed becomes
  # a positional, and a positional is a container or a repo URL.
  run env STUB_COMPOSE_PS="coder-alice-ws1" bash "${SCRIPT}" check coder-alice-ws1 --recursive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown flag --recursive"* ]]
  [[ "${output}" == *"bazelisk run //scripts:github-auth -- check [container] [repo-url] [--source=<slot>]"* ]]
  assert_eq "nothing was probed" "0" "$(stub_log_count curl)"

  run env STUB_COMPOSE_PS="coder-alice-ws1" bash "${SCRIPT}" check --recursive coder-alice-ws1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown flag --recursive"* ]]
  assert_eq "still nothing was probed" "0" "$(stub_log_count curl)"
}

@test "help: the first line is the header title, not the shellcheck directive" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_eq "the title line leads" \
    "# ## github-auth.sh - workspace GitHub credential doctor and one-line auth (entry point)" \
    "${lines[0]}"
  [[ "${output}" != *"shellcheck"* ]]
  # The whole header, not a fixed line count: both argument orders and both
  # modes have to survive the sed.
  [[ "${output}" == *"bazelisk run //scripts:github-auth -- fix [repo-url]"* ]]
  [[ "${output}" == *"[container] [repo-url] [--source=<slot>]"* ]]
  [[ "${output}" == *"HANDOFF"* ]]
}

@test "repair_self: mint_token mints, the store is written, and the re-probe prints ok" {
  # The whole repair, end to end, starting from the state that broke pushes:
  # the helper git runs is the plain `!gh auth git-credential`, which echoes
  # the expired pair Coder injected at start, while the store beside it is
  # healthy. fix must mint through Coder (never trust the pair), write the
  # store, replace the helper, and prove the push in the same run.
  use_gh_shim 'ghp_STOREHEALTHY'
  export CODER_WORKSPACE_ID=ws-test EVO_T1_GITCONFIG="${HOME}/.gitconfig"
  export GH_TOKEN="ghu_EXPIREDBOGUS" GITHUB_TOKEN="ghu_EXPIREDBOGUS"
  # The pre-repair helper: git's own answer is the dead injected pair.
  git config --file "${EVO_T1_GITCONFIG}" --replace-all credential.https://github.com.helper ''
  git config --file "${EVO_T1_GITCONFIG}" --add credential.https://github.com.helper "${GH_SHIM} auth git-credential"
  run env STUB_CODER_OUT='ghu_FRESHMINT' STUB_CURL_STATUS=200 STUB_CURL_OUT="${AD_BODY}" \
    bash "${SCRIPT}" fix https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  assert_match "the mint went through Coder, not the pair" 'access-token github' "$(stub_log coder)"
  assert_match "the store got the minted token" \
    'auth login --hostname github.com --git-protocol https --with-token' "$(stub_log gh)"
  [[ "${output}" == *"self: writing the token minted from Coder external-auth into the gh auth store"* ]]
  [[ "${output}" == *"self: git now reads the gh auth store for github.com, whatever GH_TOKEN holds"* ]]
  # The proof, not the promise: the re-probe ran and the credential git now
  # consults is the helper plus the store, not the pair.
  [[ "${output}" == *"self: git would send this credential (source: git credential helper, gh stored login)"* ]]
  [[ "${output}" == *"self: push would WORK (the credential git consults writes alx/notes)"* ]]
  [[ "${output}" == *"ok: this environment can push"* ]]
  [[ "${output}" == *"summary: 1 ok, 0 warnings, 0 failed"* ]]
  [[ "${output}" != *"EXPIREDBOGUS"* ]]
  [[ "${output}" != *"FRESHMINT"* ]]
  # The exact helper string, in the file, for both hosts.
  local want
  want="!env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN ${GH_SHIM} auth git-credential"
  assert_eq "github.com got exactly the env-proof helper" "${want}" "$(installed_helper)"
  assert_eq "gist.github.com got it too" "${want}" \
    "$(git config --file "${EVO_T1_GITCONFIG}" --get-all credential.https://gist.github.com.helper |
      grep -v '^[[:space:]]*$' | tail -n 1)"
  assert_contains_file "the store holds the minted token" "${SHIM_GH_STORE}" 'ghu_FRESHMINT'
}

@test "install_helper: a bogus GH_TOKEN cannot shadow the credential fix installs" {
  # The root cause and its repair in one case. The plain helper gh writes
  # echoes the pair no matter what the store holds; the helper the repair
  # installs clears the pair first, so git reads the store.
  use_gh_shim 'ghp_STOREHEALTHY'
  export CODER_WORKSPACE_ID=ws-test EVO_T1_GITCONFIG="${HOME}/.gitconfig"
  export GH_TOKEN="ghu_EXPIREDBOGUS" GITHUB_TOKEN="ghu_EXPIREDBOGUS"
  assert_eq "the plain helper is the thing that echoes the pair" "ghu_EXPIREDBOGUS" \
    "$(GH_TOKEN=ghu_EXPIREDBOGUS GITHUB_TOKEN=ghu_EXPIREDBOGUS ask_git_the_helper_question "${GH_SHIM} auth git-credential")"
  run env STUB_CODER_OUT='ghu_FRESHMINT' STUB_CURL_STATUS=200 STUB_CURL_OUT="${AD_BODY}" \
    bash "${SCRIPT}" fix https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  local installed
  installed="$(installed_helper)"
  assert_match "the installed helper clears the pair" '^!env -u GH_TOKEN -u GITHUB_TOKEN' "${installed}"
  # Ask the installed helper the question git asks it, with the pair poisoned
  # the way a long-running workspace has it.
  assert_eq "the store token answers, not the poisoned pair" "ghu_FRESHMINT" \
    "$(GH_TOKEN=ghu_POISONED GITHUB_TOKEN=ghu_POISONED ask_git_the_helper_question "${installed}")"
}

@test "repair_self: HANDOFF when nothing can be minted and the store is empty" {
  # No mint and no store is not a repairable state, and a git config written on
  # the way to that answer would read as fixed.
  use_gh_shim ''
  export CODER_WORKSPACE_ID=ws-test EVO_T1_GITCONFIG="${HOME}/.gitconfig"
  unset GH_TOKEN GITHUB_TOKEN
  run env STUB_CODER_RC=1 bash "${SCRIPT}" fix https://github.com/alx/notes
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"self: HANDOFF"* ]]
  [[ "${output}" == *"click GitHub reauth"* ]]
  [[ "${output}" == *"https://github.com/apps/coder/installations/new"* ]]
  [[ "${output}" == *"error: this environment: the repair needs a human - see the HANDOFF line above"* ]]
  [[ "${output}" == *"summary: 0 ok, 0 warnings, 1 failed"* ]]
  [[ "${output}" != *"repaired with"* ]]
  [[ "${output}" != *"push would"* ]]
  assert_file_not_exists "no credential helper was written" "${EVO_T1_GITCONFIG}"
  assert_file_not_exists "and no credential was stored" "${SHIM_GH_STORE}"
  assert_eq "nothing was probed against github.com" "0" "$(stub_log_count curl)"
}

@test "install_helper: a second repair leaves one helper entry and store_token rewrites nothing" {
  # Idempotent by contract: an operator (or an agent) that runs fix twice must
  # not stack helpers into git's list or churn the gh store on every push.
  use_gh_shim 'ghp_STOREHEALTHY'
  export CODER_WORKSPACE_ID=ws-test EVO_T1_GITCONFIG="${HOME}/.gitconfig"
  export GH_TOKEN="ghu_EXPIREDBOGUS"
  local i
  for i in 1 2; do
    run env STUB_CODER_OUT='ghu_FRESHMINT' STUB_CURL_STATUS=200 STUB_CURL_OUT="${AD_BODY}" \
      bash "${SCRIPT}" fix https://github.com/alx/notes
    [ "${status}" -eq 0 ]
  done
  assert_eq "one non-empty helper entry survives two repairs" "1" \
    "$(git config --file "${EVO_T1_GITCONFIG}" --get-all credential.https://github.com.helper |
      grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')"
  assert_eq "the store was written once, with the minted token" "1" \
    "$(stub_log gh | grep -c 'auth login' || true)"
  assert_eq "and the store still holds exactly that token" "ghu_FRESHMINT" "$(cat "${SHIM_GH_STORE}")"
  [[ "${output}" == *"self: credential helper already ignores the agent env pair"* ]]
  [[ "${output}" == *"ok: this environment can push"* ]]
}

@test "repair_workspace: on the host, fix repairs the ONE named container" {
  use_gh_shim ''
  export EVO_T1_GITCONFIG="${HOME}/.gitconfig"
  run env STUB_COMPOSE_PS="coder-alice-ws1" STUB_CODER_OUT='ghu_FRESHMINT' \
    STUB_CURL_STATUS=200 STUB_CURL_OUT="${AD_BODY}" \
    bash "${SCRIPT}" fix coder-alice-ws1 https://github.com/alx/notes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"-> repairing coder-alice-ws1"* ]]
  [[ "${output}" == *"coder-alice-ws1: writing the token minted from Coder external-auth into the gh auth store"* ]]
  [[ "${output}" == *"ok: coder-alice-ws1 can push"* ]]
  [[ "${output}" != *"FRESHMINT"* ]]
  assert_eq "one mint, for the one workspace named" "1" "$(stub_log_count coder)"
  # The repair and its proof both go through docker exec against that one
  # container, and only that one. (The stub logs the whole probe body as one
  # argv line, which spans many physical lines, so count the exec lines.)
  local execs
  execs="$(stub_log docker | grep '^docker exec ' || true)"
  assert_eq "two execs: the repair, then the re-probe" "2" "$(printf '%s\n' "${execs}" | grep -c .)"
  assert_eq "both name only that container" "2" "$(printf '%s\n' "${execs}" | grep -c 'coder-alice-ws1')"
  [[ "${execs}" != *"coder-alice-ws2"* ]]
}

@test "fix: inside a workspace a named container is refused with the host pointer" {
  export CODER_WORKSPACE_ID=ws-test
  run bash "${SCRIPT}" fix coder-bob-ws1 https://github.com/alx/notes
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"this is a workspace shell"* ]]
  [[ "${output}" == *"a named container is repaired from the stack host"* ]]
  assert_eq "docker never called" "0" "$(stub_log_count docker)"
  assert_eq "nothing was repaired" "0" "$(stub_log_count coder)"
}

@test "fix: on the stack host a repair with no container is refused" {
  STUB_COMPOSE_PS="coder-alice-ws1" run bash "${SCRIPT}" fix
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"names the ONE workspace to repair"* ]]
  [[ "${output}" == *"fix <container> [repo-url]"* ]]
  assert_eq "no container was repaired" "0" "$(stub_log_count docker)"
  assert_eq "nothing was minted" "0" "$(stub_log_count coder)"
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
  # Two execs now: the gh login chain, then the helper-only repair that stops
  # setup-git's own helper echoing the injected pair back over the new token.
  # (The stub logs each exec's whole probe body as one argv line spanning many
  # physical lines, so count the lines that start an exec.)
  local execs
  execs="$(stub_log docker | grep '^docker exec ' || true)"
  assert_eq "two execs, both against that container" "2" "$(printf '%s\n' "${execs}" | grep -c .)"
  assert_eq "and both name only that container" "2" "$(printf '%s\n' "${execs}" | grep -c 'coder-alice-ws1')"
  assert_match "the helper re-install is helper-only" 'EVO_T1_FIX_MODE=helper-only' "$(stub_log docker)"
}
