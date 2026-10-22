#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## dev-stack.bats — hermetic coverage for scripts/dev-stack.sh.
#
# Five things are pinned here, because they are the whole contract of the
# script: the compose project defaults to evo-t1-dev and --project-name renames
# it, the env file that carries the host ports is chosen by project, an unknown
# subcommand is a usage error rather than an arbitrary action, `status` answers
# with one-line reports when the docker CLI is dead (both CLI spellings resolve
# through the tool stubs, which can be forced to refuse every probe with
# STUB_DOCKER_RC=1 — test hosts may carry a real CLI and a live daemon), and
# `reset` refuses to destroy a stack without its confirmation flag.
#
# The whole suite skips while scripts/dev-stack.sh is absent: a suite for a
# script that does not exist yet has no right to fail the gate.
#
# docker and docker-compose are stubs. Nothing here creates a compose project or
# talks to a daemon.
#
# Usage: bats tests/bats/dev-stack.bats

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
STACK=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  STACK="${REPO_ROOT}/scripts/dev-stack.sh"
  if [ ! -f "${STACK}" ]; then
    skip "scripts/dev-stack.sh is not in the tree"
  fi
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker docker-compose
}

@test "dev-stack: an unknown subcommand prints the usage and touches nothing" {
  run --separate-stderr bash "${STACK}" destroy
  [ "${status}" -ne 0 ]
  assert_match "usage" 'usage: dev-stack' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
  [ "$(stub_log_count docker-compose)" -eq 0 ]
}

@test "dev-stack: status reports an unresponsive docker CLI and still exits 0" {
  # Hermetic on every host: both CLI spellings resolve through the tool stubs,
  # and STUB_DOCKER_RC=1 makes the stubs refuse every probe (info, compose
  # version, ps), so no daemon is reachable from here. Trusting the host to
  # lack docker was the old bug — a Linux CI runner carries /usr/bin/docker
  # and a live daemon, which flipped this case from the dead-CLI shape to the
  # daemon-reachable shape and pointed `ps` at the real daemon. The
  # docker-not-on-PATH shape keeps its coverage in the helper-level
  # report_stack test, which redefines has_tool and therefore never consults
  # the PATH at all.
  run --separate-stderr env STUB_DOCKER_RC=1 bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "daemon line" 'daemon: not reachable' "${output}"
  assert_match "project line" '^project: evo-t1-dev$' "${output}"
}

@test "dev-stack: the compose project is evo-t1-dev unless --project-name says otherwise" {
  run --separate-stderr bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "default project" 'evo-t1-dev' "$(stub_log docker)$(stub_log docker-compose)"
}

@test "dev-stack: --project-name renames the compose project it addresses" {
  run --separate-stderr bash "${STACK}" status --project-name evo-t1-review
  [ "${status}" -eq 0 ]
  assert_match "renamed project" 'evo-t1-review' "$(stub_log docker)$(stub_log docker-compose)"
  assert_not_match "default name" 'evo-t1-dev' "$(stub_log docker)$(stub_log docker-compose)"
}

@test "dev-stack: only the dev project takes dev-stack.env as its port source" {
  # One host runs both stacks, and the env file is where the host ports live.
  # Handing dev-stack.env to a run that names the stable project would republish
  # that stack on the dev ports, so the file is chosen by project name. The
  # scratch root stands in for the checkout: only its two files matter here.
  scratch="${BATS_TEST_TMPDIR}/two-stacks"
  mkdir -p "${scratch}"
  : >"${scratch}/docker-compose.yml"
  printf 'CODER_HTTP_PORT=13001\n' >"${scratch}/dev-stack.env"

  run --separate-stderr env REPO_ROOT="${scratch}" bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "dev port source" '^env-file: .*/dev-stack\.env$' "${output}"

  # A named non-dev project reads the .env beside the compose file, exactly as a
  # plain `docker compose` call would, so the dev numbers stay out of it.
  run --separate-stderr env REPO_ROOT="${scratch}" bash "${STACK}" status --project-name evo-t1-coder-stack
  [ "${status}" -eq 0 ]
  assert_match "stable port source" '^env-file: none' "${output}"
  assert_not_match "no dev ports" 'dev-stack\.env' "${output}"

  # `up` prints the compose line it is about to run, and the URL summary reads
  # its ports from the same file: both have to name the stable stack's own.
  run --separate-stderr env REPO_ROOT="${scratch}" bash "${STACK}" up --project-name evo-t1-coder-stack
  [ "${status}" -eq 0 ]
  assert_match "compose line" 'run: docker compose -p evo-t1-coder-stack -f .*/docker-compose\.yml up -d' "${output}"
  assert_match "password line" 'HOMEPAGE_AUTH_PASSWORD in .*/\.env ' "${output}"
}

@test "dev-stack: reset without the confirmation flag destroys nothing" {
  run --separate-stderr bash "${STACK}" reset
  assert_match "refused" 'confirm' "${output}"
  assert_not_match "no teardown" '(^| )down( |$)' "$(stub_log docker)$(stub_log docker-compose)"
}

@test "dev-stack: logs passes --tail, --follow and any service names to compose" {
  run --separate-stderr bash "${STACK}" logs --tail 200 coder
  [ "${status}" -eq 0 ]
  assert_match "tail and service" '\-p evo-t1-dev .*-f .*/docker-compose\.yml logs --tail 200 coder$' "${output}"

  # `make stack-logs ARGS="--tail 200 coder"` spells the same call with the
  # project name between the subcommand and the tail, so the flags have to
  # resolve on either side of the subcommand — and the renamed project is the one
  # that has to reach compose.
  run --separate-stderr bash "${STACK}" logs --project-name evo-t1-review --tail 200 coder
  [ "${status}" -eq 0 ]
  assert_match "renamed project" '\-p evo-t1-review .*-f .*/docker-compose\.yml logs --tail 200 coder$' "${output}"

  # -f belongs to --file; --follow is the flag that follows, and it is the one
  # the usage block advertises.
  run --separate-stderr bash "${STACK}" logs --follow --tail 5 coder litellm
  [ "${status}" -eq 0 ]
  assert_match "follow" '\-f .*/docker-compose\.yml logs -f --tail 5 coder litellm$' "${output}"
}

# ── Helper-level coverage ----------------------------------------------------
# The tests above drive the script as a whole; the ones below the rule load one
# helper at a time (tests/extract_fn.py), because //tests:shell_inventory fails
# when a function under scripts/ is named by no asserting test. docker and
# docker-compose are still stubs: nothing here reaches a daemon.

load_fn() {
  load_shell_function "${REPO_ROOT}/$1" "$2"
}

@test "dev-stack: resolve_repo_root needs a compose file AND a docker CLI" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/dev-stack.sh resolve_repo_root
  SELF_DIR="${REPO_ROOT}"
  run resolve_repo_root
  [ "${status}" -eq 0 ]
  # ${REPO_ROOT} is the checkout under `bats` and the runfiles copy under Bazel;
  # either way it is the one directory this test knows holds docker-compose.yml.
  assert_eq "proven root" "${REPO_ROOT}" "${output}"

  # Neither half alone is proof: this scratch dir has no compose file, and the
  # shadowed has_tool says no docker CLI either, which is the sandbox case.
  scratch="${BATS_TEST_TMPDIR}/unproven"
  mkdir -p "${scratch}"
  cd "${scratch}"
  SELF_DIR="${scratch}"
  REPO_ROOT="${scratch}"
  has_tool() { return 1; }
  run resolve_repo_root
  [ "${status}" -eq 5 ]
  assert_match "unproven root" 'unresolvable repo root' "${output}"
}

@test "dev-stack: resolve_repo_root prefers BUILD_WORKSPACE_DIRECTORY over PWD" {
  # bazelisk run sets cwd to the runfiles copy (which has docker-compose.yml)
  # and BUILD_WORKSPACE_DIRECTORY to the checkout. Compose bind mounts and
  # `.env` have to come from the checkout: proxy/certs/ is bazelignored.
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/dev-stack.sh resolve_repo_root
  workspace="$(make_scratch)/workspace"
  runfiles="$(make_scratch)/runfiles"
  mkdir -p "${workspace}" "${runfiles}/scripts"
  touch "${workspace}/docker-compose.yml" "${runfiles}/docker-compose.yml"
  REPO_ROOT=""
  unset GITHUB_WORKSPACE
  BUILD_WORKSPACE_DIRECTORY="${workspace}"
  cd "${runfiles}"
  SELF_DIR="${runfiles}/scripts"
  run resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "workspace wins" "${workspace}" "${output}"
}

@test "dev-stack: status reports the BUILD_WORKSPACE_DIRECTORY compose file" {
  workspace="$(make_scratch)/workspace"
  mkdir -p "${workspace}"
  cp "${REPO_ROOT}/docker-compose.yml" "${workspace}/docker-compose.yml"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "workspace compose file" "file: ${workspace}/docker-compose.yml" "${output}"
}

@test "dev-stack: compose_cli and compose_prefix name the CLI and the project" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/dev-stack.sh compose_cli
  [ "$(compose_cli)" = "docker compose" ]

  PROJECT="evo-t1-review"
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
  ENV_FILE=""
  load_fn scripts/dev-stack.sh compose_prefix
  assert_eq "no env file" \
    "docker compose -p evo-t1-review -f ${REPO_ROOT}/docker-compose.yml" \
    "$(compose_prefix)"
  ENV_FILE="${BATS_TEST_TMPDIR}/dev-stack.env"
  assert_match "env file" '\-\-env-file .*/dev-stack\.env' "$(compose_prefix)"
}

@test "dev-stack: default_env_file picks the host-port file by project" {
  load_fn scripts/dev-stack.sh default_env_file
  scratch="${BATS_TEST_TMPDIR}/port-file"
  mkdir -p "${scratch}"
  ENV_FILE=""
  DEV_PROJECT="evo-t1-dev"

  # No dev-stack.env beside the compose file: nothing is chosen, so compose
  # interpolates its ${VAR:-default} ports, and the shell never sees a --file.
  assert_eq "no dev-stack.env" "" "$(default_env_file "${scratch}" evo-t1-dev)"

  printf 'CODER_HTTP_PORT=13001\n' >"${scratch}/dev-stack.env"
  assert_eq "dev project" "${scratch}/dev-stack.env" "$(default_env_file "${scratch}" evo-t1-dev)"

  # Every other project is a stack of its own, so it gets no file here: that is
  # what keeps the dev port numbers out of a run aimed at the stable stack.
  assert_eq "stable project" "" "$(default_env_file "${scratch}" evo-t1-coder-stack)"
  assert_eq "review project" "" "$(default_env_file "${scratch}" evo-t1-review)"

  # An explicit --env-file still outranks the default, whoever the project is.
  ENV_FILE="${scratch}/custom.env"
  assert_eq "explicit file wins" "${scratch}/custom.env" "$(default_env_file "${scratch}" evo-t1-dev)"
}

@test "dev-stack: report_stack reports a missing docker and an unproven root" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/lib/common.sh env_get
  PROJECT="evo-t1-dev"
  COMPOSE_FILE=""
  ENV_FILE=""
  load_fn scripts/dev-stack.sh report_stack
  load_fn scripts/dev-stack.sh compose_cli
  load_fn scripts/dev-stack.sh compose_prefix

  # No docker CLI at all: four lines, and the report still exits 0.
  has_tool() { return 1; }
  run report_stack
  [ "${status}" -eq 0 ]
  assert_match "docker line" '^docker: not on PATH' "${output}"
  assert_match "daemon line" '^daemon: not checked' "${output}"

  # docker on PATH but no proven checkout: the file line says so, and the `ps`
  # command that would have needed a compose file is never built.
  has_tool() { command -v "${1}" >/dev/null 2>&1; }
  run report_stack
  [ "${status}" -eq 0 ]
  assert_match "no compose file" 'no candidate holds' "${output}"
  assert_not_match "no ps" ' ps$' "${output}"
}

@test "dev-stack: report_urls prints the four origins and where the password lives" {
  load_fn scripts/lib/common.sh env_get
  load_fn scripts/dev-stack.sh report_urls
  ENV_FILE="${BATS_TEST_TMPDIR}/dev-stack.env"
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
  cat >"${ENV_FILE}" <<'ENV'
STACK_LAN_HOST=box.example
CODER_HTTP_PORT=13001
LITELLM_PORT=14000
KASM_UI_PORT=14443
HOMEPAGE_HTTPS_PORT=1443
STACK_DASHBOARD_URL=https://dashboard.example
STACK_CODER_URL=https://coder.example
STACK_LITELLM_URL=http://litellm.example:14000
HOMEPAGE_AUTH_PASSWORD=s3cr3t-not-printed
ENV
  run report_urls
  [ "${status}" -eq 0 ]
  assert_match "dashboard origin" '^dashboard: https://dashboard.example$' "${output}"
  assert_match "litellm origin" '^litellm: +http://litellm.example:14000$' "${output}"
  assert_match "password lives" 'HOMEPAGE_AUTH_PASSWORD in .*/dev-stack.env' "${output}"
  assert_match "next command" '^next: +bazelisk run //scripts:dev-stack -- logs' "${output}"
  assert_not_match "no secret" 's3cr3t-not-printed' "${output}"

  # An env file that does not exist keeps the port fallbacks, not empty URLs.
  # The load_fn copies run with Bats' own options; the strict-shell duplicate
  # of this case lives in the next test, where production's errexit is active.
  ENV_FILE="${BATS_TEST_TMPDIR}/missing.env"
  run report_urls
  assert_match "fallback dashboard" '^dashboard: https://localhost:443$' "${output}"
  assert_match "fallback coder" '^coder: +https://localhost:3001$' "${output}"
}

@test "dev-stack: report_urls survives a missing env file under strict shell options" {
  # Production runs report_urls inside `set -euo pipefail`, where a failing
  # env_get would abort the whole script on a fresh clone (no .env yet). The
  # driver below reproduces those options so `run` can never mask the abort:
  # sourcing common.sh is exactly what dev-stack.sh itself does.
  local f="${BATS_TEST_TMPDIR}/strict-report-urls.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
      "source '${REPO_ROOT}/scripts/lib/common.sh'" \
      "source '${REPO_ROOT}/tests/test_helpers.sh'" \
      "load_shell_function '${REPO_ROOT}/scripts/dev-stack.sh' report_urls" \
      "ENV_FILE='${BATS_TEST_TMPDIR}/missing.env'" \
      "COMPOSE_FILE='${REPO_ROOT}/docker-compose.yml'" \
      'report_urls'
  } > "${f}"
  chmod +x "${f}"
  run --separate-stderr bash "${f}"
  [ "${status}" -eq 0 ]
  assert_match "fallback dashboard" '^dashboard: https://localhost:443$' "${output}"
  assert_match "fallback coder" '^coder: +https://localhost:3001$' "${output}"
  assert_match "next command" '^next: +bazelisk run //scripts:dev-stack -- logs' "${output}"
}

@test "dev-stack: run_compose refuses to guess and prints the command it runs" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/dev-stack.sh compose_cli
  load_fn scripts/dev-stack.sh run_compose
  PROJECT="evo-t1-dev"
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
  ENV_FILE=""

  has_tool() { return 1; }
  run --separate-stderr run_compose ps
  [ "${status}" -eq 1 ]
  assert_match "refused" 'no compose CLI' "${stderr}"

  has_tool() { command -v "${1}" >/dev/null 2>&1; }
  run --separate-stderr run_compose logs --tail 20 coder
  [ "${status}" -eq 0 ]
  # The project name and the compose file travel with the subcommand: compose
  # reads them before it, and a call that leaves them out addresses whichever
  # project the calling folder implies, so this pins the whole command line.
  assert_match "command line" \
    'docker compose -p evo-t1-dev -f .*/docker-compose\.yml logs --tail 20 coder' "${output}"
  assert_match "service forwarded" ' -p evo-t1-dev -f .*/docker-compose\.yml logs --tail 20 coder$' \
    "$(stub_log docker)"
}
