---
name: migrator
description: "Land a dependency or API upgrade as one small, reversible change: find where the
  version really lives and cite it by path:line, read the upstream delta from a research lane
  rather than from memory, write the plan and the rollback before touching anything, fan the edits
  out over disjoint file sets, then let an independent skeptic re-run the gate and try the rollback.
  Use when asked to bump, upgrade, or migrate a dependency, or to adapt code to a changed API. Run
  as /migrator <dep>@<version>|<api-change>."
when-to-use: "Use when a pinned tool, library, or API must move to a new version, or when code must
  adapt to a changed upstream contract. Skip it for a defect -- that is /bug-hunt."
argument-hint: "<dep>@<version>|<api-change>"
compatibility: "Requires the repository's own gate; an image pin also needs the image build script
  and a no-cache rebuild. Uses Grok Build subagents (spawn_subagent) for the mapping, writing, and
  review lanes, and the stack's research lanes for the upstream delta; adds no dependency."
metadata:
  author: "operator"
  short-description: "Bump one version, prove it, and rehearse the rollback"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["migrator"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Migrator

One version moves per run, plus the proof that it moves; the rename you also wanted belongs on
another branch. This is the parent's runbook -- A depth-1 child may spawn `spawn_subagent` for read-only mappers only, and only when it ships no file of its own,
so the writer fan-out is still yours, and each block below runs only when you run it with `run_terminal_command` or `execute`.

Models are the local aliases this run uses -- `agent`, `agent-explore`, `agent-swarm`,
`agent-review` -- and no cloud id. Budget 20 to 35 of your own calls plus the migrate wave, and
never read `.env` or `.env.*`: a key's shape comes from `.env.example` or the CLI that prints it.

## Phase 1 -- pin: where the version actually lives (read-only, `agent-explore`, 2 to 5 calls)

A version is rarely one number in one file. Send one read-only child per disjoint area on
`agent-explore`, the lane for pure mapping, and take back `path:line` for every place the old string
appears: manifest, lockfile, base image tag, the test that asserts it, the doc that quotes it.

Here the pin lives in `images/dev/tool-versions.env` and its mirror in `images/dev/Dockerfile`: each
key there must also be an `ARG` in the Dockerfile or `//tests:bats_image_test` fails
(`tests/bats/image.bats:25`), and `scripts/lib/tool_pins.sh` turns the same keys into host download
URLs, so a rename strands CI. Bumping those two files is the whole dependency update -- the
contributor container needs no edit because `devcontainer.json` `cacheFrom`s the image built there.

## Phase 2 -- the delta, from a lane and not from memory (1 to 3 calls)

Read what upstream actually changed: the notes for every version you are skipping, the deprecations
since removed, the minimum runtime the release demands. Use a research lane -- context7 for an API
surface, resolved to a library id first, or searxng `search` / `fetch_content` for a release note.

A current fact carries its source URL or is labelled unverified; an unverified delta stops a major
bump, and a labelled patch or minor may proceed with that label carried into the report.

## Phase 3 -- plan before you touch anything (mandatory)

A migration is exactly the case Plan Mode exists for. Write the plan ahead of the first edit: the
files from Phase 1, the order they move in, the rollback, and the one command that proves the
upgrade. Five files or one wave of writers is `/ez-micro-plan` territory -- `.grok/plans/<slug>/`,
with `plan_check.py --ready` green before wave 1. Run the proving command on the untouched tree
first, so the baseline is quoted; a red baseline is `/bug-hunt`. Write the rollback as a command.

## Phase 4 -- migrate: one writer per disjoint file set (`agent-swarm`)

Fan out only after the conflict gate: the exact file set known, one writer per file, no overlapping
globs, no new shared symbols. At or above three independent writers the wave goes on `agent-swarm`,
which spreads it over every Spark box; below three, run them on `agent` in one turn. Each writer
gets its owns list, a must-not-touch list, the old and new version strings, a literal done command.

Hotspots stay with the parent: lockfiles, generated artifacts, snapshots, a barrel or registry,
migration order, and here the `tool-versions.env` plus `Dockerfile` pair, which move as one unit.
Bump only; take the call-site changes the new API forces and leave the rest for the next branch.
Then rehearse the rollback before you build on the new pin:

    git diff main...HEAD > /tmp/pin.patch && git apply -R /tmp/pin.patch
    <the proving command>                            # must pass on the old pin too
    git apply /tmp/pin.patch && git status --short   # clean again

## Phase 5 -- skeptic (independent, `agent-review`)

Hand the change to a reviewer that wrote none of it, with the base ref, the plan, and the commands,
and require it to run them in its own shell rather than read your report, and to repeat the rollback
trio itself. It reports each claim kept or broken with `path:line` -- the rule the Delegation
section of `templates/common/GROK_BUILD_AGENTS.md` states: nothing merges on the writer's own word.

## Hard rules

- One upgrade per branch; never bump and refactor in the same change, because a bump that also
  renames cannot be reverted alone and no reviewer can tell which line caused the failure.
- The rollback is rehearsed, not assumed: an untested rollback is a hope with a commit attached.
- Never introduce a new dependency to fix an old one without saying so -- plan, commit body, PR --
  and why the existing toolchain cannot do it.
- A pin that cannot be reproduced from a clean image is a failure: after the bump run
  `bazelisk run //:fix`, `bazelisk test //:lint --test_tag_filters=manual`, then a no-cache rebuild.
- Pure ASCII in everything you write, the diff, the plan, and the commit message included.

## Done means

Each line is a command someone ran and quoted, not an adjective you asserted. No quoted proving run,
no merge; rollback unexercised, no merge.

    # pin: git diff --stat main...HEAD names only the pin files, whose diff is the only version
    #      change in the tree
    # prove: the one command from Phase 3, its output pasted verbatim into the pull request
    bazelisk test //:test-fast
    bazelisk test //:lint --test_tag_filters=manual
    # skeptic on agent-review: re-ran both gates and the rollback; every claim kept or broken
    # rollback: the reverse patch ran once, the proving command passed, status is clean
