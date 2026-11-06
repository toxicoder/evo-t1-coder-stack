#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ez-learn-skill.bats - guardrails for the stack-shipped /ez-learn skill.
#
# Upstream /learn is a BUNDLED Grok Build skill: its download goes through the
# CLI's proxy endpoints and needs an x.ai sign-in. This stack has no x.ai
# credential (LiteLLM is the sole model transport), so ~/.grok/bundled/ is
# never created and the slash name is simply missing. The stack therefore ships
# its own templates/common/ez-learn.SKILL.md and seeds it on the same contract as
# the grok-build-delegation skill: the file is written into
# ~/.coder/skills/ez-learn/SKILL.md (what the Coder Agents chat agent reads)
# while it is absent, then twin-copied to ~/.agents/skills/ez-learn/SKILL.md
# (what the Grok Build CLI reads). Skill dedupe is first-match-wins, so both
# spellings have to exist for the two consumers.
#
# That seed no longer rides in startup.sh.tftpl. main.tf inlines every payload
# into coder_agent.startup_script and the agent execs that body as ONE argument,
# gated at 122880 bytes, and the devcontainer twin had 491 bytes of headroom
# left; each coder_script.script is its own execve with its own ceiling, so the
# skill bodies moved to templates/common/stack-skills.sh.tftpl, rendered by
# coder_script "stack_skills" in both main.tf twins.
# docs/coder-templates.md#the-one-argument-ceiling. The target PATHS did not
# move, so the two-home pair, the startup-side grok-build-delegation seed and
# the /learn retirement loop are still startup tests.
#
# The copy the stack left under the bare /learn name before that move is retired
# by both the boot and the reseed, and only while it still carries the stack
# marker.
#
# This suite pins the whole seam from both ends: the stack-skills body carries
# the absent-only seed guard, the quoted EZ_LEARN_SKILL_MD_EOF heredoc and the
# twin copy; the startup twins carry neither, but keep the delegation seed and
# the retirement loop; both main.tf twins feed ez_learn_skill, chomped, into
# that new body and no longer into the startup_script map; the one common
# payload parses as a skill (frontmatter first, managed-by marker below it,
# plain ASCII), carries only keys Grok Build documents and names the tool that
# runs its commands, and tells the truth in that marker comment about how to
# take a seeded copy over; and scripts/lib/config_seed.sh names both targets
# against that same payload so a reseed can re-materialize them.
#
# The rest of the suite pins the payload's own claims against the tree it
# describes, so an edit that makes the skill lie fails the gate rather than
# sending an operator to a target, a doc, an alias or a path that is not there:
# what its mining contract promises (report-only by default, one proposal shape,
# a retire that never deletes, the seed as the only write target, grok inspect
# as the proof) is what the payload actually says, every bazel label it cites
# resolves, every doc path it points at exists, its alias list stays inside what
# litellm/config.yaml defines, and its notes and skills paths match what the
# seeder and the two skill readers actually use.
#
# Usage: bazelisk test //tests:bats_ez_learn_skill_test   (from any cwd)
# Safety: reads the stack-skills seed body, the two startup.sh.tftpl twins, the
# two main.tf twins, templates/common/ez-learn.SKILL.md,
# templates/common/notes-setup.sh, scripts/lib/config_seed.sh,
# scripts/lib/probes/seed-rm-managed.sh, litellm/config.yaml, the root BUILD
# file, the scripts/ tree and the repo docs; the retire tests write only into a
# per-test scratch home under BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
PAYLOAD=""
SEED=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PAYLOAD="${REPO_ROOT}/templates/common/ez-learn.SKILL.md"
  SEED="${REPO_ROOT}/templates/common/stack-skills.sh.tftpl"
  [[ -f "${PAYLOAD}" && -f "${SEED}" &&
    -f "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" &&
    -f "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl" ]] ||
    skip "the learn payload, the seed body or a template twin is not reachable from ${REPO_ROOT}"
}

@test "ez-learn seed: the stack-skills body seeds the coder copy only while it is absent" {
  # The absent-only guard is what lets an operator keep their own /ez-learn: the
  # body never overwrites a file that exists, so an edited copy that dropped the
  # stack marker stays theirs. Deleting the file does not take over - the body
  # simply writes the stack's copy back at the next start.
  run grep -F 'if [ ! -f "$HOME/.coder/skills/ez-learn/SKILL.md" ]; then' "${SEED}"
  [ "${status}" -eq 0 ]
  run grep -F 'mkdir -p "$HOME/.coder/skills/ez-learn" 2>/dev/null' "${SEED}"
  [ "${status}" -eq 0 ]
  run grep -F 'cat >"$HOME/.coder/skills/ez-learn/SKILL.md"' "${SEED}"
  [ "${status}" -eq 0 ]
}

@test "ez-learn seed: the body writes it through a quoted heredoc" {
  # A quoted delimiter is load-bearing: the payload is markdown full of $-text,
  # and an unquoted heredoc would expand it while the script ran. The closing
  # delimiter has to sit alone on its own line, exactly as the opener spells it.
  # The opener's digraph is built from halves: bats' preprocessor reads a spelled
  # << inside a needle as a real here-document opener and swallows the lines below.
  run grep -F -- "$(printf '%s%s' '<' '<')'EZ_LEARN_SKILL_MD_EOF'" "${SEED}"
  [ "${status}" -eq 0 ]
  run grep -Fx 'EZ_LEARN_SKILL_MD_EOF' "${SEED}"
  [ "${status}" -eq 0 ]
  # The body is the main.tf-supplied payload, never an inline copy of it.
  run grep -F '${ez_learn_skill}' "${SEED}"
  [ "${status}" -eq 0 ]
}

@test "ez-learn seed: the .agents twin is a cp of the managed copy" {
  # ~/.agents/skills/ is the CLI-side spelling. Copying only while absent, and
  # only from the ~/.coder copy, keeps one live source under the stack's
  # first-match-wins dedupe and leaves a hand-placed CLI-side skill alone.
  run grep -F 'if [ ! -f "$HOME/.agents/skills/ez-learn/SKILL.md" ]; then' "${SEED}"
  [ "${status}" -eq 0 ]
  run grep -F 'mkdir -p "$HOME/.agents/skills/ez-learn" 2>/dev/null' "${SEED}"
  [ "${status}" -eq 0 ]
  run grep -F 'cp "$HOME/.coder/skills/ez-learn/SKILL.md"' "${SEED}"
  [ "${status}" -eq 0 ]
  run grep -F '"$HOME/.agents/skills/ez-learn/SKILL.md" 2>/dev/null' "${SEED}"
  [ "${status}" -eq 0 ]
  # The twin is a copy of the managed file, never a second heredoc body: two
  # inline copies is exactly the drift this payload exists to avoid. The body
  # now carries one heredoc tag per skill in the trio, so the count is per tag:
  # this one may appear exactly twice, its opener and its closer, and once as a
  # line of its own.
  local closer opens
  closer="$(grep -cFx 'EZ_LEARN_SKILL_MD_EOF' "${SEED}")"
  assert_eq "the learn heredoc closes exactly once" "1" "${closer}"
  opens="$(grep -c 'EZ_LEARN_SKILL_MD_EOF' "${SEED}")"
  assert_eq "the learn tag appears once as an opener and once as a closer" "2" "${opens}"
}

@test "ez-learn seed: the move out of both startup twins is complete and clean" {
  # Guards the move from both sides at once. A leftover ez-learn heredoc in a
  # startup twin is a second writer for one file (and the bytes this move was
  # made to free); and the two blocks the move cut beside it - the delegation
  # seed and the /learn retirement loop - are startup-side work that has to
  # survive it, since no coder_script "stack_skills" body seeds either.
  local tpl_dir
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    # No seed of its own survives here: neither the guard nor the heredoc tag
    # nor the rendered variable.
    run grep -F 'ez-learn' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -ne 0 ]
    run grep -F 'ez_learn_skill' "${tpl_dir}/startup.sh.tftpl"
    [ "${status}" -ne 0 ]
    # The neighbour that stays: grok-build-delegation, seed plus twin copy.
    run grep -F 'if [ ! -f "$HOME/.coder/skills/grok-build-delegation/SKILL.md" ]; then' \
      "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} still seeds the delegation skill" "0" "${status}"
    run grep -F '${grok_build_delegation_skill}' "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} still feeds the delegation body" "0" "${status}"
    run grep -F 'cp "$HOME/.coder/skills/grok-build-delegation/SKILL.md"' \
      "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} still twins the delegation skill" "0" "${status}"
    # And the loop that hands /learn back, which the trio never replaces.
    run grep -F 'for _d in "$HOME/.coder/skills/learn" "$HOME/.agents/skills/learn"; do' \
      "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} still retires the old /learn copy" "0" "${status}"
  done
}

@test "ez-learn feed: both main.tf twins feed the payload into the stack_skills body" {
  # Each template travels as its own tarball and the server reads the payload
  # with file() from inside the pushed copy, so a twin that lost this feed fails
  # the push outright (template_push_one's guard) or fails the render
  # (templatefile() rejects the undefined ${ez_learn_skill}).
  #
  # The feed has to sit in the new body's own templatefile map, not behind a
  # local: the size readers credit a coder_script body by the path.module names
  # inside its own block. And the startup_script map must have given the entry
  # up - that map is the one under the single-argument ceiling this move exists
  # to relieve. Pinning that the file holds exactly one such assignment is what
  # says so: a leftover entry beside the new one is two, and none is zero.
  #
  # chomp, like the delegation skill beside it: the heredoc closes on its own
  # line, so a trailing newline in the payload would add a blank line to every
  # file the body seeds.
  local tpl_dir block assigns
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(awk '/^resource "coder_script" "stack_skills"[[:space:]]*\{/{f=1}
      f{print} f&&/^\}/{exit}' "${tpl_dir}/main.tf")"
    assert_match "the twin declares the stack_skills script" \
      'resource "coder_script" "stack_skills"' "${block}"
    assert_match "its body is the stack-skills seed script" \
      'templatefile\("\$\{path\.module\}/stack-skills\.sh\.tftpl"' "${block}"
    assert_match "the body map feeds the chomped payload" \
      'ez_learn_skill[[:space:]]+=[[:space:]]+chomp\(file\("\$\{path\.module\}/ez-learn\.SKILL\.md"\)\)' \
      "${block}"

    assigns="$(grep -E 'ez_learn_skill[[:space:]]*=[[:space:]]*(chomp\()?file\(' \
      "${tpl_dir}/main.tf" || true)"
    assert_eq "exactly one ez-learn feed, so the startup_script map lost its own" "1" \
      "$(printf '%s\n' "${assigns}" | grep -c . || true)"

    # A bare file() would seed a trailing blank line into both homes.
    run grep -E 'ez_learn_skill[[:space:]]+=[[:space:]]+file\(' "${tpl_dir}/main.tf"
    [ "${status}" -ne 0 ]
  done
}

@test "ez-learn payload: the parser sees frontmatter first and the marker below it" {
  # The skill parser drops a file whose first line is not exactly ---, so the
  # stack-owned marker that GROK_BUILD_AGENTS.md carries on line 2 must never
  # be promoted to line 1 here: an HTML comment on line 1 silently unregisters
  # /ez-learn. name: is the key that registers the slash name.
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
  assert_match "name key registers the slash name" '^name:[[:space:]]*ez-learn[[:space:]]*$' "${frontmatter}"
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

@test "ez-learn payload: it stays plain ASCII" {
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

@test "ez-learn payload: the frontmatter parses and stays inside the documented keys" {
  # This is what actually registers /ez-learn: Grok Build's own /create-skill writes
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
if data.get("name") != "ez-learn":
    sys.exit("FAIL: name must be exactly ez-learn, got %r" % (data.get("name"),))
desc = data.get("description")
if not isinstance(desc, str) or not desc.strip():
    sys.exit("FAIL: description must be a non-empty string, got %r" % (desc,))
if "user-invocable" in data and data["user-invocable"] is not True:
    sys.exit("FAIL: user-invocable must be the boolean true, got %r"
             % (data["user-invocable"],))
' <"${PAYLOAD}"
}

@test "ez-learn payload: the marker comment tells the truth about taking it over" {
  # Deleting the seeded file gets it back: stack-skills.sh.tftpl writes it
  # whenever it is absent and config_seed.sh counts an absent target as seeded,
  # so the only takeover is an edit that drops the marker line (the seeder's
  # ownership probe leaves a marker-free file alone short of --force). Pinning
  # the wording is the only thing that keeps that fact from drifting back.
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

@test "ez-learn payload: it names the tool each consumer runs its commands with" {
  # Grok Build's skills guide: reference tools by name, and a command written
  # inline in a skill body runs nothing until the body says who runs it. The
  # payload shows several indented command blocks and two different readers run
  # them under different tool names, so it has to name both or one consumer
  # narrates the blocks instead of running them.
  assert_contains_file "the intro names the CLI-side terminal tool" "${PAYLOAD}" \
    'run_terminal_command'
  assert_contains_file "it names the chat-side runner in backticks too" "${PAYLOAD}" \
    '`execute`'
}

@test "ez-learn scope: it is workflow curation and says so against the memory system" {
  # The stack keeps these apart: /remember, /memory and /dream are the memory
  # store, this command curates workflows. A payload that drops the sentence is
  # read as a memory tool by the model and files workflow fixes as durable
  # facts, which nothing here can undo.
  assert_contains_file "it calls itself workflow curation" "${PAYLOAD}" \
    'workflow curation'
  assert_contains_file "it points durable facts at the memory system" "${PAYLOAD}" \
    '`/remember`'
}

@test "ez-learn modes: report-only is the default and apply steps through one at a time" {
  # The default is the safety property: a mining pass that writes accepted-
  # looking edits into homes and seeds without being asked is the one way this
  # command can do damage. Step-through apply is the counterpart, and accept /
  # edit / reject per proposal is what keeps an unreviewed proposal from landing.
  assert_contains_file "report-only is named as the default" "${PAYLOAD}" \
    'Report-only, the default'
  assert_contains_file "the default writes nothing" "${PAYLOAD}" 'write nothing'
  assert_contains_file "apply is offered as a second mode" "${PAYLOAD}" \
    'Step-through apply'
  assert_contains_file "each proposal is offered per item" "${PAYLOAD}" \
    'one proposal at a time'
  # The prose wraps between the second and third choice, so the answer is read
  # off the joined file rather than one line.
  assert_match "and answered accept, edit or reject" 'accept / edit /[[:space:]]*reject' \
    "$(tr '\n' ' ' <"${PAYLOAD}")"
}

@test "ez-learn proposals: every finding is proposed in one shape" {
  # The proposal block is the contract between the mining steps and the apply
  # step, and the reader's review surface: without the evidence field a single
  # anecdote reads as a convention, and without kind / name / scope nobody
  # knows what is being created, renamed or retired, or into which home. The
  # assertion is scoped to the Step 5 section so the words cannot survive as
  # decoration elsewhere in the file.
  local step5
  step5="$(awk '/^## Step 5 /{f=1;next} /^## /{f=0} f' "${PAYLOAD}")"
  [ -n "${step5}" ] || {
    printf 'FAIL: %s lost its Step 5 proposal-shape section\n' "${PAYLOAD}" >&2
    return 1
  }
  local field
  for field in '`kind`' '`name`' 'scope' '`description`' '`when-to-use`' 'steps' 'evidence'; do
    assert_match "the proposal shape carries ${field}" "${field}" "${step5}"
  done
}

@test "ez-learn proposals: a retire proposal never deletes on its own" {
  # The command proposes retiring skills, plugins, MCP servers and rules. Run
  # without the guard it is a tool that uninstalls things on a guess, so the
  # retire branch has to carry its own no-delete rule next to the
  # retire-without-deleting levers the Step 8 section offers.
  assert_contains_file "a retire proposal only names the stale thing" "${PAYLOAD}" \
    'never deleting on its own'
  assert_contains_file "retiring keeps a skill listed and inactive" "${PAYLOAD}" \
    'keeps a skill listed and inactive'
  assert_contains_file "and the hide-either lever is named" "${PAYLOAD}" \
    'ignore = \["path"\]'
}

@test "ez-learn writes: an accepted stack change goes to the seed, never a materialized copy" {
  # The stack-owned files under a home are regenerated by the boot and by
  # refresh-configs, so an "accepted" edit written straight into
  # ~/.coder/skills or ~/.grok/skills is undone at the next start and the
  # operator loses the fix they approved. The payload has to send stack work to
  # the seed that produces the file.
  assert_contains_file "stack work goes to the seed" "${PAYLOAD}" \
    'goes to the seed that produces the file'
  assert_contains_file "the seed is templates/common/" "${PAYLOAD}" 'templates/common/'
  assert_contains_file "and the materialized copy is off limits" "${PAYLOAD}" \
    'Never edit the copy in a home'
}

@test "ez-learn verify: grok inspect proves discovery and the source path" {
  # The command ends by proving the skill loaded. grok inspect is the only
  # reader-side truth here, and the name alone is not enough: first-match-wins
  # dedupe means a same-named skill elsewhere can shadow the one just written,
  # which is what the source path and the collision tag catch.
  assert_contains_file "it runs grok inspect" "${PAYLOAD}" 'grok inspect'
  assert_contains_file "and the json form that prints the source" "${PAYLOAD}" \
    'grok inspect --json'
  assert_contains_file "it checks the source is the path written" "${PAYLOAD}" \
    '`source` is the path you wrote'
  assert_contains_file "it checks the slash name is invocable" "${PAYLOAD}" \
    'userInvocable'
  assert_contains_file "and the shadowing case is named" "${PAYLOAD}" \
    'collides with /x -> scope:x'
}

@test "ez-learn siblings: it names the two commands it hands off to" {
  # The trio divides the work: this one mines and proposes, /ez-skillify
  # captures the session that just worked, /ez-create-skill scaffolds from a
  # description. Drop the hand-off and a reader who is told to write an
  # accepted skill has no sanctioned route and edits the seed by hand.
  assert_contains_file "it names the session-capture sibling" "${PAYLOAD}" '/ez-skillify'
  assert_contains_file "it names the scaffolding sibling" "${PAYLOAD}" '/ez-create-skill'
  assert_contains_file "it keeps proposing as its own half" "${PAYLOAD}" \
    '/ez-learn` proposes'
  assert_contains_file "and gives the writing to those two" "${PAYLOAD}" \
    'those two write'
}

@test "ez-learn seams: config_seed names both targets against the one payload" {
  # refresh-configs reseeds from this list; a target missing here means a
  # workspace keeps a stale or absent /ez-learn after a stack update.
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  [ -f "${lib}" ] || skip "no config_seed lib under ${REPO_ROOT}/scripts/lib"
  assert_contains_file "coder ez-learn target" "${lib}" '~/.coder/skills/ez-learn/SKILL\.md'
  assert_contains_file "agents ez-learn target" "${lib}" '~/.agents/skills/ez-learn/SKILL\.md'
  assert_contains_file "ez-learn payload source" "${lib}" 'file:templates/common/ez-learn\.SKILL\.md'
  # The push guard has to name the payload too, or a tree that lost it ships a
  # template whose Terraform apply dies on the missing file().
  assert_contains_file "push guard lists the payload" \
    "${REPO_ROOT}/scripts/lib/template-push.sh" 'ez-learn\.SKILL\.md'
  # And the seed body itself, since the coder_script now renders it from the
  # pushed copy: an unstaged stack-skills.sh.tftpl fails terraform init.
  assert_contains_file "push guard lists the seed body" \
    "${REPO_ROOT}/scripts/lib/template-push.sh" 'stack-skills\.sh\.tftpl'
}

@test "ez-learn retire: both startup twins hand /learn back to the CLI" {
  # The seed moved off the /learn name, and the absent-only contract never
  # deletes, so the boot has to retire the copy the stack left there. Left in
  # place it keeps shadowing the CLI's bundled skill for the life of the volume.
  local tpl_dir
  for tpl_dir in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    run grep -F 'for _d in "$HOME/.coder/skills/learn" "$HOME/.agents/skills/learn"; do' \
      "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} walks both retired dirs" "0" "${status}"
    run grep -F "grep -qF 'managed-by: evo-t1-coder-stack' \"\$_d/SKILL.md\"" \
      "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} asks the marker before it deletes" "0" "${status}"
    run grep -F 'rm -f "$_d/SKILL.md"' "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} removes the retired copy" "0" "${status}"
    run grep -F 'rmdir "$_d"' "${tpl_dir}/startup.sh.tftpl"
    assert_eq "${tpl_dir} prunes the dir it empties" "0" "${status}"
  done
}

@test "ez-learn retire: config_seed names the retired paths and guards the delete with the marker" {
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  local probe="${REPO_ROOT}/scripts/lib/probes/seed-rm-managed.sh"
  [ -f "${lib}" ] || skip "no config_seed lib under ${REPO_ROOT}/scripts/lib"
  [ -f "${probe}" ] || skip "the retire probe is not in the tree"
  # shellcheck source=/dev/null
  source "${lib}"
  local retired
  retired="$(seed_retired_targets)"
  assert_eq "one retired target per skill consumer" "2" \
    "$(printf '%s\n' "${retired}" | grep -c .)"
  assert_match "the coder copy is retired" '^~/\.coder/skills/learn/SKILL\.md$' "${retired}"
  assert_match "the agents copy is retired" '^~/\.agents/skills/learn/SKILL\.md$' "${retired}"
  # A rename reaches into a home on the strength of the marker, never the path
  # alone: the container delete goes through the probe that re-checks it there.
  assert_contains_file "the reseed calls the probe" "${lib}" 'probes/seed-rm-managed\.sh'
}

@test "ez-learn retire: only a copy the stack still owns comes away" {
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  local probe="${REPO_ROOT}/scripts/lib/probes/seed-rm-managed.sh"
  [ -f "${lib}" ] || skip "no config_seed lib under ${REPO_ROOT}/scripts/lib"
  [ -f "${probe}" ] || skip "the retire probe is not in the tree"
  local home marker status=0 out=""
  home="$(make_scratch)"
  marker='managed-by: evo-t1-coder-stack'
  mkdir -p "${home}/.coder/skills/learn" "${home}/.agents/skills/learn"
  printf -- '---\nname: learn\n---\n%s\n' "${marker}" >"${home}/.coder/skills/learn/SKILL.md"
  printf -- '---\nname: learn\n---\nwritten by hand\n' >"${home}/.agents/skills/learn/SKILL.md"
  # shellcheck source=/dev/null
  source "${lib}"

  # A preview names what it would take and touches nothing.
  out="$(seed_retire_renamed "" "${home}" 1 2>&1)" || status=$?
  assert_eq "a preview succeeds" "0" "${status}"
  assert_match "the preview says would-retire" 'would retire' "${out}"
  assert_file_exists "and leaves the managed copy standing" "${home}/.coder/skills/learn/SKILL.md"

  out="$(seed_retire_renamed "" "${home}" 0 2>&1)" || status=$?
  assert_eq "the reseed retires cleanly" "0" "${status}"
  assert_file_not_exists "the stack's own old copy is gone" "${home}/.coder/skills/learn/SKILL.md"
  assert_file_not_exists "its emptied dir went with it" "${home}/.coder/skills/learn"
  assert_file_exists "a marker-free copy is user-owned and stays" \
    "${home}/.agents/skills/learn/SKILL.md"
  # Re-running has to be silent: the contract is a no-op on an already-clean tree.
  out="$(seed_retire_renamed "" "${home}" 0 2>&1)" || status=$?
  assert_eq "a second pass still succeeds" "0" "${status}"
  assert_eq "and reports nothing to do" "" "${out}"

  # The container path runs the same marker rule inside the container, from the
  # probe the reseed cats in.
  mkdir -p "${home}/probe/managed" "${home}/probe/user"
  printf '%s\n' "${marker}" >"${home}/probe/managed/SKILL.md"
  printf 'mine\n' >"${home}/probe/user/SKILL.md"
  run sh "${probe}" "${home}/probe/managed/SKILL.md" "${marker}" '"__evoT1Stack": true' \
    '__evoT1Stack = true'
  assert_eq "the probe deletes a managed file" "0" "${status}"
  assert_file_not_exists "and prunes the dir it leaves" "${home}/probe/managed"
  run sh "${probe}" "${home}/probe/user/SKILL.md" "${marker}"
  assert_eq "a user file is a no-op, not an error" "0" "${status}"
  assert_file_exists "the user file stands" "${home}/probe/user/SKILL.md"
  run sh "${probe}" "${home}/probe/absent/SKILL.md" "${marker}"
  assert_eq "an absent path is a no-op too" "0" "${status}"
  run sh "${probe}" "${home}/probe/user/SKILL.md"
  assert_eq "and no markers proves nothing, so nothing goes" "0" "${status}"
  assert_file_exists "the user file still stands" "${home}/probe/user/SKILL.md"
}

@test "ez-learn targets: every bazel label the payload cites still resolves" {
  # Step 8 tells the reader to run what the payload prints, so a label the tree
  # stopped declaring is a dead end in the first minute of orienting. The root
  # BUILD file carries the //:labels and scripts/<stem>.sh carries the CLI
  # targets, which are the two places a target can come from here.
  [[ -f "${REPO_ROOT}/BUILD.bazel" ]] ||
    skip "the root BUILD file is not in this suite's runfiles (//:bazel_files)"

  local tokens resolvable token stem label bad missing required
  # The guard rejects a // preceded by a colon or a word char, so the
  # tcp://dind:2375 endpoint in Step 1 is not mistaken for a label, and the
  # label class carries <> so the payload's generic spelling survives capture.
  tokens="$(grep -oE '(^|[^:/A-Za-z])//([A-Za-z0-9_.-]*):([A-Za-z0-9_.<>-]+)' "${PAYLOAD}" |
    grep -oE '//[A-Za-z0-9_.-]*:[A-Za-z0-9_.<>-]+' | sort -u)"
  if [ -z "${tokens}" ]; then
    printf 'FAIL: %s cites no bazel target at all\n' "${PAYLOAD}" >&2
    return 1
  fi

  # The five gates the skill points an operator at: the loop below would pass
  # vacuously on a payload that had quietly dropped every one of them.
  required="$(printf '%s\n' //:test-fast //:lint //:fix //:validate //scripts:mcp-check | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "${required}") <(printf '%s\n' "${tokens}"))"
  if [ -n "${missing}" ]; then
    printf 'FAIL: %s no longer cites: %s\n' "${PAYLOAD}" "$(printf '%s ' "${missing}")" >&2
    return 1
  fi

  # //scripts:<stem> is the payload's generic spelling for a CLI target, so it
  # is pinned as a citation, not resolved as a label. The token class above
  # carries no shell metacharacter, so the loop can word-split the list.
  resolvable="$(printf '%s\n' "${tokens}" | grep -v '<' || true)"
  bad=""
  for token in ${resolvable}; do
    case "${token}" in
      //scripts:*)
        stem="${token#//scripts:}"
        [[ -f "${REPO_ROOT}/scripts/${stem}.sh" ]] ||
          bad="${bad}${token} (no scripts/${stem}.sh in the tree)"$'\n'
        ;;
      //:*)
        label="${token#//}"
        label="${label#:}"
        # The closing quote is part of the needle: name = "fix" must not be
        # satisfied by the fix_exec target beside it.
        grep -qF -- "name = \"${label}\"" "${REPO_ROOT}/BUILD.bazel" ||
          bad="${bad}${token} (no name = \"${label}\" in the root BUILD file)"$'\n'
        ;;
      *)
        bad="${bad}${token} (neither a root label nor a //scripts CLI)"$'\n'
        ;;
    esac
  done
  if [ -n "${bad}" ]; then
    printf 'FAIL: %s cites a target that does not resolve:\n%s' "${PAYLOAD}" "${bad}" >&2
    return 1
  fi

  # A script target has to travel in the runnable form, not as any mention.
  assert_contains_file "it shows the generic script-target form" "${PAYLOAD}" \
    'bazelisk run //scripts:<stem>'
}

@test "ez-learn docs: every doc the payload points at is still in the checkout" {
  # The closing bullets are the reader's map to the docs tree; a name that
  # leads nowhere costs them the answer they came for. The payload spells the
  # docs files bare under its docs/ bullet, so a citation resolves at the repo
  # root or under docs/, and only these two places.
  # README.md and the docs pages travel with this suite through //:entry_docs and
  # //docs:content, so a root that resolved above always carries them; a missing
  # one is the citation breaking, not the runfiles being thin.
  [[ -f "${REPO_ROOT}/README.md" ]] || {
    printf 'FAIL: README.md is not reachable from %s - the runfiles lost //:entry_docs\n' \
      "${REPO_ROOT}" >&2
    return 1; }

  local cited want missing name path unresolved
  # Two segments at most, so the SKILL.md and notes.md paths the payload prints
  # are not mistaken for doc citations.
  cited="$(grep -oE '[A-Za-z0-9._/-]+\.md' "${PAYLOAD}" |
    grep -E '^([A-Za-z0-9._-]+|docs/[A-Za-z0-9._-]+)\.md$' |
    sed 's|^docs/||' | sort -u)"

  want="$(printf '%s\n' README.md grok-build-and-agents.md project-conventions.md branching.md | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "${want}") <(printf '%s\n' "${cited}"))"
  if [ -n "${missing}" ]; then
    printf 'FAIL: %s no longer points at: %s\n' "${PAYLOAD}" "$(printf '%s ' "${missing}")" >&2
    return 1
  fi
  assert_contains_file "it names the docs tree" "${PAYLOAD}" 'docs/'

  unresolved=""
  for name in ${cited}; do
    path="${REPO_ROOT}/${name}"
    [[ -f "${path}" ]] || path="${REPO_ROOT}/docs/${name}"
    [[ -f "${path}" ]] || unresolved="${unresolved}${name}"$'\n'
  done
  if [ -n "${unresolved}" ]; then
    printf 'FAIL: %s cites a doc that is in neither the root nor docs/:\n%s' \
      "${PAYLOAD}" "${unresolved}" >&2
    return 1
  fi
}

@test "ez-learn aliases: every alias the payload lists is one the transport serves" {
  # The payload is the reader's shortcut for what LiteLLM answers: a name it
  # prints that model_config never defines sends them at an alias that cannot
  # resolve. The comparison is one-way on purpose - the payload tells the
  # reader to read the live list from the config rather than trust its count,
  # so the config may grow and the payload may not.
  local cfg="${REPO_ROOT}/litellm/config.yaml"
  [[ -f "${cfg}" ]] || skip "litellm/config.yaml is not in this suite's runfiles"

  local listed core served absent extra
  listed="$(tr '\n' ' ' <"${PAYLOAD}" |
    grep -oE 'aliases \([^)]*\)|more \([^)]*\)' |
    grep -oE '`[A-Za-z][A-Za-z0-9._-]*`' | tr -d '`' | sort -u)"
  if [ -z "${listed}" ]; then
    printf 'FAIL: %s no longer lists its aliases in parenthesized form\n' "${PAYLOAD}" >&2
    return 1
  fi

  core="$(printf '%s\n' agent agent-low agent-medium agent-xhigh coder coder-fast chat | sort -u)"
  assert_eq "the payload lists exactly the seven core aliases" "${core}" \
    "$(printf '%s\n' "${listed}" | grep -vE '^spark-(coder|chat)$' || true)"

  absent="$(comm -23 <(printf '%s\n' spark-coder spark-chat | sort -u) <(printf '%s\n' "${listed}"))"
  if [ -n "${absent}" ]; then
    printf 'FAIL: %s lost the optional Spark aliases: %s\n' "${PAYLOAD}" "${absent}" >&2
    return 1
  fi

  # Comment lines carry a bare `model_name:` with no value, so drop the empties
  # rather than comparing them against a name.
  served="$(grep -o 'model_name: *[A-Za-z0-9._-]*' "${cfg}" |
    sed 's/^model_name: *//' | grep -v '^[[:space:]]*$' | sort -u)"
  extra="$(comm -23 <(printf '%s\n' "${listed}") <(printf '%s\n' "${served}"))"
  if [ -n "${extra}" ]; then
    printf 'FAIL: %s names aliases litellm/config.yaml does not define: %s\n' \
      "${PAYLOAD}" "$(printf '%s ' "${extra}")" >&2
    return 1
  fi

  # The count in the prose is part of the claim it makes about the list.
  assert_match "the prose count matches the core list" '[Ss]even aliases \(' \
    "$(tr '\n' ' ' <"${PAYLOAD}")"
  assert_contains_file "it sends the reader to the live list" "${PAYLOAD}" \
    'litellm/config\.yaml'
}

@test "ez-learn notes: the scratch path is the one notes-setup.sh builds" {
  # notes-setup.sh builds the per-repo scratch path and points
  # core.excludesFile at that tree, so the payload has to spell the same shape
  # or it teaches a reader to keep notes somewhere nothing else finds, and the
  # per-repo key is what keeps two clones from sharing one file. The digest of
  # a mining pass lands there, so a wrong path loses it too.
  local builder="${REPO_ROOT}/templates/common/notes-setup.sh"
  [[ -f "${builder}" ]] || skip "notes-setup.sh is not reachable under ${builder}"

  local want built
  want="$(grep -oE '~/\.grok/notes/<[A-Za-z-]+>/notes\.md' "${PAYLOAD}" | head -n 1)"
  if [ -z "${want}" ]; then
    printf 'FAIL: %s lost the ~/.grok/notes/<key>/notes.md shape\n' "${PAYLOAD}" >&2
    return 1
  fi
  built="$(grep -oE '\$\{home\}/\.grok/notes/\$\{[A-Za-z_]+\}/notes\.md' "${builder}" | head -n 1)"
  if [ -z "${built}" ]; then
    printf 'FAIL: %s no longer prints a per-key notes path\n' "${builder}" >&2
    return 1
  fi

  # Same shape from both ends: the tilde stands for ${home}, one segment for
  # the key, and notes.md closes it.
  want="$(printf '%s' "${want}" | sed -E 's|^~|HOME|; s|<[^>]*>|KEY|')"
  built="$(printf '%s' "${built}" | sed -E 's|^\$\{home\}|HOME|; s|\$\{[A-Za-z_]+\}|KEY|')"
  assert_eq "the payload's notes path is the path the seeder builds" "${built}" "${want}"

  # The flat form is the pre-per-repo layout: every clone in the stack would
  # share one scratch file.
  run grep -F -- '~/.grok/notes/notes.md' "${PAYLOAD}"
  [ "${status}" -ne 0 ]
}

@test "ez-learn skills: the two homes that reach both consumers are the pair it names" {
  # Measured with grok inspect --json: this CLI does discover skills under
  # ~/.grok/skills/ (source type user) and <repo_root>/.grok/skills/ (source
  # type project), so those paths are real. What they do not reach is the Coder
  # Agents chat agent, which reads ~/.coder/skills/ only - so the pair that
  # lands a skill in front of both consumers is ~/.agents/skills plus
  # ~/.coder/skills, and that is the pair the payload has to send a user skill
  # to. A .grok/skills path may be mentioned as the CLI-side extra, but never
  # as a home on its own: each mention has to say in its own line that the chat
  # agent does not read it, or a reader files a skill nothing in the chat will
  # ever invoke.
  assert_contains_file "the CLI-side skills path" "${PAYLOAD}" \
    '~/\.agents/skills/<[A-Za-z0-9_-]+>/SKILL\.md'
  assert_contains_file "the chat-side skills twin" "${PAYLOAD}" \
    '~/\.coder/skills/<[A-Za-z0-9_-]+>/SKILL\.md'
  assert_contains_file "it says the chat agent reads the coder home only" "${PAYLOAD}" \
    'chat agent reads `~/\.coder/skills/[^`]*` only'
  assert_contains_file "and sends a user skill to both homes" "${PAYLOAD}" \
    'goes into BOTH `~/\.agents/skills/[^`]*/SKILL\.md` and'

  local mention bad=""
  while IFS= read -r mention; do
    printf '%s\n' "${mention}" | grep -Eq 'chat' || bad="${bad}${mention}"$'\n'
    printf '%s\n' "${mention}" | grep -Eqi 'never|does not read|not read|only' ||
      bad="${bad}${mention}"$'\n'
  done < <(grep -F -- '.grok/skills' "${PAYLOAD}")
  if [ -n "${bad}" ]; then
    printf 'FAIL: %s names a .grok/skills path without the caveat that the chat agent does not read it:\n%s' \
      "${PAYLOAD}" "${bad}" >&2
    return 1
  fi
}

@test "ez-learn gates: the cached-pass guidance keeps the two strings it depends on" {
  # The advice is only worth following while Bazel prints that summary for a
  # cached pass and that flag is what forces a fresh one: drop either and Step 8
  # has the reader trust a line the runner no longer prints, or open a PR
  # without the one uncached pass the gate needs.
  assert_contains_file "the cached summary line is quoted" "${PAYLOAD}" \
    'Executed 0 out of N'
  assert_contains_file "the uncached flag is named" "${PAYLOAD}" \
    '--nocache_test_results'
  # And named as something to run, attached to a test invocation, so the flag
  # cannot survive as a word on its own.
  assert_contains_file "the flag rides a bazelisk test command" "${PAYLOAD}" \
    'bazelisk test [^`]*--nocache_test_results'
}

@test "ez-learn deeper: the session sweep keeps its guardrails" {
  # The mining pass is the one place this command reads ~/.grok/sessions, and
  # those dirs hold multi-megabyte transcripts beside their small summaries: an
  # agent that forgets the guardrails either quotes a whole session into the
  # reply or proposes an edit from a single anecdote. Indexing summaries first is
  # what keeps the sweep bounded, and the full-transcript deep pass stays gated
  # behind an explicit request.
  assert_contains_file "the deep pass is opt-in" "${PAYLOAD}" \
    'only when the user asks'
  assert_contains_file "it names the session store" "${PAYLOAD}" \
    '~/.grok/sessions/'
  assert_contains_file "it redirects the bulk instead of printing it" "${PAYLOAD}" \
    '/tmp'
  assert_contains_file "it sends the fix to the seed, not the materialized copy" "${PAYLOAD}" \
    'templates/common/'
}
