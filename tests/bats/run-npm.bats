#!/usr/bin/env bats
#
# ## run-npm.bats — docs-site/run_npm.sh gives npm a real HOME.
#
# Bazel test actions drop HOME, and GitHub Actions runs the golden image as
# the runner uid (not in /etc/passwd). npm then dies with
# uv_os_homedir ENOENT before it reads package.json. This suite stubs npm
# and checks the wrapper still hands it an existing directory, that the
# deps gate installs only when the site's own binaries are missing, and that
# the coverage arm measures a real checkout.
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

# install_site_bins <scratch> <bin...> - put the site's own binaries where
# ensure_deps looks for them, relative to the directory run_npm.sh cd's into.
install_site_bins() {
  local scratch="$1" bin
  mkdir -p "${scratch}/docs-site/node_modules/.bin"
  for bin in "${@:2}"; do
    : >"${scratch}/docs-site/node_modules/.bin/${bin}"
    chmod 755 "${scratch}/docs-site/node_modules/.bin/${bin}"
  done
}

@test "run_npm: a site with nothing installed installs the deps before building" {
  local scratch
  scratch="$(stub_npm_tree)"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  # BUILD_WORKSPACE_DIRECTORY would redirect the cd out of the scratch tree, and
  # ensure_deps reads node_modules relative to that directory.
  run env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" build
  [ "${status}" -eq 0 ]
  [[ ${output} == *"docs-site: installing npm deps"* ]]
  assert_eq "the install is the first npm call" "npm ci --legacy-peer-deps" "$(grep '^npm ' "${NPM_LOG}" | head -n 1)"
  assert_eq "then the build runs" "npm run build" "$(grep '^npm ' "${NPM_LOG}" | tail -n 1)"
}

@test "run_npm: a site that already has its binaries is not re-installed" {
  local scratch
  scratch="$(stub_npm_tree)"
  install_site_bins "${scratch}" next vitest
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" build
  [ "${status}" -eq 0 ]
  assert_not_match "no install was announced" 'installing npm deps' "${output}"
  assert_not_match "npm ci never ran" 'npm ci' "$(cat "${NPM_LOG}")"
  assert_eq "the build ran directly" "npm run build" "$(grep '^npm ' "${NPM_LOG}" | tail -n 1)"
}

@test "run_npm: a half-installed site still gets the install" {
  # next alone is not enough: the gate checks the test binary too, and a site
  # that has never run the unit suite must not reach `typecheck` half-provisioned.
  local scratch
  scratch="$(stub_npm_tree)"
  install_site_bins "${scratch}" next
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" typecheck
  [ "${status}" -eq 0 ]
  [[ ${output} == *"docs-site: installing npm deps"* ]]
  assert_eq "the install came first" "npm ci --legacy-peer-deps" "$(grep '^npm ' "${NPM_LOG}" | head -n 1)"
  assert_eq "then the asked-for script" "npm run typecheck" "$(grep '^npm ' "${NPM_LOG}" | tail -n 1)"
}

@test "run_npm: unit_coverage runs the coverage script from the real checkout" {
  local scratch
  scratch="$(stub_npm_tree)"
  install_site_bins "${scratch}" next vitest
  # The coverage arm only trusts a directory that is a site: package.json is the
  # proof it found a checkout and not a runfiles tree of symlinks.
  printf '{"name":"evo-t1-docs-site"}\n' >"${scratch}/docs-site/package.json"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run env -u BUILD_WORKSPACE_DIRECTORY -u TEST_TMPDIR HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" unit_coverage
  [ "${status}" -eq 0 ]
  assert_eq "the coverage script ran" "npm run unit:coverage" "$(grep '^npm ' "${NPM_LOG}" | tail -n 1)"
}

@test "run_npm: unit_coverage refuses a copy that is not a checkout" {
  local scratch
  # Same tree, no package.json: v8 would read every file at 0% through symlinked
  # sources, so the arm has to say so and stop rather than report a red gate.
  scratch="$(stub_npm_tree)"
  install_site_bins "${scratch}" next vitest
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  run --separate-stderr env -u BUILD_WORKSPACE_DIRECTORY -u TEST_TMPDIR HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" unit_coverage
  [ "${status}" -eq 1 ]
  assert_match "names the cause" 'did not resolve to a checkout' "${stderr}"
  assert_match "points at the runnable form" 'bazelisk run' "${stderr}"
  assert_eq "npm never ran" "" "$(grep '^npm ' "${NPM_LOG}" 2>/dev/null || true)"
}
