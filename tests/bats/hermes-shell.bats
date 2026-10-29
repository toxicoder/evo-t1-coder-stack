#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## hermes-shell.bats — the host-terminal door to the Hermes assistant.
#
# scripts/hermes-shell.sh opens the on-host assistant in the operator's terminal. The
# behaviour this suite pins is the behaviour that would silently hurt the operator:
#
#   - the terminal joins the RUNNING container, because two containers on one data
#     volume is how the assistant's memory store gets corrupted; only a stopped
#     container may be replaced by a `run --rm --no-deps` one-shot, and --one-shot says
#     so out loud;
#   - the command that is printed is the command that runs, project name and files
#     included, so reading one printed line is trustworthy;
#   - an interactive mode without a tty is refused instead of hanging, and --dry-run
#     never needs one;
#   - the readiness report answers without launching anything, never prints a secret
#     value, and names the command that fixes what it found.
#
# Usage: bazelisk test //tests:bats_hermes_shell_test   (from any cwd)
# Safety: drives the docker and curl CLIs through per-test stubs only; reads the
# checkout's scripts/hermes-shell.sh and writes nothing outside a scratch directory.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
SCRATCH=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/hermes-shell.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/hermes-shell.sh is not in the tree"
  fi
  # The report and the launch path use the shared report helpers; loading one function
  # out of the CLI brings no others with it, so the contract comes from the lib.
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"

  SCRATCH="$(make_scratch)"
  export STUB_LOG="${SCRATCH}/stub-logs"
  mkdir -p "${STUB_LOG}" "${SCRATCH}/bin" "${SCRATCH}/none" "${SCRATCH}/deploy"

  # A scratch compose project, so nothing in these tests reads the real stack.
  printf 'services:\n  hermes:\n    image: nousresearch/hermes-agent:v0.22.5\n' >"${SCRATCH}/compose.yml"
  printf 'LITELLM_MASTER_KEY=sekret-value\nLITELLM_PORT=4000\nSTACK_DEPLOY_PATH=%s/deploy\n' \
    "${SCRATCH}" >"${SCRATCH}/stack.env"

  write_docker_stub "${SCRATCH}/bin/docker"
  local curlbin
  curlbin="$(stub_bin curl)"
  PATH="$(with_path "${SCRATCH}/bin" "${curlbin}")"
  export PATH STUB_PS_OUT="" STUB_IMAGE_REF="" STUB_IMAGE_RC=0 STUB_VOLUME_NAME="" \
    STUB_VOLUME_MOUNT="" STUB_INFO_RC=0 STUB_VERSION_RC=0 STUB_SERVICES="" \
    STUB_SERVICES_ERR=0
}

# load_fns <name...> - pull each named production function out of the CLI into this
# shell, so a test can call one unit with its collaborators named explicitly. Loading a
# function brings no file-level state with it, so the globals every unit reads are set
# to the same values main() would have settled; a test overrides the ones it is about.
load_fns() {
  local name
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE=""
  SERVICE="hermes"
  MODEL=""
  WRITABLE=""
  ONE_SHOT=0
  DRY_RUN=0
  MODE="chat"
  EXTRA=()
  for name in "$@"; do
    load_shell_function "${SCRIPT}" "${name}"
  done
}

# write_docker_stub <path> - a docker CLI that answers the three questions
# hermes-shell.sh asks, from environment knobs, and records every argv.
#   STUB_PS_OUT      the container id `ps -q --status running` prints (empty = none)
#   STUB_SERVICES    what `config --services` lists (default: the assistant's service)
#   STUB_SERVICES_ERR 1 makes `config --services` fail, i.e. compose cannot answer
#   STUB_IMAGE_REF   the image under the assistant's own service in the `config <svc>`
#                    render (empty = that service declares none, i.e. unresolvable)
#   STUB_CONFIG_ERR  1 makes `config <svc>` fail, i.e. compose cannot render it
#   STUB_IMAGE_RC    0 = the image is on the host, 1 = it is not
#   STUB_VOLUME_NAME the volume `volume ls` finds (empty = no volume yet)
#   STUB_VOLUME_MOUNT its Mountpoint (empty = no path to read)
#   STUB_INFO_RC     non-zero makes `docker info` refuse, i.e. no reachable daemon
#   STUB_VERSION_RC  non-zero makes `docker compose version` fail
write_docker_stub() {
  local target="${1}"
  mkdir -p "$(dirname "${target}")"
  cat >"${target}" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "docker $*" >>"${STUB_LOG}/docker.log"; fi
case "$*" in
  *"compose version"*) exit "${STUB_VERSION_RC:-0}" ;;
  info | *" info "*) exit "${STUB_INFO_RC:-0}" ;;
  *"volume ls"*)
    if [ -n "${STUB_VOLUME_NAME:-}" ]; then printf '%s\n' "${STUB_VOLUME_NAME}"; fi
    exit 0
    ;;
  *"volume inspect"*)
    if [ -n "${STUB_VOLUME_MOUNT:-}" ]; then printf '%s\n' "${STUB_VOLUME_MOUNT}"; fi
    exit 0
    ;;
  *"image inspect"*) exit "${STUB_IMAGE_RC:-0}" ;;
  *"config --services"*)
    if [ "${STUB_SERVICES_ERR:-0}" = "1" ]; then exit 1; fi
    printf '%s\n' "${STUB_SERVICES:-hermes}"
    exit 0
    ;;
  *"config "*)
    # A rendered one-service document, in the shape `compose config <svc>` prints: the
    # asked service sits between two other services, each with its own image at the same
    # indent, and a decoy value inside it. A reader that does not scope to the service
    # block picks up postgres or litellm instead.
    if [ "${STUB_CONFIG_ERR:-0}" = "1" ]; then exit 1; fi
    asked="${*: -1}"
    printf 'name: evo-t1-prod\nservices:\n  db:\n    image: postgres:17\n'
    printf '  %s:\n' "${asked}"
    printf '    command:\n      - gateway\n'
    if [ -n "${STUB_IMAGE_REF:-}" ]; then printf '    image: %s\n' "${STUB_IMAGE_REF}"; fi
    printf '    labels:\n      note: image: decoy\n'
    printf '  litellm:\n    image: ghcr.io/berriai/litellm:v1.102.1\n'
    printf 'volumes:\n  hermes-data:\n'
    exit 0
    ;;
  *"ps -q --status running"*)
    if [ -n "${STUB_PS_OUT:-}" ]; then printf '%s\n' "${STUB_PS_OUT}"; fi
    exit 0
    ;;
esac
exit 0
STUB
  chmod 755 "${target}"
}

# run_shell <args...> - run the CLI against the scratch project, with no tty.
run_shell() {
  run bash "${SCRIPT}" \
    --file "${SCRATCH}/compose.yml" --env-file "${SCRATCH}/stack.env" "$@"
}

@test "hermes-shell: --help prints the usage, the subcommands, and runs nothing" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "usage line" 'usage: bazelisk run //scripts:hermes-shell' "${output}"
  assert_match "chat subcommand" 'chat       interactive session' "${output}"
  assert_match "check subcommand" 'check      readiness report' "${output}"
  assert_match "writable flag" '--writable' "${output}"
  assert_match "exit code contract" 'Exit codes: 0' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "hermes-shell: an unknown flag prints the usage and touches nothing" {
  run_shell --bogus
  [ "${status}" -ne 0 ]
  assert_match "names the flag" "unknown argument '--bogus'" "${output}"
  assert_match "usage printed" 'usage: bazelisk run //scripts:hermes-shell' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "hermes-shell: a flag with no value says which flag needs what" {
  run_shell --model
  [ "${status}" -ne 0 ]
  assert_match "model needs a value" '--model needs a LiteLLM alias' "${output}"
  run_shell --project-name
  [ "${status}" -ne 0 ]
  assert_match "project needs a value" '--project-name needs a name' "${output}"
  run_shell --writable
  [ "${status}" -ne 0 ]
  assert_match "writable needs a value" '--writable needs a directory' "${output}"
}

@test "hermes-shell: an unknown subcommand is refused with the usage" {
  run_shell bogus
  [ "${status}" -eq 2 ]
  assert_match "names the subcommand" "unknown subcommand 'bogus'" "${output}"
  assert_match "usage printed" 'usage: bazelisk run //scripts:hermes-shell' "${output}"
}

@test "hermes-shell: chat without a terminal is refused instead of hanging" {
  # bats gives the child no tty, which is exactly the pipe this refusal exists for.
  run_shell chat
  [ "${status}" -eq 1 ]
  assert_match "refuses without a tty" 'needs a real terminal' "${output}"
  assert_match "points at ask" "takes a one-line question without a tty" "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "hermes-shell: a running assistant is entered, never duplicated" {
  export STUB_PS_OUT="abc123"
  run_shell ask "why is the coder agent offline"
  [ "${status}" -eq 0 ]
  local last
  last="$(stub_log_last docker)"
  assert_match "enters the container" \
    ' exec hermes chat -q why is the coder agent offline$' "${last}"
  assert_match "same project" '-p evo-t1-prod' "${last}"
  assert_not_match "no second container" ' --rm ' "${last}"
}

@test "hermes-shell: a stopped assistant gets a one-shot that cleans up after itself" {
  export STUB_PS_OUT=""
  run_shell ask "which disk is full"
  [ "${status}" -eq 0 ]
  local last
  last="$(stub_log_last docker)"
  assert_match "runs a one-shot" ' run --rm --no-deps hermes chat -q which disk is full$' "${last}"
  assert_match "addresses the compose file" "-f ${SCRATCH}/compose[.]yml" "${last}"
}

@test "hermes-shell: --one-shot warns before it opens a second container" {
  export STUB_PS_OUT="abc123"
  run_shell --one-shot ask "hello"
  [ "${status}" -eq 0 ]
  assert_match "names the hazard" 'two containers on one data volume' "${output}"
  assert_match "still runs the one-shot" ' run --rm --no-deps hermes chat -q hello$' \
    "$(stub_log_last docker)"
}

@test "hermes-shell: --model and --writable travel to the container as environment" {
  run_shell --model agent-medium --writable /opt/stack-deploy ask "hello"
  [ "${status}" -eq 0 ]
  local last
  last="$(stub_log_last docker)"
  assert_match "model alias" '-e HERMES_MODEL=agent-medium' "${last}"
  assert_match "write-safe root" '-e HERMES_WRITE_SAFE_ROOT=/opt/stack-deploy' "${last}"
}

@test "hermes-shell: --dry-run prints the command and launches nothing" {
  run_shell --dry-run ask "hello"
  [ "${status}" -eq 0 ]
  assert_match "prints the whole command" 'dry run: docker compose -p evo-t1-prod' "${output}"
  assert_match "and the assistant argv" 'hermes chat -q hello' "${output}"
  # Only the report's read-only probes ran: never an exec and never a run.
  [ "$(stub_log_count docker)" -gt 0 ]
  run grep -E '(^| )(exec|run)( |$)' <<<"$(stub_log docker)"
  [ "${status}" -ne 0 ]
}

@test "hermes-shell: shell mode opens the assistant's own container shell" {
  export STUB_PS_OUT="abc123"
  run_shell --dry-run shell
  [ "${status}" -eq 0 ]
  assert_match "bash is the entry" 'exec hermes bash' "${output}"
}

@test "hermes-shell: extra words pass through to the assistant untouched" {
  run_shell --dry-run chat --tui --resume latest
  [ "${status}" -eq 0 ]
  assert_match "passes the flags on" 'hermes chat --tui --resume latest' "${output}"
}

@test "hermes-shell: check reports the box and launches nothing" {
  export STUB_PS_OUT="abc123" STUB_IMAGE_REF="nousresearch/hermes-agent:v0.22.5"
  export STUB_VOLUME_NAME="evo-t1-prod_hermes-data" STUB_VOLUME_MOUNT="${SCRATCH}/volume"
  export STUB_CURL_RC=0
  mkdir -p "${SCRATCH}/volume"
  printf 'x\n' >"${SCRATCH}/volume/config.yaml"
  printf 'x\n' >"${SCRATCH}/volume/SOUL.md"

  run_shell check
  [ "${status}" -eq 0 ]
  assert_match "daemon line" 'docker: daemon reachable' "${output}"
  assert_match "project line" 'project: evo-t1-prod' "${output}"
  assert_match "container line" 'container: running' "${output}"
  assert_match "service line" 'service: hermes' "${output}"
  assert_match "image line" 'image: nousresearch/hermes-agent:v0.22.5 \(present\)' "${output}"
  assert_match "seeded volume" "data volume: ${SCRATCH}/volume \(seeded\)" "${output}"
  assert_match "key is present" 'litellm key: set in' "${output}"
  assert_match "model door answers" 'model door: LiteLLM answers' "${output}"
  assert_match "work dir present" "work dir: ${SCRATCH}/deploy \(present\)" "${output}"
  assert_match "closing summary" 'summary: ' "${output}"
  assert_not_match "the secret value stays home" 'sekret-value' "${output}"
  run grep -E '(^| )(exec|run)( |$)' <<<"$(stub_log docker)"
  [ "${status}" -ne 0 ]
}

@test "hermes-shell: an unseeded volume names the reseed command" {
  export STUB_VOLUME_NAME="evo-t1-prod_hermes-data" STUB_VOLUME_MOUNT="${SCRATCH}/empty-volume"
  mkdir -p "${SCRATCH}/empty-volume"
  run_shell check
  [ "${status}" -eq 0 ]
  assert_match "says unseeded" '\(unseeded\)' "${output}"
  assert_match "names the fix" 'bazelisk run //scripts:hermes-bootstrap -- --data' "${output}"
}

@test "hermes-shell: a shipped placeholder model key is called out by name only" {
  printf 'LITELLM_MASTER_KEY=change-me-litellm\n' >"${SCRATCH}/stack.env"
  run_shell check
  [ "${status}" -eq 0 ]
  assert_match "placeholder called out" 'still the shipped placeholder' "${output}"
  assert_match "names the key" 'LITELLM_MASTER_KEY' "${output}"
  assert_match "points at bootstrap" 'bazelisk run //scripts:bootstrap' "${output}"
}

@test "hermes-shell: a model door that is down is a warning with the next command" {
  export STUB_CURL_RC=22
  run_shell check
  [ "${status}" -eq 0 ]
  assert_match "nothing answering" 'model door: nothing answering on 127.0.0.1:4000' "${output}"
  assert_match "suggests the status command" 'prod-stack -- status' "${output}"
}

@test "hermes-shell: a daemon that does not answer blocks the launch" {
  export STUB_INFO_RC=1
  run_shell ask "hello"
  [ "${status}" -eq 1 ]
  assert_match "daemon named as the blocker" 'the docker daemon did not answer' "${output}"
  assert_match "summary counts it" 'summary: ' "${output}"
  assert_not_match "nothing launched" 'run: docker compose' "${output}"
}

@test "hermes-shell: a missing compose file is reported as a blocker" {
  run bash "${SCRIPT}" --file "${SCRATCH}/nope.yml" \
    --env-file "${SCRATCH}/stack.env" check
  [ "${status}" -eq 0 ]
  assert_match "file missing reported" '\(missing\)' "${output}"
  assert_match "blocker recorded" 'no compose file at' "${output}"
}

@test "hermes-shell: hermes_entry builds the argv each mode is promised" {
  load_fns hermes_entry
  MODE="chat"
  EXTRA=()
  run hermes_entry
  assert_eq "chat entry" "chat" "${output}"
  MODE="ask"
  run hermes_entry
  assert_eq "ask seeds the query flag" "$(printf 'chat\n-q')" "${output}"
  MODE="shell"
  run hermes_entry
  assert_eq "shell entry" "bash" "${output}"
  MODE="commands"
  run hermes_entry
  assert_eq "commands prints the image help" "--help" "${output}"
  MODE="chat"
  EXTRA=(--tui --resume latest)
  run hermes_entry
  assert_eq "extra words follow" "$(printf 'chat\n--tui\n--resume\nlatest')" "${output}"
}

@test "hermes-shell: compose_prefix carries the project and both files as arguments" {
  load_fns compose_cli compose_prefix
  PROJECT="evo-t1-dev"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE="${SCRATCH}/stack.env"
  run compose_prefix
  assert_eq "full prefix" \
    "docker compose -p evo-t1-dev --env-file ${SCRATCH}/stack.env -f ${SCRATCH}/compose.yml" \
    "${output}"
  ENV_FILE=""
  run compose_prefix
  assert_eq "no env file means none passed" \
    "docker compose -p evo-t1-dev -f ${SCRATCH}/compose.yml" "${output}"
}

@test "hermes-shell: compose_cli accepts both compose spellings" {
  load_fns compose_cli
  run compose_cli
  assert_eq "plugin spelling" "docker compose" "${output}"

  # A host with only the legacy standalone binary still opens the assistant.
  printf '#!/usr/bin/env bash\nexit 0\n' >"${SCRATCH}/none/docker-compose"
  chmod 755 "${SCRATCH}/none/docker-compose"
  export STUB_VERSION_RC=1
  PATH="$(with_path "${SCRATCH}/none")"
  run compose_cli
  assert_eq "legacy spelling" "docker-compose" "${output}"

  rm -f "${SCRATCH}/none/docker-compose"
  PATH="$(with_path "${SCRATCH}/none")"
  run compose_cli
  [ "${status}" -ne 0 ]
}

@test "hermes-shell: container_state asks compose once and answers one word" {
  load_fns compose_cli container_state
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE=""
  export STUB_PS_OUT="abc123"
  run container_state
  assert_eq "running answers running" "running" "${output}"
  export STUB_PS_OUT=""
  run container_state
  assert_eq "no container answers stopped" "stopped" "${output}"

  # No docker on PATH at all is "nothing to enter", never a crash.
  PATH="$(with_path "${SCRATCH}/none")"
  run container_state
  assert_eq "no docker CLI answers stopped" "stopped" "${output}"
}

@test "hermes-shell: image_ref takes the image inside the assistant's own service block" {
  load_fns compose_cli image_ref
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE=""
  export STUB_IMAGE_REF="nousresearch/hermes-agent:v0.22.5"
  run image_ref
  assert_eq "resolved image" "nousresearch/hermes-agent:v0.22.5" "${output}"
  # The neighbours in the same render are not the answer: postgres and litellm both
  # declare an image, and one label value reads like one.
  assert_not_match "no neighbour image" 'postgres' "${output}"
  assert_not_match "no litellm image" 'litellm' "${output}"
  assert_not_match "no decoy" 'decoy' "${output}"
  assert_match "asked for one service" 'config hermes$' "$(stub_log docker)"
  export STUB_IMAGE_REF=""
  run image_ref
  assert_eq "unresolvable is empty, not a guess" "" "${output}"
  export STUB_IMAGE_REF="nousresearch/hermes-agent:v0.22.5" STUB_CONFIG_ERR=1
  run image_ref
  assert_eq "a compose that cannot render answers empty" "" "${output}"
}

@test "hermes-shell: data_mountpoint reads the volume by its compose labels" {
  load_fns data_mountpoint
  PROJECT="evo-t1-prod"
  export STUB_VOLUME_NAME="evo-t1-prod_hermes-data"
  export STUB_VOLUME_MOUNT="/var/lib/docker/volumes/x/_data"
  run data_mountpoint
  assert_eq "mountpoint printed" "/var/lib/docker/volumes/x/_data" "${output}"
  assert_match "asked by project label" \
    'label=com.docker.compose.project=evo-t1-prod' "$(stub_log docker)"
  assert_match "asked by volume label" \
    'label=com.docker.compose.volume=hermes-data' "$(stub_log docker)"
  export STUB_VOLUME_NAME=""
  run data_mountpoint
  assert_eq "no volume means no path" "" "${output}"
}

@test "hermes-shell: service_present blocks only on a service compose says is absent" {
  load_fns compose_cli service_present
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE=""
  run service_present
  assert_eq "listed service is yes" "yes" "${output}"

  export STUB_SERVICES="coder
litellm"
  run service_present
  assert_eq "a renamed service is no" "no" "${output}"

  export STUB_SERVICES="" STUB_SERVICES_ERR=1
  run service_present
  assert_eq "a compose that cannot answer is unknown" "unknown" "${output}"
}

@test "hermes-shell: a service compose denies is a blocker, an unknown one is not" {
  export STUB_SERVICES="coder
litellm"
  run_shell ask "hello"
  [ "${status}" -eq 1 ]
  assert_match "blocker names the service" 'no hermes service in this compose project' "${output}"
  assert_not_match "nothing launched" 'run: docker compose' "${output}"

  export STUB_SERVICES="" STUB_SERVICES_ERR=1
  run_shell ask "hello"
  [ "${status}" -eq 0 ]
  assert_match "unknown is a note" "not confirmed" "${output}"
  assert_match "and the session still opens" 'run: docker compose' "${output}"
}

@test "hermes-shell: dotenv_path prefers the named env file and falls back to the folder" {
  load_fns dotenv_path
  ENV_FILE="${SCRATCH}/stack.env"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  run dotenv_path
  assert_eq "the named file wins" "${SCRATCH}/stack.env" "${output}"

  ENV_FILE=""
  run dotenv_path
  assert_eq "no file beside the compose file yet" "" "${output}"
  printf 'STACK_DEPLOY_PATH=/opt/stack-deploy\n' >"${SCRATCH}/.env"
  run dotenv_path
  assert_eq "the compose folder is the fallback" "${SCRATCH}/.env" "${output}"
}

@test "hermes-shell: build_launch_argv chooses exec or run from the container state" {
  load_fns compose_cli compose_prefix hermes_entry build_launch_argv
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE=""
  MODEL=""
  WRITABLE=""
  ONE_SHOT=0
  MODE="ask"
  EXTRA=("hello")

  run build_launch_argv running
  assert_eq "the running branch execs" \
    "$(printf 'docker\ncompose\n-p\nevo-t1-prod\n-f\n%s/compose.yml\nexec\nhermes\nchat\n-q\nhello' \
      "${SCRATCH}")" "${output}"

  run build_launch_argv stopped
  assert_match "the stopped branch runs a one-shot" '--rm' "${output}"
  assert_match "and starts no dependencies" '--no-deps' "${output}"

  ONE_SHOT=1
  run build_launch_argv running
  assert_match "--one-shot overrides the join" '--rm' "${output}"

  MODEL="agent-xhigh"
  WRITABLE="/opt/stack"
  ONE_SHOT=0
  run build_launch_argv running
  assert_match "model travels as env" '-e' "${output}"
  assert_match "model value" 'HERMES_MODEL=agent-xhigh' "${output}"
  assert_match "write root value" 'HERMES_WRITE_SAFE_ROOT=/opt/stack' "${output}"
}

@test "hermes-shell: with no compose CLI there is no plan to print or run" {
  load_fns compose_cli compose_prefix container_state build_launch_argv hermes_entry
  has_tool() { return 1; }

  run build_launch_argv stopped
  [ "${status}" -eq 1 ]
  assert_eq "not one word is printed" "" "${output}"
}

@test "hermes-shell: launch refuses instead of printing a command with no program" {
  load_fns compose_cli compose_prefix container_state image_ref service_present \
    data_mountpoint dotenv_path report_readiness build_launch_argv hermes_entry launch
  has_tool() { return 1; }
  MODE="ask"
  DRY_RUN=1
  EXTRA=("hi")
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0

  run launch
  [ "${status}" -eq 1 ]
  assert_match "names the missing piece" 'no compose CLI' "${output}"
  assert_not_match "no prefixless command is offered" 'dry run: ' "${output}"
}

@test "hermes-shell: report_readiness counts a blocker without launching anything" {
  load_fns compose_cli compose_prefix container_state image_ref service_present \
    data_mountpoint dotenv_path report_readiness
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/nope.yml"
  ENV_FILE="${SCRATCH}/stack.env"
  MODEL=""
  WRITABLE=""
  ONE_SHOT=0
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  local out=""
  report_readiness >"${SCRATCH}/report.txt" 2>&1
  out="$(cat "${SCRATCH}/report.txt")"
  assert_match "file line says missing" '\(missing\)' "${out}"
  assert_match "names the blocker" 'no compose file at' "${out}"
  [ "${SUMMARY_FAIL}" -ge 1 ]
  run grep -E '(^| )(exec|run)( |$)' <<<"$(stub_log docker)"
  [ "${status}" -ne 0 ]
}

@test "hermes-shell: parse_args stops at the first bare word and keeps the rest verbatim" {
  load_fns parse_args
  PROJECT=""
  COMPOSE_FILE=""
  ENV_FILE=""
  MODEL=""
  WRITABLE=""
  ONE_SHOT=0
  DRY_RUN=0
  EXTRA=()
  parse_args --project-name evo-t1-dev --dry-run ask what now
  assert_eq "flag before the subcommand still parses" "evo-t1-dev" "${PROJECT}"
  assert_eq "dry run parsed" "1" "${DRY_RUN}"
  assert_eq "the bare word is the mode" "ask" "${MODE}"
  assert_eq "the words behind the subcommand pass through" "2" "${#EXTRA[@]}"
  assert_eq "first passthrough word" "what" "${EXTRA[0]}"
  assert_eq "last passthrough word" "now" "${EXTRA[1]}"
}

@test "hermes-shell: usage prints the contract a person can act on" {
  load_fns usage
  run usage
  assert_match "names the entry point" 'bazelisk run //scripts:hermes-shell' "${output}"
  assert_match "documents ask" 'ask TEXT' "${output}"
  assert_match "documents commands" 'commands' "${output}"
  assert_match "documents the hazard" 'corrupt' "${output}"
}

@test "hermes-shell: launch is the only place the command is decided" {
  load_fns compose_cli compose_prefix container_state image_ref service_present \
    data_mountpoint dotenv_path hermes_entry build_launch_argv report_readiness launch
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${SCRATCH}/compose.yml"
  ENV_FILE="${SCRATCH}/stack.env"
  MODEL=""
  WRITABLE=""
  ONE_SHOT=0
  DRY_RUN=1
  STUB_PS_OUT=""
  MODE="commands"
  EXTRA=()
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  run launch
  [ "${status}" -eq 0 ]
  assert_match "dry run printed" 'dry run: docker compose -p evo-t1-prod' "${output}"
  assert_match "help is the entry" 'hermes --help' "${output}"
}
