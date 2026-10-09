#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## workspace.bats — hermetic coverage for scripts/lib/workspace.sh and
# scripts/new-workspace.sh.
#
# git is a per-test fake. docker, timeout, and coder are the shared stubs.
# Nothing here clones a remote or talks to a daemon.
#
# Usage: bats tests/bats/workspace.bats

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

fake_git() {
  local bin="${BATS_TEST_TMPDIR?}/bin"
  mkdir -p "${bin}"
  cat >"${bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'git %s\n' "$*" >>"${STUB_LOG}/git.log"; fi
shift 2
case "$*" in
  *clone*)
    if [ "${STUB_GIT_CLONE_RC:-0}" != 0 ]; then
      printf '%s\n' "${STUB_GIT_CLONE_ERR:-fatal: stub refused clone}" >&2
      exit "${STUB_GIT_CLONE_RC}"
    fi
    exit 0
    ;;
  *ls-tree*)
    if [ -n "${STUB_GIT_TREE_OUT:-}" ]; then printf '%s\n' "${STUB_GIT_TREE_OUT}"; fi
    exit "${STUB_GIT_TREE_RC:-0}"
    ;;
esac
exit 0
FAKE_GIT
  chmod 755 "${bin}/git"
}

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout coder
  fake_git
}

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/workspace.sh"
}

@test "workspace: sanitize_leaf lowercases, dashes, collapses, and trims" {
  source_libs
  [ "$(sanitize_leaf "ImageSharp")" = "imagesharp" ]
  [ "$(sanitize_leaf "Foo--Bar")" = "foo-bar" ]
  [ "$(sanitize_leaf "_foo_")" = "foo" ]
  [ "$(sanitize_leaf "a.b")" = "a-b" ]
  got="$(sanitize_leaf "Ünïcode")"
  assert_match "sanitized" '^[a-z0-9-]*$' "${got}"
}

@test "workspace: leaf_of_url drops the query, the fragment, and .git" {
  source_libs
  [ "$(leaf_of_url "https://github.com/foo/bar.git")" = "bar" ]
  [ "$(leaf_of_url "https://github.com/foo/bar?x=1")" = "bar" ]
  [ "$(leaf_of_url "https://github.com/foo/bar#code")" = "bar" ]
  [ "$(leaf_of_url "/srv/repos/my-tool")" = "my-tool" ]
}

@test "workspace: name_from_url starts with a letter and stays within 40 characters" {
  source_libs
  [ "$(name_from_url "https://github.com/foo/bar.git")" = "bar" ]
  [ "$(name_from_url "")" = "repo" ]
  [ "$(name_from_url "https://example.com/123-tools")" = "x123-tools" ]
  long="$(name_from_url "https://example.com/abcdefghijklmnopqrstuvwxyz0123456789abcdef")"
  [ "${#long}" -le 40 ]
  assert_match "leading letter" '^[a-z]' "${long}"
}

@test "workspace: clone_folder_of_url keeps the case the template will clone into" {
  source_libs
  [ "$(clone_folder_of_url "https://github.com/foo/ImageSharp.git")" = "ImageSharp" ]
  [ "$(name_from_url "https://github.com/foo/ImageSharp.git")" = "imagesharp" ]
  [ "$(clone_folder_of_url "/srv/repos/my_tool")" = "my_tool" ]
  [ "$(clone_folder_of_url "https://example.com/.hidden")" = "repo" ]
}

@test "workspace: probe_repo recognises a dev container and reports a miss as 3" {
  source_libs
  work="$(make_scratch)"
  export STUB_GIT_TREE_OUT=".devcontainer/devcontainer.json"
  rc=0
  probe_repo "${work}" "https://example.com/x/y.git" "${work}/repo" || rc=$?
  [ "${rc}" -eq 0 ]
  export STUB_GIT_TREE_OUT="README.md"
  rc=0
  probe_repo "${work}" "https://example.com/x/y.git" "${work}/repo" || rc=$?
  [ "${rc}" -eq 3 ]
}

@test "workspace: probe_repo returns 1 on a failed clone and 2 on a failed listing" {
  source_libs
  work="$(make_scratch)"
  export STUB_GIT_CLONE_RC=128
  rc=0
  probe_repo "${work}" "https://example.com/x/y.git" "${work}/repo" || rc=$?
  [ "${rc}" -eq 1 ]
  assert_match "clone flags" 'clone --quiet --depth 1 --no-checkout' "$(stub_log_last git)"
  assert_contains_file "probe.err" "${work}/probe.err" "stub refused clone"
  unset STUB_GIT_CLONE_RC
  export STUB_GIT_TREE_RC=1
  rc=0
  probe_repo "${work}" "https://example.com/x/y.git" "${work}/repo" || rc=$?
  [ "${rc}" -eq 2 ]
}

@test "new-workspace.sh: --help prints the flag list and creates nothing" {
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" --help
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "usage: new-workspace.sh [options] <git-url> [workspace-name]" ]
  assert_match "dry-run" '--dry-run' "${output}"
  [ "$(stub_log_count git)" -eq 0 ]
  [ "$(stub_log_count coder)" -eq 0 ]
}

@test "new-workspace.sh: --dry-run picks docker-devcontainer when a dev container is tracked" {
  export STUB_GIT_TREE_OUT=".devcontainer/devcontainer.json"
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" --dry-run https://github.com/foo/ImageSharp.git
  [ "${status}" -eq 0 ]
  assert_match "probe" '^probe:    dev container found$' "${output}"
  assert_match "template" '^template: docker-devcontainer$' "${output}"
  assert_match "name" '^name:     imagesharp$' "${output}"
  assert_match "clone folder" '/srv/coder-devcontainers/<workspace-id>/ImageSharp ' "${output}"
  [ "$(stub_log_count coder)" -eq 0 ]
}

@test "new-workspace.sh: --dry-run picks docker-dev when nothing is tracked" {
  export STUB_GIT_TREE_OUT="README.md"
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" --dry-run /srv/repos/my_tool
  [ "${status}" -eq 0 ]
  assert_match "probe" '^probe:    no dev container found$' "${output}"
  assert_match "template" '^template: docker-dev$' "${output}"
  assert_match "name" '^name:     my-tool$' "${output}"
  assert_match "clone folder" '/home/coder/workspace/my_tool ' "${output}"
  assert_match "would run" 'would run:' "${output}"
}

@test "new-workspace.sh: --devcontainer on a plain repo forces use_devcontainer=false" {
  export STUB_GIT_TREE_OUT="README.md"
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" --dry-run --devcontainer https://example.com/org/tool.git
  [ "${status}" -eq 0 ]
  assert_match "template" '^template: docker-devcontainer$' "${output}"
  assert_match "toggle" 'use_devcontainer=false' "${output}"
}

@test "new-workspace.sh: --dind passes dind=true on docker-dev" {
  export STUB_GIT_TREE_OUT="README.md"
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" --dry-run --dind https://example.com/org/tool.git
  [ "${status}" -eq 0 ]
  assert_match "template" '^template: docker-dev$' "${output}"
  assert_match "dind" 'dind=true' "${output}"
}

@test "new-workspace.sh: a failed probe still picks docker-dev and quotes the error" {
  export STUB_GIT_CLONE_RC=128
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" --dry-run https://github.com/foo/bar.git
  [ "${status}" -eq 0 ]
  assert_match "failed" 'probe failed: fatal: stub refused clone' "${output}"
  assert_match "template" '^template: docker-dev$' "${output}"
}

@test "new-workspace.sh: a real create goes to the coder stub and the temp tree is removed" {
  work_parent="$(make_scratch)"
  export TMPDIR="${work_parent}"
  export STUB_GIT_TREE_OUT="README.md"
  run --separate-stderr bash "${REPO_ROOT}/scripts/new-workspace.sh" https://github.com/foo/ImageSharp.git
  [ "${status}" -eq 0 ]
  assert_match "create" 'coder create -t docker-dev' "${output}"
  assert_match "started" '^started imagesharp from template docker-dev$' "${output}"
  [ "$(stub_log_count coder)" -eq 1 ]
  [ -z "$(ls -A "${work_parent}")" ]
}
