#!/usr/bin/env bash
#
# ## manage-docs
#
# Entry point for the Fumadocs documentation site: serve, build, preview, status, clean.
#
# The site is the Next.js app in docs-site/; docs/ holds only its markdown/MDX content.
# Deployment is CI-only (.github/workflows/deploy-docs.yml) — nothing here publishes.
#
# Usage:
#   bazelisk run //docs:serve
#   bazelisk run //docs:docs
#   bash docs/manage-docs.sh build --alias feat-foo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} ]]; then
  # `bazel run` executes from bazel-out. Why the build belongs in the real checkout is in
  # the preamble of docs-site/run_npm.sh.
  REPO_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
  SCRIPT_DIR="${REPO_ROOT}/docs"
else
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
fi
SITE_DIR="$REPO_ROOT/docs-site"
# shellcheck source=../scripts/lib/common.sh disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"
unset JSON_MODE
DEFAULT_PORT=3005
PORT=${PORT:-$DEFAULT_PORT}
AUTO_OPEN_BROWSER=true

# @function docs_node_is_ready
# Ensure Node and npm exist, are new enough for Next 16, and that deps are installed.
# Globals:
#   SITE_DIR
# Arguments:
#   None
# Outputs:
#   Progress or the failure reason on stdout/stderr
# Returns:
#   0 when the toolchain can build; exits the script when it cannot
docs_node_is_ready() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    err "Node.js 22+ and npm are required for the documentation site."
    die "In the devcontainer they are preinstalled; on a host: brew install node@22."
  fi

  # process.versions.node is "22.14.0" with no "v" prefix: take the first dotted part.
  # A non-numeric operand is read as a variable name, which `set -u` makes fatal, so a probe
  # that answers anything but a plain number counts as too old rather than aborting here.
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [[ ${node_major} =~ ^[0-9]+$ ]] || node_major=0
  if [[ ${node_major} -lt 22 ]]; then
    die "Node ${node_major} is too old for Next 16 (docs-site/package.json requires node >=22)."
  fi

  if [[ ! -x "$SITE_DIR/node_modules/.bin/next" ]]; then
    phase "Installing documentation site dependencies (npm ci)"
    (cd "$SITE_DIR" && npm ci --legacy-peer-deps) || die "npm ci failed in docs-site/"
  fi
}

# @function check_content
# Fail when the site package or the navigation tree is not where the build expects it.
# Globals:
#   SITE_DIR
# Arguments:
#   None
# Outputs:
#   The missing piece on stderr
# Returns:
#   0 when the package is complete
check_content() {
  if [[ ! -f "$SITE_DIR/source.config.ts" ]]; then
    die "docs-site/source.config.ts not found - the docs app is incomplete."
  fi
  if [[ ! -f "$SITE_DIR/lib/nav.json" ]]; then
    die "docs-site/lib/nav.json is missing - run: npm run nav:generate in docs-site/"
  fi
}

# @function open_browser
# Open the dev server when auto-open is on.
# Globals:
#   AUTO_OPEN_BROWSER, PORT
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
open_browser() {
  local url="http://127.0.0.1:${PORT}"
  if [[ $AUTO_OPEN_BROWSER == "true" ]]; then
    # python3's webbrowser module already picks the platform opener (open, xdg-open, ...).
    python3 -m webbrowser "$url" 2>/dev/null || true
  fi
}

case "${1:-help}" in
  serve)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --port)
          PORT="$2"
          shift 2
          ;;
        --no-browser)
          AUTO_OPEN_BROWSER=false
          shift
          ;;
        *)
          die "Unknown option for serve: $1"
          ;;
      esac
    done

    section "Serve"
    docs_node_is_ready
    check_content
    phase "Starting the Fumadocs dev server on port ${PORT}..."
    open_browser
    # The dev server must be reached over localhost: Next rejects cross-origin dev
    # resources requested via 127.0.0.1, which breaks hydration.
    (cd "$SITE_DIR" && exec npm run dev -- --port "$PORT" --hostname localhost)
    ok "Fumadocs dev server on port ${PORT} stopped"
    summary
    ;;

  build)
    shift
    ALIAS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --alias)
          ALIAS="$2"
          shift 2
          ;;
        *)
          die "Unknown option for build: $1"
          ;;
      esac
    done

    section "Build"
    docs_node_is_ready
    check_content
    if [[ $ALIAS == "latest" ]]; then
      phase "Building the documentation site as the latest alias (basePath set)..."
      (cd "$SITE_DIR" && npm run build:latest)
    elif [[ -n $ALIAS ]]; then
      phase "Building the documentation site as ${ALIAS} (basePath set)..."
      (cd "$SITE_DIR" && DOCS_ALIAS="$ALIAS" npm run build)
    else
      phase "Building the documentation site (no basePath, for preview and the gates)..."
      (cd "$SITE_DIR" && npm run build)
    fi
    ok "Build complete. Output is in docs-site/out/"
    summary
    ;;

  preview)
    section "Preview"
    docs_node_is_ready
    check_content
    phase "Building production preview..."
    (cd "$SITE_DIR" && npm run build)
    ok "Serving the static export from docs-site/out/ on port ${PORT}..."
    # scripts/serve_static.mjs takes positional [port] [root].
    (cd "$SITE_DIR" && npm run serve -- "$PORT" out)
    summary
    ;;

  verify)
    shift
    docs_node_is_ready
    (cd "$SITE_DIR" && npm run verify -- "$@")
    ;;

  typecheck)
    shift
    docs_node_is_ready
    (cd "$SITE_DIR" && npm run typecheck "$@")
    ;;

  test)
    shift
    docs_node_is_ready
    (cd "$SITE_DIR" && npm run unit -- "$@")
    ;;

  nav)
    shift
    (cd "$SITE_DIR" && npm run nav:generate -- "$@")
    ;;

  status)
    section "Documentation status"
    log "Content root:          $([[ -d $REPO_ROOT/docs ]] && echo 'docs/' || echo 'MISSING')"
    log "Navigation tree:       $([[ -f $SITE_DIR/lib/nav.json ]] && echo 'docs-site/lib/nav.json' || echo 'MISSING (npm run nav:generate)')"
    log "source.config.ts:      $([[ -f $SITE_DIR/source.config.ts ]] && echo 'present' || echo 'MISSING')"
    if [[ -x "$SITE_DIR/node_modules/.bin/next" ]]; then
      log "Dependencies:          installed ($(node -p "require('$SITE_DIR/node_modules/next/package.json').version" 2>/dev/null || echo '?'))"
    else
      log "Dependencies:          not installed (cd docs-site && npm ci --legacy-peer-deps)"
    fi
    if command -v node >/dev/null 2>&1; then
      log "Node:                  $(node --version 2>/dev/null || echo 'not in PATH')"
    else
      log "Node:                  not in PATH"
    fi
    log "Static export:         $([[ -f $SITE_DIR/out/index.html ]] && echo 'docs-site/out/' || echo 'not built (npm run build)')"
    log "Default port:          $DEFAULT_PORT"
    ;;

  clean)
    section "Clean"
    phase "Cleaning build artifacts..."
    rm -rf "$SITE_DIR/out" "$SITE_DIR/.next" "$SITE_DIR/.source"
    ok "Clean complete."
    summary
    ;;

  help | *)
    cat <<'EOF'
Usage: manage-docs.sh {serve|build|preview|verify|typecheck|test|nav|status|clean} [options]

Commands:
  serve          Start the Next dev server with hot reload
                 Options: --port 3005   Set custom port
                          --no-browser  Do not auto-open a browser
  build          Build the static export into docs-site/out/
                 Options: --alias NAME  Build as that published alias (basePath set)
  preview        Build + serve the static export (final check before commit)
  verify         Check an export for missing pages, unprefixed assets, leaked .md links
  typecheck      next typegen + tsc --noEmit
  test           Run the Vitest unit suite
  nav            Regenerate docs-site/lib/nav.json from scripts/gen_nav.py
  status         Show the state of the docs toolchain
  clean          Remove docs-site/out, .next and .source
EOF
    ;;
esac
