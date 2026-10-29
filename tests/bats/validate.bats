#!/usr/bin/env bats
#
# ## validate.bats - hermetic coverage for scripts/validate.sh.
#
# validate.sh is the git-unaware local gate, so its whole contract is the report
# it prints and what it refuses to do twice: the report is the operator's
# `== Validate ==` / `-> phase` / `summary: N ok, W warnings, F failed` shape;
# VALIDATE_INNER=1 is what stops a `bazelisk run //:validate` from recursing into
# Bazel; a missing bazelisk is a refusal rather than a quietly partial gate; and
# an optional tool that is absent (terraform, PyYAML) is announced as skipped
# instead of passing silently.
#
# Usage: bazelisk test //tests:bats_validate_test   (from any cwd)
# Safety: docker and terraform are the tests/bats/tool_stubs copies, and bazelisk
# and python3 are per-test fakes written into the test's own bin directory, so no
# Bazel invocation and no daemon happens here. The gate runs inside a scratch
# checkout that holds copies of the files it reads by path.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/validate.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/validate.sh is not in the tree"
  use_stubs docker terraform
  ROOT="$(scratch_checkout)"
}

# scratch_checkout - the checkout validate.sh cd's into and reads by path.
scratch_checkout() {
  local scratch
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/scripts/lib" "${scratch}/homepage/config" "${scratch}/litellm" "${scratch}/hermes" "${scratch}/searxng"
  printf 'services: {}\n' >"${scratch}/docker-compose.yml"
  cp "${REPO_ROOT}/scripts/lib/common.sh" "${scratch}/scripts/lib/common.sh"
  cp "${REPO_ROOT}/scripts/lib/parse_yaml.py" "${scratch}/scripts/lib/parse_yaml.py"
  cp "${REPO_ROOT}/.env.sample" "${scratch}/.env.sample"
  cp "${REPO_ROOT}/.env.example" "${scratch}/.env.example"
  cp "${REPO_ROOT}"/homepage/config/*.yaml "${scratch}/homepage/config/"
  cp "${REPO_ROOT}/litellm/config.yaml" "${scratch}/litellm/config.yaml"
  cp "${REPO_ROOT}/hermes/config.yaml" "${scratch}/hermes/config.yaml"
  cp "${REPO_ROOT}/searxng/settings.yml" "${scratch}/searxng/settings.yml"
  printf '%s' "${scratch}"
}

# fake_python3 - answer only the PyYAML probe and the parse call, logging argv, so
# both optional arms are chosen by the test rather than by this host's site-packages.
fake_python3() {
  local bin="${BATS_TEST_TMPDIR?}/bin"
  cat >"${bin}/python3" <<'FAKE_PY'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'python3 %s\n' "$*" >>"${STUB_LOG}/python3.log"; fi
if [ "${1:-}" = "-c" ]; then
  exit "${STUB_PY_PROBE_RC:-0}"
fi
printf 'parsed %s\n' "${*:2}"
exit "${STUB_PY_RC:-0}"
FAKE_PY
  chmod 755 "${bin}/python3"
}

# fake_bazelisk - record argv and whether the recursion guard was passed down.
fake_bazelisk() {
  local bin="${BATS_TEST_TMPDIR?}/bin"
  cat >"${bin}/bazelisk" <<'FAKE_BAZELISK'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then
  printf 'bazelisk %s [VALIDATE_INNER=%s]\n' "$*" "${VALIDATE_INNER:-unset}" >>"${STUB_LOG}/bazelisk.log"
fi
exit "${STUB_BAZELISK_RC:-0}"
FAKE_BAZELISK
  chmod 755 "${bin}/bazelisk"
}

# minimal_path - a PATH holding only the named stubs plus cmp, so an absent
# optional tool is a fact of this test and not of the host.
minimal_path() {
  local dir tool
  dir="${BATS_TEST_TMPDIR?}/minbin"
  mkdir -p "${dir}"
  # bash too: the stubs are #!/usr/bin/env bash scripts, so env has to find the
  # interpreter on this PATH as well.
  ln -sf "$(command -v bash)" "${dir}/bash"
  ln -sf "$(command -v cmp)" "${dir}/cmp"
  for tool in "$@"; do
    ln -sf "${BATS_TEST_TMPDIR?}/bin/${tool}" "${dir}/${tool}"
  done
  printf '%s' "${dir}"
}

@test "validate: VALIDATE_INNER=1 runs the checks here and never calls bazel" {
  fake_python3
  run --separate-stderr env VALIDATE_INNER=1 BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_match "the section header" '^== Validate ==$' "${output}"
  assert_match "the compose check" '^-> docker compose config -q$' "${output}"
  assert_match "the env twins are compared" '^-> cmp \.env\.sample \.env\.example$' "${output}"
  assert_match "terraform is checked" '^-> terraform fmt -check$' "${output}"
  assert_match "the yaml parse runs" '^-> yaml parse$' "${output}"
  assert_match "the closing ok line" '^ok: validate$' "${output}"
  assert_match "the summary counts one ok" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
  assert_eq "compose was the only docker call" "docker compose config -q" "$(stub_log_last docker)"
  assert_match "both template trees are formatted" 'terraform -chdir=templates/workspace fmt -check' "$(stub_log terraform)"
  assert_match "the devcontainer twin too" 'terraform -chdir=templates/devcontainer fmt -check' "$(stub_log terraform)"
  assert_match "the parse argv names the payloads" 'parse_yaml\.py homepage/config/.*litellm/config\.yaml hermes/config\.yaml searxng/settings\.yml' "$(stub_log python3)"
  [ "$(stub_log_count bazelisk)" -eq 0 ]
}

@test "validate: the searxng payload keeps the two settings the search lane depends on" {
  # Pinned here because nothing else guards them, and both fail silently and
  # far from the file. An empty search.autocomplete makes the MCP bridge's
  # autocomplete tool answer "No suggestions." on every query while still
  # returning HTTP 200, so it looks like a dead lane rather than a config
  # choice. The Cloudflare-family suspend times ship at 15 and 7 days for a
  # public instance; on this private box one challenge takes an engine out for
  # a fortnight with nothing self-healing it.
  local settings="${REPO_ROOT}/searxng/settings.yml"
  [ -f "${settings}" ] || skip "no searxng/settings.yml reachable from ${REPO_ROOT}"

  run grep -Eq '^[[:space:]]*autocomplete:[[:space:]]*"[^"]+"' "${settings}"
  [ "${status}" -eq 0 ]
  run grep -Eq '^[[:space:]]*autocomplete:[[:space:]]*""[[:space:]]*$' "${settings}"
  [ "${status}" -ne 0 ]

  # Both answer formats, or the JSON API answers 403 for every engine at once.
  run grep -Eq '^[[:space:]]*-[[:space:]]*json[[:space:]]*$' "${settings}"
  [ "${status}" -eq 0 ]

  # A park must expire on the order of minutes, not weeks.
  run grep -Eq '^[[:space:]]*cf_SearxEngineCaptcha:[[:space:]]*[0-9]+[[:space:]]*$' "${settings}"
  [ "${status}" -eq 0 ]
  local cap
  cap="$(sed -n 's/^[[:space:]]*cf_SearxEngineCaptcha:[[:space:]]*\([0-9]\+\)[[:space:]]*$/\1/p' "${settings}")"
  [ "${cap}" -le 3600 ]

  run grep -Eq '^[[:space:]]*recaptcha_SearxEngineCaptcha:[[:space:]]*[0-9]+[[:space:]]*$' "${settings}"
  [ "${status}" -eq 0 ]
  cap="$(sed -n 's/^[[:space:]]*recaptcha_SearxEngineCaptcha:[[:space:]]*\([0-9]\+\)[[:space:]]*$/\1/p' "${settings}")"
  [ "${cap}" -le 3600 ]
}

@test "validate: without VALIDATE_INNER the nested bazel tests run first, guarded" {
  fake_python3
  fake_bazelisk
  run --separate-stderr env -u VALIDATE_INNER BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count bazelisk)" -eq 2 ]
  assert_match "test-fast is the first call" '^bazelisk test //:test-fast --config=ci \[VALIDATE_INNER=1\]$' "$(stub_log bazelisk)"
  assert_match "lint is the second" '^bazelisk test //:lint --config=ci --test_tag_filters=manual \[VALIDATE_INNER=1\]$' "$(stub_log bazelisk)"
  assert_match "the phase names the command it is about to run" \
    '^-> .*bazelisk test //:test-fast //:lint --test_tag_filters=manual$' "${output}"
  assert_match "the local checks still ran" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
}

@test "validate: a bazel step that fails stops the gate before the local checks" {
  fake_python3
  fake_bazelisk
  run --separate-stderr env -u VALIDATE_INNER BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    STUB_BAZELISK_RC=1 bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  assert_not_match "no verdict is printed for a gate that did not finish" 'summary:' "${output}"
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "validate: no bazelisk on PATH is a refusal, not a partial pass" {
  # The minimal PATH also has no bazel and no bazelisk, so `command -v` answers
  # "no" on every host instead of finding a developer's Bazel.
  local minbin
  minbin="$(minimal_path docker)"
  run --separate-stderr env -u VALIDATE_INNER -u JSON_MODE BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    PATH="${minbin}" "$(command -v bash)" "${SCRIPT}"
  [ "${status}" -eq 1 ]
  assert_match "the missing tool is named" '^bazelisk is not on PATH$' "${stderr}"
  [ "$(stub_log_count docker)" -eq 0 ]
  assert_not_match "no verdict without the checks" 'summary:' "${output}"
}

@test "validate: a missing terraform is announced as skipped" {
  fake_python3
  local minbin
  minbin="$(minimal_path docker python3)"
  run --separate-stderr env VALIDATE_INNER=1 BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    PATH="${minbin}" "$(command -v bash)" "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_match "the skip is a phase line" '^-> terraform not on PATH, skipping fmt -check$' "${output}"
  assert_match "the gate still ends in a verdict" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
  [ "$(stub_log_count terraform)" -eq 0 ]
}

@test "validate: PyYAML being absent is announced as skipped" {
  fake_python3
  run --separate-stderr env VALIDATE_INNER=1 BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    STUB_PY_PROBE_RC=1 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_match "the skip is a phase line" '^-> PyYAML not installed, skipping yaml parse$' "${output}"
  assert_match "the gate still ends in a verdict" '^ok: validate$' "${output}"
  [ "$(stub_log_count python3)" -eq 1 ]
}

@test "validate: a compose check that fails fails the gate before the verdict" {
  fake_python3
  run --separate-stderr env VALIDATE_INNER=1 BUILD_WORKSPACE_DIRECTORY="${ROOT}" \
    STUB_DOCKER_RC=1 bash "${SCRIPT}"
  [ "${status}" -ne 0 ]
  assert_match "the compose phase was the last one reached" '^-> docker compose config -q$' "${output}"
  assert_not_match "no verdict is printed for a failed gate" 'summary:' "${output}"
  [ "$(stub_log_count terraform)" -eq 0 ]
}
