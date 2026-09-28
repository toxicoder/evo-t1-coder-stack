#!/usr/bin/env bash
# Prepare the EVO-T1 Coder stack for first boot:
#   - create .env from .env.sample
#   - generate local secrets (replaces change-me-* placeholders)
#   - fill in CODER_ACCESS_URL with the LAN IP
#   - in public mode (STACK_PUBLIC_HOSTS set) derive the public STACK_*_URL keys
#     and carry those names in the Coder cert SANs
#   - point the Homepage dashboard at that same host and issue its TLS cert
#   - sanity-check Docker and the Arc 140T (/dev/dri)
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

# The workspace template's default image is built locally, not pulled: the
# Coder docker provider resolves it from the host image store. A workspace
# created without it fails with an opaque Docker Hub pull error, so say so now.
# Read .env by sed rather than sourcing it: the file is user-editable, and with
# `set -e` a parse error or a stray command substitution there aborts bootstrap.
env_get() {
  sed -n "s|^${1}=||p" .env 2>/dev/null | tail -n 1 | sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|'
}

dev_image="$(env_get DEV_IMAGE)"
dev_image="${dev_image:-evo-t1-dev:latest}"
if docker image inspect "${dev_image}" >/dev/null 2>&1; then
  echo "workspace image ${dev_image} is present ($(docker image inspect --format '{{.Size}}' "${dev_image}" | awk '{printf "%.0f MB", $1/1024/1024}'))"
else
  echo "note: workspace image ${dev_image} is not built yet — run ./scripts/build-dev-image.sh before creating a workspace."
fi

# Agent mode (Grok Build, Cline, Roo) needs structured tool calls, and the Arc
# Qwen2.5-Coder weights cannot produce them: they return the call as plain text
# with finish_reason "stop". The Spark-backed agent/agent-fast aliases do work,
# so probe them here rather than letting the first agent session fail silently.
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

echo
echo "Next steps:"
echo "  1. ./scripts/build-dev-image.sh   # one-time polyglot workspace image"
echo "  2. docker compose up -d"
# Public mode wins for the two browser-facing steps: those names resolve from
# anywhere and Traefik serves them a real certificate, so printing the LAN form
# would send remote users to an address their machine cannot reach.
coder_reach_url="${public_coder_url:-https://<host>:3001}"
dash_reach_url="${public_dashboard_url:-https://${stack_lan_host:-<host>}}"
echo "  3. Open ${coder_reach_url} and register the first account (it becomes the site admin)"
echo "  4. coder login ${coder_reach_url} && coder templates push ./templates/docker-dev --var image=${dev_image}"
echo "  5. ./scripts/pull-models.sh   # pulls the OLLAMA_MODELS listed in .env"
echo "  6. Kasm first boot: http://<host>:3000 (wizard), then http://<host>:4443 (UI)"
dash_pw="$(sed -n 's|^HOMEPAGE_AUTH_PASSWORD=||p' .env | tail -n 1)"
echo "  7. Dashboard: ${dash_reach_url}/ (login password: ${dash_pw})"
