#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ez-skill-authoring.bats - the shared seam of the stack's skill-authoring trio.
#
# The stack ships three user-invocable Skills: /ez-learn (mine many sessions and
# propose), /ez-skillify (capture the session that just worked) and
# /ez-create-skill (guided builder from a description). Each seeds into
# ~/.coder/skills/<name>/SKILL.md, the only path the Coder Agents chat agent
# reads, and into its ~/.agents/skills/<name>/SKILL.md twin, which is the Grok
# Build CLI's - absent-only, from one templates/common/stack-skills.sh.tftpl
# rendered by the coder_script "stack_skills" block in both main.tf twins.
#
# The move out of startup.sh.tftpl is the reason this suite exists. main.tf
# inlines every payload into coder_agent.startup_script and the agent execs that
# body as one execve argument gated at 122880 bytes; each coder_script.script
# gets its own ceiling, which is what bought the headroom three payloads needed
# (docs/coder-templates.md#the-one-argument-ceiling). So the invariants worth a
# gate are the ones that make that escape hatch honest: the body is MEASURED
# (scripts/lib/startup_size.awk must emit a record for it and for each payload
# it inlines), the feeds are chomped and sit INSIDE the block (both byte readers
# credit a body only by the path.module names within it), the ~/.agents side is
# a cp of the managed ~/.coder copy rather than a second heredoc, and the trio's
# shared payload invariants hold for the two new files as well as for ez-learn.
#
# ez-learn's own content claims are pinned by tests/bats/ez-learn-skill.bats;
# this suite applies only the SHARED invariants across all three files and owns
# the claims that belong to ez-skillify and ez-create-skill alone.
#
# Usage: bazelisk test //tests:bats_ez_skill_authoring_test   (from any cwd)
# Safety: reads templates/common/{ez-learn,ez-skillify,ez-create-skill}.SKILL.md,
# templates/common/stack-skills.sh.tftpl, both main.tf twins, both
# startup.sh.tftpl twins, scripts/lib/config_seed.sh, scripts/lib/startup_size.awk,
# the root BUILD file, README.md/AGENTS.md and the docs tree. Writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SEED=""

# The trio, and the heredoc tag plus the main.tf map key each travels under.
SKILLS=(ez-learn ez-skillify ez-create-skill)
TAGS=(EZ_LEARN_SKILL_MD_EOF EZ_SKILLIFY_SKILL_MD_EOF EZ_CREATE_SKILL_SKILL_MD_EOF)
KEYS=(ez_learn_skill ez_skillify_skill ez_create_skill_skill)

# The frontmatter keys Grok Build documents: the whole set a payload may carry.
DOC_KEYS=(name description when-to-use allowed-tools argument-hint user-invocable
  disable-model-invocation model effort license compatibility metadata)

# The frontmatter parser, held here so the test body reads as the claim and not
# as the YAML plumbing. Reads the payload on stdin, its registered name in
# argv[1]; exits non-zero with the reason on anything the CLI would reject.
FRONTMATTER_PROG='
import sys, yaml
name = sys.argv[1]
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
    sys.exit("FAIL: %s carries keys outside the documented set: %s"
             % (name, ", ".join(unknown)))
if data.get("name") != name:
    sys.exit("FAIL: %s: name must equal the file'"'"'s own stem, got %r"
             % (name, data.get("name")))
desc = data.get("description")
if not isinstance(desc, str) or not desc.strip():
    sys.exit("FAIL: %s: description must be a non-empty string, got %r" % (name, desc))
if "user-invocable" in data and data["user-invocable"] is not True:
    sys.exit("FAIL: %s: user-invocable must be absent or the boolean true, got %r"
             % (name, data["user-invocable"]))
'

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SEED="${REPO_ROOT}/templates/common/stack-skills.sh.tftpl"
  local f
  for f in "${SKILLS[@]}"; do
    [[ -f "${REPO_ROOT}/templates/common/${f}.SKILL.md" ]] ||
      skip "the ${f} payload is not reachable from ${REPO_ROOT}"
  done
  [[ -f "${SEED}" &&
    -f "${REPO_ROOT}/templates/workspace/main.tf" &&
    -f "${REPO_ROOT}/templates/devcontainer/main.tf" &&
    -f "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" &&
    -f "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl" ]] ||
    skip "the skill seed body or a template twin is not reachable from ${REPO_ROOT}"
}

# payload_path <skill> — the staged payload for one skill of the trio.
payload_path() {
  printf '%s' "${REPO_ROOT}/templates/common/${1}.SKILL.md"
}

# payload_prose <path> — the payload with its newlines folded to single spaces,
# so a claim pinned here survives the prose rewrapping that markdown invites.
payload_prose() {
  tr '\n' ' ' <"${1}" | tr -s ' '
}

# hdoc_open — print the two characters that open a here-document. Built from two
# halves on purpose: bats' preprocessor reads that digraph inside a needle as the
# opener of a real here-document and swallows every line below it, so this suite
# pins the seed's quoted delimiters without ever spelling them out.
hdoc_open() {
  printf '%s%s' '<' '<'
}

# main_block <main.tf> <resource type> <resource name> — print one resource block,
# from its header to the brace that closes it at column zero.
main_block() {
  awk -v type="${2}" -v name="${3}" '
    $0 ~ "^resource \"" type "\" \"" name "\" \\{" { on = 1 }
    on { print }
    on && /^\}/ { exit }
  ' "${1}"
}

# ---------------------------------------------------------------------------
# The shared delivery seam.
# ---------------------------------------------------------------------------

@test "stack-skills seed: the body seeds all three skills into the coder home only while absent" {
  # Absent-only is the takeover contract: a file that exists belongs to the
  # user, so a boot must never write over one. Lose a guard and the next boot
  # silently rewrites whatever the operator wrote into ~/.coder/skills.
  # templates/common/ exists once and both twins consume it, so the body is
  # read once here while everything main.tf does with it is checked per twin.
  local i name
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    assert_contains_file "${name} coder guard" "${SEED}" \
      '^if \[ ! -f "\$HOME/\.coder/skills/'"${name}"'/SKILL\.md" \]; then$'
    assert_contains_file "${name} coder mkdir" "${SEED}" \
      'mkdir -p "\$HOME/\.coder/skills/'"${name}"'" 2>/dev/null'
    assert_contains_file "${name} coder cat" "${SEED}" \
      'cat >"\$HOME/\.coder/skills/'"${name}"'/SKILL\.md" '"$(hdoc_open)"
  done
}

@test "stack-skills seed: every payload arrives through a quoted heredoc whose tag closes alone" {
  # Two separate failures hide in these lines. An UNQUOTED delimiter lets the
  # shell expand the $-text every skill body is made of while the boot runs, so
  # the seeded file is not the payload. And a tag that is not exactly twice in
  # the file (opener + closer, the closer alone on its own line) means a heredoc
  # that never terminates: the boot swallows the rest of the body and the
  # workspace comes up with two skills and a truncated script.
  local i tag n
  for i in "${!TAGS[@]}"; do
    tag="${TAGS[i]}"
    n="$(grep -cF -- "${tag}" "${SEED}" || true)"
    assert_eq "${tag} appears exactly twice (opener + closer)" "2" "${n}"
    n="$(grep -cF -- "$(hdoc_open)'${tag}'" "${SEED}" || true)"
    assert_eq "${tag} opens quoted exactly once" "1" "${n}"
    n="$(grep -cFx -- "${tag}" "${SEED}" || true)"
    assert_eq "${tag} closes alone on its own line" "1" "${n}"
  done
}

@test "stack-skills seed: each heredoc body is its own rendered interpolation" {
  # A heredoc that quietly stopped receiving its payload still has a legal
  # opener and closer, so the tag checks above pass vacuously: the file that
  # lands on disk would be empty and the slash command simply missing. Pin the
  # line right after each opener to the map key main.tf is required to fill.
  local i tag key after
  for i in "${!TAGS[@]}"; do
    tag="${TAGS[i]}"
    key="${KEYS[i]}"
    after="$(grep -A 1 -F -- "$(hdoc_open)'${tag}'" "${SEED}" | tail -n 1)"
    assert_eq "${tag} is fed by the payload interpolation" "\${${key}}" "${after}"
  done
}

@test "stack-skills seed: the .agents twin is a cp of the managed copy, never a second heredoc" {
  # The two homes are two consumers of ONE file. If the ~/.agents side grows its
  # own heredoc body the two drift the moment one is edited, and first-match-wins
  # dedupe decides which of the two the CLI actually runs. So the twin must be a
  # cp of the managed ~/.coder file, and the file must carry exactly three
  # heredocs total - one per skill, all on the coder side.
  local i name n
  n="$(grep -cE -- "$(hdoc_open)'[A-Z_]+_SKILL_MD_EOF'" "${SEED}" || true)"
  assert_eq "the body holds exactly three quoted heredocs" "3" "${n}"
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    assert_contains_file "${name} agents guard" "${SEED}" \
      '^if \[ ! -f "\$HOME/\.agents/skills/'"${name}"'/SKILL\.md" \]; then$'
    assert_contains_file "${name} agents mkdir" "${SEED}" \
      'mkdir -p "\$HOME/\.agents/skills/'"${name}"'" 2>/dev/null'
    assert_contains_file "${name} copies the managed coder copy" "${SEED}" \
      'cp "\$HOME/\.coder/skills/'"${name}"'/SKILL\.md" \\'
    assert_contains_file "${name} lands it in the agents home" "${SEED}" \
      '"\$HOME/\.agents/skills/'"${name}"'/SKILL\.md" 2>/dev/null'
    # No second body, in either spelling.
    n="$(grep -cF -- "cat >\"\$HOME/.agents/skills/" "${SEED}" || true)"
    assert_eq "${name} never gets its own heredoc on the agents side" "0" "${n}"
  done
}

@test "stack-skills seed: the file is a plain-ASCII POSIX sh coder_script body" {
  # Coder runs this body through sh, not bash, and the agent receives it as one
  # execve argument: a bashism is a script that dies at boot, and a stray CR or
  # non-ASCII byte reaches every workspace of both templates as mojibake that a
  # byte-wise comparison reads as a different file.
  local first stray n_cr
  first="$(head -n 1 "${SEED}")"
  assert_eq "it opens with a shebang" '#!/bin/sh' "${first}"

  stray="$(tr -d '\0-\177' <"${SEED}" | wc -c | tr -d ' ')"
  if [ "${stray}" -ne 0 ]; then
    printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${SEED}" "${stray}" >&2
    LC_ALL=C grep -n '[^ -~]' "${SEED}" >&2
    return 1
  fi
  n_cr="$(grep -c $'\r' "${SEED}" || true)"
  assert_eq "it carries no carriage return" "0" "${n_cr}"
}

@test "stack-skills seed: it never writes a skills file outside an absent guard" {
  # The whole takeover story rests on "absent-only": an unconditional > to a
  # skills path silently deletes an operator's edited skill at the next boot,
  # which is the one thing the marker contract says cannot happen. Walk the
  # body and refuse any redirect into a skills path that is not inside a guard.
  local bad
  bad="$(awk '
    /^if \[ ! -f "\$HOME\/\.(coder|agents)\/skills\// { guard = 1; next }
    /^fi$/ { guard = 0 }
    />.*\/skills\// && !guard { print NR ": " $0; bad = 1 }
    END { exit bad }
  ' "${SEED}")"
  if [ -n "${bad}" ]; then
    printf 'FAIL: %s writes a skills path with no absent-guard in front:\n%s' "${SEED}" "${bad}" >&2
    return 1
  fi
}

@test "stack-skills feed: both main.tf twins declare the script gated on the workspace start" {
  # A coder_script with no count runs on every plan and re-runs the seed; with
  # no run_on_start the trio only appears after a manual start, so a freshly
  # started workspace has no slash commands to find. A wrong agent_id sends the
  # script to an agent that does not exist and the apply fails.
  local twin block
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(main_block "${twin}/main.tf" coder_script stack_skills)"
    [ -n "${block}" ] || {
      printf 'FAIL: %s has no coder_script "stack_skills" block\n' "${twin}/main.tf" >&2
      return 1; }
    assert_match "${twin} gates the seed on start_count" \
      'count[[:space:]]+=[[:space:]]+data\.coder_workspace\.me\.start_count' "${block}"
    assert_match "${twin} targets the main agent" \
      'agent_id[[:space:]]+=[[:space:]]+coder_agent\.main\.id' "${block}"
    assert_match "${twin} runs it on start" \
      'run_on_start[[:space:]]+=[[:space:]]+true' "${block}"
    assert_match "${twin} renders the shared seed body" \
      'script = templatefile\("\$\{path\.module\}/stack-skills\.sh\.tftpl"' "${block}"
  done
}

@test "stack-skills feed: the three payloads are chomped and live inside that block alone" {
  # Two load-bearing details. chomp: the heredoc closes on its own line, so a
  # trailing newline in the payload adds a blank line to every seeded SKILL.md
  # on every seed, and the marker comment drifts off the shape the parser and
  # these tests expect. In-block placement: both byte readers credit a body by
  # scanning its own block for path.module}/<name>", so a key moved behind a
  # local. indirection stops being counted - the payload becomes invisible to
  # the ceiling guard while still travelling in the argument.
  local twin block agent i key total
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(main_block "${twin}/main.tf" coder_script stack_skills)"
    agent="$(main_block "${twin}/main.tf" coder_agent main)"
    for i in "${!KEYS[@]}"; do
      key="${KEYS[i]}"
      assert_match "${twin} chomps ${key} from its payload, inside the block" \
        "${key}[[:space:]]+=[[:space:]]+chomp\(file\(\"\\\$\{path\.module\}/[a-z-]+\.SKILL\.md\"\)\)" "${block}"
      # The map key must appear once in the whole file, and inside the block:
      # a copy left behind in the startup_script map ships the bytes twice and
      # spends the headroom this move was made to buy.
      total="$(grep -cF -- "${key}" "${twin}/main.tf" || true)"
      assert_eq "${twin} feeds ${key} exactly once, out of the startup map" "1" "${total}"
      if printf '%s' "${agent}" | grep -Fq -- "${key}"; then
        printf 'FAIL: %s still inlines %s into coder_agent.main startup_script\n' \
          "${twin}/main.tf" "${key}" >&2
        return 1
      fi
    done
  done
}

@test "stack-skills size: the new body is measured in both twins, not invisible to the guard" {
  # This is the guard that keeps the escape hatch honest. startup_size.awk is
  # what scripts/push-template.sh reads to refuse an argument past MAX_ARG_STRLEN
  # before the workspace ever boots; a body it does not emit a record for is a
  # body nobody measures, and it shows up as a workspace that fails to boot with
  # "A startup script has failed" instead of as a failed push.
  local twin out want tab
  tab="$(printf '\t')"
  [[ -f "${REPO_ROOT}/scripts/lib/startup_size.awk" ]] ||
    skip "startup_size.awk is not reachable under ${REPO_ROOT}/scripts/lib"
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    out="$(awk -f "${REPO_ROOT}/scripts/lib/startup_size.awk" "${twin}/main.tf")"
    for want in stack-skills.sh.tftpl ez-learn.SKILL.md ez-skillify.SKILL.md ez-create-skill.SKILL.md; do
      assert_match "${twin} measures ${want} inside the stack-skills body" \
        "^stack-skills\.sh\.tftpl${tab}${want}\$" "${out}"
    done
    # A body this reader cannot name is one it cannot size.
    assert_not_match "${twin} never reports the new body as unmeasurable" \
      "^stack-skills\.sh\.tftpl${tab}(HEREDOC|OTHER|CLASH)\$" "${out}"
  done
}

@test "stack-skills seams: config_seed names all six targets against the three payloads" {
  # refresh-configs reseeds from this list and the boot only writes absent files,
  # so a target missing here leaves a workspace with a stale or absent skill
  # after a stack update forever - and one home missing means the operator has
  # the command in the CLI and not in the chat, or the reverse.
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  [ -f "${lib}" ] || skip "no config_seed lib under ${REPO_ROOT}/scripts/lib"
  local name
  for name in "${SKILLS[@]}"; do
    assert_contains_file "coder ${name} target" "${lib}" '~/\.coder/skills/'"${name}"'/SKILL\.md'
    assert_contains_file "agents ${name} target" "${lib}" '~/\.agents/skills/'"${name}"'/SKILL\.md'
    assert_contains_file "${name} payload source" "${lib}" \
      'file:templates/common/'"${name}"'\.SKILL\.md'
  done
  # Six lines, so neither home was added at the cost of the other.
  local n
  n="$(grep -cE "^[[:space:]]*'~/\.(coder|agents)/skills/ez-(learn|skillify|create-skill)/SKILL\.md" "${lib}" || true)"
  assert_eq "six skill targets, both homes per skill" "6" "${n}"
}

@test "stack-skills neighbours: both startup twins kept the delegation seed and the learn retirement" {
  # The move cut a block out of startup.sh.tftpl, and the two blocks that share
  # its front matter were never in scope. Losing the delegation seed unregisters
  # the orchestrator skill; losing the retirement loop leaves the old /learn copy
  # shadowing the CLI's own bundled skill for the life of the volume.
  local twin
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    assert_contains_file "the delegation seed guard survives" "${twin}/startup.sh.tftpl" \
      '^if \[ ! -f "\$HOME/\.coder/skills/grok-build-delegation/SKILL\.md" \]; then$'
    assert_contains_file "the delegation twin copy survives" "${twin}/startup.sh.tftpl" \
      'cp "\$HOME/\.coder/skills/grok-build-delegation/SKILL\.md"'
    assert_contains_file "the learn retirement loop survives" "${twin}/startup.sh.tftpl" \
      'for _d in "\$HOME/\.coder/skills/learn" "\$HOME/\.agents/skills/learn"; do'
    assert_contains_file "and it still asks the marker first" "${twin}/startup.sh.tftpl" \
      "grep -qF 'managed-by: evo-t1-coder-stack'"
  done
}

# ---------------------------------------------------------------------------
# Invariants every payload of the trio shares.
# ---------------------------------------------------------------------------

@test "payload: line 1 is the opening fence and the managed-by marker sits below the close" {
  # The parser drops a file whose first line is not exactly ---: an HTML comment
  # promoted to line 1 silently unregisters the slash command while the file
  # still looks fine to a reader. And the marker has to be provenance, not
  # structure - inside the frontmatter it would become a skill key nobody
  # documents and the seeder's ownership probe reads as content.
  local i f close marker
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    run head -n 1 "${f}"
    assert_eq "${SKILLS[i]} opens the frontmatter on line 1" "---" "${output}"

    close="$(awk 'NR > 1 && /^---[[:space:]]*$/ { print NR; exit }' "${f}")"
    [ -n "${close}" ] || {
      printf 'FAIL: no closing frontmatter fence in %s\n' "${f}" >&2
      return 1; }
    [ "${close}" -gt 2 ]

    marker="$(grep -nF 'managed-by: evo-t1-coder-stack' "${f}" | head -n 1 | cut -d: -f1)"
    [ -n "${marker}" ] || {
      printf 'FAIL: %s lost the managed-by marker\n' "${f}" >&2
      return 1; }
    [ "${marker}" -gt "${close}" ]
  done
}

@test "payload: the frontmatter parses with only the documented keys and the name is the file stem" {
  # This is what registers each slash name. A key outside the documented set is
  # drift the CLI ignores while looking like configuration, a name that stopped
  # matching the file's stem registers a command nobody calls by the path the
  # seed writes, and user-invocable: false unregisters the command the payload
  # exists to ship. PyYAML is optional the way py_helpers.bats treats it.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  local i f
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    python3 -c "${FRONTMATTER_PROG}" "${SKILLS[i]}" <"${f}"
  done
}

@test "payload: each of the three stays plain ASCII with no CR" {
  # Every consumer reads these as text a shell or a parser parses: a curly quote
  # or an en dash survives into the seeded skill, reads as mojibake in the
  # terminal, and byte-wise comparisons treat it as a different file - which is
  # how a takeover edit becomes a diff that never matches.
  local i f stray
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    stray="$(tr -d '\0-\177' <"${f}" | wc -c | tr -d ' ')"
    if [ "${stray}" -ne 0 ]; then
      printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${f}" "${stray}" >&2
      LC_ALL=C grep -n '[^ -~]' "${f}" >&2
      return 1
    fi
    local n_cr
    n_cr="$(grep -c $'\r' "${f}" || true)"
    assert_eq "${SKILLS[i]} carries no carriage return" "0" "${n_cr}"
  done
}

@test "payload: the marker comment tells the truth about taking a copy over and hiding it" {
  # Deleting a seeded file gets it back: the body writes it whenever it is
  # absent, so the only takeover is an edit that drops the marker line. A
  # payload that says "delete this file" teaches an operator a deletion that the
  # next boot silently undoes - the exact advice that costs them an afternoon.
  # And an operator who wants the command gone needs [skills]/disabled, not rm.
  local i f n
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    n="$(grep -Eic -- 'delete[[:space:]]+this[[:space:]]+file' "${f}" || true)"
    assert_eq "${SKILLS[i]} never tells the reader to delete the file" "0" "${n}"
    assert_contains_file "${SKILLS[i]} keeps the seeder marker string" "${f}" \
      'managed-by: evo-t1-coder-stack'
    assert_contains_file "${SKILLS[i]} says ownership moves by marker deletion" "${f}" \
      'delete[^.]*marker'
    assert_contains_file "${SKILLS[i]} hiding names the skills table" "${f}" '\[skills\]'
    assert_contains_file "${SKILLS[i]} names the disabled knob" "${f}" \
      'disabled[[:space:]]*=[[:space:]]*\['
  done
}

@test "payload: the body names the tool that runs the commands it shows for both consumers" {
  # A command written inline in a skill body runs nothing: it reaches the model
  # as literal text. These payloads show indented command blocks, so the intro
  # has to name run_terminal_command for the CLI and execute for the Coder
  # Agents chat agent, or the model narrates the steps instead of running them
  # and the operator believes the workflow was performed.
  local i f
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    assert_contains_file "${SKILLS[i]} names the CLI terminal tool" "${f}" 'run_terminal_command'
    assert_contains_file "${SKILLS[i]} names the chat-side shell tool" "${f}" 'execute'
    assert_match "${SKILLS[i]} ties the two tools to the two consumers" \
      'run_terminal_command[^!]{0,120}execute|execute[^!]{0,120}run_terminal_command' \
      "$(payload_prose "${f}")"
  done
}

@test "payload: every skill names the two homes as a pair and disowns .grok/skills for the chat agent" {
  # The measured split: the CLI discovers from <repo_root>/.grok/skills/,
  # ~/.grok/skills/ and ~/.agents/skills/, while the chat agent reads ONLY
  # ~/.coder/skills/. A skill that names one home has a consumer that never sees
  # it, and a payload that recommends a .grok/skills copy without saying so
  # ships a skill the chat side cannot invoke. Naming .grok/skills is legal -
  # lying about who reads it is not.
  local i f n
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    assert_contains_file "${SKILLS[i]} names the CLI-side home" "${f}" \
      '~/\.agents/skills/<[A-Za-z0-9_.-]+>/SKILL\.md'
    assert_contains_file "${SKILLS[i]} names the chat-side twin" "${f}" \
      '~/\.coder/skills/<[A-Za-z0-9_.-]+>/SKILL\.md'

    if grep -qF -- '.grok/skills' "${f}"; then
      n="$(grep -F -- '.grok/skills' "${f}" |
        grep -Eic '[Cc]hat agent.*reads?.*(only|neither|never)([^[:alpha:]]|$)' || true)"
      if [ "${n}" -eq 0 ]; then
        printf 'FAIL: %s names a .grok/skills path without stating on that line that the\nCoder Agents chat agent does not read it - that consumer reads only ~/.coder/skills/.\n' \
          "${f}" >&2
        grep -nF -- '.grok/skills' "${f}" >&2
        return 1
      fi
    fi
  done
}

@test "payload: every bazel label a skill cites still resolves" {
  # These payloads tell an operator to run what they print. A label the tree
  # stopped declaring is a dead end in the first minute, and the only way to
  # catch it before a user does is to resolve every citation against the tree:
  # the root BUILD file carries the //:labels and scripts/<stem>.sh carries the
  # CLI targets, which are the two places a target can come from here.
  [[ -f "${REPO_ROOT}/BUILD.bazel" ]] ||
    skip "the root BUILD file is not in this suite's runfiles (//:bazel_files)"

  local i f tokens resolvable token stem label bad missing required
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    # The guard rejects a // preceded by a colon or a word char, so an https://
    # URL is not mistaken for a label, and the class carries <> so the generic
    # //scripts:<stem> spelling survives capture.
    tokens="$(grep -oE '(^|[^:/A-Za-z])//([A-Za-z0-9_.-]*):([A-Za-z0-9_.<>-]+)' "${f}" |
      grep -oE '//[A-Za-z0-9_.-]*:[A-Za-z0-9_.<>-]+' | sort -u)"
    if [ -z "${tokens}" ]; then
      printf 'FAIL: %s cites no bazel target at all\n' "${f}" >&2
      return 1
    fi

    # The targets each skill is answerable for: the loop below would otherwise
    # pass vacuously on a payload that had quietly dropped every one of them.
    case "${SKILLS[i]}" in
      ez-skillify)
        required="$(printf '%s\n' //:test-fast //scripts:mcp-check //scripts:refresh-configs | sort -u)" ;;
      ez-create-skill)
        required="$(printf '%s\n' //scripts:refresh-configs | sort -u)" ;;
      *)
        required="$(printf '%s\n' //:test-fast | sort -u)" ;;
    esac
    missing="$(comm -23 <(printf '%s\n' "${required}") <(printf '%s\n' "${tokens}"))"
    if [ -n "${missing}" ]; then
      printf 'FAIL: %s no longer cites: %s\n' "${f}" "$(printf '%s ' "${missing}")" >&2
      return 1
    fi

    # //scripts:<stem> is the payloads' generic spelling for a CLI target, so it
    # is pinned as a citation, not resolved as a label.
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
          # The closing quote is part of the needle: name = "lint" must not be
          # satisfied by a longer target name beside it.
          grep -qF -- "name = \"${label}\"" "${REPO_ROOT}/BUILD.bazel" ||
            bad="${bad}${token} (no name = \"${label}\" in the root BUILD file)"$'\n'
          ;;
        *)
          bad="${bad}${token} (neither a root label nor a //scripts CLI)"$'\n'
          ;;
      esac
    done
    if [ -n "${bad}" ]; then
      printf 'FAIL: %s cites a target that does not resolve:\n%s' "${f}" "${bad}" >&2
      return 1
    fi

    # A cited target has to travel in the runnable form, not as a bare mention:
    # `bazelisk test` / `bazelisk run` is what makes it a step an agent runs.
    assert_contains_file "${SKILLS[i]} shows the labels as commands to run" "${f}" \
      'bazelisk (test|run) //'
  done
}

@test "payload: every doc a skill points at is still in the checkout" {
  # A skill that cites a doc which no longer exists sends the reader looking for
  # an answer nobody wrote. Citations resolve at the repo root or under docs/,
  # and only there. README.md and AGENTS.md travel with this suite through
  # //:entry_docs, so a root that resolved above always carries them: a missing
  # one is the citation breaking, not the runfiles being thin.
  [[ -f "${REPO_ROOT}/README.md" ]] || {
    printf 'FAIL: README.md is not reachable from %s - the runfiles lost //:entry_docs\n' \
      "${REPO_ROOT}" >&2
    return 1; }
  [[ -f "${REPO_ROOT}/AGENTS.md" ]] || {
    printf 'FAIL: AGENTS.md is not reachable from %s - the runfiles lost //:entry_docs\n' \
      "${REPO_ROOT}" >&2
    return 1; }

  local i f cited name path unresolved want missing total=0 count
  for i in "${!SKILLS[@]}"; do
    f="$(payload_path "${SKILLS[i]}")"
    # Two segments at most, so a config path or a notes path is not mistaken for
    # a doc citation; SKILL.md is the artifact every skill writes, not a doc.
    cited="$(grep -oE '[A-Za-z0-9._/-]+\.md' "${f}" |
      grep -E '^([A-Za-z0-9._-]+|docs/[A-Za-z0-9._-]+)\.md$' |
      grep -vx 'SKILL\.md' | sed 's|^docs/||' | sort -u)"
    count="$(printf '%s\n' "${cited}" | grep -c . || true)"
    total=$((total + ${count:-0}))

    case "${SKILLS[i]}" in
      ez-create-skill) want="$(printf '%s\n' grok-build-and-agents.md | sort -u)" ;;
      *) want="" ;;
    esac
    missing="$(comm -23 <(printf '%s\n' "${want}") <(printf '%s\n' "${cited}"))"
    if [ -n "${missing}" ]; then
      printf 'FAIL: %s no longer points at: %s\n' "${f}" "$(printf '%s ' "${missing}")" >&2
      return 1
    fi

    unresolved=""
    for name in ${cited}; do
      path="${REPO_ROOT}/${name}"
      [[ -f "${path}" ]] || path="${REPO_ROOT}/docs/${name}"
      [[ -f "${path}" ]] || unresolved="${unresolved}${name}"$'\n'
    done
    if [ -n "${unresolved}" ]; then
      printf 'FAIL: %s cites a doc that is in neither the root nor docs/:\n%s' \
        "${f}" "${unresolved}" >&2
      return 1
    fi
  done
  # Non-vacuity: the trio has to point at the docs tree at all, or the loop
  # above passes on a set of payloads that had quietly stopped citing anything.
  [ "${total}" -gt 0 ] || {
    printf 'FAIL: none of the three payloads cites a doc any more\n' >&2
    return 1; }
}

# ---------------------------------------------------------------------------
# /ez-skillify's own claims.
# ---------------------------------------------------------------------------

@test "ez-skillify: it gates on the run having succeeded and hands a failed gate to /ez-create-skill" {
  # Capturing a flaky session hands the next session a recipe to fail by, which
  # is worse than no skill at all. The gate has to be explicit and the fallback
  # has to be the sibling that authors from a description instead.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "the four answers are required" 'All four answers have to be yes' "${prose}"
  assert_match "answer one is that it succeeded" 'It succeeded' "${prose}"
  assert_match "a no answer names which one and routes to the sibling" \
    'name which one and hand the user to ./ez-create-skill' "${prose}"
  assert_match "it refuses a flaky run outright" 'Never capture a flaky run' "${prose}"
}

@test "ez-skillify: it reconstructs the goal, the ordered steps, the corrections and the edge cases" {
  # The transcript is the source of truth and these four are what makes a
  # captured procedure worth more than a blank prompt. Drop the corrections and
  # the file loses the lines the user paid for with their own retry loops; drop
  # the ordering and the steps run in an order that never worked.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "the goal comes from the user's own first words" \
    "The goal, in the user's own first words" "${prose}"
  assert_match "the ordered steps that worked" 'The ordered steps that worked' "${prose}"
  assert_match "every correction the user made" 'Every correction the user made' "${prose}"
  assert_match "the edge cases and dead ends" 'The edge cases that came up' "${prose}"
}

@test "ez-skillify: the command that PROVED the run worked becomes the new skill's success criterion" {
  # Without a runnable check the captured skill has no definition of done, and
  # "it looked right" is exactly how a flaky run got captured as a procedure in
  # the first place. The proof must be a command the future agent can run.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "it asks for the command that proved the run" \
    'one command or check that PROVED it worked' "${prose}"
  assert_match "that command becomes the success criterion" 'success criterion' "${prose}"
  assert_match "it must be a command the future agent can run" \
    'a command the future agent can run itself' "${prose}"
  assert_match "it rejects a look of approval as proof" 'never "it looked right"' "${prose}"
}

@test "ez-skillify: it generalizes one-off specifics into parameters" {
  # A skill keyed to tonight's branch name or ticket id is a commit message, not
  # a workflow: the next caller has nothing to fill in and the file is dead on
  # arrival. The constraints that still hold have to survive the same pass.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "it has a generalize step" '## Step 3 -- generalize it' "${prose}"
  assert_match "one-off specifics become parameters" \
    'into parameters the next caller fills in' "${prose}"
  assert_match "the constraints that still hold are kept" \
    'Keep every constraint that still holds next time' "${prose}"
}

@test "ez-skillify: it asks before writing anything" {
  # The description is what the model matches on and the name is what the whole
  # tree has to agree on; writing first means the operator reviews a file they
  # did not approve and a slash name they did not choose.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "the name, scope and triggers are confirmed first" \
    'confirm name, scope and triggers with the user' "${prose}"
  assert_match "description and when-to-use go up for approval BEFORE any write" \
    'show both for approval BEFORE writing anything' "${prose}"
}

@test "ez-skillify: it writes both homes in one mkdir" {
  # One home means one blind consumer: the chat agent reads only
  # ~/.coder/skills/, the CLI reads ~/.agents/skills/. The instruction has to
  # create both in the same breath, or the operator ships half a skill.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "both homes are created together" \
    'mkdir -p "\$HOME/\.agents/skills/<name>" "\$HOME/\.coder/skills/<name>"' "${prose}"
  assert_match "it says the pair is not optional" 'the pair is not optional' "${prose}"
}

@test "ez-skillify: it refuses to write over a marker-carrying stack-owned copy" {
  # A file that still carries the managed-by marker is stack-owned: the boot
  # rewrites it whenever it is absent, so writing over it is a change that
  # vanishes at the next start and an operator who loses real work.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "it refuses a marker-carrying home copy" \
    'Never write a skill over a home copy that still carries the stack marker' "${prose}"
  assert_match "and sends the fix to the seed, not the home" \
    'templates/common/' "${prose}"
}

@test "ez-skillify: it forbids capturing a secret or an .env value into the skill body" {
  # The transcript a skillify runs on is full of the command lines that printed
  # a token. A captured skill is written into a home directory and often into
  # git, so one copied value is a committed credential.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "it forbids capturing a secret" 'Never capture a secret' "${prose}"
  assert_match "it names the key instead of printing it" 'instead of printing it' "${prose}"
}

@test "ez-skillify: it verifies with grok inspect --json and reads source and userInvocable" {
  # Discovery sees the file, not what the model composed: a skill that was never
  # written, or written into the wrong home, still reads perfectly. The JSON
  # report is the only thing that proves both homes were found and that the
  # slash menu will actually list it.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "it runs the JSON inspector" 'grok inspect --json' "${prose}"
  assert_match "it reads the source path" "prints each skill's \`source\` and \`userInvocable\`" "${prose}"
  assert_match "it asks for a source line for BOTH homes" \
    'source` line shows for BOTH homes' "${prose}"
  assert_match "it checks userInvocable is true" '`userInvocable` is true' "${prose}"
}

@test "ez-skillify: it says a skill is not a memory" {
  # Without the line the operator files durable facts in a skill body, where
  # nothing but this command will ever read them: facts belong to /remember.
  local f prose
  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "a skill is not a memory" 'A skill is not a memory' "${prose}"
  assert_match "durable facts go to the memory command" '/remember' "${prose}"
}

# ---------------------------------------------------------------------------
# /ez-create-skill's own claims.
# ---------------------------------------------------------------------------

@test "ez-create-skill: it walks the five documented steps in order" {
  # The steps are the product: drop draft-and-approve and it writes unapproved
  # text, drop verify and it reports a skill that was never discovered. Order
  # matters too - structure before frontmatter, verification last.
  local f prose i
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  local -a titles=("1 -- gather" "2 -- draft" "3 -- create the structure" "4 -- write" "5 -- verify")
  for i in "${titles[@]}"; do
    assert_match "it carries Step ${i}" "## Step ${i}" "${prose}"
  done
  assert_match "the steps stay in the documented order" \
    '## Step 1 -- gather.*## Step 2 -- draft.*## Step 3 -- create the structure.*## Step 4 -- write.*## Step 5 -- verify' \
    "${prose}"
}

@test "ez-create-skill: it states the name rule the CLI enforces" {
  # A name outside the rule is the one mistake that cannot be fixed by editing
  # the file: the bad name is already the slash command, the directory, and in
  # some cases the qualified scope the skill is reachable under. The payload has
  # to state the rule before the operator types anything.
  local f prose
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  assert_match "lowercase letters, digits and hyphens" \
    'lowercase letters, digits and hyphens' "${prose}"
  assert_match "2-64 characters" '2-64 characters' "${prose}"
  assert_match "starting and ending with a letter or a digit" \
    'starting and ending with a letter' "${prose}"
  assert_match "spaces and underscores normalize to hyphens" \
    'normalize to hyphens' "${prose}"
}

@test "ez-create-skill: it presents the description for approval BEFORE writing" {
  # The description drives automatic invocation, so text the operator never read
  # is a skill that either never fires or fires on the wrong prompt - and it is
  # the one field a later edit rarely revisits.
  local f prose
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  assert_match "both fields go up for approval before any write" \
    'wait for approval or edits before touching disk' "${prose}"
  assert_match "it shows both of them" 'Show BOTH' "${prose}"
}

@test "ez-create-skill: its key table names exactly the documented key set" {
  # The table is the whole frontmatter contract this command teaches. A key that
  # silently disappears teaches people to omit it; a key nobody documents teaches
  # them to write configuration the CLI ignores. Both directions are drift, so
  # the table has to equal the documented set, not merely overlap it.
  local f table want got
  f="$(payload_path ez-create-skill)"
  table="$(grep -oE '^\| `[a-z-]+` \|' "${f}" | tr -d '|` ' | sort -u)"
  [ -n "${table}" ] || {
    printf 'FAIL: %s has no frontmatter key table to teach from\n' "${f}" >&2
    return 1; }
  want="$(printf '%s\n' "${DOC_KEYS[@]}" | sort -u)"
  assert_eq "the table names exactly the documented keys" "${want}" "${table}"
  got="$(printf '%s' "${table}" | tr '\n' ' ')"
  assert_match "the table is introduced as the only documented set" \
    'only documented keys' "$(payload_prose "${f}")"
}

@test "ez-create-skill: it explains the collision cost and the qualified scope:name form" {
  # A contested bare name is not an error, so nothing else tells the operator
  # their skill is now reachable only as scope:name. Without the explanation they
  # type /name forever and conclude the feature is broken.
  local f prose
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  assert_match "the built-in keeps the bare name" 'built-in keeps the bare name' "${prose}"
  assert_match "the loser is pushed to its qualified scope:name form" \
    'qualified .scope:name. form' "${prose}"
  assert_match "grok inspect is what tags the collision" \
    'collides with /x -> scope:x' "${prose}"
  assert_match "the fix is checked before writing" 'Check the name is free BEFORE writing' "${prose}"
}

@test "ez-create-skill: it names the [skills] knobs an operator reaches for when a skill is missing" {
  # "It is not showing up" is the question this payload answers or loses the
  # reader on. paths / ignore / disabled are the three levers under [skills]; if
  # the payload drops one, the operator edits the wrong one or reinstalls.
  local f prose
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  assert_match "the knobs live under [skills]" '\[skills\]' "${prose}"
  assert_match "it names paths, ignore and disabled together" \
    '.paths. scans an extra directory, .ignore. hides a skill entirely, .disabled. keeps it listed but inactive' \
    "${prose}"
}

@test "ez-create-skill: it points at the two-home rule and at grok inspect for verification" {
  # The stack rule, not a suggestion: a user-scope skill that should work on both
  # consumers ships twice. And discovery is disk state, so the only proof is what
  # the inspector resolved, not what the model wrote.
  local f prose
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  assert_match "it states the stack's two-home rule" "The stack's rule" "${prose}"
  assert_match "both homes ship or the chat agent has a blind consumer" \
    'one home means one blind consumer' "${prose}"
  assert_match "it verifies with the inspector" 'grok inspect --json' "${prose}"
  assert_match "the report covers the source path and userInvocable" \
    'the .source. path and .userInvocable.' "${prose}"
}

@test "ez-skillify and ez-create-skill: the trio names its siblings and splits by evidence" {
  # Three slash commands that overlap in the menu are three ways to do the wrong
  # one. What separates them is the evidence each starts from, and only the
  # payloads can say so: /ez-skillify captures the run that worked, /ez-learn
  # mines many sessions, this builds from a description.
  local f prose
  f="$(payload_path ez-create-skill)"
  prose="$(payload_prose "${f}")"
  assert_match "it names /ez-skillify" '/ez-skillify' "${prose}"
  assert_match "it names /ez-learn" '/ez-learn' "${prose}"
  assert_match "and states the division of labour" 'The trio splits by evidence' "${prose}"

  f="$(payload_path ez-skillify)"
  prose="$(payload_prose "${f}")"
  assert_match "skillify names its sibling for the failed gate" '/ez-create-skill' "${prose}"
}
