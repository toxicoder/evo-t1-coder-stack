---
name: ez-skillify
description: "Turn the session that just worked into a Skill from its transcript: agree the name, scope and triggers, then write it into both skill homes. Use when asked to turn this session into a skill, capture what we just did, make this repeatable, or to skillify. Registers /ez-skillify."
when-to-use: "Right after a session completed a repeatable workflow cleanly."
argument-hint: "[skill-name]"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["ez-skillify"]` under
     `[skills]` in `~/.grok/config.toml`. -->

# Skillify this session

Capture the procedure that just worked. The transcript is the source of truth: the goal as
first stated, the tool calls, the files they touched, the corrections the user made, and the
check that proved the run was good. The honest gate comes first -- this command is for a run
that WORKED; a flaky or exploratory session is not a procedure, and capturing one hands the
next session a recipe to fail by. The transcript already holds the working steps, so this is
faster and richer than a blank prompt.

Run each block with your shell tool -- `run_terminal_command` (Grok Build CLI) or `execute`
(Coder Agents chat agent). A command inline in a skill body runs nothing: it is a step, and the
body says who runs it.

## Step 1 -- decide whether this session is skillifiable

All four answers have to be yes.

1. It succeeded -- done and verified, not "probably done".
2. It is repeatable: someone would run this again (a review process, a deployment flow, a
   multi-step refactor pattern).
3. Nothing covers it already -- list the homes, then read the frontmatter of anything close:

       ls ~/.agents/skills/ ~/.coder/skills/ "$(git rev-parse --show-toplevel 2>/dev/null)/.grok/skills" 2>/dev/null
       head -n 6 ~/.agents/skills/*/SKILL.md ~/.coder/skills/*/SKILL.md 2>/dev/null

4. It is not one-off: a fix keyed to one branch name or one incident id is a commit message,
   not a workflow.

If one answer is no, name which one and hand the user to `/ez-create-skill`, which authors
a skill from what they describe rather than from what just happened. Never capture a flaky run as if it were
a procedure.

## Step 2 -- reconstruct the procedure from the transcript

Pull five things out of it:

1. The goal, in the user's own first words: it becomes the opening line and most of the
   `description`.
2. The ordered steps that worked -- each tool call and the files it touched; drop the abandoned
   attempts and the narration.
3. The one command or check that PROVED it worked. It becomes the skill's success criterion,
   and it must be a command the future agent can run itself --
   `bazelisk test //:test-fast`, `bazelisk run //scripts:mcp-check`, a `grok inspect` line --
   never "it looked right". The body ends with it, and says the work is not done until it
   passes.
4. Every correction the user made -- "not that file", "use the twin", "run the gate first".
   Each becomes a gotcha or an explicit rule -- the most valuable lines in the file.
5. The edge cases that came up, and the dead ends -- a "do not" line only where someone
   would re-attempt it.

## Step 3 -- generalize it

Turn what was true only tonight into parameters the next caller fills in -- the repo path, the
branch, a model alias, the container name, the ticket id. Keep every constraint that still
holds next time: the two-home rule below, the gate to run, the file not to touch. Drop the
narration: a skill body is instructions, not a transcript.

## Step 4 -- confirm name, scope and triggers with the user

Propose a name -- lowercase letters, digits and hyphens, 2 to 64 characters, starting and ending
with a letter or digit -- and check it is free: ls the homes above and run
`grok inspect | grep -i '<name>'`. A contested bare name stays with the built-in, so your skill
is reachable only under its qualified `scope:name` form; if the name is taken, propose another.

Propose the `description` and `when-to-use` and show both for approval BEFORE writing anything.
The description says what the skill does, carries the phrases people type, and names the slash
command `/ez-<name>`: that text is what the model matches on. Then ask the one question
that matters: model-invocable (the default, so the skill fires when a prompt matches) or
`disable-model-invocation: true`, so only an explicit `/name` runs it -- right for anything that
deploys, pushes, or resets. Never set `user-invocable`: it defaults to true and `false`
unregisters the command.

## Step 5 -- write it

Create the folder in BOTH skill homes; one file per folder, same content -- ship both or the chat
side cannot invoke it:

    mkdir -p "$HOME/.agents/skills/<name>" "$HOME/.coder/skills/<name>"

- `~/.agents/skills/<name>/SKILL.md` -- the copy the Grok Build CLI reads.
- `~/.coder/skills/<name>/SKILL.md` -- the copy the Coder Agents chat agent reads. The chat
  agent reads this path ONLY, so the pair is not optional.

Write each with your file tool (`write` in the CLI).

For something team-relevant, also write `<repo_root>/.grok/skills/<name>/SKILL.md` -- that copy
travels with git. The CLI also reads `~/.grok/skills/`. The chat agent reads neither, so a repo
copy or a `~/.grok/skills/` copy is IN ADDITION to the two-home pair, never instead of it. A
project-tier folder must be trusted first, or its skill is withheld.

Add `scripts/` or `references/` siblings only when the skill needs one: Grok inlines at most the
first 25,000 tokens of a body (the same cap as `read_file`), so keep the body tight and put long
reference material in a sibling, told to be read with an offset and a limit.

## Step 6 -- verify, then hand it over

Read both files back: discovery sees the file, not what you composed. Then:

    grok inspect | grep -i '<name>'
    grok inspect --json

`--json` prints each skill's `source` and `userInvocable`: confirm it is discovered, that a
`source` line shows for BOTH homes, and that `userInvocable` is true. Then tell the user:

- Test it in a NEW turn with `/ez-<name>` and a fresh argument; in this turn the model still
  holds the transcript, so a pass proves nothing.
- Discovery reloads from disk, so an edit lands next turn with no restart.
- To hide it without deleting: `disabled = ["<name>"]` (listed, inactive) or
  `ignore = ["<path>"]` (hidden entirely) under `[skills]` in `~/.grok/config.toml`.

## What makes the captured skill good

- A specific `description`: a vague one never fires. Name the trigger phrases and command.
- Concrete numbered steps, in the order they have to happen.
- Tools named, not implied: `run_terminal_command`, `execute`, `read_file`, `write`.
- One workflow per skill: deploy and rollback beat one skill doing each badly.
- The success-criterion command from Step 2 in the body, and the body ends on it.
- The user's corrections written as rules, not remembered as an anecdote.

## Boundaries

- Never write a skill over a home copy that still carries the stack marker
  (`managed-by: evo-t1-coder-stack`): a marked file is stack-owned and the boot rewrites it. Pick
  another name, or change the seed under `templates/common/` and re-materialize it with `bazelisk run //scripts:refresh-configs` from a host shell.
- Never capture a secret: no token, key value, or `.env` content in a skill body -- name the key
  (`LITELLM_API_KEY`) instead of printing it.
- Commit nothing unless the user asks, including a repo copy under `<repo_root>/.grok/skills/`.
- A skill is not a memory: durable facts go to `/remember`; this command captures processes.
