---
title: Building with Bazel
description: Bazelisk as the ingress for tests, lint and the operator CLIs, and what the runfiles layout means for a script you just added.
tags: [bazel, build, contributing]
---

**What's on this page**

- Stack-host bootstrap: the one script run straight from a shell
- The contributor path — the dev container, or `test-in-image` — and where it fits
- The daily commands, and the Makefile shim over them
- What Bazel brings over running the scripts directly
- Script targets, runfiles, and why a new `scripts/*.sh` is a target automatically

**What this enables**

- Running any operator CLI from a foreign working directory with pinned inputs
- Adding a script without editing a BUILD file
- Getting the same Bazel, Bats, shellcheck and Terraform that CI uses without installing
  any of them

Bazelisk is how this repo runs tests, lint, and the operator CLIs. The Makefile targets call
the same commands. [test-with-bazel.md](test-with-bazel.md) covers the Bats harness;
[../branching.md](../branching.md) the branch rules that CI guards;
[devcontainer.md](devcontainer.md) the container that carries the toolchain.

## The contributor path

The toolchain Bazel drives comes from one Linux golden image, `images/dev/Dockerfile`, and
the contributor path is that image rather than a set of tools installed on your machine:

- Open the checkout in the contributor dev container (`.devcontainer/devcontainer.json`
  builds it) and run the commands below unchanged.
- Or, from a machine that is not in that container, `bazelisk run //scripts:test-in-image --`
  docker-runs `evo-t1-dev:latest` and runs the gate inside it.

Both give you the GNU userland the gate runs on, which a macOS laptop cannot promise
natively. Neither replaces the bootstrap below — that one is for the stack host.

## Stack-host bootstrap

`scripts/setup-host.sh` is the only script run straight from a shell, and it is the
**stack host's** bootstrap: the box that runs Coder, LiteLLM, Ollama, Kasm, Homepage and
Hermes, where Compose and Bazel have to live on the host itself. It installs what Bazel
needs (Bazelisk, shellcheck, shfmt, buildifier, Terraform), so it necessarily runs before
Bazel exists — that is its whole exemption, not a convenience:

```sh
bash scripts/setup-host.sh          # repair leftovers and Linux DNS, then install
bash scripts/setup-host.sh --check  # report tools, leftover runfiles and DNS; write nothing
bash scripts/setup-host.sh --repair # recover leftover runfiles and Linux public DNS
```

`--repair` is the recovery when `bazelisk run //scripts:prod-stack` dies creating
the runfiles tree (`FileAccessException ... Permission denied` on
`homepage/assets/icons/evo-t1.svg`). Bazel never reaches the stack script, so the
repair has to live in this shell entry point. On Linux it also installs public
DNS so `github.com` still resolves when Tailscale MagicDNS is the only
nameserver (`Could not resolve host: github.com` after a compose `up`). `--check`
reports that lookup and writes nothing.

Everything else is a Bazel target, including every `scripts/*.sh`. CI repeats the gate from
a clean runner inside the same golden image: `.github/workflows/ci.yml` builds
`images/dev` with buildx and the Actions layer cache and docker-runs the two suites below in
it, so the bazel job does not install the pins onto the runner at all — the image already
carries them. The persistent cache on that path is the buildx GHA layer cache, so a pull
request that leaves `images/dev/**` alone replays the image layers.

## Daily commands

```bash
bazelisk test //:test-fast
bazelisk test //tests:bats_common_test
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:fix
bazelisk run //:validate
bazelisk run //scripts:test-in-image --               # the same gate, inside evo-t1-dev:latest
bazelisk run //scripts:dev-stack -- status            # dev stack (the default project)
bazelisk run //scripts:prod-stack -- status           # stable stack (default project evo-t1-prod)
bazelisk run //scripts:prod-stack -- status --project-name evo-t1-coder-stack   # hand-raised stack
```

| Target | What it runs |
| --- | --- |
| `//:test-fast` | One `sh_test` per `tests/bats/*.bats` file, plus the shell inventory and docstring gates |
| `//:lint` | ShellCheck, shfmt, buildifier (manual: host tools) |
| `//:validate` | test-fast, lint, `docker compose config -q`, `.env.sample` vs `.env.example`, terraform fmt when terraform is installed |
| `//:fix` | buildifier and shfmt write mode |
| `//scripts:<stem>` | One operator CLI: `bazelisk run //scripts:<stem> -- <args>`, e.g. `//scripts:dev-stack -- up`, `//scripts:new-workspace -- --dry-run <url>` |
| `//scripts:test-in-image` | The merge gate inside `evo-t1-dev:latest`, for a machine that is not the contributor container |
| `//scripts:seed-dev-env` | Materialize a contributor home (Grok config, editor settings, notes, tmux, helpers) from the workspace templates |

`make test`/`bats`/`lint`/`fix`/`validate` and the `stack-*`/`prod-stack-*` shims are the
same commands;
`make help` lists them. `//:test-fast` does not start Compose, pull models, or SSH to a Spark
box: the suites exercise those scripts against `tests/bats/tool_stubs`. `bazelisk run
//scripts:<stem> -- <args>` is how a human runs one of them for real.

Those operator runs are bounded: a script's non-interactive `docker exec` closes stdin
(`</dev/null`), and the docker wrappers go through `timeout(1)` with `--kill-after`, so a
`bazelisk run //scripts:<stem>` cannot sit forever the way `docker exec -i` did under
`bazelisk run`, waiting for an EOF that never came. `logs --follow` is the intentional
long-running exception, and you stop it with Ctrl-C.

## What Bazel brings

- **Hermetic sandbox.** `test --spawn_strategy=local,sandboxed` and `build
  --spawn_strategy=sandboxed`: an action sees its declared inputs and its runfiles tree, not
  the whole checkout. That is why a suite declares its stubs and payload files as `data` and
  why a script resolves its repo root with `resolve_checkout` (`scripts/lib/common.sh`) instead of
  trusting the cwd.
- **Action cache.** An action's outputs are keyed on its inputs and command line, so an
  unchanged suite replays its cached PASS instead of re-running Bats.
- **Local disk and repository cache.** `.bazelrc` points `--disk_cache` at
  `~/.cache/bazel-disk` and `--repository_cache` at `~/.cache/bazel-repo`. A contributor
  container and a Coder workspace reuse those directories across runs. CI docker-runs the
  gate with `HOME=/tmp` and `USER=$(id -un)`, so those Bazel caches are per-job and Bazel
  can name a uid the image passwd file does not list; the cache that survives there is
  the image's buildx GHA cache. No remote cache is configured — the same two flags
  would take a `--remote_cache=<uri>` endpoint later.

## Script targets and runfiles

`scripts/BUILD.bazel` declares one `exec_shell` launcher plus one `sh_binary` wrapper per
`scripts/*.sh`, generated from the directory, so a new CLI is a Bazel target without a second
edit there. `//:validate` is an alias for `//scripts:validate`; `//:fix` keeps the same
launcher pattern at the repo root.

`rules_shell` only symlinks an `sh_test` or `sh_binary` source when that file is executable.
`//tools:exec_shell.bzl` writes a generated launcher and runs the real `.sh` from runfiles
with bash, so a checkout whose scripts are mode `100644` still builds.

Each CLI target also declares the repo files that script reads by path: the libs it
sources (`_SCRIPT_LIBS`) and the payload groups whose files it opens (`_SCRIPT_PAYLOAD`),
both keyed by script stem in `scripts/BUILD.bazel`. Those payload groups live one per
payload directory (`//litellm:config`, `//searxng:settings`, `//homepage:config`,
`//homepage:icons`, `//hermes:seed`, `//hermes:skills`, `//proxy:confs`,
`//images/dev:dockerfile`, `//images/dev:tool_versions`, and a `:payload` in each of
`templates/common`, `templates/workspace`, `templates/devcontainer`), with the root
BUILD.bazel holding the groups that have no directory of their own (`//:compose_file`,
`//:env_sample`, `//:env_example`, `//:license`, `//:devcontainer`, `//:githooks`, and the
`//:ci_*` groups). `//:stack_data` is the explicit aggregate of all of them, and
`//scripts:doc_sources` (every `scripts/**.sh`, so a sourced `scripts/lib/*.sh` resolves
too) rides along on every CLI. `proxy/certs/` is `.bazelignored` (bootstrap issues those on the host), so a
`bazelisk run` of a stack runner, of `push-template`, or of the six CLIs that read a file the
checkout alone holds (`dashboard-password`, `pull-models`, `coder-agents`, `spark-verify`,
`spark-configure`, `build-dev-image`) prefers `BUILD_WORKSPACE_DIRECTORY` (the real checkout)
over the runfiles copy as the compose project directory, the live `.env`, and the template tree (runfiles
`templates/**` are symlinks that Coder cannot follow after unpack). Without the committed payloads a
sandboxed run would read a partial copy of the repo and fail for the wrong reason. A new
top-level payload directory gets its own package with its own `filegroup` targets, joins
`//:stack_data` by label, and is named in the map of every target that reads it: `test-fast`
and `lint` only see repo files that travel in runfiles, so an unlisted directory is invisible
to the harness rather than checked loosely.

## The dependency maps and their gate

The two maps in `scripts/BUILD.bazel` and the one in `tests/BUILD.bazel` are the
machine-readable record of which repo file each target reads:

| Map | Says |
| --- | --- |
| `_SCRIPT_LIBS` | the `scripts/lib` closure one CLI sources, executes, or ships to a remote host |
| `_SCRIPT_PAYLOAD` | the payload groups whose files that CLI (or a lib it sources) opens |
| `_SUITE_PAYLOAD` | the payload groups one Bats suite opens, beyond what every suite carries |
| `*_PAYLOAD_ALLOW` | a pairing the source scan cannot see from either side; each entry states its reason |

`tests/bazel_deps.py` re-derives all of them by scanning the shell and Bats sources and
reports the drift both ways: a script that starts reading a payload its target does not
declare, and a target that still ships a payload nothing opens. `//tests:bats_bazel_deps_test`
runs it, so the BUILD files stay something an automated reader can trust, and a
`bazelisk query` of any target names the files a change to which should be reviewed with it.

The scan treats a comment, a here-doc body, a log message, and a scratch file a suite writes
as prose rather than a dependency, so the maps record reads and not mentions. When the scan
genuinely cannot see a pairing (a lib that builds a path and returns it as a string, a
`case` glob over `git diff` output, help text), the entry goes in the `_ALLOW` map with the
reason as a comment above the key; the Bats gate fails an `_ALLOW` key that has no reason.

A script that needs the checkout reaches it the same way: source its libs by absolute path from
`SELF_DIR`, resolve the root with `resolve_checkout` (`scripts/lib/common.sh`), then `cd` into
what it prints. Never `cd "$(dirname "$0")/.."` - under `bazelisk run` the launcher execs the
runfiles copy of the script, so that is the runfiles tree, which holds only `//:stack_data` and is
recreated on the next build.
