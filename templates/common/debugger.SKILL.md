---
name: debugger
description: "Force evidence to exist before a fix is written: reproduce the failure with the
  exact command and its real output quoted, localise with read-only mappers who cite lines and an
  honest bisect, raise at least three competing causes and kill each with one named observation,
  then let one writer make the minimal change and a skeptic re-run the red and the green. Use
  when someone is about to patch without a repro, when a fix already looks obvious, or when asked
  to debug, diagnose, or root-cause. Run as /debugger <symptom|failing-test|issue-number>."
when-to-use: "Use when a fix is tempting before anything has been reproduced: the guess-and-patch
  pass, the retry added to make a flake quiet, the broad catch that makes red disappear. For the
  full investigation of a defect you intend to fix properly, use /bug-hunt; this skill is the gate."
argument-hint: "<symptom|failing-test|issue-number> [--no-fix]"
compatibility: "Requires git and the repository's own gate. Uses Grok Build subagents
  (spawn_subagent) for the mapping, hypothesis, writing, and review lanes; adds no dependency."
metadata:
  author: "operator"
  short-description: "No fix before evidence: reproduce, localise, falsify, then prove"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["debugger"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Debugger

## The one hard rule

The one hard rule: no fix is written before evidence exists. `/bug-hunt` is the runbook from
symptom to shipped fix; this is the gate that stops a run where the fix comes first -- the patch
typed before anything failed, the flake answered with a retry, the broad catch that hides the red.

A depth-1 child may spawn `spawn_subagent` for read-only mappers only, and only when it
ships no file of its own, so the writer fan-out here is still yours to run.

## Two consumers, one file

The CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the chat agent reads only the other home.

## Models and the five hard rules

Models are the local aliases this run uses -- `agent`, `agent-explore`, `agent-swarm`,
`agent-review` -- and no cloud id.

Five hard rules, none bendable:

- no fix without a reproduction you ran and quoted
- no fix without a test that was red first
- when the report came from an issue, quote the reporter's own acceptance wording back
- a change that widens a catch, adds a sleep or a retry, or loosens an assertion is a non-fix and
  must be named as one
- pure ASCII throughout

## Phase 1 -- reproduce, or the run stops (mandatory, on `agent-explore`, 2 to 4 calls)

### Quote the real command and its real output

Run the failing thing on the current tree and quote the command and the output it really produced
-- not a paraphrase, not "it fails sometimes":

    <the reported command> 2>&1 | tail -30

### Take the symptom in their words

Take the symptom from whoever saw it, in their words; for an issue read body and comments first:
`env -u GH_TOKEN -u GITHUB_TOKEN gh issue view <n> --comments`.

Then refuse to go on: "Cannot reproduce" is a finding to report with what you ran, never a
conclusion that clears the code.

## Phase 2 -- localise with mappers, and bisect for real when you can (up to 5 calls)

### Narrow with mappers first

Narrow before you theorise. Spawn read-only children on `agent-explore`, one per disjoint
question:

- who calls the failing path
- what changed since it last worked
- what the tests around it assert

Every claim comes back with its `path:line` -- a mapper that quotes no line did not read
the file.

### Bisect for real when you can

When a known-good and a known-bad ref both exist, bisect rather than guess, and run it honestly:
the script decides, not your patience.

    git bisect start <bad> <good> && git bisect run <the repro script>

The run script exits:

- 0 for good
- 1 for bad
- 125 when the commit cannot be tested at all (no build, no harness, a flake that answered neither
  way) -- 125 makes git skip it rather than record a verdict you never earned

Keep `git bisect log`, then `git bisect reset`; never bisect dirty.

## Phase 3 -- hypothesise three causes, each with what would kill it (probes on `agent-swarm`)

Write down at least three competing causes, one sentence each, and for each the single observation
that would rule it out -- one of:

- the input that still passes
- the counter the log says never moved
- the call that demonstrably did not happen

A cause with no ruling-out observation is a belief: park it.

### Fan the probes out on the fan-out lane

Then fan the tests out as read-only probes, one child per cause, all in one turn on
`agent-swarm`, the fan-out lane. Each gets:

- the repro command
- the narrowed file set
- its cause and its one observation

Each answers yes or no with what it ran.

A probe's result is a claim, not a fact: you re-run whatever proves the cause before that cause
becomes the diagnosis.

## Phase 4 -- fix, once one cause survived (1 to 4 calls, the writer on `agent-swarm`)

Only a hypothesis that survived its observation earns a fix. One writer on `agent-swarm`, carrying:

- the repro
- the surviving cause with its evidence
- an `owns` set narrowed to the files the fix needs

The diff is that cause's size: no drive-by cleanup, no rename, no reformat, no new
dependency while a bug is open -- a cleanup you want goes in a later commit, visibly separate.

## Phase 5 -- prove it, then let a skeptic run both halves (3 to 6 calls)

### Write the red test first

Write the smallest test that fails for this symptom at the lowest level that still catches it, and
run it against the unfixed tree before the fix lands:

    bazelisk test //tests:bats_<stem>_test --nocache_test_results   # red: quote this run
    bazelisk test //tests:bats_<stem>_test --nocache_test_results   # green: same test, after
    bazelisk test //:test-fast

The flag is not decoration: a cached green is a real pass over unchanged inputs and this is the run
where they change. The red test ships in the same commit as the fix.

### Hand both runs to a skeptic

Then hand both commands and the base ref to an independent skeptic on `agent-review` -- not the
writer, not you -- to run both.

## Done means

Each line is a command that ran and the output it printed, quoted, not an adjective claimed:

    # repro: the exact Phase 1 command with the failure quoted under it
    # red:   the new test on the unfixed tree, --nocache_test_results, failing
    # green: the same test after the fix, passing
    bazelisk test //:test-fast   # passes, in your own shell
    # skeptic on agent-review: re-ran both runs; returned no broken claim

The reporter's acceptance wording is quoted back and answered line by line when the report came
from an issue. Non-fix, no repro, or a test nobody saw red: say which, and hand back the finding.
