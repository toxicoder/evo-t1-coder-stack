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
# What makes the step safe is that it destroys nothing it cannot prove, and neither of its
# two orphan tests proves a writer is gone. vim writes the swap once about four seconds
# after a change and then stays quiet, so an idle live session is indistinguishable from a
# crashed one, which makes the hour a courtesy toward another container's session rather
# than evidence; and each workspace has its own PID namespace, so the descriptor scan sees
# this container's processes only. So what the sweep judges orphaned is moved into
# ~/.grok/stale-swaps under a name it gives itself, re-dated to the moment it was set down
# so the month of recovery is real, and every path that cannot decide - a probe that
# errors, a scan with nothing to read, a target it cannot move - leaves the swap exactly
# where it is for a person to answer by hand. Pinned below: a holder's open descriptor, an
# mtime inside the hour, a symlink, a missing or failing probe, an unreadable descriptor
# tree, an unwritable archive directory, a refused move, an archive name already taken, and
# any name that is not vim's own single-suffix `.sw?` on that one file all keep the file.
# A config.toml that carries neither stack marker is the operator's, swap and all.
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

# run_sweep <home> [path_prefix] - run the real body with HOME pointed at a scratch tree.
# An optional prefix goes on PATH first, which is how a probe is made to fail. run keeps
# the function's own report in ${output}.
run_sweep() {
  local home="${1}" prefix=""
  [ "$#" -gt 1 ] && prefix="${2}:"
  run bash -c "HOME='${home}'; PATH='${prefix}${PATH}'; source <(python3 '${REPO_ROOT}/tests/extract_fn.py' '${BODY}' grok_sweep_config_swaps); grok_sweep_config_swaps"
}

# run_sweep_proc <home> <proc_dir> - same, with the descriptor scan pointed somewhere
# else. The body names its scan root as one constant so a case can hand it a tree with no
# descriptors in it; the assertion here is that the seam still exists.
run_sweep_proc() {
  local home="${1}" procdir="${2}" fn="${BATS_TEST_TMPDIR}/fn-proc.sh"
  python3 "${REPO_ROOT}/tests/extract_fn.py" "${BODY}" grok_sweep_config_swaps \
    | sed "s|grok_proc_dir=/proc|grok_proc_dir=${procdir}|" > "${fn}"
  grep -qF "grok_proc_dir=${procdir}" "${fn}" || {
    echo "the body no longer names grok_proc_dir=/proc, so this case tested nothing" >&2
    return 1
  }
  run bash -c "HOME='${home}'; . '${fn}'; grok_sweep_config_swaps"
}

# new_swap <home> <name> [age] - one swap file in <home>/.grok, backdated by <age>.
new_swap() {
  local home="${1}" name="${2}" age="${3:-2 days ago}"
  mkdir -p "${home}/.grok"
  printf 'VIM swap fixture\n' > "${home}/.grok/${name}"
  touch -d "${age}" "${home}/.grok/${name}"
}

# manage <home> <stack|person|comment> - what the config beside the swap claims to be.
# `comment` carries only the marker comment; `stack` only the TOML key. Either one on its
# own is enough for the sweep to consider the file stack-owned.
manage() {
  mkdir -p "${1}/.grok"
  case "${2}" in
    stack) printf '__evoT1Stack = true\n' > "${1}/.grok/config.toml" ;;
    comment) printf '# managed-by: evo-t1-coder-stack\n' > "${1}/.grok/config.toml" ;;
    *) printf '# the operator wrote this one\n' > "${1}/.grok/config.toml" ;;
  esac
}

# names_in <home> - every name left in <home>/.grok, so a case proves the sweep took
# exactly what it should and nothing else, rather than only what it took.
names_in() {
  find "${1}/.grok" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '
}

# archived <home> - what landed in the recover directory, names only. A sweep that
# "cleared" the swap by deleting it shows an empty list here.
archived() {
  local dir="${1}/.grok/stale-swaps"
  [ -d "${dir}" ] || {
    printf '(none)\n'
    return
  }
  find "${dir}" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '
}

# archive_holding <home> <text> - is any archived byte sequence the one we seeded?
archive_holding() {
  local dir="${1}/.grok/stale-swaps"
  [ -d "${dir}" ] && grep -rls -- "${2}" "${dir}" >/dev/null 2>&1
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
  # braced shell expansion that only made sense after Terraform rendered it: raw, the
  # shell got the pattern's own slash and the move silently failed. A braced expansion is
  # the one form whose meaning changes across the render, so this body uses none. The
  # alternatives are the ones that mean the same thing both ways - basename, or a loop.
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
  assert_eq "the E325 prompt is clear of them" "config.toml stale-swaps " "$(names_in "${home}")"
  # Recoverable is the contract: the bytes still exist, so a wrong orphan call is undone
  # by an ls and a `vim -r`, and a step that had deleted them fails this line.
  local kept
  kept="$(archived "${home}")"
  for suffix in swp swo swn swm; do
    case " ${kept} " in
      *" sweep-.config.toml.${suffix}.orphan."*) ;;
      *)
        echo "stale-swaps holds '${kept}'; a sweep-named .config.toml.${suffix} is not in it" >&2
        return 1
        ;;
    esac
  done
  archive_holding "${home}" 'VIM swap fixture' || {
    echo "the archived swap is not the file's own bytes" >&2
    return 1
  }
  # A boot that relocates a file the operator can see says so, and says where to: the
  # archived name carries a suffix nobody can guess, so the log has to print it.
  assert_match "one report per move" 'Moved the stale editor swap' "${output}"
  assert_match "and the report names the archived path" \
    'vim -r ~/.grok/stale-swaps/sweep-\.config\.toml\.swp\.orphan\.' "${output}"
}

@test "swap sweep: the hour is the boundary, on both sides of it" {
  # Pinning the number itself: fixtures at now and two days ago alone let any threshold
  # between one minute and two days pass, which would make the guard decorative.
  local home="${BATS_TEST_TMPDIR}/hour"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp "30 minutes ago"
  new_swap "${home}" .config.toml.swo "90 minutes ago"
  run_sweep "${home}"
  assert_eq "inside the hour stays, outside it goes" \
    ".config.toml.swp config.toml stale-swaps " "$(names_in "${home}")"
  case " $(archived "${home}") " in
    *" sweep-.config.toml.swo.orphan."*) ;;
    *)
      echo "the 90-minute swap should be archived; got '$(archived "${home}")'" >&2
      return 1
      ;;
  esac
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

@test "swap sweep: a probe that errors is not an answer, and the swap stays" {
  # readlink is the probe whose silence means "nobody holds this": an erroring one answers
  # the empty string, and the compare reads that as no holder. The body therefore has to
  # exercise readlink and check the result, not just look for the binary.
  local stub="${BATS_TEST_TMPDIR}/readlink-fails"
  mkdir -p "${stub}"
  printf '#!/bin/sh\nexit 1\n' > "${stub}/readlink"
  chmod 755 "${stub}/readlink"
  local home="${BATS_TEST_TMPDIR}/readlink-errors"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  run_sweep "${home}" "${stub}"
  assert_eq "an unreadable answer keeps every swap in place" \
    ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_eq "and nothing reached the archive" "(none)" "$(archived "${home}")"

  # A readlink that is simply not on PATH is the same undecided case.
  local gone="${BATS_TEST_TMPDIR}/readlink-missing"
  mkdir -p "${gone}"
  for tool in find basename grep mv mkdir touch cat python3; do
    ln -s "$(command -v "${tool}")" "${gone}/${tool}" 2>/dev/null || true
  done
  local home2="${BATS_TEST_TMPDIR}/readlink-absent"
  manage "${home2}" stack
  new_swap "${home2}" .config.toml.swp
  run bash -c "HOME='${home2}'; PATH='${gone}'; source <(python3 '${REPO_ROOT}/tests/extract_fn.py' '${BODY}' grok_sweep_config_swaps); grok_sweep_config_swaps"
  assert_eq "a missing probe keeps every swap in place" \
    ".config.toml.swp config.toml " "$(names_in "${home2}")"
}

@test "swap sweep: a descriptor tree with nothing readable in it is not an answer either" {
  # With the scan root gone the glob matches nothing, so every swap looks unheld and the
  # sweep would move a file out from under a live editor. The guard has to fail closed.
  local home="${BATS_TEST_TMPDIR}/no-proc"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  run_sweep_proc "${home}" "${BATS_TEST_TMPDIR}/definitely-not-proc"
  assert_eq "no descriptors to read keeps the swap where it is" \
    ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_not_match "and the boot claims no move" 'Moved the stale editor swap' "${output}"
}

@test "swap sweep: a swap that is a symlink is left alone" {
  # Archiving a link would move the name, strand the bytes it points at, and then promise
  # recovery of a dangling path.
  local home="${BATS_TEST_TMPDIR}/symlink-swap"
  manage "${home}" stack
  mkdir -p "${home}/elsewhere"
  printf 'REAL BYTES OUTSIDE THE HOME\n' > "${home}/elsewhere/real.bin"
  ln -s "${home}/elsewhere/real.bin" "${home}/.grok/.config.toml.swp"
  touch -h -d '2 days ago' "${home}/.grok/.config.toml.swp"
  run_sweep "${home}"
  assert_eq "the link stays put" ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_eq "and nothing was archived" "(none)" "$(archived "${home}")"
  grep -q 'REAL BYTES OUTSIDE THE HOME' "${home}/elsewhere/real.bin" || {
    echo "the bytes behind the link moved" >&2
    return 1
  }
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

@test "swap sweep: either stack marker on its own makes the config ours to sweep" {
  # The guard accepts the TOML key or the comment. A fixture that seeds only one of them
  # leaves the other alternative untested, and dropping it from the grep would then be a
  # silent change in which homes get swept.
  local home
  for spelling in stack comment; do
    home="${BATS_TEST_TMPDIR}/marker-${spelling}"
    manage "${home}" "${spelling}"
    new_swap "${home}" .config.toml.swp
    run_sweep "${home}"
    assert_eq "a config marked by ${spelling} is swept" \
      "config.toml stale-swaps " "$(names_in "${home}")"
  done
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

@test "swap sweep: every undecided path keeps the swap and stays quiet" {
  # A find that cannot answer is not an answer: the age check has to keep the file.
  local stub="${BATS_TEST_TMPDIR}/find-fails"
  mkdir -p "${stub}"
  printf '#!/bin/sh\nexit 1\n' > "${stub}/find"
  chmod 755 "${stub}/find"
  local home="${BATS_TEST_TMPDIR}/probe-fails"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  run_sweep "${home}" "${stub}"
  assert_eq "a probe that errors costs the swap nothing" \
    ".config.toml.swp config.toml " "$(names_in "${home}")"
  assert_eq "and nothing reached the archive" "(none)" "$(archived "${home}")"

  # An archive directory that cannot be made is a reason to leave the file where the
  # operator can find it, and no reason to overwrite what already owns that name.
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

@test "swap sweep: a move that cannot happen leaves the swap and stays quiet" {
  # The report has to be earned: announcing a move that mv refused is the one outcome
  # worse than silence, because the operator then looks in stale-swaps for a file that is
  # still sitting in .grok. Stub mv and both halves are checked.
  local home="${BATS_TEST_TMPDIR}/mv-fails"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  local stub="${BATS_TEST_TMPDIR}/mv-stub"
  mkdir -p "${stub}"
  printf '#!/bin/sh\nexit 1\n' > "${stub}/mv"
  chmod 755 "${stub}/mv"
  run_sweep "${home}" "${stub}"
  assert_eq "a refused move leaves the swap where it was" \
    ".config.toml.swp config.toml stale-swaps " "$(names_in "${home}")"
  assert_not_match "and the boot claims no move it did not make" \
    'Moved the stale editor swap' "${output}"
}

@test "swap sweep: a swap that is already a month old still arrives in the archive" {
  # The feature's own common case: a workspace sits stopped for six weeks, so the swap it
  # leaves is older than the retention. mv carries the old mtime with it, so without
  # re-dating the archived copy the prune in this same run deletes what it just moved and
  # the month of recovery is a lie exactly when it is most needed.
  local home="${BATS_TEST_TMPDIR}/ancient"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp "40 days ago"
  run_sweep "${home}"
  assert_eq "the swap left .grok" "config.toml stale-swaps " "$(names_in "${home}")"
  case " $(archived "${home}") " in
    *" sweep-.config.toml.swp.orphan."*) ;;
    *)
      echo "a 40-day-old swap was archived and pruned in one run; archive is '$(archived "${home}")'" >&2
      return 1
      ;;
  esac
  archive_holding "${home}" 'VIM swap fixture' || {
    echo "the archived bytes are gone" >&2
    return 1
  }
}

@test "swap sweep: archiving never overwrites an archive already there" {
  # Sibling containers share this volume and each starts its own PID sequence, so two
  # sweeps can reach the same $$ and the second mv would eat the first one's evidence.
  local home="${BATS_TEST_TMPDIR}/collision"
  manage "${home}" stack
  new_swap "${home}" .config.toml.swp
  local fn="${BATS_TEST_TMPDIR}/fn-collision.sh"
  python3 "${REPO_ROOT}/tests/extract_fn.py" "${BODY}" grok_sweep_config_swaps > "${fn}"
  run bash -c "HOME='${home}'; mkdir -p \"\$HOME/.grok/stale-swaps\"; printf 'BOOT ONE PRECIOUS WORK\n' > \"\$HOME/.grok/stale-swaps/sweep-.config.toml.swp.orphan.\$\$-0\"; . '${fn}'; grok_sweep_config_swaps"
  assert_eq "the swap still left .grok" "config.toml stale-swaps " "$(names_in "${home}")"
  local count
  count="$(find "${home}/.grok/stale-swaps" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')"
  [ "${count}" -eq 2 ] || {
    echo "two sweeps should leave two archives, found ${count}: $(archived "${home}")" >&2
    return 1
  }
  archive_holding "${home}" 'BOOT ONE PRECIOUS WORK' || {
    echo "the earlier archive was overwritten" >&2
    return 1
  }
}

@test "swap sweep: the archive is kept for a month, and only the sweep's own files" {
  local home="${BATS_TEST_TMPDIR}/prune"
  manage "${home}" stack
  mkdir -p "${home}/.grok/stale-swaps/keepme"
  printf 'old\n' > "${home}/.grok/stale-swaps/sweep-.config.toml.swp.orphan.111-0"
  printf 'new\n' > "${home}/.grok/stale-swaps/sweep-.config.toml.swo.orphan.222-0"
  # The docs send a person to this directory to recover work, so anything they park there
  # is theirs. These three are the shapes that a looser prune filter eats: a name with
  # `.orphan.` in it that the sweep never wrote, and a file one level down.
  printf 'mine\n' > "${home}/.grok/stale-swaps/notes.orphan.txt"
  printf 'backup\n' > "${home}/.grok/stale-swaps/config.toml.bak.orphan.keep"
  printf 'deep\n' > "${home}/.grok/stale-swaps/keepme/sweep-.config.toml.swn.orphan.333-0"
  local stale
  for stale in sweep-.config.toml.swp.orphan.111-0 sweep-.config.toml.swo.orphan.222-0 \
    notes.orphan.txt config.toml.bak.orphan.keep keepme/sweep-.config.toml.swn.orphan.333-0; do
    touch -d '40 days ago' "${home}/.grok/stale-swaps/${stale}"
  done
  touch -d '2 days ago' "${home}/.grok/stale-swaps/sweep-.config.toml.swo.orphan.222-0"
  run_sweep "${home}"
  assert_eq "a month-old sweep archive is junk; everything else is a person's" \
    "config.toml.bak.orphan.keep keepme notes.orphan.txt sweep-.config.toml.swo.orphan.222-0 " \
    "$(archived "${home}")"
  grep -q 'mine' "${home}/.grok/stale-swaps/notes.orphan.txt" || {
    echo "the prune ate a file the operator named" >&2
    return 1
  }
  grep -q 'deep' "${home}/.grok/stale-swaps/keepme/sweep-.config.toml.swn.orphan.333-0" || {
    echo "the prune walked past one level" >&2
    return 1
  }

  # And the prune must not turn a missing archive into a failing boot.
  local fresh="${BATS_TEST_TMPDIR}/prune-none"
  manage "${fresh}" stack
  run_sweep "${fresh}"
  [ "${status}" -eq 0 ] || {
    echo "a home with no archive yet made the boot fail: rc=${status}" >&2
    return 1
  }
  assert_eq "and it built nothing" "(none)" "$(archived "${fresh}")"
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
