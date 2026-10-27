# shellcheck shell=bash
#
# ## domain.sh — composed public hostnames (sourced; never executed)
#
# One place that turns composable parts into the stack's public DNS names, so an
# operator sets a zone and a box label once instead of typing five long names into
# STACK_PUBLIC_HOSTS and again into the router's vhost table.
#
# The grammar is fixed: `<service>-<environment>-<suffix>.<base>`, always ONE label
# under the zone. A wildcard certificate covers exactly one label, so the dotted
# two-label form (`coder.gmktecbeast.`) has no certificate at the public edge and the
# browser aborts the handshake before Traefik is reached. The environment label sits
# AFTER the service prefix for that same reason and because classify_public_entry in
# lib/bootstrap.sh routes an entry by its service prefix: `coder-dev-box.example.com`
# is Coder, while `dev-coder-box.example.com` would fall through to the dashboard.
#
# Every part is normalized before it is joined. A part that cannot be a DNS label is
# dropped and reported rather than pasted into an `https://` origin, a
# HOMEPAGE_ALLOWED_HOSTS entry, a certificate SAN or an nginx server_name.
#
# Nothing here reads .env: callers resolve the keys they want and hand the values over
# through the environment, which is what lets a dev deploy carry a label the stable
# file does not have.
#
# Usage (after set -euo pipefail and the repo-root cd):
#   # shellcheck source=lib/domain.sh disable=SC1091
#   source "scripts/lib/domain.sh"
#   public_host_for STACK_CODER_NAME coder   # -> coder-gmktecbeast.overeazy.io
#   STACK_ENV_LABEL=dev public_host_for STACK_CODER_NAME coder

# The shipped defaults, in one table so .env.sample, the docs and the tests cannot
# drift from each other. The environment label and the dashboard name have no default
# on purpose: an unlabelled stable deploy and a zone-apex dashboard are the shapes that
# work without them.
: "${STACK_DOMAIN_BASE_DEFAULT:=overeazy.io}"
: "${STACK_SUBDOMAIN_SUFFIX_DEFAULT:=gmktecbeast}"

# @function domain_service_default
# Print the shipped default service label for one naming key, so the defaults live in
# exactly one case table. An unknown key prints nothing, which the caller treats as
# "no label" rather than guessing.
# Globals:
#   None
# Arguments:
#   $1 - the naming key, one of STACK_CODER_NAME, STACK_KASM_NAME, STACK_LITELLM_NAME,
#        STACK_HERMES_NAME, STACK_DASHBOARD_NAME
# Outputs:
#   The default label on stdout, or nothing for an unknown or unlabelled key
# Returns:
#   0 always
domain_service_default() {
  case "${1:-}" in
    STACK_CODER_NAME) printf 'coder\n' ;;
    STACK_KASM_NAME) printf 'kasm\n' ;;
    STACK_LITELLM_NAME) printf 'litellm\n' ;;
    STACK_HERMES_NAME) printf 'hermes\n' ;;
    *) printf '\n' ;;
  esac
}

# @function domain_part_value
# Print one naming part normalized: trimmed of spaces and CRs, lowercased, and stripped
# of leading and trailing dots and hyphens, so a value copied from a browser bar or left
# with a trailing dot cannot leak into an origin or a server_name.
# Globals:
#   None
# Arguments:
#   $1 - the raw part
# Outputs:
#   The normalized part on stdout, or nothing when the part is empty
# Returns:
#   0 when the part is empty or a valid DNS name, 1 when it holds characters a DNS name
#   cannot carry (a scheme, a slash, a port, an underscore, or punctuation at a join)
domain_part_value() {
  local raw="${1-}" normalized
  raw="${raw//"$(printf '\r')"/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [ -n "${raw}" ] || return 0
  normalized="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' |
    sed -E 's/^[-.]+//; s/[-.]+$//')"
  [ -n "${normalized}" ] || return 0
  if [[ ! ${normalized} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
    return 1
  fi
  printf '%s\n' "${normalized}"
}

# @function domain_part
# Print one naming part resolved from the environment: the named variable when it holds
# anything, the fallback when it is unset or empty. The fallback is passed in rather than
# baked in so a caller can override one part without touching the table.
# Globals:
#   None
# Arguments:
#   $1 - variable name to read
#   $2 - fallback used when that variable is unset or empty
# Outputs:
#   The normalized part on stdout, or nothing when both are empty
# Returns:
#   0 when the part is empty or valid, 1 when the value is unusable
domain_part() {
  local name="$1" fallback="${2:-}" raw
  raw="${!name-}"
  [ -n "${raw}" ] || raw="${fallback}"
  domain_part_value "${raw}"
}

# @function public_host_for
# Print the public DNS name for one service: the service label, then the optional
# environment label, then the box suffix, then the domain base, joined with hyphens. An
# empty service label yields the zone apex, which is the dashboard's shape. Prints
# nothing when the zone is missing or any part is unusable, so a caller keeps its LAN
# default instead of building `https://-gmktecbeast.overeazy.io`.
# Globals:
#   STACK_DOMAIN_BASE, STACK_SUBDOMAIN_SUFFIX, STACK_ENV_LABEL, and the key named by $1
# Arguments:
#   $1 - naming key to read the service label from; empty or omitted for the zone apex
#   $2 - default service label when that key is unset or empty
# Outputs:
#   One DNS name on stdout, or nothing
# Returns:
#   0 when a name was printed, 1 when a part was missing or invalid
public_host_for() {
  local key="${1:-}" label_default="${2:-}" base suffix label service="" host
  base="$(domain_part STACK_DOMAIN_BASE "${STACK_DOMAIN_BASE_DEFAULT}")" || return 1
  suffix="$(domain_part STACK_SUBDOMAIN_SUFFIX "${STACK_SUBDOMAIN_SUFFIX_DEFAULT}")" || return 1
  label="$(domain_part STACK_ENV_LABEL)" || return 1
  if [ -n "${key}" ]; then
    service="$(domain_part "${key}" "${label_default}")" || return 1
  fi
  [ -n "${base}" ] && [ -n "${suffix}" ] || return 1
  host=""
  [ -n "${service}" ] && host="${service}-"
  [ -n "${label}" ] && host="${host}${label}-"
  printf '%s%s.%s\n' "${host}" "${suffix}" "${base}"
}

# @function public_hosts_default
# Print the comma-separated name list STACK_PUBLIC_HOSTS carries, composed from the
# parts: dashboard, coder, kasm, litellm, hermes. A service whose name will not compose
# is left out rather than sent as an empty list item, and the line is empty when the zone
# itself is missing, which is LAN-only.
# Globals:
#   STACK_DOMAIN_BASE, STACK_SUBDOMAIN_SUFFIX, STACK_ENV_LABEL, STACK_DASHBOARD_NAME,
#   STACK_CODER_NAME, STACK_KASM_NAME, STACK_LITELLM_NAME, STACK_HERMES_NAME
# Arguments:
#   None
# Outputs:
#   A comma-separated list of DNS names on stdout, possibly empty
# Returns:
#   0 always
public_hosts_default() {
  local keys=('' STACK_CODER_NAME STACK_KASM_NAME STACK_LITELLM_NAME STACK_HERMES_NAME)
  local key name host out=""
  for key in "${keys[@]}"; do
    name="$(domain_part "${key:-STACK_DASHBOARD_NAME}" "$(domain_service_default "${key}")")" || continue
    host="$(public_host_for "${key}" "${name}")" || continue
    if [ -n "${out}" ]; then
      out="${out},${host}"
    else
      out="${host}"
    fi
  done
  printf '%s\n' "${out}"
}

# @function public_urls_default
# Print `key=value` lines for the five derived origins a public deploy needs, one per
# line, in the order bootstrap writes them into .env. An origin whose name will not
# compose is emitted with an empty value, which is what clears the key and lets compose's
# LAN fallback apply.
# Globals:
#   STACK_DOMAIN_BASE, STACK_SUBDOMAIN_SUFFIX, STACK_ENV_LABEL, STACK_DASHBOARD_NAME,
#   STACK_CODER_NAME, STACK_KASM_NAME, STACK_LITELLM_NAME, STACK_HERMES_NAME
# Arguments:
#   None
# Outputs:
#   Lines shaped STACK_CODER_URL=https://coder-box.example.com on stdout
# Returns:
#   0 always
public_urls_default() {
  local pair key role host
  for pair in "STACK_DASHBOARD_URL:STACK_DASHBOARD_NAME" "STACK_CODER_URL:STACK_CODER_NAME" \
    "STACK_KASM_URL:STACK_KASM_NAME" "STACK_LITELLM_URL:STACK_LITELLM_NAME" \
    "STACK_HERMES_URL:STACK_HERMES_NAME"; do
    key="${pair%%:*}"
    role="${pair##*:}"
    host="$(public_host_for "${role}" "$(domain_service_default "${role}")")" || host=""
    printf '%s=%s\n' "${key}" "${host:+https://${host}}"
  done
  return 0
}

# @function render_public_router_conf
# Write the public router nginx config for the composed names by substituting the
# __EVO_HOST_*__ tokens in the template. The token set is exactly the five vhosts the
# router answers, so a rendered file cannot gain or lose a service on its own. Writes
# nothing when a name will not compose or a token survived: half a vhost table would
# answer 421 for a name Traefik is forwarding, which is worse than no render at all.
# Globals:
#   STACK_DOMAIN_BASE, STACK_SUBDOMAIN_SUFFIX, STACK_ENV_LABEL, STACK_DASHBOARD_NAME,
#   STACK_CODER_NAME, STACK_KASM_NAME, STACK_LITELLM_NAME, STACK_HERMES_NAME
# Arguments:
#   $1 - path to the tokenized template
#   $2 - path to write
# Outputs:
#   The rendered config at $2, and a `warning:` line on stdout when it refused
# Returns:
#   0 when the file was written, 1 when the template is missing or a name is unusable
render_public_router_conf() {
  local template="$1" output="$2" body role token host tmp
  if [ -z "${template}" ] || [ ! -f "${template}" ]; then
    echo "warning: router template ${template:-<empty>} is missing, so the public router config was not rendered"
    return 1
  fi
  body="$(cat "${template}")"
  local roles=('dashboard:STACK_DASHBOARD_NAME' 'coder:STACK_CODER_NAME' 'kasm:STACK_KASM_NAME'
    'litellm:STACK_LITELLM_NAME' 'hermes:STACK_HERMES_NAME')
  for role in "${roles[@]}"; do
    token="__EVO_HOST_${role%%:*}__"
    token="$(printf '%s' "${token}" | tr '[:lower:]' '[:upper:]')"
    if ! host="$(public_host_for "${role##*:}" "$(domain_service_default "${role##*:}")")"; then
      echo "warning: cannot compose the ${role%%:*} public name, so the public router config was not rendered"
      return 1
    fi
    body="${body//"${token}"/${host}}"
  done
  # Check the directives, not the prose: this file's own header names the token set, and
  # a substring test over the whole body would read that comment as an unfinished render.
  if printf '%s\n' "${body}" |
    grep -qE '^[[:space:]]*server_name[[:space:]]+__EVO_HOST_[A-Z_]+__;'; then
    echo "warning: ${template} still holds an unsubstituted __EVO_HOST_*__ token, so the public router config was not rendered"
    return 1
  fi
  tmp="${output}.tmp.$$"
  if ! printf '%s\n' "${body}" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  mv -f "${tmp}" "${output}"
}
