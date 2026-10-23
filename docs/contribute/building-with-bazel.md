# Building with Bazel

Bazelisk is how this repo runs tests, lint, and the operator CLIs. The Makefile targets call
the same commands. [test-with-bazel.md](test-with-bazel.md) covers the Bats harness;
[../branching.md](../branching.md) the branch rules that CI guards.

## Host bootstrap

`scripts/setup-host.sh` is the only script run straight from a shell. It installs what Bazel
needs (Bazelisk, shellcheck, shfmt, buildifier, Terraform), so it necessarily runs before
Bazel exists — that is its whole exemption, not a convenience:

```sh
bash scripts/setup-host.sh          # repair leftovers, then install what is missing
bash scripts/setup-host.sh --check  # report tools, leftover runfiles and DNS; write nothing
bash scripts/setup-host.sh --repair # recover leftover runfiles so bazelisk run can start
```

`--repair` is the recovery when `bazelisk run //scripts:prod-stack` dies creating
the runfiles tree (`FileAccessException ... Permission denied` on
`homepage/assets/icons/evo-t1.svg`). Bazel never reaches the stack script, so the
repair has to live in this shell entry point. `--check` also reports whether
`github.com` resolves (Tailscale MagicDNS as the only nameserver is the usual
cause of `Could not resolve host: github.com` after a compose `up`).

Everything else is a Bazel target, including every `scripts/*.sh`. CI repeats both halves
from a clean runner: the composite action `.github/actions/setup-bazel` installs the same host
tools through `.github/scripts/install-lint-tools.sh`, and the workflow then runs the two
suites below.

## Daily commands

```bash
bazelisk test //:test-fast
bazelisk test //tests:bats_common_test
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:fix
bazelisk run //:validate
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

`make test`/`bats`/`lint`/`fix`/`validate` and the `stack-*`/`prod-stack-*` shims are the
same commands;
`make help` lists them. `//:test-fast` does not start Compose, pull models, or SSH to a Spark
box: the suites exercise those scripts against `tests/bats/tool_stubs`. `bazelisk run
//scripts:<stem> -- <args>` is how a human runs one of them for real.

## What Bazel brings

- **Hermetic sandbox.** `test --spawn_strategy=local,sandboxed` and `build
  --spawn_strategy=sandboxed`: an action sees its declared inputs and its runfiles tree, not
  the whole checkout. That is why a suite declares its stubs and payload files as `data` and
  why a script probes for its repo root instead of trusting the cwd.
- **Action cache.** An action's outputs are keyed on its inputs and command line, so an
  unchanged suite replays its cached PASS instead of re-running Bats.
- **Local disk and repository cache.** `.bazelrc` points `--disk_cache` at
  `~/.cache/bazel-disk` and `--repository_cache` at `~/.cache/bazel-repo`; CI restores and
  saves both through `actions/cache` (`.github/actions/setup-bazel`). No remote cache is
  configured — the same two flags would take a `--remote_cache=<uri>` endpoint later.

## Script targets and runfiles

`scripts/BUILD.bazel` declares one `exec_shell` launcher plus one `sh_binary` wrapper per
`scripts/*.sh`, generated from the directory, so a new CLI is a Bazel target without a second
edit there. `//:validate` is an alias for `//scripts:validate`; `//:fix` keeps the same
launcher pattern at the repo root.

`rules_shell` only symlinks an `sh_test` or `sh_binary` source when that file is executable.
`//tools:exec_shell.bzl` writes a generated launcher and runs the real `.sh` from runfiles
with bash, so a checkout whose scripts are mode `100644` still builds.

Each CLI target also declares the repo files that script reads by path — `//:stack_data`
(`docker-compose.yml`, both `templates/**` payload trees, `images/dev/**`, `litellm/**`,
`searxng/**`, `homepage/**`, `proxy/**`, the two `.env` samples, `LICENSE`) and
`//scripts:doc_sources` (every `scripts/**.sh`, so a sourced `scripts/lib/*.sh` resolves
too). `proxy/certs/` is `.bazelignored` (bootstrap issues those on the host), so a
`bazelisk run` of a stack runner or of `push-template` prefers `BUILD_WORKSPACE_DIRECTORY` — the real checkout —
over the runfiles copy as the compose project directory, the live `.env`, and the template tree (runfiles
`templates/**` are symlinks that Coder cannot follow after unpack). Without the committed payloads a
sandboxed run would read a partial copy of the repo and fail for the wrong reason. A new
top-level payload directory has to be added to that `glob` by hand: `test-fast` and `lint`
only see repo files that travel in runfiles, so an unlisted directory is invisible to the
harness rather than checked loosely.
