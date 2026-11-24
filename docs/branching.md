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
- How an issue is read, referenced by the branch, and closed by the merge that fixes it
- What CI runs, what branch protection should require, and where secrets go
- How a stacked pull request chains its base, merges bottom-up, and is turned on per repository

**What this enables**

- Naming a branch and a commit so CI and `git log` read the way the rest of the repo does
- Recovering a half-finished change with one revert, because each landed step was committed as it landed
- Knowing which green check actually gates a merge into `main`
- Landing one change as a chain of layers a reviewer reads alone, without bypassing the gate

Trunk-based, GitHub-Flow shaped: one long-lived branch, short-lived work branches, and a pull
request as the only way back into `main`.

## main

### What main is allowed to be

- `main` is the only long-lived branch. It stays green and deployable: `main` is what a
  machine is built from, so a merge to `main` is by definition deployable to the stack host.
- Nothing is committed straight to `main`. Integration into `main` is by pull request, and a
  PR is only mergeable once CI is green:

  - `bazelisk test //:test-fast`
  - `bazelisk test //:lint --test_tag_filters=manual`
  - the full gate `bazelisk test //:test-all`

  All are executed inside the golden image (`images/dev/Dockerfile`) that CI builds with
  buildx and docker-runs — the toolchain comes from that image, not from anything installed
  onto the runner.

### Running the same gate locally

Locally, run them the same way: inside the contributor container
([contribute/devcontainer.md](contribute/devcontainer.md)) or with
`bazelisk run //scripts:test-in-image --`. `bash scripts/setup-host.sh` is the bootstrap
for the stack host, where the suites have to run on the host itself.

### Who runs the checks for you

Two things run those checks for you so the gate is not a thing to remember:

- `bazelisk run //scripts:pre-commit` on demand
- once `bazelisk run //scripts:install-hooks` has pointed `core.hooksPath` at `.githooks`,
  `.githooks/pre-commit` on every commit and `.githooks/pre-push` before anything is pushed

`bazelisk run //:validate` runs the fast pair plus `docker compose config -q` and the
`.env.sample`/`.env.example` comparison; the pre-PR gate is `//:test-all`, which
`//:validate` and the pre-push hook both reach.

## Work branches

### Cut, delete, and hotfix

- Cut `feat/…`, `fix/…`, `refactor/…` (and `docs/…`, `test/…`, `chore/…`, `ci/…`) from the
  current tip of `main`, one branch per change, and delete it the moment it merges. A branch
  that outlives its change is a branch nobody rebases any more.

  `bazelisk run //scripts:branch-hygiene` is the check for that sentence and for the two
  below:

  - it lists every branch the trunk already contains, every unmerged branch past the branch
    lifetime, and every branch that carries an environment in its name, each printed with its
    tip SHA because that is the record a deletion has to leave behind.
  - It reports and never deletes - `--plan` prints the commands, and deleting stays the
    operator's call.
  - Pass `--fetch` before acting on what it names, so the remote rows are the remote's
    current answer rather than the last one this checkout happened to see. That flag is the
    run's only write: it is `git remote update --prune`, which refreshes and prunes this
    checkout's own remote-tracking refs and deletes nothing on the remote.

- `fix/…` means a defect that is already on `main`.

  **A hotfix branches from `main` and lands on `main` first** — every environment deploys
  *from* `main` (or from a tag cut on `main`), so there is no `staging` or `production` branch
  to patch and then remember to merge back.

### Name the branch and the commit

- Name the branch after the change, not the author, and keep the commit subject imperative
  with one of `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, `refactor:`.
- Below the subject leave one empty line, then the bullet points, and leave an empty line
  between every two bullets, so each bullet is its own paragraph.

The same rule is in `templates/common/GROK_BUILD_AGENTS.md`, which is the text every workspace
seeds into `~/.grok/AGENTS.md`, so a commit written by an agent and one written by hand read the
same way in `git log`.

## Commits, and when they happen

### While the work happens

The branch and the commits are in place while the work happens, and the push waits. This is the
order the agent seed teaches and the order a human contributor gets the most out of:

- **Branch first, then edit.** The work branch is cut as the first action of the change, off the
  tip of `main`.

  - `main` is not a place to work: an agent edits it only when the operator asked for that in
    words.
  - Cut late and the branch is cheap to add anyway - `git switch -c` carries the working tree
    with it - which is the fix, where `stash`, `reset --hard`, or `checkout -- .` to clean the
    tree is how an unfinished change is destroyed.

- **Commit each unit as it lands.** A unit is what a reviewer reads as one step:

  - a script with its Bats file
  - a template with its twin
  - a flag with the docs that name it

  Commit when that unit's own check is green, then start the next one.
  `git log --oneline main..HEAD` then shows the shape of the change, and a wrong turn is one
  `git revert` away instead of a lost afternoon.

- **Stage by path.** `git add <path> <path>`, and read the index back with
  `git diff --cached --name-only`.

  `git add -A`, `git add .`, and `git commit -a` are how a scratch file, a build artifact, or
  someone else's edit walks into a commit - and the secret hygiene rule above depends on the
  agent being able to say what is in each one.

- **A local commit is free, a push is not.** Nothing leaves the machine until you push, so err
  toward committing, including a `WIP:` checkpoint before a step that might break something
  green.

  History is local until then, so amend the message, fold the checkpoint into the commit it
  belongs to, and reorder there; that door closes at the push, after which a shared commit is
  never rewritten.

### The push

- **Push once, when the pull request opens**, and pre-flight it:

  - the log above reads as one commit per unit with imperative prefixed subjects
  - `git diff --stat main...HEAD` matches what was meant
  - no `.env`, token, key, or workspace-local state is in any commit

Small commits cost nothing at the gate: `.githooks/pre-commit` runs the hermetic half on every
commit and `.githooks/pre-push` runs the full set before anything leaves the machine, so a stream
of focused commits is held to the same bar as one large one. See [`main`](#main) for installing
them.

## Issues, and how they close

Every change answers something, and the tracker is where the answer gets recorded. This is the
same etiquette `templates/common/GROK_BUILD_AGENTS.md` teaches every workspace, so a bug an agent
fixes and a bug a human fixes leave the tracker in the same state.

### Before the work

- **Read the report before you plan.** `gh issue view <n> --comments` is the requirements and
  the reproduction in one place, and it is the wording the change is measured against. An agent
  reads it through `env -u GH_TOKEN -u GITHUB_TOKEN gh ...` for the reason in
  [troubleshooting.md](troubleshooting.md).

- **Search before you file.** `gh issue list --state open --search '<keywords> in:title,body'`,
  then the same with `--state closed`.

  - A duplicate becomes a link to the original
  - Something `main` already fixed becomes a comment naming the commit
  - Only a genuinely new report becomes `gh issue create` - with the reproduction and the
    verbatim output in its body

- **Announce a long fix.** For anything past an obvious edit, a short comment saying what is
  about to change lets a maintainer redirect the work early and keeps two people off the same
  file.

### Recording the fix

- **Name the issue in the branch, close it in one place.** A bug fix branches as
  `fix/<n>-<slug>`, and the closing keyword goes in the pull request body only. GitHub
  auto-links `#<n>` in a commit subject too, so repeating `Fixes #<n>` down the branch
  multiplies one link and hides which commit answers the report.

- **Let the merge close it.**

  - `Closes #<n>` / `Fixes #<n>` claim the pull request fully satisfies the report, and GitHub
    closes the issue when it lands on the default branch - a merge a human performs.
  - `Refs #<n>` is the keyword for a pull request that is one step of the work, or lands before
    the fix.

  Nobody closes an issue by hand to announce that a pull request exists.

- **A bug fix ships with its proof.** The test that fails before the change and passes after it,
  with the reproduction's failing output quoted in the pull request. "Cannot reproduce" is a
  finding to post on the issue, and the issue stays open.

- **Triage belongs to a person.** Closing, reopening, reassigning, labelling and milestoning are
  the maintainer's calls, and an agent makes them only when the operator asked for that in words.

## CI and protection

### The CI workflow

- The `ci` workflow (`.github/workflows/ci.yml`) runs for `push` to `main` and for a
  `pull_request` whose **base** is `main` or one of the sanctioned work-branch prefixes
  (`feat/**`, `fix/**`, `refactor/**`, `docs/**`, `test/**`, `chore/**`, `ci/**`).

`pull_request.branches` filters on the base rather than the head, so naming only `main` left a
stacked pull request - a dependent branch that names its parent as its base, the shape the agent
guidance in `templates/common/GROK_BUILD_AGENTS.md` tells you to open - with no gate at all: it
collected just the docs deploy its branch push earned from `deploy-docs`. Gate a stack the same
way as any other pull request.

### The deploy-docs workflow

The other shipped workflow, `deploy-docs`, also runs on a `push` to any branch
(`branches: ["**"]`) whose diff touches its `paths:` list - `docs/**`, `docs-site/**`, the two
`scripts/ci/` helpers it publishes through (`publish-pages-tree.sh`, `docs-alias.sh`), and its
own workflow file - and by `workflow_dispatch`.

### Branch protection

- Branch protection on `main` should require a pull request before pushing, and the two
  Bazel checks before merging — `//:test-fast` and `//:lint`, run inside the golden image
  the workflow builds, so a green check means the suite passed on the Linux toolchain the
  stack actually ships rather than on whatever the runner image carried that day.

### Environments

- Environments are where future protection rules and secrets go, per environment:
  `development`, `staging`, `production`.
- `production` stays restricted to `main` — or to tags — with required reviewers. See the
  header comment in `.github/workflows/ci.yml`.

Those three words are environments and never branch names, and
`bazelisk run //scripts:branch-hygiene` is what keeps that honest: a branch or a
remote-tracking ref named `dev`, `staging`, `prod`, `uat` or the like - bare, or as the
first segment of a path - is an error and exits 1.

It is an operator CLI rather than a CI step on purpose: the branches that break the rule
live on the remote, where a job checked out at `main` cannot see them.

## Stacked pull requests

A stack is one change cut into layers that each review alone, where a layer's pull request
names the branch below it as its base instead of `main`. Every layer is still an ordinary
short-lived work branch, so everything under [Work branches](#work-branches) keeps applying
to it.

### The base chain

- Each layer names the branch below it as its base, and only the bottom layer names `main`.
  A reviewer then reads that layer's own commits rather than the change as a whole, which is
  the reason to stack at all.

- Open every layer as a draft, and mark one ready only when its own diff is complete and the
  layer below is green. A layer whose parent is still moving is a diff that keeps changing
  under the reviewer.

- Name the chain in the bodies. A layer states which pull request it depends on and names that
  pull request's base branch, and the pull request below says a child is stacked on it. The
  body's own sections still carry the change.

- A stack stays inside one repository: it cannot cross a fork or reach a second repository, so
  a change that genuinely spans two is two stacks whose bodies link each other.

- One logical change per stack. A stack splits a change a reviewer would read together; it is
  not a way to bundle unrelated work behind one review.

### Protection, merging, and deletion

- Protection is inherited, never duplicated. Branch protection and CODEOWNERS apply from the
  base of the bottom pull request - `main` - so a layer carries no rules of its own, and a
  layer is never a place to relax one.

- The gate runs on every layer. See [The CI workflow](#the-ci-workflow) for why the workflow
  has to match the work-branch prefixes rather than `main` alone.

- Merge bottom-up, and only through the asynchronous merge endpoint: `PUT` on
  `/repos/{o}/{r}/pulls/{n}/merge-async`, then poll the matching
  `GET .../pulls/{n}/merge-async/{uuid}` until it reports the result. Each merge hands the
  layer above a new base, so the stack unwinds one layer at a time from the bottom.

- Never merge a layer with the plain merge call and never merge out of order: the layer above
  is left pointing at a base that no longer exists, carrying commits that belong to its
  parent.

- Record a layer's tip SHA before it is deleted - the same record any deletion leaves behind,
  per [Work branches](#work-branches) - and delete only the layers the trunk already
  contains.

### Enabling it, and the two CLIs

- Stacks are enabled per repository, and that is an operator action in the repository's
  settings: no script can turn it on. A stack call against a repository that has them off is
  reported as a note naming that setting, so the reader knows a person has to act rather than
  the command being worth retrying.

- Every call goes through `env -u GH_TOKEN -u GITHUB_TOKEN gh api`, for the reason in
  [troubleshooting.md](troubleshooting.md).

- `bazelisk run //scripts:stack-prs` is the CLI for the chain: it records the layers in order,
  bottom to top, and performs the bottom-up merges through `merge-async` and nothing else.

- `bazelisk run //scripts:branch-hygiene` still audits the topology, because the layers are
  branches: a merged-but-undeleted layer, or one past the branch lifetime, is still its
  finding, and an environment-named layer is still the error [Environments](#environments)
  already refuses.

## Scope

A `fix/…` branch that also has to rename a template directory, retarget a `.bats` suite, and
update `docs/` is one change: the rename is not green until the last reference follows.

When a rename cannot be proven complete, the reference stays (a rename is only "done" when
the old name is gone outside historical docs) and the CI file says so in a comment.
