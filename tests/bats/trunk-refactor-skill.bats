#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## trunk-refactor-skill.bats - the trunk + flags skill stays whole, linked, and loadable.
#
# The repo ships one reusable procedure for converting a repository onto trunk-based
# development with lightweight flags: templates/common/trunk-refactor.SKILL.md is the
# canonical body, .grok/skills/trunk-refactor/SKILL.md is the tracked symlink that makes
# it a repo-tier skill the CLI discovers, and .grok/rules/trunk-feature-flags.md is the
# always-loaded
# constraint set, docs/workflows/trunk-feature-flags-refactor.md is the prose twin, and
# config/flags.yaml.example is the payload the procedure copies into a repo that has
# outgrown bare env vars.
#
# templates/common/trunk-refactor-seed.sh.tftpl is the coder_script body that seeds that
# canonical copy into both global skill homes. It rides its own body rather than
# stack-repo-skills.sh.tftpl for the ceiling reason that body's header gives, so the
# suite polices the split as well as the payload: one body, two homes, absent-only, and
# the map key that feeds it.
#
# Each of those files fails in a way nothing else notices. A truncated paste loses a
# phase or a criterion and the skill still loads; a broken symlink leaves /trunk-refactor
# undiscoverable while the body reads fine; an unquoted or drifted frontmatter title fails
# only the npm docs gate; and the flags sample is parsed by NO gate at all, because
# scripts/validate.sh names its YAML files rather than globbing config/. This suite is the
# completeness gate for that set: the body's structure, the link's target, the sample's
# schema (including that every stacks.<stack> override names a declared flag), the
# citations the always-loaded rules and the generated navigation make, and the seed body
# that carries the canonical copy into both skill homes.
#
# Usage: bazelisk test //tests:bats_trunk_refactor_skill_test   (from any cwd)
# Safety: reads templates/common/trunk-refactor.SKILL.md, templates/common/trunk-refactor-seed.sh.tftpl,
#         both main.tf twins, both startup.sh.tftpl twins, scripts/lib/{template-push.sh,
#         startup_size.awk}, the .grok/ link and rules file, the flags
#         example, the docs page and docs-site/lib/nav.json; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SKILL=""
SEED=""
SKILL_LINK=""
RULES=""
FLAGS_EXAMPLE=""
DOC_PAGE=""
NAV_JSON=""

# The docs page by its docs-relative spelling, which is how nav.json names it too.
DOC_PATH="workflows/trunk-feature-flags-refactor.md"

# The six phases, in the order the procedure runs them. A phase that is renamed or
# dropped silently shortens the workflow, so the claim is the ordered list.
PHASES=(
  "Phase 0 - Inventory"
  "Phase 1 - Establish the trunk-based rules in writing"
  "Phase 2 - Environments without environment branches"
  "Phase 3 - Lightweight feature flags"
  "Phase 4 - Branch cleanup and feature preservation"
  "Phase 5 - Verify and polish"
)

# The flag ladder in preference order. The order is the contract: the run that reaches for
# a flag service before it has tried an env var is the failure this pins out.
LADDER=(
  "Environment variable plus dotenv sample"
  "Compose \`profiles:\`"
  "A checked-in \`flags.yaml\`"
  "The platform's own parameter surface"
)

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  SKILL="${REPO_ROOT}/templates/common/trunk-refactor.SKILL.md"
  SEED="${REPO_ROOT}/templates/common/trunk-refactor-seed.sh.tftpl"
  SKILL_LINK="${REPO_ROOT}/.grok/skills/trunk-refactor/SKILL.md"
  RULES="${REPO_ROOT}/.grok/rules/trunk-feature-flags.md"
  FLAGS_EXAMPLE="${REPO_ROOT}/config/flags.yaml.example"
  DOC_PAGE="${REPO_ROOT}/docs/${DOC_PATH}"
  NAV_JSON="${REPO_ROOT}/docs-site/lib/nav.json"
}

# criteria_items <file> - print the Ideal State Criteria block, from its heading to the
# next level-2 heading. The count and the per-item checks both run against this slice so a
# numbered list elsewhere in the body cannot satisfy them.
criteria_items() {
  awk '/^## Ideal State Criteria$/ { on = 1; next }
       on && /^## / { exit }
       on { print }' "${1}"
}

@test "trunk_refactor_skill: the canonical body and the repo-tier link are one file" {
  [[ -f "${SKILL}" ]] || {
    echo "missing ${SKILL}" >&2
    return 1
  }
  [[ -L "${SKILL_LINK}" ]] || {
    echo "${SKILL_LINK} is not a symlink, so the body is duplicated and free to drift" >&2
    return 1
  }
  # readlink -f resolves both sides, so the claim is one source of truth rather than two
  # copies that agree today. Under a runfiles tree the chain walks out to the real checkout,
  # so the aim is matched on its templates/common/ tail rather than on an absolute path, and
  # cmp proves the bytes are the payload's - a link aimed at the wrong sibling breaks here.
  local target
  target="$(readlink -f "${SKILL_LINK}")"
  case "${target}" in
    */templates/common/trunk-refactor.SKILL.md) ;;
    *)
      echo "${SKILL_LINK} resolves to ${target}, not to the templates/common/trunk-refactor.SKILL.md body" >&2
      return 1
      ;;
  esac
  cmp -s "${SKILL_LINK}" "${SKILL}" || {
    echo "${SKILL_LINK} does not carry the bytes of ${SKILL}" >&2
    return 1
  }
}

@test "trunk_refactor_skill: frontmatter names the skill and sells it well enough to fire" {
  local name description
  name="$(sed -n 's/^name: //p' "${SKILL}" | head -n 1)"
  description="$(sed -n 's/^description: //p' "${SKILL}" | head -n 1)"
  # Discovery keys off the folder name, so a mismatch registers the skill under a name no
  # citation in AGENTS.md or the rules file uses.
  [[ "${name}" == "trunk-refactor" ]]
  # The description is what the model matches on; a short one never fires. It also has to
  # carry the slash command the docs tell a person to type.
  [[ ${#description} -gt 200 ]]
  [[ "${description}" == *"/trunk-refactor"* ]]
}

@test "trunk_refactor_skill: the body runs all six phases in order" {
  local phase seen=0 last=0 line
  for phase in "${PHASES[@]}"; do
    line="$(grep -n -F -m 1 "## ${phase}" "${SKILL}" | cut -d: -f1)"
    [[ -n "${line}" ]] || {
      echo "no heading for '## ${phase}'" >&2
      return 1
    }
    ((line > last)) || {
      echo "'${phase}' sits out of order (line ${line} after ${last})" >&2
      return 1
    }
    last="${line}"
    ((seen += 1))
  done
  [[ ${seen} -eq 6 ]]
}

@test "trunk_refactor_skill: twelve criteria and every one carries a proof" {
  local block items proved
  block="$(criteria_items "${SKILL}")"
  [[ -n "${block}" ]] || {
    echo "no '## Ideal State Criteria' block" >&2
    return 1
  }
  items="$(printf '%s\n' "${block}" | grep -cE '^[0-9]+\. \*\*')"
  [[ ${items} -eq 12 ]] || {
    echo "expected 12 criteria, found ${items}" >&2
    return 1
  }
  # A criterion without a command is an opinion. Every item has to name something to run,
  # which is what makes the final report's proof column fillable. The count is per item,
  # not per line: an item wraps, and its command usually lands on the second line.
  proved="$(printf '%s\n' "${block}" |
    awk '/^[0-9]+\. \*\*/ { if (seen && has) good++; seen = 1; has = 0 }
         index($0, "`") > 0 { has = 1 }
         END { if (seen && has) good++; print good + 0 }')"
  [[ ${proved} -eq 12 ]] || {
    echo "only ${proved} of 12 criteria cite a command" >&2
    return 1
  }
}

@test "trunk_refactor_skill: the flag ladder stays cheap-first" {
  local rung found
  for rung in "${LADDER[@]}"; do
    found="$(grep -F -m 1 -- "${rung}" "${SKILL}" || true)"
    [[ -n "${found}" ]] || {
      echo "the ladder lost '${rung}'" >&2
      return 1
    }
  done
  # The anti-default, stated where a reader would otherwise skip it.
  grep -qE 'flag service' "${SKILL}"
}

@test "trunk_refactor_skill: the always-loaded rules carry the constraints and cite the body" {
  [[ -f "${RULES}" ]] || {
    echo "missing ${RULES}: the constraints load only when asked" >&2
    return 1
  }
  # The rules file is the copy that reaches a session without being asked for, so it is
  # the one that has to name where the full procedure lives: the templates/common/ body,
  # which is the only tracked copy now that skills/trunk-refactor/ is gone.
  grep -qF -- 'templates/common/trunk-refactor.SKILL.md' "${RULES}" || {
    echo "the rules file does not point at the skill body" >&2
    return 1
  }
  grep -q "docs/${DOC_PATH}" "${RULES}" || {
    echo "the rules file does not point at the docs twin" >&2
    return 1
  }
  # The two constraints an agent is most likely to violate under momentum.
  grep -qiE 'never (force-push|delete a remote branch)' "${RULES}"
  # Branch timing is the third: an agent that works first and reaches for git at
  # the end leaves the change uncommitted on trunk, so the rules file has to say
  # the branch comes before the edit and the push comes after the pull request.
  grep -qiE 'before the first edit' "${RULES}"
  grep -qiE 'defaults off|default.*off' "${RULES}"
  # And the prose twin has to lead a reader to both the body and the payload it copies.
  grep -qF -- 'templates/common/trunk-refactor.SKILL.md' "${DOC_PAGE}"
  # The body reaches a repository through the tracked link the repository-tier seed writes,
  # so the page that tells a person how to install it has to name that link.
  grep -qF -- '.grok/skills/trunk-refactor/SKILL.md' "${DOC_PAGE}"
  grep -qF -- 'config/flags.yaml.example' "${DOC_PAGE}"
}

@test "trunk_refactor_skill: the flags example parses and carries its schema" {
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  python3 - "${FLAGS_EXAMPLE}" <<'TRUNK_FLAGS_CHECK'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

if not isinstance(doc, dict):
    raise SystemExit(f"{path}: expected a mapping at the top level")
if doc.get("version") != 1:
    raise SystemExit(f"{path}: version must be 1, got {doc.get('version')!r}")

flags = doc.get("flags")
if not isinstance(flags, dict) or not flags:
    raise SystemExit(f"{path}: flags must be a non-empty mapping")

required = ("default", "owner", "description", "expires", "environments")
for name, body in flags.items():
    if not name.startswith("FEATURE_"):
        raise SystemExit(f"{path}: {name} should follow the FEATURE_ convention")
    if not isinstance(body, dict):
        raise SystemExit(f"{path}: flag {name} is not a mapping")
    missing = [key for key in required if key not in body]
    if missing:
        raise SystemExit(f"{path}: flag {name} is missing {', '.join(missing)}")
    if body["default"] is not False:
        raise SystemExit(f"{path}: flag {name} must default off on the trunk")

stacks = doc.get("stacks") or {}
if not isinstance(stacks, dict):
    raise SystemExit(f"{path}: stacks must be a mapping")
for stack, overrides in stacks.items():
    for name in overrides or {}:
        if name not in flags:
            raise SystemExit(f"{path}: stacks.{stack} overrides undeclared flag {name}")
TRUNK_FLAGS_CHECK
}

@test "trunk_refactor_skill: the docs twin is navigable and titles itself" {
  [[ -f "${DOC_PAGE}" ]] || {
    echo "missing ${DOC_PAGE}" >&2
    return 1
  }
  [[ -f "${NAV_JSON}" ]] || skip "docs-site/lib/nav.json is not generated in this runfiles set"
  # An undeclared page is invisible to a reader, and the docs contract test is the one that
  # usually says so; the citation is checked here so this suite fails on its own claim too.
  grep -q "\"${DOC_PATH}\"" "${NAV_JSON}" || {
    echo "${DOC_PATH} is not declared in nav.json; run bazelisk run //docs:nav" >&2
    return 1
  }
  local title heading
  title="$(sed -n 's/^title: //p' "${DOC_PAGE}" | head -n 1)"
  heading="$(grep -m 1 '^# ' "${DOC_PAGE}" | sed 's/^# //')"
  # The site prints one and indexes the other, so a drift is a page with two names.
  [[ -n "${title}" && "${title}" == "${heading}" ]]
}

# ------------------------------------------------------------------ the seed body
#
# The split these tests police: this payload left templates/common/
# stack-repo-skills.sh.tftpl for a coder_script of its own, because the agent execs every
# body as one execve argument and that family clears the ceiling only once this payload
# rides a second argument (docs/coder-templates.md#the-one-argument-ceiling). A payload
# that stopped being seeded, a write that lost its absent guard, or a twin that grew its
# own here-doc all show up here rather than as a workspace that boots with no
# /trunk-refactor.

# hdoc_open -- print the two characters that open a here-document. Built from two halves
# on purpose: bats' preprocessor reads that digraph inside a needle as the opener of a
# real here-document and swallows every line below it.
hdoc_open() {
  printf '%s%s' '<' '<'
}

# main_block <main.tf> <resource type> <resource name> -- print one resource block, from
# its header to the brace that closes it at column zero.
main_block() {
  awk -v type="${2}" -v name="${3}" '
    $0 ~ "^resource \"" type "\" \"" name "\" \\{" { on = 1 }
    on { print }
    on && /^\}/ { exit }
  ' "${1}"
}

@test "trunk_refactor_seed: the coder copy is written only while absent, from one quoted here-doc fed by the payload key" {
  [[ -f "${SEED}" ]] || {
    echo "missing ${SEED}: nothing seeds /trunk-refactor into a workspace" >&2
    return 1
  }
  # Absent-only is the takeover contract: a file that already exists belongs to the
  # person who put it there, so a write that lost its guard silently rewrites their edit.
  # The guard, the directory and the write all have to be there: mkdir is what makes the
  # skills/<name>/ path exist for the copy.
  assert_contains_file "the coder write is guarded on absence" "${SEED}" \
    '^if \[ ! -f "\$HOME/\.coder/skills/trunk-refactor/SKILL\.md" \]; then$'
  assert_contains_file "the coder directory is made for it" "${SEED}" \
    'mkdir -p "\$HOME/\.coder/skills/trunk-refactor" 2>/dev/null'
  assert_contains_file "the coder copy is a cat into a here-doc" "${SEED}" \
    'cat >"\$HOME/\.coder/skills/trunk-refactor/SKILL\.md" '"$(hdoc_open)"
  assert_contains_file "and the guard's else branch leaves the operator's file alone" "${SEED}" \
    'boot_note "trunk-refactor SKILL\.md is the operator'
  # Two separate failures hide in the delimiter. An UNQUOTED one lets the shell expand the
  # $-text the payload is made of while the boot runs, so the seeded file is not the
  # payload; and a tag that is not exactly twice in the file (opener, plus the closer alone
  # on its line) is a here-doc that never terminates, so the boot swallows the rest of the
  # body and the workspace comes up with a truncated script.
  local n
  n="$(grep -cF -- "TRUNK_REFACTOR_SKILL_MD_EOF" "${SEED}" || true)"
  assert_eq "the tag appears exactly twice (opener + closer)" "2" "${n}"
  n="$(grep -cF -- "$(hdoc_open)'TRUNK_REFACTOR_SKILL_MD_EOF'" "${SEED}" || true)"
  assert_eq "the tag opens quoted exactly once" "1" "${n}"
  n="$(grep -cFx -- "TRUNK_REFACTOR_SKILL_MD_EOF" "${SEED}" || true)"
  assert_eq "the tag closes alone on its own line" "1" "${n}"
  # A here-doc that quietly stopped receiving its payload still has a legal opener and
  # closer, so the tag checks above pass vacuously: pin the line right after the opener to
  # the map key main.tf is required to fill, or the file that lands is empty.
  local after
  after="$(grep -A 1 -F -- "$(hdoc_open)'TRUNK_REFACTOR_SKILL_MD_EOF'" "${SEED}" | tail -n 1)"
  assert_eq "the here-doc is fed by the trunk_refactor_skill interpolation" \
    '${trunk_refactor_skill}' "${after}"
}

@test "trunk_refactor_seed: the agents copy is a cp of the managed coder copy, never a second here-doc" {
  # The two homes are two consumers of ONE file: the ~/.coder copy is what the Coder Agents
  # chat reads and the ~/.agents copy what the Grok Build CLI reads. If the agents side
  # grew its own body the two drift the moment one is edited, and first-match-wins dedupe
  # decides which of the two the CLI actually runs.
  assert_contains_file "the agents write is guarded on absence" "${SEED}" \
    '^if \[ ! -f "\$HOME/\.agents/skills/trunk-refactor/SKILL\.md" \]; then$'
  assert_contains_file "the agents directory is made for it" "${SEED}" \
    'mkdir -p "\$HOME/\.agents/skills/trunk-refactor" 2>/dev/null'
  assert_contains_file "the twin copies the managed coder copy" "${SEED}" \
    'cp "\$HOME/\.coder/skills/trunk-refactor/SKILL\.md" \\'
  assert_contains_file "and lands it in the agents home" "${SEED}" \
    '"\$HOME/\.agents/skills/trunk-refactor/SKILL\.md" 2>/dev/null'
  local n
  n="$(grep -cF -- 'cat >"$HOME/.agents/skills/' "${SEED}" || true)"
  assert_eq "the agents side never gets its own here-doc" "0" "${n}"
  n="$(grep -cE -- "$(hdoc_open)'[A-Z_]+_EOF'" "${SEED}" || true)"
  assert_eq "the body holds exactly one quoted here-doc" "1" "${n}"
  # Both writes, and only both writes: a third skills path in this body would be a payload
  # nobody's reseed list carries.
  n="$(grep -cE '^if \[ ! -f "\$HOME/\.(coder|agents)/skills/' "${SEED}" || true)"
  assert_eq "both writes sit behind their own absent guard" "2" "${n}"
  # The twin cp runs with its errors quieted, so the outcome is read back rather than
  # trusted: an artifact missing from either home is a seed that failed quietly.
  assert_contains_file "the coder copy is read back" "${SEED}" \
    '\[ -f "\$HOME/\.coder/skills/\$f" \] \|\| boot_warn "no coder copy of \$f"'
  assert_contains_file "and so is the agents twin" "${SEED}" \
    '\[ -f "\$HOME/\.agents/skills/\$f" \] \|\| boot_warn "no agents twin of \$f"'
}

@test "trunk_refactor_seed: it is a POSIX sh body that reads exactly its two map keys and narrates its own boot" {
  # Coder runs the body through sh, not bash, and the agent receives it as one execve
  # argument: a bashism is a script that dies at boot, and a stray CR or non-ASCII byte
  # reaches every workspace of both templates as text a byte-wise comparison reads as a
  # different file.
  assert_eq "it opens with a shebang" '#!/bin/sh' "$(head -n 1 "${SEED}")"
  assert_eq "it closes with a successful exit" 'exit 0' "$(tail -n 1 "${SEED}")"
  sh -n "${SEED}"
  local stray n_cr
  stray="$(tr -d '\0-\177' <"${SEED}" | wc -c | tr -d ' ')"
  [[ "${stray}" -eq 0 ]] || {
    printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${SEED}" "${stray}" >&2
    LC_ALL=C grep -n '[^ -~]' "${SEED}" >&2
    return 1
  }
  n_cr="$(grep -c $'\r' "${SEED}" || true)"
  assert_eq "the seed body carries no carriage return" "0" "${n_cr}"
  # The map carries exactly two keys: the payload and the boot logger. A third would be a
  # payload main.tf feeds that nothing reads, and a name the push guard cannot match.
  local got want
  want='${boot_log_lib}
${trunk_refactor_skill}'
  got="$(grep -oE '\$\{[a-z_]+\}' "${SEED}" | sort -u)"
  assert_eq "the body reads its payload key and the boot logger, nothing else" \
    "${want}" "${got}"
  assert_eq "and each key is interpolated exactly once" "2" \
    "$(grep -cE '^\$\{[a-z_]+\}$' "${SEED}" || true)"
  # The logger has to be the first thing the shell reads: a logger defined below the first
  # command narrates nothing about the part of the boot an operator asks about.
  local first_cmd
  first_cmd="$(awk '
    $0 == "set -u" { on = 1; next }
    on && /^[[:space:]]*$/ { next }
    on && /^#/ { next }
    on { print; exit }
  ' "${SEED}")"
  assert_eq "the boot logger is the first thing the shell reads after the option line" \
    '${boot_log_lib}' "${first_cmd}"
  # One begin, one stage, one summary: the shape of the start log an operator reads when
  # this seed is the part that went quiet.
  local verb
  for verb in boot_begin boot_stage boot_summary; do
    assert_eq "${verb} is called exactly once" "1" \
      "$(grep -cE "^[[:space:]]*${verb}([[:space:]]|$)" "${SEED}" || true)"
  done
}

@test "trunk_refactor_seed: both main.tf twins declare the block and feed it its two keys" {
  # A coder_script with no count runs on every plan; with no run_on_start the command only
  # appears after a manual start, so a freshly started workspace has none to find.
  local twin block agent
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(main_block "${twin}/main.tf" coder_script trunk_refactor_command)"
    [[ -n "${block}" ]] || {
      echo "${twin}/main.tf has no coder_script trunk_refactor_command block" >&2
      return 1
    }
    assert_match "${twin} gates the seed on start_count" \
      'count[[:space:]]+=[[:space:]]+data\.coder_workspace\.me\.start_count' "${block}"
    assert_match "${twin} targets the main agent" \
      'agent_id[[:space:]]+=[[:space:]]+coder_agent\.main\.id' "${block}"
    assert_match "${twin} says which command it seeds" \
      'display_name[[:space:]]+=[[:space:]]+"Seed the repository conversion command"' "${block}"
    assert_match "${twin} gives it the code icon" \
      'icon[[:space:]]+=[[:space:]]+"/icon/code\.svg"' "${block}"
    assert_match "${twin} runs it on start" \
      'run_on_start[[:space:]]+=[[:space:]]+true' "${block}"
    assert_match "${twin} renders the body of its own" \
      'script[[:space:]]+=[[:space:]]+templatefile\("\$\{path\.module\}/trunk-refactor-seed\.sh\.tftpl"' "${block}"
    assert_eq "${twin} declares the block exactly once" "1" \
      "$(grep -cF -- 'coder_script" "trunk_refactor_command"' "${twin}/main.tf" || true)"
    # chomp: the here-doc closes on its own line, so a trailing newline in the payload
    # lands as a blank line in the seeded file. In-block placement: both byte readers
    # credit a body by the path.module names inside its own block, so a key hoisted behind
    # a local stops being measured while still travelling in the argument.
    assert_match "${twin} chomps the boot logger into the block" \
      'boot_log_lib[[:space:]]+=[[:space:]]+chomp\(file\("\$\{path\.module\}/boot-log\.lib\.sh"\)\)' \
      "${block}"
    assert_match "${twin} chomps the payload into the block" \
      'trunk_refactor_skill[[:space:]]+=[[:space:]]+chomp\(file\("\$\{path\.module\}/trunk-refactor\.SKILL\.md"\)\)' \
      "${block}"
    assert_eq "${twin} feeds trunk_refactor_skill exactly once" "1" \
      "$(grep -cF -- 'trunk_refactor_skill' "${twin}/main.tf" || true)"
    # And not back in the agent's own startup map, which is the argument this split exists
    # to keep room in.
    agent="$(main_block "${twin}/main.tf" coder_agent main)"
    if printf '%s' "${agent}" | grep -Fq -- 'trunk_refactor'; then
      echo "${twin}/main.tf still inlines trunk-refactor into coder_agent.main startup_script" >&2
      return 1
    fi
  done
}

@test "trunk_refactor_seed: the size reader measures the body, the push guard names it, and neither startup twin carries it" {
  # startup_size.awk is what the push reads to refuse an argument past the ceiling before
  # a workspace ever boots, so a body it emits no record for is a body nobody measures.
  # Three records per twin: the body, the logger main.tf hands it, the payload.
  local twin tab out want name
  tab="$(printf '\t')"
  [[ -f "${REPO_ROOT}/scripts/lib/startup_size.awk" ]] || {
    echo "startup_size.awk is not reachable under ${REPO_ROOT}/scripts/lib" >&2
    return 1
  }
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    out="$(awk -f "${REPO_ROOT}/scripts/lib/startup_size.awk" "${twin}/main.tf")"
    for want in trunk-refactor-seed.sh.tftpl boot-log.lib.sh trunk-refactor.SKILL.md; do
      assert_match "${twin} measures ${want} inside the trunk-refactor body" \
        "^trunk-refactor-seed\.sh\.tftpl${tab}${want//./\\.}\$" "${out}"
    done
    assert_eq "${twin} emits exactly three records for the body" "3" \
      "$(printf '%s\n' "${out}" | grep -c "^trunk-refactor-seed\.sh\.tftpl${tab}" || true)"
    # A body this reader cannot name is one it cannot size.
    assert_not_match "${twin} never reports the body as unmeasurable" \
      "^trunk-refactor-seed\.sh\.tftpl${tab}(HEREDOC|OTHER|CLASH)\$" "${out}"
    # The body buys a second ceiling; nothing of its may drift back into the shared one.
    for name in trunk-refactor.SKILL.md trunk-refactor-seed.sh.tftpl \
      trunk_refactor_skill trunk_refactor_command; do
      assert_eq "${twin}/startup.sh.tftpl never mentions ${name}" "0" \
        "$(grep -cF -- "${name}" "${twin}/startup.sh.tftpl" || true)"
    done
  done
  # main.tf reads both files out of the pushed copy, so a push that shipped without either
  # renders a template that fails to plan on every workspace made from it afterwards.
  local pushlib guard got missing=""
  pushlib="${REPO_ROOT}/scripts/lib/template-push.sh"
  [[ -f "${pushlib}" ]] || {
    echo "no template-push lib under ${REPO_ROOT}/scripts/lib" >&2
    return 1
  }
  guard="$(awk '/^  for payload in \\/ { on = 1; next } on && /^  done$/ { exit } on { print }' "${pushlib}")"
  [[ -n "${guard}" ]] || {
    printf 'FAIL: %s has no payload guard loop\n' "${pushlib}" >&2
    return 1
  }
  # Split on whitespace and the list terminator rather than deleting them, so the last item
  # (the one carrying `; do`) stays one token.
  got="$(printf '%s\n' "${guard}" | tr ' \t;' '\n' | tr -d '\\' | sed '/^$/d' | sort -u)"
  for name in trunk-refactor.SKILL.md trunk-refactor-seed.sh.tftpl; do
    printf '%s\n' "${got}" | grep -qxF -- "${name}" || missing="${missing}${name}"$'\n'
  done
  [[ -z "${missing}" ]] || {
    printf 'FAIL: the push guard in %s does not list:\n%s' "${pushlib}" "${missing}" >&2
    return 1
  }
}
