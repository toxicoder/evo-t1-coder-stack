#!/usr/bin/env bash
#
# ## pull-models.sh — pull OLLAMA_MODELS into the IPEX-LLM container
#
# Pull the Ollama models listed in OLLAMA_MODELS (.env) into the IPEX-LLM
# container. First run is a large download (~35 GB for the default set).
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

OLLAMA_MODELS="${OLLAMA_MODELS:-qwen2.5-coder:32b qwen2.5-coder:14b}"

# Ask compose, not the daemon: this stays scoped to this stack without hand-
# rolling label filters. A container stuck in a restart loop reports as
# anything other than running, so it fails here with a pointer to the logs.
if ! running="$(docker compose ps --status running --services 2>&1)"; then
  echo "error: could not query the stack: ${running}" >&2
  echo "       this script needs docker access — run it with sudo, or add your user to the docker group" >&2
  exit 1
fi
if ! grep -qx ollama <<<"${running}"; then
  echo "error: the ollama service is not running (start the stack with: docker compose up -d)" >&2
  echo "       if it is in a restart loop, check: docker compose logs --tail 100 ollama" >&2
  exit 1
fi

for model in ${OLLAMA_MODELS}; do
  echo "pulling ${model} ..."
  docker compose exec -T ollama bash -lc "cd /llm/ollama && ./ollama pull '${model}'"
done

echo
echo "Models available on the IPEX-LLM Ollama service:"
docker compose exec -T ollama bash -lc "cd /llm/ollama && ./ollama list"
