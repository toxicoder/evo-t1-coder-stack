#!/usr/bin/env bats
#
# ## run-npm.bats — docs-site/run_npm.sh gives npm a real HOME.
#
# Bazel test actions drop HOME, and GitHub Actions runs the golden image as
# the runner uid (not in /etc/passwd). npm then dies with
# uv_os_homedir ENOENT before it reads package.json. This suite stubs npm
# and checks the wrapper still hands it an existing directory, that the
# deps gate installs only when the site's own binaries are missing, and that
# the coverage arm measures a real checkout. Every npm-backed gate reads one
# node_modules in that checkout, so the suite also starts two cold gates side by
# side: the install has to run once for both, a box without flock has to install
# anyway, and a lock someone else never releases has to fail with a cause.
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
# Hold an install open long enough that a second gate has to meet the lock,
# then leave the site's binaries behind the way a real `npm ci` does: the
# waiter inside the lock decides whether to install by looking for them.
if [[ ${1:-} == ci ]]; then
  if [[ -n ${NPM_SLEEP:-} ]]; then
    sleep "${NPM_SLEEP}"
  fi
  mkdir -p node_modules/.bin
  : >node_modules/.bin/next
  : >node_modules/.bin/vitest
  chmod 755 node_modules/.bin/next node_modules/.bin/vitest
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

# core_path <scratch> — a directory holding just the external commands
# run_npm.sh shells out to, for a PATH that has no flock in it.
core_path() {
  local scratch="$1" dir="${scratch}/core" tool
  mkdir -p "${dir}"
  for tool in bash basename dirname mkdir readlink; do
    ln -s "$(command -v "${tool}")" "${dir}/${tool}"
  done
  printf '%s' "${dir}"
}

@test "run_npm: two cold gates install the shared tree once" {
  # The regression this pins: //:test-all starts typecheck, unit, unit_coverage
  # and verify as parallel Bazel actions against a checkout with no
  # node_modules yet. Unlocked, each ran its own `npm ci` into the tree the
  # others read, and a gate that started while another was mid-install took a
  # SIGBUS on a short esbuild binary. One install, and both gates still run.
  local scratch rc1 rc2 installs
  scratch="$(stub_npm_tree)"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG NPM_SLEEP=2
  env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" build \
    >"${scratch}/a.out" 2>&1 &
  local p1=$!
  env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" bash "${scratch}/docs-site/run_npm.sh" typecheck \
    >"${scratch}/b.out" 2>&1 &
  local p2=$!
  wait "${p1}" && rc1=0 || rc1=$?
  wait "${p2}" && rc2=0 || rc2=$?
  assert_eq "the first gate finished" "0" "${rc1}"
  assert_eq "the gate that waited finished" "0" "${rc2}"
  installs="$(grep -c '^npm ci --legacy-peer-deps$' "${NPM_LOG}" || true)"
  assert_eq "the install ran exactly once" "1" "${installs}"
  assert_match "and both gates still ran their own script" 'npm run build$' "$(cat "${NPM_LOG}")"
  assert_match "including the one that waited for the lock" 'npm run typecheck$' "$(cat "${NPM_LOG}")"
}

@test "run_npm: a gate still installs where flock is missing" {
  # A macOS laptop has no util-linux flock. The arm has to install unlocked,
  # because refusing to install would leave a contributor with no site.
  local scratch core
  scratch="$(stub_npm_tree)"
  core="$(core_path "${scratch}")"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  [[ -e ${core}/basename ]]
  if ! PATH="${scratch}/bin:${core}" command -v flock >/dev/null 2>&1; then
    : # the shape the arm is meant to take
  else
    skip "flock is reachable on a restricted PATH here"
  fi
  run env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${core}" bash "${scratch}/docs-site/run_npm.sh" build
  [ "${status}" -eq 0 ]
  [[ ${output} == *"docs-site: installing npm deps"* ]]
  assert_eq "the install ran" "npm ci --legacy-peer-deps" "$(grep '^npm ' "${NPM_LOG}" | head -n 1)"
  assert_eq "then the asked-for script" "npm run build" "$(grep '^npm ' "${NPM_LOG}" | tail -n 1)"
}

@test "run_npm: a lock held past the wait fails with a named cause" {
  # A wedged installer must surface as this gate's own error, not as the Bazel
  # test timeout, so the wait is bounded and its cause is printed.
  command -v flock >/dev/null 2>&1 || skip "no flock on this box"
  local scratch lock holder waited
  scratch="$(stub_npm_tree)"
  NPM_LOG="${scratch}/npm.log"
  export NPM_LOG
  lock="${scratch}/docs-site/.npm-ci.lock"
  : >"${lock}"
  flock -x "${lock}" sleep 10 &
  holder=$!
  # Only start the gate once the lock is observably held, so this pins the
  # timeout rather than whichever installer happens to win.
  waited=0
  while flock -n -x "${lock}" true 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "${waited}" -gt 100 ]; then
      kill "${holder}" 2>/dev/null || true
      skip "the test holder never took the lock"
    fi
  done
  run --separate-stderr env -u BUILD_WORKSPACE_DIRECTORY HOME="${scratch}/home" \
    PATH="${scratch}/bin:${PATH}" NPM_CI_LOCK_WAIT=1 \
    bash "${scratch}/docs-site/run_npm.sh" build
  kill "${holder}" 2>/dev/null || true
  wait "${holder}" 2>/dev/null || true
  [ "${status}" -eq 1 ]
  assert_match "names the lock it could not take" 'npm-ci.lock' "${stderr}"
  assert_eq "npm ci never ran" "" "$(grep '^npm ci' "${NPM_LOG}" 2>/dev/null || true)"
}
