#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## domain.bats — hermetic coverage for scripts/lib/domain.sh.
#
# The library is the single place a public hostname is composed, so this suite
# pins the whole grammar: `<service>-<environment>-<suffix>.<base>`, always ONE
# label under the zone. Five of these names are typed by nobody any more — the
# operator sets a zone, a box label and a service prefix, and the router table,
# the HOMEPAGE_ALLOWED_HOSTS entries, the cert SANs and the five STACK_*_URL keys
# all follow from what these functions print. A wrong character here becomes a
# 421 at the edge or a card that points at a name nothing answers, so the
# assertions are on exact strings rather than shapes.
#
# Two behaviours are pinned deliberately because they were found broken first:
# the zone-apex path (no service label) must survive `set -u`, and an unusable
# part must refuse loudly rather than compose a name nobody owns.
#
# No stubs are needed: nothing here touches the network, docker, or .env.
#
# Usage: bazelisk test //tests:bats_domain_test   (from any cwd)

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  if [ ! -f "${REPO_ROOT}/scripts/lib/domain.sh" ]; then
    skip "scripts/lib/domain.sh is not in the tree"
  fi
  cd "${BATS_TEST_TMPDIR}" || return 1
  # The parts come from the environment, so a key left over from the host shell
  # would silently change every expected name in this suite.
  unset STACK_DOMAIN_BASE STACK_SUBDOMAIN_SUFFIX STACK_ENV_LABEL
  unset STACK_CODER_NAME STACK_KASM_NAME STACK_LITELLM_NAME STACK_HERMES_NAME
  unset STACK_DASHBOARD_NAME
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/domain.sh"
}

# ---------------------------------------------------------------- domain_part_value

@test "domain_part_value: lowercases, trims spaces and strips a trailing zone dot" {
  run domain_part_value "  GMKtec-Beast. "
  [ "${status}" -eq 0 ]
  [ "${output}" = "gmktec-beast" ]
}

@test "domain_part_value: a pasted URL is refused, not salvaged into a host" {
  # Guessing a domain out of `https://x/` would turn a typo into a live public name.
  # Refusal is what makes bootstrap say "composed no name" and stay LAN-only.
  run domain_part_value "https://Coder.Example.COM/"
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]
}

@test "domain_part_value: an empty part is legal and prints nothing" {
  run domain_part_value ""
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "domain_part_value: a part with a slash, a port or an underscore is refused" {
  run domain_part_value "bad/path"
  [ "${status}" -eq 1 ]
  run domain_part_value "box:8080"
  [ "${status}" -eq 1 ]
  run domain_part_value "bad_box"
  [ "${status}" -eq 1 ]
}

# ---------------------------------------------------------------------- domain_part

@test "domain_part: an unset variable falls back to the caller's default" {
  run domain_part STACK_CODER_NAME coder
  [ "${status}" -eq 0 ]
  [ "${output}" = "coder" ]
}

@test "domain_part: the environment wins over the default" {
  STACK_CODER_NAME=coder2 run domain_part STACK_CODER_NAME coder
  [ "${status}" -eq 0 ]
  [ "${output}" = "coder2" ]
}

@test "domain_part: an unusable value is refused rather than sanitized into a name" {
  STACK_DOMAIN_BASE="not a domain!" run domain_part STACK_DOMAIN_BASE overeazy.io
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]
}

# ----------------------------------------------------------- domain_service_default

@test "domain_service_default: the four services carry their shipped prefixes" {
  run domain_service_default STACK_CODER_NAME
  [ "${output}" = "coder" ]
  run domain_service_default STACK_KASM_NAME
  [ "${output}" = "kasm" ]
  run domain_service_default STACK_LITELLM_NAME
  [ "${output}" = "litellm" ]
  run domain_service_default STACK_HERMES_NAME
  [ "${output}" = "hermes" ]
}

@test "domain_service_default: the dashboard and an unknown key have no label" {
  run domain_service_default STACK_DASHBOARD_NAME
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
  run domain_service_default STACK_NOT_A_SERVICE
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

# --------------------------------------------------------------- public_host_for

@test "public_host_for: the shipped defaults compose the documented names" {
  run public_host_for STACK_CODER_NAME coder
  [ "${status}" -eq 0 ]
  [ "${output}" = "coder-gmktecbeast.overeazy.io" ]
  run public_host_for STACK_HERMES_NAME hermes
  [ "${status}" -eq 0 ]
  [ "${output}" = "hermes-gmktecbeast.overeazy.io" ]
}

@test "public_host_for: an environment label goes AFTER the service, keeping the prefix first" {
  # Order matters twice over: classify_public_entry routes an entry by its service
  # prefix, and a wildcard cert only covers one label under the zone.
  export STACK_ENV_LABEL=dev
  run public_host_for STACK_CODER_NAME coder
  [ "${status}" -eq 0 ]
  [ "${output}" = "coder-dev-gmktecbeast.overeazy.io" ]
}

@test "public_host_for: an empty service label yields the zone apex" {
  run public_host_for STACK_DASHBOARD_NAME ""
  [ "${status}" -eq 0 ]
  [ "${output}" = "gmktecbeast.overeazy.io" ]
}

@test "public_host_for: the apex path survives set -u with no service label" {
  # The regression this pins: `service` was only assigned when a key was passed, so
  # the dashboard branch read an unbound variable under the entry scripts' set -u
  # and the dashboard silently vanished from every derived list.
  run bash -c 'set -u; source "$1/scripts/lib/domain.sh"; public_host_for STACK_DASHBOARD_NAME ""' \
    _ "${REPO_ROOT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "gmktecbeast.overeazy.io" ]
}

@test "public_host_for: base, suffix and the service label are all operator-controlled" {
  export STACK_DOMAIN_BASE=example.com
  export STACK_SUBDOMAIN_SUFFIX=BOX-01
  export STACK_CODER_NAME=cdr
  run public_host_for STACK_CODER_NAME coder
  [ "${status}" -eq 0 ]
  [ "${output}" = "cdr-box-01.example.com" ]
}

@test "public_host_for: an unusable part prints nothing and returns non-zero" {
  export STACK_DOMAIN_BASE="http://wrong/x"
  run public_host_for STACK_CODER_NAME coder
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]
}

@test "public_host_for: a suffix that normalizes to nothing is refused, not joined" {
  # `-.` strips to empty; joining it anyway would emit `coder-..overeazy.io`.
  export STACK_SUBDOMAIN_SUFFIX="-.-"
  run public_host_for STACK_CODER_NAME coder
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]
}

# ------------------------------------------------------------ public_hosts_default

@test "public_hosts_default: the five names come out dashboard-first" {
  run public_hosts_default
  [ "${status}" -eq 0 ]
  [ "${output}" = "gmktecbeast.overeazy.io,coder-gmktecbeast.overeazy.io,kasm-gmktecbeast.overeazy.io,litellm-gmktecbeast.overeazy.io,hermes-gmktecbeast.overeazy.io" ]
}

@test "public_hosts_default: an environment label reaches all five names" {
  export STACK_ENV_LABEL=dev
  run public_hosts_default
  [ "${output}" = "dev-gmktecbeast.overeazy.io,coder-dev-gmktecbeast.overeazy.io,kasm-dev-gmktecbeast.overeazy.io,litellm-dev-gmktecbeast.overeazy.io,hermes-dev-gmktecbeast.overeazy.io" ]
}

@test "public_hosts_default: a single broken service is skipped, the rest survive" {
  export STACK_KASM_NAME="bad name"
  run public_hosts_default
  [ "${status}" -eq 0 ]
  assert_not_match "the broken service is left out" "kasm" "${output}"
  assert_match "coder survives" "coder-gmktecbeast\.overeazy\.io" "${output}"
  assert_match "hermes survives" "hermes-gmktecbeast\.overeazy\.io" "${output}"
  # A skipped service must not leave an empty list item behind.
  assert_not_match "no empty list item" ",," "${output}"
}

@test "public_hosts_default: a broken zone yields an empty line, which is LAN-only" {
  export STACK_DOMAIN_BASE="still not a domain"
  run public_hosts_default
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

# -------------------------------------------------------------- public_urls_default

@test "public_urls_default: five origins in the order bootstrap writes them" {
  run public_urls_default
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "STACK_DASHBOARD_URL=https://gmktecbeast.overeazy.io" ]
  [ "${lines[1]}" = "STACK_CODER_URL=https://coder-gmktecbeast.overeazy.io" ]
  [ "${lines[2]}" = "STACK_KASM_URL=https://kasm-gmktecbeast.overeazy.io" ]
  [ "${lines[3]}" = "STACK_LITELLM_URL=https://litellm-gmktecbeast.overeazy.io" ]
  [ "${lines[4]}" = "STACK_HERMES_URL=https://hermes-gmktecbeast.overeazy.io" ]
}

@test "public_urls_default: a name that will not compose is written empty, clearing the key" {
  # An empty value is what lets compose fall back to its LAN default, so the key has
  # to be present with nothing after the equals sign.
  export STACK_HERMES_NAME="nope!"
  run public_urls_default
  [ "${status}" -eq 0 ]
  [ "${lines[4]}" = "STACK_HERMES_URL=" ]
  [ "${lines[1]}" = "STACK_CODER_URL=https://coder-gmktecbeast.overeazy.io" ]
}

# -------------------------------------------------------- render_public_router_conf

@test "render_public_router_conf: the shipped defaults fill every vhost" {
  export STACK_ENV_LABEL=dev
  render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" "${BATS_TEST_TMPDIR}/router.conf"
  [ -f "${BATS_TEST_TMPDIR}/router.conf" ]
  for name in dev-gmktecbeast.overeazy.io coder-dev-gmktecbeast.overeazy.io \
    kasm-dev-gmktecbeast.overeazy.io litellm-dev-gmktecbeast.overeazy.io \
    hermes-dev-gmktecbeast.overeazy.io; do
    grep -qF -- "server_name ${name};" "${BATS_TEST_TMPDIR}/router.conf" ||
      fail "rendered router conf is missing server_name ${name};"
  done
}

@test "render_public_router_conf: nothing is written when a part is unusable" {
  export STACK_DOMAIN_BASE="nope / nope"
  run render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" "${BATS_TEST_TMPDIR}/router.conf"
  [ "${status}" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/router.conf" ]
  assert_match "it says why" "^warning:" "${output}"
}

@test "render_public_router_conf: a missing template is a warning, not a silent pass" {
  run render_public_router_conf "${BATS_TEST_TMPDIR}/absent.template" "${BATS_TEST_TMPDIR}/router.conf"
  [ "${status}" -ne 0 ]
  assert_match "it says why" "^warning:" "${output}"
  [ ! -e "${BATS_TEST_TMPDIR}/router.conf" ]
}

@test "render_public_router_conf: the template and the shipped default conf cannot drift" {
  # proxy/router.conf is this template rendered under the shipped defaults, and it is
  # what compose mounts when STACK_ROUTER_CONF is empty. If the two diverge, a
  # LAN-only deploy serves a vhost table that no longer matches the naming rules.
  render_public_router_conf "${REPO_ROOT}/proxy/router.conf.template" "${BATS_TEST_TMPDIR}/router.conf"
  run cmp "${REPO_ROOT}/proxy/router.conf" "${BATS_TEST_TMPDIR}/router.conf"
  [ "${status}" -eq 0 ]
}
