#!/usr/bin/env bats
#
# ## infisical.bats - hermetic coverage for scripts/infisical.sh.
#
# The operator contract pinned here: every verb that touches the vault answers the
# flag before it touches anything else, and the refusal is a note that names the key
# to set rather than a stack trace; an unknown verb is answered before any work
# starts; `status` and `check` read like a healthy box that never adopted the vault
# rather than like a failure; the inventory file is the only list any verb consults,
# so a key the env file does not hold is a named warning and never a blanked line;
# rotate writes the vault BEFORE .env and leaves .env byte-identical when the vault
# says no; and no secret VALUE ever rides argv or a printed line - the stub's argv
# log is the witness, which is why the minted value is asserted absent from it. The
# value rotate mints is created under TMPDIR, never the directory the operator was
# standing in, and every managed key the inventory names has an assignment in both
# dotenv twins -- the invariant that file states for itself and no other gate
# checks. The fifteen functions the CLI declares are pinned by name, each with its
# # @function block, which is also the reference tests/shell_inventory.sh counts on.
#
# Hermetic by construction. Every call is one process:
#   run --separate-stderr "${BASH}" "${SCRIPT}" --env-file "${ENV_FILE}" <verb>
# with PATH shadowed by tests/bats/tool_stubs (infisical, curl, tar, timeout) and
# HOME, TMPDIR, XDG_DATA_HOME and ENV_FILE pinned inside BATS_TEST_TMPDIR, so nothing
# reaches a server, a real ~/.infisical, the checkout's own .env, or any path outside
# this test's tree. The coreutils the CLI pipes through stay the host's, because a
# suite that hid those would test a PATH no operator runs on. --env-file is passed on
# every call as well as exported through ENV_FILE: the CLI's last-resort default is
# the checkout's .env, and no test may read or write that file.
#
# The whole suite skips while the CLI is absent: a suite for a file that does not exist
# yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_infisical_test   (from any cwd)
# Safety: stubs and canned dotenv bodies only. No live service, no Docker, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
INVENTORY=""
SCRATCH=""

# CLI_FUNCTIONS - every function scripts/infisical.sh declares, in the order it declares
# them. The list is literal on purpose: tests/shell_inventory.sh fails any production
# function no suite under tests/ names on a non-comment line, and this suite is the one
# that drives this CLI, so the names live here. A function added, renamed or dropped in
# the CLI fails the test below rather than silently leaving the gate.
CLI_FUNCTIONS=(resolve_root find_lib usage missing_keys report_missing refusal lib_status
  cmd_status cmd_check cmd_install_cli cmd_bootstrap cmd_push cmd_pull cmd_rotate cmd_run)

# setup - resolve the checkout, shadow the CLI and the three tools the installer
# shells out to, and pin every path this CLI can write inside the test's tree.
# Globals:
#   REPO_ROOT, SCRIPT, LIB, INVENTORY, SCRATCH, STUB_LOG, PATH, ENV_FILE, HOME,
#   TMPDIR, XDG_DATA_HOME
# Arguments:
#   None
# Outputs:
#   The private bin/ and this test's scratch tree
# Returns:
#   0, or a skip when the CLI, the seam, the inventory, or a stub copy is missing
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  SCRIPT="${REPO_ROOT}/scripts/infisical.sh"
  LIB="${REPO_ROOT}/scripts/lib/infisical.sh"
  INVENTORY="${REPO_ROOT}/infisical/managed-secrets.txt"
  [ -f "${SCRIPT}" ] || skip "scripts/infisical.sh is absent"
  [ -f "${LIB}" ] || skip "scripts/lib/infisical.sh is absent"
  [ -r "${INVENTORY}" ] || skip "infisical/managed-secrets.txt is absent"
  local stub
  for stub in infisical curl tar timeout; do
    [ -f "${STUB_BIN_DIR}/${stub}" ] || skip "the ${stub} stub is not in the tree"
  done

  SCRATCH="${BATS_TEST_TMPDIR}/scratch"
  mkdir -p "${SCRATCH}/home"
  use_stubs infisical curl tar timeout
  # Nothing may reach outside the test: the installer's target is under
  # XDG_DATA_HOME, the CLI's own config under HOME, and every lib temp (the pull
  # export and the rotate value alike) under TMPDIR, which is why the rotate tests
  # cd into their own cwd dir rather than into TMPDIR -- a template that resolved
  # against the cwd would then leave its mark where this suite can see it.
  export HOME="${SCRATCH}/home"
  export TMPDIR="${SCRATCH}"
  export XDG_DATA_HOME="${SCRATCH}/xdg"
  export ENV_FILE="${SCRATCH}/.env"
  # Nothing in this suite may reach a real checkout's .env or a real vault through an
  # ambient value: the flag, every INFISICAL_* name the seam reads, and COMPOSE_FILE
  # (which decides the default env file) are cleared for every test.
  unset COMPOSE_FILE INFISICAL_ENABLED INFISICAL_URL INFISICAL_PORT INFISICAL_DOMAIN
  unset INFISICAL_PROJECT_ID INFISICAL_ENVIRONMENT INFISICAL_CLI_BIN INFISICAL_CLI_VERSION
  unset INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
  unset INFISICAL_MACHINE_IDENTITY_ID INFISICAL_ADMIN_EMAIL INFISICAL_ADMIN_PASSWORD
  unset INFISICAL_ORGANIZATION INFISICAL_ORGANIZATION_ID INFISICAL_TMP_FILES INFISICAL_MKTEMP
  unset INFISICAL_EXIT_TRAP_SET INFISICAL_CLI_ASSET INFISICAL_CLI_RELEASE_BASE
  # And no knob of the stub survives from one test into the next.
  unset STUB_INFISICAL_TOKEN STUB_INFISICAL_DUMP STUB_INFISICAL_EXPORT_RC
  unset STUB_INFISICAL_SET_RC STUB_INFISICAL_DELETE_RC STUB_INFISICAL_BOOTSTRAP
  unset STUB_INFISICAL_BOOTSTRAP_RC STUB_INFISICAL_LOGIN_RC STUB_INFISICAL_VERSION
  unset STUB_INFISICAL_RC STUB_CURL_OUT STUB_CURL_RC STUB_TAR_LIST STUB_TAR_LIST_RC
}

# write_env - lay down a dotenv fixture with one line per argument.
# Arguments:
#   $1 - the file; $2.. - the lines to write
# Outputs:
#   The file on disk
# Returns:
#   0
write_env() {
  local file="$1"
  shift
  : >"${file}"
  local line
  for line in "$@"; do
    printf '%s\n' "${line}" >>"${file}"
  done
}

# vault_on - lay down the .env a configured stack has, and print its path. Every
# mutating verb short-circuits on INFISICAL_ENABLED, so a sync test that forgot this
# would prove only the off branch while reading as a pass. The credential slots hold
# inert stand-ins, kept short so no fixture in this file reads as a real value.
# Arguments:
#   $1 - the path to write (default: this test's ENV_FILE)
# Outputs:
#   The path of the file it wrote
# Returns:
#   0
vault_on() {
  local file="${1:-${ENV_FILE}}"
  write_env "${file}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_PROJECT_ID=prj-1" "INFISICAL_ENVIRONMENT=prod" \
    "INFISICAL_MACHINE_IDENTITY_ID=idn-1" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid-inert" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csec-inert"
  printf '%s\n' "${file}"
}

# run_cli - run the CLI as one process against this test's env file. `run` sets the
# test's status, output and stderr, so it is never called inside a substitution.
# Arguments:
#   $1.. - the verb and its own arguments
# Outputs:
#   The CLI's streams, captured into status/output/stderr
# Returns:
#   The CLI's exit status, through `status`
run_cli() {
  run --separate-stderr "${BASH}" "${SCRIPT}" --env-file "${ENV_FILE}" "$@"
}

# cli_managed_keys - print the stack's secret surface through the seam's own reader,
# so this suite never retypes the twelve names and cannot drift from the file.
# Arguments:
#   None
# Outputs:
#   One KEY per line on stdout
# Returns:
#   The reader's status
cli_managed_keys() {
  "${BASH}" -c "source '${LIB}' >/dev/null 2>&1; infisical_managed_keys"
}

# required_keys - print the config keys the CLI insists on, read off the CLI's own
# REQUIRED_KEYS assignment for the same no-drift reason.
# Arguments:
#   None
# Outputs:
#   One KEY per line on stdout
# Returns:
#   0 when the assignment was found, 1 otherwise
required_keys() {
  local line
  line="$(grep -m1 '^REQUIRED_KEYS=' "${SCRIPT}")" || return 1
  line="${line#*\"}"
  line="${line%\"}"
  # shellcheck disable=SC2086
  printf '%s\n' ${line}
}

# read_key - print one key's value out of a dotenv file, byte for byte.
# Arguments:
#   $1 - the file; $2 - the key
# Outputs:
#   The value on stdout
# Returns:
#   0
read_key() {
  local file="$1" key="$2" line
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${key}"=*) printf '%s' "${line#"${key}="}" ;;
    esac
  done <"${file}"
}

# key_list - collect the CLI's own key list into the named array.
# Arguments:
#   $1 - name of the array to fill; $2 - "managed" or "required"
# Outputs:
#   Nothing
# Returns:
#   1 when the source named no key at all
key_list() {
  local -n into="$1"
  local kind="$2" key
  while IFS= read -r key; do
    if [ -n "${key}" ]; then
      into+=("${key}")
    fi
  done < <(
    if [ "${kind}" = "managed" ]; then
      cli_managed_keys
    else
      required_keys
    fi
  )
  [ "${#into[@]}" -gt 0 ]
}

# dotenv_missing_keys - print the managed keys a dotenv file never assigns. The
# inventory's own header states the invariant ("Every key must also exist in
# .env.example"): Infisical feeds .env on a pull and compose keeps interpolating
# .env, so a managed key with no line in the twins is a key bootstrap never mints
# (it only mints a line still reading =change-me) and no service ever receives.
# The inventory reader's `^[A-Z0-9_]+$` filter runs first, so no key name can
# reach grep as a pattern.
# Arguments:
#   $1 - the inventory file; $2 - the dotenv file to compare it against
# Outputs:
#   One KEY per line on stdout, for each managed key ${2} does not assign
# Returns:
#   0 when both files were readable; 1 when either is not, with the reason on stderr
dotenv_missing_keys() {
  local inventory="$1" dotenv="$2" key
  [ -r "${inventory}" ] || {
    printf 'inventory is not readable: %s\n' "${inventory}" >&2
    return 1
  }
  [ -r "${dotenv}" ] || {
    printf 'dotenv is not readable: %s\n' "${dotenv}" >&2
    return 1
  }
  while IFS= read -r key; do
    grep -Eq "^${key}[[:space:]]*=" "${dotenv}" || printf '%s\n' "${key}"
  done < <(grep -E '^[A-Z0-9_]+$' "${inventory}")
}

# summary_line - print the closing summary line out of a captured stdout.
# Arguments:
#   $1 - the captured output
# Outputs:
#   The `summary: ...` line
# Returns:
#   0
summary_line() {
  printf '%s\n' "$1" | grep '^summary: '
}

# ---------------------------------------------------------------------------
# The dispatcher: usage is answered before any work starts.
# ---------------------------------------------------------------------------

@test "dispatcher: --help exits 0 and names all eight verbs and both options" {
  run_cli --help
  [ "${status}" -eq 0 ]
  local verb
  for verb in status check install-cli bootstrap push pull rotate run; do
    assert_match "the usage names the ${verb} verb" "^  ${verb} " "${output}"
  done
  assert_match "the usage names the env-file option" '^  --env-file PATH' "${output}"
  assert_match "the usage names the help option" '^  -h, --help' "${output}"
  assert_match "the usage states the exit codes" '^Exit codes: 0 when the verb' "${output}"
  assert_eq "usage alone execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "dispatcher: no arguments prints the usage block on stdout" {
  # This branch prints the table and exits 0; the suite pins the table's content,
  # which is the half an operator actually reads.
  run_cli
  assert_eq "no verb is answered with the usage" "0" "${status}"
  assert_match "the block names the CLI's own entry point" \
    'Usage: bazelisk run //scripts:infisical -- <subcommand>' "${output}"
  assert_match "and the rotate verb" '^  rotate KEY' "${output}"
  assert_eq "and execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "dispatcher: an unknown verb exits 2, prints the usage, and does no work" {
  run_cli frobnicate
  [ "${status}" -eq 2 ]
  assert_match "the complaint names the verb" \
    '^error: unknown subcommand: frobnicate$' "${stderr:-}"
  assert_match "the usage block comes with the complaint" \
    'Usage: bazelisk run //scripts:infisical' "${output}"
  assert_eq "a typo execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "dispatcher: a malformed argument is refused before any work starts" {
  run_cli --bogus
  [ "${status}" -ne 0 ]
  assert_match "the unknown option is named" \
    '^error: unknown option: --bogus \(try --help\)$' "${stderr:-}"

  run_cli --env-file
  [ "${status}" -ne 0 ]
  assert_match "a flag that lost its value says so" '^error: --env-file names a file$' "${stderr:-}"

  # The --env-file=FORM is the same flag and has to reach the same place. The proof it
  # reached that file is the decision it changes: the same argv against a file with the
  # flag on is no longer a refusal.
  local envf="${SCRATCH}/equals.env"
  write_env "${envf}" "INFISICAL_ENABLED=false"
  run --separate-stderr "${BASH}" "${SCRIPT}" "--env-file=${envf}" push
  [ "${status}" -eq 5 ]
  assert_match "the = form is refused off the flag in that file" \
    '^note: push refused: INFISICAL_ENABLED is off\.' "${output}"
  assert_eq "and none of it execs the CLI" "0" "$(stub_log_count infisical)"
  write_env "${envf}" "INFISICAL_ENABLED=true"
  run --separate-stderr "${BASH}" "${SCRIPT}" "--env-file=${envf}" push
  [ "${status}" -eq 0 ]
  assert_not_match "the same argv on a file that turned the flag on is no refusal" \
    'push refused: INFISICAL_ENABLED is off' "${output}"
  assert_match "and that run takes the push path" '^ok: push$' "${output}"
}

# ---------------------------------------------------------------------------
# status: the read-only table, on both branches of the flag.
# ---------------------------------------------------------------------------

@test "status: an unadopted box reads as the shipped default and execs no CLI" {
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false"
  run_cli status
  [ "${status}" -eq 0 ]
  assert_match "the section header" '^== Status ==$' "${output}"
  assert_match "the flag is named as the shipped default" \
    '^INFISICAL_ENABLED: off \(the shipped default\)$' "${output}"
  assert_match "the profile argv is spelled as nothing" \
    '^compose profile argv: \(none - the three secrets services are not addressed\)$' "${output}"
  assert_match "the port is named through the compose default URL" \
    '^vault URL: http://127\.0\.0\.1:8182 \(the compose default\)$' "${output}"
  local count
  count="$(cli_managed_keys | grep -c .)"
  assert_eq "the managed-key count comes from the inventory" "managed keys: ${count}" \
    "$(printf '%s\n' "${output}" | grep '^managed keys: ')"
  assert_match "the table closes with its ok line" '^ok: status$' "${output}"
  # cmd_status documents itself as the read-only table (scripts/infisical.sh:263-273):
  # it prints no -> phase line, no warning: line and no closing summary:, and it names
  # neither the CLI binary state nor the project id. Pinned as it is documented; the
  # summary and the phase line are pinned where the CLI does print them (check, push,
  # pull, rotate, install-cli, bootstrap), so a future summary: line here stays green.
  assert_match "an empty required key is a note that names the file" \
    "^note: INFISICAL_URL is empty; set it in ${ENV_FILE} before this verb can reach the vault$" \
    "${output}"
  assert_not_match "a read-only table never reports a failure" '^error: ' "${stderr:-}"
  assert_eq "status execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "status: an adopted box prints the profile argv and no credential value" {
  local envf
  envf="$(vault_on "${ENV_FILE}")"
  printf '%s\n' "LITELLM_MASTER_KEY=master-inert" >>"${envf}"
  run_cli status
  [ "${status}" -eq 0 ]
  assert_match "the flag reads on" '^INFISICAL_ENABLED: on$' "${output}"
  assert_match "the profile argv is the two words compose needs" \
    '^compose profile argv: --profile secrets$' "${output}"
  assert_match "the configured URL is reported" '^vault URL: http://vault:8182$' "${output}"
  # The whole point of the credential rules: a table about secrets prints no secret.
  assert_not_match "the client credential stayed out of the table" 'csec-inert' \
    "${output}${stderr:-}"
  assert_not_match "the managed value stayed out of the table" 'master-inert' \
    "${output}${stderr:-}"
  assert_eq "status execs no CLI even when the flag is on" "0" "$(stub_log_count infisical)"
}

# ---------------------------------------------------------------------------
# check: every precondition counted separately, and a flag-off box is a healthy
# answer rather than a failure.
# ---------------------------------------------------------------------------

@test "check: an unadopted box exits 0 with its summary and never execs the CLI" {
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false"
  run_cli check
  [ "${status}" -eq 0 ]
  assert_match "the section header" '^== Check ==$' "${output}"
  assert_match "the flag is reported as the reason nothing is reachable" \
    '^note: INFISICAL_ENABLED is off, so nothing below is reachable yet$' "${output}"
  assert_match "an env file that exists is an ok" "^ok: env file: ${ENV_FILE}$" "${output}"
  local count
  count="$(cli_managed_keys | grep -c .)"
  assert_eq "the inventory is counted against the number the CLI expects" \
    "ok: inventory: ${count} managed keys" \
    "$(printf '%s\n' "${output}" | grep '^ok: inventory: ')"
  assert_match "the CLI binary is its own phase" '^-> the CLI binary$' "${output}"
  assert_match "the vault probe is skipped while a key is empty" \
    '^note: skipped the vault probe: a required key is still empty$' "${output}"
  assert_eq "the summary counts what the table printed" "summary: 3 ok, 0 warnings, 0 failed" \
    "$(summary_line "${output}")"
  assert_eq "and it matches the ok lines the table printed" "3" \
    "$(printf '%s\n' "${output}" | grep -c '^ok: ')"
  assert_eq "a skipped probe execs no CLI" "0" "$(stub_log_count infisical)"

  # Configured keys with the flag still off: the login probe must refuse on the flag
  # before it reaches the binary, not dial a vault nobody adopted.
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "INFISICAL_ENABLED=false" >>"${ENV_FILE}"
  run_cli check
  [ "${status}" -eq 0 ]
  assert_match "a refused login is a warning, not a failure" \
    '^warning: the machine identity could not exchange a token' "${output}"
  assert_eq "and a refused login still execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "check: the report names exactly the required keys the env file leaves empty" {
  local -a all=()
  key_list all required
  local key present="" absent="" index=0
  for key in "${all[@]}"; do
    if [ "${index}" -lt 3 ]; then
      present="${present}${key}"$'\n'
    else
      absent="${absent}${key}"$'\n'
    fi
    index=$((index + 1))
  done

  # Populate three of them; the rest are what the report owes, by name.
  local -a lines=()
  index=0
  for key in "${all[@]}"; do
    if [ "${index}" -lt 3 ]; then
      lines+=("${key}=set-${index}")
    fi
    index=$((index + 1))
  done
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=true" "${lines[@]}"

  run_cli check
  [ "${status}" -eq 0 ]
  for key in ${absent}; do
    assert_match "${key} is reported as empty" \
      "^note: ${key} is empty; set it in ${ENV_FILE} before this verb can reach the vault$" \
      "${output}"
  done
  for key in ${present}; do
    assert_not_match "${key} holds a value and is not reported" "note: ${key} is empty" "${output}"
  done

  # A file that carries every required key earns no note at all.
  local -a full=()
  for key in "${all[@]}"; do
    full+=("${key}=full")
  done
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=true" "${full[@]}"
  run_cli check
  [ "${status}" -eq 0 ]
  assert_not_match "a complete file earns no empty-key note" 'is empty; set it in' "${output}"
}

@test "check: a configured box counts five ok lines and exchanges the machine identity" {
  vault_on "${ENV_FILE}" >/dev/null
  run_cli check
  [ "${status}" -eq 0 ]
  assert_match "the flag is its own ok" '^ok: flag is on$' "${output}"
  assert_match "the machine identity is its own phase" '^-> the machine identity$' "${output}"
  assert_match "and a token exchange is an ok" '^ok: universal auth exchanged a token$' "${output}"
  assert_eq "every precondition counted" "summary: 5 ok, 0 warnings, 0 failed" \
    "$(summary_line "${output}")"
  local logged
  logged="$(stub_log infisical)"
  assert_match "universal-auth is the method" '--method=universal-auth' "${logged}"
  assert_match "the client id travels as a flag" '--client-id=cid-inert' "${logged}"
  assert_match "the token is asked for plainly" '--plain' "${logged}"

  # The same table with a machine identity that cannot exchange is a warning and a
  # zero exit: a check that fails on a half-seeded vault is a check nobody runs.
  export STUB_INFISICAL_LOGIN_RC=1
  run_cli check
  [ "${status}" -eq 0 ]
  assert_match "the failure is a warning naming what to look at" \
    '^warning: the machine identity could not exchange a token; check the client id and secret' \
    "${output}"
  assert_eq "one precondition moved from ok to warning" "summary: 4 ok, 1 warnings, 0 failed" \
    "$(summary_line "${output}")"
}

@test "check: no CLI on PATH points at install-cli and stops before the vault" {
  if [ -n "$(real_bin infisical)" ]; then
    skip "a real Infisical CLI is on this host's PATH, so the branch cannot be driven"
  fi
  local stripped="${PATH#"${BATS_TEST_TMPDIR}/bin:"}"
  [ "${stripped}" != "${PATH}" ] || {
    echo "the stub directory is not at the head of PATH" >&2
    return 1
  }
  vault_on "${ENV_FILE}" >/dev/null
  run --separate-stderr env PATH="${stripped}" "${BASH}" "${SCRIPT}" \
    --env-file "${ENV_FILE}" check
  [ "${status}" -eq 0 ]
  assert_match "the missing binary names the verb that fixes it" \
    '^note: no Infisical CLI installed; run: bazelisk run //scripts:infisical -- install-cli$' \
    "${output}"
  assert_not_match "the machine identity is never probed without a binary" \
    '^-> the machine identity$' "${output}"
  assert_eq "the summary still closes the table" "summary: 3 ok, 0 warnings, 0 failed" \
    "$(summary_line "${output}")"
  assert_eq "and it counts the three ok lines it printed" "3" \
    "$(printf '%s\n' "${output}" | grep -c '^ok: ')"
}

# ---------------------------------------------------------------------------
# The flag off is the shipped state: every vault verb refuses, by name, with 5.
# ---------------------------------------------------------------------------

@test "flag off: push, pull and bootstrap refuse with 5 and never exec the CLI" {
  local verb
  for verb in push pull bootstrap; do
    write_env "${ENV_FILE}" "INFISICAL_ENABLED=false" "LITELLM_MASTER_KEY=keep-me"
    run_cli "${verb}"
    assert_eq "${verb} refused by the flag exits 5" "5" "${status}"
    assert_match "${verb} names the key that turns the tier on" \
      "^note: ${verb} refused: INFISICAL_ENABLED is off\. Set INFISICAL_ENABLED=true in \.env to adopt the vault, then re-run\.$" \
      "${output}"
    assert_eq "${verb} still closes with its summary" "summary: 0 ok, 0 warnings, 0 failed" \
      "$(summary_line "${output}")"
    assert_eq "${verb} execs no CLI" "0" "$(stub_log_count infisical)"
    run cat "${ENV_FILE}"
    assert_match "${verb} leaves the managed value alone" '^LITELLM_MASTER_KEY=keep-me$' "${output}"
  done

  # The absent key is the shipped default and must read as off, not as unset-means-on.
  write_env "${ENV_FILE}" "STACK_DOMAIN_BASE=example.test"
  run_cli push
  assert_eq "an absent INFISICAL_ENABLED is off" "5" "${status}"
  assert_match "and the refusal says so" 'INFISICAL_ENABLED is off' "${output}"
  assert_eq "the absent-key push execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "flag off: rotate refuses with 5 and leaves the env file byte-identical" {
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false" "LITELLM_MASTER_KEY=keep-me"
  cd "${SCRATCH}"
  local before after
  before="$(sha256sum "${ENV_FILE}")"
  run_cli rotate LITELLM_MASTER_KEY
  [ "${status}" -eq 5 ]
  assert_match "the refusal names the verb and the key to set" \
    '^note: rotate refused: INFISICAL_ENABLED is off\.' "${output}"
  after="$(sha256sum "${ENV_FILE}")"
  assert_eq "a refused rotate moves no byte in .env" "${before}" "${after}"
  assert_eq "a refused rotate execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "rotate: every managed name is accepted on the first attempt, every time" {
  # The managed-key probe used to be `infisical_managed_keys | grep -qx KEY` under the
  # CLI's `set -o pipefail`, so grep -q's early exit killed the reader with SIGPIPE and
  # the verb called a managed key unmanaged on 195 of 200 attempts. This suite did not
  # see it because it retried the verb up to 80 times around exactly that. There is no
  # retry now, and none belongs here: one pass over all twelve names, plus a repeat of
  # one, all taken from the inventory the CLI itself reads. With the flag off the only
  # thing being proven is that each attempt reached the flag check at all, which is the
  # half the probe gates, and no vault is touched.
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false" "LITELLM_MASTER_KEY=keep-me"
  cd "${SCRATCH}"
  local key attempts=0
  while IFS= read -r key; do
    run_cli rotate "${key}"
    [ "${status}" -eq 5 ] || {
      printf '%s was refused before the flag check (status %s): %s\n' \
        "${key}" "${status}" "${stderr:-}" >&2
      return 1
    }
    case "${stderr:-}" in
      *"is not a managed key"*)
        printf '%s is in the inventory and the CLI said otherwise\n' "${key}" >&2
        return 1
        ;;
    esac
    attempts=$((attempts + 1))
  done < <(grep -E '^[A-Z0-9_]+$' "${INVENTORY}")
  [ "${attempts}" -eq 12 ] || {
    printf 'expected twelve names, walked %s\n' "${attempts}" >&2
    return 1
  }
  for key in 1 2 3; do
    run_cli rotate CODER_PG_PASSWORD
    [ "${status}" -eq 5 ] || {
      printf 'CODER_PG_PASSWORD refused on a repeat (status %s): %s\n' \
        "${status}" "${stderr:-}" >&2
      return 1
    }
  done
}

@test "flag off: run prints the refusal, exits 0, and never runs the command" {
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false"
  local child="${SCRATCH}/never-run.sh" marker="${SCRATCH}/child-ran"
  printf '#!/usr/bin/env bash\nprintf %%s\\n ran >"%s"\n' "${marker}" >"${child}"
  chmod 755 "${child}"
  run_cli run -- "${child}"
  [ "${status}" -eq 0 ]
  assert_match "the refusal is printed" \
    '^note: run refused: INFISICAL_ENABLED is off\. Set INFISICAL_ENABLED=true in \.env to adopt the vault, then re-run\.$' \
    "${output}"
  assert_eq "and the table still closes" "summary: 0 ok, 0 warnings, 0 failed" \
    "$(summary_line "${output}")"
  [ ! -e "${marker}" ] || {
    echo "the command ran with the tier switched off" >&2
    return 1
  }
  assert_eq "a refused run execs no CLI" "0" "$(stub_log_count infisical)"
}

# ---------------------------------------------------------------------------
# push: the env file is the source, the read-back is the proof.
# ---------------------------------------------------------------------------

@test "push: seeds the vault, names the absent managed keys, and counts its summary" {
  local -a keys=()
  key_list keys managed
  local key sent=0
  local -a lines=()
  local -a mirror=()
  for key in "${keys[@]}"; do
    if [ "${sent}" -lt 3 ]; then
      lines+=("${key}=pushed-${sent}-inert")
      mirror+=("${key}=pushed-${sent}-inert")
      sent=$((sent + 1))
    fi
  done
  # A configured box: the set path authenticates, so the Universal Auth pair has to
  # be in the file the CLI reads or the push is refused before it sends anything.
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "${lines[@]}" >>"${ENV_FILE}"
  local dump="${SCRATCH}/mirror.env"
  write_env "${dump}" "${mirror[@]}"
  export STUB_INFISICAL_DUMP="${dump}"
  local missing=$((${#keys[@]} - 3))

  cd "${SCRATCH}"
  run_cli push
  [ "${status}" -eq 0 ]
  assert_match "the section header" '^== Push to the vault ==$' "${output}"
  assert_match "the phase names the file, not a value" \
    "^-> seed the managed keys from ${ENV_FILE}$" "${output}"
  assert_match "a key with a value is pushed in bulk" \
    '^-> pushing 3 managed key\(s\) to Infisical$' "${output}"
  assert_match "and the read-back is its own phase" '^-> reading the vault back to confirm it$' \
    "${output}"
  assert_eq "the ok line counts both halves" \
    "ok: pushed 3 managed key(s) to Infisical, ${missing} skipped as absent" \
    "$(printf '%s\n' "${output}" | grep '^ok: pushed ')"
  assert_eq "the verb's own ok line and the lib's are both counted" \
    "summary: 2 ok, ${missing} warnings, 0 failed" "$(summary_line "${output}")"

  # Exactly the absent keys are named, and none of the present ones.
  local named=0
  for key in "${keys[@]}"; do
    if printf '%s' "${output}" |
      grep -q "^warning: ${key} is not in ${ENV_FILE}; nothing pushed for it$"; then
      named=$((named + 1))
    fi
  done
  assert_eq "one warning per managed key the env file does not hold" "${missing}" "${named}"

  # The values travel in a file the CLI names; argv carries the file, never a value.
  local logged
  logged="$(stub_log infisical)"
  assert_match "the bulk set names a file, not a value" '--file=' "${logged}"
  assert_match "the batch is shared and rooted at /" '--type=shared' "${logged}"
  assert_match "the project is named" '--projectId=prj-1' "${logged}"
  assert_not_match "no value rode argv" 'pushed-0-inert' "${logged}"
  local set_file="${STUB_LOG}/infisical-set.txt"
  assert_file_exists "the stub recorded what the batch carried" "${set_file}"
  run grep -c . "${set_file}"
  assert_eq "and it carried exactly the three values" "3" "${output}"
}

@test "push: a fully populated env file reports nothing missing" {
  local -a keys=()
  key_list keys managed
  local key
  local -a mirror=()
  for key in "${keys[@]}"; do
    mirror+=("${key}=value-of-${key}")
  done
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "${mirror[@]}" >>"${ENV_FILE}"
  local dump="${SCRATCH}/mirror.env"
  write_env "${dump}" "${mirror[@]}"
  export STUB_INFISICAL_DUMP="${dump}"

  cd "${SCRATCH}"
  run_cli push
  [ "${status}" -eq 0 ]
  assert_not_match "a complete file earns no absent-key warning" \
    'is not in .*; nothing pushed for it' "${output}"
  assert_eq "every managed key went up" \
    "ok: pushed ${#keys[@]} managed key(s) to Infisical, 0 skipped as absent" \
    "$(printf '%s\n' "${output}" | grep '^ok: pushed ')"
  assert_eq "and the summary carries no warning at all" "summary: 2 ok, 0 warnings, 0 failed" \
    "$(summary_line "${output}")"
  run grep -c . "${STUB_LOG}/infisical-set.txt"
  assert_eq "the batch carried the whole inventory" "${#keys[@]}" "${output}"
}

@test "push: a vault that reads back different fails, naming the key and not the value" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "LITELLM_MASTER_KEY=master-inert" "CODER_PG_PASSWORD=pg-inert" >>"${ENV_FILE}"
  local dump="${SCRATCH}/mirror.env"
  write_env "${dump}" "LITELLM_MASTER_KEY=master-inert" "CODER_PG_PASSWORD=pg-other"
  export STUB_INFISICAL_DUMP="${dump}"

  cd "${SCRATCH}"
  run_cli push
  [ "${status}" -eq 1 ]
  assert_match "the disagreement names the key" \
    '^warning: CODER_PG_PASSWORD differs in the vault after the push' "${output}"
  assert_match "the count of disagreements is printed" \
    '^error: 1 managed key\(s\) did not read back unchanged$' "${stderr:-}"
  assert_match "the verb is recorded as failed" '^  failed: push$' "${output}"
  assert_match "the summary counts one failure" '^summary: 0 ok, [0-9]* warnings, 1 failed$' \
    "${output}"
  assert_not_match "the value the vault holds was never printed" 'pg-other' \
    "${output}${stderr:-}"
  assert_not_match "nor was the value this side pushed" 'master-inert' \
    "${output}${stderr:-}"
  assert_match "the export really ran, so the disagreement is a measurement" \
    'sm secrets export' "$(stub_log infisical)"
}

@test "push: a refused set fails without a read-back, and no project id refuses with 5" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "LITELLM_MASTER_KEY=master-inert" >>"${ENV_FILE}"
  export STUB_INFISICAL_SET_RC=1
  cd "${SCRATCH}"
  run_cli push
  [ "${status}" -eq 1 ]
  assert_match "the failure names the set as the step that failed" \
    '^error: the Infisical set failed; nothing was verified$' "${stderr:-}"
  assert_not_match "a failed set is not followed by a read-back" 'reading the vault back' \
    "${output}"
  assert_eq "the summary counts one failure" "summary: 0 ok, 11 warnings, 1 failed" \
    "$(summary_line "${output}")"

  # Flag on, no project id: the operator owes a bootstrap run, and the exit code is 5.
  # The env file must hold a value, or the verb short-circuits on "nothing to push"
  # before the project id is ever asked for.
  unset STUB_INFISICAL_SET_RC
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "LITELLM_MASTER_KEY=master-inert"
  : >"${STUB_LOG}/infisical.log"
  run_cli push
  [ "${status}" -eq 5 ]
  assert_match "the missing project id is named as the thing to fix" \
    'INFISICAL_PROJECT_ID is empty; run //scripts:infisical bootstrap first' "${stderr:-}"
  assert_eq "a refused push execs no CLI" "0" "$(stub_log_count infisical)"
}

# ---------------------------------------------------------------------------
# pull: the vault is the source, and a key it does not hold is left alone.
# ---------------------------------------------------------------------------

@test "pull: writes what the vault holds and moves no other byte" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "# a comment that must survive" "LITELLM_MASTER_KEY=old-master" \
    "CODER_PG_PASSWORD=keep-me" "UNRELATED=answer" >>"${ENV_FILE}"
  local dump="${SCRATCH}/vault.env"
  write_env "${dump}" "LITELLM_MASTER_KEY=new-master" "CODER_PG_PASSWORD=new-pg"
  export STUB_INFISICAL_DUMP="${dump}"
  local count left
  count="$(cli_managed_keys | grep -c .)"
  left=$((count - 2))

  run_cli pull
  [ "${status}" -eq 0 ]
  assert_match "the section names the file it writes" "^== Pull into ${ENV_FILE} ==$" "${output}"
  assert_match "the export is a phase" "^-> exporting ${count} managed keys from Infisical$" \
    "${output}"
  assert_match "the count line names counts, never values" \
    "^ok: pulled 2 managed key\(s\) into .* \(mode 600\), ${left} left alone$" "${output}"
  assert_eq "the summary counts the lib's ok and the verb's" \
    "summary: 2 ok, ${left} warnings, 0 failed" "$(summary_line "${output}")"
  assert_not_match "no vault value was printed on stdout" 'new-master' "${output}"

  local logged
  logged="$(stub_log infisical)"
  assert_match "the export is dotenv" '--format=dotenv' "${logged}"
  assert_match "imports are included" '--include-imports=true' "${logged}"
  assert_match "the project is named" '--projectId=prj-1' "${logged}"
  assert_match "the environment rides the argv" '--env=prod' "${logged}"

  run cat "${ENV_FILE}"
  assert_match "the key the vault holds moved" '^LITELLM_MASTER_KEY=new-master$' "${output}"
  assert_match "and so did the other" '^CODER_PG_PASSWORD=new-pg$' "${output}"
  assert_match "a config line the vault does not hold kept its bytes" \
    '^INFISICAL_PROJECT_ID=prj-1$' "${output}"
  assert_match "an unmanaged line is untouched" '^UNRELATED=answer$' "${output}"
  assert_match "comments survive a pull" '^# a comment that must survive$' "${output}"
  assert_eq "and the pull appended nothing: one line per key, none duplicated" \
    "11" "$(grep -c . "${ENV_FILE}")"
  assert_eq "the managed key still occurs exactly once" "1" \
    "$(grep -c '^LITELLM_MASTER_KEY=' "${ENV_FILE}")"
}

@test "pull: refuses to blank a key the vault holds empty, and a dead export moves no byte" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "LITELLM_MASTER_KEY=still-good" >>"${ENV_FILE}"
  export STUB_INFISICAL_DUMP="LITELLM_MASTER_KEY="
  run_cli pull
  [ "${status}" -eq 0 ]
  assert_match "the empty vault value is a warning that names the key" \
    '^warning: LITELLM_MASTER_KEY is empty in the Infisical project; refusing to blank it in ' \
    "${output}"
  run cat "${ENV_FILE}"
  assert_match "the live value survives" '^LITELLM_MASTER_KEY=still-good$' "${output}"
  assert_not_match "the key was never blanked" '^LITELLM_MASTER_KEY=$' "${output}"

  # A failed export is a failure, and the file it would have rewritten is untouched.
  printf '%s\n' "LITELLM_MASTER_KEY=would-have-overwritten" >"${SCRATCH}/vault.env"
  export STUB_INFISICAL_DUMP="${SCRATCH}/vault.env"
  export STUB_INFISICAL_EXPORT_RC=1
  local before after
  before="$(sha256sum "${ENV_FILE}")"
  run_cli pull
  [ "${status}" -eq 1 ]
  assert_match "the failure says the file is untouched" \
    "^error: the Infisical export failed; ${ENV_FILE} is untouched$" "${stderr:-}"
  after="$(sha256sum "${ENV_FILE}")"
  assert_eq "a failed export moves no byte in .env" "${before}" "${after}"
}

# ---------------------------------------------------------------------------
# rotate: the vault first, .env second, and the value only ever through a file.
# ---------------------------------------------------------------------------

@test "rotate: a key outside the inventory is refused with 1 and never reaches the CLI" {
  vault_on "${ENV_FILE}" >/dev/null
  cd "${SCRATCH}"
  run_cli rotate NOT_A_MANAGED_KEY
  [ "${status}" -eq 1 ]
  assert_match "the complaint names the key" \
    '^error: NOT_A_MANAGED_KEY is not a managed key; see infisical/managed-secrets.txt for the twelve that are$' \
    "${stderr:-}"
  assert_match "the failure is counted" '^  failed: rotate NOT_A_MANAGED_KEY$' "${output}"
  assert_eq "the summary counts one failure" "summary: 0 ok, 0 warnings, 1 failed" \
    "$(summary_line "${output}")"
  assert_eq "an unmanaged key execs no CLI" "0" "$(stub_log_count infisical)"
}

@test "rotate: the value goes to the vault as KEY=@file before .env moves at all" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "LITELLM_MASTER_KEY=old-master-value" >>"${ENV_FILE}"
  # The rotate temp must land under TMPDIR, not the cwd, so this test stands its
  # cwd apart from TMPDIR: a template that resolved against the cwd would then drop
  # the mode-600 secret here instead, and the two checks below catch it either way.
  mkdir -p "${SCRATCH}/cwd"
  cd "${SCRATCH}/cwd"
  # The stock stub files a set value away only for a KEY=@path word that carries a
  # slash, and this test wants the file's bytes, its mode and the directory it was
  # created in, so it shadows the stub with a wrapper that captures all three before
  # execing the stub. Everything the wrapper writes lives under this test's own tree.
  local capture="${SCRATCH}/capture"
  mkdir -p "${capture}/bin"
  export CAPTURE_DIR="${capture}" STUB_COPY_DIR="${BATS_TEST_TMPDIR}/bin"
  cat >"${capture}/bin/infisical" <<'STUBWRAP'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${CAPTURE_DIR}/argv.txt"
for word in "$@"; do
  case "${word}" in
    *@*)
      target="${word#*@}"
      if [ -f "${target}" ]; then
        cp "${target}" "${CAPTURE_DIR}/value.txt"
        printf '%s\n' "${word}" >"${CAPTURE_DIR}/word.txt"
        stat -c '%a' "${target}" >"${CAPTURE_DIR}/mode.txt"
        dirname "${target}" >"${CAPTURE_DIR}/dir.txt"
      fi
      ;;
  esac
done
exec "${STUB_COPY_DIR}/infisical" "$@"
STUBWRAP
  chmod 755 "${capture}/bin/infisical"
  PATH="${capture}/bin:${PATH}"
  export PATH
  run_cli rotate LITELLM_MASTER_KEY
  [ "${status}" -eq 0 ]
  assert_match "the mint phase names the key only" \
    '^-> mint a fresh value for LITELLM_MASTER_KEY$' "${output}"
  assert_match "the vault is written first" \
    '^-> write the vault first, so \.env never holds what the vault does not$' "${output}"
  assert_match "and the env file is written after" '^-> then the env file$' "${output}"
  local vault_line env_line
  vault_line="$(printf '%s\n' "${output}" | grep -n 'write the vault first' |
    head -n 1 | cut -d: -f1)"
  env_line="$(printf '%s\n' "${output}" | grep -n 'then the env file' |
    head -n 1 | cut -d: -f1)"
  [ -n "${vault_line}" ] && [ -n "${env_line}" ] || {
    echo "one of the two ordering phases was not printed" >&2
    return 1
  }
  [ "${vault_line}" -lt "${env_line}" ] || {
    echo "the env file was written before the vault: ${output}" >&2
    return 1
  }
  assert_match "the ok line names the key and no value" '^ok: rotated LITELLM_MASTER_KEY$' \
    "${output}"
  assert_match "the restart note is printed" \
    '^note: compose reads .* only when a container is recreated' "${output}"
  assert_eq "one ok, nothing to warn about, nothing failed" \
    "summary: 1 ok, 0 warnings, 0 failed" "$(summary_line "${output}")"

  # The value the CLI minted: 32 hex, which is gen_secret_for's default shape. The
  # value file carries the bare secret with no trailing newline (scripts/infisical.sh
  # writes it with printf '%s'), so it is read whole and the byte count pins that.
  local minted in_env
  assert_file_exists "the CLI named a value file the stub could read" \
    "${capture}/value.txt"
  minted="$(cat "${capture}/value.txt")"
  assert_match "the vault accepted a 32-character hex secret" '^[0-9a-f]{32}$' "${minted}"
  assert_eq "and the file is exactly those 32 bytes, no trailing newline" "32" \
    "$(wc -c <"${capture}/value.txt" | tr -d '[:space:]')"
  in_env="$(read_key "${ENV_FILE}" LITELLM_MASTER_KEY)"
  assert_eq ".env holds exactly what the vault was given" "${minted}" "${in_env}"
  assert_match "that value file was created mode 600" '^600$' "$(cat "${capture}/mode.txt")"
  assert_match "the argv word was the @file form" \
    '^LITELLM_MASTER_KEY=@[^[:space:]]*infisical-rotate\.[A-Za-z0-9]+$' \
    "$(cat "${capture}/word.txt")"
  assert_match "and that path is absolute, never a name the cwd resolves" \
    '^LITELLM_MASTER_KEY=@/' "$(cat "${capture}/word.txt")"
  assert_eq "the secret was minted under TMPDIR, not where the operator was standing" \
    "${TMPDIR}" "$(cat "${capture}/dir.txt")"

  local logged
  logged="$(stub_log infisical)"
  assert_match "the value reached the CLI as @file" \
    'LITELLM_MASTER_KEY=@[^[:space:]]*infisical-rotate\.[A-Za-z0-9]+' "${logged}"
  assert_not_match "the minted value never rode argv" "${minted}" "${logged}"
  assert_match "shared, rooted at /, one project" '--type=shared' "${logged}"
  assert_not_match "no printed line carried the new value" "${minted}" "${output}${stderr:-}"
  local leftover
  leftover="$(find "${SCRATCH}" -maxdepth 1 -name 'infisical-rotate.*' | wc -l |
    tr -d '[:space:]')"
  assert_eq "the mode-600 value file is gone once the CLI exited" "0" "${leftover}"
  leftover="$(find "${SCRATCH}/cwd" -name 'infisical-rotate.*' | wc -l | tr -d '[:space:]')"
  assert_eq "and the cwd never held one at all" "0" "${leftover}"
}

@test "rotate: a vault that refuses the write leaves .env byte-identical" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "LITELLM_MASTER_KEY=old-master-value" >>"${ENV_FILE}"
  cd "${SCRATCH}"
  local before after
  before="$(sha256sum "${ENV_FILE}")"
  export STUB_INFISICAL_SET_RC=1
  run_cli rotate LITELLM_MASTER_KEY
  [ "${status}" -eq 1 ]
  assert_match "the failure names the vault as the half that said no" \
    "^error: LITELLM_MASTER_KEY: the vault refused the write, so ${ENV_FILE} was left untouched$" \
    "${stderr:-}"
  assert_eq "the summary counts one failure" "summary: 0 ok, 0 warnings, 1 failed" \
    "$(summary_line "${output}")"
  after="$(sha256sum "${ENV_FILE}")"
  assert_eq ".env did not move" "${before}" "${after}"
  run cat "${ENV_FILE}"
  assert_match "and it still holds the old value" '^LITELLM_MASTER_KEY=old-master-value$' \
    "${output}"
  assert_match "the vault really was asked first" 'sm secrets set' "$(stub_log infisical)"
  # The minted value reached disk before the vault said no, so this is the path where
  # the EXIT trap earns its keep: a cleanup written only on the success path would
  # leave a mode-600 file holding a live credential behind.
  local leftover
  leftover="$(find "${SCRATCH}" -maxdepth 1 -name 'infisical-rotate.*' | wc -l |
    tr -d '[:space:]')"
  assert_eq "the refused path cleans the minted value too" "0" "${leftover}"
}

@test "rotate: the auth secret keeps its 44-character base64 shape and stays unmanaged" {
  # The asymmetry gen_secret_for pins: a NextAuth secret minted as 32 hex yields an
  # instance that corrupts its own session tokens. The generator is driven in a child,
  # so nothing the sourced lib registers can land an EXIT handler in the harness shell.
  local script="${SCRATCH}/gen.sh"
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${REPO_ROOT}/scripts/lib/bootstrap.sh" >/dev/null 2>&1 || exit 6
printf 'auth %s\n' "\$(gen_secret_for INFISICAL_AUTH_SECRET)"
printf 'other %s\n' "\$(gen_secret_for LITELLM_MASTER_KEY)"
exit 7
EOS
  run bash "${script}"
  assert_eq "the generator child reached its own exit code" "7" "${status}"
  local auth other
  auth="$(printf '%s\n' "${output}" | sed -n 's/^auth //p')"
  other="$(printf '%s\n' "${output}" | sed -n 's/^other //p')"
  assert_match "the auth secret is base64 on one line" '^[A-Za-z0-9+/=]+$' "${auth}"
  assert_eq "and exactly 44 characters wide" "44" "${#auth}"
  assert_match "every other managed key is hex" '^[0-9a-f]+$' "${other}"
  assert_eq "and exactly 32 characters wide" "32" "${#other}"

  # The CLI will not rotate it: it is not one of the twelve the inventory owns.
  vault_on "${ENV_FILE}" >/dev/null
  cd "${SCRATCH}"
  run_cli rotate INFISICAL_AUTH_SECRET
  [ "${status}" -eq 1 ]
  assert_match "and the refusal points at the inventory" \
    '^error: INFISICAL_AUTH_SECRET is not a managed key' "${stderr:-}"
}

# ---------------------------------------------------------------------------
# run: the command reaches the CLI's argv after --, with the pinned environment.
# ---------------------------------------------------------------------------

@test "run: execs the command with the pinned domain and flags, and keeps its status" {
  vault_on "${ENV_FILE}" >/dev/null
  printf '%s\n' "INFISICAL_ENVIRONMENT=staging" >>"${ENV_FILE}"
  printf '%s\n' "LITELLM_MASTER_KEY=run-inert-master" >>"${ENV_FILE}"
  local child="${SCRATCH}/child.sh"
  cat >"${child}" <<'EOS'
#!/usr/bin/env bash
printf 'domain=%s\n' "${INFISICAL_DOMAIN:-none}"
printf 'sentinel=%s\n' "${PROBE_SENTINEL:-none}"
printf 'argv=%s\n' "$*"
exit 3
EOS
  chmod 755 "${child}"

  cd "${SCRATCH}"
  PROBE_SENTINEL="reached-the-child" run_cli run -- "${child}" --flag "two words"
  [ "${status}" -eq 3 ]
  assert_match "the section header" '^== Run under the vault ==$' "${output}"
  assert_match "the child inherited the pinned vault domain" \
    '^domain=http://vault:8182$' "${output}"
  assert_match "the child inherited the CLI's environment" '^sentinel=reached-the-child$' \
    "${output}"
  assert_match "its own arguments survived the -- boundary intact" \
    '^argv=--flag two words$' "${output}"

  local logged
  logged="$(stub_log_last infisical)"
  assert_match "the run verb and the configured environment rode the argv" \
    'sm run --env=staging' "${logged}"
  assert_match "the project is named" '--projectId=prj-1' "${logged}"
  assert_match "the command follows a bare --" '-- .*/child\.sh --flag two words$' "${logged}"
  assert_not_match "no credential was printed by the CLI" 'csec-inert' "${output}${stderr:-}"
  assert_not_match "nor was the managed secret the env file holds" 'run-inert-master' \
    "${output}${stderr:-}"
  assert_not_match "and the value never rode the run argv" 'run-inert-master' \
    "$(stub_log infisical)"
  local exports
  exports="$(stub_log infisical | grep -c 'secrets export' || true)"
  assert_eq "no export was run to stage the values" "0" "${exports}"
}

@test "run: its two argument errors are answered before the vault is touched" {
  vault_on "${ENV_FILE}" >/dev/null
  cd "${SCRATCH}"
  run_cli run
  [ "${status}" -ne 0 ]
  assert_match "a run with no command says what it wants" \
    '^error: run names a command: run -- env$' "${stderr:-}"
  assert_eq "and execs no CLI" "0" "$(stub_log_count infisical)"

  write_env "${ENV_FILE}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182"
  : >"${STUB_LOG}/infisical.log"
  run_cli run -- true
  [ "${status}" -eq 1 ]
  assert_match "a run with no project id names the run that fixes it" \
    '^error: INFISICAL_PROJECT_ID is empty; run //scripts:infisical bootstrap first$' \
    "${stderr:-}"
  assert_match "the failure is counted" '^  failed: run$' "${output}"
  assert_eq "and execs no CLI" "0" "$(stub_log_count infisical)"
}

# ---------------------------------------------------------------------------
# install-cli and bootstrap: the two verbs that reach outside the dotenv chain.
# ---------------------------------------------------------------------------

@test "install-cli: installs the pinned release from the stubbed archive, mode 755" {
  export STUB_CURL_OUT="not-really-gzip-but-non-empty"
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false"
  run_cli install-cli
  [ "${status}" -eq 0 ]
  local cli_output="${output}"
  assert_match "the section header" '^== Install the CLI ==$' "${cli_output}"
  assert_match "the fetch names the pinned release URL and nothing else" \
    '^-> fetching the Infisical CLI from https://github\.com/Infisical/cli/releases/download/v0\.45\.8/cli_0\.45\.8_linux_amd64\.tar\.gz$' \
    "${cli_output}"
  local installed="${SCRATCH}/xdg/evo-t1/infisical/bin/infisical"
  assert_file_exists "the binary landed under this test's data dir" "${installed}"
  run stat -c '%a' "${installed}"
  assert_eq "and it is executable" "755" "${output}"
  run cat "${installed}"
  assert_eq "the bytes are the extracted member" "stub-binary" "${output}"
  assert_eq "the verb counted itself and the install" "summary: 2 ok, 0 warnings, 0 failed" \
    "$(summary_line "${cli_output}")"
  assert_match "the download went to a file, never a pipe" '-o ' "$(stub_log curl)"
  local tarred
  tarred="$(stub_log tar)"
  assert_match "the archive is listed before anything runs" 'tar -tzf' "${tarred}"
  assert_match "extraction names one member" '-xzf' "${tarred}"
  assert_eq "the fetch is capped once" "1" "$(stub_log_count timeout)"
  assert_match "and the cap rides timeout's argv" '^timeout 300 ' "$(stub_log timeout)"
}

@test "install-cli: an empty download is a failure the summary counts" {
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=false"
  run_cli install-cli
  [ "${status}" -eq 1 ]
  assert_match "the failure names the URL it could not fetch" \
    '^error: download failed: https://github\.com/Infisical/cli/releases/download/' "${stderr:-}"
  assert_eq "the summary counts one failure" "summary: 0 ok, 0 warnings, 1 failed" \
    "$(summary_line "${output}")"
  assert_match "and records which verb failed" '^  failed: install-cli$' "${output}"
  assert_eq "a body with no bytes never reached tar" "0" "$(stub_log_count tar)"
  [ ! -e "${SCRATCH}/xdg/evo-t1/infisical/bin/infisical" ] || {
    echo "a failed install still put a binary in place" >&2
    return 1
  }
}

@test "bootstrap: lands the identity id, reports the org, and prints neither token nor password" {
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_ADMIN_EMAIL=ops@example.test" "INFISICAL_ADMIN_PASSWORD=pw-inert-x"
  run_cli bootstrap
  [ "${status}" -eq 0 ]
  # Snapshot the CLI's own streams: the env-file dump below reuses ${output}, and the
  # no-secret-printed assertions answer for the CLI's stdout/stderr only.
  local cli_output="${output}"
  local cli_err="${stderr:-}"
  assert_match "the section header" '^== Bootstrap the instance ==$' "${cli_output}"
  assert_match "the run names the domain" \
    '^-> bootstrapping the Infisical instance at http://vault:8182$' "${cli_output}"
  assert_match "the organization id is reported" \
    '^ok: bootstrapped organization stub-org-id at ' "${cli_output}"
  assert_match "the identity id is recorded in the file" \
    "^ok: recorded the machine identity and its id in ${ENV_FILE} \(mode 600\)$" "${cli_output}"
  assert_eq "three ok lines and nothing failed" "summary: 3 ok, 0 warnings, 0 failed" \
    "$(summary_line "${cli_output}")"
  run cat "${ENV_FILE}"
  local env_dump="${output}"
  assert_match "the identity id really landed" '^INFISICAL_MACHINE_IDENTITY_ID=stub-identity-id$' \
    "${env_dump}"
  assert_not_match "the organization id is reported but never stored" \
    'INFISICAL_ORGANIZATION_ID=' "${env_dump}"

  local logged
  logged="$(stub_log infisical)"
  assert_match "the bootstrap verb asked for JSON" '--output=json' "${logged}"
  assert_match "and named the domain it was pointed at" '--domain=http://vault:8182' "${logged}"
  # The two credentials this verb must keep to itself.
  assert_not_match "the super admin's password was never printed" 'pw-inert-x' \
    "${cli_output}${cli_err}"
  assert_not_match "nor was the machine identity token" 'stub-machine-identity-secret' \
    "${cli_output}${cli_err}"
  if grep -rl 'stub-machine-identity-secret' "${STUB_LOG}" >/dev/null 2>&1; then
    echo "the machine identity token reached a stub log" >&2
    return 1
  fi

  # The shipped placeholder is not a password: it is refused before the CLI is run.
  write_env "${ENV_FILE}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_ADMIN_EMAIL=ops@example.test" \
    "INFISICAL_ADMIN_PASSWORD=change-me-infisical-admin"
  : >"${STUB_LOG}/infisical.log"
  run_cli bootstrap
  [ "${status}" -eq 5 ]
  assert_match "the placeholder is named as the problem" \
    'INFISICAL_ADMIN_PASSWORD is empty or still the shipped change-me placeholder' "${stderr:-}"
  assert_eq "and the CLI was never called with it" "0" "$(stub_log_count infisical)"
}

# ---------------------------------------------------------------------------
# The inventory's own invariant, which its header states and nothing else enforces:
# every managed key has a line in both dotenv twins. bootstrap mints a value only
# for a key whose .env line still reads =change-me, so a key added to
# infisical/managed-secrets.txt with no dotenv line is never minted, never pushed,
# and reaches no service -- silently. This is the gate for that.
# ---------------------------------------------------------------------------

@test "inventory: all twelve managed keys are assigned in both dotenv twins" {
  local example="${REPO_ROOT}/.env.example" sample="${REPO_ROOT}/.env.sample"
  if [ ! -r "${example}" ] || [ ! -r "${sample}" ]; then
    skip "the dotenv twins are not in this target's runfiles: tests/BUILD.bazel _SUITE_PAYLOAD[\"infisical.bats\"] needs //:env_example and //:env_sample"
  fi

  # Non-vacuous from both ends: an empty inventory reader would report every twin
  # clean, so the count the reader produces is pinned here as well.
  local count
  count="$(cli_managed_keys | grep -c .)"
  assert_eq "the inventory holds the twelve keys the contract names" "12" "${count}"

  local missing
  missing="$(dotenv_missing_keys "${INVENTORY}" "${example}")"
  assert_eq ".env.example is missing a managed key, which bootstrap would never mint" \
    "" "${missing}"
  missing="$(dotenv_missing_keys "${INVENTORY}" "${sample}")"
  assert_eq ".env.sample is missing a managed key, which bootstrap would never mint" \
    "" "${missing}"
}

@test "inventory: a managed key with no dotenv line is named, not skipped" {
  local fixture="${SCRATCH}/twins" dropped="SPARK_2_API_KEY" key out status
  mkdir -p "${fixture}"

  # A twin that satisfies the invariant has to read clean, or the drop below would
  # pass on a helper that reports every key missing.
  : >"${fixture}/.env.example"
  while IFS= read -r key; do
    printf '%s=change-me\n' "${key}" >>"${fixture}/.env.example"
  done < <(cli_managed_keys)
  assert_eq "a twin carrying every managed key is reported clean" "" \
    "$(dotenv_missing_keys "${INVENTORY}" "${fixture}/.env.example")"

  # The shape of the defect: one managed key with no assignment anywhere.
  grep -v "^${dropped}=" "${fixture}/.env.example" >"${fixture}/.env.gap"
  status=0
  out="$(dotenv_missing_keys "${INVENTORY}" "${fixture}/.env.gap")" || status=$?
  [ "${status}" -eq 0 ] || {
    echo "the check failed outright instead of reporting the gap" >&2
    return 1
  }
  assert_eq "the key with no dotenv line is the one thing it names" "${dropped}" "${out}"
  assert_match "and it names it as a bare key, so the message can be acted on" \
    "^${dropped}$" "${out}"

  # An unreadable twin is a failure, never the empty answer that would read as clean.
  if dotenv_missing_keys "${INVENTORY}" "${fixture}/absent" 2>/dev/null; then
    echo "a twin that does not exist read as if it carried every key" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# The lib probe: a missing lib is one error and an exit, not bash's own noise.
# ---------------------------------------------------------------------------

@test "find_lib: a script with no lib beside it prints one error and exits 1" {
  local lonely="${SCRATCH}/lonely"
  mkdir -p "${lonely}"
  cp "${SCRIPT}" "${lonely}/infisical.sh"
  cd "${lonely}"
  # No checkout marker anywhere above it, and no harness-stated root, so neither
  # candidate find_lib probes exists. The three variables resolve_checkout would
  # otherwise answer from are cleared for this one call.
  run --separate-stderr env -u REPO_ROOT -u BUILD_WORKSPACE_DIRECTORY -u GITHUB_WORKSPACE \
    "${BASH}" "${lonely}/infisical.sh" status
  [ "${status}" -eq 1 ]
  assert_eq "exactly one line reaches stderr" "1" "$(printf '%s\n' "${stderr:-}" | grep -c .)"
  assert_match "it names the lib and where it looked" \
    '^error: common\.sh is not reachable from .*/lonely/lib/common\.sh$' "${stderr:-}"
  assert_not_match "bash's own complaint never leaks through" 'No such file or directory' \
    "${stderr:-}"
  assert_not_match "no usage block is printed for a missing lib" 'Usage: bazelisk run' "${output}"
}

# ---------------------------------------------------------------------------
# The documented surface: every function the inventory counts is defined, named
# here, and carries the # @function block this repo's test rule requires.
# ---------------------------------------------------------------------------

@test "the CLI declares exactly the fifteen functions this suite names, each documented" {
  local fn
  for fn in "${CLI_FUNCTIONS[@]}"; do
    grep -q "^${fn}() {" "${SCRIPT}" || {
      echo "scripts/infisical.sh no longer defines ${fn}() {" >&2
      return 1
    }
    grep -q "^# @function ${fn}$" "${SCRIPT}" || {
      echo "${fn} has no # @function block, which this repo's test rule requires" >&2
      return 1
    }
  done

  # And nothing was added beside them: the derived set has to equal the literal list.
  # main is dropped the way the inventory drops it, since the dispatcher body is not a
  # documented function.
  local defined expected
  defined="$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${SCRIPT}" | sed 's/()$//' |
    grep -vx main | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
  expected="$(printf '%s\n' "${CLI_FUNCTIONS[@]}" | LC_ALL=C sort | tr '\n' ' ' |
    sed 's/ *$//')"
  assert_eq "the CLI grew or lost a function this suite does not know" \
    "${expected}" "${defined}"
}
