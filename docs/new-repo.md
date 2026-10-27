---
title: New projects from the template
description: What project-template/ ships, how scripts/new-repo.sh renders it into a new GitHub repository, and what the Coder side adds.
tags: [template, new-repo, scaffold, coder-task, project-template]
---

**What's on this page**

- Two different things called "template", and which one this page is about
- What the scaffold ships, and the account-wide gaps it closes
- Rendering a repository with `new-repo`, its flags, and its lanes
- Which GitHub steps need which App permission, and what the CLI does when one is refused
- The `New project` workspace preset and the optional Coder Task
- Where all of this is enforced

**What this enables**

- Starting a new repository with the quality gate already in place, in one command
- Getting the same scaffold on a laptop, in CI, and from a workspace
- Telling a refused GitHub permission apart from a broken render

## Two kinds of template

This repository already uses the word *template* for a **Coder template**: the Terraform tree
under `templates/workspace/` and `templates/devcontainer/` that `push-template.sh` registers with
the Coder server.

`project-template/` is a different thing. It is a **project scaffold**: a tree of files that
`scripts/new-repo.sh` copies, substitutes, and hands to `git init` as the first commit of a brand
new repository. Nothing in `project-template/` is built by Bazel or read by the stack at runtime.
It is registered as a payload group (`//project-template:payload`) so the render gate can open it
under hermetic runfiles and so its shell is held to this repo's own shellcheck and shfmt bar.

## What the scaffold ships

The scaffold is language-neutral at the core, with optional per-language lanes. Everything below
was chosen from what is measurably missing across the account, not from taste: across a sample of
eleven ordinary projects, `SECURITY.md`, `CONTRIBUTING.md`, issue templates, a pull-request
template, `dependabot.yml`, `CODEOWNERS` and `.editorconfig` were each present in none of them,
and no repository in the surveyed set had a single release or tag.

| Area | What ships |
|---|---|
| Community | `SECURITY.md` with a supported-versions table and private-report route, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md` |
| GitHub | `.github/workflows/ci.yml`, `release.yml`, `security.yml`, `dependabot.yml`, `CODEOWNERS`, issue templates with blank issues disabled, a PR template with a Safety/ops-impact section |
| Hygiene | `.editorconfig`, `.gitattributes`, `.gitignore`, `.env.example`, `.yamllint.yml`, `.shellcheckrc` |
| Gates | `.pre-commit-config.yaml` whose local hooks **fail** when a tool is missing, plus `tests/run.sh`, a dispatcher that errors rather than skipping when a runner is absent |
| Pins | `tool-versions.env`, read by the dev container, `make doctor`, and CI, so the three cannot drift |
| Agent contract | `AGENTS.md` with the cost-tiered "which check first" table and the path-to-test mapping |
| Docs | `docs/ARCHITECTURE.md`, `docs/project-conventions.md`, and `docs/adr/` with a template plus one worked ADR |
| Packaging | a multi-stage non-root `Dockerfile` and a separate `Dockerfile.test` |

The rule that ties it together: **a check that silently skips is a bug**. Two existing
repositories print `tool not found ... Skipping` and then exit zero, and a pre-commit config in
another wraps every hook in `command -v ... || exit 0`. Nothing in the scaffold may do that.

### Lanes

| Lane | Adds |
|---|---|
| `shell` (default) | `src/main.sh`, a pure helper under `src/lib/`, Bats suites, `scripts/lint-shell.sh` |
| `python` | `pyproject.toml` with Ruff and `fail_under = 100`, `mypy.ini` at strict, a package under `src/`, pytest |
| `typescript` | ESLint 9 flat config, Prettier, Vitest with 100% thresholds, `tsc --noEmit` |
| `go` | `go.mod`, `.golangci.yml`, table-driven tests, `go vet`, `gosec`, a coverage floor |

Each lane lives at `project-template/.evo-lanes/<lane>/`. A file there is copied over the rendered
tree at the same path, so a lane may add files or replace a core one. `LANE.md` and
`gitignore.fragment` are lane metadata: the renderer appends the fragment to `.gitignore` and drops
both from the output.

## Rendering a repository

```bash
bazelisk run //scripts:new-repo -- --dry-run demo-tool
bazelisk run //scripts:new-repo -- demo-tool --description "Does the thing" --lane python
bazelisk run //scripts:new-repo -- --private my-tool --lane go --lane shell
bazelisk run //scripts:new-repo -- --no-push --out /tmp/try demo-tool
```

| Flag | Effect |
|---|---|
| `--dry-run` | render, report, create nothing on GitHub |
| `--out <dir>` | parent directory for the rendered repository (default: the current directory) |
| `--no-push` | render and commit locally only |
| `--no-remote` | skip every GitHub step |
| `--private` | create the repository private |
| `--as-template` | mark it as a template repository |
| `--description`, `--owner`, `--holder`, `--year` | token values; the owner defaults to the authenticated account |
| `--lane <id>` | add a lane; repeatable, default `shell`. `--lane none` clears the lanes named so far and renders the bare core, whose `make test` asks for a lane |
| `--topic <t>` | extra topic; repeatable |
| `--task`, `--task-template <n>` | also offer a Coder Task |
| `--branch <name>` | default branch, `main` by default |

Placeholders are substituted in file contents *and* in file and directory names:
`__PROJECT_NAME__`, `__PROJECT_SLUG__`, `__PROJECT_MODULE__`, `__PROJECT_DESCRIPTION__`,
`__PROJECT_OWNER__`, `__PROJECT_LICENSE_HOLDER__`, `__PROJECT_YEAR__`. A token that survives is a
hard failure, not a warning -- a repository that ships with its placeholders showing is worse than
no template at all.

Markdown carries a token in a second spelling. Prettier reads a bare `__PROJECT_NAME__` as strong
emphasis and rewrites it to `**PROJECT_NAME**`, so a markdown formatter run over the template turns
every prose placeholder into that form; the renderer substitutes both spellings, and
`tests/bats/project-template.bats` rejects any token name outside the seven in either form.

Two kinds of file are removed on the way out: a lane's reserved metadata (`LANE.md`,
`gitignore.fragment`, whose contents are consumed rather than copied) and the stack-only files in
`NEW_REPO_TEMPLATE_META`. The latter is currently `project-template/BUILD.bazel`, which exists so
`//:stack_data` can depend on the payload and has no meaning inside a customer's repository.

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
`additional_repos`, which is what puts `scripts/new-repo.sh` and `project-template/` inside a fresh
workspace beside the project. It is a preset, so it only sets parameter values.

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

## Where this is enforced

- `//tests:bats_new_repo_test` renders into a temp directory with `gh` and `git` stubbed and asserts
  token substitution, lane overlay, `gitignore` fragments, and that `--dry-run` creates nothing.
- `//tests:bats_project_template_test` asserts the scaffold ships its required files, carries no
  unsubstituted token, contains no `|| exit 0` silent skip, and pins every tool rather than using
  `@latest`. It also pins that every lane has a heading in `tool-versions.env`, which is what lets
  `make doctor` skip a lane's tools when that lane was never rendered.
- `//tests:bats_new_repo_test` renders each lane and asserts the rendered tree holds no symlink (a
  lane copied out of Bazel runfiles with `cp -a` would ship files that point into a directory which
  disappears with the build) and that `make doctor` does not demand another lane's toolchain.
- `//project-template:shell_sources` is in the lint drivers' source lists, so scaffold shell is
  checked by the same shellcheck and shfmt runs as the CLIs.
- `//tests:bats_bazel_deps_test` keeps `_SCRIPT_PAYLOAD["new-repo"]`, the `TOKEN_GROUPS` entry and
  the `//:stack_data` aggregate honest about what the CLI actually reads.
