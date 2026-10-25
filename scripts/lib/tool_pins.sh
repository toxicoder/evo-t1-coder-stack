# shellcheck shell=bash
#
# ## tool_pins.sh — golden-image pin reader (sourced; never executed)
#
# images/dev/tool-versions.env is the single source of truth for toolchain
# versions. The Dockerfile takes every KEY as an ARG; setup-host.sh and the CI
# lint installer fetch the same four host tools (bazelisk, shfmt, buildifier,
# terraform) from the URLs this file builds, so a pin bump cannot leave CI or
# a Linux workstation on a different release.
#
# Invariants:
#   - Sourcing this file changes no shell options, cwd, or environment.
#   - It never network-fetches; it only parses the pin file and prints paths
#     or URLs. Callers do the curl.
#   - Keys are [A-Z0-9_]+; values have no spaces or quotes (the pin-file
#     contract in images/dev/tool-versions.env).
#
# Usage (after the repo-root cd):
#   # shellcheck source=lib/tool_pins.sh disable=SC1091
#   source "scripts/lib/tool_pins.sh"
#   pins="$(tool_pins_file "${REPO_ROOT}")"
#   tool_pins_linux_url "${pins}" bazelisk amd64

# @function tool_pins_file
# Print the pin file path under a repository root.
# Globals:
#   None
# Arguments:
#   $1 - repository root
# Outputs:
#   Absolute or root-relative path to images/dev/tool-versions.env
# Returns:
#   0
tool_pins_file() {
  printf '%s/images/dev/tool-versions.env\n' "${1:?tool_pins_file: repo root required}"
}

# @function tool_pins_get
# Print the value of one KEY=value pin. The last assignment wins.
# Globals:
#   None
# Arguments:
#   $1 - path to the pin file
#   $2 - KEY (A-Z, digits, underscore)
# Outputs:
#   The value, with no surrounding quotes, on stdout
# Returns:
#   0 when the key is present; 1 when the file or key is missing
tool_pins_get() {
  local file="${1:-}" key="${2:-}" line=""
  case "${key}" in
    [A-Z]*) ;;
    *) return 1 ;;
  esac
  case "${key}" in
    *[!A-Z0-9_]*) return 1 ;;
  esac
  [ -f "${file}" ] || return 1
  line="$(grep -E "^${key}=" "${file}" | tail -n 1)" || true
  [ -n "${line}" ] || return 1
  printf '%s\n' "${line#*=}"
}

# @function tool_pins_goarch
# Map a uname -m (or GOARCH) spelling to the amd64/arm64 GitHub asset arch.
# Globals:
#   None
# Arguments:
#   $1 - optional machine name; defaults to $(uname -m)
# Outputs:
#   amd64 or arm64 on stdout
# Returns:
#   0 when the arch is known; 1 otherwise
tool_pins_goarch() {
  local machine="${1:-}"
  if [ -z "${machine}" ]; then
    machine="$(uname -m)"
  fi
  case "${machine}" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

# @function tool_pins_linux_url
# Print the Linux release-asset URL for one host tool, using the pin file.
# Globals:
#   None
# Arguments:
#   $1 - path to the pin file
#   $2 - tool: bazelisk, shfmt, buildifier, or terraform
#   $3 - goarch from tool_pins_goarch (amd64 or arm64)
# Outputs:
#   One HTTPS URL on stdout
# Returns:
#   0 when the tool and pin exist; 1 otherwise
tool_pins_linux_url() {
  local file="${1:-}" tool="${2:-}" arch="${3:-}" ver=""
  case "${arch}" in
    amd64 | arm64) ;;
    *) return 1 ;;
  esac
  case "${tool}" in
    bazelisk)
      ver="$(tool_pins_get "${file}" BAZELISK_VERSION)" || return 1
      printf 'https://github.com/bazelbuild/bazelisk/releases/download/%s/bazelisk-linux-%s\n' \
        "${ver}" "${arch}"
      ;;
    shfmt)
      ver="$(tool_pins_get "${file}" SHFMT_ASSET_VERSION)" || return 1
      printf 'https://github.com/mvdan/sh/releases/download/v%s/shfmt_v%s_linux_%s\n' \
        "${ver}" "${ver}" "${arch}"
      ;;
    buildifier)
      ver="$(tool_pins_get "${file}" BUILDIFIER_VERSION)" || return 1
      printf 'https://github.com/bazelbuild/buildtools/releases/download/%s/buildifier-linux-%s\n' \
        "${ver}" "${arch}"
      ;;
    terraform)
      ver="$(tool_pins_get "${file}" TERRAFORM_VERSION)" || return 1
      printf 'https://releases.hashicorp.com/terraform/%s/terraform_%s_linux_%s.zip\n' \
        "${ver}" "${ver}" "${arch}"
      ;;
    *)
      return 1
      ;;
  esac
}
