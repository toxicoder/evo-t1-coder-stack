#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## stack-data.bats — committed compose bind-mount sources travel in runfiles.
#
# docker-compose.yml bind-mounts `./homepage/...` and `./proxy/*.conf` relative
# to the compose file. Under `bazelisk run` that file lives in the target's
# runfiles copy, which only holds what `//:stack_data` lists. A missing source
# makes Docker create a directory at that path and then fail mounting it onto
# a file in the nginx image (`homepage.conf` -> `/etc/nginx/conf.d/default.conf`).
# `proxy/certs/` is bazelignored (bootstrap issues those on the host) and is
# skipped here: the stack runners prefer BUILD_WORKSPACE_DIRECTORY so those
# generated files come from the checkout. The router mount carries a compose
# interpolation (`./proxy/${STACK_ROUTER_CONF:-router.conf}`), so a source is checked
# at the path compose falls back to when the variable is unset (the checked-in conf)
# rather than at a literal path holding `${`; see resolve_compose_default below. The
# coder service also pins public DNS upstreams so terraform init does not depend on
# host MagicDNS.
#
# Usage: bazelisk test //tests:bats_stack_data_test   (from any cwd)
# Safety: reads docker-compose.yml and the payload tree; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
COMPOSE=""

# resolve_compose_default - stdin filter that replaces every `${VAR:-default}` with
# <default>, which is the value compose itself mounts when VAR is unset. Only the `:-`
# default form resolves; a bare `${VAR}` has no default to fall back to and is passed
# through so the existence check reports the path it really cannot satisfy.
resolve_compose_default() {
  sed -E 's/[$][{][A-Za-z_][A-Za-z0-9_]*:-([^{}]*)[}]/\1/g'
}

# compose_bind_sources <compose-file> - print the relative host paths to check in
# runfiles: every bind source, interpolations resolved. The resolve runs BEFORE the
# split on the host/container colon, because the default in
# `${STACK_ROUTER_CONF:-router.conf}` carries the very colon that would otherwise cut
# the host side short.
compose_bind_sources() {
  resolve_compose_default <"${1}" |
    sed -n 's|^[[:space:]]*- \(\./[^:]*\):.*|\1|p'
}

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  COMPOSE="${REPO_ROOT}/docker-compose.yml"
  [[ -f "${COMPOSE}" ]] || skip "docker-compose.yml is not reachable from ${REPO_ROOT}"
}

@test "stack_data: committed compose bind-mount sources exist beside docker-compose.yml" {
  local src rel host base checked=0
  while IFS= read -r src; do
    rel="${src#./}"
    case "${rel}" in
      proxy/certs | proxy/certs/*) continue ;;
    esac
    host="${REPO_ROOT}/${rel}"
    base="${rel##*/}"
    if [[ "${base}" == *.* ]]; then
      assert_file_exists "compose bind source ${src}" "${host}"
    else
      if [ ! -d "${host}" ]; then
        printf 'FAIL: compose bind source %s: missing directory: %s\n' "${src}" "${host}" >&2
        return 1
      fi
    fi
    checked=$((checked + 1))
  done < <(compose_bind_sources "${COMPOSE}")
  [[ "${checked}" -gt 0 ]] || skip "no relative compose bind mounts in ${COMPOSE}"
}

@test "stack_data: the router bind source resolves its compose default to the checked-in conf" {
  local mount resolved
  mount="$(grep -oE '\./proxy/\$\{STACK_ROUTER_CONF:-[^}]*\}' "${COMPOSE}" | head -n 1)"
  if [ -z "${mount}" ]; then
    printf 'FAIL: %s has no ./proxy/${STACK_ROUTER_CONF:-router.conf} router bind mount\n' "${COMPOSE}" >&2
    return 1
  fi
  resolved="$(printf '%s\n' "${mount}" | resolve_compose_default)"
  if [ "${resolved}" != "./proxy/router.conf" ]; then
    printf 'FAIL: router bind source %s resolved to %s, not ./proxy/router.conf\n' "${mount}" "${resolved}" >&2
    return 1
  fi
  if printf '%s\n' "${resolved}" | grep -qF -- '${'; then
    printf 'FAIL: resolved router bind source %s still holds a compose interpolation\n' "${resolved}" >&2
    return 1
  fi
  compose_bind_sources "${COMPOSE}" | grep -qxF './proxy/router.conf'
  assert_file_exists "the router conf compose mounts by default" "${REPO_ROOT}/proxy/router.conf"
}

@test "stack_data: coder forwards public DNS so terraform init does not depend on MagicDNS" {
  local block
  block="$(awk '
    /^  coder:[[:space:]]*$/ { p=1 }
    p && /^  [a-z0-9_-]+:/ && !/^  coder:/ { exit }
    p { print }
  ' "${COMPOSE}")"
  assert_match "dns key" '^    dns:' "${block}"
  assert_match "cloudflare resolver" '1\.1\.1\.1' "${block}"
  assert_match "google resolver" '8\.8\.8\.8' "${block}"
  assert_match "the terraform symptom is named" 'registry\.terraform\.io' "${block}"
  assert_not_match "MagicDNS is not a dns list entry" \
    '^[[:space:]]+- ["'"'"']?100\.100\.100\.100' "${block}"
}
