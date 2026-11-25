---
name: documenter
description: "Document a change that already exists rather than a wish to document things:
  read the diff, fan read-only mappers over every documentation surface to find the text the
  change made wrong, write one file per writer in that file's own voice, then put the result
  past an independent skeptic that runs every command the new prose names. Use when asked to
  document a commit, a branch, a pull request, or a new operator CLI. Run as
  /documenter <commit-ish|path|PR-number> [--surface <name>]."
when-to-use: "Use once the change exists -- a commit, a branch, a pull request, or a gate
  saying the docs no longer match the code. Not for prose from nothing: with no diff there is
  no fact to check a claim against."
argument-hint: "<commit-ish|path|PR-number> [--surface docs|readme|rulebook|comments]"
compatibility: "Requires git and the repository's own gate. Uses Grok Build subagents
  (spawn_subagent) for the mapping, writing, and review lanes; adds no dependency."
metadata:
  author: "operator"
  short-description: "Document a landed change, and run what you tell people to run"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["documenter"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Documenter

The unit of work is a change, never a topic: the diff is the source and a document is a claim
to check against it.

Scope the change, map the docs against it, write, then let someone who
wrote none of it run every command the prose now names.

This is the parent's runbook -- A depth-1 child may spawn `spawn_subagent`
for read-only mappers only, and only when it ships no file of its own,
so the writing fan-out is still yours to run.

Budget 12 to 25 of your own calls plus the lanes, and run every block with `run_terminal_command`
(Grok Build CLI) or `execute` (Coder
Agents chat agent): a command written inline in this body runs nothing on its own.

Local references only: the diff, the code, the tests, the docs. Models are the local aliases
only -- `agent`, `agent-explore`, `agent-swarm`, `agent-review` -- and never a cloud id.

## Step 1 -- Scope: read the change, write nothing (parent's own calls, 2 to 4)

Take the change itself, whichever form the argument named -- no lane, your own reading:

    git show <commit-ish>                              # a commit
    git diff main...HEAD                               # a branch or a path set
    env -u GH_TOKEN -u GITHUB_TOKEN gh pr diff <n>     # a pull request

### The ledger the docs must answer

Then list, from that diff alone, every user-visible thing it adds, renames, removes, or renumbers:

- commands and flags
- Bazel labels
- paths, ports, env keys, defaults

That ledger is what the docs must answer.

Given only a wish to document something, stop and ask which change.

## Step 2 -- Read: one mapper per documentation surface (1 call per surface, one turn)

Fan out read-only mappers on `agent-explore`, the lane for pure mapping, one per surface; each
returns numbered claims carrying `path:line` and the document that is now wrong, and edits nothing:

- the operator docs, wherever this repo keeps them -- `git ls-files | grep -Ei
  '^(docs|documentation|guide|manual|site)/' | head` names them, with whatever nav or sidebar
  file a new page has to join
- the README command list, the surface a reader types from first
- the agent rulebook this repo keeps, if it keeps one: in `evo-t1-coder-stack` that is
  `templates/common/GROK_BUILD_AGENTS.md`, which the boot writes into `~/.grok/AGENTS.md`
  while it carries its marker
- the inline comments and doc blocks the repo's own doc-coverage step checks -- name that step
  from `bazelisk query 'kind(test, //...:all)'`, the `scripts` map in `package.json`, `make -n`,
  or the CI job list; `evo-t1-coder-stack` gates the `# @function` blocks under `scripts/`

### The twin and the owner

A mapper that quotes no line did not read the file; send it back.

Ask each one for the twin and
the owner too: which other copy of the file has to move with it (a template or fixture twin, a
generated mirror, a vendored second path), and which build target's `srcs` can see a new file at all.
Discover both rather than assuming a helper exists -- `bazelisk query 'rdeps(//..., <path>)'` plus the
filegroups in the nearest `BUILD.bazel` answer it in a Bazel repo; the `files` list in `package.json`,
the `Makefile`, and the CI workflow's file lists answer it elsewhere.

## Step 3 -- Write: one writer per documentation file, disjoint paths (1 call per file)

One writer on `agent-swarm` per documentation file, which spreads them over every Spark box;
below three writers keep them on `agent` and launch them in one turn anyway. Every path sits in
exactly one writer's set -- overlapping globs are a collision, not a race.

### Hotspots and the writer brief

The hotspot stays with the parent:

- `README.md`
- `templates/common/GROK_BUILD_AGENTS.md`
- any file two writers both name

A writer that wants a path outside its set is resliced, not told to share it.

Each writer gets:

- the diff
- only the claims naming its file
- its owned path
- the voice to match

An operator doc says what the thing is, what it costs, and which command proves it, and
it is not a changelog. Correct a stale fact, add a new one, leave a limitation nobody removed.

## Step 4 -- Check: the skeptic runs the documentation (2 to 5 calls)

Hand the changed files -- the files, not your summary -- to one child on `agent-review` that
wrote none of it, never the producer, the rule
`templates/common/GROK_BUILD_AGENTS.md` carries in its Delegation section.

Its one job is to execute every command a doc tells a reader to run and report each kept
or broken with its `path:line`.

Then you fix what broke and it re-runs it:

    <the exact line the doc gives the reader> 2>&1 | tail -20

## Hard rules

- Never document a command you did not run: a stale invocation in an operator doc is a support
  ticket with a filename on it.
- Never invent a flag, a path, or a target name -- derive it from the repository in front of you:
  `ls`, `find`, `bazelisk query 'kind(rule, //...:all)'` where `BUILD.bazel` files exist,
  `jq -r '.scripts | keys[]' package.json`, `make -n`, or the step names in `.github/workflows`.
- Every new fact traces to the diff or to a file a mapper cited with `path:line`; what the
  author meant is not evidence.
- Prose and commands are ASCII, punctuation included
  (`templates/common/GROK_BUILD_AGENTS.md`, "Character Hygiene"). Never read `.env` or `.env.*`, and never
  print a secret (`templates/common/GROK_BUILD_AGENTS.md`, "Execution"): name the CLI that prints it.

## Done means

- [ ] `git diff --stat main...HEAD` names only the documentation files this run claimed.
- [ ] Every command line a changed doc names was executed, with its output quoted in the pull
      request beside the file that tells the reader to run it.
- [ ] The repository's own doc-coverage step passes -- whichever step in `BUILD.bazel`,
      `package.json` scripts, the `Makefile`, or the CI job list checks the doc blocks over its
      sources (in `evo-t1-coder-stack`, the `# @function` gate over `scripts/**/*.sh`); name the
      command you discovered and paste its output.
- [ ] The docs build, link check, and nav check pass when the change touched documentation pages --
      the step the CI workflow names for docs, run after whatever installs that site's
      dependencies.
- [ ] The skeptic on `agent-review` returned no broken claim, carrying the output it got for
      each command it ran.
