# shellcheck shell=bash
# shellcheck disable=SC2034 # SPARK_HOSTS_* are the output-variable contract for sourcing scripts
#
# ## spark.sh — shared helpers for the Spark fleet probes (sourced; never executed)
#
# The Spark boxes are reached two ways: capped HTTP GETs against their published
# ports, and base64-encoded sh scripts ferried over ssh as ONE quoted remote
# command. Both scripts that drive that plumbing (spark-configure.sh,
# spark-verify.sh) also resolve their host list the same way — arguments win,
# then the SPARK*_URL keys in .env, then the shipped placeholder trio. These
# helpers exist so those two scripts keep their policy and reporting and stop
# duplicating the plumbing.
#
# Invariants:
#   - Sourcing this file changes no shell options and runs no probe; it sources
#     common.sh first when common.sh has not been sourced yet, so this file
#     never depends on the source order chosen by an entry script.
#   - An empty probe body is a RESULT ("did not answer"), never an error:
#     probe_http prints nothing in that case so "never measured" stays
#     distinguishable from "answered and looks right".
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root `cd`):
#   # shellcheck source=lib/spark.sh disable=SC1091
#   source "scripts/lib/spark.sh"   # sources scripts/lib/common.sh when needed

if ! declare -f has_tool >/dev/null 2>&1; then
  # shellcheck source=lib/common.sh disable=SC1091
  source "${BASH_SOURCE[0]%/*}/common.sh"
fi

# ── Knobs ────────────────────────────────────────────────────────────────────

# SPARK_DEFAULT_HOSTS — the placeholder trio .env.sample ships as the value of
# SPARK1_HOST / SPARK2_HOST / SPARK3_HOST. These names do not resolve; they exist
# so an unconfigured checkout still reports every host as "not yet", rather than
# passing silently.
SPARK_DEFAULT_HOSTS="spark-1.lan spark-2.lan spark-3.lan"

# SPARK_HTTP_PORT — the TensorFold port of a Spark box: the /v1 endpoint the
# `agent` alias routes to, the /health path the dashboard cards probe, and the
# port both Spark CLIs use. docker-compose.yml composes every Spark URL from
# it, so one value covers the proxy, the dashboard, and these scripts.
SPARK_HTTP_PORT="${SPARK_HTTP_PORT:-8888}"

# ── Host-list derivation ─────────────────────────────────────────────────────

# derive_spark_hosts <env-file> — resolve the space-separated host list for
# this run WITHOUT printing it. Afterwards:
#   SPARK_HOSTS_RESOLVED — the resolved host list, one line, never empty
#   SPARK_HOSTS_SOURCE   — how it was resolved: env | derived | default
# Order of precedence (identical in both entry scripts): a non-empty
# SPARK_HOSTS from the process environment wins; otherwise the SPARKn_HOST keys
# in <env-file>, then the host part of the SPARKn_OLLAMA_URL / SPARKn_OPENAI_URL
# keys (stripped of scheme and port), all deduplicated and malformed hosts
# dropped; when that yields nothing, the placeholder trio from
# SPARK_DEFAULT_HOSTS.
# @function derive_spark_hosts
# Resolve the fleet host list into SPARK_HOSTS_RESOLVED and SPARK_HOSTS_SOURCE.
# Globals:
#   SPARK_HOSTS, SPARK_DEFAULT_HOSTS, SPARK_HOSTS_RESOLVED, SPARK_HOSTS_SOURCE
# Arguments:
#   $1 - env file to read when SPARK_HOSTS is empty
# Outputs:
#   None. Writes the two SPARK_HOSTS_* globals.
# Returns:
#   0
derive_spark_hosts() {
  local file="$1" key url host
  SPARK_HOSTS_RESOLVED=""
  SPARK_HOSTS_SOURCE=""
  if [ -n "${SPARK_HOSTS:-}" ]; then
    # shellcheck disable=SC2086 # word splitting over the SPARK_HOSTS list is the point
    for host in ${SPARK_HOSTS}; do
      SPARK_HOSTS_RESOLVED="${SPARK_HOSTS_RESOLVED:+${SPARK_HOSTS_RESOLVED} }${host}"
    done
    SPARK_HOSTS_SOURCE="env"
    return 0
  fi
  if [ -f "${file}" ]; then
    # SPARKn_HOST first: it is the key the operator sets once and the one
    # docker-compose.yml composes every Spark URL from, so the fleet this
    # checkout points at is the fleet these probes check. The URL keys stay in
    # the list for a .env that names a box only there.
    for key in SPARK1_HOST SPARK2_HOST SPARK3_HOST \
      SPARK1_OLLAMA_URL SPARK2_OLLAMA_URL SPARK1_OPENAI_URL SPARK2_OPENAI_URL SPARK3_OPENAI_URL; do
      url="$(env_get "${file}" "${key}" | tr -d ' \r' || true)"
      [ -n "${url}" ] || continue
      host="$(canonical_url "${url}")"
      case "${host}" in '' | *[!A-Za-z0-9.-]*) continue ;; esac
      case " ${SPARK_HOSTS_RESOLVED} " in *" ${host} "*) continue ;; esac
      SPARK_HOSTS_RESOLVED="${SPARK_HOSTS_RESOLVED:+${SPARK_HOSTS_RESOLVED} }${host}"
    done
  fi
  if [ -n "${SPARK_HOSTS_RESOLVED}" ]; then
    SPARK_HOSTS_SOURCE="derived"
  else
    SPARK_HOSTS_RESOLVED="${SPARK_DEFAULT_HOSTS}"
    SPARK_HOSTS_SOURCE="default"
  fi
}

# ── Endpoint derivation ──────────────────────────────────────────────────────

# spark_openai_url <env-file> <n> — print the OpenAI-compatible /v1 URL the
# proxy is handed for box n, which is the endpoint a probe must ask. An
# explicit SPARKn_OPENAI_URL in <env-file> wins (compose passes it through
# verbatim); otherwise the URL is composed from SPARKn_HOST, falling to
# STACK_LAN_HOST, plus SPARK_HTTP_PORT — the composition docker-compose.yml
# performs, kept here so a probe never asks a different question than the proxy
# answers. Prints nothing and returns 1 when no host is named at all: that box
# is not configured, which is the caller's "not yet" state to report.
# @function spark_openai_url
# Compose the /v1 URL for one Spark box, or report that it names no host.
# Globals:
#   SPARK_HTTP_PORT, STACK_LAN_HOST
# Arguments:
#   $1 - env file to read
#   $2 - box number (1, 2 or 3)
# Outputs:
#   The URL on stdout, or nothing when no host is named.
# Returns:
#   0 when a URL was printed, 1 when the box names no host.
spark_openai_url() {
  local file="$1" box="$2" url host
  url="$(env_get "${file}" "SPARK${box}_OPENAI_URL" | tr -d ' \r' || true)"
  if [ -n "${url}" ]; then
    printf '%s\n' "${url}"
    return 0
  fi
  host="$(env_get "${file}" "SPARK${box}_HOST" | tr -d ' \r' || true)"
  [ -n "${host}" ] || host="${STACK_LAN_HOST:-}"
  [ -n "${host}" ] || return 1
  printf 'http://%s:%s/v1\n' "${host}" "${SPARK_HTTP_PORT:-8888}"
}

# ── Probe plumbing ───────────────────────────────────────────────────────────

# probe_http <cap> <url> — one capped HTTP GET, printing the body or nothing at
# all. An empty body means "did not answer" and is a result, not an error, so
# this never dies and never prints a tool's own error text.
# @function probe_http
# Print the body of one capped HTTP GET, or nothing when it does not answer.
# Globals:
#   None
# Arguments:
#   $1 - cap seconds; $2 - URL
# Outputs:
#   The body, or nothing
# Returns:
#   0
probe_http() {
  local out=""
  out="$(capped_run "${1}" curl -fsS -m 5 "${2}" 2>/dev/null || true)"
  printf '%s' "${out}"
}

# probe_transport <cap> <port> <target> <payload> — ferry ONE base64 payload
# (a whole script, pre-encoded by the caller) to <target> as a single quoted
# ssh argument, so the remote half always reads as one flat sh body with no
# nested quoting for hostile output to break against. <cap> is the wall-clock
# cap seconds, <port> the ssh port. The exit status is ssh's own — 124/143
# (timeout cut-off) included — and belongs to the caller to interpret.
# @function probe_transport
# Send one base64 payload to a host as a single quoted ssh command.
# Globals:
#   None
# Arguments:
#   $1 - cap seconds; $2 - ssh port; $3 - target; $4 - base64 payload
# Outputs:
#   The remote command's output
# Returns:
#   ssh's status, including 124 or 143 when the cap fires
probe_transport() {
  local cap="$1" port="$2" target="$3" payload="$4"
  capped_run "${cap}" ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -p "${port}" -- "${target}" \
    "printf '%s' '${payload}' | base64 -d | sh"
}
