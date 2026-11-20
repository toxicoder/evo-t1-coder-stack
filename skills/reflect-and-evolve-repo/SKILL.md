---
name: "reflect-and-evolve-repo"
description: "Thoroughly review past sessions in the context of the current git repository, identify codebase issues, anti-patterns, and opportunities, then implement well-planned improvements to code, project conventions, scripts, docs, and configs. Use when the user asks to reflect on the project, evolve the codebase, improve best practices, or make the repo better based on experience."
when-to-use: "Use when the user asks to reflect and evolve the repo, codebase or project, to
  improve this project based on past sessions, to evolve the codebase and its best practices,
  or to review what has been done and make the repository better. For the agent setup itself,
  use /reflect-and-evolve."
argument-hint: "[repo-path] [--since <days>] [--dry-run]"
compatibility: "Works in any git repository. Here what it changes is gated by the
  repository's own gate (`bazelisk test //:test-fast`,
  `bazelisk test //:lint --test_tag_filters=manual`); elsewhere it runs the target repo's own
  test, lint and typecheck commands."
metadata:
  author: "operator"
  short-description: "Review past sessions and land high-leverage improvements to the repository"
  type: "workflow"
  lifecycle: "active"
---

<!-- managed-by: evo-t1-coder-stack -->

# Reflect and Evolve (Repo) - Continuous Improvement of the Current Codebase

Review past work in this git repository, identify systemic issues, friction, and anti-patterns in
the codebase and the project practices around it, then make high-leverage, well-planned
improvements. Focus on this specific project and its best practices rather than on general agent
setup: this skill changes the repository, `/reflect-and-evolve` changes the agent.

## When to Use

Trigger on requests such as:

- "reflect and evolve the repo / codebase / project"
- "improve this project based on past sessions"
- "evolve the codebase and best practices"
- "review what we've done and make the repo better"
- After difficult work in the repository when the user wants structural improvements

Not for the rulebook, the skills, the hooks, or the `~/.grok` config: that is `/reflect-and-evolve`.

## Core Workflow

Follow these steps in order. Ground every change in evidence from this repository and its past
sessions. Be willing to make large, well-justified changes (refactors, new conventions, structural
improvements) when the evidence supports them.

### 1. Gather Evidence from the Repo and Sessions

Collect real signal specific to this project:

- Run `git status` and `git log --oneline -20`, and read the recent commits for patterns: what gets
  touched together, what gets reverted, what lands as a fixup.
- Read the key project files: `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, the architecture docs
  under `docs/`, the linter and formatter configs, and CI under `.github/workflows/`.
- List the major directories and name the structure, languages, and tooling: `scripts/` with
  `scripts/lib/`, `templates/`, `tests/bats/`, `lints/`, `docs/`, and the read-only payloads
  `litellm/`, `hermes/`, `homepage/`, `proxy/`, `searxng/`.
- Ask the graph rather than grepping: `bazelisk run //scripts:bazel-map -- scope --untracked` names
  the tests for what changed, and `-- owners <path>` says whether a new file is visible to a gate.
- Review past sessions, session artifacts, or memory for friction tied to this codebase: the sweeper
  `python3 skills/reflect-and-evolve/scripts/session_signals.py --limit 20` ranks the sessions, then
  `~/.grok/memory/<slug>-<hash8>/sessions/*.md` (the `/ez-learn` logs) and `~/.grok/notes/<host>/<owner>/<repo>/notes.md`. Look for:
  - Repeated bugs, friction, or user corrections related to this codebase
  - Places the agent struggled with project conventions
  - Tasks that required excessive manual steps or workarounds
  - Missing tests, docs, scripts, or automation
  - Inconsistencies in style, architecture, or practice
- That route is not free: `~/.grok/sessions/<escaped-cwd>/*/` holds gigabytes and the sweeper above is the
  only sanctioned way in. Never print `chat_history.jsonl`, `prompt_history.jsonl`, or `events.jsonl`, never
  list `/var/lib/grok-session-archive`, never read `.env` or `.env.*`, and cap the rest with `head -n`.
- Check the existing `scripts/`, the `Makefile`, the Bazel targets, `.githooks/pre-commit`, and the
  CI workflow for gaps. Make is a shim here, so a Makefile-only fix says nothing new.
- Note the project-specific rules already documented, so the run evolves them instead of restating.

If session history is limited, state the limitation and work primarily from the current codebase
state and recent git history.

### 2. Analyze for High-Leverage Project Improvements

Categorize the findings specific to this repo:

| Category | Examples | Typical Fix |
|----------|----------|-------------|
| Code quality / patterns | Repeated anti-patterns, inconsistent structure | Refactor, add a lint rule, document the convention |
| Missing automation | Manual steps repeated across sessions | Add a `scripts/*.sh` CLI or a Bazel target |
| Documentation gaps | Architecture or setup unclear | Update `README.md`, add an ADR under `docs/`, improve inline docs |
| Convention drift | Style or practice varies | Enforce via `lints/` config (shellcheck, shfmt, buildifier, ruff) plus `AGENTS.md` or `CONTRIBUTING.md` |
| Testing / reliability | Fragile areas or missing coverage | Add a `tests/bats/` suite or widen the coverage targets |
| Developer experience | Slow or error-prone local workflows | Improve `scripts/`, the Bazel targets, or the devcontainer config |
| Architectural | Fundamental design issues surfaced by work | Larger refactor or restructuring (plan it carefully) |

Prioritize changes that:

- Will make future work in this repo faster, safer, or more consistent
- Are supported by evidence from the codebase or its sessions, not by "would be nice"
- Have clear success criteria, which here means a gate label that goes green
- Align with, or deliberately evolve, the direction the project already took

Be willing to propose **big changes** (significant refactors, new tooling layers, convention overhauls)
when the evidence supports them.

### 3. Plan Changes

Before editing, write a short plan covering:

- What will change and why, citing specific evidence from the repo or a session
- The expected impact on future development
- Risks, migration steps, or cascading effects - the `.tftpl` payload twins under `templates/workspace/`
  and `templates/devcontainer/` move together, and new payload must join `//:stack_data` to be gated
- How you will validate: `bazelisk test //:test-fast`,
  `bazelisk test //:lint --test_tag_filters=manual`, and `bazelisk test //tests:bats_<stem>_test`

Cut the branch before the first edit: a short-lived branch off the tip of `main`, one logical change
per branch. `development`, `staging`, and `production` are environments, never branches. Incomplete
work lands on `main` behind a flag that defaults off, in the first shape that fits: an env var with
a dotenv sample, a compose `profiles:` entry, a `config/flags.yaml` key, a template parameter.

Prefer a small number of high-impact changes over many minor ones in a single run. If the scope is
large, implement the highest-value subset and note the rest for a later reflection.

### 4. Implement in the Repository

Make the changes directly in the repo:

- **Code**: refactor, fix the pattern, improve the structure. An operator CLI sources
  `scripts/lib/common.sh` rather than copying its helpers, and imports the Python, awk, or probe it
  needs instead of embedding a second language in the caller.
- **Project conventions**: update or create `AGENTS.md`, `CONTRIBUTING.md`, the architecture docs
  under `docs/`, or a style guide, with precise, actionable rules and an example for each.
- **Scripts / automation**: add the reusable `scripts/*.sh` CLI or Bazel target that replaces the
  manual step, and document it in `README.md` and `AGENTS.md`. A new `scripts/*.sh` needs a key in
  `_SCRIPT_LIBS` or `_SCRIPT_PAYLOAD` in `scripts/BUILD.bazel`; new payload joins `//:stack_data`.
- **Configs**: update the linters, formatters, hooks, and CI under `lints/`, `.githooks/`, and
  `.github/workflows/`, so the better practice is enforced rather than requested.
- **Tests and docs**: add or improve the tests and documentation that prevent recurrence; a new function
  needs its `# @function` block, which `//tests:shell_inventory` and `//tests:doc_coverage` enforce.
- Record significant changes in the commit message and the pull request body: this repo keeps no
  first-party `CHANGELOG.md`. A fact worth keeping past the change goes to `/ez-learn` notes.

After each substantial change, verify it: run the tests, the lint, the typecheck, or the one scoped target.

Run the whole gate after the run: `bazelisk test //:test-fast`,
`bazelisk test //:lint --test_tag_filters=manual`, and `bazelisk run //:validate` when you touched a
payload it parses. `bazelisk run //:fix` is the formatter; a cached `N tests pass.` wants one
`--nocache_test_results` pass before the pull request.

A reflection that reaches for the agent's own files stops at the seed: a file under `~/.grok/`
carrying the `managed-by: evo-t1-coder-stack` marker is rewritten on the next boot, so edit the seed
under `templates/common/` and re-materialize it, never the copy that lives in a workspace.

### 5. Validate and Summarize

- Confirm the most important changes work and are non-breaking, with the command and its output.
- Provide a clear summary to the user:
  - What evidence from the repo and the sessions was reviewed
  - The key problems or opportunities identified
  - The changes made, with file paths and a brief rationale for each
  - Why each change improves the project going forward
  - Any recommended follow-up or residual risk
- Suggest committing the improvements if appropriate, on the branch this run cut.

## Principles

- **Repo-specific evidence**: prefer what this codebase and its sessions show over generic advice.
- **High leverage**: one strong convention, script, or structural fix beats many small notes.
- **Bold but planned**: large changes are encouraged when justified by evidence, not made carelessly.
- **Respect existing direction**: evolve the project's practices rather than imposing unrelated
  ones; align with the languages, tools, and goals already in use.
- **Leave the repo better**: every run should end with a measurably better codebase or developer
  experience for future work.

## Common Targets

- Source code structure and patterns under `scripts/` and `scripts/lib/`
- `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, and the architecture docs under `docs/`
- `scripts/*.sh`, the Bazel targets, and `.githooks/` developer tooling
- The `.tftpl` twins in `templates/workspace/` and `templates/devcontainer/`, and `templates/common/`
- The linter, formatter, and CI configuration under `lints/` and `.github/workflows/`
- The tests and reliability harness in `tests/bats/` and the coverage targets under `tests/`
- The stack payloads: `litellm/config.yaml`, `hermes/`, `homepage/`, `proxy/`, `searxng/`
- Project-specific conventions that steer future changes faster

## References

- `skills/reflect-and-evolve-repo/references/checklist.md` - checklist and heuristics tailored to
  codebase reflection. Read when planning or when the evidence is ambiguous.
- `skills/reflect-and-evolve/scripts/session_signals.py` - the session sweeper step 1 runs, shared
  with the agent-side skill: reference it, never copy or fork it.
- Consult language- or framework-specific skills or documentation when making technical changes.

Start every reflection by examining the current repository state rather than assuming it.
