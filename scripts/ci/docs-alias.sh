#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## docs-alias.sh — GitHub Pages URL segment for one git ref.
#
# main and master publish as /latest/. Every other ref collapses to a single
# URL-safe segment (feat/foo -> feat-foo). An empty result or a segment that
# contains ".." is refused: either would name nothing or escape the alias
# directory.
#
# Usage:
#   ./scripts/ci/docs-alias.sh "${GITHUB_REF_NAME}"

set -euo pipefail

# shellcheck source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would send the alias to
# stderr and leave stdout empty for the workflow that captures it.
unset JSON_MODE

# @function docs_alias
# Print a GitHub Pages URL segment for one git ref name.
# Globals:
#   None (uses err from common)
# Arguments:
#   $1 - git ref name (GITHUB_REF_NAME)
# Outputs:
#   The alias on stdout
# Returns:
#   0, or 1 when the sanitized alias is empty or contains ..
docs_alias() {
  local ref="${1:-}"
  local alias=""
  case "${ref}" in
    main | master) alias="latest" ;;
    *)
      alias="$(printf '%s' "${ref}" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
      ;;
  esac
  if [[ -z ${alias} || ${alias} == *..* ]]; then
    err "deploy-docs: ref ${ref} sanitizes to an unusable alias"
    return 1
  fi
  printf '%s\n' "${alias}"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  docs_alias "${1:-}"
fi
