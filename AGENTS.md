# evo-t1-coder-stack

Compose stack for GMKtec EVO-T1: Coder + LiteLLM + IPEX-LLM Ollama + Kasm + Homepage. Operator docs in README.md. Shell conventions in docs/project-conventions.md. Branching in docs/branching.md.

## Commands
Prefer Bazelisk. Make is a shim.

- test: `bazelisk test //:test-fast`
- one suite: `bazelisk test //tests:bats_<stem>_test` (dashes → underscores)
- lint: `bazelisk test //:lint --test_tag_filters=manual`
- fmt: `bazelisk run //:fix`
- gate: `bazelisk run //:validate`
- scripts: `bazelisk run //scripts:<stem> -- <args>` (keep dashes)
- dev stack: `bazelisk run //scripts:dev-stack -- up|down|status|logs|reset`
- new workspace: `bazelisk run //scripts:new-workspace -- --dry-run <git-url>`

`scripts/setup-host.sh` is the only script run from shell (installs Bazelisk). Everything else is a Bazel target.

Done means `//:test-fast` + lint green. Stack changes must be verified on the dev stack first.

## Structure
- `scripts/*.sh` — operator CLIs; `scripts/lib/*.sh` — sourced helpers (do not copy log/die helpers).
- `templates/workspace/` and `templates/devcontainer/` keep independent `.tftpl` payload copies (edit both twins when changing one). `templates/common/GROK_BUILD_AGENTS.md` exists once instead: the seed text both startup scripts inline, staged by the push plumbing into each template's pushed copy, where `main.tf` reads it with `file()`.
- `tests/bats/` — hermetic Bats; stubs in `tests/bats/tool_stubs/`.
- Workspace `~/.grok` is one shared profile volume per user (`grok-profile-<owner-id>`) by default. Last-booted workspace re-renders `config.toml`.
- Runtime is `docker compose`. Do not add Kubernetes.
- LiteLLM is the sole model transport. Never re-add per-deployment rpm/tpm caps. GitHub auth is only Coder External Auth (`primary-github`); never introduce a static token or PAT.

## Working rules
- Short-lived branch from tip of `main` (`feat/`, `fix/`, `refactor/`, …), one change per branch, PR into `main`.
- Prefer small focused changes. Default one repository per workspace.
- Prefer Bazel targets over direct script execution.
- Never introduce a static GitHub token anywhere.

## Tests
Ship tests with the shell they cover. New function needs a `# @function` block and an asserting Bats test. `//tests:shell_inventory` and `//tests:doc_coverage` enforce this. No `eval`. Prefer `"${var}"`, `[[ ]]`, `$(...)`.

## Branching
Trunk-based: `main` is the only long-lived branch. Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, `refactor:` + imperative summary.
