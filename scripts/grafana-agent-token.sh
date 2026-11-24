#!/usr/bin/env bash
#
# ## grafana-agent-token.sh - mint the read-only Grafana credential the agent reads.
#
# scripts/observability-query.sh is the agent's ingress to the observability plane, and
# it takes its credential from one file and from nowhere else: one token-shaped line,
# mode 0600, at ${GRAFANA_QUERY_TOKEN_FILE} (default
# /var/lib/evo-t1-observability/grafana-query-token). Until something writes that file,
# every credential-bearing verb on that CLI answers error naming the path. This is the
# step that writes it.
#
# Why the API and not a provisioning file. Grafana file-provisions datasources,
# dashboards and alerting from the directories this bundle mounts, and those three are
# the only kinds it file-provisions: a service account is an object in the database and
# its token is a secret generated at creation time, so neither has a file-provisioning
# schema. A checked-in token would also be a committed credential, which this stack
# never ships. So the account and its Viewer token are created through the same API the
# console uses, and only the token's *path* is a checked-in fact.
#
# Two things this must not do:
#
#   mutate anything    the account is created with role Viewer and nothing else. The
#                      role is a constant, not a flag: there is no way to ask this CLI
#                      for an editor, so no run of it can land a credential that can
#                      rewrite a provisioned dashboard
#   print the token    not in a success line, not in an error, not in a body. The
#                      credential is handed to curl as a config line inside a 0700
#                      scratch directory, the response body is written to a file rather
#                      than captured, and every string this prints is scrubbed with
#                      gat_redact on its way out
#
# Grafana publishes a host port, but the request is still made the way the rest of the
# bundle reaches the plane: a one-shot pinned curl container on the project network,
# like scripts/observability-check.sh:454. That keeps this working on a box where
# GRAFANA_PORT is taken, and keeps the admin password out of this host's process
# listing, because it travels in a mounted config file rather than in argv.
#
# The admin credential is read from the environment the compose file already
# interpolates (GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD) and from nowhere else: no
# new secret key, no dotenv file read by this CLI, and no password in argv, a URL, or a
# committed file.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:grafana-agent-token -- --help
#   bazelisk run //scripts:grafana-agent-token -- --dry-run
#   bazelisk run //scripts:grafana-agent-token -- --token-file /tmp/token
#   bazelisk run //scripts:grafana-agent-token -- --rotate
#   bazelisk run //scripts:grafana-agent-token -- --owner coder
#
# Options (accepted anywhere in argv):
#   --token-file PATH   where the credential is written. Default:
#                       $GRAFANA_QUERY_TOKEN_FILE, else
#                       /var/lib/evo-t1-observability/grafana-query-token -- the exact
#                       precedence scripts/observability-query.sh:170 reads it by
#   --rotate            replace a credential that is already live. Without it a second
#                       run refuses rather than silently invalidating the token a
#                       running agent is holding
#   --repair            write even when the target file is absent or holds nothing
#                       token-shaped. That path is box-wide and read by every agent on
#                       it, so establishing a credential on it is something an operator
#                       asks for rather than a side effect of running the CLI once
#   --owner NAME        chown the token file to this user after writing it, for the
#                       box where the mint runs as root and the agent reads as coder
#   --account-name NAME the service account to create or reuse. Default evo-t1-agent
#   --ttl SECONDS       lifetime of the minted token, in whole seconds above zero.
#                       Default: $GRAFANA_AGENT_TOKEN_TTL, else 2592000 (30 days)
#   --no-expiry         mint a token with no expiry at all. An explicit opt-out, and
#                       the only way this CLI writes a credential that outlives its
#                       operator; it conflicts with --ttl
#   --timeout SECS      per-request curl budget. Default 5
#   --compose-file PATH compose file the project network is named after. Default:
#                       $COMPOSE_FILE, else ./docker-compose.yml
#   --no-docker         stop before any container runs (same checks, no request)
#   --dry-run           print what this would do and write nothing
#   -h | --help         print usage, exit 0
#
# Output: the house vocabulary - "== section ==", "-> phase", "ok:", "warning:",
#   "note:", "error:", and a closing "summary: N ok, W warnings, F failed" as the last
#   line of the run. The token is never one of those lines.
# Exit codes: 0 with the credential in place (or the plan printed, under --dry-run);
#   1 with at least one failure; 2 on a usage error, answered before anything runs.
#
# Related: scripts/observability-query.sh (the reader), scripts/lib/
#   grafana_agent_token.sh (the rules), scripts/observability-check.sh (the same
#   in-network curl container), docs/observability.md (the operator's page for both).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SELF_DIR}/lib/common.sh"
TOKEN_LIB="${SELF_DIR}/lib/grafana_agent_token.sh"
for _needed in "${COMMON_LIB}" "${TOKEN_LIB}"; do
  [ -r "${_needed}" ] || {
    printf 'error: cannot read %s\n' "${_needed}" >&2
    exit 4
  }
done
unset _needed
# shellcheck source=lib/common.sh disable=SC1091
source "${COMMON_LIB}"
# shellcheck source=lib/grafana_agent_token.sh disable=SC1091
source "${TOKEN_LIB}"

# The report is prose on stdout; this CLI has no machine-readable mode, because the one
# value a machine would want is the one value this must never print.
unset JSON_MODE

# -- knobs -----------------------------------------------------------------

# The path is the only credential-shaped thing this CLI accepts or reports. The
# precedence matches the reader's: environment first, then --token-file.
TOKEN_FILE="${GRAFANA_QUERY_TOKEN_FILE:-/var/lib/evo-t1-observability/grafana-query-token}"
TOKEN_FILE_ARG=""

# Hard-coded on purpose. Viewer is the whole security story of this credential, and a
# flag that could widen it would put that story in the hands of a typo.
GAT_SA_ROLE="Viewer"

ACCOUNT_NAME="evo-t1-agent"
TOKEN_NAME=""
OWNER=""
# A minted credential that never dies is the default nobody meant to choose, so the
# default here is a lifetime and the endless one is the opt-in (--no-expiry). The
# number is a month: long enough that no agent's read path breaks between one
# operator visit and the next, short enough that a forgotten box stops presenting a
# credential. GRAFANA_AGENT_TOKEN_TTL or --ttl changes it.
TTL_DEFAULT_SECONDS=2592000
TTL=""
NO_EXPIRY=0
REPAIR=0
ROTATE=0
DRY_RUN=0
NO_DOCKER=0
TIMEOUT=5
COMPOSE_FILE="${COMPOSE_FILE:-}"
PROJECT_NAME=""
WORK_DIR=""

# Where the scratch directory is visible inside the one-shot container. The config file,
# the request bodies and the response bodies all cross this one mount, so no credential
# ever has to be an argument.
GAT_MOUNT="/mnt/evo-t1-mint"
CURL_IMAGE="curlimages/curl:8.10.1"
GRAFANA_SERVICE="grafana"
GRAFANA_CONTAINER_PORT="3000"

# The transport answers, filled by gat_container_curl and read by the caller that asks
# about their shape.
GAT_RC=0
GAT_CODE=""
GAT_ERR=""
GAT_SA_ID=""
GAT_TOKEN=""

# @function usage
# Print the flag list, the credential story and the exit-code contract on stdout.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The help text on stdout
# Returns:
#   0
usage() {
  cat <<'EOF'
grafana-agent-token.sh - mint the read-only Grafana credential the agent reads

  Writes the one-line, 0600 service-account token file that
  scripts/observability-query.sh reads, by creating (or reusing) a service
  account whose role is Viewer and nothing else.

Options:
  --token-file PATH   where the credential is written. Default:
                      $GRAFANA_QUERY_TOKEN_FILE, else
                      /var/lib/evo-t1-observability/grafana-query-token
  --rotate            replace a credential that is already live. Without it a
                      second run refuses instead of invalidating a token an
                      agent is holding
  --repair            write even when the target file is absent or holds nothing
                      token-shaped: the flag that says this run is the mint
                      meant to establish the credential on this box
  --owner NAME        chown the token file to this user after writing it
  --account-name NAME service account to create or reuse. Default evo-t1-agent
  --ttl SECONDS       token lifetime, whole seconds above zero. Default:
                      $GRAFANA_AGENT_TOKEN_TTL, else 2592000 (30 days)
  --no-expiry         mint with no expiry. Explicit opt-out; conflicts with --ttl
  --timeout SECS      per-request curl budget. Default 5
  --compose-file PATH compose file the project network is named after
  --no-docker         stop before any container runs
  --dry-run           print the plan, write nothing
  -h | --help         this text

The admin credential comes from GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD
in the environment, the two keys docker-compose.yml already interpolates. The
minted token is never printed, in any mode.

Every run revokes the account's tokens that this CLI's own naming scheme owns
before minting, so a rerun cannot leave two live credentials behind; a token
named by anything else is left alone.

Exit: 0 minted or planned, 1 a check or request failed, 2 a usage error.
EOF
}

# @function gat_usage_error
# Print one complaint plus the usage block and leave with the usage code, before any
# check, any container, or any write.
# Globals:
#   None
# Arguments:
#   $* - the complaint
# Outputs:
#   The complaint and the usage block on stderr
# Returns:
#   nothing: exits 2
gat_usage_error() {
  printf 'error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

# @function gat_preflight
# Answer everything that is knowable without asking Grafana: that the credential has an
# owner to read it, that the transport exists, that the admin credential is present at
# all, and that writing the target file would not silently knock a live token out from
# under a running agent. The refusal is the whole point of a second run: rotation has to
# be something the operator asked for.
# Globals:
#   TOKEN_FILE, ROTATE, DRY_RUN, NO_DOCKER, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
# Arguments:
#   None
# Outputs:
#   ok:, warning:, note: and error: lines
# Returns:
#   0 when the run may go on, 1 when it must not
gat_preflight() {
  local rc=0
  section "Preflight"
  local refused=0
  gat_refuses_overwrite "${TOKEN_FILE}" "${ROTATE}" "${REPAIR}" || refused=$?
  case "${refused}" in
    0) : ;;
    1)
      fail_item "a live credential is already in ${TOKEN_FILE}: a second mint would invalidate the token an agent is holding. Re-run with --rotate to replace it deliberately"
      return 1
      ;;
    2)
      fail_item "${TOKEN_FILE} exists and cannot be read by this user: check its owner and mode before minting over it"
      return 1
      ;;
    3)
      # --dry-run writes nothing, so the missing credential is printed as part of
      # the plan rather than refused: the plan is the thing an operator wants here.
      if [ "${DRY_RUN}" = "1" ]; then
        warn "no credential in ${TOKEN_FILE} yet: a real run needs --repair to write it"
      else
        fail_item "nothing to replace in ${TOKEN_FILE}: it is absent or holds no credential, and this CLI does not silently establish one at a box-wide path every agent on the box reads. Re-run with --repair to say this mint is the one meant to write it"
        return 1
      fi
      ;;
    *)
      fail_item "could not decide whether ${TOKEN_FILE} holds a live credential"
      return 1
      ;;
  esac

  if [ "${DRY_RUN}" = "1" ]; then
    note "dry run: nothing is created, requested or written"
    return 0
  fi

  if [ "${NO_DOCKER}" = "1" ]; then
    fail_item "--no-docker was asked for and this CLI mints through a one-shot container: there is no other transport"
    return 1
  fi

  if ! has_tool docker; then
    fail_item "docker is not on PATH: the request is made by a one-shot ${CURL_IMAGE} container on the project network"
    return 1
  fi

  if [ -z "${GRAFANA_ADMIN_USER:-}" ] && [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
    fail_item "neither GRAFANA_ADMIN_USER nor GRAFANA_ADMIN_PASSWORD is in the environment: export the two keys docker-compose.yml interpolates, then re-run"
    return 1
  fi
  if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
    fail_item "GRAFANA_ADMIN_PASSWORD is unset or blank: this CLI reads the admin credential from the environment and never from a dotenv file"
    return 1
  fi
  if [ "${GRAFANA_ADMIN_PASSWORD}" = "change-me-grafana" ]; then
    warn "GRAFANA_ADMIN_PASSWORD is the shipped placeholder; Grafana answers 401 until the box has a real one"
  fi
  return "${rc}"
}

# @function gat_container_curl
# Make one API request from inside the compose network with the pinned one-shot curl
# image, the way the unpublished backends are probed elsewhere in the bundle. Auth and
# both bodies cross a bind mount of the scratch directory: the config file carries the
# admin credential, --data-binary names the request body, and -o names where the
# response goes, so no credential is ever an argument to docker or to curl. The response
# body is never captured into this process.
# Globals:
#   PROJECT_NAME, WORK_DIR, GAT_MOUNT, CURL_IMAGE, TIMEOUT, GAT_TOKEN
# Arguments:
#   $1 - HTTP method, or empty for curl's default
#   $2 - the full URL
#   $3 - request body file basename inside the scratch dir, or empty
#   $4 - response body file basename inside the scratch dir
# Outputs:
#   The body in ${WORK_DIR}/$4; curl's own first complaint line is redacted into
#   GAT_ERR and the status code into GAT_CODE
# Returns:
#   curl's exit status, so 7 is "the container could not reach Grafana"
gat_container_curl() {
  local method="${1:-}" url="${2:-}" body="${3:-}" out="${4:-body.json}" rc=0
  local -a outer=(docker run --rm --network "${PROJECT_NAME}_default"
    --volume "${WORK_DIR}:${GAT_MOUNT}" "${CURL_IMAGE}")
  local -a inner=(-sS --max-time "${TIMEOUT}" --config "${GAT_MOUNT}/curlrc"
    -o "${GAT_MOUNT}/${out}" -w '%{http_code}')
  [ -z "${method}" ] || inner+=(--request "${method}")
  [ -z "${body}" ] || inner+=(--data-binary "@${GAT_MOUNT}/${body}")
  inner+=("${url}")
  GAT_CODE=""
  GAT_ERR=""
  capped_run "$((TIMEOUT + 10))" "${outer[@]}" "${inner[@]}" \
    >"${WORK_DIR}/code" 2>"${WORK_DIR}/err" || rc=$?
  GAT_RC="${rc}"
  GAT_CODE="$(sed -n '1p' "${WORK_DIR}/code" 2>/dev/null || true)"
  GAT_ERR="$(sed -n '1p' "${WORK_DIR}/err" 2>/dev/null || true)"
  GAT_ERR="$(gat_redact "${GAT_ERR}")"
  return "${rc}"
}

# @function gat_write_payload
# Write one request body into the scratch directory for the container to read. Bodies
# are data and stay in the mount: putting a JSON body on the command line is how a
# credential ends up in a process listing.
# Globals:
#   WORK_DIR
# Arguments:
#   $1 - basename to write
#   $2 - the body text
# Outputs:
#   The file at ${WORK_DIR}/$1, mode 0600
# Returns:
#   0, or 3 when the file cannot be written
gat_write_payload() {
  local name="${1:-}" text="${2:-}"
  [ -n "${name}" ] || return 3
  umask 077
  printf '%s' "${text}" >"${WORK_DIR}/${name}" 2>/dev/null || return 3
  chmod 0600 "${WORK_DIR}/${name}" 2>/dev/null || return 3
  return 0
}

# @function gat_ensure_service_account
# Find the account named ACCOUNT_NAME, or create it with role Viewer. Reusing is the
# idempotent half of a second run: without it every rotate would leave a second
# service account behind, and the dashboards' ACL would then name an orphan. The role is
# re-read from the answer and checked, because a Viewer the box did not grant is not a
# Viewer.
# Globals:
#   ACCOUNT_NAME, GAT_SA_ROLE, GAT_SA_ID, GAT_CODE, GAT_ERR, WORK_DIR
# Arguments:
#   None
# Outputs:
#   ok:, note: and error: lines; GAT_SA_ID on success
# Returns:
#   0 with GAT_SA_ID set, 1 otherwise
gat_ensure_service_account() {
  local base="http://${GRAFANA_SERVICE}:${GRAFANA_CONTAINER_PORT}" found="" answer_role=""
  phase "GET ${base}/api/serviceaccounts/search (find ${ACCOUNT_NAME})"
  if ! gat_container_curl GET "${base}/api/serviceaccounts/search?query=${ACCOUNT_NAME}" \
    "" "search.json"; then
    fail_item "Grafana could not be reached on the project network${GAT_ERR:+ / ${GAT_ERR}} (docker exit ${GAT_RC}): is the observability profile up (bazelisk run //scripts:dev-stack -- status)"
    return 1
  fi
  if [ "${GAT_CODE}" = "200" ] && found="$(gat_find_service_account_id "${WORK_DIR}/search.json" "${ACCOUNT_NAME}")"; then
    GAT_SA_ID="${found}"
    ok "reusing service account ${ACCOUNT_NAME} (id ${GAT_SA_ID})"
    return 0
  fi
  phase "POST ${base}/api/serviceaccounts (create ${ACCOUNT_NAME} as ${GAT_SA_ROLE})"
  gat_write_payload "service-account.json" \
    "{\"name\":\"${ACCOUNT_NAME}\",\"role\":\"${GAT_SA_ROLE}\"}" || {
    fail_item "could not write the create body into the scratch directory"
    return 1
  }
  gat_container_curl POST "${base}/api/serviceaccounts" "service-account.json" "created.json" || true
  case "${GAT_CODE}" in
    200 | 201) : ;;
    *)
      fail_item "Grafana refused to create ${ACCOUNT_NAME}: ${GAT_CODE:-no code}${GAT_ERR:+ / ${GAT_ERR}} (expected 200 or 201)"
      return 1
      ;;
  esac
  GAT_SA_ID="$(gat_json_field "${WORK_DIR}/created.json" id 2>/dev/null || true)"
  if [ -z "${GAT_SA_ID}" ]; then
    fail_item "Grafana created the account but its answer carries no id: refusing to mint against an account this CLI cannot name"
    return 1
  fi
  answer_role="$(gat_json_field "${WORK_DIR}/created.json" role 2>/dev/null || true)"
  if [ -n "${answer_role}" ] && [ "${answer_role}" != "${GAT_SA_ROLE}" ]; then
    fail_item "Grafana granted ${ACCOUNT_NAME} the role ${answer_role}, not ${GAT_SA_ROLE}: this CLI will not mint a credential it cannot prove is read-only"
    return 1
  fi
  ok "created service account ${ACCOUNT_NAME} (id ${GAT_SA_ID}) with role ${GAT_SA_ROLE}"
  return 0
}

# @function gat_revoke_existing_tokens
# Delete every token the account already holds, so that --rotate leaves exactly one
# live credential behind rather than one per rotation. A token that cannot be listed is
# a warning and not a fault: minting still succeeds, and the operator is told the old
# one may still be live.
# Delete every token whose name this CLI's naming scheme owns, before any new one is
# minted, so that no run leaves a previous credential of its own live. Tokens named by
# anything else are not this CLI's to delete and are left alone. A token list that
# cannot be read is a warning and not a fault: minting still succeeds, and the operator
# is told the old one may still be live.
# Globals:
#   ACCOUNT_NAME, TOKEN_NAME, GAT_SA_ID, GAT_CODE, GAT_ERR, WORK_DIR
# Arguments:
#   None
# Outputs:
#   ok:, warning: and error: lines
# Returns:
#   0 when the account holds no token of this CLI's own afterwards, or the list could
#   not be read, 1 when a deletion Grafana was asked for failed
gat_revoke_existing_tokens() {
  local base="http://${GRAFANA_SERVICE}:${GRAFANA_CONTAINER_PORT}" ids="" deleted=0 id=""
  phase "GET ${base}/api/serviceaccounts/${GAT_SA_ID}/tokens (what to revoke)"
  if ! gat_container_curl GET "${base}/api/serviceaccounts/${GAT_SA_ID}/tokens" \
    "" "tokens.json"; then
    warn "could not list ${ACCOUNT_NAME}'s tokens${GAT_ERR:+ / ${GAT_ERR}}: the previous token may still be live"
    return 0
  fi
  if [ "${GAT_CODE}" != "200" ]; then
    warn "Grafana answered ${GAT_CODE:-no code} to the token list: the previous token may still be live"
    return 0
  fi
  ids="$(gat_list_token_ids "${WORK_DIR}/tokens.json" "${TOKEN_NAME}")"
  if [ -z "${ids}" ]; then
    ok "${ACCOUNT_NAME} holds no token of this CLI's own to revoke"
    return 0
  fi
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    phase "DELETE ${base}/api/serviceaccounts/${GAT_SA_ID}/tokens/${id}"
    gat_container_curl DELETE \
      "${base}/api/serviceaccounts/${GAT_SA_ID}/tokens/${id}" "" "revoked.json" || true
    case "${GAT_CODE}" in
      200 | 204) deleted=$((deleted + 1)) ;;
      *)
        fail_item "Grafana refused to revoke token ${id} of ${ACCOUNT_NAME}: ${GAT_CODE:-no code}${GAT_ERR:+ / ${GAT_ERR}}"
        return 1
        ;;
    esac
  done <<<"${ids}"
  ok "revoked ${deleted} previous token(s) of ${ACCOUNT_NAME}"
  return 0
}

# @function gat_mint_token
# Ask for the token, prove the answer is one token-shaped line before anything is
# written, then write it 0600 and hand it to the agent's user if this box needs that.
# A response that is not one token is a failure, not a file: the reader would only
# refuse it later, with a worse message.
# Globals:
#   ACCOUNT_NAME, GAT_SA_ID, TOKEN_NAME, TTL, TOKEN_FILE, OWNER, GAT_TOKEN, GAT_CODE,
#   GAT_ERR, WORK_DIR
# Arguments:
#   None
# Outputs:
#   ok:, note: and error: lines; the credential file at TOKEN_FILE
# Returns:
#   0 with the file written, 1 otherwise
gat_mint_token() {
  local base="http://${GRAFANA_SERVICE}:${GRAFANA_CONTAINER_PORT}" body=""
  body="{\"name\":\"${TOKEN_NAME}\"}"
  if [ -n "${TTL}" ]; then
    body="{\"name\":\"${TOKEN_NAME}\",\"secondsToLive\":${TTL}}"
  fi
  gat_write_payload "token.json" "${body}" || {
    fail_item "could not write the mint body into the scratch directory"
    return 1
  }
  phase "POST ${base}/api/serviceaccounts/${GAT_SA_ID}/tokens (mint ${TOKEN_NAME})"
  gat_container_curl POST "${base}/api/serviceaccounts/${GAT_SA_ID}/tokens" \
    "token.json" "minted.json" || true
  case "${GAT_CODE}" in
    200 | 201) : ;;
    *)
      fail_item "Grafana refused to mint a token for ${ACCOUNT_NAME}: ${GAT_CODE:-no code}${GAT_ERR:+ / ${GAT_ERR}} (expected 200 or 201)"
      return 1
      ;;
  esac
  GAT_TOKEN="$(gat_json_field "${WORK_DIR}/minted.json" key 2>/dev/null || true)"
  if ! gat_is_token_shape "${GAT_TOKEN}"; then
    GAT_TOKEN=""
    fail_item "Grafana's answer carries no token-shaped key: nothing was written to ${TOKEN_FILE}"
    return 1
  fi
  if ! gat_write_token_file "${TOKEN_FILE}" "${GAT_TOKEN}"; then
    GAT_TOKEN=""
    fail_item "could not write the credential to ${TOKEN_FILE}: does the directory exist, and may this user write it?"
    return 1
  fi
  GAT_TOKEN=""
  ok "wrote the read-only credential to ${TOKEN_FILE} (one line, mode 0600)"
  if [ -n "${OWNER}" ]; then
    if chown "${OWNER}" "${TOKEN_FILE}" 2>/dev/null; then
      ok "handed ${TOKEN_FILE} to ${OWNER}"
    else
      warn "could not chown ${TOKEN_FILE} to ${OWNER}: run the mint as root or with --owner left out"
    fi
  fi
  if [ -z "${TTL}" ]; then
    warn "this token never expires: --no-expiry was asked for explicitly. Revoke it from Grafana's service-account page or re-run with --rotate when the agent is done with it"
  else
    note "this token expires in ${TTL} seconds; re-run with --rotate before then to hand the agent a fresh one"
  fi
  return 0
}

# @function gat_plan
# Print the plan --dry-run stops at: which account, which role, which path, whether a
# live credential would be replaced. Every one of those is the thing an operator wants
# to have confirmed before a credential changes on a box that is serving.
# Globals:
#   ACCOUNT_NAME, GAT_SA_ROLE, TOKEN_NAME, TOKEN_FILE, ROTATE, OWNER, PROJECT_NAME,
#   GRAFANA_SERVICE, GRAFANA_CONTAINER_PORT, TTL
# Arguments:
#   None
# Outputs:
#   note: lines naming the account, the role, the path and the network
# Returns:
#   0
gat_plan() {
  section "Plan"
  note "service account: ${ACCOUNT_NAME} (role ${GAT_SA_ROLE}, token name ${TOKEN_NAME})"
  note "request: one-shot ${CURL_IMAGE} on ${PROJECT_NAME}_default to http://${GRAFANA_SERVICE}:${GRAFANA_CONTAINER_PORT}"
  note "credential: written to ${TOKEN_FILE}, one line, mode 0600, never printed"
  if [ "${ROTATE}" = "1" ]; then
    note "a credential already in place would be revoked and replaced (--rotate)"
  else
    note "a credential already in place would be refused (pass --rotate to replace it)"
  fi
  if gat_refuses_overwrite "${TOKEN_FILE}" "${ROTATE}" "${REPAIR}"; then
    note "the target file needs no further flag"
  else
    case "$?" in
      3) note "no credential in ${TOKEN_FILE} yet: a real run needs --repair to write it" ;;
      *) : ;;
    esac
  fi
  note "revocation: the account's tokens named ${TOKEN_NAME}* are revoked before the mint; anything named by another tool is left alone"
  if [ -n "${TTL}" ]; then
    note "lifetime: ${TTL} seconds"
  else
    note "lifetime: none (--no-expiry)"
  fi
  if [ -n "${OWNER}" ]; then
    note "owner after the write: ${OWNER}"
  fi
  ok "plan printed; nothing was created, requested or written"
  return 0
}

# -- argv -------------------------------------------------------------------

[ "${1:-}" != "--help" ] && [ "${1:-}" != "-h" ] || {
  usage
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --token-file)
      [ "$#" -ge 2 ] || gat_usage_error "unknown option: $1 (--token-file needs a path)"
      TOKEN_FILE_ARG="$2"
      shift 2
      ;;
    --account-name)
      [ "$#" -ge 2 ] || gat_usage_error "unknown option: $1 (--account-name needs a name)"
      ACCOUNT_NAME="$2"
      shift 2
      ;;
    --owner)
      [ "$#" -ge 2 ] || gat_usage_error "unknown option: $1 (--owner needs a user name)"
      OWNER="$2"
      shift 2
      ;;
    --ttl)
      [ "$#" -ge 2 ] || gat_usage_error "unknown option: $1 (--ttl needs a number of seconds)"
      TTL="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || gat_usage_error "unknown option: $1 (--timeout needs a number of seconds)"
      TIMEOUT="$2"
      shift 2
      ;;
    --compose-file)
      [ "$#" -ge 2 ] || gat_usage_error "unknown option: $1 (--compose-file needs a path)"
      COMPOSE_FILE="$2"
      shift 2
      ;;
    --rotate)
      ROTATE=1
      shift
      ;;
    --repair)
      REPAIR=1
      shift
      ;;
    --no-expiry)
      NO_EXPIRY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-docker)
      NO_DOCKER=1
      shift
      ;;
    *)
      gat_usage_error "unknown option: $1 (see --help)"
      ;;
  esac
done

[[ ${ACCOUNT_NAME} =~ ^[A-Za-z0-9._-]+$ ]] ||
  gat_usage_error "--account-name must be letters, digits, dot, dash or underscore: it names a Grafana object and goes into a JSON body"
[[ ${OWNER} =~ ^[A-Za-z0-9._-]*$ ]] ||
  gat_usage_error "--owner must be a plain user name"
[[ ${TIMEOUT} =~ ^[1-9][0-9]*$ ]] ||
  gat_usage_error "--timeout must be a whole number of seconds above zero, got '${TIMEOUT}' (0 and 00 both mean no cap, and this CLI does not run uncapped requests)"
[ -z "${TTL}" ] || [[ ${TTL} =~ ^[1-9][0-9]*$ ]] ||
  gat_usage_error "--ttl must be a whole number of seconds above zero, got '${TTL}' (0 and 00 are not lifetimes)"
if [ "${NO_EXPIRY}" = "1" ] && [ -n "${TTL}" ]; then
  gat_usage_error "--no-expiry and --ttl ask for opposite things: pick one"
fi
if [ "${NO_EXPIRY}" != "1" ] && [ -z "${TTL}" ]; then
  TTL="${GRAFANA_AGENT_TOKEN_TTL:-${TTL_DEFAULT_SECONDS}}"
  [[ ${TTL} =~ ^[1-9][0-9]*$ ]] ||
    gat_usage_error "GRAFANA_AGENT_TOKEN_TTL must be a whole number of seconds above zero, got '${TTL}'"
fi
[ "${DRY_RUN}" != "1" ] || [ "${NO_DOCKER}" != "1" ] ||
  gat_usage_error "--dry-run and --no-docker ask the same thing twice; pick one"

if [ -n "${TOKEN_FILE_ARG}" ]; then
  TOKEN_FILE="${TOKEN_FILE_ARG}"
fi
[ -n "${TOKEN_FILE}" ] || gat_usage_error "the token file path is empty"
TOKEN_NAME="${ACCOUNT_NAME}-token"

# The network the one-shot container joins: compose names it after the project, and the
# project after the directory the compose file sits in, which is the same derivation the
# rest of the bundle uses.
if [ -z "${COMPOSE_FILE}" ]; then
  COMPOSE_FILE="${PWD}/docker-compose.yml"
fi
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$(dirname "${COMPOSE_FILE}")")}"

# One scratch directory per run for the config file, the request bodies and the response
# bodies, removed on every exit path. mktemp -d creates it 0700 and the umask keeps every
# file inside it private to this run, which is what makes it safe to hand to a container.
WORK_DIR="$(mktemp -d 2>/dev/null || true)"
[ -n "${WORK_DIR}" ] || gat_usage_error "could not create a scratch directory for the request bodies"
trap 'rm -rf "${WORK_DIR}"' EXIT

section "Grafana read-only credential"
if [ "${DRY_RUN}" = "1" ]; then
  gat_plan
  summary
  exit 0
fi

gat_preflight || {
  summary
  exit 1
}

umask 077
if ! gat_curl_config "${WORK_DIR}/curlrc" "${GRAFANA_ADMIN_USER:-admin}" "${GRAFANA_ADMIN_PASSWORD}"; then
  fail_item "could not write the curl config the admin credential travels in: is ${WORK_DIR} writable?"
  summary
  exit 1
fi

# Ensure, revoke, then mint - in that order, every run. Revoking is not gated on
# --rotate: --rotate guards the file on disk, while this guards the plane, where a
# rerun that left its previous credential live would mean two working credentials for
# one agent and no way to tell which one a 401 is about. A revoke Grafana refused
# stops the run rather than minting on top of it.
proceed=1
gat_ensure_service_account || proceed=0
if [ "${proceed}" = "1" ]; then
  gat_revoke_existing_tokens || proceed=0
fi
if [ "${proceed}" = "1" ]; then
  gat_mint_token || proceed=0
fi

# The response bodies held the credential. The trap removes the directory when the
# process ends, and this removes them the moment they have been read, so the window in
# which a secret sits on disk is the read and not the run.
rm -f "${WORK_DIR}/minted.json" "${WORK_DIR}/search.json" "${WORK_DIR}/created.json" 2>/dev/null || true

summary
[ "${SUMMARY_FAIL:-0}" -eq 0 ] || exit 1
exit 0
