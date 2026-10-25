---
title: Testing with Bazel (the Bats harness)
description: "Hermetic Bats: how a suite is discovered, what the stub PATH gives you, and the two inventory gates a new function has to satisfy."
tags: [bats, tests, bazel, contributing]
---

**What's on this page**

- The layout: suites, helpers, stubs and fixtures
- The two inventory gates that tie a production function to a test
- Running one suite, from any directory
- Which runtime actually gates a merge, and which one is a convenience
- The stub-PATH recipe, and the two paths a suite may take
- Sandbox-safe repo-root probing

**What this enables**

- Adding a test that passes in the Bazel sandbox and on a laptop
- Making a new function satisfy `//tests:shell_inventory` without guessing
- Reproducing a CI failure locally by running the suites in the image CI runs them in

Every suite under `tests/` is hermetic Bats: it runs against stubs and a throwaway tree,
never against a daemon, a network, or the operator's real `.env`.

## Layout

- `tests/bats/*.bats` — one suite per module. `tests/bats.bzl` turns each file into one
  `bats_<stem>_test` sh_test (dashes become underscores: `bats_spark_configure_test` for
  `spark-configure.bats`) and adds it to the `bats` suite that `//:test-fast` runs.
- `tests/bats/test_helper.bash` — the shared helpers, pulled in with `load 'test_helper'`.
- `tests/test_helpers.sh` — the assertions, shared with the bash gates.
- `tests/bats/tool_stubs/` — the fake external tools (`docker`, `ssh`, `curl`, `git`,
  `coder`, `psql`, `timeout`, …); `tests/bats/fixtures/` holds a fixture that has to answer
  like the real client, such as the `psql-token` copies that echo `returning id`.
- `tests/bats_runner.sh` — what Bazel executes: it locates bats-core and this checkout in
  runfiles, exports `REPO_ROOT`, and execs bats.

## Two gates, one rule

`tests/shell_inventory.sh` fails when a function under `scripts/` is not named under
`tests/`; `tests/doc_coverage.sh` fails when a `# @function` block (or the file header) is
missing or incomplete. So every new function needs, in the same change as the function:

1. one asserting test in the **one** suite for its module — a `scripts/lib/<mod>.sh` helper
   belongs to `tests/bats/<mod>.bats`, and a helper that only an entry CLI defines belongs to
   `tests/bats/entry-fns.bats`, which loads single functions with `load_shell_function`;
2. the `# @function` block above the definition, with Globals/Arguments/Outputs/Returns.

Name it in exactly one suite. A chain test that happens to mention the name also satisfies
the inventory, but the owning suite is the one that asserts its behaviour.

The inventory strips comment lines before it looks for a name, so a name that only ever
appears in a `# @function` block or in prose is still untested: it has to sit in a code line
somewhere under `tests/`. The usual way to get one there is a unit case that calls the
helper directly:

```bash
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" split_list
  assert_eq "a phrase stays one entry" "a b c" "$(split_list 'a b c')"
```

## Running a suite

```bash
bazelisk test //:test-fast
bazelisk test //tests:bats_common_test
bazelisk test //tests:bats_workspace_test --test_output=all
bash tests/bats/workspace.bats                    # same suite, straight from a shell
```

A suite is one cached action. Its `.bats` file, `test_helper.bash`, `test_helpers.sh`,
`bats_runner.sh` and the `scripts/**.sh` plus stub/fixture files it declares as `data` are
its inputs, so editing one script re-runs only the suites that read it, and an unchanged
suite replays its cached PASS.

## Which runtime gates

The merge gate is the Linux golden image — the same `images/dev/Dockerfile` the Coder
workspaces boot and CI builds:

```bash
bazelisk test //:test-fast                                     # inside the contributor container
bazelisk run //scripts:test-in-image --                        # from any host with docker
```

- Inside the contributor dev container ([devcontainer.md](devcontainer.md)) the commands
  above are exactly what CI runs.
- On a host that is not that container, `//scripts:test-in-image` docker-runs
  `evo-t1-dev:latest` as this process's uid:gid, with `HOME=/tmp` and `USER` set so
  Bazel can name that uid, and runs them there.
- A native `bazelisk test` on macOS is convenience only: the BSD userland differs from the
  GNU one in the image (`sed`, `date`, `find`, `sort`), so a red run there is not proof of a
  defect and a green one is not the run that unlocks the merge button. CI and branch
  protection gate on the image result either way.

## The two paths a suite may use

- `REPO_ROOT` — where the checkout is *for this run*. `tests/bats_runner.sh` exports it;
  outside Bazel it is whatever `bats_canonical_repo_root` resolves. Derive it, never
  hardcode a machine path, and treat "cannot resolve" as a `skip`, not a failure.
- `BATS_TEST_TMPDIR` — per-test scratch, removed after each test. `make_scratch` prints a
  fresh directory under it; `fake_root`-style helpers build a throwaway checkout there.

## The stub-PATH recipe

Copy this shape; it is the convention every suite already uses (`use_stubs` prints nothing
and shadows PATH for the current test only, and fails when a stub is missing):

```bash
bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout curl git
}
```

- `stub_bin <tool…>` copies each stub out of `STUB_BIN_DIR` into `${BATS_TEST_TMPDIR}/bin`
  and `chmod 755`s it; `use_stubs` = `stub_bin` + a fresh `STUB_LOG` + the PATH shadow.
  The copy-plus-chmod is load-bearing: the Bazel sandbox and some tar extractions strip the
  exec bit, and a per-test copy keeps one test's argv log out of the next test.
- `with_path <dir…>` prepends directories to PATH when a test needs a hand-written fake
  instead of a shared stub.
- **Prepend; never replace PATH.** `use_stubs` and `with_path` put the stub directory *in
  front of* the host PATH. `PATH="${BIN}"` takes `bash`, `grep`, `cut`, `sort` and `wc` away
  from the script under test as well, and a script that pipes its answer through
  `grep | wc | tr` then fails for a reason that has nothing to do with the contract the
  suite means to check.
- **`run` keeps stdout in `$output`.** With `run --separate-stderr` there is no `$stdout`:
  `$output` is stdout and `$stderr` is stderr. An assertion written against `$stdout`
  compares against an empty string and fails, which is how a whole suite of real
  assertions can look like a broken harness.
- **`run` can call a helper, and a helper that `exit`s is safe.** `run` forks, so
  `run --separate-stderr usage_error '…'` followed by `[ "${status}" -eq 2 ]` works even
  though `usage_error` ends in `exit 2`. Pass a real command (`bash "${SCRIPT}" …`) when
  the script is what is under test.
- `stub_log <tool>`, `stub_log_last`, `stub_log_count` read back what the stub recorded from
  `$STUB_LOG/<tool>.log`; assert on the argv, not on prose.
- `real_bin <tool>` resolves a tool with the stub directory removed from PATH. That is the
  integration-tier gate: `if [ -z "$(real_bin terraform)" ]; then skip "terraform not
  installed"; fi` — a test that could talk to a real daemon skips when the tool is absent
  instead of failing.
- The `docker` stub passes `exec`/`compose exec` through by default (`STUB_DOCKER_EXEC_RUN=1`),
  so a binary the script execs inside a container lands on its own stub; set
  `STUB_DOCKER_EXEC_RUN=0` with `STUB_DOCKER_EXEC_RC`/`STUB_DOCKER_EXEC_OUT` for the
  "the daemon answered, and it said No" case.
- Assertions come from `tests/test_helpers.sh`: `fail`, `assert_eq`, `assert_match`,
  `assert_not_match`, `assert_file_exists`, `assert_file_not_exists`, `load_shell_function`.
  `load_shell_function` is the one harness place that expands a function body (it is how a
  single entry-CLI function gets unit-tested); production scripts still never use `eval`.

## Sandbox-safe: probe for the repo root, then say so

A script must work when the cwd is **not** the checkout. Under `bazel test` the working
directory is an exec root or a runfiles tree that holds *copies* of whatever the target
declares as `data`; under `bazel run` it is wherever the operator typed `bazelisk`, and
`bazel run` alone sets `BUILD_WORKSPACE_DIRECTORY`. Neither guarantees a working Docker
daemon, an `ssh`, or a reachable Spark box — a sandboxed action usually has none of them on
PATH.

So resolve the root from the environment first, then prove it, and fail loudly when the
proof fails:

```bash
find_repo_root() {
  local root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
  if [[ -n "${root}" && ! -f "${root}/docker-compose.yml" ]]; then
    root=""
  elif [[ -n "${root}" ]] && ! command -v docker >/dev/null 2>&1; then
    # A checkout that cannot have come from the host: no compose CLI means this is
    # the Bazel sandbox or some other copy of the repo, not a working stack host.
    root=""
  fi
  if [[ -z "${root}" ]]; then
    printf 'error: unresolvable repo root\n' >&2
    return 5
  fi
  printf '%s' "${root}"
}
```

- The `${REPO_ROOT:-}` / `${GITHUB_WORKSPACE:-}` default is not decoration: these scripts run
  under `set -euo pipefail`, and a bare `${REPO_ROOT?}` aborts with `REPO_ROOT: parameter not
  set` the moment a sandbox or CI runner leaves the variable unset.
- The file probe (`-f docker-compose.yml`) says "this is a repo root"; the `command -v` probe
  of a tool that cannot exist inside the sandbox says "and it is the real checkout, not a
  copy". Two probes, because either one alone passes in the wrong case.
- Exit `5` with one `unresolvable repo root` line beats guessing a cwd and half-running a
  fleet check against a copy of the repo.
