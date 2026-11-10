#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## hermes-skills.bats - pin what the Hermes skills *tell the assistant to do*.
#
# hermes-config.bats guards the seed (file exists, frontmatter name matches). It
# cannot see a claim, so a skill that tells the host assistant to run
# `--flag=<nobody-parses-it>`, dial a port compose never published, or name a
# service that does not exist still passes that gate - and the assistant obeys
# the doc, not the tree. This suite reads the skill text as the source of the
# claim and the payload as the truth: compose service names, each stack CLI's own
# argument parser, published ports and container listeners, the read-only mounts,
# and litellm/config.yaml's model_name values and router_settings.
#
# Hermetic: reads files under REPO_ROOT only - no network, no docker, no live
# container. YAML parsing is optional the way the other suites treat PyYAML: skip.
#
# Usage: bazelisk test //tests:bats_hermes_skills_test   (from any cwd)
# Safety: reads hermes/skills/, docker-compose.yml, litellm/config.yaml,
#         searxng/settings.yml and scripts/*.sh; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SKILLS=""
COMPOSE=""
LITELLM_CFG=""
SEARXNG_CFG=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SKILLS="${REPO_ROOT}/hermes/skills"
  COMPOSE="${REPO_ROOT}/docker-compose.yml"
  LITELLM_CFG="${REPO_ROOT}/litellm/config.yaml"
  SEARXNG_CFG="${REPO_ROOT}/searxng/settings.yml"
  [[ -d "${SKILLS}" ]] || skip "hermes/skills is not reachable from ${REPO_ROOT}"
  [[ -f "${COMPOSE}" ]] || skip "docker-compose.yml is not reachable from ${REPO_ROOT}"
}

# --- payload readers -------------------------------------------------------

# hs_compose_services - print the top-level service names of docker-compose.yml.
hs_compose_services() {
  awk '
    /^services:/ { f = 1; next }
    f && /^[^[:space:]#]/ { exit }
    f && /^  [A-Za-z0-9_-]+:/ { name = $1; sub(/:$/, "", name); print name }
  ' "${COMPOSE}"
}

# hs_service_block <service> - print the lines of one top-level service block.
hs_service_block() {
  awk -v svc="$1" '
    /^services:/ { f = 1; next }
    f && /^[^[:space:]#]/ { exit }
    f && /^  [A-Za-z0-9_-]+:/ {
      name = $1; sub(/:$/, "", name)
      if (name == svc) { inblk = 1; next }
      if (inblk) { exit }
      next
    }
    inblk { print }
  ' "${COMPOSE}"
}

# hs_port_pairs <service> - print "host target" per published port mapping,
# resolving a `${VAR:-default}` host side down to its default. The split is on
# the LAST colon because the host side of `${CODER_HTTP_PORT:-3001}:3443`
# carries a colon of its own.
hs_port_pairs() {
  hs_service_block "$1" | awk '
    /^[[:space:]]*ports:/ { p = 1; next }
    p && /^[^[:space:]#-]/ { p = 0 }
    p && /^[[:space:]]*#/ { next }
    p && /^[[:space:]]*-[[:space:]]/ {
      line = $2; gsub(/"/, "", line)
      cut = 0
      for (i = length(line); i > 0; i--) { if (substr(line, i, 1) == ":") { cut = i; break } }
      if (cut == 0) next
      host = substr(line, 1, cut - 1); target = substr(line, cut + 1)
      sub(/^[$][{][A-Za-z_0-9]+:-/, "", host)
      sub(/[}]$/, "", host)
      print host, target
    }
  '
}

# hs_parser_flags <script> - print the long flags that script's own argument
# parser matches, taken from its case labels only (never its usage prose, which
# is documentation and can drift from the code).
hs_parser_flags() {
  grep -E '^[[:space:]]*(-[a-z][[:space:]]*\|[[:space:]]*)?--[a-z][a-z0-9-]*[[:space:]]*(=[^)]*)?\)' "$1" \
    | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u
}

# hs_skill_cli_flags - print "<stem> --flag" for every long flag a skill passes
# after `//scripts:<stem> --`, which is the argv the assistant copies verbatim.
hs_skill_cli_flags() {
  grep -rhoE '//scripts:[a-z0-9-]+ +-- [^`]*' "${SKILLS}"/*/SKILL.md \
    | awk '{
        stem = $1; sub(/^\/\/scripts:/, "", stem)
        seen = 0
        for (i = 2; i <= NF; i++) {
          tok = $i
          if (tok == "--") { seen = 1; continue }
          if (!seen || tok ~ /^#/) break
          if (tok ~ /^--[a-z][a-z0-9-]*$/) { sub(/=.*/, "", tok); print stem, tok }
        }
      }'
}

# hs_skill_cli_subcommands - print "<stem> <word>" for the first word a skill
# puts after `//scripts:<stem> --`, when that word is a subcommand and not a flag
# or a `<placeholder>`.
hs_skill_cli_subcommands() {
  grep -rhoE '//scripts:[a-z0-9-]+ +-- [^`]*' "${SKILLS}"/*/SKILL.md \
    | awk '{
        stem = $1; sub(/^\/\/scripts:/, "", stem)
        seen = 0
        for (i = 2; i <= NF; i++) {
          tok = $i
          if (tok == "--") { seen = 1; continue }
          if (!seen || tok ~ /^[-<#]/) break
          print stem, tok
          break
        }
      }'
}

# hs_script_has_subcommand <script> <sub> - the dispatch really answers to <sub>:
# either a case label, or a compared variable (hermes-shell branches on MODE, and
# update-configs on mode, instead of a case label per mode).
hs_script_has_subcommand() {
  local pattern
  # shellcheck disable=SC2016  # ${VAR} is the literal text to match in the dispatch
  pattern='[${][A-Za-z_]+[}]?"?[[:space:]]*==?[[:space:]]*"'"${2}"'"'
  grep -Eq -- "^[[:space:]]*${2}\)" "$1" || grep -Eq -- "${pattern}" "$1"
}

# --- 1. service names ------------------------------------------------------

@test "hermes skills: the compose service list evo-stack-ops names is the compose file's own set" {
  # The assistant enumerates and restarts by these names; a service the skill
  # invented sends `docker compose restart` nowhere, and a service the file
  # gained but the skill never learned stays invisible to the operator.
  local skill claimed actual missing extra
  skill="${SKILLS}/evo-stack-ops/SKILL.md"
  assert_file_exists "evo-stack-ops skill" "${skill}"
  # shellcheck disable=SC2016  # the backticks are the skill's own markup, not command substitution
  claimed="$(sed -n '/^Services:/,/\.$/p' "${skill}" | grep -oE '`[a-z0-9_-]+`' | tr -d '`' | sort -u)"
  actual="$(hs_compose_services | sort -u)"
  [[ -n ${claimed} ]] || { printf 'FAIL: no "Services:" list found in %s\n' "${skill}" >&2; return 1; }
  missing="$(comm -23 <(printf '%s\n' "${claimed}") <(printf '%s\n' "${actual}"))"
  extra="$(comm -13 <(printf '%s\n' "${claimed}") <(printf '%s\n' "${actual}"))"
  if [[ -n ${missing} || -n ${extra} ]]; then
    printf 'FAIL: service set drift vs %s\n  named by the skill but absent from compose: %s\n  in compose but not named: %s\n' \
      "${COMPOSE}" "${missing//$'\n'/ }" "${extra//$'\n'/ }" >&2
    return 1
  fi
}

# --- 2. CLI flags and subcommands -----------------------------------------

@test "hermes skills: every long flag shown after //scripts:<cli> -- is parsed by that script" {
  # These are the lines the assistant copies verbatim. A flag the parser does not
  # know is a `die "unknown option"` in front of the operator, or worse a silently
  # ignored switch on a command that then mutates something.
  local stem flag script known offenders=""
  while read -r stem flag; do
    [[ -n ${stem} && ${flag} == --* ]] || continue
    script="${REPO_ROOT}/scripts/${stem}.sh"
    if [[ ! -f ${script} ]]; then
      printf 'FAIL: skill invokes //scripts:%s but %s does not exist\n' "${stem}" "${script}" >&2
      return 1
    fi
    known="$(hs_parser_flags "${script}")"
    if ! grep -qxF -- "${flag}" <<<"${known}"; then
      offenders+="  //scripts:${stem} -- ... ${flag}"$'\n'
    fi
  done < <(hs_skill_cli_flags | sort -u)
  [[ -z ${offenders} ]] || { printf 'FAIL: flags no parser accepts:\n%s' "${offenders}" >&2; return 1; }
}

@test "hermes skills: the shared option set both stack CLIs claim is real, with the project names" {
  # evo-stack-ops promises `-p/--project-name`, `-f/--file`, `-e/--env-file` on
  # both, and says which compose project each drives. The wrong default project
  # is how a `down` meant for the dev sandbox lands on the stable stack.
  local stem script flag want
  for stem in prod-stack dev-stack; do
    script="${REPO_ROOT}/scripts/${stem}.sh"
    assert_file_exists "${stem} script" "${script}"
    for flag in --project-name --file --env-file; do
      if ! grep -qxF -- "${flag}" <<<"$(hs_parser_flags "${script}")"; then
        printf 'FAIL: %s parser has no %s, which evo-stack-ops claims both CLIs take\n' \
          "${script}" "${flag}" >&2
        return 1
      fi
    done
  done
  # shellcheck disable=SC2016  # literal backticks from the skill's prose
  assert_contains_file "both CLIs claimed" "${SKILLS}/evo-stack-ops/SKILL.md" \
    'Both take `-p/--project-name`'
  want="evo-t1-prod"
  assert_contains_file "prod-stack default project" "${REPO_ROOT}/scripts/prod-stack.sh" \
    "^PROJECT=\"${want}\"$"
  want="evo-t1-dev"
  assert_contains_file "dev-stack default project" "${REPO_ROOT}/scripts/dev-stack.sh" \
    "^PROJECT=\"${want}\"$"
}

@test "hermes skills: every subcommand they tell the assistant to run is dispatched by that CLI" {
  # `hermes-shell -- check` is the readiness report the skills lean on for every
  # triage; `update-configs -- workspace` is the re-materialize step. A word the
  # dispatcher does not know is a usage error at the moment of need.
  local stem word script offenders=""
  while read -r stem word; do
    [[ -n ${stem} && -n ${word} && ${word} != --* ]] || continue
    script="${REPO_ROOT}/scripts/${stem}.sh"
    [[ -f ${script} ]] || { printf 'FAIL: //scripts:%s has no %s\n' "${stem}" "${script}" >&2; return 1; }
    hs_script_has_subcommand "${script}" "${word}" || offenders+="  //scripts:${stem} -- ${word}"$'\n'
  done < <(hs_skill_cli_subcommands | sort -u)
  [[ -z ${offenders} ]] || { printf 'FAIL: subcommands no dispatcher answers:\n%s' "${offenders}" >&2; return 1; }
}

# --- 3. ports --------------------------------------------------------------

@test "hermes skills: the host ports they dial are published by compose on those services" {
  # model-routing sends the assistant to LiteLLM, host-diagnostics to search-check
  # and the router, and a port compose never published answers nothing while the
  # skill insists the service is up.
  local pair service host target
  for pair in "litellm 4000 4000" "searxng 8181 8181" "router 8080 8080"; do
    read -r service host target <<<"${pair}"
    if ! grep -qxF -- "${host} ${target}" <<<"$(hs_port_pairs "${service}")"; then
      printf 'FAIL: compose publishes no %s:%s -> %s for service %s; it publishes [%s]\n' \
        "${service}" "${host}" "${target}" "${service}" \
        "$(hs_port_pairs "${service}" | tr '\n' ' ')" >&2
      return 1
    fi
  done
  # The probe the skill shows needs the format SearXNG refuses without the key.
  assert_contains_file "the skill dials format=json" "${SKILLS}/model-routing/SKILL.md" \
    'http://searxng:8181/search\?.*format=json'
  assert_contains_file "settings.yml enables the json format" "${SEARXNG_CFG}" \
    '^[[:space:]]*-[[:space:]]*json[[:space:]]*$'
}

@test "hermes skills: Coder's two listeners are the ports the coder-workspace skill says" {
  # The skill routes the assistant to `http://coder:3000` over compose DNS and
  # calls the host's :3001 the TLS door. If the plain listener moved or 3001
  # stopped fronting TLS, every workspace-inspection command in that skill 404s.
  local block
  block="$(hs_service_block coder)"
  printf '%s' "${block}" | grep -Eq 'CODER_HTTP_ADDRESS: "0\.0\.0\.0:3000"' \
    || { printf 'FAIL: coder has no plain listener on container port 3000, which coder-workspace dials\n' >&2; return 1; }
  printf '%s' "${block}" | grep -Eq 'CODER_TLS_ADDRESS: "0\.0\.0\.0:3443"' \
    || { printf 'FAIL: coder TLS listener is not 3443, so the :3001 mapping fronting it is wrong\n' >&2; return 1; }
  grep -qxF -- "3001 3443" <<<"$(hs_port_pairs coder)" \
    || { printf 'FAIL: compose publishes no host 3001 -> 3443 for coder (the TLS door the skill names)\n' >&2; return 1; }
}

@test "hermes skills: Ollama stays unpublished on the Arc, as model-routing claims" {
  # The skill tells the assistant NOT to dial :11434 because the port is closed
  # to the host on purpose. If compose ever publishes it, that advice is a lie and
  # the Arc's model port is exposed on the LAN.
  local block
  assert_contains_file "the skill names 11434" "${SKILLS}/model-routing/SKILL.md" ':11434'
  block="$(hs_service_block ollama)"
  [[ -n ${block} ]] || { printf 'FAIL: no ollama service in %s\n' "${COMPOSE}" >&2; return 1; }
  if printf '%s\n' "${block}" | grep -Eq '^[[:space:]]*ports:'; then
    printf 'FAIL: ollama publishes ports, but model-routing says :11434 is unpublished on the Arc on purpose\n' >&2
    return 1
  fi
  printf '%s' "${block}" | grep -Eq 'OLLAMA_HOST: [^ ]*:11434' \
    || { printf 'FAIL: ollama does not bind 11434, so the compose-network URL the skill assumes is stale\n' >&2; return 1; }
}

# --- 4. paths and env ------------------------------------------------------

@test "hermes skills: the host paths and container paths they name are the mounts compose makes" {
  # The skills send the assistant to ${STACK_HOST_PATH:-/opt/stack}, the deploy
  # workspace, the read-only skills mount, and /opt/data. A path that is not a
  # mount is a directory the assistant writes into oblivion - or a checkout it
  # edits believing it is editing the running payload.
  local hermes
  assert_contains_file "checkout path in the skill" "${SKILLS}/evo-stack-ops/SKILL.md" \
    'STACK_HOST_PATH:-/opt/stack'
  assert_contains_file "deploy path in the skill" "${SKILLS}/deploy-from-github/SKILL.md" \
    'STACK_DEPLOY_PATH:-/opt/stack-deploy'
  assert_contains_file "checkout env default" "${COMPOSE}" \
    'STACK_HOST_PATH: \$\{STACK_HOST_PATH:-/opt/stack\}'
  assert_contains_file "deploy workspace mount" "${COMPOSE}" \
    '\$\{STACK_DEPLOY_PATH:-/opt/stack-deploy\}:\$\{STACK_DEPLOY_PATH:-/opt/stack-deploy\}'
  assert_contains_file "skills mounted read-only" "${COMPOSE}" \
    '\./hermes/skills:/opt/stack-skills:ro'
  hermes="$(hs_service_block hermes)"
  printf '%s' "${hermes}" | grep -Eq '^[[:space:]]*-[[:space:]]*hermes-data:/opt/data([[:space:]]|$)' \
    || { printf 'FAIL: hermes has no hermes-data volume at /opt/data, which the skills call the data door\n' >&2; return 1; }
}

@test "hermes skills: the payloads they forbid editing in place are bind-mounted read-only" {
  # Both skills say litellm/config.yaml and searxng/settings.yml are bind-mounted
  # from the checkout, so the fix is a commit plus a recreate. If a mount stops
  # being :ro, the assistant's in-container edit would win and silently diverge
  # from git.
  local pair service source
  for pair in "litellm ./litellm/config.yaml" "searxng ./searxng/settings.yml"; do
    read -r service source <<<"${pair}"
    assert_contains_file "${source} bind-mounted read-only into ${service}" \
      "${COMPOSE}" "^[[:space:]]*-[[:space:]]*${source}:[^:]+:ro[[:space:]]*$"
  done
  assert_contains_file "the skill forbids the hand edit" "${SKILLS}/model-routing/SKILL.md" \
    'bind-mounted from the checkout'
}

# --- 5. model aliases ------------------------------------------------------

@test "hermes skills: every alias in the model-routing table is a LiteLLM model_name" {
  # The table is the whole routing answer the assistant gives. `hermes config set
  # model.model agent-xhigh` against an alias LiteLLM never registered is a
  # gateway that answers nothing until someone re-reads this file.
  local names offenders="" want_alias table
  names="$(grep -E '^[[:space:]]*-[[:space:]]*model_name:' "${LITELLM_CFG}" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*//' | sort -u)"
  [[ -n ${names} ]] || { printf 'FAIL: no model_name entries in %s\n' "${LITELLM_CFG}" >&2; return 1; }
  # shellcheck disable=SC2016  # the backticks delimit the alias cell of each table row
  table="$(grep -E '^\|[[:space:]]*`' "${SKILLS}/model-routing/SKILL.md" \
    | sed -E 's/^\|[[:space:]]*`([^`]+)`.*/\1/' | sort -u)"
  while read -r want_alias; do
    [[ -n ${want_alias} ]] || continue
    grep -qxF -- "${want_alias}" <<<"${names}" || offenders+="  ${want_alias}"$'\n'
  done <<<"${table}"
  [[ -z ${offenders} ]] \
    || { printf 'FAIL: model-routing advertises aliases LiteLLM does not serve:\n%s  served: %s\n' \
      "${offenders}" "$(tr '\n' ' ' <<<"${names}")" >&2; return 1; }
}

@test "hermes skills: the 32k context ceiling they quote is the coder lane's own config" {
  # "coder / coder-fast cap at 32k" is what makes the assistant refuse a long diff
  # instead of overflowing the model; agent's much larger window is the reason it
  # switches. Both numbers come from model_info, so they can drift silently.
  local block
  assert_contains_file "the skill quotes 32k" "${SKILLS}/model-routing/SKILL.md" 'cap at 32k context'
  # Both coder entries, so the slice runs to the alias that follows coder-fast.
  block="$(sed -n '/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*coder$/,/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*chat$/p' "${LITELLM_CFG}")"
  [[ "$(grep -c 'max_input_tokens: 32768' <<<"${block}")" -eq 2 ]] \
    || { printf 'FAIL: coder and coder-fast do not both declare max_input_tokens: 32768\n' >&2; return 1; }
  block="$(sed -n '/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*agent$/,/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*agent-low$/p' "${LITELLM_CFG}")"
  grep -Eq 'max_input_tokens: (1[0-9]{5}|2[0-9]{5}|[3-9][0-9]{5,})' <<<"${block}" \
    || { printf 'FAIL: the agent group does not declare a context window far above 32k\n' >&2; return 1; }
}

@test "hermes skills: no per-deployment cap in litellm/config.yaml, and the agent fallback is real" {
  # Both skills promise "nothing here gets a cap"; AGENTS.md forbids re-adding
  # rpm/tpm. The fallback claim is the one the assistant repeats when the Sparks
  # are dark, so it has to be the config's own router_settings.
  local caps
  caps="$(grep -vE '^[[:space:]]*#' "${LITELLM_CFG}" | grep -nE 'rpm|tpm|max_parallel_requests' || true)"
  [[ -z ${caps} ]] || { printf 'FAIL: per-deployment caps in %s, which the skills and AGENTS.md forbid:\n%s\n' \
    "${LITELLM_CFG}" "${caps}" >&2; return 1; }
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  python3 - "${LITELLM_CFG}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    cfg = yaml.safe_load(handle)
fallbacks = (cfg.get("router_settings") or {}).get("fallbacks") or []
agent = [list(item.keys())[0] for item in fallbacks if isinstance(item, dict) and "agent" in item]
if not agent:
    sys.exit("FAIL: router_settings.fallbacks maps no agent alias, which model-routing claims")
targets = next(item["agent"] for item in fallbacks if isinstance(item, dict) and "agent" in item)
if "coder" not in targets:
    sys.exit("FAIL: the agent alias falls back to %r, not coder as model-routing states" % (targets,))
PY
}

# --- 6. what the pinned image actually ships ------------------------------

# Read off the pinned image (`docker run --rm --entrypoint /bin/bash
# nousresearch/hermes-agent:v0.22.5`, then `command -v <tool>`), not remembered:
# each of these answers MISSING there, while git, curl, rg, vmstat, df, du and the
# Docker CLI are present. `ollama` is left out because it is also a compose service
# name, and a skill naming the service is not naming a command.
HS_IMAGE_MISSING_TOOLS=(bazelisk jq sqlite3 sensors iotop sar)

@test "hermes skills: a file that names a tool the image lacks also says the image lacks it" {
  # The failure this pins is the one an operator sees: the assistant copies the
  # line, gets "command not found", and reports the box as broken. Saying the tool
  # is absent in the same file is what turns that into a hand-over instead.
  local tool file offenders=""
  for file in "${SKILLS}"/*/SKILL.md "${REPO_ROOT}/hermes/SOUL.md"; do
    [[ -f ${file} ]] || continue
    for tool in "${HS_IMAGE_MISSING_TOOLS[@]}"; do
      grep -qw -- "${tool}" "${file}" || continue
      # The admission is one sentence long: "no bazelisk, and no `jq`, `sqlite3`
      # ..." counts for every tool in the list, so the window runs to the first
      # full stop rather than to the next word.
      grep -qiEz 'no [^.]*'"${tool}" "${file}" \
        || offenders+="  ${file#"${REPO_ROOT}"/}: names ${tool}, never says the image has none"$'\n'
    done
  done
  [[ -z ${offenders} ]] \
    || { printf 'FAIL: skills that name a tool the pinned image does not ship:\n%s' "${offenders}" >&2; return 1; }
}

@test "hermes skills: the web lane they teach is the lane the seed configures" {
  # The skills are what the assistant reads when it decides how to look something
  # up. If the seed moves and the prose does not, the assistant is told one door
  # exists while the config opens another - and the difference is invisible until
  # a search leaves the box.
  local research="${SKILLS}/web-research/SKILL.md"
  assert_file_exists "web-research skill" "${research}"
  assert_contains_file "names the pin" "${research}" 'web\.search_backend: searxng'
  assert_contains_file "names the registering env" "${research}" 'SEARXNG_URL'
  assert_contains_file "names the extract gap" "${research}" 'web_extract'
  assert_contains_file "names the keyless switches" "${research}" 'keyless_fallback'

  # Naming a vendor to forbid it is documentation, which is what the seed's own
  # comment does. Handing one a route is not, so the skills get checked on the two
  # things that would actually send a query out: an endpoint and a backend value.
  # The glob is deliberate - under runfiles the skill files are symlinks, and a
  # recursive grep walks past a symlink it did not receive as an argument.
  local hosts backends
  hosts="$(grep -niE 'https?://[a-z0-9.-]*(exa|parallel|firecrawl|keenable|tavily|brave|perplexity|serpapi)' \
    "${SKILLS}"/*/SKILL.md || true)"
  [[ -z ${hosts} ]] \
    || { printf 'FAIL: a skill gives a web vendor an endpoint:\n%s\n' "${hosts}" >&2; return 1; }
  backends="$(grep -hoE 'search_backend:[[:space:]]*[a-z-]+' "${SKILLS}"/*/SKILL.md \
    | awk '{print $2}' | sort -u | tr '\n' ' ')"
  [[ "${backends}" == 'searxng ' ]] \
    || { printf 'FAIL: the skills set a web search backend other than searxng: [%s]\n' "${backends}" >&2; return 1; }
}

# --- 7. the coding-agent door ----------------------------------------------

@test "hermes skills: the coding-agents state table is the states coder-sessions prints" {
  # state_word is the only place these words are made, and the skill is what tells
  # the assistant what each one means and what to say back. A sixth state added to
  # the script without a row here gets read as one of the states the assistant did
  # learn - the difference between "it is working" and "it is waiting on you".
  local cli skill states table offenders=""
  cli="${REPO_ROOT}/scripts/coder-sessions.sh"
  skill="${SKILLS}/coding-agents/SKILL.md"
  assert_file_exists "coder-sessions script" "${cli}"
  assert_file_exists "coding-agents skill" "${skill}"
  states="$(sed -n '/^state_word()/,/^}/p' "${cli}" \
    | sed -nE "s/.*printf '([a-z-]+)\\\\n'.*/\\1/p" | sort -u)"
  [[ -n ${states} ]] \
    || { printf 'FAIL: state_word in %s prints no state words; the extraction is stale\n' "${cli}" >&2; return 1; }
  # Only the state table, which is the one block whose first column is a state word.
  # The backtick pre-filter is what drops the header and the |---| separator row.
  table="$(sed -n '/^| state |/,/^$/p' "${skill}" \
    | grep -E '^\|[[:space:]]*`' \
    | sed -E 's/^\|[[:space:]]*`([^`]+)`.*/\1/' | sort -u)"
  [[ -n ${table} ]] \
    || { printf 'FAIL: no "| state |" table found in %s\n' "${skill}" >&2; return 1; }
  offenders="$(comm -3 <(printf '%s\n' "${states}") <(printf '%s\n' "${table}"))"
  [[ -z ${offenders} ]] \
    || { printf 'FAIL: state words out of step between %s and %s:\n  %s\n  script prints: %s\n  table names: %s\n' \
      "${cli}" "${skill}" "${offenders//$'\n'/ }" \
      "$(tr '\n' ' ' <<<"${states}")" "$(tr '\n' ' ' <<<"${table}")" >&2; return 1; }
}

@test "hermes skills: the coding-agents door names the real script path and its verbs" {
  # The assistant copies the invocation verbatim from a container that has no
  # bazelisk, so the mounted-checkout path and the verb list are the whole door.
  local skill="${SKILLS}/coding-agents/SKILL.md"
  assert_contains_file "reaches the CLI through the mounted checkout" "${skill}" \
    'STACK_HOST_PATH:-/opt/stack\}/scripts/coder-sessions\.sh'
  # The three verbs that change something, named as such: the skill has to tell the
  # assistant which commands are safe to run on its own and which need the yes.
  assert_contains_file "names the mutating verbs" "${skill}" \
    'Mutating verbs are `send`, `launch`, and `stop`'
  # Every verb the skill demonstrates in its own examples must be a real subcommand;
  # the section-2 test only sees the //scripts: form, and this file mostly shows the
  # bash form, which is the one used from inside the container.
  local verb offenders=""
  for verb in list show tail send launch stop watch check; do
    grep -qF -- "bash \"\$CS\" ${verb}" "${skill}" \
      || offenders+="  ${verb}"$'\n'
    hs_script_has_subcommand "${REPO_ROOT}/scripts/coder-sessions.sh" "${verb}" \
      || offenders+="  ${verb} is not dispatched"$'\n'
  done
  [[ -z ${offenders} ]] \
    || { printf 'FAIL: coding-agents verbs not both shown and dispatched:\n%s' "${offenders}" >&2; return 1; }
}
