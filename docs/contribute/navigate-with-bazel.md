---
title: Navigating the repo with the Bazel graph
description: "Answer what-depends-on-this with one bazelisk query instead of a grep sweep: the bazel-map CLI, the raw query predicates behind it, and the empty-result trap."
tags: [bazel, contributing, tooling, graph]
---

# Navigating the repo with the Bazel graph

**What's on this page**

- Why a structural question is a query here, not a grep sweep
- The `bazel-map` CLI, its verbs, and the `--json` split that feeds `bazelisk test`
- Before a large edit: the twin copies, the filegroup, the map key, the test a new function owes
- While you iterate: the derived test list, and when you still owe one uncached pass
- Enumerating real target names instead of guessing them
- What a target actually reads, and why an unlisted payload directory stays invisible
- The raw `bazelisk query` predicates for when a verb does not fit

**What this enables**

- Naming every suite that must move with a payload file in one query, in about 60 ms
- Running the suites that cover the files you touched instead of the whole fast gate
- Catching a payload directory no filegroup claims before the gates stay green by accident
- Telling a rule class from a target name without opening a BUILD file
- Stopping the late-gate discovery of a coupling rule the graph already recorded

This repo keeps its coupling in BUILD files: `scripts/BUILD.bazel` names the libs and payload
groups each CLI reads, `tests/BUILD.bazel` names what each Bats suite opens, and the root
`BUILD.bazel` aggregates every payload group into `//:stack_data`. `//tests:bats_bazel_deps_test`
fails when those maps drift from the sources, so the graph is a record an automated reader can
trust, and "which suites cover this file" has a ground truth sitting in it. Answering that from
`grep` re-derives what one `bazelisk query` prints.

[building-with-bazel.md](building-with-bazel.md) explains the maps, runfiles, and the daily
commands; [test-with-bazel.md](test-with-bazel.md) explains the suites those queries name and the
two inventory gates; [../project-conventions.md](../project-conventions.md) the CLI vocabulary this
tool prints in.

## Why a query, not a grep

A sweep of this repo's own agent session logs measured the habits the graph is meant to
replace. Corpus: the 199 parent sessions recorded for this checkout under
`~/.grok/sessions/` before 2026-11-01, counted with `jq` and `grep -c` over each session's
`chat_history.jsonl`. Every count is a floor, because a truncated tool result hides a call.

| Habit | Measured |
| --- | --- |
| `bazelisk query` at all | 8 sessions, about 4% |
| `rdeps()` and `somepath()` | never used in that corpus |
| Recursive grep for a structural question | the default instrument: `grep -rn` outnumbered `bazelisk query` by an order of magnitude |
| `//:test-fast` re-run to learn one dependency | 48 sessions ran it; 16 ran it three or more times |
| Reading the checker's own source to learn why a gate failed | 19 sessions |
| Guessing a target name into `ERROR: no such target` | 4 to 7 sessions, depending on how strictly a match is counted |

The cost of not querying shows up late. In the sessions that hit a coupling rule, the first
`FAIL: //` line appeared only after a hundred or more messages of editing: the rule was
discoverable in the graph on message 1, and was instead discovered by running the gate. One agent
audited `//:stack_data` by listing the repo's top-level directories rather than diffing the graph
against `git ls-files`, which is the same question asked in a way that cannot answer it.

The verbs below are the shapes of those questions.

## The CLI: bazel-map

`bazel-map` is a thin shell over `bazelisk query`. It reads nothing and writes nothing; each verb
is one query, run from the real checkout, with Bazel's stderr kept so a miss is reported instead of
swallowed. Run it through Bazel like every other CLI:

```bash
bazelisk run //scripts:bazel-map -- targets [pattern]
bazelisk run //scripts:bazel-map -- tests-for <path>...
bazelisk run //scripts:bazel-map -- owners <path>...
bazelisk run //scripts:bazel-map -- files <target>
bazelisk run //scripts:bazel-map -- twins <path>...
bazelisk run //scripts:bazel-map -- scope [--staged] [--untracked] [--ref <ref>]
bazelisk run //scripts:bazel-map -- unlisted <dir>...
```

Flags, accepted anywhere in argv: `--staged`, `--untracked`, `--ref <ref>`, `--all`,
`--label-kind`, `--json`, `-h|--help`. Exit codes: 0 when every named thing resolved, 1 on a query
failure, 2 on a usage error (an unknown verb or flag, or a verb invoked without the argument it
needs).

**Use `--json` when you want to act on the answer.** Prose (`== section ==`, `ok:`, `note:`,
`summary:`) rides stderr and stdout carries only labels, one per line, which is the shape
`bazelisk test` consumes:

```bash
bazelisk run //scripts:bazel-map -- --json tests-for tests/bats/common.bats 2>/dev/null \
  | xargs bazelisk test
```

Without `--json` the same labels are interleaved with the report lines, so piping them straight into
another command feeds it `ok: tests-for` as an argument. Paths are repo-relative, and a batch costs
one query: when a batch fails, the verb re-runs it per path and names the path the graph does not
know instead of hiding every other answer.

## Before a large edit: what moves with this file?

This is the question that costs the most sessions, because the answer is spread over four different
mechanisms and each one is normally discovered by a failing gate.

### The suites that read a payload

```bash
bazelisk run //scripts:bazel-map -- tests-for litellm/config.yaml
```

```text
//tests:bats_ez_learn_skill_test
//tests:bats_hermes_skills_test
//tests:bats_litellm_config_test
//tests:bats_stack_data_test
//tests:bats_update_stack_test
//tests:bats_validate_test
//tests:shell_coverage
```

Seven suites, printed in about 60 ms. Change that file and those are the suites that go red; edit one
of them and the same verb in the other direction tells you what it covers.

### The twin template copies

`templates/workspace/` and `templates/devcontainer/` keep independent payload copies that must move
together, and `templates/common/` holds the files both consume as one shared copy. The verb matches
basenames over the union of the three payload groups, so the twin set is the graph's answer rather
than a convention you have to remember:

```bash
bazelisk run //scripts:bazel-map -- twins templates/workspace/main.tf
# -> //templates/devcontainer:main.tf

bazelisk run //scripts:bazel-map -- twins templates/common/tmux.conf
# -> note: one shared copy in //templates/common:payload, staged by both template twins
```

A per-tree file whose sibling tree has no counterpart is a `warning:` naming the group that claims
it: that asymmetry is the drift worth knowing about before you edit, not after.

### The filegroup that must claim a new payload file

A file the graph does not know is a warning naming that path, and the usual cause is a file you just
created that no filegroup claims yet. `owners` answers "is this visible to the harness at all":

```bash
bazelisk run //scripts:bazel-map -- owners litellm/config.yaml
# -> //:stack_data
# -> //litellm:config

bazelisk run //scripts:bazel-map -- owners docs/contribute/building-with-bazel.md
# -> //docs:content
```

An empty list is the finding: no filegroup carries the file, so `test-fast` and `lint` never open it.
The pair verb, `unlisted`, asks it per directory by diffing `git ls-files` against the graph's own
source list. It skips Bazel's own declaration files (`BUILD.bazel`, `*.bzl`, `MODULE.bazel`), which
Bazel reads implicitly and which only appear in the graph when a package deliberately exports them,
so a directory holding nothing but a BUILD file reads as clean.

```bash
bazelisk run //scripts:bazel-map -- unlisted hermes proxy searxng
# -> ok: unlisted
# -> summary: 1 ok, 0 warnings, 0 failed
```

A new top-level payload directory belongs in its own package with its own `filegroup` targets, joins
`//:stack_data` by label, and is named in the map of every target that reads it, as
[building-with-bazel.md](building-with-bazel.md) spells out. `unlisted` is how you find out you have
not done that, rather than finding out that the gate never noticed.

### The map key a new `scripts/*.sh` needs, and the test a new function needs

A new `scripts/*.sh` is a Bazel target automatically (the package is generated from the directory),
but it is not wired automatically: it needs a `_SCRIPT_LIBS` key (the `scripts/lib` closure it
sources) and a `_SCRIPT_PAYLOAD` key (the payload groups it opens), both in `scripts/BUILD.bazel`.
Until those keys land the graph does not know the file at all, which is worth saying out loud:
`rdeps` reads the graph, not the filesystem.

```bash
bazelisk run //scripts:bazel-map -- tests-for scripts/new-cli.sh
# -> warning: the graph does not know scripts/new-cli.sh: no target declares it (a new
#    file reaches the harness through a filegroup)
```

That warning is the honest version of "nothing depends on this", and it is the reason to keep
stderr with a query. Go to the gate that owns the map instead of guessing its label:

```bash
bazelisk test //tests:bats_bazel_deps_test --test_output=errors
```

A script missing its key outright fails `//scripts` analysis before any test runs, and a script
whose declared map disagrees with its sources is what that checker reports, naming the pairing and
the direction. Once the keys are in place the same verb resolves the file, and
`tests-for scripts/bazel-map.sh` lists `//tests:bats_bazel_deps_test` among its consumers. Every new function additionally owes one `# @function` block and one asserting test in exactly
one suite, which [test-with-bazel.md](test-with-bazel.md) covers; `//tests:shell_inventory` and
`//tests:doc_coverage` are the two gates, and both are test targets the graph can point you at
before the gate does.

## While you iterate: which tests, and when you still owe a full pass

`scope` derives the test list from what this checkout changes, which is the loop that replaces
re-running the whole fast gate after every edit:

```bash
bazelisk run //scripts:bazel-map -- scope --untracked
# illustrative: the label list is whatever your working tree implies
# -> 2 changed path(s)
# -> //lints:buildifier
# -> //tests:bats_bazel_deps_test
# -> //tests:bats_ez_learn_skill_test
# -> //tests:bats_docs_alias_test
# -> ...
# -> note: run them with: bazelisk test <labels>; keep one uncached //:test-fast pass before the PR
```

Default scope reads `git diff HEAD`; add `--staged` for the index, `--untracked` to count files git
does not track yet (a file you just created is exactly the case worth covering), or `--ref <ref>` for
what this branch adds over a base. `--all` also lists the aggregate suites that reach everything
(`//:test`, `//:test-fast`, `//:test-all` and `//tests:bats`), which is useful when you want the full
set named explicitly rather than the leaf suites you can invoke. The default already includes the
lint targets: every test rule here, `//lints:shell` and `//lints:shfmt` among them, is an `sh_test`.

Two things scope tells you that a habit of `bazelisk test //:test-fast` hides:

- **A Bats file is cheap; a script is not.** `tests-for tests/bats/common.bats` returns five targets.
  `tests-for scripts/lib/common.sh` returns 60 of the 67 test targets on this checkout, because every
  suite declares `//scripts:doc_sources`, which is every `scripts/**.sh` (66 targets reach that
  group). That is the honest graph answer: editing a broadly sourced script genuinely re-runs nearly
  the whole suite set, and knowing it before you start is what decides whether to run the derived
  list or the aggregate.
- **An empty result means run everything.** Nothing changed against HEAD, or the change touches no
  file the graph tracks, and `scope` says so and points at `//:test-fast`.

The uncached pass is not replaced. `bazelisk test` replays a cached PASS for an action whose inputs
did not change, so the derived list proves your change against whatever actually rebuilds, and one
`bazelisk test //:test-fast --nocache_test_results` remains the pass you owe before the PR, per
[building-with-bazel.md](building-with-bazel.md). Use the derived list for the loop and keep the full
uncached pass for the end, instead of paying for sixty suites to learn one thing per edit.

## Enumerate targets instead of guessing them

Seven logged sessions guessed a target name and got `ERROR: no such target`. A target is never
guessed, it is listed:

```bash
bazelisk run //scripts:bazel-map -- targets //docs-site:* --label-kind
# -> filegroup rule //docs-site:app
# -> sh_binary rule //docs-site:build
# -> sh_binary rule //docs-site:build-latest
# -> filegroup rule //docs-site:build_file
# -> filegroup rule //docs-site:components
# -> ...
```

The rule class is the part that saves the round trip. `//docs-site:app` looks like the site's test
target and is a `filegroup`, so `bazelisk test` on it fails to start; the real test targets are the
`sh_test` rows. The same listing filtered by a name fragment is how you find a Bats suite's target
without knowing the stem convention:

```bash
bazelisk query 'attr("name","bazel_deps",//tests:*)' --output=label_kind
# -> sh_test rule //tests:bats_bazel_deps_test
```

## What a target reads, and why an unlisted directory is invisible

`//:test-fast` runs in a sandbox: an action sees its declared inputs and its runfiles tree, not the
checkout. So "what does this target read" is a real question with a printed answer, and the answer has
two depths worth keeping separate.

The direct inputs are the `data` the dependency maps write, which is what you edit when a target
needs one more payload group:

```bash
bazelisk query 'labels("data", //tests:bats_bazel_deps_test)' | wc -l
# -> 25
```

The files it can actually open are the transitive closure of those groups, which is what the verb
prints:

```bash
bazelisk run //scripts:bazel-map -- files //tests:bats_bazel_deps_test | grep '^//' | head
# -> //:BUILD.bazel
# -> //:MODULE.bazel
# -> //:docker-compose.yml
# -> //docs:BUILD.bazel
# -> //docs-site:BUILD.bazel
# -> //lints:BUILD.bazel
# -> //scripts:BUILD.bazel
# -> //scripts:bazel-map.sh
# -> //scripts:bootstrap.sh
# -> ...
```

That target resolves to 198 source files through 25 declarations: the gap is the `filegroup` and
`scripts/lib` expansion under each label. `labels("data", ...)` is the narrower question ("what does
the BUILD file say"), `files` is the wider one ("what is in the sandbox"), and the two disagreeing is
usually the bug.

This is why an unlisted payload directory stays invisible rather than being checked loosely: a file
that travels in no runfiles tree is a file no sandboxed action can open, so `test-fast` and `lint`
never read it and never fail. Nothing prints a warning about that. `owners <path>` and
`unlisted <dir>` are the two ways to ask, and they are the difference between a payload the harness
guards and a payload nobody has ever executed.

## Raw query recipes when a verb does not fit

Every verb is one of these, so a question outside the verb set needs one predicate, not a grep plan.
All of these run warm in about 50 to 70 ms.

| Predicate | Question it answers |
| --- | --- |
| `rdeps(//..., "path")` | what depends on this file |
| `deps(//target)` | what this target depends on, transitively |
| `kind("sh_test", ...)` | narrow to the rules you can act on |
| `attr("name", "re", pkg:*)` | find a target by a name fragment |
| `labels("data", //target)` | the groups a target declares as its inputs |
| `somepath(a, b)` | is there any path from this suite to that file |
| `A intersect B`, `A except B` | combine two result sets |

The `kind` filter is what makes an `rdeps` usable. A bare `rdeps(//..., "litellm/config.yaml")`
includes `//:test-fast`, which reaches every file and therefore tells you nothing about this one:

```bash
bazelisk query 'kind("sh_test", rdeps(//..., "litellm/config.yaml"))'      # 7 suites to run
bazelisk query 'kind("filegroup", rdeps(//..., "litellm/config.yaml"))'    # 2 owners
```

Two exclusions earn their place. `except kind("test_suite", //...)` drops the aggregates, which is
what the CLI filters on so `//:test-fast` cannot answer a per-file question, and
`except kind("sh_test", //lints:*)` drops the two manual lint targets, `//lints:shell` and
`//lints:shfmt`, that ride on every script:

```bash
bazelisk query 'kind("sh_test", rdeps(//..., "scripts/lib/common.sh")) except kind("test_suite", //...) except kind("sh_test", //lints:*)'
```

A reachability proof, for when you must know that a gate really does sit on top of a file:

```bash
bazelisk query 'somepath(//:test-all, "tests/shell_inventory.sh")'
# -> //:test-all
# -> //tests:shell_inventory
# -> //tests:shell_inventory_exec
# -> //tests:shell_inventory.sh
```

The whole-graph enumeration `unlisted` is built from, which is also the answer to "how much of the
repo do the gates actually see":

```bash
bazelisk query 'kind("source file", deps(//...))' | wc -l
# -> on this checkout, 324 labels carry a // prefix and about 50 more come from external
#    repositories (bazel_tools, bats_core, rules_java)
```

The `//` half is the honest measure of what the gates can see, and it moves as files are added, so
treat any absolute total in a document as a snapshot rather than a fact to assert.

And set algebra, for "is this payload covered by the suite I trust with it":

```bash
bazelisk query 'kind("sh_test", rdeps(//..., "hermes/config.yaml")) intersect kind("sh_test", deps(//tests:bats_hermes_config_test))'
# -> //tests:bats_hermes_config_test
```

## The empty result is not an answer

This is the trap that makes a hand-check unreliable, and it is the reason the CLI keeps Bazel's
stderr instead of discarding it. A query can print `ERROR: no such target` and leave stdout empty,
which looks exactly like "nothing depends on this":

```bash
bazelisk query 'kind("sh_test", rdeps(//..., "litellm/config.yml"))'
# ERROR: no such target '//litellm:config.yml': target 'config.yml' not declared in
# package 'litellm' defined by .../litellm/BUILD.bazel (did you mean config.yaml?)
```

One mistyped character, an empty stdout, and a shell that tests only `-z "$out"` reports a clean
result. So before you believe an empty list: check the exit status (Bazel exits non-zero here), read
stderr, and confirm the operand resolved at all with `bazelisk query '"litellm/config.yaml"'`, which
prints its label back. A miss you can see is a finding; a miss you cannot see is a green gate over a
file nobody tests.
