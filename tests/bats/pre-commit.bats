#!/usr/bin/env bats
#
# ## pre-commit.bats — the gate the git hooks call
#
# Covers scripts/pre-commit.sh: bazel_ingress (bazelisk first, then bazel), the
# hermetic arm, the --all arm that adds //:test-all, the --image arm that hands
# the full set to //scripts:test-in-image, main's mode dispatch, and the failure
# path where a red gate has to leave the hook non-zero.
#
# Safety: no real bazel and no real docker run. Both are PATH stubs written into
# this test's own bin/, and the CLI works in a scratch checkout under
# BATS_TEST_TMPDIR, so nothing here builds, pulls, or touches a stack.

load 'test_helper'

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  export REPO_ROOT
  SCRIPT="${REPO_ROOT}/scripts/pre-commit.sh"
  [ -f "${SCRIPT}" ] || skip "scripts/pre-commit.sh is not in the tree yet"

  STUB_BIN="${BATS_TEST_TMPDIR}/gate-bin"
  mkdir -p "${STUB_BIN}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"

  cat >"${STUB_BIN}/bazelisk" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG}/bazelisk.log"
exit "${BAZEL_STUB_RC:-0}"
STUB
  cat >"${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG}/docker.log"
exit "${DOCKER_STUB_RC:-0}"
STUB
  chmod 755 "${STUB_BIN}/bazelisk" "${STUB_BIN}/docker"

  CHECKOUT="$(make_scratch)"
  : >"${CHECKOUT}/docker-compose.yml"
  printf 'SHARED=1\n' >"${CHECKOUT}/.env.sample"
  printf 'SHARED=1\n' >"${CHECKOUT}/.env.example"
  PATH_ORIG="${PATH}"
}

# The direct-call tests narrow PATH to prove an ingress or docker is absent.
# bats runs teardown in the same process as the test, so the original PATH is
# restored there; without this the next teardown loses rm and mktemp.
teardown() {
  PATH="${PATH_ORIG:-${PATH}}"
  export PATH
}

run_gate() {
  run --separate-stderr env \
    REPO_ROOT="${CHECKOUT}" \
    PATH="$(with_path "${STUB_BIN}")" \
    STUB_LOG="${STUB_LOG}" \
    BAZEL_STUB_RC="${BAZEL_STUB_RC:-0}" \
    DOCKER_STUB_RC="${DOCKER_STUB_RC:-0}" \
    bash "${SCRIPT}" "$@"
}

# load_gate_api — pull the four gate functions into this shell, with the
# reporting helpers they call, so a test can assert on a function's own return
# code rather than inferring it from main's exit status.
load_gate_api() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  unset JSON_MODE
  ROOT_DIR="${CHECKOUT}"
  load_shell_function "${SCRIPT}" bazel_ingress
  load_shell_function "${SCRIPT}" run_hermetic_gate
  load_shell_function "${SCRIPT}" run_full_gate
  load_shell_function "${SCRIPT}" run_image_gate
}

# path_without <tool> — PATH with every directory that ships <tool> dropped, so
# an "absent tool" branch is proven rather than stubbed.
path_without() {
  local tool="$1" dir keep=""
  local IFS=':'
  for dir in ${PATH}; do
    [[ -n ${dir} && ! -x "${dir}/${tool}" ]] || continue
    keep="${keep:+${keep}:}${dir}"
  done
  printf '%s' "${keep}"
}

@test "pre-commit: the default arm runs the hermetic gate and passes on a green tree" {
  run_gate
  [ "${status}" -eq 0 ]
  assert_match "section header" '^== Hermetic gate ==' "${output}"
  assert_eq "one bazel invocation" "1" "$(stub_log_count bazelisk)"
  assert_eq "bazel asked for test-fast and lint" \
    "test //:test-fast //:lint --test_tag_filters=manual" "$(stub_log_last bazelisk)"
  assert_eq "compose checked" "compose config -q" "$(stub_log_last docker)"
  assert_match "closing summary" 'summary: 1 ok, 0 warnings, 0 failed' "${output}"
}

@test "pre-commit: a red bazel run fails the gate" {
  BAZEL_STUB_RC=1
  export BAZEL_STUB_RC
  run_gate
  [ "${status}" -eq 1 ]
  assert_match "reports the failure" 'the gate failed' "${stderr}"
}

@test "pre-commit: a red compose config fails the gate" {
  DOCKER_STUB_RC=1
  export DOCKER_STUB_RC
  run_gate
  [ "${status}" -eq 1 ]
  assert_match "reports the failure" 'the gate failed' "${stderr}"
}

@test "pre-commit: the env samples must still match" {
  printf 'DRIFT=1\n' >>"${CHECKOUT}/.env.example"
  run_gate
  [ "${status}" -eq 1 ]
  assert_match "reports the failure" 'the gate failed' "${stderr}"
  # The arms keep going after a failed check so one run reports every problem,
  # so compose is still consulted even though cmp already failed.
  assert_eq "compose still checked" "1" "$(stub_log_count docker)"
}

@test "pre-commit: --all adds the full gate, docs gates and coverage included" {
  run_gate --all
  [ "${status}" -eq 0 ]
  assert_match "full section" '^== Full gate ==' "${output}"
  assert_eq "bazel ran twice" "2" "$(stub_log_count bazelisk)"
  assert_eq "second call names test-all" "test //:test-all" "$(stub_log_last bazelisk)"
}

@test "pre-commit: --all fails when the full gate fails" {
  BAZEL_STUB_RC=1
  export BAZEL_STUB_RC
  run_gate --all
  [ "${status}" -eq 1 ]
  assert_match "reports the failure" 'the gate failed' "${stderr}"
}

@test "pre-commit: --image hands the full set to test-in-image" {
  run_gate --image
  [ "${status}" -eq 0 ]
  assert_match "image section" '^== Golden-image gate ==' "${output}"
  assert_eq "second call runs test-in-image" \
    "run //scripts:test-in-image -- -- test //:test-all" "$(stub_log_last bazelisk)"
}

@test "pre-commit: bazel_ingress falls back to bazel when bazelisk is absent" {
  local only_bazel="${BATS_TEST_TMPDIR}/only-bazel"
  mkdir -p "${only_bazel}"
  cat >"${only_bazel}/bazel" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG}/bazel.log"
exit 0
STUB
  cp "${STUB_BIN}/docker" "${only_bazel}/docker"
  chmod 755 "${only_bazel}/bazel" "${only_bazel}/docker"

  # Drop both the stub directory (which holds the bazelisk stub) and the real
  # system directory that provides bazelisk, so nothing can answer for
  # bazelisk and only `bazel` remains.
  local real_bazel_dir
  real_bazel_dir="$(dirname "$(command -v bazelisk)")"
  local stripped
  stripped="$(printf '%s' "$(with_path "${STUB_BIN}")" | tr ':' '\n' |
    grep -vxF -e "${STUB_BIN}" -e "${real_bazel_dir}" | paste -sd: -)"
  [ -n "${stripped}" ] || fail "PATH filter left nothing"

  run --separate-stderr env \
    REPO_ROOT="${CHECKOUT}" \
    PATH="${only_bazel}:${stripped}" \
    STUB_LOG="${STUB_LOG}" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_eq "bazel was used" "test //:test-fast //:lint --test_tag_filters=manual" "$(stub_log_last bazel)"
  assert_eq "bazelisk was never used" "0" "$(stub_log_count bazelisk)"
}

@test "pre-commit: an unknown mode is refused" {
  run_gate --nonsense
  [ "${status}" -eq 1 ]
  assert_match "names the bad mode" "unknown mode '--nonsense'" "${stderr}"
  assert_eq "nothing ran" "0" "$(stub_log_count bazelisk)"
}

@test "pre-commit: bazel_ingress prints bazelisk when both are available" {
  load_gate_api
  PATH="$(with_path "${STUB_BIN}")"

  run bazel_ingress
  [ "${status}" -eq 0 ]
  assert_eq "bazelisk wins" "bazelisk" "${output}"
}

@test "pre-commit: bazel_ingress fails when neither ingress is on PATH" {
  load_gate_api
  local empty="${BATS_TEST_TMPDIR}/no-ingress"
  mkdir -p "${empty}"
  PATH="${empty}"

  run bazel_ingress
  [ "${status}" -eq 1 ]
  assert_eq "nothing is printed on the failure" "" "${output}"
}

@test "pre-commit: run_hermetic_gate returns the status of the checks it ran" {
  load_gate_api
  export STUB_LOG
  ROOT_DIR="${CHECKOUT}"
  PATH="$(with_path "${STUB_BIN}")"
  cd "${CHECKOUT}"

  BAZEL_STUB_RC=0 DOCKER_STUB_RC=0 run --separate-stderr run_hermetic_gate
  [ "${status}" -eq 0 ]
  assert_eq "the suite ran once" "test //:test-fast //:lint --test_tag_filters=manual" \
    "$(stub_log_last bazelisk)"

  BAZEL_STUB_RC=1 run --separate-stderr run_hermetic_gate
  [ "${status}" -eq 1 ]

  printf 'DRIFT=1\n' >>"${CHECKOUT}/.env.example"
  BAZEL_STUB_RC=0 run --separate-stderr run_hermetic_gate
  [ "${status}" -eq 1 ]
}

@test "pre-commit: run_full_gate names //:test-all and fails when it is red" {
  load_gate_api
  export STUB_LOG
  ROOT_DIR="${CHECKOUT}"
  PATH="$(with_path "${STUB_BIN}")"

  BAZEL_STUB_RC=0 run --separate-stderr run_full_gate
  [ "${status}" -eq 0 ]
  assert_eq "the full suite was named" "test //:test-all" "$(stub_log_last bazelisk)"

  BAZEL_STUB_RC=1 run --separate-stderr run_full_gate
  [ "${status}" -eq 1 ]
}

@test "pre-commit: run_image_gate delegates to test-in-image" {
  load_gate_api
  export STUB_LOG
  ROOT_DIR="${CHECKOUT}"
  PATH="$(with_path "${STUB_BIN}")"

  BAZEL_STUB_RC=0 run --separate-stderr run_image_gate
  [ "${status}" -eq 0 ]
  assert_eq "the image runner was invoked" \
    "run //scripts:test-in-image -- -- test //:test-all" "$(stub_log_last bazelisk)"
}

@test "pre-commit: run_image_gate refuses without docker" {
  load_gate_api
  export STUB_LOG
  ROOT_DIR="${CHECKOUT}"
  # A bin dir holding the ingress and nothing else, plus a PATH with every
  # directory that ships docker removed: the absence is real, not stubbed.
  local only_ingress="${BATS_TEST_TMPDIR}/ingress-only"
  mkdir -p "${only_ingress}"
  cp "${STUB_BIN}/bazelisk" "${only_ingress}/bazelisk"
  chmod 755 "${only_ingress}/bazelisk"
  PATH="$(with_path "${only_ingress}")"
  PATH="$(path_without docker)"
  [ -n "${PATH}" ] || fail "PATH filter left nothing"
  command -v docker >/dev/null 2>&1 && fail "docker still resolves on the filtered PATH"

  run --separate-stderr run_image_gate
  [ "${status}" -eq 1 ]
  assert_match "says what is missing" 'docker is not on PATH' "${stderr}"
  assert_eq "no build was started" "0" "$(stub_log_count bazelisk)"
}
