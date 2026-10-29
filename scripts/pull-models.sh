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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE
# shellcheck source=lib/coder_api.sh disable=SC1091
source "${SELF_DIR}/lib/coder_api.sh"

# OLLAMA_MODELS is read from the checkout's .env, so the checkout has to be
# resolved first: under `bazelisk run` the script's own directory is the runfiles
# tree, which has no .env, and a silent fall back to the default model list would
# pull models nobody asked for.
ROOT_DIR="$(resolve_checkout "${SELF_DIR}")" || exit 5
cd "${ROOT_DIR}"

# Read .env with the reader in scripts/lib/common.sh rather than sourcing it:
# that file is operator-editable and a sourced `.` parses it as shell. An
# unquoted OLLAMA_MODELS=qwen2.5-coder:32b qwen2.5-coder:14b is then a variable
# prefix followed by a COMMAND, so the run died on `qwen2.5-coder:14b: command
# not found` under set -e before the first pull, and any other stray line in the
# file would have executed with this script's privileges. Only this one key is
# read, so no other value in the file (a master key, say) is exported into the
# docker execs below. The file beats the caller's environment, which beats the
# shipped pair; an empty or absent line falls through rather than pulling nothing.
env_models="$(env_get .env OLLAMA_MODELS)"
OLLAMA_MODELS="${env_models:-${OLLAMA_MODELS:-qwen2.5-coder:32b qwen2.5-coder:14b}}"

# Each tag is data, never shell: it is interpolated into the in-container command
# line below, so anything outside an Ollama tag's own charset (registry
# namespaces carry /, a tag may carry : and @) is refused here rather than handed
# to bash on the other side of docker exec. The whole list is checked before the
# first pull so a typo on the fourth tag does not surface after the first three
# have downloaded tens of gigabytes.
for model in ${OLLAMA_MODELS}; do
  [[ ${model} =~ ^[A-Za-z0-9._:@/-]+$ ]] ||
    die "$(printf 'not an Ollama model tag: %s (check OLLAMA_MODELS in .env)' "${model}")"
done

# The ollama container is found on the DAEMON, by container label, not through
# a cwd-resolved compose project (scripts/lib/coder_api.sh: under `bazelisk
# run` the cwd resolves to a project that never had a stack, which read every
# live stack as "not running"). A container stuck in a restart loop is not
# listed as running, so it fails here with a pointer to the logs.
if ! running="$(stack_ps)"; then
  die "$(printf 'could not query the stack: %s\n       this script needs docker access — run it with sudo, or add your user to the docker group' "${running}")"
fi
OLLAMA_CONTAINER="$(stack_container "${running}" ollama)"
if [ -z "${OLLAMA_CONTAINER}" ]; then
  die "$(printf 'the ollama service is not running (start the stack with: bazelisk run //scripts:prod-stack -- up)\n       if it is in a restart loop, check: bazelisk run //scripts:prod-stack -- logs --tail 100 ollama')"
fi

section "Models"
# DOCKER_BIN stays unquoted so a "sudo docker" override still works, and each
# exec runs without a TTY with stdin at EOF — the role `docker compose exec -T`
# used to play. No timeout caps the pull: a first run is tens of gigabytes and
# would fail on the clock before it failed on the network.
for model in ${OLLAMA_MODELS}; do
  phase "pull ${model}"
  log "pulling ${model} ..."
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  ${DOCKER_BIN} exec -i "${OLLAMA_CONTAINER}" bash -lc "cd /llm/ollama && ./ollama pull '${model}'" </dev/null
done

log ""
log "Models available on the IPEX-LLM Ollama service:"
# shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
${DOCKER_BIN} exec -i "${OLLAMA_CONTAINER}" bash -lc "cd /llm/ollama && ./ollama list" </dev/null
summary
