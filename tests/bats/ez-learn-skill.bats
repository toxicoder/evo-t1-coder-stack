#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ez-learn-skill.bats - guardrails for the stack-shipped /ez-learn command.
#
# Upstream ships its memory family - /flush, /dream, /remember, /memory - as
# BUILT-IN Grok Build commands: three entries in the shell's built-in command
# table plus one pager command. Three of them sit behind the cross-session
# memory gate, which is off by default and needs a configured memory store, so
# on this stack the names stay hidden. The stack therefore ships its own
# templates/common/ez-learn.SKILL.md and seeds it on the same contract as
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
# describes, so an edit that makes the command lie fails the gate rather than
# sending an operator to a doc, a label or a path that is not there: what the
# memory contract promises (the four upstream commands it reproduces and why the
# bundle is missing, report-only by default, the fail-closed memory gate, both
# storage layouts, the flush and dream instructions with their headings, caps and
# thresholds kept, the upstream report lines quoted, one destructive member that
# confirms first, the deep session pass kept opt-in, the seed as the only write
# target, grok inspect as the proof) is what the payload actually says, every
# bazel label it cites resolves, and every doc path it points at exists. Skill
# authoring is not pinned here: the sibling skills carry it, in
# tests/bats/ez-skill-authoring.bats.
#
# Usage: bazelisk test //tests:bats_ez_learn_skill_test   (from any cwd)
# Safety: reads the stack-skills seed body, the two startup.sh.tftpl twins, the
# two main.tf twins, templates/common/ez-learn.SKILL.md,
# scripts/lib/config_seed.sh, scripts/lib/probes/seed-rm-managed.sh, the root
# BUILD file, the scripts/ tree and the repo docs; the retire tests write only
# into a per-test scratch home under BATS_TEST_TMPDIR.

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

# payload_section <heading fragment> - the body of one "## " section, its heading
# line left out. The prompt-transcription tests read their claims off the section
# they belong to, so a heading, a cap or a report line cannot survive as
# decoration somewhere else in the file.
payload_section() {
  awk -v want="$1" '$0 ~ "^## .*" want {f=1; next} /^## /{f=0} f' "${PAYLOAD}"
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
    # And the loop that retires the pre-rename /learn copy, which the trio never
    # replaces.
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

@test "ez-learn memory: it names the four upstream commands it reproduces" {
  # Upstream ships /flush, /dream, /remember and /memory as built-ins: three
  # entries in the shell's built-in command table behind the cross-session memory
  # gate, plus one pager command. Three of the four surface only when that gate is
  # open, so the payload has to say what it stands in for and how upstream ships
  # it, or a reader cannot tell a reproduction from an unrelated tool.
  local cmd desc
  for cmd in flush dream remember memory; do
    assert_contains_file "it names the upstream /${cmd} command" "${PAYLOAD}" \
      "\`/${cmd}\`"
  done

  # The frontmatter is what the model reads when it chooses the command, so the
  # four names belong there too, not only in the body.
  desc="$(grep -m1 '^description:' "${PAYLOAD}")"
  for cmd in flush dream remember memory; do
    assert_match "the model-facing description names /${cmd}" "/${cmd}" "${desc}"
  done
  assert_contains_file "it says this is the stack's own copy" "${PAYLOAD}" \
    "This is this stack's copy of the upstream Grok Build memory commands"

  # How upstream ships them, in its own words: built-ins over files on disk, the
  # command table, the pager, the gate, and why the ez- prefix stays clear.
  assert_contains_file "it says upstream ships them as built-ins" "${PAYLOAD}" \
    'those as built-ins, not as files on disk'
  assert_contains_file "it names the built-in command table" "${PAYLOAD}" \
    "entries in the shell's built-in command table"
  assert_contains_file "it says /remember is a pager command" "${PAYLOAD}" \
    'is a pager command'
  assert_contains_file "and that this file is what the stack seeds" "${PAYLOAD}" \
    'the stack seeds this file instead'
  assert_contains_file "and why the ez- prefix stays clear of the built-ins" "${PAYLOAD}" \
    'clear of the built-in names'
}

@test "ez-learn memory: skill authoring is handed to the two writing siblings" {
  # The trio divides the work: this command writes memory files, /ez-skillify
  # captures the procedure from a session that just worked, /ez-create-skill
  # scaffolds one from a description. Drop the hand-off and a reader who decides
  # a fact should have been a skill has no sanctioned route and edits a SKILL.md
  # by hand. How those two write is pinned in ez-skill-authoring.bats.
  assert_contains_file "it says this command is not authoring" "${PAYLOAD}" \
    'It is not skill authoring'
  assert_contains_file "it names the session-capture sibling" "${PAYLOAD}" '/ez-skillify'
  assert_contains_file "it names the scaffolding sibling" "${PAYLOAD}" '/ez-create-skill'
  assert_contains_file "it gives the writing to those two" "${PAYLOAD}" \
    'Those two write skill files'
  assert_contains_file "and keeps the memory writes as its own" "${PAYLOAD}" \
    'this one writes memory files'

  # The two siblings stand in for commands that ride in the runtime skills bundle,
  # and that is the half the stack genuinely cannot sync: the download wants an
  # x.ai sign-in, LiteLLM is the only transport here, so the bundle dir never
  # appears and the stack seeds those two files by hand instead.
  assert_contains_file "it names the bundled skill dir" "${PAYLOAD}" '~/\.grok/bundled/'
  assert_contains_file "it names the sign-in the bundle needs" "${PAYLOAD}" \
    'x\.ai sign-in'
  assert_contains_file "and the transport that replaces x.ai" "${PAYLOAD}" \
    'LiteLLM is the sole model transport'
  assert_contains_file "it says the bundled dir is never created" "${PAYLOAD}" \
    'is never created'
  assert_contains_file "and that those two are stack-seeded too" "${PAYLOAD}" \
    'the stack seeds those two files instead'
}

@test "ez-learn memory: report-only is the default and nothing is written until asked" {
  # The default is the safety property: this command overwrites memory files and
  # deletes session logs, so a bare /ez-learn has to print what it would do and
  # stop. Naming the target on the apply side is the counterpart - a write whose
  # path the reader never sees cannot be reviewed before it lands.
  local section
  section="$(payload_section 'Default:')"
  [ -n "${section}" ] || {
    printf 'FAIL: %s lost its report-only default section\n' "${PAYLOAD}" >&2
    return 1
  }

  assert_contains_file "the section is named for the report-only default" "${PAYLOAD}" \
    '^## Default: report-only, then apply on request'
  assert_match "no argument writes nothing" 'with no argument reports and writes nothing' \
    "${section}"
  assert_match "it prints what it resolved" \
    'prints the resolved root, the workspace directory name' \
    "$(tr '\n' ' ' <"${PAYLOAD}")"
  assert_match "it prints the logs it would fold" \
    'the session-log files it would fold' "${section}"
  assert_match "it prints the markdown it proposes" 'proposes to write' "${section}"
  assert_match "nothing reaches disk until asked" \
    'Nothing touches disk until you ask for the' "${section}"
  assert_match "and a write names the path it touched" 'a write names the path it touched' \
    "${section}"
  assert_match "--force is the only overwrite" 'Pass `--force` only to' "${section}"
}

@test "ez-learn gate: memory is off by default and every gate is named" {
  # Every member here is fail-closed on a switch an operator has to flip, so a
  # payload that drops the gate teaches a reader to write memory files that
  # nothing will ever read back. The precedence chain, both tables, the flag and
  # the line the user sees are all part of that contract.
  local section
  section="$(payload_section 'Step 0')"
  [ -n "${section}" ] || {
    printf 'FAIL: %s lost its Step 0 gate section\n' "${PAYLOAD}" >&2
    return 1
  }

  assert_match "memory is off by default" 'Memory is \*\*off by default\*\*' "${section}"
  assert_match "and each gate is fail-closed" 'fail-closed' "${section}"
  assert_match "the env knob is named" 'GROK_MEMORY' "${section}"
  assert_match "the CLI kill switch is named" '`--no-memory`' "${section}"
  assert_match "the legacy table is named" '\[memory\] enabled' "${section}"
  assert_match "the v2 table is named" '\[memory_v2\] enabled' "${section}"
  assert_match "the last resort is spelled false" 'default `false`' "${section}"
  assert_match "the user-visible line is quoted" \
    'Memory is turned off for this session\.' "${section}"
  assert_match "and /remember is the least gated member" 'least gated' "${section}"
}

@test "ez-learn paths: both layouts, the workspace dir, and the log dirs are spelled out" {
  # Writing next to the CLI's own writes is the whole trick: a note filed under a
  # guessed root, a guessed workspace dir name, or a nested topics/ path is
  # invisible to the index and to the dream pass, so it is memory that never
  # comes back. Both layouts and the digest rule are pinned, never paraphrased.
  assert_contains_file "the legacy root is named" "${PAYLOAD}" '~/\.grok/memory/'
  assert_contains_file "the v2 root is named" "${PAYLOAD}" '~/\.grok/memory-v2/'
  assert_contains_file "the workspace dir is slug plus hash8" "${PAYLOAD}" '<slug>-<hash8>'
  assert_contains_file "hash8 is a digest, never invented" "${PAYLOAD}" \
    'first 8 hex chars of a blake3 digest'
  assert_contains_file "the session log path is spelled out" "${PAYLOAD}" \
    'sessions/YYYY-MM-DD-<slug>-<sid8>\.md'
  assert_contains_file "the v2 topics dir is named" "${PAYLOAD}" '`topics/`'
  assert_contains_file "the v2 observation inbox is named" "${PAYLOAD}" \
    '`observations/_inbox/`'
  assert_contains_file "and only one level deep counts" "${PAYLOAD}" \
    'Only immediate children of'
}

@test "ez-learn flush: the extraction instruction keeps its four sections and its caps" {
  # Step 2 transcribes the upstream FLUSH_SYSTEM_PROMPT. The four section
  # headings are what the acceptance rules and the dream pass read, NO_REPLY is
  # how a worthless flush is refused, and the cap and the dedup threshold are the
  # two numbers upstream answers with; reworded, the payload is a different
  # prompt writing files nothing downstream parses the same way.
  local section heading
  section="$(payload_section 'Step 2')"
  [ -n "${section}" ] || {
    printf 'FAIL: %s lost its Step 2 flush section\n' "${PAYLOAD}" >&2
    return 1
  }

  assert_match "it is named as the upstream prompt" 'FLUSH_SYSTEM_PROMPT' "${section}"
  for heading in 'Decisions & rationale' 'Technical context' 'Debugging techniques' \
    'Problems & solutions'; do
    assert_match "the prompt keeps the ${heading} heading" "\*\*${heading}" "${section}"
  done
  assert_match "a worthless flush answers NO_REPLY" 'Respond with NO_REPLY' "${section}"
  assert_match "and noreply is matched loosely" 'reduces to `noreply`' "${section}"
  assert_match "the body is capped at 8000 chars" 'Cap the body at 8000 characters' \
    "${section}"
  assert_match "and the cap is named after the setting" 'max_flush_write_chars' "${section}"
  assert_match "a near-verbatim repeat is dropped at 0.92" 'cosine similarity 0\.92' \
    "${section}"
  assert_match "a body without headers is rejected" 'flush response lacks markdown' \
    "${section}"
}

@test "ez-learn flush: a repeat flush appends behind the delimiter dream splits on" {
  # The delimiter is the contract between two members: dream splits entries on
  # it, so an append that drops or rewords it fuses two flushes into one entry,
  # and the next dream pass merges them with no way back.
  assert_contains_file "the append delimiter is quoted exactly" "${PAYLOAD}" \
    '<!-- flush HH:MM:SS UTC -->'
  assert_contains_file "and dream is told it splits entries on it" "${PAYLOAD}" \
    'dream pass later splits entries on'
  assert_contains_file "the rule that separates flushes is named" "${PAYLOAD}" \
    'A repeat flush appends'
}

@test "ez-learn dream: the seven verbs, the caps, and the recency guard survive" {
  # Dream is the step that actually learns, and Step 3 transcribes the upstream
  # DREAM_SYSTEM_PROMPT. The seven verbs are what keeps the pass from quietly
  # becoming a copy: drop Resolve or Discard and it starts keeping contradictions
  # and session noise. The caps bound what the model sees and writes, the 300
  # second guard is what stops it eating a log another session is still
  # appending to, and the scaffold marker is how it refuses a stub file.
  local section verb n=1
  section="$(payload_section 'Step 3')"
  [ -n "${section}" ] || {
    printf 'FAIL: %s lost its Step 3 dream section\n' "${PAYLOAD}" >&2
    return 1
  }

  assert_match "it is named as the upstream prompt" 'DREAM_SYSTEM_PROMPT' "${section}"
  for verb in Merge Resolve Convert Discard Preserve Generalize Ground; do
    assert_match "verb ${n} is ${verb}" "${n}\. \*\*${verb}" "${section}"
    n=$((n + 1))
  done
  assert_match "the input stops at 32000 chars" 'reaches 32000 chars' "${section}"
  assert_match "the finished document is capped" 'Cap the finished document' "${section}"
  assert_match "and that cap is 16000 chars" 'at 16000 chars' "${section}"
  assert_match "a log touched in the last 300 seconds stays" 'last 300 seconds' "${section}"
  assert_match "a scaffold file is skipped by its marker" \
    'Auto-populated by dream consolidation' "${section}"
  assert_match "a held lock is a skip, not a queue" 'lock held by another process' \
    "${section}"
  assert_match "the generated index is never hand-edited" \
    'Do not edit this file directly' "${section}"
}

@test "ez-learn report: the summary lines are quoted in the upstream wording" {
  # A user who knows the real commands reads these lines as the result, and a
  # paraphrase is what makes the two tools stop looking like one family. The four
  # that carry an outcome (how far the flush got, what the dream folded, an empty
  # store, a concurrent run) are quoted exactly.
  assert_contains_file "flush names the turn it reached" "${PAYLOAD}" \
    'Memory flushed through turn'
  assert_contains_file "dream reports what it folded in" "${PAYLOAD}" \
    'Dream merged N observations into M topics\.'
  assert_contains_file "and the merge line is singularized" "${PAYLOAD}" \
    '[Ss]ingularize the merge line'
  assert_contains_file "an empty dream says so" "${PAYLOAD}" 'Nothing to consolidate\.'
  assert_contains_file "a concurrent dream says so too" "${PAYLOAD}" \
    'Dream is already running'
  assert_contains_file "and a skipped run carries its reason" "${PAYLOAD}" \
    'skipped: <reason>'
}

@test "ez-learn clear: the one destructive member confirms before it deletes" {
  # Everything else writes a file; clear removes a tree, and it defaults to the
  # workspace scope. The confirmation block is the only thing between a
  # mistyped subcommand and lost memory, so its prompts are pinned as printed
  # rather than described.
  assert_contains_file "clear is named the only destructive member" "${PAYLOAD}" \
    'is the only destructive'
  assert_contains_file "and it defaults to the workspace scope" "${PAYLOAD}" \
    'defaults to the \*\*workspace\*\* scope'
  assert_contains_file "the three scope flags cannot combine" "${PAYLOAD}" \
    'mutually exclusive'
  assert_contains_file "the confirmation names what is about to go" "${PAYLOAD}" \
    'The following will be deleted:'
  assert_contains_file "and asks the yes/no question" "${PAYLOAD}" \
    'Are you sure\? \[y/N\]'
  assert_contains_file "anything but yes cancels" "${PAYLOAD}" 'prints `Cancelled\.`'
  assert_contains_file "an empty store is its own outcome" "${PAYLOAD}" 'Nothing to clear'
  assert_contains_file "and an empty browser says so honestly" "${PAYLOAD}" \
    'No memory files have been recorded yet\.'
}

@test "ez-learn deeper: the session sweep keeps its guardrails" {
  # Reaching into ~/.grok/sessions is the one place this command reads raw
  # transcripts, and those dirs hold multi-megabyte jsonl beside their small
  # summaries: an agent that forgets the guardrails either quotes a whole session
  # into the reply or mines a "fact" out of one anecdote. So the deep pass stays
  # behind an explicit request, counts before it reads, and keeps the bulk on
  # disk.
  assert_contains_file "the deep pass is opt-in" "${PAYLOAD}" 'only when the user asks'
  assert_contains_file "and never runs as a default" "${PAYLOAD}" 'never as a default'
  assert_contains_file "it names the session store" "${PAYLOAD}" '~/\.grok/sessions/'
  assert_contains_file "it counts before it reads" "${PAYLOAD}" \
    'count and select with `jq`'
  assert_contains_file "it redirects the bulk instead of printing it" "${PAYLOAD}" \
    'scratch file under `/tmp`'
  assert_contains_file "and keeps a transcript out of the reply" "${PAYLOAD}" \
    'never paste a transcript into the reply'
}

@test "ez-learn writes: a correction goes to the seed, never the copy in a home" {
  # The copies under a home are rewritten by the boot and re-seeded by
  # refresh-configs, so an edit written straight into ~/.coder/skills or
  # ~/.agents/skills is undone at the next start and the reader loses the fix
  # they just made. The payload has to send the correction to the seed.
  assert_contains_file "the seed is templates/common/" "${PAYLOAD}" 'templates/common/'
  assert_contains_file "and names the CLI that re-materializes it" "${PAYLOAD}" \
    'refresh-configs'
  run grep -Ei -- 'never edit the copy in a home' "${PAYLOAD}"
  [ "${status}" -eq 0 ]
  assert_contains_file "because only the seed survives a boot" "${PAYLOAD}" \
    'only the seed survives'
  assert_contains_file "and names the suite that has to move with the claim" "${PAYLOAD}" \
    'ez-learn-skill\.bats'
}

@test "ez-learn verify: grok inspect proves the wiring and /local: settles a collision" {
  # grok inspect is the only reader-side truth here: the payload claims a slash
  # command exists and this stack seeds it as a plain file, so it has to say how
  # to prove the command registered, which field shows it, and what to do when a
  # bundled or plugin command of the same name shadows it.
  assert_contains_file "it runs grok inspect" "${PAYLOAD}" 'grok inspect'
  assert_contains_file "and the json form that prints the source" "${PAYLOAD}" \
    'grok inspect --json'
  assert_contains_file "it reads the invocable flag" "${PAYLOAD}" 'userInvocable'
  assert_contains_file "and the source is the file it edited" "${PAYLOAD}" \
    'the `source` path'
  assert_contains_file "and the qualified form disambiguates a collision" "${PAYLOAD}" \
    '/local:ez-learn'
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

@test "ez-learn retire: both startup twins retire the pre-rename /learn copy" {
  # The seed moved off the /learn name, and the absent-only contract never
  # deletes, so the boot has to retire the copy the stack left there. Left in
  # place it keeps offering that old name for the life of the volume.
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
  # The memory command prints grok, git and grep invocations, so today the
  # payload cites no Bazel target at all. This is the guard for the day someone
  # adds one: a label the tree stopped declaring is a dead end in the first
  # minute of orienting, and nothing else in the gate notices a citation going
  # stale. The root BUILD file carries the //:labels and scripts/<stem>.sh
  # carries the CLI targets, which are the two places a target can come from.
  [[ -f "${REPO_ROOT}/BUILD.bazel" ]] ||
    skip "the root BUILD file is not in this suite's runfiles (//:bazel_files)"

  local tokens resolvable token stem label bad
  # The guard rejects a // preceded by a colon or a word char, so a URL endpoint
  # is not mistaken for a label, and the label class carries <> so the payload's
  # generic spelling survives capture.
  tokens="$(grep -oE '(^|[^:/A-Za-z])//([A-Za-z0-9_.-]*):([A-Za-z0-9_.<>-]+)' "${PAYLOAD}" |
    grep -oE '//[A-Za-z0-9_.-]*:[A-Za-z0-9_.<>-]+' | sort -u)"

  # //scripts:<stem> is the generic spelling for a CLI target, so it is pinned as
  # a citation, not resolved as a label. The token class above carries no shell
  # metacharacter, so the loop can word-split the list.
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
}

@test "ez-learn docs: every doc the payload points at is still in the checkout" {
  # The closing paragraph is the reader's map: the seed, this suite, the README
  # and the two docs pages the CLI and the shell style live on. A name that leads
  # nowhere costs them the answer they came for. Two families are deliberately not
  # resolved here: the upstream Rust paths it cites as the source of its claims
  # (crates/codegen/... is Grok Build's own tree, so they are pinned as named and
  # never as files), and MEMORY.md, which is the memory store's generated index
  # rather than a document anyone reads off a path.
  # README.md and the docs pages travel with this suite through //:entry_docs and
  # //docs:content, so a root that resolved above always carries them; a missing
  # one is the citation breaking, not the runfiles being thin.
  [[ -f "${REPO_ROOT}/README.md" ]] || {
    printf 'FAIL: README.md is not reachable from %s - the runfiles lost //:entry_docs\n' \
      "${REPO_ROOT}" >&2
    return 1; }

  local cited want missing name path unresolved
  # A citation is a path made of repo segments, or a bare file at the root; a
  # path that starts with / or a ~ is one the payload prints as its own target,
  # not one it sends the reader to.
  cited="$(grep -oE '[A-Za-z0-9._/-]+\.(md|bats)' "${PAYLOAD}" |
    grep -E '^([A-Za-z0-9._-]+|(docs|templates|tests|scripts)/[A-Za-z0-9._/-]+)\.(md|bats)$' |
    grep -vx 'MEMORY\.md' | sort -u)"
  if [ -z "${cited}" ]; then
    printf 'FAIL: %s cites no document at all\n' "${PAYLOAD}" >&2
    return 1
  fi

  # What the map has to keep carrying. The suite file is named by the paragraph
  # that tells the reader where a drifting claim gets pinned; it is resolved
  # below like any other citation, so it is not spelled out here.
  want="$(printf '%s\n' README.md docs/grok-build-and-agents.md \
    docs/project-conventions.md templates/common/ez-learn.SKILL.md | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "${want}") <(printf '%s\n' "${cited}"))"
  if [ -n "${missing}" ]; then
    printf 'FAIL: %s no longer points at: %s\n' "${PAYLOAD}" "$(printf '%s ' "${missing}")" >&2
    return 1
  fi
  assert_contains_file "it names the suite that pins it" "${PAYLOAD}" 'ez-learn-skill\.bats'

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

  # The provenance claim: every number and report line above comes from these two
  # upstream paths, so they stay named even though this checkout cannot answer them.
  assert_contains_file "it names the upstream memory crate" "${PAYLOAD}" \
    'crates/codegen/xai-grok-memory/'
  assert_contains_file "and the upstream session module" "${PAYLOAD}" \
    'crates/codegen/xai-grok-shell/src/session/'
}
