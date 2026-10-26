---
title: Branching
description: "Trunk-based branch rules: main is the only long-lived branch, work branches are short-lived, and a pull request is the only way back in."
tags: [git, branching, ci]
---

**What's on this page**

- What `main` is allowed to be, and what may not be committed to it
- How to cut, name and delete a short-lived work branch
- Where a hotfix branches from and where it lands first
- What CI runs, what branch protection should require, and where secrets go

**What this enables**

- Naming a branch and a commit so CI and `git log` read the way the rest of the repo does
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

## CI and protection

- CI runs only for `push` to `main` and for `pull_request` targeting `main`.
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
