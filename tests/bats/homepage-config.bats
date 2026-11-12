#!/usr/bin/env bats
#
# ## homepage-config.bats - guardrails for the dashboard payload.
#
# `homepage/config/*.yaml` is bind-mounted into the dashboard file by file, and before
# this suite nothing in the repository read it: `//:validate` only proved the files
# parse, so a dashboard could be silently wrong - a card whose href names a compose
# service (a link only the container could follow), a layout row wider than the cards
# that fill it, a token compose never fills, a bookmark written as a mapping instead of
# the list of {abbr, href} the app reads (the tile then loads with a name and nothing
# else), a fifth customapi mapping the shipped bundle slices away, a local icon outside
# the one path the auth middleware exempts.
#
# tests/homepage_config_check.py is the rulebook; this suite proves three things about
# it: the shipped payload satisfies it, each rule still fires when its invariant is
# broken (a check that cannot fail guards nothing), and the search lane - the card, the
# header search box and the compose variable behind both - keeps the shape the
# dashboard needs.
#
# Usage: bazelisk test //tests:bats_homepage_config_test   (from any cwd)
# Safety: reads homepage/config/*.yaml, docker-compose.yml and the checker; writes only
#         into BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CHECKER=""
CONFIG_DIR=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CHECKER="${REPO_ROOT}/tests/homepage_config_check.py"
  [[ -f "${CHECKER}" ]] || skip "tests/homepage_config_check.py is not in the tree"
  CONFIG_DIR="${REPO_ROOT}/homepage/config"
  [[ -d "${CONFIG_DIR}" ]] || skip "homepage/config is not reachable from ${REPO_ROOT}"
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
}

# scratch_tree - copy the payload into a scratch root and print its path, so a test can
# break exactly one invariant without touching the tree the other tests read.
#
# The -L is load-bearing: under Bazel the payload reaches runfiles as a symlink to the
# file in the working tree, `cp -r` copies the link rather than the bytes, and a mutation
# would then open the repository's own YAML through that link and rewrite it.
scratch_tree() {
  local root="${BATS_TEST_TMPDIR}/root"
  mkdir -p "${root}/homepage"
  cp -rL "${CONFIG_DIR}" "${root}/homepage/config"
  cp -L "${REPO_ROOT}/docker-compose.yml" "${root}/"
  printf '%s\n' "${root}"
}

# check_fires <root> <name> - the checker must fail, naming that check.
check_fires() {
  local out; out="$(findings "$1")"
  assert_match "the checker exits 1" "exit=1" "${out}"
  assert_match "the ${2} check fires" "${2}" "${out}"
}

# findings <root> - run the checker against a scratch root and print its exit code with
# its output, so one assert can name the check and another can insist it was a failure.
findings() {
  local out rc
  out="$(python3 "${CHECKER}" --root "$1" 2>&1)"
  rc=$?
  printf 'exit=%s\n%s\n' "${rc}" "${out}"
}

@test "the shipped payload satisfies every dashboard invariant" {
  run --separate-stderr python3 "${CHECKER}" --root "${REPO_ROOT}"
  assert_eq "clean payload" "0" "${status}"
  assert_match "reports zero findings" "summary: 0 findings" "${output}"
}

@test "the checker refuses a tree with no payload instead of reporting it clean" {
  local root="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "${root}"
  run --separate-stderr python3 "${CHECKER}" --root "${root}"
  assert_eq "refused" "1" "${status}"
  assert_match "names the missing file" "error: missing:" "${output}"
}

@test "an undeclared HOMEPAGE_VAR token is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's/HOMEPAGE_VAR_SEARCH_URL/HOMEPAGE_VAR_BOGUS_URL/' "${root}/homepage/config/services.yaml"
  check_fires "${root}" token-declared
}

@test "a HOMEPAGE_VAR key no config file uses is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's/^      HOMEPAGE_VAR_AGENT_URL:/      HOMEPAGE_VAR_AGENT_URL_ORPHAN:/' "${root}/docker-compose.yml"
  check_fires "${root}" token-used
}

@test "a group with no layout entry is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's/^- Host:/- Boxes:/' "${root}/homepage/config/services.yaml"
  check_fires "${root}" layout-group
}

@test "a layout row whose columns do not match its cards is a finding" {
  local root; root="$(scratch_tree)"
  python3 - "${root}/homepage/config/services.yaml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
extra = (
    "    - Second-ollama:\n"
    "        icon: mdi-chip\n"
    "        description: an extra card that makes the row wider than columns says\n"
    "        siteMonitor: http://ollama:11434/api/version\n\n"
)
open(path, "w", encoding="utf-8").write(text.replace("    # Ollama has no href on purpose:", extra + "    # Ollama has no href on purpose:", 1))
PY
  check_fires "${root}" row-columns
}

@test "an href that names a compose service is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's|href: "{{HOMEPAGE_VAR_KASM_URL}}"|href: http://kasm:4443/|' "${root}/homepage/config/services.yaml"
  check_fires "${root}" href-browser
}

@test "a probe that hard-codes an address literal is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's|siteMonitor: http://searxng:8181/healthz|siteMonitor: http://192.168.4.20:8181/healthz|' "${root}/homepage/config/services.yaml"
  check_fires "${root}" monitor-network
}

# The Spark boxes are off-stack, so compose DNS cannot reach them and a hostname
# written into docker-compose.yml names a machine nobody owns. Each box is named
# once, by SPARKn_HOST in .env, and compose composes every URL from it.
@test "a Spark URL that names a host in compose is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's|^      HOMEPAGE_VAR_SPARK1_HEALTH: .*|      HOMEPAGE_VAR_SPARK1_HEALTH: ${SPARK1_HEALTH_URL:-http://spark-off.example:8888/health}|' "${root}/docker-compose.yml"
  check_fires "${root}" spark-host
}

@test "a Spark URL whose fallback is an address literal is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's|^      HOMEPAGE_VAR_AGENT_HEALTH: .*|      HOMEPAGE_VAR_AGENT_HEALTH: ${AGENT_MODEL_URL:-http://192.168.4.20:8888/v1/models}|' "${root}/docker-compose.yml"
  check_fires "${root}" spark-host
}

@test "the Spark cards and the LiteLLM deployments read one hostname per box" {
  # Pinned because the cards once defaulted to a spark-<n>.lan literal that no
  # operator's .env agreed with: configure the boxes and the cards went stale.
  local compose; compose="$(cat "${REPO_ROOT}/docker-compose.yml")"
  assert_match "box 1 agent deployment" 'SPARK1_OPENAI_URL: \$\{SPARK1_OPENAI_URL:-http://\$\{SPARK1_HOST' "${compose}"
  assert_match "box 1 health card" 'HOMEPAGE_VAR_SPARK1_HEALTH: \$\{SPARK1_HEALTH_URL:-http://\$\{SPARK1_HOST' "${compose}"
  assert_match "agent card rides box 2 host" 'HOMEPAGE_VAR_AGENT_HEALTH: \$\{AGENT_MODEL_URL:-http://\$\{SPARK2_HOST' "${compose}"
  assert_match "the ollama alias reads the host too" 'SPARK1_OLLAMA_URL: \$\{SPARK1_OLLAMA_URL:-http://\$\{SPARK1_HOST' "${compose}"
  assert_not_match "no LAN hostname left in compose" 'spark-[123]\.lan' "${compose}"
}

@test "a block widget with more mappings than the bundle renders is a finding" {
  local root; root="$(scratch_tree)"
  python3 - "${root}/homepage/config/services.yaml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
extra = "".join(f"              - field: extra_{i}\n                label: Extra {i}\n" for i in range(6))
open(path, "w", encoding="utf-8").write(text.replace("              - field: version\n                label: Version\n", extra, 1))
PY
  check_fires "${root}" block-mappings
}

@test "a bookmark written as a bare mapping is a finding" {
  local root; root="$(scratch_tree)"
  python3 - "${root}/homepage/config/bookmarks.yaml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
broken_shape = "        - abbr: HP\n          href: https://gethomepage.dev/"
open(path, "w", encoding="utf-8").write(text.replace(broken_shape, "        abbr: HP\n        href: https://gethomepage.dev/", 1))
PY
  check_fires "${root}" bookmark-shape
}

@test "a local icon outside the exempt /icons/ path is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's|icon: /icons/evo-t1.svg|icon: /images/evo-t1.svg|' "${root}/homepage/config/widgets.yaml"
  check_fires "${root}" icon-path
}

@test "a custom search provider without an open query url is a finding" {
  local root; root="$(scratch_tree)"
  sed -i 's|url: "{{HOMEPAGE_VAR_SEARCH_URL}}/search?q="|url: "{{HOMEPAGE_VAR_SEARCH_URL}}/search"|' "${root}/homepage/config/widgets.yaml"
  check_fires "${root}" search-url
}

# The search lane is one feature in three files: the card, the header search box, and the
# compose variable both read. Pin the seam, because a rename in any one of the three
# leaves the dashboard with a dead link or an unrendered token.
@test "the search lane card probes the instance over the compose network" {
  local services; services="$(cat "${CONFIG_DIR}/services.yaml")"
  assert_match "health probe" "siteMonitor: http://searxng:8181/healthz" "${services}"
  assert_match "config read" "url: http://searxng:8181/config" "${services}"
  assert_match "browser link rides the token" 'href: "{{HOMEPAGE_VAR_SEARCH_URL}}"' "${services}"
}

@test "the header search and the Search card share one compose variable" {
  local widgets compose
  widgets="$(cat "${CONFIG_DIR}/widgets.yaml")"
  compose="$(cat "${REPO_ROOT}/docker-compose.yml")"
  assert_match "box url" 'url: "\{\{HOMEPAGE_VAR_SEARCH_URL\}\}/search\?q="' "${widgets}"
  assert_match "compose declares it" 'HOMEPAGE_VAR_SEARCH_URL: \$\{STACK_SEARCH_URL' "${compose}"
}

@test "the header search box asks the box's own instance, not a public engine" {
  # Comment lines are dropped: the prose right above the widget documents how to hand the
  # box back to a public engine, and naming that engine there is not the box using one.
  local widgets; widgets="$(grep -v '^[[:space:]]*#' "${CONFIG_DIR}/widgets.yaml")"
  assert_match "custom provider" "provider: custom" "${widgets}"
  assert_not_match "no duckduckgo" 'provider: duckduckgo' "${widgets}"
  assert_not_match "no google" 'provider: google' "${widgets}"
}

@test "the published docs site keeps the bookmark shape the app reads" {
  local entry; entry="$(grep -A 2 'Docs site' "${CONFIG_DIR}/bookmarks.yaml")"
  assert_match "docs site url" "toxicoder.github.io/evo-t1-coder-stack/latest/" "${entry}"
  assert_match "abbr list form" "- abbr: DOC" "${entry}"
}
