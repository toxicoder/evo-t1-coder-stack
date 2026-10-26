---
name: grok-build-delegation
description: "Delegate big multi-file work to the Grok Build CLI (`grok`, also on PATH as `agent`): run it headless as a tracked background process, then review its diff and run the project tests before reporting done."
---

<!-- managed-by: evo-t1-coder-stack — stack-seeded. Delete this file to take the
     skill over: the workspace boot reseeds it only while the file is absent. -->

# Grok Build delegation

## Small ask — handle it yourself

Single-file or short-readable work (read a file, tweak one file, run one
command): do it yourself with `read_file`, `edit_files` and `execute`. Do not
delegate — delegation costs a review pass and buys nothing on a small ask.

## Big task — delegate through `execute`

Multi-file refactor, framework adoption, test suites, a new app: anything that
needs many tool calls against a real repository. Run the Grok Build CLI
headless instead of driving the edits yourself, via `execute`:

    execute: grok -p "<the task brief, with its acceptance criteria>" --cwd <repo> --permission-mode acceptEdits --max-turns <budget>

Rules:

1. Write the brief first: goal, the repo path, and the acceptance criteria —
   the commands or behaviour that prove the task is done. Delegation without
   criteria has nothing to review the delegated diff against.
2. Start it as a TRACKED BACKGROUND PROCESS and poll its output (re-`execute`
   to re-check the tracked process/log, or reattach to its tmux session) —
   `execute` only waits a short window per tool call (about a minute), so a
   synchronous foreground `grok -p` would die mid-run on any big task.
3. When it exits, REVIEW before anything else: `git diff` in the repo (plus
   `git status` for new files), then RUN the project's own tests or build
   against the criteria you wrote.
4. Only then report done. If grok exited non-zero, hit the timeout, or the
   diff fails the criteria, fall back to doing the work yourself — say so in
   the reply rather than reporting or relaunching unreviewed results.

## Environment facts

- `grok` lives at `/usr/local/bin/grok` and may also be called as `agent`
  (the symlink beside it).
- LiteLLM is already exported into workspace shells: `LITELLM_BASE_URL` plus
  the key in `LITELLM_API_KEY`; the CLI's default model alias `agent` is the
  tool-call-capable one. Never print or embed `$LITELLM_API_KEY` in a command,
  file or reply — reference it by name only.
