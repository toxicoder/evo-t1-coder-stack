#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## update-configs.bats - hermetic coverage for scripts/update-configs.sh.
#
# The contract pinned here: the env pass is driven by the <name>.env.example
# twins a checkout ships, and env_pairs has to FIND them - the one at the repo
# root is a dotfile, which a plain glob walks straight past, and a pass that
# finds no twin reports nothing at all. A reconcile keeps what the operator set,
# parks what the new twin no longer declares instead of deleting it, and prints
# no value that looks like a credential. --dry-run writes nothing, a usage error
# prints the usage, and the workspace pass says which docker daemon it
# addressed, because inside a workspace an empty `docker ps` means the
# workspace's own sidecar and not a stack that is down.
#
# The whole suite skips while scripts/update-configs.sh is absent: a suite for a
# script that does not exist yet has no right to fail the gate.
#
# docker only ever resolves through the tool stub, and no test here needs a
# daemon: --home points the workspace pass at a scratch tree, and
# STUB_COMPOSE_PS / STUB_COMPOSE_PS_RC drive the stub's two daemon shapes.
#
# Usage: bats tests/bats/update-configs.bats
# Safety: hermetic. Reads the repo tree; writes only under the per-test scratch.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB_DIR=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/update-configs.sh"
  LIB_DIR="${REPO_ROOT}/scripts/lib"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${LIB_DIR}/config_seed.sh" ]; then
    skip "scripts/update-configs.sh or its lib is not in the tree"
  fi
  use_stubs docker
  # The two libs the entry script sources, so a test that lifts one function
  # out of it still has the helpers that function calls (env_get, note, warn,
  # has_tool) and the fragments is_secret_key sorts by.
  # shellcheck source=/dev/null
  source "${LIB_DIR}/common.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config_seed.sh"
}

# scratch_root - a directory that proves itself a checkout, so resolve_repo_root
# has something to find and the env pass has somewhere to work.
scratch_root() {
  local dir
  dir="$(make_scratch)"
  printf 'x\n' >"${dir}/docker-compose.yml"
  printf '%s' "${dir}"
}

@test "update-configs: --help prints the usage, and so does every usage error" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: update-configs' "${output}"

  run --separate-stderr bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  assert_match "usage on a bare call" 'usage: update-configs' "${output}"

  run --separate-stderr bash "${SCRIPT}" --dry-run
  [ "${status}" -eq 1 ]
  assert_match "a flag before the subcommand is a usage error" 'usage: update-configs' "${output}"

  run --separate-stderr bash "${SCRIPT}" env --bogus
  [ "${status}" -eq 1 ]
  assert_match "the bad flag is named" 'unknown option: --bogus' "${stderr}"

  # None of those four runs reached a docker CLI.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "update-configs: resolve_repo_root only accepts a directory holding docker-compose.yml" {
  load_shell_function "${SCRIPT}" resolve_repo_root

  local nowhere="${BATS_TEST_TMPDIR}/nowhere"
  local proven="${BATS_TEST_TMPDIR}/proven"
  mkdir -p "${nowhere}" "${proven}/scripts"
  printf 'x\n' >"${proven}/docker-compose.yml"

  # Shadowed, not exported: these four are what the probe reads, and a
  # leftover value from the harness would answer the question for it.
  # BUILD_WORKSPACE_DIRECTORY is assigned (not local) so a Bazel-exported
  # value is overwritten for the `run` subshell too.
  REPO_ROOT=""
  GITHUB_WORKSPACE=""
  BUILD_WORKSPACE_DIRECTORY=""
  SELF_DIR="${nowhere}"
  cd "${nowhere}"

  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 5 ]
  assert_match "an unresolvable root is reported" 'unresolvable repo root' "${stderr}"
  assert_match "the marker it wanted is named" 'need docker-compose.yml' "${stderr}"

  # The cwd probe is what makes a runfiles copy work: docker-compose.yml
  # travels there as a copy, beside the script.
  cd "${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "the cwd marker is enough" "${proven}" "${output}"

  cd "${nowhere}"
  REPO_ROOT="${proven}"
  run --separate-stderr resolve_repo_root
  assert_eq "an explicit REPO_ROOT wins" "${proven}" "${output}"

  # The third probe is the directory beside the script, which is how a run
  # under Bazel finds its runfiles copy of the tree.
  SELF_DIR="${proven}/scripts"
  REPO_ROOT=""
  cd "${nowhere}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "the copy beside the script is a root" "${proven}/scripts/.." "${output}"
}

@test "update-configs: resolve_repo_root prefers BUILD_WORKSPACE_DIRECTORY over PWD" {
  # bazelisk run sets cwd to the runfiles copy (which has docker-compose.yml
  # and .env.example) and BUILD_WORKSPACE_DIRECTORY to the checkout, which is
  # the only place the gitignored live .env lives.
  load_shell_function "${SCRIPT}" resolve_repo_root
  workspace="$(make_scratch)/workspace"
  runfiles="$(make_scratch)/runfiles"
  mkdir -p "${workspace}" "${runfiles}/scripts"
  printf 'x\n' >"${workspace}/docker-compose.yml"
  printf 'x\n' >"${runfiles}/docker-compose.yml"
  REPO_ROOT=""
  unset GITHUB_WORKSPACE
  BUILD_WORKSPACE_DIRECTORY="${workspace}"
  cd "${runfiles}"
  SELF_DIR="${runfiles}/scripts"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  assert_eq "workspace wins" "${workspace}" "${output}"
}

@test "update-configs: env_pairs pairs every twin with its live file, dotfile included" {
  load_shell_function "${SCRIPT}" env_pairs

  local root
  root="$(scratch_root)"
  touch "${root}/project.env.example" "${root}/dev-stack.env.example" "${root}/notes.txt"

  run --separate-stderr env_pairs "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the visible twin is paired" 'project\.env[[:space:]]' "${output}"
  assert_match "the second twin is paired" 'dev-stack\.env[[:space:]]' "${output}"
  assert_not_match "a non-env file is ignored" 'notes.txt' "${output}"
  assert_eq "one line per twin" '2' "$(printf '%s\n' "${output}" | grep -c .)"

  # The twin at the repo root is a dotfile. A glob cannot see it, and a pass
  # that sees no twin reports nothing at all, so the dotfile has to count.
  local hidden
  hidden="$(make_scratch)"
  touch "${hidden}/.env.example"
  run --separate-stderr env_pairs "${hidden}"
  assert_match "the hidden twin is paired too" '\.env[[:space:]].*\.env\.example$' "${output}"

  # dev-stack.env is generated and has no twin of its own; it still has to be
  # walked, so it pairs with .env.example.
  printf 'X=1\n' >"${hidden}/dev-stack.env"
  run --separate-stderr env_pairs "${hidden}"
  assert_match "the generated live file is paired" 'dev-stack\.env[[:space:]].*\.env\.example$' "${output}"

  # A missing root is a report, not a failure.
  run --separate-stderr env_pairs "${BATS_TEST_TMPDIR}/nowhere"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "update-configs: is_secret_key sorts a credential key from a plain one" {
  load_shell_function "${SCRIPT}" is_secret_key
  STACK_SECRET_KEYS='KEY SECRET TOKEN PASSWORD'

  run --separate-stderr is_secret_key LITELLM_MASTER_KEY
  [ "${status}" -eq 0 ]
  run --separate-stderr is_secret_key GITHUB_TOKEN
  [ "${status}" -eq 0 ]
  run --separate-stderr is_secret_key SESSION_SECRET
  [ "${status}" -eq 0 ]
  run --separate-stderr is_secret_key DOCKER_PASSWORD
  [ "${status}" -eq 0 ]
  run --separate-stderr is_secret_key CODER_ACCESS_URL
  [ "${status}" -eq 1 ]
  run --separate-stderr is_secret_key HOME_NETWORK
  [ "${status}" -eq 1 ]
}

@test "update-configs: is_placeholder_value treats YOUR_LAN_IP as unfinished" {
  load_shell_function "${SCRIPT}" is_placeholder_value

  run --separate-stderr is_placeholder_value ""
  [ "${status}" -eq 0 ]
  run --separate-stderr is_placeholder_value "change-me-please"
  [ "${status}" -eq 0 ]
  run --separate-stderr is_placeholder_value "NOTSET"
  [ "${status}" -eq 0 ]
  run --separate-stderr is_placeholder_value "https://YOUR_LAN_IP:3001"
  [ "${status}" -eq 0 ]
  run --separate-stderr is_placeholder_value "https://coder.example.invalid"
  [ "${status}" -eq 1 ]
}

@test "update-configs: key_state describes a value and never prints it" {
  load_shell_function "${SCRIPT}" is_placeholder_value
  load_shell_function "${SCRIPT}" key_state

  run --separate-stderr key_state ""
  assert_eq "an empty value" 'empty' "${output}"
  run --separate-stderr key_state "change-me-please"
  assert_eq "a placeholder" 'still the placeholder' "${output}"
  run --separate-stderr key_state "NOTSET"
  assert_eq "the unset sentinel" 'still the placeholder' "${output}"
  run --separate-stderr key_state "https://YOUR_LAN_IP:3001"
  assert_eq "the LAN-IP token" 'still the placeholder' "${output}"
  run --separate-stderr key_state "https://coder.example.invalid"
  assert_eq "a real value" 'set' "${output}"

  run --separate-stderr key_state "ghp_abcdefghijklmnop"
  assert_not_match "the value itself never reaches stdout" 'abcdefghijklmnop' "${output}"
}

@test "update-configs: key_comment lifts the block above a key and stops at the gap" {
  load_shell_function "${SCRIPT}" key_comment

  local file="${BATS_TEST_TMPDIR}/twin.example"
  printf '# An explanation.\n# A second line.\n\n# The key nobody documented.\nSOLO_KEY=one\nSOLO2=two\n' \
    >"${file}"

  # A blank line separates the two blocks, so only the one touching the key is
  # the explanation for it.
  run --separate-stderr key_comment "${file}" SOLO_KEY
  assert_match "the block beside the key is taken" 'The key nobody documented' "${output}"
  assert_not_match "the block above the gap stays put" 'An explanation' "${output}"

  # A key with nothing above it has nothing to explain it.
  run --separate-stderr key_comment "${file}" SOLO2
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run --separate-stderr key_comment "${file}" ABSENT_KEY
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run --separate-stderr key_comment "${BATS_TEST_TMPDIR}/no-such-twin" SOLO_KEY
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "update-configs: env_retired_keys names only the keys the twin dropped" {
  load_shell_function "${SCRIPT}" env_retired_keys

  local root
  root="$(scratch_root)"
  printf 'THING_TOKEN=change-me\nNEW_KEY=default-value\n' >"${root}/project.env.example"
  printf 'THING_TOKEN=keepme\nOLD_KEY=stale-value\n' >"${root}/project.env"

  run --separate-stderr env_retired_keys "${root}/project.env" "${root}/project.env.example"
  [ "${status}" -eq 0 ]
  assert_match "the retired key is named" '^OLD_KEY$' "${output}"
  assert_not_match "a key the twin still declares is not named" 'THING_TOKEN' "${output}"

  run --separate-stderr env_retired_keys "${root}/absent.env" "${root}/project.env.example"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "update-configs: env_sync reconciles one pair and writes the merge where told" {
  load_shell_function "${SCRIPT}" is_placeholder_value
  load_shell_function "${SCRIPT}" key_state
  load_shell_function "${SCRIPT}" env_retired_keys
  load_shell_function "${SCRIPT}" env_sync

  local root stage
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\nTHING_URL=https://example.invalid\nNEW_KEY=default-value\n' \
    >"${root}/project.env.example"
  printf 'THING_TOKEN=keepme-secret\nOLD_KEY=stale-value\n' >"${root}/project.env"

  # A pair with no live file has nothing to port, and says nothing: the report
  # is about what the operator had set.
  run --separate-stderr env_sync "${root}/absent.env" "${root}/project.env.example" ""
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  # With no twin there is nothing to reconcile against, and that is a note.
  run --separate-stderr env_sync "${root}/project.env" "${root}/absent.example" ""
  [ "${status}" -eq 0 ]
  assert_match "a missing twin is a note" 'nothing to reconcile it against' "${output}"

  run --separate-stderr env_sync "${root}/project.env" "${root}/project.env.example" ""
  [ "${status}" -eq 0 ]
  assert_match "a kept value is reported" 'THING_TOKEN: your value kept' "${output}"
  assert_match "a new key is reported" 'NEW_KEY: new in this update' "${output}"
  assert_match "a retired key is reported" 'OLD_KEY' "${output}"
  assert_not_match "no value reaches stdout" 'keepme-secret' "${output}"

  # With a staging file named, the same walk writes the merged file, line by
  # line off the twin, so each key stays beside the comment that explains it.
  stage="$(make_scratch)"
  run --separate-stderr env_sync "${root}/project.env" "${root}/project.env.example" "${stage}/next"
  [ "${status}" -eq 0 ]
  assert_contains_file "the operator's value survived" "${stage}/next" '^THING_TOKEN=keepme-secret$'
  assert_contains_file "a new key takes the example default" "${stage}/next" '^NEW_KEY=default-value$'
  assert_contains_file "the retired key is parked, not deleted" "${stage}/next" '^#OLD_KEY=stale-value$'
  assert_contains_file "the parked key says why" "${stage}/next" 'no longer declares'
  assert_contains_file "the comment that explains a key survived" "${stage}/next" '^# the token$'
}

@test "update-configs: env_ask lists what is missing and only writes through a terminal" {
  load_shell_function "${SCRIPT}" is_placeholder_value
  load_shell_function "${SCRIPT}" key_state
  load_shell_function "${SCRIPT}" key_comment
  load_shell_function "${SCRIPT}" is_secret_key
  load_shell_function "${SCRIPT}" env_ask
  STACK_SECRET_KEYS='KEY SECRET TOKEN PASSWORD'

  local root file
  root="$(scratch_root)"
  file="${root}/project.env"
  printf '# the token\nTHING_TOKEN=change-me\nTHING_URL=https://example.invalid\n' \
    >"${root}/project.env.example"
  printf 'THING_TOKEN=change-me\nTHING_URL=\n' >"${file}"

  # Prompting off: the keys are listed, nothing is asked and nothing is written.
  run --separate-stderr env_ask "${root}/project.env.example" "${file}" 0
  [ "${status}" -eq 0 ]
  assert_match "the count is stated" '2 key\(s\) to review' "${output}"
  assert_match "the placeholder key is named" 'THING_TOKEN' "${output}"
  assert_match "the empty key is named" 'THING_URL' "${output}"
  assert_contains_file "the file is untouched" "${file}" '^THING_TOKEN=change-me$'

  # Prompting with no terminal to ask through is a warning. It must not hang on
  # a closed stdin and must not guess an answer.
  run --separate-stderr env_ask "${root}/project.env.example" "${file}" 1
  [ "${status}" -eq 0 ]
  assert_match "the missing terminal is named" 'no terminal to ask through' "${output}"
  assert_contains_file "the file still holds what it held" "${file}" '^THING_TOKEN=change-me$'
}

@test "update-configs: env --dry-run reconciles a checkout and writes nothing" {
  local root
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\nTHING_URL=https://example.invalid\nKEEP_KEY=x\n' \
    >"${root}/project.env.example"
  printf 'THING_TOKEN=keepme-secret\nRETIRED_SECRET=stale-value\n' >"${root}/project.env"
  chmod 600 "${root}/project.env"

  run --separate-stderr bash "${SCRIPT}" env --dry-run --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the kept value is reported" 'THING_TOKEN: your value kept' "${output}"
  assert_match "the new key is reported" 'THING_URL: new in this update' "${output}"
  assert_match "the retired key is reported" 'RETIRED_SECRET' "${output}"
  assert_not_match "a secret value never reaches stdout" 'keepme-secret' "${output}"

  # --dry-run is a report: the live file comes out exactly as it went in.
  assert_contains_file "the live file still holds what it held" "${root}/project.env" \
    '^RETIRED_SECRET=stale-value$'
  assert_not_match "nothing was moved to the trailer yet" 'no longer declares' \
    "$(cat "${root}/project.env")"
}

@test "update-configs: env rewrites the live file, keeps its mode, and keeps its values" {
  local root
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\nTHING_URL=https://example.invalid\nKEEP_KEY=x\n' \
    >"${root}/project.env.example"
  printf 'THING_TOKEN=keepme-secret\nRETIRED_SECRET=stale-value\n' >"${root}/project.env"
  chmod 600 "${root}/project.env"

  run --separate-stderr bash "${SCRIPT}" env --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the rewrite is announced" 'project.env rewritten from project.env.example' "${output}"
  assert_match "the per-key detail is printed, not swallowed" 'THING_TOKEN: your value kept' "${output}"
  assert_not_match "no credential reaches stdout" 'keepme-secret' "${output}"
  assert_not_match "nor does the retired key's value" 'stale-value' "${output}"

  assert_contains_file "the operator's value survived the rewrite" "${root}/project.env" \
    '^THING_TOKEN=keepme-secret$'
  assert_contains_file "the new key arrived with its default" "${root}/project.env" \
    '^THING_URL=https://example.invalid$'
  assert_contains_file "a key the twin still declares stayed live" "${root}/project.env" \
    '^KEEP_KEY=x$'
  # A key the twin dropped is not deleted: it moves to the trailer, commented
  # out, where the reason it was set stays readable.
  assert_contains_file "the retired key is parked, commented out" "${root}/project.env" \
    '^#RETIRED_SECRET=stale-value$'
  [ "$(stat -c '%a' "${root}/project.env" 2>/dev/null || stat -f '%OLp' "${root}/project.env")" = "600" ]
}

@test "update-configs: a checkout with no live env file says so and moves on" {
  local root
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\n' >"${root}/project.env.example"

  run --separate-stderr bash "${SCRIPT}" env --dry-run --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the absent live file is named" 'no project.env here' "${output}"
  assert_match "the twin it would have used is named" 'project.env.example' "${output}"

  # A twin that declares no key means every key the live file sets has been
  # retired. Nothing is deleted and nothing is silently kept: each one is
  # reported and parked, commented out, beside the reason it was set.
  printf 'not a key line\n' >"${root}/project.env.example"
  printf 'THING_TOKEN=keepme-secret\n' >"${root}/project.env"
  chmod 600 "${root}/project.env"
  run --separate-stderr bash "${SCRIPT}" env --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the retired key is reported" '1 key\(s\) this update no longer reads' "${output}"
  assert_contains_file "the retired key is parked, not deleted" "${root}/project.env" \
    '^#THING_TOKEN=keepme-secret$'
}

@test "update-configs: env_live_files names only the live files that exist" {
  load_shell_function "${SCRIPT}" env_pairs
  load_shell_function "${SCRIPT}" env_live_files

  local root
  root="$(scratch_root)"
  printf 'K=1\n' >"${root}/project.env.example"
  printf 'K=1\n' >"${root}/.env.example"
  printf 'K=keep\n' >"${root}/.env"
  printf 'K=dev\n' >"${root}/dev-stack.env"

  run --separate-stderr env_live_files "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the root env file is listed" '\.env$' "${output}"
  assert_match "the generated live file is listed" 'dev-stack.env' "${output}"
  assert_not_match "the twin is not a live file" 'project.env$' "${output}"
}

@test "update-configs: env_reuse_value prefers a sibling's real value over a placeholder" {
  load_shell_function "${SCRIPT}" is_placeholder_value
  load_shell_function "${SCRIPT}" env_reuse_value

  local root
  root="$(scratch_root)"
  printf 'THING_TOKEN=change-me\n' >"${root}/dev-stack.env"
  printf 'THING_TOKEN=keepme-secret\n' >"${root}/.env"

  run --separate-stderr env_reuse_value THING_TOKEN "${root}/dev-stack.env" \
    "${root}/.env" "${root}/dev-stack.env"
  assert_eq "the sibling's value is reused" 'keepme-secret' "${output}"

  run --separate-stderr env_reuse_value MISSING "${root}/dev-stack.env" "${root}/.env"
  [ -z "${output}" ]
}

@test "update-configs: env_set_key rewrites one assignment and env_seed_live copies the twin" {
  load_shell_function "${SCRIPT}" env_set_key
  load_shell_function "${SCRIPT}" env_seed_live

  local root
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\nKEEP=x\n' >"${root}/project.env.example"
  printf 'THING_TOKEN=change-me\nKEEP=x\n' >"${root}/project.env"

  run --separate-stderr env_set_key "${root}/project.env" THING_TOKEN 'keepme-secret'
  [ "${status}" -eq 0 ]
  assert_contains_file "the key was rewritten" "${root}/project.env" '^THING_TOKEN=keepme-secret$'
  assert_contains_file "the neighbour is untouched" "${root}/project.env" '^KEEP=x$'

  run --separate-stderr env_seed_live "${root}/project.env.example" "${root}/fresh.env"
  [ "${status}" -eq 0 ]
  assert_match "the create is announced" 'created fresh.env from project.env.example' "${output}"
  assert_contains_file "the twin was copied" "${root}/fresh.env" '^THING_TOKEN=change-me$'
  [ "$(stat -c '%a' "${root}/fresh.env" 2>/dev/null || stat -f '%OLp' "${root}/fresh.env")" = "600" ]
}

@test "update-configs: env_ask lists a key that is new this update" {
  load_shell_function "${SCRIPT}" is_placeholder_value
  load_shell_function "${SCRIPT}" is_secret_key
  load_shell_function "${SCRIPT}" key_state
  load_shell_function "${SCRIPT}" key_comment
  load_shell_function "${SCRIPT}" env_reuse_value
  load_shell_function "${SCRIPT}" env_set_key
  load_shell_function "${SCRIPT}" env_ask
  STACK_SECRET_KEYS='KEY SECRET TOKEN PASSWORD'

  local root
  root="$(scratch_root)"
  printf 'OLD=keep\nNEW_KEY=default-value\n' >"${root}/project.env.example"
  printf 'OLD=keep\nNEW_KEY=default-value\n' >"${root}/project.env"
  printf 'OLD=keep\n' >"${root}/orig.env"

  run --separate-stderr env_ask "${root}/project.env.example" "${root}/project.env" 0 \
    "${root}/orig.env"
  [ "${status}" -eq 0 ]
  assert_match "the new key is listed" 'NEW_KEY' "${output}"
  assert_not_match "a kept key is not listed" 'OLD' "${output}"
}

@test "update-configs: env --interactive without a terminal warns and fills nothing" {
  local root
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\n' >"${root}/project.env.example"
  printf 'THING_TOKEN=change-me\n' >"${root}/project.env"

  run --separate-stderr bash "${SCRIPT}" env --interactive --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the missing terminal is named" 'no terminal to ask through' "${output}"
  assert_contains_file "the placeholder is left alone" "${root}/project.env" \
    '^THING_TOKEN=change-me$'
}

@test "update-configs: daemon_vantage names the daemon a workspace shell can reach" {
  load_shell_function "${SCRIPT}" daemon_vantage

  # Inside a workspace the only daemon docker can address is that workspace's
  # own sidecar, and saying so out loud is the whole point of this line.
  CODER_WORKSPACE_ID="95b7eb7f" DOCKER_HOST="tcp://dind:2375" \
    run --separate-stderr daemon_vantage
  [ "${status}" -eq 0 ]
  assert_match "the sidecar is named" 'sidecar daemon is all that docker here can reach' "${output}"
  assert_match "the daemon address is printed" 'tcp://dind:2375' "${output}"

  # On a host shell the configured address is what gets named.
  CODER_WORKSPACE_ID="" DOCKER_HOST="unix:///run/docker.sock" \
    run --separate-stderr daemon_vantage
  assert_match "the host daemon is named" 'unix:///run/docker.sock' "${output}"

  # No docker CLI at all is its own answer, and it needs no daemon either.
  has_tool() { return 1; } # shellcheck disable=SC2329
  CODER_WORKSPACE_ID="" DOCKER_HOST="" run --separate-stderr daemon_vantage
  assert_match "a missing CLI is named" 'daemon: no docker CLI on PATH' "${output}"
}

@test "update-configs: workspace inside a workspace says where it looked and calls no daemon" {
  # This is the shape an operator hits from a terminal inside a workspace: an
  # empty `docker ps` there is the sidecar, and silence about it reads as
  # "the stack is down".
  run --separate-stderr env CODER_WORKSPACE_ID="95b7eb7f" DOCKER_HOST="tcp://dind:2375" \
    bash "${SCRIPT}" workspace
  [ "${status}" -eq 0 ]
  assert_match "the vantage is printed" 'sidecar daemon is all that docker here can reach' "${output}"
  assert_match "the reason nothing ran is printed" 'nothing to reseed from here' "${output}"
  assert_match "the way out is printed" 'Run this in a host shell' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "update-configs: workspace names the containers a daemon answers for" {
  local root="${BATS_TEST_TMPDIR}/root"
  mkdir -p "${root}"
  printf 'x\n' >"${root}/docker-compose.yml"

  # The stub refuses every probe, which is the daemon-down shape: the answer
  # has to be a sentence, not an empty list.
  run --separate-stderr env STUB_COMPOSE_PS_RC=1 \
    bash "${SCRIPT}" workspace --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "an empty stack is reported as empty" \
    'no coder-\* workspace container answered' "${output}"

  # A container the daemon does name is addressed by name, and the reseed
  # reaches it through one docker exec per probe.
  local home="${BATS_TEST_TMPDIR}/hosthome"
  mkdir -p "${home}"
  run --separate-stderr env STUB_COMPOSE_PS="coder-self-coder" HOME="${home}" \
    bash "${SCRIPT}" workspace --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the named container is addressed" 'coder-self-coder' "${output}"
  assert_match "the reseed went through the docker stub" 'docker exec' "$(stub_log docker)"
}

@test "update-configs: workspace --home reseeds a host tree shaped like a workspace HOME" {
  local home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${home}/.shared/vscode" "${home}/.grok"
  printf 'set -g mouse off\n' >"${home}/.tmux.conf"
  printf '{\n  "__evoT1Stack": true,\n  "cline.apiKey": "KEEP-ME",\n  "roo.openaiApiKey": "KEEP-ME"\n}\n' \
    >"${home}/.shared/vscode/settings.json"
  printf 'the operator wrote this by hand\n' >"${home}/.grok/AGENTS.md"

  # --dry-run names what would change and writes nothing; a file with no
  # managed-by marker belongs to the user, who has to opt in with --force.
  run --separate-stderr bash "${SCRIPT}" workspace --dry-run --home "${home}"
  [ "${status}" -eq 0 ]
  assert_match "the hand-written file is left alone" 'user-owned, left alone' "${output}"
  assert_contains_file "the hand-written file is intact" "${home}/.grok/AGENTS.md" \
    'operator wrote this by hand'

  # The seven reseed targets seed_seed_targets lists are all home-relative, so
  # a host --home tree has all seven to fill.
  run --separate-stderr bash "${SCRIPT}" workspace --home "${home}"
  [ "${status}" -eq 0 ]
  assert_match "the shared agents file is reseeded" '\.grok/AGENTS\.md' "${output}"
  assert_match "the editor settings are re-rendered" '\.shared/vscode/settings\.json' "${output}"
  assert_contains_file "a hand-written file survives without --force" "${home}/.grok/AGENTS.md" \
    'operator wrote this by hand'
  assert_contains_file "the re-rendered settings still parse as JSON" \
    "${home}/.shared/vscode/settings.json" '"__evoT1Stack": true'
  # Per-workspace values are carried forward, because this file is rendered per
  # workspace and a copy from the host would move that workspace's settings.
  assert_contains_file "the editor's own key is carried forward" \
    "${home}/.shared/vscode/settings.json" 'KEEP-ME'

  # A named target that does not exist is a note, and nothing else is guessed.
  run --separate-stderr bash "${SCRIPT}" workspace --home "${BATS_TEST_TMPDIR}/absent-dir"
  [ "${status}" -eq 0 ]
  assert_match "the absent directory is named" 'directory to reseed into - skipped' "${output}"
}

@test "update-configs: --force lets a reseed overwrite a user-owned file" {
  local home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${home}/.grok"
  printf 'the operator wrote this by hand\n' >"${home}/.grok/AGENTS.md"

  run --separate-stderr bash "${SCRIPT}" workspace --force --home "${home}"
  [ "${status}" -eq 0 ]
  assert_match "the override is taken" 'OVERWRITTEN under --force' "${output}"
  assert_not_match "the hand-written text is replaced" 'operator wrote this by hand' \
    "$(cat "${home}/.grok/AGENTS.md")"
}

@test "update-configs: all runs the env pass and then the workspace pass" {
  local root
  root="$(scratch_root)"
  printf '# the token\nTHING_TOKEN=change-me\n' >"${root}/project.env.example"
  printf 'THING_TOKEN=keepme-secret\n' >"${root}/project.env"

  run --separate-stderr bash "${SCRIPT}" all --dry-run --from "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the env pass ran" 'env files reconcile against' "${output}"
  assert_match "the workspace pass ran" 'workspace configs re-materialize from' "${output}"
  assert_match "the placeholder key is still listed" 'THING_TOKEN' "${output}"
}
