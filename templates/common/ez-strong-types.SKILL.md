---
name: ez-strong-types
description: "Impose a strong-types philosophy across every language in a repository: a
  strict, centrally pinned checker profile per language, shared type vocabulary written
  before call sites, an enumerated ladder of escape hatches that ends below Any, a
  broad-type census wired as a ratchet gate that fails on any increase, then verified
  commit and pull request. Use when asked to add type hints, type annotations, strict
  typing, strong types, or to remove Any; or to re-widen a codebase's typing budget back
  down. Run as /ez-strong-types [repo-path] [--language LANE]."
when-to-use: "Use when the operator wants types everywhere they are representable, broad
  types such as Any pushed out, and the result enforced by the build rather than by review."
argument-hint: "[repo-path] [--language python|typescript|shell|terraform]"
compatibility: "Requires git. Uses whichever checkers the image already provides (mypy, tsc, shellcheck, shfmt); adds no dependency."
metadata:
  author: "operator"
  short-description: "Strict types per language, enforced by a ratchet"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["ez-strong-types"]` under `[skills]`
     in `~/.grok/config.toml`. -->

# Strong types

Five conditions define done:

1. Each language has a strict profile written out rule by rule, in one file, so every
   rule is nameable in review.
2. The checker is a build target, so enforcement outlives the PR.
3. The shared type vocabulary exists before call sites are annotated, and it is the
   only place a shape is named once.
4. Broad types are counted, and the count can only go down.
5. The full gate is green, in CI as well as locally, then committed and opened as a PR.

Budget 50 to 80 of your own calls plus one wave of writers. Two facts from previous
runs of this exact task set the shape of the work: on a repo that already types well,
most language lanes turn out to be documentation only, and the wall time is spent in
the writer wave and in one CI round-trip. Both are avoidable by measuring first.

## Step 0 -- census and baseline before any edit (delegate)

Measure, because "as much as reasonably possible" needs a number to move.

    python3 ~/.agents/skills/ez-strong-types/scripts/type_baseline.py --root <repo> \
      | tee /tmp/strong-types-baseline.txt
    python3 ~/.agents/skills/ez-strong-types/scripts/type_baseline.py --root <repo> --json \
      > /tmp/strong-types-baseline.json

It reports per-language file counts, explicit `Any`, `# type: ignore`, unannotated
`def`, `@ts-ignore`, missing `set -euo pipefail`, and `eval`. Record the checker's own
error count and the per-file split too, since that is what a writer needs:

    <checker> 2>&1 | tail -5
    <checker> 2>&1 | grep -oE '^[^:]+' | sort | uniq -c | sort -rn | head -20

Delegate the broad sweep to one read-only child and take a digest back: file, line,
error code, count. Hand each writer its own exact error list in Step 3; a writer that
has to find its work spends a third of its calls doing it.

## Step 1 -- pin the profile centrally (yours alone, no writer touches these)

Write the config before the code, and write every rule explicitly rather than
relying on a preset flag. A named rule can be argued about in review; `--strict`
cannot.

- Python: `mypy.ini` with the standard strict set spelled out, plus
  `disallow_any_explicit = True` and `disallow_any_generics = True`. Unstubbed
  third-party imports become a declared boundary with `ignore_missing_imports`, named
  in a comment, not silenced globally.
- TypeScript: `strict` plus `noUncheckedIndexedAccess`, `noImplicitOverride`,
  `noImplicitReturns`, `noFallthroughCasesInSwitch`, `noUnusedLocals`,
  `noUnusedParameters`. Turn on `checkJs` only together with a tightened `include`, or
  it will ingest minified build bundles and report thousands of errors you did not ask
  for. Leave `exactOptionalPropertyTypes` and `noPropertyAccessFromIndexSignature` off
  unless the code already satisfies them, and say so in a comment.
- Shell: `set -euo pipefail` everywhere, `shellcheck -x --severity=warning`, and a
  `.shellcheckrc` if the repo needs exceptions. A function contract block per function
  is the type system shell has; keep it current.
- Terraform: `type` constraints on every `variable`, no bare `any` or unparameterised
  `list`/`map`. Where no linter is installed, a small scanner that emits
  `file<TAB>line<TAB>rule<TAB>detail` and runs as a validate phase is worth more than a
  tool you cannot install. Verify a new scanner against a file you deliberately break:
  one buggy one-liner once reported every variable in a repo untyped.
- Terraform templates, YAML, JSON, Markdown: state in the docs what is checked and what
  is checked nowhere. An honest gap beats a fake gate.

Register each checker as a target following the repo's own recipe for a new gate, and
keep the semantics: a missing checker prints a skip and exits 0 locally, and exits 1
under `CI=true` or `REQUIRE_LINT_TOOLS=1`. Then wire the baseline script with
`--fail-on-increase /tmp/strong-types-baseline.json` as its own target so the budget
only ratchets down.

## Step 2 -- write the shared vocabulary yourself

Before any fan-out, you own the modules where a shape is named once: the recursive
aliases for parsed data, the `TypedDict`s for known dict slices, the `Protocol`s for
structural shapes, the enums and `NewType`s, and the dataclasses at the boundaries.
Anything a writer might invent is a symbol you should define first, because two writers
who each invent a `Config` type produce two.

Unstructured data gets a named recursive alias (`JsonValue`, `TomlValue`), which is the
single most useful move: it removes most of the `Any` that parsed TOML, JSON, and YAML
would otherwise force into signatures.

## Step 3 -- fan out, one writer per file

At most four writers, launched in one turn, each with:

- its OWN list and a MUST-NOT-TOUCH list naming its siblings;
- the pinned contract line: which config file to read first and the exact strictness
  it enforces;
- its literal per-file error list from Step 0;
- the definition-of-done command, verbatim;
- the escape-hatch ladder below, and a standing order to add zero `Any` and zero bare
  `# type: ignore`;
- "add no dependency". The image is the supply chain, and a committed lockfile plus
  `npm ci` in CI makes an npm addition off the table.

Everything shared stays with you: all `BUILD` files, the checker configs, payload and
suite manifests, generated docs, and navigation. Writers on one checkout collide in
time even with disjoint files, so isolate them or forbid `git stash` and `git checkout`
for baselining and have them read `git show HEAD:<path>` into `/tmp`.

## Step 4 -- the escape-hatch ladder

Reach for the top rung that preserves behaviour, and never skip a rung silently.

1. Name the exact type.
2. Name a recursive alias for parsed, unstructured data.
3. `TypedDict` for a dict whose keys are known, `total=False` where keys are optional.
4. `Protocol` for a structural shape, including a callable: a `Protocol` with
   `__call__(*args: object, **kwargs: object) -> object` where `Callable[..., object]`
   would be rejected, because some strict profiles count the ellipsis as `Any`.
5. `TypeGuard` or `isinstance` narrowing, where narrowing cannot change behaviour.
6. `cast(...)` with a one-line reason comment, where an `isinstance` check would
   change behaviour. A commented cast beats an ignore; a bare ignore is a failure.
7. `object` plus narrowing at the point of use.
8. `Any` with an error code and a reason, counted by the ratchet, in a place a reader
   is told why.

Load-bearing fixes that recur: a loader that returns `object` producing a wall of
`attr-defined` errors is fixed by typing it `-> types.ModuleType` and raising when
`spec` or `spec.loader` is `None`, which usually deletes pre-existing ignores rather
than adding new ones. Declare attributes a mixin only sets in a helper.

## Step 5 -- keep the tests honest

A type-clean change can break a test, and two causes recur. Generated output checked
into the tree goes stale, so rebuild the export before running anything that asserts
against it. And a new build `data` edge widens the denominator of a coverage suite that
measures declared payloads, so previously unreachable functions become measured and the
percentage drops on an otherwise green run. Write the missing tests; do not lower the
floor.

Run the suite after each wave, not once at the end.

## Step 6 -- verify, then commit and PR

    <checker>                       # expect: Success, no issues found
    <test runner> --nocache_test_results
    <aggregate gate target>         # the exact command CI runs

Run the aggregate gate locally before you push, because CI runs more than the fast
lane and a CI-only failure costs a full round-trip. Then: a short-lived branch from the
tip of the default branch; commits grouped so that none of them is red, typically one
per language lane plus one for the gate and one for tests; messages via
`git commit -F /tmp/msg.txt`; the PR via `gh pr create --body-file` with Problem, What
changed, How tested, and Risks. Leave the merge to the reviewer. Clean up every scratch
file, background server, and worktree you made.

## Pitfalls, each with the fix

1. **Counting the wrong thing.** Measure source-level broad types, not only the
   checker's error count; errors go to zero while `Any` stays.
2. **`Callable[..., object]` rejected.** Some strict profiles treat its ellipsis as
   `Any`; use a `Protocol` with `__call__`.
3. **`checkJs` with a wide `include`.** It swallows minified bundles. Tighten `include`
   in the same edit, and keep generated directories excluded and grep-excluded.
4. **A missing `@types` package becomes an error the moment you check JS.** Inline a
   `Record<string, unknown>` typedef instead of installing anything.
5. **Assuming a matcher is literal.** Assertion helpers are often regex-based, so a
   pattern containing `${}` or `(` silently matches nothing. Escape, and prove the test
   fails for the right reason.
6. **Awk or grep probes that match nothing** read as "all clean" or "all broken". Test a
   probe against a known-bad sample first.
7. **`shfmt -d` alone** reports formatting noise from style it disagrees with; use the
   repo's full flags.
8. **A gate that skips.** A missing checker must fail under the CI flag, or the lane is
   decoration.
9. **Inventing types in parallel.** Two writers, two `Config` types. Step 2 exists for
   this.
10. **Stale generated output** and **coverage denominator drift**, both above in Step 5.
11. **Pushing before the aggregate gate runs.** One CI cycle costs more than one local
    run.
12. **Reverting a shared test to make it pass.** Adjust the source or the placement of
    new content so a pinned assertion stays untouched; a reverted file is a signal you
    edited a hotspot.
