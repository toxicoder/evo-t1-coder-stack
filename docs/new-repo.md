---
title: New projects from the template
description: How scripts/new-repo.sh fetches the ezrepo scaffold from GitHub, renders it into a new repository, and what the Coder side adds.
tags: [template, new-repo, scaffold, coder-task, ezrepo]
---

**What's on this page**

- Two different things called "template", and which one this page is about
- What the scaffold repository ships, and the account-wide gaps it closes
- Where the scaffold is fetched from, and how to pin or replace it
- Rendering a repository with `new-repo`, its flags, and its lanes
- Which GitHub steps need which App permission, and what the CLI does when one is refused
- The `New project` workspace preset and the optional Coder Task
- Where all of this is enforced

**What this enables**

- Starting a new repository with the quality gate already in place, in one command
- Getting the same scaffold on a laptop, in CI, and from a workspace
- Pinning a scaffold revision, or rendering a local tree with no network at all
- Telling a refused GitHub permission apart from a broken render

## Two kinds of template

This repository already uses the word *template* for a **Coder template**: the Terraform tree
under `templates/workspace/` and `templates/devcontainer/` that `push-template.sh` registers with
the Coder server.

The other *template* is a **project scaffold**: a tree of files that `scripts/new-repo.sh` copies,
substitutes, and hands to `git init` as the first commit of a brand new repository. It is not
vendored here. It lives in its own repository -- by default `https://github.com/toxicoder/ezrepo`
-- and this repo's whole job is to fetch that tree and render it. The scaffold is a product with
its own CI and its own release rhythm, and a vendored copy drifts from the day it is committed, so
nothing here is kept in step with it.

The coupling runs one way: this repo may name the scaffold repository; the scaffold repository
never names this one. And the scaffold's quality gate is its own -- the `.self-check/` suite and
the CI that runs it in that repository -- so a scaffold change is tested where it is made, and a
lane or a file the scaffold adds needs no change here.

## What the scaffold ships

These files belong to the scaffold repository. This repo does not ship them, lint them, or keep a
copy: it fetches them at run time and renders them. The scaffold is language-neutral at the core,
with optional per-language lanes. Everything below was chosen from what is measurably missing
across the account, not from taste: across a sample of eleven ordinary projects, `SECURITY.md`,
`CONTRIBUTING.md`, issue templates, a pull-request template, `dependabot.yml`, `CODEOWNERS` and
`.editorconfig` were each present in none of them, and no repository in the surveyed set had a
single release or tag.

| Area | What ships |
|---|---|
| Community | `SECURITY.md` with a supported-versions table and private-report route, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md` |
| GitHub | `.github/workflows/ci.yml`, `release.yml`, `security.yml`, `dependabot.yml`, `CODEOWNERS`, issue templates with blank issues disabled, a PR template with a Safety/ops-impact section |
| Hygiene | `.editorconfig`, `.gitattributes`, `.gitignore`, `env.example` (the render writes it out as `.env.example`), `.yamllint.yml`, `.shellcheckrc` |
| Gates | `.pre-commit-config.yaml` whose local hooks **fail** when a tool is missing, plus `tests/run.sh`, a dispatcher that errors rather than skipping when a runner is absent |
| Pins | `tool-versions.env`, read by the dev container, `make doctor`, and CI, so the three cannot drift |
| Agent contract | `AGENTS.md` with the cost-tiered "which check first" table and the path-to-test mapping |
| Docs | `docs/ARCHITECTURE.md`, `docs/project-conventions.md`, and `docs/adr/` with a template plus one worked ADR |
| Packaging | a multi-stage non-root `Dockerfile` and a separate `Dockerfile.test` |

The rule that ties it together: **a check that silently skips is a bug**. Two existing
repositories print `tool not found ... Skipping` and then exit zero, and a pre-commit config in
another wraps every hook in `command -v ... || exit 0`. Nothing in the scaffold may do that, and
the scaffold's own `.self-check/` suite is what holds the line.

### Lanes

Lane ids are not declared here. `scripts/new-repo.sh` discovers them from the fetched tree's
`.template-lanes/` directory at run time, so a lane the scaffold repository adds needs no change
in this repo. The four below are what it ships today:

| Lane | Adds |
|---|---|
| `shell` (default) | `src/main.sh`, a pure helper under `src/lib/`, Bats suites, `scripts/lint-shell.sh` |
| `python` | `pyproject.toml` with Ruff and `fail_under = 100`, `mypy.ini` at strict, a package under `src/`, pytest |
| `typescript` | ESLint 9 flat config, Prettier, Vitest with 100% thresholds, `tsc --noEmit` |
| `go` | `go.mod`, `.golangci.yml`, table-driven tests, `go vet`, `gosec`, a coverage floor |

Each lane lives at `<scaffold>/.template-lanes/<lane>/`. A file there is copied over the rendered
tree at the same path, so a lane may add files or replace a core one. `LANE.md` and
`gitignore.fragment` are lane metadata: the renderer appends the fragment to `.gitignore` and drops
both from the output. Ask for a lane the fetched tree does not have and the run dies naming the
lanes it does offer.

## Rendering a repository

```bash
bazelisk run //scripts:new-repo -- --dry-run demo-tool
bazelisk run //scripts:new-repo -- demo-tool --description "Does the thing" --lane python
bazelisk run //scripts:new-repo -- --private my-tool --lane go --lane shell
bazelisk run //scripts:new-repo -- --no-push --out /tmp/try demo-tool
bazelisk run //scripts:new-repo -- --template-ref v1 --lane python demo-tool
bazelisk run //scripts:new-repo -- --template-dir /tmp/ezrepo demo-tool
```

The scaffold is fetched before anything is rendered: a shallow (`--depth 1`), single-branch clone
of `--template-ref` into a scratch directory an EXIT trap removes. `GIT_TERMINAL_PROMPT=0` and an
empty credential helper keep a scaffold that turned private from hanging on a prompt nobody can
answer inside a workspace. A fetched tree with no `template.yml` at its root is a hard failure --
that manifest belongs to the scaffold repository, so pick a ref that has it. The new repository's
first commit records what it was built from: `- Scaffold: <url>@<sha>.`, or
`- Scaffold: local tree <dir>.` for a `--template-dir` render.

| Flag | Effect |
|---|---|
| `--dry-run` | render, report, create nothing on GitHub |
| `--out <dir>` | parent directory for the rendered repository (default: the current directory) |
| `--no-push` | render and commit locally only |
| `--no-remote` | skip every GitHub step |
| `--private` | create the repository private |
| `--as-template` | mark it as a template repository |
| `--description`, `--owner`, `--holder`, `--year` | token values; the owner defaults to the authenticated account |
| `--lane <id>` | add a lane; repeatable, default `shell`. Ids are discovered from the fetched scaffold, so a lane the scaffold adds needs no change here. `--lane none` clears the lanes named so far and renders the bare core, whose `make test` asks for a lane |
| `--topic <t>` | extra topic; repeatable |
| `--template-url <url>` | scaffold repository to clone (default: `$EZREPO_URL`, else `https://github.com/toxicoder/ezrepo.git`) |
| `--template-ref <ref>` | branch or tag to fetch (default: `$EZREPO_REF`, else `main`). Pin a tag for a reproducible render |
| `--template-dir <dir>` | render this local tree and fetch nothing (default: `$EZREPO_DIR`); `--template-ref` has no effect on it |
| `--task`, `--task-template <n>` | also offer a Coder Task |
| `--branch <name>` | default branch, `main` by default |

The three scaffold flags exist so the source can be pointed elsewhere without editing anything:
the env pair covers a mirror or a fork for a whole deployment, and `--template-dir` renders a tree
you already hold, which is the offline route and the one the hermetic tests use.

The run exits 0 when the render succeeded -- a refused GitHub step is a `warning:`, not a failure --
and 1 on a render failure, a bad argument, or a scaffold that cannot be fetched.

Placeholders are substituted in file contents *and* in file and directory names:
`__PROJECT_NAME__`, `__PROJECT_SLUG__`, `__PROJECT_MODULE__`, `__PROJECT_DESCRIPTION__`,
`__PROJECT_OWNER__`, `__PROJECT_LICENSE_HOLDER__`, `__PROJECT_YEAR__`. Those seven are named once,
in `NEW_REPO_TOKENS`, and they are the whole contract between this script and the scaffold -- a
ceiling rather than an equality, so the template may use a subset of them. A token that survives is
a hard failure, not a warning -- a repository that ships with its placeholders showing is worse
than no template at all.

Markdown carries a token in a second spelling. Prettier reads a bare `__PROJECT_NAME__` as strong
emphasis and rewrites it to `**PROJECT_NAME**`, so a markdown formatter run over the template turns
every prose placeholder into that form; the renderer substitutes both spellings. Which of the seven
the scaffold actually uses, in either spelling, is the scaffold's own invariant and its own
`.self-check/` suite checks it.

Two kinds of path are removed on the way out: a lane's reserved metadata (`LANE.md`,
`gitignore.fragment`, whose contents are consumed rather than copied) and the generator-owned paths
in `NEW_REPO_TEMPLATE_META`, stripped from every render: `.template-lanes/` (the overlay source this
script reads), `.self-check/` (the scaffold's conformance suite, which goes stale the moment a real
project diverges from the template it was checked against), and `.git` (which would hand the new
repository the template's history and origin remote).

## What each GitHub step needs

The credential here is the Coder External Auth GitHub App **user-to-server token**; this stack
never introduces a static token or PAT. An App can be granted one endpoint and refused another, so
the CLI runs the publish side as independent steps, each reporting `ok:` or `warning:` on its own.
No step is fatal, because aborting on the first refusal would abandon the steps that were allowed.

| Step | Endpoint | App permission |
|---|---|---|
| Create | `POST /user/repos` | `Administration: write` (or `Repository creation: write`) |
| Settings | `PATCH /repos/{o}/{r}` | `Administration: write` |
| Topics | `PUT /repos/{o}/{r}/topics` | `Administration: write` |
| Alerts | `PUT /repos/{o}/{r}/vulnerability-alerts` | `Administration: write` |
| Push | git over HTTPS | the credential above |

Dependabot **secrets** are a different permission that this App does not currently hold, which is
why the CLI does not attempt them. When a step is refused the CLI prints the endpoint, GitHub's
message, and the permission to ask for, then re-mints nothing and continues.

Because git and `gh` consult `GH_TOKEN`/`GITHUB_TOKEN` before the stored login, an expired token
pair from an old refresh can shadow a working credential. Every call tries the environment first
and, on refusal, retries once with the pair cleared and says so in a `warning:`. Re-mint with
`coder external-auth access-token github`.

## Coder side

Two things, and neither replaces the CLI.

The **`New project (scaffold ready)` preset** in both templates is a form shortcut. It pins the
golden image, turns on the DinD sidecar in the workspace template, and passes this stack as
`additional_repos`, which is what puts `scripts/new-repo.sh` inside a fresh workspace beside the
project being started. The scaffold does not ride along: the CLI fetches it from GitHub when it
runs. It is a preset, so it only sets parameter values.

**`--task`** calls `coder task create` once the repository exists. The Coder server here is v2.36.6
and does ship `coder task`, but the Terraform provider is pinned to `~> 2.18`, so a task cannot be
declared inside a template. The CLI therefore creates it at run time and, when it cannot reach the
Coder API -- the usual case outside a logged-in host shell -- prints the exact command and continues
with exit 0. That follows `new-workspace.sh`, which treats "cannot create right now" as a not-yet
rather than an error.

The CLI never creates the workspace itself. It prints
`next: bazelisk run //scripts:new-workspace -- <url>` and stops, because `new-workspace.sh` owns the
dev-container probe and the template choice, and a second copy of that decision would eventually
disagree with the first.

That preset/CLI pair is the whole hand-off. It is where this repo hands a new project over, and the
only coupling between the two repositories: this repo names the scaffold it clones, the scaffold
never names this one.

## Where this is enforced

The split follows the ownership: the scaffold's own invariants are checked in the scaffold
repository, and this repo checks only the renderer.

- The scaffold's `.self-check/` suite, in that repository and run by its own CI, owns the template's
  internal invariants: every token the template uses is one this script declares, every lane ships
  its `LANE.md` plus `gitignore.fragment` pair, every tool is pinned rather than `@latest`, the
  workflows declare `permissions`, the docs links resolve, and the pins cover the lanes present.
- `//tests:bats_new_repo_test` owns the renderer: token substitution in file contents and in file
  and directory names, the markdown `**NAME**` alias, the lane overlay and its `gitignore`
  fragments, the generator-owned paths stripped from every render, the argv of the scaffold clone,
  the credential ladder that retries once with `GH_TOKEN`/`GITHUB_TOKEN` cleared, the GitHub ladder
  staying advisory (a refused step warns and never fails the run), and the Coder Task being a
  convenience that cannot fail a render.
- `//tests:bats_bazel_deps_test` keeps `_SCRIPT_PAYLOAD["new-repo"]` honest about what the CLI
  actually reads.
