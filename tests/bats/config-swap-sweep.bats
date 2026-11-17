#!/usr/bin/env bats
#
# ## config-swap-sweep.bats - the boot clears an orphaned vim swap, never a live one.
#
# ~/.grok is one persistent per-owner volume, so a vim that a workspace stop killed
# leaves its .config.toml.swp behind, and the next `vim ~/.grok/config.toml` stops on
# E325 asking about a session whose container is long gone. The operator answers that
# prompt by hand on every boot, and answering "(E)dit anyway" leaves the swap in place
# and mints another beside it, so the home accumulates .swp/.swo/.swn/.swm and the
# prompt never goes away.
#
# grok_sweep_config_swaps rides coder_script.agents_seed's body rather than
# startup.sh.tftpl for two reasons. The startup argument is under a byte gate
# (//tests:bats_startup_script_size_test) that keeps 12 KiB free under the kernel's
# one-argument ceiling, and this body has its own ceiling and room; and the seed body is
# already the place where a stack-owned file under ~/.grok is refreshed against its
# marker on every start. It runs after the blocking startup script, so by the time it
# looks, the boot has already re-rendered config.toml and anything a leftover swap holds
# describes bytes that no longer exist.
#
# The two hazards are a swap still in use and a swap of some other file, so both are
# pinned here: a holder's open descriptor and an mtime inside the hour keep the file,
# and only vim's own `.sw?` suffix on that one name is ever a candidate. The descriptor
# check sees this container's processes, which is why the age check has to stand beside
# it - a sibling workspace shares the volume and its editor is invisible from here. And
# a config.toml whose marker a person deleted is theirs, swap and all.
#
# Usage: bazelisk test //tests:bats_config_swap_sweep_test   (from any cwd)
# Safety: drives the extracted function against scratch homes under BATS_TEST_TMPDIR;
# writes nothing outside them and never touches the real ~/.grok.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
BODY=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  BODY="${REPO_ROOT}/templates/common/agents-seed.sh.tftpl"
  [ -f "${BODY}" ] || skip "the agents_seed body is absent"
}

# run_sweep <home> - run the real body with HOME pointed at a scratch tree. run keeps
# the function's own report in ${output}.
run_sweep() {
  run bash -c "HOME='${1}'; source <(python3 '${REPO_ROOT}/tests/extract_fn.py' '${BODY}' grok_sweep_config_swaps); grok_sweep_config_swaps"
}

# new_swap <home> <name> [age] - one swap file in <home>/.grok, backdated by <age>.
new_swap() {
  local home="${1}" name="${2}" age="${3:-2 days ago}"
  mkdir -p "${home}/.grok"
  printf 'VIM swap fixture\n' > "${home}/.grok/${name}"
  touch -d "${age}" "${home}/.grok/${name}"
}

# manage <home> <stack|person> - what the config beside the swap claims to be.
manage() {
  mkdir -p "${1}/.grok"
  if [ "${2}" = "stack" ]; then
    printf '__evoT1Stack = true\n' > "${1}/.grok/config.toml"
  else
    printf '# the operator wrote this one\n' > "${1}/.grok/config.toml"
  fi
}

# names_in <home> - every name left in <home>/.grok, so a case proves the sweep took
# exactly what it should and nothing else, rather than only what it took.
names_in() {
  find "${1}/.grok" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '
}

@test "swap sweep: both twins still consume the body that carries it" {
  local dir
  for dir in workspace devcontainer; do
    grep -qF 'script = templatefile("${path.module}/agents-seed.sh.tftpl"' \
      "${REPO_ROOT}/templates/${dir}/main.tf" || {
      echo "templates/${dir}: agents_seed no longer runs this body, so the sweep never runs there" >&2
      return 1
    }
  done
}

@test "swap sweep: it is called, and it stays off the startup argument" {
  local twin
  grep -qF 'grok_sweep_config_swaps || true' "${BODY}" || {
    echo "the body defines the sweep and never calls it" >&2
    return 1
  }
  # Column 0 is what lets this gate drive the body the boot ships.
  grep -qF 'grok_sweep_config_swaps() {' "${BODY}"
  # The startup twins are under a byte gate that has no room left for it; a copy that
  # crept in there would be paid for twice and would fail //:test-fast, not just here.
  for twin in workspace devcontainer; do
    ! grep -q 'grok_sweep_config_swaps' "${REPO_ROOT}/templates/${twin}/startup.sh.tftpl" || {
      echo "templates/${twin}/startup.sh.tftpl now carries the sweep a second time" >&2
      return 1
    }
  done
}

@test "swap sweep: an orphaned swap of a stack-owned config goes, in every vim extension" {
  local home="${BATS_TEST_TMPDIR}/orphan"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  new_swap "${home}" .config.toml.swo
  new_swap "${home}" .config.toml.swn
  new_swap "${home}" .config.toml.swm
  run_sweep "${home}"
  # A boot that deletes a file the operator can see says so: a silent removal here
  # reads exactly like the stack eating someone's work.
  assert_match "one report per removal" 'Removed the stale editor swap' "${output}"
  assert_eq "every orphan is gone" "config.toml " "$(names_in "${home}")"
}

@test "swap sweep: a swap written in the last hour stays" {
  local home="${BATS_TEST_TMPDIR}/fresh"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp "now"
  run_sweep "${home}"
  assert_eq "a session that may be live keeps its swap" ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_not_match "and the boot says nothing about it" 'Removed' "${output}"
}

@test "swap sweep: a swap an open descriptor holds stays" {
  local home="${BATS_TEST_TMPDIR}/held"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  # The holder has to be a process the function can find under /proc, which is the
  # question it actually asks. An fd open in this shell is exactly that.
  exec 9< "${home}/.grok/.config.toml.swp"
  load_shell_function "${BODY}" grok_sweep_config_swaps
  HOME="${home}" grok_sweep_config_swaps
  exec 9<&-
  assert_eq "a live editor keeps its swap" ".config.toml.swp config.toml " "$(names_in "${home}")"
}

@test "swap sweep: a swap of any other file, or a non-vim suffix, is left alone" {
  local home="${BATS_TEST_TMPDIR}/others"
  manage "${home}" stack
  new_swap "${home}" .notes.md.swp
  new_swap "${home}" .tmux.conf.swp
  new_swap "${home}" .config.toml.newswp
  new_swap "${home}" .config.toml.old
  run_sweep "${home}"
  assert_eq "only that one name's vim swaps are candidates" \
    ".config.toml.newswp .config.toml.old .notes.md.swp .tmux.conf.swp config.toml " \
    "$(names_in "${home}")"
}

@test "swap sweep: a config the stack does not own keeps its swap" {
  local home="${BATS_TEST_TMPDIR}/unmanaged"
  manage "${home}" person
  new_swap "${home}" .config.toml.swp
  run_sweep "${home}"
  assert_eq "the operator's file is not ours to tidy" \
    ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_not_match "and nothing is announced" 'Removed' "${output}"
}

@test "swap sweep: a missing config.toml is not an error, and costs the boot nothing" {
  local home="${BATS_TEST_TMPDIR}/noconfig"
  mkdir -p "${home}/.grok"
  new_swap "${home}" .config.toml.swp
  run_sweep "${home}"
  [ "${status}" -eq 0 ] || {
    echo "a home with no config.toml made the boot fail: rc=${status}" >&2
    return 1
  }
  assert_eq "and the swap is left for a person to decide on" ".config.toml.swp " "$(names_in "${home}")"

  # The clean case: no swaps at all must not turn an unmatched glob into a failing body.
  local clean="${BATS_TEST_TMPDIR}/clean"
  mkdir -p "${clean}/.grok"
  manage "${clean}" stack
  run_sweep "${clean}"
  assert_eq "no swaps, no output" "" "${output}"
  [ "${status}" -eq 0 ] || {
    echo "an unmatched glob made the boot fail: rc=${status}" >&2
    return 1
  }
}
