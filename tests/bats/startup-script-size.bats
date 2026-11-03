#!/usr/bin/env bats
#
# ## startup-script-size.bats - the startup script has to fit in one execve argument.
#
# The Coder agent runs coder_agent.startup_script as `bash -c <body>`, so the whole
# rendered body travels as a single argument to execve(2). Linux caps one argument at
# MAX_ARG_STRLEN, 32 pages = 131072 bytes, and past that the fork fails outright: the
# agent logs `fork/exec /bin/bash: argument list too long` with exit_code=255 a few
# milliseconds in, the home directory is never seeded, and the workspace banner reads
# "A startup script has failed". Nothing in this repo bounded that, so the payload
# crept for six commits (104 KB, 117 KB, 127 KB, 128 KB, 129 KB, 130 KB) and one
# documentation commit crossed the wall at 135 KB and broke every workspace recreate.
#
# The body is not one file: main.tf composes it from startup.sh.tftpl plus every
# templates/common/ payload it inlines, so any edit to the rulebook, the skills, the
# tmux config, the notes seeder, or the Grok config moves this number. The suite sums
# exactly what main.tf passes and holds it under BOUND, which keeps roughly one
# documentation-sized PR of slack below the ceiling the kernel enforces.
#
# Usage: bazelisk test //tests:bats_startup_script_size_test   (from any cwd)
# Safety: reads the two template twins, their staged payloads, the push guard and its
# awk reader; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

# The kernel's own limit, measured rather than recalled: see the ceiling test below.
readonly ARG_LIMIT=131072
# The budget the twins have to stay inside. 8 KiB of slack under the ceiling is about
# two documentation-sized commits, which is the point: a future addition trips this
# gate in review instead of tripping the agent on someone's workspace.
readonly BOUND=122880

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

# The payload files main.tf inlines into one twin's startup_script, one path per line,
# resolved the way push-template resolves them: a name the template reads through
# ${path.module} is the twin's own file if it keeps one, and the templates/common/
# canonical copy otherwise. A local passed into the block is followed to the file it
# renders, which is how the rendered VS Code settings join the total.
startup_script_sources() {
  local dir="$1"
  local main="${REPO_ROOT}/templates/${dir}/main.tf"
  local block names f resolved

  [ -f "${main}" ] || {
    echo "templates/${dir}/main.tf is gone" >&2
    return 1
  }
  block="$(sed -n '/^  startup_script = templatefile(/,/^  })$/p' "${main}")"
  [ -n "${block}" ] || {
    echo "no startup_script = templatefile(...) block found in templates/${dir}/main.tf" >&2
    return 1
  }

  names="$(printf '%s\n' "${block}" | grep -oE 'path\.module\}/[A-Za-z0-9._-]+"' |
    sed -e 's|path\.module}/||' -e 's|"||' | sort -u)"

  # Names the block takes from a local, and the file that local renders.
  local key target
  while read -r key; do
    [ -n "${key}" ] || continue
    target="$(grep -oE "${key} = (template|)file\(\"\\\$\{path\.module\}/[A-Za-z0-9._-]+\"" "${main}" |
      grep -oE 'path\.module\}/[A-Za-z0-9._-]+"' | sed -e 's|path\.module}/||' -e 's|"||' | head -1)"
    [ -n "${target}" ] && names="$(printf '%s\n%s\n' "${names}" "${target}")"
  done < <(printf '%s\n' "${block}" | grep -oE '[a-z_]+ = local\.[a-z_]+' |
    sed -e 's|.*local\.||' | sort -u)

  while read -r f; do
    [ -n "${f}" ] || continue
    resolved=""
    [ -f "${REPO_ROOT}/templates/${dir}/${f}" ] && resolved="${REPO_ROOT}/templates/${dir}/${f}"
    [ -n "${resolved}" ] || [ ! -f "${REPO_ROOT}/templates/common/${f}" ] || resolved="${REPO_ROOT}/templates/common/${f}"
    if [ -z "${resolved}" ]; then
      echo "${dir}: ${f} is inlined by main.tf and exists in neither the twin nor templates/common/" >&2
      return 1
    fi
    printf '%s\n' "${resolved}"
  done < <(printf '%s\n' "${names}" | sort -u)
}

# Total bytes main.tf would hand to bash for one twin, with the per-file table on
# stdout so a failure explains itself instead of just going red.
composed_bytes() {
  local dir="$1" total=0 f
  while read -r f; do
    [ -n "${f}" ] || continue
    local size
    size="$(wc -c < "${f}")"
    printf '  %7d %s\n' "${size}" "${f#"${REPO_ROOT}/"}"
    total=$((total + size))
  done < <(startup_script_sources "${dir}")
  printf '  %7d TOTAL\n' "${total}"
  printf '%s\n' "${total}" > "${BATS_TEST_TMPDIR}/total-${dir}"
}

@test "startup budget: the ceiling is the kernel's own single-argument limit" {
  # Measure, do not recall: a no-op of exactly BOUND bytes has to exec, and one byte
  # over the documented ceiling must not. If this test goes red the platform moved, and
  # every number in this file needs re-measuring rather than re-guessing.
  local pad
  pad="$(head -c "${BOUND}" /dev/zero | tr '\0' 'a')"
  run bash -c ": '${pad}'"
  [ "${status}" -eq 0 ] || {
    echo "a ${BOUND}-byte script no longer execs: $(printf '%s\n' "${output}" | head -1)" >&2
    return 1
  }

  pad="$(head -c "$((ARG_LIMIT + 1))" /dev/zero | tr '\0' 'a')"
  run bash -c ": '${pad}'"
  [ "${status}" -ne 0 ] || {
    echo "an argument of $((ARG_LIMIT + 1)) bytes execed; the ceiling is not ${ARG_LIMIT}" >&2
    return 1
  }
  [[ "${output}" == *"Argument list too long"* ]]
}

@test "startup budget: the workspace twin fits in one execve argument" {
  composed_bytes workspace
  local total
  total="$(cat "${BATS_TEST_TMPDIR}/total-workspace")"
  [ -n "${total}" ] || return 1
  if [ "${total}" -gt "${BOUND}" ]; then
    echo "templates/workspace startup_script composes to ${total} bytes; the budget is ${BOUND}" >&2
    echo "the agent execs it as one argument and bash dies with E2BIG past ${ARG_LIMIT};" >&2
    echo "move rationale comments out of startup.sh.tftpl into docs/coder-templates.md," >&2
    echo "or move a payload out of the argument entirely (see docs/coder-templates.md)." >&2
    return 1
  fi
  [ "${total}" -lt "${ARG_LIMIT}" ]
}

@test "startup budget: the devcontainer twin fits in one execve argument" {
  composed_bytes devcontainer
  local total
  total="$(cat "${BATS_TEST_TMPDIR}/total-devcontainer")"
  [ -n "${total}" ] || return 1
  if [ "${total}" -gt "${BOUND}" ]; then
    echo "templates/devcontainer startup_script composes to ${total} bytes; the budget is ${BOUND}" >&2
    echo "the agent execs it as one argument and bash dies with E2BIG past ${ARG_LIMIT};" >&2
    echo "move rationale comments out of startup.sh.tftpl into docs/coder-templates.md," >&2
    echo "or move a payload out of the argument entirely (see docs/coder-templates.md)." >&2
    return 1
  fi
  [ "${total}" -lt "${ARG_LIMIT}" ]
}

@test "startup budget: both twins say the limit out loud where the script is composed" {
  local dir
  for dir in workspace devcontainer; do
    grep -qiE 'argument list too long|MAX_ARG_STRLEN|131072' \
      "${REPO_ROOT}/templates/${dir}/main.tf" || {
      echo "templates/${dir}/main.tf never names the exec limit, so the next author" >&2
      echo "grows startup.sh.tftpl blind and finds the ceiling on a live workspace" >&2
      return 1
    }
  done
}

@test "startup budget: the budget is not just below the wall, it has slack" {
  # A bound that sits one byte under the ceiling passes right up to the moment it stops
  # protecting anyone, so assert the margin exists rather than trusting the constant.
  [ $((ARG_LIMIT - BOUND)) -ge 8192 ] || {
    echo "the budget leaves only $((ARG_LIMIT - BOUND)) bytes of slack" >&2
    return 1
  }
}

# --- the push-time guard, checked against the parser above ----------------------
#
# scripts/push-template.sh refuses a template whose exec'd bodies compose past the
# budget, before it ever talks to Coder. That guard parses main.tf a second time, in
# scripts/lib/startup_size.awk, so the two parsers have to be held together or one of
# them rots quietly: the suite would stay green while the gate that protects an operator
# measures something else entirely.

load_production_guard() {
  load_shell_function "${REPO_ROOT}/scripts/lib/common.sh" log
  load_shell_function "${REPO_ROOT}/scripts/lib/common.sh" err
  load_shell_function "${REPO_ROOT}/scripts/lib/common.sh" die
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" startup_size_guard
}

@test "startup budget: the push guard counts the bytes this suite counts" {
  load_production_guard
  local dir total
  for dir in workspace devcontainer; do
    composed_bytes "${dir}"
    total="$(cat "${BATS_TEST_TMPDIR}/total-${dir}")"
    [ -n "${total}" ] || return 1
    # Two probes bracket the guard's own number exactly: a budget equal to this suite's
    # total has to pass, and one byte lower has to fail. Together they say both parsers
    # counted the same bytes, without the guard needing a mode that prints its total.
    export STARTUP_SIZE_BOUND="${total}"
    run startup_size_guard "${REPO_ROOT}/templates/${dir}"
    [ "${status}" -eq 0 ] || {
      echo "${dir}: the guard refused what this suite measured at ${total} bytes" >&2
      printf '%s\n' "${output}" >&2
      return 1
    }
    export STARTUP_SIZE_BOUND=$((total - 1))
    run startup_size_guard "${REPO_ROOT}/templates/${dir}"
    unset STARTUP_SIZE_BOUND
    [ "${status}" -eq 1 ] || {
      echo "${dir}: the guard accepted ${total} bytes under a budget of $((total - 1))," >&2
      echo "so its parser counts fewer bytes than this suite's" >&2
      return 1
    }
  done
}

@test "startup budget: every body the agent execs fits, coder_script bodies included" {
  load_production_guard
  local dir bodies
  for dir in workspace devcontainer; do
    # The startup script is not the whole story: each coder_script body is its own
    # execve and gets its own ceiling. At the shipped budget every body has to pass.
    export STARTUP_SIZE_BOUND="${BOUND}"
    run startup_size_guard "${REPO_ROOT}/templates/${dir}"
    unset STARTUP_SIZE_BOUND
    [ "${status}" -eq 0 ] || {
      echo "${dir}: a body crossed the ${BOUND}-byte budget" >&2
      printf '%s\n' "${output}" >&2
      return 1
    }
    # And the pass has to mean more than one body, or this test would still pass if the
    # guard had silently stopped looking at anything but the startup script.
    bodies="$(awk -f "${REPO_ROOT}/scripts/lib/startup_size.awk" \
      "${REPO_ROOT}/templates/${dir}/main.tf" | cut -f1 | sort -u | grep -cv '^startup\.sh\.tftpl$')"
    [ "${bodies}" -gt 0 ] || {
      echo "${dir}: no coder_script body was measured, so the pass proved nothing" >&2
      return 1
    }
  done
}

@test "startup budget: the guard carries this suite's numbers and runs on every push" {
  local src="${REPO_ROOT}/scripts/push-template.sh"
  # The two constants live in the guard and in this file. Pinned by text so drift is a
  # red test here rather than a gate that quietly stops matching the kernel.
  grep -Fq "STARTUP_SIZE_BOUND:-${BOUND}}" "${src}" || {
    echo "the push guard's budget is no longer ${BOUND}" >&2
    return 1
  }
  grep -Fq "STARTUP_ARG_LIMIT:-${ARG_LIMIT}}" "${src}" || {
    echo "the push guard no longer names the ${ARG_LIMIT}-byte ceiling" >&2
    return 1
  }
  # A guard nobody calls protects nothing, and the per-template loop is the only caller.
  grep -Fq 'startup_size_guard "${dir}"' "${src}" || {
    echo "startup_size_guard is defined but never called from the push loop" >&2
    return 1
  }
}

