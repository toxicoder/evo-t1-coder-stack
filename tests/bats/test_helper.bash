# shellcheck shell=bash
#
# ## test_helper.bash — BATS support shared by tests/bats/*.bats (sourced; never
# executed)
#
# Invariants:
#   - Every helper here derives its paths from BATS_TEST_DIRNAME /
#     BATS_TEST_TMPDIR or from its arguments. No helper depends on the cwd of
#     the caller, and none hardcodes a machine path (the /repo fallback below
#     is a documented convention, not a requirement of the host).
#   - PATH-stubbed tools stay stubs: the stub copies and the command log are
#     per-test scratch under BATS_TEST_TMPDIR, so one test's argv log never
#     leaks into the next test. Real docker/ssh/curl only ever run in the
#     guarded integration tier, which must skip (not fail) when the real tool
#     or daemon is absent.
#
# Usage (top of a .bats file):
#   load 'test_helper'
#   setup() { use_stubs docker ssh; }

# shellcheck source=../test_helpers.sh disable=SC1091
source "${BATS_TEST_DIRNAME?}/../test_helpers.sh"

# Where the deterministic tool stubs live (override for unusual runtimes).
STUB_BIN_DIR="${STUB_BIN_DIR:-${BATS_TEST_DIRNAME?}/tool_stubs}"

# bats_canonical_repo_root — print the repo root for this run: the nearest
# ancestor of the cwd holding docker-compose.yml, then the same probe under
# /repo (the Bazel runfiles convention). Non-zero when neither matches.
bats_canonical_repo_root() {
  local dir="${PWD}"
  while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
    if [ -f "${dir}/docker-compose.yml" ]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  if [ -f "/repo/docker-compose.yml" ]; then
    printf '%s' "/repo"
    return 0
  fi
  return 1
}

# bats_source_repo_root - print the repo root whose FILE BYTES are what the stack
# ships. Under tests/coverage/shell_cov.sh the suites run against an instrumented
# mirror (bats_runner.sh points REPO_ROOT at it) so production .sh bodies record
# coverage, which makes every instrumented copy larger than the file that ships. A
# gate that measures a payload's size has to count the shipping bytes, so it asks
# here instead. Non-zero when EVO_COV_SOURCE_ROOT is set at something that is not a
# repo root: a byte gate that quietly fell back to the mirror would measure the
# harness, so the handoff is checked rather than trusted.
bats_source_repo_root() {
  local dir
  if [ -n "${EVO_COV_SOURCE_ROOT:-}" ]; then
    dir="${EVO_COV_SOURCE_ROOT}"
    if [ ! -f "${dir}/docker-compose.yml" ] || [ ! -d "${dir}/tests/bats" ]; then
      printf 'FAIL: bats_source_repo_root: EVO_COV_SOURCE_ROOT=%s holds no docker-compose.yml or tests/bats\n' "${dir}" >&2
      return 1
    fi
    printf '%s' "${dir}"
    return 0
  fi
  bats_canonical_repo_root
}

# make_scratch — print a fresh per-test scratch directory (BATS removes the
# BATS_TEST_TMPDIR tree after each test).
make_scratch() {
  local dir
  dir="$(mktemp -d "${BATS_TEST_TMPDIR?}/scratch.XXXXXX")"
  chmod 755 "${dir}"
  printf '%s' "${dir}"
}

# stub_bin <tool...> — copy each named tool's stub from STUB_BIN_DIR into a
# per-test bin/ directory, make it executable, and print that directory. The
# copy-plus-chmod (rather than symlinks or direct PATH use) is load-bearing:
# the Bazel sandbox and some tar extractions strip the exec bit.
stub_bin() {
  local tool bin
  bin="${BATS_TEST_TMPDIR?}/bin"
  mkdir -p "${bin}"
  for tool in "$@"; do
    if [ ! -f "${STUB_BIN_DIR?}/${tool}" ]; then
      printf 'FAIL: stub_bin: no stub for %s under %s\n' "${tool}" "${STUB_BIN_DIR}" >&2
      return 1
    fi
    cp "${STUB_BIN_DIR}/${tool}" "${bin}/${tool}"
    chmod 755 "${bin}/${tool}"
  done
  printf '%s' "${bin}"
}

# with_path <dir...> — print PATH with the given directories prepended.
with_path() {
  local d out=""
  for d in "$@"; do
    out="${out:+${out}:}${d}"
  done
  printf '%s' "${out:+${out}:}${PATH}"
}

# use_stubs <tool...> — one-stop shadowing: copy the stubs, point STUB_LOG at
# a fresh per-test log directory, and shadow PATH. Inside a @test body the
# PATH change is test-local; use_stubs returns non-zero when a stub is missing.
use_stubs() {
  local bin
  bin="$(stub_bin "$@")" || return 1
  export STUB_LOG="${BATS_TEST_TMPDIR?}/stub-logs"
  mkdir -p "${STUB_LOG}"
  PATH="${bin}:${PATH}"
  export PATH
}

# real_bin <tool> — print <tool> resolved with this test's stub bin/ removed
# from PATH (empty when only the stub would answer). The integration-tier gate:
#   if [ -z "$(real_bin terraform)" ]; then skip "terraform not installed"; fi
real_bin() {
  local tool="$1" stripped
  stripped="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -vxF "${BATS_TEST_TMPDIR?}/bin" | paste -sd: -)"
  if [ -z "${stripped}" ]; then
    return 1
  fi
  PATH="${stripped}" command -v "${tool}" 2>/dev/null
}

# path_without_exe <tool> - print PATH with this test's stub bin/ and every other directory
# that holds an executable <tool> removed: the PATH of a machine that never installed it.
# Removing only the stub bin stopped being enough the day the golden workspace image
# started shipping the real Infisical CLI at /usr/local/bin, because this repo's gate
# runs *inside* that image: a fixture that means "the binary is absent" has to remove it
# from the PATH it hands the code under test, or it drives the wrong branch and says
# nothing. Returns 1 when no usable directory would be left, so the caller can say so.
# Globals:
#   PATH, BATS_TEST_TMPDIR
# Arguments:
#   tool - the executable name to remove from every PATH directory
# Outputs:
#   The stripped PATH on stdout
# Returns:
#   0 on success, 1 when only empty entries would survive
# The name is deliberately not path_without: tests/bats/pre-commit.bats defines a
# file-local function of that name with a different empty-PATH contract, and a bats
# file's own definition shadows the helper loaded above it.
path_without_exe() {
  local tool="$1" dir
  local -a parts=() kept=()
  IFS=':' read -r -a parts <<<"${PATH}"
  for dir in "${parts[@]}"; do
    [ "${dir}" = "${BATS_TEST_TMPDIR?}/bin" ] && continue
    if [ -n "${dir}" ] && [ -f "${dir}/${tool}" ] && [ -x "${dir}/${tool}" ]; then
      continue
    fi
    kept+=("${dir}")
  done
  for dir in "${kept[@]}"; do
    if [ -n "${dir}" ]; then
      ( IFS=: ; printf '%s' "${kept[*]}" )
      return 0
    fi
  done
  return 1
}

# stub_log <tool> — print the full argv log recorded for <tool> this test.
stub_log() {
  if [ -f "${STUB_LOG:-}/${1}.log" ]; then
    cat "${STUB_LOG}/${1}.log"
  fi
}

# stub_log_last <tool> — print the last argv line recorded for <tool>.
stub_log_last() {
  if [ -f "${STUB_LOG:-}/${1}.log" ]; then
    tail -n 1 "${STUB_LOG}/${1}.log"
  fi
}

# stub_log_count <tool> — print how many invocations <tool> recorded.
stub_log_count() {
  if [ -f "${STUB_LOG:-}/${1}.log" ]; then
    wc -l <"${STUB_LOG}/${1}.log" | tr -d ' '
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# Boot-body rendering. Every suite that runs a coder_script or startup body needs it
# rendered first, and each one used to hand-roll its own list of map keys; a key added
# to main.tf then broke whichever suites had not memorised it. These two helpers are
# that seam, in one place.
# ---------------------------------------------------------------------------

# bats_repo_root -- print the checkout these helpers were loaded from.
bats_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)" || return 1
  [ -f "${here}/docker-compose.yml" ] || return 1
  printf '%s' "${here}"
}

# bats_render_tftpl <tftpl> <dest> [NAME=VALUE]... -- render one boot body the way
# templatefile() would, with no terraform on PATH, and hand the shell the REAL boot
# logger: boot_log_lib is always filled with the shipped
# templates/common/boot-log.lib.sh, so a suite exercises the narration instead of
# stubbing it to a word and calling the pass meaningless. A caller that names
# boot_log_lib itself is refused for the same reason.
#
# The two steps run in the order Terraform runs them: hide every escaped $${ pair,
# substitute each ${name} against the caller's map, put the escapes back. The library
# is spliced in by awk at the end rather than passed through sed, because its own text
# is full of ${...} that sed would read as part of a replacement.
#
# An ${name} the caller did not supply fails the call. A key renamed on one side of the
# seam has to be a red test, not a body that runs with a hole where its payload was.
# A VALUE must carry neither a pipe nor a newline.
#
# Returns: 0 on success; 1 when a template, the library, or a value is missing.
bats_render_tftpl() {
  local tpl="${1:-}" dest="${2:-}"
  shift 2 2>/dev/null || {
    printf 'FAIL: bats_render_tftpl: <tftpl> <dest> [NAME=VALUE]...\n' >&2
    return 1
  }
  local root lib staged names name pair value supplied rc=0
  [ -f "${tpl}" ] || {
    printf 'FAIL: bats_render_tftpl: no template at %s\n' "${tpl}" >&2
    return 1
  }
  root="$(bats_repo_root)" || {
    printf 'FAIL: bats_render_tftpl: cannot locate the checkout from test_helper.bash\n' >&2
    return 1
  }
  lib="${root}/templates/common/boot-log.lib.sh"
  [ -f "${lib}" ] || {
    printf 'FAIL: bats_render_tftpl: the boot logger is missing at %s\n' "${lib}" >&2
    return 1
  }
  for pair in "$@"; do
    if [ "${pair%%=*}" = "boot_log_lib" ]; then
      printf 'FAIL: bats_render_tftpl: boot_log_lib belongs to the helper, not the caller\n' >&2
      return 1
    fi
  done

  staged="$(mktemp "${TMPDIR:-/tmp}/bats-tftpl.XXXXXX")" || return 1
  cp "${tpl}" "${staged}"
  # Terraform's escape has to be out of the way before the interpolations are hunted,
  # or every $${shell_var} in a body reads as a key nobody passed. The sentinel carries
  # no brace of its own: GNU sed will not match a literal { sitting at the end of a
  # pattern (and rejects \{ as an unmatched interval), so a sentinel that kept the brace
  # would restore as "=${var}" and hand the body a guard whose test is always false --
  # silently, because the render still exits 0. The brace is put back with the token.
  sed -i 's/\$\${/@@BATS_ESCAPED_BRACE@@/g' "${staged}"
  names="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${staged}" | tr -d '${}' | sort -u)" || true
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    [ "${name}" = "boot_log_lib" ] && continue
    supplied=""
    for pair in "$@"; do
      [ "${pair%%=*}" = "${name}" ] || continue
      supplied="yes"
      value="${pair#*=}"
      # A value that looks like an interpolation or a sed instruction would render here
      # differently than under templatefile(): keys substitute one at a time, so a
      # ${other_key} sitting inside a value survives as literal text that terraform would
      # have expanded, and a backslash is read a second time by the replacement. Nothing
      # a suite legitimately passes is either -- these values are payload markers -- so
      # refuse the shape rather than hand back a render that quietly disagrees with terraform.
      case "${value}" in
        *'\'*|*'${'*|*'@@BATS_ESCAPED_BRACE@@'*)
          printf 'FAIL: bats_render_tftpl: the value for %s carries a backslash, a dollar-brace, or the helper sentinel; it cannot be rendered the way terraform would\n' \
            "${name}" >&2
          rc=1
          continue
          ;;
      esac
      value="$(printf '%s' "${value}" | sed 's/[&|]/\\&/g')"
      # shellcheck disable=SC2016  # ${name} is the sed pattern, not a shell expansion
      sed -i "s|\${${name}}|${value}|g" "${staged}"
    done
    if [ -z "${supplied}" ]; then
      printf 'FAIL: bats_render_tftpl: ${%s} is interpolated by %s and no value was passed for it\n' \
        "${name}" "${tpl}" >&2
      rc=1
    fi
  done <<<"${names}"
  sed -i 's/@@BATS_ESCAPED_BRACE@@/${/g' "${staged}"

  if [ "${rc}" -eq 0 ]; then
    awk -v lib="${lib}" '
      $0 == "${boot_log_lib}" {
        while ((getline line < lib) > 0) { print line }
        close(lib)
        next
      }
      { print }
    ' "${staged}" >"${dest}"
    grep -q 'boot_begin()' "${dest}" || {
      printf 'FAIL: bats_render_tftpl: %s never received the boot logger\n' "${tpl}" >&2
      rc=1
    }
  fi
  rm -f "${staged}"
  return "${rc}"
}

# bats_strip_boot_lines [file] -- print <file> (stdin when omitted) without the lines
# the boot logger prints. Every body narrates now, so a suite that used to claim "this
# start printed nothing" claims that about the body's own output instead. The framing,
# the per-file ok:/note:, and the closing summary are the narration and are what an
# operator reads; warning: and error: deliberately SURVIVE the strip, because a suite
# that asked for silence should still go red when the boot had something to complain
# about. The patterns are the logger's exact shapes rather than a prefix guess, so a
# body that legitimately prints an arrow or an ok of its own keeps it. sed and not
# grep -v: grep exits 1 when nothing survives the filter, and under bats a command
# substitution that fails fails the test, which would make a perfectly silent body
# look broken.
bats_strip_boot_lines() {
  sed \
    -e '/^== [^=]*: start ==$/d' \
    -e '/^== [^=]*: stage [0-9]*\/[0-9]*: .* == (+[0-9]*s)$/d' \
    -e '/^-> .* (+[0-9]*s)$/d' \
    -e '/^ok: /d' \
    -e '/^note: /d' \
    -e '/^summary: [0-9]* ok, [0-9]* warnings, [0-9]* failed (+[0-9]*s, .*$/d' \
    "${1:-/dev/stdin}"
}
