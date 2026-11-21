#!/bin/sh
# managed-by: evo-t1-coder-stack
#
# bin/dangerous-command-guard.sh -- PreToolUse guard for the shell tool.
#
# The stack already denies these commands in prose. The rulebook seed
# (`templates/common/GROK_BUILD_AGENTS.md`, "Execution") tells an agent to clean
# scratch with `find <dir> -type f -delete` because the seeded deny on
# `Bash(rm -rf *)` fires on the benign globbed form too, and the same section
# bans the tmux and pkill sweeps that
# end the very session the agent runs in. Prose is a request a model can talk
# itself past; this hook is the same rule with teeth, run on every shell call.
#
# The rule set is the list, not this script: one extended regex per line in
# deny-patterns.txt beside it, `#` starting a comment and blank lines ignored.
# Adding a rule is a line in that file. A line that does not compile as an ERE is
# skipped with one complaint on stderr, so one bad pattern cannot take the shell
# tool down with it.
#
# Everything this script does not control fails open (ctx/L0.md): no jq, no
# event, no command, no list. A guard that cannot read must never be able to
# wedge a session. It fails closed only on what it is here for -- a command it
# was not handed whole, and a command the list names.
set -u

allow() {
  printf '%s\n' '{"decision":"allow"}'
  exit 0
}

# deny <reason> -- block the call and name the rule, so the reader edits the
# list instead of routing around the guard. jq escapes pattern text, which is
# arbitrary bytes; the fixed fallback keeps stdout a valid decision if jq goes
# missing between the check below and here.
deny() {
  if ! jq -cn --arg reason "$1" '{decision:"deny",reason:$reason}' 2>/dev/null; then
    printf '%s\n' '{"decision":"deny","reason":"command blocked by dangerous-command-guard"}'
  fi
  exit 2
}

command -v jq >/dev/null 2>&1 || allow

event=$(cat)
[ -n "$event" ] || allow
printf '%s' "$event" | jq -e . >/dev/null 2>&1 || allow

# Only the boolean false proves the runner handed the command over complete, so
# true, a null, and an absent key all deny: a command too long to inspect is
# exactly the case a guard must not wave through (ctx/L0.md pins
# "toolInputTruncated not false is a deny for a guard").
truncated=$(printf '%s' "$event" | jq -r '.toolInputTruncated' 2>/dev/null || true)
if [ "$truncated" != "false" ]; then
  deny "dangerous-command-guard: toolInputTruncated is '$truncated' rather than false, so the command could not be inspected whole"
fi

cmd=$(printf '%s' "$event" | jq -r '.toolInput.command // ""' 2>/dev/null || true)
[ -n "$cmd" ] || allow

# Resolve the list against $0, never the cwd: the runner starts a hook with the
# workspace root as its working directory, so $0 is the only thing that says
# where this script itself sits (~/.grok/hooks/bin/, list included).
patterns_file=$(dirname "$0")/deny-patterns.txt
[ -r "$patterns_file" ] || allow

# Read by redirect, not through a pipe, so the loop body is this shell and
# deny's exit 2 leaves the script the way the PreToolUse shape needs it.
lineno=0
while IFS= read -r pattern || [ -n "$pattern" ]; do
  lineno=$((lineno + 1))
  # Blank, whitespace-only, and comment lines carry no rule. The leading-blank
  # arm lets an indented comment and an indented rule read the same way.
  case "$pattern" in
    '' | [[:space:]]* | '#'*) continue ;;
  esac
  # LC_ALL=C matches byte-wise, so a command holding bytes the container locale
  # cannot decode reads as data rather than as a regex that failed to compile.
  printf '%s\n' "$cmd" | LC_ALL=C grep -E -q -e "$pattern" >/dev/null 2>&1
  status=$?
  if [ "$status" -gt 1 ]; then
    printf 'dangerous-command-guard: %s:%s: not a valid extended regex, skipping: %s\n' \
      "$patterns_file" "$lineno" "$pattern" >&2
    continue
  fi
  if [ "$status" -eq 0 ]; then
    deny "dangerous-command-guard: command matched $patterns_file line $lineno: $pattern"
  fi
done <"$patterns_file"

# Nothing on the list matched, and stdout still has to carry the decision
# (ctx/L0.md), which is what allow prints before its exit 0.
allow
