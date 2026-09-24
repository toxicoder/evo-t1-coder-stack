#!/usr/bin/env bash
# Prepare the EVO-T1 Coder stack for first boot:
#   - create .env from .env.sample
#   - generate local secrets (replaces change-me-* placeholders)
#   - fill in CODER_ACCESS_URL with the LAN IP
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

# Only replace values still carrying the sample placeholder.
for var in CODER_ADMIN_PASSWORD CODER_PG_PASSWORD LITELLM_MASTER_KEY; do
  if grep -q "^${var}=change-me" .env; then
    set_secret "$var"
  fi
done

if grep -q "CODER_ACCESS_URL=http://YOUR_LAN_IP" .env; then
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [ -z "${lan_ip}" ]; then
    # macOS fallback: first non-loopback interface
    lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
  if [ -n "${lan_ip}" ]; then
    sed_inplace "s|http://YOUR_LAN_IP|http://${lan_ip}|" .env
    echo "set CODER_ACCESS_URL=http://${lan_ip}:3001"
  else
    echo "warning: could not detect a LAN IP; edit CODER_ACCESS_URL in .env"
  fi
fi

if [ ! -e /dev/dri ]; then
  echo "warning: /dev/dri not found — the IPEX-LLM Ollama service needs the Arc 140T (EVO-T1 hardware)."
fi

echo
echo "Next steps:"
echo "  1. docker compose up -d"
echo "  2. Open http://<host>:3001 and sign in (admin user from .env;"
echo "     if admin-bootstrap did not apply, create the admin on the first-run screen)"
echo "  3. coder login http://<host>:3001 && coder template push ./templates/docker-dev"
echo "  4. ./scripts/pull-models.sh   # pulls the OLLAMA_MODELS listed in .env"
echo "  5. Kasm first boot: http://<host>:3000 (wizard), then http://<host>:4443 (UI)"
