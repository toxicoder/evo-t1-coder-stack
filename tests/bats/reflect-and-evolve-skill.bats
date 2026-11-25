#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## reflect-and-evolve-skill.bats - the reflection runbook stays whole, linked, and runnable.
#
# The repo ships one reusable procedure for turning past sessions into planned changes to the
# agent system: templates/common/reflect-and-evolve.SKILL.md is the canonical body,
# .grok/skills/reflect-and-evolve/SKILL.md is the tracked symlink that makes it a repo-tier
# skill the CLI discovers, templates/common/reflect-and-evolve.checklist.md is the
# evidence-and-quality page the body hands the reader (seeded at
# ~/.coder/skills/reflect-and-evolve/references/checklist.md), and
# templates/common/reflect-and-evolve.session_signals.py is the sweeper step 1 runs (seeded at
# ~/.coder/skills/reflect-and-evolve/scripts/session_signals.py), and
# docs/grok-build-and-agents.md is the roster entry that tells a person the command exists.
#
# Each of those fails in a way nothing else notices. A truncated paste loses a Core Workflow
# step and the skill still loads; a copied-instead-of-linked body drifts from the seed while
# both read fine; a frontmatter key the CLI does not document is silently dropped, so the
# skill stops being user-invocable; and the sweeper is the ONLY sanctioned way into a session
# store holding gigabytes of transcripts, so a regression that prints a raw field, a non-ASCII
# title, or an over-long line, or that opens a file it should not, is a leak the next
# reflection performs. This suite is the completeness gate for that set: the body's structure,
# the link's target, the two reference pages, the docs citation, and the sweeper read off a
# shipped fixture - the row order and summary line, every counter pinned in its own column,
# the control-character-and-truncation rule for a model-written title, the recency tie-break,
# a percent derived from the token pair when the store omits the usage key, a zero that has to
# print 0% rather than the missing-value dash, the --limit note, the documented --limit and
# --since defaults, and a decoy transcript that must reach neither stream.
#
# The fixture carries six readable sessions plus one whose signals.json is unparsable, and its
# dates are fixed, so the sweeper is never run against the clock here: sweep() pins --since on
# every call, and the two defaults are read off the sweeper's own source text and its --help
# output instead. The privacy probe and the unreadable-file case build their own throwaway
# session trees under BATS_TEST_TMPDIR, because a store written to be provably unopened is not
# something to commit into the repo.
#
# Usage: bazelisk test //tests:bats_reflect_and_evolve_skill_test   (from any cwd)
# Safety: reads templates/common/reflect-and-evolve.SKILL.md, its checklist page and its
#         sweeper, the .grok/ link, the stack-skills seed that lays the two helpers down, the
#         fixture session tree under tests/bats/fixtures/, and the docs page;
#         writes only per-test scratch under BATS_TEST_TMPDIR. Never touches a real ~/.grok
#         session store, and never runs the sweeper without --home pointing at one of these.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SKILL=""
SKILL_LINK=""
CHECKLIST=""
SWEEPER=""
SEED=""
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
# regen + compaction, descending, then recency, then the id. The scores are 13, 4, 2, 2, 1, 0;
# the cccc/eeee pair is the recency tie-break, ffff's stored title carries a tab, and gggg has
# no contextWindowUsage key at all. The seventh session, 01a1dddd, is the unparsable one the
# run has to warn about instead of dying on.
ROW_SIDS=(01a1aaaa 01a1gggg 01a1cccc 01a1eeee 01a1bbbb 01a1ffff)
ROW_TITLES=("add grafana dashboards" "derive the percent from tokens"
  "rename the template twin" "tie recency older" "fix litellm routing"
  "refactor the observability exporters and split d..")
ROW_CTX=(72% 25% 30% 0% 11% 5%)
WARNED_SID=01a1dddd

# The fixture's session dates are fixed, so a run years from now would drop every row under
# the default 90-day window and the suite would go red for a reason that is not a defect.
# Every call widens the window instead of pinning the age column, which drifts by the hour.
WINDOW=3650

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root"
  SKILL="${REPO_ROOT}/templates/common/reflect-and-evolve.SKILL.md"
  SKILL_LINK="${REPO_ROOT}/.grok/skills/reflect-and-evolve/SKILL.md"
  CHECKLIST="${REPO_ROOT}/templates/common/reflect-and-evolve.checklist.md"
  SWEEPER="${REPO_ROOT}/templates/common/reflect-and-evolve.session_signals.py"
  # The stack seed is what lays the two helpers down under the skill's own home, which is the
  # path the body's References section sends a reader to.
  SEED="${REPO_ROOT}/templates/common/stack-skills.sh.tftpl"
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
# A caller that does not name --since gets WINDOW, so no sweep can ever fall back to the
# 90-day default and empty the table as the fixture's fixed dates age out.
sweep() {
  local dir="${1}" home="${2}" arg has_since=0
  shift 2
  local rc=0
  mkdir -p "${dir}"
  for arg in "$@"; do
    if [[ "${arg}" == "--since" || "${arg}" == --since=* ]]; then
      has_since=1
    fi
  done
  ((has_since)) || set -- "$@" --since "${WINDOW}"
  # shellcheck disable=SC2086  # the caller passes the sweeper's own argv
  python3 "${SWEEPER}" --home "${home}" "$@" >"${dir}/out" 2>"${dir}/err" || rc="${?}"
  printf '%s' "${rc}"
}

# make_session <dir> <sid8> <title> <turns> <tools> <toolfail> <errors> <regen> <compaction>
# <usage|-> <last_active> - write one readable session directory under <dir>, the shape the
# privacy and failure probes need built at runtime. A usage of - omits the key entirely.
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

# make_unreadable <path> - leave <path> where the process cannot open it. The mode bits are the
# realistic case (a store file owned by someone else); a privileged run ignores them, so the
# file becomes a directory instead, which open() refuses for any uid.
make_unreadable() {
  local path="${1}"
  chmod 000 "${path}"
  if [[ -r "${path}" ]]; then
    rm -f "${path}"
    mkdir "${path}"
  fi
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
  # copies that agree today. Under a runfiles tree the chain walks out to the real checkout,
  # so the aim is matched on its templates/common/ tail rather than on an absolute path, and
  # cmp proves the bytes are the payload's. A link still aimed at the retired skills/ path
  # resolves to nothing here, so it fails as a dangling link rather than as a wrong tail.
  local target
  target="$(readlink -f "${SKILL_LINK}")"
  case "${target}" in
    */templates/common/reflect-and-evolve.SKILL.md) ;;
    *)
      echo "${SKILL_LINK} resolves to ${target}, not to the templates/common/reflect-and-evolve.SKILL.md body" >&2
      return 1
      ;;
  esac
  cmp -s "${SKILL_LINK}" "${SKILL}" || {
    echo "${SKILL_LINK} does not carry the bytes of ${SKILL}" >&2
    return 1
  }
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
  # The two helper pages, spelled the way the body spells them: under the skill's own home,
  # which is where the seed lays them. The tracked sources they are rendered from sit under
  # templates/common/, and the pair below proves the reader is sent somewhere that ships.
  for page in \
    '~/.agents/skills/reflect-and-evolve/references/checklist.md' \
    '~/.agents/skills/reflect-and-evolve/scripts/session_signals.py'; do
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
  # The six readable rows, in score order, each with its ctx cell. The age column is not
  # asserted: it is a function of the wall clock, so pinning it would make this suite rot on
  # the calendar.
  for i in 0 1 2 3 4 5; do
    row="${lines[i + 1]:-}"
    [[ "${row}" == "${ROW_SIDS[i]} ${ROW_TITLES[i]}"* ]] || {
      echo "row $((i + 1)) is '${row}', expected '${ROW_SIDS[i]} ${ROW_TITLES[i]}' (score order)" >&2
      return 1
    }
    [[ "${row}" == *" ${ROW_CTX[i]} "* ]] || {
      echo "row $((i + 1)) (${ROW_SIDS[i]}) does not print ctx ${ROW_CTX[i]}: '${row}'" >&2
      return 1
    }
  done
  # Nothing else prints a row: the unparsable session is a warning that names it, not a crash
  # and not a silence, and it never reaches the table.
  [[ "$(grep -c '^01a1' "${scratch}/out")" -eq ${#ROW_SIDS[@]} ]] || {
    echo "the table printed $(grep -c '^01a1' "${scratch}/out") rows, expected ${#ROW_SIDS[@]}" >&2
    cat "${scratch}/out" >&2
    return 1
  }
  if grep -qE "^${WARNED_SID} " "${scratch}/out"; then
    echo "the unparsable session ${WARNED_SID} printed a table row" >&2
    return 1
  fi
  grep -qF -- "warning: ${WARNED_SID} has no readable signals.json, skipped" "${scratch}/out" || {
    echo "no warning line for the unparsable session ${WARNED_SID}" >&2
    return 1
  }
  last="${lines[-1]:-}"
  [[ "${last}" == "summary: 6 ok, 1 warnings, 0 failed" ]] || {
    echo "the closing line is '${last}', expected 'summary: 6 ok, 1 warnings, 0 failed'" >&2
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
# Score order, and the same six rows the table prints. gggg carries no contextWindowUsage key
# in the fixture, so its 25 is the derived percent; eeee carries a literal 0, so its ctx is 0
# and not None.
EXPECTED = {
    "01a1aaaa": ("add grafana dashboards", 40, 180, 4, 1, 2, 1, 72),
    "01a1gggg": ("derive the percent from tokens", 8, 30, 0, 2, 0, 0, 25),
    "01a1cccc": ("rename the template twin", 12, 60, 1, 0, 0, 0, 30),
    "01a1eeee": ("tie recency older", 9, 40, 1, 0, 0, 0, 0),
    "01a1bbbb": ("fix litellm routing", 6, 20, 0, 0, 1, 0, 11),
    "01a1ffff": ("refactor the observability exporters and split d..", 20, 90, 0, 0, 0, 0, 5),
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
if "summary: 6 ok, 1 warnings, 0 failed" not in err_text:
    raise SystemExit("%s: the summary line is not on stderr" % err_path)
RFE_JSON_CHECK
}

@test "reflect_and_evolve_skill: a table row pins every counter in the column it belongs to" {
  local scratch rc
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the plain run exited ${rc}" >&2
    cat "${scratch}/err" >&2
    return 1
  }
  python3 - "${scratch}/out" <<'RFE_COLUMN_CHECK'
import re
import sys

# The pinned column layout: one width per column (8, 48, 5, 6, 8, 6, 5, 10, 5, 4), each cell
# padded to its width and the columns joined by a single space. Offsets are (start, width) into
# the rendered line, so a counter that moved columns fails even when the row still carries the
# right numbers. They are spelled out here rather than read out of the script on purpose: a
# layout change should be a decision made twice.
COLS = (("sid", 0, 8), ("title", 9, 48), ("turns", 58, 5), ("tools", 64, 6),
        ("toolfail", 71, 8), ("errors", 80, 6), ("regen", 87, 5),
        ("compaction", 93, 10), ("ctx%", 104, 5))

# sid, title, turns, tools, toolfail, errors, regen, compaction, ctx%: the whole row but the
# age, which moves with the clock. The truncated ffff title overruns its column by the two dots
# and is pinned by its own claim below, so it is not listed here.
ROWS = [
    ("01a1aaaa", "add grafana dashboards", "40", "180", "4", "1", "2", "1", "72%"),
    ("01a1gggg", "derive the percent from tokens", "8", "30", "0", "2", "0", "0", "25%"),
    ("01a1cccc", "rename the template twin", "12", "60", "1", "0", "0", "0", "30%"),
    ("01a1eeee", "tie recency older", "9", "40", "1", "0", "0", "0", "0%"),
    ("01a1bbbb", "fix litellm routing", "6", "20", "0", "0", "1", "0", "11%"),
]

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = [line for line in handle.read().splitlines() if line.strip()]

if lines[:1] != ["== session signals =="]:
    raise SystemExit("%s: the run printed no table header" % path)
rows = lines[1:1 + len(ROWS)]
if len(rows) != len(ROWS):
    raise SystemExit("%s: the table printed %d rows, expected %d"
                     % (path, len(rows), len(ROWS)))

AGE_START = COLS[-1][1] + COLS[-1][2] + 1
for row, want in zip(rows, ROWS):
    for (name, start, width), expected in zip(COLS, want):
        got = row[start:start + width].strip()
        if got != expected:
            raise SystemExit(
                "%s: row %s column %s reads %r, expected %r (line %r)"
                % (path, want[0], name, got, expected, row))
    age = row[AGE_START:].strip()
    if not re.fullmatch(r"\d+[mhd]", age):
        raise SystemExit("%s: row %s has age %r, not a coarse m/h/d token"
                         % (path, want[0], age))
RFE_COLUMN_CHECK
}

@test "reflect_and_evolve_skill: a tab in a stored title becomes a space and a long title truncates" {
  local scratch rc
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the plain run exited ${rc}" >&2
    return 1
  }
  python3 - "${scratch}/out" "${FIXTURE}" <<'RFE_TITLE_CHECK'
import glob
import json
import os
import re
import sys

SID = "01a1ffff"
TITLE_MAX = 48

out_path, fixture = sys.argv[1], sys.argv[2]
found = glob.glob(os.path.join(fixture, "sessions", "%2Fr", SID + "*"))
if len(found) != 1:
    raise SystemExit("fixture: expected one %s session, found %d" % (SID, len(found)))
with open(os.path.join(found[0], "summary.json"), encoding="utf-8") as handle:
    raw = json.load(handle)["generated_title"]

# The fixture has to carry the case, or this claim proves nothing about the branch.
if "\t" not in raw:
    raise SystemExit(
        "fixture: the stored %s title carries no tab, so the control-character branch is "
        "unexercised" % SID)

text = "".join(" " if ord(ch) < 32 or ord(ch) == 127 else ch for ch in raw)
collapsed = " ".join(text.split())
if len(collapsed) <= TITLE_MAX:
    raise SystemExit("fixture: the cleaned title is %d characters, too short to truncate"
                     % len(collapsed))
want = collapsed[:TITLE_MAX] + ".."

with open(out_path, encoding="utf-8") as handle:
    rows = [line for line in handle.read().splitlines() if line.startswith(SID)]
if len(rows) != 1:
    raise SystemExit("%s: expected one %s row, got %d" % (out_path, SID, len(rows)))
row = rows[0]
if re.search(r"[\x00-\x1f\x7f]", row):
    raise SystemExit("%s: the rendered row still carries a control character: %r"
                     % (out_path, row))

# One row is one line: the title is everything ahead of the eight counter columns, which the
# row splits into from the right because the title itself carries spaces.
fields = row.partition(" ")[2].rsplit(None, 8)
if len(fields) != 9:
    raise SystemExit("%s: the %s row split into %d fields, expected a title plus 8 columns: %r"
                     % (out_path, SID, len(fields), row))
if fields[0] != want:
    raise SystemExit(
        "%s: the title renders as %r, expected the first %d characters of %r plus '..'"
        % (out_path, fields[0], TITLE_MAX, collapsed))
if fields[1:7] != ["20", "90", "0", "0", "0", "0"] or fields[7] != "5%":
    raise SystemExit(
        "%s: the truncated row carries %r, expected its counters after the title"
        % (out_path, fields[1:8]))
RFE_TITLE_CHECK
}

@test "reflect_and_evolve_skill: two sessions on one score come out with the newer row first" {
  local scratch rc
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the plain run exited ${rc}" >&2
    return 1
  }
  python3 - "${scratch}/out" "${FIXTURE}" <<'RFE_TIE_CHECK'
import glob
import json
import os
import sys

NEWER, OLDER = "01a1cccc", "01a1eeee"


def load(fixture, sid, name):
    found = glob.glob(os.path.join(fixture, "sessions", "%2Fr", sid + "*"))
    if len(found) != 1:
        raise SystemExit("fixture: expected one %s session, found %d" % (sid, len(found)))
    with open(os.path.join(found[0], name), encoding="utf-8") as handle:
        return json.load(handle)


out_path, fixture = sys.argv[1], sys.argv[2]
stamps = {}
for sid in (NEWER, OLDER):
    signals = load(fixture, sid, "signals.json")
    summary = load(fixture, sid, "summary.json")
    stamps[sid] = (
        2 * signals.get("toolFailureCount", 0) + 2 * signals.get("errorCount", 0)
        + signals.get("regenerationCount", 0) + signals.get("compactionCount", 0),
        summary.get("last_active_at"),
    )

# Both legs of the claim come from the fixture: the pair must really tie, and the one the
# suite calls newer must really be the more recent stamp. Otherwise a change to the fixture
# would silently retire the tie-break.
if stamps[NEWER][0] != stamps[OLDER][0]:
    raise SystemExit("fixture: %s scores %s and %s scores %s, so this pair is not a tie"
                     % (NEWER, stamps[NEWER][0], OLDER, stamps[OLDER][0]))
if not (stamps[NEWER][1] > stamps[OLDER][1]):
    raise SystemExit("fixture: %s (%s) is not more recent than %s (%s)"
                     % (NEWER, stamps[NEWER][1], OLDER, stamps[OLDER][1]))

with open(out_path, encoding="utf-8") as handle:
    order = [line.split(" ", 1)[0] for line in handle.read().splitlines()
             if line.startswith("01a1")]
for sid in (NEWER, OLDER):
    if sid not in order:
        raise SystemExit("%s: %s printed no row, so the tie was never ranked" % (out_path, sid))
if order.index(NEWER) > order.index(OLDER):
    raise SystemExit(
        "%s: the rows came out %r; the equal-score session from 2026-11-17 must precede the "
        "2026-11-15 one" % (out_path, order))
RFE_TIE_CHECK
}

@test "reflect_and_evolve_skill: recency still wins when it disagrees with the session id" {
  local tree rc scratch
  # In the shipped fixture the tie-break's newer row also carries the lower id, so recency and
  # the id fallback would print the same order. This probe inverts them under
  # BATS_TEST_TMPDIR: here only the recency leg can put the 2026-11-19 session first, so a
  # sort that dropped it and fell through to the id would go red on this claim and not the one
  # above.
  tree="${BATS_TEST_TMPDIR}/tie"
  scratch="$(make_scratch)"
  make_session "${tree}" 01a1aaaa "the older half of the tie" 4 9 1 0 0 0 9 \
    2026-11-10T09:00:00.000000Z >/dev/null
  make_session "${tree}" 01a1bbbb "the newer half of the tie" 4 9 1 0 0 0 9 \
    2026-11-19T09:00:00.000000Z >/dev/null
  rc="$(sweep "${scratch}/run" "${tree}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the tie probe exited ${rc}" >&2
    cat "${scratch}/run/err" >&2
    return 1
  }
  [[ "$(sed -n '2p' "${scratch}/run/out")" == 01a1bbbb* ]] || {
    echo "row 1 is '$(sed -n '2p' "${scratch}/run/out")'; the equal-score session from 2026-11-19 " >&2
    echo "must precede the 2026-11-10 one even though its id sorts later:" >&2
    cat "${scratch}/run/out" >&2
    return 1
  }
  [[ "$(sed -n '3p' "${scratch}/run/out")" == 01a1aaaa* ]] || {
    echo "row 2 is '$(sed -n '3p' "${scratch}/run/out")', expected the older tied session" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: a missing contextWindowUsage is derived from the token pair" {
  local scratch rc
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the plain run exited ${rc}" >&2
    return 1
  }
  python3 - "${scratch}/out" "${FIXTURE}" <<'RFE_DERIVED_CHECK'
import glob
import json
import os
import sys

SID = "01a1gggg"
CTX_COL = (104, 5)

out_path, fixture = sys.argv[1], sys.argv[2]
found = glob.glob(os.path.join(fixture, "sessions", "%2Fr", SID + "*"))
if len(found) != 1:
    raise SystemExit("fixture: expected one %s session, found %d" % (SID, len(found)))
with open(os.path.join(found[0], "signals.json"), encoding="utf-8") as handle:
    signals = json.load(handle)
if "contextWindowUsage" in signals:
    raise SystemExit(
        "fixture: %s carries contextWindowUsage, so the derived-percent branch is "
        "unexercised" % SID)
used = signals.get("contextTokensUsed")
window = signals.get("contextWindowTokens")
if (used, window) != (65536, 262144):
    raise SystemExit("fixture: %s carries the token pair %r, expected 65536/262144"
                     % (SID, (used, window)))
want = "%d%%" % round(100.0 * used / window)
if want != "25%":
    raise SystemExit("fixture: 65536 of 262144 derives %s, not 25%%" % want)

with open(out_path, encoding="utf-8") as handle:
    rows = [line for line in handle.read().splitlines() if line.startswith(SID)]
if len(rows) != 1:
    raise SystemExit("%s: expected one %s row, got %d" % (out_path, SID, len(rows)))
start, width = CTX_COL
got = rows[0][start:start + width].strip()
if got != want:
    raise SystemExit(
        "%s: %s prints ctx %r in its column, expected %s derived from %d/%d (line %r)"
        % (out_path, SID, got, want, used, window, rows[0]))
RFE_DERIVED_CHECK
}

@test "reflect_and_evolve_skill: a zero usage prints 0% and is not read as a missing value" {
  local scratch rc
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}" "${FIXTURE}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the plain run exited ${rc}" >&2
    return 1
  }
  python3 - "${scratch}/out" "${FIXTURE}" <<'RFE_ZERO_CHECK'
import glob
import json
import os
import sys

SID = "01a1eeee"
CTX_COL = (104, 5)

out_path, fixture = sys.argv[1], sys.argv[2]
found = glob.glob(os.path.join(fixture, "sessions", "%2Fr", SID + "*"))
if len(found) != 1:
    raise SystemExit("fixture: expected one %s session, found %d" % (SID, len(found)))
with open(os.path.join(found[0], "signals.json"), encoding="utf-8") as handle:
    usage = json.load(handle).get("contextWindowUsage")
if usage != 0:
    raise SystemExit("fixture: %s carries contextWindowUsage %r, expected a literal 0"
                     % (SID, usage))

with open(out_path, encoding="utf-8") as handle:
    rows = [line for line in handle.read().splitlines() if line.startswith(SID)]
if len(rows) != 1:
    raise SystemExit("%s: expected one %s row, got %d" % (out_path, SID, len(rows)))
start, width = CTX_COL
got = rows[0][start:start + width].strip()
# A falsy test in the renderer turns this row's 0 into the '-' that means "no data", which is
# how an empty context window gets reported as an unknown one.
if got != "0%":
    raise SystemExit(
        "%s: %s prints ctx %r, expected '0%%': a zero is a measurement, not a gap (line %r)"
        % (out_path, SID, got, rows[0]))
RFE_ZERO_CHECK
}

@test "reflect_and_evolve_skill: --limit truncates the table and says how many rows it hid" {
  local scratch rc last
  scratch="$(make_scratch)"
  rc="$(sweep "${scratch}/three" "${FIXTURE}" --repo /r --limit 3)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the --limit run exited ${rc}" >&2
    cat "${scratch}/three/err" >&2
    return 1
  }
  grep -qF -- 'note: showing 3 of 6 sessions; raise --limit for the rest' \
    "${scratch}/three/out" || {
    echo "a run that hid 3 of 6 sessions printed no note line:" >&2
    cat "${scratch}/three/out" >&2
    return 1
  }
  rc="$(grep -c '^01a1' "${scratch}/three/out")"
  [[ "${rc}" -eq 3 ]] || {
    echo "the --limit run printed ${rc} rows, expected 3" >&2
    cat "${scratch}/three/out" >&2
    return 1
  }
  last="$(tail -n 1 "${scratch}/three/out")"
  [[ "${last}" == "summary: 3 ok, 1 warnings, 0 failed" ]] || {
    echo "the --limit run closed with '${last}', expected the count it printed" >&2
    return 1
  }
  # The note is a truncation note: a run that prints every row must not claim it hid any.
  rc="$(sweep "${scratch}/all" "${FIXTURE}" --repo /r --limit 6)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the untruncated run exited ${rc}" >&2
    return 1
  }
  if grep -q '^note: ' "${scratch}/all/out"; then
    echo "a run that printed all six sessions still printed a note line:" >&2
    cat "${scratch}/all/out" >&2
    return 1
  fi
  [[ "$(grep -c '^01a1' "${scratch}/all/out")" -eq 6 ]] || {
    echo "--limit 6 did not print all six sessions" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: the documented defaults are 20 rows and 90 days" {
  local help
  # Pinned from the sweeper's own text and its --help, never by dropping the flag on the
  # shipped fixture: the fixture's dates are fixed, so an unwindowed sweep would drop every row
  # roughly 90 days out and the suite would go red for a reason that is not a defect.
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
  grep -qE 'default=DEFAULT_LIMIT' "${SWEEPER}" || {
    echo "the --limit argument is no longer bound to DEFAULT_LIMIT" >&2
    return 1
  }
  grep -qE 'default=DEFAULT_SINCE_DAYS' "${SWEEPER}" || {
    echo "the --since argument is no longer bound to DEFAULT_SINCE_DAYS" >&2
    return 1
  }
  # And the same two numbers as a person reads them: a constant that stopped feeding its own
  # help string, or a help string that drifted, is a documented default that lies. COLUMNS is
  # set so argparse cannot wrap either line across two and hide the number.
  help="${BATS_TEST_TMPDIR}/help.txt"
  COLUMNS=100 python3 "${SWEEPER}" --help >"${help}" 2>&1 || {
    echo "the sweeper --help exited $?" >&2
    return 1
  }
  grep -qE '^ +--limit +LIMIT +rows to print, default 20$' "${help}" || {
    echo "--help does not offer 20 as the row limit:" >&2
    cat "${help}" >&2
    return 1
  }
  grep -qE '^ +--since +SINCE +days of history to keep, default 90$' "${help}" || {
    echo "--help does not offer 90 days as the history window:" >&2
    cat "${help}" >&2
    return 1
  }
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
  # The shipped set is the three templates/common/ payloads the stack seed renders: the body,
  # its checklist page, and its sweeper. Runfiles hand these over as symlinks into the source
  # tree, so the file test reads the bytes that actually ship, and the count is checked or an
  # empty set would satisfy the loop.
  for file in "${SKILL}" "${CHECKLIST}" "${SWEEPER}"; do
    [[ -f "${file}" ]] || continue
    assert_ascii "${file}" || return 1
    ((checked += 1))
  done
  [[ ${checked} -eq 3 ]] || {
    echo "only ${checked} of the 3 files the skill ships (body, checklist, sweeper) are present under templates/common/" >&2
    return 1
  }
  # Each helper ships into the skill's own home, which is the path the body's References
  # section sends a reader to: a payload that stopped being seeded leaves that path missing
  # while the body still reads fine.
  local home
  for home in \
    '.coder/skills/reflect-and-evolve/references/checklist.md' \
    '.coder/skills/reflect-and-evolve/scripts/session_signals.py'; do
    grep -qF -- "\$HOME/${home}" "${SEED}" || {
      echo "stack-skills.sh.tftpl never lays down \$HOME/${home}" >&2
      return 1
    }
  done
}

@test "reflect_and_evolve_skill: the docs page lists the skill under the reflection runbooks" {
  [[ -f "${DOC_PAGE}" ]] || {
    echo "missing ${DOC_PAGE}: the roster never tells a person the command exists" >&2
    return 1
  }
  local block
  block="$(subsection "${DOC_PAGE}" "#### The session reviewer")"
  [[ -n "${block}" ]] || {
    echo "${DOC_PATH} has no '#### The session reviewer' subsection under the reflection runbooks" >&2
    return 1
  }
  grep -qF -- '/reflect-and-evolve' <<<"${block}" || {
    echo "the repo-scoped runbook subsection never names /reflect-and-evolve" >&2
    return 1
  }
  grep -qF -- 'templates/common/reflect-and-evolve.SKILL.md' <<<"${block}" || {
    echo "the subsection does not say the canonical body is templates/common/reflect-and-evolve.SKILL.md" >&2
    return 1
  }
}

@test "reflect_and_evolve_skill: the sweeper never reads or prints a transcript sitting beside its two files" {
  local tree session canary rc scratch
  # The whole reason the sweeper is the sanctioned way into the store is that it opens two
  # files per session and nothing else. A session tree is cheap to build, so the probe builds
  # its own under BATS_TEST_TMPDIR and plants a sentinel in the three files the contract names
  # as off-limits: if any code path starts opening them, or prints a path or a line from them,
  # this is the claim that goes red.
  tree="${BATS_TEST_TMPDIR}/privacy"
  scratch="$(make_scratch)"
  canary="EVIDENCE-LEAK-CANARY-9d2f"
  session="$(make_session "${tree}" 01a1pppp "privacy probe" 3 7 1 0 0 0 12 \
    2026-11-19T09:00:00.000000Z)"
  printf '%s\n' \
    "{\"role\": \"user\", \"content\": \"${canary} the whole prompt body\"}" \
    "{\"role\": \"assistant\", \"content\": \"${canary} the whole diff body\"}" \
    >"${session}/chat_history.jsonl"
  printf '%s\n' "{\"prompt\": \"${canary} the resent prompt\"}" >"${session}/prompt_history.jsonl"
  printf '%s\n' "{\"event\": \"tool_result\", \"body\": \"${canary} the tool output\"}" \
    >"${session}/events.jsonl"
  [[ -s "${session}/chat_history.jsonl" ]] || {
    echo "the probe tree built no decoy transcript, so the claim would be vacuous" >&2
    return 1
  }
  grep -qrF -- "${canary}" "${tree}" || {
    echo "the probe tree holds no sentinel, so the claim would be vacuous" >&2
    return 1
  }
  rc="$(sweep "${scratch}/run" "${tree}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "the sweeper exited ${rc} on the probe tree" >&2
    cat "${scratch}/run/err" >&2
    return 1
  }
  # The probe has to have been swept, or the silence below would prove nothing.
  grep -q '^01a1pppp ' "${scratch}/run/out" || {
    echo "the sweeper printed no row for the probe session, so it never reached the tree:" >&2
    cat "${scratch}/run/out" "${scratch}/run/err" >&2
    return 1
  }
  if grep -qF -- "${canary}" "${scratch}/run/out" "${scratch}/run/err"; then
    echo "a transcript sentinel reached the output:" >&2
    grep -nF -- "${canary}" "${scratch}/run/out" "${scratch}/run/err" >&2
    return 1
  fi
  # Not even the file names: the program must not have a reason to name what it must not open.
  if grep -qiE 'chat_history|prompt_history|events\.jsonl' "${scratch}/run/out" \
    "${scratch}/run/err"; then
    echo "the output names a transcript file the sweeper is not allowed to open:" >&2
    grep -niE 'chat_history|prompt_history|events\.jsonl' "${scratch}/run/out" \
      "${scratch}/run/err" >&2
    return 1
  fi
}

@test "reflect_and_evolve_skill: an unreadable signals.json is one error line and one failed" {
  local tree good bad rc last scratch
  # The two prose counters the summary carries are only useful if a file that cannot be opened
  # is counted as failed while its neighbours still print. The store hits this for real when a
  # session directory is owned by someone else, so the probe makes one signals.json unreadable
  # beside one that reads fine.
  tree="${BATS_TEST_TMPDIR}/unreadable"
  scratch="$(make_scratch)"
  good="$(make_session "${tree}" 01a1iiii "the readable neighbour" 5 11 0 0 0 0 8 \
    2026-11-18T09:00:00.000000Z)"
  bad="$(make_session "${tree}" 01a1hhhh "the locked one" 4 9 1 0 0 0 6 \
    2026-11-18T10:00:00.000000Z)"
  [[ -s "${good}/signals.json" ]] || {
    echo "the probe tree built no readable neighbour session, so the claim would be vacuous" >&2
    return 1
  }
  make_unreadable "${bad}/signals.json"
  rc="$(sweep "${scratch}/run" "${tree}" --repo /r)"
  [[ "${rc}" -eq 0 ]] || {
    echo "an unreadable signals.json exited ${rc}, expected 0" >&2
    cat "${scratch}/run/err" >&2
    return 1
  }
  grep -qF -- 'error: 01a1hhhh could not be read:' "${scratch}/run/out" || {
    echo "the unreadable session produced no error: line" >&2
    cat "${scratch}/run/out" "${scratch}/run/err" >&2
    return 1
  }
  if grep -qE '^01a1hhhh ' "${scratch}/run/out"; then
    echo "the unreadable session still printed a table row:" >&2
    cat "${scratch}/run/out" >&2
    return 1
  fi
  grep -qE '^01a1iiii ' "${scratch}/run/out" || {
    echo "one unreadable file stopped the readable neighbour from printing:" >&2
    cat "${scratch}/run/out" >&2
    return 1
  }
  last="$(tail -n 1 "${scratch}/run/out")"
  [[ "${last}" == "summary: 1 ok, 0 warnings, 1 failed" ]] || {
    echo "the closing line is '${last}', expected 'summary: 1 ok, 0 warnings, 1 failed'" >&2
    return 1
  }
}
