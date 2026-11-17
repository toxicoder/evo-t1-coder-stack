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
# Usage: bazelisk test //tests:bats_agent_workflows_test   (from any cwd)
# Safety: reads the workflow directory and litellm/config.yaml; writes nothing. node is
# probed for and the parse test skips, rather than fails, when the runner has none.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
WORKDIR=""
CONFIG=""

# The aliases this repo declares. Anything outside it is a cloud id or a typo, and both
# mean a call that cannot be served from this box.
LANE_ROSTER='agent agent-low agent-medium agent-xhigh agent-xhigh-fast agent-swarm agent-swarm-fast agent-explore agent-review coder coder-fast chat'

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || return 1
  WORKDIR="${REPO_ROOT}/.grok/workflows"
  CONFIG="${REPO_ROOT}/litellm/config.yaml"
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

@test "workflows: the three named workflows are present" {
  local name
  for name in fleet-verify implement-reviewed debug-fix; do
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
  # The whole point of these two is the independent pass. A workflow that quietly drops
  # it would still run, and the change would land unreviewed.
  local name
  for name in implement-reviewed debug-fix; do
    grep -q 'agent-review' "${WORKDIR}/${name}.js" || {
      printf 'FAIL: %s.js names no agent-review pass, so its result is self-graded\n' "${name}" >&2; return 1; }
  done
}

@test "workflows: the read-only mapping runs on agent-explore" {
  local name
  for name in implement-reviewed debug-fix; do
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
