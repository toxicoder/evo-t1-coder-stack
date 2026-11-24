---
name: feature-implementation
description: "Take one feature request from Plan Mode to a verified, PR-ready change with a
  fleet of subagents: map the surface with read-only explorers, hand the split to
  /ez-micro-plan, fan the writers out over the Spark boxes, then close with a panel wave:
  testers and skeptics dispatched in one turn, each re-running the producers' own done
  commands before anything merges.
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

## What stays with the parent

The parent's runbook: you decompose, dispatch, merge, and verify, and the children do the
bulk reads and the edits. Decomposition, dispatch, the merge, and every writer stay with
you, so no phase below happens unless you cause it.

A depth-1 child may spawn `spawn_subagent` for read-only mappers only, and only when it ships no file of its own.

Planning is not restated here: the lanes, task blocks, context files, and the dispatcher
check belong to `/ez-micro-plan`.

## How to run the blocks

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder
Agents chat agent); a command written inline in this body runs nothing on its own.

## Where this file lives

Two consumers, one file: the CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the Coder Agents chat agent reads only
`~/.coder/skills/<name>/SKILL.md`. Keep the pair; never ship one home alone.

## Models, reading, and the call budget

Models are local aliases only -- `agent`, `agent-low`, `agent-medium`, `agent-xhigh`,
`agent-swarm`, `agent-explore`, `agent-review` -- and no cloud model id belongs in this stack.

Read the code, the tests, and the diff; a research lane is for a fact outside this repository.

Budget: 20 to 35 of your own calls plus the waves.

## Step 0 -- decide whether the fleet is worth it (2 calls)

A single file or one obvious edit: do it yourself and stop here.

Otherwise read your real slot count once, and set up the branch, since it exists before the first
edit and children
never cut one (trunk-based, one logical change, `docs/branching.md`):

    grep -A4 '^\[subagents\]' ~/.grok/config.toml
    git rev-parse --abbrev-ref HEAD && git status --short

## Step 1 -- map the surface with read-only explorers (up to 5 of your own calls)

### One mapper per disjoint area

Spawn one `explore` child per disjoint area for a digest -- files that must change, files
that must not, the pattern to copy, and the command that proves it. Pure mapping is
`agent-explore`, the low-effort lane; a map wave is the cheapest thing you can put on it.

### Use the repo's own map verbs

Find the current repository's own map verbs before grepping -- the target, script, or index
that answers who reads a file and what must move with it -- and quote the command you found
and the line it printed. Where the repo has none, index the clone and read that:

    python3 ~/.agents/skills/ez-code-index/scripts/code_index.py --repo .

## Step 2 -- plan the split with /ez-micro-plan (parent only, on `agent`, 4 to 6 calls)

Write the repo-local plan with `/ez-micro-plan`, whose `plan_check.py --ready` refuses a
plan that cannot fill your slots; the plan and its context files stay yours alone.

### Pin every seam first

Pin every seam before a child consumes it -- the type, signature, interface, config key,
flag, path.

Where B consumes what A creates and the seam is unpinned, that is two waves, not one.

### Hotspots stay with the parent

Hotspots stay parent-owned:

- BUILD files
- registries
- lockfiles
- fixtures
- migrations
- docs

## Step 3 -- fan the implementers out (1 call per child, the whole wave in one turn)

### The lane rule

The lane rule: at or above three independent children goes on `agent-swarm`, the unpinned
lane whose children spread over all the Spark boxes instead of queueing behind one box's
streams; below three, keep them on `agent` and still launch the wave in one turn. One writer
per file, every path in exactly one `owns` set.

### The seven parts of a child prompt

Each prompt carries the seven parts and nothing else:

- the role line
- the task id with its one-line summary
- `owns`
- the `reads` paths
- the pinned seams copied verbatim
- the `done` command
- the `report` path
- stop and report on any file outside `owns`

## Step 4 -- the tester and the skeptic panel are mandatory, not a courtesy (1 call per member, the whole wave in one turn)

### Never merge on the producer's report

A delegated result is a claim, not a fact: never merge on the producer's own report, and
never let the producer review its own work. Send the testers and the skeptics out together
in one turn, so the phase costs the slowest check rather than the sum of them.

The reviewers ride `agent-review`, the lane for the independent pass;
a tester runs `agent-swarm` when
several independent checks are pending and `agent` otherwise.

### What each member gets and re-runs

Each member owns no file, gets
the diff, the tests, and the acceptance list rather than the author's summary, and re-runs the
producer's own `done:` command rather than trusting its report. The default panel is the three
angles `/skeptical-review` runs -- requirements, proof, adversary -- and a single-file fix
saves the streams by putting one skeptic over all three. Each skeptic scopes its own read-only
mappers, up to 3, instead of returning to you for each read.

### How wide the panel may go

Decide that width here, against the whole tree: sum the in-flight `1 + spawns` over every task
and keep that total at or below the fleet's stream count (`fleet:` in the plan, 15 by default).
That total is a separate number from `slots`, which caps your own children in flight. The panel
is where nesting is cheapest -- the writers have all landed by review time, so those streams
are free. Every finding cites `path:line`; an uncited finding is an opinion and does not block
a merge.

### Run the gate in your own shell

Then run the gate in your own shell, so the green you quote is yours. Discover the current
repository's own gate first -- its `AGENTS.md`, `README`, CI workflow, Makefile, or build file
names it -- and run the fast test command and the lint command it declares, pasting both
exactly as that repo states them. A target carried over from another repository is not this
repo's gate:

    <the repo's own fast test command>
    <the repo's own lint command>

## Step 5 -- merge, hotspots, and the derived artifacts (parent only, 3 to 5 calls)

### Integrate and regenerate

You integrate and resolve; children never merge, rebase, or touch a branch. Apply the
hotspot edits you held back, then regenerate the derived artifacts once, after the merge --
codegen, lockfiles, snapshots, and migrations are parent-side steps, never a child task.

### Re-run the gate before the pull request

Re-run the repo's fast gate after the merge, then one uncached pass over its full gate -- the
wider command the repo names beside the fast one, with its CI job as the authority on which
that is -- before the pull request; a tree left broken costs every later child its `done`
check, so fix it before dispatching again.

## Step 6 -- close it out (2 to 4 calls)

Stage by path, commit each unit as it lands, and push once when the change is ready for
review. Every acceptance criterion is answered with a command you ran and its result, not a
line quoted from a child. Durable facts go to `~/.grok/notes/<host>/<owner>/<repo>/notes.md`
(the `ez-learn` skill), not into the plan. No secret, token, or `.env` value is staged,
committed, or pasted into the pull request.
