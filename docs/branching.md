---
title: Branching
description: "Trunk-based branch rules: main is the only long-lived branch, work branches are short-lived, and a pull request is the only way back in."
tags: [git, branching, ci]
---

# Branching

**What's on this page**

- What `main` is allowed to be, and what may not be committed to it
- How to cut, name and delete a short-lived work branch, and when the branch and its commits happen
- Where a hotfix branches from and where it lands first
- What CI runs, what branch protection should require, and where secrets go

**What this enables**

- Naming a branch and a commit so CI and `git log` read the way the rest of the repo does
- Recovering a half-finished change with one revert, because each landed step was committed as it landed
- Knowing which green check actually gates a merge into `main`

Trunk-based, GitHub-Flow shaped: one long-lived branch, short-lived work branches, and a pull
request as the only way back into `main`.

## main

- `main` is the only long-lived branch. It stays green and deployable: `main` is what a
  machine is built from, so a merge to `main` is by definition deployable to the stack host.
- Nothing is committed straight to `main`. Integration into `main` is by pull request, and a
  PR is only mergeable once CI is green:
  `bazelisk test //:test-fast`, `bazelisk test //:lint --test_tag_filters=manual` and the
  full gate `bazelisk test //:test-all`, all
  executed inside the golden image (`images/dev/Dockerfile`) that CI builds with buildx and
  docker-runs — the toolchain comes from that image, not from anything installed onto the
  runner. Locally, run them the same way: inside the contributor container
  ([contribute/devcontainer.md](contribute/devcontainer.md)) or with
  `bazelisk run //scripts:test-in-image --`. `bash scripts/setup-host.sh` is the bootstrap
  for the stack host, where the suites have to run on the host itself.
  Two things run those checks for you so the gate is not a thing to remember:
  `bazelisk run //scripts:pre-commit` on demand, and, once
  `bazelisk run //scripts:install-hooks` has pointed `core.hooksPath` at `.githooks`,
  `.githooks/pre-commit` on every commit and `.githooks/pre-push` before anything is
  pushed. `bazelisk run //:validate` runs the fast pair plus
  `docker compose config -q` and the `.env.sample`/`.env.example` comparison; the
  pre-PR gate is `//:test-all`, which `//:validate` and the pre-push hook both reach.

## Work branches

- Cut `feat/…`, `fix/…`, `refactor/…` (and `docs/…`, `test/…`, `chore/…`, `ci/…`) from the
  current tip of `main`, one branch per change, and delete it the moment it merges. A branch
  that outlives its change is a branch nobody rebases any more.
- `fix/…` means a defect that is already on `main`. **A hotfix branches from `main` and lands
  on `main` first** — every environment deploys *from* `main` (or from a tag cut on `main`),
  so there is no `staging` or `production` branch to patch and then remember to merge back.
- Name the branch after the change, not the author, and keep the commit subject imperative
  with one of `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, `refactor:`.
- Below the subject leave one empty line, then the bullet points, and leave an empty line
  between every two bullets, so each bullet is its own paragraph. The same rule is in
  `templates/common/GROK_BUILD_AGENTS.md`, which is the text every workspace seeds into
  `~/.grok/AGENTS.md`, so a commit written by an agent and one written by hand read the
  same way in `git log`.

## Commits, and when they happen

The branch and the commits are in place while the work happens, and the push waits. This is the
order the agent seed teaches and the order a human contributor gets the most out of:

- **Branch first, then edit.** The work branch is cut as the first action of the change, off the
  tip of `main`. `main` is not a place to work: an agent edits it only when the operator asked for
  that in words. Cut late and the branch is cheap to add anyway - `git switch -c` carries the
  working tree with it - which is the fix, where `stash`, `reset --hard`, or `checkout -- .` to
  clean the tree is how an unfinished change is destroyed.
- **Commit each unit as it lands.** A unit is what a reviewer reads as one step: a script with its
  Bats file, a template with its twin, a flag with the docs that name it. Commit when that unit's
  own check is green, then start the next one. `git log --oneline main..HEAD` then shows the shape
  of the change, and a wrong turn is one `git revert` away instead of a lost afternoon.
- **Stage by path.** `git add <path> <path>`, and read the index back with
  `git diff --cached --name-only`. `git add -A`, `git add .`, and `git commit -a` are how a scratch
  file, a build artifact, or someone else's edit walks into a commit - and the secret hygiene rule
  above depends on the agent being able to say what is in each one.
- **A local commit is free, a push is not.** Nothing leaves the machine until you push, so err
  toward committing, including a `WIP:` checkpoint before a step that might break something green.
  History is local until then, so amend the message, fold the checkpoint into the commit it belongs
  to, and reorder there; that door closes at the push, after which a shared commit is never
  rewritten.
- **Push once, when the pull request opens**, and pre-flight it: the log above reads as one commit
  per unit with imperative prefixed subjects, `git diff --stat main...HEAD` matches what was meant,
  and no `.env`, token, key, or workspace-local state is in any commit.

Small commits cost nothing at the gate: `.githooks/pre-commit` runs the hermetic half on every
commit and `.githooks/pre-push` runs the full set before anything leaves the machine, so a stream of
focused commits is held to the same bar as one large one. See [`main`](#main) for installing them.

## CI and protection

- The `ci` workflow (`.github/workflows/ci.yml`) runs for `push` to `main` and for a
  `pull_request` whose **base** is `main` or one of the sanctioned work-branch prefixes
  (`feat/**`, `fix/**`, `refactor/**`, `docs/**`, `test/**`, `chore/**`, `ci/**`).
  `pull_request.branches` filters on the base rather than the head, so naming only
  `main` left a stacked pull request - a dependent branch that names its parent as its
  base, the shape the agent guidance in `templates/common/GROK_BUILD_AGENTS.md` tells
  you to open - with no gate at all: it collected
  just the docs deploy its branch push earned from `deploy-docs`. Gate a stack the same
  way as any other pull request. The other shipped workflow, `deploy-docs`, also runs
  on a `push` to any branch (`branches: ["**"]`) whose diff touches its `paths:` list -
  `docs/**`, `docs-site/**`, the two `scripts/ci/` helpers it publishes through
  (`publish-pages-tree.sh`, `docs-alias.sh`), and its own workflow file - and by
  `workflow_dispatch`.
- Branch protection on `main` should require a pull request before pushing, and the two
  Bazel checks before merging — `//:test-fast` and `//:lint`, run inside the golden image
  the workflow builds, so a green check means the suite passed on the Linux toolchain the
  stack actually ships rather than on whatever the runner image carried that day.
- Environments are where future protection rules and secrets go, per environment:
  `development`, `staging`, `production`. `production` stays restricted to `main` — or to
  tags — with required reviewers. See the header comment in `.github/workflows/ci.yml`.

## Scope

A `fix/…` branch that also has to rename a template directory, retarget a `.bats` suite, and
update `docs/` is one change: the rename is not green until the last reference follows.
When a rename cannot be proven complete, the reference stays (a rename is only "done" when
the old name is gone outside historical docs) and the CI file says so in a comment.
