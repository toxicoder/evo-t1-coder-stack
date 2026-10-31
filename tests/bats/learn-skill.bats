#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## learn-skill.bats - guardrails for the stack-shipped /learn skill.
#
# Upstream /learn is a BUNDLED Grok Build skill: its download goes through the
# CLI's proxy endpoints and needs an x.ai sign-in. This stack has no x.ai
# credential (LiteLLM is the sole model transport), so ~/.grok/bundled/ is
# never created and the slash name is simply missing. The stack therefore ships
# its own templates/common/learn.SKILL.md and seeds it on the same contract as
# the grok-build-delegation skill: the boot writes ~/.coder/skills/learn/SKILL.md
# (what the Coder Agents chat agent reads) while the file is absent, then
# twin-copies it to ~/.agents/skills/learn/SKILL.md (what the Grok Build CLI
# reads). Skill dedupe is first-match-wins, so both spellings have to exist for
# the two consumers.
#
# This suite pins the whole seam from both ends: the two startup.sh.tftpl twins
# carry the absent-only seed guard, the quoted LEARN_SKILL_MD_EOF heredoc and
# the twin copy; both main.tf twins feed learn_skill into that render; the one
# common payload parses as a skill (frontmatter first, managed-by marker below
# it, plain ASCII), carries only keys Grok Build documents and names the tool
# that runs its commands, and tells the truth in that marker comment about how
# to take a seeded copy over; and scripts/lib/config_seed.sh names both targets
# against that same payload so a reseed can re-materialize them.
#
# Usage: bazelisk test //tests:bats_learn_skill_test   (from any cwd)
# Safety: reads the two startup.sh.tftpl twins, the two main.tf twins,
# templates/common/learn.SKILL.md and scripts/lib/config_seed.sh; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
PAYLOAD=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PAYLOAD="${REPO_ROOT}/templates/common/learn.SKILL.md"
  [[ -f "${PAYLOAD}" &&
    -f "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" &&
    -f "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl" ]] ||
    skip "the learn payload or a template twin is not reachable from ${REPO_ROOT}"
}

@test "learn seed: both startup twins seed the coder copy only while it is absent" {
  # The absent-only guard is what lets an operator keep their own /learn: the
  # boot never overwrites a file that exists, so an edited copy that dropped
  # the stack marker stays theirs. Deleting the file does not take over - the
  # guard simply writes the stack's copy back at the next boot.
  local tpl_dir
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -F 'if [ ! -f "$HOME/.coder/skills/learn/SKILL.md" ]; then' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'mkdir -p "$HOME/.coder/skills/learn" 2>/dev/null' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'cat >"$HOME/.coder/skills/learn/SKILL.md"' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
  done
}

@test "learn seed: both startup twins write the body through a quoted heredoc" {
  # A quoted delimiter is load-bearing: the payload is markdown full of $-text,
  # and an unquoted heredoc would expand it while the boot ran. The closing
  # delimiter has to sit alone on its own line, exactly as the opener spells it.
  local tpl_dir
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -F -- "<<'LEARN_SKILL_MD_EOF'" "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -Fx 'LEARN_SKILL_MD_EOF' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    # The body is the main.tf-supplied payload, never an inline copy of it.
    run grep -F '${learn_skill}' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
  done
}

@test "learn seed: both startup twins twin-copy into .agents from the managed copy" {
  # ~/.agents/skills/ is the CLI-side spelling. Copying only while absent, and
  # only from the ~/.coder copy, keeps one live source under the stack's
  # first-match-wins dedupe and leaves a hand-placed CLI-side skill alone.
  local tpl_dir n
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -F 'if [ ! -f "$HOME/.agents/skills/learn/SKILL.md" ]; then' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'mkdir -p "$HOME/.agents/skills/learn" 2>/dev/null' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F 'cp "$HOME/.coder/skills/learn/SKILL.md"' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    run grep -F '"$HOME/.agents/skills/learn/SKILL.md" 2>/dev/null' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -eq 0 ]
    # The twin is a copy of the managed file, never a second heredoc body: two
    # inline copies is exactly the drift this payload exists to avoid, so the
    # closer may appear exactly once per twin.
    n="$(grep -cFx 'LEARN_SKILL_MD_EOF' "${tpl_dir}/startup.sh.tftpl")"
    assert_eq "${tpl_dir} closes the learn heredoc exactly once" "1" "${n}"
  done
}

@test "learn feed: both main.tf twins read the payload from their staged copy" {
  # Each template travels as its own tarball and the server reads the payload
  # with file() from inside the pushed copy, so a twin that lost this feed
  # fails the push outright (template_push_one's guard) or fails the render
  # (templatefile() rejects the undefined ${learn_skill}).
  local tpl_dir
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -E 'learn_skill[[:space:]]+=[[:space:]]+chomp\(file\("\$\{path\.module\}/learn\.SKILL\.md"\)\)' \
      "${tpl_dir}/main.tf"
    [ "${status}" -eq 0 ]
    # chomp, like the delegation skill beside it: the heredoc closes on its own
    # line, so a trailing newline in the payload would add a blank line to the
    # written file on every seed.
    run grep -E 'learn_skill[[:space:]]+=[[:space:]]+file\(' "${tpl_dir}/main.tf"
    [ "${status}" -ne 0 ]
  done
}

@test "learn payload: the parser sees frontmatter first and the marker below it" {
  # The skill parser drops a file whose first line is not exactly ---, so the
  # stack-owned marker that GROK_BUILD_AGENTS.md carries on line 2 must never
  # be promoted to line 1 here: an HTML comment on line 1 silently unregisters
  # /learn. name: is the key that registers the slash name.
  run head -n 1 "${PAYLOAD}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "---" ]

  local close
  close="$(awk 'NR > 1 && /^---[[:space:]]*$/ { print NR; exit }' "${PAYLOAD}")"
  [ -n "${close}" ] || {
    printf 'FAIL: no closing frontmatter fence in %s\n' "${PAYLOAD}" >&2
    return 1
  }
  [ "${close}" -gt 2 ]

  local frontmatter
  frontmatter="$(sed -n "2,$((close - 1))p" "${PAYLOAD}")"
  assert_match "name key registers the slash name" '^name:[[:space:]]*learn[[:space:]]*$' "${frontmatter}"
  assert_match "description key is present" '^description:[[:space:]]*[^[:space:]]' "${frontmatter}"

  # The marker has to be provenance, not structure: below the closing fence.
  local marker
  marker="$(grep -nF 'managed-by: evo-t1-coder-stack' "${PAYLOAD}" | head -n 1 | cut -d: -f1)"
  [ -n "${marker}" ] || {
    printf 'FAIL: %s lost the managed-by marker\n' "${PAYLOAD}" >&2
    return 1
  }
  [ "${marker}" -gt "${close}" ]
}

@test "learn payload: it stays plain ASCII" {
  # Every consumer of this file reads it as text a shell or a parser parses: a
  # curly quote or an en dash survives into the seeded skill and reads as
  # mojibake in the terminal, and byte-wise comparisons treat it as different.
  local stray
  stray="$(tr -d '\0-\177' <"${PAYLOAD}" | wc -c | tr -d ' ')"
  if [ "${stray}" -ne 0 ]; then
    printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${PAYLOAD}" "${stray}" >&2
    LC_ALL=C grep -n '[^ -~]' "${PAYLOAD}" >&2
    return 1
  fi
  run grep -c $'\r' "${PAYLOAD}"
  [ "${status}" -ne 0 ]
}

@test "learn payload: the frontmatter parses and stays inside the documented keys" {
  # This is what actually registers /learn: Grok Build's own /create-skill writes
  # name and description and nothing else, and the keys it documents are the
  # whole set a skill may carry. A key outside that set is drift the CLI ignores,
  # and user-invocable: false would unregister the slash name this payload exists
  # to ship. PyYAML is optional the way py_helpers.bats treats it: skip, never
  # hard-fail, when the interpreter has no yaml module.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  python3 -c '
import sys, yaml
lines = sys.stdin.read().splitlines()
if not lines or lines[0].strip() != "---":
    sys.exit("FAIL: the frontmatter does not open with --- on line 1")
close = 0
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        close = i
        break
if close == 0:
    sys.exit("FAIL: no closing frontmatter fence")
try:
    data = yaml.safe_load("\n".join(lines[1:close]))
except yaml.YAMLError as exc:
    sys.exit("FAIL: the frontmatter is not valid YAML: %s" % exc)
if not isinstance(data, dict):
    sys.exit("FAIL: the frontmatter is not a mapping: %r" % (data,))
documented = set(("name", "description", "when-to-use", "allowed-tools",
                  "argument-hint", "user-invocable", "disable-model-invocation",
                  "model", "effort", "license", "compatibility", "metadata"))
unknown = sorted(set(data) - documented)
if unknown:
    sys.exit("FAIL: keys outside the documented set: %s" % ", ".join(unknown))
if data.get("name") != "learn":
    sys.exit("FAIL: name must be exactly learn, got %r" % (data.get("name"),))
desc = data.get("description")
if not isinstance(desc, str) or not desc.strip():
    sys.exit("FAIL: description must be a non-empty string, got %r" % (desc,))
if "user-invocable" in data and data["user-invocable"] is not True:
    sys.exit("FAIL: user-invocable must be the boolean true, got %r"
             % (data["user-invocable"],))
' <"${PAYLOAD}"
}

@test "learn payload: the marker comment tells the truth about taking it over" {
  # Deleting the seeded file gets it back: startup.sh.tftpl writes it whenever it
  # is absent and config_seed.sh counts an absent target as seeded, so the only
  # takeover is an edit that drops the marker line (the seeder's ownership probe
  # leaves a marker-free file alone short of --force). Pinning the wording is the
  # only thing that keeps that fact from drifting back into the payload.
  run grep -Ei -- 'delete[[:space:]]+this[[:space:]]+file' "${PAYLOAD}"
  [ "${status}" -ne 0 ]

  # Still provenance for the seeder probe, and it says how ownership moves.
  assert_contains_file "the seeder marker string survives" "${PAYLOAD}" \
    'managed-by: evo-t1-coder-stack'
  run grep -Ei -- 'delete[^.]*marker' "${PAYLOAD}"
  [ "${status}" -eq 0 ]
  # And how to hide the slash command without deleting anything.
  assert_contains_file "hiding names the skills table" "${PAYLOAD}" '\[skills\]'
  run grep -Ei -- 'disabled[[:space:]]*=[[:space:]]*\[' "${PAYLOAD}"
  [ "${status}" -eq 0 ]
}

@test "learn payload: it names the tool that runs the commands it shows" {
  # Grok Build's skills guide: reference tools by name, and a command written
  # inline in a skill body runs nothing until the body says who runs it. The
  # payload shows several indented command blocks, so its intro has to name
  # run_terminal_command or the model may narrate them instead of running them.
  assert_contains_file "the intro names the terminal tool" "${PAYLOAD}" \
    'run_terminal_command'
}

@test "learn seams: config_seed names both targets against the one payload" {
  # refresh-configs reseeds from this list; a target missing here means a
  # workspace keeps a stale or absent /learn after a stack update.
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  [ -f "${lib}" ] || skip "no config_seed lib under ${REPO_ROOT}/scripts/lib"
  assert_contains_file "coder learn target" "${lib}" '~/.coder/skills/learn/SKILL\.md'
  assert_contains_file "agents learn target" "${lib}" '~/.agents/skills/learn/SKILL\.md'
  assert_contains_file "learn payload source" "${lib}" 'file:templates/common/learn\.SKILL\.md'
  # The push guard has to name the payload too, or a tree that lost it ships a
  # template whose Terraform apply dies on the missing file().
  assert_contains_file "push guard lists the payload" \
    "${REPO_ROOT}/scripts/lib/template-push.sh" 'learn\.SKILL\.md'
}
