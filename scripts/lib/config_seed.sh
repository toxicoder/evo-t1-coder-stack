#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## config_seed.sh - the reseed plumbing behind the two workspace-cleanup CLIs
# (sourced; never executed).
#
# One list of stack-owned payload files (the reseed set) plus the helpers that
# stage a payload, decide whether a workspace may receive a fresh copy, and
# transport the bytes. scripts/refresh-configs.sh and scripts/storage-clean.sh
# source this file so neither keeps a private copy of the reseed set.
#
# Invariants:
#   - Sourcing this file changes no shell options and no cwd; it inherits the
#     caller's `set -euo pipefail` like every other file under scripts/lib/,
#     and it sources common.sh (its helpers) when that has not been sourced
#     yet. Nothing here builds a command out of text with eval.
#   - Ownership contract, inherited from the two startup.sh.tftpl twins: a
#     stack-owned config file carries one of the three marker spellings below
#     (the `managed-by: evo-t1-coder-stack` comment, the `"__evoT1Stack": true`
#     JSON key, or the `__evoT1Stack = true` TOML key), or it is user-owned. A
#     marker-free file is no proof of a human edit: the Grok Build CLI persists
#     its own settings by parsing config.toml and writing it back, and that
#     round trip drops every comment line, so only a key outlives it. Reseeding
#     still leaves a marker-free file alone unless --force is used.
#   - Container traffic is one `docker exec -i <name> sh -c <script> sh
#     <args...>` per probe or write. Probes close stdin (bazelisk run keeps
#     a pipe open, and docker exec -i waits for EOF on it); writes pass
#     --stdin and redirect the payload. No
#     `docker run`, no helper container, and no dev-only file ever lands in a
#     workspace volume. Paths and marker texts travel as separate argv words,
#     never interpolated into the script body, so the Bats docker stub can
#     replay a call and a test can point --container-root at a scratch tree.
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root cd):
#   SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/config_seed.sh disable=SC1091
#   source "${SELF_DIR}/lib/config_seed.sh"

if ! declare -f log >/dev/null 2>&1; then
  SELF_DIR="${SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  # shellcheck source=lib/common.sh disable=SC1091
  source "${SELF_DIR}/common.sh"
fi

# _CONFIG_SEED_DIR — this lib's directory, so probe scripts and json_copy_key.py
# resolve next to it under bazelisk runfiles and a checkout.
_CONFIG_SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# STACK_MARKER_TEXT / STACK_MARKER_JSON / STACK_MARKER_TOML - the three
# spellings of the marker that marks a file as stack-owned. The comment form
# has to survive being embedded in a heredoc, the JSON key carries the same
# promise inside settings.json, and the TOML key carries it inside
# ~/.grok/config.toml. The TOML key exists because the comment alone does not
# last: the Grok Build CLI persists its own settings by parsing that file and
# writing it back, and that round trip drops every comment line, which would
# hand a stack-managed config over to the user with no human involved. A plain
# key survives the same write and the CLI parses it without complaint.
STACK_MARKER_TEXT='managed-by: evo-t1-coder-stack'
STACK_MARKER_JSON='"__evoT1Stack": true'
STACK_MARKER_TOML='__evoT1Stack = true'

# STACK_LITELLM_URL - the stack's one model-transport address as a workspace
# sees it. A workspace reaches LiteLLM through the host's published port, so
# the rendered editor settings must carry this exact spelling. The 4000 default
# is the stable stack's port: an env-file reseed for a dev stack that remapped
# LITELLM_PORT overrides it here (or with refresh-configs --litellm-url).
STACK_LITELLM_URL="${STACK_LITELLM_URL:-http://host.docker.internal:4000/v1}"

# STACK_VSCODE_COLOR_THEME - the editor color theme rendered into a reseeded
# settings.json. On a workspace boot that value is a per-workspace parameter; a
# reseed has no parameter to read, so it lands the parameter's own default and
# an operator exports this name to reseed a different one.
STACK_VSCODE_COLOR_THEME="${STACK_VSCODE_COLOR_THEME:-Default Dark Modern}"

# @function seed_seed_targets
# Print the reseed set, one "<target path>\t<payload kind>:<source>" line per
# stack-owned target. Kinds: file (copy this repo file), exec (copy it and set
# mode 755, for a payload the runner starts rather than reads), render (render
# this repo file, substituting ${litellm_url} and ${vscode_color_theme},
# $${...} unfolds to ${...}, and carrying each target's own cline.apiKey /
# roo.openaiApiKey forward). Targets are home-relative (~/...) so
# --container-root can repoint them in a test.
# A twin pair is listed twice on purpose: the Coder Agents chat reads the
# ~/.coder copy, the Grok Build CLI reads the ~/.agents copy, and the two
# never dedupe each other. ~/.grok/config.toml is absent from this set by
# design: it renders per workspace (the model list, the session-affinity key
# and the Grok theme are each that workspace's own), so re-seeding it from a
# shared seed here is what the per-workspace profile removes.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One tab-separated line per reseed target
# Returns:
#   0
seed_seed_targets() {
  # The ~/... spellings below are home-relative KEYS, not tilde paths: the
  # readers strip the leading ~ and re-root the rest at $HOME or at the
  # --container-root, so nothing here must expand early.
  #
  # ez-bazel-first is absent from this set on purpose. It seeds into the repository it
  # converts, at <repo>/.grok/skills/ez-bazel-first/ (the repo tier the Grok Build CLI
  # reads), which templates/common/stack-repo-skills.sh.tftpl discovers per repository --
  # a per-repository path is not a home-relative one, so it cannot be a reseed target
  # here. Its six former global-home entries are retired below, so a tree that booted
  # while they were still seeded stops advertising a Bazel gate to a project that has
  # none.
  #
  # The fleet family (seven agent definitions, three persona overlays, four
  # parent-side skills) is listed under the same two contracts the boot body
  # templates/common/stack-fleet.sh.tftpl implements: one marker-aware copy each
  # under ~/.grok/agents and ~/.grok/personas, and a SKILL.md per home for the
  # skills, because the chat reads ~/.coder and the CLI reads ~/.agents. The
  # coder_script seeds them on a workspace start; this list is what brings a host
  # tree, or a workspace that missed a boot, to the same bytes.
  # shellcheck disable=SC2088
  printf '%s\n' \
    '~/.tmux.conf	file:templates/common/tmux.conf' \
    '~/.shared/vscode/settings.json	render:templates/workspace/settings.json.tftpl' \
    '~/.grok/AGENTS.md	file:templates/common/GROK_BUILD_AGENTS.md' \
    '~/.coder/AGENTS.md	file:templates/common/coder-agents.md' \
    '~/.agents/INSTRUCTIONS.md	file:templates/common/coder-agents.md' \
    '~/.coder/skills/grok-build-delegation/SKILL.md	file:templates/common/grok-build-delegation.SKILL.md' \
    '~/.agents/skills/grok-build-delegation/SKILL.md	file:templates/common/grok-build-delegation.SKILL.md' \
    '~/.coder/skills/ez-learn/SKILL.md	file:templates/common/ez-learn.SKILL.md' \
    '~/.agents/skills/ez-learn/SKILL.md	file:templates/common/ez-learn.SKILL.md' \
    '~/.coder/skills/ez-skillify/SKILL.md	file:templates/common/ez-skillify.SKILL.md' \
    '~/.agents/skills/ez-skillify/SKILL.md	file:templates/common/ez-skillify.SKILL.md' \
    '~/.coder/skills/ez-create-skill/SKILL.md	file:templates/common/ez-create-skill.SKILL.md' \
    '~/.agents/skills/ez-create-skill/SKILL.md	file:templates/common/ez-create-skill.SKILL.md' \
    '~/.coder/skills/reflect-and-evolve/SKILL.md	file:templates/common/reflect-and-evolve.SKILL.md' \
    '~/.agents/skills/reflect-and-evolve/SKILL.md	file:templates/common/reflect-and-evolve.SKILL.md' \
    '~/.coder/skills/reflect-and-evolve/scripts/session_signals.py	file:templates/common/reflect-and-evolve.session_signals.py' \
    '~/.agents/skills/reflect-and-evolve/scripts/session_signals.py	file:templates/common/reflect-and-evolve.session_signals.py' \
    '~/.coder/skills/reflect-and-evolve/references/checklist.md	file:templates/common/reflect-and-evolve.checklist.md' \
    '~/.agents/skills/reflect-and-evolve/references/checklist.md	file:templates/common/reflect-and-evolve.checklist.md' \
    '~/.coder/skills/reflect-and-evolve-repo/SKILL.md	file:templates/common/reflect-and-evolve-repo.SKILL.md' \
    '~/.agents/skills/reflect-and-evolve-repo/SKILL.md	file:templates/common/reflect-and-evolve-repo.SKILL.md' \
    '~/.coder/skills/reflect-and-evolve-repo/references/checklist.md	file:templates/common/reflect-and-evolve-repo.checklist.md' \
    '~/.agents/skills/reflect-and-evolve-repo/references/checklist.md	file:templates/common/reflect-and-evolve-repo.checklist.md' \
    '~/.coder/skills/ez-strong-types/SKILL.md	file:templates/common/ez-strong-types.SKILL.md' \
    '~/.agents/skills/ez-strong-types/SKILL.md	file:templates/common/ez-strong-types.SKILL.md' \
    '~/.coder/skills/ez-strong-types/scripts/type_baseline.py	file:templates/common/ez-strong-types.type_baseline.py' \
    '~/.agents/skills/ez-strong-types/scripts/type_baseline.py	file:templates/common/ez-strong-types.type_baseline.py' \
    '~/.coder/skills/ez-trunk-based-repo/SKILL.md	file:templates/common/ez-trunk-based-repo.SKILL.md' \
    '~/.agents/skills/ez-trunk-based-repo/SKILL.md	file:templates/common/ez-trunk-based-repo.SKILL.md' \
    '~/.coder/skills/ez-micro-plan/SKILL.md	file:templates/common/ez-micro-plan.SKILL.md' \
    '~/.agents/skills/ez-micro-plan/SKILL.md	file:templates/common/ez-micro-plan.SKILL.md' \
    '~/.coder/skills/ez-micro-plan/scripts/plan_check.py	file:templates/common/ez-micro-plan.plan_check.py' \
    '~/.agents/skills/ez-micro-plan/scripts/plan_check.py	file:templates/common/ez-micro-plan.plan_check.py' \
    '~/.coder/skills/trunk-refactor/SKILL.md	file:templates/common/trunk-refactor.SKILL.md' \
    '~/.agents/skills/trunk-refactor/SKILL.md	file:templates/common/trunk-refactor.SKILL.md' \
    '~/.grok/agents/explorer.md	file:templates/common/explorer.AGENT.md' \
    '~/.grok/agents/architect.md	file:templates/common/architect.AGENT.md' \
    '~/.grok/agents/implementer.md	file:templates/common/implementer.AGENT.md' \
    '~/.grok/agents/tester.md	file:templates/common/tester.AGENT.md' \
    '~/.grok/agents/reviewer.md	file:templates/common/reviewer.AGENT.md' \
    '~/.grok/agents/security-auditor.md	file:templates/common/security-auditor.AGENT.md' \
    '~/.grok/agents/documenter.md	file:templates/common/documenter.AGENT.md' \
    '~/.grok/personas/thorough-researcher.toml	file:templates/common/thorough-researcher.PERSONA.toml' \
    '~/.grok/personas/senior-implementer.toml	file:templates/common/senior-implementer.PERSONA.toml' \
    '~/.grok/personas/skeptical-reviewer.toml	file:templates/common/skeptical-reviewer.PERSONA.toml' \
    '~/.coder/skills/feature-implementation/SKILL.md	file:templates/common/feature-implementation.SKILL.md' \
    '~/.agents/skills/feature-implementation/SKILL.md	file:templates/common/feature-implementation.SKILL.md' \
    '~/.coder/skills/skeptical-review/SKILL.md	file:templates/common/skeptical-review.SKILL.md' \
    '~/.agents/skills/skeptical-review/SKILL.md	file:templates/common/skeptical-review.SKILL.md' \
    '~/.coder/skills/security-audit/SKILL.md	file:templates/common/security-audit.SKILL.md' \
    '~/.agents/skills/security-audit/SKILL.md	file:templates/common/security-audit.SKILL.md' \
    '~/.coder/skills/bug-hunt/SKILL.md	file:templates/common/bug-hunt.SKILL.md' \
    '~/.agents/skills/bug-hunt/SKILL.md	file:templates/common/bug-hunt.SKILL.md' \
    '~/.coder/skills/documenter/SKILL.md	file:templates/common/documenter.SKILL.md' \
    '~/.agents/skills/documenter/SKILL.md	file:templates/common/documenter.SKILL.md' \
    '~/.coder/skills/performance-optimizer/SKILL.md	file:templates/common/performance-optimizer.SKILL.md' \
    '~/.agents/skills/performance-optimizer/SKILL.md	file:templates/common/performance-optimizer.SKILL.md' \
    '~/.coder/skills/debugger/SKILL.md	file:templates/common/debugger.SKILL.md' \
    '~/.agents/skills/debugger/SKILL.md	file:templates/common/debugger.SKILL.md' \
    '~/.coder/skills/migrator/SKILL.md	file:templates/common/migrator.SKILL.md' \
    '~/.agents/skills/migrator/SKILL.md	file:templates/common/migrator.SKILL.md' \
    '~/.coder/skills/ez-code-index/SKILL.md	file:templates/common/ez-code-index.SKILL.md' \
    '~/.agents/skills/ez-code-index/SKILL.md	file:templates/common/ez-code-index.SKILL.md' \
    '~/.coder/skills/ez-code-index/scripts/code_index.py	file:templates/common/ez-code-index.code_index.py' \
    '~/.agents/skills/ez-code-index/scripts/code_index.py	file:templates/common/ez-code-index.code_index.py' \
    '~/.grok/hooks/evo-t1-hooks.json	file:templates/common/hooks.evo-t1-hooks.json' \
    '~/.grok/hooks/bin/deny-patterns.txt	file:templates/common/hooks.deny-patterns.txt' \
    '~/.grok/hooks/bin/secret-guard.sh	exec:templates/common/hooks.secret-guard.sh' \
    '~/.grok/hooks/bin/dangerous-command-guard.sh	exec:templates/common/hooks.dangerous-command-guard.sh' \
    '~/.grok/hooks/bin/post-edit-format.sh	exec:templates/common/hooks.post-edit-format.sh' \
    '~/.grok/hooks/bin/selective-test-runner.sh	exec:templates/common/hooks.selective-test-runner.sh'
}

# @function seed_retired_targets
# Print the targets a rename or a tier change left behind, one home-relative path per
# line. A renamed skill does not uninstall itself: the boot contract only ever writes
# an absent file, so the copy the stack seeded under the old name survives and
# keeps shadowing whatever the CLI ships under it (a user-scope skill wins over
# a same-named bundled one). The reseed removes those leftovers; the boot
# scripts do the same for a workspace that never runs a reseed.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One home-relative path per retired target
# Returns:
#   0
seed_retired_targets() {
  # shellcheck disable=SC2088
  printf '%s\n' \
    '~/.coder/skills/learn/SKILL.md' \
    '~/.agents/skills/learn/SKILL.md' \
    '~/.coder/skills/ez-bazel-first/SKILL.md' \
    '~/.agents/skills/ez-bazel-first/SKILL.md' \
    '~/.coder/skills/ez-bazel-first/scripts/owned_files_check.py' \
    '~/.agents/skills/ez-bazel-first/scripts/owned_files_check.py' \
    '~/.coder/skills/ez-bazel-first/scripts/glob_budget.py' \
    '~/.agents/skills/ez-bazel-first/scripts/glob_budget.py'
}

# @function seed_container_exec
# Run one POSIX sh snippet inside a running container with its arguments kept
# as separate argv words. With docker stubbed or absent this same argv shape
# runs on the host instead, which is how the Bats suites replay it. Stdin is
# closed unless the first argument is --stdin (payload writes).
# Globals:
#   None
# Arguments:
#   $1 - optional --stdin to inherit stdin; otherwise stdin is /dev/null
#   $1 or $2 - container name
#   $2 or $3 - the POSIX sh script body
#   remaining - the script's own arguments ($1, $2 ... inside it)
# Outputs:
#   Whatever the script printed
# Returns:
#   The script's status; 1 when the arguments are incomplete or the docker
#   CLI refused the exec
seed_container_exec() {
  local inherit_stdin=0 container script
  if [[ ${1:-} == --stdin ]]; then
    inherit_stdin=1
    shift
  fi
  container="${1:-}"
  script="${2:-}"
  shift 2
  if [[ -z ${container} || -z ${script} ]]; then
    return 1
  fi
  # The argv0 slot that makes the script's own $1 its first argument is the
  # leading "sh" every caller passes, not a word added here: adding one here too
  # shifts every probe by one, so seed-write.sh writes the payload to a file
  # named "sh" in the container's cwd and the target never lands.
  if [[ ${inherit_stdin} == 1 ]]; then
    docker exec -i "${container}" sh -c "${script}" "$@"
  else
    docker exec -i "${container}" sh -c "${script}" "$@" </dev/null
  fi
}

# @function seed_target_owner
# Ask one container (or one host directory standing in for one) who owns a
# config file right now.
# Globals:
#   STACK_MARKER_TEXT, STACK_MARKER_JSON, STACK_MARKER_TOML
# Arguments:
#   $1 - container name ("" for a host path)
#   $2 - full path to the file
# Outputs:
#   One word on stdout: absent, managed, user or unreadable
# Returns:
#   0 unless the docker CLI refused to run the probe
seed_target_owner() {
  local target="${1:-}" path="${2:-}" state=""
  if [[ -z ${target} ]]; then
    if [[ ! -e ${path} ]]; then
      printf 'absent\n'
    elif [[ ! -r ${path} ]]; then
      printf 'unreadable\n'
    elif grep -qF -e "${STACK_MARKER_TEXT}" -e "${STACK_MARKER_JSON}" \
      -e "${STACK_MARKER_TOML}" "${path}" 2>/dev/null; then
      printf 'managed\n'
    else
      printf 'user\n'
    fi
    return 0
  fi
  state="$(seed_container_exec "${target}" "$(cat "${_CONFIG_SEED_DIR}/probes/seed-owner.sh")" \
    sh "${path}" "${STACK_MARKER_TEXT}" "${STACK_MARKER_JSON}" "${STACK_MARKER_TOML}")" || {
    return 1
  }
  case "${state}" in
    *absent*) printf 'absent\n' ;;
    *managed*) printf 'managed\n' ;;
    *unreadable*) printf 'unreadable\n' ;;
    *) printf 'user\n' ;;
  esac
  return 0
}

# @function seed_key_value
# Print the last "key": "value" string value found in a JSON body, unquoted.
# Globals:
#   None
# Arguments:
#   $1 - the JSON text to read
#   $2 - the key to look for
# Outputs:
#   The value on stdout; nothing when the key is absent
# Returns:
#   0, always (a no-match sed stays invisible on purpose: it would otherwise
#   abort a strict-mode caller through pipefail)
seed_key_value() {
  printf '%s\n' "${1:-}" |
    sed -nE "s|.*\"${2}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*|\1|p" |
    tail -n 1
  return 0
}

# @function seed_render_settings
# Render a settings.json.tftpl into a staging file a workspace may receive:
# $${...} unfolds back to ${...}, ${litellm_url} becomes STACK_LITELLM_URL,
# ${vscode_color_theme} becomes STACK_VSCODE_COLOR_THEME (a reseed has no
# per-workspace theme parameter, so it lands that parameter's default), and a
# cline.apiKey / roo.openaiApiKey the target already carries is copied
# forward (the seed in git carries no key; a workspace that was handed one on
# its first boot keeps it through a reseed).
# Globals:
#   STACK_LITELLM_URL, STACK_VSCODE_COLOR_THEME
# Arguments:
#   $1 - the .tftpl source to render
#   $2 - the staging file to write
#   $3 - the target's current copy, when it has one ("" or absent otherwise)
# Outputs:
#   One note per refusal reason
# Returns:
#   1 (with the note) when nothing could be rendered or the carried key would
#   be lost; 0 when the staging file is ready
seed_render_settings() {
  local src="${1:-}" dest="${2:-}" current="${3:-}" rendered="" key=""
  if [[ ! -f ${src} ]]; then
    note "no ${src} to render - skipped"
    return 1
  fi
  rendered="$(mktemp "${TMPDIR:-/tmp}/evoT1Render.XXXXXX")" || {
    note "${src}: nowhere to stage the rendered copy - skipped"
    return 1
  }
  if ! sed -e 's/\$\${/${/g' \
    -e "s|\${litellm_url}|${STACK_LITELLM_URL}|g" \
    -e "s|\${vscode_color_theme}|${STACK_VSCODE_COLOR_THEME}|g" "${src}" \
    >"${rendered}"; then
    rm -f "${rendered}"
    note "${src}: rendering failed - skipped"
    return 1
  fi
  if [[ -n ${current} && -f ${current} ]]; then
    for key in cline.apiKey roo.openaiApiKey; do
      if grep -qE "\"${key}\"[[:space:]]*:" "${current}" 2>/dev/null; then
        if ! has_tool python3; then
          note "${current} carries ${key} but python3 is missing - the reseed stops short of dropping that key: skipped"
          rm -f "${rendered}"
          return 1
        fi
        if ! python3 "${_CONFIG_SEED_DIR}/json_copy_key.py" "${rendered}" "${current}" "${key}"; then
          note "${current} carries ${key} but is no longer valid JSON - the reseed stops short of guessing: skipped"
          rm -f "${rendered}"
          return 1
        fi
      fi
    done
  fi
  mv "${rendered}" "${dest}"
  return 0
}

# @function seed_volume_kind
# Classify one Docker volume name by what the stack keeps in it.
# Globals:
#   None
# Arguments:
#   $1 - volume name
# Outputs:
#   One word on stdout: grok-state, grok-legacy, shared-config, home,
#   docker-lib or nothing
# Returns:
#   0 when the kind is known, 1 when it is not
seed_volume_kind() {
  case "${1:-}" in
    # The three live per-owner mounts: state that is shared deliberately, while
    # config.toml stays on each workspace's own home volume.
    grok-notes-* | grok-memory-* | grok-sessions-*) printf 'grok-state\n' ;;
    # The pre-split whole-profile volume. Not the live mount any more: it comes
    # back read-only at ~/.grok-legacy for the one-time hoist only.
    grok-profile-*) printf 'grok-legacy\n' ;;
    vscode-settings-*) printf 'shared-config\n' ;;
    *-home) printf 'home\n' ;;
    *-dind-lib) printf 'docker-lib\n' ;;
    *) return 1 ;;
  esac
  return 0
}

# @function seed_workspace_containers
# Print the workspace containers a reseed or sweep may address: names from
# `docker ps` that start with coder-, minus the docker-in-docker sidecars.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One container name per line (none when no daemon answers)
# Returns:
#   0, always
seed_workspace_containers() {
  local names=""
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)" || return 0
  printf '%s\n' "${names}" | grep -E '^coder-' | grep -vE -- '-dind-sidecar$' || true
  return 0
}

# @function seed_sweep_stale
# List (action list) or remove (action delete) plain files that have not been
# modified in <days> days under each given root. Read-only under list.
# Globals:
#   None
# Arguments:
#   $1 - container name ("" for a host directory)
#   $2 - age cutoff in days, default 30
#   $3 - list or delete, default list
#   $4.. - absolute roots to sweep (nothing happens under an absent root)
# Outputs:
#   One line per listed or removed file
# Returns:
#   0 when the sweep ran (empty roots included), 1 on a bad action or an
#   exec the docker CLI refused
seed_sweep_stale() {
  local target="${1:-}" days="${2:-30}" action="${3:-list}"
  shift 3
  case "${action}" in
    list)
      if [[ -z ${target} ]]; then
        for root in "$@"; do
          [[ -d ${root} ]] || continue
          find "${root}" -type f -mtime +"${days}" -print
        done
        return 0
      fi
      seed_container_exec "${target}" "$(cat "${_CONFIG_SEED_DIR}/probes/seed-find-mtime.sh")" \
        sh "${days}" "$@"
      ;;
    delete)
      if [[ -z ${target} ]]; then
        for root in "$@"; do
          [[ -d ${root} ]] || continue
          find "${root}" -type f -mtime +"${days}" -exec rm -f {} +
        done
        return 0
      fi
      seed_container_exec "${target}" "$(cat "${_CONFIG_SEED_DIR}/probes/seed-rm-mtime.sh")" \
        sh "${days}" "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

# @function seed_retire_renamed
# Remove every retired target from one target tree, plus the directory it left
# once that is empty. The marker contract decides who goes: a retired file that
# still carries a stack marker is the stack's own leftover from before the
# rename, and a marker-free one belongs to whoever took it over, so it stays.
# Globals:
#   STACK_MARKER_TEXT, STACK_MARKER_JSON, STACK_MARKER_TOML
# Arguments:
#   $1 - container name ("" for a home directory tree standing in for one)
#   $2 - home root (where the home-relative retired targets live)
#   $3 - 1 to report without deleting anything (default 0)
# Outputs:
#   One line per retired target, one note per target that could not be touched
# Returns:
#   0 when every retired target was handled; 1 when a probe or a delete the
#   docker CLI refused left one in place
seed_retire_renamed() {
  local target="${1:-}" home="${2:-}" preview="${3:-0}" name path state rc=0
  [[ -n ${home} ]] || return 0
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    path="${home}/${name#\~/}"
    if [[ -z ${target} ]]; then
      state="$(seed_target_owner "" "${path}")"
    elif ! state="$(seed_target_owner "${target}" "${path}")"; then
      note "${target}:${name}: the probe could not run - left alone"
      rc=1
      continue
    fi
    [[ ${state} == "managed" ]] || continue
    if [[ ${preview} == "1" ]]; then
      printf '  %s: would retire (this checkout no longer seeds this path)\n' "${name}"
      continue
    fi
    if [[ -z ${target} ]]; then
      rm -f "${path}"
      rmdir "$(dirname "${path}")" 2>/dev/null
    elif ! seed_container_exec "${target}" \
      "$(cat "${_CONFIG_SEED_DIR}/probes/seed-rm-managed.sh")" \
      sh "${path}" "${STACK_MARKER_TEXT}" "${STACK_MARKER_JSON}" "${STACK_MARKER_TOML}"; then
      note "${target}:${name}: could not be removed - left alone"
      rc=1
      continue
    fi
    printf '  %s: retired (this checkout no longer seeds this path)\n' "${name}"
  done <<<"$(seed_retired_targets)"
  return "${rc}"
}

# @function seed_ensure_mode
# Re-assert the executable bit on a payload the runner execs. The byte compare in
# seed_container_seed answers "does the content match this checkout", which says
# nothing about the mode, and a hook whose bit was cleared by a copy or an editor
# still matches while failing at the first edit - so the mode is checked on the
# already-matches path too, not only after a write. A kind other than exec has no
# mode to assert, and a payload that is not there yet is the write's business.
# Globals:
#   none
# Arguments:
#   $1 - payload kind from seed_seed_targets ("exec" is the only one that matters)
#   $2 - path the payload lands at
#   $3 - container name ("" for a host directory tree)
#   $4 - payload name, for the note
# Outputs:
#   Nothing on success - the caller's own verb line is the one record this target gets,
#   and refresh-configs reads one decision line per payload off this function's stdout.
#   A refused chmod is a note naming the payload, since a guard that never runs is the
#   failure this prevents
# Returns:
#   0 when the mode is right or the kind needs none, 1 when a chmod was refused
seed_ensure_mode() {
  local kind="${1:-}" path="${2:-}" target="${3:-}" name="${4:-}"
  local have=""

  [[ ${kind} == "exec" ]] || return 0
  if [[ -z ${target} ]]; then
    [[ -f ${path} ]] || return 0
    have="$(stat -c '%a' "${path}" 2>/dev/null)" || have=""
    [[ ${have} == "755" ]] && return 0
    if ! chmod 755 "${path}" 2>/dev/null; then
      note "${name}: could not be made executable (mode ${have:-unknown}) - it will not run"
      return 1
    fi
  elif ! seed_container_exec "${target}" 'chmod 755 "${1}"' sh "${path}"; then
    note "${target}:${name}: the container refused chmod 755 - the hook will not run"
    return 1
  fi
  return 0
}

# @function seed_container_seed
# Re-materialize the whole reseed set into one target (a container name, a
# container's home-relative paths under a host directory standing in for one,
# or "" for the host itself). The decision per file belongs to the marker
# contract: absent gets a fresh seed, marker-carrying gets a reseed when the
# content drifted, marker-free stays untouched unless force is 1.
# Globals:
#   STACK_MARKER_TEXT, STACK_MARKER_JSON
# Arguments:
#   $1 - container name ("" for a host directory tree)
#   $2 - home root (where home-relative targets live)
#   $3 - repo root (where the payload sources live)
#   $4 - staging directory for one-file-at-a-time staging
#   $5 - 1 to report without writing anything (default 0)
#   $6 - 1 to overwrite user-owned files too (default 0)
# Outputs:
#   One line per reseed decision, one note per skipped payload, and the
#   retire lines seed_retire_renamed prints for the targets a rename left behind
# Returns:
#   0, always
seed_container_seed() {
  local target="${1:-}" home="${2:-}" root="${3:-}" stage="${4:-}"
  local preview="${5:-0}" force="${6:-0}"
  local name kind source path staged current state verb forced=""

  [[ -d ${stage} ]] || return 0
  if [[ ${force} == "1" ]]; then
    forced=" (forced)"
  fi

  while IFS=$'\t' read -r path source; do
    [[ -n ${path} && -n ${source} ]] || continue
    name="${path#\~/}"
    kind="${source%%:*}"
    source="${source#*:}"
    path="${home}/${name}"
    staged="${stage}/staged"
    current="${stage}/current"
    rm -f "${staged}" "${current}"

    if [[ -z ${target} ]]; then
      state="$(seed_target_owner "" "${path}")"
    elif ! state="$(seed_target_owner "${target}" "${path}")"; then
      note "${target}:${name}: the probe could not run - skipped"
      continue
    fi

    if [[ ${state} == "user" || ${state} == "unreadable" ]]; then
      if [[ ${force} != "1" ]]; then
        printf '  %s: %s - user-owned, left alone (--force overrides)\n' "${name}" "${state}"
        continue
      fi
    fi

    if [[ ${state} != "absent" ]]; then
      if [[ -z ${target} ]]; then
        cat "${path}" >"${current}" 2>/dev/null || true
      else
        seed_container_exec "${target}" 'cat "${1}" 2>/dev/null' sh "${path}" >"${current}" || true
      fi
    fi

    case "${kind}" in
      file | exec)
        if [[ ! -f "${root}/${source}" ]]; then
          note "${name}: ${source} is not in this checkout - skipped"
          continue
        fi
        printf '%s\n' "$(cat "${root}/${source}")" >"${staged}"
        ;;
      render)
        if ! seed_render_settings "${root}/${source}" "${staged}" "${current}"; then
          continue
        fi
        ;;
      *)
        note "${name}: ${source} names no known payload kind - skipped"
        continue
        ;;
    esac

    if [[ ${state} != "absent" ]] && cmp -s "${current}" "${staged}"; then
      printf '  %s: already matches this checkout\n' "${name}"
      seed_ensure_mode "${kind}" "${path}" "${target}" "${name}" || true
      continue
    fi

    if [[ ${preview} == "1" ]]; then
      printf '  %s: would re-materialize%s\n' "${name}" "${forced}"
      continue
    fi

    verb="re-materialized"
    if [[ ${state} == "absent" ]]; then
      verb="seeded"
    elif [[ ${state} == "user" || ${state} == "unreadable" ]]; then
      verb="OVERWRITTEN under --force"
    fi

    if [[ -z ${target} ]]; then
      mkdir -p "$(dirname "${path}")"
      cp "${staged}" "${path}"
    elif ! seed_container_exec --stdin "${target}" "$(cat "${_CONFIG_SEED_DIR}/probes/seed-write.sh")" \
      sh "${path}" <"${staged}"; then
      printf '  %s: skipped (nothing could be written there)\n' "${name}"
      continue
    fi
    # A hook is exec'd by the runner, not read as data, so the mode is part of the
    # payload, and the container's chmod has to be able to say it was refused.
    seed_ensure_mode "${kind}" "${path}" "${target}" "${name}" || true
    printf '  %s: %s\n' "${name}" "${verb}"
  done <<<"$(seed_seed_targets)"

  # A rename in the set above leaves its old target behind, and the absent-only
  # contract means nothing else ever removes it, so retire it from the same
  # place: every caller (both workspace CLIs and the contributor seed) then
  # unshadows the name the CLI bundles.
  seed_retire_renamed "${target}" "${home}" "${preview}" || true

  return 0
}
