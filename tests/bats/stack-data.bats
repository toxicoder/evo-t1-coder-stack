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
# generated files come from the checkout. The coder service also pins public
# DNS upstreams so terraform init does not depend on host MagicDNS.
#
# Usage: bazelisk test //tests:bats_stack_data_test   (from any cwd)
# Safety: reads docker-compose.yml and the payload tree; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
COMPOSE=""

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
  done < <(sed -n 's|^[[:space:]]*- \(\./[^:]*\):.*|\1|p' "${COMPOSE}")
  [[ "${checked}" -gt 0 ]] || skip "no relative compose bind mounts in ${COMPOSE}"
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
