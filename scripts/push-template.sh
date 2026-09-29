#!/usr/bin/env bash
# Push templates/docker-dev into the running Coder server and confirm the pushed
# version became the active one. bootstrap.sh runs this for you; it is also the
# standalone loop for "I edited the template, make workspaces see it".
#
# Everything Coder-facing runs INSIDE the coder container, against the server's own
# loopback listener. That is deliberate and it is the reason this script replaced a
# host-side `coder login` + `coder templates push`:
#
#   CODER_ACCESS_URL is the address the *browser* uses. In public mode it is a name
#   fronted by the reverse proxy and Authelia, which gates every route — including
#   the CLI's unauthenticated probes. `coder login https://coder-<host>` therefore
#   dies before it can prompt, on the first-user check, with
#     error: Trace=[Failed to check server "https://…" for first user, is the URL
#     correct and is coder accessible from your browser? Error - has initial user: ]
#     unexpected non-JSON response "text/html; charset=utf-8"
#   because Authelia answers that probe with its HTML sign-in page (a 303 to
#   /api/v2/users/initial-user). No amount of host-side logging in fixes that: the
#   CLI must reach the API before it has a credential, and the only URL it will use
#   is the gated one.
#
#   http://127.0.0.1:3000 inside the container is the same API the server serves
#   (CODER_HTTP_ADDRESS in compose), reached without crossing Traefik, Authelia, or
#   the WAN. It also runs the image's own coder binary, so client and server are the
#   same build and no version skew is possible. The host coder CLI is not required,
#   and a stale `coder login` session on the host cannot aim this push at some other
#   deployment.
#
# Credentials come from the stack's own Postgres, the same way `coder reset-password`
# works: the CLI inside the container has no session file, so a short-lived token is
# inserted into api_keys for an admin user, used for the three calls below, and
# deleted on the way out (including on failure, via the trap). The token never
# appears in this script's output.
#
# Template source travels as a tar on stdin (`--directory -`), so nothing is copied
# into the container or its volumes. Coder stores a pushed template as a Filestore
# row referenced from the template version, so copying files into coder-home would
# be invisible to the server; a push is the only thing that registers a template.
#
# Contract: push when it can, otherwise exit 0 with a one-line reason. A running
# stack, docker access, and an admin account are three things a fresh clone does not
# have yet, and bootstrap.sh must not show a red error for states that are simply
# not-true-yet. Only a push that was attempted and failed exits non-zero.
#
# Re-runnable: a push replaces the template's active version, so re-running after
# an unchanged checkout just re-activates equivalent Terraform. Nothing here reads
# or writes .env beyond the reads below.
#
# Usage:
#   ./scripts/push-template.sh
#   SKIP_TEMPLATE_PUSH=1 ./scripts/bootstrap.sh   # bootstrap skips this step
# Overrides (rare; each exists for a stack that renamed something in compose):
#   CODER_CONTAINER_SERVICE=coder    compose service holding the server
#   CODER_DB_SERVICE=db              compose service holding Postgres
#   CODER_CONTAINER_API_URL=…        server API URL reachable from inside the
#                                    coder container (default http://127.0.0.1:3000)
#   CODER_PUSH_USER=<username>       user to mint the push token for
#   CODER_PUSH_TOKEN_MINUTES=10      lifetime of the minted token
set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE_NAME="docker-dev"
TEMPLATE_DIR="templates/docker-dev"
CODER_SERVICE="${CODER_CONTAINER_SERVICE:-coder}"
DB_SERVICE="${CODER_DB_SERVICE:-db}"
DB_USER="coder"
DB_NAME="coder"
CONTAINER_API_URL="${CODER_CONTAINER_API_URL:-http://127.0.0.1:3000}"
PUSH_USER="${CODER_PUSH_USER:-}"
# Bound tightly: the token is root-equivalent while it lives, it only has to outlast
# this script, and a deleted row is inert (Coder validates on every request).
TOKEN_MINUTES="${CODER_PUSH_TOKEN_MINUTES:-10}"
case "${TOKEN_MINUTES}" in
  '' | *[!0-9]*) TOKEN_MINUTES=10 ;;
esac
TOKEN_NAME="stack-template-push"
# A half-started server leaves the CLI retrying its API call; 20s is long enough
# for a live server to answer and short enough not to stall a scripted run.
PROBE_TIMEOUT=20
VERIFY_TIMEOUT=60
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Expected states, not errors: exit 0 so callers (bootstrap) keep going.
skip() { printf '%s\n' "$*"; exit 0; }

# Read .env by sed rather than sourcing it: the file is user-editable, and with
# `set -e` a parse error or a stray command substitution there aborts the script.
env_get() {
  sed -n "s|^${1}=||p" .env 2>/dev/null | tail -n 1 | sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|'
}

first_line() {
  # $1 = text; prints its first non-blank line so a tool's own complaint can be
  # quoted without dumping its whole stderr into this script's output. The `|| true`
  # is load-bearing: pipefail makes an all-blank input (grep exits 1) abort the
  # caller, which is an assignment under `set -e`.
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

[ -f "${TEMPLATE_DIR}/main.tf" ] \
  || die "${TEMPLATE_DIR}/main.tf not found (run this from the repo root)"
# The username goes into a quoted SQL literal, so keep it to characters where that
# quoting cannot be broken out of. Coder restricts usernames to this set already;
# anything else is a typo or worse, and a clear message beats a psql syntax error (or
# a stray quote that changes the statement's meaning).
if [ -n "${PUSH_USER}" ] && ! printf '%s' "${PUSH_USER}" | grep -qE '^[A-Za-z0-9._@-]+$'; then
  die "CODER_PUSH_USER='${PUSH_USER}' is not a valid Coder username (letters, digits, dot, underscore, hyphen, @)"
fi
# Coder pushes without a lockfile but warns, and the README's fix is one command;
# say it here rather than make the operator decode the CLI's warning.
if [ ! -f "${TEMPLATE_DIR}/.terraform.lock.hcl" ]; then
  log "note: ${TEMPLATE_DIR}/.terraform.lock.hcl is missing — regenerate it with:"
  log "      terraform -chdir=${TEMPLATE_DIR} init -backend=false"
fi

command -v docker >/dev/null 2>&1 \
  || skip "skipped: docker is not on PATH, so neither the coder server nor its database can be reached"
command -v timeout >/dev/null 2>&1 \
  || skip "skipped: timeout(1) is not available, so the probes below cannot be bounded"
# The template travels as a tar on stdin; without it there is nothing to pipe.
command -v tar >/dev/null 2>&1 \
  || skip "skipped: tar is not on PATH, so the template directory cannot be streamed to the server"

# The server has to be up before anything has a chance of working. Ask compose
# rather than the daemon so the check stays scoped to this stack, and treat a
# docker failure as "cannot tell" rather than as a push failure.
if ! running="$(docker compose ps --status running --services 2>&1)"; then
  skip "skipped: could not query the stack ($(first_line "${running}")) — this script needs docker access; run it with sudo, or add your user to the docker group"
fi
if ! grep -qx "${CODER_SERVICE}" <<<"${running}"; then
  skip "skipped: the ${CODER_SERVICE} service is not running yet (start the stack with: docker compose up -d)"
fi
if ! grep -qx "${DB_SERVICE}" <<<"${running}"; then
  skip "skipped: the ${DB_SERVICE} service is not running, so no push token can be minted (start the stack with: docker compose up -d)"
fi

# Prove the in-container API is answering before minting anything. curl is used
# rather than the coder CLI because it needs no credential: a 200 here separates
# "the container is wedged" from "the token was rejected".
buildinfo="$(timeout "${PROBE_TIMEOUT}" \
  docker compose exec -T "${CODER_SERVICE}" \
  curl -fsS -m 5 "${CONTAINER_API_URL}/api/v2/buildinfo" </dev/null 2>&1)" || probe_rc=$?
probe_rc="${probe_rc:-0}"
if [ "${probe_rc}" != "0" ]; then
  if [ "${probe_rc}" = "124" ]; then
    skip "skipped: no answer within ${PROBE_TIMEOUT}s from ${CONTAINER_API_URL} inside ${CODER_SERVICE} — the server may still be starting: docker compose logs --tail 100 ${CODER_SERVICE}"
  fi
  die "the Coder API at ${CONTAINER_API_URL} is not answering inside the ${CODER_SERVICE} container ($(first_line "${buildinfo}")) — check: docker compose logs --tail 100 ${CODER_SERVICE}"
fi

dev_image="$(env_get DEV_IMAGE)"
dev_image="${dev_image:-evo-t1-dev:latest}"

# ── Mint a short-lived token ────────────────────────────────────────────────
# Coder hashes an API key secret with plain SHA-256 (coderd/apikey HashSecret) and
# stores the hash, so minting one means inserting a row whose secret only we hold.
# That is the same trust model as `coder reset-password`, which also bypasses the
# API and talks to the database directly.
#
# Scope has to be coder:all: a token narrowed to the template scopes still fails the
# CLI's opening organization lookups ("get organizations: You are signed out"), so a
# least-privilege push is not available on v2.36. The compensating controls are the
# minutes-long lifetime and the delete in the trap.
command -v openssl >/dev/null 2>&1 \
  || skip "skipped: openssl is not on PATH, so no push token can be generated"

key_id="$(openssl rand -hex 5)"
key_secret="$(openssl rand -hex 11)"
# Matches what coderd/apikey.Generate produces: a 10-char id and a 22-char secret,
# joined as "<id>-<secret>". Hex from openssl satisfies both (alphanumeric, no
# padding), and the server compares sha256(secret) against hashed_secret. openssl
# computes the digest rather than sha256sum, which the macOS hosts bootstrap.sh
# supports do not ship.
key_hash="$(printf '%s' "${key_secret}" | openssl dgst -sha256 -r 2>/dev/null \
  | cut -c1-64)"
if [ "${#key_hash}" != "64" ]; then
  die "could not compute a sha256 digest with openssl — this openssl build lacks the dgst command"
fi

psql_sql() {
  # $1 = SQL. ON_ERROR_STOP makes a failed insert non-zero instead of a quiet
  # warning, which would otherwise surface as an unexplained auth failure below.
  timeout "${PROBE_TIMEOUT}" docker compose exec -T "${DB_SERVICE}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -c "$1" </dev/null 2>&1
}

psql_query() {
  # $1 = SQL returning at most one row; prints that single column, trimmed. -q
  # suppresses the command statuses ("INSERT 0 1" and friends) that -t alone still
  # prints, so the only output is the RETURNING value.
  timeout "${PROBE_TIMEOUT}" docker compose exec -T "${DB_SERVICE}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -tAc "$1" </dev/null 2>&1 \
    | tr -d '[:space:]'
}

# A token left behind by a killed run (the trap cannot fire on SIGKILL) is replaced
# rather than colliding with the unique (user_id, token_name) index.
cleanup_sql="delete from api_keys where token_name = '${TOKEN_NAME}';"
if ! cleanup_out="$(psql_sql "${cleanup_sql}")"; then
  die "could not clean up in ${DB_SERVICE}: $(first_line "${cleanup_out}")"
fi
# Insert first, so the cleanup below has something to delete no matter what happens
# next. TERM reaches the EXIT trap on its own; INT does not — bash dies from the
# default disposition without running it — so Ctrl-C gets an explicit handler that
# deletes the token and then exits with the conventional 130. HUP is a covered case
# rather than a guess: this is the script bootstrap calls, and a closed terminal is
# how a run gets interrupted here. SIGKILL remains the one case nothing can clean
# up, which is why the token's lifetime is minutes and why the delete above runs
# before minting.
cleanup_token() {
  psql_sql "delete from api_keys where token_name = '${TOKEN_NAME}';" >/dev/null 2>&1 || true
}
trap 'cleanup_token' EXIT
trap 'trap - EXIT; cleanup_token; exit 130' INT HUP

# Admin selection: an explicit CODER_PUSH_USER wins, otherwise a site owner, with a
# template-admin as the fallback and the most recently seen of those winning the tie.
# Deleted, dormant and service-account rows are excluded — the first two fail the
# api_keys insert trigger, and the last is not an interactive account.
admin_where="(rbac_roles && '{owner,template-admin}'::text[])"
if [ -n "${PUSH_USER}" ]; then
  admin_where="username = '${PUSH_USER}'"
fi
insert_sql="
insert into api_keys
  (id, hashed_secret, user_id, last_used, expires_at, created_at, updated_at,
   login_type, lifetime_seconds, ip_address, token_name, scopes, allow_list)
select '${key_id}', decode('${key_hash}','hex'), u.id, now(),
       now() + interval '${TOKEN_MINUTES} minute', now(), now(),
       'token', $(( TOKEN_MINUTES * 60 )), '0.0.0.0'::inet, '${TOKEN_NAME}',
       '{coder:all}'::api_key_scope[], '{*:*}'::text[]
from users u
where u.status = 'active' and not u.deleted and not u.is_service_account
  and ${admin_where}
order by (u.rbac_roles && '{owner}'::text[]) desc, u.last_seen_at desc
limit 1
returning id;"
# RETURNING id is what proves the insert landed: the same statement matched against
# zero users prints nothing, so an empty result is the "nobody has registered yet"
# state rather than a separate count query that could race with the delete above.
# The `|| insert_rc` capture is required: a failed assignment carries the command's
# status, so under `set -e` a psql error would abort here without printing anything.
insert_rc=0
inserted="$(psql_query "${insert_sql}")" || insert_rc=$?
case "${inserted}:${insert_rc}" in
  "${key_id}:0") ;;
  ':0')
    access_url_hint="$(env_get CODER_ACCESS_URL)"
    case "${access_url_hint}" in
      '' | *YOUR_LAN_IP*) access_url_hint="https://<host>:3001" ;;
    esac
    if [ -n "${PUSH_USER}" ]; then
      skip "skipped: ${PUSH_USER} is not an active human Coder account, so no push token could be minted — check it with: docker compose exec ${DB_SERVICE} psql -U ${DB_USER} -d ${DB_NAME} -c 'select username, status from users'"
    fi
    skip "skipped: no active Coder account with the site owner role — open ${access_url_hint} and register the first account, it becomes the site admin, then re-run this script."
    ;;
  *)
    printf '%s\n' "${inserted}" >&2
    die "could not mint a push token in ${DB_NAME}.api_keys (exit ${insert_rc}) — pass an explicit admin with CODER_PUSH_USER=<username>"
    ;;
esac

session_token="${key_id}-${key_secret}"

# The two CODER_* names below are the only credentials the CLI reads from the
# environment, and neither is referenced by docker-compose.yml, so prefixing them to
# `docker compose` cannot perturb compose's own ${CODER_*} interpolation. Passing
# them this way (rather than as -e NAME=VALUE) keeps the token out of the argv that
# `ps` shows while the command runs.
coder_exec() {
  # $@ = coder subcommand and args. -T keeps progress output parseable and makes
  # this safe under a pipe; -i is added by callers that supply stdin.
  CODER_URL="${CONTAINER_API_URL}" CODER_SESSION_TOKEN="${session_token}" \
    timeout "${VERIFY_TIMEOUT}" docker compose exec -T \
      -e CODER_URL -e CODER_SESSION_TOKEN "${CODER_SERVICE}" \
      coder "$@" </dev/null
}

# Authenticated before attempting a Terraform run, so a rejected token reads as an
# auth problem and not as a failed build.
whoami_out="$(coder_exec whoami 2>&1)" || whoami_rc=$?
whoami_rc="${whoami_rc:-0}"
if [ "${whoami_rc}" != "0" ]; then
  printf '%s\n' "${whoami_out}" >&2
  die "the minted token was rejected by ${CONTAINER_API_URL} — check that ${CODER_SERVICE} and ${DB_SERVICE} belong to the same deployment (CODER_PG_CONNECTION_URL in docker-compose.yml)"
fi

vars=(--var "image=${dev_image}")
# The daemon has this image from build-dev-image.sh, never from a registry; if it is
# gone, workspaces created from this template fail with an opaque pull error. Say so
# and still push — the image can be built afterwards and re-pushing is cheap.
if ! docker image inspect "${dev_image}" >/dev/null 2>&1; then
  log "note: ${dev_image} is not in the local image store — build it with ./scripts/build-dev-image.sh before creating a workspace."
fi

# litellm_key is sensitive with an empty default, so an unset LITELLM_MASTER_KEY has
# to stay unset rather than be pushed as a blank key. A value still carrying the
# .env.sample placeholder would leave every workspace holding a public constant.
# The value is never printed; it reaches the CLI as an argument and so is visible in
# that process's argv inside the container for the length of the push, which is why
# it is passed only when it is a real secret generated by bootstrap.sh.
litellm_key="$(env_get LITELLM_MASTER_KEY)"
case "${litellm_key}" in
  '' | change-me*)
    log "litellm_key not passed (LITELLM_MASTER_KEY in .env is empty or still the sample placeholder) — workspaces get an empty LITELLM_API_KEY"
    ;;
  *)
    vars+=(--var "litellm_key=${litellm_key}")
    log "litellm_key passed from LITELLM_MASTER_KEY (value not shown)"
    ;;
esac

# coder_agent_url is passed only when .env carries the key at all: the template's own
# default (http://host.docker.internal:3002) is what keeps agents dialing the local
# plain listener when CODER_ACCESS_URL is a public name, and pushing an empty value
# would override that with the provider-rendered access URL.
if grep -q '^CODER_AGENT_URL=' .env 2>/dev/null; then
  vars+=(--var "coder_agent_url=$(env_get CODER_AGENT_URL)")
  log "coder_agent_url passed from .env"
fi

log "pushing ${TEMPLATE_DIR} as template ${TEMPLATE_NAME} (image ${dev_image}) to ${CONTAINER_API_URL} in ${CODER_SERVICE} ..."

# `--directory -` makes the CLI read the template as a tar from stdin, which is how
# the source gets into the container without a copy step. .terraform/ is excluded:
# it is gitignored provider cache, and pushing it would put the plan's provider
# binaries in the version's Filestore row.
#
# No timeout on the push itself: it runs a Terraform plan and apply server-side,
# which legitimately takes minutes. The buildinfo probe above already proved the
# server answers.
push_rc=0
tar -C "${TEMPLATE_DIR}" --exclude=./.terraform -cf - . \
  | CODER_URL="${CONTAINER_API_URL}" CODER_SESSION_TOKEN="${session_token}" \
    docker compose exec -T -i \
      -e CODER_URL -e CODER_SESSION_TOKEN "${CODER_SERVICE}" \
      coder templates push "${TEMPLATE_NAME}" \
        --directory - \
        --yes \
        ${vars[@]+"${vars[@]}"} || push_rc=$?

if [ "${push_rc}" != "0" ]; then
  # The CLI's own plan/apply output already went to the terminal above.
  die "the push of ${TEMPLATE_NAME} failed (exit ${push_rc}) — check the server with: docker compose logs --tail 100 ${CODER_SERVICE}"
fi

# A push can exit 0 while leaving the template inactive, because a failing Terraform
# run produces a version that is present but never activated — and an inactive
# template gives no option in the workspace dropdown. Confirm, do not assume.
verify_rc=0
verify_out="$(coder_exec templates versions list "${TEMPLATE_NAME}" \
  --column id --column active 2>&1)" || verify_rc=$?
if [ "${verify_rc}" != "0" ]; then
  printf '%s\n' "${verify_out}" >&2
  die "pushed ${TEMPLATE_NAME} but could not read its versions (exit ${verify_rc}) — inspect from the host: docker compose exec ${CODER_SERVICE} coder templates versions list ${TEMPLATE_NAME}"
fi

# Table output, not -o json: the JSON form nests the whole TemplateVersion, so
# finding the active version's id needs a JSON parser this repo does not depend on.
# The active cell renders as the word "Active" (ANSI-wrapped, but contiguous), so
# the id is taken from that row; the header row carries the same word and no uuid.
active_id="$(printf '%s\n' "${verify_out}" \
  | grep -i active \
  | grep -oE "${UUID_RE}" \
  | sed -n '1p' || true)"
if [ -z "${active_id}" ]; then
  printf '%s\n' "${verify_out}" >&2
  die "pushed ${TEMPLATE_NAME} but it has no active version — new workspaces cannot use it; inspect: docker compose exec ${CODER_SERVICE} coder templates versions list ${TEMPLATE_NAME}"
fi

# Disarm before the normal exit so the delete runs once, deliberately.
trap - EXIT
psql_sql "${cleanup_sql}" >/dev/null 2>&1 \
  || log "note: the push token '${TOKEN_NAME}' could not be deleted from ${DB_NAME}.api_keys — remove it with: docker compose exec ${DB_SERVICE} psql -U ${DB_USER} -d ${DB_NAME} -c \"delete from api_keys where token_name = '${TOKEN_NAME}';\""

log "template ${TEMPLATE_NAME} pushed; active version ${active_id}"
