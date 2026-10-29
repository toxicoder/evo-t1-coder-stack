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

@test "bootstrap: render_public_router_conf fills the five vhosts from the shipped defaults" {
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" router.gen.conf
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ -f router.gen.conf ]
  local name
  for name in gmktecbeast.overeazy.io coder-gmktecbeast.overeazy.io \
    kasm-gmktecbeast.overeazy.io litellm-gmktecbeast.overeazy.io \
    hermes-gmktecbeast.overeazy.io; do
    assert_router_vhost router.gen.conf "${name}"
  done
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
  run warn_missing_router_hosts router.gen.conf gmktecbeast.overeazy.io coder-gmktecbeast.overeazy.io
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
    printf 'label=%s\n' "${STACK_ENV_LABEL-<unset>}"
  )
}

@test "bootstrap: auto resolves the five names from the parts in the file" {
  run resolve_public_case 'STACK_PUBLIC_HOSTS=auto
STACK_ENV_LABEL=dev
'
  [ "${status}" -eq 0 ]
  assert_match "the label rides every service name" 'raw=.*coder-dev-gmktecbeast\.overeazy\.io' "${output}"
  assert_match "the dashboard carries it too" '^raw=dev-gmktecbeast\.overeazy\.io,' "${output}"
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
