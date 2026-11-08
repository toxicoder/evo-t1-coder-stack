#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## trunk-refactor-skill.bats - the trunk + flags skill stays whole, linked, and loadable.
#
# The repo ships one reusable procedure for converting a repository onto trunk-based
# development with lightweight flags: skills/trunk-refactor/SKILL.md is the canonical
# body, .grok/skills/trunk-refactor/SKILL.md is the symlink that makes it a repo-tier
# skill the CLI discovers, .grok/rules/trunk-feature-flags.md is the always-loaded
# constraint set, docs/workflows/trunk-feature-flags-refactor.md is the prose twin, and
# config/flags.yaml.example is the payload the procedure copies into a repo that has
# outgrown bare env vars.
#
# Each of those five files fails in a way nothing else notices. A truncated paste loses a
# phase or a criterion and the skill still loads; a broken symlink leaves /trunk-refactor
# undiscoverable while the body reads fine; an unquoted or drifted frontmatter title fails
# only the npm docs gate; and the flags sample is parsed by NO gate at all, because
# scripts/validate.sh names its YAML files rather than globbing config/. This suite is the
# completeness gate for that set: the body's structure, the link's target, the sample's
# schema (including that every stacks.<stack> override names a declared flag), and the
# citations the always-loaded rules and the generated navigation make.
#
# Usage: bazelisk test //tests:bats_trunk_refactor_skill_test   (from any cwd)
# Safety: reads skills/trunk-refactor/SKILL.md, the .grok/ link and rules file, the flags
#         example, the docs page and docs-site/lib/nav.json; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SKILL=""
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
  SKILL="${REPO_ROOT}/skills/trunk-refactor/SKILL.md"
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
  # copies that agree today.
  [[ "$(readlink -f "${SKILL_LINK}")" == "$(readlink -f "${SKILL}")" ]]
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
  # the one that has to name where the full procedure lives.
  grep -q 'skills/trunk-refactor/SKILL.md' "${RULES}" || {
    echo "the rules file does not point at the skill body" >&2
    return 1
  }
  grep -q "docs/${DOC_PATH}" "${RULES}" || {
    echo "the rules file does not point at the docs twin" >&2
    return 1
  }
  # The two constraints an agent is most likely to violate under momentum.
  grep -qiE 'never (force-push|delete a remote branch)' "${RULES}"
  grep -qiE 'defaults off|default.*off' "${RULES}"
  # And the prose twin has to lead a reader to both the body and the payload it copies.
  grep -q 'skills/trunk-refactor/SKILL.md' "${DOC_PAGE}"
  grep -q 'config/flags.yaml.example' "${DOC_PAGE}"
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
