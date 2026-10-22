#!/usr/bin/env bash
#
# ## setup-host.sh — one-time host bootstrap: Bazelisk + the lint toolchain.
#
# The only script in this repo meant to run straight from a shell, and it has to:
# Bazel is the ingress for everything else, and a fresh host has no Bazel until this
# runs. CI does the same job on a clean runner through
# .github/scripts/install-lint-tools.sh, which is apt-and-cURL shaped and runs with
# sudo — this is the laptop and stack-host version of that step.
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
# Usage (both forms work from any directory):
#   bash scripts/setup-host.sh          # repair leftovers, then install what is missing
#   bash scripts/setup-host.sh --check  # report tools, leftovers and DNS; write nothing
#   bash scripts/setup-host.sh --repair # repair leftovers only
#
# Options:
#   --check       probe only: print the report and exit 0, writing nothing
#   --repair      repair leftover runfiles (uses sudo when chmod is not enough)
#   -h, --help    print this help and exit 0
#
# Exit codes: 0 when every tool is present, for --check, and for a completed
# --repair; 1 when an install was asked for and something stayed missing, or
# when --repair could not take ownership of a leftover path.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/host_state.sh disable=SC1091
source "${SELF_DIR}/lib/host_state.sh"

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
buildifier, terraform — install the ones that are missing, and repair leftover
Docker bind-mounts in Bazel's runfiles tree that make `bazelisk run` fail with
Permission denied on homepage/assets/icons/evo-t1.svg.

  --check     report tools, leftovers and DNS; write nothing
  --repair    repair leftovers only (uses sudo when chmod is not enough)
  -h, --help  this help

  bash scripts/setup-host.sh          # repair, then install what is missing
  bash scripts/setup-host.sh --check  # what is missing or leftover right now
  bash scripts/setup-host.sh --repair # the recovery when bazelisk run cannot start
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
  host_dns_report /etc/resolv.conf github.com || true
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
repair_stale_runfiles "${SETUP_ROOT}" "${use_sudo}" || {
  echo "setup-host: leftover runfiles could not all be repaired (see warnings above)" >&2
  if [ "${repair_only}" = "1" ]; then
    exit 1
  fi
}

if [ "${repair_only}" = "1" ]; then
  echo "setup-host: runfiles repair finished."
  exit 0
fi

if [ "${#missing[@]}" -eq 0 ]; then
  echo "setup-host: every tool the Bazel targets need is on PATH."
  exit 0
fi

# Homebrew carries all five as core formulae, so the macOS branch names no version:
# brew picks the same shfmt and buildifier the CI action downloads by hand.
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
  # The Linux branch mirrors CI's installer: shellcheck from apt, shfmt and
  # buildifier from the same two GitHub releases, bazelisk from its own release.
  # Terraform is the one this will not guess at: its apt repository has to be
  # added first, so the operator is told rather than handed a wrong URL.
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
  arch="$(uname -m)"
  case "${arch}" in
    x86_64 | amd64) goarch=amd64 ;;
    aarch64 | arm64) goarch=arm64 ;;
    *) goarch="" ;;
  esac
  tmp="$(mktemp -d 2>/dev/null || true)"
  if [ -z "${tmp}" ]; then
    tmp=""
  fi
  if [ -n "${tmp}" ] && [ -n "${goarch}" ] && command -v curl >/dev/null 2>&1; then
    for tool in "${missing[@]}"; do
      case "${tool}" in
        bazelisk)
          url="https://github.com/bazelbuild/bazelisk/releases/download/v1.29.0/bazelisk-linux-${goarch}"
          ;;
        shfmt)
          url="https://github.com/mvdan/sh/releases/download/v3.11.0/shfmt_v3.11.0_linux_${goarch}"
          ;;
        buildifier)
          url="https://github.com/bazelbuild/buildtools/releases/download/v8.2.0/buildifier-linux-${goarch}"
          ;;
        *)
          echo "  ${tool}: nothing to fetch here — Terraform needs the HashiCorp apt" \
            "repository (or https://releases.hashicorp.com/terraform), then re-run this." >&2
          continue
          ;;
      esac
      echo "  fetching ${tool} from ${url}"
      if curl -fsSL "${url}" -o "${tmp}/${tool}" && [ -s "${tmp}/${tool}" ]; then
        chmod 755 "${tmp}/${tool}"
        if [ -n "${sudo_cmd}" ]; then
          sudo install -m 0755 "${tmp}/${tool}" "${bin_dir}/${tool}" ||
            echo "  ${tool}: fetched, but ${bin_dir} is not writable even with sudo" >&2
        else
          install -m 0755 "${tmp}/${tool}" "${bin_dir}/${tool}" ||
            echo "  ${tool}: fetched, but ${bin_dir} is not writable here" >&2
        fi
      else
        echo "  ${tool}: nothing was fetched (no network, or no curl)" >&2
      fi
    done
  else
    echo "  no curl, or an unsupported arch (${arch}): install the tools above by hand" >&2
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
