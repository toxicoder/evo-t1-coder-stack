#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## dev-stack.sh — drive one isolated compose project (up, down, status, logs, reset).
#
# The dev stack is a second copy of the stack: its own compose project name, so its
# own volumes and networks, and — with --env-file — its own host ports. That is what
# lets a stack-affecting change be checked without taking the stable instance down.
#
# What is decided here:
#
# 1. Which compose project the command addresses. `docker compose` needs one name per
#    invocation because docker-compose.yml declares no top-level `name:` key, and the
#    name is what namespaces volumes and networks. It defaults to `evo-t1-dev`;
#    `--project-name <name>` (or `-p <name>`) renames it.
#
# 2. Which compose file and env file that call uses. The project name only isolates
#    half of the stack: host ports are `${VAR:-default}` interpolations
#    (CODER_HTTP_PORT, LITELLM_PORT, KASM_UI_PORT, HOMEPAGE_HTTP_PORT, …), so two
#    stacks on one box need different numbers to come up at the same time.
#    `--env-file <file>` names one. With nothing named, the dev project takes
#    `<root>/dev-stack.env` when that file exists and every other project gets no
#    `--env-file` at all, so a run that addresses a different stack keeps the dev
#    port numbers out of it and resolves the ports the way a plain
#    `docker compose` call would. Naming a stack is therefore enough to address it.
#
# 3. Where the repo root is. Bazel runs this from a sandbox or a runfiles copy that
#    holds *copies* of the repo, so the root is read from ${REPO_ROOT:-} /
#    ${BUILD_WORKSPACE_DIRECTORY:-} / ${GITHUB_WORKSPACE:-} / $PWD and then PROVEN by
#    two probes: the compose file must exist and `docker` must be on PATH. `bazelisk
#    run` sets BUILD_WORKSPACE_DIRECTORY to the real checkout; that candidate has to
#    beat $PWD, because Bazel's cwd is the runfiles tree, which has docker-compose.yml
#    but not gitignored `.env` or bazelignored proxy/certs/. Relative compose bind
#    mounts resolve next to the compose file, so a runfiles compose file makes Docker
#    create missing sources as directories and then fail mounting them onto nginx
#    files. Neither probe alone is enough — a copy of the repo has the file but no
#    daemon, and the real checkout has both. An unproven root is reported as
#    `unresolvable repo root` and nothing runs: a stack that starts from a directory
#    nobody chose is worse than one that does not start.
#
# `status` is read-only and reports the Docker provider's reachability instead of
# failing when no daemon answers, which is the normal state inside the sandbox.
# `reset` is the one command that destroys volumes, so it stops and asks for
# `--yes` first; without it, nothing is destroyed.
#
# Usage (Bazel is the entry point; every example below is the whole command):
#   bazelisk run //scripts:dev-stack -- up
#   bazelisk run //scripts:dev-stack -- status
#   bazelisk run //scripts:dev-stack -- status --project-name evo-t1-review
#   bazelisk run //scripts:dev-stack -- logs --tail 200 coder
#   bazelisk run //scripts:dev-stack -- logs --follow --tail 200 coder litellm
#   bazelisk run //scripts:dev-stack -- down
#   bazelisk run //scripts:dev-stack -- reset --yes
#
# Options (accepted before or after the subcommand):
#   -p, --project-name <name>  compose project to address, default evo-t1-dev
#   -f, --file <file>          compose file, default <root>/docker-compose.yml
#   -e, --env-file <file>      env file carrying the host ports. With nothing
#                              named, only the dev project gets one (dev-stack.env,
#                              when it exists): a run aimed at any other project
#                              never inherits the dev port numbers.
#       --tail <n>             for logs: how many lines per service, default 100
#       --follow               for logs: keep following instead of printing a slice
#                              (`-f` is the compose file, never a second meaning)
#       --json                 one JSON object on stdout, prose on stderr
#   -y, --yes                  confirm: the only way to let `reset` destroy volumes
#   -h, --help                 print the usage and exit 0
#
# A bare word is a subcommand, not an option: `up coder` names no service, so it
# is refused. Only `logs` takes trailing words, and they are the services to read.
#
# Exit codes: 0 for a completed or skipped action and for `status`; 1 for a usage
# error, a refused one, or a failed one (an unknown subcommand prints the usage
# first); 2 when argv names no subcommand at all; 5 for an unresolvable repo root.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/host_state.sh disable=SC1091
source "${SELF_DIR}/lib/host_state.sh"
# shellcheck source=lib/pg-apply-password.sh disable=SC1091
source "${SELF_DIR}/lib/pg-apply-password.sh"

PROJECT="evo-t1-dev"
# The project whose host ports come from dev-stack.env. Any other project is a
# stack of its own, and its ports live in .env beside the compose file.
DEV_PROJECT="evo-t1-dev"
COMPOSE_FILE=""
ENV_FILE=""
LOG_TAIL="100"
LOG_FOLLOW=0
CONFIRMED=0

# @function usage
# Print the subcommand and flag list on stdout, so a typo prints something readable.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE'
usage: dev-stack [--project-name <name>] [--file <file>] [--env-file <file>]
                 [--tail <n>] [--follow] [--json] [--yes]
                 <up | down | status | logs [service...]> [same flags]

  up            docker compose up -d for the project, re-apply the Postgres
                role password from .env, bounce coder if it was failing auth,
                then the URL summary
  down          stop the project and keep its volumes
  status        read-only report: compose CLI, daemon, project, services
  logs          print compose logs (default: the last 100 lines per service;
                trailing words name the services to read)
  reset         stop the project AND destroy its volumes; needs --yes

Options: -p/--project-name (default evo-t1-dev, the dev stack; name the stable
project to drive that one), -f/--file, -e/--env-file (only the dev project gets a
default: dev-stack.env, when it exists; any other project gets none, so compose
reads its own .env), --tail, --follow (logs only), --json, -y/--yes, -h/--help. A
bare word is a subcommand: only `logs` takes trailing words, and they name
services.

Examples (each line is the whole command, run from the repo root):
  bazelisk run //scripts:dev-stack -- status
  bazelisk run //scripts:dev-stack -- status --project-name evo-t1-review
  bazelisk run //scripts:dev-stack -- up --project-name evo-t1-coder-stack
  bazelisk run //scripts:dev-stack -- logs --tail 200 coder
  bazelisk run //scripts:dev-stack -- logs --follow --tail 200 coder litellm
  bazelisk run //scripts:dev-stack -- up
  bazelisk run //scripts:dev-stack -- reset --yes
USAGE
}

# @function resolve_repo_root
# Print the repo root this run should use: the first candidate that holds
# docker-compose.yml AND has docker on PATH.
# Globals:
#   REPO_ROOT, BUILD_WORKSPACE_DIRECTORY, GITHUB_WORKSPACE
# Arguments:
#   None
# Outputs:
#   The root on stdout, or one "unresolvable repo root" line on stderr
# Returns:
#   The root on stdout; prints the complaint and returns 5 when none is proven
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    candidates+=("${BUILD_WORKSPACE_DIRECTORY}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}")
  candidates+=("${SELF_DIR}/..")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}/docker-compose.yml" ] && has_tool docker; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: unresolvable repo root: no proven checkout in %s (need docker-compose.yml and docker on PATH)\n' \
    "${candidates[*]}" >&2
  return 5
}

# @function compose_cli
# Print the compose invocation to use: "docker compose", or "docker-compose".
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The two words (or the one legacy name) on stdout
# Returns:
#   0 when either spelling exists, 1 when neither does
compose_cli() {
  if has_tool docker && docker compose version >/dev/null 2>&1; then
    printf 'docker compose\n'
    return 0
  fi
  if has_tool docker-compose; then
    printf 'docker-compose\n'
    return 0
  fi
  return 1
}

# @function default_env_file
# Print the env file whose port numbers this run should interpolate. An explicit
# --env-file always wins; the dev project takes dev-stack.env when it exists; any
# other project gets nothing here, so compose reads the .env beside the compose
# file exactly as a plain `docker compose` call would. One file can only carry one
# set of host ports, and the two stacks share a host: handing the dev overrides to
# a run that names a different project would republish that stack on the dev ports
# and move the dashboard links off the origin the browser uses.
# Globals:
#   ENV_FILE, DEV_PROJECT
# Arguments:
#   $1 - the repo root to look under
#   $2 - the compose project this run addresses
# Outputs:
#   The chosen file on stdout, or nothing when this run has no file of its own
# Returns:
#   0
default_env_file() {
  local root="${1}"
  local project="${2}"

  if [[ -n ${ENV_FILE} ]]; then
    printf '%s\n' "${ENV_FILE}"
    return 0
  fi

  if [[ ${project} != "${DEV_PROJECT}" ]] || [[ ! -f "${root}/dev-stack.env" ]]; then
    return 0
  fi

  printf '%s\n' "${root}/dev-stack.env"
}

# @function compose_prefix
# Print the argv that addresses the project: the CLI, the project name, and the
# two files. The project name travels as an argument and never as an environment
# variable, so `status` and `logs` can be checked against one printed command.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE
# Arguments:
#   None
# Outputs:
#   One space-separated command prefix on stdout
# Returns:
#   0
compose_prefix() {
  local -a argv=()
  argv=("$(compose_cli)")
  argv+=("-p" "${PROJECT}")
  if [ -n "${ENV_FILE}" ]; then
    argv+=("--env-file" "${ENV_FILE}")
  fi
  argv+=("-f" "${COMPOSE_FILE}")
  printf '%s\n' "${argv[*]}"
}

# @function report_stack
# Print the read-only `status` report: one line per check, never a stack change.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE
# Arguments:
#   None
# Outputs:
#   The report on stdout
# Returns:
#   0
report_stack() {
  local cli=""
  if ! has_tool docker; then
    printf 'docker: not on PATH\n'
    printf 'daemon: not checked (no docker CLI)\n'
    printf 'project: %s\n' "${PROJECT}"
    printf 'note: nothing was read and nothing was changed.\n'
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    printf 'daemon: reachable\n'
  else
    printf 'daemon: not reachable (the docker CLI is installed, the daemon did not answer)\n'
  fi
  cli="$(compose_cli)" || cli=""
  if [ -z "${cli}" ]; then
    printf 'compose: no compose CLI (neither `docker compose` nor `docker-compose`)\n'
    printf 'project: %s\n' "${PROJECT}"
    return 0
  fi
  printf 'compose: %s\n' "${cli}"
  printf 'project: %s\n' "${PROJECT}"
  if [ -z "${COMPOSE_FILE}" ]; then
    # No proven checkout, so there is no compose file to read: the report says so
    # instead of running `ps` against an empty -f argument.
    printf 'file: (none: no candidate holds both docker-compose.yml and a docker CLI)\n'
    printf 'note: nothing was read and nothing was changed.\n'
    return 0
  fi
  printf 'file: %s\n' "${COMPOSE_FILE}"
  if [ -n "${ENV_FILE}" ]; then
    printf 'env-file: %s\n' "${ENV_FILE}"
  else
    printf 'env-file: none (compose reads the .env beside that file, or its ${VAR:-default} ports)\n'
  fi
  printf 'command: %s ps\n' "$(compose_prefix)"
  printf 'services:\n'
  # `ps` is the read-only half of compose: an empty answer means nothing is up.
  $(compose_cli) -p "${PROJECT}" -f "${COMPOSE_FILE}" ps 2>/dev/null ||
    printf '  (no answer from compose)\n'
  return 0
}

# @function report_urls
# Print where the running stack can be opened (dashboard, Coder, LiteLLM, Kasm),
# then where the dashboard password lives and one command worth running next.
# Globals:
#   ENV_FILE, COMPOSE_FILE
# Arguments:
#   None
# Outputs:
#   Four URL lines, then the password-location and next-step lines
# Returns:
#   0
report_urls() {
  local host coder_port litellm_port kasm_port dash_port coder_url litellm_url dash_url env_src
  host=""
  # The env file is the only place these five keys live: compose interpolates
  # them from --env-file when one is named and from the .env beside the compose
  # file when it is not, so the same lookup works for both modes.
  env_src="${ENV_FILE:-}"
  if [ -z "${env_src}" ]; then
    env_src="$(dirname "${COMPOSE_FILE:-/nonexistent}")/.env"
  fi
  if [ -f "${env_src}" ]; then
    host="$(env_get "${env_src}" STACK_LAN_HOST)"
  fi
  [ -n "${host}" ] || host="localhost"
  coder_port="$(env_get "${env_src}" CODER_HTTP_PORT)"
  litellm_port="$(env_get "${env_src}" LITELLM_PORT)"
  kasm_port="$(env_get "${env_src}" KASM_UI_PORT)"
  dash_port="$(env_get "${env_src}" HOMEPAGE_HTTPS_PORT)"
  coder_url="$(env_get "${env_src}" STACK_CODER_URL)"
  litellm_url="$(env_get "${env_src}" STACK_LITELLM_URL)"
  dash_url="$(env_get "${env_src}" STACK_DASHBOARD_URL)"
  printf 'dashboard: %s\n' "${dash_url:-https://${host}:${dash_port:-443}}"
  printf 'coder:     %s\n' "${coder_url:-https://${host}:${coder_port:-3001}}"
  printf 'litellm:   %s\n' "${litellm_url:-http://${host}:${litellm_port:-4000}}"
  printf 'kasm:      https://%s:%s\n' "${host}" "${kasm_port:-4443}"
  printf 'password:  the dashboard login password is HOMEPAGE_AUTH_PASSWORD in %s (rotate it with bazelisk run //scripts:dashboard-password)\n' \
    "${env_src}"
  printf 'next:      bazelisk run //scripts:dev-stack -- logs --tail 200 coder\n'
}

# @function run_compose
# Run one compose command against the resolved project, printing it first.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE
# Arguments:
#   $1... - the compose subcommand and its arguments
# Outputs:
#   The command line and whatever compose prints
# Returns:
#   1 with a note when no compose CLI exists, otherwise compose's status
run_compose() {
  local cli=""
  local -a argv=()
  if ! cli="$(compose_cli)"; then
    printf 'error: no compose CLI (neither `docker compose` nor `docker-compose`)\n' >&2
    return 1
  fi
  # The project name and the two files travel as arguments on every subcommand.
  # Without -p compose addresses the project named after the folder it was called
  # from, which on the stack host is the stable stack: a dev run would then stop
  # the services it was never meant to touch.
  argv=("-p" "${PROJECT}")
  if [ -n "${ENV_FILE}" ]; then
    argv+=("--env-file" "${ENV_FILE}")
  fi
  argv+=("-f" "${COMPOSE_FILE}")
  argv+=("$@")
  if [ "${JSON_MODE:-}" = "1" ]; then
    printf 'run: %s %s\n' "${cli}" "${argv[*]}" >&2
  else
    printf 'run: %s %s\n' "${cli}" "${argv[*]}"
  fi
  # shellcheck disable=SC2086 # $cli is the two-word `docker compose` or the one
  # word `docker-compose` that compose_cli resolved; it is never a user path.
  ${cli} "${argv[@]}"
}

# @function main
# Parse argv, resolve the root, and dispatch one subcommand.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, LOG_TAIL, LOG_FOLLOW, CONFIRMED, JSON_MODE
# Arguments:
#   $* - optional flags, one subcommand, that subcommand's arguments, and the
#     same flags again (a leading `-` is what makes a word an option)
# Outputs:
#   The usage block, the report, or the compose output
# Returns:
#   0, or 1 (refused or failed), 2 (no subcommand given), 5 (unresolvable root)
main() {
  local -a rest=()
  local -a services=()
  local root="" action=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      --json)
        JSON_MODE=1
        export JSON_MODE
        ;;
      -y | --yes | --force) CONFIRMED=1 ;;
      --tail)
        [ "$#" -ge 2 ] || die "--tail needs a line count"
        LOG_TAIL="$2"
        shift
        ;;
      --follow) LOG_FOLLOW=1 ;;
      -p | --project-name)
        [ "$#" -ge 2 ] || die "--project-name needs a project name"
        PROJECT="$2"
        shift
        ;;
      -f | --file)
        [ "$#" -ge 2 ] ||
          die "--file needs a compose file (-f always names the compose file; --follow is the flag that follows logs)"
        COMPOSE_FILE="$2"
        shift
        ;;
      -e | --env-file)
        [ "$#" -ge 2 ] || die "--env-file needs an env file"
        ENV_FILE="$2"
        shift
        ;;
      -*)
        usage
        die "dev-stack: unknown option '$1' (try --help)"
        ;;
      *)
        rest+=("$1")
        ;;
    esac
    shift
  done

  if [ "${#rest[@]}" -eq 0 ]; then
    usage
    return 2
  fi

  # The first bare word is the subcommand; `logs` keeps the rest as service names
  # and every other subcommand takes none, so a typo cannot quietly become an
  # argument that gets ignored.
  action="${rest[0]}"
  case "${action}" in
    up | down | status | logs | reset) ;;
    *)
      usage
      die "dev-stack: unknown subcommand '${action}' (try --help)"
      ;;
  esac

  if [ "${action}" != "logs" ] && [ "${#rest[@]}" -gt 1 ]; then
    usage
    die "dev-stack: '${action}' takes no arguments (the subcommand is the first bare word)"
  fi

  if [ "${action}" = "logs" ] && [ "${#rest[@]}" -gt 1 ]; then
    services=("${rest[@]:1}")
  fi

  root="$(resolve_repo_root)" || {
    # `status` reads nothing and changes nothing, so it still reports on a host
    # where no checkout could be proven; anything that would drive compose cannot
    # guess where the compose file is, and stops instead.
    if [ "${action}" = "status" ]; then
      report_stack
      return 0
    fi
    return 5
  }
  if [[ -z ${COMPOSE_FILE} ]]; then
    COMPOSE_FILE="${root}/docker-compose.yml"
  fi
  ENV_FILE="$(default_env_file "${root}" "${PROJECT}")"

  case "${action}" in
    status)
      report_stack
      ;;
    up)
      repair_stale_runfiles "${root}" 0 || true
      compose_up_or_diagnose_db
      restart_coder_if_pg_auth_failed
      if [[ -t 0 ]]; then
        host_dns_report /etc/resolv.conf github.com || true
      fi
      report_urls
      ;;
    down)
      run_compose down --remove-orphans
      ;;
    logs)
      if [ "${LOG_FOLLOW}" = "1" ]; then
        run_compose logs -f --tail "${LOG_TAIL}" ${services[@]+"${services[@]}"}
      else
        run_compose logs --tail "${LOG_TAIL}" ${services[@]+"${services[@]}"}
      fi
      ;;
    reset)
      if [ "${CONFIRMED}" != "1" ]; then
        echo "reset refused: pass --yes to confirm destroying the ${PROJECT} volumes"
        return 1
      fi
      run_compose down --volumes --remove-orphans
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
