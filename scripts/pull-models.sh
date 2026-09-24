#!/usr/bin/env bash
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

if [ -z "$(docker ps -q --filter 'com.docker.compose.service=ollama')" ]; then
  echo "error: the ollama service is not running (start the stack with: docker compose up -d)" >&2
  exit 1
fi

for model in ${OLLAMA_MODELS}; do
  echo "pulling ${model} ..."
  docker compose exec -T ollama bash -lc "cd /llm/ollama && ./ollama pull '${model}'"
done

echo
echo "Models available on the IPEX-LLM Ollama service:"
docker compose exec -T ollama bash -lc "cd /llm/ollama && ./ollama list"
