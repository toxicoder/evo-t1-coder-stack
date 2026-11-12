---
title: Contributor environment
description: "The one Linux golden image behind laptop work, the Coder workspaces and CI: what the contributor dev container builds, how it caches, how it seeds itself, and which path is the merge gate."
tags: [contributing, devcontainer, bazel, ci, docker]
---

# Contributor environment

**What's on this page**

- The single golden image, and the file that pins it
- Opening the repo as a contributor container in VS Code or a compatible editor
- The cache seam: the mounted volumes, the `~/.bazelrc` block, and when to drop them
- The background warm-up, and the one knob that turns it off
- What `seed-dev-env` materializes into that home, and what it refuses to touch
- GitHub auth inside the container, and why `github-auth check` runs SELF there
- The merge gate (Linux image) versus the convenience path (native Darwin)
- What CI does, and why this repo's own Coder workspaces stay on `workspace`
- Keeping the container maintained as the project moves

**What this enables**

- Reproducing CI's failure on your own machine with the same image CI runs
- Running the Bazel gate on macOS without maintaining a second, BSD-flavoured toolchain
- Recreating the container without paying for a cold Bazel cache again
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
| `build.cacheFrom` | `ghcr.io/toxicoder/evo-t1-coder-stack/evo-t1-dev:latest` | Seeds BuildKit's layer cache from the image CI publishes on every merge to `main`, so a fresh clone pulls finished layers. An unreachable registry is a buildx warning, not a failed build. |
| `remoteUser` | `coder` | uid/gid 1000, bash as its login shell — the user the Coder agent runs as. |
| `updateRemoteUserUID` | `true` | The container's `coder` uid matches the host user's, so the bind-mounted checkout stays writable without a `chmod` dance. |
| `containerEnv` / `remoteEnv` | `EVO_T1_DEVCONTAINER=1` | The marker that says *contributor container*, not Coder workspace. Also carries `SEARXNG_URL`, `EVO_T1_BAZEL_CACHE_ROOT`, and the `BAZELISK_HOME` / `NPM_CONFIG_CACHE` / `UV_CACHE_DIR` / `PIP_CACHE_DIR` download dirs. |
| `mounts` | `/var/run/docker.sock` + four named volumes | The socket is the workstation's own daemon, which is how a `docker run` inside it is a real one. The volumes are Bazel's disk, repository and output caches plus the package-manager download cache; see [The cache seam](#the-cache-seam). |
| `runArgs` | `--add-host=host.docker.internal:host-gateway`, `--ulimit nofile=1048576` | Reaches LiteLLM on `:4000` and SearXNG on `:8181` on the laptop; the Bazel sandbox and the Next dev server both want more than Docker's 1024 default. |
| `forwardPorts` | `3000` | `bazelisk run //docs-site:dev` serves the docs site there. |
| `hostRequirements` | 4 cpus, 8 GB, 32 GB | Advisory floor for the gate and a Next build (the devcontainer CLI and Codespaces enforce it, an editor warns). |
| `postCreateCommand` | `bash .devcontainer/library-scripts/configure.sh create` | One idempotent script: the cache seam, the seed, the git hooks, the socket ACL, then the background warm-up. |
| `postStartCommand` | `bash .devcontainer/library-scripts/configure.sh start` | Runs on every start, not just the first: cheap checks, the socket ACL again (host-side perms change), and a warm-up a previous start skipped. |
| `customizations.vscode.extensions` | Bazel, shellcheck, shell-format, Terraform, Docker, YAML, Python, Ruff, Go, Tailwind, Even Better TOML | shellcheck and shfmt are the two `//:lint` runners, wired into the editor beside the Terraform, Docker, YAML, Python, Go and Tailwind helpers the tree actually holds. |

`customizations.vscode.settings` carries container-scoped settings only: the
formatter and linter paths and flags, the `bazel-*` and `node_modules` watcher
excludes, and `git.branchProtection` for `main`. Editor taste (theme, minimap,
word wrap) still arrives from `seed-dev-env.sh` through
`~/.shared/vscode/settings.json`, so the two never fight.

Nothing in this table belongs in the image. `images/dev/Dockerfile` is shared with
the Coder workspaces and the CI gate, so it carries the toolchain and stays
unaware that a contributor container exists; everything above is container shape,
read from the checkout on every start. That is what makes the whole thing editable
without a rebuild.

## The cache seam

`.bazelrc` points `--disk_cache` and `--repository_cache` at `~/.cache`, and Bazel's
output base lives under `~/.cache/bazel` as well. Inside a container `$HOME` is the
image's own filesystem, so all three die with the container, and a recreation - which
is what every edit to this config or the Dockerfile causes - repays the whole cost:
re-fetch every external archive, re-analyze the graph, re-run every action.

The config mounts three named volumes under `/var/cache/evo-t1-bazel`, and
`.devcontainer/library-scripts/configure.sh` writes this block into `~/.bazelrc`:

```text
# BEGIN evo-t1 contributor dev container (managed by .devcontainer/library-scripts/configure.sh)
common --disk_cache=/var/cache/evo-t1-bazel/disk
common --repository_cache=/var/cache/evo-t1-bazel/repo
startup --output_user_root=/var/cache/evo-t1-bazel/root
# END evo-t1 contributor dev container
```

`~/.bazelrc` is the seam because Bazel reads it after the repo's `.bazelrc`, and
because it reaches only this container: a Coder workspace booted from the same image
keeps using its own `~/.cache`. Everything outside the two marker lines belongs to
the developer and survives every run, and a re-run replaces the block rather than
stacking a second one. `EVO_T1_BAZEL_CACHE_ROOT` is the one value both halves read,
so the mount targets and the block move together, and
`bazelisk test //tests:bats_contributor_devcontainer_test` fails if they drift.

Docker creates a named volume once and reuses it, so the caches survive recreations
until you deliberately drop them:

```sh
docker volume ls --filter name=evo-t1-dev-
docker volume rm evo-t1-dev-bazel-disk evo-t1-dev-bazel-repo evo-t1-dev-bazel-root evo-t1-dev-toolcache
```

Drop them when a Bazel upgrade or a corrupt action cache is the suspect, not as
routine cleanup - deleting them costs one cold gate run each.

## The warm-up

`configure.sh` finishes by starting `library-scripts/warmup.sh` detached (`setsid`, so
the Dev Containers CLI's teardown of the postCreate process group does not take it
with it). It runs `bazelisk test //:test-fast` and then `bazelisk run
//docs-site:install`, which is where a cold container actually spends its time: the
Bazelisk download, every `MODULE.bazel` fetch, and the site's `npm ci`. The editor is
usable the whole time; the first real gate run then reads a warm cache.

```sh
tail -f /tmp/evo-t1-warmup.log
cat /tmp/evo-t1-warmup.status      # running | ok | failed: <step>
export EVO_T1_WARMUP=off           # in the host shell, before Reopen in Container
```

`EVO_T1_WARMUP=off` is the only knob. It reaches the container through
`containerEnv`'s `${localEnv:EVO_T1_WARMUP}`, so a laptop can opt out permanently from
its own shell profile without editing the config, and an unset value keeps the default.
A skipped or failed warm-up costs a slow first command and nothing else: every gate
still runs, and `//:lint` does not depend on it.

## Keeping it maintained

The container is code in this repository, and it rots the same way a lockfile does.
These are the moments that oblige a contributor to touch it, and each has a gate:

| Change in the project | What the container owes it |
| --- | --- |
| A pin moves or is added in `images/dev/tool-versions.env` | The matching `ARG` in `images/dev/Dockerfile`, or `bazelisk run //scripts:build-dev-image` refuses the build. `build.cacheFrom` keeps the rebuild cheap. |
| A gate gains a tool (`//:lint`, `//:validate`, a coverage target) | The tool belongs in the image and its pins in `tool-versions.env`; a container-only convenience belongs in `configure.sh`, never in the image. |
| A new language or lint runner appears | The extension and its formatter path and flags in `customizations.vscode`, set to the exact binary and flags the gate runs, so save-time formatting cannot fight `//:lint`. |
| A new top-level payload directory of shell | `lints/run_shellcheck.sh`, `lints/run_shfmt.sh` and `fix.sh` scan sets, plus the matching entry in `lints/BUILD.bazel`. `.devcontainer` joined all three; a fourth directory is a one-line change to each. |
| A new contributor-facing env var | `containerEnv` (and `remoteEnv` when a VS Code terminal or task must see it), never a shell profile the image writes. |
| A new cache worth keeping across recreations | A named volume in `mounts`, a download-cache env var pointed inside it, and the path asserted in the Bats suite. |

`.devcontainer/library-scripts/*.sh` is first-party shell: it carries
`# @function` blocks, is linted by `//:lint` (shellcheck `-x --severity=warning`, shfmt
`-s -i 2 -ci`), and its behaviour is pinned by
`bazelisk test //tests:bats_contributor_devcontainer_test`. That suite reads
`devcontainer.json` as data, so renaming a mount target, dropping the
`EVO_T1_DEVCONTAINER` marker from one env layer, or pointing the build at something
other than `images/dev` is a failing test rather than a surprise on someone's laptop.

## Seeding the contributor home

`scripts/seed-dev-env.sh` materializes, into a laptop or CI home, the same stack-owned
files a Coder workspace writes at startup — from the same template payloads, with no
Terraform and no docker. The contributor container runs it for you: `postCreateCommand`
calls `configure.sh create`, which calls this script with `--devcontainer --context7-mcp`
and nothing else, so a rebuilt container re-materializes every stack-marked file from the
current seed and leaves anything you own alone. Everything below is what that one call
does, and what to re-run by hand after a seed change:

```sh
bazelisk run //scripts:seed-dev-env -- --dry-run --home /tmp/contributor-home
bazelisk run //scripts:seed-dev-env -- --home "${HOME}"
bazelisk run //scripts:seed-dev-env -- --litellm-url http://host.docker.internal:14000/v1
bazelisk run //scripts:seed-dev-env -- --devcontainer --context7-mcp
```

| Flag | Effect |
| --- | --- |
| `--home <dir>` | Home tree to shape (default `$HOME`; created when absent; an existing non-directory is an error). |
| `--litellm-url <url>` | Model-transport address rendered into `settings.json` and `~/.grok/config.toml` (default `http://host.docker.internal:4000/v1`). |
| `--context7-mcp` | Keep the `[mcp_servers.context7]` docs lane in the rendered `~/.grok/config.toml` even with no `CONTEXT7_API_KEY` in the environment. Without it a keyless home renders the context7-free file, so the contributor has no docs lane while their workspaces do. The key is optional: with no value the server sends no `Authorization` header, still handshakes, and answers at the public rate limit (private libraries are the only thing out of reach), so a missing block is the defect this flag prevents, not a key problem. |
| `--devcontainer` | After a successful write, run `gh auth setup-git` when `GH_TOKEN`/`GITHUB_TOKEN` is set and `gh` is on PATH. Best effort, and the token is never an argument. |
| `--force` | Re-materialize files a user owns. |
| `--dry-run` | Print the plan; write nothing, create no directory, call no `gh`. |

The two research lanes that config can render are split by question type: a library,
framework, CLI or setup question goes to `context7` (resolve the library id first, then
query docs on that id), anything else on the web goes to the `searxng` `search` tool,
and a URL already in hand goes to `searxng`'s `fetch_content` - Grok's native
`web_search` is parked here and native `web_fetch` needs an egress proxy endpoint this
stack does not run, so neither is a lane. Prove what this home declares with:

```sh
bazelisk run //scripts:mcp-check -- --lanes context7 --config /tmp/contributor-home/.grok/config.toml
```

A missing `[mcp_servers.context7]` block in that file means the seed ran keyless and
without `--context7-mcp`: re-run the seeder with the flag, adding `--force` when the
existing file carries no stack marker and the seeder left it alone. On a Coder
workspace the same repair runs from the stack host:
`bazelisk run //scripts:refresh-configs -- --container coder-<owner>-<ws>`.

What it writes: `~/.tmux.conf`, the shared `~/.shared/vscode/settings.json` (with the
code-server and desktop VS Code User settings symlinked to it), `~/.grok/AGENTS.md`,
`~/.coder/AGENTS.md`, the rendered `~/.grok/config.toml`, the two terminal helpers in
`~/.grok/bin`, `~/.grok/notes-setup.sh` plus this clone's `notes.md`, and the
`~/.grok/bin` line in `~/.bashrc`.

That `notes.md` is `notes_materialize` from the same library: it restores the canonical copy
under `~/.grok/notes/<host>/<owner>/<repo>/` over a live file that is empty or still the
seeded stub, and copies a real live file back there, so a stub never walks over written
notes. Here that runs once, at seed time - the background watcher that repeats the back-copy
about every 30 seconds is a workspace-startup thing (`NOTES_SYNC_INTERVAL`; see
[../grok-build-and-agents.md](../grok-build-and-agents.md#what-is-shared)) - so re-run the
seeder to push a fresh edit to the canonical copy in this container.

Two rules decide every write, and they are the same rules the workspace startup applies:

- A file carrying the stack marker - the `managed-by: evo-t1-coder-stack` comment, the
  `"__evoT1Stack": true` JSON key, or the `__evoT1Stack = true` TOML key - is
  stack-owned and is reseeded when the seed in this repo drifted. Taking
  `~/.grok/config.toml` over means deleting both its marker lines, since the Grok CLI
  deletes comments when it rewrites that file:
  [../grok-build-and-agents.md](../grok-build-and-agents.md#the-rendered-grok-config).
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
- Credentials still arrive by the one supported path: Coder External Auth mints them, and
  the gh auth store is what git actually reads. That store is the target because
  `GH_TOKEN`/`GITHUB_TOKEN` are the copy injected when the container started and expire
  about an hour later, and the plain `!gh auth git-credential` helper echoes that pair, so
  git would keep sending a dead token. The helper this stack installs clears the pair first,
  which is why `gh auth setup-git` alone is not enough. There is no static token and no PAT
  in this repo's tooling.
- `push would FAIL` from the check above means one command:
  `bazelisk run //scripts:github-auth -- fix https://github.com/toxicoder/evo-t1-coder-stack.git`.
  It mints a live token, writes the store, installs that helper, and re-proves the verdict.
  For `gh` itself, prefix `env -u GH_TOKEN -u GITHUB_TOKEN`: no process can rewrite another
  process's environment.

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

That is the host ingress: it `docker run`s `evo-t1-dev:latest` as this process's uid:gid
(`$(id -u):$(id -g)`), with `HOME=/tmp` and `USER=$(id -un)` so Bazel has a writable home
and a name for a uid the image passwd file does not list, and runs the same suites CI
runs. A macOS laptop gets the Linux result without a Linux box. Build the tag first with
`bazelisk run //scripts:build-dev-image` if the daemon does not have it.

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
  toolchain through `docker run --user "$(id -u):$(id -g)"` with `HOME=/tmp` and
  `USER=$(id -un)`, so what gates the merge is an image tag, the bind-mounted checkout
  stays writable, permission tests see a non-root identity, and Bazel can name a uid the
  image passwd file does not list.
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
- **Not a place for contributor-only behavior in the image.** The image is shared with Coder
  workspaces and CI, so anything that only a person at a keyboard wants (the Bazel volume
  seam, the warm-up, the git hooks, the socket ACL) lives in
  `.devcontainer/library-scripts/configure.sh`, which only this container runs. An `ENV` or
  `RUN` line added to `images/dev/Dockerfile` for the same purpose changes what a workspace
  gets, which is the mistake this split exists to prevent.
- **Not a credential store.** GitHub auth stays Coder External Auth; no static token and no
  PAT appears in any file this page describes.

When the container itself is the suspect, `bazelisk run //:validate` from inside it is the
fastest answer, and [../troubleshooting.md](../troubleshooting.md) covers the stack-side
failures it rules in or out.
