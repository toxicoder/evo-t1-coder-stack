# evo-t1-coder-stack

Compose stack for GMKtec EVO-T1: Coder + LiteLLM + IPEX-LLM Ollama + Kasm + Homepage. Operator docs in README.md. Shell conventions in docs/project-conventions.md. Branching in docs/branching.md.

## Where you run

You are usually editing this repo *from inside one of the workspaces it deploys*, not
from the stack host. `CODER_WORKSPACE_ID` set means you are in a Coder workspace
container (and, on the `devcontainer` template, inside a dev container built on that
workspace's own DinD sidecar). Assume all of this until you prove otherwise:

- `docker` addresses that sidecar daemon (`DOCKER_HOST=tcp://dind:2375`) or nothing,
  never the daemon running Coder/LiteLLM/Ollama/Kasm. An empty `docker ps` here is
  normal; it does not mean the stack is down.
- Whole-stack commands (`dev-stack`, `refresh-configs`, `storage-clean`, `pull-models`,
  `search-check`, `spark-verify`) work on the stack host or on the fleet, not on this
  workspace, so run them in a host shell. `search-check` probes
  `http://127.0.0.1:8181` by default and reads `$SEARXNG_URL` first; the agent env inside a
  workspace carries `SEARXNG_URL` (default `http://host.docker.internal:8181`), so a
  workspace-side probe needs no `--url`.
- `github-auth check` (also `bazelisk run //scripts:github-auth -- check`) works from
  either place: on the host it enumerates the labeled workspace containers via docker,
  or probes a named container; inside a workspace it runs SELF mode with no docker and
  no `DOCKER_HOST`, probing this environment's own credential chain and printing one
  `self:` line. Pass only the repo URL there; a named container is refused with a
  pointer to the host shell.
- `host.docker.internal` and `172.17.0.1` are the stack host: `:4000` LiteLLM,
  `:3002` the Coder agent tunnel, `:8181` SearXNG.
- The `~/.grok` you see here is one volume per owner, shared with that owner's other
  workspaces, and the last-booted workspace re-renders the shared `config.toml` for all
  of them. A file carrying the stack marker (`managed-by: evo-t1-coder-stack`, or the
  `"__evoT1Stack": true` key) is stack-owned: change the seed in this repo and
  re-materialize it, never the copy that lives in a workspace.
- Bazel behaves the same here, so `//:test-fast`, `//:lint` and
  `bazelisk run //scripts:<stem>` all still run.

## Commands
Prefer Bazelisk. Make is a shim.

- test: `bazelisk test //:test-fast`
- one suite: `bazelisk test //tests:bats_<stem>_test` (dashes → underscores)
- lint: `bazelisk test //:lint --test_tag_filters=manual`
- fmt: `bazelisk run //:fix`
- gate: `bazelisk run //:validate`
- scripts: `bazelisk run //scripts:<stem> -- <args>` (keep dashes)
- dev stack: `bazelisk run //scripts:dev-stack -- up|down|status|logs|reset`
- prod (stable) stack: `bazelisk run //scripts:prod-stack -- up|down|status|logs|reset`
- new workspace: `bazelisk run //scripts:new-workspace -- --dry-run <git-url>`
- config refresh: `bazelisk run //scripts:update-configs -- env|workspace|all`
  (`workspace` addresses docker, and inside a workspace the CLI only reaches that
  workspace's own DinD sidecar — run it in a host shell or name `--container`/`--home`)

`scripts/setup-host.sh` is the only script run from shell (installs Bazelisk; `--repair` recovers leftover runfiles so `bazelisk run` can start). Everything else is a Bazel target.

Done means `//:test-fast` + lint green. Stack changes must be verified on the dev stack first.

## Structure
- `scripts/*.sh` — operator CLIs; `scripts/lib/*.sh` — sourced helpers (do not copy log/die helpers).
- `templates/workspace/` and `templates/devcontainer/` keep independent `.tftpl` payload copies (edit both twins when changing one). `templates/common/` exists once instead and both templates consume it: `GROK_BUILD_AGENTS.md` (the seed text the startup scripts inline) and `vscode-alt.svg` (the editor icon), each staged by the push plumbing beside the staged `main.tf` and read there with `file()` / `filebase64()`; pushing without either fails early by design. The SVG must produce a data URL of at most 256 characters (`workspace_apps.icon` is varchar(256) on Coder v2.36).
- `tests/bats/` — hermetic Bats; stubs in `tests/bats/tool_stubs/`.
- `searxng/settings.yml`, `homepage/**`, `proxy/*.conf` — payloads bind-mounted read-only. `proxy/certs/` is `.bazelignored` (bootstrap issues those on the host). A new top-level payload directory (or an unlisted `scripts/*.sh`) is invisible to `test-fast` and `lint` until it is added to `//:stack_data` / `//scripts:doc_sources`, and `//:validate` parses YAML only under `homepage/config/*.yaml` and `litellm/config.yaml`.
- Workspace `~/.grok` is one shared profile volume per user (`grok-profile-<owner-id>`) by default. Last-booted workspace re-renders `config.toml`.
- Runtime is `docker compose`. Do not add Kubernetes.
- LiteLLM is the sole model transport. Never re-add per-deployment rpm/tpm caps. GitHub auth is only Coder External Auth (id `github` by default, or `CODER_EXTERNAL_AUTH_0_ID` from coder.env); never introduce a static token or PAT.

## Working rules
- Short-lived branch from tip of `main` (`feat/`, `fix/`, `refactor/`, …), one change per branch, PR into `main`.
- Prefer small focused changes. Default one repository per workspace.
- Prefer Bazel targets over direct script execution.
- Never introduce a static GitHub token anywhere.

## Tests
Ship tests with the shell they cover. New function needs a `# @function` block and an asserting Bats test. `//tests:shell_inventory` and `//tests:doc_coverage` enforce this. No `eval`. Prefer `"${var}"`, `[[ ]]`, `$(...)`.

## Branching
Trunk-based: `main` is the only long-lived branch. Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, `refactor:` + imperative summary.
