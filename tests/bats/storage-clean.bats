#!/usr/bin/env bats
#
# ## storage-clean.bats - hermetic coverage for scripts/storage-clean.sh.
#
# The janitor contract pinned here: --check (and a declined prompt) reports
# and touches nothing; a prompt answer of y or --yes sweeps only files older
# than --older-than days (never the fresh ones, never a user-owned config);
# acting re-syncs stack-owned configs and carries a workspace's own API key
# forward; the docker side only ever runs through the stub, either as
# read-only listing or not at all. Docker, and the whole workspace view, can
# be pointed at a scratch tree through --home, so nothing here needs a
# daemon.
#
# The whole suite skips while scripts/storage-clean.sh is absent: a suite
# for a script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_storage_clean_test   (from any cwd)
# Safety: reads the template payloads and the two scripts; writes only under
# the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CLEAN=""
LIB=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CLEAN="${REPO_ROOT}/scripts/storage-clean.sh"
  LIB="${REPO_ROOT}/scripts/lib/config_seed.sh"
  if [ ! -f "${CLEAN}" ] || [ ! -f "${LIB}" ]; then
    skip "the storage-clean script or its lib is not in the tree"
  fi
  use_stubs docker
}

# seed_cache <home> <name> <date> - one file under the swept caches, stamped
# with a given age so --older-than has real boundary cases to sort.
# <date> is YYYY-MM-DD; GNU and BSD touch both honour that once rewritten.
seed_cache() {
  local path day compact
  mkdir -p "${1}/.grok/logs"
  path="${1}/.grok/logs/${2}"
  day="${3}"
  printf 'x\n' >"${path}"
  if ! touch -d "${day}T00:00:00" "${path}" 2>/dev/null; then
    compact="$(printf '%s' "${day}" | tr -d '-')"
    touch -t "${compact}0000" "${path}"
  fi
}

# days_ago <n> — YYYY-MM-DD for n days before today (GNU date -d, BSD date -v).
days_ago() {
  if date -u -d "${1} days ago" +%F >/dev/null 2>&1; then
    date -u -d "${1} days ago" +%F
  else
    date -u -v-"${1}"d +%F
  fi
}

# checksum_tree <dir> — sorted per-file hashes (sha256sum or BSD shasum).
checksum_tree() {
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${1}" && find . -type f -exec sha256sum {} + | sort)
  else
    (cd "${1}" && find . -type f -exec shasum -a 256 {} + | sort)
  fi
}

@test "storage-clean: help, an unknown flag, and a bad --older-than all print the usage" {
  run --separate-stderr bash "${CLEAN}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: bazelisk run //scripts:storage-clean --' "${output}"

  run bash "${CLEAN}" --older-than abc
  [ "${status}" -ne 0 ]
  assert_match "bad cutoff rejected" 'needs a number of days' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "storage-clean: --check lists stale files and writes nothing" {
  local scratch before after
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" old.log '2000-01-01'
  seed_cache "${scratch}/home" fresh.log "$(date +%F)"
  before="${scratch}/before.sha"
  checksum_tree "${scratch}/home" >"${before}"

  STUB_DOCKER_RC=1 run --separate-stderr env STUB_DOCKER_RC=1 bash "${CLEAN}" --check --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_match "stale listed" 'stale: .*old\.log' "${output}"
  assert_not_match "fresh kept out of the list" 'fresh\.log' "${output}"
  after="${scratch}/after.sha"
  checksum_tree "${scratch}/home" >"${after}"
  cmp -s "${before}" "${after}"
}

@test "storage-clean: --older-than counts by age, not by presence" {
  local scratch
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" six.log "$(days_ago 6)"
  seed_cache "${scratch}/home" four.log "$(days_ago 4)"
  run bash "${CLEAN}" --check --older-than 5 --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_match "six-day file listed" 'six\.log' "${output}"
  assert_not_match "four-day file kept out" 'four\.log' "${output}"
}

@test "storage-clean: a declined prompt touches nothing (and so does a closed stdin)" {
  local scratch
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" old.log '2000-01-01'
  printf 'set -g mouse off\n' >"${scratch}/home/.tmux.conf"

  run bash "${CLEAN}" --home "${scratch}/home" </dev/null
  [ "${status}" -eq 0 ]
  assert_match "decline is explained" 'left as it is' "${output}"
  assert_match "stale file still there" 'old\.log' "$(find "${scratch}/home" -type f)"
  assert_match "user tmux.conf still there" 'mouse off' "$(cat "${scratch}/home/.tmux.conf")"

  run bash "${CLEAN}" --home "${scratch}/home" <<<"n"
  [ "${status}" -eq 0 ]
  assert_not_match "no reseed on decline" 're-materialized' "${output}"
}

@test "storage-clean: an accepted prompt sweeps only the stale files" {
  local scratch
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" old.log '2000-01-01'
  seed_cache "${scratch}/home" fresh.log "$(date +%F)"
  run bash "${CLEAN}" --home "${scratch}/home" <<<"y"
  [ "${status}" -eq 0 ]
  [ ! -e "${scratch}/home/.grok/logs/old.log" ]
  [ -e "${scratch}/home/.grok/logs/fresh.log" ]
}

@test "storage-clean: --yes acts without asking and still spares user-owned files" {
  local scratch
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" old.log '2000-01-01'
  printf 'set -g mouse off\n' >"${scratch}/home/.tmux.conf"
  mkdir -p "${scratch}/home/.shared/vscode"
  printf '{\n  "__evoT1Stack": true,\n  "cline.apiKey": "SECRET-KEEP-ME",\n  "terminal.integrated.scrollback": 2000\n}\n' \
    >"${scratch}/home/.shared/vscode/settings.json"

  run bash "${CLEAN}" --yes --older-than 14 --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_not_match "no prompt under --yes" '\[y/N\]' "${output}"
  # The sweep took the stale log...
  [ ! -e "${scratch}/home/.grok/logs/old.log" ]
  # ...the re-sync rewrote the managed settings.json and carried its key...
  assert_contains_file "key carried" "${scratch}/home/.shared/vscode/settings.json" 'SECRET-KEEP-ME'
  assert_contains_file "fresh scrollback" "${scratch}/home/.shared/vscode/settings.json" '"terminal.integrated.scrollback": 10000'
  # ...and the marker-free tmux.conf is user-owned, so it stayed untouched.
  assert_contains_file "user file untouched" "${scratch}/home/.tmux.conf" 'set -g mouse off'
}

@test "storage-clean: the dev project is reported by name and can be renamed" {
  local scratch
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" old.log '2000-01-01'

  run bash "${CLEAN}" --check --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_match "default project listed" 'volume ls -q --filter name=evo-t1-dev' "$(stub_log docker)"

  run bash "${CLEAN}" --check --project-name evo-t1-review --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_match "renamed project listed" 'volume ls -q --filter name=evo-t1-review' "$(stub_log docker)"
}

@test "config_seed: seed_volume_kind classifies exactly the kinds the stack keeps" {
  # shellcheck source=/dev/null
  source "${LIB}"
  [ "$(seed_volume_kind grok-profile-coder)" = "grok-config" ]
  [ "$(seed_volume_kind vscode-settings-coder)" = "shared-config" ]
  [ "$(seed_volume_kind ws-demo-home)" = "home" ]
  [ "$(seed_volume_kind ws-demo-dind-lib)" = "docker-lib" ]
  run seed_volume_kind some-other-volume
  [ "${status}" -ne 0 ]
}

@test "config_seed: seed_sweep_stale lists first and deletes only on demand" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${CLEAN}" sweep_stale_files
  local scratch listing
  scratch="$(make_scratch)"
  seed_cache "${scratch}/home" old.log '2000-01-01'
  seed_cache "${scratch}/home" fresh.log "$(date +%F)"

  listing="$(seed_sweep_stale "" 30 list "${scratch}/home/.grok/logs")"
  assert_match "old listed" 'old\.log' "${listing}"
  assert_not_match "fresh not listed" 'fresh\.log' "${listing}"

  # sweep_stale_files wraps the same helper; under check=1 it must stay
  # read-only, and under check=0 it must delete.
  run --separate-stderr sweep_stale_files "" "${scratch}/home" 30 1
  [ "${status}" -eq 0 ]
  assert_not_match "check kept the old file" 'removed' "${output}"
  [ -e "${scratch}/home/.grok/logs/old.log" ]
  run --separate-stderr sweep_stale_files "" "${scratch}/home" 30 0
  [ "${status}" -eq 0 ]
  [ ! -e "${scratch}/home/.grok/logs/old.log" ]
  [ -e "${scratch}/home/.grok/logs/fresh.log" ]
}

@test "config_seed: seed_container_seed drives everything through seed_container_exec and seed_target_owner" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # A host probe never touches docker, and the empty-container guard keeps a
  # malformed call from firing a blind docker exec.
  run seed_container_exec "" "echo x" sh
  [ "${status}" -ne 0 ]
  assert_eq "empty container rejected" "1" "${status}"
  run seed_container_exec --stdin "" "echo x" sh
  [ "${status}" -ne 0 ]

  local stage
  stage="$(mktemp -d "${BATS_TEST_TMPDIR}/stage.XXXXXX")"
  # seed_container_seed in host mode (empty target) must reach the same
  # decisions through the same helpers the container path uses.
  local home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${home}"
  run --separate-stderr seed_container_seed "" "${home}" "${REPO_ROOT}" "${stage}" 0 0
  assert_match "fresh seed ran" 'seeded' "${output}"
  assert_file_exists "tmux.conf seeded" "${home}/.tmux.conf"
  assert_match "dollar-brace unfolded" 'terminal.integrated.cwd.*\$\{workspaceFolder\}' "$(cat "${home}/.shared/vscode/settings.json")"
  rm -rf "${stage}"
}

@test "config_seed: report_disk_usage keeps working when the docker CLI refuses to answer" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${CLEAN}" report_disk_usage
  export STUB_DOCKER_RC=1
  run --separate-stderr report_disk_usage evo-t1-dev
  [ "${status}" -eq 0 ]
  assert_match "dead daemon reported, not fatal" 'did not answer' "${output}"
}

@test "config_seed: seed_workspace_containers lists workspaces and drops the sidecar" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # The daemon's name list arrives through the docker stub: plain services and
  # the dind sidecar are never reseed or sweep targets, so neither may pass
  # the filter unchanged.
  export STUB_COMPOSE_PS=$'db\npostgres\ncoder-alice-ws1\ncoder-alice-ws1-dind-sidecar\ncoder-bob-notes'
  run --separate-stderr seed_workspace_containers
  [ "${status}" -eq 0 ]
  [ "${output}" = $'coder-alice-ws1\ncoder-bob-notes' ]
  [ "$(stub_log_count docker)" -eq 1 ]

  # A daemon that does not answer yields "nothing found", not an error.
  export STUB_COMPOSE_PS='coder-alice-ws1'
  export STUB_COMPOSE_PS_RC=1
  run --separate-stderr seed_workspace_containers
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}
