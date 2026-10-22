#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## update-configs.sh - bring a checkout's config in line after a git pull (entry point)
#
# Two things go stale in this repo and neither is checked in, so neither
# survives a `git pull` on its own. One is the env file that feeds compose's
# ${...} lines (.env at the root, dev-stack.env for the dev project), whose
# .env.example twin carries the keys and explains them in the comment
# lines above: a pull that renames, adds or drops a key silently changes what
# the stack runs on. The other is the stack-owned config that lives INSIDE the
# running workspaces (~/.grok/AGENTS.md, ~/.grok/config.toml,
# ~/.shared/vscode/settings.json, ~/.tmux.conf, ~/.coder/..., ~/.agents/...),
# which the templates seed on first boot and never revisit. This script is the
# one command that refreshes both, and -i/--interactive is what makes the env
# pass safe to run unattended: it explains every key that still needs a value,
# and prompts for it, instead of quietly accepting a placeholder.
#
# What this script never does:
#   - print an env value that looks like a secret. A key whose name carries
#     KEY, SECRET, TOKEN or PASSWORD reports "set" or "empty" only, so a
#     screenful of output can be pasted into a chat or an issue;
#   - drop a key your env file still sets. A key the new twin no longer
#     declares is reported and moved to a commented trailer at the end of the
#     file, where it stays readable and costs nothing, rather than deleted;
#   - re-copy ~/.grok/config.toml or ~/.shared/vscode/settings.json over a
#     workspace's copy. Both are RENDERED per workspace (the model list, the
#     session-affinity key and an editor API key are all per-workspace), so a
#     copy from the host would move that workspace's own settings. The
#     workspace pass reseeds the verbatim payloads and reports the rendered
#     ones instead: restarting the workspace re-renders them from this
#     checkout, which is the only place those per-workspace values are known;
#   - run a docker, ssh or curl command of its own. `workspace` hands each
#     target to seed_container_seed, which addresses one docker exec at a time.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:update-configs -- env --dry-run
#   bazelisk run //scripts:update-configs -- env --interactive
#   bazelisk run //scripts:update-configs -- workspace --dry-run
#   bazelisk run //scripts:update-configs -- all
#   bazelisk run //scripts:update-configs -- workspace --home ~/scratch/home
#
# Run `workspace` from a host shell. Inside a workspace the docker CLI
# addresses that workspace's own DinD sidecar (or nothing at all), so an empty
# `docker ps` there is normal and this script says so instead of reporting an
# empty stack.
#
# Options (each one follows the subcommand):
#   env / workspace / all  what to refresh; `all` is env then workspace
#   --dry-run            report the plan without writing anything
#   -i, --interactive    stop and ask about every key that still needs a value
#                        (the default on a TTY; --non-interactive turns it off)
#   --non-interactive    never prompt; list what would be asked
#   --force              reseed user-owned workspace files too
#   --from <dir>         read the payloads from this checkout (default: the one
#                        this script was run from, or $REPO_ROOT)
#   --home <dir>         treat this host directory as a workspace HOME tree
#   --container <name>   address this container explicitly
#   -h, --help           print the usage and exit 0
#
# Exit codes: 0 for a completed run and for every "nothing to do" skip;
# 1 for a usage error; 5 for an unresolvable repo root.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/config_seed.sh disable=SC1091
source "${SELF_DIR}/lib/config_seed.sh"
# shellcheck source=lib/host_state.sh disable=SC1091
source "${SELF_DIR}/lib/host_state.sh"

# STACK_SECRET_KEYS - the name fragments that mark an env key as holding a
# credential. These are named in a report, never printed with their value.
STACK_SECRET_KEYS='KEY SECRET TOKEN PASSWORD'

# @function usage
# Print the flag list on stdout, so a typo prints something readable.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE'
usage: update-configs [--dry-run] [--interactive] [--non-interactive] [--force]
                      [--from <dir>] [--home <dir> ...] [--container <name> ...]
                      env | workspace | all

  env        port your env file's values onto the new <name>.env.example twin
             (.env, and dev-stack.env when that file exists). Existing values
             are kept; a sibling env file can fill a new key; a TTY walks you
             through new keys, placeholders and empty values
  workspace  re-materialize the stack-owned workspace configs from this
             checkout, and name any rendered file that would re-render on the
             target's next start
  all        env, then workspace

Options: --dry-run (report only), --interactive (ask; the default on a TTY),
--non-interactive (never prompt), --force (reseed user-owned files too),
--from <dir> (read the payloads from that checkout), --home <dir> (a host
directory shaped like a workspace HOME), --container <name>, -h/--help.

Examples (each line is the whole command, run from the repo root):
  bazelisk run //scripts:update-configs -- env --dry-run
  bazelisk run //scripts:update-configs -- env
  bazelisk run //scripts:update-configs -- workspace --dry-run
  bazelisk run //scripts:update-configs -- workspace --home ~/scratch/home
USAGE
}

# @function resolve_repo_root
# Print the repo root this run reads payloads from: the first candidate that
# holds docker-compose.yml (the marker of a real checkout).
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE
# Arguments:
#   None
# Outputs:
#   The root on stdout, or nothing
# Returns:
#   The root on stdout; prints the complaint and returns 5 when none is proven
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}")
  candidates+=("${SELF_DIR}/..")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}/docker-compose.yml" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: unresolvable repo root: no proven checkout in %s (need docker-compose.yml)\n' \
    "${candidates[*]}" >&2
  return 5
}

# @function env_pairs
# List the env pairs this run can reconcile, as "<live>\t<example>" lines:
# every <name>.env.example under the given root, paired with the live file of
# the same name minus the .example, whether or not that live file exists yet.
# The twins are found with find, not a glob: the one at the repo root is a
# dotfile, and a plain glob would walk straight past it.
# Globals:
#   None
# Arguments:
#   $1 - the repo root to scan
# Outputs:
#   One tab-separated pair per env file
# Returns:
#   0, always
env_pairs() {
  local root="${1:-}" example
  [[ -d ${root} ]] || return 0
  while IFS= read -r example; do
    [[ -n ${example} ]] || continue
    printf '%s\t%s\n' "${example%.example}" "${example}"
  done < <(find "${root}" -maxdepth 1 -type f -name '*.env.example' | sort)
  # dev-stack.env is generated from .env (ports shifted); it has no twin of
  # its own. Pair it with .env.example so a pull still walks it.
  if [[ -f ${root}/dev-stack.env && ! -f ${root}/dev-stack.env.example ]]; then
    if [[ -f ${root}/.env.example ]]; then
      printf '%s\t%s\n' "${root}/dev-stack.env" "${root}/.env.example"
    elif [[ -f ${root}/.env.sample ]]; then
      printf '%s\t%s\n' "${root}/dev-stack.env" "${root}/.env.sample"
    fi
  fi
  return 0
}

# @function env_live_files
# Print the live env files under a root that actually exist.
# Globals:
#   None
# Arguments:
#   $1 - the repo root to scan
# Outputs:
#   One path per line
# Returns:
#   0, always
env_live_files() {
  local live
  while IFS=$'\t' read -r live _; do
    if [[ -n ${live} && -f ${live} ]]; then
      printf '%s\n' "${live}"
    fi
  done < <(env_pairs "${1:-}")
  return 0
}

# @function is_placeholder_value
# Succeed when an env value is empty or still a shipped placeholder.
# Globals:
#   None
# Arguments:
#   $1 - the value to classify
# Outputs:
#   Nothing
# Returns:
#   0 when the value is empty, change-me*, NOTSET, or carries YOUR_LAN_IP
is_placeholder_value() {
  case "${1:-}" in
    '' | change-me* | NOTSET | *YOUR_LAN_IP*) return 0 ;;
  esac
  return 1
}

# @function is_secret_key
# Succeed when an env key name suggests a credential.
# Globals:
#   STACK_SECRET_KEYS
# Arguments:
#   $1 - the key name
# Outputs:
#   Nothing
# Returns:
#   0 when the name carries one of the fragments in STACK_SECRET_KEYS
is_secret_key() {
  local fragment
  for fragment in ${STACK_SECRET_KEYS}; do
    if [[ ${1} == *"${fragment}"* ]]; then
      return 0
    fi
  done
  return 1
}

# @function key_state
# Describe an env value without printing it, because a report meant to be
# pasteable cannot carry a credential: only whether the key is filled is said.
# Globals:
#   None
# Arguments:
#   $1 - the value to classify
# Outputs:
#   "empty", "still the placeholder" or "set" on stdout
# Returns:
#   0, always
key_state() {
  if ! is_placeholder_value "${1:-}"; then
    printf 'set'
    return 0
  fi
  case "${1:-}" in
    '') printf 'empty' ;;
    *) printf 'still the placeholder' ;;
  esac
  return 0
}

# @function env_reuse_value
# Print a reusable value for one key from a sibling env file: the first
# non-placeholder assignment of that key, so a new key in dev-stack.env can
# keep the secret already set in .env.
# Globals:
#   None
# Arguments:
#   $1 - the key
#   $2 - the live file being filled (skipped)
#   $3.. - sibling live files to read
# Outputs:
#   The value on stdout, or nothing
# Returns:
#   0, always
env_reuse_value() {
  local key="${1:-}" current="${2:-}" file="" value=""
  shift 2
  for file in "$@"; do
    if [[ -z ${file} || ${file} == "${current}" || ! -f ${file} ]]; then
      continue
    fi
    value="$(env_get "${file}" "${key}")"
    if ! is_placeholder_value "${value}"; then
      printf '%s\n' "${value}"
      return 0
    fi
  done
  return 0
}

# @function env_set_key
# Replace one assignment in an env file through awk and ENVIRON, never through
# a shell re-parse of the line.
# Globals:
#   None
# Arguments:
#   $1 - the env file
#   $2 - the key
#   $3 - the new value
# Outputs:
#   Nothing
# Returns:
#   0 when the file was rewritten, 1 when it could not be
env_set_key() {
  local file="${1:-}" key="${2:-}" value="${3:-}" stage=""
  [[ -f ${file} && -n ${key} ]] || return 1
  stage="$(mktemp "${TMPDIR:-/tmp}/evoT1Env.XXXXXX")" || return 1
  if ! UCKEY="${key}" UCVAL="${value}" awk '
    BEGIN { n = ENVIRON["UCKEY"]; v = ENVIRON["UCVAL"] }
    index($0, n "=") == 1 { print n "=" v; next }
    { print }
  ' "${file}" >"${stage}"; then
    rm -f "${stage}"
    return 1
  fi
  mv "${stage}" "${file}"
  return 0
}

# @function env_seed_live
# Create a live env file from its example twin, mode 600.
# Globals:
#   None
# Arguments:
#   $1 - the example twin
#   $2 - the live path to write
# Outputs:
#   One created line
# Returns:
#   0 when the file was written, 1 when the twin is missing
env_seed_live() {
  local example="${1:-}" live="${2:-}"
  if [[ ! -f ${example} ]]; then
    return 1
  fi
  cp "${example}" "${live}"
  chmod 600 "${live}"
  log "created ${live##*/} from ${example##*/}"
  return 0
}

# @function key_comment
# Print the comment lines that sit directly above one key in an example file:
# the explanation that twin carries for that key, and nothing from the block
# above it. Blank and non-comment lines reset the run, so only the block that
# touches the key is printed.
# Globals:
#   None
# Arguments:
#   $1 - the example file to read
#   $2 - the key to look up
# Outputs:
#   The comment block on stdout, empty when the key has none
# Returns:
#   0, always
key_comment() {
  local file="${1:-}" key="${2:-}"
  if [[ ! -f ${file} ]]; then
    return 0
  fi
  awk -v want="${key}" '
    index($0, want "=") == 1 { exit }
    /^#/ { block[++n] = $0; next }
    /^$|^[^#]/ { n = 0 }
    END { for (i = 1; i <= n; i++) print block[i] }
  ' "${file}"
  return 0
}

# @function env_retired_keys
# Print the keys a live env file sets that its example twin no longer
# declares. Read-only: this is how a pull that renames or retires a key stops
# being a silent change.
# Globals:
#   None
# Arguments:
#   $1 - the live env file
#   $2 - the example twin to compare it with
# Outputs:
#   One key per line, nothing when every key is still declared
# Returns:
#   0, always
env_retired_keys() {
  local live="${1:-}" example="${2:-}" key
  if [[ ! -f ${live} ]]; then
    return 0
  fi
  while IFS= read -r key; do
    if [[ -z ${key} ]]; then
      continue
    fi
    if ! grep -qE "^${key}=" "${example}"; then
      printf '%s\n' "${key}"
    fi
  done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${live}" | tr -d '=' | sort -u)
  return 0
}

# @function env_sync
# Reconcile one live env file with its example twin and print what changed:
# every key the twin adds, every key whose value the operator's file keeps, and
# every key the twin no longer declares. With a staging file named it also
# writes the merged result there, line by line off the twin, so each key stays
# beside the comment that explains it and the file keeps its shape.
# Globals:
#   None
# Arguments:
#   $1 - the live env file (absent for a checkout that has no env file yet)
#   $2 - the example twin to read
#   $3 - the staging file to write, or "" to report only
# Outputs:
#   One line per added, kept and retired key
# Returns:
#   0, always: a pair with nothing to reconcile is a report, not a failure
env_sync() {
  local live="${1:-}" example="${2:-}" stage="${3:-}"
  local stale="" key="" value="" default="" line

  if [[ ! -f ${example} ]]; then
    note "no ${example:-twin} beside ${live:-this file} - nothing to reconcile it against"
    return 0
  fi

  while IFS= read -r line; do
    case "${line}" in
      '' | '#'*)
        if [[ -n ${stage} ]]; then
          printf '%s\n' "${line}" >>"${stage}"
        fi
        continue
        ;;
      *=*) ;;
      *)
        if [[ -n ${stage} ]]; then
          printf '%s\n' "${line}" >>"${stage}"
        fi
        continue
        ;;
    esac

    key="${line%%=*}"
    default="${line#*=}"
    value=""
    if [[ -f ${live} ]]; then
      value="$(env_get "${live}" "${key}")"
    fi

    if [[ -z ${value} ]]; then
      if [[ -n ${stage} ]]; then
        printf '%s=%s\n' "${key}" "${default}" >>"${stage}"
      fi
      if [[ -f ${live} ]]; then
        printf '  %s: new in this update - the example default is %s\n' \
          "${key}" "$(key_state "${default}")"
      fi
      continue
    fi

    if [[ -n ${stage} ]]; then
      printf '%s=%s\n' "${key}" "${value}" >>"${stage}"
    fi
    if [[ ${value} != "${default}" ]]; then
      printf '  %s: your value kept\n' "${key}"
    fi
  done <"${example}"

  stale="$(env_retired_keys "${live}" "${example}")"
  if [[ -z ${stale} ]]; then
    return 0
  fi

  printf '  %d key(s) this update no longer reads, kept commented out:\n' \
    "$(printf '%s\n' "${stale}" | grep -c .)"
  while IFS= read -r key; do
    printf '    %s\n' "${key}"
  done <<<"${stale}"

  if [[ -n ${stage} ]]; then
    {
      printf '\n# Keys this update no longer declares. Nothing reads them, and they\n'
      printf '# stay here commented out so the reason they were set stays readable.\n'
      while IFS= read -r key; do
        printf '#%s=%s\n' "${key}" "$(env_get "${live}" "${key}")"
      done <<<"${stale}"
    } >>"${stage}"
  fi
  return 0
}

# @function env_ask
# Walk one env file and prompt for every key that is new, still empty, or still
# a placeholder, with the explanation the twin carries above it. A sibling env
# file can supply a reusable value (Enter keeps it). With prompting off the
# same keys are only listed. A closed stdin never blocks or hangs.
# Globals:
#   None
# Arguments:
#   $1 - the example twin (for the explanations)
#   $2 - the env file to read
#   $3 - 1 to prompt (default 0; 0 lists instead)
#   $4 - snapshot of the live file from before the merge ("" = every key is new)
#   $5.. - sibling live files to reuse values from
# Outputs:
#   The prompt block per unresolved key, or the list of them
# Returns:
#   0, always
env_ask() {
  local example="${1:-}" file="${2:-}" ask="${3:-0}" orig="${4:-}"
  local -a missing=() reuse_files=()
  local line key value orig_val="" answer="" reuse="" default=""

  if [[ $# -ge 5 ]]; then
    shift 4
    reuse_files=("$@")
  fi

  if [[ ! -f ${file} ]]; then
    return 0
  fi

  while IFS= read -r line; do
    case "${line}" in
      *=*) ;;
      *) continue ;;
    esac
    case "${line}" in \#*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    orig_val=""
    if [[ -n ${orig} && -f ${orig} ]]; then
      orig_val="$(env_get "${orig}" "${key}")"
    fi
    if is_placeholder_value "${value}"; then
      missing+=("${key}")
    elif [[ -z ${orig_val} ]]; then
      missing+=("${key}")
    fi
  done <"${file}"

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ ${ask} != "1" ]]; then
    note "${file##*/}: ${#missing[@]} key(s) to review (new, empty, or still a placeholder)"
    for key in "${missing[@]}"; do
      printf '  %s\n' "${key}"
    done
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn "no terminal to ask through: ${#missing[@]} key(s) to review and stay as they are" \
      "(rerun in a terminal, without --dry-run, to fill)"
    return 0
  fi

  for key in "${missing[@]}"; do
    value="$(env_get "${file}" "${key}")"
    default="$(env_get "${example}" "${key}")"
    reuse="$(env_reuse_value "${key}" "${file}" "${reuse_files[@]+"${reuse_files[@]}"}")"
    printf '\n%s: %s\n' "${key}" "$(key_comment "${example}" "${key}" |
      sed 's/^#[[:space:]]\{0,1\}//' | grep -vE '^[[:space:]]*$' | head -n 3 | tr '\n' ' ')"
    printf '  Current value: %s.\n' "$(key_state "${value}")"
    if [[ -n ${reuse} ]]; then
      printf '  A reusable value is already set in a sibling env file. Enter to keep it.\n'
    elif ! is_placeholder_value "${default}"; then
      if is_secret_key "${key}"; then
        printf '  The example default is set. Enter to keep it, or type a new value.\n'
      else
        printf '  Enter to keep %s, or type a new value.\n' "${default}"
      fi
    else
      printf '  Type a new value, or nothing to leave it.\n'
    fi
    if is_secret_key "${key}"; then
      printf '  This key holds a credential, so what you type is not echoed.\n'
      read -rs -r answer || answer=""
      printf '\n'
    else
      read -r answer || answer=""
    fi
    if [[ -z ${answer} ]]; then
      if is_placeholder_value "${value}" && [[ -n ${reuse} ]]; then
        answer="${reuse}"
        printf '  %s reused from a sibling env file.\n' "${key}"
      else
        continue
      fi
    fi
    if ! env_set_key "${file}" "${key}" "${answer}"; then
      warn "${key}: the answer could not be written - the file is left as it was"
      return 0
    fi
    printf '  %s set.\n' "${key}"
  done

  return 0
}

# @function daemon_vantage
# Print which docker daemon this shell would address, so a run from inside a
# workspace says which daemon was asked instead of reporting an empty stack.
# Globals:
#   DOCKER_HOST, CODER_WORKSPACE_ID
# Arguments:
#   None
# Outputs:
#   One line naming the daemon, or a note that the docker CLI is missing
# Returns:
#   0, always
daemon_vantage() {
  if [[ -n ${CODER_WORKSPACE_ID:-} ]]; then
    printf 'daemon: this shell runs inside workspace %s, whose own sidecar daemon is' \
      "${CODER_WORKSPACE_ID}"
    printf ' all that docker here can reach (%s) - no stack service sits behind it\n' \
      "${DOCKER_HOST:-no DOCKER_HOST, so a mounted socket if there is one}"
    return 0
  fi
  if [[ -n ${DOCKER_HOST:-} ]]; then
    printf 'daemon: %s (from DOCKER_HOST)\n' "${DOCKER_HOST}"
    return 0
  fi
  if has_tool docker; then
    printf 'daemon: the default docker socket\n'
    return 0
  fi
  printf 'daemon: no docker CLI on PATH\n'
  return 0
}

# @function main
# Parse argv, then run the env pass, the workspace pass, or both.
# Globals:
#   DRY_RUN, FORCE, REPO_ROOT
# Arguments:
#   "$@" - the argv documented in the file header
# Outputs:
#   The reconciliation and reseed report on stdout
# Returns:
#   0 when the plan ran or nothing addressed a target; 1 on a usage error;
#   5 when no repo root can be proven
main() {
  local -a targets=() siblings=()
  local root="" stage="" live="" example="" home="" target="" answer=""
  local mode="${1:-}"

  case "${mode}" in
    env | workspace | all) shift ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage
      return 1
      ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -i | --interactive) ASK=1 ;;
      --non-interactive)
        ASK=0
        NO_ASK=1
        ;;
      --force) FORCE=1 ;;
      --from)
        if [ $# -lt 2 ]; then
          err "--from needs a checkout path"
          usage
          return 1
        fi
        REPO_ROOT="${2}"
        shift
        ;;
      --container)
        if [ $# -lt 2 ]; then
          err "--container needs a container name"
          usage
          return 1
        fi
        targets+=("c:${2}")
        shift
        ;;
      --home)
        if [ $# -lt 2 ]; then
          err "--home needs a directory"
          usage
          return 1
        fi
        targets+=("h:${2}")
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --*)
        err "unknown option: $1"
        usage
        return 1
        ;;
      *)
        targets+=("$1")
        ;;
    esac
    shift
  done

  root="$(resolve_repo_root)" || return 5

  if [[ ${DRY_RUN:-0} != "1" && ${NO_ASK:-0} != "1" && -t 0 ]]; then
    ASK=1
  fi

  if [[ ${mode} == "env" || ${mode} == "all" ]]; then
    log "env files reconcile against the twin under ${root}"
    if [[ -t 0 ]]; then
      host_dns_report /etc/resolv.conf github.com || true
    fi
    siblings=()
    while IFS= read -r live; do
      siblings+=("${live}")
    done < <(env_live_files "${root}")
    while IFS=$'\t' read -r live example; do
      if [[ -z ${live} ]]; then
        continue
      fi
      if [[ ! -f ${live} ]]; then
        if [[ ${ASK:-0} == "1" && -t 0 && ${DRY_RUN:-0} != "1" ]]; then
          printf '\nNo %s here. Create it from %s and walk through the keys? [Y/n] ' \
            "${live##*/}" "${example##*/}"
          read -r answer || answer=""
          case "${answer}" in
            n | N | no | No | NO)
              note "no ${live##*/} here: skipped"
              continue
              ;;
          esac
          if ! env_seed_live "${example}" "${live}"; then
            note "no ${live##*/} here: this checkout ships ${example##*/} and nothing to port onto it"
            continue
          fi
          siblings+=("${live}")
        else
          note "no ${live##*/} here: this checkout ships ${example##*/} and nothing to port onto it"
          continue
        fi
      fi
      if [[ ! -w ${live} ]]; then
        warn "${live##*/} is not writable here - skipped"
        continue
      fi
      log "--- ${live##*/} ---"
      stage="$(mktemp -d "${TMPDIR:-/tmp}/evoT1Env.XXXXXX")"
      cp "${live}" "${stage}/orig"
      if [[ ${DRY_RUN:-0} == "1" ]]; then
        env_sync "${live}" "${example}" ""
        env_ask "${example}" "${live}" 0 "${stage}/orig" "${siblings[@]+"${siblings[@]}"}"
      else
        env_sync "${live}" "${example}" "${stage}/next"
        if [[ ! -f ${stage}/next ]]; then
          note "${live##*/}: ${example##*/} declares no key - the file is left as it was"
        else
          chmod 600 "${stage}/next"
          mv "${stage}/next" "${live}"
          log "  ${live##*/} rewritten from ${example##*/}"
          env_ask "${example}" "${live}" "${ASK:-0}" "${stage}/orig" \
            "${siblings[@]+"${siblings[@]}"}"
        fi
      fi
      rm -rf "${stage}"
    done < <(env_pairs "${root}")
  fi

  if [[ ${mode} == "workspace" || ${mode} == "all" ]]; then
    log "workspace configs re-materialize from ${root}"
    daemon_vantage
    if [[ ${#targets[@]} -eq 0 ]]; then
      if [[ -n ${CODER_WORKSPACE_ID:-} ]] || [[ ${DOCKER_HOST:-} == *dind* ]]; then
        note "nothing to reseed from here. The stack's services run on the host's docker" \
          "daemon, which this shell cannot reach. Run this in a host shell, or name the" \
          "target with --container <name> or --home <dir>."
        return 0
      fi
      while IFS= read -r target; do
        targets+=("c:${target}")
      done < <(seed_workspace_containers)
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
      note "no coder-* workspace container answered on this daemon - nothing to reseed"
      return 0
    fi
    stage="$(mktemp -d "${TMPDIR:-/tmp}/evoT1Seed.XXXXXX")"
    for target in "${targets[@]}"; do
      case "${target}" in
        c:*)
          log "--- ${target#c:} ---"
          seed_container_seed "${target#c:}" /home/coder "${root}" "${stage}" \
            "${DRY_RUN:-0}" "${FORCE:-0}"
          ;;
        h:*)
          home="${target#h:}"
          if [[ ! -d ${home} ]]; then
            warn "no ${home} directory to reseed into - skipped"
            continue
          fi
          log "--- ${home} (host directory) ---"
          seed_container_seed "" "${home}" "${root}" "${stage}" \
            "${DRY_RUN:-0}" "${FORCE:-0}"
          ;;
      esac
    done
    note "what stays per workspace: ~/.grok/config.toml is rendered inside the" \
      "workspace, not copied from here (its model list, session-affinity key and" \
      "editor keys are per-workspace) - start or restart the workspace to re-render it."
    rm -rf "${stage}"
  fi

  return 0
}

main "$@"
