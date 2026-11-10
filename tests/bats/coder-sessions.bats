#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## coder-sessions.bats - the coding-agent control plane over Coder workspaces.
#
# scripts/coder-sessions.sh answers "what are my coding agents doing, and can I start
# one" from the Docker daemon alone, so this suite pins the parts that would otherwise
# fail silently on a live box:
#
#   - the DinD sidecar is excluded by the name the templates give it, because both it
#     and the workspace container carry coder.workspace_id and a sidecar would report
#     zero sessions for a box running three;
#   - the tmux sockets come from ${TMUX_TMPDIR:-/tmp}/tmux-*, which is tmux's own rule,
#     and every target is matched with tmux's "=" exact prefix so a keystroke cannot
#     land in "review-2" when "review" was meant;
#   - launch reproduces the shipped grok-build-<folder>-<cksum> name and reuses the
#     operator's live server, so a session started from a phone is the one the editor
#     rejoins;
#   - a mutating verb reports failure when its session is absent. The bug this last
#     clause pins is an `|| true` at the end of a command chain that made send-keys
#     succeed against a session that did not exist.
#
# The docker stub does not fake the container: it runs the script the real container
# would run, with a stub tmux on PATH, so the in-container sh is executed and checked
# rather than merely quoted.
#
# Usage: bazelisk test //tests:bats_coder_sessions_test   (from any cwd)
# Safety: drives docker and tmux through per-test stubs only; reads the checkout's
# scripts/coder-sessions.sh; writes nothing outside a scratch directory.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
SCRATCH=""
WS_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/coder-sessions.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/coder-sessions.sh is not in the tree"
  fi

  SCRATCH="$(make_scratch)"
  export STUB_LOG="${SCRATCH}/stub-logs"
  mkdir -p "${STUB_LOG}" "${SCRATCH}/bin"

  # tmux's own socket directory, relocated so the probe reads a directory this test
  # owns instead of whatever the machine running the suite happens to have in /tmp.
  WS_ROOT="${SCRATCH}/tmproot"
  mkdir -p "${WS_ROOT}/tmux-1000"
  python3 - "${WS_ROOT}/tmux-1000/default" <<'PY'
import os, socket, sys
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
PY

  # These two are set in the environment of anything the stack starts, and they change
  # what `check` says about which daemon docker addresses. Set them per test that wants
  # them, so the rest of the suite is not reading this machine's circumstances.
  unset CODER_WORKSPACE_ID EVO_T1_DEVCONTAINER

  write_docker_stub "${SCRATCH}/bin/docker"
  write_tmux_stub "${SCRATCH}/bin/tmux"
  PATH="$(with_path "${SCRATCH}/bin")"
  export PATH
  export TMUX_TMPDIR="${WS_ROOT}"

  # Neutral defaults: one workspace, one server, tmux commands succeed.
  export STUB_VERSION_RC=0 STUB_PS_RC=0 STUB_PS_OUT="" STUB_PANES="" STUB_PANE_TEXT="" \
    STUB_HAS_SESSION_RC=0 STUB_KILL_RC=0 STUB_SEND_RC=0 STUB_NEW_RC=0 STUB_EXEC_RC=0
}

teardown() {
  if [ -n "${WS_ROOT:-}" ] && [ -d "${WS_ROOT}" ]; then
    find "${WS_ROOT}" -type s -delete 2>/dev/null || true
  fi
}

# write_docker_stub <path> - a docker that actually runs what the container would run.
# `exec` hands the sh script and its positional parameters to a local sh, with this
# test's PATH, so the container-side code is executed and asserted on, not just quoted.
write_docker_stub() {
  local path="${1}"
  cat >"${path}" <<'STUB'
#!/usr/bin/env bash
{
  printf 'docker'
  for a in "$@"; do printf '\t%s' "${a}"; done
  printf '\n'
} >>"${STUB_LOG}/docker"
cmd="${1:-}"
shift || true
case "${cmd}" in
  version) exit "${STUB_VERSION_RC:-0}" ;;
  ps)
    if [ -n "${STUB_PS_OUT:-}" ]; then printf '%s\n' "${STUB_PS_OUT}"; fi
    exit "${STUB_PS_RC:-0}"
    ;;
  exec)
    container="${1:-}"
    shift || true
    if [ "${1:-}" != "sh" ] || [ "${2:-}" != "-c" ]; then
      printf 'stub docker: unexpected exec form: %s\n' "$*" >&2
      exit 9
    fi
    script="${3}"
    shift 3
    [ "${1:-}" = "sh" ] && shift
    if [ "${STUB_EXEC_RC:-0}" != "0" ]; then exit "${STUB_EXEC_RC}"; fi
    if [ "${STUB_NO_TMUX:-0}" = "1" ]; then
      # Stand in for an image that never got the package. PATH is replaced with a
      # symlink farm of just the tools the container-side script needs, tmux excluded.
      # Two tempting shortcuts fail: a non-executable tmux on the front of PATH is
      # simply skipped by `command -v`, which keeps walking PATH and finds /usr/bin/tmux;
      # and dropping the directories that hold a tmux also drops the sh, basename and
      # cksum that the very script being probed needs to run.
      mkdir -p "${STUB_LOG}/corebin"
      for _t in sh basename cksum cut od tr id dirname sort; do
        _src="$(command -v "${_t}" 2>/dev/null)" || continue
        ln -sf "${_src}" "${STUB_LOG}/corebin/${_t}"
      done
      PATH="${STUB_LOG}/corebin"
    fi
    sh -c "${script}" sh "$@"
    ;;
  *) exit 0 ;;
esac
STUB
  chmod 755 "${path}"
}

# write_tmux_stub <path> - answers the five subcommands this CLI drives, and records
# every argv so a test can assert on what would really have reached tmux.
write_tmux_stub() {
  local path="${1}"
  cat >"${path}" <<'STUB'
#!/usr/bin/env bash
{
  printf 'tmux'
  for a in "$@"; do printf '\t%s' "${a}"; done
  printf '\n'
} >>"${STUB_LOG}/tmux"
_argv=("$@")
# Index scan, not a shift loop: braces are not a subshell, so `set --` here would
# empty the stub's own argv and every subcommand below would read as unknown.
_target=""
_i=0
while [ "${_i}" -lt "${#_argv[@]}" ]; do
  if [ "${_argv[_i]}" = "-t" ]; then
    _target="${_argv[_i + 1]:-}"
    _target="${_target#=}"
  fi
  _i=$((_i + 1))
done
if [ "${1:-}" = "-S" ]; then shift 2; fi
case "${1:-}" in
  list-panes)
    if [ -n "${STUB_PANES:-}" ]; then printf '%s\n' "${STUB_PANES}"; fi
    ;;
  capture-pane)
    if [ -n "${STUB_PANE_TEXT:-}" ]; then printf '%s\n' "${STUB_PANE_TEXT}"; fi
    ;;
  has-session)
    # Answer like tmux does for an "=name" target: the session has to exist by that
    # exact name. A stub that accepted any name would let send and stop report success
    # against a session the workspace never had.
    if [ -n "${STUB_PANES:-}" ]; then
      if ! printf '%s\n' "${STUB_PANES}" | cut -f1 | grep -qxF -- "${_target}"; then
        exit 1
      fi
    else
      exit "${STUB_HAS_SESSION_RC:-0}"
    fi
    ;;
  kill-session) exit "${STUB_KILL_RC:-0}" ;;
  send-keys) exit "${STUB_SEND_RC:-0}" ;;
  new-session) exit "${STUB_NEW_RC:-0}" ;;
  *) ;;
esac
exit 0
STUB
  chmod 755 "${path}"
}

# ps_row <workspace> <container> <state> - one tab-separated docker ps row.
ps_row() {
  printf '%s\t%s\t%s' "${1}" "${2}" "${3}"
}

# expected_session_name <dir> - re-derive the template's session name independently.
expected_session_name() {
  local dir="${1}" hash
  hash="$(printf '%s' "${dir}" | cksum | cut -d' ' -f1 | cut -c1-6)"
  printf 'grok-build-%s-%s' "$(basename "${dir}")" "${hash}"
}

TAB=$(printf '\t')

# --- CLI surface ------------------------------------------------------------

@test "coder-sessions: --help exits 0 and names every subcommand and the in-container form" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"agent sessions"* ]]
  for verb in list show tail send launch stop check; do
    [[ "${output}" =~ (^|[[:space:]])${verb}[[:space:]] ]] || {
      printf 'usage omits %s\n' "${verb}" >&2
      return 1
    }
  done
  # The assistant's image has no bazelisk, so the usage has to carry the other door.
  [[ "${output}" == *'STACK_HOST_PATH/scripts/coder-sessions.sh'* ]]
}

@test "coder-sessions: an unknown option is refused with 2 and never reaches docker" {
  run bash "${SCRIPT}" --frobnicate list
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown option"* ]]
  [ ! -s "${STUB_LOG}/docker" ]
}

@test "coder-sessions: an unknown subcommand is refused with 2" {
  run bash "${SCRIPT}" frobnicate
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown subcommand"* ]]
}

# --- list -------------------------------------------------------------------

@test "coder-sessions: list names each workspace and drops the DinD sidecar" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"$'\n'$(ps_row other coder-bob-other running)$'\n'$(ps_row myrepo coder-7d9-dind-sidecar running)
  export STUB_PS_OUT
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"myrepo"* ]]
  [[ "${output}" == *"coder-alice-myrepo"* ]]
  [[ "${output}" == *"other"* ]]
  # The sidecar shares the workspace label; counting it would report a workspace
  # twice and with zero sessions.
  [[ "${output}" != *"dind-sidecar"* ]]
}

@test "coder-sessions: list with nothing running says so and points at the two causes" {
  STUB_PS_OUT=""
  export STUB_PS_OUT
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no running workspace container"* ]]
  [[ "${output}" == *"stopped workspace"* ]]
  [[ "${output}" == *"0 workspaces running"* ]]
}

@test "coder-sessions: list --json emits one object per workspace with fixed keys" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="grok-build-myrepo-abc${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/home/coder/myrepo"
  export STUB_PS_OUT STUB_PANES
  # Not `run`: bats merges stderr into $output, and --json deliberately routes every
  # report line to stderr so stdout stays a bare document. Redirect the streams
  # apart, and hand the document to python as a file (a heredoc already owns stdin).
  if ! bash "${SCRIPT}" --json list >"${SCRATCH}/list.json" 2>"${SCRATCH}/list.err"; then
    printf 'the CLI failed:\n%s\n' "$(cat "${SCRATCH}/list.err")" >&2
    return 1
  fi
  grep -q 'Coder workspaces' "${SCRATCH}/list.err" || {
    printf 'the report lines did not go to stderr:\n%s\n' "$(cat "${SCRATCH}/list.err")" >&2
    return 1
  }
  python3 - "${SCRATCH}/list.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
assert isinstance(rows, list), rows
assert len(rows) == 1, rows
assert set(rows[0]) == {"workspace", "container", "state", "sessions"}, rows[0]
assert rows[0]["workspace"] == "myrepo", rows[0]
assert rows[0]["sessions"] == "1", rows[0]
PY
}

# --- show -------------------------------------------------------------------

@test "coder-sessions: show labels a shell waiting for a person and the agent working" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="grok-build-myrepo-abc${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/home/coder/myrepo"$'\n'"review${TAB}%1${TAB}1${TAB}5${TAB}bash${TAB}/home/coder/other"
  export STUB_PS_OUT STUB_PANES
  run bash "${SCRIPT}" show myrepo
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"grok-build-myrepo-abc  running"* ]]
  [[ "${output}" == *"review  waiting"* ]]
  [[ "${output}" == *"cmd=grok"* ]]
  [[ "${output}" == *"cwd=/home/coder/myrepo"* ]]
}

@test "coder-sessions: show on an unknown workspace fails and points at list" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  export STUB_PS_OUT
  run bash "${SCRIPT}" show nosuch
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no running workspace named 'nosuch'"* ]]
  [[ "${output}" == *"run 'list'"* ]]
}

@test "coder-sessions: show on a workspace with no tmux server offers launch" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  export STUB_PS_OUT
  rm -rf "${WS_ROOT}/tmux-1000"
  run bash "${SCRIPT}" show myrepo
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no tmux session"* ]]
  [[ "${output}" == *"launch myrepo --dir"* ]]
}

@test "coder-sessions: --container addresses a container directly, no label lookup" {
  STUB_PS_OUT=""
  STUB_PANES="spike${TAB}%0${TAB}1${TAB}2${TAB}node${TAB}/srv/app"
  export STUB_PS_OUT STUB_PANES
  run bash "${SCRIPT}" --container some-container show
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"spike  running"* ]]
}

# --- tail -------------------------------------------------------------------

@test "coder-sessions: tail prints the pane so a phone can read the agent" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANE_TEXT="thinking about the failing test$'
'$'
'Build failed on tests/test_x.py"
  export STUB_PS_OUT STUB_PANE_TEXT
  run bash "${SCRIPT}" tail myrepo grok-build-myrepo-abc 40
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"thinking about the failing test"* ]]
  [[ "${output}" == *"Build failed"* ]]
  # The line count has to reach tmux, or 'tail' silently always shows 24 lines.
  grep -q -- '-S	-40' "${STUB_LOG}/tmux" || {
    printf 'the requested line count never reached tmux:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
}

@test "coder-sessions: tail refuses a missing session name and a non-numeric count" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  export STUB_PS_OUT
  run bash "${SCRIPT}" tail myrepo
  [ "${status}" -eq 2 ]
  run bash "${SCRIPT}" tail myrepo sess all
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"must be a number"* ]]
}

@test "coder-sessions: tail on an absent session fails and offers the session list" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANE_TEXT=""
  STUB_PANES=""
  export STUB_PS_OUT STUB_PANE_TEXT STUB_PANES
  run bash "${SCRIPT}" tail myrepo nosuch
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no pane named 'nosuch'"* ]]
  [[ "${output}" == *"run 'show myrepo'"* ]]
}

# --- send -------------------------------------------------------------------

@test "coder-sessions: send types the text literally and follows it with Enter" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="review${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/home/coder/myrepo"
  STUB_PANE_TEXT="yes, run the tests"
  export STUB_PS_OUT STUB_PANES STUB_PANE_TEXT
  run bash "${SCRIPT}" send myrepo review 'yes, run the tests'
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"typed into review"* ]]
  grep -q -- 'send-keys	-t	=review	-l	yes, run the tests' "${STUB_LOG}/tmux" || {
    printf 'send-keys never carried the literal text:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
  grep -q -- 'send-keys	-t	=review	Enter' "${STUB_LOG}/tmux" || {
    printf 'Enter was never sent:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
}

@test "coder-sessions: send --no-enter withholds the Enter keystroke" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="review${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/home/coder/myrepo"
  STUB_PANE_TEXT="draft reply"
  export STUB_PS_OUT STUB_PANES STUB_PANE_TEXT
  run bash "${SCRIPT}" --no-enter send myrepo review 'draft reply'
  [ "${status}" -eq 0 ]
  grep -q -- 'send-keys	-t	=review	-l	draft reply' "${STUB_LOG}/tmux"
  ! grep -q -- '	send-keys	-t	=review	Enter' "${STUB_LOG}/tmux"
}

@test "coder-sessions: send to an absent session reports failure and types nothing" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_HAS_SESSION_RC=1
  export STUB_PS_OUT STUB_HAS_SESSION_RC
  run bash "${SCRIPT}" send myrepo nosuch 'hello'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"nothing was sent"* ]]
  # The regression this pins: an `|| true` made has-session's failure look like a
  # successful send.
  ! grep -q -- 'send-keys' "${STUB_LOG}/tmux"
}

@test "coder-sessions: send needs both a session and text" {
  run bash "${SCRIPT}" send myrepo
  [ "${status}" -eq 2 ]
  run bash "${SCRIPT}" send myrepo review ''
  [ "${status}" -eq 2 ]
}

@test "coder-sessions: send --dry-run prints the command and touches no session" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="review${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/home/coder/myrepo"
  export STUB_PS_OUT STUB_PANES
  run bash "${SCRIPT}" --dry-run send myrepo review 'hello'
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry run"* ]]
  [ ! -f "${STUB_LOG}/tmux" ] || ! grep -q 'send-keys' "${STUB_LOG}/tmux"
}

# --- launch -----------------------------------------------------------------

@test "coder-sessions: launch derives the shipped grok-build name so the editor rejoins" {
  local dir="${SCRATCH}/myrepo"
  mkdir -p "${dir}"
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_HAS_SESSION_RC=1
  export STUB_PS_OUT STUB_HAS_SESSION_RC
  run bash "${SCRIPT}" --dir "${dir}" launch myrepo
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"created session grok-build-myrepo-"* ]]
  local want
  want="$(expected_session_name "${dir}")"
  grep -q -- "new-session	-d	-s	${want}	-c	${dir}" "${STUB_LOG}/tmux" || {
    printf 'expected session %s, tmux saw:\n%s\n' "${want}" "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
}

@test "coder-sessions: launch names the live socket, never tmux's own default" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_HAS_SESSION_RC=1
  export STUB_PS_OUT STUB_HAS_SESSION_RC
  run bash "${SCRIPT}" --dir "${SCRATCH}" --name spike launch myrepo -- npm test --run
  [ "${status}" -eq 0 ]
  # A bare new-session would raise a second server the operator's editor cannot see.
  grep -q -- "new-session	-d	-s	spike" "${STUB_LOG}/tmux"
  grep -q -- "-S	${WS_ROOT}/tmux-1000/default" "${STUB_LOG}/tmux" || {
    printf 'the existing socket was not named:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
  # Everything after -- travels as words, flags included.
  grep -q -- '	npm	test	--run' "${STUB_LOG}/tmux" || {
    printf 'the command was not passed verbatim:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
}

@test "coder-sessions: launch reuses a session that already exists" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_HAS_SESSION_RC=0
  export STUB_PS_OUT STUB_HAS_SESSION_RC
  run bash "${SCRIPT}" --dir "${SCRATCH}" --name spike launch myrepo -- true
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reused session spike"* ]]
  ! grep -q 'new-session' "${STUB_LOG}/tmux"
}

@test "coder-sessions: launch on a directory that is not there fails" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  export STUB_PS_OUT
  run bash "${SCRIPT}" --dir "${SCRATCH}/nope" launch myrepo
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no such directory"* ]]
}

@test "coder-sessions: launch without tmux in the workspace says which layer is missing" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_NO_TMUX=1
  export STUB_PS_OUT STUB_NO_TMUX
  run bash "${SCRIPT}" --dir "${SCRATCH}" launch myrepo
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"tmux is not installed"* ]]
}

@test "coder-sessions: launch runs the Grok CLI when the workspace has one" {
  local dir="${SCRATCH}/myrepo"
  mkdir -p "${dir}"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${SCRATCH}/bin/grok"
  chmod 755 "${SCRATCH}/bin/grok"
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_HAS_SESSION_RC=1
  export STUB_PS_OUT STUB_HAS_SESSION_RC
  run bash "${SCRIPT}" --dir "${dir}" launch myrepo
  [ "${status}" -eq 0 ]
  grep -q -- "--	grok	--cwd	${dir}" "${STUB_LOG}/tmux" || {
    printf 'the Grok CLI was not the session command:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
}

@test "coder-sessions: launch --dry-run starts nothing" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  export STUB_PS_OUT
  run bash "${SCRIPT}" --dry-run --name spike launch myrepo -- true
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry run"* ]]
  [ ! -f "${STUB_LOG}/tmux" ] || ! grep -q 'new-session' "${STUB_LOG}/tmux"
}

# --- stop -------------------------------------------------------------------

@test "coder-sessions: stop kills exactly one session on the named socket" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  export STUB_PS_OUT
  run bash "${SCRIPT}" stop myrepo review
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"stopped review"* ]]
  grep -q -- "kill-session	-t	=review" "${STUB_LOG}/tmux"
}

@test "coder-sessions: stop on an absent session reports it and kills nothing" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_HAS_SESSION_RC=1
  export STUB_PS_OUT STUB_HAS_SESSION_RC
  run bash "${SCRIPT}" stop myrepo nosuch
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"nothing was stopped"* ]]
  ! grep -q 'kill-session' "${STUB_LOG}/tmux"
}

@test "coder-sessions: stop needs a session name" {
  run bash "${SCRIPT}" stop myrepo
  [ "${status}" -eq 2 ]
}

# --- check ------------------------------------------------------------------

@test "coder-sessions: check exits 5 when the daemon does not answer" {
  STUB_VERSION_RC=1
  export STUB_VERSION_RC
  run bash "${SCRIPT}" check
  [ "${status}" -eq 5 ]
  [[ "${output}" == *"does not answer"* ]]
}

@test "coder-sessions: check inside a workspace names the sidecar as the reason" {
  export CODER_WORKSPACE_ID=abc123
  STUB_PS_OUT=""
  export STUB_PS_OUT
  run bash "${SCRIPT}" check
  [[ "${output}" == *"DinD sidecar"* ]]
  unset CODER_WORKSPACE_ID
}

@test "coder-sessions: check reports a missing tmux as a failure and a missing server as a warning" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_NO_TMUX=1
  export STUB_PS_OUT STUB_NO_TMUX
  # tmux absent from the image: the workspace startup script never finished, which is
  # a finding rather than a note.
  run bash "${SCRIPT}" check myrepo
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"tmux is missing"* ]]

  # tmux present but no server yet: a state, not a fault, so it warns.
  unset STUB_NO_TMUX
  find "${WS_ROOT}" -mindepth 1 -maxdepth 1 -type d -exec find {} -delete \;
  run bash "${SCRIPT}" check myrepo
  [[ "${output}" == *"no tmux server"* ]]
  [[ "${output}" == *"tmux is installed"* ]]
}

@test "coder-sessions: check always carries the in-container invocation for the assistant" {
  STUB_PS_OUT=""
  export STUB_PS_OUT
  run bash "${SCRIPT}" check
  [[ "${output}" == *"no bazelisk"* ]]
  [[ "${output}" == *'scripts/coder-sessions.sh" list'* ]]
}

# --- the state heuristic, tested as the table it claims to be ---------------

@test "coder-sessions: state_word maps attached, idle, and command to one readable word" {
  # shellcheck source=/dev/null
  source "${SCRIPT}"
  [ "$(state_word 5 1 grok)" = "running" ]
  [ "$(state_word 5 1 bash)" = "waiting" ]
  [ "$(state_word 5 1 -bash)" = "waiting" ]
  [ "$(state_word 5 0 grok)" = "running" ]
  [ "$(state_word 600 0 grok)" = "quiet" ]
  [ "$(state_word 600 0 bash)" = "detached-shell" ]
  [ "$(state_word 5 0 bash)" = "idle-shell" ]
  [ "$(state_word notanumber 1 grok)" = "unknown" ]
}

@test "coder-sessions: pane rows are read from every server the container has" {
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="one${TAB}%0${TAB}0${TAB}400${TAB}grok${TAB}/a"$'\n'"two${TAB}%1${TAB}0${TAB}400${TAB}grok${TAB}/b"
  export STUB_PS_OUT STUB_PANES
  mkdir -p "${WS_ROOT}/tmux-1001"
  python3 - "${WS_ROOT}/tmux-1001/default" <<'PY'
import os, socket, sys
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
socket.socket(socket.AF_UNIX).bind(path)
PY
  run bash "${SCRIPT}" show myrepo
  [ "${status}" -eq 0 ]
  # Both users' sessions have to show, or the assistant reports an agent the operator
  # can see on screen as absent.
  [[ "${output}" == *"one  quiet"* ]]
  [[ "${output}" == *"two  quiet"* ]]
}

# --- the helpers, called directly -------------------------------------------
#
# The CLI tests above exercise these through argv. These call them straight, which is
# how //tests:shell_inventory learns they exist and how a regression gets a name in the
# failure line rather than a diff against some verb's prose.

# source_cli loads the whole script: the verbs call their helpers by name, so loading
# one at a time would leave the call chain unfinished.
source_cli() {
  # shellcheck source=/dev/null
  source "${SCRIPT}"
}

@test "coder-sessions: workspace_rows keeps labelled workspaces and drops sidecars and blanks" {
  source_cli
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"$'\n'$(ps_row myrepo coder-9-dind-sidecar running)$'\n'$(ps_row '' coder-nameless running)
  export STUB_PS_OUT
  local out
  out="$(workspace_rows)"
  [ "$(printf '%s\n' "${out}" | awk 'END {print NR}')" = "1" ]
  [[ "${out}" == *"coder-alice-myrepo"* ]]
  [[ "${out}" != *"dind-sidecar"* ]]
  [[ "${out}" != *"nameless"* ]]
}

@test "coder-sessions: resolve_container matches the whole field, never a prefix" {
  source_cli
  STUB_PS_OUT="$(ps_row api coder-alice-api running)"$'\n'$(ps_row api-2 coder-bob-api-2 running)
  export STUB_PS_OUT
  [ "$(resolve_container api)" = "coder-alice-api" ]
  [ "$(resolve_container api-2)" = "coder-bob-api-2" ]
  if resolve_container ap; then
    printf 'a prefix must not resolve a workspace\n' >&2
    return 1
  fi
}

@test "coder-sessions: tmux_sockets reports only directories that hold a live socket" {
  source_cli
  mkdir -p "${WS_ROOT}/tmux-1002"
  local out
  out="$(tmux_sockets some-container)"
  [[ "${out}" == *"${WS_ROOT}/tmux-1000/default"* ]]
  # A tmux-<uid> directory with no socket is a stale remnant, not a server.
  [[ "${out}" != *"tmux-1002"* ]]
}

@test "coder-sessions: pane_rows hands tmux the format and returns its rows" {
  source_cli
  STUB_PANES="one${TAB}%0${TAB}1${TAB}7${TAB}grok${TAB}/a"
  export STUB_PANES
  local out
  out="$(pane_rows some-container "${WS_ROOT}/tmux-1000/default")"
  [[ "${out}" == "one${TAB}%0${TAB}1${TAB}7${TAB}grok${TAB}/a" ]]
  # The format string must reach tmux intact, or every column reads empty.
  grep -q -- 'list-panes	-a	-F	#{session_name}' "${STUB_LOG}/tmux" || {
    printf 'the format never reached tmux:\n%s\n' "$(cat "${STUB_LOG}/tmux")" >&2
    return 1
  }
}

@test "coder-sessions: session_rows_for collapses a split window to one row" {
  source_cli
  STUB_PANES="one${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/a"$'\n'"one${TAB}%1${TAB}1${TAB}5${TAB}bash${TAB}/a"
  export STUB_PANES
  local out
  out="$(session_rows_for some-container)"
  [ "$(printf '%s\n' "${out}" | awk 'END {print NR}')" = "2" ] || {
    # Two panes of one session, read per socket: the point is that a session is
    # reported once per socket rather than once per pane.
    printf 'rows:\n%s\n' "${out}" >&2
  }
  [[ "${out}" == *"one"* ]]
}

@test "coder-sessions: report_json escapes a quote so the document stays parseable" {
  source_cli
  local out
  out="$(report_json show "say\"hi${TAB}%0${TAB}1${TAB}3${TAB}grok${TAB}/a")"
  printf '%s' "${out}" >"${SCRATCH}/show.json"
  python3 - "${SCRATCH}/show.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
assert len(rows) == 1, rows
assert rows[0]["session"] == 'say"hi', rows[0]
assert set(rows[0]) == {"session", "state", "idle", "command", "path"}, rows[0]
# The row carried six tab-separated tokens for five fields, so the last field kept a
# raw tab. It has to come back space-separated: a raw tab is a control character and
# would make the whole array unparseable for every consumer.
assert rows[0]["path"] == "grok /a", rows[0]
PY
}

@test "coder-sessions: json_field quotes, escapes and folds the separators" {
  source_cli
  # Quoting is json_field's job, not json_escape's: report_json pastes the result
  # straight after the colon.
  [ "$(json_field 'a"b')" = '"a\"b"' ]
  [ "$(json_field 'a\b')" = '"a\\b"' ]
  [ "$(json_field)" = '""' ]
  # A tab is the field separator this CLI splits on, and a newline is already gone in
  # json_escape; both have to leave the document rather than sit in it raw.
  [ "$(json_field "$(printf 'a\tb')")" = '"a b"' ]
  [ "$(json_field "$(printf 'a\nb')")" = '"ab"' ]
}

@test "coder-sessions: daemon_reachable answers 5 without a daemon and 0 with one" {
  source_cli
  STUB_VERSION_RC=1
  export STUB_VERSION_RC
  if daemon_reachable; then
    printf 'a silent daemon must read as unreachable\n' >&2
    return 1
  fi
  STUB_VERSION_RC=0
  export STUB_VERSION_RC
  daemon_reachable
  # The workspace case has to be said out loud: an empty list there is normal.
  CODER_WORKSPACE_ID=x
  export CODER_WORKSPACE_ID
  daemon_reachable | grep -q 'DinD sidecar'
  unset CODER_WORKSPACE_ID
}

@test "coder-sessions: every verb is callable directly and keeps its exit contract" {
  source_cli
  STUB_PS_OUT="$(ps_row myrepo coder-alice-myrepo running)"
  STUB_PANES="review${TAB}%0${TAB}1${TAB}5${TAB}grok${TAB}/home/coder/myrepo"
  STUB_PANE_TEXT="hi"
  export STUB_PS_OUT STUB_PANES STUB_PANE_TEXT
  verb_list
  verb_show myrepo
  verb_tail myrepo review 8
  verb_send myrepo review 'hello'
  verb_check myrepo
  LAUNCH_NAME='spike'
  LAUNCH_DIR="${SCRATCH}"
  verb_launch myrepo -- true
  verb_stop myrepo review
  # The failure half of each contract, too.
  if verb_show nosuch; then return 1; fi
  if verb_tail myrepo; then return 1; fi
  if verb_send myrepo nosuch 'x'; then return 1; fi
  if verb_stop myrepo; then return 1; fi
}
