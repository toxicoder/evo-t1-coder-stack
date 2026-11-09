---
name: ez-bazel-first
description: "Make a repository fully Bazelisk-first: every tracked file owned by a build
  target under a machine-checked gate, explicit srcs instead of glob(), one umbrella target
  as the entry point, docs and command output rewritten to name targets, a host bootstrap
  path for the toolchain, then the gate driven to 100% test coverage. Use when asked to make
  a repo bazelisk-first or bazel-first, to prove full file coverage under Bazel rules, or to
  re-prove it after drift. Run as /ez-bazel-first [repo-path]."
when-to-use: "Use when the operator wants the whole repo behind Bazel targets with a check
  that proves no file is unclaimed, or when that gate needs re-proving after new files or
  directories landed."
argument-hint: "[repo-path] [--dry-run]"
compatibility: "Requires bazelisk, git. Uses bazel query, so a WORKSPACE or MODULE.bazel must exist."
metadata:
  author: "operator"
  short-description: "Prove and keep a repo fully Bazel-first"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["ez-bazel-first"]` under `[skills]`
     in `~/.grok/config.toml`. -->

# Bazel-first conversion

Five conditions define done. Everything below exists to prove them, in this order:

1. Every file `git ls-files` reports is either owned by a target or listed in an
   exclusion ledger with a reason.
2. Targets name what they read; a `glob()` survives only with a written policy and
   a budget that can only shrink.
3. One umbrella target runs the whole gate, and it is the only command anyone
   documents.
4. Docs, docstrings, comments, help text, and error strings name targets, never a
   script path.
5. Coverage targets run through that gate and report 100%.

Work the conditions in order. Step 2 is the definition of done, so wire it before
you migrate anything: it tells you the size of the job and stays red until the job
is finished.

Budget: about 40 to 60 of your own tool calls for a repo the size of a few hundred
files. If you pass 80 without Step 2 green, you are exploring instead of converting.

## Step 0 -- probe, then stop probing (5 calls, `run_terminal_command`)

Run these four and record the answers. Do not re-derive them later.

    cd <repo> && git rev-parse --show-toplevel && git ls-files | wc -l
    bazelisk --version
    bazelisk query '//...' --output=label_kind 2>&1 | head -40
    bazelisk query 'kind("source file", deps(//...))' --output=label 2>/dev/null | wc -l

Then find out what the repo already has before you build anything, because a
duplicate mechanism costs a whole phase:

    git ls-files | grep -Ei 'BUILD|\.bzl$|Makefile$|setup-host|bootstrap' | head -20
    git ls-files 'scripts/*' 'tools/*' | grep -iE 'map|invent|coverage|deps' | head

Look for an existing "which files are unclaimed" verb (here it is
`bazelisk run //scripts:bazel-map -- unlisted <dir>`). Use the repo's own when it
exists and wire it into the gate; reach for the shipped
`scripts/owned_files_check.py` only when nothing asks the question. A guessed target
label wastes a turn on `ERROR: no such target`; a query costs none.

## Step 1 -- bootstrap the host so the gate can be trusted

The toolchain usually ships as a golden image plus one shell-run bootstrap script.
Confirm it exists and is honest; `//:lint`-style gates commonly SKIP a missing linter
and go green having checked nothing.

    grep -n 'command -v\|check_tool\|REQUIRE_LINT_TOOLS\|CI' lints/*.sh scripts/*.sh 2>/dev/null | head -20

A bootstrap script must be idempotent, pinned by version, and have a `--check` mode
that prints what is missing without installing. Give the umbrella target a `doctor`
verb that reports the same facts. The rule that makes this worth having: a check that
silently skips locally must fail under `CI=true` or `REQUIRE_LINT_TOOLS=1`, and the CI
lane must install every tool the strict lane demands, including the ones that live in a
sub-project's package manager. Run it with `run_terminal_command` and quote the output.

## Step 2 -- prove file ownership, with a ledger for the honest exceptions

Start with the check, not the fix.

    python3 ~/.agents/skills/ez-bazel-first/scripts/owned_files_check.py --root <repo>

It maps labels to paths and reports `summary: N tracked | M target-owned | K
control-plane | L ledger-excluded (reasoned) | U unowned`. Mapping a label by
replacing every `:` with `/` is the classic bug: `//:file` becomes `/file`, and
almost every file looks unowned. The root package has no package directory, and that
is what `label_to_path` handles.

Then create `<repo>/bazel-unowned.txt`, one entry per deliberate exception:

    CONTRIBUTING.md    human-facing prose, read by nobody at build time
    Makefile           shim that forwards to //:targets
    .vscode/tasks.json editor convenience, no build meaning

Two rules keep the ledger from becoming the place files go to hide: an entry with no
reason is a failure, and `--strict-ledger` fails an entry that matches nothing, so a
deletion cannot leave a claim behind. Bazel's own control plane (`.bazelrc`,
`.bazelversion`, `MODULE.bazel`, every `BUILD.bazel`) is exempt in code, because no
rule can be its owner.

Register the check as a test target so drift fails a build rather than waiting for a
human. Follow the repo's own recipe for a new gate, which normally means: the rule in
the lints or tests package, the runner added to the runners filegroup, the suite added
to `//lints:all` or the aggregate suite, and any payload the runner reads added to
both the data filegroup and the manifest the dependency test pins. Omit the manifest
and the check passes while reading nothing.

## Step 3 -- make targets explicit, and ratchet the globs

    python3 ~/.agents/skills/ez-bazel-first/scripts/glob_budget.py --root <repo> --max <count>

Set `--max` to the count it reports, so the budget can only shrink. Every surviving
`glob(` needs `# glob-policy: <reason>` nearby. A glob is right when the directory is
the contract and new files are meant to be picked up silently, such as a payload tree
mounted into a container; a glob is wrong for sources, test suites, and anything whose
addition should force a review. Prefer an explicit list wherever a new file must be a
conscious act.

## Step 4 -- one entry point

There is one command for "did everything pass", and the fast loop beside it:

    bazelisk test //<aggregate-target> --test_tag_filters= --test_output=errors
    bazelisk test //<fast-target> --nocache_test_results

Suites tagged `manual` stay out of `bazelisk test //...` on purpose; pass an empty
`--test_tag_filters=` or name the suite directly to run one. Iterate on the derived
scope, never on the whole suite:

    bazelisk query 'rdeps(//..., <path>)' --output=label   # or the repo's own map verb

`Executed 0 out of N tests: N tests pass.` is a cached pass over unchanged inputs,
which is a real pass. Take exactly one uncached pass before the pull request.

## Step 5 -- make the docs and the outputs speak in targets

A human should never need a script path. Enumerate the surfaces from the build rather
than guessing which files are docs:

    bazelisk query 'kind("filegroup", //...)' --output=label
    grep -rn 'scripts/[a-z0-9-]*\.sh\|bash scripts/\|python3 scripts/\|\./scripts/' \
      --include='*.md' --include='*.mdx' --include='*.py' --include='*.sh' . \
      | grep -v '^tests/' | head -40

Rewrite each hit to `bazelisk run //scripts:<stem> -- <args>`. Cover the four surfaces
the request asks for: prose docs, docstrings and `# @function` blocks, inline comments,
and the text a CLI prints, which includes help output, `error:` lines, and retry hints.
A message like `failed; retry with: ./scripts/manage.sh restart` is the bug; the fixed
form names the target.

Where docs are generated, edit the seed and re-run the generate target; hand-editing a
generated file trips the committed-render test. Finish with a gate that keeps it true:
a test fails when a doc names a script path or cites a target that `bazelisk query`
cannot resolve.

## Step 6 -- drive coverage through the gate

    bazelisk test //<py-coverage-target> //<shell-coverage-target> \
      --test_tag_filters= --test_output=errors

Read the report line, not the pass line: a suite can pass at 99.5%. Every uncovered
function gets a test, and a genuinely unreachable one gets an exclusion with a reason
in the same place the ledger keeps its reasons.

One trap worth its own bullet: adding a `data` edge to reach a new runner widens the
denominator of any xtrace-based shell coverage suite, because the denominator is the
union of declared payloads. Functions that were never reachable become newly measured
and the number drops on a green local run. When that happens, write the missing tests;
a lowered floor that nobody noticed is the failure this gate exists to catch.

## Step 7 -- verify, commit, PR

Run the full gate uncached once, then the same command CI runs, before you push:

    bazelisk test //<aggregate-target> --test_tag_filters= --test_output=errors --nocache_test_results

Branch from the tip of the default branch, commit in an order where no commit is red,
and open the pull request per the repo's convention. On any push or `gh` auth error,
run the repo's one auth probe once and read its last line; do not improvise a
credential helper.

## Fan-out

Census first with one read-only child, then at most four writers in a single turn.
Hotspots stay with you: the root and per-package `BUILD` files, aggregate suites,
payload manifests, the ledger, and generated docs. Give each writer an OWN list, a
MUST-NOT-TOUCH list naming its siblings, the pinned contract text, and a literal
definition-of-done command.

Writers on a shared checkout collide in time even when their file sets are disjoint.
Either isolate them, or forbid `git stash` and `git checkout` for baselining and have
them read `git show HEAD:<path>` into `/tmp`. Children cannot spawn children.

## Pitfalls, each with the fix

1. **Guessing a label.** Query first; `bazel-map`-style verbs answer in under a second.
2. **Re-implementing an existing check.** Search for the repo's own unclaimed-file verb
   in Step 0 and wire that.
3. **Trusting a green lint lane.** A linter missing from PATH commonly skips. Make
   absence fatal in CI and install what the lane needs there.
4. **Whole-suite iteration.** Scope with `rdeps` or the map verb; save the one uncached
   full pass for before the PR.
5. **`manual` tags.** Without `--test_tag_filters=` the coverage and lint lanes you mean
   to run are silently skipped.
6. **Payload invisible to the gate.** A new directory that never joins the data filegroup
   and the pinned manifest is unchecked and reports no failure.
7. **Unicode lookalikes.** Copying prose dashes and quotes into a BUILD file or a test
   produces errors like `rm: invalid option -- 'F'`. Keep those files ASCII.
8. **Generated docs hand-edited.** Edit the seed, re-run generate, let the committed-render
   test pass on its own.
9. **Coverage denominator drift.** New `data` edges expose previously unmeasured code;
   cover it rather than lowering the floor.
10. **Auth rediscovery.** One probe, read the verdict, and stop. Budget five calls total.
11. **Long first builds.** Start them with `block_until_ms` 0 and poll; a blocking wait
    burns the turn.
