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

## The three rules, and who runs the blocks

Three rules, in this order: reproduce, localise, prove. A fix written before the symptom
reproduced is a guess with a commit message attached, and a fix with no test that failed
before it is unfalsifiable.

This is the parent's runbook. A depth-1 child may spawn `spawn_subagent` for read-only mappers
only, and only when it ships no file of its own; the writer lanes below stay yours to run, and a
mapper is a leaf by definition -- only the reviewer, security-auditor and tester definitions name
the tool.

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder
Agents chat agent); a command written inline in this body runs nothing on its own.

## Two consumers, one file

The CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the Coder Agents chat agent reads only
`~/.coder/skills/<name>/SKILL.md`. Keep the pair; never ship one home alone.

## Local references, models, and the call budget

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

Read the issue before you plan, not after you have a fix to defend: the body and the comments
ARE the requirements -- the reproduction, the acceptance wording, the definition of fixed.
Quote their acceptance text back when you report done; that text, not your paraphrase, is
what the fix must satisfy. Note the environment and what changed since it last worked.

## Step 0a -- search the tracker before you fix an unnumbered defect (2 calls)

### Search open, then closed

A defect nobody numbered is not yet a licence to write a fix. Search the tracker twice, open
first and closed second, so a report `main` already fixed and one somebody else filed last
month both surface. Use the symptom's own words -- the error string, the command, the file:

    env -u GH_TOKEN -u GITHUB_TOKEN gh issue list --state open --search '<keywords> in:title,body'
    env -u GH_TOKEN -u GITHUB_TOKEN gh issue list --state closed --search '<keywords> in:title,body'

### Three outcomes, not one

- `main` already fixed it: post a comment naming the commit that fixed it, and stop there.
- a duplicate of an open report: link the original and work there; do not file a second one.
- genuinely new: file it, then read it as your Step 0 report.

### Say so before a long fix

Anything past an obvious edit, post what you intend to change before you change it, so a human
can redirect you early and nobody else starts the same work. Body from a file, never argv:

    env -u GH_TOKEN -u GITHUB_TOKEN gh issue comment <n> --body-file <path>

### Every gh call carries the prefix

`GH_TOKEN`/`GITHUB_TOKEN` are the pair the environment started with; it expires about an hour
later and nothing can rewrite another process's environment, while the gh auth store beside it
stays healthy and is never asked. Hence the prefix on every `gh` call, including these.

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

## Step 5a -- write back to the issue (2 calls)

### The number, the branch, and the keyword

A bug fix branches as `fix/<n>-<slug>` off the tip of the trunk. The closing keyword lives in
the pull request body and nowhere else on the branch:

- `Closes #<n>` / `Fixes #<n>` only when this pull request fully settles the report
- `Refs #<n>` when it is one of several, or lands before the fix
- never repeat `Fixes #<n>` down the branch -- GitHub links every commit subject that carries
  one, so repeating it multiplies a single link and blurs which commit answers the report

### Post the reproduction, the verdict, and the branch

Write the body to a file and give `gh` the path; never put the body in argv, where one quoting
mistake mangles the report:

    env -u GH_TOKEN -u GITHUB_TOKEN gh issue comment <n> --body-file <path>

Post the reproduction output verbatim, the verdict, and the branch name. "Cannot reproduce" is
a finding to post with what you ran and what you actually saw, not a fix -- the report stays
open either way.

### Make the association an artifact, not a sentence

The link between the bug and the fix is a file you write and a path you record, so it survives
the session. Write the pull-request body to a path outside the repository, name that path in
the issue comment beside the branch and the tip sha (`git rev-parse <branch>`, not the sha you
remembered), and read the number back if a pull request already exists for the branch:

    env -u GH_TOKEN -u GITHUB_TOKEN gh pr list --head <branch> --state all --json number,url,state

Post that number onto the issue as a comment from a file. A comment that names the pull request
is the cross-reference; nothing in this step closes, reopens, or relabels the issue.

### The push and the open are the operator's, so hand over a checklist

Never push or open the pull request on your own. Hand the operator the two commands, with the
body file already in the second one, and say plainly that you skipped both:

    git push -u origin fix/<n>-<slug>
    env -u GH_TOKEN -u GITHUB_TOKEN gh pr create --head fix/<n>-<slug> --body-file <path>

The checklist they run: open the body file, fill the two lines it asks for, check the keyword
line is the one the evidence earns, run both commands, then read the new number back onto the
issue. Only a run the operator explicitly asked to ship may run those two itself, and then it
reports whether the push really happened.

### You are not the maintainer

Never close, reopen, reassign, label, or milestone someone else's issue, and never answer a
question in it that belongs to the operator; draft that reply for them instead. The merge that
closes an issue is a human action -- your closing keyword only takes effect there.

### The one auth stop rule

    bazelisk run //scripts:github-auth -- check <repo-url>

Its last line is the verdict. A line beginning `HANDOFF` means a human owes three clicks in the
Coder UI: pass that on and stop. Do not try workarounds -- no hand-rolled `GIT_ASKPASS`, no
hand-written credential helper, no interactive login, no ssh remote.
