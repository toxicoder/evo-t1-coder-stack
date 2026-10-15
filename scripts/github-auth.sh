#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## github-auth.sh — workspace GitHub credential doctor and one-line auth (entry point)
#
# A workspace talks to github.com over HTTPS, and git consults credential
# sources in this order: GH_TOKEN/GITHUB_TOKEN from the agent environment (they
# exist only when the owner connected a GitHub account to the `primary-github`
# external-auth provider), then whatever the gh CLI holds — that env token
# first, then the stored login in the per-workspace gh auth store that the
# gh_token_refresh coder_script re-mints on start and every 6 hours — and only
# then a direct `coder external-auth access-token primary-github` mint. A
# credential that authenticates but was never GRANTED the repository still
# fails clone/push: private repos answer 403 or 404 (a GitHub App or OAuth
# grant without write scope answers "Resource not accessible by integration").
# This script makes that state visible from the host, and fixes the
# no-credential case in one line: with no connected account the gh auth store
# is empty, so an installed PAT there IS the credential, reachable from shells
# launched outside the agent environment too.
#
# Usage:
#   scripts/github-auth.sh check [container] [repo-url]
#       Report the credential source every running workspace (or just
#       <container>) would present to github.com. With a repo URL, also probe
#       api.github.com for that repo WITH the live credential and say whether
#       the credential can read it — read access is the floor for clone/push,
#       so "no read grant" means push would be denied too. Prints source names
#       and verdicts only; never token bytes.
#   scripts/github-auth.sh auth <container> [-]
#       Install a write-capable credential into that ONE workspace: the PAT
#       arrives on stdin only (the - form, or a TTY prompt). A second argument
#       is refused: argv is readable through `ps` by any other process in that
#       container and the token lands in shell history. The token then goes to
#       `gh auth login --hostname github.com --with-token` inside the
#       container, and `gh auth setup-git` wires git's credential helper to gh,
#       replacing the gh login that host had before. Legitimate when the owner
#       connected no Coder account (nothing can be minted) or the minted/App
#       credential was revoked or expired. While an agent-env token exists gh
#       prefers that over the store, and the next `gh_token_refresh` run
#       (start, then every 6 hours) rewrites the store with a minted pair.
#       Rotate or remove the PAT in GitHub -> Applications when work ends.
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

# @function probe_workspace
# Ask one workspace container what credential git/gh would present to
# github.com (env token, gh login, then a fresh external-auth mint) and, when
# a repo path is given, whether that credential can read the repo. The probe
# runs as one POSIX sh -c inside the container, so PATH and env there decide
# what really answers, exactly like a real git clone would; this function
# itself never prints a token value, and it hands that credential to curl on
# stdin through curl's --config - channel instead of in curl's argv, where any
# other process in the container could read it from `ps`.
# Globals:
#   None
# Arguments:
#   $1 - container name
#   $2 - optional repo path (owner/repo) to probe
# Outputs:
#   One report line for the container
# Returns:
#   0 unless docker itself failed
probe_workspace() {
  local container="$1" repo="${2:-}"
  local probe
  probe='
    ws="$1"
    repo="$2"
    tok=""; src="none"
    if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
      src="env token (GITHUB_TOKEN/GH_TOKEN)"
      tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    elif command -v gh >/dev/null 2>&1 && gh_tok=$(gh auth token 2>/dev/null) && [ -n "${gh_tok}" ]; then
      src="gh stored login"
      tok="${gh_tok}"
    elif mint=$(timeout 15 coder external-auth access-token primary-github 2>/dev/null) && [ -n "${mint}" ]; then
      src="Coder external-auth minted token"
      tok="${mint}"
    fi
    if [ -z "${tok}" ]; then
      printf "%s: NO GitHub credential (git will prompt and be refused); fix: pipe a PAT into scripts/github-auth.sh auth %s -\n" "${ws}" "${ws}"
      exit 0
    fi
    if [ -z "${repo}" ]; then
      printf "%s: credential present (source: %s); pass the repo URL to check its grants\n" "${ws}" "${src}"
      exit 0
    fi
    if ! body=$(printf "header = \"Authorization: token ${tok}\"\n" | curl -s --max-time 10 --config - "https://api.github.com/repos/${repo}"); then
      printf "%s: credential present (source: %s); api.github.com gave no useful answer for %s (offline? probe again)\n" "${ws}" "${src}" "${repo}"
      exit 0
    fi
    case "${body}" in
      *"Resource not accessible"*)
        printf "%s: credential present (source: %s) but NOT GRANTED on %s -- auth would authenticate and still be denied (that is the push 403); fix: grant the token/App Contents write on that repo, or pipe a PAT into scripts/github-auth.sh auth %s -\n" "${ws}" "${src}" "${repo}" "${ws}"
        ;;
      *"full_name"*)
        printf "%s: credential present (source: %s) and %s is readable through it (read proves the credential is live; a token that can only READ still cannot push — grant Contents:write too, or check the App grant)\n" "${ws}" "${src}" "${repo}"
        ;;
      "" | *"Not Found"*)
        printf "%s: credential present (source: %s) but %s is NOT readable through it (private repo denied or absent) — clone and push would both fail\n" "${ws}" "${src}" "${repo}"
        ;;
      *)
        printf "%s: credential present (source: %s); api.github.com gave no useful answer for %s (offline? probe again)\n" "${ws}" "${src}" "${repo}"
        ;;
    esac
  '
  # The sh -c arg order is (name, $1=container, $2=repo); name is a placeholder
  # the probe never reads. Positional args (not -e env) because the Bats docker
  # stub passes argv through verbatim, keeping host-side tests faithful.
  if [[ -n ${repo} ]]; then
    docker exec "${container}" sh -c "${probe}" sh "${container}" "${repo}"
  else
    docker exec "${container}" sh -c "${probe}" sh "${container}"
  fi
}

# @function auth_workspace
# Install a PAT into one workspace through the gh CLI: replaces that host's
# previous gh login, points git's credential helper at gh, and verifies with
# `gh api /user`. The token travels on stdin only — never in argv.
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
    warn "${container}: empty PAT — nothing installed (pipe the token: echo \$TOKEN | scripts/github-auth.sh auth ${container} -)"
    return 1
  fi
  # login exits non-zero on its own when the token fails to authenticate.
  if printf '%s\n' "${pat}" | docker exec -i "${container}" sh -c \
    'umask 077; gh auth logout --hostname github.com >/dev/null 2>&1 || true; gh auth login --hostname github.com --git-protocol https --with-token && gh auth setup-git && gh api /user >/dev/null'; then
    log "${container}: gh credential installed (rotate or remove it in GitHub -> Applications when work ends)"
  else
    warn "${container}: gh refused the token, or no gh/credential plumbing inside — nothing changed"
    return 1
  fi
}

# ── Commands ───────────────────────────────────────────────────────────────

# @function main
# Parse the subcommand and drive one or every workspace.
# Globals:
#   None
# Arguments:
#   $1.. - subcommand, then for check an optional container and repo URL, or
#     for auth the container and optionally - (a PAT as a further argument is
#     refused, because argv is readable through ps and keeps the token in
#     shell history)
# Outputs:
#   probe_workspace / auth_workspace output
# Returns:
#   0, or 1 on a refused argument or a dead docker daemon
main() {
  local cmd="${1:-}"
  case "${cmd}" in
    check)
      shift
      local target="" repo_url="" repo=""
      if [[ ${1:-} == *github.com* ]]; then
        repo_url="${1}"
      else
        target="${1:-}"
        repo_url="${2:-}"
      fi
      if [[ -n ${repo_url} ]]; then
        case "${repo_url}" in
          *github.com*) repo="$(sed -E 's|.*github\.com[:/]||; s|\.git$||' <<<"${repo_url}")" ;;
          *) die "github-auth.sh: probe only understands github.com URLs (got ${repo_url})" ;;
        esac
      fi
      local containers
      if [[ -n ${target} ]]; then
        containers="${target}"
      else
        containers="$(running_workspaces)" || die "cannot list containers — is the docker daemon reachable from this host?"
      fi
      if [[ -z ${containers} ]]; then
        note "no running workspace containers — nothing to check"
        return 0
      fi
      local c
      while IFS= read -r c; do
        if [[ -n ${c} ]]; then
          probe_workspace "${c}" "${repo}"
        fi
      done <<<"${containers}"
      ;;
    auth)
      shift
      local container="${1:-}"
      [[ -n ${container} ]] || die "usage: github-auth.sh auth <container> [-]  (- or nothing: read the PAT from stdin)"
      # A PAT never travels in argv: any other process in that container can
      # read it through ps, and the token lands in shell history, so only -
      # (read the PAT from stdin) or nothing (prompt) may follow the container.
      if [[ $# -gt 2 || ${2:-} != "-" && $# -gt 1 ]]; then
        die "github-auth.sh: a PAT is never an argument (argv is readable through ps and lands in shell history): pipe it in with 'github-auth.sh auth ${container} -', or run 'github-auth.sh auth ${container}' to be prompted"
      fi
      local pat=""
      # - or a non-TTY stdin means the PAT is on stdin; a bare container at a
      # TTY prompts for it. Either way it reaches gh on stdin, never in argv.
      if [[ $# -eq 1 && -t 0 ]]; then
        printf 'Paste the GitHub token (input not echoed): ' >&2
        read -rs pat || true
        printf '\n' >&2
      else
        read -r pat || true
      fi
      auth_workspace "${container}" "${pat}"
      ;;
    -h | --help | help)
      sed -n '2,48p' "${BASH_SOURCE[0]}"
      ;;
    *)
      die "usage: github-auth.sh check [container] [repo-url] | auth <container> [-] | -h"
      ;;
  esac
}

main "$@"
