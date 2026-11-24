#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## workspace-tz.bats - the workspace boot resolves one zone and applies it.
#
# Nothing in the stack ever set a timezone, so every workspace answered in the
# golden image's default while the stack host ran on its own zone: date, the
# terminals the agent opens, and the agent process itself all read the container's
# localtime, which no boot stage had touched. Two halves are pinned here.
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
