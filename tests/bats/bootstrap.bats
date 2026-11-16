#!/usr/bin/env bats
#
# ## bootstrap.bats — unit coverage for scripts/lib/bootstrap.sh and the router
# render in scripts/lib/domain.sh
#
# Hermetic: curl is the stub. openssl and sed are the host tools, pointed at
# scratch files. The entry script is not executed here (it provisions certs
# and may build an image). The router render is pinned against the checked-in
# proxy/router.conf so the template and the shipped conf cannot drift apart.
# Usage: bazelisk test //tests:bats_bootstrap_test   (from any cwd)

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs curl
  cd "${BATS_TEST_TMPDIR}" || return 1
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/bootstrap.sh"
  [[ -f "${REPO_ROOT}/scripts/lib/domain.sh" ]] ||
    skip "scripts/lib/domain.sh is absent, so the router render cannot be exercised"
  # The naming parts come from the environment, so a shell that exported its .env must
  # not tilt a render: drop every part (and the two *_DEFAULT knobs) BEFORE domain.sh
  # is sourced, which puts its own shipped defaults back.
  unset STACK_DOMAIN_BASE STACK_SUBDOMAIN_SUFFIX STACK_ENV_LABEL STACK_DASHBOARD_NAME
  unset STACK_CODER_NAME STACK_KASM_NAME STACK_LITELLM_NAME STACK_HERMES_NAME
  unset STACK_GRAFANA_NAME STACK_INFISICAL_NAME
  unset STACK_DOMAIN_BASE_DEFAULT STACK_SUBDOMAIN_SUFFIX_DEFAULT
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/domain.sh"
}

# assert_router_vhost <file> <dns-name> - fail unless the rendered conf carries the
# exact `server_name <name>;` directive. Fixed string, semicolon included, so a block
# that merely ends with the name cannot satisfy it.
assert_router_vhost() {
  local file="$1" name="$2"
  if ! grep -Fq -- "server_name ${name};" "${file}"; then
    printf 'FAIL: %s has no "server_name %s;" directive\n' "${file}" "${name}" >&2
    return 1
  fi
}

# assert_no_router_vhost <file> <dns-name> - fail when the rendered conf does carry it.
assert_no_router_vhost() {
  local file="$1" name="$2"
  if grep -Fq -- "server_name ${name};" "${file}"; then
    printf 'FAIL: %s still holds "server_name %s;"\n' "${file}" "${name}" >&2
    return 1
  fi
}

@test "bootstrap: gen_secret prints 32 hex characters" {
  secret="$(gen_secret)"
  [[ "${secret}" =~ ^[0-9a-f]{32}$ ]]
}

@test "bootstrap: gen_secret_for mints each key in the shape its consumer requires" {
  # The asymmetry is the whole test. Infisical documents AUTH_SECRET as a 32-byte
  # base64 NextAuth secret; minting it like every other key yields an instance that
  # boots, signs users in, and then corrupts its own session tokens.
  local auth other raw err_out
  auth="$(gen_secret_for INFISICAL_AUTH_SECRET)"
  # Byte count of the raw stream, not of a captured copy: $( ) strips a trailing
  # newline and would hide one, and a newline that reaches the vault through
  # KEY=@file becomes part of the secret.
  raw="$(gen_secret_for INFISICAL_AUTH_SECRET | wc -c)"
  assert_eq "exactly 44 bytes and no trailing newline" "44" "${raw}"
  [ "${#auth}" -eq 44 ] || { echo "AUTH_SECRET is ${#auth} chars, expected 44" >&2; return 1; }
  [[ "${auth}" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "AUTH_SECRET is not base64: ${auth}" >&2; return 1; }

  other="$(gen_secret_for INFISICAL_ENCRYPTION_KEY)"
  [[ "${other}" =~ ^[0-9a-f]{32}$ ]] ||
    { echo "ENCRYPTION_KEY must stay 32 hex chars, got '${other}'" >&2; return 1; }

  other="$(gen_secret_for GRAFANA_ADMIN_PASSWORD)"
  [[ "${other}" =~ ^[0-9a-f]{32}$ ]] ||
    { echo "an unlisted key falls through to gen_secret" >&2; return 1; }

  # Two calls must not hand back the same credential.
  [ "$(gen_secret_for INFISICAL_AUTH_SECRET)" != "$(gen_secret_for INFISICAL_AUTH_SECRET)" ]

  # And the value must never reach a log: this is the shape both mint sites use, so a
  # printf of the value here is the leak the operator-facing CLIs rely on not existing.
  err_out="$(gen_secret_for INFISICAL_AUTH_SECRET 2>&1 1>/dev/null)"
  assert_eq "nothing is written to stderr" "" "${err_out}"
}

@test "bootstrap: sed_inplace rewrites a file in place" {
  printf 'A=1\n' > .env
  sed_inplace 's|^A=.*|A=2|' .env
  [ "$(cat .env)" = "A=2" ]
}

@test "bootstrap: set_secret replaces a placeholder and names the key" {
  printf 'CODER_PG_PASSWORD=change-me\n' > .env
  run --separate-stderr set_secret CODER_PG_PASSWORD
  [ "${status}" -eq 0 ]
  [ "${output}" = "generated CODER_PG_PASSWORD" ]
  value="$(sed -n 's|^CODER_PG_PASSWORD=||p' .env)"
  [[ "${value}" =~ ^[0-9a-f]{32}$ ]]
}

@test "bootstrap: GRAFANA_ADMIN_PASSWORD leaves the sample placeholder and is not rotated" {
  # The observability bundle's admin password ships as `change-me-grafana`, so a stack
  # that never rotated it signs every dashboard in with a value that is in the repo. The
  # entry script rotates it in the same guarded loop as the other managed secrets, so run
  # that guard here and pin the key's presence in the loop below.
  printf 'GRAFANA_ADMIN_PASSWORD=change-me-grafana\n' > .env
  if grep -q "^GRAFANA_ADMIN_PASSWORD=change-me" .env; then
    run set_secret GRAFANA_ADMIN_PASSWORD
  fi
  [ "${status}" -eq 0 ]
  [ "${output}" = "generated GRAFANA_ADMIN_PASSWORD" ]
  value="$(sed -n 's|^GRAFANA_ADMIN_PASSWORD=||p' .env)"
  [ -n "${value}" ]
  [ "${value}" != "change-me-grafana" ]
  [[ "${value}" =~ ^[0-9a-f]{32}$ ]]

  # A re-run must keep a working password: the running container holds the old value in
  # its environment, so a second rotation locks the operator out of the UI.
  output=""
  if grep -q "^GRAFANA_ADMIN_PASSWORD=change-me" .env; then
    run set_secret GRAFANA_ADMIN_PASSWORD
  fi
  [ -z "${output}" ]
  [ "$(sed -n 's|^GRAFANA_ADMIN_PASSWORD=||p' .env)" = "${value}" ]

  # The key has to reach both loops: the --check pass that reports a live placeholder,
  # and the full run that replaces it. Both now walk the one list the managed-key
  # inventory builds, so that is what pins the key here -- its membership lives in
  # infisical/managed-secrets.txt, which this target's runfiles do not carry.
  assert_contains_file "check pass walks the managed-key list" \
    "${REPO_ROOT}/scripts/bootstrap.sh" 'for probe_key in .*mint_keys'
  assert_contains_file "full run walks the managed-key list" \
    "${REPO_ROOT}/scripts/bootstrap.sh" 'for var in .*mint_keys'
}

@test "bootstrap: upsert_env appends, replaces, and stays quiet when equal" {
  printf 'K=old\n' > .env
  run upsert_env K new
  [ "${output}" = "set K=new" ]
  [ "$(sed -n 's|^K=||p' .env)" = "new" ]
  run upsert_env K new
  [ -z "${output}" ]
  run upsert_env OTHER v
  [ "${output}" = "set OTHER=v" ]
  grep -qx 'OTHER=v' .env
}

@test "bootstrap: STACK_DEPLOY_PATH is filled once and never rewritten" {
  # The pair scripts/bootstrap.sh runs for the assistant's deploy workspace. A path the
  # operator moved is operator state, so a value that is already set survives; a blank
  # or absent key takes the same default compose interpolates to.
  printf 'STACK_DEPLOY_PATH=\n' > .env
  deploy_path="$(env_get .env STACK_DEPLOY_PATH)"
  upsert_env STACK_DEPLOY_PATH "${deploy_path:-/opt/stack-deploy}" >/dev/null
  grep -qx 'STACK_DEPLOY_PATH=/opt/stack-deploy' .env

  printf 'STACK_DEPLOY_PATH=/srv/assistant-deploy\n' > .env
  deploy_path="$(env_get .env STACK_DEPLOY_PATH)"
  upsert_env STACK_DEPLOY_PATH "${deploy_path:-/opt/stack-deploy}" >/dev/null
  grep -qx 'STACK_DEPLOY_PATH=/srv/assistant-deploy' .env

  : > .env
  deploy_path="$(env_get .env STACK_DEPLOY_PATH)"
  upsert_env STACK_DEPLOY_PATH "${deploy_path:-/opt/stack-deploy}" >/dev/null
  grep -qx 'STACK_DEPLOY_PATH=/opt/stack-deploy' .env

  # The entry script runs exactly this pair, so the rule above is the rule it follows.
  # A rewrite that always refreshed would quietly move an operator's deploy directory.
  assert_contains_file "entry script reads before it writes" \
    "${REPO_ROOT}/scripts/bootstrap.sh" '^deploy_path="\$\(env_get \.env STACK_DEPLOY_PATH\)"'
  assert_contains_file "entry script keeps a path that is set" \
    "${REPO_ROOT}/scripts/bootstrap.sh" 'upsert_env STACK_DEPLOY_PATH .*deploy_path:-/opt/stack-deploy'
}

@test "bootstrap: probe_agent_endpoint warns on an empty URL and on silence" {
  run probe_agent_endpoint SPARK1_OPENAI_URL ""
  [ "${status}" -eq 0 ]
  [ "${output}" = "warning: SPARK1_OPENAI_URL is empty — the agent aliases cannot route." ]
  run probe_agent_endpoint SPARK1_OPENAI_URL "http://10.255.255.1:8888/v1"
  [[ "${output}" == warning:*10.255.255.1:8888* ]]
}

@test "bootstrap: probe_agent_endpoint reports a host that answers" {
  export STUB_CURL_OUT="ok"
  export STUB_CURL_RC=0
  run probe_agent_endpoint SPARK1_OPENAI_URL "http://10.0.0.9:8888/v1"
  [ "${output}" = "agent endpoint reachable: 10.0.0.9:8888" ]
}

@test "bootstrap: classify_public_entry sorts service names and rejects junk" {
  [ "$(classify_public_entry coder-box.example)" = "ok coder https://coder-box.example" ]
  [ "$(classify_public_entry kasm.example)" = "ok kasm https://kasm.example" ]
  [ "$(classify_public_entry litellm-box.example)" = "ok litellm https://litellm-box.example" ]
  [ "$(classify_public_entry hermes-box.example)" = "ok hermes https://hermes-box.example" ]
  [ "$(classify_public_entry hermes.example)" = "ok hermes https://hermes.example" ]
  [ "$(classify_public_entry infisical-box.example)" = "ok infisical https://infisical-box.example" ]
  [ "$(classify_public_entry infisical.example)" = "ok infisical https://infisical.example" ]
  [ "$(classify_public_entry box.example)" = "ok dashboard https://box.example" ]
  [ "$(classify_public_entry 'https://box.example')" = "skip url" ]
  [ "$(classify_public_entry 'bad_name')" = "skip dns" ]
}

@test "bootstrap: stack_host_path prefers BUILD_WORKSPACE_DIRECTORY over cwd" {
  mkdir -p "${BATS_TEST_TMPDIR}/checkout" "${BATS_TEST_TMPDIR}/runfiles"
  : >"${BATS_TEST_TMPDIR}/checkout/docker-compose.yml"
  BUILD_WORKSPACE_DIRECTORY="${BATS_TEST_TMPDIR}/checkout"
  cd "${BATS_TEST_TMPDIR}/runfiles"
  [ "$(stack_host_path)" = "$(cd "${BATS_TEST_TMPDIR}/checkout" && pwd -P)" ]
}

@test "bootstrap: stack_host_path falls back to the physical cwd" {
  unset BUILD_WORKSPACE_DIRECTORY || true
  mkdir -p "${BATS_TEST_TMPDIR}/here"
  cd "${BATS_TEST_TMPDIR}/here"
  [ "$(stack_host_path)" = "$(pwd -P)" ]
}

@test "bootstrap: stack_host_path uses git for a checkout named from a subdirectory" {
  # What the assistant's bind mount is named from when nobody runs under
  # bazelisk: a moved clone asked from scripts/ or a linked worktree still has
  # to answer with the checkout, or STACK_HOST_PATH records a subdirectory and
  # compose mounts that subdirectory at /opt/stack.
  unset BUILD_WORKSPACE_DIRECTORY || true
  local top="${BATS_TEST_TMPDIR}/clone"
  mkdir -p "${top}/scripts"
  : >"${top}/docker-compose.yml"
  ( cd "${top}" && git init -q . && git add -A )
  cd "${top}/scripts"
  [ "$(stack_host_path)" = "$(cd "${top}" && pwd -P)" ]
}

@test "bootstrap: stack_host_path ignores a git root that holds no compose file" {
  # A repo that is not the stack (a scratch clone, the operator's home under a
  # dotfiles repo) must not become the bind source: git answers, the marker
  # refuses it, and the caller keeps the physical cwd so bootstrap's own guard
  # can warn instead of mounting a directory with no compose project in it.
  # Standing in a subdirectory is what makes the answer observable: the cwd is
  # then a different path from the git root the function must decline.
  unset BUILD_WORKSPACE_DIRECTORY || true
  local top="${BATS_TEST_TMPDIR}/notstack"
  mkdir -p "${top}/sub"
  ( cd "${top}" && git init -q . )
  cd "${top}/sub"
  [ "$(stack_host_path)" = "$(cd "${top}/sub" && pwd -P)" ]
  run git rev-parse --show-toplevel
  [ "${status}" -eq 0 ]
}

@test "bootstrap: host_user_ids prints uid:gid" {
  [ "$(host_user_ids)" = "$(id -u):$(id -g)" ]
}

@test "bootstrap: dind_image_ref reads the terraform pin and falls back" {
  printf '  dind_image = "docker:29.8.1-dind"\n' > main.tf
  [ "$(dind_image_ref main.tf)" = "docker:29.8.1-dind" ]
  [ "$(dind_image_ref missing.tf)" = "docker:29.8.1-dind" ]
}

@test "bootstrap: warn_missing_router_hosts is silent for a served name" {
  printf '    server_name gmktecbeast.overeazy.io;\n' > router.conf
  run warn_missing_router_hosts router.conf gmktecbeast.overeazy.io
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "bootstrap: warn_missing_router_hosts warns once per unserved name" {
  printf '    server_name gmktecbeast.overeazy.io;\n' > router.conf
  run warn_missing_router_hosts router.conf coder-gmktecbeast.overeazy.io hermes-gmktecbeast.overeazy.io
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "warning:"*"coder-gmktecbeast.overeazy.io"* ]]
  [[ "${lines[1]}" == "warning:"*"hermes-gmktecbeast.overeazy.io"* ]]
}

@test "bootstrap: warn_missing_router_hosts will not match on a name suffix" {
  printf '    server_name coder-gmktecbeast.overeazy.io;\n' > router.conf
  run warn_missing_router_hosts router.conf gmktecbeast.overeazy.io coder-gmktecbeast.overeazy.io
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "warning:"*"gmktecbeast.overeazy.io is not a server_name"* ]]
  [[ "${lines[0]}" != *"coder-gmktecbeast.overeazy.io is not a server_name"* ]]
}

@test "bootstrap: warn_missing_router_hosts no-ops on a missing conf or no names" {
  run warn_missing_router_hosts no-such-router.conf gmktecbeast.overeazy.io
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  printf '    server_name gmktecbeast.overeazy.io;\n' > router.conf
  run warn_missing_router_hosts router.conf
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  run warn_missing_router_hosts
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "bootstrap: render_public_router_conf fills the seven vhosts from the shipped defaults" {
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" router.gen.conf
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -f router.gen.conf ]
  local names=(
    gmktecbeast.overeazy.io coder-gmktecbeast.overeazy.io
    kasm-gmktecbeast.overeazy.io litellm-gmktecbeast.overeazy.io
    hermes-gmktecbeast.overeazy.io grafana-gmktecbeast.overeazy.io
    infisical-gmktecbeast.overeazy.io
  )
  local name served
  for name in "${names[@]}"; do
    assert_router_vhost router.gen.conf "${name}"
  done
  # Presence alone cannot catch a vhost that joins the template without joining the list
  # above, so count the named directives too. The catch-all `server_name _;` is the only
  # one that names no host, so it is the one the count leaves out.
  served="$(grep -cE '^[[:space:]]*server_name [^_]' router.gen.conf)"
  if [ "${served}" -ne "${#names[@]}" ]; then
    printf 'FAIL: router.gen.conf serves %s named vhost(s) but this test lists %s:\n' \
      "${served}" "${#names[@]}" >&2
    grep -nE '^[[:space:]]*server_name ' router.gen.conf >&2
    return 1
  fi
}

@test "bootstrap: the checked-in router.conf is the template rendered with the shipped defaults" {
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" router.gen.conf
  [ "${status}" -eq 0 ]
  if ! cmp -s "${REPO_ROOT}/proxy/router.conf" router.gen.conf; then
    printf 'FAIL: proxy/router.conf has drifted from proxy/router.conf.template rendered with the shipped defaults.\n' >&2
    printf 'FAIL: keep the two byte-identical (rerun `bazelisk run //scripts:bootstrap`, or fix the template).\n' >&2
    diff -u "${REPO_ROOT}/proxy/router.conf" router.gen.conf | head -n 40 >&2
    return 1
  fi
}

@test "bootstrap: render_public_router_conf carries STACK_ENV_LABEL into the vhosts" {
  export STACK_ENV_LABEL=dev
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" router.dev.conf
  [ "${status}" -eq 0 ]
  [ -f router.dev.conf ]
  assert_router_vhost router.dev.conf coder-dev-gmktecbeast.overeazy.io
  assert_no_router_vhost router.dev.conf coder-gmktecbeast.overeazy.io
}

@test "bootstrap: render_public_router_conf refuses an unusable part and writes no file" {
  export STACK_DOMAIN_BASE='not a domain!'
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" router.refused.conf
  [ "${status}" -ne 0 ]
  printf '%s\n' "${output}" | grep -q '^warning:'
  local leftovers=()
  shopt -s nullglob
  leftovers=(router.refused.conf*)
  shopt -u nullglob
  [ "${#leftovers[@]}" -eq 0 ]
}

@test "bootstrap: render_public_router_conf warns and fails on a missing template" {
  run render_public_router_conf "${REPO_ROOT}/proxy/no-such-router.template" router.missing.conf
  [ "${status}" -ne 0 ]
  printf '%s\n' "${output}" | grep -q '^warning:'
  printf '%s\n' "${output}" | grep -q 'no-such-router\.template'
  [ ! -e router.missing.conf ]
}

@test "bootstrap: warn_missing_router_hosts checks the rendered router conf" {
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" router.gen.conf
  [ "${status}" -eq 0 ]
  run warn_missing_router_hosts router.gen.conf gmktecbeast.overeazy.io coder-gmktecbeast.overeazy.io \
    grafana-gmktecbeast.overeazy.io
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  run warn_missing_router_hosts router.gen.conf coder-dev-gmktecbeast.overeazy.io
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  printf '%s\n' "${lines[0]}" |
    grep -q '^warning: coder-dev-gmktecbeast\.overeazy\.io is not a server_name in router\.gen\.conf'
}

@test "bootstrap: classify_public_entry routes a labelled name to its service" {
  local name
  name=coder-dev-gmktecbeast.overeazy.io
  [ "$(classify_public_entry "${name}")" = "ok coder https://${name}" ]
  name=hermes-dev-gmktecbeast.overeazy.io
  [ "$(classify_public_entry "${name}")" = "ok hermes https://${name}" ]
}

@test "bootstrap: classify_public_entry routes a grafana name to the grafana role" {
  # The role is what decides which STACK_*_URL an entry fills. Without the grafana case
  # the name falls through to the dashboard branch and, since it is last in the composed
  # list, it would overwrite STACK_DASHBOARD_URL with the observability UI's origin.
  local name
  name=grafana-gmktecbeast.overeazy.io
  [ "$(classify_public_entry "${name}")" = "ok grafana https://${name}" ]
  name=grafana-dev-gmktecbeast.overeazy.io
  [ "$(classify_public_entry "${name}")" = "ok grafana https://${name}" ]
  name=grafana.overeazy.io
  [ "$(classify_public_entry "${name}")" = "ok grafana https://${name}" ]
}

@test "bootstrap: the entry script routes and upserts the grafana origin" {
  # The router vhost, the cert SAN and the dashboard card all hang off these two lines in
  # scripts/bootstrap.sh. A rename or a rebase that drops either one leaves STACK_GRAFANA_URL
  # empty forever and nothing else fails, so pin the pair here rather than trust the run.
  assert_contains_file "entry script routes the grafana role" \
    "${REPO_ROOT}/scripts/bootstrap.sh" 'grafana\) public_grafana_url='
  assert_contains_file "entry script upserts the grafana origin" \
    "${REPO_ROOT}/scripts/bootstrap.sh" 'upsert_env STACK_GRAFANA_URL "\${public_grafana_url}"'
}

# --- resolve_auto_public_hosts: the STACK_PUBLIC_HOSTS=auto path --------------
#
# This is the half of bootstrap that decides what the box serves publicly, and it is
# pure environment work: no daemon, no openssl, no writes. It takes the env file as an
# argument, so a scratch file with any name drives it. Each case runs in a subshell
# because the part lift exports into the caller on purpose, and one test's lifted parts
# must not become the next test's defaults.

resolve_public_case() {
  local content="$1" process_label="${2:-}" envf="${BATS_TEST_TMPDIR}/stackenv"
  printf '%s' "${content}" >"${envf}"
  (
    set -uo pipefail
    # The keys go first: domain.sh fills any part it finds unset with its shipped
    # default at source time, so unsetting afterwards would erase those defaults.
    unset STACK_DOMAIN_BASE STACK_SUBDOMAIN_SUFFIX STACK_ENV_LABEL STACK_DASHBOARD_NAME
    unset STACK_CODER_NAME STACK_KASM_NAME STACK_LITELLM_NAME STACK_HERMES_NAME
    unset STACK_GRAFANA_NAME STACK_INFISICAL_NAME
    unset STACK_DOMAIN_BASE_DEFAULT STACK_SUBDOMAIN_SUFFIX_DEFAULT
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/lib/common.sh"
    unset JSON_MODE
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/lib/bootstrap.sh"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/lib/domain.sh"
    if [ -n "${process_label}" ]; then
      export STACK_ENV_LABEL="${process_label}"
    fi
    file_public_hosts=""
    raw_public_hosts=""
    public_hosts_mode=""
    public_hosts_are_auto=0
    resolve_auto_public_hosts "${envf}"
    printf 'raw=%s\n' "${raw_public_hosts}"
    printf 'mode=%s\n' "${public_hosts_mode}"
    printf 'auto=%s\n' "${public_hosts_are_auto}"
    printf 'file=%s\n' "${file_public_hosts}"
    printf 'coder_name=%s\n' "${STACK_CODER_NAME-<unset>}"
    printf 'grafana_name=%s\n' "${STACK_GRAFANA_NAME-<unset>}"
    printf 'label=%s\n' "${STACK_ENV_LABEL-<unset>}"
  )
}

@test "bootstrap: auto resolves the six names from the parts in the file" {
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
STACK_ENV_LABEL=dev
'
  [ "${status}" -eq 0 ]
  assert_match "the label rides every service name" 'raw=.*coder-dev-gmktecbeast\.overeazy\.io' "${output}"
  assert_match "the dashboard carries it too" '^raw=dev-gmktecbeast\.overeazy\.io,' "${output}"
  assert_match "the observability UI is one of the names" 'raw=.*grafana-dev-gmktecbeast\.overeazy\.io' "${output}"
  assert_match "the mode is recorded" '^mode=auto$' "${output}"
  assert_match "the caller is told it composed" '^auto=1$' "${output}"
  assert_match "the label reached the environment" '^label=dev$' "${output}"
}

@test "bootstrap: the mode key alone turns composition on" {
  # The bookkeeping key is what makes a later run re-derive, so it has to work as the
  # only signal, and it has to beat a list that is still sitting in the file.
  run resolve_public_case 'STACK_PUBLIC_HOSTS=gmktecbeast.overeazy.io,coder-gmktecbeast.overeazy.io
STACK_PUBLIC_HOSTS_MODE=auto
STACK_SUBDOMAIN_SUFFIX=beastbox
'
  [ "${status}" -eq 0 ]
  assert_match "the edited suffix wins" 'raw=.*coder-beastbox\.overeazy\.io' "${output}"
  assert_not_match "the stale list is gone" 'raw=.*coder-gmktecbeast\.overeazy\.io' "${output}"
  assert_match "it says the list was ignored" 'note:.*STACK_PUBLIC_HOSTS_MODE' "${output}"
}

@test "bootstrap: no sentinel leaves the file's list exactly as it was" {
  run resolve_public_case 'STACK_PUBLIC_HOSTS=coder-pin.example.com
'
  [ "${status}" -eq 0 ]
  assert_match "the list passes through" 'raw=coder-pin\.example\.com$' "${output}"
  assert_match "not an auto run" '^auto=0$' "${output}"
  assert_match "no mode invented" '^mode=$' "${output}"
  assert_not_match "no composed name leaks in" 'gmktecbeast' "${output}"
}

@test "bootstrap: an env file with no switch composes nothing" {
  run resolve_public_case 'STACK_LAN_HOST=192.0.2.9
'
  [ "${status}" -eq 0 ]
  assert_match "nothing resolved" '^raw=$' "${output}"
  assert_match "stays LAN-only" '^auto=0$' "${output}"
}

@test "bootstrap: the sentinel never survives into the resolved list" {
  # compose appends the raw value to HOMEPAGE_ALLOWED_HOSTS, so a literal "auto" there
  # would answer no Host at all.
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
'
  [ "${status}" -eq 0 ]
  assert_not_match "no literal auto in the list" '^raw=auto$' "${output}"
  assert_match "real names instead" '^raw=gmktecbeast\.overeazy\.io,coder-gmktecbeast' "${output}"
}

@test "bootstrap: a part that cannot be a DNS label keeps the run LAN-only and names it" {
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
STACK_DOMAIN_BASE=not a domain!
'
  [ "${status}" -eq 0 ]
  assert_match "it warns rather than failing" 'warning:' "${output}"
  assert_match "and names the key to fix" 'STACK_DOMAIN_BASE' "${output}"
  assert_match "nothing resolved" '^raw=$' "${output}"
  assert_match "the mode is cleared so it stops trying" '^mode=$' "${output}"
  assert_match "not an auto run" '^auto=0$' "${output}"
}

@test "bootstrap: a label the shell carries survives an empty key in the file" {
  # How an operator tries a label for one run: export it and leave the file alone.
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
STACK_ENV_LABEL=
' green
  [ "${status}" -eq 0 ]
  assert_match "the shell value is kept" '^label=green$' "${output}"
  assert_match "and it lands in the names" 'raw=.*coder-green-gmktecbeast\.overeazy\.io' "${output}"
}

@test "bootstrap: the parts the file carries reach the environment" {
  # lib/domain.sh reads the process environment only, so a renamed service has to be
  # lifted out of the file or the composition would answer for the shipped prefix.
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
STACK_CODER_NAME=coderctl
'
  [ "${status}" -eq 0 ]
  assert_match "the file's prefix was lifted" '^coder_name=coderctl$' "${output}"
  assert_match "and composed with it" 'raw=.*coderctl-gmktecbeast\.overeazy\.io' "${output}"
  assert_not_match "the shipped prefix is not used" 'raw=.*[^a-z]coder-gmktecbeast' "${output}"
}

@test "bootstrap: a grafana prefix the file carries is lifted and composed" {
  # Same rule as the other parts, and the same failure if it is broken: lib/domain.sh
  # reads only the process environment, so a renamed observability UI has to be lifted
  # out of the file or the router vhost and the card href keep answering `grafana-`.
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
STACK_GRAFANA_NAME=boards
'
  [ "${status}" -eq 0 ]
  assert_match "the file's prefix was lifted" 'raw=.*boards-gmktecbeast\.overeazy\.io' "${output}"
  assert_match "and it reached the environment" '^grafana_name=boards$' "${output}"
  assert_not_match "the shipped prefix is not used" 'raw=.*grafana-gmktecbeast' "${output}"
}

@test "bootstrap: STACK_GRAFANA_NAME is read wherever its sibling naming keys are" {
  # Every consumer of the naming parts keeps its own fixed key list, so a key that joins
  # one list and not the next composes for one caller and stays the shipped prefix for
  # another: the router would answer boards-... while the deploy exported grafana-...
  # Each of the three lists below names the five sibling parts, so the grafana key has to
  # appear exactly as often as the hermes key does in the file that holds the loop.
  local holder hermes grafana
  for holder in "${REPO_ROOT}/scripts/lib/bootstrap.sh" "${REPO_ROOT}/scripts/dev-stack.sh" \
    "${REPO_ROOT}/scripts/prod-stack.sh"; do
    assert_file_exists "the naming loop lives in a file that exists" "${holder}"
    hermes="$(grep -c 'STACK_HERMES_NAME' "${holder}" || true)"
    grafana="$(grep -c 'STACK_GRAFANA_NAME' "${holder}" || true)"
    if [ "${hermes}" -ne "${grafana}" ]; then
      printf 'FAIL: %s lists STACK_HERMES_NAME %s time(s) but STACK_GRAFANA_NAME %s time(s):\n  that file never lifts the observability prefix\n' \
        "${holder#"${REPO_ROOT}/"}" "${hermes}" "${grafana}" >&2
      grep -n 'STACK_[A-Z]*_NAME' "${holder}" >&2
      return 1
    fi
  done
}

@test "bootstrap: the mint list comes from the inventory, not a literal in the script" {
  local script="${REPO_ROOT}/scripts/bootstrap.sh"
  assert_file_exists "the entry script exists" "${script}"
  if ! grep -q 'infisical_managed_keys' "${script}"; then
    printf 'FAIL: scripts/bootstrap.sh never reads the managed-key inventory,\n' >&2
    printf 'FAIL: so the key list is hand-written there again\n' >&2
    grep -n 'CODER_PG_PASSWORD' "${script}" >&2
    return 1
  fi
  # The two sites that used to each carry the 8-key literal on one line.
  if grep -nE 'for (probe_key|var) in CODER_PG_PASSWORD' "${script}" >&2; then
    printf 'FAIL: scripts/bootstrap.sh still hand-writes the managed-key list above\n' >&2
    return 1
  fi
  # Sourcing the lib is what makes the seam callable from the entry script.
  if ! grep -q 'source "scripts/lib/infisical.sh"' "${script}"; then
    printf 'FAIL: scripts/bootstrap.sh does not source scripts/lib/infisical.sh\n' >&2
    return 1
  fi
}

@test "bootstrap: both secret loops walk the whole mint list" {
  # The list is built once from the inventory and shared by the --check probe and the
  # mint, so a loop that keeps its own subset is how a key gets reported but never
  # minted, or the other way round. The empty-list guard matters for the same reason:
  # an unreadable inventory would otherwise mint nothing and say nothing.
  local script="${REPO_ROOT}/scripts/bootstrap.sh"
  local -a loops=(
    'for probe_key in "${mint_keys[@]}"; do'
    'for var in "${mint_keys[@]}"; do'
    'die "bootstrap: infisical/managed-secrets.txt yielded no managed key'
  )
  local line
  for line in "${loops[@]}"; do
    if ! grep -Fq -- "${line}" "${script}"; then
      printf 'FAIL: scripts/bootstrap.sh is missing:\n  %s\n' "${line}" >&2
      return 1
    fi
  done
}

@test "bootstrap: the four vault-own keys are minted outside the inventory" {
  # The vault cannot hand out its own credentials, so these four are not in
  # infisical/managed-secrets.txt; they join the mint list in the script itself and are
  # minted locally whichever way the flag sits.
  local script="${REPO_ROOT}/scripts/bootstrap.sh" key
  local vault_keys=(
    INFISICAL_DB_PASSWORD INFISICAL_ENCRYPTION_KEY
    INFISICAL_AUTH_SECRET INFISICAL_ADMIN_PASSWORD
  )
  for key in "${vault_keys[@]}"; do
    if ! grep -Fq "${key}" "${script}"; then
      printf 'FAIL: scripts/bootstrap.sh never names %s, so nothing mints it\n' "${key}" >&2
      return 1
    fi
  done
}

@test "bootstrap: the mint writes .env only after Infisical accepted the value" {
  local script="${REPO_ROOT}/scripts/bootstrap.sh" set_line write_line
  if ! grep -q 'infisical_enabled' "${script}"; then
    printf 'FAIL: scripts/bootstrap.sh mints without reading the vault flag\n' >&2
    return 1
  fi
  set_line="$(grep -nF 'infisical_secret_set "${var}"' "${script}" | head -n 1 | cut -d: -f1)"
  write_line="$(grep -nF 'sed_inplace "s|^${var}=' "${script}" | head -n 1 | cut -d: -f1)"
  if [ -z "${set_line}" ] || [ -z "${write_line}" ]; then
    printf 'FAIL: scripts/bootstrap.sh lost the vault write or the .env write (%s/%s)\n' \
      "${set_line:-none}" "${write_line:-none}" >&2
    return 1
  fi
  if [ "${write_line}" -lt "${set_line}" ]; then
    printf 'FAIL: .env is written at line %s, before the vault at line %s\n' \
      "${write_line}" "${set_line}" >&2
    return 1
  fi
}
