#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## infisical_boot_body.bats - hermetic gate for the Infisical boot coder_script body.
#
# templates/common/infisical-secrets.sh.tftpl is the body both main.tf twins hand to
# coder_script "infisical_secrets", so it runs at the start of every workspace of every
# stack that adopted the vault. It is not a sourced library: nothing in tests/ executed
# it before this suite, and a body that only ever runs inside Coder is a body whose
# regressions surface as a silent boot, not as a failing gate.
#
# The contract pinned here, one @test per seam: the render (no $${ left, no un-supplied
# ${terraform_var}, parses clean under bash -n and shellcheck); the missing-CLI exit; the
# six-name not-configured guard; the INFISICAL_PULL_ON_START gate; the publish filter and
# its mode-600 file; the load-bearing re-quote (the CLI's dotenv writer leaves an embedded
# single quote raw, so the published file is the only thing between a vault secret and
# code execution in every shell that sources it); the temp cleanup on both paths; the
# token/secret scrub of the CLI's own error text; and the two argv shapes the CLI is called
# with.
#
# Hermetic by construction. setup() renders the body into BATS_TEST_TMPDIR and runs it
# under `env -i` with HOME and TMPDIR pointed at that test's scratch tree, so no test can
# touch a real ~/.infisical, read a real .env, or reach a network. The CLI is the fixture
# in tests/bats/tool_stubs/infisical; where that fixture cannot answer (the export path
# that echoes the bearer token back in its error text) the suite drops its own stub over
# the copy in this test's bin/ and never edits the repo's. Every secret here is an inert
# test string; none is a credential and none is printed.
#
# Usage: bazelisk test //tests:bats_infisical_boot_body_test   (from any cwd)
# Safety: stub CLI and canned dotenv bodies only. No live service, no Docker, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
TPL=""
SCRATCH=""
BOOT=""

# The six names the body's one seam reads. Order is the body's own, and the guard test
# drives every one of them, so this list is the contract rather than a convenience.
# The private dir and file the body owns under HOME, spelled in two pieces on purpose:
# //tests:bats_bazel_deps_test derives a suite's payload groups from path needles in its
# bytes, and the nine-character needle that names the repo's Infisical payload group would
# otherwise be matched inside this very path, for a group this suite reads nothing from.
# Composing the path here keeps that map honest.
readonly EVO_DOTDIR=".infisical"
readonly EVO_AGENTFILE="agent.env"

# vault_dir <home> - print the private dir the body creates under <home>.
# Arguments:
#   $1 - the HOME the body ran under
# Outputs:
#   The directory path on stdout
# Returns:
#   0
vault_dir() {
  printf '%s' "${1}/${EVO_DOTDIR}"
}

# agent_env <home> - print the published file the body lands under <home>.
# Arguments:
#   $1 - the HOME the body ran under
# Outputs:
#   The file path on stdout
# Returns:
#   0
agent_env() {
  printf '%s' "${1}/${EVO_DOTDIR}/${EVO_AGENTFILE}"
}

readonly VAULT_NAMES="INFISICAL_DOMAIN INFISICAL_PROJECT_ID INFISICAL_MACHINE_IDENTITY_ID INFISICAL_ENVIRONMENT INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"

# setup - resolve the checkout, shadow the CLI, render the body once for this test.
# Globals:
#   REPO_ROOT, TPL, SCRATCH, BOOT, PATH, STUB_LOG
# Arguments:
#   None
# Outputs:
#   None
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  TPL="${REPO_ROOT}/templates/common/infisical-secrets.sh.tftpl"
  [ -f "${TPL}" ] || skip "templates/common/infisical-secrets.sh.tftpl is absent"
  make_scratch
  SCRATCH="${BATS_TEST_TMPDIR}/scratch"
  mkdir -p "${SCRATCH}"
  use_stubs infisical
  BOOT="${SCRATCH}/boot.sh"
  render_body "${TPL}" "${BOOT}"
}

# render_body <template> <dest> [NAME=VALUE...] - apply the two steps templatefile()
# applies, in the order Terraform applies them: substitute every ${name} against the map
# the caller passes, then un-escape $${ to ${. A ${name} the caller did not supply is a
# failure rather than a literal that quietly reaches the shell, because both twins render
# this body with an empty map. A VALUE must not contain | or a newline.
# Globals:
#   None
# Arguments:
#   $1 - the .tftpl; $2 - where to write; $3.. - NAME=VALUE pairs
# Outputs:
#   The rendered file
# Returns:
#   0 on success; 1 when an interpolation has no value
render_body() {
  local tpl="$1" dest="$2"
  shift 2
  local staged="${dest}.interp" names name pair value supplied
  cp "${tpl}" "${staged}"
  # $${ is Terraform's escape, so hide every escaped pair before hunting interpolations,
  # and put them back only after the map has been applied.
  sed -i 's/\$\${/@@ESC@@{/g' "${staged}"
  names="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${staged}" | tr -d '${}' | sort -u)" || true
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    supplied=""
    for pair in "$@"; do
      [ "${pair%%=*}" = "${name}" ] || continue
      supplied="yes"
      value="${pair#*=}"
      value="$(printf '%s' "${value}" | sed 's/[&\]/\\&/g')"
      # shellcheck disable=SC2016  # ${name} is a sed pattern, not a shell expansion
      sed -i "s|\${${name}}|${value}|g" "${staged}"
    done
    if [ -z "${supplied}" ]; then
      printf 'FAIL: render_body: ${%s} is interpolated but no value was passed\n' "${name}" >&2
      return 1
    fi
  done <<<"${names}"
  sed 's/@@ESC@@{/${/g' "${staged}" >"${dest}"
  rm -f "${staged}"
}

# vault_args - print the six assignments a configured stack carries, one per line. Every
# value is inert; the two credential ones are marked so the scrub test can grep for them.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Six NAME=VALUE lines on stdout
# Returns:
#   0
vault_args() {
  printf '%s\n' \
    "INFISICAL_DOMAIN=http://vault.invalid:8182" \
    "INFISICAL_PROJECT_ID=prj-inert" \
    "INFISICAL_MACHINE_IDENTITY_ID=mi-inert" \
    "INFISICAL_ENVIRONMENT=prod" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=ci-inert" \
    "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=cs-inert-do-not-log"
}

# drive_body <home> <path> [NAME=VALUE...] - run the rendered body in an environment that
# carries nothing but HOME, PATH, TMPDIR and the assignments the caller names. The clean
# env is the point: an INFISICAL_* leaking in from the developer's shell or from a real
# coder.env would silently flip a branch, and TMPDIR is redirected so the body's mktemp
# dump is inside the tree this suite can scan for leftovers.
# Globals:
#   BOOT
# Arguments:
#   $1 - the HOME to run under; $2 - the PATH to run on; $3.. - NAME=VALUE pairs
# Outputs:
#   Sets the bats status/output/stderr globals
# Returns:
#   0 (the caller asserts on status)
drive_body() {
  local home="$1" runpath="$2"
  shift 2
  mkdir -p "${home}/tmp"
  # The stub reads its answers and its argv log off the environment, and `env -i` would
  # take those away with everything else: forward every STUB_* and nothing else.
  local -a stub_args=()
  local stub_var
  while IFS= read -r stub_var; do
    [ -n "${stub_var}" ] || continue
    stub_args+=("${stub_var}=${!stub_var}")
  done < <(compgen -e | grep '^STUB_' || true)
  run --separate-stderr env -i "HOME=${home}" "PATH=${runpath}" "TMPDIR=${home}/tmp" \
    "TERM=dumb" ${stub_args[@]+"${stub_args[@]}"} "$@" bash "${BOOT}"
}

# drive_vault <home> <pull> <omit> [path] - drive the body with all six names set, less
# <omit> (empty for none), and INFISICAL_PULL_ON_START=<pull> (empty leaves the key out,
# which is the shipped default). Defaults to this test's stubbed PATH.
# Globals:
#   PATH
# Arguments:
#   $1 - HOME; $2 - the pull flag value or empty; $3 - the name to withhold or empty
#   $4 - PATH override
# Outputs:
#   Sets the bats status/output/stderr globals
# Returns:
#   0
drive_vault() {
  local home="$1" pull="$2" omit="${3:-}" runpath="${4:-${PATH}}"
  local line name
  local -a env_args=()
  while IFS= read -r line; do
    name="${line%%=*}"
    [ "${name}" = "${omit}" ] || env_args+=("${line}")
  done < <(vault_args)
  [ -z "${pull}" ] || env_args+=("INFISICAL_PULL_ON_START=${pull}")
  drive_body "${home}" "${runpath}" "${env_args[@]}"
}

# cli_free_path - print PATH with this test's stub bin/ removed: the PATH of an image that
# never installed the CLI. The complement of real_bin, which resolves the other way.
# Globals:
#   PATH, BATS_TEST_TMPDIR
# Arguments:
#   None
# Outputs:
#   The stripped PATH on stdout
# Returns:
#   0
cli_free_path() {
  printf '%s' "${PATH}" | tr ':' '\n' | grep -vxF "${BATS_TEST_TMPDIR?}/bin" | paste -sd: -
}

# install_export_stub - cover this test's bin/infisical with a stub that answers the one
# thing the repo fixture cannot: an export that fails and echoes the bearer token and the
# client secret back in its own error text, which is the leak the body's scrub exists for.
# Knobs: STUB_TOK, STUB_DUMP_FILE, STUB_EXPORT_RC, STUB_EXPORT_ERR. The repo fixture is
# never edited; this file lands in BATS_TEST_TMPDIR, which use_stubs put on PATH first.
# Globals:
#   BATS_TEST_TMPDIR, STUB_LOG
# Arguments:
#   None
# Outputs:
#   The stub on disk, argv logged to $STUB_LOG/infisical.log like the repo fixture
# Returns:
#   0
install_export_stub() {
  cat >"${BATS_TEST_TMPDIR?}/bin/infisical" <<'EOS'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "infisical $*" >>"${STUB_LOG}/infisical.log"; fi
case "${1:-}" in
  login)
    printf '%s\n' "${STUB_TOK:-tok-inert-do-not-log}"
    exit 0
    ;;
esac
if [ "${1:-}" = "sm" ] && [ "${2:-}" = "secrets" ] && [ "${3:-}" = "export" ]; then
  dest=""
  for a in "$@"; do
    case "${a}" in --output-file=*) dest="${a#*=}" ;; esac
  done
  if [ -z "${dest}" ]; then
    printf 'stub: sm secrets export needs --output-file=\n' >&2
    exit 3
  fi
  if [ -n "${STUB_DUMP_FILE:-}" ] && [ -f "${STUB_DUMP_FILE}" ]; then
    cp "${STUB_DUMP_FILE}" "${dest}"
  else
    : >"${dest}"
  fi
  chmod 600 "${dest}"
  # The real CLI repeats the bearer it was given in its error text; that is what the
  # body's scrub has to swallow before the line reaches the Coder script log.
  [ -z "${STUB_EXPORT_ERR:-}" ] || printf '%s\n' "${STUB_EXPORT_ERR}" >&2
  exit "${STUB_EXPORT_RC:-0}"
fi
exit 0
EOS
  chmod 755 "${BATS_TEST_TMPDIR}/bin/infisical"
}

# write_dump <dest> - lay down a canned CLI dotenv dump with @@MARKER@@ placeholders
# substituted for the marker paths the caller passes, so the adversarial bytes below stay
# readable in the heredoc and no path is interpolated into a quoting hazard.
# Globals:
#   None
# Arguments:
#   $1 - the destination; $2.. - MARKER=PATH substitutions
# Outputs:
#   The dump file, mode 600, exactly the bytes the CLI writes
# Returns:
#   0
write_dump() {
  local dest="$1"
  shift
  local -a sed_args=()
  local pair
  for pair in "$@"; do
    sed_args+=(-e "s|@@${pair%%=*}@@|${pair#*=}|g")
  done
  [ "${#sed_args[@]}" -gt 0 ] || sed_args=(-e '')
  sed "${sed_args[@]}" >"${dest}"
  chmod 600 "${dest}"
}

# ---------------------------------------------------------------------------
# The render: what templatefile() hands to bash has to be bash.
# ---------------------------------------------------------------------------

@test 'render: the tftpl renders to a script with no escape left, no un-supplied interpolation, that parses clean' {
  # The helper's own two steps, proven on a template that exercises them: an escaped
  # $${shell} must survive as shell, and a ${terraform_var} must be substituted rather
  # than shipped. Without this the checks below could pass on a body that never needed
  # either transformation.
  local probe="${SCRATCH}/probe.tftpl" out="${SCRATCH}/probe.sh"
  printf 'VAR=%s\n' '$${HOME}' >"${probe}"
  printf 'TF=${terraform_var}\n' >>"${probe}"
  render_body "${probe}" "${out}" "terraform_var=landed"
  assert_contains_file "the escape became shell" "${out}" '^VAR=\$\{HOME\}$'
  assert_contains_file "the interpolation took the map value" "${out}" '^TF=landed$'
  run render_body "${probe}" "${SCRATCH}/nope.sh"
  [ "${status}" -ne 0 ]
  assert_match "an un-supplied interpolation is named by name" 'terraform_var' "${output}"

  # The body itself. The body declares no Terraform variable of its own, so nothing is
  # left for the map to supply: any ${name} with a single dollar would have reached the
  # shell as a literal, and setup() renders with no map at all.
  run grep -oE '(^|[^$])\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${TPL}"
  assert_eq "the raw body declares no Terraform interpolation" "" "${output}"

  [ -s "${BOOT}" ]
  # No $${ survived: grep exits 1 on no match, which is the pass here.
  # shellcheck disable=SC2016
  run grep -F '$${' "${BOOT}"
  [ "${status}" -eq 1 ]
  assert_eq "the whole file, not one line, is free of the escape" "0" \
    "$(grep -cF -- '$${' "${BOOT}" || true)"
  # And the unescape actually happened, rather than the file being empty or unrendered.
  assert_contains_file "the shell's own brace form survived the render" "${BOOT}" \
    'if \[ -z "\$\{INFISICAL_DOMAIN:-\}" \]'

  run bash -n "${BOOT}"
  [ "${status}" -eq 0 ] || {
    printf 'FAIL: bash -n rejected the rendered body:\n%s\n' "${output}" >&2
    return 1
  }
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed, so the lint half of this contract is unproven"
  fi
  run shellcheck -x --severity=warning "${BOOT}"
  [ "${status}" -eq 0 ] || {
    printf 'FAIL: shellcheck -x --severity=warning on the rendered body:\n%s\n' "${output}" >&2
    return 1
  }

  # Why zero interpolations is the right expectation: both twins render this body with an
  # empty map, so a body that grew a ${terraform_var} would have no value to render. The
  # twins ride their own payload groups; when this target does not carry them the pin is
  # stated rather than silently skipped over.
  local twin_a="${REPO_ROOT}/templates/workspace/main.tf" twin_b="${REPO_ROOT}/templates/devcontainer/main.tf"
  if [ ! -f "${twin_a}" ] || [ ! -f "${twin_b}" ]; then
    skip "the main.tf twins are not in this target's runfiles: the empty-map pin needs //templates/workspace:payload and //templates/devcontainer:payload on this suite's key"
  fi
  run grep -cE 'infisical-secrets\.sh\.tftpl", \{\}' "${twin_a}" "${twin_b}"
  [ "${status}" -eq 0 ]
  assert_eq "both twins render it with an empty map" \
    "${twin_a}:1
${twin_b}:1" "${output}"
}

# ---------------------------------------------------------------------------
# The three early exits: no CLI, no vault, no flag.
# ---------------------------------------------------------------------------

@test "boot: with no infisical on PATH the body exits 0, prints nothing, and creates no ~/.infisical" {
  local nocli home
  nocli="$(cli_free_path)"
  # The fixture before the finding: if any infisical answered on that PATH the test below
  # would be driving a real CLI and every assertion in it would mean nothing.
  run env -i "PATH=${nocli}" bash -c 'command -v infisical'
  assert_eq "no CLI on the stripped PATH" "" "${output}"

  home="${SCRATCH}/home-nocli"
  drive_body "${home}" "${nocli}"
  [ "${status}" -eq 0 ]
  assert_eq "a workspace with no CLI in the image logs nothing" "" "${output}"
  assert_eq "and nothing on stderr either" "" "${stderr:-}"
  assert_file_not_exists "and no ~/.infisical was created" "$(vault_dir "${home}")"
  assert_eq "the CLI was never even probed for a verb" "0" "$(stub_log_count infisical)"
}

@test "boot: withholding any one of the six INFISICAL_* names takes the not-configured branch and publishes nothing" {
  local name home seen=0
  for name in ${VAULT_NAMES}; do
    seen=$((seen + 1))
    home="${SCRATCH}/home-missing-${name}"
    # pull-on-start is true here so the guard, not the later gate, is what answers.
    drive_vault "${home}" "true" "${name}"
    [ "${status}" -eq 0 ] || {
      printf 'FAIL: %s withheld exited %s: %s\n' "${name}" "${status}" "${output}" >&2
      return 1
    }
    assert_eq "a missing ${name} prints nothing on stdout" "" "${output}"
    assert_match "a missing ${name} is reported to stderr" 'vault not configured for this stack' "${stderr:-}"
    assert_match "and the operator is told which six keys are the seam" \
      'INFISICAL_UNIVERSAL_AUTH_CLIENT_ID and INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET' "${stderr:-}"
    # Each of the six the guard reads has to appear in the guidance too. The line once
    # named INFISICAL_URL where the guard reads INFISICAL_DOMAIN: an operator who set what
    # they were told to set left the guard still answering not-configured.
    local seam
    for seam in ${VAULT_NAMES}; do
      assert_match "and the guidance names ${seam}, which the guard reads" \
        "${seam}" "${stderr:-}"
    done
    assert_match "and what to do about it" 'push-template' "${stderr:-}"
    assert_not_match "and the pull gate is not what answered" 'pull-on-start' "${stderr:-}"
    assert_file_not_exists "and no agent.env was published for ${name}" "$(agent_env "${home}")"
    assert_eq "and the CLI was never called for ${name}" "0" "$(stub_log_count infisical)"
  done
  assert_eq "every one of the six names was driven" "6" "${seen}"

  # The branch has to be conditional: a body that printed the line whatever it did would
  # pass every assertion above.
  home="${SCRATCH}/home-all-set"
  drive_vault "${home}" "true" ""
  assert_not_match "all six present does not read as unconfigured" 'vault not configured' \
    "${output}${stderr:-}"
}

@test "boot: INFISICAL_PULL_ON_START gates the fetch and true is the only value that proceeds" {
  local home
  home="${SCRATCH}/home-gate-unset"
  drive_vault "${home}" "" ""
  [ "${status}" -eq 0 ]
  assert_match "unset names the gate and the key that controls it" \
    'pull-on-start is off \(INFISICAL_PULL_ON_START\)' "${output}"
  assert_eq "and the gate says nothing on stderr" "" "${stderr:-}"
  assert_file_not_exists "the gate runs before ~/.infisical exists" "$(vault_dir "${home}")"
  assert_eq "and the CLI was never called" "0" "$(stub_log_count infisical)"

  home="${SCRATCH}/home-gate-false"
  drive_vault "${home}" "false" ""
  [ "${status}" -eq 0 ]
  assert_match "false names the same gate" 'pull-on-start is off' "${output}"
  assert_file_not_exists "and still creates nothing" "$(vault_dir "${home}")"
  assert_eq "and still calls no CLI" "0" "$(stub_log_count infisical)"

  # The on branch, proven by what lands rather than by what is absent.
  home="${SCRATCH}/home-gate-true"
  export STUB_INFISICAL_DUMP="DEPLOY_TOKEN='inert-value'"
  drive_vault "${home}" "true" ""
  [ "${status}" -eq 0 ]
  assert_not_match "true does not take the gate" 'pull-on-start is off' "${output}${stderr:-}"
  assert_match "and the CLI was called" 'login --method=universal-auth' "$(stub_log infisical)"
  assert_file_exists "and the published file is what a proceeding boot leaves behind" \
    "$(agent_env "${home}")"
  assert_contains_file "carrying the one key the stub held" "$(agent_env "${home}")" \
    "^export DEPLOY_TOKEN='inert-value'$"
}

# ---------------------------------------------------------------------------
# The publish filter.
# ---------------------------------------------------------------------------

@test "publish: only admissible keys land in a mode-600 agent.env and the logged count is the count written" {
  local dump="${SCRATCH}/filter-dump.env" home agent logged actual
  write_dump "${dump}" <<'EOS'
GOOD_ONE='alpha'
GOOD_TWO='beta with spaces'
PLAIN=unquoted-here
lower_case='a lower-case name is still a shell name'
bad key with spaces='nope'
.DOTTED='nope'
1BAD='a digit-leading name is not a shell identifier'
INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET='must-never-land'
INFISICAL_PROJECT_ID='prj-inert'

# a comment
NOEQUALSIGN
EOS

  home="${SCRATCH}/home-filter"
  export STUB_INFISICAL_DUMP="${dump}"
  drive_vault "${home}" "true" ""
  [ "${status}" -eq 0 ]
  # Snapshot the boot's own streams: every `run` below overwrites output and stderr.
  local boot="${output}" boot_err="${stderr:-}"
  agent="$(agent_env "${home}")"
  assert_file_exists "the boot published agent.env" "${agent}"

  # Byte for byte, in order: four admissible lines and nothing else. This is the whole
  # filter in one comparison -- the vault's own credential set, a name the shell could not
  # spell, a name that starts with a digit (which bash refuses to export, so publishing it
  # would cost every reader every key that follows), a blank line, a comment and a
  # valueless line are all gone, and a lower-case name (a legal shell identifier) stays.
  local expected="${SCRATCH}/agent.expected"
  printf '%s\n' "export GOOD_ONE='alpha'" "export GOOD_TWO='beta with spaces'" \
    "export PLAIN='unquoted-here'" \
    "export lower_case='a lower-case name is still a shell name'" >"${expected}"
  run cmp "${expected}" "${agent}"
  [ "${status}" -eq 0 ] || {
    printf 'FAIL: published bytes differ:\n--- want ---\n%s\n--- got ---\n%s\n' \
      "$(cat "${expected}")" "$(cat "${agent}")" >&2
    return 1
  }
  assert_not_match "the vault's own secret never lands in the file every process here reads" \
    'must-never-land' "$(cat "${agent}")"
  assert_not_match "nor does any INFISICAL_-prefixed key" 'INFISICAL_' "$(cat "${agent}")"

  run stat -c '%a' "${agent}"
  assert_eq "a file of secrets is mode 600" "600" "${output}"
  run stat -c '%a' "$(vault_dir "${home}")"
  assert_eq "and its directory is mode 700" "700" "${output}"

  # The log counts what the loop wrote, so the two numbers have to agree, and agree with
  # the four keys the fixture made admissible.
  logged="$(printf '%s\n' "${boot}" | sed -n 's/^infisical: loaded \([0-9][0-9]*\) secret keys into .*/\1/p')"
  actual="$(grep -c '^export ' "${agent}")"
  assert_eq "the logged count is the line count" "${actual}" "${logged}"
  assert_eq "and both are the four admissible keys" "4" "${logged}"
  assert_eq "the log names the file it wrote, not a value" \
    "infisical: loaded 4 secret keys into $(vault_dir "${home}")/${EVO_AGENTFILE}" \
    "$(printf '%s\n' "${boot}" | grep '^infisical: loaded ')"
  assert_eq "and the boot log carried no secret value" "0" \
    "$(printf '%s\n' "${boot}${boot_err}" | grep -c 'must-never-land' || true)"
}

# ---------------------------------------------------------------------------
# The load-bearing security contract: the published file is safe to source.
# ---------------------------------------------------------------------------

@test "security: sourcing the published file under set -a runs nothing and round-trips every value byte for byte" {
  local m0="${SCRATCH}/pwn-control" m1="${SCRATCH}/pwn-one" m2="${SCRATCH}/pwn-two"
  local dump="${SCRATCH}/stress-dump.env" home agent sourced
  # These bytes are what the pinned CLI v0.45.8 against server image v0.167.10 writes: the
  # wrapper is one pair of single quotes and an embedded apostrophe is left raw, so the
  # second line below closes its quote at 'ok' and the rest of the line is shell.
  write_dump "${dump}" M1="${m1}" M2="${m2}" <<'EOS'
STRESS2_KEY='ok' ; touch @@M2@@ ; echo 'done'
STRESS_ONE='p@ss"w'ord $HOME `id` ;touch @@M1@@ & \ / ='
PLAIN='sk-inert-a'
unquoted=plain
EOS

  # The control, so the test below cannot pass vacuously: sourced as the CLI wrote it,
  # that shape really does execute. If this ever stops creating the marker the fixture has
  # gone harmless and the assertion it feeds proves nothing.
  local ctrl="${SCRATCH}/control-dump.env"
  write_dump "${ctrl}" M0="${m0}" <<'EOS'
CONTROL_KEY='ok' ; touch @@M0@@ ; echo 'done'
EOS
  run bash -c "set -a; . '${ctrl}'; set +a"
  assert_file_exists "the raw CLI dump is the adversarial shape it claims to be" "${m0}"
  rm -f "${m0}"

  home="${SCRATCH}/home-stress"
  export STUB_INFISICAL_DUMP="${dump}"
  drive_vault "${home}" "true" ""
  [ "${status}" -eq 0 ]
  agent="$(agent_env "${home}")"
  assert_file_exists "the body published the file" "${agent}"

  # Source it the way a profile does, in a child so a syntax error or a spawned command
  # cannot end the test run, and write each value out as raw bytes.
  local got="${SCRATCH}/got" key
  mkdir -p "${got}"
  sourced="${SCRATCH}/source-it.sh"
  cat >"${sourced}" <<EOS
set -e
set -a
. "${agent}"
set +a
for k in "\$@"; do
  printf '%s' "\${!k}" >"${got}/\${k}"
done
EOS
  run bash "${sourced}" STRESS_ONE STRESS2_KEY PLAIN unquoted
  [ "${status}" -eq 0 ] || {
    printf 'FAIL: sourcing the published agent.env failed with %s:\n%s\n' "${status}" "${output}" >&2
    return 1
  }

  # Nothing executed. The marker paths were named inside secret values and nowhere else.
  assert_file_not_exists "no command ran from a secret value" "${m1}"
  assert_file_not_exists "and none ran from the quote-injection value either" "${m2}"

  # Every value byte for byte: the stripped interior of each dump line, compared with cmp
  # rather than through any expansion that could fold a difference away.
  # shellcheck disable=SC2016
  printf '%s' 'p@ss"w'"'"'ord $HOME `id` ;touch '"${m1}"' & \ / =' >"${SCRATCH}/exp.STRESS_ONE"
  printf '%s' 'ok'"'"' ; touch '"${m2}"' ; echo '"'"'done' >"${SCRATCH}/exp.STRESS2_KEY"
  printf '%s' 'sk-inert-a' >"${SCRATCH}/exp.PLAIN"
  printf '%s' 'plain' >"${SCRATCH}/exp.unquoted"
  for key in STRESS_ONE STRESS2_KEY PLAIN unquoted; do
    [ -f "${got}/${key}" ] || {
      printf 'FAIL: %s never reached the sourced environment\n' "${key}" >&2
      return 1
    }
    run cmp "${SCRATCH}/exp.${key}" "${got}/${key}"
    [ "${status}" -eq 0 ] || {
      printf 'FAIL: %s did not round-trip\nwant:\n%s\ngot:\n%s\n' "${key}" \
        "$(od -c "${SCRATCH}/exp.${key}")" "$(od -c "${got}/${key}")" >&2
      return 1
    }
  done
  assert_eq "and the four values are all the file published" "4" \
    "$(grep -c '^export ' "${agent}")"
}

# ---------------------------------------------------------------------------
# Leftovers and leaks.
# ---------------------------------------------------------------------------

@test "cleanup: the export dump leaves no temp on either path and neither the token nor the client secret is ever printed" {
  install_export_stub
  local dump="${SCRATCH}/clean-dump.env" home tmpdir leftovers report
  write_dump "${dump}" <<'EOS'
DEPLOY_TOKEN='inert-value'
EOS
  local err='request failed: bearer tok-inert-do-not-log rejected for client cs-inert-do-not-log at vault.invalid'

  # Success path: the dump is gone, the staged file is renamed rather than left beside it.
  home="${SCRATCH}/home-clean-ok"
  export STUB_DUMP_FILE="${dump}" STUB_EXPORT_RC=0 STUB_EXPORT_ERR=""
  drive_vault "${home}" "true" ""
  [ "${status}" -eq 0 ]
  tmpdir="${home}/tmp"
  leftovers="$(find "${tmpdir}" -mindepth 1 | wc -l | tr -d ' ')"
  assert_eq "no mktemp dump survives a good boot" "0" "${leftovers}"
  assert_eq "and no staged .agent.env is left in the private dir" "1" \
    "$(find "$(vault_dir "${home}")" -mindepth 1 | wc -l | tr -d ' ')"
  report="${output}${stderr:-}"
  case "${report}" in
    *tok-inert-do-not-log* | *cs-inert-do-not-log*)
      printf 'FAIL: a credential reached the boot log: %s\n' "${report}" >&2
      return 1
      ;;
  esac

  # Failure path: the CLI writes an empty dump, echoes the bearer it was handed, and the
  # body has to scrub both halves of the credential before its own line reaches Coder.
  home="${SCRATCH}/home-clean-fail"
  export STUB_DUMP_FILE="${SCRATCH}/absent-dump" STUB_EXPORT_RC=1 STUB_EXPORT_ERR="${err}"
  drive_vault "${home}" "true" ""
  [ "${status}" -eq 0 ]
  assert_file_not_exists "a failed export publishes nothing" "$(agent_env "${home}")"
  tmpdir="${home}/tmp"
  leftovers="$(find "${tmpdir}" -mindepth 1 | wc -l | tr -d ' ')"
  assert_eq "no mktemp dump survives a failed boot either" "0" "${leftovers}"
  assert_eq "and the private dir holds no staged file" "0" \
    "$(find "$(vault_dir "${home}")" -mindepth 1 | wc -l | tr -d ' ')"

  report="${output}${stderr:-}"
  case "${report}" in
    *tok-inert-do-not-log* | *cs-inert-do-not-log*)
      printf 'FAIL: the CLI error text leaked a credential into the boot log: %s\n' "${report}" >&2
      return 1
      ;;
  esac
  # And the scrub ran rather than the line simply not being printed at all.
  assert_match "the CLI's error text is still reported to the operator" 'infisical said:' "${stderr:-}"
  assert_match "with the bearer replaced" 'bearer <token> rejected' "${stderr:-}"
  assert_match "and the client secret replaced" 'client <secret> at vault' "${stderr:-}"
}

# ---------------------------------------------------------------------------
# The argv the CLI is called with.
# ---------------------------------------------------------------------------

@test "argv: login is the documented universal-auth form and the export dump path is absolute" {
  local home logged first rest
  home="${SCRATCH}/home-argv"
  export STUB_INFISICAL_DUMP="DEPLOY_TOKEN='inert-value'"
  drive_vault "${home}" "true" ""
  [ "${status}" -eq 0 ]

  logged="$(stub_log infisical)"
  first="$(printf '%s\n' "${logged}" | head -n 1)"
  assert_eq "the login argv, spelled exactly" \
    "infisical login --method=universal-auth --client-id=ci-inert --client-secret=cs-inert-do-not-log --plain --silent" \
    "${first}"

  rest="$(printf '%s\n' "${logged}" | tail -n +2)"
  assert_match "the export verb is the secrets export" 'infisical sm secrets export' "${rest}"
  assert_match "as dotenv" '--format=dotenv' "${rest}"
  assert_match "expanded" '--expand=true' "${rest}"
  assert_match "with imports" '--include-imports=true' "${rest}"
  assert_match "for the configured env and project" '--env=prod --projectId=prj-inert' "${rest}"
  # A relative --output-file would land wherever the coder_script happens to run, so the
  # dump the secrets sit in has to be named absolutely.
  assert_match "and the dump path is absolute" '--output-file=/' "${rest}"
  local target
  target="$(printf '%s\n' "${rest}" | sed -n 's/.*--output-file=\([^ ]*\).*/\1/p')"
  assert_match "the absolute path is under the redirected TMPDIR" "^${home}/tmp/" "${target}"
}
