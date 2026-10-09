#!/usr/bin/env bash
# Install shellcheck, shfmt, and buildifier when they are missing.
# The shellcheck package is expected from apt on GitHub runners. shfmt and buildifier are
# fetched only when LINT_BINS_CACHE_HIT is not true.
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y shellcheck
fi

if [[ ${LINT_BINS_CACHE_HIT:-} == "true" ]] && command -v shfmt >/dev/null 2>&1 && command -v buildifier >/dev/null 2>&1; then
  exit 0
fi

arch="$(uname -m)"
case "${arch}" in
  x86_64 | amd64) goarch=amd64 ;;
  aarch64 | arm64) goarch=arm64 ;;
  *)
    echo "unsupported arch: ${arch}" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl -fsSL "https://github.com/mvdan/sh/releases/download/v3.11.0/shfmt_v3.11.0_linux_${goarch}" \
  -o "${tmp}/shfmt"
curl -fsSL "https://github.com/bazelbuild/buildtools/releases/download/v8.2.0/buildifier-linux-${goarch}" \
  -o "${tmp}/buildifier"
sudo install -m 0755 "${tmp}/shfmt" /usr/local/bin/shfmt
sudo install -m 0755 "${tmp}/buildifier" /usr/local/bin/buildifier
shfmt --version
buildifier --version
