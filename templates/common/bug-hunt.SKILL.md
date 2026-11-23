---
name: bug-hunt
description: "Drive a defect from a symptom to a proven fix: reproduce it before touching
  anything, localise the fault by reading with read-only explorers and a real bisect, raise
  competing hypotheses and test them with a fleet, then write the test that fails before the
  fix and passes after it, and ship nothing without both runs quoted. Use when asked to
  debug, reproduce, find the root cause, or fix a bug or an issue. Run as
  /bug-hunt <symptom-or-issue-number> [--bisect <ref>]."
when-to-use: "Use when something is broken and the cause is not already known: a failing
  test, a regression between a known-good and a known-bad state, or a reproducible report."
argument-hint: "<symptom-or-issue> [--bisect <good-ref>] [--no-fix]"
compatibility: "Requires git and the repository's own gate. Uses Grok Build subagents
  (spawn_subagent) for the mapping and hypothesis lanes; adds no dependency."
metadata:
  author: "operator"
  short-description: "Reproduce, localise, hypothesise, then prove with a failing test"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["bug-hunt"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Bug hunt

### The three rules, and who runs the blocks

Three rules, in this order: reproduce, localise, prove. A fix written before the symptom
reproduced is a guess with a commit message attached, and a fix with no test that failed
before it is unfalsifiable.

This is the parent's runbook. A depth-1 child may spawn `spawn_subagent` for read-only mappers
only, and only when it ships no file of its own; the writer lanes below stay yours to run, and a
mapper is a leaf by definition -- only the reviewer, security-auditor and tester definitions name
the tool.

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder
Agents chat agent); a command written inline in this body runs nothing on its own.

### Two consumers, one file

The CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the Coder Agents chat agent reads only
`~/.coder/skills/<name>/SKILL.md`. Keep the pair; never ship one home alone.

### Local references, models, and the call budget

Local references only: the reader reads the code, the tests, the logs, and the diff. A
research lane is for a fact outside this repository -- a library's documented default, a
published advisory.

Models are the local aliases only: `agent`, `agent-low`, `agent-medium`,
`agent-xhigh`, `agent-swarm`, `agent-explore`, `agent-review`. No cloud id. Budget 15 to 30
of your own calls plus the hypothesis wave.

## Step 0 -- read the report before you read the code (2 calls)

### Take the symptom in their words

Take the symptom from the person who saw it, in their words, with the exact command and the
exact output. For an issue, read the body and the comments before theorising:

    env -u GH_TOKEN -u GITHUB_TOKEN gh issue view <n> --comments

### Quote their acceptance text back

Quote their acceptance text back when you report done; that text, not your paraphrase, is
what the fix must satisfy. Note the environment and what changed since it last worked.

## Step 1 -- reproduce it, or stop (mandatory, 2 to 4 calls)

Run the reported command on the current tree and capture the failure verbatim:

    <the reported command> 2>&1 | tail -20

### No repro is a finding, not a fix

No repro is a finding, not a fix. Post what you ran and what you actually saw, and leave the
report open; never invent a plausible cause to close a symptom you never triggered.

### Ask for the one artifact

If only the reporter can reproduce it, ask for the one artifact that separates the two environments
-- the log, the input file, the version line -- before you spend calls guessing.

## Step 2 -- bisect by reading, and bisect for real when you can (up to 5 calls)

Narrow before you theorise. A regression between a good and a bad state gets a real bisect,
because that answer is cheap and definitive:

    git bisect start <bad> <good> && git bisect run <the repro command>

Without two known states, map instead:

- what changed since it worked
- who calls the failing path
- what the tests around it assert

Delegate that sweep to one read-only child per disjoint area on `agent-explore`, the lane for pure
mapping, and take back `path:line` evidence -- a child that quotes no line did not read the file.

## Step 3 -- hypotheses, one child each (1 call per hypothesis)

### One child per candidate cause

Write every candidate cause you can defend in one sentence and rank them by how cheaply each
is falsified. Then spawn one child per hypothesis, each with:

- the repro command
- the narrowed file set
- one question: does this cause survive the evidence, yes or no, and what did you run to decide?

The lane rule: at or above three independent children goes on `agent-swarm`, which spreads them
across every Spark box; below three, run them on `agent` in one turn.

### Re-run what the lane claims

A delegated result is a claim, not a fact: you re-run the command a lane says proves it before that
hypothesis becomes the diagnosis.

Kill a lane that has produced nothing by its budget instead of waiting for it, and beware the
two-error trap -- two independent faults behind one symptom is how a clean fix leaves the bug alive.

## Step 4 -- the test that fails before the fix (3 to 5 calls)

### Write the red test first

Write the smallest test that reproduces the symptom at the lowest level that still catches
it, run it, and keep the failing output. Then apply the fix and re-run the same test:

    bazelisk test //tests:bats_<stem>_test --nocache_test_results
    bazelisk test //:test-fast

### Put both runs in the pull request

Both runs go in the pull request, failing first and passing second.

`--nocache_test_results` matters for the first run: a cached green is a real pass over unchanged
inputs, and this is the one run where the inputs must change. A test you never saw fail is not
evidence.

## Step 5 -- ship the proof, or hand back the finding (2 calls)

Commit the test and the fix as the unit a reviewer reads as one step, and answer each
acceptance line from Step 0 with the command you ran and its result.

A fix spanning more than a few files is `/ez-micro-plan` territory, checked by `/skeptical-review`,
whose reviewer re-runs your `done:` command rather than believing it.

When you cannot fix it, report the localisation instead:

- the file
- the line
- the evidence
- what to try next
