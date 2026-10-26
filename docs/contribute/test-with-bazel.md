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

## Measured coverage

Three targets answer "is this code actually executed by a test" instead of
assuming it. They are `manual` like the npm gates, so `//:test-fast` stays fast, and
they are members of `//:test-all`, which pre-push and CI run:

```bash
bazelisk test //tests:shell_coverage      # every production shell function ran?
bazelisk test //tests:py_coverage         # every Python statement and branch?
bazelisk test //docs-site:unit_coverage   # every docs-site function, >=95% lines?
```

`//tests:shell_coverage` is the one to understand before you write a shell test.
It builds a mirror of the checkout with `tests/coverage/instrument.py`: every
production `.sh` is copied with one extra statement at the top of each function
body that appends `<path>\t<function>` to `$EVO_COV_LEDGER`, and every other path
stays a symlink into the real tree. `tests/bats_runner.sh` points `REPO_ROOT` at
that mirror when `EVO_COV_MIRROR` is set, so the suites execute the instrumented
copies through whichever access pattern they already use — run the CLI, source the
lib, or `load_shell_function`. Then `tests/coverage/aggregate.py` names every
function whose body never ran.

Why a ledger and not `bash -x`: xtrace traces bats-core itself, wrote 3.4 GB of log
for one suite, and leaked trace lines into the stderr bats captures per test, which
turned output-asserting suites red. The ledger measures the narrower thing the gate
asks and breaks nothing.

The consequence for a test author: a function counts when something calls it. A
name in a comment, a stub, a fixture or a quoted grep pattern satisfies
`//tests:shell_inventory` and satisfies nothing here.

`//tests:py_coverage` discovers `tests/python/test_*.py` and
`docs-site/test_gen_nav.py` under coverage.py 7.17, pinned in
`images/dev/tool-versions.env` and baked into the golden image; without it the
target fails with a pointer to `//scripts:test-in-image` rather than passing while
measuring nothing. `//docs-site:unit_coverage` is `npm run unit:coverage`
(vitest v8 provider, thresholds in `docs-site/vitest.config.ts`).

Two runfiles traps bit this gate, and both fail *silently*, so they are worth
naming:

- Under `bazelisk test` every source arrives as a **symlink**. A `find -type f`
  over the tree then sees no regular file and reports an empty suite, which reads
  as "nothing to test". `py_cov.sh` uses `find -L`.
- coverage.py resolves the symlink and records the **checkout** path, while the
  process cwd is the runfiles tree. A relative `--include=scripts/lib/*.py` is
  matched against the cwd, matches nothing, prints `No data to report`, and exits
  `0`. The gate therefore decides from `tests/coverage/py_report.py`, which lists
  the `.py` files the tree ships and requires each one to appear in the machine-
  readable report above the floor. A module nobody imported is a named failure.

The same "empty looks like green" rule applies to the vitest gate: it must measure
files no test imported. Vitest 4 made that the default and removed the `all` key
from `CoverageOptions`. To prove the default still holds after a vitest bump, drop
a `lib/__cov_probe.ts` exporting one uncalled function and confirm the run reports
it at 0% and fails; then delete the file.

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
proof fails. `resolve_checkout` in `scripts/lib/common.sh` is that resolver and every CLI that
reads a file the checkout alone holds calls it, so do not write a second one. It takes the calling
script's own directory as its last candidate and the marker to probe for (`docker-compose.yml` by
default); the call site in every one of those CLIs is this:

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
ROOT_DIR="$(resolve_checkout "${SELF_DIR}")" || exit 5
cd "${ROOT_DIR}"
```

It tries `${REPO_ROOT:-}`, then `${BUILD_WORKSPACE_DIRECTORY:-}`, then `${GITHUB_WORKSPACE:-}`,
then `${PWD}`, then `${SELF_DIR}/..`, and prints the first candidate that proves out.

- The `${REPO_ROOT:-}` / `${GITHUB_WORKSPACE:-}` default is not decoration: these scripts run
  under `set -euo pipefail`, and a bare `${REPO_ROOT?}` aborts with `REPO_ROOT: parameter not
  set` the moment a sandbox or CI runner leaves the variable unset.
- The file probe (`-f "${candidate}/${marker}"`) says "this is a repo root"; refusing a derived
  candidate whose `pwd -P` lands under `bazel-out/`, `bazel-bin/`, `execroot/`, or a
  `*.runfiles` tree says "and it is the real checkout, not a copy", because runfiles carries its
  own copy of the marker. Two probes, because either one alone passes in the wrong case: writing a
  rotated `.env` or a `sparks/<host>.env` through the runfiles copy reports success while the
  checkout keeps the old bytes. An explicit `${REPO_ROOT}` is exempt from the second probe — it is
  a statement about where to work, and this harness points it at the copy of the repo under test.
- Exit `5` with one `unresolvable repo root` line beats guessing a cwd and half-running a
  fleet check against a copy of the repo.
