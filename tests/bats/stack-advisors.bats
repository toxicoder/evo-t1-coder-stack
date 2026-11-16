#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## stack-advisors.bats - the four advisor skills and the documenter definition
# promise only what this stack can actually run.
#
# The family is five payloads in templates/common/: four runbooks (*.SKILL.md)
# that the coder_script "stack_advisors" body writes into
# ~/.coder/skills/<name>/SKILL.md with a cp twin in ~/.agents/skills/, and one
# role definition (documenter.AGENT.md) that becomes ~/.grok/agents/documenter.md.
# Nothing in a workspace checks any of it at boot. A payload dropped from the tree
# leaves the slash command undiscoverable while the sibling runbooks still read
# fine; a frontmatter that never closes swallows the body into the frontmatter, so
# the skill has no instructions at all; a model: naming a cloud id is read as
# configuration by the CLI and answered only when a parent spawns that role in
# the middle of a fan-out; a mcpInheritance that contradicts its own tools list
# gives a child an empty catalog for the tool its brief says to call; a
# Done-means list that drifted into adjectives turns the run's own gate into a
# claim nobody ran; and a payload grown past the byte headroom its coder_script
# body has to carry shows up as a failed boot, not as a failed push.
#
# Usage: bazelisk test //tests:bats_stack_advisors_test   (from any cwd)
# Safety: reads templates/common/{documenter,performance-optimizer,debugger,
# migrator}.SKILL.md and documenter.AGENT.md, plus the *.AGENT.md and
# *.SKILL.md listings of that directory. Writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
MEASURE_ROOT=""
COMMON=""

# The four advisor runbooks, in the order the family's docs list them.
ADVISORS=(documenter performance-optimizer debugger migrator)

# The one role definition the family adds to the six fleet roles.
DEFINITION="documenter"

# The whole *.AGENT.md set the directory has to hold: the six fleet roles, which
# tests/bats/fleet-agents.bats opens in full, plus this family's seventh. Only the
# directory-level set is claimed here, never the six definitions' contents.
AGENT_SET=(architect documenter explorer implementer reviewer security-auditor tester)

# The *.SKILL.md baseline: the twelve that shipped before this family, plus these
# four. Every one has to stay in the directory; names other suites own (the
# repo-skill roster) may join it, which is why this is a floor and not a count.
SKILL_SET=(bug-hunt debugger documenter ez-bazel-first ez-create-skill ez-learn
  ez-micro-plan ez-skillify ez-strong-types ez-trunk-based-repo
  feature-implementation grok-build-delegation migrator performance-optimizer
  security-audit skeptical-review)

# The lanes this family routes over, and the only model ids this stack can serve:
# the local alias table in litellm/config.yaml, with no cloud transport behind it
# (docs/litellm-routing.md).
LOCAL_ROSTER=(agent agent-explore agent-review agent-swarm agent-low agent-medium
  agent-xhigh)

# The id prefixes a cloud provider answers to. One of them anywhere in a payload
# claims a box this stack cannot reach.
CLOUD_TOKENS=(gpt- claude gemini mistral ollama/ openai/ anthropic)

# The two tool names that make an MCP catalog worth rendering at all
# (~/.grok/docs/user-guide/16-subagents.md): a definition whose tools name neither
# has nothing to inherit.
MCP_TOOLS=(search_tool use_tool)

# Per-payload and family byte ceilings. Each skill is interpolated into a
# coder_script body that is exec'd, so one payload over 12 KiB is one argument
# past MAX_ARG_STRLEN; the family total is the room the four leave the rest of that
# body inside the same ceiling.
SKILL_BYTE_LIMIT=12288
FAMILY_BYTE_LIMIT=40960

# skill_path <stem> -- the runbook for one advisor.
skill_path() {
  printf '%s' "${COMMON}/${1}.SKILL.md"
}

# definition_path -- the payload for the role definition.
definition_path() {
  printf '%s' "${COMMON}/${DEFINITION}.AGENT.md"
}

# family_paths -- all five payloads, one per line.
family_paths() {
  local name
  for name in "${ADVISORS[@]}"; do
    printf '%s\n' "$(skill_path "${name}")"
  done
  printf '%s\n' "$(definition_path)"
}

# count_suffix <ext> -- how many payload files of one extension the directory
# holds. -e rather than -type f: under a Bazel runfiles tree every payload is a
# symlink into the source, and a type test reads the link, not the file.
count_suffix() {
  local n=0 candidate
  for candidate in "${COMMON}"/*."${1}"; do
    [[ -e "${candidate}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}

# dir_stems <ext> -- the stems of that extension's files, sorted, one per line.
dir_stems() {
  local candidate
  for candidate in "${COMMON}"/*."${1}"; do
    [[ -e "${candidate}" ]] || continue
    basename "${candidate}" ".${1}"
  done | LC_ALL=C sort
}

# is_local_alias <value> -- is this model id one of the lanes above.
is_local_alias() {
  local name
  for name in "${LOCAL_ROSTER[@]}"; do
    [ "${name}" = "${1}" ] && return 0
  done
  return 1
}

# The Done-means parser. Reads one runbook; argv[2] picks the claim so each test
# reports the failure it asked about. A Done-means section is the run's own gate,
# so it has to be the last section and it has to hold something someone can run:
# commands written in markdown code, which is an inline backtick span or an
# indented block, and prose is neither. The block test requires a blank line
# before it, because that is what separates a code block from a wrapped list item
# -- without it every continued bullet reads as a command.
DONE_PROG='
import re, sys
path = sys.argv[1]
mode = sys.argv[2]
text = open(path, encoding="utf-8", errors="surrogateescape").read()
lines = text.splitlines()
heads = [i for i, line in enumerate(lines) if line.startswith("## ")]
if not heads:
    sys.exit("FAIL: %s has no level-2 heading, so it has no Done means section" % path)
last = heads[-1]
if lines[last].strip() != "## Done means":
    sys.exit("FAIL: %s ends with %r, not with its ## Done means section"
             % (path, lines[last].strip()))
if mode == "heading":
    sys.exit(0)
candidates = []
in_block = False
previous_blank = True
for line in lines[last + 1:]:
    if not line.strip():
        previous_blank = True
        in_block = False
        continue
    indented = line.startswith("    ") or line.startswith("\t")
    if indented and (previous_blank or in_block):
        in_block = True
        candidates.append(line.strip())
    else:
        in_block = False
        candidates.extend(span.strip() for span in re.findall(r"`([^`]+)`", line))
    previous_blank = False
if not candidates:
    sys.exit("FAIL: %s: its Done means section holds no backticked span and no "
             "indented command block, so nothing in it is something anyone ran" % path)
def is_command(text):
    text = text.split("#")[0].strip()
    if not re.match(r"^[a-z][a-z0-9_.-]*(\s|$)", text):
        return False
    if len(text.split()) < 2:
        return False
    return bool(re.search(r"(/|--\w|<[^>]+>|\.(sh|py|bazel|md)\b)", text))
if not [c for c in candidates if is_command(c)]:
    sys.exit("FAIL: %s: its Done means section states no command, only prose; its "
             "code spans and block lines were: %s" % (path, " | ".join(candidates[:4])))
'

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" ||
    skip "cannot locate the repo root (no docker-compose.yml marker)"
  # The byte gates count the shipping file, not an instrumented mirror of it.
  MEASURE_ROOT="$(bats_source_repo_root)" ||
    skip "cannot locate the source checkout the payload bytes come from"
  COMMON="${REPO_ROOT}/templates/common"
}

# ---------------------------------------------------------------------------
# The five payloads, and the set the directory holds.
# ---------------------------------------------------------------------------

@test "advisors: all five payloads ship and none is empty" {
  # A payload that vanished leaves a slash command nobody can invoke and a role no
  # parent can spawn, while every sibling file still reads perfectly -- the only
  # symptom is a command that is simply not there. An empty one is worse than an
  # absent one: discovery finds it and the child gets no brief.
  local path
  while IFS= read -r path; do
    assert_file_exists "the payload is in the tree" "${path}"
    [ -s "${path}" ] || {
      printf 'FAIL: %s exists but is empty - the seeded copy carries no body\n' \
        "${path}" >&2
      return 1; }
  done < <(family_paths)
}

@test "advisors: the *.AGENT.md set is exact and the four skills joined the skill family" {
  # For the definition the claim is the exact set, not presence: an eighth
  # *.AGENT.md nobody registered is a role that reaches no workspace, and a
  # vanished one leaves a home path nothing fills. The skills are the opposite --
  # only these four are this family's, and the directory holds rosters other suites
  # own (tests/bats/ez-repo-skill-authoring.bats:56-72), so the claim here is that
  # the four joined and nothing that shipped before went missing.
  local name actual expected n
  assert_eq "templates/common holds exactly seven *.AGENT.md" "7" "$(count_suffix AGENT.md)"
  actual="$(dir_stems AGENT.md)"
  expected="$(printf '%s\n' "${AGENT_SET[@]}" | LC_ALL=C sort)"
  if [ "${actual}" != "${expected}" ]; then
    printf 'FAIL: %s holds a different *.AGENT.md set than the seven the fleet and this family ship:\n' \
      "${COMMON}" >&2
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") >&2
    return 1
  fi

  for name in "${SKILL_SET[@]}"; do
    [[ -e "${COMMON}/${name}.SKILL.md" ]] || {
      printf 'FAIL: %s lost %s.SKILL.md - a runbook that stopped shipping leaves its slash command undiscoverable\n' \
        "${COMMON}" "${name}" >&2
      return 1; }
  done
  n="$(count_suffix SKILL.md)"
  [ "${n}" -ge "${#SKILL_SET[@]}" ] || {
    printf 'FAIL: %s holds %s *.SKILL.md, fewer than the %s the stack ships\n' \
      "${COMMON}" "${n}" "${#SKILL_SET[@]}" >&2
    return 1; }
}

@test "advisors: each opens its frontmatter on line 1 and closes it above the marker" {
  # A file whose first line is not --- has no frontmatter at all, so the CLI
  # registers neither the skill nor the role while the file reads fine. And the
  # marker is provenance, not structure: above line 1 it is never read, and inside
  # the frontmatter it becomes an undocumented key -- while the seeder's own probe
  # greps for that string and stops refreshing a copy that lost it.
  local path close marker
  while IFS= read -r path; do
    run head -n 1 "${path}"
    assert_eq "$(basename "${path}") opens the frontmatter on line 1" "---" "${output}"

    close="$(awk 'NR > 2 && /^---[[:space:]]*$/ { print NR; exit }' "${path}")"
    [ -n "${close}" ] || {
      printf 'FAIL: %s never closes its frontmatter - the body below is parsed as frontmatter\n' \
        "${path}" >&2
      return 1; }

    marker="$(grep -nF 'managed-by: evo-t1-coder-stack' "${path}" | head -n 1 | cut -d: -f1)"
    [ -n "${marker}" ] || {
      printf 'FAIL: %s lost the managed-by marker - the boot stops refreshing this copy\n' \
        "${path}" >&2
      return 1; }
    [ "${marker}" -gt "${close}" ] || {
      printf 'FAIL: %s carries the managed-by marker at line %s, inside the frontmatter that closes at %s\n' \
        "${path}" "${marker}" "${close}" >&2
      return 1; }
  done < <(family_paths)
}

# ---------------------------------------------------------------------------
# The cloud-model gate: nothing in this family may name a box the proxy cannot
# reach. LiteLLM over the three Spark boxes is the only transport here.
# ---------------------------------------------------------------------------

@test "advisors: no payload names a cloud model id" {
  # The most important claim in this suite. An id the alias table does not serve
  # is not a boot failure: the spawn simply dies, mid-fan-out, in whatever run was
  # counting on that lane. Scanned as fixed strings, case-sensitively: model ids
  # are lower-case, and the reserved CLAUDE_PROJECT_DIR environment variable names
  # a path, never a model.
  local path token n
  while IFS= read -r path; do
    for token in "${CLOUD_TOKENS[@]}"; do
      n="$(grep -cF -- "${token}" "${path}" || true)"
      assert_eq "$(basename "${path}") names no ${token} model id" "0" "${n}"
    done
  done < <(family_paths)
}

@test "documenter definition: every model line is a local lane" {
  # Checked per line rather than by one grep, because a second model: added later
  # -- in a frontmatter mapping, or in a tools example the CLI still reads -- is
  # exactly the line that would slip past a whole-file scan for agent-swarm.
  local path value n_model_lines
  path="$(definition_path)"
  n_model_lines="$(grep -cE '^[[:space:]]*model:' "${path}" || true)"
  [ "${n_model_lines}" -ge 1 ] || {
    printf 'FAIL: %s declares no model: line, so the role inherits whatever the spawner defaults to\n' \
      "${path}" >&2
    return 1; }

  while IFS= read -r value; do
    is_local_alias "${value}" || {
      printf 'FAIL: %s declares model: %s, which is not one of the local lanes: %s\n' \
        "${path}" "${value}" "${LOCAL_ROSTER[*]}" >&2
      return 1; }
  done < <(sed -nE 's/^[[:space:]]*model:[[:space:]]*//p' "${path}")
}

@test "documenter definition: it rides agent-swarm, names its tools, and inherits no MCP catalog" {
  # Three keys that have to agree. agent-swarm is the fan-out lane a writer wave
  # rides (a pinned definition holds one box and deepens the proxy queue); an empty
  # tools list is a role with no instruments at all; and mcpInheritance: none is
  # the honest answer for a tools list that names neither search_tool nor use_tool,
  # because an inherited catalog would render nothing and cost a render.
  local path tools named value
  path="$(definition_path)"
  assert_contains_file "documenter.AGENT.md rides the fan-out lane" "${path}" \
    '^model:[[:space:]]*agent-swarm$'
  assert_contains_file "documenter.AGENT.md declares a tools list" "${path}" \
    '^tools:[[:space:]]*[^[:space:]]'
  assert_contains_file "documenter.AGENT.md inherits no MCP catalog" "${path}" \
    '^mcpInheritance:[[:space:]]*none$'

  tools="$(sed -nE 's/^tools:[[:space:]]*//p' "${path}" | head -n 1)"
  local IFS=,
  read -r -a named <<<"$(printf '%s' "${tools}" | tr -d '[:space:]')"
  [ "${#named[@]}" -ge 1 ] || {
    printf 'FAIL: %s names no tool in its tools list: [%s]\n' "${path}" "${tools}" >&2
    return 1; }
  for value in "${named[@]}"; do
    [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      printf 'FAIL: %s lists a tool name that is not an identifier: %s\n' \
        "${path}" "${value}" >&2
      return 1; }
  done

  local mcp
  for mcp in "${MCP_TOOLS[@]}"; do
    assert_not_match "documenter.AGENT.md names no MCP tool, so none is right" \
      "(^|,)${mcp}(,|$)" "${tools// /}"
  done
}

# ---------------------------------------------------------------------------
# The lanes each runbook rides.
# ---------------------------------------------------------------------------

@test "advisor skills: each names the three lanes it rides" {
  # Every runbook fans out over the same three: a mapper, a writer wave, and an
  # independent skeptic. A runbook that stopped naming one has quietly moved that
  # lane onto the pinned default, which holds a box and deepens the queue -- and no
  # boot complains, because a lane name is prose to the CLI.
  local name path lane
  for name in "${ADVISORS[@]}"; do
    path="$(skill_path "${name}")"
    for lane in agent-explore agent-swarm agent-review; do
      assert_contains_file "${name}.SKILL.md names ${lane}" "${path}" "${lane}"
    done
  done
}

@test "advisor skills: each lane is named for the role it carries" {
  # Presence alone is satisfied by the roster line every runbook opens with, which
  # is prose about aliases. The claim that matters is the pairing: explore maps,
  # swarm writes, review doubts. reviewer is not an accepted role word here, because
  # the lane name itself contains review and would match on every line.
  local name path lane lines role_re
  for name in "${ADVISORS[@]}"; do
    path="$(skill_path "${name}")"
    for lane in agent-explore agent-swarm agent-review; do
      case "${lane}" in
        agent-explore) role_re='map|read-only' ;;
        agent-swarm) role_re='writer|fan-out|spreads' ;;
        agent-review) role_re='skeptic|independent' ;;
      esac
      lines="$(grep -nF -- "${lane}" "${path}" || true)"
      printf '%s\n' "${lines}" | grep -Eiq -- "${role_re}" || {
        printf 'FAIL: %s names %s but never for its role (expected a line matching /%s/)\n' \
          "${path}" "${lane}" "${role_re}" >&2
        return 1; }
    done
  done
}

# ---------------------------------------------------------------------------
# The Done-means section: the run's own gate, written as commands.
# ---------------------------------------------------------------------------

@test "advisor skills: each ends with its Done means section" {
  # Last, not merely present. A section that stopped being the closing one means
  # someone appended work after the gate, and the run ends on that instead of on
  # the checklist the whole runbook was written to satisfy.
  local name
  for name in "${ADVISORS[@]}"; do
    python3 -c "${DONE_PROG}" "$(skill_path "${name}")" heading
  done
}

@test "advisor skills: each Done means section carries a command, not an adjective" {
  # The section is what the parent reads as done, so an item has to be something
  # someone ran. A section of adjectives passes a read-through and ships a run that
  # verified nothing -- which is the failure this family exists to prevent.
  local name
  for name in "${ADVISORS[@]}"; do
    python3 -c "${DONE_PROG}" "$(skill_path "${name}")" command
  done
}

# ---------------------------------------------------------------------------
# Bytes: the family has to fit the body that carries it, and stay plain ASCII.
# ---------------------------------------------------------------------------

@test "advisors: each of the five is pure ASCII" {
  # Every consumer reads these as text a parser reads: a curly quote or an en dash
  # survives into the seeded file, reads as mojibake in the child's system prompt,
  # and breaks the byte-wise comparison a takeover edit depends on. The bracket
  # range is the printable set, so a stray tab or CR is a failure too.
  local path stray
  while IFS= read -r path; do
    stray="$(LC_ALL=C grep -n '[^ -~]' "${path}" || true)"
    [ -z "${stray}" ] || {
      printf 'FAIL: %s holds a non-ASCII or control byte:\n%s\n' "${path}" "${stray}" >&2
      return 1; }
  done < <(family_paths)
}

@test "advisor skills: each stays under the 12 KiB the coder_script body allows" {
  # Each runbook is interpolated into a script body the agent tunnel exec's, so one
  # payload past this ceiling is one argument past MAX_ARG_STRLEN: the workspace
  # fails to boot with "A startup script has failed" instead of failing a push.
  local name size
  for name in "${ADVISORS[@]}"; do
    size="$(wc -c <"${MEASURE_ROOT}/templates/common/${name}.SKILL.md" | tr -d ' ')"
    [ "${size}" -lt "${SKILL_BYTE_LIMIT}" ] || {
      printf 'FAIL: %s/%s.SKILL.md is %s bytes, at or past the %s byte per-payload ceiling\n' \
        "${MEASURE_ROOT}/templates/common" "${name}" "${size}" "${SKILL_BYTE_LIMIT}" >&2
      return 1; }
  done
}

@test "advisor skills: the four together stay under the 40 KiB the family allows" {
  # The per-payload ceiling says none of them is oversized; this says the four do
  # not collectively eat the room the rest of the body needs inside the same
  # argument. Four files at 11 KiB each pass the test above and still overflow it.
  local name total size
  total=0
  for name in "${ADVISORS[@]}"; do
    size="$(wc -c <"${MEASURE_ROOT}/templates/common/${name}.SKILL.md" | tr -d ' ')"
    total=$((total + size))
  done
  [ "${total}" -lt "${FAMILY_BYTE_LIMIT}" ] || {
    printf 'FAIL: the four advisor skills together hold %s bytes, at or past the %s byte family ceiling\n' \
      "${total}" "${FAMILY_BYTE_LIMIT}" >&2
    return 1; }
}
