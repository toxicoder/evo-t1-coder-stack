#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## fleet-agents.bats - the fleet family's own wiring gate.
#
# The suite is thirteen payloads in templates/common/ and one coder_script that
# carries them: six agent definitions (*.AGENT.md) that become ~/.grok/agents/,
# three persona overlays (*.PERSONA.toml) that become ~/.grok/personas/, and four
# parent-side skills (*.SKILL.md) that become a SKILL.md in each of the two skill
# homes. All thirteen are interpolated into templates/common/stack-fleet.sh.tftpl
# by the coder_script "stack_fleet" block in both main.tf twins, listed in
# scripts/lib/template-push.sh's payload loop, and named per home in
# seed_seed_targets() in scripts/lib/config_seed.sh. The repo tier reaches the
# same bytes through symlinks under .grok/agents/, .grok/personas/ and
# .grok/skills/.
#
# Each of those seams fails silently. A frontmatter key the CLI does not document
# is read as nothing; a model: value that names a cloud id or an alias
# litellm/config.yaml never serves fails only when a parent spawns that role; a
# persona whose TOML does not parse is not an error at boot, the persona is just
# absent from the catalog; a payload dropped from the push loop breaks every
# template push with a message that names the missing file and nothing else; a
# home path dropped from seed_seed_targets leaves a workspace that missed a boot
# permanently short of that file; and a payload whose interpolation key stops
# being measured by scripts/lib/startup_size.awk rides the execve argument while
# the ceiling guard cannot see it, which surfaces as "A startup script has
# failed" instead of as a failed push.
#
# The four skills' own file format, their main.tf feed and their per-payload
# measurement are also pinned by tests/bats/ez-skill-authoring.bats, whose
# FLEET_SKILLS list covers the quartet. Nothing here re-states a claim that
# belongs to that suite: the shape of a SKILL.md is not re-checked here, and the
# two-home write is checked here because that suite's two-home loop covers only
# the ez- trio. The nine definitions and overlays are covered in full: no other
# gate opens them.
#
# Usage: bazelisk test //tests:bats_fleet_agents_test   (from any cwd)
# Safety: reads templates/common/{*.AGENT.md,*.PERSONA.toml, the four fleet
# SKILL.md,stack-fleet.sh.tftpl}, both main.tf twins,
# scripts/lib/{template-push.sh,config_seed.sh,startup_size.awk}, the LiteLLM
# config, and the repo-tier links under .grok/. Writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
COMMON=""
SEED=""
PUSH=""
CONFIG_SEED=""
LITELLM=""
SIZE_AWK=""

# The six definitions, in the order the rulebook lists them, with the map key and
# the here-doc tag each one travels under in the fleet body.
AGENTS=(explorer architect implementer tester reviewer security-auditor)
AGENT_KEYS=(explorer_agent architect_agent implementer_agent tester_agent
  reviewer_agent security_auditor_agent)
AGENT_TAGS=(EXPLORER_AGENT_EOF ARCHITECT_AGENT_EOF IMPLEMENTER_AGENT_EOF
  TESTER_AGENT_EOF REVIEWER_AGENT_EOF SECURITY_AUDITOR_AGENT_EOF)

# The three overlays. The file stem IS the persona name: file-based personas are
# discovered by file name (16-subagents.md), so a renamed file is a renamed
# persona, not a renamed field.
PERSONAS=(thorough-researcher senior-implementer skeptical-reviewer)
PERSONA_KEYS=(thorough_researcher_persona senior_implementer_persona
  skeptical_reviewer_persona)
PERSONA_TAGS=(THOROUGH_RESEARCHER_PERSONA_EOF SENIOR_IMPLEMENTER_PERSONA_EOF
  SKEPTICAL_REVIEWER_PERSONA_EOF)

# The four parent-side skills.
SKILLS=(feature-implementation skeptical-review security-audit bug-hunt)
SKILL_KEYS=(feature_implementation_skill skeptical_review_skill
  security_audit_skill bug_hunt_skill)

# The whole local roster, which is the alias table litellm/config.yaml serves.
# There is no cloud transport in this stack, so a value outside this list is
# either a typo or a regression to a provider the routing arithmetic has no box
# for (docs/litellm-routing.md).
LOCAL_ROSTER=(agent agent-low agent-medium agent-xhigh agent-swarm
  agent-explore agent-review coder coder-fast chat spark-coder spark-chat)

# The definition parser: structure only. Reads the payload on stdin, its stem in
# argv[1]. The six frontmatter keys are pinned as the exact set inside the parser:
# they are what the subagent guide documents, and a key outside them is
# configuration the CLI reads as nothing while it looks like configuration to the
# next reader of the file.
AGENT_FM_PROG='
import sys, yaml
stem = sys.argv[1]
path = "%s.AGENT.md" % stem
lines = sys.stdin.read().splitlines()
if not lines or lines[0].strip() != "---":
    sys.exit("FAIL: %s does not open its frontmatter with --- on line 1" % path)
close = 0
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        close = i
        break
if close == 0:
    sys.exit("FAIL: %s has no closing frontmatter fence" % path)
try:
    data = yaml.safe_load("\n".join(lines[1:close]))
except yaml.YAMLError as exc:
    sys.exit("FAIL: %s frontmatter is not valid YAML: %s" % (path, exc))
if not isinstance(data, dict):
    sys.exit("FAIL: %s frontmatter is not a mapping: %r" % (path, data))
allowed = set(("name", "description", "model", "tools", "permissionMode",
               "mcpInheritance"))
extra = sorted(set(data) - allowed)
if extra:
    sys.exit("FAIL: %s carries keys outside the documented six: %s"
             % (path, ", ".join(extra)))
absent = sorted(allowed - set(data))
if absent:
    sys.exit("FAIL: %s is missing documented key(s): %s" % (path, ", ".join(absent)))
if data.get("name") != stem:
    sys.exit("FAIL: %s: name must equal the file'"'"'s own stem %r, got %r"
             % (path, stem, data.get("name")))
desc = data.get("description")
if not isinstance(desc, str) or not desc.strip():
    sys.exit("FAIL: %s: description must be a non-empty string, got %r" % (path, desc))
tools = data.get("tools")
if not isinstance(tools, str) or not tools.strip():
    sys.exit("FAIL: %s: tools must be a non-empty comma list, got %r" % (path, tools))
named = [t.strip() for t in tools.split(",") if t.strip()]
if not named:
    sys.exit("FAIL: %s: tools lists no tool name" % path)
if any(not t.replace("_", "").isalnum() for t in named):
    sys.exit("FAIL: %s: tools carries a name that is not an identifier: %r" % (path, tools))
'

# The definition value parser: the two keys whose value domain the guide fixes,
# plus the one cross-rule the payloads themselves state -- a definition whose
# tools name no MCP tool has nothing to inherit, so it must say none.
AGENT_VALUES_PROG='
import sys, yaml
stem = sys.argv[1]
path = "%s.AGENT.md" % stem
lines = sys.stdin.read().splitlines()
close = 0
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        close = i
        break
if close == 0:
    sys.exit("FAIL: %s has no closing frontmatter fence" % path)
data = yaml.safe_load("\n".join(lines[1:close]))
modes = set(("default", "auto", "plan", "bypassPermissions"))
mode = data.get("permissionMode")
if mode not in modes:
    sys.exit("FAIL: %s: permissionMode %r is outside the documented set (%s)"
             % (path, mode, ", ".join(sorted(modes))))
inherit = data.get("mcpInheritance")
if isinstance(inherit, str):
    if inherit not in ("all", "none"):
        sys.exit("FAIL: %s: mcpInheritance %r must be all or none" % (path, inherit))
elif isinstance(inherit, dict):
    if len(inherit) != 1 or sorted(inherit)[0] not in ("named", "except"):
        sys.exit("FAIL: %s: mapping mcpInheritance must carry one of named/except, got %r"
                 % (path, inherit))
else:
    sys.exit("FAIL: %s: mcpInheritance must be a scalar or a mapping, got %r"
             % (path, inherit))
tools = [t.strip() for t in str(data.get("tools")).split(",") if t.strip()]
mcp = [t for t in tools if t in ("search_tool", "use_tool")]
if not mcp and inherit != "none":
    sys.exit("FAIL: %s: tools names no MCP tool, so mcpInheritance must be none, got %r"
             % (path, inherit))
if mcp and inherit == "none":
    sys.exit("FAIL: %s: tools names %s but mcpInheritance is none, so those calls can never "
             "resolve" % (path, ", ".join(mcp)))
'

# The model parser: the definition's model: has to be both a local alias and a
# group the proxy actually serves. A typo here is not a boot failure -- the child
# simply never spawns, with the error surfacing in whoever tried to fan out.
AGENT_MODEL_PROG='
import sys, yaml
stem = sys.argv[1]
path = "%s.AGENT.md" % stem
roster = set(sys.argv[2].split(","))
lines = sys.stdin.read().splitlines()
close = 0
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        close = i
        break
if close == 0:
    sys.exit("FAIL: %s has no closing frontmatter fence" % path)
data = yaml.safe_load("\n".join(lines[1:close]))
model = data.get("model")
if not isinstance(model, str) or not model.strip():
    sys.exit("FAIL: %s: model must be a non-empty string, got %r" % (path, model))
if model not in roster:
    sys.exit("FAIL: %s: model %r is not one of the local aliases %s"
             % (path, model, ", ".join(sorted(roster))))
served = {e.get("model_name") for e in yaml.safe_load(open(sys.argv[3]))["model_list"]}
if model not in served:
    sys.exit("FAIL: %s: model %r is not a model_name: the proxy serves (%s)"
             % (path, model, ", ".join(sorted(str(s) for s in served))))
'

# The overlay parser. A persona file that does not parse is not a boot error --
# the persona is silently absent from the catalog -- so this is the only place
# that claim is checked. A persona is an overlay: it shapes tone and output and
# never names tools, which belong to the agent definition it layers onto.
PERSONA_PROG='
import sys, tomllib
stem = sys.argv[1]
path = "%s.PERSONA.toml" % stem
try:
    data = tomllib.load(sys.stdin.buffer)
except Exception as exc:
    sys.exit("FAIL: %s does not parse as TOML: %s" % (path, exc))
if not isinstance(data, dict):
    sys.exit("FAIL: %s is not a TOML table at top level: %r" % (path, data))
allowed = set(("instructions", "instructions_file", "description", "inputs",
               "outputs", "model", "reasoning_effort", "default_isolation"))
extra = sorted(set(data) - allowed)
if extra:
    sys.exit("FAIL: %s carries fields outside the documented set: %s"
             % (path, ", ".join(extra)))
if "tools" in data:
    sys.exit("FAIL: %s names tools, which an overlay must never do -- the agent "
             "definition owns them" % path)
for field in ("description", "instructions"):
    value = data.get(field)
    if not isinstance(value, str) or not value.strip():
        sys.exit("FAIL: %s: %s must be a non-empty string, got %r" % (path, field, value))
if "model" in data and data["model"] not in set(sys.argv[2].split(",")):
    sys.exit("FAIL: %s: model %r is not a local alias" % (path, data["model"]))
if "default_isolation" in data and data["default_isolation"] not in ("none", "worktree"):
    sys.exit("FAIL: %s: default_isolation %r must be none or worktree"
             % (path, data["default_isolation"]))
for field in ("inputs", "outputs"):
    for row in data.get(field, []):
        if not isinstance(row, dict) or not row.get("name"):
            sys.exit("FAIL: %s: %s carries an entry with no name: %r" % (path, field, row))
'

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" ||
    skip "cannot locate the repo root (no docker-compose.yml marker)"
  COMMON="${REPO_ROOT}/templates/common"
  SEED="${COMMON}/stack-fleet.sh.tftpl"
  PUSH="${REPO_ROOT}/scripts/lib/template-push.sh"
  CONFIG_SEED="${REPO_ROOT}/scripts/lib/config_seed.sh"
  LITELLM="${REPO_ROOT}/litellm/config.yaml"
  SIZE_AWK="${REPO_ROOT}/scripts/lib/startup_size.awk"
}

# definition_path <stem> -- the payload for one agent definition.
definition_path() {
  printf '%s' "${COMMON}/${1}.AGENT.md"
}

# overlay_path <stem> -- the payload for one persona overlay.
overlay_path() {
  printf '%s' "${COMMON}/${1}.PERSONA.toml"
}

# skill_path <stem> -- the payload for one fleet skill.
skill_path() {
  printf '%s' "${COMMON}/${1}.SKILL.md"
}

# roster_csv -- the local alias roster as one comma string, for the parsers.
roster_csv() {
  local out="" name
  for name in "${LOCAL_ROSTER[@]}"; do
    out="${out:+${out},}${name}"
  done
  printf '%s' "${out}"
}

# hdoc_open -- the two characters that open a here-document, built from halves:
# bats' preprocessor reads that digraph in a needle as the opener of a real
# here-document and swallows every line below it.
hdoc_open() {
  printf '%s%s' '<' '<'
}

# main_block <main.tf> <resource type> <resource name> -- one resource block, from
# its header to the brace that closes it at column zero.
main_block() {
  awk -v type="${2}" -v name="${3}" '
    $0 ~ "^resource \"" type "\" \"" name "\" \\{" { on = 1 }
    on { print }
    on && /^\}/ { exit }
  ' "${1}"
}

# push_payload_list -- the file names in the payload-presence loop of the push
# lib, one per line, with the continuations and the indent folded. A comment
# naming a payload is not a push, so the loop is extracted rather than the whole
# file grepped.
push_payload_list() {
  awk '
    /for payload in/ { on = 1; next }
    on {
      last = ($0 ~ /; do/)
      gsub(/; do[[:space:]]*$/, "")
      gsub(/[[:space:]]*\\[[:space:]]*$/, "")
      gsub(/^[[:space:]]+/, "")
      gsub(/[[:space:]]+$/, "")
      print
      if (last) { exit }
    }
  ' "${PUSH}"
}

# count_suffix <ext> -- how many payload files of one extension the shared
# template directory holds. -e rather than a -type f test: under a Bazel runfiles
# tree every payload is a symlink into the source, and a type test reads the link
# itself rather than the file it names.
count_suffix() {
  local n=0 candidate
  for candidate in "${COMMON}"/*."${1}"; do
    [[ -e "${candidate}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# The thirteen payloads exist, and the tree holds exactly that set.
# ---------------------------------------------------------------------------

@test "fleet payloads: six definitions, three overlays and four skills ship, and the set is exact" {
  # The count is the claim, not just the set: a payload that was renamed or
  # added without being wired into the push loop, the seed list, or the fleet body
  # is invisible to every boot, and a payload that vanished leaves a home path
  # that nothing fills. The docs name six and three, so six and three is what
  # the fleet family has to hold. The directory carries one more definition than
  # the fleet owns: documenter is the advisor family's, seeded by
  # stack-advisors.sh.tftpl beside the skill that dispatches it, so the whole-tree
  # count is seven and the fleet's own list stays six.
  local i name

  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    assert_file_exists "${name} definition" "$(definition_path "${name}")"
  done
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    assert_file_exists "${name} overlay" "$(overlay_path "${name}")"
  done
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    assert_file_exists "${name} skill" "$(skill_path "${name}")"
  done

  assert_eq "templates/common holds exactly seven *.AGENT.md (the fleet's six plus the advisor's documenter)" "7" "$(count_suffix AGENT.md)"
  assert_eq "templates/common holds exactly three *.PERSONA.toml" "3" "$(count_suffix PERSONA.toml)"

  [[ -f "${SEED}" ]] || {
    printf 'FAIL: %s is missing - it is the coder_script "stack_fleet" body that carries all thirteen payloads\n' \
      "${SEED}" >&2
    return 1; }
}

# ---------------------------------------------------------------------------
# The six agent definitions.
# ---------------------------------------------------------------------------

@test "definitions: line 1 opens the frontmatter, a fence closes it, and the marker sits below the close" {
  # A file whose first line is not --- has no frontmatter at all, so the type is
  # unregistered while the file reads fine. And the marker is provenance, not
  # structure: inside the frontmatter it becomes an undocumented key, and above
  # line 1 it stops being read at all. The seeder's marker probe reads the same
  # string, so a definition that lost it is a copy the boot will not refresh.
  local i f name close marker
  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    f="$(definition_path "${name}")"

    run head -n 1 "${f}"
    assert_eq "${name}.AGENT.md opens the frontmatter on line 1" "---" "${output}"

    close="$(awk 'NR > 2 && /^---[[:space:]]*$/ { print NR; exit }' "${f}")"
    [ -n "${close}" ] || {
      printf 'FAIL: %s has no closing frontmatter fence below line 2\n' "${f}" >&2
      return 1; }

    marker="$(grep -nF 'managed-by: evo-t1-coder-stack' "${f}" | head -n 1 | cut -d: -f1)"
    [ -n "${marker}" ] || {
      printf 'FAIL: %s lost the managed-by marker - the boot stops refreshing this copy\n' \
        "${f}" >&2
      return 1; }
    [ "${marker}" -gt "${close}" ] || {
      printf 'FAIL: %s carries the managed-by marker at line %s, inside the frontmatter that closes at %s\n' \
        "${f}" "${marker}" "${close}" >&2
      return 1; }
  done
}

@test "definitions: the frontmatter carries exactly the six documented keys and name is the file stem" {
  # name is what the parent types and what the seed's file name has to match, so a
  # definition whose name drifted registers a role nobody spawns under the path
  # the boot writes. A key outside the six is read as nothing by the CLI.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  local i
  for i in "${!AGENTS[@]}"; do
    python3 -c "${AGENT_FM_PROG}" "${AGENTS[i]}" <"$(definition_path "${AGENTS[i]}")"
  done
}

@test "definitions: permissionMode and mcpInheritance stay in the documented domain and agree with tools" {
  # permissionMode has four documented values; a fifth is a string the CLI does
  # not recognise and the child runs in whatever mode it falls back to. The
  # cross-rule is the one every payload states in its own comment: an inherited
  # MCP catalog is empty when tools names no MCP tool, so naming none is the
  # honest answer -- and the reverse, tools naming search_tool with mcpInheritance
  # none, is a definition whose stated job cannot be performed.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  local i
  for i in "${!AGENTS[@]}"; do
    python3 -c "${AGENT_VALUES_PROG}" "${AGENTS[i]}" <"$(definition_path "${AGENTS[i]}")"
  done
}

@test "definitions: every model is a local alias the proxy actually serves" {
  # Two failures in one line. An id outside the roster is a cloud model, and this
  # stack has no cloud transport (LiteLLM is the sole one). An alias that
  # litellm/config.yaml stopped serving is a typo or a deleted group, and it does
  # not fail at boot: the spawn simply fails, in the middle of someone's fan-out.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  [[ -f "${LITELLM}" ]] || {
    printf 'FAIL: %s is not in this suite runfiles - the runfiles lost //litellm:config\n' \
      "${LITELLM}" >&2
    return 1; }
  local i
  for i in "${!AGENTS[@]}"; do
    python3 -c "${AGENT_MODEL_PROG}" "${AGENTS[i]}" "$(roster_csv)" "${LITELLM}" \
      <"$(definition_path "${AGENTS[i]}")"
  done
}

@test "fleet payloads: no definition, overlay or skill names a cloud model id" {
  # The prefix set is the family of ids a cloud provider answers to. One of them
  # anywhere in a payload -- frontmatter, prose, or an example -- is a claim that
  # this stack can reach a box it cannot reach, and the alias table is the only
  # transport here.
  local i name f n
  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    f="$(definition_path "${name}")"
    n="$(grep -Eic -- 'grok-|claude-|gpt-|gemini-|llama-|mistral-' "${f}" || true)"
    assert_eq "${name}.AGENT.md names no cloud model id" "0" "${n}"
  done
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    f="$(overlay_path "${name}")"
    n="$(grep -Eic -- 'grok-|claude-|gpt-|gemini-|llama-|mistral-' "${f}" || true)"
    assert_eq "${name}.PERSONA.toml names no cloud model id" "0" "${n}"
  done
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    f="$(skill_path "${name}")"
    n="$(grep -Eic -- 'grok-|claude-|gpt-|gemini-|llama-|mistral-' "${f}" || true)"
    assert_eq "${name}.SKILL.md names no cloud model id" "0" "${n}"
  done
}

@test "fleet payloads: the nine definitions and overlays stay plain ASCII with no CR" {
  # Every consumer reads these as text a parser reads: a curly quote or an en dash
  # survives into the seeded file, reads as mojibake in the child's system prompt,
  # and byte-wise comparisons treat the file as different, which is how a takeover
  # edit becomes a diff that never matches. The quartet's copy of this claim lives
  # in the skill-authoring suite, which owns those four as SKILL.md files.
  local i f name stray n_cr
  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    f="$(definition_path "${name}")"
    stray="$(tr -d '\0-\177' <"${f}" | wc -c | tr -d ' ')"
    if [ "${stray}" -ne 0 ]; then
      printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${f}" "${stray}" >&2
      LC_ALL=C grep -n '[^ -~]' "${f}" >&2
      return 1
    fi
    n_cr="$(grep -c $'\r' "${f}" || true)"
    assert_eq "${name}.AGENT.md carries no carriage return" "0" "${n_cr}"
  done
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    f="$(overlay_path "${name}")"
    stray="$(tr -d '\0-\177' <"${f}" | wc -c | tr -d ' ')"
    if [ "${stray}" -ne 0 ]; then
      printf 'FAIL: %s holds %s non-ASCII byte(s)\n' "${f}" "${stray}" >&2
      LC_ALL=C grep -n '[^ -~]' "${f}" >&2
      return 1
    fi
    n_cr="$(grep -c $'\r' "${f}" || true)"
    assert_eq "${name}.PERSONA.toml carries no carriage return" "0" "${n_cr}"
  done
}

# ---------------------------------------------------------------------------
# The three persona overlays.
# ---------------------------------------------------------------------------

@test "overlays: each parses as TOML and carries description and instructions" {
  # A persona file that does not parse is not an error anyone sees: the persona is
  # simply absent from the catalog, so the overlay silently stops shaping the role
  # it was written for. description and instructions are the two fields the
  # catalog and the injected system-reminder are built from.
  python3 -c 'import tomllib' >/dev/null 2>&1 || skip "tomllib is not available (needs Python 3.11+)"
  local i
  for i in "${!PERSONAS[@]}"; do
    python3 -c "${PERSONA_PROG}" "${PERSONAS[i]}" "$(roster_csv)" \
      <"$(overlay_path "${PERSONAS[i]}")"
  done
}

@test "overlays: each carries the marker and stays an overlay, never naming tools" {
  # The marker is what makes ~/.grok/personas/<name>.toml stack-owned, so the
  # start refreshes it and refresh-configs will rewrite it; without the line the
  # file is treated as the operator's own and drifts forever. And an overlay that
  # names tools fights the agent definition it layers onto, which the guide says
  # owns both model and tools -- the three payloads each say so in their own header.
  local i name f n
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    f="$(overlay_path "${name}")"
    assert_contains_file "${name}.PERSONA.toml keeps the seeder marker string" "${f}" \
      'managed-by: evo-t1-coder-stack'
    n="$(grep -Ec '^[[:space:]]*tools[[:space:]]*=' "${f}" || true)"
    assert_eq "${name}.PERSONA.toml declares no top-level tools field" "0" "${n}"
    assert_contains_file "${name}.PERSONA.toml says it is an overlay, not a definition" "${f}" \
      '[Oo]verlay'
  done
}

# assert_link_to <link> <payload> <label> -- the repo-tier link resolves, is aimed
# at the payload it claims, and carries its bytes.
#
# Two checks, because the two failures differ. -e follows the link, so a dangling
# one is caught; readlink -f says WHERE it landed. Under a runfiles tree the link
# chain walks out to the real checkout, so the destination is matched on its
# templates/common/<name> tail rather than on an absolute path -- an absolute
# comparison would test Bazel's materialisation, not the link. cmp then proves the
# bytes are the payload's, which is what a link to the wrong sibling would break.
assert_link_to() {
  local link="${1}" payload="${2}" label="${3}" target
  [[ -e "${link}" ]] || {
    printf 'FAIL: %s does not resolve - the repo tier cannot discover it\n' "${link}" >&2
    return 1; }
  target="$(readlink -f "${link}")"
  case "${target}" in
    */templates/common/"${label}") ;;
    *)
      printf 'FAIL: %s resolves to %s, not to the templates/common/%s payload\n' \
        "${link}" "${target}" "${label}" >&2
      return 1 ;;
  esac
  cmp -s "${link}" "${payload}" || {
    printf 'FAIL: %s does not carry the bytes of %s\n' "${link}" "${payload}" >&2
    return 1; }
}

# ---------------------------------------------------------------------------
# The repo tier: how the CLI in this checkout sees the same thirteen files.
# ---------------------------------------------------------------------------

@test "repo tier: every .grok entry resolves to the templates/common payload it names" {
  # The repo tier is how this checkout's own CLI discovers the roles, and it is a
  # symlink, so two failures are possible and both are silent: a dangling link
  # leaves the role or slash command undiscoverable while the payload reads fine,
  # and a link that points at the wrong payload makes the repo run bytes that are
  # not the ones the boot seeds.
  local i name link
  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    link="${REPO_ROOT}/.grok/agents/${name}.md"
    assert_link_to "${link}" "$(definition_path "${name}")" "${name}.AGENT.md"
  done

  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    link="${REPO_ROOT}/.grok/personas/${name}.toml"
    assert_link_to "${link}" "$(overlay_path "${name}")" "${name}.PERSONA.toml"
  done

  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    link="${REPO_ROOT}/.grok/skills/${name}/SKILL.md"
    assert_link_to "${link}" "$(skill_path "${name}")" "${name}.SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# The seed body: how the thirteen reach a workspace's homes.
# ---------------------------------------------------------------------------

@test "fleet seed: each definition reaches ~/.grok/agents, marker-aware, fed by its own heredoc" {
  # Three failures in one block. An unconditional write overwrites a role the
  # operator edited; the marker guard is what makes ~/.grok/agents stack-owned
  # without that cost. An UNQUOTED heredoc delimiter expands the $-text every
  # definition body is made of while the boot runs, so the seeded file is not the
  # payload. And a tag that is not exactly twice leaves a heredoc that never
  # closes, swallowing the rest of the body: the workspace boots with the roles
  # that came first and nothing after.
  [[ -f "${SEED}" ]] || {
    printf 'FAIL: the fleet seed body is missing at %s\n' "${SEED}" >&2
    return 1; }
  local i name tag n after
  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    tag="${AGENT_TAGS[i]}"
    assert_contains_file "${name} absent-or-marker guard" "${SEED}" \
      '^if ! \[ -L "\$HOME/\.grok/agents/'"${name}"'\.md" \][[:space:]]*\\$'
    assert_contains_file "${name} guard asks the marker first" "${SEED}" \
      "grep -qs 'managed-by: evo-t1-coder-stack' \"\\\$HOME/\.grok/agents/${name}\.md\""
    assert_contains_file "${name} agents dir is created" "${SEED}" \
      'mkdir -p "\$HOME/\.grok/agents" 2>/dev/null'
    assert_contains_file "${name} is written into the agents home" "${SEED}" \
      'cat >"\$HOME/\.grok/agents/'"${name}"'\.md" '"$(hdoc_open)"

    n="$(grep -cF -- "${tag}" "${SEED}" || true)"
    assert_eq "${tag} appears exactly twice (opener + closer)" "2" "${n}"
    n="$(grep -cF -- "$(hdoc_open)'${tag}'" "${SEED}" || true)"
    assert_eq "${tag} opens quoted exactly once" "1" "${n}"
    n="$(grep -cFx -- "${tag}" "${SEED}" || true)"
    assert_eq "${tag} closes alone on its own line" "1" "${n}"

    # The line right after the opener is the interpolation: a heredoc that lost
    # its feed still has a legal opener and closer, so the three counts above pass
    # vacuously while the seeded file is empty and the role is simply gone.
    after="$(grep -A 1 -F -- "$(hdoc_open)'${tag}'" "${SEED}" | tail -n 1)"
    assert_eq "${tag} is fed by its payload interpolation" \
      "\${${AGENT_KEYS[i]}}" "${after}"
  done
}

@test "fleet seed: each overlay reaches ~/.grok/personas, marker-aware, fed by its own heredoc" {
  # Same three failures as the definitions, on the other home: a write with no
  # marker guard silently rewrites an operator's own persona, an unquoted
  # delimiter expands the body, and an unclosed tag truncates the script. The
  # guard and the heredoc cannot be inferred from the definition loop above: a
  # persona block whose guard was copy-pasted from a skills block is absent-only,
  # which is the wrong contract for this home.
  [[ -f "${SEED}" ]] || {
    printf 'FAIL: the fleet seed body is missing at %s\n' "${SEED}" >&2
    return 1; }
  local i name tag n after
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    tag="${PERSONA_TAGS[i]}"
    assert_contains_file "${name} absent-or-marker guard" "${SEED}" \
      '^if ! \[ -L "\$HOME/\.grok/personas/'"${name}"'\.toml" \][[:space:]]*\\$'
    assert_contains_file "${name} guard asks the marker first" "${SEED}" \
      "grep -qs 'managed-by: evo-t1-coder-stack' \"\\\$HOME/\.grok/personas/${name}\.toml\""
    assert_contains_file "${name} personas dir is created" "${SEED}" \
      'mkdir -p "\$HOME/\.grok/personas" 2>/dev/null'
    assert_contains_file "${name} is written into the personas home" "${SEED}" \
      'cat >"\$HOME/\.grok/personas/'"${name}"'\.toml" '"$(hdoc_open)"

    n="$(grep -cF -- "${tag}" "${SEED}" || true)"
    assert_eq "${tag} appears exactly twice (opener + closer)" "2" "${n}"
    n="$(grep -cF -- "$(hdoc_open)'${tag}'" "${SEED}" || true)"
    assert_eq "${tag} opens quoted exactly once" "1" "${n}"
    n="$(grep -cFx -- "${tag}" "${SEED}" || true)"
    assert_eq "${tag} closes alone on its own line" "1" "${n}"

    after="$(grep -A 1 -F -- "$(hdoc_open)'${tag}'" "${SEED}" | tail -n 1)"
    assert_eq "${tag} is fed by its payload interpolation" \
      "\${${PERSONA_KEYS[i]}}" "${after}"
  done
}

@test "fleet seed: each skill reaches both homes and the agents copy is a cp, never a second body" {
  # The two skill homes are two consumers of ONE file: the Coder Agents chat reads
  # ~/.coder/skills/ and the Grok Build CLI reads ~/.agents/skills/. If the
  # ~/.agents side grew its own heredoc the two drift the moment one is edited,
  # and first-match-wins discovery decides which one the CLI actually runs. Skills
  # are absent-only, unlike the two homes above: a SKILL.md that exists belongs to
  # the user.
  [[ -f "${SEED}" ]] || {
    printf 'FAIL: the fleet seed body is missing at %s\n' "${SEED}" >&2
    return 1; }
  local i name n
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    assert_contains_file "${name} coder guard" "${SEED}" \
      '^if ! \[ -L "\$HOME/\.coder/skills/'"${name}"'/SKILL\.md" \][[:space:]]*\\$'
    assert_contains_file "${name} coder mkdir" "${SEED}" \
      'mkdir -p "\$HOME/\.coder/skills/'"${name}"'" 2>/dev/null'
    assert_contains_file "${name} coder cat" "${SEED}" \
      'cat >"\$HOME/\.coder/skills/'"${name}"'/SKILL\.md" '"$(hdoc_open)"
    assert_contains_file "${name} agents guard" "${SEED}" \
      '^if ! \[ -L "\$HOME/\.agents/skills/'"${name}"'/SKILL\.md" \][[:space:]]*\\$'
    assert_contains_file "${name} agents mkdir" "${SEED}" \
      'mkdir -p "\$HOME/\.agents/skills/'"${name}"'" 2>/dev/null'
    assert_contains_file "${name} copies the managed coder copy" "${SEED}" \
      'cp "\$HOME/\.coder/skills/'"${name}"'/SKILL\.md" \\'
    assert_contains_file "${name} lands it in the agents home" "${SEED}" \
      '"\$HOME/\.agents/skills/'"${name}"'/SKILL\.md" 2>/dev/null'

    n="$(grep -cF -- "cat >\"\$HOME/.agents/skills/" "${SEED}" || true)"
    assert_eq "${name} never gets its own heredoc on the agents side" "0" "${n}"
  done
}

@test "fleet seed: the body holds thirteen quoted heredocs and renders each map key exactly once" {
  # Thirteen is the family's size, so a fourteenth body means a payload someone
  # seeded without telling this gate, and a twelfth means a role stopped reaching
  # a workspace while main.tf still ships its bytes. And a key the body renders
  # twice spends the execve headroom twice for one file, which is the ceiling this
  # separate coder_script was cut to buy.
  [[ -f "${SEED}" ]] || {
    printf 'FAIL: the fleet seed body is missing at %s\n' "${SEED}" >&2
    return 1; }
  # Counted by occurrence, not by line: a key rendered twice on one line is the
  # same double spend of the execve headroom as one rendered on two.
  local n key i
  n="$(grep -oE -- "$(hdoc_open)'[A-Z_]+_EOF'" "${SEED}" | wc -l | tr -d ' ')"
  assert_eq "the fleet body holds exactly thirteen quoted heredocs" "13" "${n}"

  for i in "${!AGENT_KEYS[@]}"; do
    key="${AGENT_KEYS[i]}"
    n="$(grep -oF -- "\${${key}}" "${SEED}" | wc -l | tr -d ' ')"
    assert_eq "${key} is rendered exactly once by the fleet body" "1" "${n}"
  done
  for i in "${!PERSONA_KEYS[@]}"; do
    key="${PERSONA_KEYS[i]}"
    n="$(grep -oF -- "\${${key}}" "${SEED}" | wc -l | tr -d ' ')"
    assert_eq "${key} is rendered exactly once by the fleet body" "1" "${n}"
  done
  for i in "${!SKILL_KEYS[@]}"; do
    key="${SKILL_KEYS[i]}"
    n="$(grep -oF -- "\${${key}}" "${SEED}" | wc -l | tr -d ' ')"
    assert_eq "${key} is rendered exactly once by the fleet body" "1" "${n}"
  done
}

# ---------------------------------------------------------------------------
# Registration: the three lists a payload has to appear in, or it does not ship.
# ---------------------------------------------------------------------------

@test "fleet seed: a planted symlink is refused and no write lands outside the four homes" {
  # The marker guard reads the file a managed path points at, so a link planted at
  # ~/.grok/agents/explorer.md aimed the body's cat at whatever it named: a link to the
  # operator's own ~/.grok/AGENTS.md satisfied the marker test and got that file
  # replaced. The guard now refuses a symlinked destination, and one symlinked root
  # stops the body before its first write. Rendered, not grepped: this is behaviour.
  local home rendered
  home="$(mktemp -d "${BATS_TEST_TMPDIR}/symlink-home.XXXXXX")"
  rendered="${BATS_TEST_TMPDIR}/rendered-fleet.sh"

  # Each map key becomes one inert line: the guards are what is under test, and the
  # payload bytes only have to be non-empty for the here-docs to close.
  python3 - "$SEED" "$rendered" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="ascii").read()
# One pass, the way templatefile() reads the body: $${ is a literal ${ and %%{ is a
# literal %{, so a shell variable survives into the script; anything else braced is a
# declared key and becomes seed text. A renderer that skips the fold leaves "$${name}"
# in the file, the shell reads it as the PID plus a literal word, and every guard that
# tests that variable silently stops testing anything.
pattern = re.compile(r"(\$\$\{)|(%%\{)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
def emit(match):
    if match.group(1):
        return "${"
    if match.group(2):
        return "%{"
    return "seeded by the fleet body for " + match.group(3)
text = pattern.sub(emit, text)
open(sys.argv[2], "w", encoding="ascii").write(text)
PY
  [ -s "${rendered}" ] || {
    printf 'FAIL: the fleet body rendered to nothing at %s\n' "${rendered}" >&2
    return 1; }

  mkdir -p "${home}/.grok/agents" "${home}/.coder/skills/bug-hunt" "${home}/.agents/skills"
  printf 'managed-by: evo-t1-coder-stack\nthe operator wrote this rulebook\n' \
    >"${home}/.grok/AGENTS.md"
  ln -s "${home}/.grok/AGENTS.md" "${home}/.grok/agents/explorer.md"
  # A dangling link passes a bare [ ! -f ], so cat would create the target instead.
  ln -s "${home}/outside/SKILL.md" "${home}/.coder/skills/bug-hunt/SKILL.md"

  HOME="${home}" sh "${rendered}"

  assert_contains_file "the rulebook the link aimed at is untouched" \
    "${home}/.grok/AGENTS.md" 'the operator wrote this rulebook'
  [ -L "${home}/.grok/agents/explorer.md" ] || {
    printf 'FAIL: the planted link at explorer.md was replaced by a real file\n' >&2
    return 1; }
  [ ! -e "${home}/outside/SKILL.md" ] || {
    printf 'FAIL: the dangling link wrote its target at %s\n' \
      "${home}/outside/SKILL.md" >&2
    return 1; }
  # The refusals are per path: the body still seeds the roles and skills nobody
  # sabotaged. bug-hunt earns no twin here, because its ~/.coder source is the link the
  # body refused to write through, and cp copies from a file that was never created.
  assert_file_exists "an unsabotaged role still lands" \
    "${home}/.grok/agents/architect.md"
  assert_file_exists "an unsabotaged skill lands in both homes" \
    "${home}/.coder/skills/feature-implementation/SKILL.md"
  assert_file_exists "its twin too" \
    "${home}/.agents/skills/feature-implementation/SKILL.md"

  # One symlinked root would aim every write at a directory outside the four homes.
  local rooty
  rooty="$(mktemp -d "${BATS_TEST_TMPDIR}/symlink-root.XXXXXX")"
  mkdir -p "${rooty}/.grok" "${rooty}/elsewhere" "${rooty}/.coder/skills" \
    "${rooty}/.agents/skills"
  ln -s "${rooty}/elsewhere" "${rooty}/.grok/agents"
  HOME="${rooty}" sh "${rendered}"
  [ -z "$(ls -A "${rooty}/elsewhere")" ] || {
    printf 'FAIL: a symlinked agents root let writes into %s: %s\n' \
      "${rooty}/elsewhere" "$(ls -A "${rooty}/elsewhere")" >&2
    return 1; }
}

@test "registration: the push lib's payload loop lists all thirteen" {
  # main.tf reads every one of these from the copy pushed beside it, so a name
  # missing here fails every template push with an error that names the file --
  # and a name that only ever appeared in the file's own comment block would pass a
  # whole-file grep while the push still died. Hence the loop, not the file.
  [[ -f "${PUSH}" ]] || {
    printf 'FAIL: the push lib is missing at %s\n' "${PUSH}" >&2
    return 1; }
  local i name listed
  listed="$(push_payload_list)"
  [ -n "${listed}" ] || {
    printf 'FAIL: no payload loop was found in %s - the extraction, not the list, is broken\n' \
      "${PUSH}" >&2
    return 1; }
  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}.AGENT.md"
    printf '%s\n' "${listed}" | grep -Fxq -- "${name}" || {
      printf 'FAIL: %s does not push %s\n' "${PUSH}" "${name}" >&2
      return 1; }
  done
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}.PERSONA.toml"
    printf '%s\n' "${listed}" | grep -Fxq -- "${name}" || {
      printf 'FAIL: %s does not push %s\n' "${PUSH}" "${name}" >&2
      return 1; }
  done
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}.SKILL.md"
    printf '%s\n' "${listed}" | grep -Fxq -- "${name}" || {
      printf 'FAIL: %s does not push %s\n' "${PUSH}" "${name}" >&2
      return 1; }
  done
  printf '%s\n' "${listed}" | grep -Fxq -- "stack-fleet.sh.tftpl" || {
    printf 'FAIL: %s does not push the fleet seed body itself\n' "${PUSH}" >&2
    return 1; }
}

@test "registration: config_seed names every home path against its payload, seventeen rows in all" {
  # refresh-configs reseeds from this list and the boot writes only what is absent,
  # so a row dropped here leaves a host tree, or a workspace that missed a boot,
  # permanently short of that file. Seventeen is six definitions plus three
  # overlays plus two skill homes times four: a home dropped for one skill is the
  # failure the count catches, which is what the per-row check alone cannot see.
  [[ -f "${CONFIG_SEED}" ]] || {
    printf 'FAIL: the seed lib is missing at %s\n' "${CONFIG_SEED}" >&2
    return 1; }
  # The real function is driven, not a copy of its text: a row that lost its
  # trailing backslash swallows the closing brace, and that is as fatal as the row
  # itself, so the extraction failing is reported as the malformed list it is.
  if ! load_shell_function "${CONFIG_SEED}" seed_seed_targets; then
    printf 'FAIL: seed_seed_targets in %s cannot be extracted and evaluated - its printf list is malformed, most likely a row that lost its trailing backslash\n' \
      "${CONFIG_SEED}" >&2
    return 1
  fi
  local i name targets n tab
  tab="$(printf '\t')"
  targets="$(seed_seed_targets)"
  [ -n "${targets}" ] || {
    printf 'FAIL: seed_seed_targets in %s printed nothing\n' "${CONFIG_SEED}" >&2
    return 1; }

  for i in "${!AGENTS[@]}"; do
    name="${AGENTS[i]}"
    assert_match "~/.grok/agents/${name}.md maps to its payload" \
      "~/\.grok/agents/${name}\.md${tab}file:templates/common/${name}\.AGENT\.md" "${targets}"
  done
  for i in "${!PERSONAS[@]}"; do
    name="${PERSONAS[i]}"
    assert_match "~/.grok/personas/${name}.toml maps to its payload" \
      "~/\.grok/personas/${name}\.toml${tab}file:templates/common/${name}\.PERSONA\.toml" "${targets}"
  done
  for i in "${!SKILLS[@]}"; do
    name="${SKILLS[i]}"
    assert_match "~/.coder/skills/${name}/SKILL.md maps to its payload" \
      "~/\.coder/skills/${name}/SKILL\.md${tab}file:templates/common/${name}\.SKILL\.md" "${targets}"
    assert_match "~/.agents/skills/${name}/SKILL.md maps to its payload" \
      "~/\.agents/skills/${name}/SKILL\.md${tab}file:templates/common/${name}\.SKILL\.md" "${targets}"
  done

  n="$(printf '%s\n' "${targets}" |
    grep -cE "^~/\.grok/(agents|personas)/|~/\.(coder|agents)/skills/(feature-implementation|skeptical-review|security-audit|bug-hunt)/SKILL\.md" || true)"
  assert_eq "the fleet family carries eighteen seed rows (six fleet agents, the advisor's documenter, three overlays, four skill pairs)" "18" "${n}"
}

@test "registration: both main.tf twins feed all thirteen keys, chomped, into the stack_fleet block" {
  # chomp, because the heredoc closes on its own line and a trailing newline in a
  # payload grows a blank line in every seeded file and drifts the marker off the
  # shape the seeder probes. In-block placement, because both byte readers credit a
  # body only by the path.module names inside it: a key moved behind a local.
  # stops being counted and the payload rides the argument unseen. Exactly once,
  # because a copy left in the coder_agent.main startup map ships the bytes twice.
  local twin block agent i key name total
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    block="$(main_block "${twin}/main.tf" coder_script stack_fleet)"
    [ -n "${block}" ] || {
      printf 'FAIL: %s has no coder_script "stack_fleet" block\n' "${twin}/main.tf" >&2
      return 1; }
    assert_match "${twin}/main.tf renders the fleet family from the shared body" \
      'script = templatefile\("\$\{path\.module\}/stack-fleet\.sh\.tftpl"' "${block}"
    agent="$(main_block "${twin}/main.tf" coder_agent main)"

    for i in "${!AGENTS[@]}"; do
      name="${AGENTS[i]}"
      key="${AGENT_KEYS[i]}"
      assert_match "${twin}/main.tf chomps ${key} from its definition, inside the block" \
        "${key}[[:space:]]+=[[:space:]]+chomp\(file\(\"\\\$\{path\.module\}/${name}\.AGENT\.md\"\)\)" "${block}"
      total="$(grep -cF -- "${key}" "${twin}/main.tf" || true)"
      assert_eq "${twin}/main.tf feeds ${key} exactly once, out of the startup map" "1" "${total}"
      if printf '%s' "${agent}" | grep -Fq -- "${key}"; then
        printf 'FAIL: %s still inlines %s into coder_agent.main startup_script\n' \
          "${twin}/main.tf" "${key}" >&2
        return 1
      fi
    done

    for i in "${!PERSONAS[@]}"; do
      name="${PERSONAS[i]}"
      key="${PERSONA_KEYS[i]}"
      assert_match "${twin}/main.tf chomps ${key} from its overlay, inside the block" \
        "${key}[[:space:]]+=[[:space:]]+chomp\(file\(\"\\\$\{path\.module\}/${name}\.PERSONA\.toml\"\)\)" "${block}"
      total="$(grep -cF -- "${key}" "${twin}/main.tf" || true)"
      assert_eq "${twin}/main.tf feeds ${key} exactly once, out of the startup map" "1" "${total}"
      if printf '%s' "${agent}" | grep -Fq -- "${key}"; then
        printf 'FAIL: %s still inlines %s into coder_agent.main startup_script\n' \
          "${twin}/main.tf" "${key}" >&2
        return 1
      fi
    done

    for i in "${!SKILLS[@]}"; do
      name="${SKILLS[i]}"
      key="${SKILL_KEYS[i]}"
      assert_match "${twin}/main.tf chomps ${key} from its skill, inside the block" \
        "${key}[[:space:]]+=[[:space:]]+chomp\(file\(\"\\\$\{path\.module\}/${name}\.SKILL\.md\"\)\)" "${block}"
      total="$(grep -cF -- "${key}" "${twin}/main.tf" || true)"
      assert_eq "${twin}/main.tf feeds ${key} exactly once, out of the startup map" "1" "${total}"
      if printf '%s' "${agent}" | grep -Fq -- "${key}"; then
        printf 'FAIL: %s still inlines %s into coder_agent.main startup_script\n' \
          "${twin}/main.tf" "${key}" >&2
        return 1
      fi
    done
  done
}

@test "registration: the size guard measures all thirteen payloads inside the fleet body" {
  # The guard that keeps the escape hatch honest. startup_size.awk is what
  # scripts/push-template.sh reads to refuse an argument past MAX_ARG_STRLEN
  # before a workspace ever boots; a payload it emits no record for is a payload
  # nobody sizes, and it shows up as a workspace that fails to boot with "A startup
  # script has failed" instead of as a failed push. The fleet body inlines thirteen
  # files on top of the two families already at their own ceiling, so this is the
  # record that has to survive any later edit.
  local twin out name tab
  tab="$(printf '\t')"
  [[ -f "${SIZE_AWK}" ]] || {
    printf 'FAIL: startup_size.awk is not reachable at %s\n' "${SIZE_AWK}" >&2
    return 1; }
  for twin in "${REPO_ROOT}/templates/workspace" "${REPO_ROOT}/templates/devcontainer"; do
    out="$(awk -f "${SIZE_AWK}" "${twin}/main.tf")"
    for name in "${AGENTS[@]}"; do
      assert_match "${twin}/main.tf measures ${name} inside the fleet body" \
        "^stack-fleet\.sh\.tftpl${tab}${name}\.AGENT\.md\$" "${out}"
    done
    for name in "${PERSONAS[@]}"; do
      assert_match "${twin}/main.tf measures ${name} inside the fleet body" \
        "^stack-fleet\.sh\.tftpl${tab}${name}\.PERSONA\.toml\$" "${out}"
    done
    for name in "${SKILLS[@]}"; do
      assert_match "${twin}/main.tf measures ${name} inside the fleet body" \
        "^stack-fleet\.sh\.tftpl${tab}${name}\.SKILL\.md\$" "${out}"
    done
    # A payload this reader reports under a placeholder is one it could not name,
    # which is the same as not measuring it.
    assert_not_match "${twin}/main.tf never reports the fleet body as unmeasurable" \
      "^stack-fleet\.sh\.tftpl${tab}(HEREDOC|OTHER|CLASH)\$" "${out}"
  done
}
