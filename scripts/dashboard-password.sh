#!/usr/bin/env bash
#
# ## dashboard-password.sh — rotate the Homepage dashboard login password
#
# Change the Homepage dashboard login password (HOMEPAGE_AUTH_PASSWORD in .env).
#
# Upstream homepage v2.4.0 hashes this value itself — its NextAuth chunk does
# sha256(HOMEPAGE_AUTH_PASSWORD) and a timingSafeEqual — so it only accepts the
# plaintext form and .env has to carry it as-is. What this script controls is
# where the value leaks: never into shell history, never into the argv of an
# exec'd process (so never visible in `ps`), never into git, and .env ends up
# mode 600.
#
# A container's environment is frozen at container-create time, so applying the
# new value takes `docker compose up -d --force-recreate homepage`; plain
# `docker compose restart homepage` reuses the existing container and keeps the
# OLD value in its env.
#
# Session cookies are signed by HOMEPAGE_AUTH_SECRET, which this script never
# touches, so already-signed-in browsers keep working until they expire.
#
# DASHBOARD_ENV_FILE overrides the .env path for test harnesses only. There is
# deliberately no flag for it: a flag that names a file this script overwrites
# is the one thing you do not want a keystroke away from mistyping.
#
# Usage:
#   bazelisk run //scripts:dashboard-password
#   bazelisk run //scripts:dashboard-password -- --prompt
#   bazelisk run //scripts:dashboard-password -- --no-apply
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=lib/coder_api.sh disable=SC1091
source "scripts/lib/coder_api.sh"

ENV_FILE="${DASHBOARD_ENV_FILE:-.env}"
KEY="HOMEPAGE_AUTH_PASSWORD"
MIN_LEN=12
TMP_FILE=""

# @function cleanup
# Remove the temporary file or directory this run created.
# Globals:
#   TMP_FILE (dashboard-password.sh) or WORK (new-workspace.sh)
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
cleanup() {
  if [ -n "${TMP_FILE}" ]; then
    rm -f "${TMP_FILE}"
  fi
}
trap cleanup EXIT

# @function usage
# Print this script's help text.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The help text on stdout
# Returns:
#   0
usage() {
  cat <<'EOF'
usage: bazelisk run //scripts:dashboard-password -- [--prompt] [-l|--length N] [--no-apply]

Change the dashboard login password stored as HOMEPAGE_AUTH_PASSWORD in .env,
then recreate the homepage container so it picks the new value up.

  (no args)      generate a strong password with `openssl rand -base64 24`
  --prompt       type the password yourself, twice, echo off
  -l|--length N  bytes of entropy for the generated password (default 24; the
                 value printed is its base64, so about 4/3*N characters)
  --no-apply     rewrite .env only, skip the docker steps (offline use)
  -h|--help      this text

A new password is NOT accepted as an argument: argv is readable by any local
user through `ps`, and the value would also be saved in your shell history.
Use --prompt, or run the script with no arguments and let it generate one.

A generated password is printed once, here and nowhere else; it then lives in
.env, which is gitignored and left mode 600.
EOF
}

# @function die
# Print an error on stderr and exit 1.
# Globals:
#   None
# Arguments:
#   $* - error text, without the "error: " prefix
# Outputs:
#   "error: ..." on stderr
# Returns:
#   Does not return; exits 1
die() {
  echo "error: $*" >&2
  exit 1
}

MODE=generate
LENGTH=24
APPLY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) MODE=prompt ;;
    -l | --length)
      shift
      [ $# -gt 0 ] || die "--length needs a number"
      case "$1" in
        '' | *[!0-9]*) die "--length must be a positive integer, got: $1" ;;
      esac
      [ "$1" -ge 1 ] || die "--length must be at least 1"
      [ "$1" -le 512 ] || die "--length must be at most 512"
      LENGTH="$1"
      ;;
    --no-apply) APPLY=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      die "a new password cannot be given as an argument: argv shows up in 'ps' for every local user, and the value would also land in your shell history. Use --prompt to type it, or run with no arguments to have one generated."
      ;;
  esac
  shift
done

if [ ! -f "${ENV_FILE}" ]; then
  echo "error: ${ENV_FILE} not found" >&2
  echo "       first boot? run bazelisk run //scripts:bootstrap to create it" >&2
  exit 1
fi
{ [ -r "${ENV_FILE}" ] && [ -w "${ENV_FILE}" ]; } ||
  die "${ENV_FILE} is not both readable and writable by this user"

if [ "${APPLY}" = 1 ]; then
  # Checked here rather than at the docker call, so an offline run fails before
  # .env has already moved on to a password nobody is logged in with. The
  # unquoted DOCKER_BIN splits "sudo docker" into both words, and every
  # daemon probe below is bounded by timeout(1), so both must be present.
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  command -v ${DOCKER_BIN} >/dev/null 2>&1 || die "docker not found on PATH (use --no-apply to update .env only)"
  command -v timeout >/dev/null 2>&1 || die "timeout(1) not found on PATH (use --no-apply to update .env only)"
fi

case "${MODE}" in
  generate)
    # openssl folds base64 at 64 columns above 48 bytes and command substitution
    # keeps those newlines in the value, which would write a multi-line (broken)
    # key into .env. Strip the folds, then require the base64 alphabet.
    new_password="$(openssl rand -base64 "${LENGTH}" | tr -d '\n\r')"
    case "${new_password}" in
      '' | *[!A-Za-z0-9+/=]*) die "openssl produced an unusable value" ;;
    esac
    ;;
  prompt)
    # read -rs keeps the value out of both echo and the history file. A
    # redirected stdin with two lines (the bats suites) returns immediately.
    # bazelisk run keeps a pipe open with no EOF, so a non-TTY read is
    # time-bounded: without -t it would wait forever.
    printf 'new dashboard password: '
    if [ -t 0 ]; then
      IFS= read -rs first
    else
      IFS= read -rs -t 15 first ||
        die "--prompt got no password on stdin within 15s (pipe two lines, or run from a terminal: bazelisk run //scripts:dashboard-password -- --prompt)"
    fi
    printf '\nrepeat it:              '
    if [ -t 0 ]; then
      IFS= read -rs second
    else
      IFS= read -rs -t 15 second ||
        die "--prompt got no second line on stdin within 15s"
    fi
    printf '\n'
    [ "${first}" = "${second}" ] || die "the two entries did not match; nothing was changed"
    new_password="${first}"
    unset first second
    ;;
esac

[ "${#new_password}" -ge "${MIN_LEN}" ] ||
  die "password too short: at least ${MIN_LEN} characters required (got ${#new_password})"

# @function read_env_value
# Print the current value of one key in ENV_FILE, with no trailing newline.
# Globals:
#   ENV_FILE
# Arguments:
#   $1 - key name
# Outputs:
#   The value, or nothing when the key is absent
# Returns:
#   0
read_env_value() {
  # $1 = key name; prints its value with no trailing newline. read -r keeps
  # backslashes literal, so this round-trips values that sed or awk would eat.
  local line out=""
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "$1"=*) out="${line#"$1"=}" ;;
    esac
  done <"${ENV_FILE}"
  printf '%s' "${out}"
}

# @function hash_of
# Print the sha256 hex of a value. The value goes in on a pipe, never argv.
# Globals:
#   None
# Arguments:
#   $1 - text to hash
# Outputs:
#   The hex digest
# Returns:
#   0
hash_of() {
  # sha256 hex of $1. The value reaches the hasher through a pipe, never through
  # argv: sha256sum hashes files, and a secret in the argv of a live process is
  # readable by anyone via /proc. printf is a builtin, so nothing is exec'd with
  # it. sha256sum is Linux, shasum is macOS; openssl is the fallback and labels
  # its output, hence $NF there.
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

# @function write_env_line
# Replace or append KEY in ENV_FILE. The value is copied, never passed to sed.
# Globals:
#   ENV_FILE, KEY, TMP_FILE
# Arguments:
#   $1 - new value
# Outputs:
#   None. Rewrites ENV_FILE mode 600.
# Returns:
#   0
write_env_line() {
  # $1 = new value. The value never reaches sed or awk: both give &, \, / and |
  # a special meaning (and awk -v collapses backslashes), and a password may
  # contain all of them. The file is copied line by line instead, so every byte
  # outside the one replaced line survives untouched.
  local value="$1" line seen=0
  # Same directory, so the mv below is an atomic rename rather than a copy that
  # leaves a window where .env does not exist.
  TMP_FILE="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  # mktemp already creates it 0600; ask anyway so the mode is not incidental.
  chmod 600 "${TMP_FILE}"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${KEY}"=*)
        # Keep exactly one occurrence: compose resolves a duplicated key by last
        # match, so a stale later line would leave the file disagreeing with the
        # password this script prints.
        if [ "${seen}" = 0 ]; then
          printf '%s=%s\n' "${KEY}" "${value}"
        fi
        seen=1
        continue
        ;;
    esac
    printf '%s\n' "${line}"
  done <"${ENV_FILE}" >"${TMP_FILE}"
  # A .env written before this key existed gets it appended rather than left
  # unset, where compose would silently fall back to its change-me default.
  if [ "${seen}" = 0 ]; then
    printf '%s=%s\n' "${KEY}" "${value}" >>"${TMP_FILE}"
  fi
  mv "${TMP_FILE}" "${ENV_FILE}"
  TMP_FILE=""
  chmod 600 "${ENV_FILE}"
}

write_env_line "${new_password}"

want_hash="$(hash_of "${new_password}")"
# Read the value back before touching docker: a rewrite that did not land must
# not be followed by a recreate that locks everybody out.
in_file="$(read_env_value "${KEY}")"
if [ "$(hash_of "${in_file}")" != "${want_hash}" ]; then
  die "${ENV_FILE} does not hold the value that was written; nothing was applied"
fi
echo "updated ${KEY} in ${ENV_FILE} (mode 600)"

if [ "${MODE}" = "generate" ]; then
  # Printed before the docker steps, not after: if compose then fails, this value
  # is already the one live in .env, and losing it would mean a second rewrite to
  # get back into the dashboard.
  echo
  echo "new dashboard password: ${new_password}"
  echo "shown only now — it lives in ${ENV_FILE} (chmod 600), which is gitignored."
fi

if [ "${APPLY}" = 0 ]; then
  echo
  echo "not applied: rerun without --no-apply:"
  echo "  bazelisk run //scripts:dashboard-password"
else
  # The homepage container is FOUND on the daemon, by container label, and then
  # recreated inside the compose project that created it — never through a
  # cwd-resolved project (scripts/lib/coder_api.sh: a bare `docker compose`
  # run from any other directory, `bazelisk run` above all, resolves a shadow
  # project and would build a second homepage with the wrong binds and no .env
  # interpolation, leaving the real one on the old password).
  if ! running="$(stack_ps)"; then
    die "could not query the docker daemon: ${running}"
  fi
  HOME_CONTAINER="$(stack_container "${running}" homepage)"
  [ -n "${HOME_CONTAINER}" ] ||
    die "could not find the homepage container on the docker daemon (use --no-apply to update .env only)"
  compose_target="$(stack_compose_target "${HOME_CONTAINER}")"
  compose_proj="${compose_target%%|*}"
  compose_file="${compose_target#*|}"
  if [ -z "${compose_proj}" ] || [ -z "${compose_file}" ] ||
    [ "${compose_file}" = "${compose_target}" ] || [ ! -f "${compose_file}" ]; then
    die "the homepage container answers to no compose project this shell can read; from the checkout root run: docker compose up -d --force-recreate homepage (or bazelisk run //scripts:prod-stack -- up, then bazelisk run //scripts:dashboard-password)"
  fi

  # -p and -f rebuild the addressing the stack was started with, from any
  # cwd: the compose file also names its own directory, and with it the .env
  # this script just rewrote, so the recreated container interpolates
  # HOMEPAGE_AUTH_PASSWORD exactly as `docker compose up -d` from the checkout
  # root would have. DOCKER_BIN stays unquoted for the "sudo docker" override.
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  ${DOCKER_BIN} compose -p "${compose_proj}" -f "${compose_file}" up -d --force-recreate homepage

  # Compose recreates the container under the same name inside the same
  # project, so the name found above now names the NEW container; and there is
  # no `head -n 1` anywhere in this branch, because closing a pipe early would
  # hand docker a SIGPIPE that pipefail would report as a spurious failure.
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  container_env="$(stack_timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${HOME_CONTAINER}" 2>/dev/null || true)"
  env_line="$(printf '%s\n' "${container_env}" | grep "^${KEY}=" || true)"
  [ -n "${env_line}" ] || die "the homepage container has no ${KEY} entry; check: bazelisk run //scripts:prod-stack -- status"

  in_container="${env_line#"${KEY}="}"
  if [ "$(hash_of "${in_container}")" = "${want_hash}" ]; then
    echo "verified: the running container has the new password"
  else
    die "the running container still has the old password — the recreate did not take; check: bazelisk run //scripts:prod-stack -- logs --tail 100 homepage"
  fi
fi

echo
echo "note: existing dashboard sessions stay valid until they expire — the session"
echo "cookie is signed by HOMEPAGE_AUTH_SECRET, which did not change."
