#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## github-auth.sh - workspace GitHub credential doctor and one-line auth (entry point)
#
# A workspace talks to github.com over HTTPS, and while the agent environment
# carries GH_TOKEN or GITHUB_TOKEN that pair is what git and gh consult
# first: git's credential helper is `!gh auth git-credential`, and gh itself
# prefers the environment variable, then falls back to the per-workspace gh
# auth store that the gh_token_refresh coder_script re-mints on start and
# every 6 hours, and only then to a direct `coder external-auth access-token`
# mint (CODER_GITHUB_AUTH_ID, then `primary-github` for workspaces that still
# declare the legacy custom-OAuth id). Those slots normally hold the SAME
# token, because Coder mints one token for the connected account and injects
# it into the env pair and into the store; a credential that authenticates can
# still be refused every write, and a PUBLIC repo answers api.github.com
# /repos with 200 for any authenticated caller, so a credential that only
# READS prints a false pass when you ask it the read question. `check`
# therefore asks the WRITE question - one GET of
# <repo>.git/info/refs?service=git-receive-pack, the endpoint git push itself
# negotiates through - and answers it per credential, not per slot, so a store
# copy that shadows to the env token is named once. A read-only credential
# prints REFUSED-GRANT, never a pass, and every verdict names the next command.
#
# Usage:
#   bazelisk run //scripts:github-auth -- check [repo-url] [--source=<slot>]            (inside a workspace)
#   bazelisk run //scripts:github-auth -- check [container] [repo-url] [--source=<slot>]  (on the stack host)
#       Inside a workspace (CODER_WORKSPACE_ID set) or a contributor
#       devcontainer (EVO_T1_DEVCONTAINER=1) the docker CLI addresses a
#       sidecar or the workstation daemon, never the stack host's workspace
#       fleet, so check runs SELF mode there: no docker at all, one probe of
#       this environment's own credential chain, printed as `self:` lines. On
#       the host (both unset) check lists the labeled workspace containers
#       via docker ps and probes each; a named container checks just that
#       one. The optional container slot and the optional repo URL
#   may come in either order, and the container slot only exists on a host.
#       repo-url takes the clone URL or the browser URL, with or without a
#       trailing slash and with or without .git, and it takes the scp-style
#       git@github.com:owner/repo and ssh:// forms too. Everything after
#       github.com has to be exactly owner/repo: a deeper path is refused
#       rather than probed, because github.com serves no ref advertisement
#       under a tree or blob path and the answer would describe that made-up
#       address, not your repository.
#       A probe answers PUSH-READY (200 advertising refs), REFUSED-GRANT
#       (403: the credential authenticates and still cannot write this repo),
#       NOT VISIBLE (404: a private repo hidden from this credential, or
#       absent), REJECTED (401: the credential itself is refused, as an
#       expired mint is), or no useful answer (offline? probe again).
#       --source names one slot instead of the chain: chain (default) probes
#       every credential that could answer for that repo and marks the
#       shadowed ones; env, gh or mint probes just that slot and says beside
#       the answer that git and gh consult the env pair first.
#       Prints slot names, kinds and verdicts; never token bytes.
#   bazelisk run //scripts:github-auth -- auth <container> [-]
#       Install a write-capable credential into that ONE workspace: the PAT
#       arrives on stdin only (the - form, or a TTY prompt). A second argument
#       is refused: argv is readable through `ps` by any other process in that
#       container and the token lands in shell history. The token then goes to
#       `gh auth login --hostname github.com --with-token` inside the
#       container, and `gh auth setup-git` wires git's credential helper to gh,
#       replacing the gh login that host had before. Legitimate when the owner
#       connected no Coder account (nothing can be minted), or when check just
#       proved the minted credential read-only. While the account stays
#       connected the next gh_token_refresh run rewrites that store, so treat
#       a pasted PAT as a stand-in, and rotate or remove it in GitHub ->
#       Applications when the work ends.
#
# Auth: the docker CLI plus, inside each workspace, whatever sh, curl, gh,
# timeout and coder resolve to there (a healthy workspace has them all).
#
# Safety: `check` is read-only and prints no secret; `auth` writes only under
# ~/.config/gh inside that workspace (gh owns those files) and is opt-in per
# workspace for exactly that reason.

set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE in the environment would
# otherwise route every report line to stderr and leave stdout empty.
unset JSON_MODE

# @function running_workspaces
# List the names of every running workspace container, via the label the
# templates stamp on the workspace docker_container (coder.workspace_id).
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One container name per line; nothing when none run
# Returns:
#   0 when the daemon answered, 1 when docker ps failed
running_workspaces() {
  docker ps --filter label=coder.workspace_id --format '{{.Names}}'
}

# @function normalize_repo_path
# Turn what an operator pastes into the owner/repo path the ref advertisement
# needs. The browser URL, a trailing slash, a trailing .git and the scp-style
# and ssh:// remote forms all arrive here, and each of them has to strip down
# to exactly owner/repo or be refused: a URL that keeps a path segment beyond
# the repo names an address github.com never serves, so probing it would
# answer a confident NOT VISIBLE about a repository the credential can see.
# Globals:
#   None
# Arguments:
#   $1 - the URL or remote as typed
# Outputs:
#   owner/repo on stdout
# Returns:
#   0 when the tail is a repository path, 1 when it is not a github.com
#   address at all or names something deeper than a repository
normalize_repo_path() {
  local raw path
  raw="${1:-}"
  case "${raw}" in
    *github.com*) ;;
    *) return 1 ;;
  esac
  path="$(printf '%s' "${raw}" |
    sed -E -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|^[^/@]*@||' -e 's|^(www\.)?github\.com[:/]?||' -e 's|/+$||' -e 's|\.git$||')"
  case "${path}" in
    */*/*) return 1 ;;
    */*) printf '%s' "${path}" ;;
    *) return 1 ;;
  esac
}

# The probe body lives in scripts/lib/probes/github-auth.sh and is printed
# verbatim, so the far end sees exactly the file this repo ships.
# @function credential_probe
# Print the POSIX sh probe script that answers the WRITE question. It lists
# the credential slots in the order git and gh consult them (the agent env
# pair, then the gh auth store, then a coder external-auth mint for
# CODER_GITHUB_AUTH_ID and then the legacy primary-github id), drops the
# slots whose token another slot already holds, and then issues one GET per
# remaining token. That is one GET in the usual case, because Coder puts the
# same minted token in the env pair and in the store, and it becomes two once
# a PAT is pasted into the store, which is exactly when answering both
# matters. A slot holding the env token is named beside it and never probed
# twice, and a slot the env pair outranks is marked shadowed, because asking
# it a question git would never ask it is still the answer an operator needs
# before pasting a PAT or granting a grant. The credential reaches curl
# through --config - on stdin, never in argv where any other process could
# read it from `ps`, and is never printed.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One POSIX sh script on stdout. Run it with sh -c and five arguments: $1
#   the label to print, $2 the optional repo path owner/repo, $3 the text the
#   fix pointers name as "github-auth.sh auth <that> -", $4 the slot selector
#   (chain, or one of env, gh, mint).
# Returns:
#   0
credential_probe() {
  cat "${SELF_DIR}/lib/probes/github-auth.sh"
}

# ── Commands ───────────────────────────────────────────────────────────────

# @function in_self_env
# True when this process is a Coder workspace or a contributor devcontainer,
# so check must probe this environment instead of enumerating docker
# containers (docker here is a sidecar or the workstation daemon, never the
# stack host's workspace fleet).
# Globals:
#   CODER_WORKSPACE_ID, EVO_T1_DEVCONTAINER
# Arguments:
#   None
# Outputs:
#   Nothing
# Returns:
#   0 when SELF mode applies, 1 otherwise
in_self_env() {
  [[ -n ${CODER_WORKSPACE_ID:-} || ${EVO_T1_DEVCONTAINER:-} == 1 ]]
}

# @function probe_self
# SELF mode: run the credential probe directly in THIS environment (inside a
# workspace or contributor devcontainer that is this environment's own
# credential chain; no docker anywhere, because docker here addresses a
# sidecar or the workstation daemon, never the host fleet). No container is
# enumerated and none is named: one report line per credential, prefixed
# "self:".
# Globals:
#   None
# Arguments:
#   $1 - optional repo path (owner/repo) to probe
#   $2 - slot selector (chain, env, gh or mint); chain by default
# Outputs:
#   One or two report lines prefixed "self:"
# Returns:
#   0 unless sh itself failed
probe_self() {
  local repo="${1:-}" sel="${2:-chain}" probe out="" rc=0
  probe="$(credential_probe)"
  phase "probing this environment"
  if [[ -n ${repo} ]]; then
    out="$(sh -c "${probe}" sh self "${repo}" '<container>' "${sel}")" || rc=$?
  else
    out="$(sh -c "${probe}" sh self "" '<container>' "${sel}")" || rc=$?
  fi
  # Reprint the probe's own lines unchanged, then count a write pass beside them.
  if [[ -n ${out} ]]; then
    printf '%s\n' "${out}"
  fi
  if [[ ${out} == *"PUSH-READY"* ]]; then
    ok "this environment can push"
  fi
  return "${rc}"
}

# @function probe_workspace
# HOST mode: ask one workspace container which credentials its git/gh could
# present (the env pair, the gh auth store, then a fresh external-auth mint)
# and, when a repo path is given, whether each of them can WRITE to that
# repo. The probe runs as one POSIX sh -c inside the container, so the PATH
# and env there decide what really answers, exactly like a real git push
# would; this function never prints a token value and hands each credential to
# curl on stdin through curl's --config - channel, not in curl's argv, where
# any other process could read it from `ps`.
# Globals:
#   None
# Arguments:
#   $1 - container name
#   $2 - optional repo path (owner/repo) to probe
#   $3 - slot selector (chain, env, gh or mint); chain by default
# Outputs:
#   One or two report lines for the container
# Returns:
#   0 unless docker itself failed
probe_workspace() {
  local container="$1" repo="${2:-}" sel="${3:-chain}" probe out="" rc=0
  probe="$(credential_probe)"
  # The sh -c arg order is (placeholder name, $1=container, $2=repo,
  # $3=the name the fix pointers print, $4=the slot selector). Positional
  # args, not -e env, because the Bats docker stub passes argv through
  # verbatim, keeping host-side tests faithful.
  phase "probing ${container}"
  if [[ -n ${repo} ]]; then
    out="$(docker exec "${container}" sh -c "${probe}" sh "${container}" "${repo}" "${container}" "${sel}")" || rc=$?
  else
    out="$(docker exec "${container}" sh -c "${probe}" sh "${container}" "" "${container}" "${sel}")" || rc=$?
  fi
  if [[ -n ${out} ]]; then
    printf '%s\n' "${out}"
  fi
  if [[ ${out} == *"PUSH-READY"* ]]; then
    ok "${container} can push"
  fi
  return "${rc}"
}

# @function auth_workspace
# Install a PAT into one workspace through the gh CLI: replaces that host's
# previous gh login, points git's credential helper at gh, and verifies with
# `gh api /user`. The token travels on stdin only - never in argv.
# Globals:
#   None
# Arguments:
#   $1 - container name
#   $2 - the PAT (empty refuses)
# Outputs:
#   One result line naming the container
# Returns:
#   0 when gh accepted the token, 1 otherwise
auth_workspace() {
  local container="$1" pat="$2"
  if [[ -z ${pat} ]]; then
    warn "${container}: empty PAT - nothing installed (pipe the token: echo \$TOKEN | bazelisk run //scripts:github-auth -- auth ${container} -)"
    summary
    return 1
  fi
  # login exits non-zero on its own when the token fails to authenticate.
  # Unset the minted env pair first: gh prefers GH_TOKEN/GITHUB_TOKEN over
  # stdin, and a workspace that already has the pair makes `--with-token`
  # refuse ("The value of the GH_TOKEN environment variable is being used
  # for authentication") the same way gh_token_refresh used to.
  phase "installing a gh credential in ${container}"
  if printf '%s\n' "${pat}" | docker exec -i "${container}" sh -c \
    'umask 077; unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; gh auth logout --hostname github.com >/dev/null 2>&1 || true; gh auth login --hostname github.com --git-protocol https --with-token && gh auth setup-git && gh api /user >/dev/null'; then
    log "${container}: gh credential installed (rotate or remove it in GitHub -> Applications when work ends)"
    summary
  else
    warn "${container}: gh refused the token, or no gh/credential plumbing inside - nothing changed"
    summary
    return 1
  fi
}

# @function main
# Parse the subcommand and drive one or every workspace.
# Globals:
#   CODER_WORKSPACE_ID, EVO_T1_DEVCONTAINER
# Arguments:
#   $1.. - subcommand, then for check the optional --source=<slot> selector,
#     an optional container (host only) and an optional repo URL in either
#     order, or for auth the container and optionally - (a PAT as a further
#     argument is refused, because argv is readable through ps and keeps the
#     token in shell history)
# Outputs:
#   credential_probe output via probe_self (inside a workspace or contributor
#   devcontainer, where a named container argument is refused) or via
#   probe_workspace (on a host)
# Returns:
#   0, or 1 on a refused argument or a dead docker daemon
main() {
  local cmd="${1:-}"
  case "${cmd}" in
    check)
      section "check"
      shift
      local sel="chain" target="" repo_url="" repo=""
      while [[ ${1:-} == --* ]]; do
        case "${1}" in
          --source=*)
            sel="${1#--source=}"
            case "${sel}" in
              chain | env | gh | mint) ;;
              *) die "github-auth.sh: --source takes chain (default), env, gh or mint (got --source=${sel})" ;;
            esac
            ;;
          *) die "github-auth.sh: unknown flag ${1} (usage: bazelisk run //scripts:github-auth -- check [container] [repo-url] [--source=<slot>])" ;;
        esac
        shift
      done
      if [[ ${1:-} == *github.com* ]]; then
        repo_url="${1}"
      else
        target="${1:-}"
        repo_url="${2:-}"
      fi
      if [[ -n ${repo_url} ]]; then
        if ! repo="$(normalize_repo_path "${repo_url}")"; then
          die "github-auth.sh: pass a github.com repository - the clone or browser URL of one repo, with or without .git (got ${repo_url}). A path below owner/repo names no repository, and probing it would describe the wrong address."
        fi
      fi
      if in_self_env; then
        # Inside a workspace the docker CLI addresses this workspace's own
        # DinD sidecar; inside a contributor devcontainer it addresses the
        # workstation daemon. Neither is the stack host's workspace fleet,
        # so there is nothing to enumerate and a daemon that looks empty
        # here proves nothing. Probe this environment's own credential
        # chain instead, and never hand a probe to docker.
        if [[ -n ${target} ]]; then
          die "github-auth.sh: this is a workspace shell (CODER_WORKSPACE_ID or EVO_T1_DEVCONTAINER is set): check probes this environment's own credential (pass only the repo URL; a named container can be checked from the stack host)"
        fi
        probe_self "${repo}" "${sel}"
      elif [[ -n ${target} ]]; then
        probe_workspace "${target}" "${repo}" "${sel}"
      else
        local containers
        if ! containers="$(running_workspaces)"; then
          die "cannot list containers - is the docker daemon reachable from this host?"
        fi
        if [[ -z ${containers} ]]; then
          note "no running workspace containers - nothing to check"
        else
          local c
          while IFS= read -r c; do
            if [[ -n ${c} ]]; then
              probe_workspace "${c}" "${repo}" "${sel}"
            fi
          done <<<"${containers}"
        fi
      fi
      summary
      ;;
    auth)
      section "auth"
      shift
      local container="${1:-}"
      [[ -n ${container} ]] || die "usage: bazelisk run //scripts:github-auth -- auth <container> [-]  (- or nothing: read the PAT from stdin)"
      # A PAT never travels in argv: any other process in that container can
      # read it through ps, and the token lands in shell history, so only -
      # (read the PAT from stdin) or nothing (prompt) may follow the container.
      if [[ $# -gt 2 || ${2:-} != "-" && $# -gt 1 ]]; then
        die "github-auth.sh: a PAT is never an argument (argv is readable through ps and lands in shell history): pipe it in with 'bazelisk run //scripts:github-auth -- auth ${container} -', or run 'bazelisk run //scripts:github-auth -- auth ${container}' to be prompted"
      fi
      local pat=""
      # - or a non-TTY stdin means the PAT is on stdin; a bare container at a
      # TTY prompts for it. Either way it reaches gh on stdin, never in argv.
      if [[ $# -eq 1 && -t 0 ]]; then
        printf 'Paste the GitHub token (input not echoed): ' >&2
        read -rs pat || true
        printf '\n' >&2
      else
        # bazelisk run keeps stdin open with no EOF; without -t this waits forever.
        IFS= read -r -t 15 pat || true
      fi
      auth_workspace "${container}" "${pat}"
      ;;
    -h | --help | help)
      # The whole header comment, up to the first blank line: the verdict
      # kinds, both argument orders and both modes live there, and a fixed
      # line count silently truncates them.
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}"
      ;;
    *)
      die "usage: bazelisk run //scripts:github-auth -- check [container] [repo-url] [--source=<slot>] | auth <container> [-] | -h"
      ;;
  esac
}

main "$@"
