#!/usr/bin/env bats
#
# ## session-archive.bats - the host-side reader of grok-session-archive.
#
# scripts/session-archive.sh is the only sanctioned reader of the archive volume the
# workspace boot mirrors ~/.grok/sessions onto. Two things are worth pinning here
# rather than trusting the read-through: the volume has to be mounted read-only on
# every verb (a reader that could write the archive stops being an out-of-band copy),
# and a workspace leaf name has to be refused before it reaches the container's shell.
#
# The docker stub does not merely echo: for a `run` whose container command is
# `sh -c <body>` it rewrites the /archive positional to a fixture directory and runs
# that body for real, so the in-container scripts are executed and asserted on, not
# just quoted. A `run` carrying `tar` streams a real tar of the fixture instead.
#
# Usage: bazelisk test //tests:bats_session_archive_test   (from any cwd)
# Safety: writes only under make_scratch; touches no daemon and no real volume.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
SCRATCH=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/session-archive.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/session-archive.sh is not in the tree"
  fi

  SCRATCH="$(make_scratch)"
  export STUB_LOG="${SCRATCH}/stub-logs"
  mkdir -p "${STUB_LOG}" "${SCRATCH}/bin"

  # The fake volume content. The CLI addresses it through EVO_ARCHIVE_ROOT, which the
  # stub substitutes for the container-side /archive positional.
  export STUB_ARCHIVE_ROOT="${SCRATCH}/volume"
  mkdir -p "${STUB_ARCHIVE_ROOT}/workspaces/ws-alice/sessions/2026"
  printf 'session one\n' >"${STUB_ARCHIVE_ROOT}/workspaces/ws-alice/sessions/2026/a.jsonl"
  printf 'session two\n' >"${STUB_ARCHIVE_ROOT}/workspaces/ws-alice/sessions/2026/b.jsonl"
  mkdir -p "${STUB_ARCHIVE_ROOT}/workspaces/ws-bob"
  printf 'bob\n' >"${STUB_ARCHIVE_ROOT}/workspaces/ws-bob/c.jsonl"

  # A daemon that answers, a volume that exists, an image that is local: the shape a
  # healthy stack host has. Each test lowers one knob to reach the failure it wants.
  export STUB_INFO_RC=0 STUB_VOLUME_EXISTS=1 STUB_IMAGE_RC=0 STUB_RUN_RC=0

  write_docker_stub "${SCRATCH}/bin/docker"
  PATH="$(with_path "${SCRATCH}/bin")"
  export PATH
}

teardown() {
  return 0
}

# write_docker_stub <path> - a docker that runs the container body locally against the
# fixture tree, logging every invocation so a test can assert the daemon was or was not
# reached and how the volume was mounted.
write_docker_stub() {
  local path="${1}"
  cat >"${path}" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${STUB_LOG}/docker"

case "${1:-}" in
  info) exit "${STUB_INFO_RC:-0}" ;;
esac

# Each docker verb arrives as separate argv words, so the probe is matched on the joined
# line rather than on any single argument.
joined="$*"
case "${joined}" in
  *"volume ls"*)
    if [ "${STUB_VOLUME_EXISTS:-1}" = "1" ]; then
      printf '%s\n' "grok-session-archive"
    fi
    exit 0
    ;;
  *"image inspect"*)
    exit "${STUB_IMAGE_RC:-0}"
    ;;
esac

# Everything below is a `docker run`. Locate the container command, which is the first
# argv word that is neither a flag nor a flag value.
args=("$@")
container_cmd=""
script=""
tail_args=()
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "tar" ]; then
    container_cmd="tar"
    break
  fi
  if [ "${args[$i]}" = "sh" ] && [ "${args[$((i + 1))]:-}" = "-c" ]; then
    container_cmd="sh"
    script="${args[$((i + 2))]}"
    tail_args=("${args[@]:$((i + 3))}")
    break
  fi
done

extra=()
if [ "${#tail_args[@]}" -gt 2 ]; then
  extra=("${tail_args[@]:2}")
fi

case "${container_cmd}" in
  tar)
    [ "${STUB_RUN_RC:-0}" -eq 0 ] || exit "${STUB_RUN_RC}"
    exec tar -cf - -C "${STUB_ARCHIVE_ROOT}/workspaces" .
    ;;
  sh)
    [ "${STUB_RUN_RC:-0}" -eq 0 ] || exit "${STUB_RUN_RC}"
    # The CLI passes the container mount point as the first positional; swap in the
    # fixture so the real in-container body runs against real files, and keep any later
    # positional (the leaf name show passes) intact.
    exec sh -c "${script}" sh "${STUB_ARCHIVE_ROOT}" "${extra[@]}"
    ;;
  *)
    exit "${STUB_RUN_RC:-0}"
    ;;
esac
STUB
  chmod +x "${path}"
}

# docker_argv - the logged docker invocations, one per line.
docker_argv() {
  cat "${STUB_LOG}/docker" 2>/dev/null || true
}

@test "session-archive: the documented functions are all defined" {
  # scripts/shell_inventory.sh requires every production function to be named under
  # tests/; this names them and proves they exist rather than only mentioning them.
  run bash -c ". '${SCRIPT}' >/dev/null 2>&1; for f in usage validate_leaf archive_run cmd_list cmd_show cmd_export cmd_check parse_args; do declare -F \"\$f\" >/dev/null || exit 1; done"
  [ "${status}" -eq 0 ]
}

@test "session-archive: --help prints the verb list and exits 0" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"list"* ]]
  [[ "${output}" == *"export WORKSPACE"* ]]
  [[ "${output}" == *"read-only"* ]]
  [[ "${output}" == *"stack host"* ]]
}

@test "session-archive: an unknown subcommand is a usage error and never reaches docker" {
  run bash "${SCRIPT}" nosuchverb
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown subcommand"* ]]
  [ ! -s "${STUB_LOG}/docker" ]
}

@test "session-archive: an unknown option is a usage error" {
  run bash "${SCRIPT}" --bogus list
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown option"* ]]
  [ ! -s "${STUB_LOG}/docker" ]
}

@test "session-archive: list prints one row per archived workspace leaf" {
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ws-alice"* ]]
  [[ "${output}" == *"ws-bob"* ]]
  [[ "${output}" == *"summary:"* ]]
}

@test "session-archive: every verb mounts the archive read-only" {
  # The archive is only an out-of-band copy while nothing can write it back.
  bash "${SCRIPT}" list >/dev/null 2>&1
  bash "${SCRIPT}" show ws-alice >/dev/null 2>&1
  bash "${SCRIPT}" export ws-alice "${SCRATCH}/out" >/dev/null 2>&1
  local runs
  runs="$(docker_argv | grep -c 'docker run\|run --rm' || true)"
  [ "${runs}" -ge 3 ]
  # No run may mount the volume without the trailing :ro.
  while IFS= read -r line; do
    [[ "${line}" == *":ro"* ]] || {
      printf 'a run mounted the volume without :ro: %s\n' "${line}" >&2
      return 1
    }
  done < <(docker_argv | grep 'run ')
}

@test "session-archive: list warns and fails on an empty archive" {
  rm -rf "${STUB_ARCHIVE_ROOT}/workspaces"
  mkdir -p "${STUB_ARCHIVE_ROOT}/workspaces"
  run bash "${SCRIPT}" list
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"warning:"* ]]
}

@test "session-archive: show lists the leaf's files relative to the leaf" {
  run bash "${SCRIPT}" show ws-alice
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"sessions/2026/a.jsonl"* ]]
  [[ "${output}" == *"sessions/2026/b.jsonl"* ]]
  [[ "${output}" == *"2 files"* ]]
  # The listing is the whole leaf, paths relative to it, so an operator can hand a
  # single session file out without mounting the volume anywhere.
}

@test "session-archive: show refuses a name that is not one path segment" {
  for bad in '../..' 'ws-alice/../ws-bob' 'a/b' '' 'a b'; do
    run bash "${SCRIPT}" show "${bad}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"one path segment"* || "${output}" == *"workspace leaf name is required"* ]]
  done
  [ ! -s "${STUB_LOG}/docker" ]
}

@test "session-archive: show warns on a leaf the archive does not hold" {
  run bash "${SCRIPT}" show ws-missing
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no archived files"* ]]
}

@test "session-archive: export writes the leaf out and refuses a dirty destination" {
  run bash "${SCRIPT}" export ws-alice "${SCRATCH}/out"
  [ "${status}" -eq 0 ]
  [ -f "${SCRATCH}/out/ws-alice/sessions/2026/a.jsonl" ]

  # A second export into the same non-empty directory must refuse rather than merge.
  run bash "${SCRIPT}" export ws-alice "${SCRATCH}/out"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"not empty"* ]]
}

@test "session-archive: export reports a failed container rather than an empty success" {
  STUB_RUN_RC=1 run bash "${SCRIPT}" export ws-alice "${SCRATCH}/out2"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"error:"* ]]
}

@test "session-archive: check passes when the daemon, volume and image all answer" {
  run bash "${SCRIPT}" check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok: the daemon answers"* ]]
  [[ "${output}" == *"ok: volume grok-session-archive exists"* ]]
  [[ "${output}" == *"ok: image alpine is present locally"* ]]
}

@test "session-archive: check flags a missing volume and a dead daemon separately" {
  STUB_VOLUME_EXISTS=0 run bash "${SCRIPT}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"volume grok-session-archive is missing"* ]]

  STUB_INFO_RC=1 run bash "${SCRIPT}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"docker is not reachable"* ]]
}

@test "session-archive: --volume and --image change what docker is asked for" {
  run bash "${SCRIPT}" --volume other-vol --image busybox list
  [ "${status}" -eq 0 ]
  docker_argv | grep -q 'other-vol:/archive:ro'
  docker_argv | grep -q 'busybox'
}

@test "session-archive: --timeout rejects a non-numeric cap" {
  run bash "${SCRIPT}" --timeout soon list
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"wants seconds"* ]]
}

@test "session-archive: the report verbs keep ok: and warning: off stderr" {
  # JSON_MODE would route them there; this CLI has no --json, so it unsets the flag.
  run bash -c "JSON_MODE=1 bash '${SCRIPT}' list 2>/dev/null"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok:"* ]]
}
