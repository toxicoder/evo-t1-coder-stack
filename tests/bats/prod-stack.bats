#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## prod-stack.bats — hermetic coverage for scripts/prod-stack.sh.
#
# Four things are pinned here, because they are the whole contract of the
# script: the compose project defaults to evo-t1-prod and --project-name
# renames it (including to the checkout-folder name a stack brought up by hand
# lives under), an unknown subcommand is a usage error rather than an
# arbitrary action, `status` answers with one-line reports when the docker CLI
# is dead (both CLI spellings resolve through the tool stubs, which can be
# forced to refuse every probe with STUB_DOCKER_RC=1 — test hosts may carry a
# real CLI and a live daemon), and `reset` refuses to destroy a stack without
# its confirmation flag. The env-file half is pinned too: no auto-pick (unlike
# dev-stack and its dev-stack.env), and the URL report reads the .env beside
# the compose file when --env-file names none.
#
# The whole suite skips while scripts/prod-stack.sh is absent: a suite for a
# script that does not exist yet has no right to fail the gate.
#
# docker and docker-compose are stubs. Nothing here creates a compose project
# or talks to a daemon.
#
# Usage: bazelisk test //tests:bats_prod_stack_test   (from any cwd)

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
STACK=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  STACK="${REPO_ROOT}/scripts/prod-stack.sh"
  if [ ! -f "${STACK}" ]; then
    skip "scripts/prod-stack.sh is not in the tree"
  fi
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker docker-compose
  # `up` refuses before compose when a clock file the coder service bind-mounts
  # read-only has no source on this host (scripts/lib/host_state.sh:
  # host_clock_files_report), and the compose file every `up` test copies names
  # the literal /etc/timezone, which a host may genuinely not ship. Point both
  # seams at names no scratch compose file here contains, so the preflight skips
  # and those tests drive compose exactly as they did before. The clock tests
  # below move the two seams onto fixtures they own.
  export HOST_TIMEZONE_FILE="${BATS_TEST_TMPDIR}/clock-skipped-timezone"
  export HOST_LOCALTIME_LINK="${BATS_TEST_TMPDIR}/clock-skipped-localtime"
}

@test "prod-stack: an unknown subcommand prints the usage and touches nothing" {
  run --separate-stderr bash "${STACK}" destroy
  [ "${status}" -ne 0 ]
  assert_match "usage" 'usage: bazelisk run //scripts:prod-stack --' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
  [ "$(stub_log_count docker-compose)" -eq 0 ]
}

@test "prod-stack: status reports an unresponsive docker CLI and still exits 0" {
  # Same hermetic shape as dev-stack.bats: STUB_DOCKER_RC=1 makes the stubs
  # refuse every probe (info, compose version, ps), so no daemon is reachable
  # from here and the report keeps its one-line answers.
  run --separate-stderr env STUB_DOCKER_RC=1 bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "daemon line" 'daemon: not reachable' "${output}"
  assert_match "project line" '^project: evo-t1-prod$' "${output}"
}

@test "prod-stack: the compose project is evo-t1-prod unless --project-name says otherwise" {
  run --separate-stderr bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "default project" 'evo-t1-prod' "$(stub_log docker)$(stub_log docker-compose)"
}

@test "prod-stack: --project-name renames the compose project it addresses" {
  # The rename case is not cosmetic: a stack brought up by hand lives under the
  # checkout folder's name, and naming that folder here addresses exactly it.
  run --separate-stderr bash "${STACK}" status --project-name evo-t1-stable
  [ "${status}" -eq 0 ]
  assert_match "renamed project" 'evo-t1-stable' "$(stub_log docker)$(stub_log docker-compose)"
  assert_not_match "default name" 'evo-t1-prod' "$(stub_log docker)$(stub_log docker-compose)"
}

@test "prod-stack: reset without the confirmation flag destroys nothing" {
  run --separate-stderr bash "${STACK}" reset
  assert_match "refused" 'confirm' "${output}"
  assert_not_match "no teardown" '(^| )down( |$)' "$(stub_log docker)$(stub_log docker-compose)"
}

@test "prod-stack: logs passes --tail, --follow and any service names to compose" {
  run --separate-stderr bash "${STACK}" logs --tail 200 coder
  [ "${status}" -eq 0 ]
  assert_match "tail and service" '\-p evo-t1-prod .*-f .*/docker-compose\.yml logs --tail 200 coder$' "${output}"

  # A renamed project has to reach compose whatever side of the subcommand the
  # flags sit on (make prod-stack-logs spells the same call with --project-name
  # between the subcommand and the tail).
  run --separate-stderr bash "${STACK}" logs --project-name evo-t1-stable --tail 200 coder
  [ "${status}" -eq 0 ]
  assert_match "renamed project" '\-p evo-t1-stable .*-f .*/docker-compose\.yml logs --tail 200 coder$' "${output}"

  # -f belongs to --file; --follow is the flag that follows, and it is the one
  # the usage block advertises.
  run --separate-stderr bash "${STACK}" logs --follow --tail 5 coder litellm
  [ "${status}" -eq 0 ]
  assert_match "follow" '\-f .*/docker-compose\.yml logs -f --tail 5 coder litellm$' "${output}"
}

@test "prod-stack: OBSERVABILITY_ENABLED decides whether compose is told about the profile" {
  # Same seam as dev-stack: the six bundle services carry
  # profiles: ["observability"] in docker-compose.yml, so --profile is what makes
  # a `up`/`down`/`logs` call about them at all. One key, read in one place, so
  # no verb can disagree with another about which stack it addresses.
  local log="${STUB_LOG}/docker.log"

  : >"${log}"
  run --separate-stderr env OBSERVABILITY_ENABLED=false bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_not_match "off: no profile word reaches compose" 'observability' "$(stub_log docker)"

  : >"${log}"
  run --separate-stderr env OBSERVABILITY_ENABLED=true bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_match "on: the two profile words reach compose in order" \
    '\-p evo-t1-prod --profile observability -f .*/docker-compose\.yml logs --tail 20 coder$' \
    "$(stub_log docker)"

  # Unset means on, because that is what .env.example ships.
  : >"${log}"
  run --separate-stderr env -u OBSERVABILITY_ENABLED bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_match "unset: on by default" \
    '\-\-profile observability -f .*/docker-compose\.yml logs --tail 20 coder$' "$(stub_log docker)"

  # A typo is off, not on: an unset-looking value must not publish metrics.
  : >"${log}"
  run --separate-stderr env OBSERVABILITY_ENABLED=maybe bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_not_match "junk: treated as off" 'observability' "$(stub_log docker)"
}

@test "prod-stack: INFISICAL_ENABLED decides whether compose is told about the secrets profile" {
  # Same seam as dev-stack: the vault's three services carry
  # profiles: ["secrets"] in docker-compose.yml, so compose_prefix/run_compose
  # append what compose_infisical_args prints (scripts/lib/infisical.sh:329)
  # after the observability words and before -f, on every verb.
  local log="${STUB_LOG}/docker.log"

  : >"${log}"
  run --separate-stderr env INFISICAL_ENABLED=false bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_not_match "off: no profile word reaches compose" 'secrets' "$(stub_log docker)"

  : >"${log}"
  run --separate-stderr env INFISICAL_ENABLED=true bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_match "on: the four profile words reach compose in order" \
    '\-p evo-t1-prod --profile observability --profile secrets -f .*/docker-compose\.yml logs --tail 20 coder$' \
    "$(stub_log docker)"

  # Unset is the shipped default and it means OFF here, the deliberate asymmetry
  # with OBSERVABILITY_ENABLED above, which answers ON to the same unset. One call
  # settles both halves: the bundle is addressed, the vault is not.
  : >"${log}"
  run --separate-stderr env -u INFISICAL_ENABLED bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_match "unset: off by default while the bundle stays on" \
    '\-\-profile observability -f .*/docker-compose\.yml logs --tail 20 coder$' "$(stub_log docker)"
  assert_not_match "unset: no secrets word reaches compose" 'secrets' "$(stub_log docker)"

  # A typo is off, not on: an unset-looking value must not start the vault.
  : >"${log}"
  run --separate-stderr env INFISICAL_ENABLED=maybe bash "${STACK}" logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_not_match "junk: treated as off" 'secrets' "$(stub_log docker)"
}

# --- the vault feeds the env file compose renders from --------------------------
# `up` is the seam: when INFISICAL_ENABLED is on it refreshes the env file from
# Infisical before compose interpolates it, so a credential rotated in the vault
# reaches coder, litellm, homepage, hermes, grafana and searxng on that bring-up
# instead of waiting for a human to run the pull verb. What is pinned here is the
# call the deploy makes - the fetch itself is pinned in infisical_lib.bats - so the
# driver replaces infisical_pull with a recorder that cannot reach a vault. Each
# call it takes appends the env-file argument to $PULL_LOG and answers $VAULT_RC.

vault_up_driver() {
  local f="${BATS_TEST_TMPDIR}/vault-up.sh"
  cat >"${f}" <<'DRV'
#!/usr/bin/env bash
source "$1"
shift
infisical_pull() {
  printf '%s\n' "${1:-}" >>"${PULL_LOG}"
  return "${VAULT_RC:-0}"
}
main "$@"
DRV
  printf '%s' "${f}"
}

# vault_workspace - a scratch checkout holding only what `up` needs to resolve.
vault_workspace() {
  local workspace="${1}"
  mkdir -p "${workspace}"
  cp "${REPO_ROOT}/docker-compose.yml" "${workspace}/docker-compose.yml"
  printf 'CODER_HTTP_PORT=13001\n' >"${workspace}/.env"
}

@test "prod-stack: up pulls the env file from the vault before compose renders" {
  # The stable stack names no env file of its own, so the file the vault has to
  # feed is the .env beside the compose file - the one compose interpolates - and
  # the fetch must land before `up -d`, because compose resolves ${VAR} at parse
  # time. An explicit --env-file is the same seam with a different path.
  workspace="$(make_scratch)/workspace"
  vault_workspace "${workspace}"
  pull_log="${BATS_TEST_TMPDIR}/pulls.log"
  : >"${pull_log}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    INFISICAL_ENABLED=true PULL_LOG="${pull_log}" VAULT_RC=0 \
    bash "$(vault_up_driver)" "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_match "phase line" '^-> vault: refreshing the env file from Infisical$' "${output}"
  assert_eq "exactly one pull" "1" "$(wc -l <"${pull_log}" | tr -d '[:space:]')"
  assert_eq "the file compose reads" "${workspace}/.env" "$(cat "${pull_log}")"

  local phase_line compose_line
  phase_line="$(grep -nF -e '-> vault: refreshing' <<<"${output}" | head -n1 | cut -d: -f1 || true)"
  compose_line="$(grep -nF -e 'up -d' <<<"${output}" | head -n1 | cut -d: -f1 || true)"
  [ -n "${phase_line}" ] && [ -n "${compose_line}" ]
  [ "${phase_line}" -lt "${compose_line}" ]

  # A named env file outranks the fallback, and it is that file, not the default
  # one, that has to be refreshed.
  : >"${pull_log}"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    INFISICAL_ENABLED=true PULL_LOG="${pull_log}" VAULT_RC=0 \
    bash "$(vault_up_driver)" "${STACK}" up --env-file "${workspace}/custom.env"
  [ "${status}" -eq 0 ]
  assert_eq "one pull of the named file" "${workspace}/custom.env" "$(cat "${pull_log}")"
}

@test "prod-stack: up with the vault flag off fetches nothing and says nothing about it" {
  # Off is the shipped default, and the off path is byte-identical to the one that
  # predates the vault: no call, no phase line, no warning. The `infisical:` row in
  # the endpoint summary is not part of this branch - it is an URL line that prints
  # whatever the flag says - so the assertions name the fetch, not the report.
  workspace="$(make_scratch)/workspace"
  vault_workspace "${workspace}"
  pull_log="${BATS_TEST_TMPDIR}/pulls.log"

  : >"${pull_log}"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    INFISICAL_ENABLED=false PULL_LOG="${pull_log}" VAULT_RC=0 \
    bash "$(vault_up_driver)" "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_eq "false: no pull" "0" "$(wc -l <"${pull_log}" | tr -d '[:space:]')"
  assert_not_match "false: no phase line" 'vault' "${output}"
  assert_not_match "false: no vault warning" 'not refreshed from Infisical' "${output}"
  assert_match "false: compose still runs" 'up -d' "$(stub_log docker)"

  # Unset is what a fresh clone carries, and it means off here.
  : >"${pull_log}"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE -u INFISICAL_ENABLED \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    PULL_LOG="${pull_log}" VAULT_RC=0 \
    bash "$(vault_up_driver)" "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_eq "unset: no pull" "0" "$(wc -l <"${pull_log}" | tr -d '[:space:]')"
  assert_not_match "unset: no phase line" 'vault' "${output}"
  assert_match "unset: compose still runs" 'up -d' "$(stub_log docker)"
}

@test "prod-stack: an unreachable vault is one warning and the stack comes up anyway" {
  # The stable stack coming down because its vault is unreachable would be worse
  # than a stale credential, so a failed fetch is one warning that names the file
  # and the retry - never a key, and never a value.
  workspace="$(make_scratch)/workspace"
  vault_workspace "${workspace}"
  pull_log="${BATS_TEST_TMPDIR}/pulls.log"
  : >"${pull_log}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    INFISICAL_ENABLED=true PULL_LOG="${pull_log}" VAULT_RC=1 \
    bash "$(vault_up_driver)" "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_eq "still exactly one attempt" "1" "$(wc -l <"${pull_log}" | tr -d '[:space:]')"
  assert_match "one warning naming the file" \
    '^warning: the env file was not refreshed from Infisical; .*/\.env keeps the credentials it already has' \
    "${output}"
  assert_eq "one such warning" "1" \
    "$(grep -c -e 'not refreshed from Infisical' <<<"${output}" || true)"
  assert_match "it names the retry" \
    'bazelisk run //scripts:infisical -- pull' "${output}"
  assert_match "the bring-up continued" 'up -d' "$(stub_log docker)"
  assert_match "the summary still closes the run" '^summary: ' "${output}"
}

@test "prod-stack: an env file given with --env-file travels to compose and to the report" {
  scratch="$(make_scratch)"
  cat >"${scratch}/custom.env" <<'ENV'
STACK_LAN_HOST=box.example
CODER_HTTP_PORT=13001
ENV
  run --separate-stderr bash "${STACK}" status --env-file "${scratch}/custom.env"
  [ "${status}" -eq 0 ]
  assert_match "env file reported" 'env-file: .*custom\.env' "${output}"
  assert_match "env file forwarded" '\-\-env-file .*/custom\.env' "$(stub_log docker)"
}

# ── Helper-level coverage ----------------------------------------------------
# The seven tests above drive the script as a whole; the four below load one
# helper at a time (tests/extract_fn.py), because //tests:shell_inventory fails
# when a function under scripts/ is named by no asserting test. docker and
# docker-compose are still stubs: nothing here reaches a daemon.

load_fn() {
  load_shell_function "${REPO_ROOT}/$1" "$2"
}

@test "prod-stack: resolve_repo_root needs a compose file AND a docker CLI" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/prod-stack.sh resolve_repo_root
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

@test "prod-stack: resolve_repo_root prefers BUILD_WORKSPACE_DIRECTORY over PWD" {
  # bazelisk run sets cwd to the runfiles copy (which has docker-compose.yml)
  # and BUILD_WORKSPACE_DIRECTORY to the checkout. Compose bind mounts and
  # `.env` have to come from the checkout: proxy/certs/ is bazelignored.
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/prod-stack.sh resolve_repo_root
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

@test "prod-stack: status reports the BUILD_WORKSPACE_DIRECTORY compose file" {
  workspace="$(make_scratch)/workspace"
  mkdir -p "${workspace}"
  cp "${REPO_ROOT}/docker-compose.yml" "${workspace}/docker-compose.yml"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" bash "${STACK}" status
  [ "${status}" -eq 0 ]
  assert_match "workspace compose file" "file: ${workspace}/docker-compose.yml" "${output}"
}

@test "prod-stack: compose_cli and compose_prefix name the CLI and the project" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/prod-stack.sh compose_cli
  [ "$(compose_cli)" = "docker compose" ]

  PROJECT="evo-t1-stable"
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
  ENV_FILE=""
  load_fn scripts/prod-stack.sh compose_prefix
  # The prefix asks the flag helper for the profile words, so the helper is
  # loaded with it: load_shell_function pulls one function, never its closure.
  load_fn scripts/lib/common.sh compose_observability_args
  load_fn scripts/lib/common.sh env_get
  load_fn scripts/lib/common.sh truthy
  # Off: the argv this suite pinned before the bundle existed, which is what a
  # stack that does not want the metrics services still runs.
  OBSERVABILITY_ENABLED=false
  assert_eq "no env file" \
    "docker compose -p evo-t1-stable -f ${REPO_ROOT}/docker-compose.yml" \
    "$(compose_prefix)"
  # Unset: on by default, with the two profile words between -p and -f so the
  # printed prefix is the command `status` reports and an operator can paste.
  unset OBSERVABILITY_ENABLED
  assert_eq "default on carries the profile" \
    "docker compose -p evo-t1-stable --profile observability -f ${REPO_ROOT}/docker-compose.yml" \
    "$(compose_prefix)"
  ENV_FILE="${BATS_TEST_TMPDIR}/custom.env"
  assert_match "env file" '\-\-env-file .*/custom\.env' "$(compose_prefix)"
}

@test "prod-stack: report_stack reports a missing docker and an unproven root" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/lib/common.sh env_get
  PROJECT="evo-t1-prod"
  COMPOSE_FILE=""
  ENV_FILE=""
  load_fn scripts/prod-stack.sh report_stack
  load_fn scripts/prod-stack.sh compose_cli
  load_fn scripts/prod-stack.sh compose_prefix
  # report_stack builds its `command:` line through compose_prefix, which needs
  # the profile helper present even in the branches that never print it.
  load_fn scripts/lib/common.sh compose_observability_args
  load_fn scripts/lib/common.sh truthy

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

@test "prod-stack: report_urls prints the origins and where the password lives" {
  load_fn scripts/lib/common.sh env_get
  load_fn scripts/prod-stack.sh report_urls
  ENV_FILE="${BATS_TEST_TMPDIR}/prod-stack.env"
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
  cat >"${ENV_FILE}" <<'ENV'
STACK_LAN_HOST=box.example
CODER_HTTP_PORT=13001
LITELLM_PORT=14000
KASM_UI_PORT=14443
HOMEPAGE_HTTPS_PORT=1443
GRAFANA_PORT=13005
PROMETHEUS_PORT=19090
STACK_DASHBOARD_URL=https://dashboard.example
STACK_CODER_URL=https://coder.example
STACK_LITELLM_URL=http://litellm.example:14000
HOMEPAGE_AUTH_PASSWORD=s3cr3t-not-printed
ENV
  run report_urls
  [ "${status}" -eq 0 ]
  assert_match "dashboard origin" '^dashboard: https://dashboard.example$' "${output}"
  assert_match "litellm origin" '^litellm: +http://litellm.example:14000$' "${output}"
  assert_match "hermes origin" '^hermes: +http://box.example:9119$' "${output}"
  assert_match "password lives" 'HOMEPAGE_AUTH_PASSWORD in .*/prod-stack.env' "${output}"
  assert_match "next command" '^next: +bazelisk run //scripts:prod-stack -- logs' "${output}"
  assert_not_match "no secret" 's3cr3t-not-printed' "${output}"

  # An env file that does not exist keeps the port fallbacks, not empty URLs.
  # The load_fn copies run with Bats' own options; the strict-shell duplicate
  # of this case lives in the next test, where production's errexit is active.
  ENV_FILE="${BATS_TEST_TMPDIR}/missing.env"
  run report_urls
  assert_match "fallback dashboard" '^dashboard: https://localhost:443$' "${output}"
  assert_match "fallback coder" '^coder: +https://localhost:3001$' "${output}"
  assert_match "fallback hermes" '^hermes: +http://localhost:9119$' "${output}"
}

@test "prod-stack: report_urls survives a missing env file under strict shell options" {
  # Production runs report_urls inside `set -euo pipefail`, where a failing
  # env_get would abort the whole script on a fresh clone (no .env yet). The
  # driver below reproduces those options so `run` can never mask the abort:
  # sourcing common.sh is exactly what prod-stack.sh itself does.
  local f="${BATS_TEST_TMPDIR}/strict-report-urls.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
      "source '${REPO_ROOT}/scripts/lib/common.sh'" \
      "source '${REPO_ROOT}/tests/test_helpers.sh'" \
      "load_shell_function '${REPO_ROOT}/scripts/prod-stack.sh' report_urls" \
      "ENV_FILE='${BATS_TEST_TMPDIR}/missing.env'" \
      "COMPOSE_FILE='${REPO_ROOT}/docker-compose.yml'" \
      'report_urls'
  } > "${f}"
  chmod +x "${f}"
  run --separate-stderr bash "${f}"
  [ "${status}" -eq 0 ]
  assert_match "fallback dashboard" '^dashboard: https://localhost:443$' "${output}"
  assert_match "fallback coder" '^coder: +https://localhost:3001$' "${output}"
  assert_match "fallback hermes" '^hermes: +http://localhost:9119$' "${output}"
  assert_match "next command" '^next: +bazelisk run //scripts:prod-stack -- logs' "${output}"
}

@test "prod-stack: run_compose refuses to guess and prints the command it runs" {
  load_fn scripts/lib/common.sh has_tool
  load_fn scripts/prod-stack.sh compose_cli
  load_fn scripts/prod-stack.sh run_compose
  load_fn scripts/lib/common.sh compose_observability_args
  load_fn scripts/lib/common.sh env_get
  load_fn scripts/lib/common.sh truthy
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
  ENV_FILE=""

  has_tool() { return 1; }
  run --separate-stderr run_compose ps
  [ "${status}" -eq 1 ]
  assert_match "refused" 'no compose CLI' "${stderr}"

  has_tool() { command -v "${1}" >/dev/null 2>&1; }
  # Off path: OBSERVABILITY_ENABLED=false leaves the argv exactly as it was
  # before the bundle existed, so a stack that does not want it pays nothing.
  OBSERVABILITY_ENABLED=false
  run --separate-stderr run_compose logs --tail 20 coder
  [ "${status}" -eq 0 ]
  # The project name and the compose file travel with the subcommand: compose
  # reads them before it, and a call that leaves them out addresses whichever
  # project the calling folder implies, so this pins the whole command line.
  assert_match "command line" \
    'docker compose -p evo-t1-prod -f .*/docker-compose\.yml logs --tail 20 coder' "${output}"
  assert_match "service forwarded" ' -p evo-t1-prod -f .*/docker-compose\.yml logs --tail 20 coder$' \
    "$(stub_log docker)"

  # On path (the default): the same argv plus the two profile words, and only
  # them, between the project selector and -f.
  unset OBSERVABILITY_ENABLED
  : >"${STUB_LOG}/docker.log"
  run --separate-stderr run_compose logs --tail 20 coder
  [ "${status}" -eq 0 ]
  assert_match "command line with the profile" \
    'docker compose -p evo-t1-prod --profile observability -f .*/docker-compose\.yml logs --tail 20 coder' "${output}"
  assert_match "profile reached compose" \
    ' -p evo-t1-prod --profile observability -f .*/docker-compose\.yml logs --tail 20 coder$' \
    "$(stub_log docker)"
}

@test "prod-stack: up restarts coder when recent logs show postgres password auth failure" {
  workspace="$(make_scratch)/workspace"
  mkdir -p "${workspace}"
  cp "${REPO_ROOT}/docker-compose.yml" "${workspace}/docker-compose.yml"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" \
    STUB_COMPOSE_LOGS='pq: password authentication failed for user "coder"' \
    bash "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_match "compose up" 'up -d' "$(stub_log docker)"
  assert_match "read coder logs" 'logs --tail 30 coder' "$(stub_log docker)"
  assert_match "bounced coder" 'restart coder' "$(stub_log docker)"
  assert_match "announced" 'restarting coder' "${output}"
}

@test "prod-stack: up does not restart coder when postgres auth is clean" {
  workspace="$(make_scratch)/workspace"
  mkdir -p "${workspace}"
  cp "${REPO_ROOT}/docker-compose.yml" "${workspace}/docker-compose.yml"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" \
    STUB_COMPOSE_LOGS='Started HTTP listener at http://0.0.0.0:3000' \
    bash "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_match "compose up" 'up -d' "$(stub_log docker)"
  assert_not_match "no bounce" 'restart coder' "$(stub_log docker)"
}

@test "prod-stack: up prints db logs when compose up fails" {
  workspace="$(make_scratch)/workspace"
  mkdir -p "${workspace}"
  cp "${REPO_ROOT}/docker-compose.yml" "${workspace}/docker-compose.yml"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" \
    STUB_COMPOSE_UP_RC=1 \
    STUB_COMPOSE_LOGS='dependency failed to start: container evo-t1-prod-db-1 is unhealthy' \
    bash "${STACK}" up
  [ "${status}" -ne 0 ]
  assert_match "compose up" 'up -d' "$(stub_log docker)"
  assert_match "db logs" 'logs --tail 80 db' "$(stub_log docker)"
  assert_match "note" 'last db logs follow' "${stderr}"
  assert_match "unhealthy body" 'evo-t1-prod-db-1 is unhealthy' "${output}"
  assert_not_match "no bounce" 'restart coder' "$(stub_log docker)"
}

# --- the clock binds are proven before compose is asked -------------------------
# The coder service bind-mounts the host's timezone file and localtime link
# read-only, both with bind.create_host_path: false, so a host that ships neither
# used to fail mid-`up`: the daemon refused the create partway through the
# project, its line named no remedy, and the only advice this verb then printed
# was the db logs. `up` asks that question before compose runs, so what is pinned
# here is the refusal (the fix line, nothing created, the vault never dialed), the
# untouched bring-up on a host that does carry both sources, and the two shapes
# the guard has to stay silent about: a compose file that binds neither path, and
# a source spelled as an interpolation.
#
# Every fixture lives in the compose file, not just on disk: before the check
# looks at the host it asks host_state.sh:compose_binds_host_path whether a bind
# SOURCE names that path exactly, and skips a path that file does not bind. That
# is also how the setup() seam keeps the other `up` tests off this path - the
# seams name paths no compose file here binds. So a refusing case writes the
# fixture path into a `source:` line, and a proceeding case either turns that
# record into a comment or spells it so this shell cannot resolve it.

# clock_workspace <workspace> <tz_src> <localtime_src> - a scratch checkout whose
# compose file names the two clock bind sources at the paths the test hands it.
clock_workspace() {
  local workspace="${1}" tz_src="${2}" localtime_src="${3}"
  mkdir -p "${workspace}"
  sed -e "s|/etc/timezone|${tz_src}|g" \
    -e "s|/etc/localtime|${localtime_src}|g" \
    "${REPO_ROOT}/docker-compose.yml" >"${workspace}/docker-compose.yml"
}

# clock_workspace_unbound <workspace> <tz_src> <localtime_src> - a scratch
# checkout whose compose file keeps every coder-service mount but binds neither
# clock path: each long-form `source:` record becomes a comment that still names
# the host path, and the `target:` line stays under it. Reading the file as text
# would find both paths in it; only an exact bind-source reading tells a mount
# from a mention.
clock_workspace_unbound() {
  local workspace="${1}" tz_src="${2}" localtime_src="${3}"
  mkdir -p "${workspace}"
  sed -E \
    -e "s|^[[:space:]]*source:[[:space:]]*/etc/timezone[[:space:]]*\$|        # unbound: ${tz_src} stays inside the image|" \
    -e "s|^[[:space:]]*source:[[:space:]]*/etc/localtime[[:space:]]*\$|        # unbound: ${localtime_src} stays inside the image|" \
    "${REPO_ROOT}/docker-compose.yml" >"${workspace}/docker-compose.yml"
}

# clock_workspace_interpolated <workspace> <tz_src> <localtime_src> - a scratch
# checkout that binds the two clock paths the way a parameterised compose file
# does, as source: ${STACK_TZ:-<path>}. The guard reads no environment, so it
# cannot resolve either spelling.
clock_workspace_interpolated() {
  local workspace="${1}" tz_src="${2}" localtime_src="${3}"
  mkdir -p "${workspace}"
  sed -e "s|source: /etc/timezone|source: \${STACK_TZ:-${tz_src}}|" \
    -e "s|source: /etc/localtime|source: \${STACK_TZ:-${localtime_src}}|" \
    "${REPO_ROOT}/docker-compose.yml" >"${workspace}/docker-compose.yml"
}

# clock_zoneinfo <dir> - the one-zone tree the fix line names, under <dir>. The
# directory keeps the literal zoneinfo component because that component is what
# tells a zone name from a stray string when the fix line is composed.
clock_zoneinfo() {
  local dir="${1}"
  mkdir -p "${dir}/zoneinfo/Europe"
  : >"${dir}/zoneinfo/Europe/Berlin"
}

@test "prod-stack: up refuses before compose when the host lacks the timezone file it binds" {
  # The decisive assertion is the compose log: a refusal that arrived after
  # `up -d` would have created half a project and dumped the db logs, which is
  # the run this preflight exists to prevent. The localtime source is a live
  # symlink into the fake tree, so only the absent file is blamed.
  local workspace clock tz lt
  workspace="$(make_scratch)/workspace"
  clock="${BATS_TEST_TMPDIR}/clock"
  tz="${clock}/absent-timezone"
  lt="${clock}/host-localtime"
  clock_workspace "${workspace}" "${tz}" "${lt}"
  clock_zoneinfo "${clock}"
  ln -s "${clock}/zoneinfo/Europe/Berlin" "${lt}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "${STACK}" up
  [ "${status}" -ne 0 ]
  assert_match "the error names the missing source" \
    "^error: ${tz} does not exist on this host" "${stderr}"
  assert_match "it says why compose would refuse" \
    'the coder service bind-mounts it read-only with create_host_path: false, so docker compose will refuse the create' \
    "${stderr}"
  assert_not_match "the healthy source is not blamed" "^error: ${lt}" "${stderr}"

  local fix_line
  fix_line="$(grep -F -e "sudo tee ${tz} >/dev/null" <<<"${output}" | head -n1 || true)"
  assert_eq "the note carries the host command, naming the zone the host runs in" \
    "note: Fix on the host: printf '%s\n' Europe/Berlin | sudo tee ${tz} >/dev/null" "${fix_line}"
  assert_match "it names the one-shot repair" 'sudo dpkg-reconfigure tzdata writes both files' "${output}"
  assert_match "refused" 'compose up refused: this host lacks a clock file' "${stderr}"

  assert_not_match "compose never ran" 'up -d' "$(stub_log docker)"
  [ "$(stub_log_count docker)" -eq 0 ]
  assert_file_not_exists "nothing was created at the bind source" "${tz}"
}

@test "prod-stack: up comes up when the host carries both clock sources" {
  # The same compose file with both sources present: the preflight has nothing to
  # say, says nothing, and the bring-up is the run the three tests above pin.
  local workspace clock tz lt
  workspace="$(make_scratch)/workspace"
  clock="${BATS_TEST_TMPDIR}/clock"
  tz="${clock}/host-timezone"
  lt="${clock}/host-localtime"
  clock_workspace "${workspace}" "${tz}" "${lt}"
  clock_zoneinfo "${clock}"
  printf 'Europe/Berlin\n' >"${tz}"
  ln -s "${clock}/zoneinfo/Europe/Berlin" "${lt}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "${STACK}" up
  [ "${status}" -eq 0 ]
  assert_not_match "nothing is refused" 'compose up refused' "${output}${stderr}"
  assert_not_match "no fix note on a healthy host" 'Fix on the host' "${output}"
  assert_match "compose up" 'up -d' "$(stub_log docker)"
}

@test "prod-stack: up proceeds when the compose file binds neither clock path" {
  # A bring-up this host cannot satisfy is only a problem if something asks for
  # it. This compose file still names both missing paths - once in the comment
  # that replaced the bind and once as a `target:` - but binds neither, so
  # refusing here would block a create no one asked the daemon to make. The seams
  # name paths that do not exist on this host, which is what makes the guard's
  # reading of the file the only thing between this run and a dead bring-up.
  local workspace bound compose tz lt log
  workspace="$(make_scratch)/workspace"
  clock="${BATS_TEST_TMPDIR}/clock"
  tz="${clock}/absent-timezone"
  lt="${clock}/absent-localtime"
  clock_workspace_unbound "${workspace}" "${tz}" "${lt}"
  compose="${workspace}/docker-compose.yml"
  assert_contains_file "the missing path is still named in the file" "${compose}" "${tz}"
  assert_not_match "but no bind source names it" "source:[[:space:]]*${tz}" "$(cat "${compose}")"

  # The control that keeps the two assertions below honest: same host, same
  # seams, and the same two paths written as a bind source, which does refuse. A
  # run that proceeded here would mean the check never fired at all.
  clock_workspace "${workspace}-bound" "${tz}" "${lt}"
  bound="${workspace}-bound/docker-compose.yml"
  log="${STUB_LOG}/docker.log"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "${STACK}" up --file "${bound}"
  [ "${status}" -ne 0 ]
  assert_match "the bound spelling of the same paths is refused" \
    'compose up refused: this host lacks a clock file' "${stderr}"

  : >"${log}"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "${STACK}" up --file "${compose}"
  [ "${status}" -eq 0 ]
  assert_not_match "nothing is refused" 'compose up refused' "${output}${stderr}"
  assert_not_match "the preflight stayed silent" "^error: ${tz}" "${stderr}"
  assert_match "compose up" 'up -d' "$(stub_log docker)"
  assert_match "compose was handed that very file" \
    " -p evo-t1-prod -f ${compose} up -d\$" "$(stub_log docker)"
}

@test "prod-stack: up proceeds when a clock bind source is an interpolation" {
  # source: ${STACK_TZ:-<path>} is a source this shell cannot resolve without
  # running compose's own interpolation, and the guard reads no environment. It
  # answers "not bound" and stays out: holding the stack down over a value it
  # cannot see would be worse than letting compose - and the daemon behind it -
  # answer for the spelling the operator wrote. The fixture names the missing
  # path inside the interpolation, so only the unresolvable form keeps this run
  # off the refusal path.
  local workspace bound compose tz lt log
  workspace="$(make_scratch)/workspace"
  clock="${BATS_TEST_TMPDIR}/clock"
  tz="${clock}/absent-timezone"
  lt="${clock}/absent-localtime"
  clock_workspace_interpolated "${workspace}" "${tz}" "${lt}"
  compose="${workspace}/docker-compose.yml"
  assert_contains_file "the unresolvable source still names the path" "${compose}" \
    "source: .*STACK_TZ:-${tz}"

  # Same control as the case above: the literal spelling of those two sources,
  # which this host cannot satisfy, does refuse.
  clock_workspace "${workspace}-bound" "${tz}" "${lt}"
  bound="${workspace}-bound/docker-compose.yml"
  log="${STUB_LOG}/docker.log"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "${STACK}" up --file "${bound}"
  [ "${status}" -ne 0 ]
  assert_match "the bound spelling of the same paths is refused" \
    'compose up refused: this host lacks a clock file' "${stderr}"

  : >"${log}"
  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "${STACK}" up --file "${compose}"
  [ "${status}" -eq 0 ]
  assert_not_match "nothing is refused" 'compose up refused' "${output}${stderr}"
  assert_not_match "the preflight stayed silent" "^error: ${tz}" "${stderr}"
  assert_match "compose up" 'up -d' "$(stub_log docker)"
  assert_match "compose was handed that very file" \
    " -p evo-t1-prod -f ${compose} up -d\$" "$(stub_log docker)"
}

@test "prod-stack: a refused clock preflight dials neither the vault nor compose" {
  # The check sits before the vault pull, so the refusing run has to leave
  # PULL_LOG empty: fetching the managed credentials and then dying on a bind
  # mount is the run this ordering prevents.
  local workspace clock tz lt pull_log
  workspace="$(make_scratch)/workspace"
  clock="${BATS_TEST_TMPDIR}/clock"
  tz="${clock}/absent-timezone"
  lt="${clock}/host-localtime"
  clock_workspace "${workspace}" "${tz}" "${lt}"
  clock_zoneinfo "${clock}"
  ln -s "${clock}/zoneinfo/Europe/Berlin" "${lt}"
  pull_log="${BATS_TEST_TMPDIR}/pulls.log"
  : >"${pull_log}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    BUILD_WORKSPACE_DIRECTORY="${workspace}" OBSERVABILITY_ENABLED=false \
    INFISICAL_ENABLED=true PULL_LOG="${pull_log}" VAULT_RC=0 \
    HOST_TIMEZONE_FILE="${tz}" HOST_LOCALTIME_LINK="${lt}" \
    HOST_ZONEINFO_DIR="${clock}/zoneinfo" \
    bash "$(vault_up_driver)" "${STACK}" up
  [ "${status}" -ne 0 ]
  assert_eq "the vault was never dialed" "0" "$(wc -l <"${pull_log}" | tr -d '[:space:]')"
  assert_not_match "no vault phase line" 'vault: refreshing' "${output}"
  assert_match "refused" 'compose up refused: this host lacks a clock file' "${stderr}"
  assert_not_match "compose never ran" 'up -d' "$(stub_log docker)"
}

# --- public_deploy_env: composed public names for a stable deploy -------------
#
# The stable stack shares the composition library with dev-stack and differs from it
# in exactly one rule: it never invents an environment label. A stable install is
# the apex name, so `--project-name evo-t1-dev` must not quietly pull `-dev` into
# the production origin, the certificate SAN list, or the nginx vhosts. These tests
# call the function directly in a subshell: it only touches the environment, and the
# naming keys are cleared first because domain.sh reads the process environment and
# a leftover key would move every expected name.

composed_public_env() {
  local content="$1" project="${2:-evo-t1-prod}" process_label="${3:-}"
  local envf="${BATS_TEST_TMPDIR}/envfile"
  printf '%s' "${content}" >"${envf}"
  (
    set -uo pipefail
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/lib/common.sh"
    unset JSON_MODE
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/lib/domain.sh"
    PROJECT="${project}"
    ENV_FILE="${envf}"
    COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
    unset STACK_DOMAIN_BASE STACK_SUBDOMAIN_SUFFIX STACK_ENV_LABEL STACK_DASHBOARD_NAME
    unset STACK_CODER_NAME STACK_KASM_NAME STACK_LITELLM_NAME STACK_HERMES_NAME
    unset STACK_GRAFANA_NAME
    unset STACK_PUBLIC_HOSTS STACK_PUBLIC_HOSTS_MODE
    unset STACK_DASHBOARD_URL STACK_CODER_URL STACK_KASM_URL STACK_LITELLM_URL STACK_HERMES_URL
    unset STACK_GRAFANA_URL
    if [ -n "${process_label}" ]; then
      export STACK_ENV_LABEL="${process_label}"
    fi
    load_shell_function "${REPO_ROOT}/scripts/prod-stack.sh" public_deploy_env
    # The function only ever speaks on the failure path, so its stderr travels with
    # the four printed facts and a test can assert on the warning it emits.
    public_deploy_env "${envf}" 2>&1
    printf 'hosts=%s\n' "${STACK_PUBLIC_HOSTS:-<unset>}"
    printf 'coder=%s\n' "${STACK_CODER_URL:-<unset>}"
    printf 'hermes=%s\n' "${STACK_HERMES_URL:-<unset>}"
    # Bracketed, and with a sentinel only for a genuinely unset variable, so an
    # exported empty label (the stable shape) reads differently from no label at all.
    printf 'label=[%s]\n' "${STACK_ENV_LABEL-<unset>}"
  )
}

@test "prod-stack: auto mode composes the unlabelled names" {
  run composed_public_env 'STACK_PUBLIC_HOSTS=auto
'
  [ "${status}" -eq 0 ]
  assert_match "no label is invented" '^label=\[\]$' "${output}"
  assert_match "coder sits on the apex name" '^coder=https://coder-gmktecbeast\.overeazy\.io$' "${output}"
  assert_match "hermes sits on the apex name" '^hermes=https://hermes-gmktecbeast\.overeazy\.io$' "${output}"
  assert_match "the allow list carries it too" 'coder-gmktecbeast\.overeazy\.io' "${output}"
}

@test "prod-stack: a dev project name never pulls a dev label into the stable stack" {
  # The one rule that separates this from dev-stack, pinned: --project-name can
  # legitimately name any project, and a stable deploy stays on the apex name.
  run composed_public_env 'STACK_PUBLIC_HOSTS=auto
' evo-t1-dev
  [ "${status}" -eq 0 ]
  assert_match "no dev label" '^label=\[\]$' "${output}"
  assert_not_match "no dev-labelled name" 'coder-dev-' "${output}"
}

@test "prod-stack: a label from the env file is honoured, and a process label outranks it" {
  run composed_public_env 'STACK_PUBLIC_HOSTS=auto
STACK_ENV_LABEL=blue
'
  [ "${status}" -eq 0 ]
  assert_match "the file label is honoured" '^label=\[blue\]$' "${output}"
  assert_match "coder carries the label" '^coder=https://coder-blue-gmktecbeast\.overeazy\.io$' "${output}"

  run composed_public_env 'STACK_PUBLIC_HOSTS=auto
STACK_ENV_LABEL=blue
' evo-t1-prod green
  [ "${status}" -eq 0 ]
  assert_match "what the caller already had wins" '^label=\[green\]$' "${output}"
  assert_match "coder carries it" '^coder=https://coder-green-gmktecbeast\.overeazy\.io$' "${output}"
}

@test "prod-stack: an empty STACK_PUBLIC_HOSTS exports nothing at all" {
  run composed_public_env 'STACK_PUBLIC_HOSTS=
'
  [ "${status}" -eq 0 ]
  assert_match "hosts stay unset" '^hosts=<unset>$' "${output}"
  assert_match "no coder url" '^coder=<unset>$' "${output}"
  assert_match "no invented label" '^label=\[<unset>\]$' "${output}"
}

@test "prod-stack: a hand-written list is passed through with nothing exported" {
  run composed_public_env 'STACK_PUBLIC_HOSTS=coder-pin.example.com
STACK_CODER_URL=https://stale.example.com
'
  [ "${status}" -eq 0 ]
  assert_match "hosts stay unset" '^hosts=<unset>$' "${output}"
  assert_match "the file keeps its value" '^coder=<unset>$' "${output}"
  assert_not_match "no composed name leaks in" 'gmktecbeast' "${output}"
}

@test "prod-stack: parts that cannot compose keep the deploy LAN-only and say so" {
  run composed_public_env 'STACK_PUBLIC_HOSTS=auto
STACK_DOMAIN_BASE=not a domain!
'
  [ "${status}" -eq 0 ]
  assert_match "it warns rather than failing" 'warning:' "${output}"
  assert_match "and names the key to fix" 'STACK_DOMAIN_BASE' "${output}"
  assert_match "no names are exported" '^coder=<unset>$' "${output}"
}
