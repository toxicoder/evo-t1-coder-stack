---
name: "reflect-and-evolve"
description: "Thoroughly review past Grok Build sessions and implement well-planned improvements to AGENTS.md, skills, reusable scripts, tools, and configs. Use when the user asks to reflect, evolve, self-improve, or optimize the agent setup based on experience."
when-to-use: "Use when the user asks to reflect and evolve, to review past sessions and
  improve yourself, to evolve the agent / AGENTS.md / skills based on what we've learned, or to
  make the system better from previous work, and after a long or difficult session when the
  user wants the setup improved."
argument-hint: "[repo-path] [--since <days>] [--dry-run]"
compatibility: "Requires python3 for the session sweeper and read access to
  `~/.grok/sessions/` for the evidence; what it changes is gated by the repository's own gate
  (`bazelisk test //:test-fast`, `bazelisk test //:lint --test_tag_filters=manual`)."
metadata:
  author: "operator"
  short-description: "Review past sessions and land high-leverage improvements to the agent setup"
  type: "workflow"
  lifecycle: "active"
---

<!-- managed-by: evo-t1-coder-stack -->

# Reflect and Evolve - Continuous Self-Improvement of the Agent System

Review past sessions, identify systemic friction or failures, and make high-leverage changes
to the agent's instructions, skills, tools, and configuration. Be willing to make large,
well-justified changes rather than small tweaks.

## When to Use

Trigger on requests such as:

- "reflect and evolve"
- "review past sessions and improve yourself"
- "evolve the agent / AGENTS.md / skills based on what we've learned"
- "make the system better from previous work"
- After a long or difficult session when the user wants the setup improved

## Core Workflow

Follow these steps in order. Be thorough. Prefer evidence from actual past work over speculation.

### 1. Gather Evidence

Collect as much real signal as possible before proposing changes:

- Read the current `AGENTS.md` (project root and any nested or global versions).
- List existing skills (`ls .grok/skills/` or equivalent) and note their purposes from frontmatter.
- Review recent conversation transcripts, session logs, or memory if available. In this stack
  that is, in order: the session sweeper
  (`python3 skills/reflect-and-evolve/scripts/session_signals.py --limit 20`) to rank sessions
  by friction, then `~/.grok/memory/<slug>-<hash8>/sessions/*.md` for the session logs written
  by `/ez-learn`, and `~/.grok/notes/<host>/<owner>/<repo>/notes.md` for stored notes. Look
  for:
  - Repeated user corrections or "don't do that" patterns
  - Tasks that required many tool calls or back-and-forth
  - Places the agent went down the wrong path
  - Manual steps that were repeated across sessions
  - Missing knowledge that caused delays
- Three caps on that sweep: never `cat` a `chat_history.jsonl`, `prompt_history.jsonl`, or
  `events.jsonl` into the transcript; never list, read, or cite `/var/lib/grok-session-archive`;
  never read `.env` or `.env.*`, and name the operator CLI that prints the value instead
  (`dev-stack -- status`, `bootstrap -- --check`, `update-configs`). Derive such paths with
  `find`/`ls`, and cap everything else with `head -n`, `--limit`, or a `/tmp` scratch file.
- Check configs (e.g. `.grok/`, tool configs, shell aliases, editor settings) for friction.
- Note any previous CHANGELOG entries or improvement notes.

If session history is limited, state the limitation clearly and work from available artifacts (current AGENTS.md, skills, recent files).

### 2. Analyze for High-Leverage Opportunities

Categorize findings:

| Category | Examples | Typical Fix |
|----------|----------|-------------|
| Instruction gaps | Agent repeatedly does X wrong | Update `AGENTS.md` with explicit rule + example |
| Missing capability | Same multi-step process reinvented | Create a skill or reusable script |
| Inefficient path | Too many tool calls for a common action | Add a script or skill that steers faster |
| Config friction | Environment or tool setup causes errors | Update configs or add setup script |
| Skill quality | Existing skill is incomplete or under-triggers | Improve skill (description, steps, evals) |
| Architectural | Fundamental process is wrong | Larger redesign of AGENTS.md or skill graph |

Prioritize changes that:

- Will save time or prevent errors in future sessions
- Are supported by evidence (not just "would be nice")
- Have clear success criteria

Be willing to propose **big changes** when evidence supports them (rewriting sections of
AGENTS.md, restructuring skills, introducing a new tool layer).

### 3. Plan Changes

Before editing, write a short plan covering:

- What will change and why (cite evidence)
- Expected impact
- Risks or cascading effects
- How you will validate

Prefer a small number of high-impact changes over many minor ones in a single run. If the
scope is large, implement the highest-value subset and note the rest for a future reflection.

### 4. Implement

Make the changes directly:

- **AGENTS.md**: Edit with precise, actionable rules. Prefer imperative language and concrete examples. Remove or update conflicting older rules.
- **Skills**: Create or update skills with proper frontmatter, workflow, and evals. Use
  `/ez-create-skill` to scaffold a new skill and `/ez-skillify` to mine the session that just
  worked; a skill's gate in this repo is an asserting Bats suite, the
  `tests/bats/trunk-refactor-skill.bats` pattern.
- **Scripts / tools**: Add reusable scripts in an appropriate location (`scripts/`, skill
  `scripts/`, or project tools). Make them robust and document usage in AGENTS.md or the skill.
- **Configs**: Update relevant config files. Prefer changes that are committed and reproducible.
- Record significant changes in the commit message and the pull request: this repo keeps no
  first-party `CHANGELOG.md`. A fact worth keeping past the change goes to the notes file
  through `/ez-learn`.

After each substantial change, briefly verify it (read the file back, run a script with sample input, check frontmatter, etc.).

The agent rulebook and the skill suite are seeds in *this* repository -
`templates/common/GROK_BUILD_AGENTS.md`, `templates/common/*.SKILL.md`,
`templates/common/*.AGENT.md`, `templates/common/*.PERSONA.toml` - that the workspace boot
re-materialize into `~/.grok/`. A reflection run edits the seed and re-materialize it; it
never hand-edits the copy living in a workspace. The same rule covers the operator CLIs under
`scripts/`. Run the gate after: `bazelisk test //:test-fast` and
`bazelisk test //:lint --test_tag_filters=manual`.

### 5. Validate and Summarize

- Confirm the most important changes are correct and non-breaking.
- Update any skill evals or triggers that are now outdated.
- Provide a clear summary to the user:
  - What evidence was reviewed
  - Key problems identified
  - Changes made (with file paths)
  - Why each change should improve future sessions
  - Any recommended follow-up or residual risks

## Principles

- **Evidence over intuition**: Prefer patterns observed in actual sessions.
- **High leverage**: One good AGENTS.md rule or script is better than many small notes.
- **Bold but planned**: Large changes are encouraged when justified. Do not make them carelessly.
- **Steer faster**: The goal is not just correctness but reducing the number of steps and corrections needed next time.
- **Leave the system better**: Every run of this skill should result in a measurable improvement in future agent performance.

## Common Targets

- `AGENTS.md` - core agent instructions and rules
- `.grok/skills/*/SKILL.md` and supporting files
- Project `scripts/` or skill-bundled scripts
- Tool configuration and environment setup
- Memory or persistent context files when they cause repeated mistakes

## References

- `skills/reflect-and-evolve/references/checklist.md` - checklist and heuristics for evidence
  gathering, analysis, and change quality. Read when planning or when evidence is ambiguous.
- `skills/reflect-and-evolve/scripts/session_signals.py` - the session sweeper step 1 runs,
  which ranks sessions by friction without reading a transcript.
- For skill creation and improvement details, consult `/ez-create-skill` and `/ez-skillify`
  and their references (workflows, output patterns).

Start every reflection by reading the current state rather than assuming it.
