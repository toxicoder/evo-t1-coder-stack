#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## configure.sh - shape a contributor dev container once it is up (entry point).
#
# Runs from .devcontainer/devcontainer.json as postCreateCommand (mode `create`)
# and postStartCommand (mode `start`), and is safe to re-run by hand: every step
# is idempotent and `--dry-run` prints the plan without writing anything.
#
# Why each step is here rather than in the image: the image (images/dev) is
# shared with the Coder workspaces and the CI gate, so it carries the toolchain
# and nothing about this container. A cache written into the container's own
# writable layer dies with every recreation, which is what the mounted volumes
# and the managed block in ~/.bazelrc below exist to prevent.
#
# It never writes a secret, never reads .env, and never guesses a git identity:
# a missing user.email is reported, not filled in.
#
# Usage (inside the container, from the checkout):
#   bash .devcontainer/library-scripts/configure.sh create [--dry-run]
#   bash .devcontainer/library-scripts/configure.sh start
#   bash .devcontainer/library-scripts/configure.sh status
#   bash .devcontainer/library-scripts/configure.sh -h|--help
#
# Environment (every default is the value devcontainer.json sets):
#   EVO_T1_BAZEL_CACHE_ROOT  cache root the mounts and ~/.bazelrc agree on
#                            (default /var/cache/evo-t1-bazel)
#   EVO_T1_TOOL_CACHE_ROOT   package-manager download cache root
#                            (default /var/cache/evo-t1-toolcache)
#   EVO_T1_WARMUP            off to skip the background gate warm-up; anything
#                            else (unset included) runs it
#   EVO_T1_WARMUP_LOG        warm-up log path (default /tmp/evo-t1-warmup.log)
#   EVO_T1_WARMUP_STATUS     warm-up status file (default /tmp/evo-t1-warmup.status)
#   EVO_T1_WARMUP_LOCK       warm-up lock file (default /tmp/evo-t1-warmup.lock)
#   EVO_T1_DOCKER_SOCKET     the socket to make usable (default
#                            /var/run/docker.sock, which is where the config
#                            bind-mounts the workstation's daemon)
#
# Exit codes: 0 when every required step succeeded (advisory findings are
# warnings, not failures); 1 for a usage error or a failed required step; 5 when
# no proven checkout was found.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh disable=SC1091
source "${REPO_DIR}/scripts/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

BAZEL_CACHE_ROOT="${EVO_T1_BAZEL_CACHE_ROOT:-/var/cache/evo-t1-bazel}"
TOOL_CACHE_ROOT="${EVO_T1_TOOL_CACHE_ROOT:-/var/cache/evo-t1-toolcache}"
WARMUP_MODE="${EVO_T1_WARMUP:-full}"
WARMUP_LOG="${EVO_T1_WARMUP_LOG:-/tmp/evo-t1-warmup.log}"
WARMUP_STATUS="${EVO_T1_WARMUP_STATUS:-/tmp/evo-t1-warmup.status}"
WARMUP_LOCK="${EVO_T1_WARMUP_LOCK:-/tmp/evo-t1-warmup.lock}"

# The two lines that bracket this script's block in ~/.bazelrc. Everything
# outside them belongs to the developer and survives every run.
BAZELRC_BEGIN="# BEGIN evo-t1 contributor dev container (managed by .devcontainer/library-scripts/configure.sh)"
BAZELRC_END="# END evo-t1 contributor dev container"

DRY_RUN=0
SUDO=""

# @function usage
# Print the usage block.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Usage text on stdout
# Returns:
#   0
usage() {
  # Print the header block verbatim. It is read up to the first line that is not
  # a comment, so documenting a new variable here cannot fall off the end of a
  # hardcoded line range.
  awk 'NR < 3 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

# @function run_or_report
# Run a command, or print what it would have done under --dry-run.
# Globals:
#   DRY_RUN
# Arguments:
#   $1 - the "would" description printed in dry-run mode
#   $* - the command and its arguments
# Outputs:
#   "-> ..." in dry-run mode; otherwise whatever the command prints
# Returns:
#   The command's status, or 0 in dry-run mode
run_or_report() {
  local description="$1"
  shift
  if [ "${DRY_RUN}" = 1 ]; then
    phase "would ${description}"
    return 0
  fi
  "$@"
}

# @function run_maybe_sudo
# Run a command as root when a usable sudo was found, and plainly when not.
#
# The `${SUDO:-true}` shorthand is a trap here: with no sudo it expands to
# `true`, which ignores its arguments and exits 0, so the caller reports a
# privilege change that never happened.
# Globals:
#   SUDO
# Arguments:
#   $* - the command and its arguments
# Outputs:
#   Whatever the command prints
# Returns:
#   The command's status
run_maybe_sudo() {
  if [ -n "${SUDO}" ]; then
    "${SUDO}" "$@"
  else
    "$@"
  fi
}

# @function ensure_cache_dirs
# Create the mounted cache directories and hand them to the remote uid.
#
# The volumes are created by Docker as root, and updateRemoteUserUID can move
# the coder uid off 1000, so ownership is asserted on every run rather than
# baked once into an image this container does not own.
# Globals:
#   BAZEL_CACHE_ROOT, TOOL_CACHE_ROOT, SUDO, DRY_RUN
# Arguments:
#   None
# Outputs:
#   One phase line per directory tree
# Returns:
#   0 always; the caller decides what a failure means
ensure_cache_dirs() {
  local d owner create_err
  # The two roots come first: install -d gives a directory it has to create the
  # default mode, and a root-owned parent makes its leaf unwritable no matter
  # what the leaf itself is owned by.
  for d in "${BAZEL_CACHE_ROOT}" "${BAZEL_CACHE_ROOT}/disk" "${BAZEL_CACHE_ROOT}/repo" "${BAZEL_CACHE_ROOT}/root" \
    "${TOOL_CACHE_ROOT}" "${TOOL_CACHE_ROOT}/bazelisk" "${TOOL_CACHE_ROOT}/npm" "${TOOL_CACHE_ROOT}/uv" "${TOOL_CACHE_ROOT}/pip"; do
    phase "cache dir ${d}"
    if [ "${DRY_RUN}" = 1 ]; then
      phase "would create and own ${d}"
      continue
    fi
    # Create unprivileged first. A uid that the host's sudo refuses - a Bazel
    # test sandbox, an unmapped uid - must not lose the seam to a sudo that
    # cannot even start, and the plain create is the one that succeeds there.
    # sudo stays the fallback for a volume Docker mounted root-owned, where
    # install -d would need the chmod it also does.
    create_err=""
    if ! create_err="$(install -d -m 0775 "${d}" 2>&1)"; then
      if [ -z "${SUDO}" ] || ! ${SUDO} install -d -m 0775 "${d}" >/dev/null 2>&1; then
        if [ -n "${create_err}" ]; then
          note "${create_err}"
        fi
        fail_item "cannot create the cache directory ${d}"
        continue
      fi
    fi
    owner="$(stat -c %u "${d}" 2>/dev/null || printf 'none')"
    if [ "${owner}" != "$(id -u)" ]; then
      if [ -n "${SUDO}" ] && ${SUDO} chown "$(id -u):$(id -g)" "${d}" >/dev/null 2>&1; then
        ok "${d} handed to uid $(id -u)"
      else
        warn "${d} is owned by uid ${owner}, not $(id -u); Bazel may refuse to write it"
      fi
    fi
  done
}

# @function strip_bazelrc_managed_block
# Print a bazelrc without this script's managed block.
# Globals:
#   BAZELRC_BEGIN, BAZELRC_END
# Arguments:
#   $1 - file to read (absent file prints nothing)
# Outputs:
#   The surviving lines on stdout
# Returns:
#   0
strip_bazelrc_managed_block() {
  local src="${1:-}" line skip=0
  [ -n "${src}" ] && [ -f "${src}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${BAZELRC_BEGIN}"*)
        skip=1
        continue
        ;;
      "${BAZELRC_END}"*)
        skip=0
        continue
        ;;
    esac
    if [ "${skip}" = 0 ]; then
      printf '%s\n' "${line}"
    fi
  done <"${src}"
  # A hand-edited file that lost its END line would otherwise swallow every
  # line after BEGIN with no trace, so say so before the caller replaces it.
  if [ "${skip}" != 0 ]; then
    printf 'warning: %s has no managed-block END line; the lines after BEGIN were dropped and will be rewritten\n' "${src}" >&2
  fi
}

# @function write_bazelrc
# Write the managed block that points Bazel's caches at the mounted volumes.
#
# ~/.bazelrc is the seam because Bazel reads it last, after the repo's
# .bazelrc, and it reaches only this container: a Coder workspace booted from
# the same image keeps using its own ~/.cache. The three options are the whole
# cost of a container recreation, and leaving any of them off costs a
# re-download or a re-analysis on the first gate run.
# Globals:
#   HOME, BAZEL_CACHE_ROOT, BAZELRC_BEGIN, BAZELRC_END, DRY_RUN
# Arguments:
#   None
# Outputs:
#   Phase and ok lines; the file itself
# Returns:
#   0 always; the caller decides what a failure means
write_bazelrc() {
  local target="${HOME}/.bazelrc" tmp
  phase "bazel cache seam in ${target}"
  if [ "${DRY_RUN}" = 1 ]; then
    phase "would write the managed block for ${BAZEL_CACHE_ROOT}"
    return 0
  fi
  tmp="$(mktemp)" || {
    fail_item "cannot create a temporary file for ${target}"
    return 0
  }
  strip_bazelrc_managed_block "${target}" >"${tmp}"
  {
    printf '%s\n' "${BAZELRC_BEGIN}"
    printf 'common --disk_cache=%s/disk\n' "${BAZEL_CACHE_ROOT}"
    printf 'common --repository_cache=%s/repo\n' "${BAZEL_CACHE_ROOT}"
    printf 'startup --output_user_root=%s/root\n' "${BAZEL_CACHE_ROOT}"
    printf '%s\n' "${BAZELRC_END}"
  } >>"${tmp}"
  # A dotfiles manager keeps ~/.bazelrc as a symlink into its own tree, and mv
  # would leave the developer's canonical file behind without the block. Write
  # through the link when there is one, and keep a plain file world-readable
  # rather than at mktemp's 0600.
  local written=0
  if [ -L "${target}" ]; then
    if cat "${tmp}" >"${target}" 2>/dev/null; then
      written=1
    fi
  elif chmod 644 "${tmp}" 2>/dev/null && mv "${tmp}" "${target}" 2>/dev/null; then
    written=1
  fi
  rm -f "${tmp}"
  if [ "${written}" = 1 ]; then
    ok "bazel caches point at ${BAZEL_CACHE_ROOT}"
  else
    fail_item "cannot write ${target}"
  fi
}

# @function relax_docker_socket
# Make the bind-mounted workstation socket usable by the remote uid.
#
# The socket's group on the host is whatever the workstation's docker daemon
# uses, and the container's uid is remapped at create time, so this is retried
# on every start rather than settled once. Either route is fine; both are
# best effort because a locked-down host may permit neither.
# Globals:
#   SUDO, EVO_T1_DOCKER_SOCKET
# Arguments:
#   None
# Outputs:
#   One ok or note line
# Returns:
#   0
relax_docker_socket() {
  local sock="${EVO_T1_DOCKER_SOCKET:-/var/run/docker.sock}"
  if [ ! -S "${sock}" ]; then
    note "no docker socket at ${sock}: docker commands in here will not reach a daemon"
    return 0
  fi
  if [ -r "${sock}" ] && [ -w "${sock}" ]; then
    ok "docker socket is usable"
    return 0
  fi
  if run_maybe_sudo setfacl -m "u:$(id -u):rw" "${sock}" 2>/dev/null ||
    run_maybe_sudo chmod a+rw "${sock}" 2>/dev/null; then
    ok "docker socket opened for uid $(id -u)"
  else
    note "docker socket is not writable by uid $(id -u); add the user to the docker group on the host"
  fi
}

# @function seed_home
# Materialize the stack-owned contributor home from the repo's own templates.
#
# This is the same seeder a workspace start runs, so tmux, the shared editor
# settings, ~/.grok/AGENTS.md, the rendered grok config, the terminal helpers
# and this clone's notes.md all arrive from one source of truth. It talks to no
# daemon and needs no credential: --devcontainer only lets it run
# `gh auth setup-git` when a token is already in the environment.
# Globals:
#   ROOT_DIR, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The seeder's own report
# Returns:
#   0 always; the caller decides what a failure means
seed_home() {
  phase "seed the contributor home"
  run_or_report "run scripts/seed-dev-env.sh --devcontainer --context7-mcp" \
    bash "${ROOT_DIR}/scripts/seed-dev-env.sh" --devcontainer --context7-mcp ||
    fail_item "seed-dev-env.sh did not finish"
}

# @function install_git_hooks
# Point this checkout's git hooks at .githooks, the gate the pre-commit hook runs.
#
# Checked before it is installed because the installer is a Bazel-free CLI that
# rewrites core.hooksPath, and a `foreign` hooksPath (someone's own hook
# directory) is reported rather than overwritten.
# Globals:
#   ROOT_DIR, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The installer's report, or one note when a foreign path is in the way
# Returns:
#   0 always; the caller decides what a failure means
install_git_hooks() {
  local configured
  configured="$(git -C "${ROOT_DIR}" config --get core.hooksPath 2>/dev/null || true)"
  if [ "${configured}" = ".githooks" ]; then
    ok "git hooks installed (core.hooksPath=.githooks)"
    return 0
  fi
  if [ -n "${configured}" ]; then
    note "core.hooksPath is already ${configured}; leaving the repo's .githooks to be installed by hand"
    return 0
  fi
  phase "install the repo's git hooks"
  run_or_report "run scripts/install-hooks.sh" \
    bash "${ROOT_DIR}/scripts/install-hooks.sh" ||
    fail_item "install-hooks.sh did not finish"
}

# @function warmup_enabled
# Report whether the background warm-up should run.
# Globals:
#   WARMUP_MODE
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   1 when EVO_T1_WARMUP says off, 0 otherwise
warmup_enabled() {
  case "${WARMUP_MODE}" in
    off | 0 | false | no) return 1 ;;
    *) return 0 ;;
  esac
}

# @function launch_warmup
# Start the detached warm-up once, and only once, per container.
#
# Detached with setsid because the Dev Containers CLI tears down the postCreate
# process group when the command returns, and a warm-up that dies with it leaves
# the first real gate run paying for every download. The lock makes a second
# start a no-op instead of a second Bazel server fighting for the same output
# base.
# Globals:
#   SELF_DIR, WARMUP_LOG, WARMUP_STATUS, WARMUP_LOCK, DRY_RUN
# Arguments:
#   None
# Outputs:
#   One phase or note line; the log and status files are created
# Returns:
#   0 always; the caller decides what a failure means
launch_warmup() {
  local prior
  if ! warmup_enabled; then
    note "warm-up skipped (EVO_T1_WARMUP=${WARMUP_MODE}); the first gate run pays the cold-cache cost"
    return 0
  fi
  # A finished warm-up is not repeated, but a failed one is: the status file
  # lives in /tmp for the life of the container, and postStart is where a
  # transient registry or Bazel failure gets its retry.
  if [ -f "${WARMUP_STATUS}" ]; then
    prior="$(cat "${WARMUP_STATUS}")"
    case "${prior}" in
      '' | running) ;;
      failed:*) warn "the last warm-up ${prior}; running it again" ;;
      *)
        ok "warm-up already finished: ${prior}"
        return 0
        ;;
    esac
  fi
  if [ "${DRY_RUN}" = 1 ]; then
    phase "would start the background warm-up"
    return 0
  fi
  if has_tool flock; then
    # fd 9 stays open into the setsid child, so the lock is held for the whole
    # warm-up and a second start finds it busy.
    exec 9>"${WARMUP_LOCK}"
    if ! flock -n 9; then
      note "warm-up is already running; log at ${WARMUP_LOG}"
      return 0
    fi
  else
    note "no flock on PATH; two overlapping starts would each launch a warm-up"
  fi
  phase "background warm-up"
  : >"${WARMUP_LOG}"
  printf 'running\n' >"${WARMUP_STATUS}"
  setsid nohup bash "${SELF_DIR}/warmup.sh" >"${WARMUP_LOG}" 2>&1 </dev/null &
  ok "warm-up started (pid $!); tail -f ${WARMUP_LOG}"
}

# @function report_state
# Print what a contributor needs to know before the first command.
# Globals:
#   ROOT_DIR, HOME, BAZEL_CACHE_ROOT, WARMUP_LOG, WARMUP_STATUS
# Arguments:
#   None
# Outputs:
#   One line per checked fact
# Returns:
#   0
report_state() {
  local d configured email node_bin
  section "container state"
  for d in "${BAZEL_CACHE_ROOT}/disk" "${BAZEL_CACHE_ROOT}/repo" "${BAZEL_CACHE_ROOT}/root"; do
    if [ -w "${d}" ]; then
      ok "bazel cache writable: ${d}"
    else
      warn "bazel cache not writable: ${d}"
    fi
  done
  configured="$(git -C "${ROOT_DIR}" config --get core.hooksPath 2>/dev/null || true)"
  if [ "${configured}" = ".githooks" ]; then
    ok "commit and push gates are armed"
  else
    warn "git hooks not installed (core.hooksPath=${configured:-unset}); run: bazelisk run //scripts:install-hooks"
  fi
  email="$(git -C "${ROOT_DIR}" config --get user.email 2>/dev/null || true)"
  if [ -z "${email}" ]; then
    warn "git identity is unset; set user.name and user.email before the first commit"
  fi
  node_bin="${ROOT_DIR}/docs-site/node_modules/.bin"
  if [ -x "${node_bin}/next" ] && [ -x "${node_bin}/vitest" ]; then
    ok "docs-site deps are installed"
  else
    warn "docs-site deps are missing; //docs-site:* gates install them on first use"
  fi
  if [ -f "${WARMUP_STATUS}" ]; then
    note "warm-up $(cat "${WARMUP_STATUS}") - log: ${WARMUP_LOG}"
  fi
}

# @function main
# Parse argv and run the requested mode.
# Globals:
#   DRY_RUN, SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL
# Arguments:
#   $1 - create | start | status; remaining args accept --dry-run and -h|--help
# Outputs:
#   Section, phase, ok, warning, note and error lines, then a summary
# Returns:
#   0 when no required step failed, 1 on a usage error or a failed step,
#   5 when no proven checkout was found
main() {
  local mode="${1:-}"
  shift || true
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        err "configure.sh: unknown option ${arg}"
        usage >&2
        return 1
        ;;
    esac
  done
  case "${mode}" in
    create | start | status) ;;
    -h | --help)
      # The documented `-h|--help` form lands in the mode position, so it is
      # answered here as well as in the option loop above.
      usage
      return 0
      ;;
    *)
      err "configure.sh: mode must be create, start or status"
      usage >&2
      return 1
      ;;
  esac

  ROOT_DIR="$(resolve_checkout "${REPO_DIR}/..")" || return 5

  if [ "${mode}" = status ]; then
    report_state
    summary
    return 0
  fi
  if [ "$(id -u)" != 0 ] && has_tool sudo; then
    SUDO=sudo
  fi

  section "contributor dev container (${mode})"
  ensure_cache_dirs
  write_bazelrc
  relax_docker_socket
  if [ "${mode}" = create ]; then
    seed_home
  fi
  install_git_hooks
  launch_warmup
  report_state
  summary "bazelisk test //:test-fast"
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    return 1
  fi
  return 0
}

main "$@"
