#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## hermes-doctor.sh - audit the Hermes assistant's posture and its drift.
#
# hermes-shell -- check answers "can I open the assistant": docker answers, the
# service is declared, the image is here, the volume is seeded, LiteLLM replies.
# Those are the gates on opening a session. This script answers the other
# question, the one a readiness report cannot: is the assistant still the one
# this repo describes, and is it still the one this repo would want?
#
# So it reads what readiness does not look at - the config the container
# actually loads, the environment it was created with, the mounts it was given,
# and the two payload files beside the checkout. Approvals left `manual`, the
# working directory resolved to a real path, the web lane still pointed at the
# stack's own SearXNG with both keyless switches off, no vendor credential
# present, the image still the pinned one, the dashboard still behind a
# non-default basic-auth pair, the anywhere door still closed and the push channel
# still push-only, and the coding-agent verbs still reachable from the mount. Each of
# those is a fact that can quietly stop
# being true: an operator edit inside the volume, a re-create from a stale
# `.env`, a merge that changed the seed and never re-seeded a long-lived box.
#
# Read-only, and loud about it. Every container-level fact is read with
# `docker inspect` or `docker compose ps`: no check writes, restarts, recreates,
# or execs anything at all. `--dry-run`
# prints the container commands it would run and reports nothing, which is what
# makes the whole audit reviewable before anyone runs it on a live box.
#
# It is a report, not a gate: it exits 0 for a clean bill and 1 when something
# failed, so a CI job can call it, but it never blocks a session on its own.
# `hermes-shell` remains the thing that decides whether to launch.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:hermes-doctor --
#   bazelisk run //scripts:hermes-doctor -- posture
#   bazelisk run //scripts:hermes-doctor -- web
#   bazelisk run //scripts:hermes-doctor -- diff
#   bazelisk run //scripts:hermes-doctor -- --check terminal-cwd --check web-lane
#   bazelisk run //scripts:hermes-doctor -- --project-name evo-t1-dev --dry-run
#   bazelisk run //scripts:hermes-doctor -- --help
#
# Options (accepted anywhere in argv, before or after the subcommand):
#   report|posture|web|diff  what to audit (default: report, which is all of them)
#                   report   every check below
#                   posture  the security and privacy checks only
#                   web      the search lane and its egress guards
#                   diff     the volume copy against the seed in the checkout
#   -p, --project-name NAME  compose project to address (default: evo-t1-prod)
#   -f, --file FILE          compose file (default: <repo root>/docker-compose.yml)
#   -e, --env-file FILE      dotenv to read keys from (default: the .env beside
#                            the compose file, which is what compose itself uses)
#   -c, --container NAME     address this container instead of resolving the
#                            project's hermes service through compose
#   --data DIR               read the data directory from DIR instead of asking
#                            the daemon where the volume is mounted
#   --check NAME             run only this check; repeat the flag for several
#   --dry-run                print the container commands, audit nothing
#   -h, --help               print this usage and exit 0
#
# Checks: approvals terminal-cwd write-root web-lane keyless-egress mcp-servers
#   seed-drift mount-identity image-pin model-key dashboard memories
#   anywhere-door (the API server and the push channel) agent-verbs (the coding-agent
#   control plane the assistant drives)
#
# Exit codes: 0 when every selected check passed (warnings allowed); 1 when any
# check failed; 2 for a bad invocation - an unknown subcommand, an unknown flag,
# or a flag with no value.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/lib/common.sh"
# A leftover JSON_MODE would route every report line to stderr and leave stdout
# empty; this CLI has no --json mode and says so in its usage.
unset JSON_MODE

PROJECT="evo-t1-prod"
COMPOSE_FILE=""
ENV_FILE=""
CONTAINER=""
DATA_DIR=""
DRY_RUN=0
SUBCOMMAND="report"
CHECKS=()
ROOT=""

# The image this repo pins, read from the compose file at run time. The default
# is what the audit compares a live container against when the compose file is
# unreachable, so a stale default reads as drift rather than passing silently.
HERMES_IMAGE_DEFAULT="nousresearch/hermes-agent:v0.22.5"

# The web vendors with a bundled provider and a key env. Used only to answer
# "is one of these present in this container" - the seed routes every search to
# the stack's own SearXNG, so a key here means the lane left the box somewhere.
WEB_VENDOR_KEYS="TAVILY_API_KEY FIRECRAWL_API_KEY BRAVE_SEARCH_API_KEY EXA_API_KEY PARALLEL_API_KEY KEENABLE_API_KEY PERPLEXITY_API_KEY"

# @function usage
# Print the usage block.
#
# The subcommands are the shape of the tool: one report that reads everything,
# and three narrower views an operator reaches for when they already know what
# they are asking about. `--dry-run` is documented as printing the container
# commands, because that is the promise an operator needs before pointing this
# at a machine that is serving traffic.
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
usage: bazelisk run //scripts:hermes-doctor -- [report|posture|web|diff]
                    [-p NAME] [-f FILE] [-e FILE] [-c NAME] [--data DIR]
                    [--check NAME]... [--dry-run] [-h|--help]

Audits the Hermes host assistant: what its container was created with, what its
config says now, and how far either has drifted from this checkout's seed.
Read-only. It reports and never launches, restarts, recreates or writes.

Subcommands: report (default, everything), posture (security and privacy),
web (the search lane and its egress guards), diff (volume copy vs seed).

Checks: approvals terminal-cwd write-root web-lane keyless-egress mcp-servers
seed-drift mount-identity image-pin model-key dashboard memories anywhere-door
agent-verbs

Exit codes: 0 = every selected check passed; 1 = something failed;
2 = unknown subcommand, unknown flag, or a flag with no value;
5 = no stack checkout found (name one with -f, or set REPO_ROOT).
USAGE
}

# @function doctor_compose
# Run one compose subcommand against the addressed project, or print it.
#
# With --dry-run the command is printed and nothing runs, which is also how a
# caller sees exactly what the audit would have done to their box. The three
# addressing flags always go out together so a stray environment cannot point
# the audit at a different project than the one named.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, DRY_RUN
# Arguments:
#   $@ - the compose subcommand and its arguments
# Outputs:
#   The subcommand's output, or the command line under --dry-run
# Returns:
#   The compose exit status, or 0 under --dry-run
doctor_compose() {
  local argv=(docker compose -p "${PROJECT}")
  [ -n "${COMPOSE_FILE}" ] && argv+=(-f "${COMPOSE_FILE}")
  # The dotenv is compose's --env-file, never a second -f: as a fragment file it
  # is not YAML, and compose answers with a parse error naming the wrong file.
  [ -n "${ENV_FILE}" ] && argv+=(--env-file "${ENV_FILE}")
  argv+=("$@")
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "dry run: ${argv[*]}"
    return 0
  fi
  "${argv[@]}"
}

# @function doctor_container
# Print the container id or name to address, resolving it once.
#
# -c wins outright, because an operator naming a container knows something the
# project labels do not. Otherwise the project's hermes service is asked for its
# running container, which is the same lookup the readiness report makes. The
# answer is cached in a global: most checks address the same container, and a
# report that asked the daemon eight times would be slower and no more true.
# Globals:
#   CONTAINER, DOCTOR_CONTAINER_CACHE, DRY_RUN
# Arguments:
#   None
# Outputs:
#   One container id or name on stdout
# Returns:
#   0 when there is one; 1 when it cannot be resolved
doctor_container() {
  if [ -n "${DOCTOR_CONTAINER_CACHE:-}" ]; then
    printf '%s\n' "${DOCTOR_CONTAINER_CACHE}"
    return 0
  fi
  if [ -n "${CONTAINER}" ]; then
    DOCTOR_CONTAINER_CACHE="${CONTAINER}"
    printf '%s\n' "${CONTAINER}"
    return 0
  fi
  local id=""
  # Under --dry-run doctor_compose prints its own command line instead of
  # running it, which is what makes the audit reviewable, and answers with no
  # id. The bare daemon fallback is not compose's to gate, so it is gated here.
  id="$(doctor_compose ps -q hermes 2>/dev/null | head -1)"
  if [ "${DRY_RUN}" -eq 0 ] && [ -z "${id}" ]; then
    id="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E -- "-hermes-1$" | head -1)"
  fi
  [ -n "${id}" ] || return 1
  DOCTOR_CONTAINER_CACHE="${id}"
  printf '%s\n' "${id}"
}

# @function doctor_container_running
# Say whether there is a live container to ask about.
#
# Checks that want the daemon ask this first instead of handing the empty string
# to `docker inspect` when nothing resolved: an empty argument makes the daemon
# answer about the *first* container it likes, which reads as a fact about the
# assistant and is a fact about something else entirely.
# Globals:
#   DRY_RUN
# Arguments:
#   None
# Outputs:
#   Nothing
# Returns:
#   0 when a container resolved and the daemon knows it; 1 otherwise
doctor_container_running() {
  local id=""
  [ "${DRY_RUN}" -eq 1 ] && return 1
  id="$(doctor_container || true)"
  [ -n "${id}" ] || return 1
  [ -n "$(docker inspect -f '{{.Id}}' "${id}" 2>/dev/null || true)" ]
}

# @function doctor_env_of
# Print one environment value from the running container, as it was created.
#
# The container's environment is what compose interpolated at create time, so
# this is the fact that matters and the .env file is only an intention: a key
# can be right in the file and wrong in the container until the next recreate.
# Globals:
#   DRY_RUN
# Arguments:
#   $1 - the variable name
# Outputs:
#   The value on stdout, empty when it is unset or unreadable
# Returns:
#   0 always; an unreadable container is an empty answer
doctor_env_of() {
  local name="$1" id=""
  [ "${DRY_RUN}" -eq 1 ] && return 0
  id="$(doctor_container || true)"
  [ -n "${id}" ] || return 0
  docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "${id}" 2>/dev/null |
    sed -n -e "s|^${name}=||p" | head -1 || true
}

# @function doctor_volume_dir
# Print the directory the data volume is mounted at, for reading the seeded files.
#
# --data wins so a Bats suite (and an operator with a bind-mounted volume) can
# point the audit at a directory without a daemon in the picture. Otherwise the
# daemon is asked, by the compose labels, which is the only way to learn where
# Docker actually put it.
# Globals:
#   DATA_DIR, PROJECT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   A directory path on stdout
# Returns:
#   0 when a directory was found; 1 otherwise
doctor_volume_dir() {
  if [ -n "${DATA_DIR}" ]; then
    # A directory that is not there is not a volume: reporting it as one turns a
    # typo into "the volume holds no config.yaml", which points the operator at
    # the seeder instead of at their own flag.
    [ -d "${DATA_DIR}" ] || return 1
    printf '%s\n' "${DATA_DIR}"
    return 0
  fi
  [ "${DRY_RUN}" -eq 1 ] && return 1
  local mount=""
  mount="$(docker volume ls -q \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "label=com.docker.compose.volume=hermes-data" 2>/dev/null | head -1)"
  [ -n "${mount}" ] || return 1
  mount="$(docker volume inspect --format '{{ .Mountpoint }}' "${mount}" 2>/dev/null)"
  [ -n "${mount}" ] && [ -d "${mount}" ] || return 1
  printf '%s\n' "${mount}"
}

# @function check_approvals
# Report that the seeded approvals gate is still the one this repo ships.
#
# approvals.mode defaults to smart upstream, so the seed's `manual` is
# load-bearing rather than decorative: this container mounts the host docker
# socket, and an approval mode that stopped being manual means a flagged command
# runs without anyone being asked. cron_mode and unattended_mode are read in the
# same breath because a scheduled run that can approve is the same hole with a
# timer on it.
# Globals:
#   ROOT
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or error: lines
# Returns:
#   0 always; a failure is recorded with fail_item
check_approvals() {
  local seed="${ROOT}/hermes/config.yaml"
  if [ ! -f "${seed}" ]; then
    fail_item "hermes/config.yaml is not reachable from ${ROOT}"
    return 0
  fi
  local pair bad=""
  for pair in "mode: manual" "cron_mode: deny" "unattended_mode: deny"; do
    grep -qE "^[[:space:]]*${pair}[[:space:]]*\$" "${seed}" || bad+=" ${pair}"
  done
  if [ -n "${bad}" ]; then
    fail_item "the seed no longer pins${bad} - every flagged command can run unasked"
  else
    ok "approvals: manual, with cron and unattended both deny"
  fi
}

# @function check_terminal_cwd
# Report whether the working directory the assistant runs in will resolve.
#
# Hermes validates terminal.cwd with expanduser() alone in agent/runtime_cwd.py,
# so a ${VAR} left in the file reads as a missing directory and the agent works
# somewhere else, while `hermes config get` prints the token looking healthy
# because the loader does expand it. In the seed the token is expected - the
# seeder renders it - so the finding lives in the volume copy, where the value
# has to be a literal absolute path that exists.
# Globals:
#   ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or error: lines, naming the value it found
# Returns:
#   0 always; a failure is recorded with fail_item
check_terminal_cwd() {
  local seed="${ROOT}/hermes/config.yaml" volume="" value=""
  if [ -f "${seed}" ] && ! grep -qE '^[[:space:]]*cwd:' "${seed}"; then
    warn "the seed names no terminal.cwd: the assistant inherits wherever the gateway started"
  fi
  volume="$(doctor_volume_dir || true)"
  if [ -z "${volume}" ] || [ ! -f "${volume}/config.yaml" ]; then
    warn "the volume copy is not readable from here: --data DIR names it, and the cwd check needs it"
    return 0
  fi
  value="$(grep -E '^[[:space:]]*cwd:' "${volume}/config.yaml" | head -1 |
    sed -E 's/^[[:space:]]*cwd:[[:space:]]*//' | tr -d '"')"
  if [ -z "${value}" ]; then
    warn "the volume config names no terminal.cwd"
    return 0
  fi
  # The one token hermes-bootstrap renders is named in full rather than matched
  # as a shape: a directory name may hold a dollar sign legitimately, and the
  # finding is a seed that was never rendered. The literal is also written so the
  # brace pair stays on this line, which tests/extract_fn.py counts per line.
  if [[ ${value} == *'${STACK_HOST_PATH}'* ]]; then
    fail_item "the seeded working directory is still a token (${value}): hermes-bootstrap --data <mount> --force renders it"
  elif [[ ${value} == /* ]]; then
    if [ -d "${value}" ]; then
      ok "terminal.cwd: ${value}, and it is a directory"
    elif doctor_container_running; then
      warn "terminal.cwd: ${value} is not a directory on this host - it has to exist inside the container"
    else
      warn "terminal.cwd: ${value} is absolute and cannot be verified from here"
    fi
  else
    fail_item "terminal.cwd is not an absolute path (${value}): Hermes resolves it against wherever the gateway started"
  fi
}

# @function check_write_root
# Report the write fence the image enforces.
#
# The official image sets HERMES_WRITE_SAFE_ROOT=/opt/data, so a file-tool write
# anywhere else is refused before an approval card even appears. That is the
# difference between "the assistant can only edit its own state" and "the
# assistant can edit the checkout", and it is set by the environment rather than
# the config, so a recreate from a hand-written compose file can lose it.
# Globals:
#   DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok: or warning: lines
# Returns:
#   0 always
check_write_root() {
  local value=""
  value="$(doctor_env_of HERMES_WRITE_SAFE_ROOT)"
  if [ -z "${value}" ]; then
    note "write root: not visible - the image default is /opt/data, which is the fence working as intended"
    return 0
  fi
  if [ "${value}" = "/opt/data" ]; then
    ok "write root: /opt/data, so a write outside the assistant's own state is refused"
  else
    warn "write root: ${value}, which is wider than the shipped /opt/data fence"
  fi
}

# @function check_web_lane
# Report where web_search will send a query.
#
# This is the check that keeps the local-only promise. The registry
# (agent/web_search_registry.py) ends its resolution walk at an anonymous
# free-tier ring of third-party vendors, so a config that names no backend and
# leaves the keyless switches at their shipped true answers a search from a
# vendor while looking local. Three things have to agree: the seed pins the
# search capability to searxng, both switches are off, and SEARXNG_URL - which
# is what registers the provider at all - is set in the container.
# Globals:
#   ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or error: lines
# Returns:
#   0 always; a failure is recorded with fail_item
check_web_lane() {
  local seed="${ROOT}/hermes/config.yaml" url="" missing=""
  if [ ! -f "${seed}" ]; then
    fail_item "hermes/config.yaml is not reachable from ${ROOT}"
    return 0
  fi
  grep -qE '^[[:space:]]*search_backend:[[:space:]]*searxng[[:space:]]*$' "${seed}" ||
    missing+=" web.search_backend"
  grep -qE '^[[:space:]]*keyless_fallback:[[:space:]]*false[[:space:]]*$' "${seed}" ||
    missing+=" web.keyless_fallback"
  grep -qE '^[[:space:]]*keyless_rescue:[[:space:]]*false[[:space:]]*$' "${seed}" ||
    missing+=" web.keyless_rescue"
  if [ -n "${missing}" ]; then
    fail_item "the seed stopped pinning the lane:${missing} - a search can reach a vendor's free tier"
  else
    ok "web lane: pinned to searxng, both keyless switches off"
  fi
  url="$(doctor_env_of SEARXNG_URL)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi
  if [ -z "${url}" ]; then
    warn "SEARXNG_URL is not set in the container: the bundled provider never registers, so web_search has no backend"
  else
    ok "SEARXNG_URL: ${url}"
  fi
}

# @function check_keyless_egress
# Report whether any third-party web credential is present.
#
# The lane has one credential by design - LITELLM_MASTER_KEY - and a vendor key
# in this container is a route out of the box that the seed refuses to open. The
# check reads the container's own environment, because that is where a key that
# should not be there actually appears.
# Globals:
#   WEB_VENDOR_KEYS, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok: or warning: lines naming the key, never its value
# Returns:
#   0 always
check_keyless_egress() {
  local key present=""
  [ "${DRY_RUN}" -eq 1 ] && {
    note "keyless egress: not probed under --dry-run"
    return 0
  }
  for key in ${WEB_VENDOR_KEYS}; do
    if [ -n "$(doctor_env_of "${key}")" ]; then
      present+=" ${key}"
    fi
  done
  if [ -n "${present}" ]; then
    warn "a web vendor credential is in this container:${present} - the seed routes every search to the stack's own instance"
  else
    ok "no web vendor credential present: the assistant holds one key, LITELLM_MASTER_KEY"
  fi
}

# @function check_mcp_servers
# Report that the seed declares no MCP servers.
#
# The upstream default carries none, and this stack keeps it that way: an MCP
# block in the volume would give the assistant a second set of tools that the
# repo's gates never saw. Finding one is not a failure of the seed, so it is a
# warning - the operator may have added it deliberately.
# Globals:
#   ROOT
# Arguments:
#   None
# Outputs:
#   ok: or warning: lines
# Returns:
#   0 always
check_mcp_servers() {
  local seed="${ROOT}/hermes/config.yaml"
  if [ -f "${seed}" ] && grep -qE '^[[:space:]]*mcp_servers:' "${seed}"; then
    warn "the seed declares an mcp_servers block: the gates here never saw those tools"
  else
    ok "mcp_servers: none declared, so the tool surface is the one this repo ships"
  fi
}

# @function check_seed_drift
# Compare what the container loads against what the checkout ships.
#
# Seeding is copy-only-when-absent, which is the right rule for an operator's
# edits and the wrong rule for a merge: a re-created container keeps a config
# from before the change that was supposed to reach it. The comparison ignores
# the two places the seed is legitimately different in the volume - the rendered
# working directory, and the key that Hermes expands at boot - because a drift
# report that cried over those would be ignored within a week.
# Globals:
#   ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or note: lines, naming each file that differs
# Returns:
#   0 always
check_seed_drift() {
  local volume="" name="" differs="" src dst compared=0
  volume="$(doctor_volume_dir || true)"
  if [ -z "${volume}" ]; then
    note "seed drift: the volume is not readable from here - --data DIR names it"
    return 0
  fi
  for name in config.yaml SOUL.md; do
    src="${ROOT}/hermes/${name}"
    dst="${volume}/${name}"
    if [ ! -f "${src}" ]; then
      fail_item "the seed file hermes/${name} is missing from ${ROOT}"
      continue
    fi
    if [ ! -f "${dst}" ]; then
      warn "the volume holds no ${name}: hermes-bootstrap seeds it"
      continue
    fi
    if doctor_same_file "${src}" "${dst}" "${name}"; then
      compared=$((compared + 1))
      continue
    fi
    compared=$((compared + 1))
    differs+=" ${name}"
  done
  if [ -n "${differs}" ]; then
    warn "the volume copy differs from the seed:${differs} - hermes-bootstrap --data <mount> --force re-seeds it"
  elif [ "${compared}" -gt 0 ]; then
    # Only a pair that was actually read earns the verdict: a volume holding
    # neither file has to be reported as empty, not as a match.
    ok "seed drift: the volume copy matches this checkout"
  fi
}

# @function doctor_same_file
# Say whether a seed file and its volume copy agree, ignoring the render.
# Globals:
#   None
# Arguments:
#   $1 - the seed file, $2 - the volume copy, $3 - the name (for the token rule)
# Outputs:
#   Nothing
# Returns:
#   0 when they are equal for the purpose of the drift report; 1 when they differ
doctor_same_file() {
  local src="$1" dst="$2" name="$3" rendered=""
  if [ "${name}" = "config.yaml" ]; then
    # hermes-bootstrap renders every ${STACK_HOST_PATH} in the seed to one
    # absolute path, so the volume's own cwd *is* that value. Substituting the
    # volume's answer into the seed compares the pair without guessing the host,
    # and a flipped switch or a renamed key still reads as a difference. The
    # delimiter matches the renderer's, so any path it accepted is safe here.
    rendered="$(sed -n -E 's/^[[:space:]]*cwd:[[:space:]]*//p' "${dst}" | head -1 | tr -d '"')"
    # shellcheck disable=SC2016  # ${VAR} is the literal token the seed carries
    sed -e "s|\${STACK_HOST_PATH}|${rendered}|g" "${src}" |
      diff -q - "${dst}" >/dev/null 2>&1
    return
  fi
  diff -q "${src}" "${dst}" >/dev/null 2>&1
}

# @function check_mount_identity
# Report whether the checkout is mounted where the key says it is.
#
# The assistant reads its own repo at $STACK_HOST_PATH because compose bind-mounts
# the host path at the same path inside the container, which is what lets a bind
# source in a compose file the assistant writes resolve on the daemon. Compose
# mounts whatever the key names, so a value pointing at no checkout gives the
# assistant an empty directory while every container-level check still reads
# healthy - the exact shape that hid this on a live box.
# Globals:
#   ROOT, ENV_FILE, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or error: lines
# Returns:
#   0 always; a failure is recorded with fail_item
check_mount_identity() {
  local key="" host=""
  key="${ENV_FILE:-$(dirname "${COMPOSE_FILE:-${ROOT}/docker-compose.yml}")/.env}"
  host="$(env_get "${key}" STACK_HOST_PATH)"
  [ -n "${host}" ] || host="${STACK_HOST_PATH:-}"
  if [ -z "${host}" ]; then
    warn "STACK_HOST_PATH is unset: compose falls back to .:/opt/stack, which mounts the compose file's directory and not a named checkout"
    return 0
  fi
  case "${host}" in
    /*) ;;
    *)
      fail_item "STACK_HOST_PATH is not absolute (${host}): compose would mount a path relative to wherever it was invoked"
      return 0
      ;;
  esac
  if [ ! -f "${host}/docker-compose.yml" ]; then
    fail_item "STACK_HOST_PATH names ${host}, which holds no docker-compose.yml - the assistant is mounting a directory that is not the stack"
    return 0
  fi
  ok "STACK_HOST_PATH: ${host}, and the compose file is there"
}

# @function check_image_pin
# Report whether the running container is on the image this repo pins.
#
# The pin is the reason the behavioural claims in hermes/ hold: which config keys
# exist, what the web registry does with them, which tools the image ships. A
# container on a newer tag while the compose file names another means the docs and
# the running agent disagree, and neither side says so.
# Globals:
#   COMPOSE_FILE, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or note: lines
# Returns:
#   0 always
check_image_pin() {
  local want="" have=""
  want="$(doctor_pinned_image)"
  [ "${DRY_RUN}" -eq 1 ] && {
    note "image pin: not probed under --dry-run"
    return 0
  }
  if [ -z "${want}" ]; then
    warn "the compose file names no image for the hermes service"
    return 0
  fi
  have=""
  if doctor_container_running; then
    have="$(docker inspect -f '{{.Config.Image}}' "$(doctor_container)" 2>/dev/null || true)"
  fi
  if [ -z "${have}" ]; then
    note "image pin: the container is not running, so only the pin is known (${want})"
    return 0
  fi
  if [ "${have}" = "${want}" ]; then
    ok "image: ${have}, the pin this checkout names"
  else
    warn "image: running ${have}, this checkout pins ${want} - the docs and the agent may disagree"
  fi
}

# @function doctor_pinned_image
# Print the image reference the compose file gives the hermes service.
# Globals:
#   COMPOSE_FILE, PROJECT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The image reference on stdout, or the shipped default when nothing is readable
# Returns:
#   0
doctor_pinned_image() {
  local file="${COMPOSE_FILE:-${ROOT}/docker-compose.yml}"
  if [ -f "${file}" ]; then
    local found=""
    found="$(awk '
      /^  hermes:/ { inblk = 1; next }
      inblk && /^  [A-Za-z0-9_-]+:/ { exit }
      inblk && /^[[:space:]]*image:/ { print $2; exit }
    ' "${file}")"
    [ -n "${found}" ] && {
      printf '%s\n' "${found}"
      return 0
    }
  fi
  printf '%s\n' "${HERMES_IMAGE_DEFAULT}"
}

# @function check_model_key
# Report the one credential the assistant is meant to hold.
#
# LITELLM_MASTER_KEY is the whole credential surface by design - there is no
# GitHub PAT here, and the config keeps the key a token so no byte of it lands in
# the volume. A change-me-* value is the one failure that reads as health: the
# container starts, the config parses, and every model call is refused.
# Globals:
#   ENV_FILE, COMPOSE_FILE, ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or error: lines; never a value
# Returns:
#   0 always; a failure is recorded with fail_item
check_model_key() {
  local key="" value=""
  [ "${DRY_RUN}" -eq 1 ] && {
    note "model key: not probed under --dry-run"
    return 0
  }
  key="${ENV_FILE:-$(dirname "${COMPOSE_FILE:-${ROOT}/docker-compose.yml}")/.env}"
  value="$(doctor_env_of LITELLM_MASTER_KEY)"
  [ -n "${value}" ] || value="$(env_get "${key}" LITELLM_MASTER_KEY)"
  if [ -z "${value}" ]; then
    fail_item "LITELLM_MASTER_KEY is set nowhere this audit can see: the assistant has no model transport"
  elif printf '%s' "${value}" | grep -q '^change-me'; then
    fail_item "LITELLM_MASTER_KEY is still the shipped placeholder: the container boots and every model call is refused"
  else
    ok "model key: LITELLM_MASTER_KEY is set and is not the placeholder (value not printed)"
  fi
}

# @function check_anywhere_door
# Report the two doors that exist for an operator who is away from the desk.
#
# The API server is the widest opening on the box: it carries the whole toolset
# behind one bearer token. It ships closed, so the audit answer that matters is not
# "is it on" but "did someone open it and leave it half-wired" - enabled on a
# placeholder key reads to the operator as an assistant that has stopped answering,
# and a mapping published off loopback puts that token on the LAN. Push is the
# mirror image: nothing to open in compose at all, and the one risk worth naming is
# a topic anyone can publish to, because the gateway treats every publisher to a
# topic as a single identity.
# Globals:
#   DRY_RUN, ENV_FILE, COMPOSE_FILE, ROOT
# Arguments:
#   None
# Outputs:
#   ok:, warning:, error:, or note: lines; never a key value and never a topic value
# Returns:
#   0 always; a failure is recorded with fail_item
check_anywhere_door() {
  local envf="" enabled="" api_key="" bind="" cors="" volume="" topic_line="" allowed=""
  [ "${DRY_RUN}" -eq 1 ] && {
    note "anywhere door: not probed under --dry-run"
    return 0
  }
  envf="${ENV_FILE:-$(dirname "${COMPOSE_FILE:-${ROOT}/docker-compose.yml}")/.env}"
  enabled="$(doctor_env_of API_SERVER_ENABLED)"
  [ -n "${enabled}" ] || enabled="$(env_get "${envf}" HERMES_API_SERVER_ENABLED)"
  case "${enabled}" in
    1 | true | True | TRUE | yes | Yes | YES | on | On | ON) ;;
    *)
      ok "api server: closed (${enabled:-unset}) - the shipped state"
      enabled=""
      ;;
  esac
  if [ -n "${enabled}" ]; then
    api_key="$(doctor_env_of API_SERVER_KEY)"
    [ -n "${api_key}" ] || api_key="$(env_get "${envf}" HERMES_API_SERVER_KEY)"
    case "${api_key}" in
      '')
        fail_item "api server is enabled with no key: upstream refuses to serve unauthenticated, so this reads as a dead assistant rather than an open one"
        ;;
      change-me*)
        fail_item "api server is enabled on the shipped placeholder key - run bootstrap so it is generated"
        ;;
      *) ok "api server: enabled, with a key set (value not printed)" ;;
    esac
    bind="$(env_get "${envf}" HERMES_API_BIND)"
    case "${bind}" in
      '' | 127.0.0.1 | localhost)
        ok "api server: published on loopback only, so nothing off this host can dial it"
        ;;
      *)
        warn "api server: HERMES_API_BIND=${bind} puts the whole toolset on that interface behind one token"
        ;;
    esac
    cors="$(doctor_env_of API_SERVER_CORS_ORIGINS)"
    if [ -n "${cors}" ]; then
      warn "api server: browser callers are allowed from ${cors} - name origins you chose, and never a wildcard"
    fi
  fi

  # Push is configured on the volume, not in compose: the gateway registers the
  # adapter from the presence of NTFY_TOPIC in its own environment, which is why an
  # empty key in the compose env would have handed it a half-built platform.
  volume="$(doctor_volume_dir || true)"
  if [ -z "${volume}" ] || [ ! -f "${volume}/.env" ]; then
    note "push: no ntfy channel configured, so nothing reaches a phone unprompted (--data DIR names the volume)"
    return 0
  fi
  if ! grep -qE '^[[:space:]]*NTFY_TOPIC=.+' "${volume}/.env"; then
    note "push: the volume's .env names no NTFY_TOPIC, so the adapter is not registered"
    return 0
  fi
  ok "push: an ntfy channel is configured (topic and token not printed)"
  # No allowlist is the recommended shape: with none, the agent never answers the
  # topic, so the phone gets notices and the topic stays an output. An allowlist
  # makes it a two-way door, and the topic name is its only credential.
  allowed="$(grep -E '^[[:space:]]*NTFY_ALLOWED_USERS=.+' "${volume}/.env" | head -1 || true)"
  if [ -n "${allowed}" ]; then
    warn "push: NTFY_ALLOWED_USERS is set, so inbound is open on this topic - every publisher to it is one identity to the gateway"
  else
    ok "push: push-only (no NTFY_ALLOWED_USERS), so nobody can answer through the topic"
  fi
  topic_line="$(grep -E '^[[:space:]]*NTFY_SERVER_URL=.+' "${volume}/.env" | head -1 || true)"
  if [ -z "${topic_line}" ]; then
    warn "push: NTFY_SERVER_URL is unset, so the notices go to the public ntfy.sh - a self-hosted server keeps them on your hardware"
  fi
}

# @function check_agent_verbs
# Say whether the assistant can still reach the coding-agent control plane.
#
# The coding-agents skill tells the assistant to run scripts/coder-sessions.sh off
# the identical-path checkout mount. Two ways that stops being true without anything
# looking broken: the checkout on the host is older than the skill the volume
# mounted, and the docker socket is no longer in the container the verbs need it in.
# Globals:
#   ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or note: lines
# Returns:
#   0 always; a failure is recorded with fail_item
check_agent_verbs() {
  local cli="" mounts="" id=""
  cli="${ROOT}/scripts/coder-sessions.sh"
  if [ -f "${cli}" ]; then
    ok "agent verbs: scripts/coder-sessions.sh is on the checkout the assistant mounts"
  else
    fail_item "scripts/coder-sessions.sh is missing from ${ROOT}: the coding-agents skill points the assistant at a file that is not there (pull, then recreate)"
  fi
  [ "${DRY_RUN}" -eq 1 ] && {
    note "agent verbs: the socket was not inspected under --dry-run"
    return 0
  }
  # Resolved before the inspect: an empty argument makes the daemon answer about the
  # first container it likes, which would report some other service's mounts as the
  # assistant's.
  id="$(doctor_container || true)"
  if [ -z "${id}" ]; then
    note "agent verbs: the assistant's container is not running, so the socket was not checked"
    return 0
  fi
  mounts="$(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' \
    "${id}" 2>/dev/null || true)"
  if [ -z "${mounts}" ]; then
    note "agent verbs: the container is not readable from here, so the socket was not checked"
  elif printf '%s\n' "${mounts}" | grep -qE 'docker\.sock$'; then
    ok "agent verbs: the docker socket is mounted, which is how the verbs see workspaces"
  else
    warn "agent verbs: no docker socket in the container, so list/show/tail have nothing to read"
  fi
}

# @function check_dashboard
# Report the dashboard's door state.
#
# The gateway binds 0.0.0.0 and an empty basic-auth pair makes it refuse to come
# up at all, so the defaults exist to be non-empty and the operator has to mean
# it to weaken them. The public URL rides the router, so an https value that
# arrives as http is a card pointing at a name that will not answer.
# Globals:
#   ENV_FILE, COMPOSE_FILE, ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or error: lines; never a value
# Returns:
#   0 always; a failure is recorded with fail_item
check_dashboard() {
  local key="" name="" value="" failed=0 user="" pass=""
  [ "${DRY_RUN}" -eq 1 ] && {
    note "dashboard: not probed under --dry-run"
    return 0
  }
  key="${ENV_FILE:-$(dirname "${COMPOSE_FILE:-${ROOT}/docker-compose.yml}")/.env}"
  for name in HERMES_DASHBOARD_USER HERMES_DASHBOARD_PASSWORD HERMES_DASHBOARD_SECRET; do
    value="$(doctor_env_of "${name}")"
    [ -n "${value}" ] || value="$(env_get "${key}" "${name}")"
    case "${name}" in
      HERMES_DASHBOARD_USER) user="${value}" ;;
      HERMES_DASHBOARD_PASSWORD) pass="${value}" ;;
    esac
    case "${value}" in
      '')
        warn "${name} is unset: the gateway refuses a non-loopback bind with no provider"
        failed=1
        ;;
      change-me*)
        warn "${name} is still the shipped placeholder"
        failed=1
        ;;
    esac
  done
  if [ "${failed}" -eq 0 ]; then
    ok "dashboard: basic auth is set on all three keys (values not printed)"
  fi
  if [ -n "${user}" ] && [ "${user}" = "${pass}" ]; then
    warn "dashboard: the basic-auth user and the password are the same string"
  fi
  value="$(doctor_env_of HERMES_DASHBOARD_PUBLIC_URL)"
  case "${value}" in
    https://*) ok "dashboard: public URL is https" ;;
    http://*) warn "dashboard: public URL is plain http (${value}) - that name rides the router on https" ;;
    '') ;;
  esac
}

# @function check_memories
# Report the state of the assistant's own memory store.
#
# /opt/data holds a SQLite database in WAL mode, which is why the path is a named
# volume: WAL on a bind mount across a hypervisor boundary is how the store
# corrupts. Two writers corrupt it the same way, which is why the terminal door
# exists. Both facts are readable without opening the database.
# Globals:
#   ROOT, DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:, warning:, or note: lines
# Returns:
#   0 always
check_memories() {
  local volume="" candidate="" store=""
  volume="$(doctor_volume_dir || true)"
  if [ -z "${volume}" ]; then
    note "memories: the volume is not readable from here - --data DIR names it"
    return 0
  fi
  # One glob per extension, tested as a file: `ls a* b*` exits non-zero when one
  # of the two patterns matches nothing, which would read as "no store".
  for candidate in "${volume}"/*.sqlite "${volume}"/*.db; do
    if [ -f "${candidate}" ]; then
      store="yes"
      break
    fi
  done
  if [ -n "${store}" ]; then
    ok "memories: a store is present in the volume, and the volume is not a bind of the checkout"
  else
    note "memories: no SQLite store yet - the assistant has not had a session to remember"
  fi
  if [ -f "${volume}/.env" ]; then
    warn "the data directory carries a .env: Hermes reads it at boot, so a key there outranks the container environment"
  fi
}

# @function run_check
# Run one named check, or refuse a name that is not one.
# Globals:
#   None
# Arguments:
#   $1 - the check name
# Outputs:
#   The check's lines, or an error for an unknown name
# Returns:
#   0; an unknown name is a usage error and exits 2
run_check() {
  local name="$1"
  case "${name}" in
    approvals)
      section "approvals"
      check_approvals
      ;;
    terminal-cwd)
      section "terminal cwd"
      check_terminal_cwd
      ;;
    write-root)
      section "write fence"
      check_write_root
      ;;
    web-lane)
      section "web lane"
      check_web_lane
      ;;
    keyless-egress)
      section "egress"
      check_keyless_egress
      ;;
    mcp-servers)
      section "mcp servers"
      check_mcp_servers
      ;;
    seed-drift)
      section "seed drift"
      check_seed_drift
      ;;
    mount-identity)
      section "mount identity"
      check_mount_identity
      ;;
    image-pin)
      section "image pin"
      check_image_pin
      ;;
    model-key)
      section "model key"
      check_model_key
      ;;
    dashboard)
      section "dashboard"
      check_dashboard
      ;;
    anywhere-door)
      section "anywhere door"
      check_anywhere_door
      ;;
    agent-verbs)
      section "agent verbs"
      check_agent_verbs
      ;;
    memories)
      section "memories"
      check_memories
      ;;
    *)
      err "unknown check: ${name} (report|posture|web|diff name them; --check takes one each)"
      exit 2
      ;;
  esac
}

# @function checks_for
# Print the check names a subcommand selects.
#
# The three narrower views are the same functions in a different order, so there
# is one implementation of each fact and no risk of a view disagreeing with the
# full report about what a check means.
# Globals:
#   None
# Arguments:
#   $1 - report|posture|web|diff
# Outputs:
#   One check name per line
# Returns:
#   0
checks_for() {
  case "${1}" in
    report)
      printf '%s\n' approvals terminal-cwd write-root web-lane keyless-egress \
        mcp-servers seed-drift mount-identity image-pin model-key dashboard \
        memories anywhere-door agent-verbs
      ;;
    posture)
      printf '%s\n' approvals write-root keyless-egress mcp-servers model-key dashboard \
        anywhere-door
      ;;
    web)
      printf '%s\n' web-lane keyless-egress mcp-servers
      ;;
    diff)
      printf '%s\n' seed-drift image-pin terminal-cwd
      ;;
  esac
}

# @function main
# Parse argv, resolve the checkout, and run the selected checks.
#
# --check narrows to named checks and outranks the subcommand, because an
# operator who says which fact they want should get exactly that one. The
# subcommand still chooses the section headers and the closing next: line.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, CONTAINER, DATA_DIR, DRY_RUN, SUBCOMMAND,
#   CHECKS, ROOT
# Arguments:
#   $@ - argv
# Outputs:
#   The report
# Returns:
#   0 when nothing failed; 1 on any failure; 2 on a bad invocation
main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p | --project-name)
        [ "$#" -ge 2 ] || die "--project-name needs a value"
        PROJECT="$2"
        shift 2
        ;;
      -f | --file)
        [ "$#" -ge 2 ] || die "--file needs a value"
        COMPOSE_FILE="$2"
        shift 2
        ;;
      -e | --env-file)
        [ "$#" -ge 2 ] || die "--env-file needs a value"
        ENV_FILE="$2"
        shift 2
        ;;
      -c | --container)
        [ "$#" -ge 2 ] || die "--container needs a value"
        CONTAINER="$2"
        shift 2
        ;;
      --data)
        [ "$#" -ge 2 ] || die "--data needs a value"
        DATA_DIR="$2"
        shift 2
        ;;
      --check)
        [ "$#" -ge 2 ] || die "--check needs a check name"
        CHECKS+=("$2")
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      report | posture | web | diff)
        SUBCOMMAND="$1"
        shift
        ;;
      -*)
        err "unknown option: $1"
        usage >&2
        exit 2
        ;;
      *)
        err "unknown subcommand: $1 (expected report|posture|web|diff)"
        usage >&2
        exit 2
        ;;
    esac
  done

  ROOT="$(resolve_checkout "${SELF_DIR}")" || {
    err "cannot find the stack checkout: name the compose file with -f or set REPO_ROOT"
    exit 5
  }
  [ -n "${COMPOSE_FILE}" ] || COMPOSE_FILE="${ROOT}/docker-compose.yml"

  section "Hermes doctor (${SUBCOMMAND}) on ${PROJECT}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    note "dry run: nothing is inspected, and the container commands are printed instead"
    # Print the one command every container-level fact is read through, so the
    # addressing an operator is about to audit is on the screen before they run
    # it for real. doctor_compose answers under --dry-run without running it.
    doctor_compose ps -q hermes
  fi
  if [ "${#CHECKS[@]}" -gt 0 ]; then
    local name
    for name in "${CHECKS[@]}"; do
      run_check "${name}"
    done
  else
    local name
    while read -r name; do
      [ -n "${name}" ] && run_check "${name}"
    done < <(checks_for "${SUBCOMMAND}")
  fi
  summary
  [ "${SUMMARY_FAIL:-0}" -eq 0 ] || return 1
}

main "$@"
