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
# Four of the seeded options are the fixes `grok doctor` offers: set-clipboard
# and allow-passthrough for the copy routes, extended-keys, and the RGB
# terminal-features entry; the extkeys entry is the one Doctor leaves to the
# operator. tmux rewrites 24-bit color down to what the attached client
# advertises, so a missing RGB entry washes a theme out in the browser while the
# app inside still emits truecolor. tmux only warns about an unknown option name
# and starts anyway, so when tmux is on PATH the suite also boots a scratch
# server on a private socket and reads the options back.
#
# Usage: bazelisk test //tests:bats_tmux_fidelity_test   (from any cwd)
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
COMMON_TMUX=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  WS_STARTUP="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  DC_STARTUP="${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"
  WS_SETTINGS="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  DC_SETTINGS="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  COMMON_TMUX="${REPO_ROOT}/templates/common/tmux.conf"
  local f
  for f in "${WS_STARTUP}" "${DC_STARTUP}" "${WS_SETTINGS}" "${DC_SETTINGS}" "${COMMON_TMUX}"; do
    [ -f "${f}" ] || skip "template payload missing: ${f}"
  done
}

# extract_tmux_guard <src> <dest> — copy the tmux ownership if/else/fi from a
# startup twin (the interpolated ${tmux_conf} heredoc plus the warning branch).
extract_tmux_guard() {
  awk '
    $0 ~ /^if \[ ! -f "\$HOME\/\.tmux\.conf" \] \\/ { start = 1 }
    start { print }
    start && $0 == "fi" { exit }
  ' "$1" >"$2"
  [ -s "$2" ] || {
    echo "seed guard missing from $1" >&2
    return 1
  }
}

# runnable_tmux_seed <dest> — the same guard, writing templates/common/tmux.conf
# the way templatefile interpolates ${tmux_conf} at apply.
runnable_tmux_seed() {
  {
    printf '%s\n' \
      'if [ ! -f "$HOME/.tmux.conf" ] \' \
      "   || grep -qs 'managed-by: evo-t1-coder-stack' \"\$HOME/.tmux.conf\"; then" \
      "  cat >\"\$HOME/.tmux.conf\" <<'TMUX_CONF_EOF'"
    cat "${COMMON_TMUX}"
    printf '%s\n' \
      'TMUX_CONF_EOF' \
      'else' \
      '  echo "WARNING: $HOME/.tmux.conf carries no evo-t1-coder-stack marker -" \' \
      '    "leaving it alone. Remove the marker line to keep your own tmux config." >&2' \
      'fi'
  } >"$1"
}

@test "tmux seed: both startup twins interpolate the common tmux.conf" {
  local a="${BATS_TEST_TMPDIR}/seed-ws.sh" b="${BATS_TEST_TMPDIR}/seed-dc.sh"
  extract_tmux_guard "${WS_STARTUP}" "${a}"
  extract_tmux_guard "${DC_STARTUP}" "${b}"
  cmp -s "${a}" "${b}"
  grep -Fq '${tmux_conf}' "${a}"
  # A drifted twin would seed a different terminal for one hosting mode.
  grep -Fc 'set -g mouse on' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'set -g set-clipboard on' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'set -g allow-passthrough on' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc "set -g extended-keys on" "${COMMON_TMUX}" | grep -qx 1
  grep -Fc "set -as terminal-features ',*:RGB'" "${COMMON_TMUX}" | grep -qx 1
  grep -Fc "set -as terminal-features 'xterm*:extkeys'" "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'setw -g mode-keys vi' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'history-limit 50000' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'MouseDragEnd1Pane' "${COMMON_TMUX}" | grep -qx 1
}

@test "tmux seed: the common payload stays interpolation-clean and twins keep the guard" {
  local f
  # Terraform interpolates ${ and %{ inside templatefile(). The payload file
  # must carry neither, or the seed text mutates at template build time.
  run grep -F '${' "${COMMON_TMUX}"
  [ "${status}" -ne 0 ] || { echo "live interpolation in templates/common/tmux.conf" >&2; return 1; }
  run grep -F '%{' "${COMMON_TMUX}"
  [ "${status}" -ne 0 ] || { echo "live directive in templates/common/tmux.conf" >&2; return 1; }
  for f in "${WS_STARTUP}" "${DC_STARTUP}"; do
    grep -Fq '${tmux_conf}' "${f}"
    assert_contains_file "warning branch" "${f}" 'carries no evo-t1-coder-stack marker'
  done
}

@test "tmux seed: a fresh HOME receives the fidelity config verbatim" {
  local script="${BATS_TEST_TMPDIR}/seed.sh" home="${BATS_TEST_TMPDIR}/home"
  runnable_tmux_seed "${script}"
  mkdir -p "${home}"
  run env HOME="${home}" bash "${script}"
  [ "${status}" -eq 0 ]
  assert_contains_file "mouse scroll/copy" "${home}/.tmux.conf" '^set -g mouse on$'
  assert_contains_file "OSC 52 clipboard" "${home}/.tmux.conf" '^set -g set-clipboard on$'
  assert_contains_file "passthrough" "${home}/.tmux.conf" '^set -g allow-passthrough on$'
  assert_contains_file "extended keys" "${home}/.tmux.conf" '^set -g extended-keys on$'
  assert_contains_file "truecolor survives the multiplexer" "${home}/.tmux.conf" "^set -as terminal-features '\\,\\*:RGB'\$"
  assert_contains_file "extkeys for Shift+Enter" "${home}/.tmux.conf" "^set -as terminal-features 'xterm\\*:extkeys'\$"
  assert_contains_file "vi copy-mode" "${home}/.tmux.conf" '^setw -g mode-keys vi$'
  assert_contains_file "y copies to clipboard" "${home}/.tmux.conf" 'y send-keys -X copy-selection-and-cancel'
  assert_contains_file "drag-release copies" "${home}/.tmux.conf" 'MouseDragEnd1Pane send-keys -X copy-selection-and-cancel'
  assert_contains_file "marker line shipped" "${home}/.tmux.conf" 'managed-by: evo-t1-coder-stack'
}

@test "tmux seed: a marker-free tmux.conf is user-owned and survives" {
  local script="${BATS_TEST_TMPDIR}/seed.sh" home="${BATS_TEST_TMPDIR}/home"
  runnable_tmux_seed "${script}"
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
  runnable_tmux_seed "${script}"
  mkdir -p "${home}"
  printf '# managed-by: evo-t1-coder-stack -- stale\nset -g mouse off\n' >"${home}/.tmux.conf"
  run env HOME="${home}" bash "${script}"
  [ "${status}" -eq 0 ]
  assert_contains_file "reseeded" "${home}/.tmux.conf" '^set -g mouse on$'
  assert_not_match "stale line gone" 'set -g mouse off' "$(cat "${home}/.tmux.conf")"
}

# Scratch tmux server for the live read-back test below; the file teardown
# reaps it when an assertion fails mid-test.
SCRATCH_TMUX_SOCKET=""

scratch_tmux_reap() {
  [ -n "${SCRATCH_TMUX_SOCKET}" ] || return 0
  tmux -L "${SCRATCH_TMUX_SOCKET}" kill-server >/dev/null 2>&1 || true
  SCRATCH_TMUX_SOCKET=""
}

teardown() {
  scratch_tmux_reap
}

@test "tmux seed: a live server holds the options grok doctor inspects" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  local conf="${BATS_TEST_TMPDIR}/tmux.conf"
  cp "${COMMON_TMUX}" "${conf}"
  SCRATCH_TMUX_SOCKET="bats-tmux-fid-$$-${BATS_TEST_NUMBER}"
  run tmux -L "${SCRATCH_TMUX_SOCKET}" -f "${conf}" new-session -d -s fid -x 80 -y 24 'sleep 30'
  [ "${status}" -eq 0 ] || skip "cannot start a scratch tmux server: ${output}"
  # tmux only warns about an unknown option name and starts anyway, so a typo
  # is visible only in what the server ends up holding.
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -g mouse
  [ "${output}" = "mouse on" ]
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -g set-clipboard
  [ "${output}" = "set-clipboard on" ]
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -wg allow-passthrough
  [ "${output}" = "allow-passthrough on" ]
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -wg extended-keys
  [ "${output}" = "extended-keys on" ]
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -s terminal-features
  [[ "${output}" == *"*:RGB"* ]] || {
    echo "terminal-features carries no RGB entry: ${output}" >&2
    return 1
  }
  [[ "${output}" == *"xterm*:extkeys"* ]] || {
    echo "terminal-features carries no extkeys entry: ${output}" >&2
    return 1
  }
  scratch_tmux_reap
}

@test "terminal keys: both settings twins carry the fidelity keys" {
  local f
  for f in "${WS_SETTINGS}" "${DC_SETTINGS}"; do
    assert_contains_file "deep scrollback" "${f}" '"terminal.integrated.scrollback": 10000'
    assert_contains_file "copy on select" "${f}" '"terminal.integrated.copyOnSelection": true'
    assert_contains_file "right-click copies" "${f}" '"terminal.integrated.rightClickBehavior": "copyPaste"'
  done
}
