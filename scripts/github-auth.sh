#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## github-auth.sh - workspace GitHub credential doctor and one-line auth (entry point)
#
# A workspace talks to github.com over HTTPS, and git consults credential
# sources in this order: GH_TOKEN/GITHUB_TOKEN from the agent environment (they
# exist only when the owner connected a GitHub account to the External Auth
# provider named by CODER_GITHUB_AUTH_ID, default `github`), then whatever the
# gh CLI holds - that env token first, then the stored login in the
# per-workspace gh auth store that the gh_token_refresh coder_script re-mints
# on start and every 6 hours - and only then a direct
# `coder external-auth access-token` mint (CODER_GITHUB_AUTH_ID, then
# `primary-github` for workspaces that still declare the legacy custom-OAuth
# id). Authenticating is not the same as being able to write, and a PUBLIC
# repo answers api.github.com /repos with 200 for any authenticated caller:
# a credential that only READS used to print a false pass here. So `check`
# now asks the WRITE question once per credential - one GET of
# <repo>.git/info/refs?service=git-receive-pack, the endpoint git push
# itself negotiates through - and a read-only credential prints REFUSED-GRANT,
# never a pass.
#
# Usage:
#   scripts/github-auth.sh check [repo-url]                    (inside a workspace)
#   scripts/github-auth.sh check [container] [repo-url] (on the stack host)
#       Inside a workspace (CODER_WORKSPACE_ID set) the docker CLI addresses
#       that workspace's own DinD sidecar, never the host daemon, so check
#       runs SELF mode there: no docker at all, one probe of this
#       environment's own credential chain, one `self:` line printed. On the
#       host (CODER_WORKSPACE_ID empty) check lists the labeled workspace
#       containers via docker ps and probes each; a named container checks
#       just that one. With a repo URL every probe answers "can this
#       credential WRITE to that repo?": PUSH-READY (200 advertising refs),
#       REFUSED-GRANT (403: authenticates, still refused; grant the
#       provider's grant on that repo, or install a write-scope PAT),
#       NOT VISIBLE (404: private repo hidden from this credential, or
#       absent), REJECTED (401: credential refused outright; re-mint or
#       reconnect), or no useful answer (offline? probe again).
#       Prints source names and verdicts only; never token bytes.
#   scripts/github-auth.sh auth <container> [-]
#       Install a write-capable credential into that ONE workspace: the PAT
#       arrives on stdin only (the - form, or a TTY prompt). A second argument
#       is refused: argv is readable through `ps` by any other process in that
#       container and the token lands in shell history. The token then goes to
#       `gh auth login --hostname github.com --with-token` inside the
#       container, and `gh auth setup-git` wires git's credential helper to gh,
#       replacing the gh login that host had before. Legitimate when the owner
#       connected no Coder account (nothing can be minted), or when check
#       just proved the minted/App credential READ-ONLY: re-mint or
#       reconnect the provider first; paste a PAT only when neither is left.
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

# @function credential_probe
# Print the POSIX sh probe script that answers the WRITE question for one
# credential: resolve the chain (env GITHUB_TOKEN/GH_TOKEN, then gh auth
# token, then a coder external-auth mint for CODER_GITHUB_AUTH_ID, then the
# legacy primary-github id), then issue exactly one GET of
# <repo>.git/info/refs?service=git-receive-pack - the endpoint git push
# itself negotiates through - with the credential on curl's Basic auth line.
# The credential reaches curl through --config - on stdin, never argv, where
# any other process could read it from `ps`; it is never printed either.
# The HTTP status is the discriminator, never body wording: 200 whose body
# advertises refs means PUSH-READY, 403 REFUSED-GRANT, 404 NOT VISIBLE,
# 401 REJECTED, anything else no useful answer. A PUBLIC repo answers the
# same endpoint 401/403 while refusing the write, which is exactly the false
# pass the old api.github.com /repos read probe printed as a pass.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One POSIX sh script on stdout; run it with sh -c and three arguments:
#   $1 the label to print, $2 the optional repo path owner/repo, $3 the text
#   the fix pointers name as "github-auth.sh auth <that> -"
# Returns:
#   0
credential_probe() {
  cat <<'PROBE'
ws="$1"
repo="${2:-}"
fix="${3:-self}"
tok=""; src="none"
id="${CODER_GITHUB_AUTH_ID:-github}"
if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
  src="env token (GITHUB_TOKEN/GH_TOKEN)"
  tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
elif command -v gh >/dev/null 2>&1 && gh_tok=$(gh auth token 2>/dev/null) && [ -n "${gh_tok}" ]; then
  src="gh stored login"
  tok="${gh_tok}"
elif mint=$(timeout 15 coder external-auth access-token "${id}" 2>/dev/null) && [ -n "${mint}" ]; then
  src="Coder external-auth minted token"
  tok="${mint}"
elif [ "${id}" != "primary-github" ] && mint=$(timeout 15 coder external-auth access-token primary-github 2>/dev/null) && [ -n "${mint}" ]; then
  src="Coder external-auth minted token"
  tok="${mint}"
fi
if [ -z "${tok}" ]; then
  printf "%s: NO GitHub credential (git will prompt and be refused); fix: pipe a PAT into scripts/github-auth.sh auth %s -\n" "${ws}" "${fix}"
  exit 0
fi
if [ -z "${repo}" ]; then
  printf "%s: credential present (source: %s); pass the repo URL to check its grants\n" "${ws}" "${src}"
  exit 0
fi
tmp="$(mktemp 2>/dev/null)" || tmp="${TMPDIR:-/tmp}/github-auth-probe.$$"
answer=$(printf 'user = "x-access-token:%s"\n' "${tok}" | curl -s --max-time 10 --config - -o "${tmp}" -w '%{http_code}' "https://github.com/${repo}.git/info/refs?service=git-receive-pack" 2>/dev/null) || answer=""
verdict="none"
case "${answer}" in
  200) if grep -qF 'service=git-receive-pack' "${tmp}" 2>/dev/null; then verdict="PUSH-READY"; fi ;;
  403) verdict="REFUSED-GRANT" ;;
  404) verdict="NOT VISIBLE" ;;
  401) verdict="REJECTED" ;;
esac
rm -f "${tmp}"
case "${verdict}" in
  PUSH-READY)
    printf "%s: credential present (source: %s) and %s answered PUSH-READY (the receive-pack advertisement came back through this credential, so a push would negotiate)\n" "${ws}" "${src}" "${repo}"
    ;;
  REFUSED-GRANT)
    printf "%s: credential present (source: %s) but REFUSED-GRANT on %s (the credential authenticates yet every write is denied, which is exactly the push 403): grant the provider's grant on this repo (GitHub -> Settings -> Applications -> <app> -> Configure -> Repository access), or from a host shell: bazelisk run //scripts:github-auth -- auth %s - (paste a write-scope PAT on stdin; rotate when done)\n" "${ws}" "${src}" "${repo}" "${fix}"
    ;;
  "NOT VISIBLE")
    printf "%s: credential present (source: %s) but %s is NOT VISIBLE to this credential (a private repo hidden from it, or absent): clone and push would both fail\n" "${ws}" "${src}" "${repo}"
    ;;
  REJECTED)
    printf "%s: credential present (source: %s) but REJECTED (github.com refused the credential outright; an expired or revoked mint behaves like this): fix: re-mint it with 'coder external-auth access-token %s' from a workspace shell, or reconnect the provider in the Coder UI (Settings -> Tokens -> external auth)\n" "${ws}" "${src}" "${id}"
    ;;
  *)
    printf "%s: credential present (source: %s); github.com gave no useful answer for %s (offline? probe again)\n" "${ws}" "${src}" "${repo}"
    ;;
esac
PROBE
}

# @function probe_self
# SELF mode: run the credential probe directly in THIS environment (inside a
# workspace that is the workspace's own credential chain; no docker
# anywhere, because docker here addresses the DinD sidecar, never the host
# daemon). No container is enumerated and none is named: one report line,
# prefixed "self:", naming credential source and verdict only.
# Globals:
#   None
# Arguments:
#   $1 - optional repo path (owner/repo) to probe
# Outputs:
#   One report line prefixed "self:"
# Returns:
#   0 unless sh itself failed
probe_self() {
  local repo="${1:-}" probe
  probe="$(credential_probe)"
  if [[ -n ${repo} ]]; then
    sh -c "${probe}" sh self "${repo}" '<container>'
  else
    sh -c "${probe}" sh self "" '<container>'
  fi
}

# @function probe_workspace
# HOST mode: ask one workspace container what credential its git/gh would
# present to github.com (env token, gh stored login, then a fresh external-
# auth mint) and, when a repo path is given, whether that credential can
# WRITE to the repo. The probe runs as one POSIX sh -c inside the
# container, so PATH and env there decide what really answers, exactly like
# a real git push would; this function never prints a token value and hands
# that credential to curl on stdin through curl's --config - channel, not
# in curl's argv, where any other process could read it from `ps`.
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
  local container="$1" repo="${2:-}" probe
  probe="$(credential_probe)"
  # The sh -c arg order is (placeholder name, $1=container, $2=repo,
  # $3=the name the fix pointers print). Positional args, not -e env,
  # because the Bats docker stub passes argv through verbatim, keeping
  # host-side tests faithful.
  if [[ -n ${repo} ]]; then
    docker exec "${container}" sh -c "${probe}" sh "${container}" "${repo}" "${container}"
  else
    docker exec "${container}" sh -c "${probe}" sh "${container}" "" "${container}"
  fi
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
    warn "${container}: empty PAT - nothing installed (pipe the token: echo \$TOKEN | scripts/github-auth.sh auth ${container} -)"
    return 1
  fi
  # login exits non-zero on its own when the token fails to authenticate.
  if printf '%s\n' "${pat}" | docker exec -i "${container}" sh -c \
    'umask 077; gh auth logout --hostname github.com >/dev/null 2>&1 || true; gh auth login --hostname github.com --git-protocol https --with-token && gh auth setup-git && gh api /user >/dev/null'; then
    log "${container}: gh credential installed (rotate or remove it in GitHub -> Applications when work ends)"
  else
    warn "${container}: gh refused the token, or no gh/credential plumbing inside - nothing changed"
    return 1
  fi
}

# ── Commands ───────────────────────────────────────────────────────────────

# @function main
# Parse the subcommand and drive one or every workspace.
# Globals:
#   CODER_WORKSPACE_ID
# Arguments:
#   $1.. - subcommand, then for check an optional container (host only) and
#     an optional repo URL, or for auth the container and optionally - (a
#     PAT as a further argument is refused, because argv is readable
#     through ps and keeps the token in shell history)
# Outputs:
#   credential_probe output via probe_self (inside a workspace, where a
#   named container argument is refused) or via probe_workspace (on a host)
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
      if [[ -n ${CODER_WORKSPACE_ID:-} ]]; then
        # Inside a workspace the docker CLI addresses this workspace's own
        # DinD sidecar, never the host daemon, so there is nothing to
        # enumerate and a daemon that looks empty here proves nothing.
        # Probe this environment's own credential chain instead, and never
        # hand a probe to docker.
        if [[ -n ${target} ]]; then
          die "github-auth.sh: CODER_WORKSPACE_ID is set, so this is a workspace shell: check probes this workspace's own credential (pass only the repo URL; a named container can be checked from the stack host)"
        fi
        probe_self "${repo}"
      elif [[ -n ${target} ]]; then
        probe_workspace "${target}" "${repo}"
      else
        local containers
        if ! containers="$(running_workspaces)"; then
          die "cannot list containers - is the docker daemon reachable from this host?"
        fi
        if [[ -z ${containers} ]]; then
          note "no running workspace containers - nothing to check"
          return 0
        fi
        local c
        while IFS= read -r c; do
          if [[ -n ${c} ]]; then
            probe_workspace "${c}" "${repo}"
          fi
        done <<<"${containers}"
      fi
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
      # Whole header comment, lines 2-58: verdict kinds and both modes live there.
      sed -n '2,58p' "${BASH_SOURCE[0]}"
      ;;
    *)
      die "usage: github-auth.sh check [container] [repo-url] | auth <container> [-] | -h"
      ;;
  esac
}

main "$@"
