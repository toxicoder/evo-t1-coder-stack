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
# `private` mode emits none of the four. Both themes are per-workspace mutable
# coder_parameters, and code-server's User/settings.json is a real file the stack
# writes, not a symlink onto the shared editor overlay.
#
# Every assertion loops over BOTH twins, because the two trees are independent payload
# copies and a fix that lands in one of them alone has to go red. The [ui] carry-over
# fold is not read as text but lifted out of the twin and EXECUTED over a render, so a
# fold that emits a second [ui] table is caught rather than grepped for. The whole suite
# skips while any template it reads is absent: a suite for a topology the tree does
# not ship has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_grok_profile_test   (from any cwd)
# Safety: reads the two template trees as data; runs awk and python3 over fixtures it
# builds itself; no terraform, no docker daemon, no network; writes nothing outside the
# per-test scratch tree.

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
    printf '%s\n' 'permission_mode = "acceptEdits"' 'banner = "keep me"' >"${keys}"
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
    require_fixed "the carried permission_mode survives a re-render" \
      'permission_mode = "acceptEdits"' "${dir}/out" || return 1
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
    require_fixed "the appended table carries permission_mode" \
      'permission_mode = "acceptEdits"' "${dir}/out-bare" || return 1
    # Appended, not prepended: the [ui] table sits below the render's own table.
    if [[ "$(grep -n '^\[ui\][[:space:]]*$' "${dir}/out-bare" | cut -d: -f1)" -lt \
      "$(grep -n '^\[model\."agent"\]' "${dir}/out-bare" | cut -d: -f1)" ]]; then
      printf 'FAIL: %s: the [ui] table was prepended, not appended\n' "${sf}" >&2
      return 1
    fi
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
