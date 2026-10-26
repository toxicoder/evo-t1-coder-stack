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

@test "dockerfile_args: names mode keeps only tokens whose name is the accepted character class" {
  local dir="${BATS_TEST_TMPDIR}/chars"
  mkdir -p "${dir}"
  # The class is [A-Z0-9_]+ with no anchor on the first character, so a digit may
  # lead; a lower-case letter, a hyphen or a dot ends the token and drops it.
  printf '%s\n' \
    'ARG lower=1' \
    'ARG Bad-Name=2' \
    'ARG dot.name=3' \
    'ARG 9LIVES=x' \
    'ARG _U_1=v' \
    'ARG OK=1' >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'9LIVES\n_U_1\nOK' ]

  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'9LIVES=x\n_U_1=v\nOK=1' ]
}

@test "dockerfile_args: defaults mode trims the pair and prints an empty default" {
  local dir="${BATS_TEST_TMPDIR}/values"
  mkdir -p "${dir}"
  # defaults mode trims each side of the pair, so a padded name still reports;
  # names mode splits on = without trimming, so the same line has no valid name.
  printf '%s\n' 'ARG EMPTY=' 'ARG  SPACED = 1 ' 'ARG TAG=latest' >"${dir}/Dockerfile"

  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'EMPTY=\nSPACED= 1\nTAG=latest' ]

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'EMPTY\nTAG' ]
}

@test "dockerfile_args: a tab separates ARG from its name just as a space does" {
  local dir="${BATS_TEST_TMPDIR}/tabs"
  mkdir -p "${dir}"
  printf '%b\n' 'ARG\tTABBED=2' 'ARG SPACED=3' >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'TABBED\nSPACED' ]

  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${output}" = $'TABBED=2\nSPACED=3' ]
}

@test "dockerfile_args: only a leading ARG opens the block, so a passing mention is not an arg" {
  local dir="${BATS_TEST_TMPDIR}/lead"
  mkdir -p "${dir}"
  printf '%s\n' \
    'FROM scratch' \
    'RUN echo ARG NOPE=0' \
    '' \
    'ARG Z=9' >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = 'Z' ]

  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${output}" = 'Z=9' ]
}

@test "dockerfile_args: a comment inside a continued block is skipped without closing it" {
  local dir="${BATS_TEST_TMPDIR}/contcomment"
  mkdir -p "${dir}"
  printf '%s\n' 'ARG A=1 \' '  # NOT_AN_ARG=2' '  B=2' 'ARG C=3' >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'A\nB\nC' ]
}

@test "dockerfile_args: blanks after the continuation backslash still continue the block" {
  local dir="${BATS_TEST_TMPDIR}/contspace"
  mkdir -p "${dir}"
  {
    printf '%s%s\n' 'ARG A=1 \' '  '
    printf '%s\n' '  B=2' 'ARG C=3\' 'ARG D=4'
  } >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'A\nB\nC\nD' ]

  # The backslash glued to the value ends the block, so D opens one of its own.
  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${output}" = $'A=1\nB=2\nC=3\nD=4' ]
}

@test "dockerfile_args: an empty Dockerfile prints nothing in either mode" {
  local dir="${BATS_TEST_TMPDIR}/emptydf"
  mkdir -p "${dir}"
  : >"${dir}/Dockerfile"

  run awk -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run awk -v mode=defaults -f "${AWK_LIB}/dockerfile_args.awk" "${dir}/Dockerfile"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
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

@test "env_set_key: every assignment of the key is rewritten, in order, not just the first" {
  local f="${BATS_TEST_TMPDIR}/repeat.env"
  printf '%s\n' 'KEY=a' 'X=1' 'KEY=b' >"${f}"

  run env UCKEY=KEY UCVAL=NEW awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'KEY=NEW\nX=1\nKEY=NEW' ]
}

@test "env_set_key: a key that only prefixes the line is not the key" {
  local f="${BATS_TEST_TMPDIR}/prefix.env"
  printf '%s\n' 'KEY=a' 'KEYWORD=keep' >"${f}"

  # "KE" is a prefix of the key name, so no line starts with "KE=".
  run env UCKEY=KE UCVAL=x awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'KEY=a\nKEYWORD=keep' ]
}

@test "env_set_key: a name with no = is not an assignment" {
  local f="${BATS_TEST_TMPDIR}/bare.env"
  printf '%s\n' 'KEY' 'KEY=a' >"${f}"

  run env UCKEY=KEY UCVAL=v awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'KEY\nKEY=v' ]
}

@test "env_set_key: an unset UCKEY rewrites only a line that already opens with =" {
  local f="${BATS_TEST_TMPDIR}/nokey.env"
  printf '%s\n' 'FOO=1' '=weird' 'BAR=2' >"${f}"

  # An empty UCKEY makes the needle just "=", so an anonymous line is the only
  # one whose column-1 prefix matches; ordinary assignments pass through.
  run env -u UCKEY -u UCVAL awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'FOO=1\n=\nBAR=2' ]
}

@test "env_set_key: an unset UCVAL writes the key with an empty value" {
  local f="${BATS_TEST_TMPDIR}/noval.env"
  printf '%s\n' 'FOO=1' 'BAR=2' >"${f}"

  run env -u UCVAL UCKEY=FOO awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'FOO=\nBAR=2' ]
}

@test "env_set_key: a value holding a newline is data, so it splits the line" {
  local f="${BATS_TEST_TMPDIR}/newline.env"
  printf '%s\n' 'KEY=a' 'X=1' >"${f}"

  run env UCKEY=KEY UCVAL=$'one\ntwo' awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'KEY=one\ntwo\nX=1' ]
}

@test "env_set_key: a CRLF file keeps its CRs on every line but the one rewritten" {
  local f="${BATS_TEST_TMPDIR}/crlf.env"
  printf '%b\n' 'KEY=a\r' 'X=1\r' >"${f}"

  # The match is on the KEY= prefix, so the CR that rode the old value goes with
  # it; the neighbours keep theirs.
  run env UCKEY=KEY UCVAL=NEW awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'KEY=NEW\nX=1\r' ]
}

@test "env_set_key: an empty file yields no output" {
  local f="${BATS_TEST_TMPDIR}/empty.env"
  : >"${f}"

  run env UCKEY=KEY UCVAL=v awk -f "${AWK_LIB}/env_set_key.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
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

@test "key_comment: with no want= the first line that opens with = ends the scan" {
  local f="${BATS_TEST_TMPDIR}/nowant"
  printf '%s\n' '# lead' '=stray' '# after' 'K=1' >"${f}"

  # want defaults to empty, so the needle is "=" and only an anonymous line
  # matches it at column 1.
  run awk -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = '# lead' ]
}

@test "key_comment: a key the file never assigns leaves the last run standing" {
  local f="${BATS_TEST_TMPDIR}/nokey"
  printf '%s\n' '# first block' '' '# tail block' >"${f}"

  # Nothing ever exits the scan, so the run still open at EOF is the answer.
  run awk -v want=GONE -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = '# tail block' ]
}

@test "key_comment: a comment above a longer-named key does not leak to the shorter one" {
  local f="${BATS_TEST_TMPDIR}/longer"
  printf '%s\n' '# belongs to KEY2' 'KEY2=v' 'KEY=1' >"${f}"

  # "KEY2=v" does not begin with "KEY=", so it is just a non-comment line and it
  # resets the run before the real key is reached.
  run awk -v want=KEY -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "key_comment: a key on the first line ends the scan before any comment is kept" {
  local f="${BATS_TEST_TMPDIR}/first"
  printf '%s\n' 'KEY=1' '# below the key' >"${f}"

  run awk -v want=KEY -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "key_comment: a CRLF key line still ends the scan" {
  local f="${BATS_TEST_TMPDIR}/crlf"
  printf '%b\n' 'KEY=1\r' '# below\r' >"${f}"

  # The CR rides the value, so the "KEY=" prefix match is unaffected.
  run awk -v want=KEY -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "key_comment: a non-comment line between block and key empties the answer" {
  local f="${BATS_TEST_TMPDIR}/between"
  printf '%s\n' '# b1' 'OTHER=1' '# b2' 'KEY=1' >"${f}"

  run awk -v want=KEY -f "${AWK_LIB}/key_comment.awk" "${f}"
  [ "${status}" -eq 0 ]
  [ "${output}" = '# b2' ]
}

@test "key_comment: an empty file prints nothing" {
  local f="${BATS_TEST_TMPDIR}/emptyblock"
  : >"${f}"

  run awk -v want=KEY -f "${AWK_LIB}/key_comment.awk" "${f}"
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

@test "tftpl_strip_gates: a directive that is not the shipped spelling is content" {
  local src="${BATS_TEST_TMPDIR}/nearmiss.tftpl"
  printf '%s\n' \
    'a' \
    '%{ endif }' \
    '%{if grok_config_extra != "" }' \
    '${grok_config_extra}' \
    'b' >"${src}"

  # No trailing ~, so neither the endif rule nor the extra gate matches and both
  # lines are ordinary text.
  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'a\n%{ endif }\n%{if grok_config_extra != "" }\n${grok_config_extra}\nb' ]
}

@test "tftpl_strip_gates: an unknown gate stays and only its endif is consumed" {
  local src="${BATS_TEST_TMPDIR}/unknown.tftpl"
  printf '%s\n' '%{if other_mcp~}' 'body' '%{endif~}' 'tail' >"${src}"

  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'%{if other_mcp~}\nbody\ntail' ]
}

@test "tftpl_strip_gates: an endif with no open gate is consumed silently" {
  local src="${BATS_TEST_TMPDIR}/orphan.tftpl"
  printf '%s\n' '%{endif~}' 'only' >"${src}"

  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 'only' ]
}

@test "tftpl_strip_gates: a dropped block with no endif swallows the rest of the file" {
  local src="${BATS_TEST_TMPDIR}/unterminated.tftpl"
  printf '%s\n' 'head' '%{if github_mcp~}' 'x' 'y' 'tail' >"${src}"

  # skip is never cleared, which is the guard that makes an unterminated gate
  # fail closed rather than emit the block.
  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 'head' ]
}

@test "tftpl_strip_gates: a gate nested in a kept block is dropped to its own endif" {
  local src="${BATS_TEST_TMPDIR}/nested.tftpl"
  printf '%s\n' \
    '%{if search_mcp~}' 'a' '%{if github_mcp~}' 'b' '%{endif~}' 'c' '%{endif~}' >"${src}"

  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'a\nc' ]
}

@test "tftpl_strip_gates: the first endif of a dropped pair ends the skip" {
  local src="${BATS_TEST_TMPDIR}/pair.tftpl"
  printf '%s\n' \
    '%{if github_mcp~}' 'x' '%{if context7_mcp~}' 'y' '%{endif~}' 'z' '%{endif~}' >"${src}"

  # One skip flag, so the inner endif closes the outer skip and z survives: the
  # seed templates never nest the dropped gates, which is what keeps this safe.
  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 'z' ]
}

@test "tftpl_strip_gates: an empty source produces no output" {
  local src="${BATS_TEST_TMPDIR}/empty.tftpl"
  : >"${src}"

  run awk -f "${AWK_LIB}/tftpl_strip_gates.awk" "${src}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
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

@test "preset_desc: a block still open at EOF is flushed there" {
  local dir="${BATS_TEST_TMPDIR}/unterminated"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "un" {' \
    '  name = "n1"' \
    '  description = "d1"' >"${dir}/un.tf"

  run preset_records "${dir}/un.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:un:n1:d1" ]
}

@test "preset_desc: a block with neither name nor description reports no record" {
  local dir="${BATS_TEST_TMPDIR}/barer"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "bare" {' \
    '  parameters = {' \
    '    (data.coder_parameter.workspace_image.name) = "img"' \
    '  }' \
    '}' >"${dir}/bare.tf"

  # Nothing measurable was seen, so flush() prints neither DESC nor SKIP.
  run preset_records "${dir}/bare.tf"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "preset_desc: a name with no description is not a record either" {
  local dir="${BATS_TEST_TMPDIR}/nameonly"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "n" {' \
    '  name = "only-name"' \
    '}' >"${dir}/n.tf"

  run preset_records "${dir}/n.tf"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "preset_desc: a description with no name is reported with an empty name field" {
  local dir="${BATS_TEST_TMPDIR}/desconly"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "d" {' \
    '  description = "only desc"' \
    '}' >"${dir}/d.tf"

  # Compared as raw bytes: IFS-tab read would collapse the empty name field and
  # the caller could not tell "no name" from "no description".
  run awk -f "${AWK_LIB}/preset_desc.awk" "${dir}/d.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'DESC\td\t\tonly desc' ]
}

@test "preset_desc: the first name and the first description win a repeated assignment" {
  local dir="${BATS_TEST_TMPDIR}/repeat"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "r" {' \
    '  name = "first"' \
    '  name = "second"' \
    '  description = "d1"' \
    '  description = "d2"' \
    '}' >"${dir}/r.tf"

  run preset_records "${dir}/r.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:r:first:d1" ]
}

@test "preset_desc: a quoted description after a heredoc is ignored, the record stays SKIP" {
  local dir="${BATS_TEST_TMPDIR}/heredocfirst"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "h" {' \
    '  name = "n"' \
    '  description = <<EOT' \
    '    plain heredoc' \
    '  EOT' \
    '  description = "too late"' \
    '}' >"${dir}/h.tf"

  # Once a description is flagged unchecked the guard stops looking, so the
  # heredoc verdict cannot be overwritten by a later one-line value.
  run preset_records "${dir}/h.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP:h:n" ]
}

@test "preset_desc: a resource block that is not a preset is skipped entirely" {
  local dir="${BATS_TEST_TMPDIR}/notpreset"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_parameter" "notpreset" {' \
    '  name = "nope"' \
    '  description = "must not be read"' \
    '}' \
    'data "coder_workspace_preset" "p" {' \
    '  name = "pn"' \
    '  description = "pd"' \
    '}' >"${dir}/p.tf"

  run preset_records "${dir}/p.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:p:pn:pd" ]
}

@test "preset_desc: a brace inside the quoted value still yields one record" {
  local dir="${BATS_TEST_TMPDIR}/brace"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "q" {' \
    '  name = "n1"' \
    '  description = "a } brace"' \
    '}' \
    '}' >"${dir}/q.tf"

  run preset_records "${dir}/q.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:q:n1:a } brace" ]
}

@test "preset_desc: two presets in one file report the first, because the brace count never nets down" {
  local dir="${BATS_TEST_TMPDIR}/two"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "two" {' \
    '  name = "a"' \
    '  description = "da"' \
    '}' \
    'data "coder_workspace_preset" "one" {' \
    '  name = "b"' \
    '  description = "db"' \
    '}' >"${dir}/two.tf"

  # braces() counts every { and } it sees, so depth only ever grows: the block
  # opens at the first header and is flushed at EOF, and the second header is
  # read as ordinary text inside it. One preset per .tf is therefore load-bearing
  # for preset_desc_guard, which is how templates/store keeps them.
  run preset_records "${dir}/two.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:two:a:da" ]
}

@test "preset_desc: tab-indented and tight assignments both parse" {
  local dir="${BATS_TEST_TMPDIR}/indent"
  mkdir -p "${dir}"
  printf '%s\n' 'data "coder_workspace_preset" "t" {' >"${dir}/t.tf"
  printf '%b\n' '\tname = "tabname"' '\tdescription = "tabdesc"' '}' >>"${dir}/t.tf"
  printf '%s\n' 'data "coder_workspace_preset" "s" {' '  name="tight"' '  description="tight desc"' '}' \
    >"${dir}/s.tf"

  run preset_records "${dir}/t.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:t:tabname:tabdesc" ]

  run preset_records "${dir}/s.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:s:tight:tight desc" ]
}

@test "preset_desc: an equals sign inside the value survives" {
  local dir="${BATS_TEST_TMPDIR}/equals"
  mkdir -p "${dir}"
  printf '%s\n' \
    'data "coder_workspace_preset" "e" {' \
    '  name = "n"' \
    '  description = "k=v"' \
    '}' >"${dir}/e.tf"

  # Only the first = splits the assignment, so the value keeps its own.
  run preset_records "${dir}/e.tf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "DESC:e:n:k=v" ]
}

@test "preset_desc: an empty .tf file reports nothing" {
  local dir="${BATS_TEST_TMPDIR}/emptytf"
  mkdir -p "${dir}"
  : >"${dir}/empty.tf"

  run preset_records "${dir}/empty.tf"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
