#!/usr/bin/env bash
# Wire the Coder Agents (control-plane chat agent) end to end: the LiteLLM AI
# provider, the tool-capable chat model configs, the subagent/compaction/title
# model pins, and the deployment system prompt. bootstrap.sh runs this after
# push-template.sh, and it is safe to re-run at any time: every step reads
# before it writes and skips what is already configured.
#
# Why this exists instead of "click around the Admin UI once": a Coder chat
# turn resolves through chat_model_configs, and a chat with no (enabled) model
# config — or no model config to fall back to — errors on the very first send.
# A deployment that never gets this script has a visible but dead Agents chat.
#
# What each step does and why (all verified against the v2.36.6 source):
#
#   1. AI provider `litellm`, type `openai-compat`, base_url pointing at the
#      compose-internal LiteLLM URL. The chat agent never dials model
#      providers directly; it dials the in-process AI Gateway (aibridge),
#      which forwards to the provider's base_url + /chat/completions. /v1
#      must be part of base_url, and without an api_key the Gateway rejects
#      the forwarding setup, so the master key rides along. When .env leaves
#      LITELLM_MASTER_KEY empty, compose still boots the proxy with its
#      `change-me-litellm` interpolation default, and that default is what
#      this script sends — the provider key must match the live proxy, not
#      the (empty) .env line.
#
#   2. Chat model configs for the two tool-capable aliases in
#      litellm/config.yaml: `agent` (Spark vLLM lane, 262144-token window,
#      made the default) and `chat` (Arc qwen2.5:7b, 32768, the offline
#      substitute). `coder` and `coder-fast` are deliberately NOT registered:
#      on this stack's IPEX-LLM runtime those weights return tool calls as
#      plain text with no tool_calls, and an agent turn without callable
#      tools cannot browse or edit — registering them would only add a
#      silently broken model to the pickers.
#      context_limit is the agent's own compaction budget, so it is pinned to
#      each alias's serving window (70% default compaction threshold applies).
#
#   3. Model pins for the four auxiliary lanes (general + explore = the two
#      subagent types; compaction + title_generation = the helper calls).
#      Pinned to the same tool-capable models so a subagent or a compaction
#      summary never lands on a text-only model, mirroring the Grok CLI
#      lane's [subagents.models] pinning. A lane that already has any pin
#      set is left alone — an admin's choice beats this script's.
#
#   4. The deployment system prompt, APPENDED to Coder's built-in default
#      (include_default_system_prompt stays true: the default carries the
#      tool-discipline and version-control rules worth keeping). The appended
#      text keeps delegation and secret-hygiene rules that must hold even
#      when a chat has no workspace attached and never reads a template's
#      instruction files.
#
# Like push-template.sh, everything Coder-facing runs INSIDE the coder
# container against the server's own loopback listener, with a short-lived
# admin token minted in the stack's Postgres (token_name 'stack-coder-agents',
# deleted via the trap, and never printed). Auth JSON bodies travel on stdin;
# the master key and the session token are expanded by the in-container
# shell from the environment, so neither ever lands in a host-visible argv.
#
# Usage:
#   bash scripts/coder-agents.sh                 # apply: write what is missing
#   bash scripts/coder-agents.sh --dry-run       # print the intended end state only
#   SKIP_CODER_AGENTS=1 bash scripts/bootstrap.sh   # bootstrap skips this step
# Overrides (rare; each exists for a stack that renamed something in compose):
#   CODER_CONTAINER_SERVICE=coder    compose service holding the server
#   CODER_DB_SERVICE=db              compose service holding Postgres
#   CODER_CONTAINER_API_URL=…        server API URL reachable from inside the
#                                    coder container (default http://127.0.0.1:3000)
#   CODER_AGENTS_PROVIDER_URL=…      provider base_url as seen from inside the
#                                    coder container (default http://litellm:4000/v1)
#   CODER_AGENTS_USER=<username>     user to mint the token for
#   CODER_AGENTS_TOKEN_MINUTES=10    lifetime of the minted token
set -euo pipefail

cd "$(dirname "$0")/.."

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

MODE=apply
for arg in "$@"; do
  case "${arg}" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    *) die "usage: $0 [--dry-run|--apply] (default: --apply)" ;;
  esac
done

CODER_SERVICE="${CODER_CONTAINER_SERVICE:-coder}"
DB_SERVICE="${CODER_DB_SERVICE:-db}"
DB_USER="coder"
DB_NAME="coder"
CONTAINER_API_URL="${CODER_CONTAINER_API_URL:-http://127.0.0.1:3000}"
PROVIDER_NAME="litellm"
PROVIDER_URL="${CODER_AGENTS_PROVIDER_URL:-http://litellm:4000/v1}"
AGENTS_USER="${CODER_AGENTS_USER:-}"
TOKEN_MINUTES="${CODER_AGENTS_TOKEN_MINUTES:-10}"
case "${TOKEN_MINUTES}" in
  '' | *[!0-9]*) TOKEN_MINUTES=10 ;;
esac
TOKEN_NAME="stack-coder-agents"
PROBE_TIMEOUT=20
API_TIMEOUT=20
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

log() { printf '%s\n' "$*"; }
skip() { printf '%s\n' "$*"; exit 0; }

# Read .env by sed rather than sourcing it (same reason as push-template.sh).
env_get() {
  sed -n "s|^${1}=||p" .env 2>/dev/null | tail -n 1 | sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|'
}

first_line() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

# ── Guards ──────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 \
  || skip "skipped: docker is not on PATH, so neither the coder server nor its database can be reached"
command -v timeout >/dev/null 2>&1 \
  || skip "skipped: timeout(1) is not available, so the API probes below cannot be bounded"

if ! running="$(docker compose ps --status running --services 2>&1)"; then
  skip "skipped: could not query the stack ($(first_line "${running}")) — this script needs docker access; run it with sudo, or add your user to the docker group"
fi
if ! grep -qx "${CODER_SERVICE}" <<<"${running}"; then
  skip "skipped: the ${CODER_SERVICE} service is not running yet (start the stack with: docker compose up -d)"
fi
if ! grep -qx "${DB_SERVICE}" <<<"${running}"; then
  skip "skipped: the ${DB_SERVICE} service is not running, so no admin token can be minted (start the stack with: docker compose up -d)"
fi

# curl is used rather than the coder CLI because it needs no session file;
# the coder image ships it (push-template.sh relies on the same probe).
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

# ── The intended end state ──────────────────────────────────────────────────
# Model aliases match litellm/config.yaml: `agent` = the tool-capable Spark
# lane (Qwen3.8-Flash-Next, 262144-token window, LiteLLM degrades it to the
# text-only `coder` when every Spark box is dark — a last resort visible in
# spend logs), `chat` = the Arc qwen2.5:7b, tool-capable and always on the
# compose network. context_limit is the agent's compaction budget and is set
# to each alias's serving window; the compression threshold keeps its default.
MODEL_AGENT_DISPLAY="Coder Agents — tool-calling (Spark vLLM Qwen3.8-Flash-Next)"
MODEL_CHAT_DISPLAY="Coder Agents — tool-calling (Arc IPEX-LLM qwen2.5:7b)"

# ── Dry-run prints the plan and stops before any write (no token minted) ──
if [ "${MODE}" = "dry-run" ]; then
  log "dry run (no changes; rerun without --dry-run to apply):"
  log "  ensure AI provider ${PROVIDER_NAME} (type openai-compat, enabled, base_url ${PROVIDER_URL}, api_keys: [LITELLM_MASTER_KEY from .env, or the compose placeholder — hidden])"
  log "  ensure chat model config agent (context_limit 262144, is_default true)"
  log "  ensure chat model config chat (context_limit 32768)"
  log "  pin model overrides general+explore -> agent (or chat if only chat exists); compaction+title_generation -> chat (or agent)"
  log "  ensure deployment system prompt (custom text appended to Coder's default)"
  exit 0
fi

# ── Mint a short-lived token (same trust model as push-template.sh) ────────
command -v openssl >/dev/null 2>&1 \
  || skip "skipped: openssl is not on PATH, so no API token can be generated"

if [ -n "${AGENTS_USER}" ] && ! printf '%s' "${AGENTS_USER}" | grep -qE '^[A-Za-z0-9._@-]+$'; then
  die "CODER_AGENTS_USER='${AGENTS_USER}' is not a valid Coder username (letters, digits, dot, underscore, hyphen, @)"
fi

key_id="$(openssl rand -hex 5)"
key_secret="$(openssl rand -hex 11)"
key_hash="$(printf '%s' "${key_secret}" | openssl dgst -sha256 -r 2>/dev/null \
  | cut -c1-64)"
if [ "${#key_hash}" != "64" ]; then
  die "could not compute a sha256 digest with openssl — this openssl build lacks the dgst command"
fi

psql_sql() {
  timeout "${PROBE_TIMEOUT}" docker compose exec -T "${DB_SERVICE}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -c "$1" </dev/null 2>&1
}

psql_query() {
  timeout "${PROBE_TIMEOUT}" docker compose exec -T "${DB_SERVICE}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -tAc "$1" </dev/null 2>&1 \
    | tr -d '[:space:]'
}

# Replace, do not collide with, a token left behind by a killed run.
cleanup_sql="delete from api_keys where token_name = '${TOKEN_NAME}';"
if ! cleanup_out="$(psql_sql "${cleanup_sql}")"; then
  die "could not clean up in ${DB_SERVICE}: $(first_line "${cleanup_out}")"
fi
cleanup_token() {
  psql_sql "delete from api_keys where token_name = '${TOKEN_NAME}';" >/dev/null 2>&1 || true
}
trap 'cleanup_token' EXIT
trap 'trap - EXIT; cleanup_token; exit 130' INT HUP

# A token narrowed to fewer scopes fails the /api/experimental and /ai/*
# middleware before any handler runs, so the minted token keeps coder:all —
# the compensating controls are the minutes-long lifetime and the delete trap.
admin_where="(rbac_roles && '{owner,template-admin}'::text[])"
if [ -n "${AGENTS_USER}" ]; then
  admin_where="username = '${AGENTS_USER}'"
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
insert_rc=0
inserted="$(psql_query "${insert_sql}")" || insert_rc=$?
case "${inserted}:${insert_rc}" in
  "${key_id}:0") ;;
  ':0')
    access_url_hint="$(env_get CODER_ACCESS_URL)"
    case "${access_url_hint}" in
      '' | *YOUR_LAN_IP*) access_url_hint="https://<host>:3001" ;;
    esac
    if [ -n "${AGENTS_USER}" ]; then
      skip "skipped: ${AGENTS_USER} is not an active human Coder account, so no token could be minted — check: docker compose exec ${DB_SERVICE} psql -U ${DB_USER} -d ${DB_NAME} -c 'select username, status from users'"
    fi
    skip "skipped: no active Coder account with the site owner role — open ${access_url_hint} and register the first account, it becomes the site admin, then re-run this script."
    ;;
  *)
    printf '%s\n' "${inserted}" >&2
    die "could not mint an API token in ${DB_NAME}.api_keys (exit ${insert_rc}) — pass an explicit admin with CODER_AGENTS_USER=<username>"
    ;;
esac

session_token="${key_id}-${key_secret}"

# ── API helpers ─────────────────────────────────────────────────────────────
# -T keeps output parseable; -i (write calls) streams the JSON body on stdin.
# The Authorization header is assembled by the IN-CONTAINER shell from
# CODER_SESSION_TOKEN (passed as -e NAME, value via the env, never argv).
api_read() {
  # $1 = path. Prints the body; a non-2xx exits non-zero (curl -f).
  CODER_SESSION_TOKEN="${session_token}" \
    timeout "${API_TIMEOUT}" docker compose exec -T \
      -e CODER_SESSION_TOKEN "${CODER_SERVICE}" \
      sh -c 'curl -fsS -m 15 -H "Authorization: Bearer $CODER_SESSION_TOKEN" "$1"' \
      sh "${CONTAINER_API_URL}${1}"
}

api_write() {
  # $1 = method, $2 = path, $3 = JSON body.
  printf '%s' "$3" | CODER_SESSION_TOKEN="${session_token}" \
    timeout "${API_TIMEOUT}" docker compose exec -T -i \
      -e CODER_SESSION_TOKEN "${CODER_SERVICE}" \
      sh -c 'curl -fsS -m 15 -H "Authorization: Bearer $CODER_SESSION_TOKEN" -H "Content-Type: application/json" -X "$1" --data-binary @- "$2"' \
      sh "$1" "${CONTAINER_API_URL}${2}"
}

# Escape a string for JSON embedding: backslash, then double quote, then
# real newlines to the two-character sequence \n (a raw newline inside a
# JSON string is malformed; the system prompt body is multiline).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# mask_secret renders a key the way the server masks stored keys (aibridge's
# MaskSecret): the API shows the first and last N characters, N being 4 for
# keys of 20+ characters, 2 for 10+, 1 for 5+, and "..." alone below 5.
# Comparing masks is how the script notices a rotated LITELLM_MASTER_KEY:
# a changed key almost always changes its mask, and re-running --apply
# re-patches the provider key set. Keys whose masks all still equal the
# .env key's mask stay untouched — deliberate, since keys added by hand in
# the Admin UI are an admin's decision to keep. (A key under 5 characters
# masks to "..." and could hide a change; that is a placeholder, not a key.)
mask_secret() {
  local s="$1" n reveal
  n="${#s}"
  if [ "${n}" -ge 20 ]; then reveal=4
  elif [ "${n}" -ge 10 ]; then reveal=2
  elif [ "${n}" -ge 5 ]; then reveal=1
  else reveal=0
  fi
  if [ "${n}" -le $((reveal * 2)) ]; then
    printf '...'
    return
  fi
  printf '%s...%s' "${s:0:${reveal}}" "${s:$((n - reveal)):${reveal}}"
}

# ── 1. AI provider ──────────────────────────────────────────────────────────
# Empty in .env is not "keyless": docker-compose.yml interpolates
# ${LITELLM_MASTER_KEY:-change-me-litellm}, so the proxy that is running
# right now was booted demanding that placeholder key. Sending the empty
# string would configure a provider the live proxy rejects on every request.
litellm_key="$(env_get LITELLM_MASTER_KEY)"
if [ -z "${litellm_key}" ]; then
  litellm_key="change-me-litellm"
  log "note: LITELLM_MASTER_KEY is empty in .env — using the compose interpolation default (rotate it in .env + this script's env override if you rotate the proxy's key)"
fi

provider_list_rc=0
provider_list="$(api_read "/api/v2/ai/providers")" || provider_list_rc=$?
if [ "${provider_list_rc}" != "0" ]; then
  printf '%s\n' "${provider_list}" >&2
  die "could not list AI providers — the minted token was rejected or the API failed (check: docker compose logs --tail 100 ${CODER_SERVICE})"
fi

provider_body=""
provider_exists=0
if printf '%s' "${provider_list}" | grep -q "\"name\":\"${PROVIDER_NAME}\""; then
  provider_exists=1
  provider_body="$(printf '%s' "${provider_list}" \
    | tr '{' '\n' | grep "\"name\":\"${PROVIDER_NAME}\"" | head -1)"
fi

provider_drift=""
if [ "${provider_exists}" = "1" ]; then
  # Drift = base_url moved (the Gateway would dial the wrong place) or the
  # stored key set no longer matching the key the live proxy demands.
  if ! printf '%s' "${provider_body}" | grep -qF "\"base_url\":\"${PROVIDER_URL}\""; then
    provider_drift="base_url"
  fi
  # Key drift: the providers API returns each stored key masked (see
  # mask_secret), so a rotated LITELLM_MASTER_KEY is detectable by mask
  # alone. Drift fires when no key is stored at all — an empty proxy would
  # reject every forwarded request — or when any stored key's mask differs
  # from the current key's mask; the patch below then replaces the whole
  # set. Masks are pulled from the full provider_list: the provider_body
  # chunk (split on '{') ends before that provider's api_keys array.
  provider_masks="$(printf '%s' "${provider_list}" \
    | awk -v RS="\"name\":\"" -v n="${PROVIDER_NAME}\"" 'index($0, n) == 1' \
    | tr '{' '\n' | grep -o '"masked":"[^"]*"' \
      | sed -e 's/^"masked":"//' -e 's/"$//' || true)"
  want_mask="$(mask_secret "${litellm_key}")"
  if [ -z "${provider_masks}" ] \
    || [ -n "$(printf '%s\n' "${provider_masks}" | grep -Fxv -e "${want_mask}" || true)" ]; then
    provider_drift="${provider_drift:+${provider_drift}+}api_keys"
  fi
  if [ -z "${provider_drift}" ]; then
    log "provider ${PROVIDER_NAME}: already configured (left untouched)"
  else
    patch_body="{\"base_url\":\"$(json_escape "${PROVIDER_URL}")\""
    if printf '%s' "${provider_drift}" | grep -q api_keys; then
      patch_body="${patch_body},\"api_keys\":[{\"api_key\":\"$(json_escape "${litellm_key}")\"}]"
    fi
    patch_body="${patch_body}}"
    log "provider ${PROVIDER_NAME}: drift in ${provider_drift}, patching"
    if ! api_write PATCH "/api/v2/ai/providers/${PROVIDER_NAME}" "${patch_body}" >/dev/null; then
      die "provider ${PROVIDER_NAME} exists but its ${provider_drift} drifted, and patching it failed — edit in the UI (Admin -> AI Providers) or delete and re-run this script"
    fi
  fi
else
  # One explicit JSON body; the master key is never empty by this point
  # (compose interpolation default above), so it always rides along.
  create_body="{\"type\":\"openai-compat\",\"name\":\"${PROVIDER_NAME}\",\"display_name\":\"LiteLLM (local cluster)\",\"enabled\":true,\"base_url\":\"$(json_escape "${PROVIDER_URL}")\",\"api_keys\":[\"$(json_escape "${litellm_key}")\"]}"
  log "creating AI provider ${PROVIDER_NAME} (base_url ${PROVIDER_URL})"
  if ! api_write POST "/api/v2/ai/providers" "${create_body}" >/dev/null; then
    die "could not create provider ${PROVIDER_NAME} — re-run against a healthy server, or wire it by hand (Admin -> AI Providers)"
  fi
fi

# ── 2. Chat model configs ───────────────────────────────────────────────────
# Both reads and writes below go through /api/experimental; on v2.36.6 the
# chat-model surface lives ONLY there (no guarantee of API stability, by
# design). `is_default` matters twice: the default config is what a
# chat without an explicit model pick resolves to, and its absence makes
# every chat turn error before the first tool call.

# Fresh api_read per call: after a create, the reread below must see the new
# row (a stale pre-create list would leave step 3 without pin targets).
# First uuid inside the object for a given model = that config's id (id is
# the first field serialized; the object is isolated by splitting on braces).
model_config_id() {
  local body
  if ! body="$(api_read "/api/experimental/chats/model-configs")"; then
    return 0
  fi
  printf '%s' "${body}" \
    | tr '{}' '\n\n' \
    | grep -F "\"model\":\"${1}\"" \
    | head -1 \
    | grep -oE "${UUID_RE}" \
    | head -1 || true
}

agent_id="$(model_config_id agent)"
chat_id="$(model_config_id chat)"

create_model_config() {
  # $1 = model, $2 = display name, $3 = context_limit, $4 = is_default(true|false)
  if ! api_write POST "/api/experimental/chats/model-configs" \
    "{\"ai_provider_id\":\"${provider_id}\",\"model\":\"${1}\",\"display_name\":\"$(json_escape "${2}")\",\"enabled\":true,\"is_default\":${4},\"context_limit\":${3}}" >/dev/null; then
    printf 'error: creating model config %s failed; if the provider was just patched it may need a server restart to pick up the new base_url\n' "${1}" >&2
    return 1
  fi
}

# The provider uuid is needed for the model-config body.
provider_get="$(api_read "/api/v2/ai/providers/${PROVIDER_NAME}")" \
  || die "could not read back provider ${PROVIDER_NAME} (its name may differ in case or the create failed)"
provider_id="$(printf '%s' "${provider_get}" | grep -oE "${UUID_RE}" | head -1)"
if [ -z "${provider_id}" ]; then
  die "provider ${PROVIDER_NAME} exists but no provider uuid could be read from the API reply"
fi

if [ -n "${agent_id}" ]; then
  log "model config agent: already present (left untouched)"
else
  log "creating model config agent (context_limit 262144, default)"
  create_model_config "agent" "${MODEL_AGENT_DISPLAY}" 262144 true \
    || die "the agent model config could not be created — Agents chats will error until one exists"
  # A created config is only proof for the NEXT step if it reads back; the
  # uuid is reread rather than trusted from the POST body (same shape, one
  # extra call, no assumption about partial success).
  agent_id="$(model_config_id agent)"
fi

if [ -n "${chat_id}" ]; then
  log "model config chat: already present (left untouched)"
else
  log "creating model config chat (context_limit 32768)"
  create_model_config "chat" "${MODEL_CHAT_DISPLAY}" 32768 false \
    || die "the chat model config could not be created — re-run after the server is healthy"
  chat_id="$(model_config_id chat)"
fi

# ── 3. Model pins for the four auxiliary lanes ──────────────────────────────
# general/explore name the subagent types; compaction/title_generation name
# the helper calls. Unset lanes get pinned; any existing pin is respected.
pin_lane() {
  # $1 = lane, $2 = model label (for the log line), $3 = model-config uuid.
  local lane="$1" label="$2" target="$3" current
  if [ -z "${target}" ]; then
    log "lane ${lane}: skipped — no model config available to pin"
    return 0
  fi
  if ! current="$(api_read "/api/experimental/chats/config/model-override/${lane}")"; then
    log "lane ${lane}: could not read the current pin, leaving it alone"
    return 0
  fi
  if ! printf '%s' "${current}" | grep -qF '"model_config_id":""'; then
    log "lane ${lane}: already pinned, leaving the admin's choice in place"
    return 0
  fi
  if api_write PUT "/api/experimental/chats/config/model-override/${lane}" \
    "{\"model_config_id\":\"${target}\"}" >/dev/null; then
    log "lane ${lane}: pinned to model config ${label}"
  else
    die "lane ${lane} could not be pinned to ${label}"
  fi
}

primary="${agent_id:-${chat_id}}"
secondary="${chat_id:-${agent_id}}"
if [ -z "${primary}" ]; then
  # Neither a pre-existing config nor a fresh create survived the reread
  # (e.g. a server that restarted mid-run). Stop loudly instead of leaving
  # the model pins without a target.
  die "no chat model config could be registered or found; Agents chat needs one — check the LiteLLM aliases against ${PROVIDER_URL}/v1/models"
fi
pin_lane general "agent (tool-capable primary)" "${primary}"
pin_lane explore "agent (tool-capable primary)" "${primary}"
pin_lane compaction "chat (32k tool-capable fallback)" "${secondary}"
pin_lane title_generation "chat (32k tool-capable fallback)" "${secondary}"

# ── 4. Deployment system prompt ─────────────────────────────────────────────
# Exact-match compare (server sanitizes, our text is plain printable ASCII).
want_prompt="Coder Agents on this stack run against locally served models over the LAN (LiteLLM to Spark vLLM or Arc IPEX-LLM). Keep tool use deliberate; local GPUs are a shared budget.
For multi-file or whole-module work, delegate to the Grok Build CLI (binary \`grok\`, also on PATH as \`agent\`) via a background process using the grok-build-delegation skill, then review its diff and run the project tests yourself; answer small asks directly without delegating.
Never echo, quote, or write into files the values of \$LITELLM_API_KEY, \$GH_TOKEN, or \$GITHUB_TOKEN found inside a workspace."

current_prompt="$(api_read "/api/experimental/chats/config/system-prompt")" \
  || die "could not read the deployment system prompt"
if printf '%s' "${current_prompt}" | grep -qF 'grok-build-delegation skill, then review its diff'; then
  log "system prompt: already carries the stack addendum (left untouched)"
else
  log "appending the stack addendum to the deployment system prompt"
  escaped_prompt="$(json_escape "${want_prompt}")"
  if ! api_write PUT "/api/experimental/chats/config/system-prompt" \
    "{\"system_prompt\":\"${escaped_prompt}\",\"include_default_system_prompt\":true}" >/dev/null; then
    die "the system prompt could not be written — re-run, or paste the same text in the UI (Admin -> Experiments -> Agent Chat)"
  fi
fi

# ── Wrap-up ────────────────────────────────────────────────────────────────
# Disarm before the delete so the delete runs once, deliberately.
trap - EXIT
psql_sql "${cleanup_sql}" >/dev/null 2>&1 \
  || log "note: the token '${TOKEN_NAME}' could not be deleted from ${DB_NAME}.api_keys — remove it with: docker compose exec ${DB_SERVICE} psql -U ${DB_USER} -d ${DB_NAME} -c \"delete from api_keys where token_name = '${TOKEN_NAME}';\""

log "Coder Agents wiring complete: provider ${PROVIDER_NAME}, model configs (agent default + chat fallback), four model pins, system prompt."
log "Spot-check in the UI: start an Agents chat, pick a workspace, and ask it to list files — a tool call in the reply means the loop is live."
