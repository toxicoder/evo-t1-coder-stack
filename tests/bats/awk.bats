#!/usr/bin/env bats
#
# ## awk.bats — unit coverage for the -f awk programs under scripts/lib
#
# Each program is run the way the shell function it backs runs it, against a
# fixture written under the bats temp directory: the shipped file is exercised,
# never a copy of its text.
#
# Usage: bazelisk test //tests:bats_awk_test   (from any cwd)
# Safety: no daemon, no network; writes only under the bats temp directory.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
AWK_LIB=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  AWK_LIB="${REPO_ROOT}/scripts/lib"
}

# ── scripts/lib/dockerfile_args.awk ─────────────────────────────────────────

@test "dockerfile_args: names mode lists every ARG name, continued lines included" {
  local dir="${BATS_TEST_TMPDIR}/df"
  mkdir -p "${dir}"
  printf '%s\n' \
    '# a comment that mentions ARG NOPE=0' \
    'ARG FOO=bar' \
    'ARG BAR=1 \' \
    '  BAZ=2' \
    'ARG TARGETARCH' >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'FOO\nBAR\nBAZ\nTARGETARCH' ]

  # mode=names spelled out is the default, so it must answer identically.
  run awk -v mode=names -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${output}" = $'FOO\nBAR\nBAZ\nTARGETARCH' ]
}

@test "dockerfile_args: defaults mode prints KEY=value and omits a bare ARG" {
  local dir="${BATS_TEST_TMPDIR}/pins"
  mkdir -p "${dir}"
  printf '%s\n' \
    '# a comment that mentions ARG NOPE=0' \
    'ARG FOO=bar' \
    'ARG BAR=1 \' \
    '  BAZ=2' \
    'ARG TARGETARCH' >"${dir}/Dockerfile"

  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'FOO=bar\nBAR=1\nBAZ=2' ]
}

# ── scripts/lib/env_set_key.awk ─────────────────────────────────────────────

@test "env_set_key: rewrites the matching KEY= line and leaves the neighbours alone" {
  local f="${BATS_TEST_TMPDIR}/live.env"
  printf '%s\n' '# the token' 'KEY=change-me' 'PREFIX_KEY=nope' 'OTHER=keep' >"${f}"

  run env UCKEY=KEY UCVAL=keepme-secret awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'# the token\nKEY=keepme-secret\nPREFIX_KEY=nope\nOTHER=keep' ]

  # The value arrives through ENVIRON, so metacharacters are data: no shell
  # re-parse and no substitution escaping can touch them.
  run env UCKEY=KEY UCVAL='a$&b"c' awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  printf '%s\n' "${output}" | grep -qxF 'KEY=a$&b"c'

  # A key the file never assigns is simply absent from the output.
  run env UCKEY=ABSENT UCVAL=x awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${output}" = $'# the token\nKEY=change-me\nPREFIX_KEY=nope\nOTHER=keep' ]
}

# ── scripts/lib/key_comment.awk ─────────────────────────────────────────────

@test "key_comment: prints the comment block that touches the key and nothing else" {
  local f="${BATS_TEST_TMPDIR}/twin.example"
  printf '%s\n' \
    '# An explanation.' \
    '# A second line.' \
    '' \
    '# The key explained.' \
    '# Its second line.' \
    'SOLO_KEY=one' \
    'SOLO2=two' \
    '# A comment for the key below.' \
    'THREE=3' >"${f}"

  run awk -v want=SOLO_KEY -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'# The key explained.\n# Its second line.' ]

  # The gap above SOLO2 means it carries no explanation of its own, and
  # scanning stopped at its line, so neither block around it leaks in.
  run awk -v want=SOLO2 -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

# ── scripts/lib/tftpl_strip_gates.awk ───────────────────────────────────────

@test "tftpl_strip_gates: a github_mcp block goes and a search_mcp body stays" {
  local src="${BATS_TEST_TMPDIR}/config.toml.tftpl"
  printf '%s\n' \
    'top = true' \
    '%{if github_mcp~}' \
    '[mcp_servers.github]' \
    'url = "https://api.githubcopilot.com/mcp/"' \
    '%{endif~}' \
    '%{if context7_mcp~}' \
    '[mcp_servers.context7]' \
    '%{endif~}' \
    '%{if search_mcp~}' \
    '[mcp_servers.searxng]' \
    'command = "searxng"' \
    '%{endif~}' \
    'footer = 1' \
    '%{if grok_config_extra != ""~}' \
    '${grok_config_extra}' \
    '%{endif~}' >"${src}"

  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'top = true\n[mcp_servers.searxng]\ncommand = "searxng"\nfooter = 1' ]
  # Every directive is consumed, kept block or not.
  [[ "${output}" != *'%{'* ]]
}

# ── scripts/lib/preset_desc.awk ─────────────────────────────────────────────

# preset_records <file.tf> — split the program's tab-separated records the way
# preset_desc_guard splits them and print one kind:label:name:value per line, so
# the record shape is part of what the test below asserts.
preset_records() {
  local kind label name value
  while IFS=$'\t' read -r kind label name value; do
    case "${kind}" in
      DESC) printf '%s:%s:%s:%s\n' "${kind}" "${label}" "${name}" "${value}" ;;
      SKIP) printf '%s:%s:%s\n' "${kind}" "${label}" "${name}" ;;
      *) fail "unexpected record kind: ${kind}" ;;
    esac
  done < <(awk -f "${AWK_LIB}/preset_desc.awk" "$1")
}

@test "preset_desc: a quoted description comes back DESC and a heredoc comes back SKIP" {
  local dir="${BATS_TEST_TMPDIR}/tpl"
  mkdir -p "${dir}"
  # One preset per file, which is how the guard drives the program: it runs it
  # once per .tf file, so each fixture states its own case.
  printf '%s\n' \
    'data "coder_workspace_preset" "quick" {' \
    '  name        = "fast"' \
    '  description = "Small preset"' \
    '  parameters = {' \
    '    (data.coder_parameter.workspace_image.name) = "evo-t1-dev:latest"' \
    '  }' \
    '}' >"${dir}/quick.tf"
  printf '%s\n' \
    'data "coder_workspace_preset" "long" {' \
    '  name = "wide"' \
    '  description = <<-EOT' \
    '    A description spread over' \
    '    more than one line' \
    '  EOT' \
    '}' >"${dir}/wide.tf"

  run preset_records "${dir}/quick.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:quick:fast:Small preset" ]

  # A heredoc cannot be measured from one line, so it is reported unchecked.
  run preset_records "${dir}/wide.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP:long:wide" ]
}
