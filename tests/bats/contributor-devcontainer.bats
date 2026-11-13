#!/usr/bin/env bats
#
# ## contributor-devcontainer.bats - the laptop/CI container stays pre-configured.
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

# contributor_checkout - print the directory that holds the contributor container.
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

# dc_lookup <json|text> <dotted.path> - resolve one value in devcontainer.json.
# A missing key exits 3, so a renamed key cannot pass as an empty answer. The path
# splits on dots and each step takes the longest key that matches, because the
# spec nests objects (customizations.vscode) while VS Code settings are written as
# flat dotted keys beside them ("shellcheck.customArgs").
dc_lookup() {
  python3 - "${DC_JSON}" "$2" "$1" <<'PY'
import json
import sys

node = json.load(open(sys.argv[1], encoding="utf-8"))
parts = sys.argv[2].split(".")
mode = sys.argv[3]
i = 0
while i < len(parts):
    for j in range(len(parts), i, -1):
        key = ".".join(parts[i:j])
        if isinstance(node, dict) and key in node:
            node = node[key]
            i = j
            break
    else:
        sys.exit(3)
if mode == "json":
    print(json.dumps(node))
elif isinstance(node, list):
    print(" ".join(str(x) for x in node))
else:
    print(node)
PY
}

dc_get() { dc_lookup json "$1"; }

# dc_value <dotted.path> - print one setting as plain text; a list joins on spaces.
# Comparing a flag string to the gate's own flags needs the text, not JSON.
dc_value() { dc_lookup text "$1"; }

# gate_runner <file> - print the path of one lint runner in the tree this suite reads.
gate_runner() {
  local dir candidate
  for dir in "${CHECKOUT}" "${TEST_SRCDIR:-}/_main" "$(dirname "${BATS_TEST_DIRNAME}")"; do
    candidate="${dir}/lints/$1"
    if [ -n "${dir}" ] && [ -f "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

# gate_flags <runner-file> <tool> - print the flags the gate runs <tool> with.
# Only the line that passes the file list is the gate: a runner also probes the
# tool with `--version` and echoes its own name, and neither is the invocation
# the editor has to match. -d is the gate's check-only diff mode, which has no
# meaning for a formatter that answers on stdout, so it is dropped; -i keeps its
# argument. The last match wins, so a runner may lint several sets in turn.
gate_flags() {
  awk -v tool="$2" '
    index($0, tool " ") == 1 && /files\[@\]/ {
      flags = ""
      for (i = 2; i <= NF; i++) {
        if ($i == "-d") continue
        if ($i ~ /^-/) {
          flags = flags sprintf("%s ", $i)
          if ($i == "-i") {
            i++
            flags = flags sprintf("%s ", $i)
          }
        }
      }
    }
    END { printf "%s", flags }
  ' "$1"
}

# dc_has <label> <needle> - fail unless the whole config contains the substring.
dc_has() {
  if ! grep -qF -- "$2" "${DC_JSON}"; then
    printf 'FAIL: %s: %s does not contain %s\n' "$1" "${DC_JSON}" "$2" >&2
    return 1
  fi
}

# make_fixture - build a throwaway checkout with its own git config and HOME.
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

# run_configure <mode> [extra args...] - run configure.sh against the fixture.
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

# bazelrc_blocks <n> - fail unless the managed block appears exactly <n> times.
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

@test "contributor container: the editor runs the gate's tools with the gate's flags" {
  local shellcheck_runner shfmt_runner gate_shellcheck gate_shfmt settings
  # A skip here would silence the only check that the editor pins track the gate,
  # and //tests:BUILD.bazel declares //lints:runners for exactly this test, so a
  # missing runner is a broken declaration and has to be loud.
  shellcheck_runner="$(gate_runner run_shellcheck.sh)" ||
    fail "run_shellcheck.sh is not in this tree or the suite's runfiles"
  shfmt_runner="$(gate_runner run_shfmt.sh)" ||
    fail "run_shfmt.sh is not in this tree or the suite's runfiles"
  settings="customizations.vscode.settings"

  # The editor settings are only worth having if they track the gate, so read
  # the flags out of the runners rather than repeating them: change the gate and
  # this test is the thing that goes red.
  gate_shellcheck="$(gate_flags "${shellcheck_runner}" shellcheck)"
  gate_shfmt="$(gate_flags "${shfmt_runner}" shfmt)"
  [ -n "${gate_shellcheck}" ] || fail "could not read the gate's shellcheck flags from ${shellcheck_runner}"
  [ -n "${gate_shfmt}" ] || fail "could not read the gate's shfmt flags from ${shfmt_runner}"

  local want_shellcheck want_shfmt have_shellcheck have_shfmt
  want_shellcheck="${gate_shellcheck% }"
  want_shfmt="${gate_shfmt% }"
  have_shellcheck="$(dc_value "${settings}.shellcheck.customArgs")"
  have_shfmt="$(dc_value "${settings}.shellformat.flag")"
  [ "${have_shellcheck}" = "${want_shellcheck}" ] ||
    fail "shellcheck.customArgs is '${have_shellcheck}', the gate runs '${want_shellcheck}' (${shellcheck_runner})"
  [ "$(dc_value "${settings}.shellcheck.executablePath")" = "/usr/bin/shellcheck" ]
  [ "${have_shfmt}" = "${want_shfmt}" ] ||
    fail "shellformat.flag is '${have_shfmt}', the gate runs '${want_shfmt}' (${shfmt_runner})"
  [ "$(dc_value "${settings}.shellformat.path")" = "/usr/local/bin/shfmt" ]

  # bashIde.* belongs to an extension this container does not install, so those
  # keys would be inert and the lint would run with someone else's defaults.
  if grep -q 'bashIde\.' "${DC_JSON}"; then
    fail "devcontainer.json pins bashIde.* keys no installed extension reads"
  fi

  local extensions
  extensions="$(dc_get customizations.vscode.extensions)"
  local extension
  for extension in timonwong.shellcheck foxundermoon.shell-format bazelbuild.vscode-bazel \
    hashicorp.terraform redhat.vscode-yaml ms-python.python; do
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

@test "configure: a sudo that cannot start still lays the seam" {
  make_fixture
  # CI runs the suite under a uid the runner's sudo refuses with "you do not
  # exist in the passwd database". configure.sh probes for sudo before using it,
  # so a create that needs no privilege at all must be attempted unprivileged
  # first: a sudo that cannot start may not be the reason the seam is missing.
  local stubs="${BATS_TEST_TMPDIR}/sudo-bin"
  mkdir -p "${stubs}"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'sudo: you do not exist in the passwd database\\n' >&2" \
    'exit 1' >"${stubs}/sudo"
  chmod 755 "${stubs}/sudo"

  PATH="$(with_path "${stubs}")" run_configure start
  [ "${status}" -eq 0 ]
  assert_not_match "no failed cache dir" 'cannot create the cache directory' "${output}"
  [ -d "${FIXTURE}/cache/disk" ] || fail "the disk cache directory was not created"
  assert_contains_file "the seam survived" "${FIXTURE_HOME}/.bazelrc" \
    "^common --disk_cache=${FIXTURE}/cache/disk$"
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

@test "configure: a bazelrc missing its END line is rewritten, and says so" {
  make_fixture
  printf '%s\n' '# mine' 'build --define=mine=1' >"${FIXTURE_HOME}/.bazelrc"
  run_configure start
  [ "${status}" -eq 0 ]
  # A careless edit that deletes the END marker makes the next strip swallow
  # everything after BEGIN. That has to be said out loud: the lines are gone.
  sed -i '/^# END evo-t1 contributor dev container$/d' "${FIXTURE_HOME}/.bazelrc"
  run_configure start
  [ "${status}" -eq 0 ]
  assert_match "the warning" "no managed-block END line" "${output}"
  assert_contains_file "the developer line" "${FIXTURE_HOME}/.bazelrc" '^build --define=mine=1$'
  assert_contains_file "the seam rewritten" "${FIXTURE_HOME}/.bazelrc" \
    "^common --disk_cache=${FIXTURE}/cache/disk$"
  bazelrc_blocks 1
}

@test "configure: a symlinked bazelrc keeps being a symlink" {
  make_fixture
  mkdir -p "${FIXTURE}/dotfiles"
  printf '%s\n' '# from my dotfiles' >"${FIXTURE}/dotfiles/bazelrc"
  ln -s "${FIXTURE}/dotfiles/bazelrc" "${FIXTURE_HOME}/.bazelrc"
  run_configure start
  [ "${status}" -eq 0 ]
  [ -L "${FIXTURE_HOME}/.bazelrc" ] || fail "the developer's symlink was replaced by a plain file"
  # Writing through the link is the point: the canonical file in the dotfiles
  # tree has to carry the block, or the next sync erases the seam.
  assert_contains_file "the dotfile got the block" "${FIXTURE}/dotfiles/bazelrc" \
    "^common --disk_cache=${FIXTURE}/cache/disk$"
  assert_contains_file "the dotfile kept its line" "${FIXTURE}/dotfiles/bazelrc" \
    '^# from my dotfiles$'
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

@test "configure: a socket it cannot open is reported, never claimed" {
  make_fixture
  local sock="${BATS_TEST_TMPDIR}/docker.sock" stubs="${BATS_TEST_TMPDIR}/acl-bin"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${sock}"
  chmod 000 "${sock}"
  mkdir -p "${stubs}"
  # setfacl never works here and the a+rw fallback is refused, so the only
  # honest answer is the note. The chmod stub passes everything else through so
  # the rest of configure.sh keeps a real chmod.
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${stubs}/setfacl"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *a+rw*) exit 1 ;; esac' 'exec /bin/chmod "$@"' >"${stubs}/chmod"
  printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"${stubs}/sudo"
  chmod 755 "${stubs}/setfacl" "${stubs}/chmod" "${stubs}/sudo"

  PATH="$(with_path "${stubs}")" EVO_T1_DOCKER_SOCKET="${sock}" run_configure start
  [ "${status}" -eq 0 ]
  assert_match "the honest note" "docker socket is not writable by uid" "${output}"
  assert_not_match "no claimed success" "docker socket opened for uid" "${output}"
}

@test "configure: the privilege helpers never fall back to a command that fakes success" {
  # ${SUDO:-true} with no sudo expands to `true`, which swallows its arguments
  # and exits 0: the script would print an ok line for a chmod it never made.
  if grep -vE '^[[:space:]]*#' "${CONFIGURE}" | grep -qE '\$\{SUDO:-true\}'; then
    fail "configure.sh runs \${SUDO:-true}, which reports success while running nothing"
  fi
}

@test "configure: a warm-up that failed last time runs again" {
  make_fixture
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${BATS_TEST_TMPDIR}/bin/bazelisk"
  chmod +x "${BATS_TEST_TMPDIR}/bin/bazelisk"
  printf '%s\n' 'failed: test-fast' >"${FIXTURE}/warmup.status"

  PATH="$(with_path "${BATS_TEST_TMPDIR}/bin")" EVO_T1_WARMUP=full run_configure start
  [ "${status}" -eq 0 ]
  assert_match "the retry is announced" "the last warm-up failed: test-fast" "${output}"
  assert_match "a warm-up starts" "warm-up started" "${output}"
  assert_not_match "not called finished" "warm-up already finished" "${output}"
}

@test "configure: status reports the seam, the hooks and the warm-up" {
  make_fixture
  run_configure start
  [ "${status}" -eq 0 ]
  printf '%s\n' 'ok' >"${FIXTURE}/warmup.status"
  run_configure status
  [ "${status}" -eq 0 ]
  assert_match "the state section" "container state" "${output}"
  assert_match "the writable cache" "bazel cache writable: ${FIXTURE}/cache/disk" "${output}"
  assert_match "the armed gate" "commit and push gates are armed" "${output}"
  assert_match "the warm-up line" "warm-up ok" "${output}"
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

@test "configure: --help works in either position and names every knob" {
  make_fixture
  local knob
  for knob in --help -h; do
    run_configure "${knob}"
    [ "${status}" -eq 0 ]
    run_configure create "${knob}"
    [ "${status}" -eq 0 ]
  done
  assert_match "the create form" 'configure\.sh create \[--dry-run\]' "${output}"
  # That header is the only documentation these flags have, so every variable the
  # script reads has to be named by it: a new knob cannot ship undocumented.
  while read -r knob; do
    assert_match "help names ${knob}" "${knob}" "${output}"
  done < <(grep -oh 'EVO_T1_[A-Z_]\+' "${CONFIGURE}" | sort -u)
}
