#!/usr/bin/env bats
#
# ## tmux-fidelity.bats — terminal fidelity seeds: tmux config and editor terminal keys.
#
# Inside a tmux pane, scrolling and copy/paste must feel like a native
# terminal: `mouse on` hands the wheel and the drag to tmux, and
# `set-clipboard on` carries a copy out to the client clipboard over OSC 52 --
# which a real terminal honours and the browser build of VS Code drops
# (microsoft/vscode#318254). In a browser tab the copy out is a Shift+drag,
# which xterm.js hands to the browser even while tmux holds the pointer, and
# Prefix m is the fallback that releases the pointer. That contract lives in the
# payload's own comments, so this suite pins those words as well as the options.
# The seed stage in both startup.sh.tftpl
# twins honours the marker-line ownership contract (a marker-free ~/.tmux.conf
# is user-owned: leave it alone, print a warning). This suite extracts that seed
# block, runs it against a throwaway HOME, and pins the editor terminal keys both
# settings.json.tftpl twins must keep. It also pins the byte parity of every
# payload both main.tf twins feed into a quoted here-doc in the startup script:
# config_seed.sh seeds the same paths from the repo bytes, so a feed that
# chomps differently gives the same file two writers with different bytes.
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
# Safety: reads the template payloads, both startup twins and both main.tf
# twins; writes only under the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
WS_STARTUP=""
DC_STARTUP=""
WS_SETTINGS=""
DC_SETTINGS=""
WS_MAIN=""
DC_MAIN=""
COMMON_TMUX=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  WS_STARTUP="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  DC_STARTUP="${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"
  WS_SETTINGS="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  DC_SETTINGS="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  WS_MAIN="${REPO_ROOT}/templates/workspace/main.tf"
  DC_MAIN="${REPO_ROOT}/templates/devcontainer/main.tf"
  COMMON_TMUX="${REPO_ROOT}/templates/common/tmux.conf"
  local f
  for f in "${WS_STARTUP}" "${DC_STARTUP}" "${WS_SETTINGS}" "${DC_SETTINGS}" "${WS_MAIN}" "${DC_MAIN}" "${COMMON_TMUX}"; do
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
  grep -Fc 'history-limit 100000' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'set -g focus-events on' "${COMMON_TMUX}" | grep -qx 1
  grep -Fc 'set -s escape-time 10' "${COMMON_TMUX}" | grep -qx 1
  # Left at its default on purpose: options-table.c scopes it to the
  # smallest/manual window-size modes and the shipped default is latest, so all
  # it could do here is the resize behaviour tmux(1) calls poor for shells.
  [ "$(grep -Ec '^[[:space:]]*setw -g aggressive-resize' "${COMMON_TMUX}")" = "0" ] || {
    echo "the payload sets aggressive-resize, which is inert under window-size latest" >&2
    return 1; }
  grep -Fc 'MouseDragEnd1Pane' "${COMMON_TMUX}" | grep -qx 1
  # The browser copy switch: one prefix key releases the mouse so a drag becomes
  # the browser's selection (VS Code web drops OSC 52; see the payload comment).
  grep -Fc 'bind-key m set -g mouse' "${COMMON_TMUX}" | grep -qx 1
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

# --- payload feed byte parity -------------------------------------------------
#
# Both main.tf twins hand the seeded payloads to startup.sh.tftpl, where a
# quoted here-doc writes each one into $HOME, and scripts/lib/config_seed.sh
# seeds some of the same paths straight from the repo bytes. Two writers, one
# file: the here-doc has to land those bytes exactly, so every feed chomps() and
# the template's own line break supplies the written file's single trailing
# newline.

# feed_specs - one line per payload that reaches $HOME through a quoted
# here-doc: <main.tf variable> <payload basename> <here-doc tag>.
feed_specs() {
  printf '%s\n' \
    'tmux_conf tmux.conf TMUX_CONF_EOF' \
    'notes_setup notes-setup.sh NOTES_SETUP_EOF' \
    'grok_build_terminal grok-build-terminal.sh GROK_BUILD_HELPER' \
    'vscode_terminal_tmux vscode-terminal-tmux.sh TMUX_ATTACH_HELPER' \
    'mcp_cache_proxy mcp-cache-proxy.json MCP_CACHE_PROXY_EOF'
}

# render_feed <tftpl> <var> <value-file> <out> - the twin as templatefile()
# renders it for one feed: the ${var} line becomes the value's bytes followed by
# the template's own line break, so a value that still carries its trailing
# newline puts a blank line at the end of the here-doc body.
render_feed() {
  local src="$1" var="$2" value="$3" out="$4" ln
  ln=$(grep -nFx -- '${'"${var}"'}' "${src}" | head -1 | cut -d: -f1)
  [ -n "${ln}" ] || {
    echo "no \${${var}} interpolation in ${src}" >&2
    return 1
  }
  {
    head -n $((ln - 1)) "${src}"
    cat "${value}"
    printf '\n'
    tail -n +"$((ln + 1))" "${src}"
  } >"${out}"
}

# feed_rhs <main.tf> <var> - the right-hand side of one feed's assignment.
feed_rhs() {
  awk -v k="$2" '$1 == k {
    sub(/^[[:space:]]*[^=]*=[[:space:]]*/, "")
    print
    exit
  }' "$1"
}

# feed_value <main.tf> <var> <name> <out> - the bytes that twin actually passes
# for the feed, so the parity below follows main.tf: drop the chomp() there and
# the here-doc body it renders stops matching the repo copy.
feed_value() {
  local tf="$1" var="$2" name="$3" out="$4" rhs
  rhs="$(feed_rhs "${tf}" "${var}")"
  [ -n "${rhs}" ] || {
    echo "${tf}: no ${var} assignment" >&2
    return 1
  }
  if [ "${rhs}" = 'chomp(file("${path.module}/'"${name}"'"))' ]; then
    head -c -1 "${REPO_ROOT}/templates/common/${name}" >"${out}"
  else
    cat "${REPO_ROOT}/templates/common/${name}" >"${out}"
  fi
}

# heredoc_body <script> <tag> <out> - the bytes `cat >f <<'TAG' ... TAG` writes,
# carved the way extract_tmux_guard carves its region out of a twin.
heredoc_body() {
  local open="<<'$2'"
  awk -v open="${open}" -v tag="$2" '
    !seen && index($0, open) { seen = 1; next }
    seen && $0 == tag { exit }
    seen { print }
  ' "$1" >"$3"
  [ -s "$3" ] || {
    echo "no here-doc closed by ${2} in $1" >&2
    return 1
  }
}

# twin_name <path> - which twin a template came from, for scratch names and
# failure messages (both twins' startup files share a basename).
twin_name() {
  basename "$(dirname "$1")"
}

@test "payload feeds: both main.tf twins chomp every here-doc payload" {
  local tf var name tag rhs want
  while read -r var name tag; do
    want='chomp(file("${path.module}/'"${name}"'"))'
    for tf in "${WS_MAIN}" "${DC_MAIN}"; do
      # Exact match on the right-hand side: a feed that lost chomp(), grew a
      # second one, or reads a path nobody stages all fail here.
      rhs="$(feed_rhs "${tf}" "${var}")"
      [ "${rhs}" = "${want}" ] || {
        echo "${tf}: ${var} = ${rhs}, want ${want}" >&2
        return 1; }
    done
  done < <(feed_specs)
}

@test "payload feeds: the here-doc writes the repo bytes with one trailing newline" {
  local mains=("${WS_MAIN}" "${DC_MAIN}")
  local starts=("${WS_STARTUP}" "${DC_STARTUP}")
  local i twin var name tag payload value rendered body
  while read -r var name tag; do
    payload="${REPO_ROOT}/templates/common/${name}"
    [ -f "${payload}" ] || { echo "payload missing: ${payload}" >&2; return 1; }
    # The parity claim is chomped payload plus the template's line break, and it
    # only lands the repo bytes while the repo copy ends on exactly one newline.
    [ "$(tail -c 1 "${payload}" | od -An -c | tr -d ' ')" = '\n' ] || {
      echo "${payload} does not end on a newline" >&2
      return 1; }
    [ "$(tail -c 2 "${payload}" | od -An -c | tr -d ' ')" != '\n\n' ] || {
      echo "${payload} ends on a blank line" >&2
      return 1; }
    # Each twin's script is rendered by its own main.tf: a twin that feeds
    # differently from its sibling seeds a different terminal for one hosting
    # mode, and one that stopped chomping lands the blank line here.
    for i in 0 1; do
      twin="$(twin_name "${starts[$i]}")"
      value="${BATS_TEST_TMPDIR}/${twin}-${var}.value"
      rendered="${BATS_TEST_TMPDIR}/${twin}-${var}.sh"
      body="${BATS_TEST_TMPDIR}/${twin}-${var}.body"
      feed_value "${mains[$i]}" "${var}" "${name}" "${value}"
      render_feed "${starts[$i]}" "${var}" "${value}" "${rendered}"
      heredoc_body "${rendered}" "${tag}" "${body}"
      cmp -s "${body}" "${payload}" || {
        {
          echo "${twin} writes bytes that stray from ${payload}"
          echo "-- written tail --"
          tail -c 24 "${body}" | od -An -c
          echo "-- payload tail --"
          tail -c 24 "${payload}" | od -An -c
        } >&2
        return 1; }
    done
  done < <(feed_specs)
}

@test "payload feeds: an un-chomped feed would leave a blank line at EOF" {
  local f twin var name tag payload rendered body
  while read -r var name tag; do
    payload="${REPO_ROOT}/templates/common/${name}"
    [ -f "${payload}" ] || { echo "payload missing: ${payload}" >&2; return 1; }
    for f in "${WS_STARTUP}" "${DC_STARTUP}"; do
      twin="$(twin_name "${f}")"
      rendered="${BATS_TEST_TMPDIR}/${twin}-${var}-raw.sh"
      body="${BATS_TEST_TMPDIR}/${twin}-${var}-raw.body"
      render_feed "${f}" "${var}" "${payload}" "${rendered}"
      heredoc_body "${rendered}" "${tag}" "${body}"
      # The shape the twins shipped with before every feed chomped: the payload's
      # own newline plus the template's line break. Pinning it is what lets the
      # parity test above actually fail.
      [ "$(tail -c 2 "${body}" | od -An -c | tr -d ' ')" = '\n\n' ] || {
        echo "${twin} ${var}: an un-chomped body does not end on a blank line" >&2
        return 1; }
      ! cmp -s "${body}" "${payload}" || {
        echo "${twin} ${var}: an un-chomped feed still matches the repo bytes" >&2
        return 1; }
    done
  done < <(feed_specs)
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
  assert_contains_file "browser copy switch" "${home}/.tmux.conf" '^bind-key m set -g mouse'
  assert_contains_file "deeper history" "${home}/.tmux.conf" '^set -g history-limit 100000$'
  assert_contains_file "per-client focus" "${home}/.tmux.conf" '^set -g focus-events on$'
  assert_contains_file "key latency stays low" "${home}/.tmux.conf" '^set -s escape-time 10$'
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
# reaps it when an assertion fails mid-test. TMUX_TMPDIR keeps the socket inside
# the per-test scratch tree, and the file itself comes off with the server
# because tmux leaves the socket behind after a clean shutdown.
SCRATCH_TMUX_SOCKET=""
SCRATCH_TMUX_TMPDIR=""

scratch_tmux_reap() {
  [ -n "${SCRATCH_TMUX_SOCKET}" ] || return 0
  local sock="${SCRATCH_TMUX_TMPDIR}/tmux-$(id -u)/${SCRATCH_TMUX_SOCKET}"
  tmux -L "${SCRATCH_TMUX_SOCKET}" kill-server >/dev/null 2>&1 || true
  [ -S "${sock}" ] && rm -f "${sock}"
  SCRATCH_TMUX_SOCKET=""
}

teardown() {
  scratch_tmux_reap
  attach_reap
}

@test "tmux seed: a live server holds the options grok doctor inspects" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  local conf="${BATS_TEST_TMPDIR}/tmux.conf"
  cp "${COMMON_TMUX}" "${conf}"
  SCRATCH_TMUX_TMPDIR="${BATS_TEST_TMPDIR}"
  SCRATCH_TMUX_SOCKET="bats-tmux-fid-$$-${BATS_TEST_NUMBER}"
  export TMUX_TMPDIR="${SCRATCH_TMUX_TMPDIR}"
  run tmux -L "${SCRATCH_TMUX_SOCKET}" -f "${conf}" new-session -d -s fid -x 80 -y 24 'sleep 30'
  [ "${status}" -eq 0 ] || skip "cannot start a scratch tmux server: ${output}"
  # tmux only warns about an unknown option name and starts anyway, so a typo
  # is visible only in what the server ends up holding.
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -g mouse
  [ "${output}" = "mouse on" ]
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -g set-clipboard
  [ "${output}" = "set-clipboard on" ]
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -g focus-events
  [ "${output}" = "focus-events on" ]
  # Not a doctor option either: the seed's whole claim about sizing is that it
  # leaves this one alone, so the running server has to agree.
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -gw aggressive-resize
  [ "${output}" != "aggressive-resize on" ] || {
    echo "aggressive-resize came up on: inert under window-size latest, and tmux(1) calls it poor for shells" >&2
    return 1; }
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
  # Not a doctor option, but the same proof shape: tmux 3.4 ships this at 500
  # and only accepts it as a server option, so a wrong scope or a typo leaves
  # the 500 in place and reads back wrong here.
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -s escape-time
  [ "${output}" = "escape-time 10" ]
  scratch_tmux_reap
}

@test "terminal keys: both settings twins carry the fidelity keys" {
  local f
  for f in "${WS_SETTINGS}" "${DC_SETTINGS}"; do
    # Browser-side memory: VS Code preallocates the xterm.js buffer from
    # scrollback, so the seed keeps it shallow and tmux history is the depth.
    assert_contains_file "bounded scrollback" "${f}" '"terminal.integrated.scrollback": 2000'
    assert_contains_file "steady cursor (no blink repaints)" "${f}" '"terminal.integrated.cursorBlinking": false'
    assert_contains_file "copy on select" "${f}" '"terminal.integrated.copyOnSelection": true'
    assert_contains_file "right-click copies" "${f}" '"terminal.integrated.rightClickBehavior": "copyPaste"'
  done
}

@test "tmux seed: the payload tells the operator the browser copy route" {
  # Measured on the shipped code-server 4.145.0 in a headless Chromium, with this
  # payload as the tmux config and the rendered settings twin as User
  # settings.json: Shift+drag calls navigator.clipboard.writeText and leaves
  # tmux's buffer empty, a plain drag is the mirror image (tmux buffer, no
  # browser selection), Alt and Ctrl drags reach neither side, and a copy-mode y
  # produces zero clipboard calls because the browser build drops OSC 52 before
  # the API. The text this replaces claimed no modifier hands a drag back, which
  # routed every browser copy through Prefix m.
  assert_contains_file "Shift+drag is the copy out" "${COMMON_TMUX}" 'Shift and drag'
  assert_contains_file "the drag fires the clipboard API" "${COMMON_TMUX}" 'navigator\.clipboard\.writeText'
  assert_contains_file "OSC 52 is the real-terminal route" "${COMMON_TMUX}" 'OSC 52 is a real terminal'
  assert_contains_file "the browser drop is named" "${COMMON_TMUX}" 'vscode#318254'
  assert_contains_file "the paste chord is named" "${COMMON_TMUX}" 'Ctrl\+Shift\+V'
  assert_contains_file "paste needs a secure context" "${COMMON_TMUX}" 'secure'
  # And the measured-false claim stays out of the file an operator reads.
  if grep -Eq -- 'Alt, Option, Shift and Ctrl' "${COMMON_TMUX}"; then
    fail "the payload again claims every modifier drag fails, which measures false"
  fi
}

# boot_scratch <socket> <session> - a scratch server on the shipped payload.
boot_scratch() {
  local sock="$1" sess="$2" conf
  conf="${BATS_TEST_TMPDIR}/scratch-${sess}.conf"
  cp "${COMMON_TMUX}" "${conf}"
  SCRATCH_TMUX_TMPDIR="${BATS_TEST_TMPDIR}"
  SCRATCH_TMUX_SOCKET="${sock}"
  export TMUX_TMPDIR="${SCRATCH_TMUX_TMPDIR}"
  run tmux -L "${sock}" -f "${conf}" new-session -d -s "${sess}" -x 80 -y 24 'sleep 30'
  [ "${status}" -eq 0 ] || skip "cannot start a scratch tmux server: ${output}"
}

@test "tmux seed: a live server binds the copy keys and the browser switch" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  boot_scratch "bats-keys-$$-${BATS_TEST_NUMBER}" keys
  run tmux -L "${SCRATCH_TMUX_SOCKET}" list-keys -T copy-mode-vi
  [[ "${output}" == *"begin-selection"* ]] || {
    echo "vi copy-mode binds no begin-selection: ${output}" >&2; return 1; }
  [[ "${output}" == *"copy-selection-and-cancel"* ]] || {
    echo "vi copy-mode binds no copy-selection-and-cancel: ${output}" >&2; return 1; }
  [[ "${output}" == *"MouseDragEnd1Pane"* ]] || {
    echo "a drag release does not copy: ${output}" >&2; return 1; }
  run tmux -L "${SCRATCH_TMUX_SOCKET}" list-keys -T prefix
  # list-keys echoes the bound command back with `set` folded to its long name,
  # so match the option it flips rather than the spelling in the payload.
  [[ "${output}" == *"set -g mouse"* || "${output}" == *"set-option -g mouse"* ]] || {
    echo "Prefix m is not bound to the mouse switch: ${output}" >&2; return 1; }
  run tmux -L "${SCRATCH_TMUX_SOCKET}" show-options -g history-limit
  [ "${output}" = "history-limit 100000" ] || {
    echo "history-limit reads ${output}" >&2; return 1; }
  scratch_tmux_reap
}

@test "tmux seed: a live server sources the payload with no complaint" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  boot_scratch "bats-parse-$$-${BATS_TEST_NUMBER}" parse
  # tmux only warns and carries on when it rejects a line, and booting with -f
  # hides even that. Sourcing the payload is what surfaces a bad option or flag,
  # which is how a bind-key with a flag tmux 3.4 does not know once vanished.
  run tmux -L "${SCRATCH_TMUX_SOCKET}" source-file "${COMMON_TMUX}"
  [ "${status}" -eq 0 ] || {
    echo "tmux rejected the payload: ${output}" >&2; return 1; }
  [[ "${output}" != *"unknown"* && "${output}" != *"invalid"* ]] || {
    echo "tmux complained while sourcing: ${output}" >&2; return 1; }
  scratch_tmux_reap
}

@test "tmux seed: the bound mouse switch really flips the option" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  boot_scratch "bats-switch-$$-${BATS_TEST_NUMBER}" switch
  local sock="${SCRATCH_TMUX_SOCKET}" bound cmd
  run tmux -L "${sock}" show-options -g mouse
  [ "${output}" = "mouse on" ]
  # Run the bound command verbatim rather than a copy of it: list-keys is what a
  # pressed Prefix m hands to the command parser.
  bound="$(tmux -L "${sock}" list-keys -T prefix | sed -n 's/^[[:space:]]*bind-key[[:space:]]*-T prefix[[:space:]]*m[[:space:]]\{1,\}//p' | head -1)"
  [[ "${bound}" == *"set -g mouse"* || "${bound}" == *"set-option -g mouse"* ]] || {
    echo "Prefix m is bound to: ${bound}" >&2; return 1; }
  cmd="${BATS_TEST_TMPDIR}/bound-mouse.conf"
  # list-keys quotes the sub-command separator for the command prompt, where a
  # shell has already eaten one level of escaping; in a config file the escaped
  # form is one argument to the first command. Undo it so the line the binding
  # stores runs exactly as a pressed Prefix m runs it.
  printf '%s\n' "${bound//\\;/;}" >"${cmd}"
  run tmux -L "${sock}" source-file "${cmd}"
  [ "${status}" -eq 0 ] || {
    echo "the bound command failed to run: ${output}" >&2; return 1; }
  run tmux -L "${sock}" show-options -g mouse
  [ "${output}" = "mouse off" ] || {
    echo "the bound command left the option at: ${output}" >&2; return 1; }
  run tmux -L "${sock}" source-file "${cmd}"
  run tmux -L "${sock}" show-options -g mouse
  [ "${output}" = "mouse on" ] || {
    echo "the second run left the option at: ${output}" >&2; return 1; }
  scratch_tmux_reap
}

# The attach helper (the default "tmux" terminal profile) starts its own
# server on the default socket, so these tests isolate it by pointing
# TMUX_TMPDIR into the per-test scratch tree and clear TMUX, which would
# otherwise pin every tmux call to whoever's session the runner sits in.
# Cleanup starts with the server kill; killing the backgrounded job pids is
# unsafe under coverage instrumentation, where those pids may already refer to
# unrelated recycled processes, so the one sweep teardown adds matches a server
# by the scratch cwd in its own argv (see attach_reap).
ATTACH_TMPDIR=""
ATTACH_CWD=""

attach_reap() {
  [ -n "${ATTACH_TMPDIR}" ] || return 0
  # timeout(1) on the kill, not around it: a server caught in the session
  # teardown race answers no more commands, and an unbounded kill-server there
  # is what left bats alive for minutes after the last ok. The argv sweep below
  # is what actually reaps a server that will not answer.
  timeout -k 2 10 env -u TMUX TMUX_TMPDIR="${ATTACH_TMPDIR}" tmux kill-server >/dev/null 2>&1 || true
  # The server kill is not always the last word: a server bootstrapped by a
  # tab can still be coming up, and a server left alive keeps its tab client
  # attached, which holds the runner's output open and hangs bats after the
  # last ok. That server carries this test's own scratch cwd in its argv (the
  # -c of the create that started it), so the sweep can only ever reach a
  # server this test brought up.
  if [ -n "${ATTACH_CWD}" ]; then
    # Both patterns carry this test's own folder hash, which is the cksum of
    # this test's scratch cwd. The create's argv holds the cwd anyway; the
    # tab's attach does not, so it has to be matched by the session name, and
    # matching the bare `vscode-proj-` stem instead was a cross-run collision:
    # Bazel runs six copies of this file at once, and each copy's teardown
    # SIGKILLed the other five's tab clients mid-attach, which their helpers
    # read as a lost rejoin and answered by raising yet another session.
    # Killing a tmux client only ever ends that tab, never a pane, which is
    # what makes a sweep like this safe to run at all.
    local stem
    stem=$(printf '%s' "${ATTACH_CWD}" | cksum 2>/dev/null | awk '{print substr($1, 1, 6)}')
    if [ -n "${stem}" ]; then
      pkill -9 -f "vscode-proj-${stem}.*-c ${ATTACH_CWD}" >/dev/null 2>&1 || true
      pkill -9 -f "attach-session -t =vscode-proj-${stem}" >/dev/null 2>&1 || true
    fi
  fi
  ATTACH_TMPDIR=""
  ATTACH_CWD=""
}

# run_attach_helper <tmpdir> <cwd> — background the payload under a pty, the
# same shape VS Code uses (bash -lc exec helper), script supplying the tty.
run_attach_helper() {
  local tmpdir="$1" cwd="$2" helper
  helper="${REPO_ROOT}/templates/common/vscode-terminal-tmux.sh"
  # EVO_TAB_X=1 runs each tab under `bash -x` with its trace in the test's
  # tmpdir, and the rejoin assertions below dump those traces when they fail.
  # It costs nothing when unset, and it is the only thing that ever told an
  # operator which branch the helper took: a lost rejoin looks identical from
  # the outside whether the scan misread the server, a control call failed, or
  # something SIGKILLed the client halfway through the attach.
  local xflag="" tablog="/dev/null"
  if [ -n "${EVO_TAB_X:-}" ]; then
    xflag="-x "
    TAB_LOG_N=$((${TAB_LOG_N:-0} + 1))
    tablog="${tmpdir}/tablog.${TAB_LOG_N}"
  fi
  ATTACH_TMPDIR="${tmpdir}"
  ATTACH_CWD="${cwd}"
  # setsid --fork puts the tab in its own session, reparented to init: it is
  # then neither a job the runner waits on nor a holder of the runner's
  # output pipe, which is how a tab that outlived its test used to stall bats
  # after the last ok.
  #
  # That is not enough on its own. bats reads this test's output from a pipe,
  # and every descriptor above 0-2 is inherited across the exec, so a tab that
  # lives on while its tmux client is stuck keeps the write end of that pipe
  # open and bats waits forever -- it prints the last ok and never exits, which
  # is how this suite outlived the 300s test timeout under parallel runs.
  # Redirecting 0-2 (below) does not touch the pipe; closing the descriptors
  # above it does, and leaves a wedged tab as the orphan it should have been.
  # bash, unlike sh, treats closing an unopened descriptor as harmless, and
  # this runs in the bats shell, so the loop cannot abort the exec.
  (
    local fd
    for fd in $(seq 3 64); do
      # shellcheck disable=SC2294
      eval "exec ${fd}>&-" 2>/dev/null
    done
    exec setsid --fork env -u TMUX -C "${cwd}" TERM=xterm-256color TMUX_TMPDIR="${tmpdir}" \
      script -qec "bash ${xflag}'${helper}'" "${tablog}" >/dev/null 2>&1
  )
}

# dump_tablogs <tmpdir> - print what each tab's helper decided, when the traces
# were asked for (EVO_TAB_X=1) and an assertion is about to fail anyway.
dump_tablogs() {
  local tl
  for tl in "${1}"/tablog.*; do
    [ -f "${tl}" ] || continue
    echo "--- $(basename "${tl}") ---"
    grep -E 'scan=|scan_ok|existing=|name=|tmux_q|new-session|attach-session|has-session|Killed|error' "${tl}" 2>/dev/null | tail -30
  done
}

# attach_wait <tmpdir> <want-sessions|-> <want-clients> - poll until the server
# reports both counts (pass "-" for a count that is the thing under test) or the
# budget runs out.
# A server caught in the session teardown race stops answering any command, so
# the budget here is a wall-clock deadline with a per-call timeout and a bail
# once the server has really gone quiet: a stalled server is a failed test, not
# a slow one, and an unbounded poll is how this suite once sat past the 300s
# test timeout waiting on a server that was never going to answer.
#
# A slow server is a retry and a dead one is a verdict, and the two used to be
# the same thing here: an empty read counted as a miss whether tmux had refused
# the connection or `timeout` had given up on it, so six suites running at once
# on one CPU could bail out early, and the caller would then reopen a tab
# against a session it only thought was free. Hence the 124 test and the longer
# per-call budget.
attach_wait() {
  local tmpdir="$1" want_sessions="$2" want_clients="$3"
  local deadline=$((SECONDS + 60)) misses=0 s c rs rc
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    s=$(timeout -k 2 10 env -u TMUX TMUX_TMPDIR="${tmpdir}" tmux list-sessions 2>/dev/null) && rs=0 || rs="${?}"
    c=$(timeout -k 2 10 env -u TMUX TMUX_TMPDIR="${tmpdir}" tmux list-clients 2>/dev/null) && rc=0 || rc="${?}"
    if [ "${rs}" != 0 ] && [ "${rs}" != 124 ] &&
      [ "${rc}" != 0 ] && [ "${rc}" != 124 ]; then
      misses=$((misses + 1))
      [ "${misses}" -ge 5 ] && return 1
    else
      misses=0
      {
        [ "${want_sessions}" = "-" ] ||
          [ "$(printf '%s\n' "${s}" | grep -c .)" = "${want_sessions}" ]
      } &&
        [ "$(printf '%s\n' "${c}" | grep -c .)" = "${want_clients}" ] &&
        return 0
    fi
    sleep 0.25
  done
  return 1
}

# attach_wait_clients <tmpdir> <want-clients> - poll on the client count alone,
# for the case where the session count is the thing under test.
attach_wait_clients() {
  attach_wait "$1" "-" "$2"
}

@test "attach helper: concurrent tabs own one session each, a closed tab rejoins" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  command -v script >/dev/null 2>&1 || skip "script(1) not on PATH"
  env -C / true 2>/dev/null || skip "env lacks -C"
  local helper="${REPO_ROOT}/templates/common/vscode-terminal-tmux.sh"
  [ -f "${helper}" ] || skip "attach payload missing"
  local work="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "${work}"
  ATTACH_TMPDIR="${BATS_TEST_TMPDIR}/tmux-sockets"
  mkdir -p "${ATTACH_TMPDIR}"
  local names i
  TXA() { timeout -k 2 10 env -u TMUX TMUX_TMPDIR="${ATTACH_TMPDIR}" tmux "$@"; }

  # Bring the server up here rather than letting the first tab do it. The tab
  # that bootstraps the server is the one case where tmux 3.4 can take the
  # session down with the tab (see the note in the payload), so asserting a
  # rejoin against that session is a coin flip under instrumentation. The
  # warm-up stays for the whole test to keep the server out of exit-empty, and
  # its name carries the stem so the teardown sweep still recognises the
  # server it forked, while the helper's own folder-prefix scan skips it.
  TXA new-session -d -s vscode-proj-warmup -c "${work}" >/dev/null 2>&1
  attach_wait "${ATTACH_TMPDIR}" 1 0 || {
    echo "the scratch server never came up" >&2; return 1; }

  run_attach_helper "${ATTACH_TMPDIR}" "${work}"
  attach_wait "${ATTACH_TMPDIR}" 2 1 || {
    echo "the first terminal never brought up a session" >&2; return 1; }

  # A second terminal beside a live one must not mirror it.
  run_attach_helper "${ATTACH_TMPDIR}" "${work}"
  attach_wait "${ATTACH_TMPDIR}" 3 2 || {
    echo "the second terminal mirrored the first instead of taking its own session" >&2; return 1; }
  names=$(TXA list-sessions -F '#{session_name}' | grep '^vscode-proj-' | grep -vx 'vscode-proj-warmup' | sort)
  [[ "${names}" == vscode-proj-* ]] || {
    echo "session names stray from the folder stem: ${names}" >&2; return 1; }
  # list-sessions is creation order and the sort puts the base name (the
  # folder cksum) before any numbered sibling, so the first line is the base.
  local base n
  base=$(printf '%s\n' "${names}" | head -n 1)
  for n in ${names}; do
    [[ "${n}" == "${base}" || "${n}" == "${base}"-[0-9]* ]] || {
      echo "session ${n} is not the base ${base} or a numbered sibling" >&2; return 1; }
  done
  [ "$(TXA list-sessions -F '#{session_attached} #{session_name}' | grep ' vscode-proj-' | grep -v ' vscode-proj-warmup' | awk '{print $1}' | sort -u | tr -d '\n')" = "1" ] || {
    echo "a session carries two clients (a mirror): $(TXA list-sessions)" >&2; return 1; }

  # Closing a tab leaves its session unattached; the next terminal walks back
  # into it (no new session is born, the client count returns to two). The
  # tab closes through the server rather than by killing the pty wrapper's
  # pid: under coverage instrumentation the job pid is not the client
  # process, and killing the wrong recycled pid is how this test once wiped
  # its own scratch server.
  TXA detach-client -s "${base}" || {
    echo "the scratch server would not close the tab" >&2; return 1; }
  attach_wait_clients "${ATTACH_TMPDIR}" 1 || {
    {
      echo "the closed tab left the wrong client count, so the reopen below"
      echo "would be scanning a folder whose sessions are all still watched:"
      TXA list-sessions -F '  #{session_attached} #{session_name}'
    } >&2
    return 1; }
  # tmux 3.4 sometimes takes a session down with the client that was its last,
  # which is the loss the payload absorbs rather than handing the operator a
  # dead tab, so the surviving count here is the folder's pair or, when the
  # race was lost, the sibling alone.
  local live
  live=$(TXA list-sessions 2>/dev/null | wc -l)
  [ "${live}" = "3" ] || [ "${live}" = "2" ] || {
    echo "unexpected session count after the close: ${live}" >&2; return 1; }

  run_attach_helper "${ATTACH_TMPDIR}" "${work}"
  if [ "${live}" = "3" ] &&
    ! attach_wait "${ATTACH_TMPDIR}" 3 2; then
    {
      echo "reopening did not rejoin the detached session"
      TXA list-sessions 2>&1 | sed 's/^/  session: /'
      TXA list-clients -F 'client: #{session_name} #{window_name}' 2>&1 | sed 's/^/  /'
      TXA list-panes -a -F 'pane: #{session_name} dead=#{pane_dead}#{pane_dead_status} cmd=#{pane_current_command}' 2>&1 | sed 's/^/  /'
      dump_tablogs "${ATTACH_TMPDIR}"
    } >&2
    return 1
  elif [ "${live}" = "2" ] &&
    ! attach_wait_clients "${ATTACH_TMPDIR}" 2; then
    {
      echo "the reopen left the tab without a terminal of its own"
      TXA list-sessions 2>&1 | sed 's/^/  session: /'
      TXA list-clients -F 'client: #{session_name}' 2>&1 | sed 's/^/  /'
    } >&2
    return 1
  fi
  # Whatever survived the close, two live tabs must mean two clients and no
  # session watched twice.
  [ "$(TXA list-sessions -F '#{session_attached} #{session_name}' | grep ' vscode-proj-' | grep -v ' vscode-proj-warmup' | awk '{print $1}' | sort -u | tr -d '\n')" = "1" ] || {
    echo "the reopen mirrored a live session: $(TXA list-sessions)" >&2; return 1; }
  [ -z "$(TXA list-panes -a -F '#{pane_dead}' | grep -v '^0$')" ] || {
    echo "the reopen left a dead pane: $(TXA list-panes -a)" >&2; return 1; }
  TXA kill-server 2>/dev/null || true
}

@test "attach helper: every session target uses tmux's exact-match prefix" {
  local helper="${REPO_ROOT}/templates/common/vscode-terminal-tmux.sh"
  [ -f "${helper}" ] || skip "attach payload missing"
  # A bare target also matches any session whose name starts with it, so a
  # name whose session is gone answers from a numbered sibling. Here that
  # reads as "this one is free" and walks a new tab into a live pane as a
  # second client -- the mirror the numbering exists to prevent.
  [ "$(grep -Ec 'attach-session -t "=' "${helper}")" -ge 2 ] || {
    echo "both attaches must address their session exactly" >&2; return 1; }
  [ "$(grep -Ec 'has-session -t "=' "${helper}")" -ge 2 ] || {
    echo "both existence probes must address their session exactly" >&2; return 1; }
  [ "$(grep -Ec 'attach-session -t "[^=]' "${helper}")" = "0" ] || {
    echo "a bare attach-session target survives: $(grep -En 'attach-session -t "[^=]' "${helper}")" >&2
    return 1; }
  [ "$(grep -Ec 'has-session -t "[^=]' "${helper}")" = "0" ] || {
    echo "a bare has-session target survives: $(grep -En 'has-session -t "[^=]' "${helper}")" >&2
    return 1; }
}

@test "attach helper: one bounded snapshot decides which session to reuse" {
  local helper="${REPO_ROOT}/templates/common/vscode-terminal-tmux.sh"
  [ -f "${helper}" ] || skip "attach payload missing"
  # Three separate queries answered three questions about the same decision, so
  # a tab attaching in between could make a busy session look free, and a scan
  # that timed out answered with no lines at all -- indistinguishable from a
  # folder with no sessions, which orphaned an idle session and raised a second
  # one beside it. The helper now reads the list once, bounded, and reads the
  # exit status to tell a failed scan from an empty one.
  [ "$(grep -Ec 'tmux_q list-sessions' "${helper}")" = "1" ] || {
    echo "the reuse decision must come from one list-sessions snapshot: $(grep -En 'list-sessions' "${helper}")" >&2
    return 1; }
  grep -Eq 'scan_ok=1' "${helper}" || {
    echo "the scan result is not checked, so a timeout reads as no sessions" >&2; return 1; }
  grep -Eq 'attempt.*-lt 2' "${helper}" || {
    echo "the scan retry is not bounded" >&2; return 1; }
}

@test "attach helper: a dead session's name cannot be borrowed by a live sibling" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not on PATH (the golden image ships it)"
  command -v script >/dev/null 2>&1 || skip "script(1) not on PATH"
  env -C / true 2>/dev/null || skip "env lacks -C"
  local helper="${REPO_ROOT}/templates/common/vscode-terminal-tmux.sh"
  [ -f "${helper}" ] || skip "attach payload missing"
  local work="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "${work}"
  ATTACH_TMPDIR="${BATS_TEST_TMPDIR}/tmux-sockets"
  mkdir -p "${ATTACH_TMPDIR}"
  local base i
  TXA() { timeout -k 2 10 env -u TMUX TMUX_TMPDIR="${ATTACH_TMPDIR}" tmux "$@"; }

  # Warm the server up first, for the reason spelled out in the test above.
  TXA new-session -d -s vscode-proj-warmup -c "${work}" >/dev/null 2>&1
  attach_wait "${ATTACH_TMPDIR}" 1 0 || {
    echo "the scratch server never came up" >&2; return 1; }

  run_attach_helper "${ATTACH_TMPDIR}" "${work}"
  attach_wait "${ATTACH_TMPDIR}" 2 1 || {
    echo "the first terminal never brought up a session" >&2; return 1; }
  run_attach_helper "${ATTACH_TMPDIR}" "${work}"
  attach_wait "${ATTACH_TMPDIR}" 3 2 || {
    echo "the second terminal mirrored the first" >&2; return 1; }
  base=$(TXA list-sessions -F '#{session_name}' | grep '^vscode-proj-' | grep -vx 'vscode-proj-warmup' | head -n 1)

  # Destroy the base session outright, which is what tmux 3.4 does to a
  # session under a losing rejoin race, and leave its sibling attached. The
  # dead name still resolves by prefix from the sibling, so a reopen that
  # trusts a bare target joins the live pane instead of starting its own.
  TXA kill-session -t "=${base}" || {
    echo "the scratch server would not destroy the session" >&2; return 1; }
  attach_wait "${ATTACH_TMPDIR}" 2 1 || {
    {
      echo "the sibling did not come through the kill attached and alone, so the"
      echo "reopen below could read it as free and put a second client on it:"
      TXA list-sessions -F '  #{session_attached} #{session_name}'
    } >&2
    return 1; }
  [ "$(TXA list-sessions 2>/dev/null | wc -l)" = "2" ] || {
    echo "the base session outlived its kill" >&2; return 1; }

  run_attach_helper "${ATTACH_TMPDIR}" "${work}"
  if ! attach_wait "${ATTACH_TMPDIR}" 3 2; then
    {
      echo "the reopen did not bring up a terminal of its own"
      TXA list-sessions 2>&1 | sed 's/^/  session: /'
      TXA list-clients -F 'client: #{session_name}' 2>&1 | sed 's/^/  /'
      dump_tablogs "${ATTACH_TMPDIR}"
    } >&2
    return 1
  fi
  [ "$(TXA list-sessions -F '#{session_attached} #{session_name}' | grep ' vscode-proj-' | grep -v ' vscode-proj-warmup' | awk '{print $1}' | sort -u | tr -d '\n')" = "1" ] || {
    echo "the reopen mirrored the live sibling: $(TXA list-sessions)" >&2; return 1; }
  [ -z "$(TXA list-panes -a -F '#{pane_dead}' | grep -v '^0$')" ] || {
    echo "the reopen left a dead pane: $(TXA list-panes -a)" >&2; return 1; }
  TXA kill-server 2>/dev/null || true
}
