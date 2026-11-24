#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## workspace-tz.bats - the workspace boot resolves one zone and applies it.
#
# Nothing in the stack ever set a timezone, so every workspace answered in the
# golden image's default while the stack host ran on its own zone: date, the
# terminals the agent opens, and the agent process itself all read the container's
# localtime, which no boot stage had touched. Three halves are pinned here: the seam
# that hands the coder container a zone at all, the probe that resolves one, and the
# boot body that applies it.
#
# The resolver is templates/common/tz.sh, a POSIX probe. It is ferried to a remote
# and run with sh, so every case below runs it with sh and never sources it: a probe
# that only works with the caller's bash environment already set up would pass here
# and fail on the far end. Its three sources are its arguments, so each case builds
# its own zoneinfo tree, its own timezone file, and its own localtime link in the
# test's tmpdir. The order is fixed - an injected TZ, then the timezone file, then
# the localtime link - and a candidate has to look like a zone name to be taken, so
# the three things those sources really carry (a POSIX rule string, an absolute
# path, hand-edited junk) fall through instead of being applied.
#
# The apply is its own boot body, templates/common/tz-setup.sh.tftpl, wired by both
# twins as coder_script "tz_setup": one shared file, so the twins cannot drift, and a
# coder_script rather than a stage of the startup script because the startup argument
# is the one execve that runs out of room. Coder runs every run_on_start body in one
# errgroup and marks the workspace ready only after all of them return, so the zone
# still lands before anything reads a clock. The cases resolve each twin's body out of
# that twin's own main.tf, so a twin that stops wiring it fails every apply case
# against a file it never runs. The section interpolates exactly one Terraform key,
# tz_probe, which that map fills from the probe file; that key is the seam between the
# two halves and the case below names it so a rename on one side is a red test.
#
# Usage: bazelisk test //tests:bats_workspace_tz_test   (from any cwd)
# Safety: no network, no daemon, no system /etc. Every write lands under
#         BATS_TEST_TMPDIR, because the section reads its three paths from the
#         environment and the cases point them at the scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
PROBE=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PROBE="${REPO_ROOT}/templates/common/tz.sh"
  [[ -f ${PROBE} ]] || skip "templates/common/tz.sh is not in the tree"
  unset TZ TZ_ZONEINFO_DIR TZ_TIMEZONE_FILE TZ_LOCALTIME_LINK
}

# scratch_tree - build ${BATS_TEST_TMPDIR}/tz and print its path. The tree is named
# zoneinfo because that is the token the localtime link is read against, and it
# carries two nested zones: a candidate without a slash is not a zone name, so a
# flat fixture could never tell a name from a rule string.
#
# Fixture knobs, set by the case before the call: TZ_FILE_CONTENT is what the
# timezone file holds, and NO_ETC_UTC drops Etc/UTC so the documented fallback has
# nothing to resolve to.
scratch_tree() {
  local etc="${BATS_TEST_TMPDIR}/tz"
  mkdir -p "${etc}/zoneinfo/Etc" "${etc}/zoneinfo/America"
  if [[ -z ${NO_ETC_UTC:-} ]]; then
    : >"${etc}/zoneinfo/Etc/UTC"
  fi
  : >"${etc}/zoneinfo/America/New_York"
  printf '%s\n' "${TZ_FILE_CONTENT:-Etc/UTC}" >"${etc}/timezone"
  ln -sfn ../zoneinfo/America/New_York "${etc}/localtime"
  printf '%s' "${etc}"
}

# probe_with <env-assignments...> -- run the probe with sh against the scratch tree.
# The three paths are positional so the case, not the image, decides what the
# resolver reads.
probe_with() {
  local etc
  etc="$(scratch_tree)"
  run env "$@" sh "${PROBE}" "${etc}/zoneinfo" "${etc}/timezone" "${etc}/localtime"
}

@test "resolver: the injected TZ wins over the timezone file and the link" {
  probe_with TZ=America/New_York
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "America/New_York" ]
}

@test "resolver: the timezone file answers when TZ is not in the environment" {
  local etc
  etc="$(scratch_tree)"
  run env -u TZ sh "${PROBE}" "${etc}/zoneinfo" "${etc}/timezone" "${etc}/localtime"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]

  TZ_FILE_CONTENT=America/New_York etc="$(scratch_tree)"
  run env -u TZ sh "${PROBE}" "${etc}/zoneinfo" "${etc}/timezone" "${etc}/localtime"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "America/New_York" ]
}

@test "resolver: a blank TZ is no source, so the file still answers" {
  probe_with TZ="   "
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: the localtime link answers when the file is gone or junk" {
  local etc
  etc="$(scratch_tree)"
  run env -u TZ sh "${PROBE}" "${etc}/zoneinfo" "${etc}/no-such-file" "${etc}/localtime"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "America/New_York" ]

  TZ_FILE_CONTENT="localtime" etc="$(scratch_tree)"
  run env -u TZ sh "${PROBE}" "${etc}/zoneinfo" "${etc}/timezone" "${etc}/localtime"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "America/New_York" ]
}

@test "resolver: a POSIX rule string is refused and the next source answers" {
  probe_with TZ=EST5EDT
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]

  probe_with TZ=UTC+8
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: an absolute path in TZ is refused" {
  local etc
  etc="$(scratch_tree)"
  probe_with "TZ=${etc}/zoneinfo/America/New_York"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: a zone the tree does not carry is refused" {
  probe_with TZ=Europe/Paris
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: a slash-free name is refused even with no zoneinfo tree to check" {
  TZ_FILE_CONTENT=EST5EDT
  local etc
  etc="$(scratch_tree)"
  run env -u TZ sh "${PROBE}" "${BATS_TEST_TMPDIR}/no-zoneinfo" "${etc}/timezone" \
    "${etc}/localtime"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "America/New_York" ]
}

@test "resolver: the fallback is Etc/UTC and it is the one answer that exits 1" {
  local etc
  etc="$(scratch_tree)"
  run env -u TZ sh "${PROBE}" "${BATS_TEST_TMPDIR}/no-zoneinfo" \
    "${BATS_TEST_TMPDIR}/no-timezone" "${BATS_TEST_TMPDIR}/no-localtime"
  [ "${status}" -eq 1 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: spaces and carriage returns around a name are folded away" {
  local etc
  etc="$(scratch_tree)"
  printf ' Etc/UTC \r\n' >"${etc}/timezone"
  run env -u TZ sh "${PROBE}" "${etc}/zoneinfo" "${etc}/timezone" "${etc}/localtime"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: a localtime that is a copied file names no zone" {
  local etc
  etc="$(scratch_tree)"
  rm -f "${etc}/localtime"
  : >"${etc}/localtime"
  run env -u TZ sh "${PROBE}" "${etc}/zoneinfo" "${BATS_TEST_TMPDIR}/no-timezone" \
    "${etc}/localtime"
  [ "${status}" -eq 1 ]
  [ "${lines[0]}" = "Etc/UTC" ]
}

@test "resolver: the probe keeps the shape the boot runs it under" {
  # The boot ferries this file to a temp path and runs it with sh, so the contract is
  # three named functions and one bare call that prints the answer: a probe turned
  # back into a sourceable lib, or one that printed from a second place, would boot a
  # workspace with a zone nobody resolved.
  local name last
  for name in tz_resolve tz_candidate_ok tz_from_localtime; do
    grep -qE "^${name}\(\) \{$" "${PROBE}" ||
      fail "templates/common/tz.sh no longer defines ${name}()"
  done
  last="$(grep -vE '^[[:space:]]*(#|$)' "${PROBE}" | tail -n 1)"
  [ "${last}" = "tz_resolve" ] ||
    fail "templates/common/tz.sh ends with '${last}'; the boot expects a bare tz_resolve call"
  [ "$(grep -cE '^[[:space:]]*tz_resolve$' "${PROBE}")" -eq 1 ] ||
    fail "templates/common/tz.sh must call tz_resolve exactly once"
}

# body_from <twin> - print the path of the boot body that twin's main.tf renders for
# coder_script "tz_setup". Resolved out of main.tf rather than typed here: a twin that
# stops wiring the body, or rewires it to a file of its own, fails here instead of
# passing against a path this suite invented.
body_from() {
  local tf="${REPO_ROOT}/templates/$1/main.tf"
  [[ -f ${tf} ]] || { printf 'no main.tf for twin %s\n' "$1" >&2; return 1; }
  # sed over the resource block, never awk: this resolver is the seam every apply
  # case hangs on, and it only has to read the block's own templatefile line.
  sed -n '/^resource "coder_script" "tz_setup"/,/^}/p' "${tf}" |
    sed -n 's@.*templatefile("${path\.module}/\([^"]*\)".*@\1@p'
}

# tz_section_path <twin> - resolve the twin's body to a real file under either template
# directory, the same way boot-log.bats resolves a body name main.tf hands it.
tz_section_path() {
  local twin="$1" name dir cand
  name="$(body_from "${twin}")"
  [[ -n ${name} ]] || { printf 'twin %s wires no coder_script "tz_setup" body\n' "${twin}" >&2; return 1; }
  for dir in "${REPO_ROOT}/templates/${twin}" "${REPO_ROOT}/templates/common"; do
    cand="${dir}/${name}"
    if [[ -f ${cand} ]]; then
      printf '%s\n' "${cand}"
      return 0
    fi
  done
  printf 'twin %s wires tz_setup to %s, which is not in the tree\n' "${twin}" "${name}" >&2
  return 1
}

# section_from <twin> - print the shipped timezone section out of the body that twin
# runs, the same bounded range tests/bats/session-archive.bats uses for its own stage.
section_from() {
  local body
  body="$(tz_section_path "$1")" || return 1
  sed -n '/^# --- Host timezone/,/^rm -f "\$tz_probe_tmp" 2>\/dev\/null || true$/p' "${body}"
}

# render_apply <twin> <dest> - the section with ${tz_probe} replaced by the probe
# bytes and every escaped $${ folded back to one dollar, which is what Terraform
# hands the body: a map value is not re-interpolated, and a doubled dollar in the
# body is the body's own escape for a shell brace.
render_apply() {
  local twin="$1" dest="$2"
  local tpl
  tpl="$(tz_section_path "${twin}")" || return 1
  awk -v probe="${PROBE}" '
    /^# --- Host timezone/ { inside = 1 }
    inside {
      if ($0 == "${tz_probe}") {
        while ((getline line < probe) > 0) print line
        close(probe)
        next
      }
      folded = $0
      gsub(/\$\$\{/, "${", folded)
      print folded
    }
    /^rm -f "\$tz_probe_tmp"/ { inside = 0 }
  ' "${tpl}" >"${dest}"
}

# run_apply <twin> - run the rendered section the way the agent runs the body: under
# bash, with the shipped boot logger, and with SUDO empty because the paths this
# suite hands it are world-writable scratch.
run_apply() {
  local rendered="${BATS_TEST_TMPDIR}/section.sh"
  local case_file="${BATS_TEST_TMPDIR}/case.sh"
  render_apply "$1" "${rendered}" || return 1
  {
    cat <<CASE_HEAD
set -u
# shellcheck disable=SC1091
source '${REPO_ROOT}/templates/common/boot-log.lib.sh'
boot_begin tz 1
SUDO=""
CASE_HEAD
    cat "${rendered}"
    cat <<'CASE_TAIL'
printf "TZ=%s\n" "${TZ:-}"
CASE_TAIL
  } >"${case_file}"
  run bash "${case_file}"
}

@test "twins: both wire one shared body, and its section interpolates only tz_probe" {
  # One body, not a twin-local copy each: the twins are independent files and a clock
  # fixed in only one of them is a workspace that still prints the image's time.
  local twin body bodies=""
  for twin in workspace devcontainer; do
    body="$(tz_section_path "${twin}")" ||
      fail "templates/${twin} wires no resolvable coder_script \"tz_setup\" body"
    bodies+=$'\n'"${body#"${REPO_ROOT}/"}"
    [[ ${body} == "${REPO_ROOT}/templates/common/"* ]] ||
      fail "templates/${twin} points tz_setup at ${body#"${REPO_ROOT}/"}; the clock body is shared under templates/common"
    [[ -n $(section_from "${twin}") ]] ||
      fail "${body#"${REPO_ROOT}/"} has no host timezone section"
    [ "$(grep -c '^\${tz_probe}$' "${body}")" -eq 1 ] ||
      fail "${body#"${REPO_ROOT}/"} must interpolate tz_probe exactly once"
    local interpolations
    interpolations="$(section_from "${twin}" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sort -u)"
    [ "${interpolations}" = '${tz_probe}' ] ||
      fail "templates/${twin} section interpolates $(printf '%s' "${interpolations}" | tr '\n' ' '); only tz_probe is allowed, and every other dollar-brace belongs escaped as a doubled dollar"
  done
  [ "$(printf '%s\n' "${bodies}" | sed '/^$/d' | sort -u | wc -l)" -eq 1 ] ||
    fail "the twins point tz_setup at different bodies: ${bodies}"
}

@test "twins: the clock is its own run_on_start body, so the zone lands before ready" {
  # What used to be proved by line order inside one body is now proved by the wiring:
  # Coder v2.36 starts every run_on_start script in one concurrent errgroup and sets
  # the workspace ready only once all of them have returned (the same fact
  # docs/coder-templates.md#the-one-argument-ceiling leans on), so a body that is
  # run_on_start applies the host's zone before the editor or any terminal of the
  # agent's can be read. A body that lost run_on_start, or lost the three writes
  # themselves, is a workspace that reports ready still showing the image's clock.
  local twin tf body
  for twin in workspace devcontainer; do
    tf="${REPO_ROOT}/templates/${twin}/main.tf"
    grep -qE '^resource "coder_script" "tz_setup"' "${tf}" ||
      fail "templates/${twin}/main.tf declares no coder_script \"tz_setup\""
    body="$(tz_section_path "${twin}")" || fail "templates/${twin}: tz_setup body unresolvable"
    sed -n '/^resource "coder_script" "tz_setup"/,/^}/p' "${tf}" |
      grep -qE '^[[:space:]]*run_on_start = true$' ||
      fail "templates/${twin}: coder_script \"tz_setup\" is not run_on_start"
    grep -q 'startup_script_behavior = "blocking"' "${tf}" ||
      fail "templates/${twin}: startup_script_behavior is not blocking, so ready does not wait for the boot bodies"
    grep -qF 'tee "$TZ_TIMEZONE_FILE"' "${body}" ||
      fail "${body#"${REPO_ROOT}/"} no longer writes the zone to the timezone file"
    grep -qF 'ln -sf "$TZ_ZONEINFO_DIR/$tz_zone" "$TZ_LOCALTIME_LINK"' "${body}" ||
      fail "${body#"${REPO_ROOT}/"} no longer repoints the localtime link"
    grep -qF 'export TZ="$tz_zone"' "${body}" ||
      fail "${body#"${REPO_ROOT}/"} no longer exports TZ for the agent's own processes"
  done
}

@test "twins: neither startup body carries a private copy of the section" {
  # The section moved into the shared body; a paragraph left behind in one startup twin
  # would apply the zone twice, from two files, and only one of them is measured.
  local twin
  for twin in workspace devcontainer; do
    ! grep -q '^# --- Host timezone' "${REPO_ROOT}/templates/${twin}/startup.sh.tftpl" ||
      fail "templates/${twin}/startup.sh.tftpl still carries its own timezone section"
  done
  diff <(section_from workspace) <(section_from devcontainer)
}

@test "apply: the resolved zone lands in both paths and in TZ" {
  local etc
  etc="$(scratch_tree)"
  export TZ_ZONEINFO_DIR="${etc}/zoneinfo"
  export TZ_TIMEZONE_FILE="${etc}/timezone"
  export TZ_LOCALTIME_LINK="${etc}/localtime"
  export TZ=America/New_York
  run_apply workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"the host timezone applied: America/New_York"* ]]
  [[ ${output} == *"TZ=America/New_York"* ]]
  [ "$(cat "${etc}/timezone")" = "America/New_York" ]
  [ "$(readlink "${etc}/localtime")" = "${etc}/zoneinfo/America/New_York" ]
}

@test "apply: it agrees with the image when nothing is injected" {
  local etc
  etc="$(scratch_tree)"
  TZ_FILE_CONTENT=America/New_York etc="$(scratch_tree)"
  export TZ_ZONEINFO_DIR="${etc}/zoneinfo"
  export TZ_TIMEZONE_FILE="${etc}/timezone"
  export TZ_LOCALTIME_LINK="${etc}/localtime"
  run_apply devcontainer
  [ "${status}" -eq 0 ]
  [[ ${output} == *"the host timezone applied: America/New_York"* ]]
  [ "$(cat "${etc}/timezone")" = "America/New_York" ]
}

@test "apply: an unwritable timezone file is a warning and the boot still exits 0" {
  local etc
  etc="$(scratch_tree)"
  export TZ_ZONEINFO_DIR="${etc}/zoneinfo"
  export TZ_TIMEZONE_FILE="${etc}/missing/timezone"
  export TZ_LOCALTIME_LINK="${etc}/missing/localtime"
  export TZ=America/New_York
  run_apply workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"is not writable at"* ]]
  [[ ${output} != *"the host timezone applied"* ]]
  [ ! -e "${etc}/missing" ]
}

@test "apply: a zone with no data in the image leaves both files alone" {
  local etc
  NO_ETC_UTC=1 TZ_FILE_CONTENT=junk etc="$(scratch_tree)"
  rm -f "${etc}/localtime"
  printf 'junk\n' >"${etc}/localtime"
  export TZ_ZONEINFO_DIR="${etc}/zoneinfo"
  export TZ_TIMEZONE_FILE="${etc}/timezone"
  export TZ_LOCALTIME_LINK="${etc}/localtime"
  export TZ=Bad/Zone
  run_apply workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"no host timezone applied"* ]]
  [ "$(cat "${etc}/timezone")" = "junk" ]
  [ ! -L "${etc}/localtime" ]
}

@test "apply: a boot with no zone to apply still exits 0" {
  local etc
  etc="$(scratch_tree)"
  rm -f "${etc}/timezone" "${etc}/localtime"
  rm -rf "${etc}/zoneinfo"
  export TZ_ZONEINFO_DIR="${etc}/zoneinfo"
  export TZ_TIMEZONE_FILE="${etc}/timezone"
  export TZ_LOCALTIME_LINK="${etc}/localtime"
  run_apply devcontainer
  [ "${status}" -eq 0 ]
  [[ ${output} == *"no host timezone applied"* ]]
}

# ---------------------------------------------------------------------------
# The seam above the probe: what the coder container is handed.
#
# Everything above drives the probe and the boot body against a scratch tree they are
# pointed at. This section reads docker-compose.yml and the two twins' main.tf as data,
# because the zone the probe is handed is decided three files away from it: compose
# publishes TZ on the coder service and mounts the host's own two zone files into that
# container, and both twins resolve the agent env's TZ from what it can see there. Until
# now nothing in the gate opened those lines, so a compose edit that quietly
# reintroduced an empty TZ, or a bind that regrew a missing host file as a directory,
# stayed green. Both were measured against compose v5.5.1 on docker 29.8.1 before the
# form below was picked:
#
#   TZ: ${TZ:-}    -> the container gets TZ present and empty, and Go's initLocal reads
#                     that as UTC without ever opening /etc/localtime;
#   TZ: ~          -> the key is dropped when nothing set it, so Go reads the mounted
#                     /etc/localtime and Terraform's env("TZ") falls through to the
#                     mounted /etc/timezone -- both answer the host, and a set value
#                     still answers both;
#   short bind of a source the host lacks -> /etc/timezone arrives as a root-owned
#                     DIRECTORY, in the container and on the host, and the host copy
#                     is still there after compose down;
#   create_host_path: false -> the daemon refuses at create and creates nothing.
#
# docker-compose.yml is already in every suite's runfiles (it is the marker
# bats_canonical_repo_root walks up to), so this section needs no new payload.
# ---------------------------------------------------------------------------

# compose_block <service> - print that service's body. services: is flat, so the next
# two-space key ends it.
compose_block() {
  awk -v svc="  ${1}:" '
    $0 == svc { inside = 1; next }
    inside && /^  [a-z0-9_-]+:$/ { inside = 0 }
    inside { print }
  ' "${REPO_ROOT}/docker-compose.yml"
}

# compose_sub_block <service> <key> - print the body of one key of one service.
compose_sub_block() {
  compose_block "${1}" | awk -v key="    ${2}:" '
    $0 == key { inside = 1; next }
    inside && /^    [a-z0-9_-]+:$/ { inside = 0 }
    inside { print }
  '
}

# compose_bind_record <service> <source> - print the whole long-syntax volume record
# whose source: is <source>, so a case asserts against one item rather than the file.
compose_bind_record() {
  compose_sub_block "${1}" volumes | awk -v src="${2}" '
    /^      - / {
      if (have) printf "%s", rec
      have = 0
      rec = ""
    }
    {
      rec = rec $0 "\n"
      line = $0
      sub(/^[[:space:]-]+/, "", line)
      if (line ~ /^source:[[:space:]]/) {
        sub(/^source:[[:space:]]*/, "", line)
        if (line == src) { have = 1 }
      }
    }
    END { if (have) printf "%s", rec }
  '
}

@test "compose: the coder service publishes TZ as a null, never as an empty default" {
  # The one key two readers share, and both read an empty value as a decision rather
  # than as silence: Go as UTC, and coalesce as a zone name it must not skip. A null is
  # the only compose form that can answer "the operator set nothing" with "no key at
  # all", which is the only thing Go reads as "ask /etc/localtime".
  local env_block
  env_block="$(compose_sub_block coder environment)"
  [[ -n ${env_block} ]] || fail "docker-compose.yml: the coder service has no environment: block"
  grep -qE '^[[:space:]]*TZ:[[:space:]]*~$' <<<"${env_block}" ||
    fail "the coder service no longer publishes TZ as a null (TZ: ~); any form that resolves to an empty string puts the server on UTC and defeats the /etc/localtime bind"
  [ "$(grep -cE '^[[:space:]]*TZ:' <<<"${env_block}")" -eq 1 ] ||
    fail "the coder service declares TZ more than once in environment:"
  ! grep -qE "^[[:space:]]*TZ:[[:space:]]*(\\\$\\{|\"\"|'')" <<<"${env_block}" ||
    fail "the coder service defaults TZ to a value compose resolves to the empty string"
  ! grep -qE '^[[:space:]]*TZ:[[:space:]]*\$\{TZ' "${REPO_ROOT}/docker-compose.yml" ||
    fail "docker-compose.yml reintroduced a \${TZ:-} style default on TZ"
}

@test "compose: both host zone binds refuse to create a host file that is missing" {
  # Long syntax plus bind.create_host_path: false, on both files. The short form does
  # not fail when the host lacks the source, it invents one: a root-owned directory, at
  # the container target (where file("/etc/timezone") then reads a directory) and on the
  # host, where it outlives compose down and misleads the next dpkg-reconfigure tzdata.
  # create_host_path also has to nest under bind: -- compose refuses it as an additional
  # property at the top of the record, so the nesting is pinned rather than assumed.
  local volumes src rec bind_col chp_col
  volumes="$(compose_sub_block coder volumes)"
  [[ -n ${volumes} ]] || fail "docker-compose.yml: the coder service has no volumes: block"
  ! grep -qE '^[[:space:]]*- /etc/(timezone|localtime):' <<<"${volumes}" ||
    fail "a host zone bind went back to the KEY:TARGET:ro short form, which auto-creates a missing source as a root-owned directory"
  for src in /etc/timezone /etc/localtime; do
    rec="$(compose_bind_record coder "${src}")"
    [[ -n ${rec} ]] || fail "the coder service no longer mounts the host's ${src}, so the workspace can no longer learn the host's zone"
    grep -qE '^[[:space:]-]*type:[[:space:]]*bind$' <<<"${rec}" || fail "${src}: not a long-syntax bind"
    grep -qE "^[[:space:]]*target:[[:space:]]*${src}\$" <<<"${rec}" || fail "${src}: not mounted at its own path"
    grep -qE '^[[:space:]]*read_only:[[:space:]]*true$' <<<"${rec}" || fail "${src}: mounted writable, and the server can rewrite the host clock config"
    grep -qE '^[[:space:]]*bind:[[:space:]]*$' <<<"${rec}" || fail "${src}: no bind: table to carry create_host_path"
    chp_col="$(awk '/^[[:space:]]*create_host_path:/{match($0,/^ */); print RLENGTH; exit}' <<<"${rec}")"
    [[ -n ${chp_col} ]] ||
      fail "${src}: no create_host_path, so a host that ships no ${src} gets a root-owned directory instead of an error"
    grep -qE '^[[:space:]]*create_host_path:[[:space:]]*false$' <<<"${rec}" ||
      fail "${src}: create_host_path is not false"
    bind_col="$(awk '/^[[:space:]]*bind:/{match($0,/^ */); print RLENGTH; exit}' <<<"${rec}")"
    [ "${chp_col}" -gt "${bind_col}" ] ||
      fail "${src}: create_host_path is not nested under bind:, and compose refuses it there"
  done
}

@test "twins: the agent env resolves TZ from that container's env and mounted files" {
  # The compose null is only half the seam: both twins have to keep reading that same
  # env, then the same mounted file, then Etc/UTC. Pin the whole line, in both twins,
  # because the three sources are an order and a contract, not a call that can drift.
  local want='TZ = coalesce(env("TZ"), try(trimspace(file("/etc/timezone")), ""), "Etc/UTC")'
  local twin tf agent
  for twin in workspace devcontainer; do
    tf="${REPO_ROOT}/templates/${twin}/main.tf"
    grep -qF "${want}" "${tf}" ||
      fail "templates/${twin}/main.tf no longer resolves the agent env TZ through the pinned coalesce chain, which is what keeps it consistent with the compose null"
    agent="$(sed -n '/^resource "coder_agent" "main" {/,/^}/p' "${tf}")"
    grep -qF "${want}" <<<"${agent}" ||
      fail "templates/${twin}/main.tf: the TZ resolution is not inside coder_agent \"main\", so the agent would not inherit it"
  done
}

@test "dotenv: the sample documents TZ and never ships it as an empty value" {
  # The shipped default is itself a vector: bootstrap copies every uncommented key of
  # .env.sample into .env, so an active TZ= there reproduces the UTC server on every
  # host that follows the docs. The key is documented commented-out, and the two copies
  # have to stay byte-identical for //:validate.
  local example="${REPO_ROOT}/.env.example" sample="${REPO_ROOT}/.env.sample"
  # The two dotenv payloads are not in this suite's runfiles yet; the pin is real the
  # moment tests/BUILD.bazel declares them, and a skip says so loudly rather than
  # reporting a green suite that never opened the files.
  [[ -f ${example} && -f ${sample} ]] ||
    skip "the two dotenv payload groups are not in this suite's runfiles; declaring them in the suite payload map makes this case assert"
  cmp -s "${example}" "${sample}" || fail ".env.example and .env.sample drifted; //:validate fails on that too"
  local f
  for f in "${example}" "${sample}"; do
    ! grep -qE '^TZ=' "${f}" ||
      fail "${f#"${REPO_ROOT}/"} ships an active TZ=, which compose hands the coder container as a present-and-empty value and Go reads as UTC"
    grep -qE '^[[:space:]]*#[[:space:]]*TZ=[A-Za-z_]+/[A-Za-z_]+$' "${f}" ||
      fail "${f#"${REPO_ROOT}/"} no longer shows a commented TZ=Area/City an operator can copy"
    grep -qE '^[[:space:]]*#[[:space:]].*IANA zone name' "${f}" ||
      fail "${f#"${REPO_ROOT}/"} no longer says what TZ is set to"
    grep -qE '^[[:space:]]*#[[:space:]].*Unset and empty are two different things' "${f}" ||
      fail "${f#"${REPO_ROOT}/"} no longer warns that an empty TZ is not the same as an unset one"
  done
}
