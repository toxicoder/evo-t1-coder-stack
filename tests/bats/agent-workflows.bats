#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## agent-workflows.bats - a workflow has to be a real, invocable, local-lane program.
#
# .grok/workflows/ holds the workflows a session can call by name. Three things about
# one of them fail silently, which is why they are checked here rather than trusted:
#
# A file that is not valid JavaScript is not a boot error. The runner discovers the
# directory, fails to load one entry, and the workflow is simply absent from the
# picker -- so a stray brace costs a person an hour of wondering why `/implement-reviewed`
# never appears rather than one line of error.
#
# A `name:` that does not match the file stem is a workflow that loads but cannot be
# called the way the docs and the skill tell people to call it. The invocation goes by
# name, and the docs name the stem.
#
# A model id the local catalog does not carry is the expensive one. This stack has no
# cloud transport: every lane is an alias in litellm/config.yaml over the Spark boxes,
# and an id that resolves to nothing surfaces as a failed agent call mid-run, after the
# fan-out has already been paid for. So the aliases a workflow names are checked against
# the roster the repo actually serves, the same cross-check the agent definitions get in
# fleet-agents.bats. A workflow that names a lane nobody declares fails here instead.
#
# The tracker commands are the fourth silent one, and they belong to open-bugs. To node
# a gh command is just a string, so a discovery that dropped --state open, a comment that
# took its body from argv, a label a run invented, or a Closes keyword that closed an
# issue nobody meant to close all parse clean and edit the real tracker instead. Those
# are pinned below by reading the workflow source as data.
#
# Usage: bazelisk test //tests:bats_agent_workflows_test   (from any cwd)
# Safety: reads the workflow directory and litellm/config.yaml; writes nothing. node is
# probed for and the parse test skips, rather than fails, when the runner has none.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
WORKDIR=""
CONFIG=""
OPEN_BUGS=""

# The aliases this repo declares. Anything outside it is a cloud id or a typo, and both
# mean a call that cannot be served from this box.
LANE_ROSTER='agent agent-low agent-medium agent-xhigh agent-xhigh-fast agent-swarm agent-swarm-fast agent-explore agent-review coder coder-fast chat'

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || return 1
  WORKDIR="${REPO_ROOT}/.grok/workflows"
  CONFIG="${REPO_ROOT}/litellm/config.yaml"
  OPEN_BUGS="${WORKDIR}/open-bugs.js"
}

# tracker_pins <file> <"why||regex">... -- one python pass that reads the workflow source as
# data and holds it to a tracker contract the runner never checks. Each spec is a sentence a
# person can act on and the pattern that proves it; the first one that stops matching is the
# one reported, so a broken pin names itself instead of just going red.
tracker_pins() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
for spec in sys.argv[2:]:
    why, _, pattern = spec.partition("||")
    if not re.search(pattern, text, re.S | re.M):
        sys.exit("FAIL: %s: %s\n         pattern: %s" % (path, why, pattern))
PY
}

# lane_check <file> -- one python pass over one workflow: the frame, the name, and every
# agent-* alias against the roster and against what the proxy serves.
lane_check() {
  python3 - "$1" "$CONFIG" "$LANE_ROSTER" <<'PY'
import re, sys

path, config_path, roster_text = sys.argv[1], sys.argv[2], sys.argv[3]
roster = set(roster_text.split())
text = open(path, encoding="utf-8").read()

# The frame: a --- block inside the leading /** */ comment, carrying the four keys the
# runner reads and at least one phase line.
open_count = text.count("/**")
close_count = text.count("*/")
if open_count != close_count:
    sys.exit("FAIL: %s: %d /** against %d */ -- the frame comment is unbalanced"
             % (path, open_count, close_count))
if open_count < 1:
    sys.exit("FAIL: %s: no leading /** frame, so the runner has no name to list" % path)

body = text.split("/**", 1)[1].split("*/", 1)[0]
for key in ("name", "description", "when_to_use"):
    if not re.search(r"^\s*\*\s*%s:" % key, body, re.M):
        sys.exit("FAIL: %s: the frame carries no %s: line" % (path, key))
if not re.search(r"^\s*\*\s*phase:", body, re.M):
    sys.exit("FAIL: %s: the frame names no phase, so the run has no shape to report" % path)

stem = path.rsplit("/", 1)[-1][:-3]
named = re.search(r"^\s*\*\s*name:\s*(\S+)", body, re.M).group(1)
if named != stem:
    sys.exit("FAIL: %s: name is %r but the file is %r.js, and the docs invoke it by stem"
             % (path, named, stem))

# Aliases. Every agent-* token has to be a lane the repo declares AND a model_name the
# proxy serves, which is the same two-sided check fleet-agents.bats runs on the roles.
served = set()
try:
    import yaml
except ImportError:
    yaml = None
if yaml is not None:
    try:
        served = {e.get("model_name") for e in yaml.safe_load(open(config_path))["model_list"]}
    except Exception as exc:  # a config that will not parse is its own suite's failure
        sys.exit("FAIL: %s: %s does not parse (%s)" % (path, config_path, exc))

used = set(re.findall(r"\bagent-[a-z0-9-]+", text))
unknown = sorted(used - roster)
if unknown:
    sys.exit("FAIL: %s: %s is not a local lane (%s)"
             % (path, ", ".join(unknown), ", ".join(sorted(roster))))
if served:
    unserved = sorted(a for a in used if a not in served)
    if unserved:
        sys.exit("FAIL: %s: %s is not a model_name the proxy serves" % (path, ", ".join(unserved)))

# The frame comment is a comment, so a cloud id hiding in prose is still a lie about this
# stack even when no call uses it.
for cloud in ("gpt-", "gpt4", "claude", "gemini", "anthropic/", "openai/", "mistral/",
              "deepseek", "llama.cpp", "api.openai"):
    if cloud in text.lower():
        sys.exit("FAIL: %s: mentions %r, and this stack has no cloud transport" % (path, cloud))

if "export default" not in text:
    sys.exit("FAIL: %s: no default export, so the runner has nothing to call" % path)
PY
}

# ---------------------------------------------------------------------------

@test "workflows: the four named workflows are present" {
  local name
  for name in fleet-verify implement-reviewed debug-fix open-bugs; do
    assert_file_exists "the ${name} workflow" "${WORKDIR}/${name}.js"
  done
}

@test "workflows: every file in the directory is a .js the runner can load" {
  local f
  for f in "${WORKDIR}"/*; do
    [ -e "${f}" ] || continue
    [[ "${f}" == *.js ]] || { printf 'FAIL: %s is not a .js, so the runner never lists it\n' "${f}" >&2; return 1; }
  done
}

@test "workflows: each one parses as JavaScript" {
  command -v node >/dev/null 2>&1 || skip "node is not on PATH in this runner"
  local f
  for f in "${WORKDIR}"/*.js; do
    run node --check "${f}"
    [ "${status}" -eq 0 ] || { printf 'FAIL: %s is not valid JavaScript: %s\n' "${f}" "${output}" >&2; return 1; }
  done
}

@test "workflows: the frame, the name, the aliases, and the export hold for each" {
  local f
  for f in "${WORKDIR}"/*.js; do
    lane_check "${f}" || return 1
  done
}

@test "workflows: the skeptic phase runs on agent-review" {
  # The whole point of these three is the independent pass. A workflow that quietly drops
  # it would still run, and the change would land unreviewed.
  local name
  for name in implement-reviewed debug-fix open-bugs; do
    grep -q 'agent-review' "${WORKDIR}/${name}.js" || {
      printf 'FAIL: %s.js names no agent-review pass, so its result is self-graded\n' "${name}" >&2; return 1; }
  done
}

@test "workflows: the read-only mapping runs on agent-explore" {
  local name
  for name in implement-reviewed debug-fix open-bugs; do
    grep -q 'agent-explore' "${WORKDIR}/${name}.js" || {
      printf 'FAIL: %s.js maps nothing on the explore lane, so the reads ride a full-depth stream\n' "${name}" >&2; return 1; }
  done
}

@test "workflows: every file is ASCII" {
  local f
  for f in "${WORKDIR}"/*.js; do
    run env LC_ALL=C grep -n '[^ -~]' "${f}"
    [ "${status}" -ne 0 ] || { printf 'FAIL: %s carries a non-ASCII byte: %s\n' "${f}" "${lines[0]}" >&2; return 1; }
  done
}

@test "workflows: no file reaches for a tool the local fleet cannot serve" {
  # An MCP or web lane inside a workflow would make a fleet run depend on something a
  # workspace may not have declared; these three are code and shell only.
  local f
  for f in "${WORKDIR}"/*.js; do
    run grep -nE 'web_search|web_fetch|use_tool|searxng__|context7__' "${f}"
    [ "${status}" -ne 0 ] || { printf 'FAIL: %s calls a lane the fleet may not have: %s\n' "${f}" "${lines[0]}" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# open-bugs: the tracker half, read off the source as data.
#
# The runner hands these strings to an agent that pastes them into a shell, so a drift here
# is not a crash -- it is the wrong thing happening on someone's issue. The pins below are
# the discovery, the read, the two writes, the keyword, and the push boundary.

@test "open-bugs: the queue is discovered as open issues under the label filter" {
  tracker_pins "${OPEN_BUGS}" \
    'the sweep lists issues and asks for the open state, so a closed bug never reopens work||gh issue list[\s\S]{0,80}--state open' \
    'that same query carries the label filter, so the sweep is a queue and not the whole tracker||--state open[\s\S]{0,40}--label' \
    'the query asks for the number, the field every later phase works from||--json number,title,labels,url'
}

@test "open-bugs: each report is read with every comment before anything is claimed" {
  tracker_pins "${OPEN_BUGS}" \
    'the report is read with gh issue view and --comments||gh issue view \$\{number\} --comments' \
    'the triage agent is told to read the body AND every comment||[Rr]ead the body AND every comment' \
    'the fixer reads the report too, and works that one number||Work that issue number'
}

@test "open-bugs: every tracker write is a comment whose body comes from a file" {
  tracker_pins "${OPEN_BUGS}" \
    'progress is posted with gh issue comment --body-file||gh issue comment \$\{number\} --body-file \$\{file\}' \
    'the agent writes that file itself, outside the repository||Write it to a scratch ' \
    'and the body is posted verbatim rather than summarised||Body to post, verbatim'
  assert_not_match "no comment body is ever passed in argv" \
    'gh issue comment[^|]*--body [^f]' "$(cat "${OPEN_BUGS}")"
}

@test "open-bugs: the labels are read before an in-progress one is ever added" {
  tracker_pins "${OPEN_BUGS}" \
    'the repository label list is read first||gh label list --json name' \
    'and so are the labels this issue already carries||gh issue view \$\{number\} --json number,title,labels,state' \
    'the in-progress label is added by name, on this issue only||--add-label \$\{workingLabel\}' \
    'the add is gated on that read, not on hope||only if both lists already carry' \
    'a missing label stays a reported absence, never an invented one||never create, rename, or delete a label'
  assert_not_match "no run creates a label" 'gh label create' "$(cat "${OPEN_BUGS}")"
}

@test "open-bugs: the closing keyword is decided, and it lives only in the pull-request body" {
  tracker_pins "${OPEN_BUGS}" \
    'the choice is a real branch over two keywords||settles \? `Closes #\$\{issue\.number\}` : `Refs #\$\{issue\.number\}`' \
    'what settles the report is the skeptic keeping every claim, not the fixer feeling done||const settles = row\.prReady === "yes" && panel\.verdict === "fixed"' \
    'the issue comment is told never to carry a keyword||never write a[\s\S]{0,20}closing keyword \(Closes #, Fixes #\) in the comment' \
    'only the number this run worked may carry one||Only #\$\{issue\.number\} may carry a keyword' \
    'and the keyword never lands on the branch, where GitHub links every commit subject||not in a commit subject'
  python3 - "${OPEN_BUGS}" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
# One decision site each: a second Closes or Refs literal is a second keyword somebody else's
# comment can carry, which is how an issue closes that nobody meant to close.
for needle in ("Closes #${", "Refs #${"):
    found = text.count(needle)
    if found != 1:
        sys.exit("FAIL: %s: %r appears %d times, so the keyword is not decided in one place"
                 % (sys.argv[1], needle, found))
PY
}

@test "open-bugs: the push and the pull request are off unless the operator passes openPr" {
  tracker_pins "${OPEN_BUGS}" \
    'the flag defaults to off, since only these four spellings turn it on||const openPr = \["1", "true", "yes", "on"\]\.includes\(String\(args\?\.openPr \?\? ""\)' \
    'the off branch tells the hand-off not to push||Do not push and do not open the pull request' \
    'the on branch is reachable only through that flag||const pushStep = openPr\s*\?' \
    'and the off branch still hands the operator the two commands||print the two commands the ' \
    'the report says the step was skipped instead of going quiet about it||NOT run - the operator'
  assert_contains_file "the report names the flag that changes it" "${OPEN_BUGS}" 'openPr: true'
}

@test "open-bugs: nothing outside the openPr gate can name a push or a pull request" {
  # The helpers spell the two commands once; the gate is the only thing allowed to reach them.
  # An inline `git push` anywhere else would let a default run push to the operator's remote.
  python3 - "${OPEN_BUGS}" <<'PY'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

gate = re.search(r"const pushStep = openPr\s*\?(.*?);\n", text, re.S)
if not gate:
    sys.exit("FAIL: %s: no `const pushStep = openPr ? ...` gate, so the flag gates nothing" % path)
allowed = [gate.span()]
for name in ("pushCommand", "prCreateCommand"):
    helper = re.search(r"const %s = .*?;\n" % name, text, re.S)
    if not helper:
        sys.exit("FAIL: %s: no %s helper, so the command is spelled inline somewhere" % (path, name))
    allowed.append(helper.span())

for needle in ("git push", "gh pr create"):
    for match in re.finditer(re.escape(needle), text):
        if not any(start <= match.start() < end for start, end in allowed):
            line = text[:match.start()].count("\n") + 1
            sys.exit("FAIL: %s:%d: %r is spelled outside the openPr gate and its two helpers"
                     % (path, line, needle))
for needle in ("pushCommand(", "prCreateCommand(", "Do not push"):
    if needle not in gate.group(1):
        sys.exit("FAIL: %s: the openPr gate never mentions %r, so one branch cannot do the hand-off"
                 % (path, needle))
PY
}

@test "open-bugs: the pull-request body is an artifact at a path the run prints and records" {
  tracker_pins "${OPEN_BUGS}" \
    'the path is the workflow s, built from the issue number||const prBodyPath = \(number\) => `\$\{scratchDir\}/pr-body-issue-\$\{number\}\.md`' \
    'the run prints that path in its report||pr-body: \$\{row\.prBody\}' \
    'the hand-off must write it at exactly that path and report it||report that exact path in body_path' \
    'a body that was not written is reported as not written, not hidden||\(NOT written:' \
    'the issue comment names the branch||Branch: \$\{row\.branch\}' \
    'the tip sha the branch really carries||Tip commit: \$\{row\.commit\}' \
    'and that body path||Pull-request body: \$\{wroteBody \? bodyPath : row\.prBody\}'
  assert_contains_file "the tip comes from git, not from the fixer remembering" \
    "${OPEN_BUGS}" 'git rev-parse'
}

@test "open-bugs: a pull request that already exists for the branch is linked back onto the issue" {
  tracker_pins "${OPEN_BUGS}" \
    'the branch is asked about with gh pr list --head||gh pr list --head \$\{branch\} --state all' \
    'and read back for its number and url||gh pr view \$\{number\} --json number,url,state' \
    'the comment carries that number onto the issue||Pull request: #\$\{handoff\.structured\.pr_number\}' \
    'and says out loud that the comment is the link||this comment is the link back onto the issue' \
    'an absent pull request is named as absent||none is open for this branch yet'
}

@test "open-bugs: every tracker command carries the gh env prefix and the tracker guard" {
  # The pair Coder injects expires about an hour in and gh consults it directly, so one
  # unprefixed call is a 401 landing mid-fan-out. A command string is only a string to node,
  # so the prefix is pinned here rather than trusted.
  python3 - "${OPEN_BUGS}" <<'PY'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
prefix = "env -u GH_TOKEN -u GITHUB_TOKEN"
for match in re.finditer(r"""(["`])gh (issue|pr|label)\b""", text):
    if prefix not in text[max(0, match.start() - 60):match.start()]:
        line = text[:match.start()].count("\n") + 1
        sys.exit("FAIL: %s:%d: a gh command without the %s prefix" % (path, line, prefix))
if prefix not in text:
    sys.exit("FAIL: %s: no gh call carries the prefix at all" % path)
PY
  tracker_pins "${OPEN_BUGS}" \
    'the guard refuses to close, reopen, reassign or milestone an issue it does not own||never close, reopen, reassign, or milestone' \
    'and a line that answers another person goes to the operator as a draft||hand it back in note as a draft for the '
}
