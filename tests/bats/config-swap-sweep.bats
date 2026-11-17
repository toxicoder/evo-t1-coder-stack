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
# (//tests:bats_startup_script_size_test) that holds the composed body to 110592 bytes -
# 12288 of room under the 122880 budget the repo sets itself, which is 8 KiB under the
# kernel's measured 131072 one-argument ceiling - and the devcontainer twin composes
# 110242 of that, so it has 350 bytes left and no payload of this size fits there; and
# the seed body is already the place where a stack-owned file under ~/.grok is refreshed
# against its marker on every start. It argues from that marker rather than from
# ordering, because a coder_script runs in no promised order with the startup script
# (templates/workspace/coder.tf:272): a config that still carries the marker is one every
# start replaces, whichever of the two bodies runs first.
#
# What makes this step safe is that it never destroys anything it cannot prove. Neither
# of its two orphan tests proves a writer is gone: vim writes the swap once about four
# seconds after a change and then stays quiet, so an idle live session is
# indistinguishable from a crashed one, which is why the hour is courtesy toward another
# container's session and not evidence; and each workspace has its own PID namespace, so
# the descriptor scan sees this container's processes only. So a file the sweep judges
# orphaned is moved into ~/.grok/stale-swaps and stays recoverable, and every path that
# cannot decide - a probe that errors, a target it cannot move - leaves the swap exactly
# where it is for a person to answer by hand. Pinned below: a holder's open descriptor,
# an mtime inside the hour, a failing probe, an unwritable archive directory, and any
# name that is not vim's own single-suffix `.sw?` on that one file all keep the file.
# And a config.toml whose marker a person deleted is theirs, swap and all.
#
# These cases drive the .tftpl's own text, not a render, so the body stays free of braced
# shell expansion: that is the one form whose meaning shifts across templatefile(), and
# the pin below is what keeps the two readings of it identical.
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

# archived <home> - what landed in the recover directory, contents only. A sweep that
# "cleared" the swap by deleting it would show an empty list here.
archived() {
  local dir="${1}/.grok/stale-swaps"
  [ -d "${dir}" ] || {
    printf '(none)\n'
    return
  }
  find "${dir}" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '
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

@test "swap sweep: the twins still run that seed on every start" {
  # run_on_start is what makes this boot-time, and the whole point of the sweep is that
  # it fires without the operator asking. Flipping it false leaves every other case here
  # green, because they drive the function directly - so pin the wiring too.
  local dir block
  for dir in workspace devcontainer; do
    block="$(awk '/^resource "coder_script" "agents_seed" \{/,/^\}/' \
      "${REPO_ROOT}/templates/${dir}/main.tf")"
    [ -n "${block}" ] || {
      echo "templates/${dir}: no coder_script \"agents_seed\" block to read" >&2
      return 1
    }
    printf '%s\n' "${block}" | grep -qE '^[[:space:]]*run_on_start[[:space:]]*=[[:space:]]*true' || {
      echo "templates/${dir}: agents_seed lost run_on_start = true, so a stale swap survives boot" >&2
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

@test "swap sweep: the body stays in the subset that means the same thing rendered and raw" {
  # Every case here drives the body's own text through bash, which is what caught a
  # `$${grok_swap##*/}` that only made sense after Terraform rendered it: raw, the shell
  # got the pattern's own slash and the move silently failed. A braced shell expansion is
  # the one form whose meaning changes across the render, so this body uses none. The
  # alternatives are the ones that mean the same thing both ways - basename, cut, or a
  # loop over the candidates.
  ! grep -q '\$\${' "${BODY}" || {
    echo "the body has a braced shell expansion again; the raw-text cases here would" >&2
    echo "disagree with what the boot runs. Use basename or a candidate loop instead." >&2
    return 1
  }
}

@test "swap sweep: an orphaned swap of a stack-owned config moves aside, in every vim extension" {
  local home="${BATS_TEST_TMPDIR}/orphan"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  new_swap "${home}" .config.toml.swo
  new_swap "${home}" .config.toml.swn
  new_swap "${home}" .config.toml.swm
  run_sweep "${home}"
  # A boot that relocates a file the operator can see says so: a silent move here reads
  # exactly like the stack eating someone's work.
  assert_match "one report per move" 'Moved the stale editor swap' "${output}"
  assert_eq "the E325 prompt is clear of them" "config.toml stale-swaps " "$(names_in "${home}")"
  # Recoverable is the contract: the bytes still exist, so a wrong orphan call is undone
  # by an ls and a `vim -r`, and a step that had deleted them fails this line.
  local kept
  kept="$(archived "${home}")"
  for suffix in swp swo swn swm; do
    case " ${kept} " in
      *" .config.toml.${suffix}.orphan."*) ;;
      *)
        echo "stale-swaps holds '${kept}'; .config.toml.${suffix} is not in it" >&2
        return 1
        ;;
    esac
  done
  grep -q 'VIM swap fixture' "${home}/.grok/stale-swaps/.config.toml.swp.orphan."* || {
    echo "the archived swap is not the file's own bytes" >&2
    return 1
  }
}

@test "swap sweep: a swap written in the last hour stays" {
  local home="${BATS_TEST_TMPDIR}/fresh"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp "now"
  run_sweep "${home}"
  assert_eq "a session that may be live keeps its swap" ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_not_match "and the boot says nothing about it" 'Moved the stale editor swap' "${output}"
  assert_eq "and nothing is archived" "(none)" "$(archived "${home}")"
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
  assert_eq "and nothing reached the archive" "(none)" "$(archived "${home}")"
}

@test "swap sweep: the descriptor check compares the path as a string, never as a glob" {
  # -lname matched the descriptor target against a *pattern*, so one bracket in $HOME -
  # a scratch dir, a checkout with a bracket in it - made a live holder invisible and the
  # sweep moved a swap out from under an editor that still had it open. Replace the exact
  # string comparison with -lname and this case is the one that catches it.
  local home="${BATS_TEST_TMPDIR}/ho[me]x"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  exec 9< "${home}/.grok/.config.toml.swp"
  load_shell_function "${BODY}" grok_sweep_config_swaps
  HOME="${home}" grok_sweep_config_swaps
  exec 9<&-
  assert_eq "a holder behind a glob metacharacter still holds its swap" \
    ".config.toml.swp config.toml " "$(names_in "${home}")"
}

@test "swap sweep: a swap of any other file, or a non-vim suffix, is left alone" {
  local home="${BATS_TEST_TMPDIR}/others"
  manage "${home}" stack
  new_swap "${home}" .notes.md.swp
  new_swap "${home}" .tmux.conf.swp
  new_swap "${home}" .config.toml.newswp
  new_swap "${home}" .config.toml.old
  # The suffix mutation probe: vim's own names are `.sw?` with exactly one letter, so a
  # longer tail is somebody else's file. Widen the glob to `.sw*` and this row is the one
  # that fails.
  new_swap "${home}" .config.toml.swxyz
  run_sweep "${home}"
  assert_eq "only that one name's vim swaps are candidates" \
    ".config.toml.newswp .config.toml.old .config.toml.swxyz .notes.md.swp .tmux.conf.swp config.toml " \
    "$(names_in "${home}")"
}

@test "swap sweep: a config the stack does not own keeps its swap" {
  local home="${BATS_TEST_TMPDIR}/unmanaged"
  manage "${home}" person
  new_swap "${home}" .config.toml.swp
  run_sweep "${home}"
  assert_eq "the operator's file is not ours to tidy" \
    ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_not_match "and nothing is announced" 'Moved the stale editor swap' "${output}"
}

@test "swap sweep: a failing probe leaves the swap in place" {
  # The fail-closed half of the design: an age check that cannot answer is a reason to
  # keep the file, never a reason to move it. Drop the `|| continue` after the find and
  # this case turns red.
  local home="${BATS_TEST_TMPDIR}/probe-fails"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  local stub="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${stub}"
  printf '#!/bin/sh\nexit 1\n' > "${stub}/find"
  chmod 755 "${stub}/find"
  run bash -c "HOME='${home}'; PATH='${stub}:${PATH}'; source <(python3 '${REPO_ROOT}/tests/extract_fn.py' '${BODY}' grok_sweep_config_swaps); grok_sweep_config_swaps"
  assert_eq "a probe that errors costs the swap nothing" ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_eq "and nothing reached the archive" "(none)" "$(archived "${home}")"

  # Same again with the age check answering and the move blocked: an archive directory
  # that cannot be made is a reason to leave the file where the operator can find it.
  local blocked="${BATS_TEST_TMPDIR}/archive-blocked"
  manage "${blocked}" stack
  new_swap "${blocked}" .config.toml.swp
  printf 'a person had this name first\n' > "${blocked}/.grok/stale-swaps"
  run_sweep "${blocked}"
  assert_eq "an unwritable archive keeps the swap in place" \
    ".config.toml.swp config.toml stale-swaps " "$(names_in "${blocked}")"
  assert_not_match "and the boot does not claim a move it did not make" \
    'Moved the stale editor swap' "${output}"
  grep -q 'a person had this name first' "${blocked}/.grok/stale-swaps" || {
    echo "the sweep overwrote something that already owned that name" >&2
    return 1
  }
}

@test "swap sweep: the archive is kept, and only for a month" {
  local home="${BATS_TEST_TMPDIR}/prune"
  manage "${home}" stack
  mkdir -p "${home}/.grok/stale-swaps"
  printf 'old\n' > "${home}/.grok/stale-swaps/.config.toml.swp.orphan.111"
  printf 'new\n' > "${home}/.grok/stale-swaps/.config.toml.swo.orphan.222"
  touch -d '40 days ago' "${home}/.grok/stale-swaps/.config.toml.swp.orphan.111"
  touch -d '2 days ago' "${home}/.grok/stale-swaps/.config.toml.swo.orphan.222"
  run_sweep "${home}"
  assert_eq "a month-old orphan nobody claimed is junk; this month's is evidence" \
    ".config.toml.swo.orphan.222 " "$(archived "${home}")"

  # And the sweep still works with no archive yet: the prune must not turn a missing
  # directory into a failing boot.
  local fresh="${BATS_TEST_TMPDIR}/prune-none"
  manage "${fresh}" stack
  run_sweep "${fresh}"
  [ "${status}" -eq 0 ] || {
    echo "a home with no archive yet made the boot fail: rc=${status}" >&2
    return 1
  }
  assert_eq "and it built nothing" "(none)" "$(archived "${fresh}")"
}

@test "swap sweep: a move that cannot happen leaves the swap and stays quiet" {
  # The report has to be earned: an announcement of a move that mv refused is the one
  # outcome worse than silence, because the operator then looks in stale-swaps for a
  # file that is still sitting in .grok. Stub mv to fail and both halves of that are
  # checked - the file stays, and no report is printed.
  local home="${BATS_TEST_TMPDIR}/mv-fails"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  local stub="${BATS_TEST_TMPDIR}/mv-stub"
  mkdir -p "${stub}"
  printf '#!/bin/sh\nexit 1\n' > "${stub}/mv"
  chmod 755 "${stub}/mv"
  run bash -c "HOME='${home}'; PATH='${stub}:${PATH}'; source <(python3 '${REPO_ROOT}/tests/extract_fn.py' '${BODY}' grok_sweep_config_swaps); grok_sweep_config_swaps"
  assert_eq "a refused move leaves the swap where it was" \
    ".config.toml.swp config.toml stale-swaps " "$(names_in "${home}")"
  assert_not_match "and the boot claims no move it did not make" \
    'Moved the stale editor swap' "${output}"
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
