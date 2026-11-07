---
title: Strong types
description: "The typing rule for every language in this repo: Python under mypy with no Any, TypeScript under the strictest flags it compiles, Terraform variables with a declared constraint, and what bash and awk owe instead."
tags: [types, mypy, typescript, terraform, contributing]
---

# Strong types

**What's on this page**

- The rule in one sentence, and the two gates that hold it
- Python: the mypy profile, the aliases that replace `Any`, and how to add a file
- TypeScript: the compiler switches, and how the `.mjs` scripts get checked
- Terraform: why a `variable` without a `type` is a runtime bug
- Bash, awk, and Bats: what an untyped language owes instead of annotations
- Adding a new language, or a new file to an existing one

**What this enables**

- Making an annotation that a reviewer cannot argue about, because a tool decides it
- Catching a wrong-shaped input at plan time or type-check time rather than in a container
- Adding a `.py`, `.ts`, or `.tf` file without guessing which list it belongs on
- Telling a contributor why `Any` came back from CI

## The rule

Every value has a declared shape at the boundary where it enters a module, and a
broad type is a design smell rather than a shortcut. Where a language has a type
system, the strictest setting that compiles is the setting the repo uses. Where it
has none, the convention is the gate.

Two gates carry most of it, and both are members of `//lints:all`, so `//:lint`,
`//:test-all`, and the `bazel` job of `.github/workflows/ci.yml` run them:

| Gate | Language | What it refuses |
| --- | --- | --- |
| `//lints:mypy` | Python | a missing annotation, an explicit `Any`, a bare generic |
| `//docs-site:typecheck` | TypeScript | the same, plus every index access that can be undefined |

`//:validate` adds the Terraform half, and `//tests:bats_mypy_lint_test` and
`//tests:bats_tf_types_test` are the asserting sides of the two newest gates.

## Python

`mypy.ini` at the repo root is the whole policy. It is `--strict` written out option
by option, plus the two that make this a rule rather than a preference:

```ini
disallow_any_explicit = True
disallow_any_generics = True
```

`disallow_any_explicit` refuses `Any` typed into a signature by a person.
`disallow_any_generics` refuses `list` and `dict` written without their element
type, which are the same hole reached by a different spelling. The binary is the
`MYPY_VERSION` pin from `images/dev/tool-versions.env`, baked into the golden image
by `images/dev/Dockerfile`, so the gate needs no network and no `pip install`.

Run it directly when you want the error text without Bazel in the way:

```bash
bazelisk test //lints:mypy
bazelisk test //lints:mypy --test_output=all   # the mypy diagnostics themselves
bash lints/run_mypy.sh                          # same checks, no Bazel
```

The pattern the profile pushes you toward is a named alias for anything unstructured.
`scripts/lib/mcp_lane_report.py` reads TOML and JSON, so rather than widen a
signature it declares the two document shapes and narrows with `isinstance`:

```python
TomlValue = Union["TomlTable", "TomlArray", str, int, float, bool]
TomlTable = dict[str, "TomlValue"]
TomlArray = list["TomlValue"]
```

The same file writes its two fixed vocabularies as `Literal`s, which is what makes a
typo in a check name a gate failure rather than a line an operator never sees. A
record that travels between functions gets a `NamedTuple`, a `@dataclass`, or a
`TypedDict` — `tests/bazel_deps.py` names its Starlark map `LabelMap` and its
`drift()` result `Drift`, and `tests/coverage/py_report.py` types the slice of
`coverage report --json` it reads with three `total=False` TypedDicts.

`# type: ignore` needs a specific error code and a reason that names the real cause.
`warn_unused_ignores` makes a stale one an error, so an ignore cannot quietly
outlive the problem it papered over. Where the value is unstructured but an
`isinstance` guard already decides what it is, a `cast` is the honest instrument:
narrowing there would change what happens to the malformed input.

## TypeScript

`docs-site/tsconfig.json` starts at `strict: true` and adds the switches that find
real defects at no churn cost: `noUncheckedIndexedAccess`, `noImplicitOverride`,
`noImplicitReturns`, `noFallthroughCasesInSwitch`, `noUnusedLocals`, and
`noUnusedParameters`. Each carries a comment naming the class of bug it catches.

Two well-known switches are deliberately off. `exactOptionalPropertyTypes` collides
with React's optional DOM props and with fumadocs' `StaticOptions`;
`noPropertyAccessFromIndexSignature` collides with how the unit tests read the
fumadocs source config. Both would be paid for in casts, which is the wrong
direction.

`allowJs` and `checkJs` are on, which is how the two operator CLIs
`docs-site/scripts/serve_static.mjs` and `verify_site.mjs` are type-checked: each
opens with `// @ts-check` and carries JSDoc `@param`/`@returns` on every function,
with `@typedef`s for the shapes it reads out of `lib/nav.json`. `zod` already
validates the frontmatter at the content boundary in `docs-site/lib/content.ts`, so
parsed pages arrive as typed `PageNode`s rather than as `unknown`.

```bash
cd docs-site && npm run typecheck   # next typegen + tsc --noEmit
bazelisk test //docs-site:typecheck # the same, as a gate target
```

`any`, `@ts-ignore`, `@ts-expect-error`, and `@ts-nocheck` are absent from every
tracked file. The one exclusion is `docs-site/.source/`, the code fumadocs-mdx
generates, which is gitignored. `docs-site/tests/unit/helpers/fumadocs-stub.ts` is
where a dependency's shape gets stated once when a test needs one.

## Terraform

A `variable` block is the only place a Coder template can declare what an input is,
and an undeclared one takes whatever HCL guessed. `search_mcp = "flase"` then reaches
a `== "true"` comparison and reads as false, so the operator gets a workspace that
came up wrong and a plan that said nothing. A declared constraint turns that into a
plan-time error.

`scripts/lib/tf_types.awk` is run by `//:validate` over both template twins and
reports three findings: `missing-type`, `broad-any`, and `bare-container` (a `list`,
`set`, or `map` with no element type, which is `any` wearing a different hat). Only
the `type` attribute of a top-level `variable` block is read, so a `type` key inside
a `default` body is never mistaken for the constraint, and `any` is matched as a word
so `company_mcp` is not a finding.

```bash
bazelisk run //:validate                       # includes the variable-type gate
awk -f scripts/lib/tf_types.awk templates/workspace/main.tf   # just the gate
```

Both twins conform today: every `variable` carries a `type` and a `description`, and
neither uses `any`, `list(any)`, or a bare container. `//tests:bats_tf_types_test`
holds that, with fixtures that prove the gate still reports each finding rather than
having quietly stopped looking.

## Bash, awk, and Bats

Bash has no type system, and no annotation comment buys one. What the repo does
instead is put the checking where the language can actually be checked:

- `//lints:shell` runs ShellCheck at `--severity=warning` over every first-party
  `.sh`, and the tree is clean at that level today.
- Variables are declared before they are used and carry their shape in the
  declaration: `local -a` for an indexed array, `local -A` for an associative one,
  `local -r` or `declare -r` for a constant. Naming the kind is what makes an array
  that was meant to be empty distinguishable from one that was never set.
- Every function in `scripts/` carries a `# @function` block with `Globals:`,
  `Arguments:`, `Outputs:`, and `Returns:`, and each `Arguments:` line states what
  the parameter is. `//tests:doc_coverage` enforces the block and
  `//tests:shell_inventory` enforces that a test names the function.
- `set -euo pipefail` is the floor, so an unset parameter is a failure rather than
  an empty string.

awk is POSIX-subset and single-purpose: a program in `scripts/lib/*.awk` takes its
input in `ARGV`, its configuration in `ENVIRON`, and prints tab-separated fields the
caller reads line by line. The types are that line shape, and they are documented in
the program's header block — see `scripts/lib/tf_types.awk` for the shape to copy.
Bats suites are bash and follow the same rules as their shell.

## Adding a file

| Adding | You also edit |
| --- | --- |
| `scripts/lib/<name>.py` | nothing: `//scripts:py_programs` globs it and `lints/run_mypy.sh` scans the directory; if a CLI runs it, it joins that CLI's `_SCRIPT_LIBS` |
| another `.py` package | `lints/run_mypy.sh` `targets` **and** the data edge of `:mypy` in `lints/BUILD.bazel` — the two are kept equal by hand, and the runner's header says so |
| `docs-site/**/*.ts` | nothing: it is already in the `tsconfig` program |
| a `.mjs` CLI | `// @ts-check` and JSDoc on every function, since `checkJs` is on |
| a `variable` in a template | its `type` and its `description`, in both twins where the template keeps twins |

A Python file that lands outside the runner's list is unchecked code that looks
gated, which is the failure `//tests:bats_mypy_lint_test` exists to catch: it
enumerates the tree and fails on any `.py` the target list does not cover, with
`tests/bats/fixtures/` the one sanctioned exclusion because that tree is scaffold
payload typed in the repository it is copied into.
