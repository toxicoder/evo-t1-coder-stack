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
# generated files come from the checkout.
#
# Usage: bats tests/bats/stack-data.bats
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
