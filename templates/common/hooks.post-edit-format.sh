#!/bin/sh
# managed-by: evo-t1-coder-stack
#
# ## post-edit-format.sh -- PostToolUse hook: format the one file an edit just wrote
#
# Started by ~/.grok/hooks/evo-t1-hooks.json on Edit|Write|search_replace|write with a
# 20s timeout. Reads one event line on stdin and prints a PostToolUse decision only when
# a formatter moved bytes under the model (ctx/L0.md:40-42).
#
# Invariants:
#   - Silent on every refusal, exit 0 on every path: a PostToolUse handler that exits
#     non-zero or writes a malformed line costs the session its next tool call, so a
#     guard here may only ever stay quiet.
#   - One file, never a directory or a tree. Whole-tree formatting is //:fix's job, and
#     the three command lines below are fix.sh:24-40's own flags, so a hook format and a
#     //:fix run can never disagree about what "formatted" means.
#   - The refusal list is load-bearing, not tidiness. ~/.grok/agents/*.md, the persona
#     and SKILL.md families are owned by their managed-by marker and compared
#     byte-for-byte against the seeds in this repo, so one reformatted seed silently
#     stops being stack-owned. Hence /.grok/, /.agents/ and /.coder/ beside the
#     build-artifact paths.
#   - That list is matched lexically, so a /../ segment and a symlink are refused rather
#     than resolved: resolving either aims a formatter at a file these tests never saw.
set -u

# Guard the guards: no jq means no fields, and a hook that cannot read its event stays
# quiet the same way it does for a file it must not touch.
command -v jq >/dev/null 2>&1 || exit 0

event=$(cat 2>/dev/null) || event=""
[ -n "$event" ] || exit 0

# field <jq-filter> -- one value out of the event, "" for a missing or broken one.
field() {
  printf '%s' "$event" | jq -r "$1" 2>/dev/null
}

tool_name=$(field '.toolName // empty')
case "$tool_name" in
  Edit | Write | search_replace | write) : ;;
  *) exit 0 ;;
esac

# The three keys the edit tools use, first one set wins. A non-string value is not a
# path, so it reads as no path and the edit is left alone.
path=$(field '(.toolInput.file_path? // .toolInput.target_file? // .toolInput.path?)
  | if type == "string" then . else "" end')
[ -n "$path" ] || exit 0

# Padded so a deny-listed or dot segment at either end still reads between two slashes.
# A /../ segment is refused with the build artifacts because the containment test below
# is lexical, and a hop is the one spelling that could walk it out of the project.
probe="/$path/"
# The three names Bazel links into the workspace, spelled out because a prefix match on
# bazel- would refuse this clone's own sources: scripts/bazel-map.sh and
# tests/bats/bazel-map.bats both start with it, and a guard that skips them looks exactly
# like a session that needed nothing.
case "$probe" in
  *"/../"* | *"/.git/"* | *"/bazel-out/"* | *"/bazel-bin/"* | *"/bazel-testlogs/"* | \
    *"/node_modules/"* | *"/__pycache__/"*) exit 0 ;;
esac
case "$probe" in
  *"/.grok/"* | *"/.agents/"* | *"/.coder/"*) exit 0 ;;
esac

name="${path##*/}"
# Refused before the file is touched at all: a dotenv file is never this hook's to open.
case "$name" in
  .env | .env.*) exit 0 ;;
esac

case "$path" in
  /*) abs="$path" ;;
  *)
    # A relative path belongs to the event's own cwd, which is the only directory this
    # hook may resolve it against; without it the path would resolve against wherever
    # the runner happened to start, which is not a claim about the edited file.
    cwd=$(field '.cwd | if type == "string" then . else "" end')
    case "$cwd" in
      /*) abs="${cwd%/}/$path" ;;
      *) exit 0 ;;
    esac
    ;;
esac

root="${CLAUDE_PROJECT_DIR:-}"
case "$root" in
  /*) ;;
  *) exit 0 ;;
esac
root="${root%/}"
[ -n "$root" ] || exit 0
# "$root" is quoted so a metacharacter in it stays a literal prefix; the trailing slash
# is what keeps /proj-off from passing for /proj.
[ "${abs#"$root"/}" != "$abs" ] || exit 0

# -f follows a link, so the link itself has to be refused first.
[ -L "$abs" ] && exit 0
[ -f "$abs" ] || exit 0

formatter=""
case "$name" in
  *.sh) formatter="shfmt" ;;
  BUILD | BUILD.bazel | MODULE.bazel | *.bzl) formatter="buildifier" ;;
  *.py) formatter="ruff" ;;
esac
[ -n "$formatter" ] || exit 0
# A missing formatter is a no-op, not a warning: the image carries these three and an
# image without one must behave like an edit nobody formatted, not like a failing hook.
command -v "$formatter" >/dev/null 2>&1 || exit 0

# The byte comparison is the whole decision, so it is only made against a real snapshot;
# without one the file still gets formatted and nothing is reported.
snapshot=""
if command -v mktemp >/dev/null 2>&1 && command -v cmp >/dev/null 2>&1; then
  snapshot=$(mktemp "${TMPDIR:-/tmp}/evo-t1-post-edit-format.XXXXXX" 2>/dev/null) || snapshot=""
  if [ -n "$snapshot" ]; then
    cp -p -- "$abs" "$snapshot" 2>/dev/null || snapshot=""
  fi
fi

# The formatter's own chatter never reaches stdout: on this event stdout is the decision
# channel, and one line of shfmt complaint is a decision the runner cannot parse.
case "$formatter" in
  shfmt) shfmt -w -s -i 2 -ci -- "$abs" ;;
  buildifier) buildifier -mode=fix -- "$abs" ;;
  ruff) ruff format --quiet -- "$abs" ;;
esac >/dev/null 2>&1

changed=0
if [ -n "$snapshot" ]; then
  cmp -s -- "$snapshot" "$abs" || changed=1
  rm -f -- "$snapshot" 2>/dev/null
fi
[ "$changed" -eq 1 ] || exit 0

# Built with jq so a path holding a quote or a backslash still yields parseable JSON.
context="${formatter} reformatted ${abs} after the edit; the file on disk no longer"
context="${context} holds the bytes you wrote, so re-read it before you edit it again."
jq -n --arg ctx "$context" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null
exit 0
