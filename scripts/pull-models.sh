#!/usr/bin/env bash
#
# ## pull-models.sh — pull OLLAMA_MODELS into the IPEX-LLM container
#
# Pull the Ollama models listed in OLLAMA_MODELS (.env) into the IPEX-LLM
# container. First run is a large download (~35 GB for the default set).
#
# Usage:
#   bazelisk run //scripts:pull-models
#   OLLAMA_MODELS='qwen2.5:7b' bazelisk run //scripts:pull-models
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=lib/coder_api.sh disable=SC1091
source "scripts/lib/coder_api.sh"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

OLLAMA_MODELS="${OLLAMA_MODELS:-qwen2.5-coder:32b qwen2.5-coder:14b}"

# The ollama container is found on the DAEMON, by container label, not through
# a cwd-resolved compose project (scripts/lib/coder_api.sh: under `bazelisk
# run` the cwd resolves to a project that never had a stack, which read every
# live stack as "not running"). A container stuck in a restart loop is not
# listed as running, so it fails here with a pointer to the logs.
if ! running="$(stack_ps)"; then
  echo "error: could not query the stack: ${running}" >&2
  echo "       this script needs docker access — run it with sudo, or add your user to the docker group" >&2
  exit 1
fi
OLLAMA_CONTAINER="$(stack_container "${running}" ollama)"
if [ -z "${OLLAMA_CONTAINER}" ]; then
  echo "error: the ollama service is not running (start the stack with: bazelisk run //scripts:prod-stack -- up)" >&2
  echo "       if it is in a restart loop, check: bazelisk run //scripts:prod-stack -- logs --tail 100 ollama" >&2
  exit 1
fi

# DOCKER_BIN stays unquoted so a "sudo docker" override still works, and each
# exec runs without a TTY with stdin at EOF — the role `docker compose exec -T`
# used to play. No timeout caps the pull: a first run is tens of gigabytes and
# would fail on the clock before it failed on the network.
for model in ${OLLAMA_MODELS}; do
  echo "pulling ${model} ..."
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  ${DOCKER_BIN} exec -i "${OLLAMA_CONTAINER}" bash -lc "cd /llm/ollama && ./ollama pull '${model}'" </dev/null
done

echo
echo "Models available on the IPEX-LLM Ollama service:"
# shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
${DOCKER_BIN} exec -i "${OLLAMA_CONTAINER}" bash -lc "cd /llm/ollama && ./ollama list" </dev/null
