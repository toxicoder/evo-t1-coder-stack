---
name: feature-implementation
description: "Take one feature request from Plan Mode to a verified, PR-ready change with a
  fleet of subagents: map the surface with read-only explorers, hand the split to
  /ez-micro-plan, fan the writers out over the Spark boxes, then close with an independent
  tester and reviewer who re-run the producers' own done commands before anything merges.
  Use when asked to implement a feature or turn an issue into a pull request. Run as
  /feature-implementation <request-or-issue-number> [--slots N]."
when-to-use: "Use when the request changes the tree rather than answering a question:
  several files, more than one kind of work, a gate that must stay green. Skip a single file."
argument-hint: "<request-or-issue> [--slots N] [--dry-run]"
compatibility: "Requires Grok Build subagents (spawn_subagent), git, and the ez-micro-plan
  skill, which owns the plan format and the dispatcher check."
metadata:
  author: "operator"
  short-description: "Map, plan, fan out, then independently review one feature"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["feature-implementation"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Feature implementation

The parent's runbook: you decompose, dispatch, merge, and verify, and the children do the
bulk reads and the edits. A child has no `spawn_subagent` and cannot spawn anything, so no
phase below happens unless you cause it. Planning is not restated here: the lanes, task
blocks, context files, and the dispatcher check belong to `/ez-micro-plan`.

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder
Agents chat agent); a command written inline in this body runs nothing on its own.

Two consumers, one file: the CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the Coder Agents chat agent reads only
`~/.coder/skills/<name>/SKILL.md`. Keep the pair; never ship one home alone.

Models are local aliases only -- `agent`, `agent-low`, `agent-medium`, `agent-xhigh`,
`agent-swarm`, `agent-explore`, `agent-review` -- and no cloud model id belongs in this
stack. Read the code, the tests, and the diff; a research lane is for a fact outside this
repository. Budget: 20 to 35 of your own calls plus the waves.

## Step 0 -- decide whether the fleet is worth it (2 calls)

A single file or one obvious edit: do it yourself and stop here. Otherwise read your real
slot count once, and set up the branch, since it exists before the first edit and children
never cut one (trunk-based, one logical change, `docs/branching.md`):

    grep -A4 '^\[subagents\]' ~/.grok/config.toml
    git rev-parse --abbrev-ref HEAD && git status --short

## Step 1 -- map the surface with read-only explorers (up to 5 of your own calls)

Spawn one `explore` child per disjoint area for a digest -- files that must change, files
that must not, the pattern to copy, and the command that proves it. Pure mapping is
`agent-explore`, the low-effort lane; a map wave is the cheapest thing you can put on it.
Use the repo's own map verbs (`-- twins <path>`, `-- owners <path>`) before grepping:

    bazelisk run //scripts:bazel-map -- scope --untracked

## Step 2 -- plan the split with /ez-micro-plan (parent only, on `agent`, 4 to 6 calls)

Write the repo-local plan with `/ez-micro-plan`, whose `plan_check.py --ready` refuses a
plan that cannot fill your slots; the plan and its context files stay yours alone. Pin every
seam before a child consumes it -- the type, signature, interface, config key, flag, path.
Where B consumes what A creates and the seam is unpinned, that is two waves, not one.
Hotspots stay parent-owned: BUILD files, registries, lockfiles, fixtures, migrations, docs.

## Step 3 -- fan the implementers out (1 call per child, the whole wave in one turn)

The lane rule: at or above three independent children goes on `agent-swarm`, the unpinned
lane whose children spread over all the Spark boxes instead of queueing behind one box's
streams; below three, keep them on `agent` and still launch the wave in one turn. One writer
per file, every path in exactly one `owns` set. Each prompt carries the seven parts and
nothing else: the role line, the task id with its one-line summary, `owns`, the `reads`
paths, the pinned seams copied verbatim, the `done` command, the `report` path, and stop and
report on any file outside `owns`.

## Step 4 -- the tester and the reviewer are mandatory, not a courtesy (3 to 6 calls)

A delegated result is a claim, not a fact: never merge on the producer's own report, and
never let the producer review its own work. Spawn an independent tester and reviewer who did
not write the diff -- the reviewer rides `agent-review`, the tester `agent-swarm` when
several independent checks are pending and `agent` otherwise -- each handed the diff, the
tests, and the acceptance list rather than the author's summary, and each re-runs the
producer's own `done:` command rather than trusting its report. Every finding cites
`path:line`; an uncited finding is an opinion and does not block a merge. Then run the gate
in your own shell, so the green you quote is yours:

    bazelisk test //:test-fast
    bazelisk test //:lint --test_tag_filters=manual

## Step 5 -- merge, hotspots, and the derived artifacts (parent only, 3 to 5 calls)

You integrate and resolve; children never merge, rebase, or touch a branch. Apply the
hotspot edits you held back, then regenerate the derived artifacts once, after the merge --
codegen, lockfiles, snapshots, and migrations are parent-side steps, never a child task.
Re-run `//:test-fast` after the merge, then one uncached pass over the full gate
(`bazelisk test //:test-all`) before the pull request; a tree left broken costs every later
child its `done` check, so fix it before dispatching again.

## Step 6 -- close it out (2 to 4 calls)

Stage by path, commit each unit as it lands, and push once when the change is ready for
review. Every acceptance criterion is answered with a command you ran and its result, not a
line quoted from a child. Durable facts go to `~/.grok/notes/<host>/<owner>/<repo>/notes.md`
(the `ez-learn` skill), not into the plan. No secret, token, or `.env` value is staged,
committed, or pasted into the pull request.
