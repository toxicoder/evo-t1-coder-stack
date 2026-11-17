#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## hermes-config.bats — guardrails for the Hermes host-assistant seed.
#
# Pins the seams the host-assistant feature rests on: approvals stay manual,
# the terminal backend stays local (so dangerous-command checks stay on),
# models go through LiteLLM's `agent` alias, every alias the proxy serves is declared
# exactly once as a pickable Hermes model option (derived from litellm/config.yaml,
# with the summariser lane held out of the picker and the row that pins discovery kept
# first), the Arc's own Ollama models ship as named
# `providers:` entries reached through the same door with no key byte
# in the seed, the git-tracked skills exist
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
# Safety: reads hermes/, litellm/config.yaml, docker-compose.yml, .env.sample,
# docs/hermes.md, scripts/bootstrap.sh and proxy/router.conf; writes nothing.

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

# Distinct `model_name:` values the proxy actually serves. The deployment entries are
# the `- model_name:` list items, so the anchor excludes the two prose mentions of
# the word inside litellm/config.yaml's comments.
litellm_served_aliases() {
  grep -E '^[[:space:]]*-[[:space:]]+model_name:' "${REPO_ROOT}/litellm/config.yaml" |
    sed -E 's/^[[:space:]]*-[[:space:]]+model_name:[[:space:]]*//; s/[[:space:]]*$//' |
    sort -u
}

# How many rows the providers: block declares - the two-space keys between
# `providers:` and the next top-level key. Derived, so adding a row is not a test
# edit and dropping a row's credential is.
hermes_provider_rows() {
  awk '
    /^providers:[[:space:]]*$/            { in_prov = 1; next }
    in_prov && /^[^[:space:]#]/           { in_prov = 0 }
    in_prov && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { n++ }
    END                                   { print n + 0 }
  ' "${CONFIG}"
}

# Every pickable model id the seed declares, as `alias<TAB>row` lines. Hermes matches a
# typed `/model <alias>` against each row's `models`, `model` AND `default_model`
# (hermes_cli/model_switch.py:_configured_provider_matches), so an Arc row declares its
# alias with the one `default_model` key and the catalogue row declares its ids under
# `models:`. Read positionally rather than through a YAML parser so the gate keeps
# working in a bare bats sandbox, and so it proves the shape the loader expects
# (two-space row, four-space keys, six-space model ids).
hermes_alias_rows() {
  awk '
    /^providers:[[:space:]]*$/                { in_prov = 1; next }
    in_prov && /^[^[:space:]#]/               { in_prov = 0 }
    in_prov && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      row = $0; sub(/^  /, "", row); sub(/:.*$/, "", row); in_models = 0; next
    }
    in_prov && row != "" && /^    default_model:/ {
      v = $0; sub(/^    default_model:[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v)
      if (v != "") print v "\t" row
      next
    }
    in_prov && /^    models:[[:space:]]*$/    { in_models = 1; next }
    in_prov && in_models && /^      [A-Za-z0-9._-]+:[[:space:]]*\{\}[[:space:]]*$/ {
      v = $0; sub(/^      /, "", v); sub(/:.*$/, "", v); print v "\t" row; next
    }
    in_prov && in_models && !/^      /        { in_models = 0 }
  ' "${CONFIG}"
}

# Everything a session can type. This set, not the catalogue row alone, is the one
# that has to equal what LiteLLM serves. A row listing its own `default_model` in its
# `models:` too is one declarer, so the pair list is deduplicated before the alias
# column is.
hermes_declared_aliases() {
  hermes_alias_rows | cut -f1 | sort -u
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

# The Arc's own Ollama weights ship as named routes beside the catalogue, and every
# alias the proxy serves has to be declared as a Hermes model option or the assistant
# cannot pick it. The expected set is derived from litellm/config.yaml, so a new
# alias fails this gate rather than going unnoticed.
@test "hermes config: the Arc Ollama models ship as named providers" {
  assert_contains_file "providers block" "${CONFIG}" 'providers:'
  assert_contains_file "tool-capable local lane" "${CONFIG}" 'arc-chat:'
  assert_contains_file "coder lane" "${CONFIG}" 'arc-coder:'
  assert_contains_file "coder-fast lane" "${CONFIG}" 'arc-coder-fast:'
  assert_contains_file "chat alias travels" "${CONFIG}" 'default_model: chat'
  assert_contains_file "coder alias travels" "${CONFIG}" 'default_model: coder'
  assert_contains_file "coder-fast alias travels" "${CONFIG}" 'default_model: coder-fast'
  # One credential line per row: the model block plus every providers: entry, and
  # the count is derived from the file rather than pinned to a literal so a new row
  # is not a test edit.
  local rows keys
  rows="$(hermes_provider_rows)"
  keys="$(grep -Ec '^[[:space:]]*api_key:' "${CONFIG}" || true)"
  [ "${keys}" -eq $((rows + 1)) ] ||
    { printf 'FAIL: %d api_key lines for %d provider rows (want rows + the model block)\n' \
        "${keys}" "${rows}" >&2; return 1; }
  # And no credential byte anywhere: every one is an ${...} env ref.
  run grep -E '^[[:space:]]*api_key:[[:space:]]*[^[:space:]$]' "${CONFIG}"
  [ "${status}" -ne 0 ]
  # Local means the LiteLLM door, never the unpublished Ollama port.
  run grep -E 'base_url:[[:space:]]*http://ollama' "${CONFIG}"
  [ "${status}" -ne 0 ]
  # Opt-in: a row is inert until something names it, so a plain `hermes` run still
  # takes the Spark lane. (Naming a row with --provider does move its default_model
  # along with the route; hermes_cli/cli_init_mixin.py:263.)
  assert_contains_file "default stays the Spark lane" "${CONFIG}" 'model: agent'
}

# Hermes routes a typed `/model <alias>` (and `--model <alias>`) to the provider row
# that *declares* that id: hermes_cli/model_switch.py matches the typed name against
# each entry's `models` / `model` / `default_model`, exactly, and a name no row
# declares is left on the current provider as an unknown hidden model. So the seed's
# declarations, not LiteLLM, are what make an alias a choice the assistant offers -
# and a LiteLLM alias missing from them is a lane nobody can run Hermes on. Measured
# against nousresearch/hermes-agent:v0.22.5.
@test "hermes config: every LiteLLM alias is a declared Hermes model option" {
  local served declared alias
  served="$(litellm_served_aliases)"
  [ -n "${served}" ] ||
    { printf 'FAIL: parsed no aliases out of litellm/config.yaml\n' >&2; return 1; }
  declared="$(hermes_declared_aliases)"
  [ -n "${declared}" ] ||
    { printf 'FAIL: hermes/config.yaml declares no pickable model at all\n' >&2; return 1; }

  local missing=()
  while IFS= read -r alias; do
    # The summariser is the one served alias a session must not be able to pick.
    [[ "${alias}" == "compaction-fast" ]] && continue
    printf '%s\n' "${declared}" | grep -Fxq -- "${alias}" || missing+=("${alias}")
  done <<< "${served}"
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'FAIL: LiteLLM aliases no Hermes row declares: %s\n' "${missing[*]}" >&2
    return 1
  fi

  # And nothing declared is a name the proxy does not serve: a typo or a retired
  # alias would show as a pickable model that 400s on every turn.
  local stale=()
  while IFS= read -r alias; do
    printf '%s\n' "${served}" | grep -Fxq -- "${alias}" || stale+=("${alias}")
  done <<< "${declared}"
  if [ "${#stale[@]}" -gt 0 ]; then
    printf 'FAIL: Hermes declares aliases LiteLLM does not serve: %s\n' "${stale[*]}" >&2
    return 1
  fi
}

# One alias on two rows is not a harmless duplicate. `_route_configured_provider`
# collects every row that declares the typed name and, when the session is not already
# on one of them, refuses the switch outright with "declared by multiple configured
# providers" (hermes_cli/model_switch.py:1338). Measured on v0.22.5: with `chat` in the
# catalogue row's `models:` as well as in arc-chat's `default_model`, a fresh session's
# `/model chat` fails, where it routed fine before the catalogue row existed. So each
# alias is declared in exactly one place.
@test "hermes config: no alias is declared by two provider rows" {
  local dupes
  dupes="$(hermes_alias_rows | sort -u | cut -f1 | uniq -d)"
  [ -z "${dupes}" ] ||
    { printf 'FAIL: alias declared by more than one row, so /model refuses it: %s\n' \
        "$(printf '%s' "${dupes}" | tr '\n' ' ')" >&2; return 1; }
}

# The four rows share one endpoint, credential and wire protocol, so Hermes folds them
# into a single picker group and reads `discover_models` from the group's first member
# alone (hermes_cli/model_switch_providers.py:1010-1018). Measured: litellm first
# answers discovery_allowed=False, arc-chat first answers True - and a group with
# discovery on adopts `compaction-fast` off /v1/models. So the row that carries the
# pin has to stay first, not merely be present somewhere in the block.
@test "hermes config: the row that pins discovery stays first" {
  local first
  first="$(awk '
    /^providers:[[:space:]]*$/                { in_prov = 1; next }
    in_prov && /^[^[:space:]#]/               { in_prov = 0 }
    in_prov && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      sub(/^  /, ""); sub(/:.*$/, ""); print; exit
    }
  ' "${CONFIG}")"
  [ "${first}" = "litellm" ] ||
    { printf 'FAIL: first providers: row is %s; the fold takes discover_models from it\n' \
        "${first:-<none>}" >&2; return 1; }
  awk '
    /^  litellm:[[:space:]]*$/          { in_row = 1; next }
    in_row && /^  [A-Za-z0-9._-]+:/     { in_row = 0 }
    in_row && /^    discover_models:[[:space:]]*false[[:space:]]*$/ { found = 1 }
    END                                 { exit found ? 0 : 1 }
  ' "${CONFIG}" ||
    { printf 'FAIL: the litellm row lost its own discover_models: false\n' >&2; return 1; }
}

# `compaction-fast` is the Arc group the two `-fast` lanes hop to for one
# conversation summary, and litellm/compaction_router.py owns that hop. It carries no
# tool support and no reasoning effort by design, so the assistant must never be able
# to drive a session with it. Hermes' own /v1/models probe would otherwise adopt it
# (the reason the row pins discover_models: false), so the pin is pinned here too.
@test "hermes config: the summariser lane stays out of the picker" {
  # This is the only guard: the derived coverage test skips `compaction-fast` by name
  # in its missing loop, and its stale loop accepts it because the proxy really does
  # serve it. So report the offending line rather than failing on a bare status.
  local leaked
  leaked="$(grep -E '^[[:space:]]*compaction-fast:' "${CONFIG}" || true)"
  [ -z "${leaked}" ] ||
    { printf 'FAIL: compaction-fast is declared pickable: %s\n' "${leaked}" >&2; return 1; }
  assert_contains_file "no unsanctioned discovery" "${CONFIG}" 'discover_models: false'
}


@test "hermes docs: the local providers and how to select one are written down" {
  local doc="${REPO_ROOT}/docs/hermes.md"
  local readme="${REPO_ROOT}/README.md"
  assert_file_exists "hermes doc" "${doc}"
  assert_contains_file "names the local lane" "${doc}" 'arc-chat'
  assert_contains_file "shows the one-shot switch" "${doc}" 'hermes --provider arc-chat'
  assert_contains_file "shows the durable switch" "${doc}" 'hermes config set model.provider arc-chat'
  # The skim page is the one an operator actually reads, so its verb is pinned too:
  # `model.model` prints a success line and changes nothing once a persisted /model
  # has written `default:`, which is why the seed and the docs name `model.default`.
  assert_file_exists "readme" "${readme}"
  assert_contains_file "readme durable model verb" "${readme}" \
    'hermes config set model.default'
  run grep -E 'config set model\.model' "${readme}"
  [ "${status}" -ne 0 ] ||
    { printf 'FAIL: README recommends the legacy model.model verb\n' >&2; return 1; }
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
  # bootstrap only replaces change-me-* for the keys on its mint lists. A key left
  # off them ships a well-known secret, and an enabled server then authenticates
  # to nothing. Both lists (the --check probe and the generator) have to carry it --
  # and they are no longer two literals that can drift apart: bootstrap builds one
  # array from infisical/managed-secrets.txt through infisical_managed_keys() and both
  # loops iterate that array, so the proof is that the key is on the inventory and that
  # both loops read the inventory. A key dropped from the file now fails here instead
  # of silently shipping a placeholder.
  grep -Fq 'infisical_managed_keys' "${REPO_ROOT}/scripts/bootstrap.sh" ||
    { printf 'FAIL: bootstrap no longer mints from the managed-key inventory\n' >&2; return 1; }
  [ "$(grep -cF '"${mint_keys[@]}"' "${REPO_ROOT}/scripts/bootstrap.sh")" -eq 2 ] ||
    { printf 'FAIL: bootstrap does not drive both its check probe and its generator from one array\n' >&2; return 1; }
  local minted
  for minted in HERMES_DASHBOARD_SECRET HERMES_API_SERVER_KEY; do
    grep -Fxq "${minted}" "${REPO_ROOT}/infisical/managed-secrets.txt" ||
      { printf 'FAIL: %s is off the managed-key inventory bootstrap mints from\n' "${minted}" >&2; return 1; }
  done
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
