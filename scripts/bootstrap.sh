#!/usr/bin/env bash
# Prepare the EVO-T1 Coder stack for first boot:
#   - create .env from .env.sample
#   - generate local secrets (replaces change-me-* placeholders)
#   - fill in CODER_ACCESS_URL with the LAN IP
#   - in public mode (STACK_PUBLIC_HOSTS set) derive the public STACK_*_URL keys
#     and carry those names in the Coder cert SANs
#   - point the Homepage dashboard at that same host and issue its TLS cert
#   - sanity-check Docker and the Arc 140T (/dev/dri)
#   - build the golden workspace image if it is missing, then push the template
#   - wire the Coder Agents chat agent with scripts/coder-agents.sh
#   - check the Spark fleet with scripts/spark-configure.sh and scripts/spark-verify.sh
#
# The last four are the steps a fresh clone used to have to be told about in the
# README. All run at the very end, after every fast check, so a broken box still
# fails quickly on the things that cost nothing to test. None is fatal: a build that
# cannot download, a template push with no Coder session yet, or a Spark that is
# switched off prints why and lets bootstrap finish its "Next steps" output, because
# bootstrap is idempotent and re-running it is the normal recovery path.
#
#   SKIP_DEV_IMAGE_BUILD=1 ./scripts/bootstrap.sh   # print-only, as before
#   SKIP_TEMPLATE_PUSH=1   ./scripts/bootstrap.sh   # no coder templates push
#   SKIP_CODER_AGENTS=1    ./scripts/bootstrap.sh   # no Coder Agents model wiring
#   SKIP_SPARKS=1          ./scripts/bootstrap.sh   # no Spark fleet check
#
# All four are read from the process environment only, never from .env — an .env that
# silently disables provisioning steps would be unreadable to debug.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

command -v docker >/dev/null 2>&1 || {
  echo "error: docker not found on PATH" >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "error: docker compose plugin not available" >&2
  exit 1
}

if [ ! -f .env ]; then
  cp .env.sample .env
  echo "created .env from .env.sample"
fi

gen_secret() {
  openssl rand -hex 16
}

# BSD sed (macOS) vs GNU sed (Linux) in-place editing.
sed_inplace() {
  # $1 = sed script, rest = files
  local script="$1"
  shift
  if sed --version >/dev/null 2>&1; then
    sed -i "$script" "$@"
  else
    sed -i '' "$script" "$@"
  fi
}

set_secret() {
  # $1 = variable name in .env
  local value
  value="$(gen_secret)"
  sed_inplace "s|^${1}=.*|${1}=${value}|" .env
  echo "generated ${1}"
}

# A .env written before a variable existed would leave the variable unset, so
# compose falls back to its inline default (a change-me placeholder) and nothing
# warns. Append anything missing before the secret rotation below can see it.
if [ -f .env.sample ]; then
  while IFS= read -r sample_line; do
    case "${sample_line}" in
      ''|\#*) continue ;;
    esac
    var="${sample_line%%=*}"
    if ! grep -q "^${var}=" .env; then
      printf '%s\n' "${sample_line}" >> .env
      echo "added ${var} to .env"
    fi
  done < <(grep -E '^[A-Z0-9_]+=' .env.sample)
fi

# Only replace values still carrying the sample placeholder.
for var in CODER_PG_PASSWORD LITELLM_MASTER_KEY HOMEPAGE_AUTH_SECRET HOMEPAGE_AUTH_PASSWORD; do
  if grep -q "^${var}=change-me" .env; then
    set_secret "$var"
  fi
done

# Match the placeholder under either scheme: .env.sample ships https://, but an
# .env written while the sample still said http:// carries the old form.
if grep -qE "CODER_ACCESS_URL=https?://YOUR_LAN_IP" .env; then
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [ -z "${lan_ip}" ]; then
    # macOS fallback: first non-loopback interface
    lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
  if [ -n "${lan_ip}" ]; then
    # Rewrite the host token only, so the scheme the sample carries survives.
    sed_inplace "s|://YOUR_LAN_IP|://${lan_ip}|" .env
    access_url="$(sed -n 's|^CODER_ACCESS_URL=||p' .env | tail -n 1)"
    echo "set CODER_ACCESS_URL=${access_url}"
  else
    echo "warning: could not detect a LAN IP; edit CODER_ACCESS_URL in .env"
  fi
fi

# Installs that ran before this have a live CODER_ACCESS_URL=http://<ip>:3001
# line, and plain HTTP is not a secure context, so the browser never exposes
# crypto.randomUUID and the console dies on a blank TemplateBuilderPage. Coder
# serves TLS itself (CODER_TLS_* in compose), so lift any leftover http:// value.
if grep -q "^CODER_ACCESS_URL=http://" .env; then
  sed_inplace "s|^CODER_ACCESS_URL=http://|CODER_ACCESS_URL=https://|" .env
  echo "upgraded CODER_ACCESS_URL to https:// (browsers need a secure context for the console)"
fi

# The dashboard links to Coder/LiteLLM/Kasm and validates its Host header
# against one address, so derive STACK_LAN_HOST from CODER_ACCESS_URL rather
# than detecting a second time and risking a split-brain host.
coder_access_url="$(sed -n 's|^CODER_ACCESS_URL=||p' .env | tail -n 1)"
lan_host="$(printf '%s' "${coder_access_url}" \
  | sed -E 's|^https?://||; s|[:/].*$||')"
if [ -n "${lan_host}" ] && [ "${lan_host}" != "YOUR_LAN_IP" ]; then
  if ! grep -q "^STACK_LAN_HOST=" .env; then
    printf '\n# Host the browser uses to reach the Homepage dashboard.\nSTACK_LAN_HOST=\n' >> .env
  fi
  if ! grep -q "^STACK_LAN_HOST=." .env; then
    sed_inplace "s|^STACK_LAN_HOST=.*|STACK_LAN_HOST=${lan_host}|" .env
    echo "set STACK_LAN_HOST=${lan_host}"
  fi
fi

# bootstrap-managed keys are created on first use and never removed, so one
# upsert covers both "older .env predates this key" and "value changed": write
# only when it actually differs, which keeps a repeat run silent.
upsert_env() {
  # $1 = variable name, $2 = value (empty clears the key so compose's `:-`
  # fallback applies). Values are hostnames/URLs, so `|` is a safe sed delimiter.
  local key="$1" value="$2" current
  if ! grep -q "^${key}=" .env; then
    printf '%s=%s\n' "${key}" "${value}" >> .env
    echo "set ${key}=${value}"
    return 0
  fi
  current="$(sed -n "s|^${key}=||p" .env | tail -n 1)"
  if [ "${current}" != "${value}" ]; then
    sed_inplace "s|^${key}=.*|${key}=${value}|" .env
    echo "set ${key}=${value}"
  fi
}

# --- Public mode -----------------------------------------------------------
# STACK_PUBLIC_HOSTS lists the names the main Traefik on another machine holds
# TLS for; it forwards plain HTTP to this box's router container
# (proxy/router.conf, published as STACK_PROXY_HTTP_PORT, default 8080) with the
# Host header intact, so that header is what homepage validates against
# HOMEPAGE_ALLOWED_HOSTS and what the Coder cert SANs below have to carry.
# Compose appends the raw key to the allow list itself, so bootstrap only has to
# derive the per-service origins.
#
# Entries are DNS names separated by commas, not URLs: only spaces and CRs are
# trimmed, and anything that cannot be a DNS name is dropped with a warning
# rather than pasted into an https:// value. An empty value means LAN-only mode
# and every derived key below is cleared, so compose keeps its LAN fallbacks.
#
# The list is parsed once into an array: the cert check below re-walks it, and a
# second sed of .env there could disagree with what was just written to it.
#
# Order matters: this runs after STACK_LAN_HOST was taken from the LAN form of
# CODER_ACCESS_URL, because the CODER_ACCESS_URL upgrade below replaces it with
# the public name and the LAN cert must still get the LAN IP.
public_entries=()
public_dashboard_url=""
public_coder_url=""
public_kasm_url=""
public_litellm_url=""
raw_public_hosts="$(sed -n 's|^STACK_PUBLIC_HOSTS=||p' .env | tail -n 1)"

while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  case "${entry}" in
    *:*)
      echo "warning: skipping '${entry}' in STACK_PUBLIC_HOSTS — entries are DNS names, not URLs"
      continue
      ;;
    */*|*[!A-Za-z0-9.-]*)
      echo "warning: skipping '${entry}' in STACK_PUBLIC_HOSTS — entries are DNS names"
      continue
      ;;
  esac
  # Dashboard is the fallback: the bare zone apex or a `dashboard-` name, i.e.
  # anything without a service prefix. Each service matches its prefix joined by
  # HYPHEN or DOT. The hyphenated form is the one to use — a wildcard cert at the
  # public edge covers exactly one label, so the dotted two-label form has no
  # cert and the browser aborts the handshake before Traefik is reached. The
  # dotted patterns stay so an .env written before the rename still classifies
  # each entry, rather than every name falling through to the dashboard branch
  # and last-one-win.
  case "${entry}" in
    coder-*|coder.*) public_coder_url="https://${entry}" ;;
    kasm-*|kasm.*) public_kasm_url="https://${entry}" ;;
    litellm-*|litellm.*) public_litellm_url="https://${entry}" ;;
    *) public_dashboard_url="https://${entry}" ;;
  esac
  public_entries+=("${entry}")
done < <(printf '%s\n' "${raw_public_hosts}" | tr -d '\r' | tr ',' '\n' \
           | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# join the accepted entries back into one comma-separated value, so the list
# written to .env is exactly the list the cert SANs below are built from.
public_hosts=""
for entry in ${public_entries[@]+"${public_entries[@]}"}; do
  if [ -n "${public_hosts}" ]; then
    public_hosts="${public_hosts},${entry}"
  else
    public_hosts="${entry}"
  fi
done

# compose interpolates the raw value into HOMEPAGE_ALLOWED_HOSTS, so store the
# cleaned list back; a file that was already written cleanly never differs and
# this branch stays silent.
if [ -n "${raw_public_hosts}" ] && [ "${raw_public_hosts}" != "${public_hosts}" ]; then
  upsert_env STACK_PUBLIC_HOSTS "${public_hosts}"
fi

# The self-signed pair below still serves the LAN origin, so public mode needs
# the LAN IP as well as the DNS names. STACK_LAN_HOST may legitimately be empty
# on a first run, or hold a public name someone copied from CODER_ACCESS_URL
# (which this block is about to rewrite); neither can go into an IP: SAN, so
# re-detect here and let the existing LAN block own the value otherwise.
env_lan_host="$(sed -n 's|^STACK_LAN_HOST=||p' .env | tail -n 1)"
if [ -n "${public_hosts}" ]; then
  case ",${public_hosts}," in
    ",${env_lan_host},"*) env_lan_host="" ;;
  esac
  if [ -z "${env_lan_host}" ]; then
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "${lan_ip}" ]; then
      # macOS fallback: first non-loopback interface
      lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
    fi
    if [ -n "${lan_ip}" ]; then
      upsert_env STACK_LAN_HOST "${lan_ip}"
    else
      echo "warning: STACK_PUBLIC_HOSTS is set but no LAN IP was detected — set STACK_LAN_HOST in .env so the Coder cert keeps an IP SAN."
    fi
  fi
fi

# A missing entry leaves its key empty rather than half-derived, which is exactly
# the LAN fallback compose wants; the same upsert then clears a value left over
# from an earlier public run whose name has since been dropped.
upsert_env STACK_DASHBOARD_URL "${public_dashboard_url}"
upsert_env STACK_CODER_URL "${public_coder_url}"
upsert_env STACK_KASM_URL "${public_kasm_url}"
upsert_env STACK_LITELLM_URL "${public_litellm_url}"

# Coder builds every workspace link and the `coder login` target from
# CODER_ACCESS_URL, so the public name is the whole point of public mode: the
# browser gets a real certificate on a secure context and the TemplateBuilderPage
# works without trusting the self-signed LAN cert at all. Workspace agents keep
# reaching the plain listener through host.docker.internal:${CODER_AGENT_TUNNEL_PORT:-3002}
# (see the compose port and the template rewrite), not through this URL.
# It is written only while a coder entry exists: clearing STACK_PUBLIC_HOSTS
# drops Coder back on whatever the file says, so the value someone set by hand
# for LAN-only use is never guessed at here.
if [ -n "${public_coder_url}" ]; then
  upsert_env CODER_ACCESS_URL "${public_coder_url}"
fi

# homepage-proxy serves TLS from proxy/certs/ and exits if the pair is missing,
# so issue it here. Re-issue when the address changes (new DHCP lease, or a
# hand-edited CODER_ACCESS_URL): a cert whose SAN no longer matches the host the
# browser uses turns into an unavoidable certificate warning.
stack_lan_host="$(sed -n 's|^STACK_LAN_HOST=||p' .env | tail -n 1)"
mkdir -p proxy/certs
cert_file="proxy/certs/homepage.crt"
key_file="proxy/certs/homepage.key"
cert_needs_issue=0
if [ ! -f "${cert_file}" ] || [ ! -f "${key_file}" ]; then
  cert_needs_issue=1
elif ! openssl x509 -in "${cert_file}" -noout -text 2>/dev/null \
    | grep -q "IP Address:${stack_lan_host}"; then
  cert_needs_issue=1
fi
if [ "${cert_needs_issue}" = "1" ] && [ -n "${stack_lan_host}" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
    -subj "/CN=${stack_lan_host}" \
    -addext "subjectAltName=IP:${stack_lan_host},DNS:localhost,DNS:homepage" \
    -keyout "${key_file}" -out "${cert_file}" 2>/dev/null
  chmod 600 "${key_file}"
  echo "issued self-signed dashboard cert for ${stack_lan_host} (browsers warn once — expected on a LAN IP)"
elif [ -z "${stack_lan_host}" ]; then
  echo "warning: no LAN host resolved, so no dashboard cert was issued — homepage-proxy will fail to start until STACK_LAN_HOST is set in .env."
fi

# The coder container terminates TLS itself (CODER_TLS_* in compose) and mounts
# this pair read-only at /etc/coder/certs; it exits if the pair is missing. The
# SAN carries coder and host.docker.internal because the compose health check
# and the workspace agents both reach the server through the host gateway, not
# through the LAN IP the browser uses. In public mode it also carries every
# STACK_PUBLIC_HOSTS name: Traefik terminates TLS for those, but anything that
# dials this origin directly (the agent tunnel's host.docker.internal hop, a
# hand-written /etc/hosts entry) gets the self-signed pair and checks it.
cert_file="proxy/certs/coder.crt"
key_file="proxy/certs/coder.key"
cert_needs_issue=0
if [ ! -f "${cert_file}" ] || [ ! -f "${key_file}" ]; then
  cert_needs_issue=1
elif ! openssl x509 -in "${cert_file}" -noout -text 2>/dev/null \
    | grep -q "IP Address:${stack_lan_host}"; then
  cert_needs_issue=1
fi
# Same bug class one step later: a cert issued before public mode, or before a
# name was added to the list, has no SAN for a name the browser uses, and the
# handshake fails there with no way to click through. Re-issue when any entry is
# missing from the existing pair.
if [ "${cert_needs_issue}" = "0" ]; then
  for entry in ${public_entries[@]+"${public_entries[@]}"}; do
    if ! openssl x509 -in "${cert_file}" -noout -text 2>/dev/null \
         | grep -q "DNS:${entry}"; then
      cert_needs_issue=1
      break
    fi
  done
fi
if [ "${cert_needs_issue}" = "1" ] && [ -n "${stack_lan_host}" ]; then
  coder_san_dns=""
  for entry in ${public_entries[@]+"${public_entries[@]}"}; do
    coder_san_dns="${coder_san_dns},DNS:${entry}"
  done
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
    -subj "/CN=${stack_lan_host}" \
    -addext "subjectAltName=IP:${stack_lan_host},DNS:localhost,DNS:coder,DNS:host.docker.internal${coder_san_dns}" \
    -keyout "${key_file}" -out "${cert_file}" 2>/dev/null
  chmod 600 "${key_file}"
  echo "issued self-signed Coder cert for ${stack_lan_host}${public_hosts:+ and ${public_hosts}} (browsers warn once — expected on a LAN IP)"
elif [ -z "${stack_lan_host}" ]; then
  echo "warning: no LAN host resolved, so no Coder cert was issued — the coder TLS listener will not start until STACK_LAN_HOST is set in .env."
fi

if [ ! -e /dev/dri ]; then
  echo "warning: /dev/dri not found — the IPEX-LLM Ollama service needs the Arc 140T (EVO-T1 hardware)."
fi

# The coder container runs as uid 1000 and needs the host docker group GID to
# reach the mounted socket; the group name does not exist inside the image.
docker_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
if [ -n "${docker_gid}" ]; then
  if grep -q "^DOCKER_GID=" .env; then
    sed_inplace "s|^DOCKER_GID=.*|DOCKER_GID=${docker_gid}|" .env
  else
    printf '\n# GID of the host docker group, for the coder container socket access.\nDOCKER_GID=%s\n' "${docker_gid}" >> .env
  fi
  echo "set DOCKER_GID=${docker_gid}"
else
  echo "warning: could not detect the docker group GID; set DOCKER_GID in .env if workspace creation fails with 'Cannot connect to the Docker daemon'."
fi

# Read .env by sed rather than sourcing it: the file is user-editable, and with
# `set -e` a parse error or a stray command substitution there aborts bootstrap.
env_get() {
  sed -n "s|^${1}=||p" .env 2>/dev/null | tail -n 1 | sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|'
}

# Agent mode (Grok Build, Cline, Roo) needs structured tool calls, and the Arc
# Qwen2.5-Coder weights cannot produce them: they return the call as plain text
# with finish_reason "stop". The Spark-backed `agent` alias (one alias, one
# deployment per Spark) does work, so probe the boxes here rather than letting
# the first agent session fail silently.
# (The Arc `chat` alias — qwen2.5:7b — does emit real tool calls, so it is the
# offline substitute when no Spark answers.)
probe_agent_endpoint() {
  local name="$1" url="$2"
  [ -n "${url}" ] || { echo "warning: ${name} is empty — the agent aliases cannot route."; return 0; }
  local host
  host="$(printf '%s' "${url}" | sed -E 's|^https?://||; s|/.*$||')"
  if curl -fsS -m 5 -o /dev/null "http://${host}/v1/models" 2>/dev/null \
     || curl -fsS -m 5 -o /dev/null "${url}/models" 2>/dev/null; then
    echo "agent endpoint reachable: ${host}"
  else
    echo "warning: no agent endpoint answered at ${host} — the agent aliases fall back to the Arc coder/coder-fast aliases, which return tool calls as plain text. Start a Spark inference server, set ${name} in .env, or point GROK_DEFAULT_MODEL at chat (qwen2.5:7b does emit tool calls)."
  fi
}
probe_agent_endpoint "SPARK1_OPENAI_URL" "$(env_get SPARK1_OPENAI_URL)"
probe_agent_endpoint "SPARK2_OPENAI_URL" "$(env_get SPARK2_OPENAI_URL)"
probe_agent_endpoint "SPARK3_OPENAI_URL" "$(env_get SPARK3_OPENAI_URL)"

# ── Golden workspace image ───────────────────────────────────────────────────
# The workspace template's default image is built locally, not pulled: the Coder
# docker provider resolves it from the host image store. A workspace created without
# it fails with an opaque Docker Hub pull error, so build it here instead of leaving
# it as a README instruction someone has to notice.
#
# Last, and after every fast check above, because a cold build pulls several GB and
# takes many minutes — anything cheaper should have already failed loudly. A failure
# stays advisory: bootstrap is the script you re-run to recover, so aborting here
# would cost the "Next steps" output below.
dev_image="$(env_get DEV_IMAGE)"
dev_image="${dev_image:-evo-t1-dev:latest}"
if docker image inspect "${dev_image}" >/dev/null 2>&1; then
  echo "workspace image ${dev_image} is present ($(docker image inspect --format '{{.Size}}' "${dev_image}" | awk '{printf "%.0f MB", $1/1024/1024}'))"
elif [ -n "${SKIP_DEV_IMAGE_BUILD:-}" ]; then
  echo "note: workspace image ${dev_image} is not built yet (SKIP_DEV_IMAGE_BUILD is set) — run ./scripts/build-dev-image.sh before creating a workspace."
else
  echo "building workspace image ${dev_image} — several GB of downloads, this takes a few minutes ..."
  build_rc=0
  DEV_IMAGE_TAG="${dev_image}" ./scripts/build-dev-image.sh || build_rc=$?
  if [ "${build_rc}" != "0" ]; then
    # Almost always a pinned upstream download that failed or no internet; the build
    # script already printed the layer that stopped.
    echo "warning: the workspace image ${dev_image} did not build (exit ${build_rc}) — workspaces cannot start until it exists. Retry with: ./scripts/build-dev-image.sh"
  fi
fi

# The DinD sidecar's daemon image is resolved from the host store by
# `data "docker_image"` in templates/docker-dev, which never pulls — that is the
# behaviour that keeps a LAN box with no internet from hanging mid-apply, so the
# pull has to happen here instead. Without it, enabling the toggle on a fresh box
# fails the plan with "did not find docker image 'docker:29.8.1-dind'". Advisory
# on failure: DinD is opt-in, so an offline box still gets a working stack.
DIND_IMAGE="$(sed -nE 's/^[[:space:]]*dind_image[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' \
  templates/docker-dev/main.tf | head -n 1)"
DIND_IMAGE="${DIND_IMAGE:-docker:29.8.1-dind}"
if docker image inspect "${DIND_IMAGE}" >/dev/null 2>&1; then
  echo "docker-in-docker image ${DIND_IMAGE} is present"
else
  echo "pulling docker-in-docker image ${DIND_IMAGE} ..."
  if docker pull "${DIND_IMAGE}" >/dev/null 2>&1; then
    echo "pulled ${DIND_IMAGE}"
  else
    echo "warning: ${DIND_IMAGE} did not pull — workspaces with docker-in-docker enabled will fail to build until it is in the local image store (retry: docker pull ${DIND_IMAGE})."
  fi
fi

# ── Template push ────────────────────────────────────────────────────────────
# Non-fatal by design: the push needs a running coder container, docker access and
# at least one registered account, none of which a fresh clone has, and
# push-template.sh exits 0 with a one-line reason when it cannot run. It needs no
# host coder CLI and no `coder login`: it drives the CLI inside the coder container
# over loopback, and it pushes both templates, docker-dev first. A non-zero here
# means at least one of those pushes was attempted and failed.
if [ -n "${SKIP_TEMPLATE_PUSH:-}" ]; then
  echo "note: template push skipped (SKIP_TEMPLATE_PUSH is set) — run ./scripts/push-template.sh after registering an account."
else
  push_rc=0
  ./scripts/push-template.sh || push_rc=$?
  if [ "${push_rc}" != "0" ]; then
    echo "warning: template push failed (exit ${push_rc}) — retry the failed one with: ./scripts/push-template.sh [name]"
  fi
fi

# ── Coder Agents wiring ──────────────────────────────────────────────────────
# The control-plane chat agent cannot answer a single prompt until the deployment
# has a chat model config, and its subagent lanes (general/explore/compaction/
# title_generation) default to nothing once pinned lanes are wanted.
# scripts/coder-agents.sh writes all of that through the server API — the
# `litellm` provider, the `agent` + `chat` model configs, the four lane pins, and
# the system-prompt addendum that teaches delegation to the Grok Build CLI. It
# mints its own short-lived admin token from Postgres (like push-template.sh),
# skips cleanly while the stack is down or nobody has registered yet, and reuses
# what is already wired, so this step is safe to re-run beside the push above.
if [ -n "${SKIP_CODER_AGENTS:-}" ]; then
  echo "note: Coder Agents wiring skipped (SKIP_CODER_AGENTS is set) — run ./scripts/coder-agents.sh --apply after the stack is up."
else
  agents_rc=0
  ./scripts/coder-agents.sh --apply || agents_rc=$?
  if [ "${agents_rc}" != "0" ]; then
    echo "warning: the Coder Agents wiring did not complete (exit ${agents_rc}) — check with: ./scripts/coder-agents.sh --dry-run (once the stack is up), then re-run with --apply."
  fi
fi

# ── Spark fleet ──────────────────────────────────────────────────────────────
# The optional DGX Spark boxes all serve the same Qwen3.8-Flash-Next weights behind one
# `agent` model group with `least-busy` routing, so they have to agree on everything
# that changes an answer: same model id, same PARALLEL stream count, same context
# window, same KV dtype. A box that differs keeps receiving traffic and answers with a
# degraded or wrong completion, and because LiteLLM v1.102.1 builds its Router with
# ignore_invalid_deployments forced to True, a box serving a model id that is spelled
# even one character differently is dropped from the model group at boot — after which
# it answers curl perfectly well while the proxy reports "No deployments available".
# Hence two scripts: spark-configure.sh asserts what each box is set up to run and
# writes sparks/<host>.env with --apply, spark-verify.sh proves the fleet still agrees
# with itself.
#
# Advisory for the same reason as the two steps above: a Spark that is switched off, has
# no server on it, or is not an ssh target from this box is a "not yet" state, so an
# unreachable host prints why and bootstrap still finishes. Hosts come from SPARK_HOSTS
# in the process environment when set; with nothing set both scripts derive the fleet's
# addresses from the SPARK*_URL keys in .env (host part of each), so a .env that names
# real boxes gets those boxes checked instead of being told to retype them. A .env
# still on the shipped spark-<n>.lan placeholders checks those names anyway — they do
# not resolve, so they skip as a "not yet" state rather than failing.
# --no-tests keeps the recipe's own probes — a
# 195k-token needle plus a 1/2/4/5-client bench sweep, minutes per box — out of a
# bootstrap run; re-run ./scripts/spark-verify.sh without it to get them back.
if [ -n "${SKIP_SPARKS:-}" ]; then
  echo "note: Spark fleet check skipped (SKIP_SPARKS is set) — run ./scripts/spark-verify.sh --no-tests to check the boxes."
else
  spark_rc=0
  ./scripts/spark-configure.sh || spark_rc=$?
  if [ "${spark_rc}" != "0" ]; then
    echo "warning: the Spark config check did not complete (exit ${spark_rc}) — no sparks/<host>.env was written. Name the boxes with SPARK_HOSTS and check SPARK_SSH_USER, then re-run ./scripts/spark-configure.sh."
  fi
  verify_rc=0
  ./scripts/spark-verify.sh --no-tests || verify_rc=$?
  if [ "${verify_rc}" != "0" ]; then
    echo "warning: the Spark fleet check failed (exit ${verify_rc}) — either a box disagrees with its peers or its model id is spelled differently from the one litellm/config.yaml declares, and the proxy routes to it either way. Re-run ./scripts/spark-verify.sh --no-tests for the per-box detail, and ./scripts/spark-configure.sh --apply <host> to write the fix."
  fi
fi

echo
echo "Next steps:"
echo "  1. ./scripts/build-dev-image.sh   # one-time polyglot workspace image (re-run if the build above failed)"
echo "  2. docker compose up -d"
# Public mode wins for the two browser-facing steps: those names resolve from
# anywhere and Traefik serves them a real certificate, so printing the LAN form
# would send remote users to an address their machine cannot reach.
coder_reach_url="${public_coder_url:-https://<host>:3001}"
dash_reach_url="${public_dashboard_url:-https://${stack_lan_host:-<host>}}"
echo "  3. Open ${coder_reach_url} and register the first account (it becomes the site admin)"
echo "  4. ./scripts/push-template.sh   # re-run after step 3 if the push above skipped (image=${dev_image})"
echo "  5. ./scripts/pull-models.sh   # pulls the OLLAMA_MODELS listed in .env"
echo "  6. ./scripts/coder-agents.sh --apply   # wires the control-plane chat agent: LiteLLM provider + model configs + lane pins + system prompt (skipped on a cold box; re-run it after steps 2-3)"
echo "  7. ./scripts/spark-verify.sh --no-tests   # read-only Spark fleet check (checks the hosts named by the SPARK*_URL keys in .env; SPARK_HOSTS=\"host1 host2 ...\" overrides that; drop --no-tests for the 195k/bench sweep)"
echo "  8. Kasm first boot: http://<host>:3000 (wizard), then http://<host>:4443 (UI)"
dash_pw="$(sed -n 's|^HOMEPAGE_AUTH_PASSWORD=||p' .env | tail -n 1)"
echo "  9. Dashboard: ${dash_reach_url}/ (login password: ${dash_pw})"
