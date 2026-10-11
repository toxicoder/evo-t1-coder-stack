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
# Usage (both forms work from any directory):
#   bash scripts/setup-host.sh          # install what is missing
#   bash scripts/setup-host.sh --check  # report what is missing, install nothing
#
# Options:
#   --check       probe only: print one line per tool and exit 0, writing nothing
#   -h, --help    print this help and exit 0
#
# Exit codes: 0 when every tool is present, and for --check whatever is missing;
# 1 when an install was asked for and something stayed missing (no package
# manager, no network, or a package this host's repositories do not carry).

set -euo pipefail

REQUIRED_TOOLS=(bazelisk shellcheck shfmt buildifier terraform)

check_only=0

for arg in "$@"; do
  case "${arg}" in
    --check)
      check_only=1
      ;;
    -h | --help)
      cat <<'HELP'
usage: bash scripts/setup-host.sh [--check]

Probe the host tools the Bazel targets need — bazelisk, shellcheck, shfmt,
buildifier, terraform — and install the ones that are missing.

  --check     report what is missing and stop: installs nothing, writes nothing
  -h, --help  this help

  bash scripts/setup-host.sh          # first bootstrap on a fresh host
  bash scripts/setup-host.sh --check  # what is missing right now
HELP
      exit 0
      ;;
    *)
      printf 'error: setup-host: unknown argument %s (try --help)\n' "${arg}" >&2
      exit 1
      ;;
  esac
done

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

if [ "${#missing[@]}" -eq 0 ]; then
  echo "setup-host: every tool the Bazel targets need is on PATH."
  exit 0
fi

printf 'missing: %s\n' "${missing[*]}"

if [ "${check_only}" = "1" ]; then
  echo "note: --check installed nothing and wrote nothing."
  echo '  Run "bash scripts/setup-host.sh" (no flags) to install what is missing,'
  echo '  or run "bazelisk test //:lint --test_tag_filters=manual" knowing that a'
  echo "  linter which is not on PATH is SKIPPED, not passed: a lint gate with no"
  echo "  linter in it proves nothing."
  exit 0
fi

# Root needs no prefix; a normal user needs sudo. Neither means no install:
# Homebrew installs into its own prefix, which is user-writable on macOS.
sudo_cmd=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
  sudo_cmd="sudo"
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
