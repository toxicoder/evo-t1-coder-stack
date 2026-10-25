# shellcheck shell=bash
#
# ## bootstrap.sh — pure helpers for scripts/bootstrap.sh (sourced; never executed)
#
# The entry script owns the first-boot sequence. These helpers own secret
# generation, in-place .env edits, and the agent-endpoint probe so those pieces
# can be tested without running the rest of bootstrap.
#
# Usage (after set -euo pipefail and the repo-root cd):
#   # shellcheck source=lib/bootstrap.sh disable=SC1091
#   source "scripts/lib/bootstrap.sh"

if ! declare -f die >/dev/null 2>&1; then
  # shellcheck source=lib/common.sh disable=SC1091
  source "${BASH_SOURCE[0]%/*}/common.sh"
fi

# @function gen_secret
# Print one 32-hex-character secret from openssl.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   32 hex characters and a newline (openssl's own)
# Returns:
#   openssl's status
gen_secret() {
  openssl rand -hex 16
}

# @function sed_inplace
# Apply one sed script in place. GNU sed uses -i; BSD sed uses -i ''.
# Globals:
#   None
# Arguments:
#   $1 - sed script
#   $2... - files
# Outputs:
#   None
# Returns:
#   sed's status
sed_inplace() {
  local script="$1"
  shift
  if sed --version >/dev/null 2>&1; then
    sed -i "$script" "$@"
  else
    sed -i '' "$script" "$@"
  fi
}

# @function set_secret
# Replace one .env assignment in the current directory with a fresh secret.
# Globals:
#   None
# Arguments:
#   $1 - variable name
# Outputs:
#   "generated <name>" on stdout
# Returns:
#   0
set_secret() {
  local value
  value="$(gen_secret)"
  sed_inplace "s|^${1}=.*|${1}=${value}|" .env
  echo "generated ${1}"
}

# @function upsert_env
# Write one .env key in the current directory when it is missing or different.
# An empty value clears the key so compose's `:-` fallback applies.
# Globals:
#   None
# Arguments:
#   $1 - variable name
#   $2 - value
# Outputs:
#   "set KEY=value" when the file changes, otherwise nothing
# Returns:
#   0
upsert_env() {
  local key="$1" value="$2" current
  if ! grep -q "^${key}=" .env; then
    printf '%s=%s\n' "${key}" "${value}" >>.env
    echo "set ${key}=${value}"
    return 0
  fi
  current="$(sed -n "s|^${key}=||p" .env | tail -n 1)"
  if [ "${current}" != "${value}" ]; then
    sed_inplace "s|^${key}=.*|${key}=${value}|" .env
    echo "set ${key}=${value}"
  fi
}

# @function probe_agent_endpoint
# Probe one OpenAI-compatible agent URL and print whether it answered.
# The host keeps its port. An empty URL is a warning, not a failure.
# Globals:
#   None
# Arguments:
#   $1 - env key name, used only in the warning text
#   $2 - URL
# Outputs:
#   A reachable line or a warning
# Returns:
#   0
probe_agent_endpoint() {
  local name="$1" url="$2"
  [ -n "${url}" ] || {
    echo "warning: ${name} is empty — the agent aliases cannot route."
    return 0
  }
  local host
  host="$(printf '%s' "${url}" | sed -E 's|^https?://||; s|/.*$||')"
  if curl -fsS -m 5 -o /dev/null "http://${host}/v1/models" 2>/dev/null ||
    curl -fsS -m 5 -o /dev/null "${url}/models" 2>/dev/null; then
    echo "agent endpoint reachable: ${host}"
  else
    echo "warning: no agent endpoint answered at ${host} — the agent aliases fall back to the Arc coder/coder-fast aliases, which return tool calls as plain text. Start a Spark inference server, set ${name} in .env, or point GROK_DEFAULT_MODEL at chat (qwen2.5:7b does emit tool calls)."
  fi
}

# @function classify_public_entry
# Classify one STACK_PUBLIC_HOSTS entry.
# Globals:
#   None
# Arguments:
#   $1 - trimmed DNS name or junk
# Outputs:
#   "ok <role> <https-url>" or "skip <reason>"
# Returns:
#   0
classify_public_entry() {
  local entry="$1"
  case "${entry}" in
    *:*)
      printf 'skip url\n'
      return 0
      ;;
    */* | *[!A-Za-z0-9.-]*)
      printf 'skip dns\n'
      return 0
      ;;
  esac
  case "${entry}" in
    coder-* | coder.*) printf 'ok coder https://%s\n' "${entry}" ;;
    kasm-* | kasm.*) printf 'ok kasm https://%s\n' "${entry}" ;;
    litellm-* | litellm.*) printf 'ok litellm https://%s\n' "${entry}" ;;
    hermes-* | hermes.*) printf 'ok hermes https://%s\n' "${entry}" ;;
    *) printf 'ok dashboard https://%s\n' "${entry}" ;;
  esac
}

# @function stack_host_path
# Print the physical path of the stack checkout. Prefer
# BUILD_WORKSPACE_DIRECTORY (bazelisk run names the real checkout) so a
# runfiles cwd cannot become the hermes bind source.
# Globals:
#   BUILD_WORKSPACE_DIRECTORY
# Arguments:
#   None
# Outputs:
#   One absolute path
# Returns:
#   0
stack_host_path() {
  if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ] && [ -f "${BUILD_WORKSPACE_DIRECTORY}/docker-compose.yml" ]; then
    (cd "${BUILD_WORKSPACE_DIRECTORY}" && pwd -P)
    return 0
  fi
  pwd -P
}

# @function host_user_ids
# Print the calling user's uid:gid. hermes-init chowns /opt/data to this pair
# so the gateway can reopen the seed after s6 drops privileges.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   uid:gid
# Returns:
#   0
host_user_ids() {
  printf '%s:%s\n' "$(id -u)" "$(id -g)"
}

# @function dind_image_ref
# Print the dind_image string from a Terraform file, or the default tag.
# Globals:
#   None
# Arguments:
#   $1 - path to main.tf
# Outputs:
#   Image reference
# Returns:
#   0
dind_image_ref() {
  local image=""
  if [ -f "$1" ]; then
    image="$(sed -nE 's/^[[:space:]]*dind_image[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$1" | head -n 1)"
  fi
  printf '%s\n' "${image:-docker:29.8.1-dind}"
}

# @function warn_missing_router_hosts
# Warn when a public DNS name is not a server_name in proxy/router.conf.
# Globals:
#   None
# Arguments:
#   $1 - path to router.conf
#   remaining - DNS names
# Outputs:
#   One warning line per unmatched name on stdout
# Returns:
#   0
warn_missing_router_hosts() {
  local conf="${1:-}"
  if [ -z "${conf}" ] || [ ! -f "${conf}" ]; then
    return 0
  fi
  shift
  local names=("$@")
  local name
  for name in ${names[@]+"${names[@]}"}; do
    [ -n "${name}" ] || continue
    # Fixed string, trailing semicolon included: a bare "gmktecbeast" must not
    # be satisfied by the "coder-gmktecbeast" block that merely ends with it.
    if ! grep -Fq -- "server_name ${name};" "${conf}"; then
      echo "warning: ${name} is not a server_name in ${conf}: the router answers 421 for that Host, so add the server block or fix STACK_PUBLIC_HOSTS"
    fi
  done
  return 0
}
