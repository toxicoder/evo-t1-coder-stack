# evo-t1-coder-stack

Compose stack for a GMKtec EVO-T1: Coder, LiteLLM, IPEX-LLM Ollama, Kasm, Homepage. Operator docs live in README.md. Shell conventions live in docs/project-conventions.md.

## Commands

Prefer Bazelisk. Make targets are shims (`make lint`/`test`/`fix`/`validate` delegate to the lines below).

- test: `bazelisk test //:test-fast`
- one suite: `bazelisk test //tests:bats_<stem>_test` — the stem is the `.bats` file name with dashes written as underscores (`bats_spark_configure_test` for `spark-configure.bats`)
- lint: `bazelisk test //:lint --test_tag_filters=manual`
- fmt: `bazelisk run //:fix`
- gate: `bazelisk run //:validate`

Done means `bazelisk test //:test-fast` and the lint target are green.

## Structure

- `scripts/*.sh` — operator CLIs
- `scripts/lib/*.sh` — sourced helpers. Entry scripts call these instead of copying log/die/json helpers.
- `templates/docker-dev/` and `templates/docker-devcontainer/` keep independent `.tftpl` copies (`startup.sh.tftpl`, `settings.json.tftpl`, `grok-config.toml.tftpl`). The twins must change together — today only `settings.json.tftpl` is byte-identical across the two directories, so edit both copies of any payload. That settings seed is copied once onto the per-owner volume `vscode-settings-<owner-id>` (mounted at `~/.shared/vscode/settings.json`) and then left alone; code-server's User settings file is a symlink to it.
- `tests/bats/` — hermetic Bats. Stubs live in `tests/bats/tool_stubs/`: docker, ssh, curl and the other external tools resolve through stubs, so no suite touches the network or a real daemon.
- Workspace `~/.grok` is one profile volume per user in `shared` mode (default; `grok-profile-<owner-id>`), and its single `config.toml` is re-rendered by the last-booted workspace of that owner — last boot wins. See README, section "Grok Build state: one shared profile per user".
- Runtime is still `docker compose`. Do not add a Kubernetes layer.
- Routing: LiteLLM is the sole model transport — the Coder Agents chat through the `litellm` provider + `agent`/`chat` model configs + lane pins that `scripts/coder-agents.sh` wires, and each workspace's Grok Build through the rendered `~/.grok/config.toml`. Inside the `agent` group, `session_affinity` pins a workspace's conversation to one healthy Spark box while that pinned backend stays healthy, `least-busy` picks for unpinned traffic, and `agent` → `coder` is the last-resort text-only fallback. Never re-add per-deployment rpm/tpm caps.

## Tests

Ship tests in the same change as the shell they cover. A new function needs a `# @function` block (Globals, Arguments, Outputs, Returns) and an asserting Bats test. `//tests:shell_inventory` and `//tests:doc_coverage` enforce that.

No `eval`. Prefer `"${var}"`, `[[ ]]`, and `$(...)`.

## Branching

Integrate with a PR into `main`. Commits use `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, or `refactor:` plus an imperative summary.
