#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## coder-sessions.sh - see and drive the coding agents running in Coder workspaces.
#
# The question this answers is the one an operator asks from a phone: "what are my
# coding agents doing right now, and can I start another one?" Until now the stack
# had no answer to either half. The workspaces were reachable only through the Coder
# UI, and the agent sessions inside them - the tmux panes that
# templates/common/grok-build-terminal.sh and vscode-terminal-tmux.sh actually put
# the Grok CLI in - were visible to nobody but the browser tab already looking at
# them. An operator away from the desk could not tell a stuck agent from a thinking
# one, could not answer the one line it was waiting on, and could not start a run
# without opening the editor.
#
# Why this reads the Docker daemon and not the Coder API. A workspace that can host
# a session is a *running* one, and a running workspace is a labelled container:
# both templates stamp coder.workspace_id and coder.workspace_name onto what they
# create (templates/workspace/main.tf, templates/devcontainer/main.tf), which is the
# same label scripts/github-auth.sh already enumerates to find workspace containers.
# Reading the daemon therefore needs no credential and works from the Hermes
# container, which holds the socket and nothing else. The Coder API needs a session
# token, and this stack mints one only for the length of a template push
# (scripts/push-template.sh) and deletes it on the way out precisely because it is
# root-equivalent - so a chat turn that wanted to list workspaces would have to mint
# one itself. Where a verb genuinely belongs to Coder rather than to the daemon, this
# CLI prints the hand-off command instead of quietly becoming a credential mint.
#
# Why the sidecar is excluded. Each workspace creates two containers: docker_container
# "workspace", named coder-<owner>-<workspace>, and docker_container "dind", named
# coder-<id>-dind-sidecar (local.dind_sidecar in both templates). Both carry the
# workspace labels, so a label filter alone reports an agent session count of zero
# for a box that is running three of them - the sidecar runs a Docker daemon, not a
# shell. The sidecar is dropped by the name the templates give it.
#
# Why the tmux sockets are enumerated per uid. A tmux server belongs to one user and
# listens on /tmp/tmux-<uid>/default. `docker exec` lands as whatever the image's
# default user is, so asking that user for its default server would report "no agent
# running" for a session the operator can see on screen - the interactive terminals
# are opened by the editor and by startup.sh.tftpl, not by the exec'd user. Listing
# ${TMUX_TMPDIR:-/tmp}/tmux-* finds every server the workspace actually has and reads
# each one.
#
# Why every target carries tmux's "=" prefix. A bare target name is tried as an exact
# match and then as a name prefix, so once "review" is gone "review-2" answers for it
# and a keystroke meant for one agent lands in another's prompt. vscode-terminal-tmux.sh
# records the same lesson for the same reason.
#
# Why launch names a session the way it does. With no --name it reproduces the rule in
# templates/common/grok-build-terminal.sh - grok-build-<folder>-<first six of cksum>
# over the repo root - and runs `grok --cwd <dir>` the way that file does, so a session
# started from a phone is the very session the editor's Grok Build terminal profile
# rejoins when the operator sits down. A differently-named session would start a second
# agent beside the first, which is what that naming exists to prevent.
#
# Usage (Bazel from a host shell; the second form is what runs inside the Hermes
# container, whose image ships no bazelisk - see docs/hermes.md):
#   bazelisk run //scripts:coder-sessions -- list
#   bazelisk run //scripts:coder-sessions -- show myrepo
#   bazelisk run //scripts:coder-sessions -- tail myrepo grok-build-myrepo-1a2b3c 40
#   bazelisk run //scripts:coder-sessions -- send myrepo grok-build-myrepo-1a2b3c 'yes, run the tests'
#   bazelisk run //scripts:coder-sessions -- --dir /home/coder/myrepo launch myrepo
#   bazelisk run //scripts:coder-sessions -- --name spike launch myrepo -- npm test
#   bazelisk run //scripts:coder-sessions -- stop myrepo spike
#   bazelisk run //scripts:coder-sessions -- check
#   bazelisk run //scripts:coder-sessions -- --json list
#   bash "$STACK_HOST_PATH/scripts/coder-sessions.sh" list
#
# Subcommands:
#   list                         every running workspace: name, container, sessions
#   show WORKSPACE               agent sessions in one workspace, with their state
#   tail WORKSPACE SESSION [N]   the last N lines of a session's pane (default 24)
#   send WORKSPACE SESSION TEXT  type into a session (Enter follows unless --no-enter)
#   launch [--name N] [--dir DIR] WORKSPACE [-- CMD...]
#                                start a detached session; the default CMD is the
#                                Grok Build CLI over DIR, mirroring the shipped
#                                terminal profile. --name and --dir are options, so
#                                they go before the subcommand like every other flag
#   stop WORKSPACE SESSION       kill one session
#   check                        why a verb returned nothing: daemon, labels, tmux
#
# Options (every one of these goes before the subcommand; every word after the
# subcommand belongs to the verb, which is what lets `launch ws -- npm test --run`
# keep the flags that belong to npm):
#   --json            machine-readable output for list and show; report lines go to
#                     stderr so stdout stays a bare JSON document
#   --container NAME  address this container instead of resolving WORKSPACE by label
#   --timeout SECS    cap on every docker call, default 30 (120 for launch and send)
#   --dry-run         print the command that would run inside the container, run nothing
#   -h, --help        print this usage and exit 0
#
# The mutating verbs are send, launch, and stop. They name a tmux target and nothing
# broader: no shell string built from argv reaches the container, and every argument
# travels as its own positional parameter. The read verbs touch nothing.
#
# Exit codes: 0 when the verb did its work or --dry-run printed; 1 when a workspace,
# container, or session does not exist, or a docker call failed; 2 on a bad
# subcommand or missing argument; 5 when the Docker daemon does not answer.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# stack_timeout and DOCKER_BIN come from the same library the other daemon-facing
# CLIs use, so this CLI caps and addresses docker the way the rest of the stack does.
# shellcheck source=lib/coder_api.sh disable=SC1091
source "${SELF_DIR}/lib/coder_api.sh"

JSON_MODE_WANTED=0
CONTAINER_OVERRIDE=""
TIMEOUT_SECS="${PROBE_TIMEOUT:-30}"
MUTATE_TIMEOUT_SECS=120
DRY_RUN=0
VERB=""
ARGS=()
LAUNCH_NAME=""
LAUNCH_DIR=""
NO_ENTER=0

# @function usage
# Print the subcommand list, the flag list and the exit-code contract on stdout.
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
usage: bazelisk run //scripts:coder-sessions [--json] [--container NAME]
                    [--timeout SECS] [--dry-run] [-h|--help] SUBCOMMAND [ARGS...]

Lists and drives the coding-agent sessions running inside this stack's Coder
workspaces - the tmux panes the workspace templates put the Grok CLI in. Reads
the Docker daemon by the coder.workspace_name label, so it needs no Coder token,
and runs from the Hermes container with nothing but bash, docker, and tmux.

Subcommands:
  list                        running workspaces, container, agent-session count
  show WORKSPACE              agent sessions with command, idle time, last line
  tail WORKSPACE SESSION [N]  last N lines of a pane (default 24)
  send WORKSPACE SESSION TEXT type into a session (--no-enter to withhold Enter)
  launch [--name N] [--dir DIR] WORKSPACE [-- CMD...]
                              start a detached session; default CMD is
                              `grok --cwd DIR`, the shipped terminal profile
  stop WORKSPACE SESSION      kill one session
  check                       why a verb returned nothing (daemon, labels, tmux)

Mutating verbs: send, launch, stop. Everything else reads.

Options: --json (list and show), --container NAME, --timeout SECS, --dry-run,
-h/--help. Inside the Hermes container, whose image has no bazelisk:
  bash "$STACK_HOST_PATH/scripts/coder-sessions.sh" list

Exit codes: 0 = verb ran or dry run; 1 = unknown workspace/container/session or a
failed docker call; 2 = bad subcommand or missing argument; 5 = no Docker daemon.
USAGE
}

# @function daemon_reachable
# Say whether docker answers at all, and whether this shell is looking at the stack's
# daemon or at a workspace's own DinD sidecar. The second half is not decoration:
# inside a Coder workspace container DOCKER_HOST points at that workspace's sidecar,
# so an empty list there is the normal answer and not an outage, and saying so is the
# difference between a hand-off and a false alarm.
# Globals:
#   DOCKER_BIN
# Arguments:
#   None
# Outputs:
#   One explanatory line when the box is a workspace or the daemon is silent
# Returns:
#   0 when the daemon answered; 5 when it did not
daemon_reachable() {
  if [ -n "${CODER_WORKSPACE_ID:-}" ] || [ -n "${EVO_T1_DEVCONTAINER:-}" ]; then
    note "this shell is inside a workspace/dev container, so docker addresses that container's own DinD sidecar, not the stack daemon; run this on the stack host or in the Hermes container"
  fi
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  if stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} version >/dev/null 2>&1; then
    return 0
  fi
  err "the Docker daemon does not answer (is ${DOCKER_BIN} usable here? whole-stack commands belong in a host shell)"
  return 5
}

# @function workspace_rows
# Print one "workspace<TAB>container<TAB>state" line per running workspace container,
# across every compose project the daemon holds. Project scoping is deliberately
# absent for the reason scripts/lib/coder_api.sh records: a compose call resolves a
# project from the cwd, and under `bazelisk run` that cwd is a runfiles copy whose
# directory name is not a project anywhere.
# Globals:
#   DOCKER_BIN, TIMEOUT_SECS
# Arguments:
#   None
# Outputs:
#   Tab-separated rows on stdout; docker's own error text when the call fails
# Returns:
#   0 when the daemon answered, the command's status otherwise
workspace_rows() {
  local tab=$'\t'
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} ps \
    --filter label=coder.workspace_id \
    --format '{{.Label "coder.workspace_name"}}'"${tab}"'{{.Names}}'"${tab}"'{{.State}}' \
    </dev/null 2>&1 |
    awk -F'\t' '$2 !~ /-dind-sidecar$/ && $1 != "" {print}'
}

# @function resolve_container
# Print the container that runs a named workspace, or nothing when no running
# container carries that coder.workspace_name. Matching is whole-field and
# case-sensitive against the label, so a workspace named "api" cannot be answered by
# "api-2"; the operator names what `list` printed.
# Globals:
#   CONTAINER_OVERRIDE
# Arguments:
#   $1 - workspace name
# Outputs:
#   The container name on stdout, or nothing
# Returns:
#   0 when one was found; 1 when the name matched nothing
resolve_container() {
  local want="${1:-}"
  if [ -n "${CONTAINER_OVERRIDE}" ]; then
    printf '%s\n' "${CONTAINER_OVERRIDE}"
    return 0
  fi
  [ -n "${want}" ] || return 1
  workspace_rows | awk -F'\t' -v want="${want}" '$1 == want {c = $2} END {if (c) {print c; exit 0}; exit 1}'
}

# @function tmux_sockets
# Print every tmux socket path a container actually has, one per line. Empty output
# means the container has no tmux server, which for a workspace means no interactive
# terminal has been opened in it yet. The directory is ${TMUX_TMPDIR:-/tmp}, which is
# the rule tmux(1) itself uses, so a workspace that relocates its sockets is still
# read correctly.
# Globals:
#   DOCKER_BIN, TIMEOUT_SECS
# Arguments:
#   $1 - container name
# Outputs:
#   Socket paths on stdout
# Returns:
#   0, always: a container with no /tmp/tmux-* is a state, not an error
tmux_sockets() {
  local container="${1:-}" root
  # TMUX_TMPDIR is where tmux itself puts its sockets when it is set, so honouring it
  # here is what keeps this probe and that server looking at the same directory.
  root="${TMUX_TMPDIR:-/tmp}"
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
    sh -c 'root="$1"; for d in "$root"/tmux-*; do [ -d "$d" ] || continue; [ -S "$d/default" ] && printf "%s/default\n" "$d"; done' \
    sh "${root}" \
    </dev/null 2>/dev/null || true
}

# @function pane_rows
# Print every pane of one tmux server as
# "session<TAB>pane_id<TAB>attached<TAB>activity_epoch<TAB>command<TAB>path".
# list-panes -a covers all sessions of that server, so this is one exec per server
# rather than one per session.
# Globals:
#   DOCKER_BIN, TIMEOUT_SECS
# Arguments:
#   $1 - container name; $2 - socket path
# Outputs:
#   Tab-separated pane rows on stdout; nothing when the server has no pane
# Returns:
#   0, always
pane_rows() {
  local container="${1:-}" socket="${2:-}" fmt
  # The format is passed as its own argv word, tabs included, so no part of it is
  # interpolated into the shell string the container runs.
  fmt=$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    '#{session_name}' '#{pane_id}' '#{session_attached}' \
    '#{window_activity}' '#{pane_current_command}' '#{pane_current_path}')
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
    sh -c 'tmux -S "$1" list-panes -a -F "$2" 2>/dev/null' sh "${socket}" "${fmt}" \
    </dev/null 2>/dev/null || true
}

# @function state_word
# Turn idle seconds, attached-ness and the pane's foreground command into one word an
# operator can read on a phone. The rule is stated rather than implied, because it is
# a heuristic and not a fact tmux reports: an attached pane whose foreground command
# is a shell is waiting for a person, an attached pane running anything else is the
# agent working, and a detached pane is only a kept-alive buffer.
# Globals:
#   None
# Arguments:
#   $1 - idle seconds ("" or non-numeric tolerated); $2 - attached (0/1); $3 - command
# Outputs:
#   One word on stdout: waiting, running, quiet, idle-shell, detached-shell, unknown
# Returns:
#   0
state_word() {
  local idle="${1:-}" attached="${2:-0}" command="${3:-}" shell_re
  # The shells a workspace lands on when nothing is running. Matched as a suffix so
  # a login shell spelled "-bash" is still recognised as a shell.
  shell_re='^(bash|sh|zsh|fish|dash|-bash|-zsh|-sh)$'
  if [[ ! ${idle} =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [ "${attached}" = "1" ]; then
    if [[ ${command} =~ ${shell_re} ]]; then
      printf 'waiting\n'
    else
      printf 'running\n'
    fi
    return 0
  fi
  if [[ ${command} =~ ${shell_re} ]]; then
    if [ "${idle}" -le 30 ]; then
      printf 'idle-shell\n'
    else
      printf 'detached-shell\n'
    fi
    return 0
  fi
  if [ "${idle}" -le 30 ]; then
    printf 'running\n'
  else
    printf 'quiet\n'
  fi
}

# @function session_rows_for
# Print every agent session of one workspace as
# "session<TAB>state<TAB>idle<TAB>command<TAB>path", one row per *session* (the
# busiest pane of that session wins, so a split window reads once).
# Globals:
#   TIMEOUT_SECS
# Arguments:
#   $1 - container name
# Outputs:
#   Tab-separated rows on stdout
# Returns:
#   0, always
session_rows_for() {
  local container="${1:-}" socket now
  now="$(date +%s)"
  while IFS= read -r socket; do
    [ -n "${socket}" ] || continue
    pane_rows "${container}" "${socket}" |
      while IFS=$'\t' read -r sess _pane attached activity command path; do
        [ -n "${sess}" ] || continue
        local idle=""
        if [[ ${activity} =~ ^[0-9]+$ ]]; then
          idle=$((now > activity ? now - activity : 0))
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "${sess}" "$(state_word "${idle}" "${attached}" "${command}")" \
          "${idle:-}" "${command}" "${path}"
      done
  done < <(tmux_sockets "${container}")
}

# @function json_field
# Render one value as a JSON string literal, ready to paste after a colon.
#
# common.sh's json_escape escapes the backslash and the quote, drops newlines and
# truncates, and leaves the quoting to the caller. It does not touch tabs, and every
# row this CLI hands over is tab-separated, so a tab that survived the split upstream
# would land raw in the document and a strict parser would reject the whole array on
# the control character. A tab becomes a space: the value stays readable and the
# document always parses.
#
# Globals:
#   None
# Arguments:
#   $1 - the raw value
# Outputs:
#   The quoted, escaped value on stdout
# Returns:
#   0
json_field() {
  printf '"%s"' "$(json_escape "${1:-}" | tr '\t' ' ')"
}

# @function report_json
# Print one verb's result as a JSON array of objects. Field names are fixed and are
# the same ones the human-readable form labels, so a phone client reads one and
# prints the other.
# Globals:
#   None
# Arguments:
#   $1 - the verb (list|show); $2 - newline-separated tab-separated rows
# Outputs:
#   A JSON array on stdout
# Returns:
#   0
report_json() {
  local verb="${1:-}" rows="${2:-}" first=1
  local -a fields
  case "${verb}" in
    list) fields=(workspace container state sessions) ;;
    *) fields=(session state idle command path) ;;
  esac
  printf '['
  while IFS=$'\t' read -r a b c d e; do
    [ -n "${a}" ] || continue
    [ "${first}" = 1 ] || printf ','
    first=0
    # common.sh's json_escape escapes and truncates and leaves the quoting to the
    # caller, which is how coder-agents.sh builds its bodies too; json_field is the
    # quoting half and also folds a stray tab.
    printf '{'
    printf '"%s":%s' "${fields[0]}" "$(json_field "${a}")"
    printf ',"%s":%s' "${fields[1]}" "$(json_field "${b}")"
    printf ',"%s":%s' "${fields[2]}" "$(json_field "${c}")"
    printf ',"%s":%s' "${fields[3]}" "$(json_field "${d}")"
    if [ "${#fields[@]}" -gt 4 ]; then
      printf ',"%s":%s' "${fields[4]}" "$(json_field "${e}")"
    fi
    printf '}'
  done <<<"${rows}"
  printf ']\n'
}

# @function verb_list
# Print every running workspace with its container and how many agent sessions it
# holds. This is the answer to "what is on my machine right now" and the only verb
# that needs no argument, so it is the one a phone opens with.
# Globals:
#   JSON_MODE_WANTED
# Arguments:
#   None
# Outputs:
#   The report on stdout
# Returns:
#   0 always: zero workspaces is a state, and `check` explains it
verb_list() {
  local rows="" sess count
  section "Coder workspaces"
  rows="$(workspace_rows)"
  if [ "${JSON_MODE_WANTED}" = 1 ]; then
    local out=""
    while IFS=$'\t' read -r name container _state; do
      [ -n "${name}" ] || continue
      count="$(session_rows_for "${container}" | awk -F'\t' '$1 != "" {n++} END {print n + 0}')"
      out+="${name}"$'\t'"${container}"$'\t'"${_state}"$'\t'"${count}"$'\n'
    done <<<"${rows}"
    report_json list "${out}"
    return 0
  fi
  if [ -z "${rows}" ]; then
    note "no running workspace container carries label coder.workspace_id"
    note "a stopped workspace has no container at all; start it in Coder, then re-run"
    ok "0 workspaces running"
    summary
    return 0
  fi
  while IFS=$'\t' read -r name container state; do
    [ -n "${name}" ] || continue
    count="$(session_rows_for "${container}" | awk -F'\t' '$1 != "" {n++} END {print n + 0}')"
    sess="${count} agent session(s)"
    log "${name}  [${container}]  ${state}  ${sess}"
  done <<<"${rows}"
  ok "workspace list"
  summary
}

# @function verb_show
# Print one workspace's agent sessions with their state, idle seconds, foreground
# command and working directory, so the operator can tell a stuck run from a thinking
# one without opening the editor.
# Globals:
#   JSON_MODE_WANTED, CONTAINER_OVERRIDE
# Arguments:
#   $1 - workspace name (optional when --container names one)
# Outputs:
#   The report on stdout
# Returns:
#   0 on success; 1 when the workspace is not running
verb_show() {
  local want="${1:-}" container="" rows=""
  container="$(resolve_container "${want}")" || {
    err "no running workspace named '${want}'"
    note "run 'list' for what is running, or 'check' for why the list is empty"
    return 1
  }
  [ -n "${container}" ] || {
    err "no container to address (name a workspace, or pass --container)"
    return 2
  }
  section "agent sessions in ${want:-${container}}"
  rows="$(session_rows_for "${container}")"
  if [ "${JSON_MODE_WANTED}" = 1 ]; then
    report_json show "${rows}"
    return 0
  fi
  if [ -z "${rows}" ]; then
    note "no tmux session in ${container}: no interactive terminal has been opened there yet"
    note "start one with: launch ${want:-${container}} --dir <clone-dir>"
    ok "0 agent sessions"
    summary
    return 0
  fi
  while IFS=$'\t' read -r sess state idle command path; do
    [ -n "${sess}" ] || continue
    log "${sess}  ${state}  idle=${idle:-?}s  cmd=${command}  cwd=${path}"
  done <<<"${rows}"
  ok "session list"
  summary
}

# @function verb_tail
# Print the last N lines of one session's pane. This is what makes "is it stuck" a
# question with an answer from a phone: the pane is the only place the agent's own
# output exists.
# Globals:
#   CONTAINER_OVERRIDE, DRY_RUN, DOCKER_BIN, TIMEOUT_SECS
# Arguments:
#   $1 - workspace name; $2 - session name; $3 - line count (default 24)
# Outputs:
#   The pane history on stdout
# Returns:
#   0 on success; 1 when the workspace is unknown; 2 on a missing session argument
verb_tail() {
  local want="${1:-}" sess="${2:-}" lines="${3:-24}" container="" rc=0 body=""
  [ -n "${sess}" ] || {
    err "tail needs a session name (see 'show ${want}')"
    return 2
  }
  [[ ${lines} =~ ^[0-9]+$ ]] || {
    err "line count must be a number, got '${lines}'"
    return 2
  }
  container="$(resolve_container "${want}")" || {
    err "no running workspace named '${want}'"
    return 1
  }
  section "pane ${sess} (${container})"
  while IFS= read -r socket; do
    [ -n "${socket}" ] || continue
    # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
    body="$(stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
      sh -c 'tmux -S "$1" capture-pane -p -t "=$2" -S -"$3" 2>/dev/null' \
      sh "${socket}" "${sess}" "${lines}" </dev/null 2>/dev/null)" || rc=$?
    [ -n "${body}" ] || continue
    printf '%s\n' "${body}"
    ok "pane tail"
    summary
    return 0
  done < <(tmux_sockets "${container}")
  err "no pane named '${sess}' in ${container} (and nothing to print)"
  note "run 'show ${want:-${container}}' for the session names this container has"
  return 1
}

# @function verb_send
# Type into one session. The text is one argv word handed to tmux's -l (literal) flag,
# so nothing in it is re-parsed by a shell inside the container; the Enter key is a
# separate send-keys and --no-enter withholds it.
# Globals:
#   CONTAINER_OVERRIDE, DRY_RUN, DOCKER_BIN, MUTATE_TIMEOUT_SECS, NO_ENTER
# Arguments:
#   $1 - workspace name; $2 - session name; $3 - text to type
# Outputs:
#   What was sent, then the pane tail so the send is not a blind act
# Returns:
#   0 on success; 1 when the workspace is unknown or the session is absent; 2 on
#   missing arguments
verb_send() {
  local want="${1:-}" sess="${2:-}" text="${3:-}" container="" socket sent=0
  [ -n "${sess}" ] && [ -n "${text}" ] || {
    err "send needs a session and the text to type"
    return 2
  }
  container="$(resolve_container "${want}")" || {
    err "no running workspace named '${want}'"
    return 1
  }
  section "send to ${sess} (${container})"
  if [ "${DRY_RUN}" = 1 ]; then
    printf 'dry run: %s exec %s sh -c '\''tmux -S "$1" send-keys -t =%s -l "$2"'\'' <socket> <text>\n' \
      "${DOCKER_BIN}" "${container}" "${sess}"
    ok "dry run: nothing sent"
    summary
    return 0
  fi
  while IFS= read -r socket; do
    [ -n "${socket}" ] || continue
    # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
    # Two calls, and the first one carries the verdict: has-session failing has to
    # reach the caller as a failure, which an `|| true` at the end of that chain would
    # have hidden by reporting success for a session that does not exist.
    if stack_timeout "${MUTATE_TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
      sh -c 'tmux -S "$1" has-session -t "=$2" 2>/dev/null || exit 1
             tmux -S "$1" send-keys -t "=$2" -l "$3" 2>/dev/null || exit 1' \
      sh "${socket}" "${sess}" "${text}" </dev/null 2>/dev/null; then
      if [ "${NO_ENTER}" != "1" ]; then
        # shellcheck disable=SC2086
        stack_timeout "${MUTATE_TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
          sh -c 'tmux -S "$1" send-keys -t "=$2" Enter 2>/dev/null' \
          sh "${socket}" "${sess}" </dev/null 2>/dev/null || true
      fi
      sent=1
      break
    fi
  done < <(tmux_sockets "${container}")
  if [ "${sent}" != "1" ]; then
    err "no session named '${sess}' in ${container}: nothing was sent"
    note "run 'show ${want:-${container}}' for the session names this container has"
    return 1
  fi
  ok "typed into ${sess}"
  summary
  # The echo-back is a convenience, not the verb's contract: the keystrokes are in
  # whether or not the pane has produced a line yet, so an empty tail warns and the
  # send still exits 0.
  if ! verb_tail "${want}" "${sess}" 12; then
    warn "typed into ${sess}, but the pane printed nothing back yet"
  fi
}

# @function verb_launch
# Start one detached agent session in a workspace. With no --name and no -- command it
# reproduces the shipped Grok Build terminal profile: the session name is the same
# cksum-derived name templates/common/grok-build-terminal.sh derives, and the command
# is `grok --cwd DIR`, so a session started from a phone is the very session the
# editor's Grok Build terminal profile rejoins when the operator sits down. A
# differently-named session would start a second agent beside the first, which is what
# that naming exists to prevent.
#
# The socket is named, never left to tmux's default: `docker exec` lands as the image's
# default user, and a bare `tmux new-session` there would raise a second server that
# the operator's editor, attached to the real one, can never show. With no server yet,
# the path tmux itself would have chosen for this user is used.
# Globals:
#   CONTAINER_OVERRIDE, DRY_RUN, DOCKER_BIN, MUTATE_TIMEOUT_SECS, LAUNCH_NAME, LAUNCH_DIR
# Arguments:
#   $1 - workspace name; the rest is the command to run, already past --
# Outputs:
#   Whether the session was created or reused, and the name it went by
# Returns:
#   0 on success; 1 when the workspace is unknown or tmux refused; 2 on a bad argument
verb_launch() {
  local want="${1:-}" container="" rc=0 out="" sock="" action="" name=""
  shift || true
  container="$(resolve_container "${want}")" || {
    err "no running workspace named '${want}'"
    return 1
  }
  section "launch a session in ${want:-${container}}"
  # Reuse the server the operator is already looking at when there is one.
  sock="$(tmux_sockets "${container}" | head -n 1)"
  if [ "${DRY_RUN}" = 1 ]; then
    printf 'dry run: %s exec %s sh -c tmux new-session -d -s %s -c %s -- %s\n' \
      "${DOCKER_BIN}" "${container}" "${LAUNCH_NAME:-<derived from DIR>}" \
      "${LAUNCH_DIR:-\$HOME}" "$*"
    ok "dry run: nothing started"
    summary
    return 0
  fi
  # One script, three leading positional parameters (name, dir, socket) and then the
  # command words. Nothing the caller typed becomes part of the shell string, which is
  # what lets an operator write `-- npm test --run` and get exactly what they typed.
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  out="$(stack_timeout "${MUTATE_TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
    sh -c '
      name="$1"; dir="$2"; sock="$3"; shift 3
      [ -n "$sock" ] || sock="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
      [ -n "$dir" ] || dir="$HOME"
      if [ ! -d "$dir" ]; then
        printf "no such directory: %s\n" "$dir" >&2
        exit 1
      fi
      if ! command -v tmux >/dev/null 2>&1; then
        printf "tmux is not installed in this workspace\n" >&2
        exit 1
      fi
      if [ -z "$name" ]; then
        folder=$(basename "$dir")
        hash=$(printf "%s" "$dir" | cksum 2>/dev/null | cut -d" " -f1 | cut -c1-6)
        [ -n "$hash" ] || hash=$(printf "%s" "$dir" | od -An -tx1 2>/dev/null | tr -d " \n" | cut -c1-6)
        [ -n "$hash" ] || hash=root
        name="grok-build-$folder-$hash"
      fi
      if tmux -S "$sock" has-session -t "=$name" 2>/dev/null; then
        printf "reused\t%s\n" "$name"
      elif [ "$#" -gt 0 ]; then
        tmux -S "$sock" new-session -d -s "$name" -c "$dir" -- "$@" || exit 1
        printf "created\t%s\n" "$name"
      elif command -v grok >/dev/null 2>&1; then
        # No command named: mirror the shipped profile, which runs the Grok CLI when
        # the image has it and a plain shell when an offline first boot has not.
        tmux -S "$sock" new-session -d -s "$name" -c "$dir" -- grok --cwd "$dir" || exit 1
        printf "created\t%s\n" "$name"
      else
        tmux -S "$sock" new-session -d -s "$name" -c "$dir" || exit 1
        printf "created\t%s\n" "$name"
      fi
    ' sh "${LAUNCH_NAME}" "${LAUNCH_DIR}" "${sock}" "$@" 2>&1)" || rc=$?
  if [ "${rc}" != "0" ]; then
    err "the session did not start: ${out}"
    note "check tmux reached the workspace with: check ${want:-${container}}"
    return 1
  fi
  action="${out%%$'\t'*}"
  name="${out##*$'\t'}"
  ok "${action} session ${name}"
  summary
  printf 'next: tail %s %s\n' "${want:-${container}}" "${name}"
}

# @function verb_stop
# Kill one session. Deliberately narrower than anything else here: it names one
# session on one socket and takes down no server, no container, and no workspace.
# Globals:
#   CONTAINER_OVERRIDE, DRY_RUN, DOCKER_BIN, MUTATE_TIMEOUT_SECS
# Arguments:
#   $1 - workspace name; $2 - session name
# Outputs:
#   What was stopped
# Returns:
#   0 on success; 1 when the workspace or session is unknown; 2 on a missing argument
verb_stop() {
  local want="${1:-}" sess="${2:-}" container="" socket stopped=0
  [ -n "${sess}" ] || {
    err "stop needs a session name (see 'show ${want}')"
    return 2
  }
  container="$(resolve_container "${want}")" || {
    err "no running workspace named '${want}'"
    return 1
  }
  section "stop ${sess} (${container})"
  if [ "${DRY_RUN}" = 1 ]; then
    printf 'dry run: %s exec %s sh -c '\''tmux -S <socket> kill-session -t =%s'\''\n' \
      "${DOCKER_BIN}" "${container}" "${sess}"
    ok "dry run: nothing stopped"
    summary
    return 0
  fi
  while IFS= read -r socket; do
    [ -n "${socket}" ] || continue
    # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
    if stack_timeout "${MUTATE_TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
      sh -c 'tmux -S "$1" has-session -t "=$2" 2>/dev/null &&
             tmux -S "$1" kill-session -t "=$2" 2>/dev/null' \
      sh "${socket}" "${sess}" </dev/null 2>/dev/null; then
      stopped=1
      break
    fi
  done < <(tmux_sockets "${container}")
  if [ "${stopped}" != "1" ]; then
    err "no session named '${sess}' in ${container}: nothing was stopped"
    return 1
  fi
  ok "stopped ${sess}"
  summary
}

# @function verb_check
# Answer "why did that return nothing" without launching anything. Each line is a
# blocker an operator would otherwise discover by guessing: the daemon is not this
# daemon, no workspace is running, the labels are absent, tmux never made it into the
# image, or the caller is inside a workspace and looking at the wrong daemon entirely.
# Globals:
#   DOCKER_BIN, TIMEOUT_SECS
# Arguments:
#   $1 - optional workspace name to inspect tmux inside
# Outputs:
#   The readiness report on stdout
# Returns:
#   0 when nothing failed; 1 when a check failed
verb_check() {
  local want="${1:-}" container="" rows="" sockets=""
  section "coder-sessions readiness"
  daemon_reachable || return 5

  phase "workspace containers"
  rows="$(workspace_rows)"
  if [ -z "${rows}" ]; then
    warn "no running container carries label coder.workspace_id"
    note "Coder creates those labels in templates/{workspace,devcontainer}/main.tf; a workspace that is stopped has no container"
  else
    ok "$(printf '%s\n' "${rows}" | awk 'END {print NR}') workspace container(s) running"
    printf '%s\n' "${rows}" | while IFS=$'\t' read -r name cname _s; do
      [ -n "${name}" ] || continue
      log "  ${name} -> ${cname}"
    done
  fi

  container="$(resolve_container "${want}")" || container=""
  if [ -n "${container}" ]; then
    phase "tmux inside ${container}"
    # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
    # Wrapped in sh: `command` is a shell builtin, so `docker exec <c> command -v tmux`
    # has no executable to execve and would report tmux missing from every container.
    if stack_timeout "${TIMEOUT_SECS}" ${DOCKER_BIN} exec "${container}" \
      sh -c 'command -v tmux >/dev/null 2>&1' sh </dev/null >/dev/null 2>&1; then
      ok "tmux is installed"
    else
      fail_item "tmux is missing from ${container}: the workspace startup script installs it, so a missing tmux means that script never completed"
    fi
    sockets="$(tmux_sockets "${container}")"
    if [ -n "${sockets}" ]; then
      ok "$(printf '%s\n' "${sockets}" | awk 'END {print NR}') tmux server(s): $(printf '%s ' ${sockets})"
    else
      warn "no tmux server in ${container}: no interactive terminal has been opened there"
    fi
  elif [ -n "${want}" ]; then
    fail_item "no running workspace named '${want}'"
  fi

  phase "how the assistant runs this"
  note "the Hermes image ships no bazelisk; from inside its container use:"
  note '  bash "${STACK_HOST_PATH:-/opt/stack}/scripts/coder-sessions.sh" list'
  summary
  [ "${SUMMARY_FAIL:-0}" = 0 ]
}

# @function parse_args
# Split argv into the option set, the verb, and the verb's own words. Options are read
# only before the subcommand, which is what lets every word after it reach the verb
# verbatim - `launch ws -- npm test --run` must not have its own flags eaten here.
# Globals:
#   JSON_MODE_WANTED, CONTAINER_OVERRIDE, TIMEOUT_SECS, DRY_RUN, VERB, ARGS,
#   LAUNCH_NAME, LAUNCH_DIR, NO_ENTER
# Arguments:
#   $@ - the command line
# Outputs:
#   Nothing; sets the globals above
# Returns:
#   0; 2 on an unknown option or an unusable subcommand
parse_args() {
  local -a pre=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) JSON_MODE_WANTED=1 ;;
      --container)
        [ "$#" -ge 2 ] || {
          err "--container needs a name"
          return 2
        }
        CONTAINER_OVERRIDE="$2"
        shift
        ;;
      --timeout)
        [ "$#" -ge 2 ] || {
          err "--timeout needs a number"
          return 2
        }
        [[ $2 =~ ^[0-9]+$ ]] || {
          err "--timeout wants seconds, got '$2'"
          return 2
        }
        TIMEOUT_SECS="$2"
        PROBE_TIMEOUT="$2"
        shift
        ;;
      --name)
        [ "$#" -ge 2 ] || {
          err "--name needs a session name"
          return 2
        }
        LAUNCH_NAME="$2"
        shift
        ;;
      --dir)
        [ "$#" -ge 2 ] || {
          err "--dir needs a directory"
          return 2
        }
        LAUNCH_DIR="$2"
        shift
        ;;
      --no-enter) NO_ENTER=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      --) break ;;
      -*)
        err "unknown option '$1'"
        usage >&2
        return 2
        ;;
      *) break ;;
    esac
    shift
  done

  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    pre+=("$1")
    shift
  done
  [ "${#pre[@]}" -gt 0 ] || {
    VERB="list"
    return 0
  }
  VERB="${pre[0]}"
  case "${VERB}" in
    list | show | tail | send | launch | stop | check) ;;
    *)
      err "unknown subcommand '${VERB}' (see --help)"
      usage >&2
      return 2
      ;;
  esac
  local i=1
  while [ "${i}" -lt "${#pre[@]}" ]; do
    ARGS+=("${pre[${i}]}")
    i=$((i + 1))
  done
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    shift
    while [ "$#" -gt 0 ]; do
      ARGS+=("$1")
      shift
    done
  fi
  return 0
}

# @function main
# Dispatch one verb.
# Globals:
#   VERB, ARGS, JSON_MODE_WANTED
# Arguments:
#   $@ - the command line
# Outputs:
#   Whatever the verb prints
# Returns:
#   The verb's status; 2 when argv was unusable
main() {
  parse_args "$@" || return $?
  # A machine-readable verb must keep stdout to JSON alone, which is what common.sh's
  # report helpers do when JSON_MODE is set.
  if [ "${JSON_MODE_WANTED}" = 1 ]; then
    JSON_MODE=1
  else
    unset JSON_MODE
  fi
  case "${VERB}" in
    list) verb_list ;;
    show) verb_show "${ARGS[0]:-}" ;;
    tail) verb_tail "${ARGS[0]:-}" "${ARGS[1]:-}" "${ARGS[2]:-24}" ;;
    send) verb_send "${ARGS[0]:-}" "${ARGS[1]:-}" "${ARGS[2]:-}" ;;
    stop) verb_stop "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
    check) verb_check "${ARGS[0]:-}" ;;
    launch) verb_launch "${ARGS[@]+"${ARGS[@]}"}" ;;
  esac
  # Read back rather than trust the wanted-flag: --json is only machine-readable for
  # the two verbs that emit a document, and saying so belongs after the verb ran.
  if [ -n "${JSON_MODE:-}" ] && [ "${VERB}" != "list" ] && [ "${VERB}" != "show" ]; then
    warn "--json is machine-readable for list and show only; ${VERB} printed its report"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
