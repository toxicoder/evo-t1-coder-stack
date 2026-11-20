#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## reflect-and-evolve-repo-skill.bats - the repo-tier reflection runbook stays whole,
# linked, distinct from its sibling, and runnable.
#
# The repo ships a second reflection procedure beside the one that improves the agent
# system: skills/reflect-and-evolve-repo/SKILL.md is the canonical body for improving the
# repository itself, .grok/skills/reflect-and-evolve-repo/SKILL.md is the symlink that makes
# it a repo-tier skill the CLI discovers, references/checklist.md is the evidence-and-quality
# page the body hands the reader, and docs/grok-build-and-agents.md is the roster entry that
# tells a person the command exists. Its sweeper is the sibling's, shared and never forked.
#
# Each of those fails in a way nothing else notices. A truncated paste loses a Core Workflow
# step and the skill still loads; a copied-instead-of-linked body drifts from the seed while
# both read fine; a frontmatter key the CLI does not document is parsed, loaded, and dropped,
# so the skill silently stops being user-invocable; a body that pasted the operator's generic
# draft back keeps the instruction to maintain a CHANGELOG.md this repo does not keep, and the
# sentence still reads fine; a body that forked the sweeper would put a second, unaudited
# reader onto a store holding gigabytes of transcripts, three files of which are off-limits;
# and one non-ASCII byte or carriage return in a shipped page breaks whatever consumes it
# without breaking anything a person sees. This suite is the completeness gate for that set:
# the body against the contract's pinned frontmatter, H1, ten ordered and non-empty headings,
# verbatim spans, and exactly seven ordered categories; the link's target; the checklist page
# and its run-report skeleton; the sweeper command the body itself prints, run off a session
# tree built at runtime, against the defaults the page and the program both state; and the
# docs citation.
#
# There is no fixture and there must not be: the one case that runs the sweeper builds its
# session tree under BATS_TEST_TMPDIR, because a store written to be provably unopened is not
# something to commit into the repo.
#
# Usage: bazelisk test //tests:bats_reflect_and_evolve_repo_skill_test   (from any cwd)
# Syntax: a .bats file is not bash source, so plain bash -n exits 2 on every suite in
#         tests/bats, this one and the sibling alike. The two checks that do parse it are
#         the lint runner over this file (shellcheck -x, exit 0), and the same file with its
#         @test headers turned into function headers:
#         sed -E 's/^@test "[^"]*" \{/f_n() {/' <file> | bash -n -
# Safety: reads skills/reflect-and-evolve-repo/SKILL.md and its references page, the .grok/
#         link, the sibling body it must stay distinct from, the one sweeper both share, and
#         the docs page; writes only per-test scratch under BATS_TEST_TMPDIR. Never touches a
#         real ~/.grok session store: run_sweeper refuses a --home outside that scratch.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SKILL=""
SKILL_LINK=""
CHECKLIST=""
SIBLING=""
SWEEPER=""
DOC_PAGE=""

# The docs page, spelled as its repo-relative path, which is how the body and the seed both
# cite it.
DOC_PATH="docs/grok-build-and-agents.md"

# The two pages the body's References section has to name, spelled as the contract pins them,
# and the repo-relative form the gate greps for. The sweeper belongs to the sibling skill:
# both skills read it and neither owns a copy.
CHECKLIST_PATH="skills/reflect-and-evolve-repo/references/checklist.md"
SWEEPER_PATH="skills/reflect-and-evolve/scripts/session_signals.py"

# The ten headings the contract pins, in the order the runbook runs them. A heading that is
# renamed or moved silently shortens the procedure, so the claim is the ordered list.
HEADINGS=(
  "## When to Use"
  "## Core Workflow"
  "### 1. Gather Evidence from the Repo and Sessions"
  "### 2. Analyze for High-Leverage Project Improvements"
  "### 3. Plan Changes"
  "### 4. Implement in the Repository"
  "### 5. Validate and Summarize"
  "## Principles"
  "## Common Targets"
  "## References"
)

# The negation line the contract pins for the changelog rule: this repo keeps no first-party
# changelog, so the record is the commit message and the pull request body. Spelled once so
# the claims that read it agree on the bytes.
# shellcheck disable=SC2016  # the backticks are literal text the contract pins
CHANGELOG_NEGATION='first-party `CHANGELOG.md`'

# The spans the contract requires verbatim. Each is a substring the gate greps for, so a
# reworded seam is a red test rather than a seam that quietly stopped naming its command.
VERBATIM=(
  'bazelisk test //:test-fast'
  'bazelisk test //:lint --test_tag_filters=manual'
  'templates/common/'
  'skills/reflect-and-evolve-repo/references/checklist.md'
  'skills/reflect-and-evolve/scripts/session_signals.py'
  "${CHANGELOG_NEGATION}"
)

# Step 2's seven categories, in the pinned order, with the row pattern each must match. The
# patterns are lower-case and tolerate the spacing around a slash, because a table cell is
# prose; the claim that bites is the order and the one-row-each count.
CATEGORY_NAMES=(
  "Code quality / patterns"
  "Missing automation"
  "Documentation gaps"
  "Convention drift"
  "Testing / reliability"
  "Developer experience"
  "Architectural"
)
CATEGORY_RES=(
  'code quality[ ]*/[ ]*patterns'
  'missing automation'
  'documentation gap'
  'convention drift'
  'testing[ ]*/[ ]*reliability'
  'developer experience'
  'architectural'
)

# The five level-2 sections the checklist page pins, in the order the evidence page runs
# them: gather, read, judge, refuse, report. A renamed or dropped section silently retires
# one of those five moves while the page still reads as a checklist.
CHECKLIST_SECTIONS=(
  "## Evidence checklist"
  "## Signal reading"
  "## Change quality bar"
  "## What not to do"
  "## Run report"
)

# The pinned headings that must carry prose rather than stand empty: a heading over nothing
# is a step nobody runs. The five numbered steps are the five middle HEADINGS entries.
BODY_SECTIONS=(
  "## When to Use"
  "## Principles"
  "## Common Targets"
)

# The sweeper's own documented defaults, which the checklist page and the program's --help
# have to agree on: the page is what a reflection reads before it types the command, and a
# page that drifted from the program sends the reader to the wrong session store.
# shellcheck disable=SC2016,SC2088  # literal page text: $GROK_HOME and ~/.grok are what the reader types
SWEEPER_DEFAULTS_PAGE=(
  '$GROK_HOME'
  '~/.grok'
  'the cwd'
  '--limit` 20'
  '--since` 90'
)
# shellcheck disable=SC2016  # the help text is matched literally, dollar sign included
SWEEPER_DEFAULTS_HELP=(
  'default \$GROK_HOME, else ~/\.grok'
  'rows to print, default 20'
  'days of history to keep, default 90'
)

# The probe session's date is fixed, so the sweep pins its own window instead of trusting the
# 90-day default: a run years from now would drop the row and go red for a reason that is not
# a defect.
WINDOW=3650
PROBE_SID=01a1feed

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  SKILL="${REPO_ROOT}/skills/reflect-and-evolve-repo/SKILL.md"
  SKILL_LINK="${REPO_ROOT}/.grok/skills/reflect-and-evolve-repo/SKILL.md"
  CHECKLIST="${REPO_ROOT}/${CHECKLIST_PATH}"
  SIBLING="${REPO_ROOT}/skills/reflect-and-evolve/SKILL.md"
  SWEEPER="${REPO_ROOT}/${SWEEPER_PATH}"
  DOC_PAGE="${REPO_ROOT}/${DOC_PATH}"
}

# heading_line <file> <exact-heading> - print the line number of the heading when the file
# carries that line verbatim, nothing when it does not. Exact match, not substring: the
# contract pins the spelling, and a "## Core Workflow" that became "## Core workflow" is a
# renamed section, not a kept one.
heading_line() {
  awk -v want="${2}" '$0 == want { print NR; exit }' "${1}"
}

# body_head <file> - print the first non-blank line after the frontmatter closes. The contract
# puts the stack marker there, before the H1.
body_head() {
  awk 'NR == 1 { if ($0 != "---") exit 2; next }
       !closed && $0 == "---" { closed = 1; next }
       closed && NF { print; exit }' "${1}"
}

# after_marker <file> - print the first non-blank line after the stack marker line, which is
# where the contract puts the H1.
after_marker() {
  awk '$0 == "<!-- managed-by: evo-t1-coder-stack -->" { seen = 1; next }
       seen && NF { print; exit }' "${1}"
}

# section <file> <exact-heading> - print one level-2 section, from just after its heading to
# the next level-2 heading. The reference claim runs against this slice so a matching path
# elsewhere in the file cannot satisfy it.
section() {
  awk -v want="${2}" '$0 == want { on = 1; next }
       on && /^## / { exit }
       on { print }' "${1}"
}

# subsection <file> <exact-heading> - print one level-3 section, stopping at the next heading
# of either level.
subsection() {
  awk -v want="${2}" '$0 == want { on = 1; next }
       on && /^(##|###) / { exit }
       on { print }' "${1}"
}

# assert_ascii <file> - fail with the offending line when <file> carries a byte outside
# printable ASCII or a carriage return.
assert_ascii() {
  local file="${1}"
  if LC_ALL=C grep -q '[^[:print:][:space:]]' "${file}"; then
    echo "non-ASCII byte in ${file}: $(LC_ALL=C grep -n '[^[:print:][:space:]]' "${file}" | head -n 1)" >&2
    return 1
  fi
  if LC_ALL=C grep -q $'\r' "${file}"; then
    echo "carriage return in ${file}: $(LC_ALL=C grep -n $'\r' "${file}" | head -n 1)" >&2
    return 1
  fi
}

# make_session <dir> <sid8> <title> <turns> <tools> <toolfail> <errors> <regen> <compaction>
# <usage|-> <last_active> - write one readable session directory under <dir>, the two files
# per session the sweeper opens and nothing else. A usage of - omits the key entirely.
make_session() {
  local dir="${1}" sid="${2}" title="${3}" turns="${4}" tools="${5}" tf="${6}" err="${7}"
  local regen="${8}" comp="${9}" usage="${10}" when="${11}"
  local session="${dir}/sessions/%2Fr/${sid}-0000-7000-8000-000000000000"
  mkdir -p "${session}"
  printf '{"generated_title": "%s", "last_active_at": "%s", "num_messages": %s,\n "current_model_id": "agent", "git_root_dir": "/r"}\n' \
    "${title}" "${when}" "${turns}" >"${session}/summary.json"
  if [[ "${usage}" == "-" ]]; then
    printf '{"turnCount": %s, "toolCallCount": %s, "toolFailureCount": %s, "errorCount": %s,\n "regenerationCount": %s, "compactionCount": %s}\n' \
      "${turns}" "${tools}" "${tf}" "${err}" "${regen}" "${comp}" >"${session}/signals.json"
  else
    printf '{"turnCount": %s, "toolCallCount": %s, "toolFailureCount": %s, "errorCount": %s,\n "regenerationCount": %s, "compactionCount": %s, "contextWindowUsage": %s}\n' \
      "${turns}" "${tools}" "${tf}" "${err}" "${regen}" "${comp}" "${usage}" >"${session}/signals.json"
  fi
  printf '%s' "${session}"
}

# run_sweeper <dir> <home> <program> [flag...] - run the sweeper <program> with the flags the
# body itself hands the reader, its two streams captured under <dir>, and print its exit
# status. The window and the repo are pinned on every call so no run can fall back to the
# 90-day default and empty the table as the probe's fixed date ages out. The home is refused
# unless this test built it: a suite that sweeps a session store only ever sweeps one it wrote
# itself.
run_sweeper() {
  local dir="${1}" home="${2}" program="${3}" rc=0
  shift 3
  if [[ "${home}" != "${BATS_TEST_TMPDIR}"/* ]]; then
    echo "run_sweeper refuses --home ${home}: it is not under ${BATS_TEST_TMPDIR}" >&2
    return 1
  fi
  mkdir -p "${dir}"
  python3 "${program}" "$@" --home "${home}" --repo /r --since "${WINDOW}" \
    >"${dir}/out" 2>"${dir}/err" || rc="${?}"
  printf '%s' "${rc}"
}

# body_sweeper_command <file> - print the backtick-delimited command the body hands the reader
# for the session sweep: the literal line a reflection types. Empty when the body shows no
# runnable form, which is what makes the sweep claim test the reader's command rather than a
# path this suite picked for itself.
body_sweeper_command() {
  # shellcheck disable=SC2016  # the backticks delimit the command span in the markdown body
  grep -oE '`python3 [^`]*session_signals[^`]*`' "${1}" | head -n 1 | tr -d '`'
}

# category_line <file> <lowercase-regex> - print the line number of the first markdown table
# row whose text matches <lowercase-regex>, nothing when no row does. Restricting the match
# to a row is what makes the claim "the table carries the category" rather than "the word
# appears somewhere".
category_line() {
  awk -v re="${2}" '
    { line = tolower($0) }
    /^[ ]*\|/ && line ~ re { print NR; exit }
  ' "${1}"
}

@test "reflect_and_evolve_repo_skill: the canonical body and the repo-tier link are one file" {
  # Silent failure: a second copy of the body loads fine, reads fine, and drifts from the
  # seed the day either one is edited.
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

@test "reflect_and_evolve_repo_skill: frontmatter parses, names the skill, and sells it well enough to fire" {
  # Silent failure: an undocumented key loads and is ignored, and a thin description simply
  # never fires, so the skill exists and nobody can reach it.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  python3 - "${SKILL}" <<'RFE_REPO_FRONTMATTER_CHECK'
import sys

import yaml

# The keys Grok Build documents for a skill. Anything else parses, loads, and is then ignored
# by the CLI, which is how an operator's intent silently stops taking effect.
ALLOWED = {
    "name",
    "description",
    "when-to-use",
    "allowed-tools",
    "argument-hint",
    "user-invocable",
    "disable-model-invocation",
    "model",
    "effort",
    "license",
    "compatibility",
    "metadata",
}

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

if not lines or lines[0] != "---":
    raise SystemExit("%s: line 1 must open the frontmatter with ---" % path)
try:
    end = lines.index("---", 1)
except ValueError:
    raise SystemExit("%s: the frontmatter never closes" % path)

doc = yaml.safe_load("\n".join(lines[1:end]))
if not isinstance(doc, dict):
    raise SystemExit("%s: frontmatter is not a mapping" % path)

undocumented = sorted(set(doc) - ALLOWED)
if undocumented:
    raise SystemExit("%s: undocumented frontmatter keys: %s" % (path, ", ".join(undocumented)))
if doc.get("name") != "reflect-and-evolve-repo":
    raise SystemExit(
        "%s: name must be reflect-and-evolve-repo, got %r" % (path, doc.get("name"))
    )

# Discovery keys off the folder name, but the description is what the model matches on; a
# short one never fires, and the three words a person actually types have to be in it.
description = doc.get("description") or ""
if len(description) <= 200:
    raise SystemExit(
        "%s: description is %d characters, too short to fire" % (path, len(description))
    )
for phrase in ("reflect", "sessions", "codebase"):
    if phrase not in description.lower():
        raise SystemExit("%s: description does not carry %r" % (path, phrase))

# The operator's own two keys sit under metadata beside author and short-description: at the
# top level the CLI would read and drop them. Presence is not the claim; a reference-type or
# a retired lifecycle is a different thing to load, and it still parses.
metadata = doc.get("metadata")
if not isinstance(metadata, dict):
    raise SystemExit("%s: metadata must be a mapping, got %r" % (path, type(metadata).__name__))
for key, want in (("type", "workflow"), ("lifecycle", "active")):
    if metadata.get(key) != want:
        raise SystemExit(
            "%s: metadata.%r is %r, expected %r" % (path, key, metadata.get(key), want)
        )

# The two keys that switch the skill off without breaking the file: user-invocable false hides
# it from a person, and disable-model-invocation true stops the model ever firing it. Both
# load, both read fine, and neither shows up anywhere else in the gate.
if "user-invocable" in doc and not doc["user-invocable"]:
    raise SystemExit(
        "%s: user-invocable is %r, so nobody can call the skill by name" % (path, doc["user-invocable"])
    )
if "disable-model-invocation" in doc and doc["disable-model-invocation"]:
    raise SystemExit(
        "%s: disable-model-invocation is %r, so the model never fires the skill"
        % (path, doc["disable-model-invocation"])
    )
RFE_REPO_FRONTMATTER_CHECK
}

@test "reflect_and_evolve_repo_skill: the body opens as the contract pins it and runs its sections in order" {
  # Silent failure: a body that lost step 4 or renamed a section still loads and still reads
  # like a runbook, so the only thing that says the procedure is short is this claim.
  local head h1 line seen=0 last=0 heading body
  head="$(body_head "${SKILL}")"
  [[ "${head}" == "<!-- managed-by: evo-t1-coder-stack -->" ]] || {
    echo "the first line after the frontmatter is '${head}', not the stack marker" >&2
    return 1
  }
  h1="$(after_marker "${SKILL}")"
  [[ "${h1}" == "# Reflect and Evolve (Repo) - Continuous Improvement of the Current Codebase" ]] || {
    echo "the H1 is '${h1}'" >&2
    return 1
  }
  for heading in "${HEADINGS[@]}"; do
    line="$(heading_line "${SKILL}" "${heading}")"
    [[ -n "${line}" ]] || {
      echo "no heading line for '${heading}'" >&2
      return 1
    }
    ((line > last)) || {
      echo "'${heading}' sits out of order (line ${line} after ${last})" >&2
      return 1
    }
    last="${line}"
    ((seen += 1))
  done
  [[ ${seen} -eq 10 ]] || {
    echo "matched ${seen} of ${#HEADINGS[@]} pinned headings" >&2
    return 1
  }
  # A heading that survived with nothing under it is a step that was cut and a section that
  # was pasted as a placeholder, so each pinned section is also held to carrying content. The
  # five numbered steps are the middle five HEADINGS entries; References is held to the same
  # bar by the reference claim, and Core Workflow by the five steps that sit inside it.
  for heading in "${BODY_SECTIONS[@]}" "${HEADINGS[@]:2:5}"; do
    if [[ "${heading}" == '### '* ]]; then
      body="$(subsection "${SKILL}" "${heading}")"
    else
      body="$(section "${SKILL}" "${heading}")"
    fi
    grep -q '[^[:space:]]' <<<"${body}" || {
      echo "'${heading}' has no content under it" >&2
      return 1
    }
  done
}

@test "reflect_and_evolve_repo_skill: the body names its reference pages and both exist" {
  # Silent failure: prose that points at a page nobody shipped reads perfectly, and the
  # reader finds out by opening a path that is not there. The paths are extracted from the
  # slice rather than substring-grepped, because a pinned span is also a substring of a
  # renamed target: References aimed at checklist.md.bak satisfies a grep and sends the reader
  # nowhere.
  local block page paths rel extracted=0
  block="$(section "${SKILL}" "## References")"
  [[ -n "${block}" ]] || {
    echo "no '## References' section in ${SKILL}" >&2
    return 1
  }
  # shellcheck disable=SC2016  # the backticks delimit the path spans in the markdown slice
  paths="$(grep -oE '`[^`]+`' <<<"${block}" | tr -d '`' | grep -E '\.(md|py)$' || true)"
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    ((extracted += 1))
    [[ -f "${REPO_ROOT}/${rel}" ]] || {
      echo "the References section points at ${rel}, which is not on disk:" >&2
      printf '%s\n' "${block}" >&2
      return 1
    }
  done <<<"${paths}"
  [[ ${extracted} -ge 2 ]] || {
    echo "the References section carries ${extracted} backtick-delimited paths, expected two" >&2
    printf '%s\n' "${block}" >&2
    return 1
  }
  for page in "${CHECKLIST_PATH}" "${SWEEPER_PATH}"; do
    grep -qxF -- "${page}" <<<"${paths}" || {
      echo "the References section never names ${page} as a path of its own:" >&2
      printf '%s\n' "${block}" >&2
      return 1
    }
  done
}

@test "reflect_and_evolve_repo_skill: the body carries this repo's seams and none of the un-adapted draft" {
  # Silent failure: the two things that make this body a repo run rather than a generic
  # paste are two sentences, and a reworded one reads just as well while sending a reader
  # somewhere that does not exist here.
  local span changelog offenders
  for span in "${VERBATIM[@]}"; do
    grep -qF -- "${span}" "${SKILL}" || {
      echo "the body never carries the pinned span: ${span}" >&2
      return 1
    }
  done
  # The operator's draft closed step 4 by telling the reader to document changes in a
  # CHANGELOG.md this repo does not keep. The contract pins the adaptation, so the draft
  # sentence coming back is a regression and not a style choice.
  if grep -qiE 'document significant changes in relevant[ ]+changelog' "${SKILL}"; then
    echo "the un-adapted draft instruction to document changes in a CHANGELOG is back:" >&2
    grep -niE 'document significant changes in relevant[ ]+changelog' "${SKILL}" >&2
    return 1
  fi
  # The pinned negation is the one changelog line the contract wants. Every other line that
  # names a changelog may mention one a target repo keeps; none may instruct the reader to
  # maintain one, which is an imperative verb plus the word with no negation near it.
  grep -qF -- "${CHANGELOG_NEGATION}" "${SKILL}" || {
    echo "the body no longer says this repo keeps no first-party changelog" >&2
    return 1
  }
  changelog="$(grep -in 'changelog' "${SKILL}" |
    grep -vF -- "${CHANGELOG_NEGATION}" || true)"
  offenders="$(printf '%s\n' "${changelog}" |
    grep -iE '(^|[^[:alnum:]_])(document|update|maintain|append|add|write|edit|create|record)([^[:alnum:]_]|$)' |
    grep -viwE 'no|not|never|none|neither|without' || true)"
  [[ -z "${offenders}" ]] || {
    echo "leftover instruction to maintain a changelog: ${offenders}" >&2
    return 1
  }
}

@test "reflect_and_evolve_repo_skill: every file the skill ships is pure ASCII with no carriage return" {
  # Silent failure: one curly quote or CRLF in a shipped page is invisible in the editor and
  # breaks whatever later consumes the bytes, so the count is checked too or an empty tree
  # would satisfy the loop.
  local file checked=0
  # Runfiles hand these over as symlinks into the source tree, so -type f alone matches
  # nothing here; -type l plus the file test reads the bytes that actually ship.
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    assert_ascii "${file}" || return 1
    ((checked += 1))
  done < <(find "${REPO_ROOT}/skills/reflect-and-evolve-repo" \( -type f -o -type l \) | sort)
  [[ ${checked} -ge 2 ]] || {
    echo "only ${checked} file(s) under skills/reflect-and-evolve-repo/, expected the body and the checklist page" >&2
    return 1
  }
}

@test "reflect_and_evolve_repo_skill: the checklist page carries its five pinned sections" {
  # Silent failure: a page whose sections were cut, renamed, or left as headings over nothing
  # still loads, and the reader meets the hole mid-reflection instead of before the proposal.
  local section_name line last=0 seen=0 count empties h1s h1line placeholders report
  [[ -s "${CHECKLIST}" ]] || {
    echo "missing or empty ${CHECKLIST}" >&2
    return 1
  }
  for section_name in "${CHECKLIST_SECTIONS[@]}"; do
    line="$(heading_line "${CHECKLIST}" "${section_name}")"
    [[ -n "${line}" ]] || {
      echo "no heading line for '${section_name}' in ${CHECKLIST}" >&2
      return 1
    }
    ((line > last)) || {
      echo "'${section_name}' sits out of order (line ${line} after ${last})" >&2
      return 1
    }
    last="${line}"
    ((seen += 1))
  done
  [[ ${seen} -eq ${#CHECKLIST_SECTIONS[@]} ]] || {
    echo "matched ${seen} of ${#CHECKLIST_SECTIONS[@]} pinned sections" >&2
    return 1
  }
  # Nothing else may pose as a section: a sixth or a duplicated level-2 heading is a section
  # the contract never pinned, and a rename that left the old one behind reads fine.
  count="$(awk '/^```/ { fence = !fence } !fence && /^## / { n++ } END { print n + 0 }' "${CHECKLIST}")"
  [[ "${count}" -eq ${#CHECKLIST_SECTIONS[@]} ]] || {
    echo "the checklist carries ${count} '## ' sections, expected the five it pins:" >&2
    awk '/^```/ { fence = !fence } !fence && /^## / { printf "  line %d: %s\n", NR, $0 }' \
      "${CHECKLIST}" >&2
    return 1
  }
  # One title above the sections: two H1s is a page assembled from two drafts, and a title
  # after the first section is a page whose head was pasted in at the wrong end.
  h1s="$(awk '/^```/ { fence = !fence } !fence && /^# / { n++ } END { print n + 0 }' "${CHECKLIST}")"
  [[ "${h1s}" -eq 1 ]] || {
    echo "${CHECKLIST} carries ${h1s} level-1 headings, expected one title above the five sections" >&2
    return 1
  }
  h1line="$(awk '/^```/ { fence = !fence } !fence && /^# / { print NR; exit }' "${CHECKLIST}")"
  line="$(heading_line "${CHECKLIST}" "${CHECKLIST_SECTIONS[0]}")"
  [[ -n "${h1line}" && ${h1line} -lt ${line} ]] || {
    echo "the checklist's title (line ${h1line:-none}) does not precede its first section (line ${line})" >&2
    return 1
  }
  # A heading with nothing between it and the next heading is a stub, not a section.
  empties="$(awk '
    /^```/ { fence = !fence }
    fence { next }
    /^#/ { if (head != "" && blank) print head; head = $0; blank = 1; next }
    NF { blank = 0 }
    END { if (head != "" && blank) print head }
  ' "${CHECKLIST}")"
  [[ -z "${empties}" ]] || {
    echo "a heading in ${CHECKLIST} has nothing under it: ${empties}" >&2
    return 1
  }
  # The page is the evidence page, so it has to hand over the sweeper as a command the reader
  # can paste and a report the body's step 5 can copy, not merely name them.
  grep -qF -- "${SWEEPER_PATH}" "${CHECKLIST}" || {
    echo "the checklist never names ${SWEEPER_PATH}" >&2
    return 1
  }
  grep -qE 'python3[ ]+[^ ]*session_signals\.py' "${CHECKLIST}" || {
    echo "the checklist never shows the sweeper being run with python3:" >&2
    grep -n 'session_signals' "${CHECKLIST}" >&2
    return 1
  }
  # The two report claims run against the '## Run report' slice alone. The page carries
  # <path>-style placeholders elsewhere, so a count taken over the whole file stays green with
  # the skeleton itself gutted, which is exactly how a report section becomes a paragraph.
  report="$(section "${CHECKLIST}" "## Run report")"
  placeholders="$(grep -c '<[A-Za-z][^<>]*>' <<<"${report}" || true)"
  [[ ${placeholders} -ge 3 ]] || {
    echo "the '## Run report' slice carries ${placeholders} placeholder lines, too few to be a skeleton" >&2
    printf '%s\n' "${report}" >&2
    return 1
  }
  grep -qiE 'skeleton' <<<"${report}" || {
    echo "the '## Run report' slice names no skeleton for the body's step 5 to copy:" >&2
    printf '%s\n' "${report}" >&2
    return 1
  }
}

@test "reflect_and_evolve_repo_skill: the body's category table carries every pinned category in order" {
  # Silent failure: step 2 ranks findings against this table, so a dropped or reordered row
  # silently retires one whole class of improvement and the run still reports a full sweep.
  local i name re line seen=0 last=0 alt="" row_count
  for i in "${!CATEGORY_NAMES[@]}"; do
    name="${CATEGORY_NAMES[i]}"
    re="${CATEGORY_RES[i]}"
    line="$(category_line "${SKILL}" "${re}")"
    [[ -n "${line}" ]] || {
      echo "no table row in ${SKILL} carries the category '${name}'" >&2
      return 1
    }
    ((line > last)) || {
      echo "the category '${name}' sits out of order (row line ${line} after ${last})" >&2
      return 1
    }
    last="${line}"
    ((seen += 1))
  done
  [[ ${seen} -eq ${#CATEGORY_NAMES[@]} ]] || {
    echo "matched ${seen} of ${#CATEGORY_NAMES[@]} pinned categories" >&2
    return 1
  }
  # Presence and order are not the size of the table. category_line answers with the first
  # match, so a class pasted twice, or an eighth one added on a later edit, keeps every first
  # match ascending while the table no longer holds the seven the contract pins.
  for re in "${CATEGORY_RES[@]}"; do
    alt="${alt:+${alt}|}${re}"
  done
  row_count="$(grep -cEi "^[ ]*[|].*(${alt})" "${SKILL}" || true)"
  [[ "${row_count}" -eq ${#CATEGORY_NAMES[@]} ]] || {
    echo "the category table carries ${row_count} rows, expected exactly ${#CATEGORY_NAMES[@]}:" >&2
    grep -niE "^[ ]*[|].*(${alt})" "${SKILL}" >&2
    return 1
  }
}

@test "reflect_and_evolve_repo_skill: the new body is a distinct skill and not a copy of the sibling" {
  # Silent failure: a rename of the sibling body passes every structural claim above, keeps
  # pointing a repo reflection at the agent setup, and forks or loses the one sweeper.
  [[ -f "${SIBLING}" ]] || {
    echo "missing ${SIBLING}: nothing to be distinct from" >&2
    return 1
  }
  if cmp -s "${SKILL}" "${SIBLING}"; then
    echo "${SKILL} is a byte-for-byte copy of the sibling body" >&2
    return 1
  fi
  if grep -qF -- '# Reflect and Evolve - Continuous Self-Improvement of the Agent System' "${SKILL}"; then
    echo "the new body still carries the sibling's H1, so it is a rename and not a second skill" >&2
    return 1
  fi
  # The pair has to point at each other: the new skill sends an agent-setup ask to the
  # sibling. The leading class excludes a path segment, so skills/reflect-and-evolve/...
  # cannot satisfy it, and the trailing class excludes the new skill's own longer name.
  grep -qE '(^|[^[:alnum:]_/])/reflect-and-evolve($|[^-])' "${SKILL}" || {
    echo "the new body never hands the agent-setup case to /reflect-and-evolve" >&2
    return 1
  }
  # And the sweeper stays shared: neither new page may name one under the new skill's own
  # directory, both must name the sibling's, and no fork may exist on disk.
  local page
  for page in "${SKILL}" "${CHECKLIST}"; do
    [[ -f "${page}" ]] || continue
    if grep -qE 'reflect-and-evolve-repo/[^ ]*session_signals\.py' "${page}"; then
      echo "a forked sweeper is named at $(grep -nE 'reflect-and-evolve-repo/[^ ]*session_signals\.py' "${page}" | head -n 1)" >&2
      return 1
    fi
    grep -qF -- "${SWEEPER_PATH}" "${page}" || {
      echo "${page} never names the shared sweeper ${SWEEPER_PATH}" >&2
      return 1
    }
  done
  if [[ -e "${REPO_ROOT}/skills/reflect-and-evolve-repo/scripts/session_signals.py" ]]; then
    echo "the sweeper was forked into skills/reflect-and-evolve-repo/scripts/: it is shared, never copied" >&2
    return 1
  fi
}

@test "reflect_and_evolve_repo_skill: the body hands the reader a sweeper that actually runs" {
  # Silent failure: the body tells a reader to run one program to get into a store holding
  # gigabytes of transcripts. If that command no longer names a program that starts, or the
  # program stops printing rows, the reflection degrades into reading a transcript by hand,
  # and nothing in the skill itself says so. The command is read out of the body rather than
  # chosen here: this suite can prove the line the reader types works, and a path chosen here
  # would prove only that some program exists.
  local tree session rc out err last invocation program word program_rel
  local -a argv=() flags=()
  [[ -f "${SKILL}" ]] || {
    echo "missing ${SKILL}: there is no body to hand a reader anything" >&2
    return 1
  }
  invocation="$(body_sweeper_command "${SKILL}")"
  [[ -n "${invocation}" ]] || {
    echo "the body shows no backtick-delimited python3 ... session_signals command to run:" >&2
    grep -n 'session_signals' "${SKILL}" >&2
    return 1
  }
  read -r -a argv <<<"${invocation}"
  [[ "${argv[0]:-}" == "python3" ]] || {
    echo "the command the body hands the reader starts with '${argv[0]:-}', not python3: ${invocation}" >&2
    return 1
  }
  program_rel=""
  for word in "${argv[@]:1}"; do
    if [[ -z "${program_rel}" && "${word}" == *session_signals.py ]]; then
      program_rel="${word}"
      continue
    fi
    flags+=("${word}")
  done
  [[ -n "${program_rel}" ]] || {
    echo "the command the body hands the reader names no session_signals.py program: ${invocation}" >&2
    return 1
  }
  [[ "${program_rel}" == "${SWEEPER_PATH}" ]] || {
    echo "the body points the reader at ${program_rel}, not the shared sweeper ${SWEEPER_PATH}" >&2
    return 1
  }
  program="${REPO_ROOT}/${program_rel}"
  [[ -f "${program}" ]] || {
    echo "the command the body hands the reader runs ${program}, which is not on disk" >&2
    return 1
  }
  tree="${BATS_TEST_TMPDIR}/store"
  session="$(make_session "${tree}" "${PROBE_SID}" "tighten the compose profiles" 6 14 1 0 1 0 22 \
    2026-11-19T09:00:00.000000Z)"
  # The probe has to exist, or the empty table below would be a pass.
  [[ -s "${session}/summary.json" && -s "${session}/signals.json" ]] || {
    echo "the probe tree built no session files under ${session}, so the sweep would be vacuous" >&2
    return 1
  }
  out="${BATS_TEST_TMPDIR}/run/out"
  err="${BATS_TEST_TMPDIR}/run/err"
  rc="$(run_sweeper "${BATS_TEST_TMPDIR}/run" "${tree}" "${program}" "${flags[@]}")" || {
    echo "run_sweeper refused to sweep ${tree}" >&2
    return 1
  }
  [[ "${rc}" -eq 0 ]] || {
    echo "the sweeper exited ${rc} on the probe tree" >&2
    cat "${err}" >&2
    return 1
  }
  [[ "$(sed -n '1p' "${out}")" == "== session signals ==" ]] || {
    echo "the first line is '$(sed -n '1p' "${out}")', not '== session signals =='" >&2
    cat "${out}" >&2
    return 1
  }
  grep -q "^${PROBE_SID} " "${out}" || {
    echo "the sweep printed no row for the probe session ${PROBE_SID}:" >&2
    cat "${out}" "${err}" >&2
    return 1
  }
  last="$(tail -n 1 "${out}")"
  [[ "${last}" == "summary: 1 ok, 0 warnings, 0 failed" ]] || {
    echo "the closing line is '${last}', expected 'summary: 1 ok, 0 warnings, 0 failed'" >&2
    cat "${out}" >&2
    return 1
  }
}

@test "reflect_and_evolve_repo_skill: the docs page lists the skill in the repo-scoped runbook" {
  # Silent failure: an undiscoverable skill is a file nobody runs, and the roster reads fine
  # whether or not it names the command.
  [[ -f "${DOC_PAGE}" ]] || {
    echo "missing ${DOC_PAGE}: the roster never tells a person the command exists" >&2
    return 1
  }
  local block
  block="$(subsection "${DOC_PAGE}" "### The repo-scoped runbook")"
  [[ -n "${block}" ]] || {
    echo "${DOC_PATH} has no '### The repo-scoped runbook' subsection" >&2
    return 1
  }
  # The command, not merely a path that contains the same letters: the leading class rules
  # out a path segment, so only a real /reflect-and-evolve-repo mention satisfies this.
  grep -qE '(^|[^[:alnum:]_/])/reflect-and-evolve-repo($|[^-])' <<<"${block}" || {
    echo "the repo-scoped runbook subsection never names /reflect-and-evolve-repo" >&2
    return 1
  }
  # The canonical-path claim, anchored the same way: skills/... is a substring of the
  # .grok/skills/... symlink line, so an unanchored grep is satisfied by the discovery
  # sentence alone and the subsection can drop "canonical at" without going red.
  grep -qE '(^|[^[:alnum:]_./])skills/reflect-and-evolve-repo/SKILL\.md' <<<"${block}" || {
    echo "the subsection does not say the canonical body is skills/reflect-and-evolve-repo/SKILL.md" >&2
    return 1
  }
}

@test "reflect_and_evolve_repo_skill: the checklist page and the sweeper agree on the defaults" {
  # Silent failure: the page is what a reflection reads before it types the command. A page
  # whose --home default drifted sends every reader at the wrong profile home, and neither
  # the prose nor the program's own --help complains about the other half being wrong.
  local block defaults help re
  block="$(section "${CHECKLIST}" "## Evidence checklist")"
  [[ -n "${block}" ]] || {
    echo "no '## Evidence checklist' section in ${CHECKLIST}" >&2
    return 1
  }
  defaults="$(grep -m1 'Defaults:' <<<"${block}" || true)"
  [[ -n "${defaults}" ]] || {
    echo "the Evidence checklist states no Defaults: line for the sweeper" >&2
    return 1
  }
  for re in "${SWEEPER_DEFAULTS_PAGE[@]}"; do
    grep -qF -- "${re}" <<<"${defaults}" || {
      echo "the page's Defaults line never states ${re}: ${defaults}" >&2
      return 1
    }
  done
  # The same facts as the program states them, so the page is checked against the sweeper and
  # not against this suite's memory of it. COLUMNS is set so argparse cannot wrap a help line
  # across two and hide the number from the match.
  [[ -f "${SWEEPER}" ]] || {
    echo "missing ${SWEEPER}: there is no program left to agree with the page" >&2
    return 1
  }
  help="${BATS_TEST_TMPDIR}/help.txt"
  COLUMNS=200 python3 "${SWEEPER}" --help >"${help}" 2>&1 || {
    echo "the sweeper --help exited $?" >&2
    return 1
  }
  for re in "${SWEEPER_DEFAULTS_HELP[@]}"; do
    grep -qE -- "${re}" "${help}" || {
      echo "the sweeper --help does not state ${re}:" >&2
      cat "${help}" >&2
      return 1
    }
  done
  # And the help strings still feed their own arguments: a constant that stopped binding is a
  # documented default that lies, on both sides of the seam at once.
  grep -qE '^DEFAULT_LIMIT = 20$' "${SWEEPER}" || {
    echo "the sweeper no longer declares a 20-row default" >&2
    grep -n 'DEFAULT_LIMIT' "${SWEEPER}" >&2
    return 1
  }
  grep -qE '^DEFAULT_SINCE_DAYS = 90$' "${SWEEPER}" || {
    echo "the sweeper no longer declares a 90-day default" >&2
    grep -n 'DEFAULT_SINCE_DAYS' "${SWEEPER}" >&2
    return 1
  }
}
