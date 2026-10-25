---
title: Contributor environment
description: "The one Linux golden image behind laptop work, the Coder workspaces and CI: what the contributor dev container builds, how it is seeded, and which path is the merge gate."
tags: [contributing, devcontainer, bazel, ci, docker]
---

**What's on this page**

- The single golden image, and the file that pins it
- Opening the repo as a contributor container in VS Code or a compatible editor
- What `seed-dev-env` materializes into that home, and what it refuses to touch
- GitHub auth inside the container, and why `github-auth check` runs SELF there
- The merge gate (Linux image) versus the convenience path (native Darwin)
- What CI does, and why this repo's own Coder workspaces stay on `workspace`

**What this enables**

- Reproducing CI's failure on your own machine with the same image CI runs
- Running the Bazel gate on macOS without maintaining a second, BSD-flavoured toolchain
- Telling the contributor container, the Coder workspace and the stack host apart in one look

One image — `images/dev/Dockerfile`, built as `evo-t1-dev:latest` — is the contributor and
test runtime on macOS, on Linux, and on GitHub. The same Dockerfile serves the Coder
workspaces the stack provisions, the contributor dev container on a laptop, and the
container CI docker-runs its checks inside. Every version in it comes from
`images/dev/tool-versions.env`; [../coder-templates.md](../coder-templates.md) covers the
workspace side, and [CONTRIBUTING.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/CONTRIBUTING.md)
is the checklist the PR follows.

## The one image, the one pin file

- `images/dev/tool-versions.env` is the single source of truth for every tool version:
  Bazelisk, buildifier, shfmt, shellcheck (apt), bats, Terraform/tflint/terragrunt, the
  Coder CLI, the Docker *client* trio, Node, Python, Go, protoc and the pinned Grok CLI.
- Each `KEY` there is also an `ARG` in `images/dev/Dockerfile`, and the `ARG` default
  mirrors the pin, so a bare `docker build` matches a scripted one.
- `bazelisk run //scripts:build-dev-image` refuses to build when a pin has no matching
  `ARG`, or when an `ARG` default drifted from the pin. Add both sides of a new pin in the
  same change.
- The image ships the Docker client only. The build ends with `test ! -x
  /usr/local/bin/dockerd` (plus `containerd`, `runc`, `docker-proxy`), so the merge-gate
  container drives a daemon it is given rather than owning one.

Build it locally when you want the tag in the local store (the Coder docker provider
resolves `evo-t1-dev:latest` from there and never pulls):

```sh
bazelisk run //scripts:build-dev-image
docker image inspect evo-t1-dev:latest
```

## Open it on a laptop

Use VS Code, Cursor, or any editor with the Dev Containers extension, and reopen this
repository **in a container**.

```text
Command Palette → Dev Containers: Reopen in Container
```

`.devcontainer/devcontainer.json` is what that reads:

| Key | Value | Why |
| --- | --- | --- |
| `build.context` / `build.dockerfile` | `../images/dev` / `Dockerfile` | The same Dockerfile the workspace and CI use; `ARG` defaults are the pins, so no build args are needed. |
| `remoteUser` | `coder` | uid/gid 1000, bash as its login shell — the user the Coder agent runs as. |
| `containerEnv` / `remoteEnv` | `EVO_T1_DEVCONTAINER=1` | The marker that says *contributor container*, not Coder workspace. Also carries `SEARXNG_URL`. |
| `mounts` | `/var/run/docker.sock` | The container talks to the workstation's own daemon, which is how a `docker run` inside it is a real one. |
| `runArgs` | `--add-host=host.docker.internal:host-gateway` | Reaches LiteLLM on `:4000` and SearXNG on `:8181` on the laptop. |
| `postCreateCommand` | `bash scripts/seed-dev-env.sh --devcontainer` | Seeds the contributor home the way a workspace start seeds a workspace. |
| `customizations.vscode.extensions` | Bazel, shellcheck, shell-format, Terraform, Docker, YAML | shellcheck and shfmt are the two `//:lint` runners, wired into the editor beside the Terraform, Docker and YAML helpers. |

`updateRemoteUserUID` is on, so the container's `coder` uid matches the host user and the
bind-mounted checkout stays writable without a `chmod` dance.

## Seeding the contributor home

`scripts/seed-dev-env.sh` materializes, into a laptop or CI home, the same stack-owned
files a Coder workspace writes at startup — from the same template payloads, with no
Terraform and no docker:

```sh
bazelisk run //scripts:seed-dev-env -- --dry-run --home /tmp/contributor-home
bazelisk run //scripts:seed-dev-env -- --home "${HOME}"
bazelisk run //scripts:seed-dev-env -- --litellm-url http://host.docker.internal:14000/v1
bazelisk run //scripts:seed-dev-env -- --devcontainer
```

| Flag | Effect |
| --- | --- |
| `--home <dir>` | Home tree to shape (default `$HOME`; created when absent; an existing non-directory is an error). |
| `--litellm-url <url>` | Model-transport address rendered into `settings.json` and `~/.grok/config.toml` (default `http://host.docker.internal:4000/v1`). |
| `--devcontainer` | After a successful write, run `gh auth setup-git` when `GH_TOKEN`/`GITHUB_TOKEN` is set and `gh` is on PATH. Best effort, and the token is never an argument. |
| `--force` | Re-materialize files a user owns. |
| `--dry-run` | Print the plan; write nothing, create no directory, call no `gh`. |

What it writes: `~/.tmux.conf`, the shared `~/.shared/vscode/settings.json` (with the
code-server and desktop VS Code User settings symlinked to it), `~/.grok/AGENTS.md`,
`~/.coder/AGENTS.md`, the rendered `~/.grok/config.toml`, the two terminal helpers in
`~/.grok/bin`, `~/.grok/notes-setup.sh` plus this clone's `notes.md`, and the
`~/.grok/bin` line in `~/.bashrc`.

Two rules decide every write, and they are the same rules the workspace startup applies:

- A file carrying the stack marker — `managed-by: evo-t1-coder-stack`, or the
  `"__evoT1Stack": true` key — is stack-owned and is reseeded when the seed in this repo
  drifted.
- A marker-free file is user-owned and stays untouched unless `--force` says otherwise.
  The terminal helpers and `notes-setup.sh` are the exception: startup rewrites those on
  every boot, so this script does too.

It never writes a secret, never writes a GitHub token or a PAT, and never installs the
Grok CLI — the golden image already carries `/usr/local/bin/grok`. Exit `5` means no
proven checkout was found (it wants `docker-compose.yml` where it is looking), which is the
same repo-root probe every other script in the repo makes.

## GitHub auth in the container

The contributor container is its own credential chain, so the doctor runs in SELF mode
there — exactly as it does inside a Coder workspace:

```sh
bazelisk run //scripts:github-auth -- check https://github.com/toxicoder/evo-t1-coder-stack.git
```

- SELF mode applies when `CODER_WORKSPACE_ID` is set **or** `EVO_T1_DEVCONTAINER=1` is. The
  container sets the latter; a Coder workspace sets the former.
- SELF means no docker at all and no `DOCKER_HOST`: one probe of this environment's own
  credential chain, printed as one `self:` line per credential. `docker` in here addresses
  the workstation daemon mounted in, never the stack host's workspace fleet.
- Pass only the repository URL. A named container argument is refused with a pointer to the
  host shell, because that container lives on a daemon this environment cannot enumerate.
- Credentials still arrive by the one supported path: Coder External Auth mints
  `GH_TOKEN`/`GITHUB_TOKEN`, and `--devcontainer` hands them to git through
  `gh auth setup-git`. There is no static token and no PAT in this repo's tooling.

## Running the gate here

The merge gate is the Linux image, so run it in the contributor container:

```bash
bazelisk test //:test-fast
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:validate
```

From a machine that is **not** inside the container, ask the image to run them instead of
installing the toolchain onto that machine:

```sh
bazelisk run //scripts:test-in-image --
```

That is the host ingress: it `docker run`s `evo-t1-dev:latest` as `--user root` and runs the
same suites CI runs, so a macOS laptop gets the Linux result without a Linux box. Build the
tag first with `bazelisk run //scripts:build-dev-image` if the daemon does not have it.

Native `bazelisk test` on macOS is a convenience, not a merge path. The suites run there,
but the BSD userland differs from the GNU one the image ships (`sed`, `date`, `find`,
`sort`), so a green Darwin run is not the run that gates the merge and a red one is not
proof of a defect. The container, or `test-in-image`, is the answer
[test-with-bazel.md](test-with-bazel.md) and [../branching.md](../branching.md) gate on.

## What CI does

`.github/workflows/ci.yml` builds `images/dev` with `docker buildx build` and the GitHub
Actions layer cache (`type=gha`), then `docker run`s that image and runs the checks inside
it: `//:test-fast`, `//:lint`, `//:validate`, and the `docs-site/` Node checks.

- No Actions `container:` key is involved. The job runs on a plain runner and reaches the
  toolchain through `docker run`, so what gates the merge is an image tag, not whatever the
  runner image happens to carry that week.
- The Bazel job no longer installs the pins onto the runner: the image already has them at
  the pinned versions.
- A pull request that does not touch `images/dev/**` replays the cached layers instead of
  rebuilding them, which is what keeps the gate's wall time flat.

The equivalent run on your own machine is the host ingress above, so a CI-only failure is
reproducible without a Linux box or a workflow rerun.

## Why this repo's own workspaces stay on `workspace`

`.devcontainer/contributor-env` is a sentinel, not a config file. It is tracked in this
repository, and `probe_repo` (in `scripts/lib/workspace.sh`) treats a clone that tracks it
as a **miss** — exit `3` — even when the same clone also tracks
`.devcontainer/devcontainer.json`.

```sh
bazelisk run //scripts:new-workspace -- --dry-run https://github.com/toxicoder/evo-t1-coder-stack.git
```

- The sentinel outranks every other signal, so `new-workspace` answers `workspace` for this
  repo and a Coder workspace of it never builds the contributor container on its DinD
  sidecar.
- That container is the *laptop and CI* environment: it mounts the host docker socket and
  assumes a workstation daemon, neither of which belongs inside a workspace's nested dev
  container.
- Do not copy the sentinel into another repository. An application repo's
  `.devcontainer/` is exactly what `new-workspace` is supposed to find, and the sentinel in
  front of it silently downgrades that workspace to the plain template.

## What this is not

- **Not the stack host.** The compose host (gmktec) is bootstrapped with
  `bash scripts/setup-host.sh`, and it cannot be this container: it owns the daemon that
  runs Coder, LiteLLM, Ollama, Kasm, Homepage and Hermes. See
  [../project-conventions.md](../project-conventions.md) for the ingress rule that keeps
  that script the single documented `bash scripts/…`.
- **Not a template change.** `templates/workspace/startup.sh.tftpl` and
  `templates/devcontainer/startup.sh.tftpl` are untouched by any of this; the contributor
  seed reads them as payloads, it does not rewrite the twins.
- **Not a second toolchain.** Nothing in the contributor path installs pins onto a laptop
  or a runner — that is what the image is for.
- **Not a credential store.** GitHub auth stays Coder External Auth; no static token and no
  PAT appears in any file this page describes.

When the container itself is the suspect, `bazelisk run //:validate` from inside it is the
fastest answer, and [../troubleshooting.md](../troubleshooting.md) covers the stack-side
failures it rules in or out.
