# Building with Bazel

Bazelisk is how this repo runs tests and lint. The Makefile targets call the same commands.

## Prerequisites

- Bazelisk, which reads `.bazelversion` (Bazel 8.4.1)
- shellcheck, shfmt, and buildifier for `//:lint`
- bats is vendored (bats-core 1.11.0) and is not a host dependency

## Daily commands

```bash
bazelisk test //:test-fast
bazelisk test //tests:bats_common_test
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:fix
bazelisk run //:validate
```

| Target | What it runs |
| --- | --- |
| `//:test-fast` | One `sh_test` per `tests/bats/*.bats` file, plus the shell inventory and docstring gates |
| `//:lint` | ShellCheck, shfmt, buildifier (manual: host tools) |
| `//:validate` | test-fast, lint, `docker compose config -q`, `.env.sample` vs `.env.example`, terraform fmt when terraform is installed |
| `//:fix` | buildifier and shfmt write mode |

`//:test-fast` does not start Compose, pull models, or SSH to a Spark box.

`rules_shell` only symlinks an `sh_test` or `sh_binary` source when that file is executable. `//tools:exec_shell.bzl` writes a generated launcher and runs the real `.sh` from runfiles with bash, so a checkout whose scripts are mode `100644` still builds.
