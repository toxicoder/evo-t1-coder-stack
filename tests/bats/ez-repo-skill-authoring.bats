#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ez-repo-skill-authoring.bats - the shared seam of the repository-refactoring family.
#
# The stack ships four more user-invocable commands beside the authoring trio:
# /ez-bazel-first (put every tracked file behind a Bazel target and keep it there),
# /ez-strong-types (a strict checker profile per language plus a broad-type
# ratchet), /ez-trunk-based-repo (collapse a repo onto one trunk, with the
# environments and the flags as configuration) and /ez-micro-plan (divide one
# piece of multi-file work into micro tasks a fleet of subagents can each finish
# on its own).
# Each seeds its SKILL.md into
# ~/.coder/skills/<name>/, the only path the
# Coder Agents chat agent reads, and into its ~/.agents/skills/<name>/ twin, which
# is what the Grok Build CLI reads - absent-only, from ONE
# templates/common/stack-repo-skills.sh.tftpl body rendered by the
# coder_script "stack_repo_skills" block in both main.tf twins. The fifth command of
# the family, /trunk-refactor, rides a body of its own for the ceiling reason that
# body's header gives, and tests/bats/trunk-refactor-skill.bats polices that body; the
# gates here name it only where one spans the family. Unlike the trio,
# three of these four carry python helpers beside the SKILL.md, under scripts/ in
# BOTH homes, because a skill body names the ~/.agents path while the chat agent
# reads the same text out of ~/.coder; the fourth ships a SKILL.md alone, so the
# gates below are driven by the payload lists rather than by a fixed shape.
#
# Why a second body at all: main.tf inlines every payload into
# coder_agent.startup_script and the agent execs that body as one execve argument
# gated at MAX_ARG_STRLEN; each coder_script.script gets its own ceiling, which is
# the headroom eight more payloads need (docs/coder-templates.md#the-one-argument-
# ceiling). So the gates here are the ones that keep that escape hatch honest: the
# body is MEASURED (scripts/lib/startup_size.awk must emit a record for it and for
# every payload it inlines), each feed is chomped and sits INSIDE the block (both
# byte readers credit a body only by the path.module names within it), the
# ~/.agents side is a cp of the managed ~/.coder copy rather than a second here-doc
# body, none of the family leaks back into startup.sh.tftpl, the repository-tier
# copy of ez-bazel-first is guarded per repository and behind a link test, and the
# reseed list names both homes of every family target, the trunk-refactor pair from
# that other body included, and the push guard names all nine payload files of this
# body beside the body itself.
#
# The authoring trio's own seam is tests/bats/ez-skill-authoring.bats; this suite
# covers the other family and shares no assertion with it.
#
# Usage: bazelisk test //tests:bats_ez_repo_skill_authoring_test   (from any cwd)
# Safety: reads templates/common/stack-repo-skills.sh.tftpl, the eight payloads it
# inlines, both main.tf twins, both startup.sh.tftpl twins, and
# scripts/lib/{config_seed.sh,template-push.sh,startup_size.awk}. Writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SEED=""

# Index-aligned across the two arrays below: the home-relative target (below
# <home>/) and the payload file it comes from. These are the five that keep the
# global two-home pair: the target, its mkdir, its cat on the ~/.coder side and the
# cp that twins it into ~/.agents.
GLOBAL_TARGETS=(
  "ez-strong-types/SKILL.md"
  "ez-strong-types/scripts/type_baseline.py"
  "ez-trunk-based-repo/SKILL.md"
  "ez-micro-plan/SKILL.md"
  "ez-micro-plan/scripts/plan_check.py"
)
GLOBAL_PAYLOADS=(
  "ez-strong-types.SKILL.md"
  "ez-strong-types.type_baseline.py"
  "ez-trunk-based-repo.SKILL.md"
  "ez-micro-plan.SKILL.md"
  "ez-micro-plan.plan_check.py"
)

# All eight payloads the body carries, index-aligned with the here-doc tag (TAGS)
# and the main.tf map key (KEYS) that feeds it. ez-bazel-first is absent from
# GLOBAL_TARGETS on purpose: it converts a repository, so the body stages its three
# payloads once and copies them into the repo tier at
# <repo>/.grok/skills/ez-bazel-first/ for every Bazel repository under the workspace
# root - a tier its own test below pins. It still rides the body as a here-doc and
# still has to be pushed, so it stays in the three arrays. stack-repo-commands is
# absent from GLOBAL_TARGETS for the same reason: it is seeded per clone, into the
# checkout that carries the .evo-t1-stack-repo sentinel, and
# tests/bats/seed-dev-env.bats runs that path for real.
PAYLOADS=(
  "ez-bazel-first.SKILL.md"
  "ez-bazel-first.owned_files_check.py"
  "ez-bazel-first.glob_budget.py"
  "ez-strong-types.SKILL.md"
  "ez-strong-types.type_baseline.py"
  "ez-trunk-based-repo.SKILL.md"
  "ez-micro-plan.SKILL.md"
  "ez-micro-plan.plan_check.py"
  "stack-repo-commands.SKILL.md"
)
TAGS=(
  EZ_BAZEL_FIRST_SKILL_MD_EOF
  EZ_BAZEL_FIRST_OWNED_FILES_CHECK_PY_EOF
  EZ_BAZEL_FIRST_GLOB_BUDGET_PY_EOF
  EZ_STRONG_TYPES_SKILL_MD_EOF
  EZ_STRONG_TYPES_TYPE_BASELINE_PY_EOF
  EZ_TRUNK_BASED_REPO_SKILL_MD_EOF
  EZ_MICRO_PLAN_SKILL_MD_EOF
  EZ_MICRO_PLAN_PLAN_CHECK_PY_EOF
  STACK_REPO_COMMANDS_SKILL_MD_EOF
)
KEYS=(
  ez_bazel_first_skill
  ez_bazel_first_owned_files_check
  ez_bazel_first_glob_budget
  ez_strong_types_skill
  ez_strong_types_type_baseline
  ez_trunk_based_repo_skill
  ez_micro_plan_skill
  ez_micro_plan_plan_check
  stack_repo_commands_skill
)

# The whole family, both bodies: trunk-refactor is absent from the five arrays above
# because templates/common/trunk-refactor-seed.sh.tftpl seeds it out of its own
# body, one coder_script of its own for the reason that body's header gives. It joins
# the arrays below only where a gate spans the family rather than one body -- the
# reseed list and the push guard, which do not care which body wrote the file.
FAMILY_TARGETS=( "${GLOBAL_TARGETS[@]}" "trunk-refactor/SKILL.md" )
FAMILY_PAYLOADS=( "${GLOBAL_PAYLOADS[@]}" "trunk-refactor.SKILL.md" )

# The frontmatter keys Grok Build documents: the whole set a payload may carry.
DOC_KEYS=(name description when-to-use allowed-tools argument-hint user-invocable
  disable-model-invocation model effort license compatibility metadata)

# The frontmatter parser, held here so the test body reads as the claim and not as
# the YAML plumbing. Reads the payload on stdin, its registered name in argv[1];
# exits non-zero with the reason on anything the CLI would reject.
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
    sys.exit("FAIL: %s: name must equal the stem of the file that carries it, got %r"
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
  SEED="${REPO_ROOT}/templates/common/stack-repo-skills.sh.tftpl"
  # Only the subject of the suite may skip it: with no seed body or no twin there is
  # nothing left to claim. The nine payloads deliberately are NOT gated here - a
  # payload renamed away must fail the tests that police it, not skip them quietly.
  [[ -f "${SEED}" ]] || skip "the repository-command seed body is not reachable from ${REPO_ROOT}"
  [[ -f "${REPO_ROOT}/templates/workspace/main.tf" &&
    -f "${REPO_ROOT}/templates/devcontainer/main.tf" &&
    -f "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" &&
    -f "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl" ]] ||
    skip "a template twin is not reachable from ${REPO_ROOT}"
}

# payload_path <payload> -- the staged copy of one payload of this family.
payload_path() {
  printf '%s' "${REPO_ROOT}/templates/common/${1}"
}

# hdoc_open -- print the two characters that open a here-document. Built from two
# halves on purpose: bats' preprocessor reads that digraph inside a needle as the
# opener of a real here-document and swallows every line below it, so this suite
# pins the seed's quoted delimiters without ever spelling them out.
hdoc_open() {
  printf '%s%s' '<' '<'
}

# main_block <main.tf> <resource type> <resource name> -- print one resource block,
# from its header to the brace that closes it at column zero.
main_block() {
  awk -v type="${2}" -v name="${3}" '
    $0 ~ "^resource \"" type "\" \"" name "\" \\{" { on = 1 }
    on { print }
    on && /^\}/ { exit }
  ' "${1}"
}

# ascii_gate <label> <path> -- fail with the offending lines when <path> holds a
# byte outside printable ASCII or a carriage return.
ascii_gate() {
  local stray n_cr
  stray="$(tr -d '\0-\177' <"${2}" | wc -c | tr -d ' ')"
  if [ "${stray}" -ne 0 ]; then
    printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${2}" "${stray}" >&2
    LC_ALL=C grep -n '[^ -~]' "${2}" >&2
    return 1
  fi
  n_cr="$(grep -c $'\r' "${2}" || true)"
  assert_eq "${1} carries no carriage return" "0" "${n_cr}"
}

# ---------------------------------------------------------------------------
# The delivery seam: one body, nine payloads, two homes.
# ---------------------------------------------------------------------------

@test "stack-repo-skills seed: the body seeds all five global-home targets into the coder home only while absent" {
  # Absent-only is the takeover contract: a file that exists belongs to the user,
  # so a boot must never write over one. Lose a guard and the next boot silently
  # rewrites whatever the operator wrote into ~/.coder/skills. Each target needs
  # all three lines - the test, the directory, the write - because mkdir -p is
  # what makes the scripts/ subdirectory exist for the python helpers.
  # templates/common/ exists once and both twins consume it, so the body is read
  # once here while everything main.tf does with it is checked per twin.
  local i tgt n
  for i in "${!GLOBAL_TARGETS[@]}"; do
    tgt="${GLOBAL_TARGETS[i]}"
    assert_contains_file "${tgt} coder guard" "${SEED}" \
      '^if \[ ! -f "\$HOME/\.coder/skills/'"${tgt}"'" \]; then$'
    assert_contains_file "${tgt} coder mkdir" "${SEED}" \
      'mkdir -p "\$HOME/\.coder/skills/'"$(dirname "${tgt}")"'" 2>/dev/null'
    assert_contains_file "${tgt} coder cat" "${SEED}" \
      'cat >"\$HOME/\.coder/skills/'"${tgt}"'" '"$(hdoc_open)"
  done
  # Counted from the body, not from the array: a target whose block was dropped
  # mid-refactor would otherwise leave the loop above asserting nothing about a file
  # nobody seeds any more.
  n="$(grep -cE '^if \[ ! -f "\$HOME/\.coder/skills/' "${SEED}" || true)"
  assert_eq "the body guards every global-home target and no other" \
    "${#GLOBAL_TARGETS[@]}" "${n}"
  # And ez-bazel-first never reaches a home: a copy under ~/.coder/skills advertises
  # a Bazel gate to a session working on a project that has none, which is the whole
  # reason it moved to the repository tier.
  n="$(grep -cE '"\$HOME/\.(coder|agents)/skills/ez-bazel-first' "${SEED}" || true)"
  assert_eq "ez-bazel-first is never written into a global skill home" "0" "${n}"
}

@test "stack-repo-skills seed: every payload arrives through a quoted here-doc whose tag closes alone" {
  # Two separate failures hide in these lines. An UNQUOTED delimiter lets the shell
  # expand the $-text every payload is made of (every python helper here is full of
  # f-strings and shell text) while the boot runs, so the seeded file is not the
  # payload. And a tag that is not exactly twice in the file (opener + closer, the
  # closer alone on its own line) means a here-doc that never terminates: the boot
  # swallows the rest of the body and the workspace comes up with whatever
  # commands landed before it and a truncated script.
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

@test "stack-repo-skills seed: each here-doc body is its own rendered interpolation, and the body consumes exactly the nine payload keys and the boot logger" {
  # A here-doc that quietly stopped receiving its payload still has a legal opener
  # and closer, so the tag checks above pass vacuously: the file that lands on disk
  # would be empty and the command simply missing. Pin the line right after each
  # opener to the map key main.tf is required to fill - and pin the whole set, so a
  # renamed key on one side of the seam cannot survive by matching nothing at all.
  local i tag key after got want
  for i in "${!TAGS[@]}"; do
    tag="${TAGS[i]}"
    key="${KEYS[i]}"
    after="$(grep -A 1 -F -- "$(hdoc_open)'${tag}'" "${SEED}" | tail -n 1)"
    assert_eq "${tag} is fed by the payload interpolation" "\${${key}}" "${after}"
  done

  got="$(grep -oE '\$\{[a-z_]+\}' "${SEED}" | sort -u)"
  [ -n "${got}" ] || {
    printf 'FAIL: %s interpolates no map key at all\n' "${SEED}" >&2
    return 1; }
  want="$(printf '%s\n' "${KEYS[@]}" boot_log_lib | sed 's/^/${/; s/$/}/' | sort -u)"
  assert_eq "the body reads the nine payload keys plus the boot logger" "${want}" "${got}"
  assert_eq "and each key is interpolated exactly once" "10" \
    "$(grep -cE '^\$\{[a-z_]+\}$' "${SEED}" || true)"
  # The ninth key carries no payload: main.tf passes the TEXT of
  # templates/common/boot-log.lib.sh for it, and the body drops that text in as one
  # bare line. It has to be the first thing the shell reads - a logger defined below
  # the first command narrates nothing about the part of the boot an operator asks
  # about, which is how far it got before it went quiet. Comments may precede it, and
  # this repo's bodies carry one explaining why the line is bare; nothing executable
  # may.
  local first_cmd
  first_cmd="$(awk '
    $0 == "set -u" { on = 1; next }
    on && /^[[:space:]]*$/ { next }
    on && /^#/ { next }
    on { print; exit }
  ' "${SEED}")"
  assert_eq "the boot logger is the first thing the shell reads after the option line" \
    '${boot_log_lib}' "${first_cmd}"
}

@test "stack-repo-skills seed: the .agents twin is a cp of the managed copy, never a second here-doc" {
  # The two homes are two consumers of ONE file. If the ~/.agents side grew its own
  # here-doc body the two drift the moment one is edited, and first-match-wins
  # dedupe decides which of the two the CLI actually runs. So the twin must be a cp
  # of the managed ~/.coder file, and the file must carry exactly eight here-docs in
  # total - one per payload, all on the coder side.
  local i tgt n
  n="$(grep -cE -- "$(hdoc_open)'[A-Z_]+_EOF'" "${SEED}" || true)"
  assert_eq "the body holds exactly nine quoted here-docs" "9" "${n}"
  for i in "${!GLOBAL_TARGETS[@]}"; do
    tgt="${GLOBAL_TARGETS[i]}"
    assert_contains_file "${tgt} agents guard" "${SEED}" \
      '^if \[ ! -f "\$HOME/\.agents/skills/'"${tgt}"'" \]; then$'
    assert_contains_file "${tgt} agents mkdir" "${SEED}" \
      'mkdir -p "\$HOME/\.agents/skills/'"$(dirname "${tgt}")"'" 2>/dev/null'
    assert_contains_file "${tgt} copies the managed coder copy" "${SEED}" \
      'cp "\$HOME/\.coder/skills/'"${tgt}"'" \\'
    assert_contains_file "${tgt} lands it in the agents home" "${SEED}" \
      '"\$HOME/\.agents/skills/'"${tgt}"'" 2>/dev/null'
    # No second body, in either spelling.
    n="$(grep -cF -- "cat >\"\$HOME/.agents/skills/" "${SEED}" || true)"
    assert_eq "${tgt} never gets its own here-doc on the agents side" "0" "${n}"
  done
  n="$(grep -cE '^  cp "\$HOME/\.coder/skills/' "${SEED}" || true)"
  assert_eq "one cp line carries each twin" "${#GLOBAL_TARGETS[@]}" "${n}"
}

@test "stack-repo-skills seed: the file is a plain-ASCII POSIX sh coder_script body" {
  # Coder runs this body through sh, not bash, and the agent receives it as one
  # execve argument: a bashism is a script that dies at boot, and a stray CR or
  # non-ASCII byte reaches every workspace of both templates as mojibake that a
  # byte-wise comparison reads as a different file. exit 0 is the closer the agent
  # reads as success - a body that falls off the end on a failed test would mark
  # the script failed and the workspace would come up reporting a broken start.
  local first
  first="$(head -n 1 "${SEED}")"
  assert_eq "it opens with a shebang" '#!/bin/sh' "${first}"
  assert_eq "it closes with a successful exit" 'exit 0' "$(tail -n 1 "${SEED}")"
  ascii_gate "the seed body" "${SEED}"
  sh -n "${SEED}"
}

@test "stack-repo-skills seed: it never writes a skills file outside an absent guard" {
  # The whole takeover story rests on "absent-only": an unconditional write to a
  # skills path silently deletes an operator's edited skill or helper at the next
  # boot, which is the one thing the marker contract says cannot happen. Walk the
  # body and refuse any writer that reaches a skills path outside a guard - the cat
  # on the coder side and the cp on the agents side both count.
  local bad writers
  bad="$(awk '
    /^#/ { next }
    /^if \[ ! -f "\$HOME\/\.(coder|agents)\/skills\// { guard = 1; next }
    /^fi$/ { guard = 0 }
    /(>.*\/skills\/|cp "[^"]*\/skills\/)/ && !guard { print NR ": " $0; bad = 1 }
    END { exit bad }
  ' "${SEED}")"
  if [ -n "${bad}" ]; then
    printf 'FAIL: %s writes a skills path with no absent-guard in front:\n%s' "${SEED}" "${bad}" >&2
    return 1
  fi
  # Non-vacuity: the walk above has ten writers to cover, five cats and five cps -
  # the two-home pair for every target the suite names. The repository-tier copies
  # this body also makes are policed by the test below, which requires each of them
  # to sit behind the symlink guard.
  writers="$(grep -cE '^  (cat >|cp )"[^"]*/skills/' "${SEED}" || true)"
  assert_eq "the walk covers every guarded two-home writer" \
    "$(( ${#GLOBAL_TARGETS[@]} * 2 ))" "${writers}"
}

@test "stack-repo-skills seed: ez-bazel-first seeds the repository tier, absent-only and link-guarded" {
  # The fourth member of this family converts a repository, so it belongs to the
  # repository it converts. <repo>/.grok/skills/ is the tier the Grok Build CLI reads
  # and the Coder Agents chat does not, so it has one home and no cp twin; the
  # single-source rule survives as one staged copy per payload, cp'd per repository.
  # Two things make that safe and both are pinned here: the copy is absent-only per
  # repository, so a copy the repository tracks or a person took over is left alone,
  # and a path behind a link is refused rather than written through by cp.
  local name n
  for name in SKILL.md owned_files_check.py glob_budget.py; do
    assert_contains_file "${name} is staged once" "${SEED}" \
      'cat >"\$bazel_first_stage/'"${name}"'" '"$(hdoc_open)"
  done
  # Each repository copy is a cp of the staged copy: one literal line for the runbook
  # and one loop for the two helpers, so no payload is ever inlined twice. The needles
  # below spell every braced shell var \$\$\{...\}: this is a .tftpl, so a var reaches the
  # shell only through Terraform's doubled-dollar escape, and a body that wrote a single
  # one would fail to plan rather than seed the wrong path.
  assert_contains_file "the runbook reaches each repository as a cp of the staged copy" "${SEED}" \
    'cp "\$bazel_first_stage/SKILL\.md" "\$\$\{evo_t1_skill_dir\}/SKILL\.md"'
  assert_contains_file "both helpers are copied from the staged dir, not a second body" "${SEED}" \
    'cp "\$bazel_first_stage/\$\$\{evo_t1_helper\}"'
  assert_contains_file "the helper loop names exactly the two shipped helpers" "${SEED}" \
    'for evo_t1_helper in owned_files_check\.py glob_budget\.py; do$'
  assert_contains_file "the tier is the repository's own skills dir" "${SEED}" \
    'evo_t1_skill_dir="\$\$\{evo_t1_repo\}\.grok/skills/ez-bazel-first"'
  assert_contains_file "the helpers keep the scripts/ subdir the skill names" "${SEED}" \
    'mkdir -p "\$\$\{evo_t1_skill_dir\}/scripts"'
  # Only a folder that is a git repository and names the Bazel module gets a copy;
  # the two WORKSPACE spellings are the pre-bzlmod form of a repo this skill has not
  # converted yet. Anything else is named in the log and seeded nowhere.
  assert_contains_file "a plain folder is reported and seeded nowhere" "${SEED}" \
    'is not a bazel repository, seeded nowhere'
  assert_contains_file "the module file is what makes a repository a bazel one" "${SEED}" \
    '\[ ! -f "\$\$\{evo_t1_repo\}MODULE\.bazel" \]'
  # A dangling link passes "[ ! -e ]", which is why the guard tests the path and the
  # directory above it, and why it cannot be a plain absent test.
  assert_contains_file "a path behind a link is refused, not written through" "${SEED}" \
    '\[ -L "\$1" \] \|\| \[ -L '
  assert_contains_file "and the guard still requires the target to be absent" "${SEED}" \
    '\[ ! -e "\$1" \]$'
  n="$(grep -cE '^ *if evo_t1_repo_writable ' "${SEED}" || true)"
  assert_eq "every repository-tier copy sits behind that guard" "3" "${n}"
}

# ---------------------------------------------------------------------------
# The feed: one coder_script block per twin, measured and self-contained.
# ---------------------------------------------------------------------------

@test "stack-repo-skills feed: both main.tf twins declare the script block with its five gating attributes" {
  # A coder_script with no count runs on every plan and re-runs the seed; with no
  # run_on_start the pair only appears after a manual start, so a freshly started
  # workspace has no command to find. A wrong agent_id sends the script to an agent
  # that does not exist and the apply fails. display_name is what the operator reads
  # in the agent log when a seed fails, and it has to say which family it is.
  local twin block
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(main_block "${twin}/main.tf" coder_script stack_repo_skills)"
    [ -n "${block}" ] || {
      printf 'FAIL: %s has no coder_script "stack_repo_skills" block\n' "${twin}/main.tf" >&2
      return 1; }
    assert_match "${twin} gates the seed on start_count" \
      'count[[:space:]]+=[[:space:]]+data\.coder_workspace\.me\.start_count' "${block}"
    assert_match "${twin} targets the main agent" \
      'agent_id[[:space:]]+=[[:space:]]+coder_agent\.main\.id' "${block}"
    assert_match "${twin} says which family it seeds" \
      'display_name[[:space:]]+=[[:space:]]+"Seed the repository refactoring commands"' "${block}"
    assert_match "${twin} gives it the code icon" \
      'icon[[:space:]]+=[[:space:]]+"/icon/code\.svg"' "${block}"
    assert_match "${twin} runs it on start" \
      'run_on_start[[:space:]]+=[[:space:]]+true' "${block}"
    assert_match "${twin} renders the shared seed body" \
      'script[[:space:]]+=[[:space:]]+templatefile\("\$\{path\.module\}/stack-repo-skills\.sh\.tftpl"' "${block}"
    assert_eq "${twin} declares the block exactly once" "1" \
      "$(grep -cF -- 'coder_script" "stack_repo_skills"' "${twin}/main.tf" || true)"
  done
}

@test "stack-repo-skills feed: the nine payloads are chomped and live inside that block alone" {
  # Two load-bearing details. chomp: the here-doc closes on its own line, so a
  # trailing newline in the payload adds a blank line to every seeded file and
  # drifts the marker comment off the shape the parser and these tests expect.
  # In-block placement: both byte readers credit a body by scanning its own block
  # for path.module}/<name>", so a key moved behind a local. indirection stops
  # being counted - the payload becomes invisible to the ceiling guard while still
  # travelling in the argument. And a copy left behind in the startup_script map
  # ships the bytes twice and spends the headroom this move was made to buy.
  local twin block agent i key payload esc want
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(main_block "${twin}/main.tf" coder_script stack_repo_skills)"
    agent="$(main_block "${twin}/main.tf" coder_agent main)"
    [ -n "${agent}" ] || {
      printf 'FAIL: %s has no coder_agent "main" block to compare against\n' "${twin}/main.tf" >&2
      return 1; }
    for i in "${!KEYS[@]}"; do
      key="${KEYS[i]}"
      payload="${PAYLOADS[i]}"
      esc="${payload//./\\.}"
      want="${key}[[:space:]]+=[[:space:]]+chomp\(file\(\"\\\$\{path\.module\}/${esc}\"\)\)"
      assert_match "${twin} chomps ${key} from ${payload}, inside the block" "${want}" "${block}"
      # The map key must appear once in the whole file, and not in the agent block.
      assert_eq "${twin} feeds ${key} exactly once, out of the startup map" "1" \
        "$(grep -cF -- "${key}" "${twin}/main.tf" || true)"
      if printf '%s' "${agent}" | grep -Fq -- "${key}"; then
        printf 'FAIL: %s still inlines %s into coder_agent.main startup_script\n' \
          "${twin}/main.tf" "${key}" >&2
        return 1
      fi
    done
  done
}

@test "stack-repo-skills feed: neither startup twin carries any of the family" {
  # The whole point of a dedicated body is the one-argument ceiling: startup.sh.tftpl
  # shares coder_agent.startup_script with everything else that body inlines. One
  # payload drifting back there spends the headroom this split exists to keep, and
  # it does so quietly, because the workspace still boots until the argument crosses
  # MAX_ARG_STRLEN. Checked per twin, and non-vacuously: the family has to exist in
  # main.tf and the startup body has to still carry the neighbour it shares with it.
  local twin name hits
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    for name in "${PAYLOADS[@]}" stack-repo-skills.sh.tftpl stack_repo_skills \
      ez_bazel_first_skill ez_strong_types_type_baseline; do
      hits="$(grep -cF -- "${name}" "${twin}/startup.sh.tftpl" || true)"
      assert_eq "${twin}/startup.sh.tftpl never mentions ${name}" "0" "${hits}"
    done
    # The startup body is neither empty nor renamed away, and main.tf really does
    # carry the family this suite is about.
    assert_contains_file "${twin}/startup.sh.tftpl still carries its own seed" \
      "${twin}/startup.sh.tftpl" 'grok-build-delegation/SKILL\.md'
    assert_contains_file "${twin}/main.tf carries the family instead" \
      "${twin}/main.tf" 'stack-repo-skills\.sh\.tftpl'
  done
}

@test "stack-repo-skills size: the body, its boot logger and all nine payloads are measured in both twins" {
  # This is the guard that keeps the escape hatch honest. startup_size.awk is what
  # the push reads to refuse an argument past MAX_ARG_STRLEN before the workspace
  # ever boots; a body it does not emit a record for is a body nobody measures, and
  # it shows up as a workspace that fails to boot with "A startup script has failed"
  # instead of as a failed push. Eleven records per twin: the body itself, the boot
  # logger main.tf hands it, and the nine payloads it inlines, and none of them may
  # fall through to a catch-all.
  local twin out want tab records
  tab="$(printf '\t')"
  [[ -f "${REPO_ROOT}/scripts/lib/startup_size.awk" ]] ||
    skip "startup_size.awk is not reachable under ${REPO_ROOT}/scripts/lib"
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    out="$(awk -f "${REPO_ROOT}/scripts/lib/startup_size.awk" "${twin}/main.tf")"
    assert_match "${twin} measures something at all" '.' "${out}"
    for want in stack-repo-skills.sh.tftpl boot-log.lib.sh "${PAYLOADS[@]}"; do
      assert_match "${twin} measures ${want} inside the stack-repo-skills body" \
        "^stack-repo-skills\.sh\.tftpl${tab}${want//./\\.}\$" "${out}"
    done
    records="$(printf '%s\n' "${out}" | grep -c "^stack-repo-skills\.sh\.tftpl${tab}" || true)"
    assert_eq "${twin} emits exactly eleven records for the body" "11" "${records}"
    # A body this reader cannot name is one it cannot size.
    assert_not_match "${twin} never reports the new body as unmeasurable" \
      "^stack-repo-skills\.sh\.tftpl${tab}(HEREDOC|OTHER|CLASH)\$" "${out}"
  done
}

# ---------------------------------------------------------------------------
# Invariants every payload of the family shares.
# ---------------------------------------------------------------------------

@test "payload: each of the nine exists, is non-empty, plain ASCII, CR-free and marker-carrying" {
  # The marker is what makes a seeded file reclaimable and what the boot's ownership
  # probe reads; a payload that lost it is a file the seeder may treat as the user's,
  # and a non-ASCII byte or a CR reaches every workspace of both templates as text a
  # byte-wise comparison reads as different - which is how a takeover edit becomes a
  # diff that never matches.
  local i f bytes
  for i in "${!PAYLOADS[@]}"; do
    f="$(payload_path "${PAYLOADS[i]}")"
    assert_file_exists "${PAYLOADS[i]} is in templates/common" "${f}"
    bytes="$(wc -c <"${f}" | tr -d ' ')"
    [ "${bytes}" -gt 0 ] || {
      printf 'FAIL: %s is empty\n' "${f}" >&2
      return 1; }
    ascii_gate "${PAYLOADS[i]}" "${f}"
    assert_contains_file "${PAYLOADS[i]} keeps the seeder marker string" "${f}" \
      'managed-by: evo-t1-coder-stack'
  done
}

@test "payload: the four SKILL.md frontmatters parse, carry only documented keys, and name themselves" {
  # This is what registers each slash name. A key outside the documented set is
  # drift the CLI ignores while looking like configuration, a name that stopped
  # matching the skill it ships registers a command nobody calls by the path the
  # seed writes, and the marker has to be provenance rather than structure - below
  # the closing fence, so the seeder's ownership probe reads it as content and not
  # as a frontmatter key nobody documents. PyYAML is optional the way
  # py_helpers.bats treats it.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  local skills=(ez-bazel-first ez-strong-types ez-trunk-based-repo ez-micro-plan) i name f close marker
  for i in "${!skills[@]}"; do
    name="${skills[i]}"
    f="$(payload_path "${name}.SKILL.md")"
    assert_file_exists "${name} SKILL.md is in templates/common" "${f}"
    run head -n 1 "${f}"
    assert_eq "${name} opens the frontmatter on line 1" "---" "${output}"

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

    python3 -c "${FRONTMATTER_PROG}" "${name}" <"${f}"
  done
  # The documented set is the contract this asserts against; a silently emptied list
  # would let any key through.
  assert_eq "the documented key set is the twelve the CLI names" "12" "${#DOC_KEYS[@]}"
}

@test "payload: the four python helpers compile and open with the shebang then the marker" {
  # These files are execed by the skill body through the path the body prints, so a
  # syntax error is a command that fails on the user's first step, and a missing
  # shebang makes the seeded file unrunnable while it still reads fine. The marker
  # has to be the line right under it: that is the shape every seed in this stack
  # uses, and the first two lines are what a takeover edit has to preserve. Bytecode
  # is redirected into this test's scratch tree so the gate never leaves a pyc behind
  # in the payload directory it is policing.
  local pys=(ez-bazel-first.owned_files_check.py ez-bazel-first.glob_budget.py \
    ez-strong-types.type_baseline.py ez-micro-plan.plan_check.py)
  local i f scratch stem
  scratch="$(make_scratch)"
  export PYTHONPYCACHEPREFIX="${scratch}"
  for i in "${!pys[@]}"; do
    f="$(payload_path "${pys[i]}")"
    assert_file_exists "${pys[i]} is in templates/common" "${f}"
    assert_eq "${pys[i]} opens with the interpreter shebang" \
      '#!/usr/bin/env python3' "$(head -n 1 "${f}")"
    assert_contains_file "${pys[i]} carries the marker on line 2" "${f}" \
      '^# managed-by: evo-t1-coder-stack'

    run python3 -m py_compile "${f}"
    assert_eq "${pys[i]} compiles" "0" "${status}"
    stem="${pys[i]%.py}"
    assert_file_exists "${pys[i]} bytecode landed in the scratch prefix" \
      "$(find "${scratch}" -name "${stem}.cpython-*.pyc" -print -quit)"
  done
}

# ---------------------------------------------------------------------------
# The two lists that have to name the family: the reseed set and the push guard.
# ---------------------------------------------------------------------------

@test "stack-repo-skills seams: config_seed names exactly the twelve family targets and retires the six ez-bazel-first ones" {
  # refresh-configs reseeds from this list and the boot only writes absent files, so
  # a target missing here leaves a workspace with a stale or absent command after a
  # stack update forever - and one home missing means the operator has the command
  # in the CLI and not in the chat, or the reverse. Twelve is six targets x two
  # homes: the five this body seeds plus trunk-refactor, which its own body seeds and
  # the reseed list has to carry all the same.
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  [ -f "${lib}" ] || skip "no config_seed lib under ${REPO_ROOT}/scripts/lib"
  local i tgt payload src_c src_a n seeds retired
  for i in "${!FAMILY_TARGETS[@]}"; do
    tgt="${FAMILY_TARGETS[i]}"
    payload="${FAMILY_PAYLOADS[i]}"
    assert_contains_file "coder ${tgt} target" "${lib}" '~/\.coder/skills/'"${tgt}"'[[:space:]]'
    assert_contains_file "agents ${tgt} target" "${lib}" '~/\.agents/skills/'"${tgt}"'[[:space:]]'
    # The ~/.agents spelling must be the twin of the ~/.coder spelling: same target
    # path under the other home, fed by the same payload file.
    src_c="$(grep -F -- "'~/.coder/skills/${tgt}" "${lib}" |
      grep -oE 'file:[A-Za-z0-9._/-]+' | head -n 1 | cut -d: -f2-)"
    src_a="$(grep -F -- "'~/.agents/skills/${tgt}" "${lib}" |
      grep -oE 'file:[A-Za-z0-9._/-]+' | head -n 1 | cut -d: -f2-)"
    assert_eq "${tgt} names its payload on the coder side" "templates/common/${payload}" "${src_c}"
    assert_eq "${tgt} is a twin of the coder spelling on the agents side" \
      "templates/common/${payload}" "${src_a}"
    assert_file_exists "${payload} the reseed list points at exists" \
      "${REPO_ROOT}/${src_c}"
  done
  n="$(grep -cE "^[[:space:]]*'~/\.(coder|agents)/skills/(ez-(strong-types|trunk-based-repo|micro-plan)|trunk-refactor)/" "${lib}" || true)"
  assert_eq "twelve repo-command targets across both bodies, both homes per payload" \
    "$(( ${#FAMILY_TARGETS[@]} * 2 ))" "${n}"

  # The repository tier is not home-relative, so it cannot be a reseed target; the
  # six global ez-bazel-first paths the tier change retires have to leave the reseed
  # list and join the retire list, or a workspace that booted while they were seeded
  # keeps advertising a Bazel gate to a project that has none.
  seeds="$(awk '/^seed_seed_targets\(\) \{$/ { on = 1; next } on && /^\}/ { exit } on { print }' "${lib}")"
  retired="$(awk '/^seed_retired_targets\(\) \{$/ { on = 1; next } on && /^\}/ { exit } on { print }' "${lib}")"
  n="$(printf '%s\n' "${seeds}" | grep -cE "^[[:space:]]*'~/.*ez-bazel-first" || true)"
  assert_eq "the reseed list names no global ez-bazel-first path" "0" "${n}"
  n="$(printf '%s\n' "${retired}" | grep -cE "^[[:space:]]*'~/\.(coder|agents)/skills/ez-bazel-first/" || true)"
  assert_eq "the retire list names all six retired global paths" "6" "${n}"
}

@test "stack-repo-skills seams: the push guard refuses without all nine payloads and the body" {
  # main.tf reads each of these out of the pushed copy, so a push that shipped
  # without one produces a template that renders garbage or fails to plan on every
  # workspace made from it afterwards. The guard has to live in template_push_one -
  # the function every push goes through - or it protects nothing.
  local lib="${REPO_ROOT}/scripts/lib/template-push.sh"
  [ -f "${lib}" ] || skip "no template-push lib under ${REPO_ROOT}/scripts/lib"
  assert_contains_file "the guard lives in the one push function" "${lib}" \
    '^template_push_one\(\) \{$'

  local guard got missing p fn_line loop_line
  fn_line="$(grep -n '^template_push_one() {' "${lib}" | head -n 1 | cut -d: -f1)"
  loop_line="$(awk '/^  for payload in \\/ { print NR; exit }' "${lib}")"
  [ -n "${fn_line}" ] && [ -n "${loop_line}" ] || {
    printf 'FAIL: %s has no payload guard loop inside template_push_one\n' "${lib}" >&2
    return 1; }
  [ "${loop_line}" -gt "${fn_line}" ] || {
    printf 'FAIL: the payload guard at line %s sits outside template_push_one (line %s)\n' \
      "${loop_line}" "${fn_line}" >&2
    return 1; }

  guard="$(awk '/^  for payload in \\/ { on = 1; next } on && /^  done$/ { exit } on { print }' "${lib}")"
  # Split on whitespace and the list terminator rather than deleting them, so the
  # last item (the one that carries the `; do`) stays one token.
  got="$(printf '%s\n' "${guard}" | tr ' \t;' '\n' | tr -d '\\' | sed '/^$/d' | sort -u)"
  [ -n "${got}" ] || {
    printf 'FAIL: the payload guard loop in %s names nothing\n' "${lib}" >&2
    return 1; }
  missing=""
  for p in "${PAYLOADS[@]}" stack-repo-skills.sh.tftpl; do
    printf '%s\n' "${got}" | grep -qxF -- "${p}" || missing="${missing}${p}"$'\n'
  done
  if [ -n "${missing}" ]; then
    printf 'FAIL: the push guard in %s does not list:\n%s' "${lib}" "${missing}" >&2
    return 1
  fi
}
