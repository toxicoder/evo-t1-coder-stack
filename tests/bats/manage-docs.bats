#!/usr/bin/env bats
#
# ## manage-docs.bats — hermetic coverage for docs/manage-docs.sh.
#
# The operator contract pinned here: the build refuses to start on an incomplete site
# package and names the missing piece, an unknown option is refused before any npm runs,
# `build --alias NAME` is what decides the export's DOCS_ALIAS (with `latest` routed
# to the script that bakes it in), and `serve` opens the browser at the port it binds
# unless --no-browser says otherwise.
#
# Usage: bazelisk test //tests:bats_manage_docs_test   (from any cwd)
# Safety: node, npm and python3 (the browser opener) are per-test PATH stubs and the
# site package is a scratch copy, so nothing is installed, built, opened, or written
# inside the real checkout.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
REPO=""
SITE=""
NPM_LOG=""
OPENER_LOG=""

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
  OPENER_LOG="${BATS_TEST_TMPDIR}/opener.log"
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

# stub_opener - the opener is `python3 -m webbrowser`, which would launch a real
# browser here. The fake records the URL it was handed instead.
stub_opener() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  cat >"${bin}/python3" <<'STUB'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >>"${OPENER_LOG}"
exit "${OPENER_RC:-0}"
STUB
  chmod +x "${bin}/python3"
  export OPENER_LOG
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

@test "manage-docs: serve opens the browser at the port it is serving" {
  complete_site_package
  stub_toolchain
  stub_opener
  run --separate-stderr "${REPO}/docs/manage-docs.sh" serve
  [ "${status}" -eq 0 ]
  assert_eq "the opener got the loopback dev URL" \
    "python3 -m webbrowser http://127.0.0.1:3005" "$(cat "${OPENER_LOG}")"
  assert_match "the dev server still binds localhost" \
    'npm run dev -- --port 3005 --hostname localhost$' "$(cat "${NPM_LOG}")"
  assert_match "the stop is reported" '^ok: Fumadocs dev server on port 3005 stopped$' "${output}"
  assert_match "and counted" '^summary: 1 ok, 0 warnings, 0 failed$' "${output}"
}

@test "manage-docs: serve --port puts that port in the URL the opener gets" {
  complete_site_package
  stub_toolchain
  stub_opener
  run --separate-stderr "${REPO}/docs/manage-docs.sh" serve --port 4123
  [ "${status}" -eq 0 ]
  assert_eq "one URL, on the requested port" \
    "python3 -m webbrowser http://127.0.0.1:4123" "$(cat "${OPENER_LOG}")"
  assert_match "the server was asked for the same port" \
    'npm run dev -- --port 4123 --hostname localhost$' "$(cat "${NPM_LOG}")"
}

@test "manage-docs: serve --no-browser never launches the opener" {
  complete_site_package
  stub_toolchain
  stub_opener
  run --separate-stderr "${REPO}/docs/manage-docs.sh" serve --no-browser
  [ "${status}" -eq 0 ]
  assert_file_not_exists "no opener was launched" "${OPENER_LOG}"
  assert_match "the server still started" \
    'npm run dev -- --port 3005 --hostname localhost$' "$(cat "${NPM_LOG}")"
}

@test "manage-docs: an opener that fails does not fail serve" {
  # Auto-open is a convenience; a box with no browser configured must still get
  # its dev server.
  complete_site_package
  stub_toolchain
  stub_opener
  run --separate-stderr env OPENER_RC=1 "${REPO}/docs/manage-docs.sh" serve
  [ "${status}" -eq 0 ]
  assert_match "the opener was attempted" \
    "python3 -m webbrowser http://127.0.0.1:3005" "$(cat "${OPENER_LOG}")"
  assert_match "the server still reported its stop" '^ok: Fumadocs dev server on port 3005 stopped$' "${output}"
}
