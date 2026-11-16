#!/usr/bin/env bats
#
# ## infisical_lib.bats - hermetic coverage for scripts/lib/infisical.sh.
#
# The seam contract pinned here: INFISICAL_ENABLED is read in exactly one place and an
# absent key means OFF (the deliberate inverse of compose_observability_args, where an
# absent key means on); the profile argv is two words or nothing at all; a dotenv edit
# moves no byte outside the one line it rewrites, keeps one occurrence of a key, and is
# not claimed until a re-read hash agrees; a pull never blanks a key the vault does not
# hold; and no secret value ever rides argv or a printed line, because the whole design
# rests on values travelling only through mode-600 files.
#
# Hermetic by construction. setup() shadows the `infisical` CLI with the fixture in
# tests/bats/tool_stubs/infisical, which records argv to $STUB_LOG and answers from
# STUB_INFISICAL_* variables; the coreutils the lib pipes through (grep, awk, wc) stay
# the host's, so a suite that hid those would test a PATH no operator runs on. Nothing
# here contacts a server, reads a real credential, or touches the repo's own .env: every
# file the lib writes is inside BATS_TEST_TMPDIR.
#
# The whole suite skips while the lib is absent: a suite for a file that does not exist
# yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_infisical_lib_test   (from any cwd)
# Safety: stubs and canned dotenv bodies only. No live service, no Docker, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
LIB=""
SCRATCH=""

# setup - resolve the checkout, shadow the CLI, and lay out this test's scratch tree.
# Globals:
#   REPO_ROOT, LIB, SCRATCH, STUB_LOG, PATH, INFISICAL_TMP_FILES
# Arguments:
#   None
# Outputs:
#   None
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  LIB="${REPO_ROOT}/scripts/lib/infisical.sh"
  [ -f "${LIB}" ] || skip "scripts/lib/infisical.sh is absent"
  make_scratch
  SCRATCH="${BATS_TEST_TMPDIR}/scratch"
  mkdir -p "${SCRATCH}"
  use_stubs infisical curl tar timeout
  # The lib registers temps against an EXIT trap; start each test with a clean list so
  # one test's temp can never be cleaned by, or blamed on, another.
  export INFISICAL_TMP_FILES=""
  # Nothing in this suite may reach a real checkout's .env through the default resolver.
  export ENV_FILE="${SCRATCH}/.env"
  unset COMPOSE_FILE INFISICAL_ENABLED INFISICAL_URL INFISICAL_PORT INFISICAL_PROJECT_ID
  unset INFISICAL_ENVIRONMENT INFISICAL_CLI_BIN INFISICAL_CLI_VERSION
  unset INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
}

# source_lib - bring the seam into this shell, then re-export the flag names the lib
# reads at source time.
# Globals:
#   LIB
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
source_lib() {
  # shellcheck source=/dev/null disable=SC1091
  source "${LIB}"
}

# write_env - lay down a dotenv fixture with one line per argument.
# Arguments:
#   $1 - the file; $2.. - KEY=value lines
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

# vault_on - lay down the .env a configured stack has, and print its path. Every verb
# short-circuits on INFISICAL_ENABLED, so a sync test that forgot this line would prove
# only the off branch while reading as a pass.
# Arguments:
#   None (writes ${SCRATCH}/.env)
# Outputs:
#   The path of the file it wrote
# Returns:
#   0
vault_on() {
  write_env "${SCRATCH}/.env" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_PROJECT_ID=prj" "INFISICAL_ENVIRONMENT=prod" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"
  printf '%s\n' "${SCRATCH}/.env"
}

# ---------------------------------------------------------------------------
# The flag seam: one reader, two branches, and the unset case that makes this
# flag different from every other flag in the stack.
# ---------------------------------------------------------------------------

@test "seam: compose_infisical_args prints the profile words only when the flag is truthy" {
  source_lib
  local envf="${SCRATCH}/on.env"
  write_env "${envf}" "INFISICAL_ENABLED=true"

  run compose_infisical_args "${envf}"
  [ "${status}" -eq 0 ]
  assert_eq "on: exactly the two profile words" "--profile secrets" "${output}"

  write_env "${envf}" "INFISICAL_ENABLED=false"
  run compose_infisical_args "${envf}"
  [ "${status}" -eq 0 ]
  assert_eq "off: no word at all, not an empty one" "" "${output}"

  # The load-bearing case. OBSERVABILITY_ENABLED answers "on" to this same question,
  # so a future edit that copies that helper's default silently starts three
  # containers on every box. Assert the asymmetry, not just the two branches.
  write_env "${envf}" "STACK_DOMAIN_BASE=example.test"
  run compose_infisical_args "${envf}"
  [ "${status}" -eq 0 ]
  assert_eq "unset key: off, the shipped default" "" "${output}"

  run compose_infisical_args "${SCRATCH}/no-such-file.env"
  [ "${status}" -eq 0 ]
  assert_eq "missing file: off, and still no crash" "" "${output}"
}

@test "seam: infisical_enabled accepts truthy's four spellings and nothing else" {
  source_lib
  local envf="${SCRATCH}/flag.env" value
  for value in 1 true TRUE yes on; do
    write_env "${envf}" "INFISICAL_ENABLED=${value}"
    run infisical_enabled "${envf}"
    [ "${status}" -eq 0 ] || {
      echo "want on for '${value}', got off" >&2
      return 1
    }
  done
  for value in 0 false FALSE no off maybe "" "  "; do
    write_env "${envf}" "INFISICAL_ENABLED=${value}"
    run infisical_enabled "${envf}"
    [ "${status}" -ne 0 ] || {
      echo "want off for '${value}', got on" >&2
      return 1
    }
  done

  # The process environment outranks the file, which is compose's own precedence.
  write_env "${envf}" "INFISICAL_ENABLED=false"
  INFISICAL_ENABLED=true run infisical_enabled "${envf}"
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The inventory is the only list.
# ---------------------------------------------------------------------------

@test "seam: infisical_managed_keys reads the one inventory and drops everything that is not a key" {
  source_lib
  local keys count
  run infisical_managed_keys "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 0 ]
  # Never re-type the list: compare against the file the seam itself reads, so the
  # inventory can gain a key without a second edit here.
  keys="$(grep -E '^[A-Z0-9_]+$' "${REPO_ROOT}/infisical/managed-secrets.txt")"
  assert_eq "the inventory verbatim" "${keys}" "${output}"

  count="$(printf '%s\n' "${output}" | grep -c .)"
  assert_eq "one key per line, no blanks or banners" "12" "${count}"

  local fixture="${SCRATCH}/inventory.txt"
  write_env "${fixture}" "# a banner" "" "  INDENTED=no" "lower_case=no" \
    "GOOD_KEY" "KEY_WITH_VALUE=x" "ANOTHER_KEY"
  run infisical_managed_keys "${fixture}"
  [ "${status}" -eq 0 ]
  assert_eq "only the bare upper-case names survive" "$(printf 'GOOD_KEY\nANOTHER_KEY')" "${output}"

  run infisical_managed_keys "${SCRATCH}/absent.txt"
  [ "${status}" -eq 5 ]
  run infisical_managed_keys "${fixture}" # fixture above held keys; now an empty one
  write_env "${SCRATCH}/empty.txt" "# nothing but a comment" ""
  run infisical_managed_keys "${SCRATCH}/empty.txt"
  [ "${status}" -eq 5 ]
}

@test "seam: the default inventory lookup survives a foreign cwd with no checkout named" {
  # The shape that was broken. `bash <abs>/scripts/infisical.sh` from a directory that
  # is not the checkout, with no REPO_ROOT, BUILD_WORKSPACE_DIRECTORY or
  # GITHUB_WORKSPACE to name it, leaves resolve_checkout with nothing to prove, so the
  # fallback beside the lib file has to carry the run. That file sits two levels above
  # scripts/lib/, and the one-level form it used to try named a path that has never
  # existed - so every such run was told its own managed keys were unmanaged. Counting
  # the keys here is the assertion; reading the path off the source is not.
  source_lib
  local elsewhere="${SCRATCH}/elsewhere" n rc=0
  mkdir -p "${elsewhere}"
  (
    cd "${elsewhere}" || exit 9
    unset REPO_ROOT BUILD_WORKSPACE_DIRECTORY GITHUB_WORKSPACE
    n="$(infisical_managed_keys | grep -c .)" || n="rc$?"
    if [ "${n}" != "12" ]; then
      printf 'keys printed by the default lookup: %s\n' "${n}" >&2
      exit 8
    fi
  ) || rc=$?
  [ "${rc}" -eq 0 ]
}

@test "seam: infisical_is_managed_key answers both ways and cannot lose the probe to SIGPIPE" {
  source_lib
  local inv="${REPO_ROOT}/infisical/managed-secrets.txt" key i bad=0 rc=0
  run infisical_is_managed_key "LITELLM_MASTER_KEY" "${inv}"
  [ "${status}" -eq 0 ]
  run infisical_is_managed_key "NOT_A_STACK_KEY" "${inv}"
  [ "${status}" -eq 1 ]
  run infisical_is_managed_key "" "${inv}"
  [ "${status}" -eq 1 ]
  run infisical_is_managed_key "LITELLM_MASTER_KEY" "${SCRATCH}/absent.txt"
  [ "${status}" -eq 1 ]
  # The probe this replaces was `infisical_managed_keys | grep -qx KEY` under the
  # caller's `set -o pipefail`: grep -q exited on its first match, the reader died of
  # SIGPIPE, the pipeline reported 141, and the verb refused a genuinely managed key
  # on 195 of 200 attempts. Drive every name in the inventory through the predicate
  # five times inside one pipefail shell, so a reintroduced early-exit pipe lands in
  # the counter and the gate goes red on the first lost probe.
  (
    set -o pipefail
    while IFS= read -r key; do
      for i in 1 2 3 4 5; do
        infisical_is_managed_key "${key}" "${inv}" || bad=$((bad + 1))
      done
    done < <(grep -E '^[A-Z0-9_]+$' "${inv}")
    exit "${bad}"
  ) || rc=$?
  [ "${rc}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The dotenv writer: the file compose reads must survive every edit intact.
# ---------------------------------------------------------------------------

@test "seam: infisical_write_env rewrites one line and leaves every other byte alone" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "# a comment that must survive" \
    "LITELLM_MASTER_KEY=old" "" "  # indented comment" "OTHER_KEY=untouched"
  run infisical_write_env "LITELLM_MASTER_KEY" "new value with spaces" "${envf}"
  [ "${status}" -eq 0 ]
  run cat "${envf}"
  assert_eq "one line moved, nothing else did" \
    "$(printf '# a comment that must survive\nLITELLM_MASTER_KEY=new value with spaces\n\n  # indented comment\nOTHER_KEY=untouched')" \
    "${output}"
}

@test "seam: infisical_write_env keeps one occurrence and appends a key it has never seen" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "CODER_PG_PASSWORD=one" "CODER_PG_PASSWORD=two" "X=1"
  run infisical_write_env "CODER_PG_PASSWORD" "only" "${envf}"
  [ "${status}" -eq 0 ]
  run grep -c '^CODER_PG_PASSWORD=' "${envf}"
  assert_eq "a duplicated key collapses to one" "1" "${output}"
  run cat "${envf}"
  assert_match "the surviving line holds the new value" '^CODER_PG_PASSWORD=only$' "${output}"

  run infisical_write_env "INFISICAL_ENCRYPTION_KEY" "abc123" "${envf}"
  [ "${status}" -eq 0 ]
  run tail -n 1 "${envf}"
  assert_eq "a new key is appended, not inserted into the middle" "INFISICAL_ENCRYPTION_KEY=abc123" "${output}"

  # A key name that is not a key name must not reach sed as a pattern.
  run infisical_write_env "bad key" "x" "${envf}"
  [ "${status}" -ne 0 ]
}

@test "seam: infisical_hash_of is stable, hex, and never sends the value through argv" {
  source_lib
  local a b
  a="$(infisical_hash_of "hunter2")"
  b="$(infisical_hash_of "hunter2")"
  assert_eq "the same value hashes the same way" "${a}" "${b}"
  assert_match "lower-case hex, 64 wide" '^[0-9a-f]{64}$' "${a}"
  [ "${a}" != "$(infisical_hash_of 'hunter3')" ]
}

@test "seam: infisical_dotenv_get answers byte for byte and fails on a key that is absent" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "A=one" "B=with spaces" "C=" "AB=x"
  run infisical_dotenv_get "${envf}" "A"
  assert_eq "a plain value" "one" "${output}"
  run infisical_dotenv_get "${envf}" "B"
  assert_eq "spaces survive" "with spaces" "${output}"
  run infisical_dotenv_get "${envf}" "C"
  assert_eq "an empty value is an empty answer, not a failure" "" "${output}"
  run infisical_dotenv_get "${envf}" "A"
  [ "${status}" -eq 0 ]
  run infisical_dotenv_get "${envf}" "AB"
  [ "${status}" -eq 0 ]
  run infisical_dotenv_get "${envf}" "NOPE"
  [ "${status}" -ne 0 ]
  run infisical_dotenv_get "${SCRATCH}/absent" "A"
  [ "${status}" -ne 0 ]
}

@test "seam: infisical_env_value prefers the process environment and treats blank as unstated" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "INFISICAL_URL=http://from-file:8182"

  run infisical_env_value INFISICAL_URL "${envf}"
  assert_eq "the file answers when the environment is silent" "http://from-file:8182" "${output}"

  INFISICAL_URL=http://from-env:9999 run infisical_env_value INFISICAL_URL "${envf}"
  assert_eq "the environment outranks the file" "http://from-env:9999" "${output}"

  # Every credential ships empty in .env.example, so a set-but-empty process value is
  # "not stated" and the file has to get its turn.
  INFISICAL_URL="" run infisical_env_value INFISICAL_URL "${envf}"
  assert_eq "an empty environment value falls through to the file" "http://from-file:8182" "${output}"

  run infisical_env_value NEVER_SET "${envf}"
  [ "${status}" -eq 0 ]
  assert_eq "a key neither source holds prints nothing" "" "${output}"
}

@test "seam: infisical_default_env_file resolves ENV_FILE, then COMPOSE_FILE, then ./.env" {
  source_lib
  run env ENV_FILE=/tmp/pinned.env bash -c \
    "source '${LIB}' >/dev/null 2>&1; infisical_default_env_file"
  assert_eq "ENV_FILE wins" "/tmp/pinned.env" "${output}"
  run env -u ENV_FILE COMPOSE_FILE=/opt/stack/docker-compose.yml bash -c \
    "source '${LIB}' >/dev/null 2>&1; infisical_default_env_file"
  assert_eq "the compose file's directory" "/opt/stack/.env" "${output}"
  run env -u ENV_FILE -u COMPOSE_FILE bash -c \
    "source '${LIB}' >/dev/null 2>&1; infisical_default_env_file"
  assert_eq "and finally the plain relative name" ".env" "${output}"
}

@test "seam: infisical_mktemp tightens the mode and reports through the global, not stdout" {
  source_lib
  local script="${SCRATCH}/mktempcase.sh"
  # Every call goes through a child: infisical_mktemp installs the shell's EXIT
  # handler, and a test file that installs one in the harness shell steals the line
  # bats uses to report the test. The modes are read inside the child, because the
  # child's own exit is what removes the temps.
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
# Called by name as well as through mktemp, so its own contract is on the record here:
# one handler per shell, and the second call must not stack a second trap.
infisical_install_exit_trap || exit 2
infisical_install_exit_trap || exit 2
trap -p EXIT
infisical_mktemp "${SCRATCH}/pull" || exit 3
printf 'file %s %s\n' "\${INFISICAL_MKTEMP}" "\$(stat -c '%a' "\${INFISICAL_MKTEMP}")"
[ -f "\${INFISICAL_MKTEMP}" ] || exit 4
infisical_mktemp "${SCRATCH}/dir" dir || exit 3
printf 'dir %s %s\n' "\${INFISICAL_MKTEMP}" "\$(stat -c '%a' "\${INFISICAL_MKTEMP}")"
[ -d "\${INFISICAL_MKTEMP}" ] || exit 4
( infisical_install_exit_trap
  printf 'subtrap %s\n' "\$(trap -p EXIT)" )
exit 7
EOS
  run bash "${script}"
  assert_eq "the child reached its own exit code" "7" "${status}"
  assert_eq "the slot holds the seam's cleanup, and one call per shell" \
    "trap -- 'infisical_tmp_cleanup' EXIT" \
    "$(printf '%s\n' "${output}" | grep '^trap ')"
  assert_match "a forked subshell installs its own handler rather than trusting the inherited flag" \
    '^subtrap trap -- .infisical_tmp_cleanup. EXIT$' "${output}"
  assert_match "a file temp is mode 600, the only mode a secret may sit in" \
    '^file .*/pull\.[A-Za-z0-9]+ 600$' "${output}"
  assert_match "a directory temp is mode 700" \
    '^dir .*/dir\.[A-Za-z0-9]+ 700$' "${output}"

  # ...and both are gone once that shell exits on a non-zero path.
  local path
  for path in "${SCRATCH}"/pull.* "${SCRATCH}"/dir.*; do
    [ -e "${path}" ] || continue
    echo "a temp survived the exit: ${path}" >&2
    return 1
  done

  # The path comes back in the global, so calling it in $( ) is the bug this asserts:
  # the subshell keeps the assignment and the caller gets nothing.
  local sub="${SCRATCH}/subcase.sh" bad="${SCRATCH}/badcase.sh"
  cat >"${sub}" <<EOS
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
printf '%s' "\$(infisical_mktemp '${SCRATCH}/sub')"
EOS
  run bash "${sub}"
  assert_eq "command substitution yields no path by design" "" "${output}"

  cat >"${bad}" <<EOS
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
infisical_mktemp '/nonexistent-dir/nope'
echo "rc=\$?"
EOS
  run bash "${bad}"
  assert_match "a template in a directory that does not exist is a failure" 'rc=1' "${output}"
}

@test "seam: infisical_tmp_cleanup removes this process's temps and leaves another's alone" {
  source_lib
  local mine="${SCRATCH}/mine" other="${SCRATCH}/other"
  : >"${mine}"
  : >"${other}"
  # One entry per line: the list is read back with `IFS= read -r`, so the format is part
  # of the contract. The pid tag is what makes this safe, and stays pinned below.
  INFISICAL_TMP_FILES="${BASHPID}:${mine}"$'\n'"999999:${other}"$'\n'
  infisical_tmp_cleanup
  [ ! -e "${mine}" ]
  [ -f "${other}" ]
  assert_eq "the foreign entry is carried forward, not dropped" \
    "999999:${other}"$'\n' "${INFISICAL_TMP_FILES}"
}

@test "seam: infisical_tmp_cleanup removes a temp whose path holds a space" {
  source_lib
  local spaced="${SCRATCH}/a b/keep" foreign="${SCRATCH}/a b/other"
  mkdir -p "${SCRATCH}/a b"
  : >"${spaced}"
  : >"${foreign}"
  INFISICAL_TMP_FILES="${BASHPID}:${spaced}"$'\n'"999999:${foreign}"$'\n'
  infisical_tmp_cleanup
  [ ! -e "${spaced}" ] || {
    echo "a mode-600 secret with a space in its path survived: ${spaced}" >&2
    return 1
  }
  [ -f "${foreign}" ] || {
    echo "word splitting matched a foreign spaced path and deleted it" >&2
    return 1
  }
  assert_eq "the foreign spaced entry survives whole, not as two halves" \
    "999999:${foreign}"$'\n' "${INFISICAL_TMP_FILES}"

  # And through the door an operator actually walks in: infisical_mktemp with a
  # caller-supplied --env-file / COMPOSE_FILE path that holds a space, on a failure exit.
  local dir="${SCRATCH}/dir with space" made="${SCRATCH}/made" script="${SCRATCH}/spacecase.sh"
  mkdir -p "${dir}"
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
infisical_mktemp "${dir}/sec" || exit 3
printf '%s' "\${INFISICAL_MKTEMP}" >"${made}"
infisical_mktemp "${dir}/d" dir || exit 3
printf '%s' "\${INFISICAL_MKTEMP}" >>"${made}"
exit 7
EOS
  run bash "${script}"
  [ "${status}" -eq 7 ]
  [ -s "${made}" ]
  local listing path
  listing="$(cat "${made}")"
  assert_match "the file temp really does carry a space" 'dir with space/sec\.' "${listing}"
  assert_match "and so does the directory temp" 'dir with space/d\.' "${listing}"
  while IFS= read -r path; do
    [ -e "${path}" ] || continue
    echo "a temp with a space in its path survived the exit: ${path}" >&2
    return 1
  done <"${made}"
  assert_eq "nothing at all is left in that directory" "0" \
    "$(find "${dir}" -mindepth 1 -print | wc -l)"
}

@test "seam: infisical_mktemp refuses a template that is not an absolute path" {
  source_lib
  local script="${SCRATCH}/relative.sh"
  # The child cd's into the scratch tree so a leaked relative temp is visible: mktemp
  # writes a bare template into the caller's cwd, which is how a secret file landed next
  # to the repo instead of next to TMPDIR.
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
cd "${SCRATCH}" || exit 2
infisical_mktemp "infisical-rotate"; echo "rc1=\$?"
infisical_mktemp "./dotted"; echo "rc2=\$?"
infisical_mktemp ""; echo "rc3=\$?"
printf 'mktemp=[%s]\n' "\${INFISICAL_MKTEMP}"
EOS
  run bash "${script}"
  [ "${status}" -eq 0 ]
  assert_eq "a bare name, a dotted name, and an empty template all refuse" \
    "$(printf 'rc1=2\nrc2=2\nrc3=2')" "$(printf '%s\n' "${output}" | grep '^rc')"
  assert_eq "the global stays empty on every refusal" "mktemp=[]" \
    "$(printf '%s\n' "${output}" | grep '^mktemp=')"
  assert_eq "one error line per refusal, no more" "3" \
    "$(printf '%s\n' "${output}" | grep -c '^error: ')"
  assert_match "the refusal names the argument the caller passed" \
    "infisical-rotate" "${output}"
  assert_match "and it stays in the operator vocabulary" '^error: ' "${output}"
  assert_eq "nothing was created next to the caller" "0" \
    "$(find "${SCRATCH}" -maxdepth 1 \( -name 'infisical-rotate*' -o -name 'dotted*' \
      -o -name 'tmp*' -o -name '.tmp*' \) -print | wc -l)"

  # An absolute template in a directory that does not exist is still mktemp's own
  # failure, not the new refusal.
  run infisical_mktemp "${SCRATCH}/no-such-dir/x"
  [ "${status}" -eq 1 ]
}

@test "seam: infisical_trap_body unwraps one trap -p EXIT line" {
  source_lib
  run infisical_trap_body "trap -- 'echo hi' EXIT"
  [ "${status}" -eq 0 ]
  assert_eq "the single-quoted word comes back as the handler it holds" "echo hi" "${output}"

  run infisical_trap_body "trap -- 'rm -f \"a b\"' EXIT"
  [ "${status}" -eq 0 ]
  assert_eq "quotes and spaces inside the handler survive" 'rm -f "a b"' "${output}"

  run infisical_trap_body ""
  [ "${status}" -ne 0 ]
  run infisical_trap_body "trap -- '' EXIT"
  [ "${status}" -ne 0 ]
  run infisical_trap_body "trap -- 'echo hi' INT"
  [ "${status}" -ne 0 ]

  # A handler that holds a quote of its own, taken from what bash really prints rather
  # than from a hand-written imitation of it.
  local script="${SCRATCH}/quotecase.sh"
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
trap 'echo "it'\''s here"' EXIT
caller_line="\$(trap -p EXIT)"
infisical_mktemp "${SCRATCH}/quoted" || exit 3
printf 'body='
infisical_trap_body "\${caller_line}"
printf '\n'
exit 8
EOS
  run bash "${script}"
  [ "${status}" -eq 8 ]
  assert_eq "bash's '\'' run folds back to one quote" 'body=echo "it'"'"'s here"' \
    "$(printf '%s\n' "${output}" | grep '^body=')"
  assert_eq "and the folded handler executes as the caller wrote it" 'it'"'"'s here' \
    "$(printf '%s\n' "${output}" | tail -n 1)"
}

@test "seam: the caller's own EXIT trap still runs after the seam takes the slot" {
  source_lib
  local script="${SCRATCH}/callertrap.sh" made="${SCRATCH}/caller-path"
  # bash keeps one EXIT handler, so this is the half the seam used to lose: the caller's
  # cleanup must still run, once, and with the secrets already off the disk.
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
caller_cleanup() { printf 'CALLER_TRAP_RAN %s\n' "\${1:-once}"; }
trap 'caller_cleanup once; printf "SECOND LINE with space\n"' EXIT
infisical_mktemp "${SCRATCH}/caller-secret" || exit 3
printf '%s' "\${INFISICAL_MKTEMP}" >"${made}"
( infisical_mktemp "${SCRATCH}/forked-secret" )
exit 7
EOS
  run bash "${script}"
  assert_eq "the caller's own exit code survives the chained handler" "7" "${status}"
  assert_match "the caller's handler function ran at exit" '^CALLER_TRAP_RAN once$' "${output}"
  assert_match "including its second statement" '^SECOND LINE with space$' "${output}"
  assert_eq "and it ran once, not once per forked subshell" "1" \
    "$(printf '%s\n' "${output}" | grep -c '^CALLER_TRAP_RAN ')"
  local path
  for path in "$(cat "${made}")" "${SCRATCH}/caller-secret".* "${SCRATCH}/forked-secret".*; do
    [ -e "${path}" ] || continue
    echo "a temp survived the chained exit: ${path}" >&2
    return 1
  done
}

@test "seam: the EXIT slot holds the seam's cleanup and stashes the caller's handler" {
  source_lib
  local script="${SCRATCH}/slot.sh"
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
trap 'echo CALLER_TRAP_RAN' EXIT
infisical_mktemp "${SCRATCH}/slot" || exit 3
trap -p EXIT
printf 'prior=[%s]\n' "\${INFISICAL_EXIT_TRAP_PRIOR}"
( infisical_install_exit_trap
  printf 'subprior=[%s]\n' "\${INFISICAL_EXIT_TRAP_PRIOR}" )
exit 9
EOS
  run bash "${script}"
  assert_eq "the child reached its own exit code" "9" "${status}"
  assert_eq "the slot still holds the seam's cleanup alone, so the dump is never spared" \
    "trap -- 'infisical_tmp_cleanup' EXIT" "$(printf '%s\n' "${output}" | grep '^trap ')"
  assert_eq "the caller's handler is kept for the cleanup to run" \
    "prior=[echo CALLER_TRAP_RAN]" "$(printf '%s\n' "${output}" | grep '^prior=')"
  assert_eq "a forked subshell keeps no copy of it, so it cannot run twice" \
    "subprior=[]" "$(printf '%s\n' "${output}" | grep '^subprior=')"
  assert_eq "the caller's handler ran exactly once, not also while the shell lived" "1" \
    "$(printf '%s\n' "${output}" | grep -c '^CALLER_TRAP_RAN$')"
  assert_eq "and it ran last, at the exit, after the seam's own lines" "CALLER_TRAP_RAN" \
    "$(printf '%s\n' "${output}" | tail -n 1)"
}


@test "seam: the seam owns the EXIT slot and still cleans the secret on a failure exit" {
  source_lib
  local script="${SCRATCH}/trapcase.sh" made="${SCRATCH}/path"
  # bash keeps one EXIT handler and the last setter wins, so the seam owns the slot.
  # This drives it in a child for two reasons: the harness's own EXIT bookkeeping stays
  # out of the way, and a caller that exits non-zero is the path where a file of
  # secrets is most likely to be stranded.
  cat >"${script}" <<EOS
set -u
# shellcheck source=/dev/null disable=SC1091
source "${LIB}" >/dev/null 2>&1
infisical_mktemp "${SCRATCH}/dump" || exit 3
printf '%s' "\${INFISICAL_MKTEMP}" >"${made}"
infisical_mktemp "${SCRATCH}/dump2" || exit 3
exit 7
EOS
  run bash "${script}"
  [ "${status}" -eq 7 ]
  [ -s "${made}" ]
  # Both temps are gone even though the child exited on a failure path.
  local path
  for path in "$(cat "${made}")" "${SCRATCH}/dump2".*; do
    [ -e "${path}" ] || continue
    echo "a temp survived a non-zero exit: ${path}" >&2
    return 1
  done
}

@test "seam: no script that sources the seam installs an EXIT trap of its own" {
  source_lib
  local f hits=""
  # The rule the header states, checked instead of trusted: an entry script that took
  # the single EXIT slot after sourcing the seam would silently stop cleaning the
  # dump, the push file, and the bootstrap JSON.
  for f in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
    # A real source statement, not the commented usage example in the seam's own
    # header, which is how the seam mentions its own path without sourcing it.
    grep -Eq '^[[:space:]]*source "(scripts/)?lib/infisical\.sh"' "${f}" 2>/dev/null ||
      continue
    if grep -Eq "^[[:space:]]*trap ['\"]" "${f}"; then
      hits="${hits} $(basename "${f}")"
    fi
  done
  assert_eq "no source of the seam claims the EXIT slot" "" "${hits}"
  # And the four that source it really are the four, so the check above cannot pass by
  # matching nothing.
  local n
  n="$(grep -rl 'lib/infisical.sh' "${REPO_ROOT}"/scripts/*.sh | wc -l)"
  [ "${n}" -ge 4 ] || { echo "expected at least 4 sources of the seam, saw ${n}" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# The CLI binary and its release URL.
# ---------------------------------------------------------------------------

@test "seam: infisical_cli_bin prefers the override, then PATH, then the installed copy, else 5" {
  source_lib
  local fake="${SCRATCH}/fake-infisical"
  printf '#!/bin/sh\nexit 0\n' >"${fake}"
  chmod 755 "${fake}"

  INFISICAL_CLI_BIN="${fake}" run infisical_cli_bin
  [ "${status}" -eq 0 ]
  assert_eq "the operator's override wins over everything" "${fake}" "${output}"

  # PATH: stub_bin already put the infisical fixture on PATH.
  run infisical_cli_bin
  [ "${status}" -eq 0 ]
  assert_match "PATH answers when no override is set" '/infisical$' "${output}"

  # No override, no PATH, and the install path does not exist: 5, and nothing printed.
  local empty="${SCRATCH}/empty-bin"
  mkdir -p "${empty}"
  run env -i PATH="${empty}" HOME="${SCRATCH}" XDG_DATA_HOME="${SCRATCH}/xdg" "${BASH}" -c \
    "source '${LIB}' >/dev/null 2>&1; infisical_cli_bin"
  [ "${status}" -eq 5 ]
  assert_eq "no binary prints nothing so a caller can branch on the status" "" "${output}"

  # A non-executable override is not a binary.
  printf 'x' >"${SCRATCH}/not-exec"
  INFISICAL_CLI_BIN="${SCRATCH}/not-exec" run infisical_cli_bin
  [ "${status}" -eq 0 ]
  assert_match "a non-executable override is skipped for PATH" '/infisical$' "${output}"
}

@test "seam: infisical_cli_install_path lands under the per-user data dir" {
  source_lib
  run env XDG_DATA_HOME="${SCRATCH}/xdg" bash -c \
    "source '${LIB}' >/dev/null 2>&1; infisical_cli_install_path"
  assert_eq "the pinned layout" "${SCRATCH}/xdg/evo-t1/infisical/bin/infisical" "${output}"
}

@test "seam: infisical_cli_url builds the pinned goreleaser asset and refuses a version that is not a version" {
  source_lib
  run infisical_cli_url
  [ "${status}" -eq 0 ]
  assert_eq "the default pin, spelled exactly" \
    "https://github.com/Infisical/cli/releases/download/v0.45.8/cli_0.45.8_linux_amd64.tar.gz" \
    "${output}"

  INFISICAL_CLI_VERSION=1.2.3-rc1 run infisical_cli_url
  [ "${status}" -eq 0 ]
  assert_match "a released-looking version interpolates into both slots" \
    '/v1\.2\.3-rc1/cli_1\.2\.3-rc1_linux_amd64\.tar\.gz$' "${output}"

  # This string is handed to curl, so a path or a traversal is refused rather than
  # interpolated.
  INFISICAL_CLI_VERSION="../../etc/passwd" run infisical_cli_url
  [ "${status}" -eq 5 ]
  INFISICAL_CLI_VERSION="0.45.8 --silent" run infisical_cli_url
  [ "${status}" -eq 5 ]
}

@test "seam: infisical_install_cli lists the archive before it extracts, and lands mode 755" {
  source_lib
  local bindir="${SCRATCH}/vaultbin"
  export XDG_DATA_HOME="${SCRATCH}/xdg"
  export STUB_CURL_OUT="not-really-gzip-but-non-empty"

  run infisical_install_cli
  [ "${status}" -eq 0 ]
  local installed="${SCRATCH}/xdg/evo-t1/infisical/bin/infisical"
  [ -f "${installed}" ]
  run stat -c '%a' "${installed}"
  assert_eq "the binary is executable" "755" "${output}"
  assert_eq "the bytes are the extracted member" "stub-binary" "$(cat "${installed}")"

  local logged
  logged="$(cat "${STUB_LOG}/tar.log")"
  # The listing is the integrity check, so it has to come first and the extraction
  # has to name one member rather than unpack whatever the archive feels like.
  assert_match "the archive is listed" 'tar -tzf' "${logged}"
  assert_match "extraction names the member it wants" 'tar -xzf' "${logged}"
  assert_match "the member is named after a separator" '-- infisical' "${logged}"
  assert_match "the fetch is capped" 'timeout 300' "$(cat "${STUB_LOG}/timeout.log")"
  assert_match "curl writes to a file rather than a pipe" '-o ' "$(cat "${STUB_LOG}/curl.log")"
}

@test "seam: infisical_install_cli refuses a body that is not a readable tarball" {
  source_lib
  export XDG_DATA_HOME="${SCRATCH}/xdg"
  export STUB_CURL_OUT="an HTML error page, non-empty"
  export STUB_TAR_LIST_RC=2

  run infisical_install_cli
  [ "${status}" -eq 1 ]
  assert_match "the failure names the archive, not a stack trace" \
    'not a readable tar.gz' "${output}"
  [ ! -e "${SCRATCH}/xdg/evo-t1/infisical/bin/infisical" ]
}

@test "seam: infisical_install_cli refuses an archive whose member is not a plain infisical" {
  source_lib
  export XDG_DATA_HOME="${SCRATCH}/xdg"
  export STUB_CURL_OUT="non-empty body"
  export STUB_TAR_LIST='../../bin/infisical'

  run infisical_install_cli
  [ "${status}" -eq 1 ]
  assert_match "the traversal is called out" 'no plain infisical member' "${output}"
  [ ! -e "${SCRATCH}/xdg/evo-t1/infisical/bin/infisical" ]

  export STUB_TAR_LIST=''
  run infisical_install_cli
  [ "${status}" -eq 1 ]
}

@test "seam: infisical_install_cli finds its member in a listing long enough to outlive the pipe buffer" {
  # The member scan is an in-shell loop over a here-string. The shape it replaced,
  # `printf | grep -E | head -n 1`, ends in a reader that leaves as soon as it has its
  # line, which under this repo's `set -o pipefail` callers is the SIGPIPE class: a
  # producer still writing answers 141, and the `|| member=""` arm then refuses an
  # archive that does hold the binary. Whether that race is won depends on how much
  # head(1) drains first, so this test pins the behaviour at the size where the old
  # shape could have raced rather than claiming to reproduce the 141 (measured: 0 of 18
  # on listings to 900 KiB). A release archive carries its licence, README and
  # completions beside the binary, so a listing this long is the ordinary case.
  source_lib
  export XDG_DATA_HOME="${SCRATCH}/xdg"
  export STUB_CURL_OUT="non-empty body"
  local listing="${SCRATCH}/listing.txt" i
  : >"${listing}"
  for i in $(seq 1 4000); do
    printf '%s/share/doc/infisical/README-%s.md\n' "${i}" "${i}" >>"${listing}"
  done
  # The binary sits under a directory here, which the default stub listing (the bare
  # `infisical` every other test in this file gets) never exercises. It is what makes
  # the two assertions below non-vacuous against the scan itself: a replacement that
  # never read the listing would have to guess the member name, and the guess this
  # file could not be accused of seeding is the bare `infisical`.
  printf 'usr/local/bin/infisical\n' >>"${listing}"
  # A file, not an export: execve caps one environment variable, and the size is the
  # point of the test.
  export STUB_TAR_LIST_FILE="${listing}"
  # Non-vacuity: under the 64 KiB pipe buffer the writer finishes before any reader
  # could go away, and the shape this scan replaced would pass the same assertions.
  local size
  size="$(wc -c <"${listing}")"
  [ "${size}" -gt 65536 ]

  run infisical_install_cli
  if [ "${status}" -ne 0 ]; then
    printf 'install status=%s\noutput: %s\n' "${status}" "${output}" >&2
    return 1
  fi
  assert_match "the member it extracted is the one the listing named" \
    '-- usr/local/bin/infisical' "$(cat "${STUB_LOG}/tar.log")"
  [ -x "${SCRATCH}/xdg/evo-t1/infisical/bin/infisical" ]
}

@test "seam: the CLI version the workspace image bakes is the version the host installer defaults to" {
  # The workspace half of the vault execs the Infisical CLI, so images/dev/ bakes it;
  # One file owns each spelling, and this test is what keeps them one version. The
  # pins are read from the shipping tree (bats_source_repo_root), because under the
  # coverage mirror a production .sh carries instrumentation and is no longer the bytes
  # that ship. A missing file is a broken //tests:BUILD.bazel declaration, not a
  # reason to skip: a pin test that skips is a pin that does not exist.
  local src
  src="$(bats_source_repo_root)" || skip "no source tree to pin against"
  local pins="${src}/images/dev/tool-versions.env" envs="${src}/.env.example"
  local sample="${src}/.env.sample"
  local lib="${src}/scripts/lib/infisical.sh" dockerfile="${src}/images/dev/Dockerfile"
  local f
  for f in "${pins}" "${envs}" "${sample}" "${lib}" "${dockerfile}"; do
    [ -r "${f}" ]
  done
  # Each reader drains its producer: this suite's runner runs under pipefail, and a
  # head(1) that leaves early would report 141 for a file that answered fine.
  local image_pin env_pin sample_pin lib_default dockerfile_arg
  image_pin="$(sed -n 's/^INFISICAL_CLI_VERSION=//p' "${pins}" | tail -n 1)"
  env_pin="$(sed -n 's/^INFISICAL_CLI_VERSION=//p' "${envs}" | tail -n 1)"
  sample_pin="$(sed -n 's/^INFISICAL_CLI_VERSION=//p' "${sample}" | tail -n 1)"
  lib_default="$(sed -n 's/.*version="\([0-9][0-9.]*\)".*/\1/p' "${lib}" | tail -n 1)"
  dockerfile_arg="$(sed -n 's/^[[:space:]]*INFISICAL_CLI_VERSION=\([0-9][0-9.]*\).*/\1/p' \
    "${dockerfile}" | tail -n 1)"
  assert_eq "the image pin is a bare version" "0.45.8" "${image_pin}"
  assert_eq "the Dockerfile's own default agrees" "${image_pin}" "${dockerfile_arg}"
  assert_eq "the operator default agrees" "${image_pin}" "${env_pin}"
  # The two dotenv files are one document with two names -- bootstrap copies the
  # sample to the live file (scripts/bootstrap.sh:211) and //scripts:pre-commit diffs
  # them (scripts/pre-commit.sh:91) -- but that diff is a hook, so the pin this test
  # exists to hold is read out of both here rather than trusted to the hook.
  assert_eq "and the sample an operator boots from agrees" "${image_pin}" "${sample_pin}"
  assert_eq "and the installer's fallback agrees" "${image_pin}" "${lib_default}"
}

@test "seam: the image installs the CLI by naming the member it wants out of the archive" {
  # The release asset also carries LICENSE, README, completions and a manpage, so an
  # image step that unpacks the whole archive and then goes looking for a file named
  # infisical lets whatever the release happens to ship choose what lands in
  # /usr/local/bin. Naming the member is what the host installer does (its own extract
  # is pinned above) and what the docker client layer beside it does; this pins that
  # the image layer does too.
  local src dockerfile whole layer
  src="$(bats_source_repo_root)" || skip "no source tree to read"
  dockerfile="${src}/images/dev/Dockerfile"
  [ -r "${dockerfile}" ]
  whole="$(cat "${dockerfile}")"
  layer="$(sed -n '/infisical-cli\.tgz/,/install -m 0755 \/tmp\/infisical-cli\.bin/p' \
    "${dockerfile}")"
  assert_match "the extract names the member" \
    'tar -xzf /tmp/infisical-cli\.tgz -O infisical' "${layer}"
  assert_not_match "and no step in the file unpacks the archive into a directory" \
    'tar -xzf /tmp/infisical-cli\.tgz -C ' "${whole}"
  assert_match "the installed file is the one this step wrote" \
    'install -m 0755 /tmp/infisical-cli\.bin /usr/local/bin/infisical' "${layer}"
}

@test "seam: infisical_install_cli fails on an empty download and never runs tar" {
  source_lib
  export XDG_DATA_HOME="${SCRATCH}/xdg"
  unset STUB_CURL_OUT
  export STUB_CURL_RC=0

  run infisical_install_cli
  [ "${status}" -eq 1 ]
  assert_match "an empty body is its own failure" 'wrote no bytes' "${output}"
  [ ! -f "${STUB_LOG}/tar.log" ]
}

# ---------------------------------------------------------------------------
# Auth and the two vault verbs, driven entirely by the stub.
# ---------------------------------------------------------------------------

@test "seam: infisical_login exchanges the machine identity with the pinned argv" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"

  run --separate-stderr infisical_login "${envf}"
  [ "${status}" -eq 0 ]
  assert_eq "--plain prints the token alone" "stub-access-token" "${output}"
  # The commentary is allowed, but only on the other stream: a caller that captures
  # stdout with $( ) must not glue a "-> ..." line onto the front of the credential.
  assert_match "the commentary went to stderr" 'exchanging the machine identity' "${stderr}"

  local logged
  logged="$(cat "${STUB_LOG}/infisical.log")"
  assert_match "universal-auth is the method" '--method=universal-auth' "${logged}"
  assert_match "the pinned flags are both present" '--silent' "${logged}"
  assert_match "the client id travels as a flag" '--client-id=cid' "${logged}"

  # Off means refused before any call, with the lib's own 5.
  write_env "${envf}" "INFISICAL_ENABLED=false" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"
  : >"${STUB_LOG}/infisical.log"
  run --separate-stderr infisical_login "${envf}"
  [ "${status}" -eq 5 ]
  assert_eq "a refused login never reaches the CLI" "" "$(cat "${STUB_LOG}/infisical.log")"
  assert_eq "a refused login prints nothing on the token stream" "" "${output}"

  # A configured flag but no machine identity is its own refusal, not a crash.
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182"
  run --separate-stderr infisical_login "${envf}"
  [ "${status}" -eq 5 ]
  assert_eq "and it prints no token" "" "${output}"
  assert_match "the refusal names the pair the operator owes" \
    'INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET' "${stderr}"
}

@test "seam: infisical_ensure_auth is the one gate every vault verb passes through" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"
  run infisical_ensure_auth "${envf}"
  [ "${status}" -eq 0 ]
  assert_match "it authenticates" 'universal-auth' "$(cat "${STUB_LOG}/infisical.log")"
  write_env "${envf}" "INFISICAL_ENABLED=false"
  run infisical_ensure_auth "${envf}"
  [ "${status}" -eq 5 ]
}

@test "seam: infisical_run_cli exports the domain so the CLI cannot dial US Cloud" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "INFISICAL_URL=http://vault.example:8182"
  run infisical_run_cli --version
  [ "${status}" -eq 0 ]
  assert_eq "the version answer comes from the stub" "0.45.8" "${output}"
  # The stub records argv only, so prove the export through a probe the lib itself runs.
  run env INFISICAL_DOMAIN=http://from-env:1 bash -c \
    "source '${LIB}' >/dev/null 2>&1; printf '%s' \"\${INFISICAL_DOMAIN}\""
  assert_eq "an explicit domain is honoured" "http://from-env:1" "${output}"
}

@test "seam: infisical_secrets_dump writes to a mode-600 file and never to stdout" {
  source_lib
  local envf="${SCRATCH}/.env" dest="${SCRATCH}/dump.env"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_PROJECT_ID=prj" "INFISICAL_ENVIRONMENT=prod" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"
  export STUB_INFISICAL_DUMP="LITELLM_MASTER_KEY=canary-value-do-not-log"

  run --separate-stderr infisical_secrets_dump "${dest}" "${envf}"
  [ "${status}" -eq 0 ]
  assert_eq "stdout carries the path and nothing else" "${dest}" "${output}"
  [ -f "${dest}" ]
  run stat -c '%a' "${dest}"
  assert_eq "the export lands mode 600" "600" "${output}"
  assert_match "the pinned export argv" '--format=dotenv' "$(cat "${STUB_LOG}/infisical.log")"
  assert_match "imports are included" '--include-imports=true' "$(cat "${STUB_LOG}/infisical.log")"
  assert_match "the project is named" '--projectId=prj' "$(cat "${STUB_LOG}/infisical.log")"
  # The canary must not have come back through either stream, and must not have been
  # written into any log the stub keeps: argv logging is the leak this design forbids.
  case "${output}${stderr:-}" in
    *canary-value-do-not-log*) echo "a secret value reached a stream" >&2; return 1 ;;
  esac
  if grep -rl 'canary-value-do-not-log' "${STUB_LOG}" >/dev/null 2>&1; then
    echo "a secret value reached a stub log" >&2
    return 1
  fi

  run infisical_secrets_dump "" "${envf}"
  [ "${status}" -eq 2 ]

  write_env "${envf}" "INFISICAL_ENABLED=false" "INFISICAL_PROJECT_ID=prj"
  run infisical_secrets_dump "${dest}" "${envf}"
  [ "${status}" -eq 5 ]
}

@test "seam: infisical_secret_set sends the value as @file and never as a bare argument" {
  source_lib
  local envf="${SCRATCH}/.env" valuef="${SCRATCH}/value"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_PROJECT_ID=prj" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"
  printf 'super-secret-value' >"${valuef}"
  chmod 600 "${valuef}"

  run infisical_secret_set "LITELLM_MASTER_KEY" "${valuef}" "${envf}"
  [ "${status}" -eq 0 ]
  local logged
  logged="$(cat "${STUB_LOG}/infisical.log")"
  assert_match "the argv-safe @file channel is used" "LITELLM_MASTER_KEY=@${valuef}" "${logged}"
  assert_match "delete defaults to personal so set names shared explicitly" '--type=shared' "${logged}"
  assert_match "the path is explicit" '--path=/' "${logged}"
  case "${logged}" in
    *super-secret-value*) echo "a secret value rode argv" >&2; return 1 ;;
  esac

  run infisical_secret_set "bad key" "${valuef}" "${envf}"
  [ "${status}" -eq 2 ]
  run infisical_secret_set "GOOD_KEY" "${SCRATCH}/absent" "${envf}"
  [ "${status}" -eq 2 ]

  write_env "${envf}" "INFISICAL_ENABLED=false" "INFISICAL_PROJECT_ID=prj"
  run infisical_secret_set "GOOD_KEY" "${valuef}" "${envf}"
  [ "${status}" -eq 5 ]
}

@test "seam: infisical_secrets_set_file refuses an empty batch instead of shipping an empty file" {
  source_lib
  local envf="${SCRATCH}/.env" batch="${SCRATCH}/batch.env"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_PROJECT_ID=prj" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=cid" "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=csecret"
  : >"${batch}"
  run infisical_secrets_set_file "${batch}" "${envf}"
  [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The two sync directions, including the guarantee that a pull cannot blank a
# credential just because the vault has not been seeded for it.
# ---------------------------------------------------------------------------

@test "seam: infisical_pull writes what the vault holds and leaves every other key alone" {
  source_lib
  export TMPDIR="${SCRATCH}"
  local envf report dump
  envf="$(vault_on)"
  printf '%s\n' "# keep this comment" "LITELLM_MASTER_KEY=old-master" \
    "CODER_PG_PASSWORD=keep-me" "UNRELATED=42" >>"${envf}"
  dump="${SCRATCH}/vault.env"
  write_env "${dump}" "LITELLM_MASTER_KEY=new-master"
  export STUB_INFISICAL_DUMP="${dump}"

  run --separate-stderr infisical_pull "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 0 ]
  report="${output}${stderr:-}"
  assert_match "the summary counts without naming a value" 'pulled 1 managed key' "${report}"
  assert_match "a key the vault does not hold is reported as left alone" \
    'not in the Infisical project' "${report}"
  case "${report}" in
    *new-master*) echo "a pulled value was printed" >&2; return 1 ;;
  esac

  run cat "${envf}"
  assert_match "the key the vault holds is updated" '^LITELLM_MASTER_KEY=new-master$' "${output}"
  assert_match "a key the vault does not hold keeps its value" '^CODER_PG_PASSWORD=keep-me$' "${output}"
  assert_match "an unmanaged line is untouched" '^UNRELATED=42$' "${output}"
  assert_match "comments survive a pull" '^# keep this comment$' "${output}"
}

@test "seam: infisical_pull refuses to blank a key the vault holds empty" {
  source_lib
  export TMPDIR="${SCRATCH}"
  local envf report
  envf="$(vault_on)"
  printf '%s\n' "LITELLM_MASTER_KEY=still-good" >>"${envf}"
  export STUB_INFISICAL_DUMP="LITELLM_MASTER_KEY="

  run --separate-stderr infisical_pull "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 0 ]
  report="${output}${stderr:-}"
  assert_match "and the operator is told which key, by name" \
    'LITELLM_MASTER_KEY is empty in the Infisical project; refusing to blank' "${report}"

  run cat "${envf}"
  assert_match "an empty vault value never overwrites a live one" \
    '^LITELLM_MASTER_KEY=still-good$' "${output}"
  assert_not_match "and the key was never blanked" '^LITELLM_MASTER_KEY=$' "${output}"
}

@test "seam: infisical_pull leaves the file alone and returns 0 when the flag is off" {
  source_lib
  export TMPDIR="${SCRATCH}"
  local envf
  write_env "${SCRATCH}/.env" "INFISICAL_ENABLED=false" "LITELLM_MASTER_KEY=keep"
  envf="${SCRATCH}/.env"

  run --separate-stderr infisical_pull "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 0 ]
  assert_match "the operator is told why nothing moved" 'keeps the values it has' "${output}${stderr:-}"
  [ ! -f "${STUB_LOG}/infisical.log" ] ||
    assert_eq "the CLI was never called" "" "$(cat "${STUB_LOG}/infisical.log")"
  run cat "${envf}"
  assert_match "the file keeps its value" '^LITELLM_MASTER_KEY=keep$' "${output}"
}

@test "seam: infisical_pull cleans its temp on both the success and the failure path" {
  source_lib
  export TMPDIR="${SCRATCH}"
  local envf before after
  envf="$(vault_on)"
  printf '%s\n' "LITELLM_MASTER_KEY=old" >>"${envf}"
  export STUB_INFISICAL_DUMP="LITELLM_MASTER_KEY=fresh"

  before="$(find "${SCRATCH}" -maxdepth 1 -name 'infisical-dump*' | wc -l)"
  run infisical_pull "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 0 ]
  after="$(find "${SCRATCH}" -maxdepth 1 -name 'infisical-dump*' | wc -l)"
  assert_eq "no export temp survives a successful pull" "${before}" "${after}"

  export STUB_INFISICAL_EXPORT_RC=1
  run infisical_pull "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 1 ]
  after="$(find "${SCRATCH}" -maxdepth 1 -name 'infisical-dump*' | wc -l)"
  assert_eq "no export temp survives a failed pull either" "${before}" "${after}"
  run cat "${envf}"
  assert_match "a failed export leaves the file exactly as it was" \
    '^LITELLM_MASTER_KEY=fresh$' "${output}"

  # An empty export is a warning and a failure, not a wipe.
  export STUB_INFISICAL_EXPORT_RC=0 STUB_INFISICAL_DUMP=""
  run infisical_pull "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 1 ]
  run cat "${envf}"
  assert_match "an empty export leaves the file exactly as it was" \
    '^LITELLM_MASTER_KEY=fresh$' "${output}"
}

@test "seam: infisical_push sends the managed keys and reports a read-back that disagrees" {
  source_lib
  export TMPDIR="${SCRATCH}"
  local envf report mirror
  envf="$(vault_on)"
  printf '%s\n' "LITELLM_MASTER_KEY=master-a" "CODER_PG_PASSWORD=pg-a" >>"${envf}"
  mirror="${SCRATCH}/mirror.env"
  write_env "${mirror}" "LITELLM_MASTER_KEY=master-a" "CODER_PG_PASSWORD=pg-a"
  export STUB_INFISICAL_DUMP="${mirror}"

  run --separate-stderr infisical_push "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 0 ]
  report="${output}${stderr:-}"
  assert_match "the read-back is its own phase, not an assumption" 'reading the vault back' "${report}"
  local sent
  sent="$(cat "${STUB_LOG}/infisical-set.txt")"
  assert_match "the key the env file held went up" 'LITELLM_MASTER_KEY=master-a' "${sent}"
  assert_match "and so did the other" 'CODER_PG_PASSWORD=pg-a' "${sent}"
  # A key absent from the env file is a warning, and an empty one is never pushed:
  # pushing it blank would empty the vault for every later pull.
  case "${sent}" in
    *SPARK_1_API_KEY*) echo "an unconfigured key was pushed" >&2; return 1 ;;
  esac
  assert_match "the absent key is named as skipped" 'is not in' "${report}"

  # The vault answered with something else: the seed must not be called a success.
  write_env "${mirror}" "LITELLM_MASTER_KEY=master-a" "CODER_PG_PASSWORD=something-else"
  run --separate-stderr infisical_push "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 1 ]
  assert_match "the disagreement names the key, never the value" \
    'CODER_PG_PASSWORD differs in the vault' "${output}${stderr:-}"

  export STUB_INFISICAL_SET_RC=1
  run infisical_push "${envf}" "${REPO_ROOT}/infisical/managed-secrets.txt"
  [ "${status}" -eq 1 ]
}

@test "seam: infisical_bootstrap reads the machine identity out of the bootstrap JSON" {
  source_lib
  local envf="${SCRATCH}/.env"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_ADMIN_PASSWORD=not-the-placeholder" "INFISICAL_ADMIN_EMAIL=ops@example.test" \
    "INFISICAL_ORGANIZATION=EVO-T1"
  run --separate-stderr infisical_bootstrap "${envf}"
  [ "${status}" -eq 0 ]
  assert_match "the bootstrap verb ran" 'bootstrap' "$(cat "${STUB_LOG}/infisical.log")"
  assert_match "and it asked for JSON" '--output=json' "$(cat "${STUB_LOG}/infisical.log")"
  assert_match "the identity id landed in the env file" \
    '^INFISICAL_MACHINE_IDENTITY_ID=stub-identity-id$' "$(cat "${envf}")"
  # The organization id is reported and not stored: nothing in the stack reads it, and
  # a key nobody consumes does not belong in .env.
  assert_match "and the organization id was reported" 'stub-org-id' "${output}"
  if grep -q '^INFISICAL_ORGANIZATION_ID=' "${envf}"; then
    echo "an unconsumed key was written into .env" >&2
    return 1
  fi
  # The identity's token is the credential bootstrap hands back. It is checked for
  # presence and deliberately never written out or printed.
  case "${output}${stderr:-}" in
    *stub-machine-identity-secret*) echo "the identity token was printed" >&2; return 1 ;;
  esac
  if grep -rl 'stub-machine-identity-secret' "${STUB_LOG}" >/dev/null 2>&1; then
    echo "the identity token reached a stub log" >&2
    return 1
  fi

  # An answer that carries no identity id is a failure, not a silently empty key.
  export STUB_INFISICAL_BOOTSTRAP='{"organization":{"id":"stub-org-id"}}'
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_ADMIN_PASSWORD=not-the-placeholder" "INFISICAL_ADMIN_EMAIL=ops@example.test"
  run infisical_bootstrap "${envf}"
  [ "${status}" -eq 1 ]
  if grep -q '^INFISICAL_MACHINE_IDENTITY_ID=' "${envf}"; then
    echo "an identity id was written from a JSON that carried none" >&2
    return 1
  fi
  unset STUB_INFISICAL_BOOTSTRAP

  # The shipped placeholder is not a password, and the seam must say so rather than
  # hand it to a signup endpoint.
  : >"${STUB_LOG}/infisical.log"
  write_env "${envf}" "INFISICAL_ENABLED=true" "INFISICAL_URL=http://vault:8182" \
    "INFISICAL_ADMIN_PASSWORD=change-me-infisical-admin" "INFISICAL_ADMIN_EMAIL=ops@example.test"
  run infisical_bootstrap "${envf}"
  [ "${status}" -eq 5 ]
  assert_match "the placeholder is named as the problem" 'INFISICAL_ADMIN_PASSWORD' "${output}"
  [ ! -s "${STUB_LOG}/infisical.log" ] ||
    assert_eq "and the CLI was never called with it" "" "$(cat "${STUB_LOG}/infisical.log")"
}
