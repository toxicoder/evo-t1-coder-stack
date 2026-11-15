#!/usr/bin/env bats
#
# ## tftpl_interpolation.bats - the coder_script bodies interpolate only what main.tf passes
#
# Usage: bazelisk test //tests:bats_tftpl_interpolation_test   (from any cwd)
# Safety: no daemon, no network. The render tier runs a providerless terraform config in the
#         test's own tmpdir with CHECKPOINT_DISABLE=1, and skips when terraform is not really
#         on PATH.
#
# Why this suite exists: templatefile() reads a single-dollar brace reference anywhere in a
# body - a for-loop, a comment, anywhere - as an interpolation, and the plan then dies with
# "vars map does not contain key". That is what a pushed template looked like when a fleet
# seed body named its own loop variable that way: both twins failed the push, and no gate
# had noticed, because every earlier check compared the body's text against a literal and
# never asked what the caller's map actually declares.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CHECKER=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CHECKER="${REPO_ROOT}/scripts/lib/tftpl_interpolation.py"
  [[ -f ${CHECKER} ]] || skip "scripts/lib/tftpl_interpolation.py is not in the tree"
}

# one_pair <dir> <body-name> <map-entries> <body-text>
#
# A main.tf with a single templatefile() call and the body it names, which is the smallest
# tree the checker can be pointed at. The body arrives as one argument, newlines included.
one_pair() {
  local dir="$1" body_name="$2" entries="$3" body="$4"
  mkdir -p "${dir}"
  {
    printf '%s\n' 'resource "coder_script" "probe" {'
    printf '%s\n' "  script = templatefile(\"\${path.module}/${body_name}\", {"
    printf '%s\n' "${entries}"
    printf '%s\n' '  })'
    printf '%s\n' '}'
  } >"${dir}/main.tf"
  printf '%s\n' "${body}" >"${dir}/${body_name}"
}

@test "checker: the shipped twins interpolate only names their main.tf declares" {
  run python3 "${CHECKER}" "${REPO_ROOT}/templates"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"0 failed"* ]]
  [[ ${output} == *"call(s) checked"* ]]
}

@test "checker: the shipped twins declare no key their body stopped using" {
  # Drift in the other direction: a key main.tf still feeds a body that dropped it is a
  # payload that stopped landing in the workspace, which is the same accident wearing a
  # quieter hat. --strict is the form the gate should run.
  run python3 "${CHECKER}" "${REPO_ROOT}/templates" --strict
  [ "${status}" -eq 0 ]
  [[ ${output} == *"0 failed"* ]]
}

@test "checker: a bare shell variable in a body names the call that renders it" {
  local pair="${BATS_TEST_TMPDIR}/bare"
  one_pair "${pair}" "body.sh.tftpl" "    payload = \"x\"" \
    '#!/bin/sh
set -u
for evo_t1_root in a b; do
  [ -L "${evo_t1_root}" ] && exit 0
done
printf %s "${payload}"'
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"evo_t1_root"* ]]
  [[ ${output} == *"passes no such key"* ]]
  [[ ${output} == *"1 failed"* ]]
}

@test "checker: the double-dollar escape keeps a shell variable out of the plan" {
  local pair="${BATS_TEST_TMPDIR}/escaped"
  one_pair "${pair}" "body.sh.tftpl" "    payload = \"x\"" \
    '#!/bin/sh
set -u
for evo_t1_root in a b; do
  [ -L "$${evo_t1_root}" ] && exit 0
done
printf %s "${payload}"'
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"1 call(s) checked, 0 warnings, 0 failed"* ]]
}

@test "checker: the fleet body carries the escape its plan needs" {
  # The regression, pinned at the file that shipped the defect: the loop variable is read
  # through the escape, and no single-dollar form of it survives anywhere in the body.
  local body="${REPO_ROOT}/templates/common/stack-fleet.sh.tftpl"
  run grep -F -- '"$${evo_t1_root}"' "${body}"
  [ "${status}" -eq 0 ]
  run grep -F -- '"${evo_t1_root}"' "${body}"
  [ "${status}" -ne 0 ]
}

@test "checker: a directive reads its condition from the map and a for-loop binds its own" {
  local pair="${BATS_TEST_TMPDIR}/directives"
  one_pair "${pair}" "body.txt.tftpl" "    flag = \"x\"
    pairs = \"y\"" \
    '%{ if flag ~}on%{ endif ~}
%{ for k, v in pairs ~}${k}=${v}
%{ endfor ~}'
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 0 ]

  # The same body with a condition nobody declares is the failure the plan would report.
  one_pair "${pair}" "body.txt.tftpl" "    pairs = \"y\"" \
    '%{ if flag ~}on%{ endif ~}
%{ for k, v in pairs ~}${k}=${v}
%{ endfor ~}'
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"'flag'"* ]]
}

@test "checker: an unused key warns, and --strict makes it the failure" {
  local pair="${BATS_TEST_TMPDIR}/unused"
  one_pair "${pair}" "body.txt.tftpl" "    used = \"x\"
    dropped = \"y\"" 'text ${used}'
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"warning:"* ]]
  [[ ${output} == *"'dropped'"* ]]
  run python3 "${CHECKER}" "${pair}" --strict
  [ "${status}" -eq 1 ]
  [[ ${output} == *"1 failed"* ]]
}

@test "checker: --list puts one row per call on stdout and the prose on stderr" {
  local pair="${BATS_TEST_TMPDIR}/listing"
  one_pair "${pair}" "body.txt.tftpl" "    alpha = \"x\"
    beta  = \"y\"" '${alpha}${beta}'
  run python3 "${CHECKER}" "${pair}" --list
  [ "${status}" -eq 0 ]
  # One tab-separated row: <tf path> <line> <body path> <keys>
  [ "$(printf '%s\n' "${output}" | awk 'END { print NR }')" -eq 1 ]
  [[ ${output} == *$'\t'* ]]
  [[ ${output} == *"body.txt.tftpl"* ]]
  [[ ${output} == *"alpha,beta"* ]]
  run python3 "${CHECKER}" "${pair}" --list 2>/dev/null
  [[ ${output} != *"summary:"* ]]
}

@test "checker: a templatefile() that lives only in a comment or a heredoc is not a call" {
  local pair="${BATS_TEST_TMPDIR}/masked"
  mkdir -p "${pair}"
  printf '%s\n' \
    '# templatefile("${path.module}/commented.sh.tftpl", {' \
    '// templatefile("${path.module}/slashed.sh.tftpl", {' \
    '/* templatefile("${path.module}/blocked.sh.tftpl", { */' \
    'prose = <<-EOT' \
    '  templatefile("${path.module}/heredoc.sh.tftpl", {' \
    '  EOT' \
    'resource "coder_script" "probe" {' \
    '  script = templatefile("${path.module}/real.sh.tftpl", {' \
    '    payload = "x"' \
    '  })' \
    '}' >"${pair}/main.tf"
  printf '%s\n' '#!/bin/sh' 'echo "${payload}"' >"${pair}/real.sh.tftpl"
  run python3 "${CHECKER}" "${pair}" --list
  [ "${status}" -eq 0 ]
  [[ ${output} == *"real.sh.tftpl"* ]]
  [[ ${output} != *"commented"* ]]
  [[ ${output} != *"slashed"* ]]
  [[ ${output} != *"blocked"* ]]
  [[ ${output} != *"heredoc"* ]]
}

@test "checker: an indented heredoc terminator hides nothing below it" {
  # The mask that skips heredoc bodies has to find a <<- terminator that is indented, or
  # every call after the first heredoc disappears from the gate and the gate reports all
  # clean, which is the loudest way for a gate to be wrong.
  local pair="${BATS_TEST_TMPDIR}/indented"
  mkdir -p "${pair}"
  printf '%s\n' \
    'locals {' \
    '  note = <<-EOT' \
    '    indented body with a } and a { inside' \
    '    EOT' \
    '}' \
    'resource "coder_script" "probe" {' \
    '  script = templatefile("${path.module}/after.sh.tftpl", {' \
    '    payload = "x"' \
    '  })' \
    '}' >"${pair}/main.tf"
  printf '%s\n' '#!/bin/sh' 'echo "${payload}"' >"${pair}/after.sh.tftpl"
  run python3 "${CHECKER}" "${pair}" --list
  [ "${status}" -eq 0 ]
  [[ ${output} == *"after.sh.tftpl"* ]]
}

@test "checker: a call it cannot read is an error and never a silence" {
  local pair="${BATS_TEST_TMPDIR}/unreadable"
  mkdir -p "${pair}"

  # A body nobody can locate.
  printf '%s\n' 'script = templatefile("${path.module}/gone.sh.tftpl", {' '  a = "x"' '})' \
    >"${pair}/main.tf"
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"no body found"* ]]

  # A path built at plan time: the key set cannot be settled here, so it is refused.
  printf '%s\n' 'script = templatefile("${path.module}/${name}.sh.tftpl", {' '  a = "x"' '})' \
    >"${pair}/main.tf"
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"built dynamically"* ]]

  # A path that is not a plain string literal.
  printf '%s\n' 'script = templatefile(local.body_path, {' '  a = "x"' '})' >"${pair}/main.tf"
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"not a plain string"* ]]
}

@test "checker: a body no call reaches is a finding, not an orphan in the tree" {
  local pair="${BATS_TEST_TMPDIR}/orphan"
  one_pair "${pair}" "used.txt.tftpl" "    payload = \"x\"" 'text ${payload}'
  mkdir -p "${pair}"
  printf '%s\n' 'echo "${nobody_passes_me}"' >"${pair}/stale.txt.tftpl"
  run python3 "${CHECKER}" "${pair}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"no templatefile() call under"* ]]
  [[ ${output} == *"stale.txt.tftpl"* ]]
}

@test "checker: usage refuses a missing argument and a path that is not a directory" {
  run python3 "${CHECKER}"
  [ "${status}" -eq 2 ]
  run python3 "${CHECKER}" "${BATS_TEST_TMPDIR}/no-such-dir"
  [ "${status}" -eq 2 ]
}

@test "render: every body renders through terraform and each shell body parses" {
  # The plan-time half of the check, run for real: a uniform string for every declared key
  # (HCL coerces it where a body asks for a bool), one providerless config, one apply, then
  # the emitted script goes through the parser named on its own shebang line. Terraform is
  # the only judge of a malformed interpolation - ${...} and ${a b} both read as no names
  # at all to a text scan - so the bodies the checker reasons about are rendered here too.
  local tf_bin
  tf_bin="$(real_bin terraform)"
  if [ -z "${tf_bin}" ]; then
    skip "terraform is not on PATH, so there is nothing to render with"
  fi

  local dir="${BATS_TEST_TMPDIR}/render"
  mkdir -p "${dir}"
  python3 "${CHECKER}" "${REPO_ROOT}/templates" --list 2>/dev/null |
    awk -F'\t' '
      BEGIN { print "locals {" }
      !seen[$3]++ {
        n++
        name = sprintf("r%03d", n)
        printf "%s\t%s\n", name, $3 > (dir "/map.tsv")
        printf "  %s = templatefile(\"%s\", {\n", name, $3
        nk = split($4, keys, ",")
        for (i = 1; i <= nk; i++) printf "    %s = \"true\"\n", keys[i]
        printf "  })\n"
        outs[n] = name
      }
      END {
        print "}"
        for (i = 1; i <= n; i++) printf "output \"%s\" { value = local.%s }\n", outs[i], outs[i]
      }
    ' dir="${dir}" >"${dir}/main.tf"
  [ -s "${dir}/main.tf" ]
  [ -s "${dir}/map.tsv" ]

  export CHECKPOINT_DISABLE=1
  local out
  out="$(cd "${dir}" && "${tf_bin}" init -backend=false -input=false 2>&1)" || {
    printf '%s\n' "${out}" >&2
    return 1
  }
  out="$(cd "${dir}" && "${tf_bin}" apply -auto-approve -input=false 2>&1)" || {
    printf '%s\n' "${out}" >&2
    return 1
  }

  local name body rendered interp
  while IFS=$'\t' read -r name body; do
    rendered="$(cd "${dir}" && "${tf_bin}" output -raw "${name}" 2>&1)" || {
      printf '%s\n' "${name}: ${rendered}" >&2
      return 1
    }
    [ -n "${rendered}" ]
    # Only a shell body has a parser to face; a config body is judged by rendering
    # without error alone.
    [[ ${body} == *.sh.tftpl ]] || continue
    interp=bash
    [[ $(printf '%s\n' "${rendered}" | head -1) == '#!/bin/sh' ]] && interp=sh
    printf '%s\n' "${rendered}" >"${dir}/${name}.sh"
    if ! "${interp}" -n "${dir}/${name}.sh"; then
      printf '%s: rendered body does not parse with %s\n' "${body}" "${interp}" >&2
      return 1
    fi
  done <"${dir}/map.tsv"
}

@test "render: the fleet body still emits its loop variable as shell text" {
  # The escape has to survive the render. A body that lost it fails the plan upstream; a
  # body that over-escaped would land in the workspace with a literal $${...} in the shell
  # and every guard in it would test the wrong string.
  local tf_bin
  tf_bin="$(real_bin terraform)"
  if [ -z "${tf_bin}" ]; then
    skip "terraform is not on PATH, so there is nothing to render with"
  fi

  local dir="${BATS_TEST_TMPDIR}/fleet"
  mkdir -p "${dir}"
  {
    printf '%s\n' 'locals {'
    printf '%s\n' '  fleet = templatefile("'${REPO_ROOT}'/templates/common/stack-fleet.sh.tftpl", {'
    printf '%s\n' '    explorer_agent               = "EXPLORER"' \
      '    architect_agent              = "ARCHITECT"' \
      '    implementer_agent            = "IMPLEMENTER"' \
      '    tester_agent                 = "TESTER"' \
      '    reviewer_agent               = "REVIEWER"' \
      '    security_auditor_agent       = "AUDITOR"' \
      '    thorough_researcher_persona  = "RESEARCHER"' \
      '    senior_implementer_persona   = "SENIOR"' \
      '    skeptical_reviewer_persona   = "SKEPTIC"' \
      '    feature_implementation_skill = "FEATURE"' \
      '    skeptical_review_skill       = "SKEPTICAL"' \
      '    security_audit_skill         = "AUDIT"' \
      '    bug_hunt_skill               = "BUGHUNT"'
    printf '%s\n' '  })'
    printf '%s\n' '}'
    printf '%s\n' 'output "fleet" { value = local.fleet }'
  } >"${dir}/main.tf"

  export CHECKPOINT_DISABLE=1
  (cd "${dir}" && "${tf_bin}" init -backend=false -input=false >/dev/null 2>&1) || return 1
  local rendered
  rendered="$(cd "${dir}" && "${tf_bin}" apply -auto-approve -input=false >/dev/null 2>&1 &&
    "${tf_bin}" output -raw fleet 2>&1)" || {
    printf '%s\n' "${rendered}" >&2
    return 1
  }
  [[ ${rendered} == *'if [ -L "${evo_t1_root}" ]; then'* ]]
  [[ ${rendered} != *'$${'* ]]
  [[ ${rendered} == *'EXPLORER'* ]]
  [[ ${rendered} == *'BUGHUNT'* ]]
}
