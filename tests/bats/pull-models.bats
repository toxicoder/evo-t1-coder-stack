#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## pull-models.bats - hermetic coverage for scripts/pull-models.sh
#
# What this suite pins is the shape of the docker traffic, because that is the
# whole contract of the script:
#
#   - ONE daemon-wide `docker ps --format ...` probe, carrying no -p/-f and no
#     `compose` subcommand (scripts/lib/coder_api.sh finds the ollama container
#     by SERVICE LABEL across the whole daemon; a project-scoped probe was the
#     old design and it read every live stack as "not running" from a foreign
#     cwd, which is where `bazelisk run //scripts:pull-models` lives);
#   - the container the pulls land in is the one that probe named - the LAST
#     line whose service field is exactly `ollama`, since `docker ps` lists
#     newest first and the oldest container is the stable stack's;
#   - one `docker exec -i <container> bash -lc ...` per model, then a closing
#     `./ollama list`, every one of them inside that container and none of them
#     capped by timeout(1);
#   - which models, in what order: OLLAMA_MODELS from the .env beside the script
#     beats one set in the caller's environment, and neither is looked for in
#     the cwd.
#
# Hermetic by construction: docker and timeout resolve to the copies in
# tests/bats/tool_stubs/ (use_stubs), and the script runs from a throwaway repo
# root built by fake_root, so no test consults a live daemon or the checkout's
# own .env. STUB_COMPOSE_PS answers the ps probe (STUB_COMPOSE_PS_RC sets its
# exit status); STUB_DOCKER_EXEC_RUN=0 keeps the in-container command canned
# rather than executed on the host.
#
# Usage: bazelisk test //tests:bats_pull_models_test   (from any cwd)
#
# Safety: stub only. Nothing here needs a daemon, a model, or a network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/pull-models.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/pull-models.sh is not in the tree"
  fi
  use_stubs docker timeout
  # The docker stub's default is to exec the in-container command on the host.
  # Here that command is `cd /llm/ollama && ./ollama pull ...`, which has
  # nothing to cd into and fails: canned answers keep the execs stubs, so a
  # green run proves the argv the script built and nothing more.
  export STUB_DOCKER_EXEC_RUN=0
}

# fake_root [env-line...] - print a throwaway repo root holding the script under
# test, scripts/lib/ (which it sources after its own repo-root cd) and a .env
# holding any lines given. An empty .env still matters: the script sources it, so
# a test that wants a caller-supplied OLLAMA_MODELS to win needs one to exist.
fake_root() {
  local root="${BATS_TEST_TMPDIR?}/root"
  mkdir -p "${root}/scripts/lib"
  : >"${root}/.env"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >>"${root}/.env"
  fi
  cp "${REPO_ROOT}/scripts/pull-models.sh" "${root}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  printf '%s' "${root}"
}

@test "pull-models: with nothing naming a model, the default pair is pulled in order" {
  root="$(fake_root)"
  scratch="$(make_scratch)"
  run --separate-stderr env -C "${scratch}" STUB_COMPOSE_PS='ollama|ipex-ollama-1' \
    bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 0 ]
  # The whole stdout, byte for byte: two pulls, a blank line, then the list.
  [[ "${output}" == $'pulling qwen2.5-coder:32b ...\npulling qwen2.5-coder:14b ...\n\nModels available on the IPEX-LLM Ollama service:' ]]
  # Four docker calls: the probe, one pull per model, and the list that closes
  # the run. Nothing in that list is addressed through a compose project.
  [ "$(stub_log_count docker)" -eq 4 ]
  [ "$(stub_log_last docker)" = "docker exec -i ipex-ollama-1 bash -lc cd /llm/ollama && ./ollama list" ]
}

@test "pull-models: OLLAMA_MODELS in the .env beside the script names the models" {
  root="$(fake_root 'OLLAMA_MODELS="phi-4-mini:4b tiny-stural:1b"')"
  scratch="$(make_scratch)"
  # A decoy .env in the cwd: the script cds to its own repo root first, so this
  # one must be ignored. It is the same trap the daemon-wide probe fixed.
  printf '%s\n' 'OLLAMA_MODELS="decoy-model"' >"${scratch}/.env"
  run --separate-stderr env -C "${scratch}" STUB_COMPOSE_PS='ollama|ipex-ollama-1' \
    bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "pulling phi-4-mini:4b ..."$'\n'"pulling tiny-stural:1b ..."* ]]
  [[ "${output}" != *"decoy-model"* ]]
  [[ "${output}" != *"qwen2.5-coder"* ]]
  [ "$(stub_log_count docker)" -eq 4 ]
  [[ "$(stub_log docker)" != *decoy-model* ]]
}

@test "pull-models: OLLAMA_MODELS in the environment replaces the default pair" {
  root="$(fake_root)"
  scratch="$(make_scratch)"
  run --separate-stderr env -C "${scratch}" STUB_COMPOSE_PS='ollama|ipex-ollama-1' \
    OLLAMA_MODELS='mixtral-8x22b' bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pulling mixtral-8x22b ..."* ]]
  [[ "${output}" != *"qwen2.5-coder"* ]]
  # One model, so one probe, one pull and the list: the list is split on
  # whitespace, and an empty OLLAMA_MODELS in .env would have fallen back to
  # the default pair.
  [ "$(stub_log_count docker)" -eq 3 ]
  [ "$(stub_log_last docker)" = "docker exec -i ipex-ollama-1 bash -lc cd /llm/ollama && ./ollama list" ]
}

@test "pull-models: a daemon that does not answer is reported, with the docker-access hint" {
  root="$(fake_root)"
  # STUB_COMPOSE_PS_RC=1 is the shape of a host without docker access: the ps
  # probe answers (with docker's own error text) and fails. The script must say
  # so and stop, not go looking for an ollama container in a stack it cannot
  # see. The answer arrives on the probe's stdout, so it reaches the message.
  run --separate-stderr env STUB_COMPOSE_PS='Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' \
    STUB_COMPOSE_PS_RC=1 bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 1 ]
  assert_match "refusal" \
    '^error: could not query the stack: Cannot connect to the Docker daemon at unix:///var/run/docker\.sock\. Is the docker daemon running\?$' \
    "${stderr}"
  # The separator between "access" and "run" is an em dash. .* swallows it
  # whether the regex engine counts bytes or characters (the dot would eat only
  # one of the dash's three bytes under a C locale), and the file stays ASCII.
  assert_match "docker-access hint" '^ {7}this script needs docker access .*run it with sudo, or add your user to the docker group$' "${stderr}"
  # One docker call, the failed probe: no exec may be aimed at an unknown
  # container, and no compose call may resolve a project from this cwd.
  [ "$(stub_log_count docker)" -eq 1 ]
  [[ "$(stub_log docker)" == "docker ps --format "* ]]
  [[ "$(stub_log docker)" != *"docker compose "* ]]
}

@test "pull-models: a stack without an ollama service is refused, and nothing is pulled" {
  root="$(fake_root)"
  # An empty ps answer is "the daemon answered and nothing is running".
  run --separate-stderr env STUB_COMPOSE_PS='' bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 1 ]
  assert_eq "nothing running" \
    $'error: the ollama service is not running (start the stack with: bazelisk run //scripts:prod-stack -- up)\n       if it is in a restart loop, check: bazelisk run //scripts:prod-stack -- logs --tail 100 ollama' \
    "${stderr}"

  # Services that are running are not the ollama service: the label column is
  # matched as a whole field, so a container merely NAMED after one answers for
  # nothing either.
  run --separate-stderr env STUB_COMPOSE_PS=$'db|stack-db-1\ncoder|stack-coder-1\nother|ollama-sidecar-1' \
    bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 1 ]
  assert_eq "the wrong services" \
    $'error: the ollama service is not running (start the stack with: bazelisk run //scripts:prod-stack -- up)\n       if it is in a restart loop, check: bazelisk run //scripts:prod-stack -- logs --tail 100 ollama' \
    "${stderr}"
  # Two probes, and still no exec: a pull into the wrong container would download
  # 35 GB into a service that is not Ollama.
  [ "$(stub_log_count docker)" -eq 2 ]
  [[ "$(stub_log docker)" != *'exec '* ]]
}

@test "pull-models: the pull lands in the oldest ollama container, which ps lists last" {
  root="$(fake_root)"
  # `docker ps` lists newest first, so a LATER line is the OLDER container: with
  # the dev stack up beside the stable one, the last match is the stable one's
  # copy, and that is the container this script must pull into.
  run --separate-stderr env STUB_COMPOSE_PS=$'coder|dev-coder-1\nollama|dev-ollama-1\nollama|stable-ollama-1' \
    OLLAMA_MODELS='m1' bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count docker)" -eq 3 ]
  [[ "$(stub_log docker)" != *"docker exec -i dev-ollama-1"* ]]
  [[ "$(stub_log docker)" != *"docker exec -i dev-coder-1"* ]]
  [[ "$(stub_log docker)" == *"docker exec -i stable-ollama-1 bash -lc cd /llm/ollama && ./ollama pull 'm1'"* ]]
}

@test "pull-models: the probe is daemon-wide and capped, the pulls are neither" {
  root="$(fake_root)"
  run --separate-stderr env STUB_COMPOSE_PS='ollama|ipex-ollama-1' OLLAMA_MODELS='m1 m2' \
    bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 0 ]
  assert_not_match "compose subcommand" 'docker compose ' "$(stub_log docker)"
  assert_not_match "project or file flag" ' (-p|-f) ' "$(stub_log docker)"
  # The probe asks the daemon; a project-scoped probe is the bug this seam
  # exists to kill, and it would also address whichever project the calling
  # folder happens to imply.
  [[ "$(stub_log docker)" == "docker ps --format "* ]]
  [[ "$(stub_log docker)" == *'{{.Label "com.docker.compose.service"}}|{{.Names}}'* ]]
  # timeout(1) caps the probe only: a first pull is tens of gigabytes and would
  # fail on the clock before it failed on the network.
  [ "$(stub_log_count timeout)" -eq 1 ]
  [ "$(stub_log_last timeout)" = "timeout -k 2 20 docker ps --format {{.Label \"com.docker.compose.service\"}}|{{.Names}}" ]
  [[ "$(stub_log docker)" == *"docker exec -i ipex-ollama-1 bash -lc "* ]]
}

@test "pull-models: a pull that fails stops the run before the list" {
  root="$(fake_root)"
  # A canned non-zero exec answer stands in for a pull that fails (no space, no
  # network). Nothing here retries, continues to the next model, or pretends the
  # models are available.
  run --separate-stderr env STUB_COMPOSE_PS='ollama|ipex-ollama-1' OLLAMA_MODELS='m1 m2' \
    STUB_DOCKER_EXEC_RC=1 bash "${root}/scripts/pull-models.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pulling m1 ..."* ]]
  [[ "${output}" != *"pulling m2 ..."* ]]
  [[ "${output}" != *"Models available"* ]]
  # Probe, one pull, and the run is over.
  [ "$(stub_log_count docker)" -eq 2 ]
}
