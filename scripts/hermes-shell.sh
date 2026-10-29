#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## hermes-shell.sh - open the Hermes host assistant in the terminal you are already in.
#
# Hermes is the stack's on-host assistant, and until now its only door was the Web
# Dashboard: a PTY over WebSocket, rendered as a Chat tab on :9119, behind HTTP basic
# auth, in a browser you had to open first. This opens the same agent on the door an
# operator on the box already has - the terminal. One command, and the assistant is
# answering in front of you with the same identity, the same seeded config, the same
# git-tracked skills, the same LiteLLM lane and the same approval prompts.
#
# Why this reaches into the running container instead of starting a second one:
# Hermes keeps its memory in a SQLite store under /opt/data, and pointing two
# containers at one data directory is how that store gets corrupted - the WAL sidecars
# and the lock are only visible to processes inside one container, so a second one
# reads a database mid-write and writes into it too. So when the gateway container is
# up, this runs `docker compose exec` against it and the terminal agent and the
# dashboard agent are the same process on the same store, which is what the dashboard
# already claims to be. Only when nothing is running does it `docker compose run
# --rm --no-deps` a one-shot instead: one container on the volume, alone, is safe.
#
# Why the checks are worth their lines: every blocker below is a way the operator
# finds out at the worst moment. A daemon that does not answer, a stack that is down,
# a data volume that was never seeded, a LiteLLM that is not listening, a model key
# still on its shipped placeholder - each one turns "ask the assistant" into a silent
# hang or an empty answer. `check` prints all of it without launching anything, and
# `--dry-run` prints the exact compose command it would have run.
#
# The container it enters is root-equivalent on this host (the docker socket is
# mounted there), so the assistant's approvals stay `manual` in the seeded config and
# this script never suggests otherwise. Nothing here prints a secret: the model key is
# reported as set, unset, or still a placeholder, and never by value.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:hermes-shell                       # the agent, in this terminal
#   bazelisk run //scripts:hermes-shell -- check              # readiness report, launch nothing
#   bazelisk run //scripts:hermes-shell -- commands           # the CLI surface this image has
#   bazelisk run //scripts:hermes-shell -- ask "why is coder offline"
#   bazelisk run //scripts:hermes-shell -- shell              # a shell in the same container
#   bazelisk run //scripts:hermes-shell -- chat --tui         # extra words pass through
#   bazelisk run //scripts:hermes-shell -- --model agent-medium
#   bazelisk run //scripts:hermes-shell -- --writable /opt/stack-deploy
#   bazelisk run //scripts:hermes-shell -- --project-name evo-t1-dev
#   bazelisk run //scripts:hermes-shell -- --dry-run
#   bazelisk run //scripts:hermes-shell -- --help
#
# Subcommands (the first bare word opens this CLI's own mode; every word after it is
# handed to the assistant verbatim, so a flag this script does not know still works):
#   chat          an interactive session (the default when argv names no subcommand)
#   ask TEXT      one question, answered and then the session ends
#   shell         a shell inside the assistant's own container, with its mounts and socket
#   check         the readiness report; launches nothing, changes nothing
#   commands      print the assistant CLI's own help, as this image version spells it
#
# Options (accepted before the subcommand):
#   -p, --project-name NAME  compose project to address, default evo-t1-prod
#                            (the dev sandbox is evo-t1-dev)
#   -f, --file FILE          compose file, default <root>/docker-compose.yml
#   -e, --env-file FILE      env file to interpolate from, default none (compose then
#                            reads the .env beside the compose file)
#   -m, --model ALIAS        LiteLLM alias for this session (agent, agent-low,
#                            agent-medium, agent-xhigh, chat); the seeded config stays
#                            on `agent` and keeps it for every later session
#   -w, --writable DIR       let the assistant's file tools write under DIR. The
#                            official image sets HERMES_WRITE_SAFE_ROOT=/opt/data, so
#                            a write outside it is refused outright and no approval
#                            card appears: name the checkout or the deploy directory
#   --one-shot               force a one-shot container even while the gateway runs.
#                            Two containers on one data volume is the documented way
#                            to corrupt the assistant's memory: this is the opt-in for
#                            knowing better, and it says so on the way out
#   --dry-run                print the command and exit 0 without running it
#   -h, --help               print this usage and exit 0
#
# Exit codes: 0 for a completed or dry-run launch and for `check`; 1 for a usage
# error, an interactive mode without a tty, or a launch blocked by the readiness
# report; 2 when argv names an unusable subcommand; 5 for an unresolvable repo root.
# A launched assistant replaces this process, so its own exit code is what the
# operator sees.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report line to
# stderr and leave stdout empty.
unset JSON_MODE

PROJECT="evo-t1-prod"
COMPOSE_FILE=""
ENV_FILE=""
MODE="chat"
MODEL=""
WRITABLE=""
ONE_SHOT=0
DRY_RUN=0
SERVICE="hermes"
# Every word after the subcommand: handed to the assistant's own CLI verbatim.
EXTRA=()

# @function usage
# Print the subcommand list, the flag list and the exit-code contract on stdout, so a
# typo prints something a person can act on instead of nothing.
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
usage: bazelisk run //scripts:hermes-shell [--project-name NAME] [--file FILE]
                    [--env-file FILE] [--model ALIAS] [--writable DIR] [--one-shot]
                    [--dry-run] [-h|--help] [SUBCOMMAND [ARGS...]]

Opens the stack's Hermes host assistant in the terminal you are already in - the
same agent, config, skills and approvals as the Web Dashboard on :9119. While the
assistant's container is running its CLI runs inside it, on the same memory store;
when nothing is running, a one-shot container opens on that volume alone.

Subcommands (words after them reach the assistant's own CLI verbatim):
  chat       interactive session - the default with no subcommand
  ask TEXT   one question, answered, then the session ends
  shell      a shell in the assistant's container (its mounts, its docker socket)
  check      readiness report: daemon, compose, image, volume seed, model door
  commands   print the assistant CLI's help as this image version spells it

Options: -p/--project-name (default evo-t1-prod; the dev sandbox is evo-t1-dev),
-f/--file, -e/--env-file, -m/--model ALIAS (agent, agent-medium, chat, ...),
-w/--writable DIR (the image's write-safe root is /opt/data, so a write into the
checkout needs this), --one-shot (a second container on a running assistant's data
volume can corrupt its memory store), --dry-run, -h/--help.

Exit codes: 0 = launched, dry run, or check; 1 = usage error, blocked or failed run;
2 = unusable subcommand; 5 = unresolvable repo root.
USAGE
}

# @function compose_cli
# Print the compose invocation to use: "docker compose", or the legacy "docker-compose".
# The same two spellings prod-stack.sh and dev-stack.sh accept, so a host that still
# ships the standalone binary opens the assistant too.
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

# @function compose_prefix
# Print the argv that addresses the project: the CLI, the project name, the two files.
# The project name travels as an argument and never as an environment variable, so the
# printed command is exactly the one that runs, and a run that means one project can
# never land on another by way of a cwd nobody chose.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE
# Arguments:
#   None
# Outputs:
#   One space-separated command prefix on stdout
# Returns:
#   0; 1 when no compose CLI resolved, so a caller never prints or runs a line that is
#   missing the program at its front
compose_prefix() {
  local cli=""
  local -a argv=()
  if ! cli="$(compose_cli)"; then
    return 1
  fi
  argv=("${cli}")
  argv+=("-p" "${PROJECT}")
  if [ -n "${ENV_FILE}" ]; then
    argv+=("--env-file" "${ENV_FILE}")
  fi
  argv+=("-f" "${COMPOSE_FILE}")
  printf '%s\n' "${argv[*]}"
}

# @function container_state
# Print whether the assistant's container is running, so the launch can choose between
# entering it and starting a lone one-shot. `ps -q --status running` is the whole
# question asked once: compose filters by state for us, so an answer means a container
# the terminal can enter and no answer means the volume is free for a one-shot.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE
# Arguments:
#   None
# Outputs:
#   One of running, stopped on stdout. A missing daemon or compose CLI answers as
#   stopped, which is the honest reading for the launch path: nothing is up to enter.
#   The report names each of those causes on its own line, so nothing is hidden here
# Returns:
#   0, always: this is a question about the box, not a verdict on the launch
container_state() {
  local cli="" id=""
  if ! has_tool docker || ! cli="$(compose_cli)"; then
    printf 'stopped\n'
    return 0
  fi
  # shellcheck disable=SC2086 # $cli is the compose CLI compose_cli just resolved,
  # two words or one, never a user path; it splits by design here.
  id="$(${cli} -p "${PROJECT}" ${ENV_FILE:+--env-file "${ENV_FILE}"} -f "${COMPOSE_FILE}" \
    ps -q --status running "${SERVICE}" 2>/dev/null | head -n 1 | tr -d '[:space:]')" || id=""
  if [ -n "${id}" ]; then
    printf 'running\n'
  else
    printf 'stopped\n'
  fi
}

# @function image_ref
# Print the image the assistant's service runs, as the compose file resolves it, so the
# report can say whether the host already has it. Empty when compose cannot answer
# (no compose CLI, a file that will not parse, a compose too old for
# `config <service>`), which the report prints as unknown rather than as "absent" -
# claiming an image is missing without having read the file would send the operator to
# pull the wrong thing, and blocking on it would block every run on a host whose
# compose is merely older.
#
# `config --images` is not used: on some compose versions it ignores the service
# argument and lists the whole project in an unstable order, and the first line of that
# is some other service's image. The rendered per-service document is asked instead,
# and awk takes the `image:` key that sits at service depth inside this service's own
# block, so a dependency rendered alongside it (litellm, ollama) cannot be mistaken for
# it.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, SERVICE
# Arguments:
#   None
# Outputs:
#   The image reference on stdout, or nothing
# Returns:
#   0, always
image_ref() {
  local cli="" out=""
  if ! cli="$(compose_cli)"; then
    return 0
  fi
  # shellcheck disable=SC2086 # resolved compose CLI, splits by design (see above).
  out="$(${cli} -p "${PROJECT}" ${ENV_FILE:+--env-file "${ENV_FILE}"} -f "${COMPOSE_FILE}" \
    config "${SERVICE}" 2>/dev/null | awk -v svc="${SERVICE}" '
    $0 == "  " svc ":" { insvc = 1; next }
    insvc && /^[^[:space:]]/ { insvc = 0 }
    insvc && /^  [^[:space:]]/ { insvc = 0 }
    insvc && /^    image:[[:space:]]/ {
      sub(/^    image:[[:space:]]+/, "")
      print
      exit
    }
  ')" || out=""
  printf '%s\n' "${out}"
}

# @function service_present
# Print yes, no, or unknown for whether the assistant's service is in this compose
# project. `config --services` is the question compose itself answers; `no` means it
# answered and the service is genuinely gone (a renamed service, a wrong --file), which
# is a blocker worth stopping for, and `unknown` means the command could not be asked,
# which is not.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE
# Arguments:
#   None
# Outputs:
#   yes, no, or unknown on stdout
# Returns:
#   0, always
service_present() {
  local cli="" out="" rc=0
  if ! cli="$(compose_cli)"; then
    printf 'unknown\n'
    return 0
  fi
  # shellcheck disable=SC2086 # resolved compose CLI, splits by design (see above).
  out="$(${cli} -p "${PROJECT}" ${ENV_FILE:+--env-file "${ENV_FILE}"} -f "${COMPOSE_FILE}" \
    config --services 2>/dev/null)" || rc=$?
  if [ "${rc}" != "0" ] || [ -z "${out}" ]; then
    printf 'unknown\n'
    return 0
  fi
  if printf '%s\n' "${out}" | grep -qx -- "${SERVICE}"; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# @function data_mountpoint
# Print the host directory behind the assistant's data volume, or nothing when the
# volume does not exist yet. Addressed by the labels compose puts on every volume it
# creates, so it survives the project-name and volume-naming conventions of whichever
# compose version is installed.
# Globals:
#   PROJECT
# Arguments:
#   None
# Outputs:
#   The mountpoint on stdout, or nothing
# Returns:
#   0, always
data_mountpoint() {
  local name=""
  name="$(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "label=com.docker.compose.volume=${SERVICE}-data" 2>/dev/null |
    head -n 1 | tr -d '[:space:]')" || name=""
  [ -n "${name}" ] || return 0
  docker volume inspect --format '{{ .Mountpoint }}' "${name}" 2>/dev/null || true
}

# @function dotenv_path
# Print the file compose interpolates this project's variables from: the one --env-file
# named, or the .env beside the compose file, which is what compose reads when argv
# names none. Only the path is printed and only non-secret keys are read from it.
# Globals:
#   ENV_FILE, COMPOSE_FILE
# Arguments:
#   None
# Outputs:
#   The path on stdout, or nothing when neither exists
# Returns:
#   0, always
dotenv_path() {
  local candidate=""
  if [ -n "${ENV_FILE}" ]; then
    printf '%s\n' "${ENV_FILE}"
    return 0
  fi
  candidate="$(dirname "${COMPOSE_FILE}")/.env"
  [ -f "${candidate}" ] && printf '%s\n' "${candidate}"
  return 0
}

# @function hermes_entry
# Print the argv to hand the assistant's container, one word per line. The image's
# entrypoint is a dispatcher that execs a first argument it finds on PATH (`bash`) and
# prefixes anything else with `hermes` (`chat`, `--help`), which is why a shell and a
# chat are both just words here and no entrypoint override is needed - overriding it
# would drop the container's init and its privilege drop along with it.
# Globals:
#   MODE, EXTRA
# Arguments:
#   None
# Outputs:
#   One argv word per line on stdout
# Returns:
#   0
hermes_entry() {
  local word
  case "${MODE}" in
    chat) printf 'chat\n' ;;
    ask) printf 'chat\n-q\n' ;;
    shell) printf 'bash\n' ;;
    commands) printf -- '--help\n' ;;
  esac
  for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    printf '%s\n' "${word}"
  done
}

# @function report_readiness
# Print the readiness report, one `key: value` line per thing a launch depends on, and
# count what would block it. Read-only: nothing here creates, pulls, starts or stops
# anything, and each line names the command that would fix it when one exists.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, MODE, MODEL, WRITABLE, ONE_SHOT
# Arguments:
#   None
# Outputs:
#   The report on stdout, with ok/warning/error lines counted for summary
# Returns:
#   0, always: `check` is a question about the box and prints its answer even when the
#   answer is bad news; the launch path re-reads these findings and refuses there
report_readiness() {
  local cli="" state="" image="" mount="" dotenv="" key="" port="" deploy=""
  local envfile="${STACK_DEPLOY_PATH:-/opt/stack-deploy}"

  dotenv="$(dotenv_path)"
  if [ -n "${dotenv}" ]; then
    deploy="$(env_get "${dotenv}" STACK_DEPLOY_PATH)"
  fi
  deploy="${deploy:-${envfile}}"

  if ! has_tool docker; then
    printf 'docker: not on PATH\n'
    fail_item "the docker CLI is not installed: this box cannot address the assistant's container"
  elif ! docker info >/dev/null 2>&1; then
    printf 'docker: installed, the daemon did not answer\n'
    fail_item "the docker daemon did not answer: is the daemon running, and are you in the docker group?"
  else
    printf 'docker: daemon reachable\n'
    ok "docker daemon"
  fi

  if ! cli="$(compose_cli)"; then
    printf 'compose: no compose CLI (neither `docker compose` nor `docker-compose`)\n'
    fail_item "no compose CLI: install the docker compose plugin"
    return 0
  fi
  printf 'compose: %s\n' "${cli}"
  printf 'project: %s\n' "${PROJECT}"

  if [ ! -f "${COMPOSE_FILE}" ]; then
    printf 'file: %s (missing)\n' "${COMPOSE_FILE}"
    fail_item "no compose file at ${COMPOSE_FILE}"
    return 0
  fi
  printf 'file: %s\n' "${COMPOSE_FILE}"

  if [ -n "${dotenv}" ]; then
    printf 'env-file: %s\n' "${dotenv}"
  else
    printf 'env-file: none (compose keeps its ${VAR:-default} values)\n'
  fi

  if [ "$(container_state)" = "running" ]; then
    printf 'container: running - the terminal joins it, so one memory store, one agent\n'
    ok "assistant container running"
  else
    printf 'container: not running - this opens a one-shot container on the data volume\n'
    note "a stack that is down means the assistant has no model door either: bazelisk run //scripts:prod-stack -- up"
  fi

  case "$(service_present)" in
    no)
      printf 'service: no %s service in this compose project\n' "${SERVICE}"
      fail_item "no ${SERVICE} service resolves in ${COMPOSE_FILE}: wrong --file, or the service was renamed"
      ;;
    yes)
      printf 'service: %s\n' "${SERVICE}"
      ok "service declared"
      ;;
    *)
      printf 'service: not confirmed (compose could not list this project)\n'
      note "compose did not answer 'config --services', so the service name is taken as given"
      ;;
  esac

  image="$(image_ref)"
  if [ -z "${image}" ]; then
    printf 'image: unknown (compose did not resolve it; the pull still happens on first run)\n'
  elif docker image inspect "${image}" >/dev/null 2>&1; then
    printf 'image: %s (present)\n' "${image}"
    ok "image present"
  else
    printf 'image: %s (absent - the first run pulls it, which is a large download)\n' "${image}"
    warn "the assistant's image is not on this host: docker pull ${image}"
  fi

  mount="$(data_mountpoint)"
  if [ -z "${mount}" ]; then
    printf 'data volume: not created yet (the first up creates it and hermes-init seeds it)\n'
    warn "no data volume for project ${PROJECT}: the assistant has no config or memory yet"
  elif [ -f "${mount}/config.yaml" ] && [ -f "${mount}/SOUL.md" ]; then
    printf 'data volume: %s (seeded)\n' "${mount}"
    ok "data volume seeded"
  else
    printf 'data volume: %s (unseeded)\n' "${mount}"
    warn "the volume holds neither config nor identity: bazelisk run //scripts:hermes-bootstrap -- --data ${mount} --force"
  fi

  if [ -n "${dotenv}" ]; then
    key="$(env_get "${dotenv}" LITELLM_MASTER_KEY)"
    case "${key}" in
      "")
        printf 'litellm key: missing from %s\n' "${dotenv}"
        warn "LITELLM_MASTER_KEY is unset: the assistant has no model transport and will not answer"
        ;;
      change-me-*)
        printf 'litellm key: still the shipped placeholder in %s\n' "${dotenv}"
        warn "LITELLM_MASTER_KEY is still change-me-*: run bazelisk run //scripts:bootstrap"
        ;;
      *)
        printf 'litellm key: set in %s (value not printed)\n' "${dotenv}"
        ok "model key present"
        ;;
    esac
    port="$(env_get "${dotenv}" LITELLM_PORT)"
  fi
  [ -n "${port}" ] || port="4000"

  if has_tool curl; then
    if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${port}/health/liveliness" 2>/dev/null; then
      printf 'model door: LiteLLM answers on 127.0.0.1:%s\n' "${port}"
      ok "LiteLLM answering"
    else
      printf 'model door: nothing answering on 127.0.0.1:%s\n' "${port}"
      warn "LiteLLM is not answering on ${port}: the assistant opens and cannot think (bazelisk run //scripts:prod-stack -- status)"
    fi
  else
    printf 'model door: not probed (no curl on PATH)\n'
    note "the model lane was not probed: install curl or check http://127.0.0.1:${port}/health/liveliness by hand"
  fi

  if [ -d "${deploy}" ]; then
    printf 'work dir: %s (present)\n' "${deploy}"
    ok "deploy directory present"
  else
    printf 'work dir: %s (absent)\n' "${deploy}"
    note "nothing to deploy projects into yet: sudo mkdir -p ${deploy} && sudo chown \"$(id -un)\" ${deploy}"
  fi

  if [ -n "${MODEL}" ]; then
    printf 'model: %s for this session only (the seeded config keeps agent)\n' "${MODEL}"
  fi
  if [ -n "${WRITABLE}" ]; then
    printf 'writable: %s (the image default is /opt/data alone)\n' "${WRITABLE}"
  else
    printf 'writable: the image default, /opt/data - file tools refuse a write into the checkout\n'
    note "to let the assistant edit files on the host, pass --writable ${deploy} or the checkout path"
  fi

  state="$(container_state)"
  if [ "${ONE_SHOT}" = "1" ] && [ "${state}" = "running" ]; then
    warn "--one-shot while the assistant's container runs: two containers on one data volume is the documented way to corrupt its memory store"
  fi
  return 0
}

# @function build_launch_argv
# Print the whole command line this run would execute, one word per line: the compose
# prefix, then `exec` into the running container or `run --rm --no-deps` a lone
# one-shot, then any per-session environment, then the assistant's own argv. Choosing
# here, once, is what keeps the printed command and the run command identical.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, SERVICE, MODEL, WRITABLE, ONE_SHOT
# Arguments:
#   $1 - the container state to plan for: running or anything else
# Outputs:
#   One argv word per line on stdout
# Returns:
#   0; 1 when no compose CLI resolved, in which case nothing is printed and the caller
#   says so instead of launching (or printing) a command with no program in front of it
build_launch_argv() {
  local state="${1:-}" word
  local -a prefix=()
  read -r -a prefix <<<"$(compose_prefix)"
  if [ "${#prefix[@]}" -eq 0 ]; then
    return 1
  fi
  for word in "${prefix[@]}"; do
    printf '%s\n' "${word}"
  done

  if [ "${state}" = "running" ] && [ "${ONE_SHOT}" != "1" ]; then
    printf 'exec\n'
  else
    printf 'run\n--rm\n--no-deps\n'
  fi

  if [ -n "${MODEL}" ]; then
    printf -- '-e\nHERMES_MODEL=%s\n' "${MODEL}"
  fi
  if [ -n "${WRITABLE}" ]; then
    printf -- '-e\nHERMES_WRITE_SAFE_ROOT=%s\n' "${WRITABLE}"
  fi

  printf '%s\n' "${SERVICE}"
  hermes_entry
}

# @function launch
# Decide between entering the running container and starting a lone one-shot, print the
# command, and hand the terminal over. The exec branch is the safe one and the common
# one; the run branch only opens when nothing else holds the data volume, unless
# --one-shot said otherwise. Nothing is launched for `check`, and `--dry-run` stops at
# the printed command.
# Globals:
#   MODE, DRY_RUN, ONE_SHOT, MODEL, WRITABLE
# Arguments:
#   None
# Outputs:
#   The report, the command line, then whatever the assistant prints
# Returns:
#   0 when the assistant exits 0; 1 when a blocker stopped the launch or an
#   interactive mode had no tty; 2 when argv named an unusable subcommand. A
#   launched assistant is exec'd, so its exit code is the caller's.
launch() {
  local state="" line
  local -a argv=()

  if [ "${MODE}" = "check" ]; then
    section "Hermes terminal readiness"
    report_readiness
    ok "readiness report"
    summary
    return 0
  fi

  if [ "${MODE}" != "chat" ] && [ "${MODE}" != "ask" ] && [ "${MODE}" != "shell" ] &&
    [ "${MODE}" != "commands" ]; then
    err "unknown subcommand '${MODE}' (see --help)"
    usage
    return 2
  fi

  # An interactive session needs a real terminal: compose allocates the pty off the
  # inherited one, and a pipe would leave the TUI drawing into a socket nobody reads.
  # `ask` and `commands` answer and exit, so they keep working without a tty.
  if { [ "${MODE}" = "chat" ] || [ "${MODE}" = "shell" ]; } && [ "${DRY_RUN}" != "1" ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      err "${MODE} needs a real terminal (stdin and stdout are not a tty)"
      note "run it from a shell on the host, or from tmux there; 'ask' takes a one-line question without a tty"
      return 1
    fi
  fi

  section "Hermes terminal"
  phase "read the box"
  state="$(container_state)"
  report_readiness

  phase "plan the session"
  while IFS= read -r line; do
    argv+=("${line}")
  done < <(build_launch_argv "${state}")

  # An empty plan means compose_cli found neither spelling. Say it here rather than
  # print or exec a line with no program at the front of it.
  if [ "${#argv[@]}" -eq 0 ]; then
    err "no compose CLI to address ${PROJECT} with: install the docker compose plugin (or legacy docker-compose)"
    summary "nothing launched"
    return 1
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    printf 'dry run: %s\n' "${argv[*]}"
    ok "dry run: nothing launched"
    summary
    return 0
  fi

  if [ "${SUMMARY_FAIL:-0}" != "0" ]; then
    summary "fix what is listed above, then re-run with check to confirm"
    return 1
  fi

  printf 'run: %s\n' "${argv[*]}"
  ok "handing the terminal to the assistant (approvals stay manual)"
  summary
  phase "the assistant owns this terminal now"

  # Hand the tty over with exec: the TUI reads keys and draws directly, and Ctrl-C
  # reaches the assistant instead of this script.
  exec "${argv[@]}"
}

# @function parse_args
# Consume the flags this CLI owns and stop at the first bare word, which becomes the
# subcommand; everything after it is the assistant's own argv and is never inspected.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, MODE, MODEL, WRITABLE, ONE_SHOT, DRY_RUN, EXTRA
# Arguments:
#   "$@" - the CLI contract in the file header
# Outputs:
#   The usage block on stdout or an error line on stderr
# Returns:
#   0 when argv settled a mode; exits 1 on a valueless or unknown flag; exits 0 on
#   --help
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p | --project-name)
        [ "$#" -ge 2 ] || die "--project-name needs a name"
        PROJECT="$2"
        shift 2
        ;;
      -f | --file)
        [ "$#" -ge 2 ] || die "--file needs a compose file"
        COMPOSE_FILE="$2"
        shift 2
        ;;
      -e | --env-file)
        [ "$#" -ge 2 ] || die "--env-file needs a file"
        ENV_FILE="$2"
        shift 2
        ;;
      -m | --model)
        [ "$#" -ge 2 ] || die "--model needs a LiteLLM alias"
        MODEL="$2"
        shift 2
        ;;
      -w | --writable)
        [ "$#" -ge 2 ] || die "--writable needs a directory the assistant may write"
        WRITABLE="$2"
        shift 2
        ;;
      --one-shot)
        ONE_SHOT=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --*)
        err "unknown argument '$1' (see --help)"
        usage
        exit 1
        ;;
      *)
        # First bare word: it names this CLI's mode, and every word behind it belongs
        # to the assistant, so it is copied verbatim and never parsed again.
        MODE="$1"
        shift
        EXTRA=("$@")
        return 0
        ;;
    esac
  done
  return 0
}

# @function main
# Parse argv, prove the checkout, settle the compose file, and dispatch one mode.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, MODE, MODEL, WRITABLE, ONE_SHOT, DRY_RUN, EXTRA
# Arguments:
#   "$@" - the CLI contract in the file header
# Outputs:
#   The usage block, or the report and whatever the launch prints
# Returns:
#   Whatever launch returned; exits 5 on an unresolvable repo root
main() {
  local root=""
  parse_args "$@"

  if [ -z "${COMPOSE_FILE}" ]; then
    root="$(resolve_checkout "${SELF_DIR}")" || {
      err "hermes-shell addresses the stack's compose project; run it from the checkout or pass --file"
      exit 5
    }
    COMPOSE_FILE="${root}/docker-compose.yml"
  fi

  launch
}

main "$@"
