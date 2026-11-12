#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## hermes-config.bats — guardrails for the Hermes host-assistant seed.
#
# Pins the seams the host-assistant feature rests on: approvals stay manual,
# the terminal backend stays local (so dangerous-command checks stay on),
# models go through LiteLLM's `agent` alias, the Arc's own Ollama models ship as
# opt-in `providers:` entries reached through the same door with no key byte in
# the seed, the git-tracked skills exist
# beside the seed with matching frontmatter, SOUL.md teaches both doors,
# compose interpolation defaults for dashboard
# basic-auth stay non-empty (v0.22.5 refuses 0.0.0.0 with no provider),
# HERMES_DASHBOARD_PUBLIC_URL comes from STACK_HERMES_URL, the seed trusts
# the router subnet, the web lane stays on the stack's own SearXNG with both
# keyless switches off, and proxy/router.conf vhosts the public hermes name.
# The anywhere door is pinned too: the gateway's API server ships disabled, keyed
# from a bootstrap-generated secret and published on loopback, no half-configured
# messaging platform rides compose env, and the phone doors are written down in
# docs/hermes.md.
# The live volume copy is out of scope; this suite reads the checkout
# payload, docker-compose.yml, .env.sample, docs/hermes.md and proxy/router.conf
# only.
#
# Usage: bazelisk test //tests:bats_hermes_config_test   (from any cwd)
# Safety: reads hermes/, docker-compose.yml, .env.sample, docs/hermes.md,
# scripts/bootstrap.sh and proxy/router.conf; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CONFIG=""
SOUL=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CONFIG="${REPO_ROOT}/hermes/config.yaml"
  SOUL="${REPO_ROOT}/hermes/SOUL.md"
  [[ -f "${CONFIG}" ]] || skip "hermes/config.yaml is not reachable from ${REPO_ROOT}"
}

@test "hermes config: approvals stay manual and cron/unattended stay deny" {
  assert_contains_file "manual mode" "${CONFIG}" 'mode: manual'
  assert_contains_file "cron deny" "${CONFIG}" 'cron_mode: deny'
  assert_contains_file "unattended deny" "${CONFIG}" 'unattended_mode: deny'
  run grep -E '^[[:space:]]*mode:[[:space:]]*off' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "hermes config: terminal backend stays local" {
  assert_contains_file "local backend" "${CONFIG}" 'backend: local'
  run grep -E '^[[:space:]]*backend:[[:space:]]*docker' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "hermes config: models go through LiteLLM agent alias" {
  assert_contains_file "custom provider" "${CONFIG}" 'provider: custom'
  assert_contains_file "agent alias" "${CONFIG}" 'model: agent'
  assert_contains_file "litellm base_url" "${CONFIG}" 'base_url: http://litellm:4000/v1'
  assert_contains_file "env-expanded key" "${CONFIG}" 'api_key: \$\{LITELLM_MASTER_KEY\}'
}

# The Arc's own Ollama weights are the only models this stack runs on its own
# hardware, so they ship as opt-in providers: inert until selected, which keeps
# `agent` the default, and reached through LiteLLM because the proxy is the only
# model transport here and 11434 is deliberately unpublished.
@test "hermes config: the Arc Ollama models ship as optional providers" {
  assert_contains_file "providers block" "${CONFIG}" 'providers:'
  assert_contains_file "tool-capable local lane" "${CONFIG}" 'arc-chat:'
  assert_contains_file "coder lane" "${CONFIG}" 'arc-coder:'
  assert_contains_file "coder-fast lane" "${CONFIG}" 'arc-coder-fast:'
  assert_contains_file "chat alias travels" "${CONFIG}" 'default_model: chat'
  assert_contains_file "coder alias travels" "${CONFIG}" 'default_model: coder'
  assert_contains_file "coder-fast alias travels" "${CONFIG}" 'default_model: coder-fast'
  # One entry per Arc alias, each with its own credential line: model plus three.
  run grep -E '^[[:space:]]*api_key:' "${CONFIG}"
  [ "${#lines[@]}" -eq 4 ]
  # And no credential byte anywhere: every one is an ${...} env ref.
  run grep -E '^[[:space:]]*api_key:[[:space:]]*[^[:space:]$]' "${CONFIG}"
  [ "${status}" -ne 0 ]
  # Local means the LiteLLM door, never the unpublished Ollama port.
  run grep -E 'base_url:[[:space:]]*http://ollama' "${CONFIG}"
  [ "${status}" -ne 0 ]
  # Opt-in: selecting a provider is what changes the model, never the seed.
  assert_contains_file "default stays the Spark lane" "${CONFIG}" 'model: agent'
}

@test "hermes docs: the local providers and how to select one are written down" {
  local doc="${REPO_ROOT}/docs/hermes.md"
  assert_file_exists "hermes doc" "${doc}"
  assert_contains_file "names the local lane" "${doc}" 'arc-chat'
  assert_contains_file "shows the one-shot switch" "${doc}" 'hermes --provider arc-chat'
  assert_contains_file "shows the durable switch" "${doc}" 'hermes config set model.provider arc-chat'
}

@test "hermes config: cwd follows STACK_HOST_PATH and skills stay external" {
  assert_contains_file "cwd from env" "${CONFIG}" 'cwd: \$\{STACK_HOST_PATH\}'
  assert_contains_file "skills mount" "${CONFIG}" '/opt/stack-skills'
}

@test "hermes config: stack marker and SOUL.md are present" {
  assert_contains_file "config marker" "${CONFIG}" 'managed-by: evo-t1-coder-stack'
  assert_file_exists "SOUL.md" "${SOUL}"
  assert_contains_file "SOUL marker" "${SOUL}" 'managed-by: evo-t1-coder-stack'
}

@test "hermes skills: every tracked skill exists with matching frontmatter" {
  # The four stack skills (the fourth being the coding-agent door, which is what
  # makes the assistant worth opening from a phone), the three host-operations
  # skills that make the assistant useful from a terminal (the mentor voice, the
  # triage playbooks, and the GitHub-to-running path), and the web lane.
  # `description` is pinned
  # beside `name` because it is the line the loader shows an agent when it
  # decides whether to open the skill at all - a skill with no description is
  # invisible in exactly the moment it would have been used.
  local skill path
  for skill in evo-stack-ops coder-workspace coding-agents model-routing \
    host-linux-ops host-diagnostics deploy-from-github web-research; do
    path="${REPO_ROOT}/hermes/skills/${skill}/SKILL.md"
    assert_file_exists "${skill}" "${path}"
    assert_contains_file "${skill} frontmatter name" "${path}" "^name: ${skill}\$"
    assert_contains_file "${skill} frontmatter description" "${path}" \
      '^description: [^[:space:]]'
  done
}

@test "hermes SOUL: names both doors, the deploy workspace, and the manual gate" {
  assert_contains_file "terminal door" "${SOUL}" 'scripts:hermes-shell'
  assert_contains_file "dashboard door" "${SOUL}" '9119'
  assert_contains_file "deploy workspace" "${SOUL}" 'STACK_DEPLOY_PATH'
  assert_contains_file "manual approvals stay" "${SOUL}" 'approvals\.mode. is .manual'
  assert_contains_file "one writer on /opt/data" "${SOUL}" 'second container'
}

@test "hermes compose: dashboard basic-auth interpolation defaults stay non-empty" {
  # An empty `${HERMES_DASHBOARD_PASSWORD:-}` interpolates to "" when .env
  # lacks the key; the bundled plugin then skips registration and the
  # gateway crash-loops on 0.0.0.0. Defaults must match .env.sample.
  local compose="${REPO_ROOT}/docker-compose.yml"
  local sample="${REPO_ROOT}/.env.sample"
  assert_file_exists "compose file" "${compose}"
  assert_file_exists "env sample" "${sample}"
  assert_contains_file "username fallback" "${compose}" \
    'HERMES_DASHBOARD_BASIC_AUTH_USERNAME: \$\{HERMES_DASHBOARD_USER:-admin\}'
  assert_contains_file "password fallback" "${compose}" \
    'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD: \$\{HERMES_DASHBOARD_PASSWORD:-change-me-hermes\}'
  assert_contains_file "secret fallback" "${compose}" \
    'HERMES_DASHBOARD_BASIC_AUTH_SECRET: \$\{HERMES_DASHBOARD_SECRET:-change-me-hermes-secret\}'
  assert_contains_file "sample password" "${sample}" \
    '^HERMES_DASHBOARD_PASSWORD=change-me-hermes$'
  assert_contains_file "sample secret" "${sample}" \
    '^HERMES_DASHBOARD_SECRET=change-me-hermes-secret$'
}

@test "hermes compose: public URL comes from STACK_HERMES_URL" {
  local compose="${REPO_ROOT}/docker-compose.yml"
  assert_file_exists "compose file" "${compose}"
  assert_contains_file "public url env" "${compose}" \
    'HERMES_DASHBOARD_PUBLIC_URL: \$\{STACK_HERMES_URL:-\}'
}

@test "hermes compose: the working directory arrives resolved" {
  # Hermes validates terminal.cwd with expanduser() alone, so neither copy of
  # the path may still be a token by the time the gateway reads it. Compose
  # interpolation is what resolves this one, from the same key the
  # identical-path mount uses; the seeded config.yaml carries the literal
  # hermes-bootstrap renders. A leftover ${VAR} here is the bug that made the
  # assistant work outside the checkout while every check read healthy.
  local compose="${REPO_ROOT}/docker-compose.yml"
  assert_file_exists "compose file" "${compose}"
  assert_contains_file "terminal cwd from the checkout key" "${compose}" \
    'TERMINAL_CWD: \$\{STACK_HOST_PATH:-/opt/stack\}'
  run grep -E '^[[:space:]]*TERMINAL_CWD:[[:space:]]*\$\{[A-Z_]+\}$' "${compose}"
  [ "${status}" -ne 0 ]
}

@test "hermes config: web search stays on the box" {
  # The whole point of the lane: agent/web_search_registry.py ends its
  # resolution walk at an anonymous free-tier ring (exa, parallel, firecrawl,
  # keenable), so a seed that names no backend and leaves the keyless switches
  # at their shipped defaults sends "local-only" searches to a third party.
  # searxng is the one bundled provider that needs no key, and the only one
  # whose endpoint is this stack's own container.
  assert_contains_file "search pinned to the local instance" "${CONFIG}" \
    'search_backend: searxng'
  assert_contains_file "keyless ring off" "${CONFIG}" 'keyless_fallback: false'
  assert_contains_file "keyless rescue off" "${CONFIG}" 'keyless_rescue: false'

  # No third-party backend may be configured, by any of the three keys the
  # registry reads.
  run grep -E '^[[:space:]]*(backend|search_backend|extract_backend):[[:space:]]*(tavily|firecrawl|brave-free|exa|parallel|perplexity|keenable|ddgs|openai-native|xai)' "${CONFIG}"
  [ "${status}" -ne 0 ]
  # And no vendor credential: the assistant holds one key, LITELLM_MASTER_KEY.
  run grep -E 'TAVILY_API_KEY|FIRECRAWL_API_KEY|BRAVE_SEARCH_API_KEY|EXA_API_KEY|PARALLEL_API_KEY|KEENABLE_API_KEY|PERPLEXITY_API_KEY' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "hermes config: page extraction fails closed on the box" {
  # searxng is search-only. Naming it for extract would be a lie the dispatcher
  # surfaces as an unavailable-provider error, and naming nothing leaves
  # web_extract failing with "no extract provider configured" - which is the
  # shape this seed wants: an operator who wants page fetches sets the key
  # deliberately, and nothing reaches a third-party extractor by default.
  run grep -E '^[[:space:]]*extract_backend:' "${CONFIG}"
  [ "${status}" -ne 0 ]
  run grep -E '^[[:space:]]*backend:[[:space:]]*searxng' "${CONFIG}"
  [ "${status}" -ne 0 ]
}

@test "hermes compose: the search lane dials the stack's own SearXNG" {
  # The variable's presence is what registers the bundled provider, so the
  # default has to name the compose service. An internal URL means no new
  # published port: the container reaches searxng by service name.
  local compose="${REPO_ROOT}/docker-compose.yml"
  local sample="${REPO_ROOT}/.env.sample"
  assert_contains_file "search url" "${compose}" \
    'SEARXNG_URL: \$\{STACK_HERMES_SEARCH_URL:-http://searxng:8181\}'
  assert_contains_file "the key the operator can set" "${sample}" \
    '^STACK_HERMES_SEARCH_URL=$'
}

@test "hermes config: dashboard trusts the router subnet" {
  assert_contains_file "trusted proxies" "${CONFIG}" \
    'trusted_proxies: \["172\.16\.0\.0/12"\]'
}

@test "hermes router: public vhost proxies the dashboard" {
  local router="${REPO_ROOT}/proxy/router.conf"
  assert_file_exists "router conf" "${router}"
  assert_contains_file "hermes server name" "${router}" \
    'server_name hermes-gmktecbeast\.overeazy\.io'
  assert_contains_file "hermes upstream" "${router}" \
    'http://hermes:9119'
  assert_contains_file "forwarded host" "${router}" \
    'proxy_set_header X-Forwarded-Host'
}

# --- the anywhere door ------------------------------------------------------

@test "hermes compose: the API server ships off, keyed, and bound to loopback" {
  # This server adds /v1/chat/completions and /v1/runs onto a container that
  # mounts the docker socket, with a bearer key as its only gate. Every default
  # below has to be the closed one, and closed has to be spelled out: upstream
  # documents API_SERVER_ENABLED as true/false, so an unset value is an operator
  # guessing at the default instead of reading it.
  local compose="${REPO_ROOT}/docker-compose.yml"
  local sample="${REPO_ROOT}/.env.sample"
  assert_contains_file "server off by default" "${compose}" \
    'API_SERVER_ENABLED: \$\{HERMES_API_SERVER_ENABLED:-false\}'
  assert_contains_file "key comes from the sample key" "${compose}" \
    'API_SERVER_KEY: \$\{HERMES_API_SERVER_KEY:-\}'
  assert_contains_file "container port is the documented one" "${compose}" \
    'API_SERVER_PORT: "8642"'
  assert_contains_file "the published mapping defaults to loopback" "${compose}" \
    '"\$\{HERMES_API_BIND:-127\.0\.0\.1\}:\$\{HERMES_API_PORT:-8642\}:8642"'
  assert_contains_file "sample ships the flag off" "${sample}" \
    '^HERMES_API_SERVER_ENABLED=false$'
  assert_contains_file "sample ships a placeholder key" "${sample}" \
    '^HERMES_API_SERVER_KEY=change-me-hermes-api$'
  assert_contains_file "sample binds loopback" "${sample}" \
    '^HERMES_API_BIND=127\.0\.0\.1$'
  # bootstrap only replaces change-me-* for the keys on its two lists. A key left
  # off them ships a well-known secret, and an enabled server then authenticates
  # to nothing. Both lists (the --check probe and the generator) have to carry it.
  local listed
  listed="$(grep -c 'HERMES_DASHBOARD_SECRET HERMES_API_SERVER_KEY' \
    "${REPO_ROOT}/scripts/bootstrap.sh")"
  [ "${listed}" -eq 2 ] \
    || { printf 'FAIL: bootstrap generates the api key on %s of its 2 secret lists\n' "${listed}" >&2; return 1; }
}

@test "hermes compose: no half-configured messaging platform rides compose env" {
  # The gateway registers the ntfy adapter from the presence of NTFY_TOPIC in its
  # environment, so an empty NTFY_TOPIC= line handed it a platform with no topic -
  # and a token in a container env is readable through `docker inspect`. Both
  # belong in the assistant's own /opt/data/.env on the data volume.
  local sample="${REPO_ROOT}/.env.sample"
  local compose="${REPO_ROOT}/docker-compose.yml"
  run grep -E '^[[:space:]]*#?[[:space:]]*NTFY_[A-Z_]+=' "${sample}"
  [ "${status}" -ne 0 ]
  run grep -E '^[[:space:]]*(NTFY|TELEGRAM)_[A-Z_]+:' "${compose}"
  [ "${status}" -ne 0 ]
}

@test "hermes docs: the phone doors and their opt-ins are written down" {
  # An operator on a phone reads this file, not the compose comments. A door that
  # exists in compose but not here is a door nobody finds, and a door documented
  # without its off-switch is how the API server gets enabled by accident.
  local doc="${REPO_ROOT}/docs/hermes.md"
  assert_file_exists "hermes doc" "${doc}"
  assert_contains_file "the API server door" "${doc}" 'HERMES_API_SERVER_ENABLED=true'
  assert_contains_file "the push door" "${doc}" 'NTFY_PUBLISH_TOPIC'
  assert_contains_file "the push-only posture" "${doc}" 'NTFY_ALLOWED_USERS. unset and the channel'
  assert_contains_file "the agent verbs from a phone" "${doc}" 'coder-sessions -- list'
}
