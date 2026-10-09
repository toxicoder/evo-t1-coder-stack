# evo-t1-coder-stack

Compose stack for a GMKtec EVO-T1: Coder, LiteLLM, IPEX-LLM Ollama, Kasm, Homepage. Operator docs live in README.md. Shell conventions live in docs/project-conventions.md.

## Commands

Prefer Bazelisk. Make targets are shims.

- test: `bazelisk test //:test-fast`
- one suite: `bazelisk test //tests:bats_<stem>_test`
- lint: `bazelisk test //:lint --test_tag_filters=manual`
- fmt: `bazelisk run //:fix`
- gate: `bazelisk run //:validate`

Done means `bazelisk test //:test-fast` and the lint target are green.

## Structure

- `scripts/*.sh` — operator CLIs
- `scripts/lib/*.sh` — sourced helpers. Entry scripts call these instead of copying log/die/json helpers.
- `tests/bats/` — hermetic Bats. Stubs live in `tests/bats/tool_stubs/`.
- Runtime is still `docker compose`. Do not add a Kubernetes layer.

## Tests

Ship tests in the same change as the shell they cover. A new function needs a `# @function` block (Globals, Arguments, Outputs, Returns) and an asserting Bats test. `//tests:shell_inventory` and `//tests:doc_coverage` enforce that.

No `eval`. Prefer `"${var}"`, `[[ ]]`, and `$(...)`.

## Branching

Integrate with a PR into `main`. Commits use `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, or `refactor:` plus an imperative summary.
