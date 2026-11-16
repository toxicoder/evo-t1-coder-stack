#!/usr/bin/env bats
#
# ## startup-vault-hook.bats - the .bashrc vault hook is behind the vault flag.
#
# templates/{workspace,devcontainer}/startup.sh.tftpl appends a line to the
# workspace user's ~/.bashrc that sources ~/.infisical/agent.env under `set -a`, which
# is what carries the fetched secrets into every shell of a workspace. That hook is
# gated on infisical_hook, which each main.tf twin hands it from var.infisical_enabled,
# so a stack that never adopted the vault gets no line in a file the operator owns
# rather than an inert one it merely has to tolerate.
#
# The gate is a Terraform control block, so the only honest check is a real render: the
# suite extracts the guarded region from each twin and hands it to `terraform console`
# with the flag false and true, then asserts what came back. An empty render on false
# and the exact two lines on true, byte-identical across the twins, is the contract.
#
# Usage: bazelisk test //tests:bats_startup_vault_hook_test   (from any cwd)

REPO_ROOT=""
TPL_WS=""
TPL_DC=""

setup() {
  command -v terraform >/dev/null 2>&1 || skip "terraform is not on PATH"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TPL_WS="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  TPL_DC="${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"
  [ -f "${TPL_WS}" ] || skip "workspace startup template is absent"
  [ -f "${TPL_DC}" ] || skip "devcontainer startup template is absent"
}

# extract_hook <template> <dest> - copy the guarded region, guards included, so the
# render exercises the construct the twin actually ships. The two tags are pinned to the
# exact trim form the test 'the guard keeps the region off the comment above it' asserts:
# a leading ~ on the opener only. A ~} on either tag is a different template and a
# different render, so this extractor refuses it rather than quietly extracting a region
# that no longer looks like what main.tf renders.
extract_hook() {
  local tpl="${1}" dest="${2}"
  python3 - "${tpl}" "${dest}" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
open_ = "%{~ if infisical_hook }"
close = "%{ endif }"
if text.count(open_) != 1:
    sys.stderr.write("expected exactly one %s, found %d\n" % (open_, text.count(open_)))
    raise SystemExit(1)
i = text.index(open_)
j = text.index(close, i) + len(close)
pathlib.Path(sys.argv[2]).write_text(text[i:j] + "\n", encoding="utf-8")
PY
}

# render_hook <template> <dest> <true|false> - render the guarded region for real.
# Runs from a scratch dir so terraform never loads the module beside the template.
render_hook() {
  local tpl="${1}" dest="${2}" flag="${3}" block="${BATS_TEST_TMPDIR}/hook-$$.tftpl"
  extract_hook "${tpl}" "${block}" || return 1
  (
    cd "${BATS_TEST_TMPDIR}" || exit 1
    printf 'templatefile("%s", { infisical_hook = %s })\n' "${block}" "${flag}" |
      terraform console 2>/dev/null
  ) >"${dest}"
}

# strip_render <src> <dest> - terraform console wraps a multi-line result in an EOT
# heredoc and quotes an empty one; reduce both to the rendered bytes. A result that is
# nothing but whitespace is empty: the extracted fragment carries one newline outside the
# closing tag, and a blank line is the off path saying it added no script.
strip_render() {
  python3 - "${1}" "${2}" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
if lines and lines[0].strip() == "<<EOT" and lines[-1].strip() == "EOT":
    text = "\n".join(lines[1:-1])
elif lines == ['""']:
    text = ""
if not text.strip():
    text = ""
pathlib.Path(sys.argv[2]).write_text(text, encoding="utf-8")
PY
}

@test "gate: both main.tf twins hand the startup template the vault flag" {
  local tf out
  for tf in "${REPO_ROOT}/templates/workspace/main.tf" \
    "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    [ -f "${tf}" ] || { printf 'FAIL: %s is absent\n' "${tf}" >&2; return 1; }
    out="$(grep -c '^\s*infisical_hook = var.infisical_enabled$' "${tf}" || true)"
    [ "${out}" = "1" ] || {
      printf 'FAIL: %s passes infisical_hook %s times, want exactly 1\n' "${tf}" "${out}" >&2
      return 1
    }
  done
}

@test "gate: with the flag off the hook renders to nothing in either twin" {
  local tpl rendered stripped
  for tpl in "${TPL_WS}" "${TPL_DC}"; do
    rendered="${BATS_TEST_TMPDIR}/off-$(basename "$(dirname "${tpl}")").txt"
    stripped="${rendered}.clean"
    render_hook "${tpl}" "${rendered}" "false" || {
      printf 'FAIL: could not render the guarded region of %s\n' "${tpl}" >&2
      return 1
    }
    strip_render "${rendered}" "${stripped}"
    [ ! -s "${stripped}" ] || {
      printf 'FAIL: flag off still rendered %s\n' "$(cat "${stripped}")" >&2
      return 1
    }
  done
}

@test "gate: with the flag on the hook renders the guarded source line exactly once" {
  local tpl rendered stripped line_count
  for tpl in "${TPL_WS}" "${TPL_DC}"; do
    rendered="${BATS_TEST_TMPDIR}/on-$(basename "$(dirname "${tpl}")").txt"
    stripped="${rendered}.clean"
    render_hook "${tpl}" "${rendered}" "true" || {
      printf 'FAIL: could not render the guarded region of %s\n' "${tpl}" >&2
      return 1
    }
    strip_render "${rendered}" "${stripped}"
    grep -Fq 'if [ -f "$HOME/.infisical/agent.env" ]; then set -a; . "$HOME/.infisical/agent.env"; set +a; fi' \
      "${stripped}" || {
      printf 'FAIL: flag on did not render the source-and-export line: %s\n' \
        "$(cat "${stripped}")" >&2
      return 1
    }
    # set -a is what makes each line an exported variable rather than a shell-local one.
    grep -Fq 'set -a;' "${stripped}" || {
      printf 'FAIL: the rendered hook lost its set -a wrapper\n' >&2
      return 1
    }
    line_count="$(grep -c 'infisical/agent.env' "${stripped}" || true)"
    [ "${line_count}" = "2" ] || {
      printf 'FAIL: want the grep guard and the append, two mentions, got %s\n' \
        "${line_count}" >&2
      return 1
    }
  done
}

@test "gate: the guarded block is byte-identical across the two twins" {
  local a="${BATS_TEST_TMPDIR}/ws-block.tftpl" b="${BATS_TEST_TMPDIR}/dc-block.tftpl"
  extract_hook "${TPL_WS}" "${a}" || return 1
  extract_hook "${TPL_DC}" "${b}" || return 1
  run cmp "${a}" "${b}"
  [ "${status}" -eq 0 ] || {
    printf 'FAIL: the twins guarded regions drifted:\n--- workspace ---\n%s\n--- devcontainer ---\n%s\n' \
      "$(cat "${a}")" "$(cat "${b}")" >&2
    return 1
  }
}

@test "gate: a rendered-off script carries no vault trace at all" {
  local tpl rendered
  for tpl in "${TPL_WS}" "${TPL_DC}"; do
    rendered="${BATS_TEST_TMPDIR}/trace-$(basename "$(dirname "${tpl}")").txt"
    render_hook "${tpl}" "${rendered}" "false" || return 1
    run grep -ic 'infisical' "${rendered}"
    [ "${output}" = "0" ] || {
      printf 'FAIL: an off render still mentions the vault %s time(s)\n' "${output}" >&2
      return 1
    }
  done
}

@test "gate: the guard trims before the opener only, which keeps the region off the comment above it" {
  local tpl opener lineno prev prev_line
  for tpl in "${TPL_WS}" "${TPL_DC}"; do
    # The opener eats the newline that ends the comment block documenting the gate, which
    # is the one trim this region can afford. A trim on its closing side eats the newline
    # in front of the if as well, and the whole guard then lands inside that comment, so
    # bash is left with an orphaned fi. That is a whole-file parse failure, and it is the
    # one thing a render of the extracted fragment alone cannot see -- which is why the
    # form is pinned here by its exact bytes and //:bats_tftpl_interpolation_test parses
    # the rendered file on both sides of the gate.
    opener="$(grep -n -F '%{~ if infisical_hook }' "${tpl}" || true)"
    [ -n "${opener}" ] || {
      printf 'FAIL: %s lost the opener the gate is written with\n' "${tpl}" >&2
      return 1
    }
    run grep -Fq '%{~ if infisical_hook ~}' "${tpl}"
    [ "${status}" -ne 0 ] || {
      printf 'FAIL: %s trims after the opener too, which pulls the if up into the\ncomment above it and leaves its fi for bash\n' "${tpl}" >&2
      return 1
    }
    run grep -Fq '%{~ endif' "${tpl}"
    [ "${status}" -ne 0 ] || {
      printf 'FAIL: %s trims before the closer, which welds the blank line after the fi\nto the section comment that follows it\n' "${tpl}" >&2
      return 1
    }
    # The region has to start a line of its own and follow a comment line: that pairing is
    # what the single trim protects, and a stray token would break it silently.
    lineno="${opener%%:*}"
    prev="$((lineno - 1))"
    [ "${opener#*:}" = '%{~ if infisical_hook }' ] || {
      printf 'FAIL: %s line %s is not the opener on its own line: %s\n' \
        "${tpl}" "${lineno}" "${opener#*:}" >&2
      return 1
    }
    # The region has to start a line of its own and follow a comment line: that pairing is
    # what the single trim protects, and a stray token would break it silently.
    prev_line="$(sed -n "${prev}p" "${tpl}")"
    case "${prev_line}" in
      '#'*) ;;
      *)
        printf 'FAIL: %s line %s is the opener and line %s is not a comment: %s\n' \
          "${tpl}" "${lineno}" "${prev}" "${prev_line}" >&2
        return 1
        ;;
    esac
  done
}
