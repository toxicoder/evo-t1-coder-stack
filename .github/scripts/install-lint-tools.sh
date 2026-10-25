#!/usr/bin/env bash
#
# ## install-lint-tools — CI host tools, pinned by the golden image
#
# Install shellcheck, shfmt, buildifier, and terraform when a GitHub runner
# lacks them. Every version comes from images/dev/tool-versions.env — the same
# pin file the golden dev image (images/dev/Dockerfile) consumes — read through
# scripts/lib/tool_pins.sh, so a pin bump moves the image and the CI tools
# together and nothing in this file carries a version literal.
#
# The shellcheck package is expected from apt on GitHub runners. shfmt,
# buildifier, and terraform are fetched only when LINT_BINS_CACHE_HIT is not
# true, so the runner cache keeps the fetch off the hot path.
#
# LINT_TOOLS_BIN_DIR overrides the install directory (/usr/local/bin); the
# Bats suite points it at a scratch dir to stay sudo-free.
#
# Usage:
#   bash .github/scripts/install-lint-tools.sh
set -euo pipefail

# @function lint_tools_root
# Print the repository root: this script sits two levels down in .github/scripts/.
# Globals:
#   None
# Arguments:
#   $1 - directory holding this script
# Outputs:
#   Absolute repository root on stdout
# Returns:
#   0 when the pin file hangs off that root; 1 otherwise (a moved script, not a
#   missing pin — the caller reports it)
lint_tools_root() {
  local dir="${1:?lint_tools_root: script directory required}"
  local root
  root="$(cd "${dir}/../.." && pwd)"
  [ -f "${root}/images/dev/tool-versions.env" ] || return 1
  printf '%s\n' "${root}"
}

# @function lint_tools_fetch_pinned
# Download one pinned Linux release asset (a raw binary) and install it.
# Globals:
#   LINT_TOOLS_BIN_DIR - install directory, default /usr/local/bin
# Arguments:
#   $1 - pin file path (from tool_pins_file)
#   $2 - goarch from tool_pins_goarch (amd64 or arm64)
#   $3 - scratch directory to download into
#   $4 - tool name whose asset is a raw binary: shfmt or buildifier
# Outputs:
#   Nothing on success; the failing URL or missing pin on stderr
# Returns:
#   0 when the binary is installed; 1 when the pin, the download, or the
#   installed file is unusable
lint_tools_fetch_pinned() {
  local pins="${1:-}" arch="${2:-}" tmp="${3:-}" tool="${4:-}" url="" dest=""
  url="$(tool_pins_linux_url "${pins}" "${tool}" "${arch}")" || {
    echo "install-lint-tools: no ${tool} pin in ${pins}" >&2
    return 1
  }
  dest="${tmp}/${tool}"
  curl -fsSL "${url}" -o "${dest}"
  if [ ! -s "${dest}" ]; then
    echo "install-lint-tools: ${url} downloaded nothing" >&2
    return 1
  fi
  sudo install -m 0755 "${dest}" "${LINT_TOOLS_BIN_DIR:-/usr/local/bin}/${tool}"
}

# @function lint_tools_fetch_terraform
# Download the pinned terraform release zip, unpack the terraform member, and
# install that binary. The archive itself is never installed as an executable.
# Globals:
#   LINT_TOOLS_BIN_DIR - install directory, default /usr/local/bin
# Arguments:
#   $1 - pin file path (from tool_pins_file)
#   $2 - goarch from tool_pins_goarch (amd64 or arm64)
#   $3 - scratch directory to download and unpack into
# Outputs:
#   Nothing on success; the failing URL or missing pin on stderr
# Returns:
#   0 when the terraform binary is installed; 1 when the pin, the download, or
#   the unpacked member is unusable
lint_tools_fetch_terraform() {
  local pins="${1:-}" arch="${2:-}" tmp="${3:-}" url="" zip="" bin=""
  url="$(tool_pins_linux_url "${pins}" terraform "${arch}")" || {
    echo "install-lint-tools: no terraform pin in ${pins}" >&2
    return 1
  }
  zip="${tmp}/terraform.zip"
  curl -fsSL "${url}" -o "${zip}"
  if [ ! -s "${zip}" ]; then
    echo "install-lint-tools: ${url} downloaded nothing" >&2
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y unzip
  fi
  bin="${tmp}/terraform"
  unzip -j -o -q "${zip}" terraform -d "${tmp}"
  if [ ! -s "${bin}" ]; then
    echo "install-lint-tools: ${zip} produced no terraform member" >&2
    return 1
  fi
  chmod 0755 "${bin}"
  sudo install -m 0755 "${bin}" "${LINT_TOOLS_BIN_DIR:-/usr/local/bin}/terraform"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(lint_tools_root "${SCRIPT_DIR}")" || {
  echo "install-lint-tools: no images/dev/tool-versions.env two levels above ${SCRIPT_DIR}" >&2
  exit 1
}
# shellcheck source=../../scripts/lib/tool_pins.sh disable=SC1091
source "${ROOT}/scripts/lib/tool_pins.sh"
PINS="$(tool_pins_file "${ROOT}")"

if ! command -v shellcheck >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y shellcheck
fi

if [[ ${LINT_BINS_CACHE_HIT:-} == "true" ]] && command -v shfmt >/dev/null 2>&1 && command -v buildifier >/dev/null 2>&1; then
  exit 0
fi

arch="$(tool_pins_goarch)" || {
  echo "install-lint-tools: unsupported arch: $(uname -m)" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

lint_tools_fetch_pinned "${PINS}" "${arch}" "${tmp}" shfmt
lint_tools_fetch_pinned "${PINS}" "${arch}" "${tmp}" buildifier

if ! command -v terraform >/dev/null 2>&1; then
  lint_tools_fetch_terraform "${PINS}" "${arch}" "${tmp}"
  terraform version
fi

shfmt --version
buildifier --version
