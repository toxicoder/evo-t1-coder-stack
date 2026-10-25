#!/usr/bin/env bats
#
# ## run-npm.bats — docs-site/run_npm.sh gives npm a real HOME.
#
# Bazel test actions drop HOME, and GitHub Actions runs the golden image as
# the runner uid (not in /etc/passwd). npm then dies with
# uv_os_homedir ENOENT before it reads package.json. This suite stubs npm
# and checks the wrapper still hands it an existing directory.
#
# Usage: bazelisk test //tests:bats_run_npm_test
# Safety: copies run_npm.sh into a scratch tree; never calls a real npm.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/docs-site/run_npm.sh"
  [[ -f ${SCRIPT} ]] || skip "docs-site/run_npm.sh is not in the tree"
}

# stub_npm_tree — scratch copy of run_npm.sh plus an npm that logs HOME.
stub_npm_tree() {
  local scratch bin
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/docs-site" "${scratch}/bin" "${scratch}/tmp"
  cp "${SCRIPT}" "${scratch}/docs-site/run_npm.sh"
  cat >"${scratch}/bin/npm" <<'NPM'
#!/usr/bin/env bash
printf 'HOME=%s\n' "${HOME}" >>"${NPM_LOG}"
printf 'npm %s\n' "$*" >>"${NPM_LOG}"
if [[ -z ${HOME:-} || ! -d ${HOME} ]]; then
  printf 'missing HOME\n' >>"${NPM_LOG}"
  exit 1
fi
exit 0
NPM
  chmod 755 "${scratch}/bin/npm"
  printf '%s' "${scratch}"
}

@test "run_npm: an unset HOME still reaches npm with a real directory" {
  local scratch
  scratch="$(stub_npm_tree)"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run env -u HOME -u TEST_TMPDIR PATH="${scratch}/bin:${PATH}" TMPDIR="${scratch}/tmp" \
    bash "${scratch}/docs-site/run_npm.sh" install
  [ "${status}" -eq 0 ]
  [[ -f ${NPM_LOG} ]]
  grep -q '^npm ci --legacy-peer-deps$' "${NPM_LOG}"
  grep -qv '^missing HOME$' "${NPM_LOG}"
  local home
  home="$(sed -n 's/^HOME=//p' "${NPM_LOG}" | head -n 1)"
  [[ -n ${home} && -d ${home} ]]
}

@test "run_npm: a missing HOME path is replaced with a directory that exists" {
  local scratch
  scratch="$(stub_npm_tree)"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run env HOME="${scratch}/no-such-home" PATH="${scratch}/bin:${PATH}" TMPDIR="${scratch}/tmp" \
    bash "${scratch}/docs-site/run_npm.sh" install
  [ "${status}" -eq 0 ]
  grep -q '^npm ci --legacy-peer-deps$' "${NPM_LOG}"
  local home
  home="$(sed -n 's/^HOME=//p' "${NPM_LOG}" | head -n 1)"
  [[ -n ${home} && -d ${home} ]]
  [ "${home}" != "${scratch}/no-such-home" ]
}

@test "run_npm: an existing HOME is left alone" {
  local scratch keep
  scratch="$(stub_npm_tree)"
  keep="${scratch}/keep-home"
  mkdir -p "${keep}"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run env HOME="${keep}" PATH="${scratch}/bin:${PATH}" \
    bash "${scratch}/docs-site/run_npm.sh" install
  [ "${status}" -eq 0 ]
  grep -q "^HOME=${keep}$" "${NPM_LOG}"
}
