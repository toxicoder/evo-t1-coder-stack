#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## infisical.sh - move the stack's credentials between the vault and the .env file.
#
# The stack reads every credential out of one dotenv file: compose interpolates
# `${VAR:-default}` against the `.env` beside docker-compose.yml, and nothing in the
# compose layer ever opens a connection to a secrets service. That property is worth
# keeping - an unreachable vault must not be able to stop `up` - so this CLI does not
# replace the dotenv chain. It feeds it. `pull` writes the managed keys into `.env` and
# compose reads that file exactly as it always has.
#
# What that buys, and what it costs:
#   Adopted    `INFISICAL_ENABLED=true`. The three `secrets`-profile containers become
#              part of the project, the runner CLIs pass the profile on every compose
#              invocation, and the minting loop in scripts/bootstrap.sh seeds through the
#              vault instead of `openssl rand` alone.
#   Not        The shipped state. `INFISICAL_ENABLED` is absent or falsy, so
#              `compose_infisical_args` prints nothing, none of the three containers is
#              ever addressed, and every mutating verb here refuses with a `note:` that
#              names the flag. Off is deliberate: a subsystem nobody opted into must not
#              be able to hold the stack's credentials hostage.
#
# The twelve keys this owns are data, not code: infisical/managed-secrets.txt is the one
# inventory, read through `infisical_managed_keys`. The count is asserted, because a
# silently-short inventory would leave a credential outside the vault while still
# reporting a clean sync.
#
# The credential rules that shape every function here, all inherited from
# scripts/dashboard-password.sh:
#   - a value never travels in argv, so it cannot be read out of another user's `ps`;
#   - a value never appears in a log line, including a failure line;
#   - a file that holds one is mode 600 and is removed on the failure path too;
#   - a write is verified by hashing the value read back before anything claims ok;
#   - a key the vault does not carry is a warning, never a blanked line. The second
#     half of that rule is what stops a half-seeded project from locking every service
#     out of its own credential.
#
# Read scripts/lib/infisical.sh before changing anything below: it holds every call that
# touches the CLI binary, and this file deliberately never runs `infisical` itself. That
# is how `INFISICAL_DOMAIN` gets set on every single invocation - self-hosted dials
# Infisical's US cloud when it is missing, which reads as "your secrets vanished" rather
# than as a misconfiguration.
#
# Usage: bazelisk run //scripts:infisical -- <subcommand> [options]   (from any cwd)
#   bazelisk run //scripts:infisical -- check
#   bazelisk run //scripts:infisical -- pull
#   INFISICAL_ENABLED=true bazelisk run //scripts:infisical -- status
#
# Subcommands:
#   status        what this box is configured to do: flag, profile argv, port, URL,
#                 inventory size, and which required keys are still empty. Read-only.
#   check         the diagnostic to run first. Reports the same ground as `status` plus
#                 whether the CLI binary, the vault reachability, and the machine
#                 identity actually work. Always exits 0 on a box that simply never
#                 adopted Infisical: a check that fails on an unadopted stack is a check
#                 nobody runs.
#   install-cli   fetch the pinned release and install the binary. Never pipes a
#                 download into a shell.
#   bootstrap     create the super admin, the organization and the machine identity on a
#                 fresh instance, then record the identifiers into the env file.
#   push          seed or migrate the managed keys from the env file into the vault.
#   pull          reconcile the managed keys from the vault into the env file.
#   rotate KEY    mint a fresh value for one managed key, write it to the vault first and
#                 to the env file only once the vault accepted it.
#   run -- CMD    exec a command with the project's secrets in its environment.
#   -h, --help    print this usage and exit 0
#
# Options:
#   --env-file PATH   the dotenv file to read and write (default: $ENV_FILE, else .env in
#                     the resolved checkout, which is the file compose itself reads)
#   -h, --help        print this usage and exit 0
#
# Exit codes: 0 when the verb did what it was asked, and always for `status` and `check`;
# 1 when a real operation failed - the CLI errored, a read-back hash disagreed, a rotate
# target is not a managed key; 2 on a usage error, always before any work starts; and the
# lib's own 5 when the flag is off or a prerequisite is missing, which for a mutating verb
# is the refusal, printed as a `note:` that names the key to set.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function resolve_root
# Print the checkout this run reads its inventory and env file from.
# Globals:
#   SELF_DIR
# Arguments:
#   None
# Outputs:
#   The checkout root on stdout
# Returns:
#   0 when a docker-compose.yml marker proved one out; 5 otherwise
resolve_root() {
  resolve_checkout "${SELF_DIR}" || return 5
}

# @function find_lib
# Print the path one sourced lib is reachable from: the resolved root first, then this
# script's own directory, because under `bazelisk run` both halves live in a runfiles
# copy that has to be probed for rather than assumed.
# Globals:
#   SELF_DIR
# Arguments:
#   $1 - lib file name, relative to the lib directory
#   $2 - resolved repo root, possibly empty
# Outputs:
#   The lib path on stdout, or one complaint line on stderr
# Returns:
#   0 when the lib was found, 1 otherwise
find_lib() {
  local name="$1" root="${2:-}" candidate
  local -a candidates=()
  if [ -n "${root}" ]; then
    candidates+=("${root}/scripts/lib/${name}")
  fi
  candidates+=("${SELF_DIR}/lib/${name}")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: %s is not reachable from %s\n' "${name}" "${candidates[*]}" >&2
  return 1
}

# Each lib is sourced on its own line and named on that line, so the dependency gate in
# //tests reads the closure straight off the sources. common.sh comes first and from
# SELF_DIR alone: it owns resolve_checkout, which is what finds the checkout, so the
# root cannot be an input to that first probe. Each reachability is proved one line
# before its source so a missing lib is one error and an exit, not bash's own complaint
# about an empty argument.
find_lib common.sh >/dev/null || exit 1
# shellcheck source=/dev/null disable=SC1091
source "$(find_lib common.sh)"

ROOT_DIR="$(resolve_root || true)"

find_lib infisical.sh "${ROOT_DIR}" >/dev/null || exit 1
# shellcheck source=/dev/null disable=SC1091
source "$(find_lib infisical.sh "${ROOT_DIR}")"

find_lib bootstrap.sh "${ROOT_DIR}" >/dev/null || exit 1
# shellcheck source=/dev/null disable=SC1091
source "$(find_lib bootstrap.sh "${ROOT_DIR}")"

# No --json mode here: every verb prints a table a person reads, and a JSON
# answer about a credential would be an answer that leaks it in a different font.
unset JSON_MODE

# Keys that must hold a value before anything can talk to the vault. Named here
# rather than inline so `check` and every mutating verb ask the same question and
# print the same missing key.
REQUIRED_KEYS="INFISICAL_URL INFISICAL_PROJECT_ID INFISICAL_ENVIRONMENT INFISICAL_MACHINE_IDENTITY_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"

# @function usage
# Print the subcommand and option summary.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   Always 0
usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# @function missing_keys
# Print the required keys that the env file leaves empty.
# Globals:
#   REQUIRED_KEYS
# Arguments:
#   $1 - env file to read
# Outputs:
#   One key name per line on stdout
# Returns:
#   0 always; emptiness is the caller's judgement
missing_keys() {
  local env_file="${1:-.env}" key value
  for key in ${REQUIRED_KEYS}; do
    value="$(infisical_env_value "${key}" "${env_file}")"
    if [ -z "${value}" ]; then
      printf '%s\n' "${key}"
    fi
  done
  return 0
}

# @function report_missing
# Print one note per required key that is still empty.
# Globals:
#   REQUIRED_KEYS
# Arguments:
#   $1 - env file to read
# Outputs:
#   One `note:` line per empty key
# Returns:
#   0 always
report_missing() {
  local missing
  missing="$(missing_keys "${1:-.env}")"
  if [ -z "${missing}" ]; then
    return 0
  fi
  while IFS= read -r missing; do
    [ -n "${missing}" ] || continue
    note "${missing} is empty; set it in ${1:-.env} before this verb can reach the vault"
  done <<<"${missing}"
}

# @function refusal
# Explain that the tier is switched off and say which key turns it on.
# Globals:
#   None
# Arguments:
#   $1 - the verb that was refused
# Outputs:
#   One `note:` line
# Returns:
#   Always 0
refusal() {
  note "$1 refused: INFISICAL_ENABLED is off. Set INFISICAL_ENABLED=true in .env to adopt the vault, then re-run."
  return 0
}

# @function lib_status
# Turn a lib return code into the printed verdict this CLI reports.
# Globals:
#   SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL (through ok/warn/fail_item)
# Arguments:
#   $1 - the verb's own name
#   $2 - its exit status
# Outputs:
#   An ok, warning, or error line, or the refusal note
# Returns:
#   The code the caller should exit with: 0 for a job that ran, 5 for a refusal the
#   flag caused, and 1 for a real failure. A script that drives this CLI needs to tell
#   "the vault is switched off" apart from "the vault said no", and a bare 0 for both
#   would let a half-adopted stack look healthy.
lib_status() {
  local verb="$1" status="$2"
  case "${status}" in
    0)
      ok "${verb}"
      return 0
      ;;
    5)
      refusal "${verb}"
      return 5
      ;;
    *)
      err "${verb} failed (exit ${status})"
      fail_item "${verb}"
      return 1
      ;;
  esac
}

# @function cmd_status
# Print what this box is configured to do, without contacting anything.
# Globals:
#   ROOT_DIR, ENV_FILE
# Arguments:
#   $1 - env file
# Outputs:
#   Sections naming the flag, the profile argv, the port, the URL, the inventory
#   size, and the empty required keys
# Returns:
#   Always 0
cmd_status() {
  local env_file="$1" profile_args key_count url
  section "Status"

  if infisical_enabled "${env_file}"; then
    log "INFISICAL_ENABLED: on"
  else
    log "INFISICAL_ENABLED: off (the shipped default)"
  fi

  profile_args="$(compose_infisical_args "${env_file}")"
  if [ -n "${profile_args}" ]; then
    log "compose profile argv: ${profile_args}"
  else
    log "compose profile argv: (none - the three secrets services are not addressed)"
  fi

  url="$(infisical_env_value INFISICAL_URL "${env_file}")"
  log "vault URL: ${url:-http://127.0.0.1:8182 (the compose default)}"

  key_count="$(infisical_managed_keys | grep -c . || true)"
  log "managed keys: ${key_count}"

  report_missing "${env_file}"
  ok "status"
  return 0
}

# @function cmd_check
# Run every precondition and report each one separately.
# Globals:
#   ROOT_DIR, ENV_FILE
# Arguments:
#   $1 - env file
# Outputs:
#   One line per precondition, then the summary
# Returns:
#   Always 0: this is a diagnostic, and a stack that never adopted the vault is a
#   healthy answer rather than a failure
cmd_check() {
  local env_file="$1" key_count cli_bin
  section "Check"

  if infisical_enabled "${env_file}"; then
    ok "flag is on"
  else
    note "INFISICAL_ENABLED is off, so nothing below is reachable yet"
  fi

  if [ -f "${env_file}" ]; then
    ok "env file: ${env_file}"
  else
    note "no env file at ${env_file}; a full bootstrap run creates it from .env.sample"
  fi

  key_count="$(infisical_managed_keys | grep -c . || true)"
  if [ "${key_count}" = "12" ]; then
    ok "inventory: 12 managed keys"
  else
    warn "inventory: ${key_count} keys, expected 12 - infisical/managed-secrets.txt is short or unreadable"
  fi

  report_missing "${env_file}"

  phase "the CLI binary"
  if cli_bin="$(infisical_cli_bin)"; then
    ok "CLI: ${cli_bin}"
  else
    note "no Infisical CLI installed; run: bazelisk run //scripts:infisical -- install-cli"
    summary "check"
    return 0
  fi

  if [ -n "$(missing_keys "${env_file}")" ]; then
    note "skipped the vault probe: a required key is still empty"
    summary "check"
    return 0
  fi

  phase "the machine identity"
  if infisical_login "${env_file}" >/dev/null 2>&1; then
    ok "universal auth exchanged a token"
  else
    warn "the machine identity could not exchange a token; check the client id and secret, and that the vault answers"
  fi

  summary "check"
  return 0
}

# @function cmd_install_cli
# Install the pinned CLI binary.
# Globals:
#   ENV_FILE
# Arguments:
#   $1 - env file
# Outputs:
#   phase and ok lines from the lib, naming only the URL, version and path
# Returns:
#   0 on success, 1 on a failed install, 5 when a prerequisite such as the pinned
#   version is missing
cmd_install_cli() {
  local env_file="$1" status=0 rc=0
  section "Install the CLI"
  phase "fetch the pinned release"
  infisical_install_cli || status=$?
  lib_status "install-cli" "${status}" || rc=$?
  summary "install-cli"
  return "${rc}"
}

# @function cmd_bootstrap
# Create the instance's admin, organization and machine identity.
# Globals:
#   ENV_FILE
# Arguments:
#   $1 - env file
# Outputs:
#   The lib's phase and ok lines, then the summary
# Returns:
#   0 on success or on an already-bootstrapped instance; 1 on a real failure; 5 when
#   the flag is off
cmd_bootstrap() {
  local env_file="$1" status=0 rc=0
  section "Bootstrap the instance"
  if ! infisical_enabled "${env_file}"; then
    refusal "bootstrap"
    summary "bootstrap"
    return 5
  fi
  phase "create the admin, the organization and the machine identity"
  infisical_bootstrap "${env_file}" || status=$?
  lib_status "bootstrap" "${status}" || rc=$?
  summary "bootstrap"
  return "${rc}"
}

# @function cmd_push
# Seed the vault from the env file.
# Globals:
#   ENV_FILE
# Arguments:
#   $1 - env file
# Outputs:
#   The lib's per-key warnings and count-only ok line, then the summary
# Returns:
#   0 on success; 1 on a failed set or a disagreeing read-back hash; 5 when the flag is
#   off, which is the refusal
cmd_push() {
  local env_file="$1" status=0 rc=0
  section "Push to the vault"
  if ! infisical_enabled "${env_file}"; then
    refusal "push"
    summary "push"
    return 5
  fi
  phase "seed the managed keys from ${env_file}"
  infisical_push "${env_file}" || status=$?
  lib_status "push" "${status}" || rc=$?
  summary "push"
  return "${rc}"
}

# @function cmd_pull
# Reconcile the env file from the vault.
# Globals:
#   ENV_FILE
# Arguments:
#   $1 - env file
# Outputs:
#   The lib's per-key warnings and count-only ok line, then the summary
# Returns:
#   0 on success; 1 on a failed export or a disagreeing read-back hash; 5 when the flag
#   is off, which is the refusal
cmd_pull() {
  local env_file="$1" status=0 rc=0
  section "Pull into ${env_file}"
  if ! infisical_enabled "${env_file}"; then
    refusal "pull"
    summary "pull"
    return 5
  fi
  phase "export the managed keys"
  infisical_pull "${env_file}" || status=$?
  lib_status "pull" "${status}" || rc=$?
  summary "pull"
  return "${rc}"
}

# @function cmd_rotate
# Mint one managed key, vault first, env file second.
# Globals:
#   ENV_FILE, TMPDIR (the root the minted value's temp is created under)
# Arguments:
#   $1 - env file
#   $2 - the key to rotate
# Outputs:
#   One ok line naming only the key, then the summary
# Returns:
#   0 when both halves landed; 1 when the key is not managed, the vault refused the
#   write, or the env file disagrees afterwards; 5 when the flag is off
cmd_rotate() {
  local env_file="$1" key="${2:-}" status=0 value_file
  section "Rotate one key"

  if [ -z "${key}" ]; then
    die "rotate names one key, for example: rotate LITELLM_MASTER_KEY"
  fi
  if ! infisical_managed_keys | grep -qx "${key}"; then
    err "${key} is not a managed key; see infisical/managed-secrets.txt for the twelve that are"
    fail_item "rotate ${key}"
    summary "rotate"
    return 1
  fi
  if ! infisical_enabled "${env_file}"; then
    refusal "rotate"
    summary "rotate"
    return 5
  fi

  phase "mint a fresh value for ${key}"
  # The template is absolute on purpose: a bare "infisical-rotate" resolves against
  # the cwd, which on a host run is the checkout, so the freshly minted secret would
  # land as litter an operator could commit. The seam refuses a relative template.
  infisical_mktemp "${TMPDIR:-/tmp}/infisical-rotate"
  value_file="${INFISICAL_MKTEMP}"
  # No trailing newline: the file is handed to the CLI as KEY=@file and the value is
  # stored byte for byte, so a newline here would become part of the secret.
  printf '%s' "$(gen_secret_for "${key}")" >"${value_file}"
  chmod 600 "${value_file}"

  phase "write the vault first, so .env never holds what the vault does not"
  if ! infisical_secret_set "${key}" "${value_file}" "${env_file}"; then
    err "${key}: the vault refused the write, so ${env_file} was left untouched"
    fail_item "rotate ${key}"
    summary "rotate"
    return 1
  fi

  phase "then the env file"
  infisical_write_env "${key}" "$(cat "${value_file}")" "${env_file}" || status=$?
  if [ "${status}" -ne 0 ]; then
    err "${key}: the vault holds the new value but ${env_file} does not; re-run pull to converge"
    fail_item "rotate ${key}"
    summary "rotate"
    return 1
  fi

  ok "rotated ${key}"
  note "compose reads ${env_file} only when a container is recreated; the affected service restarts on the next up"
  summary "rotate"
  return 0
}

# @function cmd_run
# Exec a command with the project's secrets in its environment.
# Globals:
#   ENV_FILE
# Arguments:
#   $1 - env file
#   $2.. - the command and its own arguments
# Outputs:
#   Whatever the command prints
# Returns:
#   The command's status; 0 with a note when the flag is off
cmd_run() {
  local env_file="$1"
  shift
  section "Run under the vault"
  if [ "$#" -eq 0 ]; then
    die "run names a command: run -- env"
  fi
  if ! infisical_enabled "${env_file}"; then
    refusal "run"
    summary "run"
    return 0
  fi
  local project_id environment
  project_id="$(infisical_env_value INFISICAL_PROJECT_ID "${env_file}")"
  if [ -z "${project_id}" ]; then
    err "INFISICAL_PROJECT_ID is empty; run //scripts:infisical bootstrap first"
    fail_item "run"
    summary "run"
    return 1
  fi
  environment="$(infisical_env_value INFISICAL_ENVIRONMENT "${env_file}")"
  [ -n "${environment}" ] || environment="prod"
  infisical_run_cli sm run --env="${environment}" --projectId="${project_id}" -- "$@"
}

ENV_FILE_ARG=""
VERB=""
RUN_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      [ "$#" -ge 2 ] || die "--env-file names a file"
      ENV_FILE_ARG="$2"
      shift 2
      ;;
    --env-file=*)
      ENV_FILE_ARG="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        RUN_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      if [ -z "${VERB}" ]; then
        VERB="$1"
      else
        RUN_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -z "${VERB}" ]; then
  usage
  exit 0
fi

ROOT_DIR="${ROOT_DIR:-$(resolve_root || true)}"
ENV_FILE="${ENV_FILE_ARG:-${ENV_FILE:-${ROOT_DIR:-.}/.env}}"

case "${VERB}" in
  status) cmd_status "${ENV_FILE}" ;;
  check) cmd_check "${ENV_FILE}" ;;
  install-cli) cmd_install_cli "${ENV_FILE}" ;;
  bootstrap) cmd_bootstrap "${ENV_FILE}" ;;
  push) cmd_push "${ENV_FILE}" ;;
  pull) cmd_pull "${ENV_FILE}" ;;
  rotate) cmd_rotate "${ENV_FILE}" "${RUN_ARGS[*]-}" ;;
  run) cmd_run "${ENV_FILE}" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} ;;
  *)
    err "unknown subcommand: ${VERB}"
    usage
    exit 2
    ;;
esac
