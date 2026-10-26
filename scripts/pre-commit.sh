#!/usr/bin/env bash
#
# ## pre-commit.sh — the gate a commit or a push has to clear
#
# This is the check the .githooks call, and the check to run by hand before
# opening a pull request. It exists because the three commands a contributor is
# supposed to run were prose in the docs and nothing else: a red tree could
# reach GitHub as easily as a green one.
#
# Three depths, so the expensive part is only paid where it earns its keep:
#   default   hermetic: //:test-fast, //:lint, the compose file, the env samples.
#             No network, no node_modules. This is what pre-commit runs.
#   --all     adds //:test-all: the npm-backed docs gates and the measured
#             coverage targets. Needs node_modules (the npm runner installs on
#             demand) and network for the first install. This is what pre-push
#             runs, and what a PR should be green on before it is opened.
#   --image   the same full set inside evo-t1-dev:latest through
#             scripts/test-in-image.sh, which is how CI answers the question.
#             Needs docker.
#
# A failure here is a fact about the tree, not a suggestion. git's own
# --no-verify remains the only way around it.
#
# Usage:
#   bazelisk run //scripts:pre-commit
#   bazelisk run //scripts:pre-commit -- --all
#   bazelisk run //scripts:pre-commit -- --image
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

# The compose file, the env samples and the docs-site tree are all read from the
# checkout, and `bazelisk run` executes from runfiles, so resolve it first.
ROOT_DIR="$(resolve_checkout "${SELF_DIR}")" || exit 5
cd "${ROOT_DIR}"

# @function bazel_ingress
# Print the Bazel command to use, preferring bazelisk.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The command name on stdout
# Returns:
#   0 when one is on PATH, 1 otherwise
bazel_ingress() {
  local candidate
  for candidate in bazelisk bazel; do
    if has_tool "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

# @function run_hermetic_gate
# Run the checks that need no network and no installed toolchain.
# Globals:
#   ROOT_DIR
# Arguments:
#   None
# Outputs:
#   Phase lines and tool output on stdout
# Returns:
#   0 when every check passes, 1 on the first failure
run_hermetic_gate() {
  local bazel rc=0
  bazel="$(bazel_ingress)" || {
    err "neither bazelisk nor bazel is on PATH; the gate cannot be run"
    note "on the stack host: scripts/setup-host.sh installs bazelisk"
    return 1
  }
  section "Hermetic gate"
  phase "${bazel} test //:test-fast //:lint --test_tag_filters=manual"
  "${bazel}" test //:test-fast //:lint --test_tag_filters=manual || rc=1
  phase "cmp .env.sample .env.example"
  cmp .env.sample .env.example || rc=1
  if has_tool docker; then
    phase "docker compose config -q"
    docker compose config -q || rc=1
  else
    note "docker is not on PATH; skipping the compose config check"
  fi
  return "${rc}"
}

# @function run_full_gate
# Add the npm-backed docs gates and the measured coverage targets.
# Globals:
#   ROOT_DIR
# Arguments:
#   None
# Outputs:
#   Phase lines and tool output on stdout
# Returns:
#   0 when every check passes, 1 on the first failure
run_full_gate() {
  local bazel
  bazel="$(bazel_ingress)" || return 1
  section "Full gate"
  phase "${bazel} test //:test-all"
  # //:test-all is manual-tagged, which is why it is named rather than reached
  # through a wildcard: bazelisk test //... keeps its meaning.
  "${bazel}" test //:test-all || return 1
  return 0
}

# @function run_image_gate
# Run the full set inside the golden image, the way CI does.
# Globals:
#   ROOT_DIR
# Arguments:
#   None
# Outputs:
#   Phase lines and tool output on stdout
# Returns:
#   0 when every check passes, 1 on the first failure
run_image_gate() {
  local bazel
  bazel="$(bazel_ingress)" || return 1
  section "Golden-image gate"
  if ! has_tool docker; then
    err "docker is not on PATH; --image runs the gate inside evo-t1-dev:latest"
    return 1
  fi
  phase "scripts/test-in-image.sh -- test //:test-all"
  "${bazel}" run //scripts:test-in-image -- -- test //:test-all || return 1
  return 0
}

# @function main
# Pick a depth and run it.
# Globals:
#   ROOT_DIR
# Arguments:
#   "$@" - optional --all or --image
# Outputs:
#   Operator CLI report on stdout
# Returns:
#   0 when the tree is green, 1 otherwise
main() {
  local mode="${1:-}" rc=0
  case "${mode}" in
    --all)
      run_hermetic_gate || rc=1
      run_full_gate || rc=1
      ;;
    --image)
      run_hermetic_gate || rc=1
      run_image_gate || rc=1
      ;;
    "")
      run_hermetic_gate || rc=1
      ;;
    *)
      die "unknown mode '${mode}' (expected --all or --image)"
      ;;
  esac
  if [[ ${rc} -ne 0 ]]; then
    fail_item "the gate failed"
    summary
    return 1
  fi
  ok "gate passed"
  summary
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
