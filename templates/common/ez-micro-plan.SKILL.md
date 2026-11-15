---
name: ez-micro-plan
description: "Divide one piece of multi-file work into micro tasks a fleet of subagents can
  each finish on its own, and drive the fan-out from a written plan: a repo-local plan
  document with lanes, dependency-ordered single-deliverable tasks, layered context files,
  and a dispatcher check that refuses a plan too narrow to fill the session's subagent
  slots. Use when asked to micro-plan work, plan a fan-out or a swarm run, split work for
  subagents, or maximize subagent concurrency. Run as /ez-micro-plan [goal-or-task-list]."
when-to-use: "Use when the change touches roughly five or more files, spans more than one
  kind of work, or needs two or more dispatch waves - and especially when the session runs
  on the unpinned swarm lane, where idle subagent slots are capacity thrown away. Skip it
  for a single file, a rename, a formatting pass, or one obvious edit."
argument-hint: "[goal] [--slots N] [--dry-run]"
compatibility: "Requires Grok Build subagents (spawn_subagent) and python3 for the plan
  check. Reads [subagents] max_concurrent from ~/.grok/config.toml."
metadata:
  author: "operator"
  short-description: "Micro-task plan and fan-out dispatcher for subagent fleets"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["ez-micro-plan"]` under `[skills]`
     in `~/.grok/config.toml`. -->

# Micro-task plan and fan-out

This is the parent's protocol. Children never plan: they receive one micro task, do it,
and report. The plan exists so a child can start with everything it needs and nothing it
does not, and so the parent can hand a ready task to any free slot without re-deriving
anything.

Four rules carry the design:

1. One task is one deliverable one reviewer can check alone, in about 15 tool calls.
2. Every fact a child needs is either in a context file it is told to read or in its
   prompt. Never both, and never a file it was not told about.
3. No slot stays empty while a ready task exists. Concurrency is the point.
4. The plan is a work artifact, not the record: results live in the tree, durable facts
   go to the notes file, and the plan directory stays out of git.

The plan document is separate from Grok Build's own `/plan`: that one is
`~/.grok/sessions/<cwd>/<session-id>/plan.md`, is the Plan Mode preview, and disappears
with the session. This plan is repo-local at `.grok/plans/<slug>/plan.md`, is written in
Act mode, and is what both the parent and every child read from.

Budget: 15 to 30 of your own tool calls to plan, dispatch, and merge a 20-task change. A
plan that needs 60 calls of authoring was the wrong plan.

## Step 0 -- is this worth a plan (2 calls)

Write the plan when the change touches about five or more files, spans more than one kind
of work (source plus tests plus docs, say), or needs two or more waves. Below that, do
the work yourself or spawn one child: authoring this plan costs more than it saves.

Read your real slot count once, here, and never guess it again:

    grep -A4 '^\[subagents\]' ~/.grok/config.toml

`max_concurrent` is the ceiling for one session and `sampling_limit` follows it when
unset. Put that number in the plan as `slots:`. If it is above 5 and the session's
subagents ride a pinned Spark lane, the fan-out queues behind that one box's streams: the
fix is the unpinned lane, not a smaller plan. `docs/litellm-routing.md` explains the
trade and `--var grok_subagents_lane=agent-swarm` sets it. That knob moves the writer
types only: `grok_explore_lane`, `grok_plan_lane` and `grok_review_lane` route the
mappers, the planner and the skeptics, so a wave of readers or a review pass can be put
on its own alias without touching the writers. `[subagents.models]` is the
seam that routes a subagent type to a lane, and the guide documents it applying whatever
the parent's own model is, so the lane is a config decision: the spawn call's `model`
argument names one child's model, and the guide leaves how it ranks against that pin
open, so change the pin when you want the lane itself to move.

## Step 1 -- map the change surface before you split anything (up to 5 calls)

You cannot scope tasks from a guess. Enumerate what must change and what might:

    git ls-files | grep -Ei '<pattern>' | head -50

Use the repo's own map verbs where it has them (here:
`bazelisk run //scripts:bazel-map -- scope --untracked`, `-- twins <path>`,
`-- files <target>`). When the surface is bigger than five calls, spawn one `explore`
child per disjoint area and have it answer: files that must change, files that must not,
the pattern to copy, and the command that proves it. Its answer becomes a lane brief in
Step 3, not a blob in your context.

## Step 2 -- write the plan (parent only)

Create `.grok/plans/<slug>/plan.md` with `ctx/` and `results/` beside it. The layout is
fixed because the check parses it:

    .grok/plans/<slug>/
      plan.md              the parent's document; children never read it
      ctx/L0.md            the contract: every child reads this one file
      ctx/L1-<lane>.md     one brief per lane; that lane's children read it
      ctx/L2-T<nn>.md      a task brief, only when L0 plus L1 cannot start the task
      results/T<nn>.md     written by the child, read by the parent

Skeleton (keep the headings; the check keys on them):

    # Micro-plan: <slug>
    <!-- ez-micro-plan v1 -->

    ## Goal
    <one sentence on the change and the state it leaves the tree in>
    - A1: <acceptance criterion> -- check: `<command>`
    - A2: <acceptance criterion> -- check: `<command>`

    ## Dispatch
    - lane: agent-swarm
    - slots: 8
    - cap source: [subagents] max_concurrent
    - review: T09
    - parent keeps: BUILD.bazel, docs/index.ts, package-lock.json
    - between waves: run the lane's own test target; keep the tree buildable

    ## Lanes
    | lane | owns | role | brief | notes |
    |---|---|---|---|---|
    | src-core | scripts/lib/search.sh | general-purpose | ctx/L1-src-core.md | |
    | tests | tests/bats/search.bats | general-purpose | ctx/L1-tests.md | |
    | map | - | explore | ctx/L1-map.md | context only |

    ## Tasks
    ### T01 -- add the lane resolver to scripts/lib/search.sh
    - lane: src-core
    - role: general-purpose
    - owns: scripts/lib/search.sh
    - reads: L0, L1-src-core
    - needs: none
    - calls: 12
    - done: `bazelisk test //tests:bats_search_test`
    - report: results/T01.md

    ## Ledger
    | task | state | wave | slot | result | verified |
    |---|---|---|---|---|---|
    | T01 | ready | - | - | - | no |

    ## Not doing
    - <what a reviewer might expect and will not find>

Every task block carries all nine lines, exactly those keys. `owns` is a comma list or
`-` for a read-only task. `reads` names context files (`L0`, `L1-<lane>`, `L2-T<nn>`) and
nothing else; the repo files a task edits are in `owns`, and any file it reads to copy a
pattern is named in `reads` with a line range (`src/lib/spark.sh:40-75`). `needs` is
`none` or a comma list of task ids that must be done first. `done` is one command or one
inspectable artifact. `report` is that task's own result path. In `## Dispatch`, `review:`
is optional and names the skeptic that reviews the rest of the plan: it must own nothing
and need every task that owns a file, which the check enforces once you write the key and
warns about when you leave it out.

## Step 3 -- layer the context, and keep it thin

Each layer answers one question, has a size cap, and is written by exactly one party.

| layer | answers | written by | read by | cap |
|---|---|---|---|---|
| prompt | this task, now | parent | one child | 40 lines |
| `ctx/L0.md` | what is being built, and the rules | parent | every child | 80 lines |
| `ctx/L1-<lane>.md` | this lane's file map and the pattern to copy | parent, grown from child reports | that lane's children | 40 lines |
| `ctx/L2-T<nn>.md` | the one fact only this task needs | parent, just in time | one child | 20 lines |
| `results/T<nn>.md` | what happened, what was found | child | parent | 12 lines |

L0 is the shared cache and it is frozen before wave 1: goal in three lines, the vocabulary
table, every seam a task invents that another task consumes (a signature, a config key, a
flag name, a token, a path) written verbatim, the paths a child must not touch, and the
commands that prove the goal. Anything two children both need belongs here; anything one
child needs belongs in L2 or its prompt. A change to L0 after dispatch is a re-dispatch
event, not an edit: children already running read the old copy.

Write L1 per lane from the Step 1 answers, and grow it between waves. When two children
independently rediscover the same fact, that fact goes into L1 before the next wave is
dispatched, so no third child pays for it again. That promotion is the whole caching
mechanism: children never write shared files, and the parent is the only writer.

L2 exists so L0 stays 80 lines. If you find L0 growing past the cap, move the detail down.

The prompt carries seven parts and nothing else: the role line, the task id plus its one
line summary, `owns`, the `reads` paths, the pinned seams the task touches (copied from
L0, not re-summarized), `done`, and the `report` path. Add the two standing instructions:
stop and report instead of touching a file outside `owns`, and do not read `plan.md`, the
Ledger, or another task's result.

Child report, fixed fields, so you can read six lines instead of a transcript:

    task: T07
    state: done | blocked | failed
    wrote: <paths actually written>
    checked: `<command>` -> pass | fail (<one line of tail>)
    found: <one-line fact worth promoting, or none>
    needs: <file outside owns, or contract change, or none>
    next: <the one thing the parent should do>

## Step 4 -- size every task, then prove the plan dispatches

A task is micro when all of these hold. Split it when any of them fail:

- one deliverable, and one report line for it;
- three or fewer files in `owns`, from one directory family;
- 15 tool calls or fewer, counting the reads a child needs to get oriented;
- it starts from at most three context files;
- one `done` command a reviewer can run;
- no other ready task shares a path with it;
- it never waits on a live task, only on finished ones.

Two structural habits do most of the work. A test file is its own task next to its
source task, never folded into it: that is one free slot and one clean review. And a fact
several children would each go and look up gets a `map` lane of `explore` tasks that land
in wave 0 and write lane briefs, so the writers start warm.

Hotspots stay with you: registries, barrel and index re-exports, BUILD files, lockfiles,
shared fixtures and seeds, schemas and migrations, i18n catalogs, docs indexes. List them
under `parent keeps:` and schedule them yourself between waves.

Run the check before you dispatch, and fix what it names:

    python3 ~/.agents/skills/ez-micro-plan/scripts/plan_check.py \
      .grok/plans/<slug>/plan.md --ready

It errors on a task missing a key, two ready tasks sharing a path, a dependency cycle or
unknown id, a lane or context file that does not exist, a task with no `done` check, a
`calls` budget over 25, and a first wave narrower than `slots` (that last one is the
point: if wave 1 cannot fill the fleet, the split is too coarse). It prints the ready set
on `--ready`, which is the wave to spawn.

## Step 5 -- dispatch: keep every slot busy

1. Take the ready set from `--ready`, capped at `slots`.
2. Spawn the whole wave in one turn: several `spawn_subagent` calls in a single message,
   each with `background = true`. One wave per turn, or the fleet idles while you type.
3. As each child lands, in that same turn: read its six report lines, run its `done`
   check yourself, write its Ledger row, promote any `found:` fact into the lane brief,
   and dispatch the next ready task into the slot it left.
4. Do your own work (merge, hotspot edits, docs) only while every slot is full.
5. Between waves, run the affected test targets and keep the tree buildable; a wave that
   leaves the tree broken costs every later child its `done` check.
6. Re-run the check when the Ledger changes; states move, and a task unblocked is a task
   to dispatch.
7. The `review:` task is dispatched last, once every producer has landed, and it re-runs
   each producer's own `done` command itself instead of trusting `results/T<nn>.md`.

A wave is not a phase: it is whatever fits in the slots. Prefer many small waves over two
big ones. A child that fails twice with the same error is a layer problem, not a retry
candidate: take that slice yourself. A child that reports `needs:` a file outside `owns`
is a reslice, not a rule violation.

When the plan outgrows a manual loop -- more than about 40 tasks -- the same file drives
the `workflow` tool with an `agent_budget`; the task blocks are the round list. That is
still parent-owned orchestration, and children still cannot spawn children.

## Step 6 -- close it out

- Every `A<n>` acceptance line has a command that passed, run by you, not quoted from a
  child.
- The Ledger holds no `ready` or `running` row, and every `verified` row was checked by
  you.
- The `review:` task ran last, after every producer, and re-ran each producer's own
  `done` command itself rather than trusting what `results/T<nn>.md` claimed.
- Anything the next session should know goes to the notes file
  (`~/.grok/notes/<host>/<owner>/<repo>/notes.md`, the `ez-learn` skill), not into the
  plan.
- Delete `.grok/plans/<slug>/results/` when the change is committed. The plan directory is
  git-ignored by the stack; commit a plan only when the operator asked for it in the
  review.
