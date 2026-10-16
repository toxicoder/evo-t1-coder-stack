#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## dashboard-password.bats - hermetic coverage for scripts/dashboard-password.sh
#
# Three contracts are pinned here.
#
# (1) The password never reaches argv. A new value cannot be given as an argument
#     (that is a refusal the script itself makes), the prompt reads never reach
#     docker's argv, and no test asserts a flow where they would.
# (2) The env file is edited in place, one HOMEPAGE_AUTH_PASSWORD line, mode 600,
#     and every test points DASHBOARD_ENV_FILE at a scratch file. The checkout's
#     own .env is never read, printed, or written by this suite.
# (3) The apply path addresses the daemon directly, then recreates through the
#     compose project the container's own labels name: `docker ps` with no -p/-f,
#     then `docker inspect` for com.docker.compose.project + project.config_files,
#     then `docker compose -p <project> -f <file> up -d --force-recreate homepage`.
#     A bare compose command or a plain restart is what used to be wrong here.
#
# docker and timeout resolve to the copies in tests/bats/tool_stubs/ (use_stubs),
# so `command -v docker` passes and the unquoted ${DOCKER_BIN} + timeout(1) probes
# land on a stub that never opens a socket. With DOCKER_BIN left at its default
# the stub swallows the two `inspect -f ...` probes (its `*config*` case matches
# the label format string, which names com.docker.compose.project.config_files),
# so those runs can only ever reach the script's "cannot tell" refusals - that is
# what the last two compose-target tests pin. fake_daemon writes a throwaway
# daemon that answers the label probe and mirrors the container's env, which is
# how the recreate-and-verify half gets asserted.
#
# Usage: bats tests/bats/dashboard-password.bats   (from any cwd)
#
# Safety: stub only. Nothing here needs a daemon, a network, or the real .env.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
SCRATCH=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/dashboard-password.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/dashboard-password.sh is not in the tree"
  fi
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout
  SCRATCH="$(make_scratch)"
  # A scratch env file with a stale password in it, plus the two prompt entries a
  # --prompt run reads. 22 characters, so the length floor is never the question.
  printf '%s\n%s\n' 'HOMEPAGE_AUTH_PASSWORD=old-password-1234' 'STACK_LAN_HOST=box.example' >"${SCRATCH}/x.env"
  printf '%s\n%s\n' 'rotated-passwd-abcdefgh' 'rotated-passwd-abcdefgh' >"${SCRATCH}/in"
}

# fake_daemon <ps-body> [project|compose-file] [file-to-mirror-as-container-env]
# Replace the copied docker stub with a daemon that answers the three probes the
# apply path makes: the daemon-wide ps (one "service|container" line per running
# container), the label probe that names the compose project and file, and the
# env probe that reports the running container's environment. An empty project
# means "no compose labels"; the env answer is copied out of <file> at call
# time, so a pre-rewrite copy reads as a container that kept the old password.
# Every argv is still recorded to ${STUB_LOG}/docker.log, prefixed "docker ".
fake_daemon() {
  local bin="${BATS_TEST_TMPDIR?}/bin"
  export FAKE_PS="${1-}"
  export FAKE_TARGET="${2-}"
  export FAKE_ENVFILE="${3:-/dev/null}"
  cat >"${bin}/docker" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'docker %s\n' "$*" >>"${STUB_LOG:-/dev/null}/docker.log"
argv=" $* "
case "${argv}" in
  *" ps "*)
    if [ -n "${FAKE_PS}" ]; then printf '%s\n' "${FAKE_PS}"; fi
    exit "${FAKE_PS_RC:-0}"
    ;;
  *Config.Labels*)
    printf '%s\n' "${FAKE_TARGET}"
    exit 0
    ;;
  *Config.Env*)
    grep '^HOMEPAGE_AUTH_PASSWORD=' "${FAKE_ENVFILE}" 2>/dev/null || true
    exit 0
    ;;
esac
exit 0
STUB
  chmod 755 "${bin}/docker"
}

# unchanged_env <file> - true while <file> still holds the two lines setup wrote.
unchanged_env() {
  assert_contains_file "env file untouched" "${1}" '^HOMEPAGE_AUTH_PASSWORD=old-password-1234$' &&
    assert_contains_file "env file untouched" "${1}" '^STACK_LAN_HOST=box\.example$'
}

@test "dashboard-password: --help only prints the usage" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ] || fail "help exited ${status}"
  assert_match "usage line" '^usage: scripts/dashboard-password\.sh' "${output}"
  assert_match "documents --prompt" '--prompt' "${output}"
  assert_match "documents --length" '--length' "${output}"
  assert_match "documents --no-apply" '--no-apply' "${output}"
  # There is deliberately no flag for the env file or the compose project: the
  # help text says so by not naming either.
  assert_not_match "no env-file flag" '--env-file' "${output}"
  assert_not_match "no project flag" '--project-name' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ] || fail "help reached docker: $(stub_log docker)"
  unchanged_env "${SCRATCH}/x.env"
}

@test "dashboard-password: a password given as an argument is refused" {
  run --separate-stderr bash "${SCRIPT}" --no-apply 'hunter2hunter2hunter2'
  [ "${status}" -eq 1 ] || fail "an argv password was not refused (${status})"
  assert_match "refused" 'a new password cannot be given as an argument' "${stderr}"
  assert_match "says why" 'shell history' "${stderr}"
  assert_not_match "value not printed" 'hunter2hunter2hunter2' "${output}"
  assert_not_match "value not echoed to docker" 'hunter2hunter2hunter2' "$(stub_log docker)"
  [ "$(stub_log_count docker)" -eq 0 ] || fail "docker was called: $(stub_log docker)"
}

@test "dashboard-password: --no-apply refuses an env file that is missing, or one it cannot write" {
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/absent.env" bash "${SCRIPT}" --no-apply
  [ "${status}" -eq 1 ] || fail "a missing env file was not refused (${status})"
  assert_match "names the file" 'absent\.env not found' "${stderr}"
  assert_match "points at the bootstrap script" 'first boot\? run \./scripts/bootstrap\.sh to create it' "${stderr}"
  assert_file_not_exists "no env file was created" "${SCRATCH}/absent.env"
  chmod 444 "${SCRATCH}/x.env"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "a read-only env file was not refused (${status})"
  assert_match "refuses a file it cannot write" 'is not both readable and writable by this user' "${stderr}"
  assert_not_match "the old value is not printed" 'old-password-1234' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ] || fail "docker was called: $(stub_log docker)"
}

@test "dashboard-password: --no-apply rewrites only the password line, with docker nowhere" {
  printf '%s\n%s\n%s\n' 'HOMEPAGE_AUTH_PASSWORD=first-older-pass' 'OTHER_KEY=1' 'HOMEPAGE_AUTH_PASSWORD=second-older-pass' >"${SCRATCH}/dup.env"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/dup.env" bash "${SCRIPT}" --prompt --no-apply <"${SCRATCH}/in"
  [ "${status}" -eq 0 ] || fail "--no-apply exited ${status}: ${stderr}"
  assert_eq "one password line" '1' "$(grep -c '^HOMEPAGE_AUTH_PASSWORD=' "${SCRATCH}/dup.env")"
  assert_match "the new value landed" '^HOMEPAGE_AUTH_PASSWORD=rotated-passwd-abcdefgh$' "$(cat "${SCRATCH}/dup.env")"
  assert_not_match "both stale values are gone" 'older-pass' "$(cat "${SCRATCH}/dup.env")"
  assert_match "the neighbour line survived" '^OTHER_KEY=1$' "$(cat "${SCRATCH}/dup.env")"
  assert_match "says it stayed offline" 'not applied: rerun without --no-apply' "${output}"
  # The command it skipped is named in full: an operator applying it by hand has
  # to be able to copy it, and `restart` would keep the old value in the env.
  assert_match "names the recreate it skipped" 'docker compose up -d --force-recreate homepage' "${output}"
  assert_not_match "restart is never suggested" 'compose restart' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ] || fail "docker was called: $(stub_log docker)"
}

@test "dashboard-password: --length and the prompt entries are checked before .env moves on" {
  local bad
  for bad in '' 'abc' '0' '600'; do
    run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --length "${bad}"
    [ "${status}" -eq 1 ] || fail "--length ${bad} exited ${status}"
    assert_match "refuses --length ${bad}" '--length must be' "${stderr}"
    assert_not_match "nothing was applied for --length ${bad}" 'updated HOMEPAGE_AUTH_PASSWORD' "${output}"
  done
  assert_contains_file "the key line survives a rewrite" "${SCRATCH}/x.env" '^HOMEPAGE_AUTH_PASSWORD=old-password-1234$'
  printf '%s\n%s\n' 'first-entry-value-abcdef' 'second-entry-value-xyz' >"${SCRATCH}/mismatch.in"
  printf '%s\n%s\n' 'short' 'short' >"${SCRATCH}/short.in"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/mismatch.in"
  [ "${status}" -eq 1 ] || fail "mismatched entries were accepted (${status})"
  assert_match "mismatch refused" 'the two entries did not match; nothing was changed' "${stderr}"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/short.in"
  [ "${status}" -eq 1 ] || fail "a short password was accepted (${status})"
  assert_match "short password refused" 'password too short: at least 12 characters required \(got 5\)' "${stderr}"
  unchanged_env "${SCRATCH}/x.env"
  [ "$(stub_log_count docker)" -eq 0 ] || fail "docker was called: $(stub_log docker)"
}

@test "dashboard-password: with no docker, or a daemon that will not answer, .env is left alone or the run stops" {
  # No docker on PATH at all: the guard runs before the rewrite, so the file
  # still holds the password the operator is logged in with.
  run --separate-stderr env "DOCKER_BIN=nodocker" "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "a missing docker binary was not refused (${status})"
  assert_match "names the offline way out" 'docker not found on PATH \(use --no-apply to update \.env only\)' "${stderr}"
  unchanged_env "${SCRATCH}/x.env"

  # A daemon that answers the daemon-wide probe with an error is answered, not
  # ignored: the refusal quotes docker's own text back.
  run --separate-stderr env "STUB_COMPOSE_PS=Error: dial unix /var/run/docker.sock: connect: connection refused" "STUB_COMPOSE_PS_RC=1" \
    "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "a failing daemon probe did not stop the run (${status})"
  assert_match "quotes the failed probe" 'could not query the docker daemon: Error: dial unix' "${stderr}"
  assert_match "the rewrite had already landed" 'updated HOMEPAGE_AUTH_PASSWORD in .*/x\.env' "${output}"
  assert_not_match "no compose was attempted" 'docker compose' "$(stub_log docker)"
}

@test "dashboard-password: a daemon with no homepage container refuses to recreate anything" {
  # Both containers carry a service label; neither is the homepage service. The
  # label column is matched as a whole field, so xhomepage is not a homonym.
  run --separate-stderr env "STUB_COMPOSE_PS=db|stack-db-1
xdb|stack-home-1" "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "an empty container list did not stop the run (${status})"
  assert_match "refuses without the container" 'could not find the homepage container on the docker daemon \(use --no-apply to update \.env only\)' "${stderr}"
  # The one daemon call is the daemon-wide `docker ps`: no -p and no -f, because
  # a project resolved from this script's cwd is a different project.
  assert_eq "one daemon probe" '1' "$(stub_log_count docker)"
  assert_match "the probe is daemon-wide" '^docker ps --format ' "$(stub_log docker)"
  assert_not_match "the probe scoped a project" ' -p ' "$(stub_log docker)"
  assert_not_match "no compose was attempted" 'docker compose' "$(stub_log docker)"
}

@test "dashboard-password: the oldest labelled homepage container answers, and an unreadable compose target stops the run" {
  # Two containers carry the homepage label: docker ps lists the newest first, so
  # the script must take the LAST one (the older stack), and it must ask that
  # container's own labels rather than assuming a project from the cwd.
  export STUB_COMPOSE_PS='homepage|home-new
homepage|home-old'
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "an unknown compose target did not stop the run (${status})"
  assert_match "refuses to guess a project" 'answers to no compose project this shell can read' "${stderr}"
  assert_match "points at a manual recreate" 'recreate it by hand from the checkout root: docker compose up -d --force-recreate homepage' "${stderr}"
  assert_match "the older container was inspected" 'Config\.Labels.* home-old$' "$(stub_log docker)"
  assert_not_match "no recreate without a compose target" 'compose -p' "$(stub_log docker)"
  assert_not_match "no password was left behind in argv" 'rotated-passwd-abcdefgh' "$(stub_log docker)"
}

@test "dashboard-password: the recreate names the compose project and file the labels gave" {
  printf '%s\n' 'services:' '  homepage:' >"${SCRATCH}/compose.yml"
  fake_daemon 'homepage|home-new
homepage|home-old' "prod-stack|${SCRATCH}/compose.yml" "${SCRATCH}/x.env"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 0 ] || fail "a resolvable compose target exited ${status}: ${stderr}"
  assert_match "four daemon calls" '^docker compose -p prod-stack -f .*/compose\.yml up -d --force-recreate homepage$' "$(stub_log docker)"
  assert_eq "ps, labels, recreate, env" '4' "$(stub_log_count docker)"
  assert_not_match "a restart is not a recreate" 'restart' "$(stub_log docker)"
  assert_match "the running container was verified" 'verified: the running container has the new password' "${output}"
  assert_not_match "the password never reaches docker argv" 'rotated-passwd-abcdefgh' "$(stub_log docker)"
  assert_not_match "no cwd-resolved project" 'compose -p evo-t1' "$(stub_log docker)"
}

@test "dashboard-password: a recreate the running container cannot confirm is reported, not celebrated" {
  # First: the container answers with the password it was created with, which is
  # still the old one. The recreate rebuilt nothing, and saying "verified" here
  # would leave every browser signed out against a password nobody knows.
  printf '%s\n' 'HOMEPAGE_AUTH_PASSWORD=old-password-1234' 'STACK_LAN_HOST=box.example' >"${SCRATCH}/stale.env"
  printf '%s\n' 'services:' '  homepage:' >"${SCRATCH}/compose.yml"
  fake_daemon 'homepage|home-old' "prod-stack|${SCRATCH}/compose.yml" "${SCRATCH}/stale.env"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "a recreate that kept the old password reported success (${status})"
  assert_match "names the failed recreate" 'the running container still has the old password' "${stderr}"
  assert_match "points at the compose logs" 'check: docker compose logs homepage' "${stderr}"
  assert_not_match "no false success claim" 'verified: the running container' "${output}"
  assert_match "the recreate really was addressed" '^docker compose -p prod-stack -f ' "$(stub_log docker)"
  # Then: a container whose environment carries no such key at all. Same refusal
  # shape - the script will not call a rotate verified on an env it cannot read.
  printf '%s\n' 'STACK_LAN_HOST=box.example' >"${SCRATCH}/nokey.env"
  fake_daemon 'homepage|home-old' "prod-stack|${SCRATCH}/compose.yml" "${SCRATCH}/nokey.env"
  run --separate-stderr env "DASHBOARD_ENV_FILE=${SCRATCH}/x.env" bash "${SCRIPT}" --prompt <"${SCRATCH}/in"
  [ "${status}" -eq 1 ] || fail "an env with no password entry did not stop the run (${status})"
  assert_match "refuses to claim a rotate it cannot see" 'the homepage container has no HOMEPAGE_AUTH_PASSWORD entry; check: docker compose config' "${stderr}"
  assert_not_match "no false success claim" 'verified: the running container' "${output}"
}
