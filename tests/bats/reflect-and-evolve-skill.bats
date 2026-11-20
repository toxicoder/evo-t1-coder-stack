#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## reflect-and-evolve-skill.bats - the reflection runbook stays whole, linked, and runnable.
#
# The repo ships one reusable procedure for turning past sessions into planned changes to the
# agent system: skills/reflect-and-evolve/SKILL.md is the canonical body,
# .grok/skills/reflect-and-evolve/SKILL.md is the symlink that makes it a repo-tier skill the
# CLI discovers, references/checklist.md is the evidence-and-quality page the body hands the
# reader, scripts/session_signals.py is the sweeper step 1 runs, and
# docs/grok-build-and-agents.md is the roster entry that tells a person the command exists.
#
# Each of those fails in a way nothing else notices. A truncated paste loses a Core Workflow
# step and the skill still loads; a copied-instead-of-linked body drifts from the seed while
# both read fine; a frontmatter key the CLI does not document is silently dropped, so the
# skill stops being user-invocable; and the sweeper is the ONLY sanctioned way into a session
# store holding gigabytes of transcripts, so a regression that prints a raw field, a non-ASCII
# title, or an over-long line, or that opens a file it should not, is a leak the next
# reflection performs. This suite is the completeness gate for that set: the body's structure,
# the link's target, the two reference pages, the sweeper's pinned output shape on a shipped
# fixture, and the docs citation.
#
# Usage: bazelisk test //tests:bats_reflect_and_evolve_skill_test   (from any cwd)
# Safety: reads skills/reflect-and-evolve/SKILL.md, its references page and its sweeper, the
#         .grok/ link, the fixture session tree under tests/bats/fixtures/, and the docs page;
#         writes only per-test scratch. Never touches a real ~/.grok session store.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SKILL=""
SKILL_LINK=""
CHECKLIST=""
SWEEPER=""
FIXTURE=""
DOC_PAGE=""

# The docs page, spelled as its repo-relative path, which is how the body and the seed both
# cite it.
DOC_PATH="docs/grok-build-and-agents.md"

# The ten headings the contract pins, in the order the runbook runs them. A heading that is
# renamed or moved silently shortens the procedure, so the claim is the ordered list.
HEADINGS=(
  "## When to Use"
  "## Core Workflow"
  "### 1. Gather Evidence"
  "### 2. Analyze for High-Leverage Opportunities"
  "### 3. Plan Changes"
  "### 4. Implement"
  "### 5. Validate and Summarize"
  "## Principles"
  "## Common Targets"
  "## References"
)

# The fixture's rows in the order the friction score puts them: 2*toolfail + 2*errors +
# regen + compaction, descending, then recency. The fourth session is the unparsable one the
# run has to warn about instead of dying on.
ROW_SIDS=(01a1aaaa 01a1cccc 01a1bbbb)
ROW_TITLES=("add grafana dashboards" "rename the template twin" "fix litellm routing")
WARNED_SID=01a1dddd

# The fixture's session dates are fixed, so a run years from now would drop every row under
# the default 90-day window and the suite would go red for a reason that is not a defect.
# Every call widens the window instead of pinning the age column, which drifts by the hour.
WINDOW=3650

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  SKILL="${REPO_ROOT}/skills/reflect-and-evolve/SKILL.md"
  SKILL_LINK="${REPO_ROOT}/.grok/skills/reflect-and-evolve/SKILL.md"
  CHECKLIST="${REPO_ROOT}/skills/reflect-and-evolve/references/checklist.md"
  SWEEPER="${REPO_ROOT}/skills/reflect-and-evolve/scripts/session_signals.py"
  # The fixture is this suite's own tree, so it is reached from the suite directory rather
  # than by re-spelling the suite path.
  FIXTURE="${BATS_TEST_DIRNAME}/fixtures/reflect-and-evolve-skill"
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
# the next level-2 heading. The reference and runbook claims both run against this slice so a
# matching path elsewhere in the file cannot satisfy them.
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

# sweep <dir> <home> <args...> - run the sweeper against <home> with its two streams captured
# to <dir>/out and <dir>/err, and print its exit status. Every call in this suite points
# --home at a tree this suite ships or a per-test scratch directory, never at a real profile.
sweep() {
  local dir="${1}" home="${2}"
  shift 2
  local rc=0
  mkdir -p "${dir}"
  # shellcheck disable=SC2086  # the caller passes the sweeper's own argv
  python3 "${SWEEPER}" --home "${home}" "$@" >"${dir}/out" 2>"${dir}/err" || rc="${?}"
  printf '%s' "${rc}"
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

@test "reflect_and_evolve_skill: the canonical body and the repo-tier link are one file" {
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

@test "reflect_and_evolve_skill: frontmatter parses, names the skill, and sells it well enough to fire" {
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"
  python3 - "${SKILL}" <<'RFE_FRONTMATTER_CHECK'
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
if doc.get("name") != "reflect-and-evolve":
    raise SystemExit(
        "%s: name must be reflect-and-evolve, got %r" % (path, doc.get("name"))
    )

# Discovery keys off the folder name, but the description is what the model matches on; a
# short one never fires, and the two words a person actually types have to be in it.
description = doc.get("description") or ""
if len(description) <= 200:
    raise SystemExit(
        "%s: description is %d characters, too short to fire" % (path, len(description))
    )
for phrase in ("reflect", "sessions"):
    if phrase not in description.lower():
        raise SystemExit("%s: description does not carry %r" % (path, phrase))

# The operator's own two keys sit under metadata beside author and short-description.
metadata = doc.get("metadata")
if not isinstance(metadata, dict):
    raise SystemExit("%s: metadata must be a mapping, got %r" % (path, type(metadata).__name__))
for key in ("type", "lifecycle"):
    if key not in metadata:
        raise SystemExit("%s: metadata is missing %r" % (path, key))
RFE_FRONTMATTER_CHECK
}

@test "reflect_and_evolve_skill: the body opens as the contract pins it and runs its sections in order" {
  local head h1 line seen=0 last=0 heading
  head="$(body_head "${SKILL}")"
  [[ "${head}" == "<!-- managed-by: evo-t1-coder-stack -->" ]] || {
    echo "the first line after the frontmatter is '${head}', not the stack marker" >&2
    return 1
  }
  h1="$(after_marker "${SKILL}")"
  [[ "${h1}" == "# Reflect and Evolve - Continuous Self-Improvement of the Agent System" ]] || {
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
}

@test "reflect_and_evolve_skill: the body names its two reference pages and both exist" {
  local block page
  block="$(section "${SKILL}" "## References")"
  [[ -n "${block}" ]] || {
    echo "no '## References' section in ${SKILL}" >&2
    return 1
  }
  for page in \
    "skills/reflect-and-evolve/references/checklist.md" \
    "skills/reflect-and-evolve/scripts/session_signals.py"; do
    grep -qF -- "${page}" <<<"${block}" || {
      echo "the References section never names ${page}" >&2
      return 1
    }
  done
  [[ -f "${CHECKLIST}" ]] || {
    echo "missing ${CHECKLIST}: the page the body sends a reader to is not there" >&2
    return 1
  }
  [[ -f "${SWEEPER}" ]] || {
    echo "missing ${SWEEPER}: step 1 tells the reader to run a program that is not there" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: the body carries this repo's seams and none of the source text's" {
  # The two stack-specific seams: the change is not done until the gate is green, and the
  # thing a reflection edits is the seed under templates/common/, never the workspace copy.
  grep -qF -- 'bazelisk test //:test-fast' "${SKILL}" || {
    echo "the body never names the gate a reflection has to run" >&2
    return 1
  }
  grep -qF -- 'templates/common/GROK_BUILD_AGENTS.md' "${SKILL}" || {
    echo "the body never names the rulebook seed a reflection edits instead of ~/.grok" >&2
    return 1
  }
  # The body was adapted from a generic skill that told the reader to reach for
  # scripts/init_skill.py and to maintain a changelog. Neither belongs in this repo, and a
  # paste that reverts the adaptation is silent: the sentence still reads fine.
  if grep -qF -- 'init_skill.py' "${SKILL}"; then
    echo "leftover init_skill.py instruction: $(grep -nF 'init_skill.py' "${SKILL}" | head -n 1)" >&2
    return 1
  fi
  local changelog
  changelog="$(grep -in 'changelog' "${SKILL}" |
    grep -vF -- 'first-party `CHANGELOG.md`' |
    grep -vF -- 'previous CHANGELOG entries or improvement notes' || true)"
  # The two surviving lines are the negation (this repo keeps no first-party changelog) and
  # the evidence step that notes a target repo's own entries; anything else is an instruction
  # to write one.
  [[ -z "${changelog}" ]] || {
    echo "leftover changelog instruction: ${changelog}" >&2
    return 1
  }
  grep -qF -- 'first-party `CHANGELOG.md`' "${SKILL}" || {
    echo "the body no longer says this repo keeps no first-party changelog" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: the sweeper prints the pinned shape on the shipped fixture" {
  local scratch rc last i row
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r --since "${WINDOW}")"
  [[ "${rc}" -eq 0 ]] || {
    echo "the sweeper exited ${rc} on the shipped fixture" >&2
    cat "${scratch}/err" >&2
    return 1
  }
  [[ -s "${FIXTURE}/sessions/%2Fr/01a1aaaa-0000-7000-8000-000000000001/signals.json" ]] || {
    echo "the fixture session tree is missing under ${FIXTURE}" >&2
    return 1
  }
  local -a lines=()
  mapfile -t lines <"${scratch}/out"
  [[ "${lines[0]:-}" == "== session signals ==" ]] || {
    echo "the first line is '${lines[0]:-}', not '== session signals =='" >&2
    return 1
  }
  # The three readable rows, in score order. The age column is not asserted: it is a function
  # of the wall clock, so pinning it would make this suite rot on the calendar.
  for i in 0 1 2; do
    row="${lines[i + 1]:-}"
    [[ "${row}" == "${ROW_SIDS[i]} ${ROW_TITLES[i]}"* ]] || {
      echo "row $((i + 1)) is '${row}', expected '${ROW_SIDS[i]} ${ROW_TITLES[i]}' (score order)" >&2
      return 1
    }
  done
  # The unparsable session is a warning that names it, not a crash and not a silence.
  grep -qF -- "warning: ${WARNED_SID} has no readable signals.json, skipped" "${scratch}/out" || {
    echo "no warning line for the unparsable session ${WARNED_SID}" >&2
    return 1
  }
  last="${lines[-1]:-}"
  [[ "${last}" == "summary: 3 ok, 1 warnings, 0 failed" ]] || {
    echo "the closing line is '${last}', expected 'summary: 3 ok, 1 warnings, 0 failed'" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: --json puts one object per session on stdout and the prose on stderr" {
  local scratch rc
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r --since "${WINDOW}" --json)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the sweeper --json exited ${rc} on the shipped fixture" >&2
    cat "${scratch}/err" >&2
    return 1
  }
  python3 - "${scratch}/out" "${scratch}/err" <<'RFE_JSON_CHECK'
import json
import re
import sys

# The row keys, in the order the table prints its columns. A renamed key is a silent break
# for whatever downstream reader greps it out of the JSON.
KEYS = ["sid", "title", "turns", "tools", "toolfail", "errors", "regen", "compaction", "ctx%", "age"]
EXPECTED = {
    "01a1aaaa": ("add grafana dashboards", 40, 180, 4, 1, 2, 1, 72),
    "01a1cccc": ("rename the template twin", 12, 60, 1, 0, 0, 0, 30),
    "01a1bbbb": ("fix litellm routing", 6, 20, 0, 0, 1, 0, 11),
}

out_path, err_path = sys.argv[1], sys.argv[2]
with open(out_path, encoding="utf-8") as handle:
    out_lines = [line for line in handle.read().splitlines() if line.strip()]
with open(err_path, encoding="utf-8") as handle:
    err_text = handle.read()

if len(out_lines) != len(EXPECTED):
    raise SystemExit(
        "%s: expected %d JSON objects, got %d" % (out_path, len(EXPECTED), len(out_lines))
    )

seen = []
for line in out_lines:
    row = json.loads(line)
    if not isinstance(row, dict):
        raise SystemExit("%s: not a JSON object: %s" % (out_path, line))
    extra = sorted(set(row) - set(KEYS))
    missing = sorted(set(KEYS) - set(row))
    if extra or missing:
        raise SystemExit(
            "%s: keys are %s (missing %s, unexpected %s)"
            % (out_path, sorted(row), missing, extra)
        )
    want = EXPECTED.get(row["sid"])
    if want is None:
        raise SystemExit("%s: unexpected sid %r" % (out_path, row["sid"]))
    got = (row["title"], row["turns"], row["tools"], row["toolfail"], row["errors"],
           row["regen"], row["compaction"], row["ctx%"])
    if got != want:
        raise SystemExit("%s: %s carries %r, expected %r" % (out_path, row["sid"], got, want))
    if not re.fullmatch(r"\d+[mhd]", row["age"]):
        raise SystemExit("%s: %s has age %r, not a coarse m/h/d token"
                         % (out_path, row["sid"], row["age"]))
    seen.append(row["sid"])

if seen != list(EXPECTED):
    raise SystemExit("%s: rows came back %r, expected score order %r"
                     % (out_path, seen, list(EXPECTED)))

# stdout stays machine-readable: neither the warning nor the summary may appear in it.
for line in out_lines:
    if line.startswith(("summary:", "warning:", "note:", "error:")):
        raise SystemExit("%s: prose reached stdout: %s" % (out_path, line))
if "warning: 01a1dddd has no readable signals.json, skipped" not in err_text:
    raise SystemExit("%s: the warning for the unparsable session is not on stderr" % err_path)
if "summary: 3 ok, 1 warnings, 0 failed" not in err_text:
    raise SystemExit("%s: the summary line is not on stderr" % err_path)
RFE_JSON_CHECK
}

@test "reflect_and_evolve_skill: every table row fits the cap and no output line leaves ASCII" {
  local scratch rc toolong file
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r --since "${WINDOW}")"
  [[ "${rc}" -eq 0 ]] || {
    echo "the plain run exited ${rc}" >&2
    return 1
  }
  rc="$(sweep "${scratch}/json" "${FIXTURE}" --repo /r --since "${WINDOW}" --json)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the json run exited ${rc}" >&2
    return 1
  }
  # The 120-character cap the contract pins is the columns table's, so it is measured on the
  # plain run. --json prints one unpadded object per session and is held to ASCII below.
  # LC_ALL=C so awk counts bytes: a multi-byte title would otherwise slip past the cap as
  # fewer characters than the line really occupies on a terminal.
  toolong="$(LC_ALL=C awk 'length > 120 { printf "%s:%d is %d bytes\n", FILENAME, FNR, length }' \
    "${scratch}/out" "${scratch}/err")"
  [[ -n "$(sed -n '1p' "${scratch}/out")" ]] || {
    echo "the plain run printed no table at all" >&2
    return 1
  }
  [[ -z "${toolong}" ]] || {
    echo "a table line is past the 120-character cap:" >&2
    printf '%s\n' "${toolong}" >&2
    return 1
  }
  for file in "${scratch}/out" "${scratch}/err" "${scratch}/json/out" "${scratch}/json/err"; do
    assert_ascii "${file}" || return 1
  done
}

@test "reflect_and_evolve_skill: an absent store is a note and an unknown flag is a usage error" {
  local scratch rc
  scratch="$(make_scratch)"
  # The absent store is the ordinary first run in a repo that has never had a session: it has
  # to be a note and exit 0, so a reflection can still report instead of dying on a traceback.
  rc="$(sweep "${scratch}/empty" "${scratch}/no-home" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "an absent sessions directory exited ${rc}, expected 0" >&2
    cat "${scratch}/empty/err" >&2
    return 1
  }
  grep -qF -- 'note: no sessions for /r' "${scratch}/empty/out" || {
    echo "an absent store did not print 'note: no sessions for /r'" >&2
    cat "${scratch}/empty/out" "${scratch}/empty/err" >&2
    return 1
  }
  [[ "$(tail -n 1 "${scratch}/empty/out")" == "summary: 0 ok, 0 warnings, 0 failed" ]] || {
    echo "an absent store did not close with the zero summary line" >&2
    cat "${scratch}/empty/out" >&2
    return 1
  }
  # The unknown flag is a usage error: exit 2, the usage text on stderr, nothing on stdout.
  rc="$(sweep "${scratch}/bogus" "${FIXTURE}" --bogus)"
  [[ "${rc}" -eq 2 ]] || {
    echo "an unknown flag exited ${rc}, expected 2" >&2
    return 1
  }
  [[ ! -s "${scratch}/bogus/out" ]] || {
    echo "an unknown flag printed a table before refusing:" >&2
    cat "${scratch}/bogus/out" >&2
    return 1
  }
  grep -qE '^usage: ' "${scratch}/bogus/err" || {
    echo "an unknown flag printed no 'usage:' line on stderr" >&2
    cat "${scratch}/bogus/err" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: every file the skill ships is pure ASCII with no carriage return" {
  local file checked=0
  # Runfiles hand these over as symlinks into the source tree, so -type f alone matches
  # nothing here; -type l plus the file test reads the bytes that actually ship.
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    assert_ascii "${file}" || return 1
    ((checked += 1))
  done < <(find "${REPO_ROOT}/skills/reflect-and-evolve" \( -type f -o -type l \) | sort)
  [[ ${checked} -ge 3 ]] || {
    echo "only ${checked} file(s) under skills/reflect-and-evolve/, expected the body, the checklist, and the sweeper" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: the docs page lists the skill in the repo-scoped runbook" {
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
  grep -qF -- '/reflect-and-evolve' <<<"${block}" || {
    echo "the repo-scoped runbook subsection never names /reflect-and-evolve" >&2
    return 1
  }
  grep -qF -- 'skills/reflect-and-evolve/SKILL.md' <<<"${block}" || {
    echo "the subsection does not say the canonical body is skills/reflect-and-evolve/SKILL.md" >&2
    return 1
  }
}
