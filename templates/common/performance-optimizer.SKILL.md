---
name: performance-optimizer
description: "Find the hotspots a program that already works actually pays for: take a baseline
  with the instrument that already exists locally and quote it, hunt the cost with read-only
  mappers who cite lines and name the cost they see, rank proposals by measured cost rather than
  how bad the code looks, land at most one change, then re-measure and let an independent skeptic
  decide whether the delta survives. Use when asked to optimise, speed up, profile, or fix slow
  code. Run as /performance-optimizer <path|command> [--metric <name>] [--no-change]."
when-to-use: "Use when the code works and is too slow, or a number is already on the table and
  you want it smaller. Skip it for a defect -- that is /bug-hunt -- and for code nobody waits on."
argument-hint: "<path|command> [--metric <name>] [--no-change]"
compatibility: "Requires the repository's own gate plus one instrument that is already here: time,
  hyperfine if installed, rg --stats, or Bazel --profile and --explain. Uses Grok Build subagents
  (spawn_subagent) for the mapping, writing, and review lanes; adds no dependency."
metadata:
  author: "operator"
  short-description: "Measure, hunt, change one thing, re-measure, then let a skeptic judge"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["performance-optimizer"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Performance optimizer

## The one rule, and who runs the blocks

One number before, one number after, one change between them: a speed-up nobody measured is an
opinion with a commit attached, so no baseline means no run. This is the parent's runbook --

A depth-1 child may spawn `spawn_subagent` for read-only mappers only, and only when it ships no
file of its own, so the writer fan-out is still yours; run each block with `run_terminal_command` or
`execute`, since a block written inline here runs nothing on its own.

## Two consumers, one file

The CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the chat agent reads only that other home.

## Models and the four hard rules

Models are the local aliases this run uses -- `agent`, `agent-explore`, `agent-swarm`,
`agent-review` -- and no cloud id.

Four hard rules, none of them bend:

- one change per run, so the delta has one cause
- no new dependency, no framework, no micro-optimising code that runs once
- report a regression even when the headline improved
- pure ASCII in everything you write

## Step 1 -- baseline, or the run stops (mandatory, on `agent-explore`, 3 to 6 calls)

Measure the program as it stands, on the input it actually sees, and name the instrument you used:

    time <the command>
    hyperfine --warmup 3 --runs 7 '<the command>'   # only if installed; never install it
    rg --stats '<pattern>' .                        # search work: files, matches, elapsed
    bazelisk build //... --profile=/tmp/perf-profile.gz --explain=/tmp/perf-explain.txt  # Bazel repos
    <the build or test step the repo's own CI runs, with its profiler flags>              # elsewhere
    cat /proc/loadavg /proc/meminfo /proc/self/io   # Linux: is it even the CPU

A single run under a second is noise: quote the median of at least seven with its spread.

If no baseline can be taken -- no runnable input, nothing to time, a box too noisy to separate 5
percent from jitter -- stop and say so in those words: an optimisation with no before number is a
guess.

## Step 2 -- hunt with two mappers on disjoint suspicions (2 children, `agent-explore`)

### Pick two suspicions that do not price the same line

Spawn two read-only children in one turn on `agent-explore`, the cheap mapping lane, over disjoint
suspicions so the pair does not price the same line twice:

- algorithmic shape: nested loops over one collection, linear scans that want a keyed lookup, a sort
  where one pass or a heap suffices, strings built by concatenation;
- work done twice, and IO: files re-read, config re-parsed, a subprocess or a round trip per item,
  uncached stat and directory walks, plus startup and cold-cache cost.

### What each finding must carry

Each finding carries:

- its `path:line`
- the cost it believes it sees
- how it got that cost: the loop bound, the subprocess count, bytes from `/proc/self/io`, seconds
  from a timed sub-run

A mapper that cites no line did not read the file; one that names no cost is guessing. Neither child
edits.

## Step 3 -- rank by measured cost and falsify each proposal (on `agent`, 2 to 3 calls)

### Rank by measurement, not by ugliness

Rank the findings by what the measurement says each one costs, not by how bad the code looks: the
ugly loop the profile never mentions is not a hotspot, and the plain one holding 60 percent of the
wall time is.

### Write three proposals, each falsifiable

Then write the top three proposals, one line each, each with the experiment that would falsify it --
same command, same input, the number expected to move and by how much. A proposal with no falsifying
experiment is a preference, not a candidate.

Take the one whose experiment is cheapest and whose predicted move is largest; with `--no-change`,
report the ranked list and stop.

## Step 4 -- one change, one writer (1 to 3 calls, the writer on `agent-swarm`)

### One writer, one change

Land at most one change per run, with one writer, so the after number belongs to that change alone.

Spawn it on `agent-swarm` with the baseline, the proposal, its falsifying experiment, and an `owns`
set narrowed to the files it needs, plus the instruction to keep the diff that proposal's size: no
drive-by reformat, no new dependency.

### Hotspots stay parent-owned

Hotspots stay parent-owned (the registry, the BUILD file, the shared fixture), and you make those
edits yourself once the writer lands.

## Step 5 -- re-measure, then a skeptic who ran both numbers decides (3 to 6 calls)

### Set the two numbers side by side

Re-run the baseline command on the changed tree -- same input, same box, same repeat count -- and
set the two numbers side by side.

Then hand the change to an independent skeptic on `agent-review`, never the writer and never you,
with both commands, the repo's own gate command, and the base ref, and require it to run all three.
Discover that gate once before you hand anything over -- the test steps in the nearest `BUILD.bazel`
(`bazelisk query 'kind(test, //...:all)'`), the `scripts` map in `package.json`, the `Makefile`'s
target list, or the job steps in `.github/workflows` -- and never copy one from another repo:

    git worktree add --detach /tmp/perf-base <base-ref> && (cd /tmp/perf-base && <the command>)
    <the exact same command>           # then git worktree remove /tmp/perf-base
    <the repo's own gate command>      # discovered just above

### Let the skeptic's own runs decide

The skeptic answers one question: does the delta survive its own runs?

Quote a regression even when the headline improved: median down with the tail up, or wall time down
with user time doubled. When the delta does not survive, revert and report the measurement that
killed it.

## Done means

Each line is a command someone ran and quoted, not an adjective you asserted:

    # before: instrument named, median of N runs with its spread, from Step 1
    # after: the same command, the same input, the same repeat count
    # skeptic on agent-review: re-ran both in its own shell; its own transcript is the proof
    <the repo's own gate command, discovered in Step 5>   # the gate, in your own shell

One change in the diff, one writer on it, the falsifying experiment confirmed or falsified, and
every regression listed beside the headline win. No both-numbers, no optimisation.
