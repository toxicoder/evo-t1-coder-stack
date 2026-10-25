#!/usr/bin/env bash
#
# ## setup-host.sh — one-time host bootstrap: Bazelisk + the lint toolchain.
#
# The only script in this repo meant to run straight from a shell, and only on
# the stack host: Bazel is the ingress for everything else, and a fresh host has
# no Bazel until this runs. A laptop uses the contributor dev container (or
# bazelisk run //scripts:test-in-image) instead. CI docker-runs the same golden
# image (images/dev/Dockerfile) and does not call this script.
#
# On Linux the releases this fetches — bazelisk, shfmt, buildifier, terraform — come
# from images/dev/tool-versions.env through scripts/lib/tool_pins.sh, the same pins
# the golden dev image builds from, so bumping a pin there moves the image, CI and a
# workstation together and cannot leave this script on an older release. Terraform's
# asset is a zip; this extracts the terraform member rather than installing the
# archive. Darwin keeps the convenience path: unpinned Homebrew formulae.
#
# What it probes for is the five binaries the Bazel targets shell out to:
#
# - bazelisk: every entry point (`bazelisk test|run …`); without it nothing runs
# - shellcheck: //:lint lints:shell, and //:fix
# - shfmt: //:lint lints:shfmt, and //:fix
# - buildifier: //:lint lints:buildifier, and //:fix
# - terraform: //:validate runs `terraform fmt -check` in both templates
#
# The three linters are what makes the lint gate mean anything: lints/check_tool.sh
# skips a linter that is not on PATH (and //:fix skips it too), so on a host that
# never ran this script `bazelisk test //:lint` goes green having checked nothing.
# That is the hole this closes.
#
# It also repairs leftover Docker bind-mounts in Bazel's runfiles tree. An older
# `bazelisk run` used the runfiles copy of docker-compose.yml, so compose mounted
# homepage/assets/icons from bazel-out; the homepage container then chowned those
# files (or Docker created a directory where evo-t1.svg belongs). The next
# `bazelisk run //scripts:prod-stack` dies creating the runfiles tree with
# Permission denied. --repair is the recovery that does not need Bazel to start.
#
# On Linux, default and --repair also install public DNS (1.1.1.1 / 8.8.8.8)
# beside Tailscale MagicDNS so `git pull` still resolves github.com when Docker
# or Kasm has made 100.100.100.100 unreachable: a systemd-resolved drop-in plus
# `tailscale set --accept-dns=false`, with MagicDNS kept for ts.net. --check
# still writes nothing. Darwin is a no-op for that step.
#
# Usage (both forms work from any directory):
#   bash scripts/setup-host.sh          # repair leftovers and DNS, then install
#   bash scripts/setup-host.sh --check  # report tools, leftovers and DNS; write nothing
#   bash scripts/setup-host.sh --repair # repair leftovers and Linux public DNS
#
# Options:
#   --check       probe only: print the report and exit 0, writing nothing
#   --repair      repair leftover runfiles and Linux public DNS (uses sudo
#                 when chmod / /etc is not writable)
#   -h, --help    print this help and exit 0
#
# Exit codes: 0 when every tool is present, for --check, and for a completed
# --repair; 1 when an install was asked for and something stayed missing, when
# --repair could not take ownership of a leftover path, or when github.com
# still does not resolve after the DNS repair.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/host_state.sh disable=SC1091
source "${SELF_DIR}/lib/host_state.sh"
# shellcheck source=lib/tool_pins.sh disable=SC1091
source "${SELF_DIR}/lib/tool_pins.sh"

REQUIRED_TOOLS=(bazelisk shellcheck shfmt buildifier terraform)

check_only=0
repair_only=0

for arg in "$@"; do
  case "${arg}" in
    --check)
      check_only=1
      ;;
    --repair)
      repair_only=1
      ;;
    -h | --help)
      cat <<'HELP'
usage: bash scripts/setup-host.sh [--check] [--repair]

Probe the host tools the Bazel targets need — bazelisk, shellcheck, shfmt,
buildifier, terraform — install the ones that are missing, repair leftover
Docker bind-mounts in Bazel's runfiles tree that make `bazelisk run` fail with
Permission denied on homepage/assets/icons/evo-t1.svg, and on Linux install
public DNS (1.1.1.1 / 8.8.8.8) so github.com still resolves when Tailscale
MagicDNS is the only nameserver.

  --check     report tools, leftovers and DNS; write nothing
  --repair    repair leftovers and Linux public DNS (uses sudo when chmod
              or /etc is not enough)
  -h, --help  this help

  bash scripts/setup-host.sh          # repair, then install what is missing
  bash scripts/setup-host.sh --check  # what is missing or leftover right now
  bash scripts/setup-host.sh --repair # runfiles + public DNS; no Bazel needed
HELP
      exit 0
      ;;
    *)
      printf 'error: setup-host: unknown argument %s (try --help)\n' "${arg}" >&2
      exit 1
      ;;
  esac
done

# The checkout this script lives in: repair looks at bazel-out beside it.
# SETUP_ROOT is overridable so the Bats suite can point it at a scratch tree.
SETUP_ROOT="${SETUP_ROOT:-$(cd "${SELF_DIR}/.." && pwd)}"

# One pass builds the report, so --check and the install run print the same lines.
present=()
missing=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "${tool}" >/dev/null 2>&1; then
    present+=("${tool}")
  else
    missing+=("${tool}")
  fi
done

if [ "${#present[@]}" -gt 0 ]; then
  printf 'present: %s\n' "${present[*]}"
fi
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'missing: %s\n' "${missing[*]}"
fi

if [ "${check_only}" = "1" ]; then
  report_stale_runfiles "${SETUP_ROOT}"
  host_dns_report "${SETUP_RESOLV_CONF:-/etc/resolv.conf}" github.com || true
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "note: --check installed nothing and wrote nothing."
    echo '  Run "bash scripts/setup-host.sh" (no flags) to install what is missing,'
    echo '  or run "bazelisk test //:lint --test_tag_filters=manual" knowing that a'
    echo "  linter which is not on PATH is SKIPPED, not passed: a lint gate with no"
    echo "  linter in it proves nothing."
  else
    echo "setup-host: every tool the Bazel targets need is on PATH."
  fi
  exit 0
fi

# Root needs no prefix; a normal user needs sudo. Neither means no install:
# Homebrew installs into its own prefix, which is user-writable on macOS.
sudo_cmd=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
  sudo_cmd="sudo"
fi

use_sudo=0
if [ -n "${sudo_cmd}" ]; then
  use_sudo=1
fi
runfiles_rc=0
repair_stale_runfiles "${SETUP_ROOT}" "${use_sudo}" || {
  echo "setup-host: leftover runfiles could not all be repaired (see warnings above)" >&2
  runfiles_rc=1
}

dns_rc=0
if ! ensure_host_public_dns \
  "${SETUP_RESOLV_CONF:-/etc/resolv.conf}" \
  "${SETUP_RESOLVED_DROPIN:-${RESOLVED_DROPIN_DEFAULT}}" \
  "${use_sudo}"; then
  echo "setup-host: host DNS still cannot resolve github.com (see warnings above)" >&2
  dns_rc=1
fi

if [ "${repair_only}" = "1" ]; then
  if [ "${runfiles_rc}" = "0" ]; then
    echo "setup-host: runfiles repair finished."
  fi
  if [ "${runfiles_rc}" != "0" ] || [ "${dns_rc}" != "0" ]; then
    exit 1
  fi
  exit 0
fi

if [ "${dns_rc}" != "0" ]; then
  exit 1
fi

if [ "${#missing[@]}" -eq 0 ]; then
  echo "setup-host: every tool the Bazel targets need is on PATH."
  exit 0
fi

# @function setup_host_tool_url
# Print the pinned Linux release URL for one host tool. The version comes from
# images/dev/tool-versions.env, never from this script.
# Globals:
#   None
# Arguments:
#   $1 - path to the pin file (from tool_pins_file)
#   $2 - tool to fetch: bazelisk, shfmt, buildifier, or terraform
#   $3 - goarch from tool_pins_goarch (amd64 or arm64)
# Outputs:
#   One HTTPS URL on stdout; terraform's ends in .zip and needs a member extract
# Returns:
#   0 when the tool and its pin resolve; 1 when they do not (unknown tool,
#   unknown arch, or a KEY missing from the pin file)
setup_host_tool_url() {
  tool_pins_linux_url "${1:-}" "${2:-}" "${3:-}"
}

# @function setup_host_extract_member
# Write one member of a release zip to a path, so the archive itself is never
# what gets installed as the tool.
# Globals:
#   None
# Arguments:
#   $1 - path to the downloaded zip
#   $2 - member name inside the zip (terraform)
#   $3 - path to write the extracted member to
# Outputs:
#   The extracted file at $3; nothing on stdout
# Returns:
#   0 when the member was extracted; 1 when no unzip/bsdtar is available or the
#   zip or member is missing
setup_host_extract_member() {
  local zip="${1:-}" member="${2:-}" dest="${3:-}" part=""
  [ -s "${zip}" ] || return 1
  [ -n "${member}" ] && [ -n "${dest}" ] || return 1
  part="${dest}.extracted"
  if command -v unzip >/dev/null 2>&1; then
    if ! unzip -p "${zip}" "${member}" >"${part}" 2>/dev/null; then
      rm -f "${part}"
      return 1
    fi
  elif command -v bsdtar >/dev/null 2>&1; then
    if ! bsdtar -xOf "${zip}" "${member}" >"${part}" 2>/dev/null; then
      rm -f "${part}"
      return 1
    fi
  else
    return 1
  fi
  if [ ! -s "${part}" ]; then
    rm -f "${part}"
    return 1
  fi
  mv "${part}" "${dest}"
}

# Homebrew carries all five as core formulae, so the macOS branch stays the
# convenience path: it names no version and pins nothing. The pinned Linux path
# below is what tracks images/dev/tool-versions.env.
if command -v brew >/dev/null 2>&1; then
  echo "installing with Homebrew (brew install) ..."
  for tool in "${missing[@]}"; do
    if brew install "${tool}" >/dev/null 2>&1; then
      echo "  installed ${tool}"
    else
      echo "  brew install ${tool} did not work — check that formula by hand" >&2
    fi
  done
elif command -v apt-get >/dev/null 2>&1; then
  # The Linux branch mirrors CI's installer: shellcheck from apt, and the other
  # four from the releases the golden image builds — bazelisk, shfmt and
  # buildifier are raw binaries, terraform arrives as a zip whose terraform
  # member is what gets installed. Every URL comes from the pin file; nothing
  # here names a version.
  echo "installing with apt-get and the upstream release binaries ..."
  apt=(apt-get)
  if [ -n "${sudo_cmd}" ]; then
    apt=(sudo apt-get)
  fi
  if [[ " ${missing[*]} " == *" shellcheck "* ]]; then
    "${apt[@]}" update >/dev/null 2>&1 || true
    "${apt[@]}" install -y shellcheck >/dev/null 2>&1 ||
      echo "  apt-get install shellcheck did not work — install it by hand" >&2
  fi
  bin_dir="/usr/local/bin"
  pins="$(tool_pins_file "${SETUP_ROOT}")"
  machine="$(uname -m)"
  goarch="$(tool_pins_goarch "${machine}")" || goarch=""
  tmp="$(mktemp -d 2>/dev/null || true)"
  if [ -z "${tmp}" ]; then
    tmp=""
  fi
  if [ -n "${tmp}" ] && [ -n "${goarch}" ] && command -v curl >/dev/null 2>&1; then
    for tool in "${missing[@]}"; do
      # apt owns shellcheck above; the four pinned releases are the fetch list.
      if [ "${tool}" = "shellcheck" ]; then
        continue
      fi
      if ! url="$(setup_host_tool_url "${pins}" "${tool}" "${goarch}")"; then
        echo "  ${tool}: no pinned Linux release in ${pins##*/} — install it by hand" >&2
        continue
      fi
      echo "  fetching ${tool} from ${url}"
      if ! curl -fsSL "${url}" -o "${tmp}/${tool}" || [ ! -s "${tmp}/${tool}" ]; then
        echo "  ${tool}: nothing was fetched (no network, or no curl)" >&2
        continue
      fi
      install_src="${tmp}/${tool}"
      if [ "${tool}" = "terraform" ]; then
        # The release is a zip: terraform is one member of it, so the archive
        # must never be what is installed under the tool's name.
        if ! setup_host_extract_member "${tmp}/${tool}" terraform "${tmp}/${tool}.bin"; then
          echo "  terraform: the zip was fetched but its member could not be unpacked —" \
            "install unzip (or unpack the release by hand) and re-run this" >&2
          continue
        fi
        install_src="${tmp}/${tool}.bin"
      fi
      chmod 755 "${install_src}"
      if [ -n "${sudo_cmd}" ]; then
        sudo install -m 0755 "${install_src}" "${bin_dir}/${tool}" ||
          echo "  ${tool}: fetched, but ${bin_dir} is not writable even with sudo" >&2
      else
        install -m 0755 "${install_src}" "${bin_dir}/${tool}" ||
          echo "  ${tool}: fetched, but ${bin_dir} is not writable here" >&2
      fi
    done
  else
    echo "  no curl, or an unsupported arch (${machine}): install the tools above by hand" >&2
  fi
  if [ -n "${tmp}" ]; then
    rm -rf "${tmp}"
  fi
else
  echo "error: no brew and no apt-get: install bazelisk, shellcheck, shfmt, buildifier" \
    "and terraform by hand, then re-run this script to check them" >&2
  exit 1
fi

# The re-probe is the point: a lint gate that skipped every linter is what this
# script exists to prevent, so say plainly what is still missing.
still_missing=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    still_missing+=("${tool}")
  fi
done

if [ "${#still_missing[@]}" -gt 0 ]; then
  printf 'setup-host: still missing: %s — //:lint will skip those checks instead of\n' \
    "${still_missing[*]}"
  echo "running them."
  exit 1
fi

echo "setup-host: every tool the Bazel targets need is on PATH."
