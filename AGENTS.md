# evo-t1-coder-stack

Compose stack for a GMKtec EVO-T1: Coder, LiteLLM, IPEX-LLM Ollama, Kasm, Homepage. Operator docs live in README.md. Shell conventions live in docs/project-conventions.md. Branch rules live in docs/branching.md.

## Commands

Prefer Bazelisk. Make targets are shims (`make lint`/`test`/`fix`/`validate` delegate to the lines below).

- test: `bazelisk test //:test-fast`
- one suite: `bazelisk test //tests:bats_<stem>_test` — the stem is the `.bats` file name with dashes written as underscores (`bats_spark_configure_test` for `spark-configure.bats`)
- lint: `bazelisk test //:lint --test_tag_filters=manual`
- fmt: `bazelisk run //:fix`
- gate: `bazelisk run //:validate`

Those four are the primary entry points. Everything else that runs a script is a run target in the same file stem's spelling — `bazelisk run //scripts:<stem> -- <args>`, keeping the script's dashes (`//scripts:dev-stack`, `//scripts:new-workspace`, `//scripts:push-template`):

- dev stack: `bazelisk run //scripts:dev-stack -- up` (also `down`, `status`, `logs`, `reset`, and `--project-name`, default `evo-t1-dev`)
- new workspace: `bazelisk run //scripts:new-workspace -- --dry-run <git-url>`

`scripts/setup-host.sh` is the one script run straight from a shell (`bash scripts/setup-host.sh`, or `--check` to report what is missing): it installs Bazelisk and the lint toolchain, so it necessarily runs before Bazel exists. Every other script reaches the sandbox through a Bazel target, which is also why none of them is invoked by relative path from another script.

Done means `bazelisk test //:test-fast` and the lint target are green, and a change that touches the stack has been re-upped and checked on the dev stack first (`bazelisk run //scripts:dev-stack -- up`, README "Testing changes locally").

## Structure

- `scripts/*.sh` — operator CLIs
- `scripts/lib/*.sh` — sourced helpers. Entry scripts call these instead of copying log/die/json helpers.
- `templates/workspace/` and `templates/devcontainer/` keep independent `.tftpl` copies (`startup.sh.tftpl`, `settings.json.tftpl`, `grok-config.toml.tftpl`). The twins must change together — only `settings.json.tftpl` is byte-identical across the two directories, so edit both copies of any payload.
- `tests/bats/` — hermetic Bats. Stubs live in `tests/bats/tool_stubs/`: docker, ssh, curl and the other external tools resolve through stubs, so no suite touches the network or a real daemon.
- Workspace `~/.grok` is one profile volume per user in `shared` mode (default; `grok-profile-<owner-id>`), and its single `config.toml` is re-rendered by the last-booted workspace of that owner — last boot wins. See README, section "Grok Build state: one shared profile per user".
- Runtime is still `docker compose`. Do not add a Kubernetes layer.
- Routing: LiteLLM is the sole model transport — the Coder Agents chat through the `litellm` provider + `agent`/`chat` model configs + lane pins that `scripts/coder-agents.sh` wires, and each workspace's Grok Build through the rendered `~/.grok/config.toml`. Inside the `agent` group, `session_affinity` pins a workspace's conversation to one healthy Spark box while that pinned backend stays healthy, `least-busy` picks for unpinned traffic, and `agent` → `coder` is the last-resort text-only fallback. Never re-add per-deployment rpm/tpm caps.
- GitHub auth is Coder External Auth, provider id `primary-github`, and nothing else. There is no GitHub-token template variable and no PAT in `.env`, in an agent env map, or in a rendered `config.toml` — do not reintroduce one.

## Working rules for an AI agent

- Work on a short-lived branch cut from the current tip of `main` (`feat/…`, `fix/…`, `refactor/…`, …), one change per branch, and open the PR against `main`. See docs/branching.md.
- Prefer small, focused changes. One problem per branch is what makes a revert cheap.
- Default to ONE repository per workspace. Multi-repo is opt-in (`--additional-repos`, README "Cloning more than one repository") and only when it is asked for.
- Run `bazelisk test //:test-fast` and `bazelisk test //:lint --test_tag_filters=manual` before calling work done, and read the output — a green summary from a sub-agent is not a test run.
- A change that affects the running stack gets checked on the dev stack first (`bazelisk run //scripts:dev-stack -- up`), which is a separate compose project with its own volumes and host ports, so the stable instance stays up while you test.
- Prefer a Bazel target over executing a script directly, in docs and in scripts alike. A script run from a foreign cwd cannot find the repo files it reads by path.
- Never introduce a static GitHub token, in code, docs, fixtures or env samples: External Auth `primary-github` is the only credential path, and placeholders stay placeholders.

## Tests

Ship tests in the same change as the shell they cover. A new function needs a `# @function` block (Globals, Arguments, Outputs, Returns) and an asserting Bats test. `//tests:shell_inventory` and `//tests:doc_coverage` enforce that.

No `eval`. Prefer `"${var}"`, `[[ ]]`, and `$(...)`.

## Branching

Trunk-based: `main` is the only long-lived branch and stays deployable. Integrate with a PR into `main` once CI is green; there are no environment branches (`dev`, `staging`, `prod`, `uat`) to merge forward, and a `fix/…` branch lands on `main` first and deploys from there. docs/branching.md is the rule, this section is the reminder. Commits use `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, or `refactor:` plus an imperative summary.
