#!/usr/bin/env bats
#
# ## test-in-image.bats - hermetic coverage for scripts/test-in-image.sh
#
# The contract pinned here: a host that is not the contributor dev container
# proves the gates inside the golden image, so the exact docker command line is
# what matters. A missing tag is built from images/dev/Dockerfile with
# images/dev as the context and tagged locally; the gates then run through
# docker run with the checkout bind-mounted at /work, --user <host uid:gid>, and bazelisk
# as the command ("test //:test-fast" unless argv said otherwise). --image
# repoints the tag, DEV_IMAGE_TAG does the same from the environment, --build
# rebuilds even a tag that already exists, and everything after -- reaches
# bazelisk untouched. With EVO_T1_DEVCONTAINER=1 the script is already inside
# that image, so it must not call docker at all - it execs bazelisk here.
#
# Docker only ever resolves through the tool stub (inspect answers only when
# STUB_DOCKER_INSPECT=1, build and run just record argv), and the Bazel
# container-side command is a per-test fake on PATH, so no test here needs a
# daemon, a registry, or Bazel.
#
# The whole suite skips while scripts/test-in-image.sh is absent: a suite for a
# script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_test_in_image_test   (from any cwd)
# Safety: reads the script and the golden-image payload paths; writes only under
# the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export REPO_ROOT
  SCRIPT="${REPO_ROOT}/scripts/test-in-image.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/test-in-image.sh is not in the tree yet"
  fi
  # A contributor container sets this; a host-path test that inherited it would
  # exec bazelisk instead of building the docker command line under test.
  unset EVO_T1_DEVCONTAINER
  use_stubs docker
}

# fake_bazelisk - put a logging bazelisk first on PATH, in the stub bin
# directory use_stubs already prepended, so the container-side command and the
# contributor-container path can be asserted without Bazel. It adds one file to
# the per-test bin directory and never replaces PATH.
fake_bazelisk() {
  local bin="${BATS_TEST_TMPDIR?}/bin"
  mkdir -p "${bin}"
  cat >"${bin}/bazelisk" <<'FAKE_BAZELISK'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'bazelisk %s\n' "$*" >>"${STUB_LOG}/bazelisk.log"; fi
exit "${STUB_BAZELISK_RC:-0}"
FAKE_BAZELISK
  chmod 755 "${bin}/bazelisk"
}

# source_common - the entry script sources these helpers, so a unit test that
# loads one function out of it needs the same log/err definitions.
source_common() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
}

# script_default_tag - read the DEFAULT_IMAGE_TAG constant out of the script:
# load_shell_function lifts a function body only, so the constant a unit test
# calls through has to come from the file rather than a second copy here.
script_default_tag() {
  sed -n 's/^DEFAULT_IMAGE_TAG="\(.*\)"$/\1/p' "${SCRIPT}" | head -n 1
}

@test "test-in-image: --help prints the usage and an unknown option refuses before docker" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" '^usage: bazelisk run //scripts:test-in-image --' "${output}"

  run --separate-stderr bash "${SCRIPT}" --bogus
  [ "${status}" -eq 1 ]
  assert_match "usage shown on a bad flag" '^usage: bazelisk run //scripts:test-in-image --' "${output}"
  assert_match "flag named on stderr" 'unknown option: --bogus' "${stderr}"
  # A usage error never reaches the daemon.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "test-in-image: a valueless --image or --user is a usage error" {
  run --separate-stderr bash "${SCRIPT}" --image
  [ "${status}" -eq 1 ]
  assert_match "image names its flag" 'image needs an image tag' "${stderr}"

  run --separate-stderr bash "${SCRIPT}" --user
  [ "${status}" -eq 1 ]
  assert_match "user names its flag" 'user needs a user name' "${stderr}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "test-in-image: usage is the block a typo meets" {
  load_shell_function "${SCRIPT}" usage
  run usage
  [ "${status}" -eq 0 ]
  assert_match "first line names the entry point" '^usage: bazelisk run //scripts:test-in-image --' "${output}"
}

@test "test-in-image: resolve_repo_root names the checkout holding docker-compose.yml" {
  load_shell_function "${SCRIPT}" resolve_repo_root
  local scratch got rc=0
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/ws/scripts"
  printf 'services: {}\n' >"${scratch}/ws/docker-compose.yml"

  # The cwd candidate proves it when nothing else is handed in.
  got="$(cd "${scratch}/ws" && REPO_ROOT="" SELF_DIR="${scratch}/ws/scripts" resolve_repo_root)"
  [ "${got}" = "${scratch}/ws" ]

  # From a foreign cwd, the SELF_DIR/.. candidate still lands on the marker.
  got="$(cd "${BATS_TEST_TMPDIR}" && REPO_ROOT="" SELF_DIR="${scratch}/ws/scripts" resolve_repo_root)"
  [ -f "${got}/docker-compose.yml" ]

  # Nothing holds the marker: the probe says so and exits 5.
  got="$(cd "${BATS_TEST_TMPDIR}" && REPO_ROOT="" SELF_DIR="${scratch}/nowhere" resolve_repo_root 2>/dev/null)" || rc=$?
  [ "${rc}" -eq 5 ]
}

@test "test-in-image: test_in_image_tag prefers argv, then DEV_IMAGE_TAG, then the golden tag" {
  load_shell_function "${SCRIPT}" test_in_image_tag
  local got
  DEFAULT_IMAGE_TAG="$(script_default_tag)"
  [ "${DEFAULT_IMAGE_TAG}" = "evo-t1-dev:latest" ]
  unset DEV_IMAGE_TAG
  got="$(test_in_image_tag "")"
  [ "${got}" = "evo-t1-dev:latest" ]

  got="$(DEV_IMAGE_TAG=evo-t1-dev:v9 test_in_image_tag "")"
  [ "${got}" = "evo-t1-dev:v9" ]

  got="$(DEV_IMAGE_TAG=evo-t1-dev:v9 test_in_image_tag my:tag)"
  [ "${got}" = "my:tag" ]
}

@test "test-in-image: test_in_image_in_contributor_env is true only for EVO_T1_DEVCONTAINER=1" {
  load_shell_function "${SCRIPT}" test_in_image_in_contributor_env
  EVO_T1_DEVCONTAINER=1
  run test_in_image_in_contributor_env
  [ "${status}" -eq 0 ]

  EVO_T1_DEVCONTAINER=0
  run test_in_image_in_contributor_env
  [ "${status}" -ne 0 ]

  EVO_T1_DEVCONTAINER=yes
  run test_in_image_in_contributor_env
  [ "${status}" -ne 0 ]

  unset EVO_T1_DEVCONTAINER
  run test_in_image_in_contributor_env
  [ "${status}" -ne 0 ]
}

@test "test-in-image: test_in_image_image_present asks the local image store" {
  source_common
  load_shell_function "${SCRIPT}" test_in_image_image_present

  # Default stub: the tag is not there.
  run test_in_image_image_present evo-t1-dev:latest
  [ "${status}" -ne 0 ]
  assert_match "inspect was issued" 'image inspect evo-t1-dev:latest' "$(stub_log docker)"

  export STUB_DOCKER_INSPECT=1
  run test_in_image_image_present evo-t1-dev:latest
  [ "${status}" -eq 0 ]

  # No tag asked is never "present".
  run test_in_image_image_present ""
  [ "${status}" -ne 0 ]
}

@test "test-in-image: test_in_image_build builds the golden Dockerfile with images/dev as context" {
  source_common
  load_shell_function "${SCRIPT}" test_in_image_build
  run test_in_image_build evo-t1-dev:latest "${REPO_ROOT}"
  [ "${status}" -eq 0 ]
  local line
  line="$(stub_log_last docker)"
  assert_match "build subcommand" '^docker build ' "${line}"
  assert_match "the golden Dockerfile" "-f ${REPO_ROOT}/images/dev/Dockerfile" "${line}"
  assert_match "the local tag" "-t evo-t1-dev:latest" "${line}"
  assert_match "the context is images/dev" "${REPO_ROOT}/images/dev$" "${line}"

  run test_in_image_build "" "${REPO_ROOT}"
  [ "${status}" -ne 0 ]
  run test_in_image_build evo-t1-dev:latest ""
  [ "${status}" -ne 0 ]
}

@test "test-in-image: test_in_image_run runs bazelisk in the image against the checkout" {
  source_common
  load_shell_function "${SCRIPT}" test_in_image_run
  run test_in_image_run evo-t1-dev:latest "${REPO_ROOT}" coder test //:lint --test_tag_filters=manual
  [ "${status}" -eq 0 ]
  local line
  line="$(stub_log_last docker)"
  assert_match "run subcommand" '^docker run ' "${line}"
  assert_match "throwaway container" '--rm' "${line}"
  assert_match "named user honoured" '--user coder' "${line}"
  assert_match "checkout mounted at /work" "-v ${REPO_ROOT}:/work" "${line}"
  assert_match "cwd is the mount" '-w /work' "${line}"
  assert_match "CI passed through" '-e CI' "${line}"
  assert_match "scratch HOME" '-e HOME=/tmp' "${line}"
  assert_match "USER for bazel" "-e USER=${USER:-$(id -un)}" "${line}"
  assert_match "stack host resolvable" '--add-host=host.docker.internal:host-gateway' "${line}"
  assert_match "bazelisk is the command" 'evo-t1-dev:latest bazelisk test //:lint --test_tag_filters=manual$' "${line}"

  # An empty user is this process's uid:gid, and a missing argument is a caller bug.
  run test_in_image_run evo-t1-dev:latest "${REPO_ROOT}" "" test //:test-fast
  [ "${status}" -eq 0 ]
  assert_match "host uid by default" "--user $(id -u):$(id -g)" "$(stub_log_last docker)"
  run test_in_image_run
  [ "${status}" -ne 0 ]
}

@test "test-in-image: a missing tag is built first, then the gates run inside the image" {
  # Default stub inspect: evo-t1-dev:latest is not in the local store.
  run --separate-stderr bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local log line
  log="$(stub_log docker)"
  [ "$(stub_log_count docker)" -eq 3 ]
  assert_match "the tag was probed" 'image inspect evo-t1-dev:latest' "${log}"
  assert_match "then built" '^docker build ' "$(printf '%s\n' "${log}" | sed -n '2p')"
  assert_match "from the golden Dockerfile" "-f ${REPO_ROOT}/images/dev/Dockerfile" "${log}"
  assert_match "tagged locally" "-t evo-t1-dev:latest" "${log}"
  assert_match "context is images/dev" "${REPO_ROOT}/images/dev$" "${log}"
  line="$(stub_log_last docker)"
  assert_match "then run" '^docker run ' "${line}"
  assert_match "as host uid" "--user $(id -u):$(id -g)" "${line}"
  assert_match "checkout mounted" "-v ${REPO_ROOT}:/work" "${line}"
  assert_match "cwd is the mount" '-w /work' "${line}"
  assert_match "scratch HOME" '-e HOME=/tmp' "${line}"
  assert_match "USER for bazel" "-e USER=${USER:-$(id -un)}" "${line}"
  assert_match "stack host resolvable" '--add-host=host.docker.internal:host-gateway' "${line}"
  assert_match "the default suite" 'bazelisk test //:test-fast$' "${line}"
}

@test "test-in-image: a present tag is reused with no rebuild" {
  export STUB_DOCKER_INSPECT=1
  run --separate-stderr bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local log
  log="$(stub_log docker)"
  [ "$(stub_log_count docker)" -eq 2 ]
  assert_not_match "no build ran" '^docker build ' "${log}"
  assert_match "the gates still ran" '^docker run ' "$(stub_log_last docker)"
  assert_match "the default suite" 'bazelisk test //:test-fast$' "$(stub_log_last docker)"
}

@test "test-in-image: --build rebuilds even a tag the store already has" {
  export STUB_DOCKER_INSPECT=1
  run --separate-stderr bash "${SCRIPT}" --build
  [ "${status}" -eq 0 ]
  local log
  log="$(stub_log docker)"
  [ "$(stub_log_count docker)" -eq 2 ]
  assert_not_match "no presence probe needed" 'image inspect' "${log}"
  assert_match "built anyway" '^docker build ' "${log}"
  assert_match "tagged locally" "-t evo-t1-dev:latest" "${log}"
  assert_match "then run" '^docker run ' "$(stub_log_last docker)"
}

@test "test-in-image: --image runs that tag instead of the golden default" {
  export STUB_DOCKER_INSPECT=1
  run --separate-stderr bash "${SCRIPT}" --image my:tag
  [ "${status}" -eq 0 ]
  local log
  log="$(stub_log docker)"
  assert_match "probed that tag" 'image inspect my:tag' "${log}"
  assert_not_match "the default tag untouched" 'evo-t1-dev' "${log}"
  assert_match "ran that tag" 'my:tag bazelisk test //:test-fast$' "$(stub_log_last docker)"
}

@test "test-in-image: DEV_IMAGE_TAG repoints the default tag from the environment" {
  export STUB_DOCKER_INSPECT=1
  run --separate-stderr env DEV_IMAGE_TAG=evo-t1-dev:v9 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_match "probed the env tag" 'image inspect evo-t1-dev:v9' "$(stub_log docker)"
  assert_match "ran the env tag" 'evo-t1-dev:v9 bazelisk test //:test-fast$' "$(stub_log_last docker)"
}

@test "test-in-image: --user repoints the container user" {
  export STUB_DOCKER_INSPECT=1
  run --separate-stderr bash "${SCRIPT}" --user coder
  [ "${status}" -eq 0 ]
  assert_match "named user" '--user coder' "$(stub_log_last docker)"
}

@test "test-in-image: everything after -- reaches bazelisk verbatim" {
  export STUB_DOCKER_INSPECT=1
  run --separate-stderr bash "${SCRIPT}" -- test //:lint --test_tag_filters=manual
  [ "${status}" -eq 0 ]
  local line
  line="$(stub_log_last docker)"
  assert_match "the flags reached bazelisk" 'bazelisk test //:lint --test_tag_filters=manual$' "${line}"
  assert_not_match "no separator leaked" 'bazelisk -- ' "${line}"
  assert_not_match "the default suite is gone" 'test-fast' "${line}"
}

@test "test-in-image: inside the contributor container bazelisk runs here and docker is never called" {
  fake_bazelisk
  run --separate-stderr env EVO_T1_DEVCONTAINER=1 bash "${SCRIPT}" -- test //:lint --test_tag_filters=manual
  [ "${status}" -eq 0 ]
  assert_match "bazelisk got the argv" '^bazelisk test //:lint --test_tag_filters=manual$' "$(stub_log bazelisk)"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "test-in-image: the contributor container path also defaults to test-fast" {
  fake_bazelisk
  run --separate-stderr env EVO_T1_DEVCONTAINER=1 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_match "the default suite ran here" '^bazelisk test //:test-fast$' "$(stub_log bazelisk)"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "test-in-image: a docker step that fails fails this script instead of passing quietly" {
  export STUB_DOCKER_RC=1
  run --separate-stderr bash "${SCRIPT}"
  [ "${status}" -ne 0 ]
  assert_match "the build was the step that failed" '^docker build ' "$(stub_log_last docker)"
}

@test "test-in-image: no docker CLI on a host is a refusal, not a silent skip" {
  # A PATH holding only what the script needs before its own probe (dirname),
  # so command -v docker answers "no" on every host: no skip, and no
  # dependence on whether this machine happens to have docker installed.
  local nodocker="${BATS_TEST_TMPDIR?}/nodocker"
  mkdir -p "${nodocker}"
  ln -s "$(command -v dirname)" "${nodocker}/dirname"
  run --separate-stderr env PATH="${nodocker}" "$(command -v bash)" "${SCRIPT}"
  [ "${status}" -eq 1 ]
  assert_match "docker is named" 'docker is not on PATH' "${stderr}"
  [ "$(stub_log_count docker)" -eq 0 ]
}
