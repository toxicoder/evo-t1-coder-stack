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
# does not resolve reliably through the runfiles sandbox.
if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} && -d "${BUILD_WORKSPACE_DIRECTORY}/docs-site" ]]; then
  cd "${BUILD_WORKSPACE_DIRECTORY}/docs-site"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$SCRIPT_DIR"
fi

# Map the bazel target name (via $0) to an npm script; sh_test passes the subcommand as $1.
TARGET_NAME="$(basename "${0:-npm}")"
SUBCMD="$TARGET_NAME"
if [[ $SUBCMD == "run_npm.sh" || $SUBCMD == "npm" ]] && [[ $# -gt 0 ]]; then
  SUBCMD="$1"
  shift
fi

# bazel run //docs-site:build invokes "build build" — drop the duplicated subcommand arg.
if [[ $# -gt 0 && $1 == "$SUBCMD" ]]; then
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
    # Dev resources are served cross-origin when addressed by IP, which Next rejects.
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
    # scripts/serve_static.mjs takes positional [port] [root].
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
  nav-check)
    ensure_deps
    exec $CMD run nav:check "$@"
    ;;
esac

# Fallback / generic escape hatch: bazel run //docs-site:npm -- <any npm args>
if [[ $# -gt 0 ]]; then
  exec $CMD "$@"
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
