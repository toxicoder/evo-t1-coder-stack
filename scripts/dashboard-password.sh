#!/usr/bin/env bash
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
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${DASHBOARD_ENV_FILE:-.env}"
KEY="HOMEPAGE_AUTH_PASSWORD"
MIN_LEN=12
TMP_FILE=""

cleanup() {
  if [ -n "${TMP_FILE}" ]; then
    rm -f "${TMP_FILE}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: scripts/dashboard-password.sh [--prompt] [-l|--length N] [--no-apply]

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
  echo "       first boot? run ./scripts/bootstrap.sh to create it" >&2
  exit 1
fi
{ [ -r "${ENV_FILE}" ] && [ -w "${ENV_FILE}" ]; } ||
  die "${ENV_FILE} is not both readable and writable by this user"

if [ "${APPLY}" = 1 ]; then
  # Checked here rather than at the docker call, so an offline run fails before
  # .env has already moved on to a password nobody is logged in with.
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH (use --no-apply to update .env only)"
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
    # read -rs keeps the value out of both echo and the history file. With a
    # redirected stdin the two reads come back empty, which the length floor
    # below rejects, so a non-tty run can never write a blank password.
    printf 'new dashboard password: '
    IFS= read -rs first
    printf '\nrepeat it:              '
    IFS= read -rs second
    printf '\n'
    [ "${first}" = "${second}" ] || die "the two entries did not match; nothing was changed"
    new_password="${first}"
    unset first second
    ;;
esac

[ "${#new_password}" -ge "${MIN_LEN}" ] ||
  die "password too short: at least ${MIN_LEN} characters required (got ${#new_password})"

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
  echo "not applied: rerun without --no-apply, or run"
  echo "  docker compose up -d --force-recreate homepage"
else
  docker compose up -d --force-recreate homepage

  # No `head -n 1` here: closing the pipe early would hand docker compose a
  # SIGPIPE, and pipefail would turn that into a spurious failure.
  cid="$(docker compose ps --quiet homepage 2>/dev/null || true)"
  cid="${cid%%[[:space:]]*}"
  [ -n "${cid}" ] || die "could not find the homepage container; check: docker compose ps homepage"

  # Compare hashes, never values: the container's own env is dumped through a
  # pipe into a variable, and only the digest is ever printed or compared.
  container_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}")"
  env_line="$(printf '%s\n' "${container_env}" | grep "^${KEY}=" || true)"
  [ -n "${env_line}" ] || die "the homepage container has no ${KEY} entry; check: docker compose config"

  in_container="${env_line#"${KEY}="}"
  if [ "$(hash_of "${in_container}")" = "${want_hash}" ]; then
    echo "verified: the running container has the new password"
  else
    die "the running container still has the old password — the recreate did not take; check: docker compose logs homepage"
  fi
fi

echo
echo "note: existing dashboard sessions stay valid until they expire — the session"
echo "cookie is signed by HOMEPAGE_AUTH_SECRET, which did not change."
