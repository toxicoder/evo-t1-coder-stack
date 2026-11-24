#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## stack-workflows.bats - the three workflows travel as stack payload, not as repo files.
#
# Grok Build reads a project workflow from `.grok/workflows/<name>.js` in the trusted clone
# and a user workflow from `~/.grok/workflows/<name>.js` (`$GROK_HOME/workflows`). Project
# workflows load only from that clone's own tree, so the three general-purpose workflows
# this repo carries are invisible to every workspace that cloned some other repository --
# which is every workspace this stack creates except this one. The user tier is the only
# home that travels, so the canonical bodies now live in `templates/common/` and a
# coder_script seeds them there, the way the agent definitions and the personas already do.
#
# Four things about that arrangement fail silently, which is why they are asserted here:
#
# A repo-tier entry that stopped being a symlink is a second copy of a workflow. The two
# then drift, and `/debug-fix` runs whichever one the tier that wins happens to hold. The
# `.grok/agents/*.md` family already keeps one canonical body and links to it; this is the
# same discipline, and it is checked the same way - the link and where it resolves.
#
# A seed that is not marker-aware is either a bulldozer or a no-op. Overwrite unconditionally
# and a person's edited workflow is gone on the next boot; write only when absent and a
# workflow that drifted from the seed never comes back. So the pair below is driven against
# a fixture `HOME`: a hand-authored file survives with a `note:`, a marker-carrying file is
# refreshed to the canonical bytes. That is the hooks contract, and it is proven by running
# the rendered body rather than by reading it.
#
# A coder_script missing from one twin is a template that quietly stops seeding, and the two
# trees are edited independently. Both are read as data and both have to declare it.
#
# A payload `scripts/lib/template-push.sh` does not list is a push that dies in the server's
# Terraform, because the Coder side resolves `file()` against the pushed copy.
#
# Usage: bazelisk test //tests:bats_stack_workflows_test   (from any cwd)
# Safety: drives the rendered body against scratch homes under BATS_TEST_TMPDIR with TMPDIR
# pointed there too; writes nothing outside them and never touches the real ~/.grok.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
COMMON=""
WORKDIR=""
SEED=""

WORKFLOW_NAMES="debug-fix fleet-verify implement-reviewed"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  COMMON="${REPO_ROOT}/templates/common"
  WORKDIR="${REPO_ROOT}/.grok/workflows"
  SEED="${COMMON}/stack-workflows.sh.tftpl"
}

# render_seed <out> -- the seed body the way terraform would render it: hide every escaped
# $${ pair, substitute each map key against the REAL payload file, put the escapes back.
# The order is the one bats_render_tftpl documents, and it is load-bearing here for a reason
# that suite does not have: these three payloads are JavaScript full of dollar-brace
# template literals, so substituting first and folding after would rewrite the module. The
# boot logger splices in for real, so the assertions below read the narration the operator
# reads rather than a stubbed word.
#
# An ${name} the template references but this call does not supply is a failure: a key
# renamed on one side of the seam has to be a red test, not a body running with a hole
# where its payload was.
render_seed() {
  local out="${1}"
  python3 - "${SEED}" "${out}" "${COMMON}" <<'PY'
import pathlib
import re
import sys

tpl, dest, common = sys.argv[1], sys.argv[2], sys.argv[3]
keys = {
    "debug_fix_workflow": "debug-fix.workflow.js",
    "fleet_verify_workflow": "fleet-verify.workflow.js",
    "implement_reviewed_workflow": "implement-reviewed.workflow.js",
}
ESC = "\x00ESC{"
text = pathlib.Path(tpl).read_text(encoding="utf-8")
text = text.replace("$${", ESC)

refs = set(re.findall(r"\$\{([A-Za-z0-9_]+)\}", text))
wanted = set(keys) | {"boot_log_lib"}
if refs != wanted:
    sys.exit("FAIL: %s: templatefile() interpolates %s, expected %s"
             % (tpl, sorted(refs), sorted(wanted)))

for key, name in keys.items():
    body = pathlib.Path(common, name).read_text(encoding="utf-8")
    text = text.replace("${" + key + "}", body.rstrip("\n"))

lib = pathlib.Path(common, "boot-log.lib.sh").read_text(encoding="utf-8")
text = text.replace("${boot_log_lib}", lib.rstrip("\n"))
pathlib.Path(dest).write_text(text.replace(ESC, "${"), encoding="utf-8")
PY
}

# new_home <dir> -- a fixture home with an empty managed workflows directory.
new_home() {
  mkdir -p "${1}/.grok/workflows"
}

# run_seed <home> -- the rendered body as the boot runs it, with HOME and TMPDIR both inside
# the test's own tree so nothing escapes and the scratch directory is observable.
run_seed() {
  local home="${1}" rendered="${BATS_TEST_TMPDIR}/seed.sh" tmp="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${tmp}"
  render_seed "${rendered}" || return 1
  run env HOME="${home}" TMPDIR="${tmp}" sh "${rendered}"
}

# ---------------------------------------------------------------------------

@test "canonical bodies: each workflow lives in templates/common under the payload name" {
  local name
  for name in ${WORKFLOW_NAMES}; do
    assert_file_exists "the canonical ${name} body" "${COMMON}/${name}.workflow.js"
    [ -s "${COMMON}/${name}.workflow.js" ] || {
      printf 'FAIL: %s/%s.workflow.js is empty\n' "${COMMON}" "${name}" >&2; return 1; }
  done
}

@test "canonical bodies: each repo-tier entry is a symlink resolving to its body" {
  # The .grok/agents/*.md discipline: one canonical body, one link per consumer. A regular
  # file here is a fork that drifts, and the tier that wins decides which one runs. Two
  # failures differ, so two checks: -e follows the link and catches a dangling one, and
  # readlink -f says where it landed. Under a runfiles tree the chain walks out to the real
  # checkout, so the destination is matched on its templates/common tail rather than on an
  # absolute path -- that would test Bazel's materialisation, not the link. cmp then proves
  # a link to the wrong sibling cannot pass.
  local name link target
  for name in ${WORKFLOW_NAMES}; do
    link="${WORKDIR}/${name}.js"
    [[ -e "${link}" ]] || {
      printf 'FAIL: %s does not resolve - the repo tier cannot discover it\n' "${link}" >&2; return 1; }
    target="$(readlink -f "${link}")"
    case "${target}" in
      */templates/common/"${name}".workflow.js) ;;
      *)
        printf 'FAIL: %s resolves to %s, not to the templates/common/%s.workflow.js payload\n' \
          "${link}" "${target}" "${name}" >&2
        return 1
        ;;
    esac
    cmp -s "${link}" "${COMMON}/${name}.workflow.js" || {
      printf 'FAIL: %s does not carry the bytes of %s/%s.workflow.js\n' \
        "${link}" "${COMMON}" "${name}" >&2; return 1; }
  done
}

@test "canonical bodies: the repo workflow directory holds nothing but the four" {
  # A stray .js here is a workflow the picker lists and nobody maintains - the shape a
  # staging file left behind by a seed would take.
  local f
  for f in "${WORKDIR}"/*; do
    [ -e "${f}" ] || continue
    case "$(basename "${f}")" in
      debug-fix.js | fleet-verify.js | implement-reviewed.js | open-bugs.js) ;;
      *)
        printf 'FAIL: %s is not one of the four workflows this directory owns\n' "${f}" >&2
        return 1
        ;;
    esac
  done
}

@test "seed: the body writes the user tier and reaches for nothing else" {
  [ -f "${SEED}" ] || { printf 'FAIL: no seed body at %s\n' "${SEED}" >&2; return 1; }
  grep -qF '"$HOME/.grok/workflows' "${SEED}" || {
    printf 'FAIL: the seed never names $HOME/.grok/workflows, so it seeds no user tier\n' >&2; return 1; }
  grep -qF '$HOME/.grok/workflows/' "${SEED}" || {
    printf 'FAIL: the seed never names a destination under the user workflow home\n' >&2; return 1; }
  # The other tiers belong to their own bodies; a second writer is two boots arguing.
  run grep -nE '\$HOME/\.grok/(agents|personas|hooks)|\.coder/skills|\.agents/skills' "${SEED}"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: the workflow seed also writes a tier another body owns: %s\n' "${lines[0]}" >&2; return 1; }
  # Never deletes: the contract is write-or-leave, and a prune is one bad boot from
  # erasing a person's own workflow.
  run grep -nE '\brm -rf\b|\brm -r\b|find .*-delete' "${SEED}"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: the seed removes something: %s\n' "${lines[0]}" >&2; return 1; }
}

@test "seed: every shell brace is escaped, so templatefile has only its four keys" {
  # A single-dollar brace reference anywhere in a .tftpl is an interpolation, and the plan
  # fails when main.tf does not pass that key. render_seed asserts the exact ref set.
  local rendered="${BATS_TEST_TMPDIR}/escape-check.sh"
  render_seed "${rendered}" || {
    printf 'FAIL: the seed body references a key the twins do not pass\n' >&2; return 1; }
  [ -s "${rendered}" ] || { printf 'FAIL: the render is empty\n' >&2; return 1; }
  # Folded escapes have to be back as live shell, or the body dies under set -u.
  grep -qF 'for evo_t1_src in "${evo_t1_dir}"' "${rendered}" || {
    printf 'FAIL: the loop variable never came back as shell after the render\n' >&2; return 1; }
  grep -qF 'export default async function' "${rendered}" || {
    printf 'FAIL: no workflow body landed in the render\n' >&2; return 1; }
}

@test "seed: a hand-authored workflow survives and the boot says so" {
  local home="${BATS_TEST_TMPDIR}/person"
  new_home "${home}"
  printf 'export default function mine() { return "mine"; }\n' >"${home}/.grok/workflows/debug-fix.js"

  run_seed "${home}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: the boot failed: %s\n' "${output}" >&2; return 1; }
  [ "$(cat "${home}/.grok/workflows/debug-fix.js")" = \
    'export default function mine() { return "mine"; }' ] || {
    printf 'FAIL: the seed overwrote a file whose marker the operator deleted\n' >&2; return 1; }
  printf '%s\n' "${output}" | grep -q '^note: debug-fix\.js' || {
    printf 'FAIL: the declined write went unreported: %s\n' "${output}" >&2; return 1; }
  # The other two are still stack-owned and still arrive.
  [ -s "${home}/.grok/workflows/fleet-verify.js" ] || {
    printf 'FAIL: declining one workflow declined the family\n' >&2; return 1; }
}

@test "seed: a marker-carrying copy is refreshed to the canonical bytes" {
  local home="${BATS_TEST_TMPDIR}/stale" name
  new_home "${home}"
  for name in ${WORKFLOW_NAMES}; do
    printf '// stale from an earlier boot\n// managed-by: evo-t1-coder-stack\n' \
      >"${home}/.grok/workflows/${name}.js"
  done

  run_seed "${home}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: the boot failed: %s\n' "${output}" >&2; return 1; }
  for name in ${WORKFLOW_NAMES}; do
    local dest="${home}/.grok/workflows/${name}.js"
    if grep -q 'stale from an earlier boot' "${dest}"; then
      printf 'FAIL: %s was never rewritten\n' "${name}" >&2
      return 1
    fi
    grep -q 'export default async function' "${dest}" || {
      printf 'FAIL: %s is not the canonical module\n' "${name}" >&2; return 1; }
    tail -n 1 "${dest}" | grep -qF '// managed-by: evo-t1-coder-stack' || {
      printf 'FAIL: %s lost its marker, so no later boot refreshes it\n' "${name}" >&2; return 1; }
  done
}

@test "seed: an absent workflow lands with the marker that keeps it current" {
  local home="${BATS_TEST_TMPDIR}/fresh" name
  new_home "${home}"

  run_seed "${home}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: the boot failed: %s\n' "${output}" >&2; return 1; }
  for name in ${WORKFLOW_NAMES}; do
    [ -f "${home}/.grok/workflows/${name}.js" ] || {
      printf 'FAIL: %s.js was not seeded into the user home\n' "${name}" >&2; return 1; }
    # The marker is appended, never prepended: row 1 stays the payload's own frame comment
    # the runner reads its name: out of.
    head -n 1 "${home}/.grok/workflows/${name}.js" | grep -q '^/\*\*$' || {
      printf 'FAIL: %s.js no longer opens with its frame comment\n' "${name}" >&2; return 1; }
    tail -n 1 "${home}/.grok/workflows/${name}.js" | grep -qF '// managed-by: evo-t1-coder-stack' || {
      printf 'FAIL: %s.js carries no stack marker\n' "${name}" >&2; return 1; }
  done
}

@test "seed: nothing outside the managed set is touched and the scratch dir is left clean" {
  local home="${BATS_TEST_TMPDIR}/mine" tmp="${BATS_TEST_TMPDIR}/tmp" kept
  new_home "${home}"
  mkdir -p "${tmp}"
  printf 'export default function yours() {}\n' >"${home}/.grok/workflows/my-own.js"
  kept="$(cat "${home}/.grok/workflows/my-own.js")"

  run_seed "${home}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: the boot failed: %s\n' "${output}" >&2; return 1; }
  [ "$(cat "${home}/.grok/workflows/my-own.js")" = "${kept}" ] || {
    printf 'FAIL: the seed rewrote a workflow it does not manage\n' >&2; return 1; }
  [ -e "${home}/.grok/workflows/my-own.js" ] || {
    printf 'FAIL: the seed deleted a workflow it does not manage\n' >&2; return 1; }
  # The staged scratch files are the loop's input and have to leave no trace.
  [ -z "$(find "${tmp}" -mindepth 1 -print -quit)" ] || {
    printf 'FAIL: the seed left its scratch tree behind: %s\n' \
      "$(find "${tmp}" -mindepth 1 -print | tr '\n' ' ')" >&2; return 1; }
}

@test "seed: a symlinked user workflow home is refused out loud" {
  local home="${BATS_TEST_TMPDIR}/linked" elsewhere="${BATS_TEST_TMPDIR}/elsewhere"
  mkdir -p "${home}/.grok" "${elsewhere}"
  ln -s "${elsewhere}" "${home}/.grok/workflows"

  run_seed "${home}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: a refused install must not fail the boot: %s\n' "${status}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -q 'workflows is a symlink' || {
    printf 'FAIL: the bail-out went unreported: %s\n' "${output}" >&2; return 1; }
  [ ! -e "${elsewhere}/debug-fix.js" ] || {
    printf 'FAIL: the seed wrote through the link anyway\n' >&2; return 1; }
}

@test "seed: the run narrates in the boot's own vocabulary" {
  local home="${BATS_TEST_TMPDIR}/narrate"
  new_home "${home}"

  run_seed "${home}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: the boot failed: %s\n' "${output}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -q '^== stack workflows: start ==$' || {
    printf 'FAIL: the run never named itself: %s\n' "${output}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -q '^-> ' || {
    printf 'FAIL: no phase line: %s\n' "${output}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -q '^ok: ' || {
    printf 'FAIL: no completed item was counted: %s\n' "${output}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -qE '^summary: [0-9]+ ok, [0-9]+ warnings, [0-9]+ failed' || {
    printf 'FAIL: the run closed without a summary: %s\n' "${output}" >&2; return 1; }
}

@test "twins: both templates declare coder_script stack_workflows with the four payloads" {
  local twin key
  for twin in "${REPO_ROOT}/templates/workspace/main.tf" "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    assert_file_exists "the template twin" "${twin}"
    grep -qF 'resource "coder_script" "stack_workflows"' "${twin}" || {
      printf 'FAIL: %s declares no stack_workflows coder_script, so that template never seeds the user tier\n' "${twin}" >&2; return 1; }
    grep -qF 'stack-workflows.sh.tftpl' "${twin}" || {
      printf 'FAIL: %s does not render the seed body\n' "${twin}" >&2; return 1; }
    for key in boot_log_lib debug_fix_workflow fleet_verify_workflow implement_reviewed_workflow; do
      grep -qE "${key}[[:space:]]*=" "${twin}" || {
        printf 'FAIL: %s passes no %s to the seed body\n' "${twin}" "${key}" >&2; return 1; }
    done
    for key in debug-fix fleet-verify implement-reviewed; do
      grep -qF "file(\"\${path.module}/${key}.workflow.js\")" "${twin}" || {
        printf 'FAIL: %s never reads %s.workflow.js from the pushed copy\n' "${twin}" "${key}" >&2; return 1; }
    done
  done
}

@test "push: template-push.sh names all four new payloads in both its lists" {
  # The loop is the hard stop that saves the server's Terraform; the header docstring is
  # the list a person reads to know what a push stages. Both have to carry the name.
  local push="${REPO_ROOT}/scripts/lib/template-push.sh" payload
  assert_file_exists "the push lib" "${push}"
  for payload in stack-workflows.sh.tftpl debug-fix.workflow.js \
    fleet-verify.workflow.js implement-reviewed.workflow.js; do
    # The loop is the guard that stops a push before the CLI runs; the docstring is the
    # list a person reads to know what a push stages. Two shapes, so two reads: a token on
    # a non-comment line is the loop, one on a comment line is the docstring.
    grep -v '^[[:space:]]*#' "${push}" | grep -qwF "${payload}" || {
      printf 'FAIL: %s is not in the for payload in loop, so a push stages nothing and dies in the server Terraform\n' "${payload}" >&2; return 1; }
    grep -qE "^#.*${payload}" "${push}" || {
      printf 'FAIL: %s is missing from the header docstring payload list\n' "${payload}" >&2; return 1; }
  done
}

@test "push: the canonical bodies are still JavaScript the runner can load" {
  # The move to templates/common took them out of the directory agent-workflows.bats walks,
  # so the parse check runs here against the bytes that now travel.
  command -v node >/dev/null 2>&1 || skip "node is not on PATH in this runner"
  local name
  for name in ${WORKFLOW_NAMES}; do
    run node --check "${COMMON}/${name}.workflow.js"
    [ "${status}" -eq 0 ] || {
      printf 'FAIL: %s/%s.workflow.js is not valid JavaScript: %s\n' \
        "${COMMON}" "${name}" "${output}" >&2; return 1; }
  done
}

@test "push: every canonical body stays pure ASCII" {
  # It travels through a here-doc, a tar, and a JSON-quoted coder_script argument; a
  # non-ASCII byte that survives all three still reads as mojibake in the picker.
  local name
  for name in ${WORKFLOW_NAMES}; do
    run env LC_ALL=C grep -n '[^ -~]' "${COMMON}/${name}.workflow.js"
    [ "${status}" -ne 0 ] || {
      printf 'FAIL: %s carries a non-ASCII byte: %s\n' "${name}" "${lines[0]}" >&2; return 1; }
  done
  run env LC_ALL=C grep -n '[^ -~]' "${SEED}"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: the seed body carries a non-ASCII byte: %s\n' "${lines[0]}" >&2; return 1; }
}
