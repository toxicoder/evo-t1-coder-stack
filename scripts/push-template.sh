#!/usr/bin/env bash
# Push templates/docker-dev into the running Coder server and confirm the pushed
# version became the active one. bootstrap.sh runs this for you; it is also the
# standalone loop for "I edited the template, make workspaces see it".
#
# Contract: push when it can, otherwise exit 0 with a one-line reason. The coder
# CLI, a running server and a logged-in session are three separate things a fresh
# clone does not have yet, and bootstrap.sh must not show a red error for states
# that are simply not-true-yet. Only a push that was attempted and failed exits
# non-zero.
#
# Every coder invocation reads stdin from /dev/null under `timeout`, so this never
# blocks on a login or parameter prompt nobody can answer when it is run from a
# script. `--yes` bypasses the confirmation prompt the push itself would raise.
#
# Re-runnable: a push replaces the template's active version, so re-running after
# an unchanged checkout just re-activates equivalent Terraform. Nothing here reads
# or writes .env beyond the reads below.
#
# Usage:
#   ./scripts/push-template.sh
#   SKIP_TEMPLATE_PUSH=1 ./scripts/bootstrap.sh   # bootstrap skips this step
set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE_NAME="docker-dev"
TEMPLATE_DIR="templates/docker-dev"
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

[ -f "${TEMPLATE_DIR}/main.tf" ] \
  || die "${TEMPLATE_DIR}/main.tf not found (run this from the repo root)"
# Coder pushes without a lockfile but warns, and the README's fix is one command;
# say it here rather than make the operator decode the CLI's warning.
if [ ! -f "${TEMPLATE_DIR}/.terraform.lock.hcl" ]; then
  log "note: ${TEMPLATE_DIR}/.terraform.lock.hcl is missing — regenerate it with:"
  log "      terraform -chdir=${TEMPLATE_DIR} init -backend=false"
fi

command -v coder >/dev/null 2>&1 \
  || skip "skipped: the coder CLI is not on PATH (it is baked into the workspace image; on the host, install it as the README describes and export PATH=\"\$PATH:\$HOME/bin\")"
# Without it a wedged server could hang this script on the very first probe.
command -v timeout >/dev/null 2>&1 \
  || skip "skipped: timeout(1) is not available, so the coder probes cannot be bounded"

first_line() {
  # $1 = text; prints its first non-blank line so a tool's own complaint can be
  # quoted without dumping its whole stderr into this script's output. The `|| true`
  # is load-bearing: pipefail makes an all-blank input (grep exits 1) abort the
  # caller, which is an assignment under `set -e`.
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

# The server has to be up before the CLI has anything to talk to. Ask compose
# rather than the daemon so the check stays scoped to this stack, and treat a
# docker failure as "cannot tell" rather than as a push failure.
if ! command -v docker >/dev/null 2>&1; then
  skip "skipped: docker is not on PATH, so the coder server container cannot be checked"
fi
if ! running="$(docker compose ps --status running --services 2>&1)"; then
  skip "skipped: could not query the stack ($(first_line "${running}")) — this script needs docker access; run it with sudo, or add your user to the docker group"
fi
if ! grep -qx coder <<<"${running}"; then
  skip "skipped: the coder service is not running yet (start the stack with: docker compose up -d)"
fi

# CODER_ACCESS_URL is the address the browser and the CLI are meant to use, so it
# is the only sane `coder login` target. LAN installs carry https://<ip>:3001 and
# the port is load-bearing (Coder serves TLS itself via CODER_TLS_*; :3000/:4443
# belong to Kasm). Public installs carry https://<name> with no port, because
# Traefik terminates TLS at 443 there — appending a port to that form would break
# it, so the authority is kept exactly as written and only the scheme and any path
# are normalised. Anything left on http:// is lifted: the same secure-context
# reason bootstrap.sh documents for the console applies to the CLI's API calls.
access_url="$(env_get CODER_ACCESS_URL)"
# Order matters: strip the scheme first, then the path. Truncating at the first `/`
# before removing the scheme leaves the bare `https:` of a scheme-only value, which
# would then be printed as the login target `https://https`.
hostport="${access_url#*://}"
hostport="${hostport%%/*}"
hostport="${hostport%%\?*}"
hostport="${hostport%:}"
login_url=""
case "${access_url}" in
  '' | *YOUR_LAN_IP*) ;;
  *)
    # A port is legitimate (Coder serves TLS itself on :3001), a second colon is not,
    # and neither is an authority with anything hostname-shaped missing — those are
    # hand-edited .env values, so leave login_url empty and ask for bootstrap instead
    # of handing the CLI something it would fail on later. An IPv6 literal is not
    # supported: bootstrap writes an IPv4 or a DNS name, never a bracketed address.
    case "${hostport}" in
      '' | *:*:* | *@* | *#* | *\?*) ;;
      *)
        case "${hostport%%:*}" in
          '' | [!A-Za-z0-9]*) ;;
          *) login_url="https://${hostport}" ;;
        esac
        ;;
    esac
    ;;
esac

dev_image="$(env_get DEV_IMAGE)"
dev_image="${dev_image:-evo-t1-dev:latest}"

# Session detection without an interactive prompt: a CLI with no token for the
# target fails immediately, and one whose server is unreachable is bounded.
# --url is passed so the CLI cannot quietly act on a session stored for a different
# deployment — a stale CODER_URL or an older `coder login` would otherwise push this
# repo's template into the wrong server. With no CODER_ACCESS_URL to work from, the
# probe lets the CLI resolve its own stored URL instead of guessing at one.
probe_rc=0
probe_output=""
url_args=()
if [ -n "${login_url}" ]; then
  url_args=(--url "${login_url}")
fi

probe_output="$(timeout "${PROBE_TIMEOUT}" coder templates list -o json \
  ${url_args[@]+"${url_args[@]}"} </dev/null 2>&1)" || probe_rc=$?

if [ "${probe_rc}" != "0" ]; then
  if [ "${probe_rc}" = "124" ]; then
    skip "skipped: the coder CLI got no answer within ${PROBE_TIMEOUT}s from ${login_url:-its stored session URL} — the server may still be starting: docker compose logs --tail 100 coder"
  fi
  if [ -z "${login_url}" ]; then
    skip "skipped: no coder session and no usable CODER_ACCESS_URL in .env — run ./scripts/bootstrap.sh, then log in once: coder login https://<host>:3001"
  fi
  # The CLI wraps its own complaint in a "see --help" line, so quote the error line
  # it prints underneath. Distinguishing an absent session from an unreachable URL
  # matters: the first is fixed by `coder login`, the second by the server or .env.
  cli_error="$(printf '%s\n' "${probe_output}" | grep '^error:' | sed -n '1p' || true)"
  case "${cli_error}" in
    *'not logged in'* | *'session has expired'*)
      log "skipped: no coder session for ${login_url}; log in once and re-run this script."
      ;;
    *)
      # Could not tell an absent session from an unreachable URL, so the login
      # command is printed either way: it is the fix for one and harmless for the other.
      log "skipped: the coder CLI could not use ${login_url}; log in once and re-run this script (if it is already logged in, the server is the problem — docker compose logs --tail 100 coder)."
      ;;
  esac
  if [ -n "${cli_error}" ]; then
    log "         coder said: ${cli_error}"
  else
    first="$(first_line "${probe_output}")"
    if [ -n "${first}" ]; then
      log "         coder said: ${first}"
    fi
  fi
  log "         coder login ${login_url}"
  log "         or, on a server that has no accounts yet:"
  log "         coder login ${login_url} --first-user-email you@example.com --first-user-username you --first-user-password 'a-long-passphrase' --first-user-trial=false"
  exit 0
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
# that process's argv for the length of the push, which is why it is passed only when
# it is a real secret generated by bootstrap.sh.
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

# No timeout here: the push runs a Terraform plan and apply server-side, which
# legitimately takes minutes. The probe above already proved the server answers.
log "pushing ${TEMPLATE_DIR} as template ${TEMPLATE_NAME} (image ${dev_image}) ..."
push_rc=0
coder templates push "${TEMPLATE_NAME}" \
  --directory "${TEMPLATE_DIR}" \
  --yes \
  ${url_args[@]+"${url_args[@]}"} \
  ${vars[@]+"${vars[@]}"} </dev/null || push_rc=$?

if [ "${push_rc}" != "0" ]; then
  # The CLI's own plan/apply output already went to the terminal above.
  die "the push of ${TEMPLATE_NAME} failed (exit ${push_rc}) — check the server with: docker compose logs --tail 100 coder"
fi

# A push can exit 0 while leaving the template inactive, because a failing Terraform
# run produces a version that is present but never activated — and an inactive
# template gives no option in the workspace dropdown. Confirm, do not assume.
verify_rc=0
verify_out="$(timeout "${VERIFY_TIMEOUT}" coder templates versions list "${TEMPLATE_NAME}" \
  --column id --column active </dev/null 2>&1)" || verify_rc=$?
if [ "${verify_rc}" != "0" ]; then
  printf '%s\n' "${verify_out}" >&2
  die "pushed ${TEMPLATE_NAME} but could not read its versions (exit ${verify_rc}) — check: coder templates versions list ${TEMPLATE_NAME}"
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
  die "pushed ${TEMPLATE_NAME} but it has no active version — new workspaces cannot use it; inspect: coder templates versions list ${TEMPLATE_NAME}"
fi

log "template ${TEMPLATE_NAME} pushed; active version ${active_id}"
