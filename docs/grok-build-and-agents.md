# Grok Build, Coder Agents, and the workspace terminal

Deep reference for what runs *inside* a workspace and in the Coder control plane: the
terminal profiles, the per-user `~/.grok` profile, where the CLI and the chat agent get
their models, and what the stack seeds for the agent.

Contents:

1. [Terminal and editor defaults](#terminal-and-editor-defaults)
2. [The Grok Build CLI in the golden image](#the-grok-build-cli-in-the-golden-image)
3. [The rendered `~/.grok` config](#the-rendered-grok-config)
4. [Grok Build state: one shared profile per user](#grok-build-state-one-shared-profile-per-user)
5. [Search lane and MCP servers](#search-lane-and-mcp-servers)
6. [Coder Agents (control-plane)](#coder-agents-control-plane)
7. [The delegation sketch](#the-delegation-sketch)

Related: [coder-templates.md](coder-templates.md) (the template files themselves),
[litellm-routing.md](litellm-routing.md) (what the aliases route to), and
[troubleshooting.md](troubleshooting.md).

## Terminal and editor defaults

- `terminal.integrated.defaultProfile.linux` is `tmux`; the automation profile stays
  `/bin/bash`, so build and task commands never wait on tmux. Plain `bash` and **Grok
  Build** stay available as extra profiles.
- The `tmux` profile re-joins (or starts) one session per folder, named
  `vscode-<folder>-<hash>`. A second terminal window, a browser reload, or
  `ssh` + `tmux attach -t <session>` lands in that same session, and a long job
  survives closing the tab. `tmux ls` lists the names.
- **Grok Build** keeps its own session, keyed off the repository: the helper walks up
  from the terminal's folder with `git rev-parse --show-toplevel` (or uses the
  terminal's `$PWD` outside a clone), names the session `grok-build-<folder>-<hash>`
  after that root, and runs `grok --cwd <repo root>` inside it. A terminal opened
  anywhere inside the clone rejoins the one session the repository shares, and starts
  Grok Build at the repository root.
- With no tmux (offline first boot) the helper execs a plain login shell, so the
  default terminal still opens.
- `display_apps.web_terminal` stays **off**: it would open a shell on the agent's
  working dir (`/home/coder`). A custom command-type `coder_app` named **Web
  Terminal** (`order = 6`, after **VS Code Web** at `order = 5`, before **GitHub
  reauth** at `order = 7` and **Install GitHub App** at `order = 8`) takes that slot,
  `cd`s to the clone folder - an empty `repo_url` keeps it on `/home/coder` - and
  execs a login shell. Like the built-in, it reads no `terminal.integrated.*`
  settings.
- Neither template installs code-server through the Registry. Each `main.tf` carries
  an inlined fork (`coder_script.code_server` + `coder_app.code_server`), because the
  upstream module hardcodes `/icon/code.svg` and has no icon input. `workspace`
  installs code-server only when it is missing from `/home/coder/.local/share/code-server`
  and starts it with `--auth none --port 13337 --app-name "VS Code Web"
  --ignore-last-opened <folder>`, passing no settings payload. `devcontainer` has no
  persistent prefix to reuse, so it installs fresh under `/tmp/code-server` on every
  start.
- The editor opens on `http://localhost:13337/?folder=<urlencoded>`: the
  `coder_app` resource in `coder/coder` `~> 2.18` has no `folder` argument, so the
  folder rides in the URL and as a positional argument to the code-server binary
  with `--ignore-last-opened`. `workspace` uses `/home/coder/workspace/<repo>` (and
  `/home/coder` with no repository); `devcontainer` uses `/workspaces/<repo>` inside a
  built dev container and `/srv/coder-devcontainers/<workspace-id>/<repo>` on the
  plain container.
- The icon travels as a `data:image/svg+xml;base64` data URL read from
  `templates/common/vscode-alt.svg`: Coder serves icons only from its bundled
  `/icon/*` set or a full `https`/`data` URL, and that icon is not bundled.
  `workspace_apps.icon` is `varchar(256)` on Coder v2.36, so the SVG is a compact
  ribbon whose data URL fits that column; a larger file fails `templates push`
  with `pq: value too long for type character varying(256)`.

## The Grok Build CLI in the golden image

- Baked in at `/usr/local/bin/grok`, with an `agent` link beside it, **outside** the
  `/home/coder` home volume, so a rebuilt volume cannot lose it.
- Pinned as `GROK_VERSION` in `images/dev/tool-versions.env` (1.0.44 at the time of
  writing). The image build unpacks that pinned `.zst` and runs `grok --version` in
  two PATH contexts as a build-time smoke check.
- Each template's startup script probes `command -v grok` on every start and
  re-downloads from `https://x.ai/cli/install.sh` - bounded, with retries - only
  while `grok` is missing from PATH. That installer follows the `stable` pointer, not
  this pin.
- A self-installed CLI under `~/.grok/bin` stays first on the login-shell PATH, so it
  wins over the baked copy.

## The rendered `~/.grok` config

Rendered per workspace from `templates/workspace/grok-config.toml.tftpl` (and
`templates/devcontainer/`'s copy of the same payload), and re-rendered idempotently
while the managed block is intact.

- `[models] default` points at the `grok_default_model` alias - `agent` unless the
  template variable or the create form's **Grok default model** dropdown names
  another.
- The four aliases (`agent`, `coder`, `coder-fast`, `chat`) are defined with
  `base_url` set to `litellm_url` and `env_key = "LITELLM_API_KEY"`. The key is
  injected as an environment variable, so it never appears in a file.
- `[models]` also carries `extra_headers` with
  `x-litellm-session-id: ws-<workspace-id>` - the key LiteLLM uses to pin a
  workspace's traffic to one healthy Spark box. Under a shared profile the
  last-booted workspace's key wins for the whole fleet.
- `github_mcp` (default `false`) adds the `github` HTTP MCP server
  (`https://api.githubcopilot.com/mcp/`), whose `Authorization` header references
  `${GH_TOKEN}` **by name**, so no token value is ever part of a template variable.
  The agent environment fills it from the Coder External Auth provider (id `github` by default); a
  workspace whose owner connected no GitHub account renders the block anyway and pays
  one failed handshake per session.
- `context7_mcp` (default `false`) adds the cached `context7` stdio MCP server. Grok
  launches `/opt/npm-global/bin/mcp-cache-proxy` with
  `--config /home/coder/.grok/mcp-cache-proxy/config.json`, and that proxy fronts the
  official `/opt/npm-global/bin/context7-mcp`; both are pre-installed in the golden
  image, so nothing is fetched with `npx` at launch. The proxy config names
  `$CONTEXT7_API_KEY` and nothing else: the key reaches the workspace environment from
  the sensitive template variable `context7_api_key`, filled by the push from
  `CONTEXT7_API_KEY` in the host `.env` - not from Coder External Auth, which is what
  fills `GH_TOKEN` above.
- `grok_config_extra` appends whatever the create form's **Grok config extras** field
  holds, verbatim under its own comment header.
- The managed block is guarded by a `managed-by: evo-t1-coder-stack` marker, so a
  hand-edited config is left alone.

## Grok Build state: one shared profile per user

Every workspace gets its own `/home/coder` volume, and `~/.grok` is a **second,
nested** mount inside it: a Docker volume named `grok-profile-<owner-id>`,
referenced by name rather than declared as a Terraform resource, which every
workspace of that owner mounts read-write at the same path **while that workspace is
in `shared` mode**.

### The two modes

- `shared` (the default here, so a workspace gets the profile unless you turn the
  mode off): configure the CLI once and the rest of that account's workspaces
  inherit it.
- `private`: that workspace's `~/.grok` - `config.toml` included - lives on its own
  home volume, differs from its siblings, and dies with the workspace (or survives a
  rebuild on the same volume).
- Set in two places: the template variable `grok_profile_mode`
  (`GROK_PROFILE_MODE=shared|private` in `.env`, forwarded by `push-template.sh` as
  `--var grok_profile_mode`), and the create form's per-workspace **Grok profile**
  field, which defaults to the variable. One workspace can therefore sit outside the
  shared profile while its siblings stay inside it.
- Changing the mode needs a **rebuild** - the nested mount either exists or it does
  not. A workspace that goes from `shared` to `private` starts on an empty profile:
  nothing is copied, and the shared volume is left alone.

### What is shared

In `shared` mode: `config.toml`, `skills/`, `memory-v2/`, `sessions/`, `notes/` (the
canonical copy of each repository's private scratch `notes.md`), and a CLI you
installed yourself under `~/.grok/bin`.

`notes/<host>/<owner>/<repo>/notes.md` is keyed per git remote, so every clone a
workspace holds — the primary and each additional repository — has its own file. What you
edit is the regular file at the clone root: that is what the editor, the terminal and a
nested dev container all see, since the inner container mounts the clone bind and has
its own `~/.grok`. The startup script copies that file here on every start and restores
it when a recreate leaves the clone without one. `grok_profile_mode=private` mounts no
shared volume, so those notes die with that workspace; `shared` is the default. Like
`config.toml`, the last workspace started for a given user and repository wins.

Two things about that start are worth knowing before you go looking for a vanished
setting. Boot **writes `git config --global core.excludesFile`** — but only when you
have not set it yourself. Left unset it points at `~/.grok/notes/exclude`, which lists
`notes.md` and `.scratch-notes.md`, so from then on *every* git repository in that
workspace ignores both names at any depth; if you already set the option, those two
lines are appended to the file it names and nothing else about it is touched. Boot also
drops the same two lines into each clone's own `.git/info/exclude`, which is the layer
that works even with no global config at all. And when a repository tracks a `notes.md`
of its own, the scratch file is written as `.scratch-notes.md` beside it instead — your
clone is never asked to delete somebody else's committed file.

### Caveats, honestly

- Keyed by **owner id**, never host-wide and never cross-user: another user's
  workspace mounts a differently named volume, and a stop or start of a *different
  user's* workspace never sees the volume at all.
- The memory and index files are SQLite, opened live by every workspace holding the
  mount, so two workspaces writing memory at once can race. *Roughly in sync* is the
  bar, not transactional sharing.
- One shared profile is one `config.toml` for every workspace that owner owns, and
  the last boot to re-render it wins - for the default model, the affinity key and
  the config extras alike.

## Search lane and MCP servers

- `searxng` (SearXNG metasearch, host port 8181) is the search backend the stack runs
  for itself: keyless engines only, no key, no account, no request logging. A
  workspace reaches it through the host gateway, so the workspace networks stay
  untouched.
- It is **not** a model transport, so `web_search = "agent"` and
  `supports_backend_search = false` stay as they are and the agent's own `web_search`
  tool still digests through the `agent` alias. Native search is the default:
  `disable_web_search = false` keeps the `web_search` tool in the session (it has no
  hosted backend on this box - LiteLLM answers "tools of type 'web_search' are not
  supported" - so the client-side scrape path is what runs). The `searxng` MCP stdio
  server is the fallback: both templates render that block gated on `search_mcp`,
  which defaults to true. To park native search, set `disable_web_search` to true
  and start a new session. Measure the self-hosted lane with:

  ```sh
  bazelisk run //scripts:search-check
  ```

  An empty result page and "no answer" are different answers, which is why the probe
  reports which one it got.

- **MCP servers: the default render declares exactly one, the gated `searxng`
  server (the fallback search lane).** It names the pre-installed
  `searxng-mcp-server` binary (pinned in `images/dev/tool-versions.env` and baked
  into the golden image), is gated on `search_mcp` (default true) and dials the
  service above through `SEARXNG_URL`.
  The five offline stdio servers (`filesystem`, `memory`, `sequential-thinking`,
  `git` and `time`) stay pre-installed in the image (`npm -g` for the first
  three, `uv tool` for the Python two), but the rendered `config.toml` names
  none of them: the session traces collected on this machine called none of
  their tools, and a declared-but-unused server still costs every session its
  handshake time and tool schemas. Declare one by hand and check a stubborn
  server with `grok mcp doctor <name>` inside a workspace. The `github` server
  is one opt-in exception: it needs a token and outbound network, so
  `github_mcp` (default false) decides on its own whether the block is rendered.
- The `context7` server (library and API docs) is the other opt-in exception, and the
  only cached one. `context7_mcp` (default false) decides the same way, and the block it
  renders runs `mcp-cache-proxy` in front of the official `context7-mcp` - two packages
  pinned in `images/dev/tool-versions.env` and baked into the golden image, so turning
  it on takes an image rebuild plus a template push, not just a flag. The proxy keeps
  its SQLite cache under `~/.grok/mcp-cache-proxy/`, which rides the owner's shared
  profile volume in `shared` mode, and the cache TTL is 12 h: the first lookup of a
  library reaches the Context7 API and needs both network and `CONTEXT7_API_KEY`, while
  an identical lookup inside the TTL is answered locally. Two tools, in order -
  `resolve-library-id`, then `query-docs` on the id it returns. Prove it with
  `grok mcp doctor context7` inside a workspace.
- Cline and Roo/Kilo are pre-wired to the LiteLLM proxy (endpoint from `litellm_url`,
  default `http://host.docker.internal:4000/v1`; model alias `agent`, with
  `coder`/`coder-fast`/`chat` listed in `__evoT1StackModels`). The seed is
  `settings.json.tftpl`, copied onto the per-owner volume
  `vscode-settings-<owner-id>` (mounted at `~/.shared/vscode/settings.json`) only
  while that file is absent, and symlinked from
  `~/.local/share/code-server/User/settings.json`. Startup chowns that volume to
  the home owner before the first write (empty named volumes are `root:root`
  755). Edits stick, and every workspace
  that owner has shares the file; delete it to copy the template in again. From the
  host it is the volume's `settings.json`:

  ```sh
  docker run --rm -it -v vscode-settings-<owner-id>:/vscode alpine vi /vscode/settings.json
  ```

- A built dev container mounts neither the volume nor the symlink, so it is the one
  place the seed is **merged** instead of linked: the inlined
  `coder_script.code_server` fork bakes a base64 copy of it and writes it over the
  dev container's private `User/settings.json` (or merges over a copy that survived a
  rebuild, when `jq` is on PATH; without `jq` the existing file is kept). Edits
  inside a built dev container therefore survive neither a rebuild nor a look at the
  shared file. Everywhere else no settings map is passed at all, because a merge
  would replace the symlink.
- Installing Cline, Roo, the Red Hat YAML extension and Material Icon Theme is a
  manual step in the Extensions panel (Open VSX by default). If an extension build
  names its settings differently, set the OpenAI-compatible endpoint and key in its
  UI.

## Coder Agents (control-plane)

Coder v2.36.6 ships *Coder Agents*: a coding agent that lives in the Coder **server** -
a chat UI and an API beside your workspaces, not inside one. A chat runs its tools
(`read_file`, `edit_files`, `execute`, `spawn_agent`) against a workspace over that
workspace's agent connection, and consults two pieces of per-workspace context first:
an **instructions** file and any **skills** it discovers. The agent itself is upstream
Coder, not a home-grown agent.

### It is always on

The chat agent is compiled into coderd unconditionally.

- `CODER_EXPERIMENTS` in `.env` (empty by default since 2026-10-08) has never gated
  anything about it: the old `agents` default was not a recognized experiment name,
  and the server logged `ignoring unknown experiment` and ignored it on every boot.
- `workspace_external_agent`, the entitlement the docs name, gates *external* agents
  (Claude Code, Codex, ...), not this one, and nothing here needs it.
- If you know a real experiment you want (`chat-advisor`, `chat-virtual-desktop`,
  ...), list it in `.env` and restart the coder service. Empty means no experiments
  on.

### Model wiring

Scripted, idempotent, re-runnable. Print the plan:

```sh
bazelisk run //scripts:coder-agents -- --dry-run
```

Apply it:

```sh
bazelisk run //scripts:coder-agents -- --apply
```

A chat turn needs an enabled chat model config - the chat's own pick, else the
deployment default, else it errors before the first tool call - and that wiring is
what the script writes. It mints a short-lived admin API token from the stack's own
Postgres (`token_name 'stack-coder-agents'`, deleted by the trap, never printed) and
drives the server's experimental chat API:

- an `openai-compat` AI provider named **`litellm`** (not `litellm-auto`), base URL
  `http://litellm:4000/v1` - LiteLLM over the compose network, *server-side*,
  authenticated with `LITELLM_MASTER_KEY`. The agent dials the in-process AI Gateway
  (aibridge), which forwards to the provider's `base_url` + `/chat/completions`, so
  `/v1` has to be part of the base URL and the key has to match the live proxy: with
  `.env` leaving the key empty, compose still boots the proxy on its
  `change-me-litellm` interpolation default, and that default is what gets sent.
  Created when absent, drift-patched when an existing provider carries a drifted
  `base_url` or key.
- chat model configs `agent` (context limit 262144, set as the default) and `chat`
  (32768), for models not already registered. `coder` and `coder-fast` stay out on
  purpose: on this stack's IPEX-LLM runtime those weights return tool calls as plain
  text with no `tool_calls`, and an agent turn without callable tools cannot browse
  or edit, so registering them would only add a silently broken model to the
  pickers. `context_limit` is the agent's own compaction budget (a 70 per cent
  default compaction threshold applies), which is why it is pinned per alias.
- pins for the four auxiliary lanes - `general` and `explore` (the two subagent
  types) take `agent`, `compaction` and `title_generation` (the helper calls) take
  `chat` - written only for lanes that carry no pin yet, so an admin's own pins stay
  in place.
- a three-line system-prompt addendum, appended after Coder's default prompt text
  (`include_default_system_prompt: true`), that keeps the delegation and
  secret-hygiene rules which must hold even when a chat has no workspace attached.

Coder's optional AI Gateway proxy stays off - LiteLLM remains the model transport,
which is why no AI-Gateway keys exist in `docker-compose.yml`.

### The delegation sketch

Chat on the Agents page -> if the ask needs more tooling than chat has, Coder Agents
provisions or uses a workspace through `execute` -> big multi-file tasks are
*delegated inside* that workspace: a headless Grok Build CLI run, started backgrounded
and polled:

```sh
grok -p "<task brief with acceptance criteria>" --cwd <repo> --permission-mode acceptEdits --max-turns <budget>
```

Backgrounded and polled because `execute` waits only a short window per tool call
(about a minute), so a synchronous foreground `grok -p` would die mid-run on any big
task. Coder Agents then reviews the delegated diff, runs the project's tests, and
commits. Subagents spawned by Coder Agents cannot create workspaces: provisioning
decisions stop at the top-level chat.

### What seeds the agent's context

Four files seed into every new workspace, on first boot and only while the file is
absent:

1. `~/.coder/AGENTS.md`
2. `~/.coder/skills/grok-build-delegation/SKILL.md`
3. `~/.agents/INSTRUCTIONS.md`
4. `~/.agents/skills/grok-build-delegation/SKILL.md`

- 1 and 2 are the Coder agent's *default* discovery paths.
- 3 and 4 are the same text under the Grok Build CLI's convention, and the CLI is
  what `execute`-lane delegation drives. The chat agent dedupes skills by name,
  first match wins, home scope before a working-dir path, so one agent never loads a
  skill twice: the twins exist for the CLI, not as a second source for chat.
- The text is the orchestration protocol (fan-out / fan-in, the edit-conflict gate,
  probe-one-worker-first, verify-what-a-worker-actually-produced). It travels as
  `templates/common/GROK_BUILD_AGENTS.md`, staged beside the staged `main.tf` and
  read back with `file()` / `filebase64()`; `templates/common/` keeps one copy for
  both templates, and the push stages it into each template's pushed copy.
- `devcontainer` and `workspace` both seed it, so the seed is *not* fetched from
  GitHub any more: no `web_search`/`web_fetch` call is needed to inspect this repo,
  and the instruction text tells the agent so.
- Both `main.tf` files deliberately set **no** `CODER_AGENT_EXP_*` env keys on
  `coder_agent.main`: those keys *replace* the agent's discovery defaults, and the
  defaults already cover exactly the seeded paths - the `~/.coder` roots plus a
  working-dir-relative `.agents/skills`, which resolves inside the agent's working
  dir (`/home/coder` in `workspace`; in `devcontainer` with the toggle on, the
  cloned folder under `/srv/coder-devcontainers/...`, where a dev container built on
  the sidecar carries its own home and no seeded path is visible from inside it
  anyway).
- Each seeded file carries the `managed-by: evo-t1-coder-stack` marker - in
  `SKILL.md` directly under the `---` frontmatter, since the agent's skill parser
  requires frontmatter on line 1 and silently drops anything else. Delete a file to
  take it over; edit it and the stack leaves it alone. Either way the marker never
  reaches the model: the agent strips HTML comments from injected instruction text.
- The seeds live per workspace, on that workspace's own home volume. They are *not*
  on the shared `~/.grok` profile volume above, and seeding does not care whether
  that mount exists.

### What this is not

Coder Agents is control-plane-native. This stack does not wrap Grok Build: the wiring
above *teaches* (skill + instructions) and *equips* (the workspace-side CLI with its
LiteLLM alias) the native Coder agent to drive Grok Build when work is too big to
hand-drive. Delegation is a taught habit, not the product.
