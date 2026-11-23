#!/usr/bin/env bats
#
# ## grok-profile.bats - the per-workspace Grok profile topology in both twins.
#
# The contract pinned here, read off the template text as data: `shared` mode shares
# only the three state concerns, each nested under /home/coder/.grok/ on its own
# owner-keyed volume, and never the whole CLI profile -- config.toml is a real
# per-workspace file. The old owner volume comes back exactly once, READ-ONLY, at
# /home/coder/.grok-legacy, so the boot can drain it but can never write into a volume
# a sibling workspace still owns; a writable legacy mount is a bug, not a fallback.
# `private` mode emits none of the four. Both themes and the approval mode are
# per-workspace mutable coder_parameters, and code-server's User/settings.json is a real
# file the stack writes, not a symlink onto the shared editor overlay.
#
# Every assertion loops over BOTH twins, because the two trees are independent payload
# copies and a fix that lands in one of them alone has to go red. The [ui] carry-over
# passes are not read as text but lifted out of the twin and EXECUTED over a render, so a
# fold that emits a second [ui] table, or leaves the render's own key sitting beside the
# operator's copy of it, is caught rather than grepped for; so is the probe that names the
# approval mode the boot drops. The [permission] note and the dropdown's option fields are
# byte-compared BETWEEN the twins, since nothing else compares them and they have split
# once already. The four operator pages that teach this behaviour are read as prose too:
# a claim there is one sentence naming the parameter, the seed variable and the shipped
# default, never a whole paragraph matched byte for byte. The whole suite
# skips while any template it reads is absent: a suite for a topology the tree does
# not ship has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_grok_profile_test   (from any cwd)
# Safety: reads the two template trees and the operator pages that teach this behaviour as
# data; runs awk and python3 over fixtures it builds itself; no terraform, no docker
# daemon, no network; writes nothing outside the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
TEMPLATES=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  TEMPLATES="${REPO_ROOT}/templates"
  local twin f
  for twin in workspace devcontainer; do
    for f in main.tf coder.tf startup.sh.tftpl grok-config.toml.tftpl; do
      if [ ! -f "${TEMPLATES}/${twin}/${f}" ]; then
        skip "templates/${twin}/${f} is not in the tree"
      fi
    done
  done
}

# twin_file <twin> <file> - print one template payload's path.
twin_file() {
  printf '%s' "${TEMPLATES}/$1/$2"
}

# count_match <ere> <file> - print how many lines of <file> match the ERE (0 for none).
count_match() {
  local n
  n="$(grep -Ec -- "$1" "$2" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# require_line <label> <ere> <file> - fail naming <label> when no line matches.
require_line() {
  if ! grep -Eq -- "$2" "$3"; then
    printf 'FAIL: %s: no line in %s matches /%s/\n' "$1" "$3" "$2" >&2
    return 1
  fi
}

# require_absent <label> <ere> <file> - fail naming <label> when any line matches.
require_absent() {
  local n
  n="$(count_match "$2" "$3")"
  if [[ "${n}" != "0" ]]; then
    printf 'FAIL: %s: %s line(s) in %s match /%s/\n' "$1" "${n}" "$3" "$2" >&2
    return 1
  fi
}

# require_count <label> <want> <ere> <file> - fail unless exactly <want> lines match.
require_count() {
  local n
  n="$(count_match "$3" "$4")"
  if [[ "${n}" != "$2" ]]; then
    printf 'FAIL: %s: expected %s line(s) matching /%s/ in %s, found %s\n' \
      "$1" "$2" "$3" "$4" "${n}" >&2
    return 1
  fi
}

# require_fixed <label> <string> <file> - fail unless the literal <string> is present.
require_fixed() {
  if ! grep -Fq -- "$2" "$3"; then
    printf 'FAIL: %s: %s does not contain the line: %s\n' "$1" "$3" "$2" >&2
    return 1
  fi
}

# require_in <label> <ere> <text> - fail naming <label> when <text> holds no match.
require_in() {
  if ! printf '%s\n' "$3" | grep -Eq -- "$2"; then
    printf 'FAIL: %s: no line matches /%s/\n' "$1" "$2" >&2
    return 1
  fi
}

# hcl_block <header-ere> <file> - print the block whose header line matches <ere>, up to
# the first line that is a lone closing brace. The header is matched, not constructed, so
# the caller states the block it means in the file's own words.
hcl_block() {
  awk -v hdr="$1" '
    !f && $0 ~ hdr { f = 1 }
    f { print }
    f && /^\}[[:space:]]*$/ { exit }
  ' "$2"
}

@test "grok_profile: neither twin mounts the whole .grok profile as one volume" {
  local twin mf
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    require_absent "whole-profile grok mount" 'container_path = "/home/coder/\.grok"' "${mf}" || return 1
  done
}

@test "grok_profile: the shared mounts come from one dynamic block gated on grok_profile_shared" {
  local twin mf
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    require_count "one dynamic volumes block" 1 '^[[:space:]]*dynamic "volumes" \{$' "${mf}" || return 1
    require_fixed "shared-mode gate" 'for_each = local.grok_profile_shared ? [' "${mf}" || return 1
    require_line "private mode emits none" '\] : \[\]$' "${mf}" || return 1
    require_count "container_path from the iterator" 1 'container_path[[:space:]]*= volumes\.value\.path' "${mf}" || return 1
    require_count "volume_name from the iterator" 1 'volume_name[[:space:]]*= volumes\.value\.name' "${mf}" || return 1
    require_count "read_only from the iterator" 1 'read_only[[:space:]]*= volumes\.value\.ro' "${mf}" || return 1
  done
}

@test "grok_profile: the three state concerns mount nested under .grok read-write" {
  local twin mf concern want
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    for concern in notes memory sessions; do
      want="{ path = \"/home/coder/.grok/${concern}\", name = local.grok_${concern}_volume, ro = false }"
      require_fixed "nested ${concern} container_path on its owner volume" "${want}" "${mf}" || return 1
    done
    require_count "three writable state mounts" 3 'ro = false' "${mf}" || return 1
    require_absent "state concern mounted read-only" \
      '\.grok/(notes|memory|sessions)", name = local\.grok_(notes|memory|sessions)_volume, ro = true' "${mf}" || return 1
  done
}

@test "grok_profile: the legacy owner volume mounts read-only as the one-time hoist source" {
  local twin mf
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    require_fixed "legacy hoist entry" \
      '{ path = "/home/coder/.grok-legacy", name = local.grok_profile_volume, ro = true }' "${mf}" || return 1
    require_count "read-only mounts in the block" 1 'ro = true' "${mf}" || return 1
    require_absent "writable legacy mount" '\.grok-legacy", name = local\.grok_profile_volume, ro = false' "${mf}" || return 1
  done
}

@test "grok_profile: the four volume names are owner-keyed locals, not declared resources" {
  local twin mf
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    require_line "notes volume local" 'grok_notes_volume[[:space:]]*=[[:space:]]*"grok-notes-\$\{data\.coder_workspace_owner\.me\.id\}"' "${mf}" || return 1
    require_line "memory volume local" 'grok_memory_volume[[:space:]]*=[[:space:]]*"grok-memory-\$\{data\.coder_workspace_owner\.me\.id\}"' "${mf}" || return 1
    require_line "sessions volume local" 'grok_sessions_volume[[:space:]]*=[[:space:]]*"grok-sessions-\$\{data\.coder_workspace_owner\.me\.id\}"' "${mf}" || return 1
    require_line "legacy volume local kept" 'grok_profile_volume[[:space:]]*=[[:space:]]*"grok-profile-\$\{data\.coder_workspace_owner\.me\.id\}"' "${mf}" || return 1
    require_absent "declared grok volume resource" 'resource "docker_volume" "grok_' "${mf}" || return 1
  done
}

@test "grok_profile: both themes are mutable coder_parameters over their variable defaults" {
  local twin mf cf body name
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    cf="$(twin_file "${twin}" coder.tf)"
    for name in grok_theme vscode_color_theme; do
      body="$(hcl_block "^data \"coder_parameter\" \"${name}\"" "${mf}")"
      if [[ -z "${body}" ]]; then
        printf 'FAIL: %s: no coder_parameter block for %s\n' "${mf}" "${name}" >&2
        return 1
      fi
      require_in "${name} is mutable" '^[[:space:]]*mutable[[:space:]]*=[[:space:]]*true' "${body}" || return 1
      require_in "${name} defaults to its variable" "^[[:space:]]*default[[:space:]]*=[[:space:]]*var\.${name}" "${body}" || return 1
      body="$(hcl_block "^variable \"${name}\"" "${cf}")"
      if [[ -z "${body}" ]]; then
        printf 'FAIL: %s: no variable block for %s\n' "${cf}" "${name}" >&2
        return 1
      fi
      require_in "${name} is a string variable" '^[[:space:]]*type[[:space:]]*=[[:space:]]*string' "${body}" || return 1
    done
    body="$(hcl_block '^variable "grok_theme"' "${cf}")"
    require_in "grok_theme default" '^[[:space:]]*default[[:space:]]*=[[:space:]]*"grokbuild"' "${body}" || return 1
    body="$(hcl_block '^variable "vscode_color_theme"' "${cf}")"
    require_in "vscode_color_theme default" '^[[:space:]]*default[[:space:]]*=[[:space:]]*"Default Dark Modern"' "${body}" || return 1
  done
}

@test "grok_profile: grok_permission_mode is a mutable coder_parameter over the always-approve variable default" {
  local twin mf cf body
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    cf="$(twin_file "${twin}" coder.tf)"
    body="$(hcl_block '^data "coder_parameter" "grok_permission_mode"' "${mf}")"
    if [[ -z "${body}" ]]; then
      printf 'FAIL: %s: no coder_parameter block for grok_permission_mode\n' "${mf}" >&2
      return 1
    fi
    require_in "grok_permission_mode is a string parameter" '^[[:space:]]*type[[:space:]]*=[[:space:]]*"string"' "${body}" || return 1
    require_in "grok_permission_mode is mutable" '^[[:space:]]*mutable[[:space:]]*=[[:space:]]*true' "${body}" || return 1
    require_in "grok_permission_mode defaults to its variable" '^[[:space:]]*default[[:space:]]*=[[:space:]]*var\.grok_permission_mode' "${body}" || return 1
    require_line "the render receives the parameter" \
      'grok_permission_mode[[:space:]]*=[[:space:]]*data\.coder_parameter\.grok_permission_mode\.value' "${mf}" || return 1
    body="$(hcl_block '^variable "grok_permission_mode"' "${cf}")"
    if [[ -z "${body}" ]]; then
      printf 'FAIL: %s: no variable block for grok_permission_mode\n' "${cf}" >&2
      return 1
    fi
    require_in "grok_permission_mode is a string variable" '^[[:space:]]*type[[:space:]]*=[[:space:]]*string' "${body}" || return 1
    require_in "grok_permission_mode ships always-approve" '^[[:space:]]*default[[:space:]]*=[[:space:]]*"always-approve"' "${body}" || return 1
  done
}

@test "grok_profile: the grok_permission_mode parameter offers exactly the four accepted approval modes" {
  local twin mf body n mode
  for twin in workspace devcontainer; do
    mf="$(twin_file "${twin}" main.tf)"
    body="$(hcl_block '^data "coder_parameter" "grok_permission_mode"' "${mf}")"
    if [[ -z "${body}" ]]; then
      printf 'FAIL: %s: no coder_parameter block for grok_permission_mode\n' "${mf}" >&2
      return 1
    fi
    n="$(printf '%s\n' "${body}" | grep -Ec -- '^[[:space:]]*option \{$' || true)"
    if [[ "${n}" != "4" ]]; then
      printf 'FAIL: %s: the approval-mode dropdown has %s option block(s), expected 4\n' "${mf}" "${n}" >&2
      return 1
    fi
    for mode in default ask auto always-approve; do
      require_in "the dropdown offers ${mode}" \
        "^[[:space:]]*value[[:space:]]*=[[:space:]]*\"${mode}\"[[:space:]]*$" "${body}" || return 1
    done
  done
}

@test "grok_profile: the boot writes code-server settings as a real file, never a symlink" {
  local twin sf
  for twin in workspace devcontainer; do
    sf="$(twin_file "${twin}" startup.sh.tftpl)"
    require_absent "symlink onto the shared settings" 'ln -sfn[[:space:]]+"\$shared_settings"' "${sf}" || return 1
    require_absent "any symlink onto user settings" 'ln -s[[:space:]].*user_settings' "${sf}" || return 1
    require_fixed "per-workspace settings heredoc" \
      'cat >"$user_settings_new" <<'"'"'VSCODE_USER_SETTINGS_EOF'"'"'' "${sf}" || return 1
    require_fixed "atomic real-file publish" 'mv -f "$user_settings_new" "$user_settings"' "${sf}" || return 1
    require_fixed "an operator symlink is left alone" '[ -L "$user_settings" ]' "${sf}" || return 1
  done
}

# lift_ui_fold <startup> <out> - write the [ui] carry-over awk PROGRAM out of the
# shipped twin into <out>. It is the single-quoted argument of the `awk -v ui=`
# call, whose shell line continuations end at the heredoc opener, so the joined
# text between the outer quotes is the program. Lifting it rather than retyping it
# is the point: rewrite the twin's fold and this is the text that gets executed.
lift_ui_fold() {
  awk '
    !s && /^[[:space:]]*awk -v ui=/ { s = 1; next }
    s {
      t = $0
      if (match(t, /<<.GROK_CONFIG_EOF./)) { t = substr(t, 1, RSTART - 1) }
      if (t ~ /[\\][[:space:]]*$/) { sub(/[[:space:]]*\\[[:space:]]*$/, "", t); buf = buf t }
      else { buf = buf t; fin = 1; exit }
    }
    END { if (!fin) exit 1; print buf }
  ' "$1" | sed -e "s/^[^']*'//" -e "s/'[^']*\$//" >"$2"
  [ -s "$2" ]
}

# lift_ui_strip <startup> <out> - write the [ui] STRIP awk PROGRAM out of the shipped
# twin into <out>: the single-quoted argument of the bare `awk` call that reads the
# operator's own file, whose shell continuation ends at the redirect. The strip and the
# fold are one mechanism, so both are lifted and run as the pair the twin ships.
lift_ui_strip() {
  awk '
    !s && /^[[:space:]]*awk / && index($0, "f=1;next") && index($0, "f=0}") { s = 1 }
    s {
      t = $0
      if (t ~ /[\\][[:space:]]*$/) { sub(/[[:space:]]*\\[[:space:]]*$/, "", t); buf = buf t; next }
      buf = buf t; fin = 1; exit
    }
    END { if (!fin) exit 1; print buf }
  ' "$1" | sed -e "s/^[^']*'//" -e "s/'[^']*\$//" >"$2"
  [ -s "$2" ]
}

# lift_ui_probe <startup> <out> - write the dropped-mode PROBE awk PROGRAM out of the
# shipped twin into <out>: the single-quoted argument of the `awk` call that reads the
# operator's [ui] table for the approval mode this boot is about to drop, so the boot
# note can name it. It is deliberately a different program from the strip pass - the
# probe tracks its own `u` flag and stops at the first match, the strip tracks `f` and
# keeps every surviving line - so it is lifted on its own shape and EXECUTED, never
# assumed to be the strip under another name.
lift_ui_probe() {
  awk '
    !s && index($0, "dropped_mode=\"$(awk ") && index($0, "u=1;next") && index($0, "u=0") { s = 1 }
    s {
      t = $0
      if (t ~ /[\\][[:space:]]*$/) { sub(/[[:space:]]*\\[[:space:]]*$/, "", t); buf = buf t; next }
      buf = buf t; fin = 1; exit
    }
    END { if (!fin) exit 1; print buf }
  ' "$1" | sed -e "s/^[^']*'//" -e "s/'[^']*\$//" >"$2"
  [ -s "$2" ]
}

# sentences <flat> - split flattened prose into one sentence per line, on the
# sentence-final punctuation this prose uses.
sentences() {
  printf '%s\n' "$1" | sed -E 's/([.!?])[[:space:]]+/\1\n/g'
}

# one_sentence_names <label> <flat> <ere>... - fail unless ONE sentence of the
# flattened <flat> prose matches every <ere>. The operator pages are hard-wrapped and
# get reworded, so a claim here is "some sentence says all of this at once", which a
# byte-for-byte paragraph match would break on the first edit that kept the meaning.
one_sentence_names() {
  local label="$1" text="$2"
  shift 2
  local -a wants=("$@")
  local part w ok
  while IFS= read -r part; do
    ok=1
    for w in "${wants[@]}"; do
      if ! printf '%s\n' "${part}" | grep -Eq -- "${w}"; then
        ok=0
        break
      fi
    done
    if [[ "${ok}" == "1" ]]; then
      return 0
    fi
  done < <(sentences "${text}")
  printf 'FAIL: %s: no single sentence names all of: %s\n' "${label}" "${wants[*]}" >&2
  return 1
}

# permission_note <config-twin> - the comment block the render ships above
# [permission]: from the sentence that opens the approval-mode story to the table it
# documents, which is the prose the two config twins have to agree on word for word.
permission_note() {
  awk '
    /^# The approval mode ships as a stack default/ { f = 1 }
    /^\[permission\][[:space:]]*$/ { exit }
    f { print }
  ' "$1"
}

# dropdown_fields <main.tf> - the option `name` and `description` lines of the
# approval-mode dropdown, in file order, comments and layout dropped so the twin that
# re-indents or re-comments the block still reads as the same four choices.
dropdown_fields() {
  hcl_block '^data "coder_parameter" "grok_permission_mode"' "$1" | awk '
    /^[[:space:]]*option \{[[:space:]]*$/ { i = 1; next }
    i && /^[[:space:]]*\}[[:space:]]*$/ { i = 0; next }
    i && /^[[:space:]]*(name|description)[[:space:]]*=/ { print }
  '
}

@test "grok_profile: the [ui] carry-over folds the operator keys into the render's own table" {
  # The render already opens one [ui] table, so the carry-over must fold the
  # operator's other [ui] keys INTO it. A fold that emits a table of its own is a
  # duplicate TOML table (tomllib: Cannot declare ('ui',) twice), which is the bug
  # this executes for. Both twins carry the same awk, so both are run.
  local twin sf dir keys render bare
  for twin in workspace devcontainer; do
    sf="$(twin_file "${twin}" startup.sh.tftpl)"
    dir="$(make_scratch)"
    if ! lift_ui_fold "${sf}" "${dir}/fold.awk"; then
      printf 'FAIL: %s: no [ui] carry-over awk to lift\n' "${sf}" >&2
      return 1
    fi
    keys="${dir}/keys"
    # The two keys here are ones the render never writes: the strip pass upstream
    # drops the render-owned keys from this fixture, and the case below executes
    # that for permission_mode, so the fold is proven on genuinely operator keys.
    printf '%s\n' 'remember_tool_approvals = true' 'banner = "keep me"' >"${keys}"
    # Case 1: the render owns [ui] with the theme, and a model table follows it.
    render="${dir}/render"
    printf '%s\n' '[ui]' 'theme = "grokbuild"' '' '[model."agent"]' \
      'reasoning_effort = "high"' >"${render}"
    awk -f "${dir}/fold.awk" -v ui="${keys}" <"${render}" >"${dir}/out"
    python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "${dir}/out" || {
      printf 'FAIL: %s: the folded config is not valid TOML:\n%s\n' "${sf}" \
        "$(cat "${dir}/out")" >&2
      return 1
    }
    require_count "one [ui] table after the fold" 1 '^\[ui\][[:space:]]*$' "${dir}/out" || return 1
    require_fixed "the carried remember_tool_approvals survives a re-render" \
      'remember_tool_approvals = true' "${dir}/out" || return 1
    require_fixed "the carried banner survives a re-render" \
      'banner = "keep me"' "${dir}/out" || return 1
    require_fixed "the render keeps its own theme" \
      'theme = "grokbuild"' "${dir}/out" || return 1
    require_fixed "the model table the render carried is intact" \
      '[model."agent"]' "${dir}/out" || return 1
    # Case 2: a render with no [ui] at all - the carried keys need a table of
    # their own, appended below what the render did emit, and still one only.
    bare="${dir}/render-bare"
    printf '%s\n' '[model."agent"]' 'reasoning_effort = "high"' >"${bare}"
    awk -f "${dir}/fold.awk" -v ui="${keys}" <"${bare}" >"${dir}/out-bare"
    python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "${dir}/out-bare" || {
      printf 'FAIL: %s: the appended [ui] table is not valid TOML:\n%s\n' "${sf}" \
        "$(cat "${dir}/out-bare")" >&2
      return 1
    }
    require_count "one [ui] table appended" 1 '^\[ui\][[:space:]]*$' "${dir}/out-bare" || return 1
    require_fixed "the appended table carries the operator key" \
      'remember_tool_approvals = true' "${dir}/out-bare" || return 1
    # Appended, not prepended: the [ui] table sits below the render's own table.
    if [[ "$(grep -n '^\[ui\][[:space:]]*$' "${dir}/out-bare" | cut -d: -f1)" -lt \
      "$(grep -n '^\[model\."agent"\]' "${dir}/out-bare" | cut -d: -f1)" ]]; then
      printf 'FAIL: %s: the [ui] table was prepended, not appended\n' "${sf}" >&2
      return 1
    fi
  done
}

@test "grok_profile: the carry-over strips the operator's permission_mode so the render keeps the only copy" {
  # The render owns [ui] permission_mode now, so an operator file that still carries
  # a value of its own must have it dropped by the strip pass: two lines for one key
  # in one table is invalid TOML (tomllib rejects the duplicate outright), and that
  # is exactly what a re-render of a hand-edited config used to produce. Both shipped
  # passes run here over a fixture - strip over the operator's file, fold over a
  # render that already carries the key - so the alternation, not just its text, is
  # what gets checked.
  local twin sf dir op keys render out
  for twin in workspace devcontainer; do
    sf="$(twin_file "${twin}" startup.sh.tftpl)"
    dir="$(make_scratch)"
    if ! lift_ui_strip "${sf}" "${dir}/strip.awk"; then
      printf 'FAIL: %s: no [ui] strip awk to lift\n' "${sf}" >&2
      return 1
    fi
    if ! lift_ui_fold "${sf}" "${dir}/fold.awk"; then
      printf 'FAIL: %s: no [ui] carry-over awk to lift\n' "${sf}" >&2
      return 1
    fi
    op="${dir}/operator"
    printf '%s\n' '[ui]' 'theme = "groknight"' 'permission_mode = "ask"' \
      'banner = "keep me"' '[models]' 'agent = "agent"' >"${op}"
    keys="${dir}/keys"
    awk -f "${dir}/strip.awk" "${op}" >"${keys}"
    render="${dir}/render"
    printf '%s\n' '[ui]' 'theme = "grokbuild"' 'permission_mode = "always-approve"' \
      '' '[models]' 'agent = "agent"' >"${render}"
    out="${dir}/out"
    awk -f "${dir}/fold.awk" -v ui="${keys}" <"${render}" >"${out}"
    require_count "one permission_mode line in the merged config" 1 \
      '^[[:space:]]*permission_mode[[:space:]]*=' "${out}" || return 1
    require_count "one [ui] table in the merged config" 1 '^\[ui\][[:space:]]*$' "${out}" || return 1
    require_fixed "the render's own approval mode wins" \
      'permission_mode = "always-approve"' "${out}" || return 1
    require_absent "the operator's approval mode is stripped" \
      'permission_mode = "ask"' "${out}" || return 1
    require_fixed "an unrelated operator [ui] key is kept" \
      'banner = "keep me"' "${out}" || return 1
    python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "${out}" || {
      printf 'FAIL: %s: the merged config is not valid TOML:\n%s\n' "${sf}" \
        "$(cat "${out}")" >&2
      return 1
    }
  done
}

@test "grok_profile: the config template emits one [ui] table carrying the theme parameter" {
  local twin tf first
  for twin in workspace devcontainer; do
    tf="$(twin_file "${twin}" grok-config.toml.tftpl)"
    require_count "exactly one [ui] table" 1 '^\[ui\][[:space:]]*$' "${tf}" || return 1
    first="$(awk '/^\[ui\][[:space:]]*$/{inui=1; next} /^\[/{inui=0} inui && NF {print; exit}' "${tf}")"
    if [[ "${first}" != 'theme = "${grok_theme}"' ]]; then
      printf 'FAIL: %s: the [ui] table opens with [%s], not [theme = "${grok_theme}"]\n' "${tf}" "${first}" >&2
      return 1
    fi
  done
}

@test "grok_profile: the config template's one [ui] table also emits the permission_mode parameter" {
  local twin tf ui first
  for twin in workspace devcontainer; do
    tf="$(twin_file "${twin}" grok-config.toml.tftpl)"
    require_count "one permission_mode line in the whole template" 1 \
      '^[[:space:]]*permission_mode[[:space:]]*=' "${tf}" || return 1
    ui="$(awk '/^\[ui\][[:space:]]*$/{inui=1; next} /^\[/{inui=0} inui' "${tf}")"
    require_in "permission_mode takes the parameter" \
      '^[[:space:]]*permission_mode[[:space:]]*=[[:space:]]*"\$\{grok_permission_mode\}"[[:space:]]*$' "${ui}" || return 1
    first="$(printf '%s\n' "${ui}" | awk 'NF {print; exit}')"
    if [[ "${first}" != 'theme = "${grok_theme}"' ]]; then
      printf 'FAIL: %s: the [ui] table opens with [%s], not [theme = "${grok_theme}"]\n' "${tf}" "${first}" >&2
      return 1
    fi
  done
}

# require_page <file> - fail naming the payload groups that have to ship an operator
# page this suite reads. A missing page is a failure, not a skip: a suite that skips
# reads identical to one that passes.
require_page() {
  if [ ! -f "$1" ]; then
    printf 'FAIL: %s is not in the runfiles: add //:entry_docs and //docs:content to this suite'\''s _SUITE_PAYLOAD entry\n' "$1" >&2
    return 1
  fi
}

# flat_prose <file> - the page as one line. This prose is hard-wrapped, and a claim
# that runs across source lines is invisible to a per-line grep.
flat_prose() {
  tr '\n' ' ' <"$1" | tr -s ' '
}

@test "grok_profile: the operator pages teach the approval mode as a stack default the create form answers" {
  # Nothing else in the gate opens these four pages, which is how four of them kept
  # teaching a retired width rule after main.tf moved (see FANOUT_DOCS in
  # tests/bats/grok-subagent-slots.bats). Pin the substance only: each page names the
  # create-form parameter, names the shipped default, and ties the parameter to what it
  # renders, in one sentence.
  local -a pages=(
    "${REPO_ROOT}/docs/grok-build-and-agents.md"
    "${REPO_ROOT}/docs/config-updates.md"
    "${REPO_ROOT}/docs/coder-templates.md"
    "${REPO_ROOT}/AGENTS.md"
  )
  local -a seed_pages=(
    "${REPO_ROOT}/docs/grok-build-and-agents.md"
    "${REPO_ROOT}/docs/config-updates.md"
    "${REPO_ROOT}/AGENTS.md"
  )
  local file flat page
  # README.md and AGENTS.md both travel with this suite through //:entry_docs, so a
  # page that resolves above always carries the two root docs: a missing one is the
  # runfiles losing the group, not a page being renamed. README is reached for that
  # reachability alone - it documents no [ui] key today, so the approval-mode claims
  # below belong to the four pages that actually teach the mode.
  [[ -f "${REPO_ROOT}/README.md" ]] || {
    printf 'FAIL: README.md is not reachable from %s - the runfiles lost //:entry_docs\n' \
      "${REPO_ROOT}" >&2
    return 1
  }
  for file in "${pages[@]}"; do
    require_page "${file}" || return 1
    page="$(basename "${file}")"
    flat="$(flat_prose "${file}")"
    require_in "${page} names the create-form parameter" 'grok_permission_mode' "${flat}" || return 1
    require_in "${page} names the shipped default" 'always-approve' "${flat}" || return 1
    one_sentence_names "${page}: the parameter is tied to what it renders" "${flat}" \
      'grok_permission_mode' '(permission_mode|approval mode)' || return 1
  done
  # The seed variable is the contributor's half of the same choice, so every page that
  # documents the contributor seed has to name it beside the create-form parameter it
  # mirrors. coder-templates.md is not one of them: it documents create-form fields and
  # names no seed variable, GROK_THEME included.
  for file in "${seed_pages[@]}"; do
    require_page "${file}" || return 1
    page="$(basename "${file}")"
    flat="$(flat_prose "${file}")"
    require_in "${page} names the seed variable" 'GROK_PERMISSION_MODE' "${flat}" || return 1
    one_sentence_names "${page}: the create form and the seed are one choice" "${flat}" \
      'grok_permission_mode' 'GROK_PERMISSION_MODE' || return 1
  done
}

@test "grok_profile: AGENTS.md ties the approval mode to its seed variable the way it ties the theme" {
  # The rulebook already states the theme seam as "the create-form parameter, and the
  # seed takes the same choice". The approval mode has to be stated the same way, or an
  # operator reading only AGENTS.md never learns GROK_PERMISSION_MODE exists. The theme
  # sentence is asserted first so the shape below cannot pass on an empty page.
  local agents flat
  agents="${REPO_ROOT}/AGENTS.md"
  require_page "${agents}" || return 1
  flat="$(flat_prose "${agents}")"
  one_sentence_names "the theme tie AGENTS.md already makes" "${flat}" \
    'grok_theme' 'GROK_THEME' || return 1
  one_sentence_names "the approval-mode tie, in that same shape" "${flat}" \
    'grok_permission_mode' 'GROK_PERMISSION_MODE' 'always-approve' || return 1
}

@test "grok_profile: the boot names the [ui] permission_mode it drops from the file it replaces" {
  # The render owns the key now, so an operator's own value disappears at the next
  # start. Silence is how a workspace starts prompting, or stops prompting, with nobody
  # able to say why, so the twin lifts the value out of the file it is replacing and
  # warns with it. The probe is its own awk program, not the strip pass, so it is
  # lifted and EXECUTED over the fixtures rather than grepped for.
  local twin sf dir probe seen lines
  for twin in workspace devcontainer; do
    sf="$(twin_file "${twin}" startup.sh.tftpl)"
    require_line "the boot captures the mode it is about to drop" 'dropped_mode="\$\(' "${sf}" || return 1
    require_line "the note fires only when a value was actually dropped" \
      '\[\[? -n "\$dropped_mode" \]\]?' "${sf}" || return 1
    require_line "the boot note names the key and the value it dropped" \
      'boot_warn.*permission_mode.*\$dropped_mode' "${sf}" || return 1
    dir="$(make_scratch)"
    if ! lift_ui_probe "${sf}" "${dir}/probe.awk"; then
      printf 'FAIL: %s: no dropped-mode awk to lift\n' "${sf}" >&2
      return 1
    fi
    probe="${dir}/probe.awk"
    # An [ui] table that carries a mode: the boot has one value to name, and it names
    # the one that was written. The program prints the right-hand side as the file has
    # it, quotes included, so what the console shows is what the operator wrote.
    printf '%s\n' '[ui]' 'theme = "groknight"' 'permission_mode = "ask"' \
      'banner = "keep me"' >"${dir}/has-mode"
    seen="$(awk -f "${probe}" "${dir}/has-mode")"
    lines="$(printf '%s\n' "${seen}" | grep -c . || true)"
    if [[ "${seen//\"/}" != "ask" || "${lines}" != "1" ]]; then
      printf 'FAIL: %s: the probe printed [%s] for a fixture whose [ui] carries permission_mode = "ask"\n' \
        "${sf}" "${seen}" >&2
      return 1
    fi
    # No [ui] table at all: nothing was dropped, so the boot stays quiet.
    printf '%s\n' '[models]' 'agent = "agent"' >"${dir}/no-table"
    seen="$(awk -f "${probe}" "${dir}/no-table")"
    if [[ -n "${seen}" ]]; then
      printf 'FAIL: %s: the probe printed [%s] for a file with no [ui] table\n' "${sf}" "${seen}" >&2
      return 1
    fi
    # An [ui] table with no approval mode: the other keys are not a dropped mode.
    printf '%s\n' '[ui]' 'theme = "groknight"' 'banner = "keep me"' >"${dir}/no-mode"
    seen="$(awk -f "${probe}" "${dir}/no-mode")"
    if [[ -n "${seen}" ]]; then
      printf 'FAIL: %s: the probe printed [%s] for an [ui] table with no permission_mode\n' \
        "${sf}" "${seen}" >&2
      return 1
    fi
  done
}

@test "grok_profile: the two config twins ship the same [permission] approval-mode note" {
  # The twins are independent payload copies and this change already split them once,
  # so the paragraph that explains the approval mode is compared byte for byte instead
  # of being grepped in each twin on its own. The non-empty and content probes come
  # first: a paragraph neither twin ships would compare identical.
  local dir ws dc
  dir="$(make_scratch)"
  ws="${dir}/workspace-note"
  dc="${dir}/devcontainer-note"
  permission_note "$(twin_file workspace grok-config.toml.tftpl)" >"${ws}"
  permission_note "$(twin_file devcontainer grok-config.toml.tftpl)" >"${dc}"
  if [ ! -s "${ws}" ]; then
    printf 'FAIL: %s ships no "The approval mode ships as a stack default" paragraph\n' \
      "$(twin_file workspace grok-config.toml.tftpl)" >&2
    return 1
  fi
  require_line "the note documents the key the render owns" 'permission_mode' "${ws}" || return 1
  require_line "the note names the shipped default" 'always-approve' "${ws}" || return 1
  if ! diff -u "${ws}" "${dc}" >&2; then
    printf 'FAIL: the [permission] approval-mode note is not identical in the two config twins\n' >&2
    return 1
  fi
}

@test "grok_profile: the two main.tf twins offer the same four approval modes" {
  # Four option blocks per twin, already pinned for their values elsewhere; what no
  # test did was check that a label or a description written into one twin's dropdown
  # is the label the other twin offers. Same fields, same order, or it goes red.
  local dir ws dc n pair
  dir="$(make_scratch)"
  ws="${dir}/workspace-options"
  dc="${dir}/devcontainer-options"
  dropdown_fields "$(twin_file workspace main.tf)" >"${ws}"
  dropdown_fields "$(twin_file devcontainer main.tf)" >"${dc}"
  for pair in "${ws}:workspace" "${dc}:devcontainer"; do
    n="$(grep -c . "${pair%:*}" || true)"
    if [[ "${n}" != "8" ]]; then
      printf 'FAIL: %s: the approval-mode dropdown exposes %s option field(s), expected 8 (4 options x name + description)\n' \
        "$(twin_file "${pair#*:}" main.tf)" "${n}" >&2
      return 1
    fi
  done
  if ! diff -u "${ws}" "${dc}" >&2; then
    printf 'FAIL: the two main.tf twins do not offer the same option names and descriptions\n' >&2
    return 1
  fi
}
