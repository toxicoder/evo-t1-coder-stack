#!/usr/bin/env bats
#
# ## manage-docs.bats — hermetic coverage for docs/manage-docs.sh.
#
# The operator contract pinned here: the build refuses to start on an incomplete site
# package and names the missing piece, an unknown option is refused before any npm runs,
# and `build --alias NAME` is what decides the export's DOCS_ALIAS (with `latest` routed
# to the script that bakes it in).
#
# Usage: bazelisk test //tests:bats_manage_docs_test   (from any cwd)
# Safety: node and npm are per-test PATH stubs and the site package is a scratch copy,
# so nothing is installed, built, or written inside the real checkout.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
REPO=""
SITE=""
NPM_LOG=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/docs/manage-docs.sh"
  [[ -f "${SCRIPT}" ]] || skip "manage-docs.sh is not reachable from ${REPO_ROOT}"
  REPO="${BATS_TEST_TMPDIR}/repo"
  SITE="${REPO}/docs-site"
  mkdir -p "${REPO}/docs" "${SITE}/lib" "${SITE}/node_modules/.bin" "${BATS_TEST_TMPDIR}/bin" "${REPO}/scripts/lib"
  cp "${SCRIPT}" "${REPO}/docs/manage-docs.sh"
  chmod +x "${REPO}/docs/manage-docs.sh"
  cp "${REPO_ROOT}/scripts/lib/common.sh" "${REPO}/scripts/lib/common.sh"
  NPM_LOG="${BATS_TEST_TMPDIR}/npm.log"
}

# complete_site_package — the files check_content looks for, plus an installed next.
complete_site_package() {
  printf 'export default {};\n' >"${SITE}/source.config.ts"
  printf '[]\n' >"${SITE}/lib/nav.json"
  : >"${SITE}/node_modules/.bin/next"
  chmod +x "${SITE}/node_modules/.bin/next"
}

# stub_toolchain — node and npm that only answer the version probe and log their argv.
stub_toolchain() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  cat >"${bin}/node" <<'STUB'
#!/usr/bin/env bash
printf '22\n'
STUB
  cat >"${bin}/npm" <<'STUB'
#!/usr/bin/env bash
printf 'DOCS_ALIAS=%s|npm %s\n' "${DOCS_ALIAS-}" "$*" >>"${NPM_LOG}"
STUB
  chmod +x "${bin}/node" "${bin}/npm"
  export PATH="${bin}:${PATH}"
  export NPM_LOG
}

@test "manage-docs: check_content names the missing site package piece" {
  # extract_fn loads one function. check_content calls die, and die calls err.
  load_shell_function "${REPO_ROOT}/scripts/lib/common.sh" err
  load_shell_function "${REPO_ROOT}/scripts/lib/common.sh" die
  load_shell_function "${SCRIPT}" check_content
  SITE_DIR="${SITE}"
  run --separate-stderr check_content
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"source.config.ts not found"* ]]

  printf 'export default {};\n' >"${SITE}/source.config.ts"
  run --separate-stderr check_content
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"nav.json is missing"* ]]

  complete_site_package
  run --separate-stderr check_content
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
}

@test "manage-docs: build --alias puts that alias on the export" {
  complete_site_package
  stub_toolchain
  run "${REPO}/docs/manage-docs.sh" build --alias feat-foo
  [ "${status}" -eq 0 ]
  assert_match "the alias reaches npm's environment" 'DOCS_ALIAS=feat-foo\|npm run build$' "$(cat "${NPM_LOG}")"
}

@test "manage-docs: build --alias latest uses the script that bakes the alias in" {
  complete_site_package
  stub_toolchain
  run "${REPO}/docs/manage-docs.sh" build --alias latest
  [ "${status}" -eq 0 ]
  assert_match "build:latest is the script that runs" 'npm run build:latest$' "$(cat "${NPM_LOG}")"
  assert_not_match "no alias is exported twice" 'DOCS_ALIAS=latest' "$(cat "${NPM_LOG}")"
}

@test "manage-docs: a build with no alias exports unprefixed" {
  complete_site_package
  stub_toolchain
  run "${REPO}/docs/manage-docs.sh" build
  [ "${status}" -eq 0 ]
  assert_match "the plain build runs" 'npm run build$' "$(cat "${NPM_LOG}")"
  assert_not_match "no basePath is baked in" 'DOCS_ALIAS=[^|]' "$(cat "${NPM_LOG}")"
}

@test "manage-docs: an unknown option is refused before anything is built" {
  stub_toolchain
  run --separate-stderr "${REPO}/docs/manage-docs.sh" build --target feat-foo
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"Unknown option for build: --target"* ]]
  [ ! -f "${NPM_LOG}" ]
}

@test "manage-docs: an unknown serve option is refused too" {
  stub_toolchain
  run --separate-stderr "${REPO}/docs/manage-docs.sh" serve --host 0.0.0.0
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"Unknown option for serve: --host"* ]]
}
