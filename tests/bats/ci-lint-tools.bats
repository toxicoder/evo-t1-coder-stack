#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ci-lint-tools.bats — CI host tools must follow the golden-image pins
#
# .github/actions/setup-bazel and .github/scripts/install-lint-tools.sh install
# the same host tools (bazelisk, shfmt, buildifier, terraform) that the golden
# dev image builds. CI itself docker-runs that image; these files stay the
# host-side pin readers. These tests keep them reading images/dev/tool-versions.env
# through scripts/lib/tool_pins.sh instead of carrying version literals, and
# prove the asset each helper fetches is the asset the pin file names.
#
# Usage: bazelisk test //tests:bats_ci_lint_tools_test   (from any cwd)
# Safety: hermetic. curl is the repo stub and sudo/unzip are written per-test;
# no network, no sudo, no apt-get, nothing written outside BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
LINT_TOOLS=""
ACTION_YML=""
PINS=""
BIN_DIR=""

# Versions that used to be hardcoded in the CI installers. The installer and the
# action must name none of them; the pin file owns the value.
STALE_PIN_LITERALS=(
  'v3.11.0'
  'shfmt_v3.11.0'
  'v8.2.0'
  'bazelisk/releases/download/v1.25.0'
)

# ci_checkout_root — print the checkout root that holds the CI installers.
# Bazel hands the suite a runfiles tree whose .github/** is not declared, so the
# runfiles symlink is resolved to the real checkout first; then the runner's
# REPO_ROOT, then the usual ancestor walk for a bare `bats` run.
ci_checkout_root() {
  local candidate real dir
  for candidate in "${TEST_SRCDIR:-}/_main" "${REPO_ROOT:-}" "$(bats_canonical_repo_root || true)"; do
    if [ -n "${candidate}" ] && [ -f "${candidate}/docker-compose.yml" ]; then
      real="$(readlink -f "${candidate}/docker-compose.yml" 2>/dev/null ||
        realpath "${candidate}/docker-compose.yml" 2>/dev/null ||
        printf '%s' "${candidate}/docker-compose.yml")"
      dir="$(cd "$(dirname "${real}")" && pwd)"
      if [ -f "${dir}/.github/scripts/install-lint-tools.sh" ]; then
        printf '%s' "${dir}"
        return 0
      fi
    fi
  done
  dir="$(cd "${BATS_TEST_DIRNAME}" && pwd)"
  while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
    if [ -f "${dir}/.github/scripts/install-lint-tools.sh" ]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

# shellcheck source=/dev/null
source_tool_pins() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/tool_pins.sh"
}

# ci_refute_contains <label> <file> <literal> — fail when <file> carries <literal>.
ci_refute_contains() {
  if grep -qF -- "$3" "$2"; then
    printf 'FAIL: %s still hardcodes %s\n' "$1" "$3" >&2
    return 1
  fi
}

# ci_stub_bin <name...> — write per-test sudo/unzip stubs and print their bin dir.
# sudo logs then execs, so the real install(1) still runs against a scratch
# target; unzip logs argv and materialises the member it was asked to extract.
ci_stub_bin() {
  local name bin="${BATS_TEST_TMPDIR}/ci-bin"
  mkdir -p "${bin}"
  for name in "$@"; do
    case "${name}" in
      sudo)
        printf '%s\n' \
          '#!/usr/bin/env bash' \
          'set -u' \
          'printf "sudo %s\n" "$*" >>"${STUB_LOG:?}/sudo.log"' \
          'exec "$@"' \
          >"${bin}/sudo"
        ;;
      unzip)
        printf '%s\n' \
          '#!/usr/bin/env bash' \
          'set -u' \
          'printf "unzip %s\n" "$*" >>"${STUB_LOG:?}/unzip.log"' \
          'zip="" member="" dir="" prev=""' \
          'for a in "$@"; do' \
          '  if [ "${prev}" = "-d" ]; then dir="${a}"; prev=""; continue; fi' \
          '  case "${a}" in' \
          "    -*) prev=\"\${a}\" ;;" \
          '    *) if [ -z "${zip}" ]; then zip="${a}"; else member="${a}"; fi ;;' \
          '  esac' \
          'done' \
          'if [ -n "${dir}" ] && [ -n "${member}" ]; then' \
          '  printf "unpacked-terraform-binary\n" >"${dir}/${member}"' \
          'fi' \
          >"${bin}/unzip"
        ;;
      *)
        printf 'FAIL: ci_stub_bin: no stub recipe for %s\n' "${name}" >&2
        return 1
        ;;
    esac
    chmod 0755 "${bin}/${name}"
  done
  printf '%s' "${bin}"
}

# ci_use_fetch_stubs <name...> — curl repo stub plus the local recipes on PATH.
ci_use_fetch_stubs() {
  local bin
  use_stubs curl
  bin="$(ci_stub_bin "$@")" || return 1
  chmod 755 "${bin}"
  PATH="${bin}:${PATH}"
  export PATH
}

setup() {
  REPO_ROOT="$(ci_checkout_root)" ||
    skip "cannot locate the checkout with .github/scripts/install-lint-tools.sh"
  LINT_TOOLS="${REPO_ROOT}/.github/scripts/install-lint-tools.sh"
  ACTION_YML="${REPO_ROOT}/.github/actions/setup-bazel/action.yml"
  PINS="${REPO_ROOT}/images/dev/tool-versions.env"
  [[ -f ${LINT_TOOLS} ]] || skip "install-lint-tools.sh is not in the tree"
  [[ -f ${ACTION_YML} ]] || skip "setup-bazel action.yml is not in the tree"
  [[ -f ${PINS} ]] || skip "images/dev/tool-versions.env is not in the tree"
  BIN_DIR="${BATS_TEST_TMPDIR}/bin-target"
  mkdir -p "${BIN_DIR}"
  export LINT_TOOLS_BIN_DIR="${BIN_DIR}"
}

@test "ci installers source the pin lib and build every URL from it" {
  assert_contains_file "installer sources tool_pins.sh" "${LINT_TOOLS}" 'scripts/lib/tool_pins\.sh'
  assert_contains_file "installer calls tool_pins_linux_url" "${LINT_TOOLS}" 'tool_pins_linux_url'
  assert_contains_file "installer names the pin file" "${LINT_TOOLS}" 'images/dev/tool-versions\.env'
  assert_contains_file "action sources tool_pins.sh" "${ACTION_YML}" 'scripts/lib/tool_pins\.sh'
  assert_contains_file "action calls tool_pins_linux_url" "${ACTION_YML}" 'tool_pins_linux_url'
  assert_contains_file "action pins bazelisk" "${ACTION_YML}" 'tool_pins_linux_url .*bazelisk'
  # No release URL may be spelled out in either file: the lib owns them.
  ci_refute_contains "installer" "${LINT_TOOLS}" 'releases/download/'
  ci_refute_contains "installer" "${LINT_TOOLS}" 'releases.hashicorp.com'
  ci_refute_contains "action" "${ACTION_YML}" 'releases/download/'
  ci_refute_contains "action" "${ACTION_YML}" 'releases.hashicorp.com'
}

@test "ci installers carry no stale version literals" {
  local stale
  for stale in "${STALE_PIN_LITERALS[@]}"; do
    ci_refute_contains "installer" "${LINT_TOOLS}" "${stale}"
    ci_refute_contains "action" "${ACTION_YML}" "${stale}"
  done
}

@test "ci installers: the URLs they build are the current pins" {
  source_tool_pins
  local pins="${PINS}" ver
  ver="$(tool_pins_get "${pins}" BAZELISK_VERSION)" && [ -n "${ver}" ]
  [ "$(tool_pins_linux_url "${pins}" bazelisk amd64)" = \
    "https://github.com/bazelbuild/bazelisk/releases/download/${ver}/bazelisk-linux-amd64" ]
  ver="$(tool_pins_get "${pins}" SHFMT_ASSET_VERSION)" && [ -n "${ver}" ]
  [ "$(tool_pins_linux_url "${pins}" shfmt amd64)" = \
    "https://github.com/mvdan/sh/releases/download/v${ver}/shfmt_v${ver}_linux_amd64" ]
  ver="$(tool_pins_get "${pins}" BUILDIFIER_VERSION)" && [ -n "${ver}" ]
  [ "$(tool_pins_linux_url "${pins}" buildifier amd64)" = \
    "https://github.com/bazelbuild/buildtools/releases/download/${ver}/buildifier-linux-amd64" ]
  ver="$(tool_pins_get "${pins}" TERRAFORM_VERSION)" && [ -n "${ver}" ]
  [ "$(tool_pins_linux_url "${pins}" terraform amd64)" = \
    "https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_amd64.zip" ]
}

@test "installer root is two levels above .github/scripts" {
  load_shell_function "${LINT_TOOLS}" lint_tools_root
  local fake="${BATS_TEST_TMPDIR}/fake-root"
  mkdir -p "${fake}/.github/scripts" "${fake}/images/dev"
  printf '%s\n' 'SHFMT_ASSET_VERSION=9.9.9' >"${fake}/images/dev/tool-versions.env"
  [ "$(lint_tools_root "${fake}/.github/scripts")" = "${fake}" ]

  # A tree without the pin file is refused rather than guessed at.
  run lint_tools_root "${BATS_TEST_TMPDIR}"
  [ "${status}" -eq 1 ]
}

@test "installer fetches shfmt and buildifier from the pinned asset URLs" {
  source_tool_pins
  load_shell_function "${LINT_TOOLS}" lint_tools_fetch_pinned
  ci_use_fetch_stubs sudo
  local tmp url
  tmp="$(make_scratch)"
  export STUB_CURL_OUT='pinned-raw-binary'

  url="$(tool_pins_linux_url "${PINS}" shfmt amd64)"
  run lint_tools_fetch_pinned "${PINS}" amd64 "${tmp}" shfmt
  [ "${status}" -eq 0 ]
  assert_eq "shfmt fetch URL" "curl -fsSL ${url} -o ${tmp}/shfmt" "$(stub_log_last curl)"
  assert_eq "shfmt install" "sudo install -m 0755 ${tmp}/shfmt ${BIN_DIR}/shfmt" "$(stub_log_last sudo)"
  assert_contains_file "installed shfmt is the asset body" "${BIN_DIR}/shfmt" 'pinned-raw-binary'

  url="$(tool_pins_linux_url "${PINS}" buildifier arm64)"
  run lint_tools_fetch_pinned "${PINS}" arm64 "${tmp}" buildifier
  [ "${status}" -eq 0 ]
  assert_eq "buildifier fetch URL" "curl -fsSL ${url} -o ${tmp}/buildifier" "$(stub_log_last curl)"
}

@test "installer rejects an unpinned tool instead of inventing a URL" {
  source_tool_pins
  load_shell_function "${LINT_TOOLS}" lint_tools_fetch_pinned
  ci_use_fetch_stubs sudo
  local tmp
  tmp="$(make_scratch)"
  run lint_tools_fetch_pinned "${PINS}" riscv "${tmp}" shfmt
  [ "${status}" -eq 1 ]
  assert_eq "no fetch attempted" "0" "$(stub_log_count curl)"
}

@test "installer unpacks the terraform zip member instead of installing the zip" {
  source_tool_pins
  load_shell_function "${LINT_TOOLS}" lint_tools_fetch_terraform
  ci_use_fetch_stubs sudo unzip
  local tmp url zip
  tmp="$(make_scratch)"
  zip="${tmp}/terraform.zip"
  export STUB_CURL_OUT='this-is-a-zip-archive'

  url="$(tool_pins_linux_url "${PINS}" terraform amd64)"
  run lint_tools_fetch_terraform "${PINS}" amd64 "${tmp}"
  [ "${status}" -eq 0 ]
  assert_eq "terraform fetch URL" "curl -fsSL ${url} -o ${zip}" "$(stub_log_last curl)"
  assert_eq "only the terraform member is extracted" \
    "unzip -j -o -q ${zip} terraform -d ${tmp}" "$(stub_log_last unzip)"
  assert_eq "the archive itself is what was downloaded" \
    "sudo install -m 0755 ${tmp}/terraform ${BIN_DIR}/terraform" "$(stub_log_last sudo)"

  # What lands in the bin dir is the unpacked member, never the archive.
  assert_file_exists "installed terraform" "${BIN_DIR}/terraform"
  assert_contains_file "installed terraform is the member" "${BIN_DIR}/terraform" 'unpacked-terraform-binary'
  ci_refute_contains "installed terraform" "${BIN_DIR}/terraform" 'this-is-a-zip-archive'
}
