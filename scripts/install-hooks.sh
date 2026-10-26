#!/usr/bin/env bash
#
# ## install-hooks.sh — point this checkout's git hooks at .githooks
#
# The repo ships its own hooks under .githooks: pre-commit runs the hermetic
# gate (//:test-fast and //:lint) and pre-push runs the full set (//:test-all,
# which adds the npm docs gates and the measured coverage targets). Git only
# reads them once the checkout is told where they live, which is the one line of
# machine-local state this CLI sets.
#
# Nothing installs it silently: an unrequested hook that runs minutes of tests
# belongs behind an explicit command. The contributor dev container runs it from
# scripts/seed-dev-env.sh, so a container gets it at postCreate.
#
# Usage:
#   bazelisk run //scripts:install-hooks            # install
#   bazelisk run //scripts:install-hooks -- --check # exit 1 when not installed
#   bazelisk run //scripts:install-hooks -- --uninstall
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

# The hooks and the .githooks directory are read from the checkout, and
# `bazelisk run` executes from runfiles, so the checkout has to be resolved
# before anything is read or written.
ROOT_DIR="$(resolve_checkout "${SELF_DIR}")" || exit 5
cd "${ROOT_DIR}"

# @function hook_state
# Report whether this checkout's core.hooksPath points at .githooks.
# Globals:
#   ROOT_DIR
# Arguments:
#   None
# Outputs:
#   installed, missing, or foreign on stdout
# Returns:
#   0 always; the caller decides what the value means
hook_state() {
  local configured
  configured="$(git -C "${ROOT_DIR}" config --get core.hooksPath 2>/dev/null || true)"
  case "${configured}" in
    .githooks) printf 'installed\n' ;;
    "") printf 'missing\n' ;;
    *) printf 'foreign (%s)\n' "${configured}" ;;
  esac
}

# @function require_hooks_dir
# Fail when the shipped hooks are not in the tree.
# Globals:
#   ROOT_DIR
# Arguments:
#   None
# Outputs:
#   An error line on stderr
# Returns:
#   0 when both hooks are present, 1 otherwise
require_hooks_dir() {
  local hook
  for hook in pre-commit pre-push; do
    if [[ ! -f ${ROOT_DIR}/.githooks/${hook} ]]; then
      err ".githooks/${hook} is missing from ${ROOT_DIR}"
      note "the hooks ship with the repo; a partial checkout cannot install them"
      return 1
    fi
  done
  return 0
}

# @function main
# Install, check, or remove the hooksPath setting.
# Globals:
#   ROOT_DIR
# Arguments:
#   $1 - optional --check or --uninstall
# Outputs:
#   Operator CLI report on stdout
# Returns:
#   0 on success; 1 on a failed check or a broken checkout
main() {
  local mode="${1:-install}" state
  section "Git hooks"
  require_tool git || die "git is not on PATH"
  if [[ ! -d ${ROOT_DIR}/.git ]]; then
    die "$(printf '%s is not a git checkout, so it has no hooks to install' "${ROOT_DIR}")"
  fi
  require_hooks_dir || return 1

  case "${mode}" in
    install)
      # git skips a hook it cannot execute, and a checkout made through GitHub's
      # contents API carries every blob as 100644, so the mode bit is set here
      # rather than trusted to the archive.
      phase "chmod +x .githooks/pre-commit .githooks/pre-push"
      chmod 755 "${ROOT_DIR}/.githooks/pre-commit" "${ROOT_DIR}/.githooks/pre-push"
      phase "git config core.hooksPath .githooks"
      git -C "${ROOT_DIR}" config core.hooksPath .githooks
      state="$(hook_state)"
      if [[ ${state} != installed ]]; then
        die "core.hooksPath did not take (${state})"
      fi
      ok "hooks installed in ${ROOT_DIR}"
      note "pre-commit runs the hermetic gate; pre-push runs //:test-all"
      note "git push --no-verify stays the deliberate escape hatch"
      ;;
    --check)
      phase "checking core.hooksPath"
      state="$(hook_state)"
      log "state: ${state}"
      if [[ ${state} != installed ]]; then
        fail_item "hooks not installed"
        summary
        return 1
      fi
      ok "hooks installed"
      ;;
    --uninstall)
      phase "git config --unset core.hooksPath"
      git -C "${ROOT_DIR}" config --unset core.hooksPath || true
      ok "hooks unset for ${ROOT_DIR}"
      ;;
    *)
      die "unknown mode '${mode}' (expected --check or --uninstall)"
      ;;
  esac
  summary
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
