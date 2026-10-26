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

ensure_deps() {
  if [[ ! -x "node_modules/.bin/next" || ! -x "node_modules/.bin/vitest" ]]; then
    echo "→ docs-site: installing npm deps (node_modules missing)"
    npm ci --legacy-peer-deps
  fi
}

CMD="npm"

case "$SUBCMD" in
  install)
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
