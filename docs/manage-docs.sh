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
  # `bazel run` executes from bazel-out; build and serve the real checkout so node_modules
  # and the export land where a developer can see and commit them.
  REPO_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
  SCRIPT_DIR="${REPO_ROOT}/docs"
else
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
fi
SITE_DIR="$REPO_ROOT/docs-site"
DEFAULT_PORT=3005
PORT=${PORT:-$DEFAULT_PORT}
AUTO_OPEN_BROWSER=true

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

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
    error "Node.js 22+ and npm are required for the documentation site."
    error "In the devcontainer they are preinstalled; on a host: brew install node@22."
    exit 1
  fi

  # process.versions.node is "22.14.0" with no "v" prefix: take the first dotted part.
  local node_major
  node_major="$(node -p 'Number.parseInt(process.versions.node.split(".")[0], 10)' 2>/dev/null || echo 0)"
  if [[ ! ${node_major:-0} =~ ^[0-9]+$ ]] || [[ ${node_major:-0} -lt 20 ]]; then
    error "Node ${node:-unknown} is too old for Next 16 (need 20+, 22 recommended)."
    exit 1
  fi

  if [[ ! -x "$SITE_DIR/node_modules/.bin/next" ]]; then
    info "Installing documentation site dependencies (npm ci)"
    (cd "$SITE_DIR" && npm ci --legacy-peer-deps) || {
      error "npm ci failed in docs-site/"
      exit 1
    }
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
    error "docs-site/source.config.ts not found - the docs app is incomplete."
    exit 1
  fi
  if [[ ! -f "$SITE_DIR/lib/nav.json" ]]; then
    error "docs-site/lib/nav.json is missing - run: npm run nav:generate in docs-site/"
    exit 1
  fi
}

# @function open_browser
# Open the dev server, when a browser opener exists and auto-open is on.
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
    if command -v python3 &>/dev/null; then
      python3 -m webbrowser "$url" 2>/dev/null || true
    elif [[ $OSTYPE == "darwin"* ]]; then
      open "$url" 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$url" 2>/dev/null || true
    fi
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
          error "Unknown option for serve: $1"
          exit 1
          ;;
      esac
    done

    docs_node_is_ready
    check_content
    info "Starting the Fumadocs dev server on port ${PORT}..."
    open_browser
    # The dev server must be reached over localhost: Next rejects cross-origin dev
    # resources requested via 127.0.0.1, which breaks hydration.
    (cd "$SITE_DIR" && exec npm run dev -- --port "$PORT" --hostname localhost)
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
          error "Unknown option for build: $1"
          exit 1
          ;;
      esac
    done

    docs_node_is_ready
    check_content
    if [[ $ALIAS == "latest" ]]; then
      info "Building the documentation site as the latest alias (basePath set)..."
      (cd "$SITE_DIR" && npm run build:latest)
    elif [[ -n $ALIAS ]]; then
      info "Building the documentation site as ${ALIAS} (basePath set)..."
      (cd "$SITE_DIR" && DOCS_ALIAS="$ALIAS" npm run build)
    else
      info "Building the documentation site (no basePath, for preview and the gates)..."
      (cd "$SITE_DIR" && npm run build)
    fi
    success "Build complete. Output is in docs-site/out/"
    ;;

  preview)
    docs_node_is_ready
    check_content
    info "Building production preview..."
    (cd "$SITE_DIR" && npm run build)
    success "Serving the static export from docs-site/out/ on port ${PORT}..."
    # scripts/serve_static.mjs takes positional [port] [root].
    (cd "$SITE_DIR" && npm run serve -- "$PORT" out)
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
    echo "=== Documentation Status ==="
    echo "Content root:          $([[ -d $REPO_ROOT/docs ]] && echo 'docs/' || echo 'MISSING')"
    echo "Navigation tree:       $([[ -f $SITE_DIR/lib/nav.json ]] && echo 'docs-site/lib/nav.json' || echo 'MISSING (npm run nav:generate)')"
    echo "source.config.ts:      $([[ -f $SITE_DIR/source.config.ts ]] && echo 'present' || echo 'MISSING')"
    if [[ -x "$SITE_DIR/node_modules/.bin/next" ]]; then
      echo "Dependencies:          installed ($(node -p "require('$SITE_DIR/node_modules/next/package.json').version" 2>/dev/null || echo '?'))"
    else
      echo "Dependencies:          not installed (cd docs-site && npm ci --legacy-peer-deps)"
    fi
    if command -v node >/dev/null 2>&1; then
      echo "Node:                  $(node --version 2>/dev/null || echo 'not in PATH')"
    else
      echo "Node:                  not in PATH"
    fi
    echo "Static export:         $([[ -f $SITE_DIR/out/index.html ]] && echo 'docs-site/out/' || echo 'not built (npm run build)')"
    echo "Default port:          $DEFAULT_PORT"
    ;;

  clean)
    info "Cleaning build artifacts..."
    rm -rf "$SITE_DIR/out" "$SITE_DIR/.next" "$SITE_DIR/.source"
    success "Clean complete."
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
