#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## update-stack.sh - pull the latest stack code and deploy it, in one step.
#
# The README sequence "After a git pull" is four commands that have to run in a
# particular order, and the order is what makes them work: the env file has to
# be current before the templates are pushed (the templates read their wiring
# out of the live .env), the env file has to be current before the containers
# are recreated (compose interpolates ${VAR} at parse time, so a stale value
# publishes the wrong port), and the workspaces have to be reseeded last, from
# the tree that is now actually deployed. Running them by hand is how a stack
# ends up serving a config it no longer has. This script runs them in that
# order, in one target:
#
#   1. fast-forward the checkout            (git pull --ff-only)
#   2. re-enter the updated checkout        (so the rest runs the new logic)
#   3. recover the host for Bazel and DNS   (setup-host.sh --repair)
#   4. reconcile the env files              (update-configs.sh env)
#   5. converge the compose project         (compose up, after a down when
#                                            compose or the env file changed)
#   6. restart what a bind mount changed    (compose restart <services>)
#   7. push the Coder templates             (push-template.sh)
#   8. reseed the running workspaces        (refresh-configs.sh)
#   9. print the stack status               (<flavour>-stack.sh status)
#
# Step 6 is the one no other tool here does. `compose up -d` recreates a
# container only when its config hash changes, and editing litellm/config.yaml
# or homepage/config/services.yaml changes the file behind an unchanged mount,
# so `up -d` reports success and keeps the old process. This script looks at
# which files the pull actually touched and restarts exactly those services.
#
# What this script never does:
#   - destroy data. It stops containers with `down` (which keeps every volume)
#     and never reaches the volume-destroying `reset` subcommand at all;
#   - rewrite history or overwrite local work. The pull is `--ff-only`, and a
#     dirty working tree, a detached HEAD, or a branch that cannot
#     fast-forward is refused with the git output quoted. --allow-dirty is the
#     only way past the tree check, and it means "I know, deploy it anyway";
#   - upgrade images behind your back. Pinned tags are applied by `up`, and
#     the mutable `:latest` tags are only pulled when --pull-images says so;
#   - prompt. Every step runs non-interactively, so it is safe from CI and
#     from an agent shell;
#   - force a reseed over files an operator edited. --force is never passed.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:update-stack
#   bazelisk run //scripts:update-stack -- --dry-run
#   bazelisk run //scripts:update-stack -- --stack dev
#   bazelisk run //scripts:update-stack -- --restart
#   bazelisk run //scripts:update-stack -- --skip-templates --skip-workspaces
#   bazelisk run //scripts:update-stack -- --pull-images
#
# Options (accepted anywhere in argv):
#   --stack <prod|dev>   which compose stack to redeploy; default prod, the
#                        stable stack the README's post-pull sequence drives
#   --branch <name>      switch to this branch before pulling (default: stay
#                        on whatever branch the checkout is on)
#   --restart            stop the stack and come back up even when the pull
#                        touched nothing the containers read at boot
#   --no-restart         converge with `up` alone; never stop a container
#   --pull-images        also `compose pull`, which is what advances the
#                        services pinned to a mutable :latest tag
#   --skip-pull          deploy the tree as it stands, with no git operation
#   --skip-repair        skip the setup-host --repair step (it can sudo)
#   --skip-configs       skip the env-file reconciliation
#   --skip-templates     skip the Coder template push (SKIP_TEMPLATE_PUSH=1
#                        is honoured as the same switch)
#   --skip-workspaces    skip reseeding the running workspace containers
#   --litellm-url <url>  the model-transport address forwarded to the reseed
#                        step; name it when this stack remapped LITELLM_PORT
#                        away from 4000, as a port-shifted dev stack does
#   --allow-dirty        proceed even with uncommitted changes in the tree
#   --dry-run            print the plan and change nothing
#   -h, --help           print the usage and exit 0
#
# Run it from a host shell. Inside a Coder workspace the docker CLI addresses
# that workspace's own DinD sidecar, so the compose steps would drive the wrong
# daemon; the script warns when it sees CODER_WORKSPACE_ID and the per-step
# tools report what their daemon actually answered.
#
# Exit codes: 0 for a completed run (warnings allowed); 1 for a usage error or
# any failed step; 2 when --stack names neither prod nor dev; 5 for an
# unresolvable repo root.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

# ── Settings ─────────────────────────────────────────────────────────────────

STACK_FLAVOUR="prod"
TARGET_BRANCH=""
# auto decides from what the pull touched; force is --restart; never is
# --no-restart.
RESTART_MODE="auto"
DRY_RUN=0
PULL_IMAGES=0
ALLOW_DIRTY=0
SKIP_PULL=0
SKIP_REPAIR=0
SKIP_CONFIGS=0
SKIP_TEMPLATES=0
SKIP_WORKSPACES=0
LITELLM_URL=""

# Set by pull_checkout; "0" until a pull proves HEAD actually moved.
HEAD_MOVED=0
# The commit a completed pull landed on, kept for the re-entered run to report.
PULLED_TO=""
# Set in the process re-entered after a pull, to the commit it was re-entered
# for. Its presence means "the pull already happened; do not pull again".
REENTERED_FROM="${EVO_T1_UPDATE_STACK_REEXEC:-}"
# Path of the file the pre-re-exec process left the pull's changed paths in.
CARRIED_PATHS="${EVO_T1_UPDATE_STACK_CHANGED:-}"
# Newline-separated paths the pull brought in, empty when nothing moved.
CHANGED_PATHS=""
# The argv this script was called with, kept verbatim for the re-exec.
ORIGINAL_ARGS=()

# ── Reporting ────────────────────────────────────────────────────────────────

# @function usage
# Print the operator-facing usage and exit.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   Does not return; exits 0
usage() {
  cat <<'USAGE'
usage: bazelisk run //scripts:update-stack -- [--stack <prod|dev>] [--branch <name>]
                       [--restart | --no-restart] [--pull-images]
                       [--skip-pull] [--skip-repair] [--skip-configs]
                       [--skip-templates] [--skip-workspaces]
                       [--litellm-url <url>] [--allow-dirty] [--dry-run]

Pulls the latest code for this checkout and deploys it: fast-forward, host
repair, env reconcile, compose converge, targeted restart of the services
whose bind-mounted payload changed, template push, workspace reseed, status.

Options: --stack prod|dev (default prod), --branch <name>, --restart,
--no-restart, --pull-images, --skip-pull, --skip-repair, --skip-configs,
--skip-templates, --skip-workspaces, --litellm-url <url>, --allow-dirty,
--dry-run.

A dirty tree, a detached HEAD, and a branch that cannot fast-forward are
refused; nothing here destroys a volume or rewrites history.
USAGE
}

# ── Checkout ─────────────────────────────────────────────────────────────────

# @function current_branch
# Print the branch the checkout is on, or nothing when HEAD is detached.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The short branch name on stdout; "HEAD" prints nothing for a detached tree
# Returns:
#   0 when git answered, the git status otherwise
current_branch() {
  local branch=""
  branch="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  if [ "${branch}" = "HEAD" ]; then
    return 0
  fi
  printf '%s\n' "${branch}"
  return 0
}

# @function head_revision
# Print the commit the checkout is on.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The commit sha on stdout
# Returns:
#   0 when git answered, the git status otherwise
head_revision() {
  git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null
}

# @function refuse_unsafe_checkout
# Stop before any network or deploy step when the tree is not safe to move.
# A dirty tree is refused because the pull would land on top of unpublished
# work and the deploy would ship a mix of the two; a detached HEAD is refused
# because there is no branch to fast-forward.
# Globals:
#   ALLOW_DIRTY, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The dirty paths (up to twenty) or the git error on stderr
# Returns:
#   0 when the tree may be pulled; 1 when it must not be
refuse_unsafe_checkout() {
  local dirty="" branch="" listed=""
  if ! dirty="$(git -C "${ROOT_DIR}" status --porcelain 2>/dev/null)"; then
    err "git status failed in ${ROOT_DIR} - fix the repository before deploying"
    return 1
  fi
  if [ -n "${dirty}" ] && [ "${ALLOW_DIRTY}" != "1" ]; then
    err "the checkout has uncommitted changes; the pull would deploy them beside the new code"
    listed="$(printf '%s\n' "${dirty}" | head -20)"
    printf '%s\n' "${listed}" >&2
    err "commit or stash them first, or re-run with --allow-dirty to deploy as-is"
    return 1
  fi
  if [ -n "${TARGET_BRANCH}" ]; then
    return 0
  fi
  if ! branch="$(current_branch)"; then
    err "git could not name the current branch in ${ROOT_DIR}"
    return 1
  fi
  if [ -z "${branch}" ]; then
    err "HEAD is detached, so there is no branch to fast-forward"
    err "check out the branch you want to deploy, or name it with --branch <name>"
    return 1
  fi
  return 0
}

# @function checkout_branch
# Switch the checkout to the branch --branch named.
# Globals:
#   TARGET_BRANCH, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The phase line, or git's own error on stderr
# Returns:
#   0 when the checkout is on that branch, 1 otherwise
checkout_branch() {
  local here=""
  here="$(current_branch || true)"
  if [ "${here}" = "${TARGET_BRANCH}" ]; then
    ok "already on ${TARGET_BRANCH}"
    return 0
  fi
  phase "switch to ${TARGET_BRANCH}"
  if [ "${DRY_RUN}" = "1" ]; then
    note "dry run: would run git checkout ${TARGET_BRANCH}"
    return 0
  fi
  if ! git -C "${ROOT_DIR}" checkout "${TARGET_BRANCH}" 2>&1 | head -5; then
    err "could not check out ${TARGET_BRANCH} in ${ROOT_DIR}"
    return 1
  fi
  ok "checked out ${TARGET_BRANCH}"
  return 0
}

# @function pull_checkout
# Fast-forward the current branch and record what the pull brought in.
# Only --ff-only: a branch that diverged from its upstream needs a real
# decision from the operator, and this script deploys, so guessing with a
# merge or a rebase is not on the table.
# Globals:
#   HEAD_MOVED, CHANGED_PATHS, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The phase line and up to ten lines of git output; failure text on stderr
# Returns:
#   0 when the tree is up to date or moved cleanly, 1 on a refused pull
pull_checkout() {
  local before="" after="" out="" rc=0

  before="$(head_revision || true)"
  if [ -z "${before}" ]; then
    err "${ROOT_DIR} is not a git checkout, so there is nothing to pull"
    err "run this from the stack host's checkout, or skip the pull with --skip-pull"
    return 1
  fi

  phase "fast-forward ${ROOT_DIR}"
  if [ "${DRY_RUN}" = "1" ]; then
    note "dry run: would run git pull --ff-only in ${ROOT_DIR}"
    return 0
  fi

  # The pull output is the diagnostic when it fails and noise when it works, so
  # it is captured and only ever printed capped.
  out="$(git -C "${ROOT_DIR}" pull --ff-only 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    err "the pull did not complete (git exit ${rc})"
    printf '%s\n' "${out}" | head -10 >&2
    case "${out}" in
      *"Couldn't resolve host"* | *"Could not resolve host"* | *"unable to resolve"*)
        err "github.com did not resolve - run: bash scripts/setup-host.sh --repair"
        err "on the host (it installs public DNS beside MagicDNS), then re-run this target"
        ;;
      *fast-forward*)
        err "the branch diverged from its upstream - reconcile it by hand, then re-run"
        ;;
      *"no tracking information"* | *"has no upstream"*)
        err "the branch has no upstream - set one with: git branch --set-upstream-to=origin/main"
        ;;
    esac
    return 1
  fi

  after="$(head_revision || true)"
  if [ -n "${after}" ] && [ "${after}" != "${before}" ]; then
    HEAD_MOVED=1
    PULLED_TO="${after}"
    CHANGED_PATHS="$(git -C "${ROOT_DIR}" diff --name-only "${before}" "${after}" 2>/dev/null || true)"
    ok "updated ${before:0:7} to ${after:0:7}"
    return 0
  fi
  ok "already up to date at ${before:0:7}"
  return 0
}

# @function changed_paths_match
# Report whether the pull brought in any path matching a pattern.
# Globals:
#   CHANGED_PATHS
# Arguments:
#   $1 - a case pattern matched against each changed path
# Outputs:
#   Nothing
# Returns:
#   0 when at least one changed path matches, 1 otherwise
changed_paths_match() {
  local pattern="$1" path
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    # shellcheck disable=SC2254
    case "${path}" in
      ${pattern}) return 0 ;;
    esac
  done <<<"${CHANGED_PATHS}"
  return 1
}

# ── Compose ──────────────────────────────────────────────────────────────────

# @function recreate_needed
# Report whether the pull changed something only a stopped project applies.
# `up -d` recreates a container when its config hash changes, so a changed
# interpolation lands, but it leaves a service deleted from the compose file
# running, and a renamed or retargeted service can bind a port the new file no
# longer wants. Those two need the project stopped first.
# Globals:
#   CHANGED_PATHS
# Arguments:
#   None
# Outputs:
#   Nothing
# Returns:
#   0 when the project must come up from a stop, 1 otherwise
recreate_needed() {
  changed_paths_match 'docker-compose.yml' ||
    changed_paths_match '.env' ||
    changed_paths_match 'dev-stack.env'
}

# @function stack_project
# Print the compose project name for the selected stack flavour.
# Globals:
#   STACK_FLAVOUR
# Arguments:
#   None
# Outputs:
#   evo-t1-prod or evo-t1-dev on stdout
# Returns:
#   0
stack_project() {
  if [ "${STACK_FLAVOUR}" = "dev" ]; then
    printf 'evo-t1-dev\n'
  else
    printf 'evo-t1-prod\n'
  fi
}

# @function stack_env_file
# Print the env file the flavour interpolates from, or nothing.
# Only the dev project takes dev-stack.env; the stable stack reads the .env
# beside the compose file, exactly as the two stack runners do.
# Globals:
#   STACK_FLAVOUR, ROOT_DIR
# Arguments:
#   None
# Outputs:
#   An absolute env-file path on stdout, or nothing
# Returns:
#   0
stack_env_file() {
  if [ "${STACK_FLAVOUR}" = "dev" ] && [ -f "${ROOT_DIR}/dev-stack.env" ]; then
    printf '%s/dev-stack.env\n' "${ROOT_DIR}"
  fi
}

# @function compose_cli
# Print the compose command available on this host.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   "docker compose" or "docker-compose" on stdout
# Returns:
#   0 when one exists, 1 when neither does
compose_cli() {
  if has_tool docker && docker compose version >/dev/null 2>&1; then
    printf 'docker compose\n'
    return 0
  fi
  if has_tool docker-compose; then
    printf 'docker-compose\n'
    return 0
  fi
  return 1
}

# @function stack_compose
# Run one compose subcommand against the selected project.
# The two stack runners own `up`, `down`, `status` and the recovery that
# follows them, so this is only used for the two verbs they do not expose:
# `restart` for a bind-mounted payload change and `pull` for a bumped tag.
# Globals:
#   STACK_FLAVOUR, ROOT_DIR, DRY_RUN
# Arguments:
#   $@ - the compose subcommand and its own arguments
# Outputs:
#   The command's own stdout and stderr; compose's own error text on failure
# Returns:
#   0 in a dry run, the compose status, or 1 when no compose CLI exists
stack_compose() {
  local cli="" env_file=""
  if [ "${DRY_RUN}" = "1" ]; then
    note "dry run: would run compose $*"
    return 0
  fi
  if ! cli="$(compose_cli)"; then
    err "neither 'docker compose' nor 'docker-compose' is on PATH"
    return 1
  fi
  local -a argv=("-p" "$(stack_project)")
  env_file="$(stack_env_file)"
  if [ -n "${env_file}" ]; then
    argv+=("--env-file" "${env_file}")
  fi
  argv+=("-f" "${ROOT_DIR}/docker-compose.yml" "$@")
  # shellcheck disable=SC2086 # cli is deliberately two words
  ${cli} "${argv[@]}"
}

# @function services_for_path
# Print the compose services that read one repo path at boot.
# Globals:
#   None
# Arguments:
#   $1 - a repo-relative path
# Outputs:
#   Space-separated service names on stdout, possibly none
# Returns:
#   0
services_for_path() {
  local path="${1:-}" out=""
  case "${path}" in
    litellm/*) out="litellm" ;;
    searxng/*) out="searxng" ;;
    proxy/certs/*) out="router homepage-proxy coder" ;;
    proxy/*) out="router homepage-proxy" ;;
    homepage/*) out="homepage" ;;
    hermes/*) out="hermes" ;;
  esac
  printf '%s\n' "${out}"
  return 0
}

# @function services_to_restart
# Print the de-duplicated services a set of changed paths affects.
# Globals:
#   CHANGED_PATHS
# Arguments:
#   None
# Outputs:
#   Space-separated unique service names on stdout, possibly empty
# Returns:
#   0
services_to_restart() {
  local path svc out=""
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    # shellcheck disable=SC2046 # the service list is deliberately word-split
    for svc in $(services_for_path "${path}"); do
      case " ${out} " in
        *" ${svc} "*) ;;
        *) out="${out}${svc} " ;;
      esac
    done
  done <<<"${CHANGED_PATHS}"
  printf '%s\n' "${out% }"
}

# ── Steps ────────────────────────────────────────────────────────────────────

# @function run_sibling
# Run one script from the resolved checkout and count the outcome.
# Siblings are started with `bash` on the checkout path, never through
# `bazelisk run`: this script already runs inside a target, and a path keeps
# every step reading the tree that was just pulled.
# Globals:
#   ROOT_DIR, DRY_RUN
# Arguments:
#   $1 - the label to report
#   $2 - the script path, relative to the checkout
#   $3.. - the arguments for that script
# Outputs:
#   The phase line, the sibling's own output, and an ok:/error: line
# Returns:
#   0 when the sibling exited 0 or the run was a dry run, 1 otherwise
run_sibling() {
  local label="$1" script="$2" rc=0
  shift 2
  local stem="${script##*/}"
  stem="${stem%.sh}"
  if [ ! -f "${ROOT_DIR}/${script}" ]; then
    fail_item "${label}: ${script} is missing from ${ROOT_DIR}"
    return 1
  fi
  phase "${label}"
  if [ "${DRY_RUN}" = "1" ]; then
    note "dry run: would run bash ${script} $*"
    return 0
  fi
  bash "${ROOT_DIR}/${script}" "$@" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail_item "${label} exited ${rc} - retry with: bazelisk run //scripts:${stem} -- $*"
    return 1
  fi
  ok "${label}"
  return 0
}

# @function reexec_after_pull
# Replace this process with the copy of itself that the pull just brought in.
# Without this, a pull that rewrote the deploy logic deploys with the old
# logic. The sentinel makes it one hop: a re-entered script never re-execs, so
# a checkout whose HEAD keeps moving cannot loop.
# Globals:
#   HEAD_MOVED, DRY_RUN, SELF_DIR, ORIGINAL_ARGS, PULLED_TO
# Arguments:
#   None
# Outputs:
#   The phase line when it re-enters
# Returns:
#   0 when there is nothing to re-enter; does not return when it does
reexec_after_pull() {
  if [ "${HEAD_MOVED}" != "1" ] || [ "${DRY_RUN}" = "1" ]; then
    return 0
  fi
  if [ -n "${REENTERED_FROM}" ]; then
    return 0
  fi
  if [ ! -f "${SELF_DIR}/update-stack.sh" ]; then
    warn "the updated checkout has no scripts/update-stack.sh; continuing with the copy already loaded"
    return 0
  fi
  phase "re-enter the updated checkout"
  # The restarted process has no git state of its own to rebuild the pull from,
  # and it is the process that has to decide which services to restart, so the
  # file list crosses the hop in a temp file rather than in argv.
  local carry=""
  carry="$(mktemp "${TMPDIR:-/tmp}/update-stack-paths.XXXXXX")" || {
    warn "the pull's file list could not be staged; continuing without the targeted restarts"
    return 0
  }
  printf '%s\n' "${CHANGED_PATHS}" >"${carry}"
  EVO_T1_UPDATE_STACK_REEXEC="${PULLED_TO}"
  EVO_T1_UPDATE_STACK_CHANGED="${carry}"
  export EVO_T1_UPDATE_STACK_REEXEC EVO_T1_UPDATE_STACK_CHANGED
  exec bash "${SELF_DIR}/update-stack.sh" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
}

# @function carry_deploy_state
# Restore what the pre-re-exec process learned, so a re-entered run still knows
# which files the pull brought in.
# Globals:
#   REENTERED_FROM, CARRIED_PATHS, HEAD_MOVED, PULLED_TO, CHANGED_PATHS
# Arguments:
#   None
# Outputs:
#   Nothing
# Returns:
#   0 always
carry_deploy_state() {
  if [ -z "${REENTERED_FROM}" ]; then
    return 0
  fi
  HEAD_MOVED=1
  PULLED_TO="${REENTERED_FROM}"
  if [ -n "${CARRIED_PATHS}" ] && [ -f "${CARRIED_PATHS}" ]; then
    CHANGED_PATHS="$(cat "${CARRIED_PATHS}")"
    rm -f "${CARRIED_PATHS}"
  fi
  return 0
}

# @function converge_stack
# Bring the compose project onto the current tree.
# `up` alone is what a code-only change needs. When the pull changed
# docker-compose.yml or an env file, the project is stopped first: `up -d`
# leaves a service that was deleted from the file running, and a changed
# interpolation only lands in a recreated container.
# Globals:
#   STACK_FLAVOUR, RESTART_MODE, PULL_IMAGES, DRY_RUN
# Arguments:
#   $1 - 1 when the pull changed compose or the env file, anything else for no
# Outputs:
#   The section, the phase lines, and the siblings' own output
# Returns:
#   0 when the stack converged, 1 when a step failed
converge_stack() {
  local recreate="${1:-0}" failed=0
  section "Deploy ${STACK_FLAVOUR} stack"

  if [ "${PULL_IMAGES}" = "1" ]; then
    phase "pull images"
    if [ "${DRY_RUN}" = "1" ]; then
      note "dry run: would run compose pull"
    elif ! stack_compose pull --quiet; then
      warn "the image pull did not complete - the stack still comes up on the tags it has"
    else
      ok "pulled the pinned images"
    fi
  fi

  if [ "${recreate}" = "1" ] || [ "${RESTART_MODE}" = "force" ]; then
    local reason="the pull changed compose or the env file"
    if [ "${RESTART_MODE}" = "force" ]; then
      reason="--restart was given"
    fi
    note "stopping the stack first: ${reason}"
    run_sibling "compose down" "scripts/${STACK_FLAVOUR}-stack.sh" down || failed=1
  fi

  if changed_paths_match 'litellm/*'; then
    note "litellm/config.yaml changed; the proxy restarts below to pick it up"
  fi

  run_sibling "compose up" "scripts/${STACK_FLAVOUR}-stack.sh" up || failed=1

  if [ "${failed}" = "1" ]; then
    return 1
  fi
  return 0
}

# @function restart_changed_services
# Restart the services whose bind-mounted payload the pull changed.
# A payload edit leaves the mount spec alone, so `up -d` sees no config delta
# and keeps the old process; restart is what makes the file land. A service
# that is not running is left to the compose error, which the summary reports.
# Globals:
#   CHANGED_PATHS, RESTART_MODE, DRY_RUN
# Arguments:
#   None
# Outputs:
#   The section, one phase line per service group, and compose's own output
# Returns:
#   0 when there was nothing to restart or every restart worked, 1 otherwise
restart_changed_services() {
  local services="" failed=0 service
  if [ "${RESTART_MODE}" = "never" ]; then
    return 0
  fi
  services="$(services_to_restart)"
  if [ -z "${services}" ]; then
    section "Restarts"
    note "no bind-mounted payload changed; nothing to restart"
    return 0
  fi
  section "Restarts"
  for service in ${services}; do
    phase "restart ${service}"
    # shellcheck disable=SC2086 # services_to_restart prints one space-separated line
    if ! stack_compose restart "${service}"; then
      fail_item "restarting ${service} did not complete - check with: bazelisk run //scripts:${STACK_FLAVOUR}-stack -- logs --tail 50 ${service}"
      failed=1
    else
      ok "restarted ${service}"
    fi
  done
  if [ "${failed}" = "1" ]; then
    return 1
  fi
  return 0
}

# ── Entry ────────────────────────────────────────────────────────────────────

# @function main
# Parse argv and run the update sequence.
# Globals:
#   SKIP_TEMPLATE_PUSH, CODER_WORKSPACE_ID, REENTERED_FROM, CARRIED_PATHS,
#   STACK_FLAVOUR, TARGET_BRANCH, RESTART_MODE, DRY_RUN, PULL_IMAGES,
#   ALLOW_DIRTY, SKIP_PULL, SKIP_REPAIR, SKIP_CONFIGS, SKIP_TEMPLATES,
#   SKIP_WORKSPACES, LITELLM_URL, ORIGINAL_ARGS, ROOT_DIR
# Arguments:
#   $@ - the operator's flags
# Outputs:
#   Every section, phase, ok:/warning:/note:/error: line, and the summary
# Returns:
#   0 when no step failed, 1 when any did, 2 for a bad flavour, 5 for no root
main() {
  local recreate=0 failed=0

  ORIGINAL_ARGS=("$@")
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stack)
        [ "$#" -ge 2 ] || die "--stack needs prod or dev"
        STACK_FLAVOUR="$2"
        shift 2
        ;;
      --branch)
        [ "$#" -ge 2 ] || die "--branch needs a branch name"
        TARGET_BRANCH="$2"
        shift 2
        ;;
      --restart)
        RESTART_MODE="force"
        shift
        ;;
      --no-restart)
        RESTART_MODE="never"
        shift
        ;;
      --pull-images)
        PULL_IMAGES=1
        shift
        ;;
      --skip-pull)
        SKIP_PULL=1
        shift
        ;;
      --skip-repair)
        SKIP_REPAIR=1
        shift
        ;;
      --skip-configs)
        SKIP_CONFIGS=1
        shift
        ;;
      --skip-templates)
        SKIP_TEMPLATES=1
        shift
        ;;
      --skip-workspaces)
        SKIP_WORKSPACES=1
        shift
        ;;
      --litellm-url)
        [ "$#" -ge 2 ] || die "--litellm-url needs a URL"
        LITELLM_URL="$2"
        shift 2
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option '$1' (try --help)" ;;
      *) die "'$1' is not an option; this CLI takes flags only (try --help)" ;;
    esac
  done

  case "${STACK_FLAVOUR}" in
    prod | dev) ;;
    *)
      err "--stack takes prod or dev, not '${STACK_FLAVOUR}'"
      return 2
      ;;
  esac

  if [ "${SKIP_TEMPLATE_PUSH:-}" = "1" ]; then
    SKIP_TEMPLATES=1
  fi

  ROOT_DIR="$(resolve_checkout "${SELF_DIR}")" || return 5
  cd "${ROOT_DIR}" || die "cannot enter ${ROOT_DIR}"

  if [ -n "${CODER_WORKSPACE_ID:-}" ]; then
    warn "this is running inside a Coder workspace, where docker addresses that workspace's DinD sidecar - run it in a host shell to drive the stack"
  fi

  section "Checkout"
  if [ -n "${REENTERED_FROM}" ]; then
    carry_deploy_state
    ok "re-entered the updated checkout at ${REENTERED_FROM:0:7}"
  elif ! has_tool git; then
    if [ "${SKIP_PULL}" = "1" ]; then
      note "git is not installed and --skip-pull was given; deploying the tree as it stands"
    else
      die "git is not on PATH; install it or re-run with --skip-pull"
    fi
  elif [ "${SKIP_PULL}" = "1" ]; then
    note "skipping the pull; deploying the tree as it stands"
  elif ! refuse_unsafe_checkout; then
    return 1
  else
    if [ -n "${TARGET_BRANCH}" ] && ! checkout_branch; then
      return 1
    fi
    if ! pull_checkout; then
      return 1
    fi
    reexec_after_pull
  fi

  # Derived here rather than in the pull branch, so the process that a pull
  # re-entered decides this from the file list it carried across the hop.
  if recreate_needed; then
    recreate=1
  fi

  section "Host"
  if [ "${SKIP_REPAIR}" = "1" ]; then
    note "skipping the host repair"
  else
    note "setup-host --repair recovers stale Bazel runfiles and installs public DNS; on Linux it may ask sudo for the resolved drop-in"
    run_sibling "host repair" "scripts/setup-host.sh" --repair || failed=1
  fi

  section "Configuration"
  if [ "${SKIP_CONFIGS}" = "1" ]; then
    note "skipping the env reconciliation"
  else
    run_sibling "env reconcile" "scripts/update-configs.sh" env --non-interactive || failed=1
  fi

  if ! converge_stack "${recreate}"; then
    summary "bazelisk run //scripts:${STACK_FLAVOUR}-stack -- logs --tail 100"
    return 1
  fi

  restart_changed_services || failed=1

  section "Templates"
  if [ "${SKIP_TEMPLATES}" = "1" ]; then
    note "skipping the template push"
  else
    note "the push reads its wiring from the live .env, which is why it follows the env reconcile"
    run_sibling "template push" "scripts/push-template.sh" || failed=1
  fi

  section "Workspaces"
  if [ "${SKIP_WORKSPACES}" = "1" ]; then
    note "skipping the workspace reseed"
  else
    local -a reseed_args=()
    if [ -n "${LITELLM_URL}" ]; then
      reseed_args+=("--litellm-url" "${LITELLM_URL}")
    fi
    if [ "${DRY_RUN}" = "1" ]; then
      reseed_args+=("--dry-run")
    fi
    run_sibling "workspace reseed" "scripts/refresh-configs.sh" ${reseed_args[@]+"${reseed_args[@]}"} || failed=1
    note "a reseed lands stack-owned files in the containers that are running; ~/.grok/config.toml is only re-rendered when a workspace starts"
  fi

  section "Status"
  run_sibling "stack status" "scripts/${STACK_FLAVOUR}-stack.sh" status || failed=1

  if [ "${failed}" = "1" ]; then
    summary "fix the failed step above and re-run this target; it is safe to run again"
    return 1
  fi
  if [ "${HEAD_MOVED}" = "1" ]; then
    summary "bazelisk run //scripts:${STACK_FLAVOUR}-stack -- status"
  else
    summary "nothing to deploy; the stack is on the code it already had"
  fi
  return 0
}

main "$@"
