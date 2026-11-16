#!/bin/sh
# managed-by: evo-t1-coder-stack
#
# bin/selective-test-runner.sh -- PostToolUse advisor that starts one Bazel test for
# the file just edited and gets out of the way.
#
# The point is the verdict a person reads before they say "done": the edit lands, this
# hook names the one target that covers that file, and the model is handed the log path
# instead of a claim. Everything about the run is deliberately off the critical path --
# nohup, every descriptor redirected, no wait -- because a PostToolUse handler that
# runs a test inline charges the session for the build (ctx/L0.md pins "never runs a
# test inline" and the timeout at 10, which one bazelisk analysis pass can eat).
#
# Off unless EVO_T1_HOOK_TESTS=1. A hook that fires bazelisk on every keystroke-sized
# edit is the hook people disable, so the default is silent and the operator opts in.
#
# Like the rest of the family, everything outside what it controls is a silent exit 0:
# no flag, no jq, no event, no path, no label. This event must never block and must
# never exit non-zero (ctx/L0.md).
set -u

[ "${EVO_T1_HOOK_TESTS:-}" = "1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

event=$(cat)
[ -n "$event" ] || exit 0

# field <jq filter> -- one string field from the event, empty when it is absent,
# null, or the payload does not parse.
field() {
  printf '%s' "$event" | jq -r "$1 // empty" 2>/dev/null || true
}

# Same resolution order as bin/post-edit-format.sh: file_path, then target_file, then
# path (ctx/L0.md pins the trio for both PostToolUse handlers).
edited=$(field '.toolInput.file_path')
[ -n "$edited" ] || edited=$(field '.toolInput.target_file')
[ -n "$edited" ] || edited=$(field '.toolInput.path')
[ -n "$edited" ] || exit 0
# Only an explicit true says the toolInput arrived in pieces, and half a path is not a
# path to run a test for. The guard next door fails closed on an absent key because it
# blocks; an advisor that did the same would go quiet on any runner that omits it.
if [ "$(field '.toolInputTruncated')" = "true" ]; then
  exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-}"
project_dir=${project_dir%/}
[ -n "$project_dir" ] || exit 0
# Relative paths come from the runner's working directory, which is the workspace root,
# so they join the project dir before the containment test can mean anything.
case "$edited" in
  /*) ;;
  *) edited="$project_dir/$edited" ;;
esac
case "$edited" in
  "$project_dir"/*) ;;
  *) exit 0 ;;
esac
# Not this clone's test to run: the VCS object store, and the tool directories the
# agent itself owns, which is where a hook's own edits land.
case "$edited" in
  */.git/* | */.grok/* | */.agents/* | */.coder/*) exit 0 ;;
esac
# bazel-map's tests-for takes a repo-relative path, which is also the shape a person
# reads back.
rel=${edited#"$project_dir/"}

# Settled once, up here, so the "not on PATH" line stays reachable on the fallback
# branch too -- that branch needs bazelisk merely to find the label.
have_bazelisk=0
command -v bazelisk >/dev/null 2>&1 && have_bazelisk=1

label=""
case "$edited" in
  "$project_dir/tests/bats/"*.bats)
    # The repo's own suite naming: bazelisk test //tests:bats_<stem>_test, dashes to
    # underscores (AGENTS.md, Commands). Derived, never asked, because the mapping is
    # total and a query for it would be the slow path on the most edited test files.
    stem=${edited##*/}
    stem=${stem%.bats}
    label="//tests:bats_$(printf '%s' "$stem" | tr -- '-' '_')_test"
    ;;
  *)
    # tests-for wraps its labels in the section and summary lines every CLI here
    # prints, so the first line that is a label is the answer.
    if [ "$have_bazelisk" = "1" ]; then
      label=$(bazelisk run //scripts:bazel-map -- tests-for "$rel" 2>/dev/null |
        grep -m1 '^//' || true)
    fi
    ;;
esac
[ -n "$label" ] || exit 0

# context <line> -- the one PostToolUse shape (ctx/L0.md): additionalContext, exit 0.
# jq escapes the path, which is arbitrary bytes.
context() {
  if ! jq -cn --arg ctx "$1" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"selective-test-runner: a test was started, read the evo-t1-hook-tests log under TMPDIR for the verdict"}}'
  fi
}

if [ "$have_bazelisk" = "0" ]; then
  context "selective-test-runner: not starting ${label}, bazelisk is not on PATH."
  exit 0
fi

log_dir="${TMPDIR:-/tmp}/evo-t1-hook-tests"
mkdir -p "$log_dir" 2>/dev/null || exit 0
# One label to one log file, so keep only the characters a filename tolerates.
log="$log_dir/$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_').log"
# Detached: nohup plus redirected stdin, stdout and stderr lets the hook return at once
# without disown, which POSIX sh does not define, and stops the child holding the
# event pipe or the hook's stdout open.
nohup bazelisk test "$label" --test_output=errors >"$log" 2>&1 </dev/null &

context "selective-test-runner: ${label} is running in the background; read ${log} for the verdict before you call this done."
exit 0
