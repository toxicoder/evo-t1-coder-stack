#!/usr/bin/env bats
#
# ## install-hooks.bats — the CLI that points core.hooksPath at .githooks
#
# Covers scripts/install-hooks.sh: the three states hook_state distinguishes,
# the guard that refuses to install when the shipped hooks are not in the tree,
# and main's install / --check / --uninstall / unknown-mode arms.
#
# Safety: every test works in a scratch checkout it creates under
# BATS_TEST_TMPDIR and its own git config file, so nothing here reads or writes
# this machine's real hooksPath, and no test needs docker, network, or a stack.
# Real git is required; the suite skips without it rather than passing on a stub.

load 'test_helper'

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  export REPO_ROOT
  SCRIPT="${REPO_ROOT}/scripts/install-hooks.sh"
  [ -f "${SCRIPT}" ] || skip "scripts/install-hooks.sh is not in the tree yet"
  command -v git >/dev/null 2>&1 || skip "git is not installed"
}

# fake_checkout — build a scratch git checkout holding what the CLI reads, and
# print its path. The hooks start executable so the test can prove the installer
# leaves them executable; tests that need them absent remove them first.
fake_checkout() {
  local dir
  dir="$(make_scratch)"
  git init -q "${dir}" || return 1
  : >"${dir}/docker-compose.yml"
  mkdir -p "${dir}/.githooks"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${dir}/.githooks/pre-commit"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${dir}/.githooks/pre-push"
  chmod 755 "${dir}/.githooks/pre-commit" "${dir}/.githooks/pre-push"
  printf '%s' "${dir}"
}

hooks_path_of() {
  git -C "$1" config --get core.hooksPath 2>/dev/null || true
}

# load_hooks_api — pull the two guards into this shell together with the
# reporting helpers they call, so a test can exercise a guard on its own and
# read the return code the CLI acts on.
load_hooks_api() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  unset JSON_MODE
  load_shell_function "${SCRIPT}" hook_state
  load_shell_function "${SCRIPT}" require_hooks_dir
}

@test "install-hooks: install sets core.hooksPath and leaves the hooks executable" {
  local dir
  dir="$(fake_checkout)"
  chmod 644 "${dir}/.githooks/pre-commit" "${dir}/.githooks/pre-push"

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" install
  [ "${status}" -eq 0 ]
  assert_eq "hooksPath" ".githooks" "$(hooks_path_of "${dir}")"
  [ -x "${dir}/.githooks/pre-commit" ] || fail "pre-commit is not executable; git would skip it"
  [ -x "${dir}/.githooks/pre-push" ] || fail "pre-push is not executable; git would skip it"
  assert_match "closing summary" 'summary: 1 ok, 0 warnings, 0 failed' "${output}"
}

@test "install-hooks: --check reports missing, then passes once installed" {
  local dir
  dir="$(fake_checkout)"

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" --check
  [ "${status}" -eq 1 ]
  assert_match "missing state" 'state: missing' "${output}"

  git -C "${dir}" config core.hooksPath .githooks
  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" --check
  [ "${status}" -eq 0 ]
  assert_match "installed state" 'state: installed' "${output}"
}

@test "install-hooks: --check reports a foreign hooksPath and leaves it alone" {
  local dir
  dir="$(fake_checkout)"
  git -C "${dir}" config core.hooksPath /opt/other-hooks

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" --check
  [ "${status}" -eq 1 ]
  assert_match "foreign state" 'state: foreign \(/opt/other-hooks\)' "${output}"
  assert_eq "setting untouched" "/opt/other-hooks" "$(hooks_path_of "${dir}")"
}

@test "install-hooks: --uninstall clears the setting" {
  local dir
  dir="$(fake_checkout)"
  git -C "${dir}" config core.hooksPath .githooks

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" --uninstall
  [ "${status}" -eq 0 ]
  assert_eq "setting cleared" "" "$(hooks_path_of "${dir}")"
}

@test "install-hooks: a checkout missing a shipped hook is refused" {
  local dir
  dir="$(fake_checkout)"
  rm "${dir}/.githooks/pre-push"

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" install
  [ "${status}" -eq 1 ]
  assert_match "names the missing hook" '.githooks/pre-push is missing' "${stderr}"
  assert_eq "nothing was configured" "" "$(hooks_path_of "${dir}")"
}

@test "install-hooks: a non-checkout is refused" {
  local dir
  dir="$(make_scratch)"
  : >"${dir}/docker-compose.yml"
  mkdir -p "${dir}/.githooks"
  : >"${dir}/.githooks/pre-commit"
  : >"${dir}/.githooks/pre-push"

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" install
  [ "${status}" -eq 1 ]
  assert_match "says it is not a checkout" 'not a git checkout' "${stderr}"
}

@test "install-hooks: an unknown mode is refused" {
  local dir
  dir="$(fake_checkout)"

  run --separate-stderr env REPO_ROOT="${dir}" bash "${SCRIPT}" --frobnicate
  [ "${status}" -eq 1 ]
  assert_match "names the bad mode" "unknown mode '--frobnicate'" "${stderr}"
  assert_eq "nothing was configured" "" "$(hooks_path_of "${dir}")"
}

@test "install-hooks: hook_state maps the setting to one of three words" {
  load_hooks_api
  local dir
  dir="$(fake_checkout)"
  ROOT_DIR="${dir}"

  run hook_state
  [ "${status}" -eq 0 ]
  assert_eq "an unset path is missing" "missing" "${output}"

  git -C "${dir}" config core.hooksPath .githooks
  run hook_state
  [ "${status}" -eq 0 ]
  assert_eq "our path is installed" "installed" "${output}"

  git -C "${dir}" config core.hooksPath /opt/other-hooks
  run hook_state
  [ "${status}" -eq 0 ]
  assert_eq "someone else's path is named back" "foreign (/opt/other-hooks)" "${output}"
}

@test "install-hooks: require_hooks_dir accepts a full tree and names a gap" {
  load_hooks_api
  local dir
  dir="$(fake_checkout)"
  ROOT_DIR="${dir}"

  run require_hooks_dir
  [ "${status}" -eq 0 ]
  assert_eq "a complete tree prints nothing" "" "${output}"

  rm "${dir}/.githooks/pre-commit"
  run --separate-stderr require_hooks_dir
  [ "${status}" -eq 1 ]
  assert_match "names the hook that is gone" '.githooks/pre-commit is missing' "${stderr}"
  assert_match "explains why it cannot proceed" 'partial checkout' "${output}"
}
