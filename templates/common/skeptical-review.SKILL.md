---
name: skeptical-review
description: "Put one diff through an independent reviewer whose job is to break it, not to
  bless it: take the author's claim as unverified, re-run the exact commands the producer
  said proved it, attack the change from several independent angles, then report every
  requirement as kept or broken with the path and line that decides it. Use when asked to
  review a diff or a pull request skeptically, or to verify that delegated work works. Run
  as /skeptical-review <diff-spec-or-pr> [--focus <risk>]."
when-to-use: "Use before anything merges that someone else wrote, and always after a
  subagent reports its own work as done: a delegated result is a claim, not a fact."
argument-hint: "<diff-spec|pr-number> [--focus <risk>] [--json]"
compatibility: "Requires git and the repository's own gate. Uses Grok Build subagents
  (spawn_subagent) for the parallel attack lanes; adds no dependency."
metadata:
  author: "operator"
  short-description: "Independent review that re-runs the producer's own proof"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["skeptical-review"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Skeptical review

One reviewer, independent of the author, trying to make the diff fail. This phase is
mandatory: nothing merges on the producer's word, and a review written by the person who
wrote the change is not a review. This is the parent's runbook -- a child has no
`spawn_subagent` and cannot spawn the lanes below, so the fan-out is yours to run. Budget
12 to 25 of your own calls: the review's value is the commands it ran, not the prose.

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder
Agents chat agent); a command written inline in this body runs nothing on its own.

Two consumers, one file: the CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the Coder Agents chat agent reads only
`~/.coder/skills/<name>/SKILL.md`. Keep the pair; never ship one home alone.

Read the diff, the tests, and the repo: everything a verdict needs is in the checkout, and
a review that searched the web for how this codebase behaves has not read the codebase. A
research lane is for a fact outside this repository. Models are the local aliases only --
`agent`, `agent-low`, `agent-medium`, `agent-xhigh`, `agent-swarm`, `agent-explore`,
`agent-review` -- never a cloud id.

## Step 0 -- take the claim, not the conclusion (2 calls)

Write down what the change asserts before you read a line of it: the request in one
sentence, each acceptance criterion, and the `done:` command the producer quoted. That list
is what you will falsify; a review with no claim to check drifts into style commentary.

    git rev-parse --abbrev-ref HEAD
    git diff --stat <base>...HEAD

For a pull request, read the issue behind it with
`env -u GH_TOKEN -u GITHUB_TOKEN gh issue view <n> --comments` and quote its acceptance text
back: the report answers to the reporter's words, not the author's summary.

## Step 1 -- read what was actually written (up to 5 calls)

Read the whole diff, then each changed file in context -- a diff hides the caller that no
longer matches the signature. Read the tests that cover it and ask what they would do if
the feature were broken: a test that passes with the change reverted proves nothing.

Map the blast radius with one read-only child on `agent-explore`, the lane for pure
mapping: who calls what changed, which payloads and twins move with it, which gate covers
it. It answers with `path:line` or it did not read the file.

## Step 2 -- re-run the producer's own done commands (mandatory, 3 to 5 calls)

Run the exact command the producer reported, in your own shell, and compare its summary
line to the one the producer claimed. Do not read the producer's report before you run the
check, or you will read the conclusion into the evidence.

    bazelisk test //:test-fast
    bazelisk test //:lint --test_tag_filters=manual

Quote the summary line you got. `Executed 0 out of N tests: N tests pass.` is a cached pass
over unchanged inputs, so re-run with `--nocache_test_results` before you accept a green you
did not earn. A claim you did not run is a claim you did not check.

## Step 3 -- attack it from independent angles (1 call per lane, one turn)

Spawn one child per independent attack surface: the requirement list, the error and
boundary paths, the security-relevant sinks, the tests' real coverage, and the docs and
flags the change owes. The lane rule: at or above three independent children goes on `agent-swarm`,
which spreads them over every Spark box; below three, keep them on `agent` and launch them in
one turn anyway. The reviewer that judges the merge rides `agent-review`.

Each lane gets the diff, the tests, and the acceptance list -- never the author's summary --
and one question, and returns kept or broken per criterion with `path:line` and the command
that shows it. A delegated result is still a claim: you re-run what a lane reports broken.

## Step 4 -- report kept and broken, each with its proof (1 call)

One block per requirement, in the author's order, each line carrying the verdict, the
`path:line`, and the command with its result. Then the findings that block, ranked by
whether they break the requirement or only the style; only the first kind holds a merge.

Say plainly what you did not check and what you could not reproduce: an honest gap is
review, where a confident blank is how a broken change ships with a green review beside it.

## Step 5 -- hand it back, and do not fix it yourself (1 call)

Return the verdict to the owner of the failing area, never to another writer with a live
edit in the same paths, and never merge your own review. The author fixes and re-runs; you
re-run the failed command on the new state and say whether it moved.

If the review turns up real work across several files, that is `/ez-micro-plan` territory:
the fix goes through a plan and a fleet, with this skill as its last wave.
