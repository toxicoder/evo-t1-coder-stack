# evo-t1-coder-stack

Compose stack for GMKtec EVO-T1: Coder + LiteLLM + IPEX-LLM Ollama + Kasm + Homepage + Hermes. Operator docs in README.md. Hermes host assistant in docs/hermes.md. Shell conventions in docs/project-conventions.md. Branching in docs/branching.md.

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
  `self:` line per credential. `--source=<slot>` (chain, env, gh, mint) narrows it to
  one slot, and any answer about a slot the env pair outranks is labelled `shadowed`,
  because git and gh consult `GH_TOKEN`/`GITHUB_TOKEN` first. Pass only the repo URL
  there; a named container is refused with a pointer to the host shell.
- `host.docker.internal` and `172.17.0.1` are the stack host: `:4000` LiteLLM,
  `:3002` the Coder agent tunnel, `:8181` SearXNG, `:9119` Hermes dashboard
  (LAN listener; the public name rides the router on `:8080`; the host
  assistant, not a workspace agent).
- The `~/.grok` you see here is one volume per owner, shared with that owner's other
  workspaces, and the last-booted workspace re-renders the shared `config.toml` for all
  of them. A file carrying the stack marker (`managed-by: evo-t1-coder-stack`, the
  `"__evoT1Stack": true` JSON key, or the `__evoT1Stack = true` TOML key in
  `~/.grok/config.toml`) is stack-owned: change the seed in this repo and
  re-materialize it, never the copy that lives in a workspace. `~/.grok/notes-setup.sh`
  and `~/.grok/notes/` (the canonical per-repo scratch `notes.md`) are both stack-owned
  and rewritten on every start; that start also sets `core.excludesFile` to
  `~/.grok/notes/exclude` when you never set it, which is why `notes.md` and
  `.scratch-notes.md` are ignored in every repo here.
- Bazel behaves the same here, so `//:test-fast`, `//:lint` and
  `bazelisk run //scripts:<stem>` all still run.
- `EVO_T1_DEVCONTAINER=1` instead of `CODER_WORKSPACE_ID` means the **contributor** dev
  container (laptop or the CI image built from `images/dev/`), not a Coder workspace: same
  golden image, `github-auth check` runs SELF there too, and
  `bazelisk run //scripts:test-in-image --` is the host ingress that docker-runs the gate in
  `evo-t1-dev:latest`. Coder workspaces of *this* repo still stay on the `workspace`
  template — `.devcontainer/contributor-env` makes `new-workspace`'s probe a miss, so never
  copy that sentinel into another repo. `scripts/setup-host.sh` remains the stack-host
  bootstrap only.

## Commands
Prefer Bazelisk. Make is a shim.

- test: `bazelisk test //:test-fast`
- one suite: `bazelisk test //tests:bats_<stem>_test` (dashes → underscores)
- lint: `bazelisk test //:lint --test_tag_filters=manual`
- fmt: `bazelisk run //:fix`
- gate: `bazelisk run //:validate`
- full gate (what pre-push and CI run): `bazelisk test //:test-all`
- gate on demand: `bazelisk run //scripts:pre-commit -- [--all|--image]`
- install the commit/push hooks once: `bazelisk run //scripts:install-hooks -- [--check|--uninstall]`
- coverage: `bazelisk test //tests:shell_coverage` (every production shell function
  executed), `//tests:py_coverage` (Python statements+branches),
  `//docs-site:unit_coverage` (docs-site functions)
- scripts: `bazelisk run //scripts:<stem> -- <args>` (keep dashes)
- dev stack: `bazelisk run //scripts:dev-stack -- up|down|status|logs|reset`
- prod (stable) stack: `bazelisk run //scripts:prod-stack -- up|down|status|logs|reset`
- pull + deploy in one step (host shell; `--dry-run` to plan):
  `bazelisk run //scripts:update-stack`
- new workspace: `bazelisk run //scripts:new-workspace -- --dry-run <git-url>`
- new repository from the scaffold (host shell; `--dry-run` to render locally only):
  `bazelisk run //scripts:new-repo -- --dry-run <name> [--lane <shell|python|typescript|go>]`
- MCP lanes: `bazelisk run //scripts:mcp-check` (declared lanes, `command=` binaries,
  lane credentials, and each server's handshake; runs inside a workspace or on the host)
- config refresh: `bazelisk run //scripts:update-configs -- env|workspace|all`
  (`workspace` addresses docker, and inside a workspace the CLI only reaches that
  workspace's own DinD sidecar — run it in a host shell or name `--container`/`--home`)
- contributor seed (laptop/CI home, devcontainer postCreate):
  `bazelisk run //scripts:seed-dev-env -- [--home DIR] [--litellm-url URL] [--context7-mcp] [--devcontainer] [--force] [--dry-run]`
  (`--context7-mcp` keeps the `[mcp_servers.context7]` block even with no
  `CONTEXT7_API_KEY` in the environment, which is what the contributor
  devcontainer passes so a laptop home matches what a workspace gets)
- gate inside the golden image, from a host that is not the contributor container:
  `bazelisk run //scripts:test-in-image --`

`scripts/setup-host.sh` is the only script run from shell, and only on the stack host (installs Bazelisk; `--repair` recovers leftover runfiles so `bazelisk run` can start, and on Linux installs public DNS so host `git pull` still resolves github.com). Everywhere else the toolchain comes from the golden image. Everything else is a Bazel target.

Done means `//:test-fast` + lint green — inside the contributor container or
`evo-t1-dev:latest` (`//scripts:test-in-image`); a native Darwin run is convenience only.
Stack changes must be verified on the dev stack first.

## Structure
- `scripts/*.sh` — operator CLIs; `scripts/lib/*.sh` — sourced helpers (do not copy log/die helpers). Python programs live in `scripts/lib/*.py`, awk programs in `scripts/lib/*.awk`, and POSIX remote probes in `scripts/lib/probes/`. Import them (`source`, `python3 file.py`, `awk -f`, `cat` + `sh -c` / `ssh`); do not embed a second language in the caller.
- Operator CLIs source `scripts/lib/common.sh` and print `== section ==`, `-> phase`, `ok:`, `warning:`, `note:`, `error:`, and a closing `summary: N ok, W warnings, F failed`. CLIs without `--json` unset `JSON_MODE` after source.
- `templates/workspace/` and `templates/devcontainer/` keep independent `.tftpl` payload copies (edit both twins when changing one). `coder_script` bodies are sibling `.tftpl` files rendered with `templatefile()`. `templates/common/` exists once instead and both templates consume it: `GROK_BUILD_AGENTS.md`, `vscode-alt.svg`, `notes-setup.sh`, `tmux.conf`, `grok-build-terminal.sh`, `vscode-terminal-tmux.sh`, `grok-build-delegation.SKILL.md`, `learn.SKILL.md`, `coder-agents.md`, `mcp-cache-proxy.json`, and `gh-token-refresh.sh.tftpl`. The push stages all of them beside each staged `main.tf`; pushing without any one of them fails early by design. The SVG must produce a data URL of at most 256 characters (`workspace_apps.icon` is varchar(256) on Coder v2.36).
- `tests/bats/` — hermetic Bats; stubs in `tests/bats/tool_stubs/`.
- `searxng/settings.yml`, `homepage/**`, `hermes/**`, `proxy/*.conf` — payloads bind-mounted read-only (`hermes/config.yaml` and `SOUL.md` are seeded into the named volume; `hermes/skills/` is mounted ro at `/opt/stack-skills`). `proxy/certs/` is `.bazelignored` (bootstrap issues those on the host). Public names are composed by `scripts/lib/domain.sh` from `STACK_DOMAIN_BASE` / `STACK_SUBDOMAIN_SUFFIX` / `STACK_ENV_LABEL` / the `*_NAME` keys: `proxy/router.conf.template` is the source, `proxy/router.conf` is its render under the shipped defaults, and `bootstrap` writes `proxy/router.gen.conf` (gitignored, and excluded from `//:stack_data` by glob `exclude`, since `.bazelignore` only covers directories) selected by `STACK_ROUTER_CONF`. Edit the naming parts, never a rendered conf. A new top-level payload directory (or an unlisted `scripts/*.sh`) is invisible to `test-fast` and `lint` until it is added to `//:stack_data` / `//scripts:doc_sources`, and `//:validate` parses YAML under `homepage/config/*.yaml`, `litellm/config.yaml`, and `hermes/config.yaml`.
- Workspace `~/.grok` is one shared profile volume per user (`grok-profile-<owner-id>`) by default. Last-booted workspace re-renders `config.toml`.
- `project-template/` is the render source for `//scripts:new-repo`, not a deployed payload.
  It is one `glob` group (`//project-template:payload`), so a new file there needs no BUILD edit; a
  new language needs a `project-template/.evo-lanes/<lane>/` directory holding at least `LANE.md`
  and `gitignore.fragment`, plus the lane id in `NEW_REPO_LANES` in `scripts/new-repo.sh` — the two
  are pinned equal by `tests/bats/project-template.bats`. The seven `__PROJECT_*__` render tokens
  are named once, in `NEW_REPO_TOKENS`; a token outside that set survives rendering into the
  customer's repo and that same suite is what catches it.
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
