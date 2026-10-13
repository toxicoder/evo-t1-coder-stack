#!/usr/bin/env bats
#
# ## tmux-fidelity.bats — terminal fidelity seeds: tmux config and editor terminal keys.
#
# Inside a tmux pane, scrolling and copy/paste must feel like a native
# terminal: `mouse on` hands the wheel and the drag to tmux, and
# `set-clipboard on` carries a copy out to the client clipboard over OSC 52.
# The seed stage in both startup.sh.tftpl twins honours the marker-line
# ownership contract (a marker-free ~/.tmux.conf is user-owned: leave it
# alone, print a warning). This suite extracts that seed block, runs it
# against a throwaway HOME, and pins the editor terminal keys both
# settings.json.tftpl twins must keep.
#
# Usage: bats tests/bats/tmux-fidelity.bats
# Safety: reads the four template payload files; writes only under the
# per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
WS_STARTUP=""
DC_STARTUP=""
WS_SETTINGS=""
DC_SETTINGS=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  WS_STARTUP="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  DC_STARTUP="${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"
  WS_SETTINGS="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  DC_SETTINGS="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  local f
  for f in "${WS_STARTUP}" "${DC_STARTUP}" "${WS_SETTINGS}" "${DC_SETTINGS}"; do
    [ -f "${f}" ] || skip "template payload missing: ${f}"
  done
}

# extract_tmux_seed <src> <dest> — copy the tmux seed stage (the if/else/fi
# block that writes $HOME/.tmux.conf, guard line through closing `fi`) from a
# startup template into <dest>. Fails unless the guard appears exactly once
# and is followed by a lone-`fi` terminator, so the extractor cannot
# silently grab the wrong region.
extract_tmux_seed() {
  python3 - "$1" "$2" <<'PY'
import sys
src, dest = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(True)
guard = 'if [ ! -f "$HOME/.tmux.conf" ] \\'
starts = [i for i, l in enumerate(lines) if l.startswith(guard)]
if len(starts) != 1:
    sys.exit("seed guard found %d times in %s" % (len(starts), src))
start = starts[0]
end = next((i for i in range(start, len(lines)) if lines[i].rstrip("\n") == "fi"), None)
if end is None:
    sys.exit("seed block never terminates with a lone 'fi' in %s" % src)
with open(dest, "w") as fh:
    fh.write("".join(lines[start:end + 1]))
PY
}

@test "tmux seed: both startup twins carry the same seed stage" {
  local a="${BATS_TEST_TMPDIR}/seed-ws.sh" b="${BATS_TEST_TMPDIR}/seed-dc.sh"
  extract_tmux_seed "${WS_STARTUP}" "${a}"
  extract_tmux_seed "${DC_STARTUP}" "${b}"
  cmp -s "${a}" "${b}"
  # A drifted twin would seed a different terminal for one hosting mode.
  grep -Fc 'set -g mouse on' "${a}" | grep -qx 1
  grep -Fc 'set -g set-clipboard on' "${a}" | grep -qx 1
  grep -Fc 'set -g allow-passthrough on' "${a}" | grep -qx 1
  grep -Fc 'setw -g mode-keys vi' "${a}" | grep -qx 1
  grep -Fc 'history-limit 50000' "${a}" | grep -qx 1
  grep -Fc 'MouseDragEnd1Pane' "${a}" | grep -qx 1
}

@test "tmux seed: the heredoc stays interpolation-clean and the markers balance" {
  local script="${BATS_TEST_TMPDIR}/seed-ic.sh" f count
  for f in "${WS_STARTUP}" "${DC_STARTUP}"; do
    # Exactly two TMUX_CONF_EOF markers per file: the seed stage's opening
    # heredoc and its terminator. scripts/lib/config_seed.sh extracts the
    # seed payload between these markers, so the count is load-bearing.
    count="$(grep -c 'TMUX_CONF_EOF' "${f}")"
    [ "${count}" -eq 2 ] || { echo "TMUX_CONF_EOF count is ${count} in ${f}" >&2; return 1; }
    # Terraform interpolates ${ and %{ inside templatefile(). The seed block
    # must carry neither, or the seed text mutates at template build time.
    extract_tmux_seed "${f}" "${script}"
    run grep -F '${' "${script}"
    [ "${status}" -ne 0 ] || { echo "live interpolation in seed block of ${f}" >&2; return 1; }
    run grep -F '%{' "${script}"
    [ "${status}" -ne 0 ] || { echo "live directive in seed block of ${f}" >&2; return 1; }
  done
  # The warning branch survives in both twins:
  for f in "${WS_STARTUP}" "${DC_STARTUP}"; do
    assert_contains_file "warning branch" "${f}" 'carries no evo-t1-coder-stack marker'
  done
}

@test "tmux seed: a fresh HOME receives the fidelity config verbatim" {
  local script="${BATS_TEST_TMPDIR}/seed.sh" home="${BATS_TEST_TMPDIR}/home"
  extract_tmux_seed "${WS_STARTUP}" "${script}"
  mkdir -p "${home}"
  run env HOME="${home}" bash "${script}"
  [ "${status}" -eq 0 ]
  assert_contains_file "mouse scroll/copy" "${home}/.tmux.conf" '^set -g mouse on$'
  assert_contains_file "OSC 52 clipboard" "${home}/.tmux.conf" '^set -g set-clipboard on$'
  assert_contains_file "passthrough" "${home}/.tmux.conf" '^set -g allow-passthrough on$'
  assert_contains_file "vi copy-mode" "${home}/.tmux.conf" '^setw -g mode-keys vi$'
  assert_contains_file "y copies to clipboard" "${home}/.tmux.conf" 'y send-keys -X copy-selection-and-cancel'
  assert_contains_file "drag-release copies" "${home}/.tmux.conf" 'MouseDragEnd1Pane send-keys -X copy-selection-and-cancel'
  assert_contains_file "marker line shipped" "${home}/.tmux.conf" 'managed-by: evo-t1-coder-stack'
}

@test "tmux seed: a marker-free tmux.conf is user-owned and survives" {
  local script="${BATS_TEST_TMPDIR}/seed.sh" home="${BATS_TEST_TMPDIR}/home"
  extract_tmux_seed "${WS_STARTUP}" "${script}"
  mkdir -p "${home}"
  printf 'set -g mouse off\nset -g scrollback 200\n' >"${home}/.tmux.conf"
  run env HOME="${home}" bash "${script}"
  [ "${status}" -eq 0 ]
  # Left alone means byte-identical, and the operator is told why.
  assert_contains_file "user file untouched" "${home}/.tmux.conf" '^set -g mouse off$'
  assert_not_match "no reseed" 'set -g mouse on' "$(cat "${home}/.tmux.conf")"
  assert_match "warning names the marker" 'evo-t1-coder-stack marker' "${output}"
}

@test "tmux seed: a marked file is rewritten to the stack defaults" {
  local script="${BATS_TEST_TMPDIR}/seed.sh" home="${BATS_TEST_TMPDIR}/home"
  extract_tmux_seed "${DC_STARTUP}" "${script}"
  mkdir -p "${home}"
  printf '# managed-by: evo-t1-coder-stack -- stale\nset -g mouse off\n' >"${home}/.tmux.conf"
  run env HOME="${home}" bash "${script}"
  [ "${status}" -eq 0 ]
  assert_contains_file "reseeded" "${home}/.tmux.conf" '^set -g mouse on$'
  assert_not_match "stale line gone" 'set -g mouse off' "$(cat "${home}/.tmux.conf")"
}

@test "terminal keys: both settings twins carry the fidelity keys" {
  local f
  for f in "${WS_SETTINGS}" "${DC_SETTINGS}"; do
    assert_contains_file "deep scrollback" "${f}" '"terminal.integrated.scrollback": 10000'
    assert_contains_file "copy on select" "${f}" '"terminal.integrated.copyOnSelection": true'
    assert_contains_file "right-click copies" "${f}" '"terminal.integrated.rightClickBehavior": "copyPaste"'
  done
}
