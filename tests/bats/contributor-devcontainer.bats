#!/usr/bin/env bats
#
# ## contributor-devcontainer.bats — the laptop/CI container stays pre-configured.
#
# .devcontainer/devcontainer.json builds the same golden image the Coder
# workspaces and CI run, and library-scripts/ is what makes it a development
# environment rather than a bare toolchain. These tests lock the two things a
# later edit can quietly break: the seam between the mounts named in the config
# and the caches configure.sh points Bazel at, and the idempotence of the
# postCreate steps (a container is recreated on every config edit, and the
# developer's own ~/.bazelrc has to survive it).
#
# Usage: bazelisk test //tests:bats_contributor_devcontainer_test   (from any cwd)
# Safety: reads the contributor container files; writes only under the bats temp
# directory and a fixture checkout built there. Never touches the real checkout's
# git config.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CHECKOUT=""
DC_JSON=""
CONFIGURE=""
WARMUP=""
FIXTURE=""
FIXTURE_HOME=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CHECKOUT="$(contributor_checkout)" || skip "cannot locate .devcontainer in the checkout or runfiles"
  DC_JSON="${CHECKOUT}/.devcontainer/devcontainer.json"
  CONFIGURE="${CHECKOUT}/.devcontainer/library-scripts/configure.sh"
  WARMUP="${CHECKOUT}/.devcontainer/library-scripts/warmup.sh"
}

# contributor_checkout — print the directory that holds the contributor container.
# Bazel runfiles ship only what the suite declares, and configure.sh resolves
# scripts/lib from its own location, so prefer a tree that has the whole repo.
contributor_checkout() {
  local candidate dir
  for candidate in "${REPO_ROOT}" "${TEST_SRCDIR:-}/_main" "$(dirname "${BATS_TEST_DIRNAME}")"; do
    if [ -n "${candidate}" ] && [ -f "${candidate}/.devcontainer/devcontainer.json" ] &&
      [ -f "${candidate}/scripts/lib/common.sh" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  dir="$(dirname "${BATS_TEST_DIRNAME}")"
  while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
    if [ -f "${dir}/.devcontainer/devcontainer.json" ] && [ -f "${dir}/scripts/lib/common.sh" ]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

# dc_get <dotted.path> — print one value from devcontainer.json as JSON text.
# A missing key is a failure, so a renamed key cannot pass as an empty answer.
dc_get() {
  python3 - "${DC_JSON}" "$1" <<'PY'
import json
import sys

node = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    if part not in node:
        sys.exit(3)
    node = node[part]
print(json.dumps(node))
PY
}

# dc_has <label> <needle> — fail unless the whole config contains the substring.
dc_has() {
  if ! grep -qF -- "$2" "${DC_JSON}"; then
    printf 'FAIL: %s: %s does not contain %s\n' "$1" "${DC_JSON}" "$2" >&2
    return 1
  fi
}

# make_fixture — build a throwaway checkout with its own git config and HOME.
#
# configure.sh writes the cache seam, the bazelrc block and the hooks path, so
# the tests aim it at a fixture instead of the checkout under test. The real
# hooks payload is copied in so the install branch reads the same files the
# pre-commit gate runs.
make_fixture() {
  FIXTURE="${BATS_TEST_TMPDIR}/checkout"
  FIXTURE_HOME="${FIXTURE}/home"
  rm -rf "${FIXTURE}"
  mkdir -p "${FIXTURE}/.githooks" "${FIXTURE_HOME}" "${FIXTURE}/scripts"
  touch "${FIXTURE}/docker-compose.yml"
  cp "${CHECKOUT}/.githooks/pre-commit" "${CHECKOUT}/.githooks/pre-push" "${FIXTURE}/.githooks/"
  cp "${CHECKOUT}/scripts/install-hooks.sh" "${FIXTURE}/scripts/"
  cp -r "${CHECKOUT}/scripts/lib" "${FIXTURE}/scripts/lib"
  git init -q "${FIXTURE}"
}

# run_configure <mode> [extra args...] — run configure.sh against the fixture.
run_configure() {
  run env \
    "HOME=${FIXTURE_HOME}" \
    "REPO_ROOT=${FIXTURE}" \
    "EVO_T1_BAZEL_CACHE_ROOT=${FIXTURE}/cache" \
    "EVO_T1_TOOL_CACHE_ROOT=${FIXTURE}/tools" \
    "EVO_T1_WARMUP=${EVO_T1_WARMUP:-off}" \
    "EVO_T1_WARMUP_LOG=${FIXTURE}/warmup.log" \
    "EVO_T1_WARMUP_STATUS=${FIXTURE}/warmup.status" \
    "EVO_T1_WARMUP_LOCK=${FIXTURE}/warmup.lock" \
    bash "${CONFIGURE}" "$@"
}

# bazelrc_blocks <n> — fail unless the managed block appears exactly <n> times.
# A re-run that appends instead of replacing would hand the developer a bazelrc
# whose last copy silently wins, so every run of configure.sh asserts on this.
bazelrc_blocks() {
  local blocks
  blocks="$(grep -c 'BEGIN evo-t1 contributor dev container' "${FIXTURE_HOME}/.bazelrc" 2>/dev/null || printf '0')"
  if [ "${blocks}" != "$1" ]; then
    printf 'FAIL: expected %s managed bazelrc block(s), found %s\n' "$1" "${blocks}" >&2
    return 1
  fi
}

@test "contributor container: the config is JSON and builds the golden image" {
  run python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "${DC_JSON}"
  [ "${status}" -eq 0 ]
  [ "$(dc_get build.context)" = '"../images/dev"' ]
  [ "$(dc_get build.dockerfile)" = '"Dockerfile"' ]
  dc_has "the image cache seed" 'ghcr.io/toxicoder/evo-t1-coder-stack/evo-t1-dev'
}

@test "contributor container: it runs as coder with the host uid remapped" {
  [ "$(dc_get remoteUser)" = '"coder"' ]
  [ "$(dc_get updateRemoteUserUID)" = 'true' ]
}

@test "contributor container: both env layers carry the contributor marker" {
  [ "$(dc_get containerEnv.EVO_T1_DEVCONTAINER)" = '"1"' ]
  [ "$(dc_get remoteEnv.EVO_T1_DEVCONTAINER)" = '"1"' ]
  [ "$(dc_get containerEnv.SEARXNG_URL)" = '"http://host.docker.internal:8181"' ]
}

@test "contributor container: every bazel volume mounts under the seam the config names" {
  local seam
  seam="$(dc_get containerEnv.EVO_T1_BAZEL_CACHE_ROOT)"
  seam="${seam//\"/}"
  [ -n "${seam}" ]
  local target
  for target in disk repo root; do
    dc_has "the ${target} cache volume" "target=${seam}/${target},type=volume"
  done
  dc_has "the tool cache volume" 'target=/var/cache/evo-t1-toolcache,type=volume'
  dc_has "the docker socket mount" 'source=/var/run/docker.sock'
}

@test "contributor container: the package caches point inside the mounted tool cache" {
  local key
  for key in BAZELISK_HOME NPM_CONFIG_CACHE UV_CACHE_DIR PIP_CACHE_DIR; do
    dc_has "${key}" "\"${key}\": \"/var/cache/evo-t1-toolcache/"
  done
}

@test "contributor container: postCreate and postStart drive the configure script" {
  dc_has "postCreateCommand" '"postCreateCommand": "bash .devcontainer/library-scripts/configure.sh create"'
  dc_has "postStartCommand" '"postStartCommand": "bash .devcontainer/library-scripts/configure.sh start"'
  assert_file_exists "the configure script" "${CONFIGURE}"
  assert_file_exists "the warm-up script" "${WARMUP}"
  run bash -n "${CONFIGURE}"
  [ "${status}" -eq 0 ]
  run bash -n "${WARMUP}"
  [ "${status}" -eq 0 ]
}

@test "contributor container: the editor formatters are the gate's own tools" {
  dc_has "the shell lint runner" '"bashIde.shellcheckArguments": "-x --severity=warning"'
  dc_has "the shell format runner" '"shellformat.flag": "-s -i 2 -ci -w"'
  dc_has "the shellcheck binary" '"bashIde.shellcheckPath": "/usr/bin/shellcheck"'
  dc_has "the shfmt binary" '"shellformat.path": "/usr/local/bin/shfmt"'
  local extensions
  extensions="$(dc_get customizations.vscode.extensions)"
  local extension
  for extension in timonwong.shellcheck foxundermoon.shell-format bazelbuild.vscode-bazel \
    hashicorp.terraform redhat.vscode-yaml ms-python.python golang.go; do
    [[ "${extensions}" == *"${extension}"* ]] || {
      printf 'FAIL: extension %s is missing\n' "${extension}" >&2
      return 1
    }
  done
}

@test "contributor container: the docs dev server port is forwarded" {
  [ "$(dc_get forwardPorts)" = '[3000]' ]
}

@test "contributor container: the probe sentinel is still tracked and still warns" {
  assert_file_exists "the probe sentinel" "${CHECKOUT}/.devcontainer/contributor-env"
  run grep -qF 'Do not copy this file into other repositories' "${CHECKOUT}/.devcontainer/contributor-env"
  [ "${status}" -eq 0 ]
}

@test "configure: dry-run plans every step and writes nothing" {
  make_fixture
  EVO_T1_WARMUP=full
  run_configure create --dry-run
  [ "${status}" -eq 0 ]
  assert_match "the seeder" "would run scripts/seed-dev-env.sh" "${output}"
  assert_match "the hooks" "would run scripts/install-hooks.sh" "${output}"
  assert_match "the bazelrc seam" "would write the managed block" "${output}"
  assert_match "the warm-up" "would start the background warm-up" "${output}"
  assert_file_not_exists "no bazelrc yet" "${FIXTURE_HOME}/.bazelrc"
  assert_file_not_exists "no cache tree yet" "${FIXTURE}/cache/disk"
  assert_file_not_exists "no warm-up status" "${FIXTURE}/warmup.status"
}

@test "configure: start lays one managed bazelrc block at the seam" {
  make_fixture
  run_configure start
  [ "${status}" -eq 0 ]
  assert_match "the summary" "^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$" "${output}"
  assert_contains_file "the disk cache" "${FIXTURE_HOME}/.bazelrc" "^common --disk_cache=${FIXTURE}/cache/disk$"
  assert_contains_file "the repository cache" "${FIXTURE_HOME}/.bazelrc" "^common --repository_cache=${FIXTURE}/cache/repo$"
  assert_contains_file "the output root" "${FIXTURE_HOME}/.bazelrc" "^startup --output_user_root=${FIXTURE}/cache/root$"
  bazelrc_blocks 1
}

@test "configure: a second start does not stack a second block" {
  make_fixture
  run_configure start
  [ "${status}" -eq 0 ]
  run_configure start
  [ "${status}" -eq 0 ]
  bazelrc_blocks 1
}

@test "configure: the developer's own bazelrc lines survive a re-run" {
  make_fixture
  printf '%s\n' '# mine' 'build --define=mine=1' >"${FIXTURE_HOME}/.bazelrc"
  run_configure start
  [ "${status}" -eq 0 ]
  run_configure start
  [ "${status}" -eq 0 ]
  assert_contains_file "the developer line" "${FIXTURE_HOME}/.bazelrc" '^build --define=mine=1$'
  bazelrc_blocks 1
}

@test "configure: a foreign hooksPath is reported, never overwritten" {
  make_fixture
  git -C "${FIXTURE}" config core.hooksPath someone-elses-hooks
  run_configure start
  [ "${status}" -eq 0 ]
  assert_match "the note" "leaving the repo's .githooks" "${output}"
  [ "$(git -C "${FIXTURE}" config --get core.hooksPath)" = "someone-elses-hooks" ]
}

@test "configure: a checkout with no hooks gets the repo's installed" {
  make_fixture
  run_configure start
  [ "${status}" -eq 0 ]
  [ "$(git -C "${FIXTURE}" config --get core.hooksPath)" = ".githooks" ]
  assert_match "the armed gate" "commit and push gates are armed" "${output}"
}

@test "configure: EVO_T1_WARMUP=off skips the background warm-up" {
  make_fixture
  EVO_T1_WARMUP=off
  run_configure start
  [ "${status}" -eq 0 ]
  assert_match "the skip note" "warm-up skipped" "${output}"
  assert_file_not_exists "no warm-up status" "${FIXTURE}/warmup.status"
}

@test "configure: the detached warm-up runs and records its outcome" {
  make_fixture
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${BATS_TEST_TMPDIR}/bin/bazelisk"
  chmod +x "${BATS_TEST_TMPDIR}/bin/bazelisk"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" EVO_T1_WARMUP=full run_configure start
  [ "${status}" -eq 0 ]
  local waited=0 status_text=missing
  while [ "${waited}" -lt 30 ]; do
    status_text="$(cat "${FIXTURE}/warmup.status" 2>/dev/null || printf 'missing')"
    if [ "${status_text}" != "running" ] && [ "${status_text}" != "missing" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  [ "${status_text}" = "ok" ]
  assert_contains_file "the gate step" "${FIXTURE}/warmup.log" "ok: warm bazel gate"
}

@test "configure: an unknown mode or option is a usage error" {
  make_fixture
  run_configure nonsense
  [ "${status}" -eq 1 ]
  assert_match "the mode list" "mode must be create, start or status" "${output}"
  run_configure create --frobnicate
  [ "${status}" -eq 1 ]
  assert_match "the unknown option" "unknown option --frobnicate" "${output}"
}
