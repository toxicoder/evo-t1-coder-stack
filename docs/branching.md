# Branching

Trunk-based, GitHub-Flow shaped: one long-lived branch, short-lived work branches, and a pull
request as the only way back into `main`.

## main

- `main` is the only long-lived branch. It stays green and deployable: `main` is what a
  machine is built from, so a merge to `main` is by definition deployable to the stack host.
- Nothing is committed straight to `main`. Integration into `main` is by pull request, and a
  PR is only mergeable once CI is green: `bazelisk test //:test-fast` and
  `bazelisk test //:lint --test_tag_filters=manual`. `bash scripts/setup-host.sh` installs
  the toolchain those two need; `bazelisk run //:validate` runs both of them locally, plus
  `docker compose config -q` and the `.env.sample`/`.env.example` comparison — that is the
  pre-PR gate.

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
  Bazel checks before merging.
- Environments are where future protection rules and secrets go, per environment:
  `development`, `staging`, `production`. `production` stays restricted to `main` — or to
  tags — with required reviewers. See the header comment in `.github/workflows/ci.yml`.

## Scope

A `fix/…` branch that also has to rename a template directory, retarget a `.bats` suite, and
update `docs/` is one change: the rename is not green until the last reference follows.
When a rename cannot be proven complete, the reference stays (a rename is only "done" when
the old name is gone outside historical docs) and the CI file says so in a comment.
