#!/bin/sh
# shellcheck shell=sh
#
# ## probes/github-auth-fix.sh — Put a credential git really consults in place, in one container (POSIX probe; run with sh, never sourced by the remote)

ws="$1"
repo="${2:-}"
envtok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
id="${CODER_GITHUB_AUTH_ID:-github}"
ghbin=""
command -v gh >/dev/null 2>&1 && ghbin="$(command -v gh)"
GITCFG="${EVO_T1_GITCONFIG:-$HOME/.gitconfig}"

# @function mint_token
# Inside the repair probe: ask Coder for a live token. The pair the agent
# environment carries was minted when the workspace started and expires while
# the workspace keeps running, so the live answer always comes from this call
# and never from the environment. A custom provider id falls back to the legacy
# primary-github id the same way the read probe does.
# Globals:
#   CODER_GITHUB_AUTH_ID
# Arguments:
#   None
# Outputs:
#   The token on stdout; nothing when no provider is linked or coder is absent
# Returns:
#   0 always
mint_token() {
  m=""
  m="$(timeout -k 2 15 coder external-auth access-token "${id}" 2>/dev/null)" || m=""
  if [ -z "${m}" ] && [ "${id}" != "primary-github" ]; then
    m="$(timeout -k 2 15 coder external-auth access-token primary-github 2>/dev/null)" || m=""
  fi
  printf '%s' "${m}"
}

# @function store_token
# Inside the repair probe: read the gh auth store with the env pair cleared, so
# a stale pair cannot be mistaken for what is actually stored.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The stored token on stdout; nothing when gh is absent or the store is empty
# Returns:
#   0 always
store_token() {
  [ -n "${ghbin}" ] || {
    printf ''
    return 0
  }
  s=""
  # shellcheck disable=SC1007 # the space after = is how an empty env assignment reads
  s="$(GITHUB_TOKEN= GH_TOKEN= gh auth token 2>/dev/null)" || s=""
  printf '%s' "${s}"
}

# @function install_helper
# Inside the repair probe: point git's github.com credential helper at the gh
# auth store in a way the agent environment cannot override.
#
# This is the repair itself, and the reason a plain `gh auth setup-git` is not
# enough. setup-git installs `!gh auth git-credential`, and that helper echoes
# GH_TOKEN/GITHUB_TOKEN whenever either is set. The pair Coder injects at
# workspace start is a frozen copy that expires about an hour later, so for the
# rest of the workspace's life git sends a dead token and every push dies with
# `Password authentication is not supported for Git operations.` while the
# stored credential next to it is healthy. Clearing the pair for the helper
# makes git read the store, which gh_token_refresh keeps live, so push stops
# depending on an environment variable nobody can rewrite from inside a running
# workspace.
#
# An empty helper entry is written first on purpose: it is git's reset marker,
# and it drops any helper inherited from a lower-precedence config file.
# Globals:
#   ghbin, GITCFG
# Arguments:
#   None
# Outputs:
#   One line naming what was installed, or why it could not be
# Returns:
#   0 when the helper is in place, 1 otherwise
install_helper() {
  if [ -z "${ghbin}" ]; then
    printf '%s: cannot install the credential helper - gh is not installed in this environment; install gh (apt install gh, or the pinned copy the golden image ships) and run this again\n' "${ws}"
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    printf '%s: cannot install the credential helper - git is not installed in this environment\n' "${ws}"
    return 1
  fi
  want="!env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN ${ghbin} auth git-credential"
  if git config --file "${GITCFG}" --get-all credential.https://github.com.helper 2>/dev/null |
    grep -qF 'env -u GH_TOKEN'; then
    printf '%s: credential helper already ignores the agent env pair\n' "${ws}"
    return 0
  fi
  # gist gets the same treatment: gh auth setup-git writes both hosts, and a
  # half-repaired config reads as a mystery a year later.
  for host in github.com gist.github.com; do
    git config --file "${GITCFG}" --replace-all "credential.https://${host}.helper" '' || return 1
    git config --file "${GITCFG}" --add "credential.https://${host}.helper" "${want}" || return 1
  done
  printf '%s: git now reads the gh auth store for github.com, whatever GH_TOKEN holds\n' "${ws}"
  return 0
}

# helper-only mode installs the credential helper and touches no credential.
# `github-auth.sh auth` needs it after piping a PAT into the store: that
# subcommand ends in `gh auth setup-git`, which installs the plain
# `!gh auth git-credential` helper, and that helper would go straight back to
# echoing a stale env pair over the healthy token just installed.
if [ "${EVO_T1_FIX_MODE:-full}" = "helper-only" ]; then
  install_helper || exit 4
  printf '%s: credential helper installed; the credential already in the gh auth store is now the one git reads\n' "${ws}"
  exit 0
fi

tok="$(mint_token)"
src="token minted from Coder external-auth"
stored="$(store_token)"
if [ -z "${tok}" ]; then
  if [ -n "${stored}" ]; then
    tok="${stored}"
    src="token already in the gh auth store"
  else
    printf '%s: HANDOFF - nothing can be minted and the gh store is empty, so no command run in this workspace can fix it. The human has to: (1) open the workspace in the Coder UI and click GitHub reauth, finishing the GitHub device-code login; (2) for private repos, click Install GitHub App and grant this repository at https://github.com/apps/coder/installations/new; (3) restart the workspace. Then run bazelisk run //scripts:github-auth -- check again.\n' "${ws}"
    exit 4
  fi
fi

# Write the live token into the store before pointing git at it, so the store is
# the freshest copy rather than whatever the last refresh left there.
if [ -n "${ghbin}" ] && [ "${tok}" != "${stored}" ]; then
  printf '%s: writing the %s into the gh auth store\n' "${ws}" "${src}"
  # gh prefers GH_TOKEN/GITHUB_TOKEN over stdin and refuses --with-token while
  # either stands, so the pair goes before the login, exactly as the startup
  # refresh script does.
  if ! printf '%s' "${tok}" |
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
      "${ghbin}" auth login --hostname github.com --git-protocol https --with-token >/dev/null 2>&1; then
    printf '%s: gh refused the token, so the store is unchanged - the credential is likely revoked or the account disconnected; run bazelisk run //scripts:github-auth -- check to see what github.com says about it\n' "${ws}"
    exit 4
  fi
  env -u GH_TOKEN -u GITHUB_TOKEN "${ghbin}" auth setup-git >/dev/null 2>&1 || true
fi

install_helper || exit 4

if [ -n "${envtok}" ] && [ "${envtok}" != "${tok}" ]; then
  printf '%s: note: GH_TOKEN/GITHUB_TOKEN still carry the copy Coder injected at workspace start, and no process can rewrite another process environment. gh itself consults that pair first, so for gh commands use: env -u GH_TOKEN -u GITHUB_TOKEN gh <args>\n' "${ws}"
fi
if [ -n "${repo}" ]; then
  printf '%s: repaired with the %s; the caller re-probes the write endpoint to prove it\n' "${ws}" "${src}"
  exit 0
fi
printf '%s: repaired with the %s\n' "${ws}" "${src}"
exit 0
