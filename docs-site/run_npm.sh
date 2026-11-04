#!/usr/bin/env bash
#
# Bazel entry point wrapper for docs-site npm scripts.
#   bazelisk run //docs-site:install
#   bazelisk run //docs-site:dev
#   bazelisk run //docs-site:build
#   bazelisk run //docs-site:typecheck
#   bazelisk run //docs-site:unit
#
# All arguments after -- are passed through to the underlying npm command.
set -euo pipefail

# `bazel run` executes from bazel-out; prefer BUILD_WORKSPACE_DIRECTORY so the build runs in
# the real checkout. The Next build reads its pages from the sibling docs/ directory, which
# does not resolve reliably through the runfiles sandbox, and node_modules plus the export
# land where a developer can see and commit them.
#
# `bazel test` gets no BUILD_WORKSPACE_DIRECTORY, so the arms resolve their own
# runfiles copy back into that same checkout: one node_modules then serves every
# npm-backed gate, and the cold install behind it is held under .npm-ci.lock.
if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} && -d "${BUILD_WORKSPACE_DIRECTORY}/docs-site" ]]; then
  cd "${BUILD_WORKSPACE_DIRECTORY}/docs-site"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$SCRIPT_DIR"
fi

# Node's os.homedir() (libuv uv_os_homedir) fails with ENOENT when HOME is
# unset or names a missing directory and the process uid is not in
# /etc/passwd. GitHub Actions runs the golden image as the runner uid
# (1001), and Bazel test actions drop HOME unless --test_env=HOME is set.
if [[ -z ${HOME:-} || ! -d "${HOME}" ]]; then
  HOME="${TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  export HOME
  mkdir -p "${HOME}"
fi

# A named sh_binary already says which script it is through $0; only the generic
# //docs-site:npm target and a direct `bash run_npm.sh <script>` carry the name in $1.
SUBCMD="$(basename "${0:-npm}")"
NPM_ARGS=("$@")
if [[ $SUBCMD == "run_npm.sh" || $SUBCMD == "npm" ]] && [[ $# -gt 0 ]]; then
  SUBCMD="$1"
  shift
fi

# How long to wait for another npm run to finish installing before giving up on
# it. A cold `npm ci` measured 25s here, so the default is many times that, and
# a waiter that outlasts it fails loudly rather than riding out the test timeout.
NPM_CI_LOCK_WAIT="${NPM_CI_LOCK_WAIT:-900}"

# Is the site's own toolchain already in place? Both binaries are checked: a
# tree with next alone is a site that has never run the unit suite.
deps_present() {
  [[ -x node_modules/.bin/next && -x node_modules/.bin/vitest ]]
}

# Install the site's deps if they are missing, one installer at a time.
#
# Every docs-site npm gate runs out of the same tree (see prefer_real_checkout),
# which turns the first install from a first-run delay into a concurrency
# problem: `npm ci` deletes node_modules before it repopulates it, and
# //:test-all starts typecheck, unit, unit_coverage and verify as parallel Bazel
# test actions against a checkout that has never had one. Unlocked they install
# side by side into that one tree, and a peer that starts reading it while
# another is mid-way through writing loads esbuild's native binary short and
# dies on SIGBUS ("Bus error") inside vitest. The lock makes the check and the
# install one step, and the waiter re-reads the gate inside it, so a cold
# checkout installs once and everyone else reads a finished tree.
ensure_deps() {
  if deps_present; then
    return 0
  fi
  if ! command -v flock >/dev/null 2>&1; then
    # A laptop without util-linux runs one gate at a time, so there is no peer
    # to race. Install unlocked rather than refusing to build.
    echo "→ docs-site: installing npm deps (node_modules missing)"
    npm ci --legacy-peer-deps
    return 0
  fi
  (
    if ! flock -w "${NPM_CI_LOCK_WAIT}" 9; then
      echo "error: another npm run has held docs-site/.npm-ci.lock for ${NPM_CI_LOCK_WAIT}s" >&2
      exit 1
    fi
    if deps_present; then
      exit 0
    fi
    echo "→ docs-site: installing npm deps (node_modules missing)"
    npm ci --legacy-peer-deps
  ) 9>.npm-ci.lock
}

# Move into the checkout this runfiles copy was symlinked from.
#
# v8 coverage pairs each executed script with the file on disk by path. Under
# `bazel test` the sources arrive as symlinks into the checkout, Node resolves
# them to their real path, and the report then matches nothing: every file
# reads 0% and the gate fails on a green tree. The coverage arm has to measure
# the files where they actually live.
run_in_real_checkout() {
  local real dir
  real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  [[ -n ${real} && ${real} != *".runfiles"* ]] || return 1
  dir="$(dirname "${real}")"
  [[ -f ${dir}/package.json ]] || return 1
  cd "${dir}"
}

# Soft form of run_in_real_checkout, for the arms that can run from either tree:
# move into the checkout when this copy resolves to one, stay put when it does
# not. unit_coverage keeps the hard form, because measuring symlinked sources
# reports 0% and has to stop rather than pass on nothing.
prefer_real_checkout() {
  run_in_real_checkout || return 0
}

# Run out of the checkout when there is one to find.
#
# Under `bazel test` the runner starts in its own runfiles tree, where
# node_modules is absent (it is gitignored, so no data edge ships it) and each
# npm-backed gate would therefore run its own cold install. Resolving this copy
# back into the checkout is what //docs-site:unit_coverage already has to do to
# measure anything; doing it for every arm makes one install serve the whole
# family, and it matches what `bazel run //docs-site:<arm>` does through
# BUILD_WORKSPACE_DIRECTORY. A foreign cwd with no checkout to resolve keeps the
# runfiles tree and installs into it, as before.
if [[ -z ${BUILD_WORKSPACE_DIRECTORY:-} ]]; then
  prefer_real_checkout
fi

CMD="npm"

case "$SUBCMD" in
  install)
    # Runs unguarded on purpose: this arm means "reinstall now", and it is
    # something an operator types by hand. The arms that Bazel starts side by
    # side are the ones ensure_deps serialises.
    exec $CMD ci --legacy-peer-deps "$@"
    ;;
  dev)
    ensure_deps
    # --hostname localhost is load-bearing; see the serve arm of docs/manage-docs.sh.
    exec $CMD run dev -- --hostname localhost "$@"
    ;;
  build)
    ensure_deps
    exec $CMD run build "$@"
    ;;
  build-latest)
    ensure_deps
    exec $CMD run build:latest "$@"
    ;;
  serve)
    ensure_deps
    exec $CMD run serve -- "$@"
    ;;
  typecheck)
    ensure_deps
    exec $CMD run typecheck "$@"
    ;;
  unit)
    ensure_deps
    exec $CMD run unit "$@"
    ;;
  unit_coverage)
    # Same suites as `unit`, with the v8 coverage gate on. $0 is the target name,
    # so //docs-site:unit_coverage lands here.
    run_in_real_checkout || {
      echo "error: the runfiles copy did not resolve to a checkout" >&2
      echo "note: v8 reads 0% when it measures symlinked sources, so the gate" >&2
      echo "      runs against the checkout; use 'bazelisk run" >&2
      echo "      //docs-site:unit_coverage' from one" >&2
      exit 1
    }
    ensure_deps
    exec $CMD run unit:coverage "$@"
    ;;
  verify)
    ensure_deps
    exec $CMD run verify "$@"
    ;;
  nav)
    ensure_deps
    exec $CMD run nav:generate "$@"
    ;;
esac

# Escape hatch: bazel run //docs-site:npm -- <any npm args>. The leading word was read as
# SUBCMD above, so replay the vector exactly as it arrived.
if [[ ${#NPM_ARGS[@]} -gt 0 ]]; then
  exec $CMD "${NPM_ARGS[@]}"
fi

echo "docs-site npm runner. Common:"
echo "  bazelisk run //docs-site:install"
echo "  bazelisk run //docs-site:dev"
echo "  bazelisk run //docs-site:build"
echo "  bazelisk run //docs-site:typecheck"
echo "  bazelisk run //docs-site:unit"
echo ""
echo "Pass extra flags after -- , e.g. bazelisk run //docs-site:build -- --debug"
exit 1
