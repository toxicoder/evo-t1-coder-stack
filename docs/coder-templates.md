---
title: Coder workspace templates
description: "Deep reference for `templates/workspace/` and `templates/devcontainer/`: what they build, how they get pushed, and what every variable means."
tags: [coder, templates, workspaces, terraform]
---

**What's on this page**

- What the two templates make, and when the `devcontainer` toggle matters
- How `push-template.sh` ships the source, and the same push by hand
- Every create-form field and template variable, with its default
- Autostop, TTLs, Docker-in-Docker, and the DinD sidecar failure modes
- Terminal and editor defaults inside the container, and workspace GitHub credentials

**What this enables**

- Choosing between the plain container and the devcontainer before you click create
- Reading a failed push or a stuck workspace against what the template actually does
- Changing a template variable without guessing which file owns it

Deep reference for `templates/workspace/` and `templates/devcontainer/`: what they build,
how they get pushed, what each template variable means, and how the create form and the
in-editor terminal and editor behave.

Related: [project-conventions.md](project-conventions.md) (shell and payload conventions),
[SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md), and
[docs/grok-build-and-agents.md](grok-build-and-agents.md)
(the long prose on the tmux profiles and the Grok Build session).

## What the two templates make

Two templates live under `templates/`, and a push covers both.

- `workspace` (`templates/workspace/`) is the plain dev container.
- `devcontainer` (`templates/devcontainer/`) is the DinD-backed one.
- `workspace` goes first, `devcontainer` last: a dependent template pushes last so a
  partial failure leaves the base template usable.
- `devcontainer` reuses `workspace`'s variables. `repo_url` exists in both; `dind` does
  not exist in `devcontainer`.
- Each template dir keeps its own independent copy of the `.tftpl` payloads
  (`startup.sh.tftpl`, `settings.json.tftpl`, `grok-config.toml.tftpl`). Change one twin,
  change the other.

### The `templates/common/` payloads

`templates/common/` exists once instead of twice, and both templates consume it.
`template_push_one` stages every file in this list beside the staged `main.tf`; a
missing one fails the push before the CLI runs.

- `GROK_BUILD_AGENTS.md` is the orchestration-protocol seed text the startup scripts
  inline into every workspace's `~/.grok/AGENTS.md` (read with `file()`, chomped).
- `vscode-alt.svg` is the editor icon (read with `filebase64()`). It stays small
  enough that the resulting `data:image/svg+xml;base64,...` URL fits Coder
  v2.36's `workspace_apps.icon` column (`varchar(256)`).
- `notes-setup.sh` is the library behind each clone's private `notes.md`. The
  startup script inlines it with `file()` the same way, writes it into
  `~/.grok/`, sources it, and calls `notes_materialize` per clone. That call also
  seeds the ignore entries that keep the file uncommitted; see "What is shared" in
  `docs/grok-build-and-agents.md` for what it writes into git config.
  Once every clone has been through it the same script calls `run_notes_watch`, which
  reaches `notes_sync_start` on the home owner's uid and leaves the container with one
  background watcher (`NOTES_SYNC_INTERVAL` seconds, 30 by default; one instance per
  container behind a `flock` on `$HOME/.notes-sync.lock`) copying each clone's notes back
  to the owner's profile volume between boots. The workspace twin watches
  `$HOME/workspace`; the devcontainer twin passes its `$dc_dir`, because those clones sit
  on the `/srv/coder-devcontainers` bind.
- `tmux.conf`, `grok-build-terminal.sh`, and `vscode-terminal-tmux.sh` are the
  terminal payloads the startup script writes. Helpers use `$folder` (not
  `$${folder}`) because `file()` contents are not re-interpolated.
- `grok-build-delegation.SKILL.md` and `coder-agents.md` are the Coder Agents
  skill and instruction seeds (chomped `file()`).
- `learn.SKILL.md` is the `/learn` orientation skill beside that delegation skill
  (chomped `file()`): the boot seeds it into `~/.coder/skills/learn/SKILL.md` and
  twin-copies it to `~/.agents/skills/learn/SKILL.md`, each only while absent. The
  CLI's own `/learn` bundle needs an x.ai sign-in this stack does not have, so this
  payload is what makes the slash command exist.
- `mcp-cache-proxy.json` is the context7 MCP cache-proxy blob the startup script
  writes, into `~/.grok/mcp-cache-proxy/config.json` and only while that file is absent
  (so a shared profile volume reuses one SQLite cache across that owner's workspaces). It
  names no secret: the empty `CONTEXT7_API_KEY` value is what tells `mcp-cache-proxy` to
  inherit `process.env`.
- `gh-token-refresh.sh.tftpl` is the shared GitHub-token refresh `coder_script`,
  rendered with `templatefile()` so `${github_auth_id}` and
  `${coder_github_app_install_url}` interpolate.
- Editing the common copy changes both templates; the staged copy overwrites any
  same-named file the template dir still carries.

### Presets

Presets collapse the create form to one click.

- `workspace`: **AI workspace** (golden image, the selected default), **Minimal shell**
  (bare `ubuntu:24.04`, for when the golden image is mid-rebuild), **AI workspace + DinD**
  (golden image plus a privileged Docker daemon).
- `devcontainer`: **Devcontainer default** (the template default) and **Plain clone**.
- Preset keys are parameter *names*; `display_name` is UI-only and would be ignored.

## How `push-template` works

`bazelisk run //scripts:push-template` runs `scripts/push-template.sh`.

1. It resolves the repo root from `BUILD_WORKSPACE_DIRECTORY` (the real checkout
   `bazelisk run` names) ahead of the runfiles copy, so `.env` and the template
   files are regular files rather than execroot symlinks.
2. It resolves the running stack on the Docker **daemon** by container label, never
   through a cwd-resolved compose project.
3. Per template it checks `main.tf` exists (otherwise "run this from the repo root") and
   notes a missing `.terraform.lock.hcl`.
4. It rejects a `coder_workspace_preset` description over Coder's 128-**byte** ceiling.
5. It rejects a `vscode-alt.svg` whose inlined data URL would exceed Coder's
   256-character `workspace_apps.icon` column.
6. It streams the source as a tar on stdin, with symlinks dereferenced into regular
   files. Coder's provisioner unpacks that archive into an empty workdir and does
   not follow host paths, so a stored runfiles symlink plans as "No configuration
   files".
7. It confirms an **active** version.
8. It re-sends the template's own description.
9. It re-pins **Autostop** to *Disabled*.

### What it does and does not do

- No `.terraform.lock.hcl` is committed under `templates/`. Each `main.tf` pins
  `coder/coder` `~> 2.18` and `kreuzwerker/docker` `~> 4.6` in `required_providers`; Coder
  pushes with a warning when no lockfile sits beside them. `coder_devcontainer` needs a
  server `>= 2.21`, which this stack runs (v2.36.6).
- `terraform init` on the server still talks to `registry.terraform.io` (and
  `registry.coder.com` for `devcontainer`'s `devcontainers_cli` module), even
  when a previous provider version is cached. The `coder` compose service
  forwards those lookups to `1.1.1.1` / `8.8.8.8` so a host whose only
  nameserver is Tailscale MagicDNS does not SERVFAIL the push. Recreate
  `coder` after pulling that compose change (`prod-stack up`) before pushing.
- `templates push` carries no description (`push` has no `--description` flag), so
  `templates edit --description` is the write. That text is the routing hint the Coder
  Agents chat reads when it picks a template to provision.
- Both the preset descriptions and the two routing hints fit the same 128-byte ceiling.
  `coder_parameter` descriptions are **not** capped (some run past 450 characters) and are
  not checked.
- A failed description edit and a failed autostop pin only add a note; neither blocks the
  template.
- A template whose push or verification failed is counted in the
  `N of M template(s) did not reach an active version` line and makes the run exit
  non-zero, while every other template still gets its push attempt.

### The one-argument ceiling

The agent runs `coder_agent.startup_script`, and every `coder_script.script`, as
`bash -c <body>`. The whole body therefore travels as **one** argument to `execve(2)`,
and Linux caps a single argument at `MAX_ARG_STRLEN`, 32 pages = 131072 bytes. Measured
on this host: an argument of 131071 bytes execs and one of 131072 fails with `E2BIG`.
Past the wall the agent logs `fork/exec /bin/bash: argument list too long` with
`exit_code=255` a few milliseconds in, the home directory never seeds, and the workspace
banner reads "A startup script has failed". Coder puts no limit there and the plan
reports no error, so the wall only announces itself on a live recreate.

The size that matters is not `startup.sh.tftpl`. `main.tf` composes the body from that
template plus every `templates/common/` payload it inlines, so any edit to the rulebook,
the skills, the tmux config, the notes seeder, or the Grok config moves the number. That
is how six commits crept from 104 KB to 130 KB and one documentation commit crossed the
wall at 135 KB.

Two things follow from the mechanism:

- **Each body is its own `execve`, so each gets its own ceiling.** Splitting a body into
  two `coder_script` resources relocates the wall; it does not raise it. On this server
  (v2.36) the start scripts fan out concurrently in an errgroup and `ready` is set only
  after all of them return, so splitting does not reduce a peak either.
  `coder_script_order` needs Coder `>= v2.39`.
- **A `#!` line does not help.** The body still becomes
  `execve(env, [env, bash, -c, body])`; the interpreter line is content inside the
  argument.

`startup_size_guard` in `scripts/push-template.sh` enforces this before the CLI runs,
beside the icon and preset-description guards. It sums each body's composed bytes and
refuses the push past `STARTUP_SIZE_BOUND` (122880, which leaves 8 KiB, about two
documentation-sized commits, under the kernel's own limit). Its reader is
`scripts/lib/startup_size.awk`; `//tests:bats_startup_script_size_test` re-derives the
same totals with an independent parser and pins the two together, so a guard that starts
measuring something else goes red in review.

When a body really does need to grow past the budget, the options are:

- **Move the prose out.** Rationale belongs in this file, not in `startup.sh.tftpl`.
  Comments in the template are bytes in everybody's argument; here they cost nothing.
- **Stage the payload as a file, not an argument.** The obvious resource does not
  exist: the OSS provider's `ResourcesMap` (`provider/provider.go`) registers
  `coder_agent`, `coder_agent_instance`, `coder_ai_task`, `coder_app`,
  `coder_metadata`, `coder_script`, `coder_env`, `coder_devcontainer` and
  `coder_external_agent`, and nothing else. `coder_file` was requested in
  `coder/coder#3055` and closed `not_planned` on 2022-09-23; a maintainer was still
  asking for it in 2025. Do not plan around it.
- **`coder_env` is the only provably-earlier file write.** The agent's
  `writeSecretFiles` (`agent.go`) runs before any start script, `MkdirAll 0700` then
  `WriteFile 0600`. It takes a string value, so it can carry a payload, and it writes
  into the agent's secret directory rather than anywhere you name.
- **`CODER_SCRIPT_DATA_DIR` is the per-script scratch the agent already hands you.**
  `agent/agentscripts/agentscripts.go` appends `CODER_SCRIPT_DATA_DIR` and
  `CODER_SCRIPT_BIN_DIR` to every script's environment, which is a writable place to
  assemble something across scripts.
- What is deliberately not done: bind-mounting `templates/` into the workspace so the
  script can `cat` a payload off the host, and fetching one over HTTP at boot. The first
  couples boot to a host path that a template push rewrites, and the second puts a
  network dependency on the path that creates the home directory.

### Argument handling

- No arguments pushes every template in `TEMPLATES_DEFAULT` order.
- Arguments are template *names*, and they select which names to push. A name that is not
  one of the known names is an error that lists the known names, so a typo cannot quietly
  do nothing.
- A repeated name is one push, not two, and the push order stays `TEMPLATES_DEFAULT`
  order whatever the argument order is. Naming `devcontainer` first cannot orphan it.
- It is also the manual path after you register an account, and the retry path for one
  template.

### Where it runs, and why

Everything Coder-facing runs **inside the coder container**, against
`http://127.0.0.1:3000`.

- That is the server's own plain listener (`CODER_HTTP_ADDRESS` binds `0.0.0.0:3000`
  inside the container), reached without crossing the reverse proxy, Authelia, or the WAN.
- `coder login` on the host must reach the API *before* it has a credential, and in
  public mode the only URL it will use is `CODER_ACCESS_URL`, which Authelia gates.
- Its first unauthenticated call (the first-user check) gets the HTML sign-in page back,
  and the CLI reports that as `unexpected non-JSON response "text/html; charset=utf-8"`.
- Loopback inside the container cannot be gated, so the push cannot fail that way.
- It runs the image's own `coder` binary, so client and server are the same build.
- No host `coder` CLI and no `coder login` are involved, and a stale host-side session
  cannot aim the push at some other deployment.

### Credentials

The script mints a short-lived token by inserting a row into the stack's own Postgres.

- Same trust model as `coder reset-password`, which also bypasses the API and talks to
  the database directly.
- The token is scoped to minutes (`CODER_PUSH_TOKEN_MINUTES`, default 10), deleted on the
  way out including on a failed or interrupted run, never printed, and minted **once** for
  the whole run however many templates it covers.
- Its scope has to be `coder:all` with `allow_list` `{*:*}`: a narrowed token fails the
  CLI's opening organization lookups, so least privilege is not available on v2.36.
- Template source travels as a tar on stdin (`coder templates push --directory -`), so
  nothing is copied into the container or its volumes.
- A push is also the only thing that *registers* a template: Coder stores the source as a
  Filestore row, not as files it scans on disk.
- The tar is built from a throwaway staging copy, not from the template dir itself.
  `.terraform/` is excluded (pushing it would put the plan's provider binaries into the
  version's Filestore row), symlinks are dumped as their targets (`tar -h`), and the
  `templates/common/` payloads are copied in beside `main.tf`. A staged copy that still
  holds a symlink is refused before the CLI runs.
- Then, per template, it confirms an **active** template version. A push can exit 0 and
  still leave the template inactive if its Terraform run failed, which shows up as the
  template missing from the create dropdown.

### `.env` keys it reads

Nothing else about GitHub travels in a `--var`.

| Read from `.env` | Passed as | Condition |
| --- | --- | --- |
| `DEV_IMAGE` | `--var image=` | always; default `evo-t1-dev:latest` |
| `LITELLM_MASTER_KEY` | `--var litellm_key=` | only when the key is real, never the `change-me*` placeholder |
| `CODER_AGENT_URL` | `--var coder_agent_url=` | only when the key is present at all |
| `GROK_PROFILE_MODE` | `--var grok_profile_mode=` | when non-empty; the retired `GROK_PROFILE_SHARE` maps (`true` to `shared`, `false` to `private`) |
| `REPO_URL` | `--var repo_url=` | only when present and non-empty |
| `GITHUB_MCP` | `--var github_mcp=false` | only when the value is `false` (the github MCP server is on by default; any other value pushes nothing and the template default stands) |
| `CONTEXT7_MCP` | `--var context7_mcp=false` | only when the value is `false` (the cached context7 MCP server is on by default; any other value pushes nothing and the template default stands) |
| `CONTEXT7_API_KEY` | `--var context7_api_key=...` | only when non-empty; the value is never logged |
| `SEARCH_MCP` | `--var search_mcp=false` | only when the value is `false` (the SearXNG MCP server is on by default and is the stack's search lane; any other value pushes nothing and the template default stands) |
| `STACK_SEARCH_PORT` | `--var searxng_url=http://host.docker.internal:<port>` | always; a blank or non-numeric value falls back to `8181` |

- `GITHUB_MCP`, `CONTEXT7_MCP` and `SEARCH_MCP` share one polarity: all three MCP blocks
  ship from the template default (`true`), so the only value worth setting is `false`,
  and `true`/unset/empty pushes nothing at all.
- The two research lanes split by question type: a library, framework, CLI or setup
  question goes to `context7` (resolve the library id first, then query docs on that
  id), anything else on the web goes to the `searxng` `search` tool, and a URL already
  in hand goes to `searxng`'s `fetch_content`. Grok's native `web_search` is parked
  here, and native `web_fetch` is unavailable because that tool needs an egress proxy
  endpoint this stack does not run, so `SEARCH_MCP=false` leaves a session with library
  docs and no way to reach the web.
- A dev stack that moved the search port needs its own template push: `searxng_url`
  is derived from `STACK_SEARCH_PORT` as read from `.env`, so a push made while
  `dev-stack.env` carries `18181` still names `8181` unless the key is set in `.env`
  too. A workspace dials the host gateway, where the compose network does not help,
  so the port in the rendered `SEARXNG_URL` has to be the one actually published.
- `repo_url` prefills the Git repository field on both create forms. The Terraform
  default is still no clone (`workspace`) or the coder/coder demo (`devcontainer`).
  `.env.sample` sets `REPO_URL` to this stack's GitHub URL, so a normal push prefills
  `https://github.com/toxicoder/evo-t1-coder-stack.git` and **VS Code Web** opens
  `~/workspace/evo-t1-coder-stack`. A blank `REPO_URL=` line stays unpassed.
- There is no GitHub-token template variable, so no push ever carries a personal access
  token. See [GitHub credentials for a workspace](#github-credentials-for-a-workspace).
- `coder_agent_url` exists so agents keep dialing the local plain listener when
  `CODER_ACCESS_URL` is a public name.

### Knobs and skips

- `CODER_CONTAINER_SERVICE` (default `coder`), `CODER_DB_SERVICE` (default `db`),
  `CODER_CONTAINER_API_URL` (default `http://127.0.0.1:3000`), `CODER_PUSH_USER`,
  `CODER_PUSH_TOKEN_MINUTES`, `DOCKER_BIN`, `PROBE_TIMEOUT` (20s) and `VERIFY_TIMEOUT`
  (60s) are the overrides.
- A missing `docker`, `timeout`, `tar` or `openssl`, a stack that is not running, or no
  active Coder account is a *skip*: a one-line reason and exit 0. `bootstrap.sh` calls
  this script, and a fresh clone has none of those prerequisites yet.
- `SKIP_TEMPLATE_PUSH=1 bazelisk run //scripts:bootstrap` skips the step.
- A `DEV_IMAGE` that is not in the local image store is a note, not a stop: build it
  first with `bazelisk run //scripts:build-dev-image`.

## The same push, by hand

The supported push is `bazelisk run //scripts:push-template`: no arguments pushes every
template, a template name retries just that one, and the image tag comes from `DEV_IMAGE`
in `.env`. The raw equivalent below is what that script does internally — it streams the
same tar and makes the same CLI call the script makes for each template, execing into the
daemon's `coder` container by name.

That form addresses the stack through `docker compose` instead, so it names the
project with `-p`. From the checkout root the folder name would have said the same thing.

The service appears twice by necessity: the first `coder` selects the compose service, the
second is the CLI binary inside it.

Set a token first. `CODER_SESSION_TOKEN` is any token from the Coder **Tokens** page or
from `coder tokens create`.

```sh
export CODER_SESSION_TOKEN=<your-token>
```

Then push `workspace` (the repo is not mounted into the container, so the directory has to
travel as a tar):

```sh
tar -C templates/workspace --exclude=./.terraform -cf - . | \
  docker compose -p evo-t1-coder-stack -f docker-compose.yml exec -T -i \
    -e CODER_URL=http://127.0.0.1:3000 -e CODER_SESSION_TOKEN \
    coder coder templates push workspace --directory - --yes \
    --var image=evo-t1-dev:latest
```

- Use this shape for reference, or for pushing a tag `.env` does not carry.
- `coder templates` is the canonical name; `template` is its alias.
- The docker provider resolves `evo-t1-dev:latest` from the local image store and never
  attempts a registry pull, which is what keeps workspace creation working with no
  internet.

### Pinning autostop by hand

Autostop is metadata, not Terraform. Re-pin it with `templates edit` after a push made
from the checkout root, or on the dev stack swap `-p evo-t1-coder-stack` for
`-p evo-t1-dev --env-file dev-stack.env`.

Point the CLI at the in-container plain listener, with a token by name:

```sh
export CODER_URL=http://127.0.0.1:3000 CODER_SESSION_TOKEN=<your-token>
```

Then re-pin both values:

```sh
docker compose -p evo-t1-coder-stack -f docker-compose.yml exec -T \
  -e CODER_URL -e CODER_SESSION_TOKEN coder \
  coder templates edit workspace \
    --default-ttl 0 \
    --activity-bump 0
```

Check it in the Coder UI afterwards: **Default autostop** must read *Disabled* (0 h).

## Create-form fields

What a create form shows, in `workspace` order.

1. **Workspace image** (`workspace_image`, dropdown, immutable). `--var image=` seeds its
   default and is also injected as its own option, so a custom tag still reaches the
   container while the form stays honest about what it is building.
2. **Docker-in-docker** (`dind`, Yes/No radio, immutable).
3. **Git repository** (`repo_url`, input, mutable). The Terraform default is empty
   (`workspace`) or the coder/coder demo (`devcontainer`); after a push that forwards
   `.env` `REPO_URL` (this stack's own repo in the sample) the form prefills that URL.
   Anything you type is cloned into the workspace on the next start.
4. **Git repositories (additional)** (`additional_repos`, textarea, mutable, default
   empty).
5. **Grok profile** (`grok_profile_mode`, dropdown, immutable, default `shared`).
   `private` gives that one workspace a private `~/.grok` on its own home volume, so one
   workspace can sit outside the shared profile while its siblings stay inside it.
   Switching needs a rebuild.
6. **Grok default model** (`grok_default_model`, dropdown, immutable, default `agent`).
7. **Grok config extras** (`grok_config_extra`, textarea, mutable, default empty).
   Whatever you type is appended verbatim, under a comment header, to that workspace's
   rendered `~/.grok/config.toml`. That file is only observably per-workspace while the
   profile mode is `private`: one shared profile is one file for every workspace that
   owner owns, and the last boot to re-render it wins.

`devcontainer` asks two questions instead: **Git repository** and **Build repo's dev
container** (`use_devcontainer`, Yes/No, immutable), plus the same three Grok fields.

## Template variables

Template variables are pushed defaults; the create form can still override them per
workspace.

| Variable | Default | Notes |
| --- | --- | --- |
| `image` | `evo-t1-dev:latest` | Seeds the **Workspace image** dropdown default. In `devcontainer` it decides nothing about the toolchain inside the editor. |
| `litellm_url` | `http://host.docker.internal:4000/v1` | Reached through the Docker host gateway. |
| `litellm_key` | `""`, `sensitive` | Handed to the workspace as `LITELLM_API_KEY`. Sensitive: pass the LiteLLM master key when creating a workspace. |
| `grok_default_model` | `agent` | One of the LiteLLM aliases. `agent` is the tool-capable Spark lane (thinking `xhigh` by default, picker `low` / `medium` / `xhigh`); `agent-low` / `agent-medium` / `agent-xhigh` bake the level into the alias. |
| `docker_socket` | `""` | Optional Docker socket URI; empty means the provider default. |
| `coder_agent_url` | `http://host.docker.internal:3002` | The URL the agent dials. Kept on the local plain listener so a public `CODER_ACCESS_URL` does not hairpin agent traffic through the reverse proxy. Empty keeps the provider-rendered access URL. |
| `dind` | `false` | Turns on the per-workspace privileged daemon described below. Does not exist in `devcontainer`. |
| `repo_url` | `""` in `workspace`, `https://github.com/coder/coder` in `devcontainer` (Terraform); `.env.sample` `REPO_URL` overrides both to this stack's GitHub URL | Prefills the **Git repository** field. Both templates clone that URL on the first start; a later start leaves a folder that already holds a `.git` alone. `REPO_URL` in `.env` overrides the default. The sample value is this stack's own repo so **VS Code Web** opens `~/workspace/evo-t1-coder-stack`. |
| `additional_repos` | `""` | The **Git repositories (additional)** textarea under the repository field. Extra URLs cloned into their own folder beside `repo_url`. |
| `grok_profile_mode` | `shared` | `shared` mounts the owner's shared `~/.grok` profile volume; `private` gives that workspace a private `~/.grok` on its own home volume. Also the default behind the per-workspace **Grok profile** dropdown; switching a live workspace between the two modes needs a rebuild. |
| `github_mcp` | `true` | Wires the `github` MCP HTTP server into Grok's rendered `config.toml`. Its `Authorization` header names `$GH_TOKEN` and nothing else, so no token value is ever part of a template variable. Set `GITHUB_MCP=false` and re-push to drop the block. |
| `context7_mcp` | `true` | Wires the cached `context7` MCP stdio server into Grok's rendered `config.toml`. The key is optional, so it ships without one. Set `CONTEXT7_MCP=false` and re-push to drop the block. |
| `context7_api_key` | `""`, `sensitive` | Handed to the workspace as `CONTEXT7_API_KEY`. The rendered file names the variable. |
| `grok_config_extra` | `""` | The **Grok config extras** textarea: free-form TOML appended verbatim, under a comment header, to that workspace's rendered `~/.grok/config.toml`. |

Notes on the two dropdowns that take a custom value:

- The `grok_default_model` aliases are `agent`, `agent-low`, `agent-medium`,
  `agent-xhigh`, `coder`, `coder-fast` and `chat`, plus a **Custom** entry when the
  variable names another one.
- The provider requires a parameter default to be one of its options, which is why a
  custom `--var` value is injected as its own option instead of being dropped.
- A `github_mcp` of `true` with no GitHub account connected gives that workspace a server
  that fails its handshake once per session, because `$GH_TOKEN` is empty. A
  `context7_mcp` of `true` with an empty `context7_api_key` is *not* the same shape:
  the key is optional, the block renders either way, and the server handshakes and
  answers without one - no `Authorization` header goes out, so the lane runs at the
  public rate limit and private libraries are the only thing out of reach. That keyless
  block is the pushed default and what a fresh deploy gets, since nothing in git
  carries a key, and `bazelisk run //scripts:mcp-check` only warns about it. Park a
  lane deliberately with `GITHUB_MCP=false` / `CONTEXT7_MCP=false` in `.env` (relayed
  by `push-template.sh`) or `--var github_mcp=false` / `--var context7_mcp=false` on
  the push; a block missing from a render that got neither of those is a defect, not a
  park. Fill the context7 key with `CONTEXT7_API_KEY` in `.env` plus a re-push when a
  session needs private libraries or a higher rate limit.

## Autostop and TTLs

Autostart, autostop and TTLs are template *metadata*, so they stay out of the Terraform
(where they would fight the UI) and travel on the CLI after pushing.

- **Autostop is disabled by default.**
- Coder reads the template's **Default autostop** (its default TTL) when it seeds a
  workspace. That field also decides whether the create form's **Enable Autostop**
  arrives ticked, and it ships at 24 h - which is how a workspace would otherwise start
  with a shutdown deadline nobody chose.
- A 0 default TTL leaves the checkbox unchecked and leaves `coder create` with nothing to
  inherit, so a workspace runs until its owner stops it.
- `--activity-bump` goes to `0` with it: a bump only extends a deadline, and with no
  deadline there is nothing to extend.
- `push-template.sh` re-sends both after every push, and `new-workspace.sh` names no
  `--stop-after`, so a script-made workspace gets no autostop deadline either.
- A workspace owner can still tick the box for one workspace: `allow_user_autostop`
  stays on, because CE cannot turn it off -- `--allow-user-autostop=false` is marked
  "can only be disabled in enterprise".
- Keep the other licensed flags out of the CE stack too. `--failure-ttl` (Failure
  cleanup), `--dormancy-threshold` and `--dormancy-auto-deletion` are all marked "This
  licensed feature's default is 0h (off)" in `templates edit --help` on v2.36.6, and
  `--allow-user-autostart` works the same way. Older notes also list `--inactivityTTL`
  among the rejected names; v2.36.6 has no flag of that name, and `--default-ttl` and
  `--activity-bump` are the closest.

Check it in the Coder UI: the template editor's **Default autostop** reads *Disabled*
(0 h), and a workspace's **Schedule** tab shows **Enable Autostop** unchecked.

## Docker-in-docker

Opt-in in `workspace` (the **Docker-in-docker** Yes/No question, preset *AI workspace +
DinD*, template variable `dind`). With the toggle off, `docker` in that workspace fails
the normal way rather than against a daemon that does not exist.

With it on, per workspace:

- One privileged `docker:29.8.1-dind` sidecar on a bridge network private to that
  workspace (`coder-<wsid>-dind`, network alias `dind`).
- The workspace container attaches to **both** `bridge` and that private network; once a
  `networks_advanced` block appears the provider stops letting `network_mode` do the
  attaching, so `bridge` has to be listed explicitly.
- `DOCKER_HOST=tcp://dind:2375` is injected into the agent environment - absent when the
  toggle is off.
- `docker build`, `docker run` and `docker compose` then work inside the workspace. The
  *AI workspace + DinD* preset is the usual way to get this shape, since the client
  binaries ship only in the golden image.

Details that matter:

- The toggle is `mutable = false`: turning it on or off means a workspace **rebuild**,
  because a network, a volume and a second container appear or vanish. The preset makes
  that one click.
- Only the literal string `"true"` enables it; anything else reads as off.
- The daemon's `/var/lib/docker` lives on its own volume (`coder-<wsid>-dind-lib`), so a
  stop/start does not re-pull every image the builds used. It is not gated on
  `start_count`, so it survives a stop and is reused by the next start.
- `DOCKER_TLS_CERTDIR=` is deliberately **empty**, so the daemon serves plain
  `tcp://0.0.0.0:2375` with no TLS and no auth. (`DOCKER_TLS_CERTSIZE=0` does not do
  this: the daemon would listen on 2376 with TLS and the client fails against 2375.)
- Nothing is published to the host, and 2375 is reachable only from that workspace's own
  network - which is also why the network is not `internal`. An internal network gets no
  gateway route or NAT, so `host.docker.internal` would resolve and never answer, and the
  agent would strand. See [SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md).
- The daemon image is resolved with `data "docker_image"`, which inspects the host store
  and **never pulls**, so `docker:29.8.1-dind` must already be there. `bootstrap.sh`
  pre-arms it; to do it manually:

  ```sh
  docker pull docker:29.8.1-dind
  ```

- A missing image fails the workspace build at **plan** time, before anything is
  created, with `did not find docker image 'docker:29.8.1-dind'` - see
  [troubleshooting.md](troubleshooting.md).
- `cgroupns_mode = "private"` and `shm_size = 1024` (MB to the provider, so 1 GiB) are
  both load-bearing; the sidecar is torn down with the workspace because it is gated on
  `start_count` as well as on the toggle.
- `DOCKER_CLI_VERSION` in `images/dev/tool-versions.env` and the `docker:29.8.1-dind` tag
  in `templates/workspace/main.tf` and `templates/devcontainer/main.tf` are the same
  engine line (29.8.1). Bump all three together.

## The `devcontainer` template

That is the *AI workspace + DinD* shape, always on, plus a repository that brings its own
toolchain.

### Shape

- One workspace container from the golden image: launcher and clone target only. It still
  has to be the golden image, because that is what ships the Docker client the
  devcontainer flow talks through. The editor's real environment is whatever the repo
  builds, so `image` decides nothing about the toolchain inside it.
- An always-on privileged `docker:29.8.1-dind` sidecar on the per-workspace bridge
  network, with `DOCKER_HOST=tcp://dind:2375` injected **unconditionally** and
  `DOCKER_TLS_CERTDIR=` empty for the reasons above. `internal` stays false for the same
  one reason.
- `dind` is not a variable here. A devcontainer workspace without a daemon is nothing,
  and the plain-clone fallback still wants a daemon its `docker` commands can reach.
- One host bind, `/srv/coder-devcontainers/<workspace-id>`, mounted at that **identical**
  path in both containers.

### Why the shared bind path is load-bearing

- The devcontainer CLI always bind-mounts the workspace folder into the dev container it
  creates, and a bind source is resolved by the daemon that *runs* that container - here
  the sidecar, not the workspace's.
- So the clone must exist at the same path inside the sidecar too, or it dies with
  `bind source path does not exist`.
- Named volumes cannot substitute: a volume is a daemon-local object and does not cross
  to the sidecar's daemon.
- Docker creates the missing host directory itself (root-owned) and `startup.sh.tftpl`
  chowns it.
- Inside a built dev container the same folder appears under `/workspaces/<repo-name>`,
  the devcontainer CLI's default mount target and where the dev-container editor opens.
- `main.tf` therefore spells the editor's `folder` per hosting environment
  (`local.editor_folder`): `/workspaces/<repo-name>` inside the dev container,
  `/srv/coder-devcontainers/<workspace-id>/<repo-name>` on the plain container, and
  `/home/coder` when no repository was named.
- One host-side path for all three would open the editor on a folder that exists nowhere
  the editor runs, and VS Code answers that with
  `Workspace does not exist. Please select another workspace to open.`

### The two questions

- **Git repository** (`repo_url`) is mutable: switching repository is a re-clone plus a
  devcontainer build, not a new topology the way `workspace`'s DinD toggle is.
- **Build repo's dev container** (`use_devcontainer`, default `true`) is immutable:
  building a dev container or not is a different topology. With Yes the editor lives in
  the dev container; with No, in the plain container.
- A repository that ships no `devcontainer.json` gets no dev container and hence no
  editor with the toggle on. The toggle - or
  `bazelisk run //scripts:new-workspace -- <git-url>`, which reads the repository and
  picks for you - is how that case is meant to be handled.

### Clone and build

- `startup.sh.tftpl` clones the repository onto that bind in **both** toggle modes.
- With the toggle on, `coder_devcontainer.repo` then builds the repo's own
  `.devcontainer/devcontainer.json` on the sidecar through the Coder agent
  (`@devcontainers/cli` is installed into the parent workspace container by a
  `run_on_start` module, and the golden image does not ship it).
- That exposes the dev container as a sub-agent with its own terminal and apps, and the
  in-browser editor attaches to *that* sub-agent, so the editor runs inside the dev
  container where the cloned repo's toolchain lives.
- With the toggle off - or on a repo that carries no `devcontainer.json`, where the build
  has nothing to build - the editor attaches to the plain workspace agent instead, opened
  on the same clone path.
- Either way `folder` is the clone, so code-server and its terminal profiles land on the
  repository, and the **Web Terminal** button `cd`s there too.
- No `config_path` is set, so the CLI discovers the file the way VS Code does, and a repo
  using the other legal locations behaves the same.
- `coder_script.dind_bootstrap` is an ordering guard, not a starter: it waits up to 120s
  (180s cap) for the sidecar to answer `docker version`, because the agent runs its
  `run_on_start` scripts before it creates the dev containers.

### What it reuses, and the trust warning

- The mount covers the workspace container only; a dev container built on the sidecar
  keeps its own home either way.
- It carries its own copies of `startup.sh.tftpl`, `settings.json.tftpl` and
  `grok-config.toml.tftpl`, so the tmux-default terminal and LiteLLM wiring above apply
  to it too.
- **Treat the repository as untrusted code.** Everything it builds runs on a privileged
  daemon on this box, so a Dockerfile in that repo is root-equivalent on the stack host.
  The create form's own description says so, and only repositories you trust belong in
  the field.

## From a git URL: `bazelisk run //scripts:new-workspace`

`bazelisk run //scripts:new-workspace -- <git-url> [name]` answers the two questions
above for you: which template, and whether to build the dev container.

The `--` ends Bazel's own flags, so a URL that begins with a dash still reaches the
script. Every fence below is one complete command.

Dry run (decision only, creates nothing):

```sh
bazelisk run //scripts:new-workspace -- --dry-run https://github.com/foo/bar.git
```

Create the workspace it picks:

```sh
bazelisk run //scripts:new-workspace -- https://github.com/foo/bar.git
```

Force the `workspace` template:

```sh
bazelisk run //scripts:new-workspace -- --plain git@git.example.com:org/private.git
```

### What it decides

- It shallow-clones (`--depth 1 --no-checkout --single-branch`) into a temporary
  directory, from the host, and lists the tracked files.
- It looks for a dev container in `.devcontainer/`, `.github/devcontainers/`, or a
  `devcontainer.json`/`devcontainer.yml` anywhere in the tree.
- A tracked `.devcontainer/contributor-env` outranks every other signal: the probe is a
  **miss** even when the same clone also tracks `.devcontainer/devcontainer.json`. That is
  how this repo keeps its own Coder workspaces on `workspace` — the `.devcontainer/` it
  ships is the contributor one for a laptop and CI, not a nested toolchain to rebuild
  inside the workspace's own DinD sidecar (see
  [contribute/devcontainer.md](contribute/devcontainer.md)). Application repositories do
  not carry the sentinel, so their dev containers stay a hit.
- Found means `devcontainer`; not found means `workspace`. A probe that fails **entirely**
  is also a `workspace` answer, with a warning.
- The clone is a plain `git clone` from the host, so it consults the host's own git
  credentials. A private repository therefore needs a grant covering it **on the machine
  you run this from**.
- It then assembles `coder create` with the template's parameters: `repo_url=<url>`
  always, `use_devcontainer=false` whenever `devcontainer` was chosen but no dev
  container was found (forced with `--devcontainer` onto a repo that has none, or a probe
  that could not check the repo - the cases where leaving the toggle at its default would
  build nothing anyway), `dind=true` on `--dind`, and `additional_repos=<list>` whenever
  `--additional-repos` named at least one extra URL.
- It names no `--stop-after`, so a script-made workspace gets no autostop deadline.
- It either runs the command (`--no-wait`; watch with `coder ls` / `coder logs <name>`)
  or, with no usable `coder` login, prints the same command to run by hand and exits 0.
- `--devcontainer` forces the devcontainer template and `--template <name>` overrides the
  template choice outright.
- A workspace name can follow the URL. Coder names start with a letter (40 characters
  max); the derived default is the repository leaf.
- It never mints, reads, or stores a token - unlike `push-template.sh`, which mints its
  own because a template push has no other credential path. With `CODER_SESSION_TOKEN`
  set but `CODER_URL` unset it refuses to guess, and an empty token is a *not yet* state
  rather than an error.

## Inside the workspace container

Each template creates one Docker container per workspace. Extra named volumes
(`vscode-settings-<owner-id>` at `~/.shared/vscode`, and `grok-profile-<owner-id>`
at `~/.grok` in shared mode) are chowned to the home owner at the start of
`startup.sh.tftpl`, because Docker creates an empty named volume as `root:root`
755 and the agent runs as `coder`.

- Image from `images/dev/Dockerfile` (overridable with the `image` variable) carrying:
  Node 22 + 24, Python 3.12 + 3.11, Go 1.24, Bazelisk/buildifier,
  Terraform/tflint/terragrunt, protoc and its Go plugins, kubectl/helm/kubeconform,
  shfmt/shellcheck/bats/ruff/mypy/prettier, the Coder CLI, and the pinned Grok Build CLI
  at `/usr/local/bin/grok`.
- The Docker **client** toolchain only (`docker`, `docker buildx`, `docker compose` as
  CLI plugins under `/usr/local/lib/docker/cli-plugins`). No daemon: the build asserts
  `dockerd`, `containerd`, `runc` and `docker-proxy` are absent.
- The five offline MCP servers ship in the image, but the rendered config declares none
  of them by default, so a workspace needs no network to start a session.
- A persistent per-workspace home volume (`coder-<wsid>-home`).
- `host.docker.internal` mapped to `host-gateway`, so workspaces reach the Coder server
  and LiteLLM.
- `startup_script_behavior = "blocking"`, so a workspace only reports *ready* once the
  toolchain is genuinely staged - no opening an editor mid-install.
- `connection_timeout = 300`.

### What the startup script does, in order

1. Installs `tmux` if it is missing, then seeds `~/.tmux.conf` (only while that file is
   absent or still carries the `managed-by: evo-t1-coder-stack` marker).
2. Ensures the **Grok Build CLI** is on PATH. The golden image ships it, so the
   `https://x.ai/cli/install.sh` download runs only where `grok` is missing from PATH -
   the `ubuntu:24.04` image option, or a home volume that never received the CLI.
3. Puts `~/.grok/bin` on PATH (login shells and that process).
4. Writes the two terminal-profile tmux helpers (see below). The default one gives each
   visible terminal its own pane: it re-joins a folder's session only while nothing is
   attached to it, and otherwise opens a numbered sibling.
5. Seeds the Coder Agents context files, then the shared code-server User settings, only
   for files that are absent.
6. Renders `~/.grok/config.toml` (the three gated MCP servers ship by default; the five
   offline stdio ones are not declared).
7. **Clones a non-empty Git repository field** into `/home/coder/workspace/<repo-name>`
   (in `devcontainer`, onto the `/srv/coder-devcontainers/<workspace-id>` bind). The
   script creates that folder first (`mkdir -p` plus a chown to the workspace user) so
   the editor's wait loop can see it, then clones into it. This is idempotent, runs as
   the workspace user so their git credentials are consulted, and refuses to touch an
   existing non-empty non-git folder there. An empty pre-created target still clones.

The repository leaf is derived the same way in `main.tf` and in `startup.sh.tftpl`:
split on `/`, drop empty segments, take the last, drop a trailing `.git`, map every
character outside `[A-Za-z0-9._-]` to `-`, and fall back to `repo` when that leaves no
leading alphanumeric. Both derivations must agree, or the editor and the terminal
helpers point at a folder that was never cloned.

### Why the stages sit where they do

The order above is not incidental; each line is a constraint the script has to keep.

- `~/.tmux.conf` is seeded *before* the two terminal helpers. `tmux` reads that file once
  at server start and every terminal (plus an SSH client that reattaches) shares that one
  server, so seeding after the first `tmux new-session -A` could run would leave that
  session unconfigured for the whole boot. `mouse on` hands the wheel and the drag to
  tmux; `set-clipboard on` is what carries a tmux copy out to the client clipboard over
  OSC 52, and a client that blocks OSC 52 (iTerm2 by default) keeps the copy inside
  tmux's own buffer instead.
- The clone folder is created before git runs, and before the `coder_script.code_server`
  script's own `mkdir`: the editor starts in parallel with the startup script, and an
  empty tree is a folder VS Code can open while the clone is still writing. An empty
  directory is also what `git clone` accepts, so pre-creating it does not change what gets
  cloned - the emptiness guard still refuses a folder holding anything.
- `notes_materialize` runs *before* the recursive chown of a fresh clone: the notes file
  and the `.git/info/exclude` write are the stack's to make, and the chown afterwards
  settles their ownership.
- The chown of `~/.grok` and `~/.shared` runs a second time at the end of the script,
  because the CLI installer and the seeds above may have created files as root when the
  agent ran as root.
- `run_notes` and `run_notes_watch` follow the clone's identity rule rather than the
  agent's uid, because that stage writes into the workspace home and runs
  `git config --global`: run as root it would rename a root-owned `~/.gitconfig` over the
  workspace user's and leave `notes.md` unreadable on an already-cloned folder.
- The watcher left at the end is what makes notes survive a recreate that lands *between*
  edits. The boot-time sync runs once, so anything written later lived solely inside that
  container, which is how a whole workspace's notes went missing on a recreate.
- Every stage from the Coder Agents seeds onward is best-effort: an offline first boot has
  to leave a working terminal, and a repository that will not clone has to leave a
  workspace someone can fix, so nothing there may abort the script. In `devcontainer` a
  missing or half-cloned folder is not silent either: `coder_devcontainer` fails on its own
  with a visible error naming the folder it looked in, and the clone stage warns first when
  a clone arrives with no devcontainer configuration in it.

### The Grok Build CLI probe, the download, and the installer stub

- The install check is `command -v grok`, not `[ -x ~/.grok/bin/grok ]`: the golden image
  bakes the CLI into `/usr/local/bin`, so on a golden-image boot the probe answers yes and
  nothing downloads. The download exists for the **Minimal shell** (`ubuntu:24.04`) preset
  and for a home volume that never received a CLI.
- It is bounded and retried on purpose: one unbounded attempt burned a whole start on a
  single stalled connection to x.ai (`curl: (28) SSL connection timeout`) and still booted
  the workspace without a CLI.
- `GROK_FRESH_INSTALL` records that an install *completed* this boot - the second
  `command -v` probe inside the install branch is what sets it, so a failed download leaves
  the flag at `0`. The installer writes its own `~/.grok/config.toml` (a
  `[cli] installer = ...` stub) that is indistinguishable from a user's config, so the
  config stage may treat that stub as stack-owned only on a completed install: a download
  that failed must never wipe a user-owned config in its place. Without that flag a
  brand-new workspace would be left with an unconfigured CLI, because the stub carries
  neither stack marker and the file already exists.

### Marker ownership of the seeded files

Most seeded files are written only while absent, so a hand-edited copy is user-owned and
the stage re-runs harmlessly. Three of them are re-written on every start, and ownership is
decided by a marker - never by mtime and never by first boot:

- `~/.tmux.conf` and `~/.grok/AGENTS.md` are rewritten while the
  `managed-by: evo-t1-coder-stack` line is present; editing the file away from the marker
  hands it to the user for good, and each prints one warning line when it is marker-free.
- `~/.grok/config.toml` is re-rendered when it is absent, when
  `GROK_FRESH_INSTALL` is set, or while *either* marker is present: the `managed-by`
  comment or the top-level `__evoT1Stack = true` key.
- The key is what makes the rule hold. The CLI's own settings writer (`grok mcp add` and
  friends) deletes every comment line, so a comment-only marker can vanish with nobody
  touching the file.
- On a shared profile volume the config file usually already exists, because another of the
  owner's workspaces wrote it, so the marker rather than first boot is what decides.
- Re-rendering carries over the tables the CLI owns instead of wiping them: `[cli]` holds
  `cli.installer`, which picks the CLI's update path; `[ui]` holds `permission_mode`, so
  re-adopting a file must never flip an operator back to prompting; and `[marketplace]` is
  CLI settings the stack never owns.
- The unmanaged case is announced rather than silent, because the render is the only place
  a workspace's model catalog and MCP lanes are ever written.
- `~/.grok/notes-setup.sh` is the exception to the absent-only rule: it is stack-owned code
  and the copy on the shared profile volume has to be the one this template shipped, so it
  is rewritten every start. It is written beside its target and `mv`'d in - and `chmod
  0644`'d first, because `mktemp` makes 0600 and `mv` keeps that mode - so the rename is the
  first moment the file exists for anyone to source, and a sibling workspace booting at the
  same time against the one shared volume never sources a half-written library.

### The shared grok profile volume

`~/.grok` is not necessarily a workspace's own directory, and that decides several of the
rules above.

- In `shared` mode (the default `grok_profile_mode`) the container mounts the owner's
  shared per-user Docker volume read-write at `/home/coder/.grok`, nested inside that
  workspace's own `/home/coder` volume. The terminal helpers, `config.toml`,
  `notes-setup.sh` and the `memory-v2/` tree the CLI keeps there are then the same files
  every other workspace this owner has reads and writes, and they survive a rebuild.
- That is also why `config.toml` cannot be per-workspace in that mode: it is one file, and
  the last workspace to boot re-renders it for all of them, so this workspace's default
  model (or, in `devcontainer`, its model alias) and config extras overwrite whatever the
  previous boot wrote - for every sibling.
- `private` mounts nothing extra: the tree then lives on this workspace's own home volume,
  so its `config.toml`, defaults and extras included, is its own and dies with it.
- In `devcontainer` the mount is on the workspace container only. A dev container the repo
  builds on the sidecar keeps its own home and its own `~/.grok`, which is why the live
  `notes-setup.sh` there is a regular file reached through the clone bind rather than a
  link into `~/.grok`, and why a built dev container sees neither the settings volume nor
  the editor symlink.
- The Coder Agents seeds under `~/.coder` and `~/.agents` are not on that mount: they live
  on the workspace's own home volume, and that stage neither needs nor disturbs it.

### The Coder Agents seeds and their agents-tree twins

- The chat agent discovers its context through its *default* paths (verified against the
  v2.36.6 agent binary and its `agentcontextconfig` source): the instruction file
  `AGENTS.md` under `~/.coder`, skills under `~/.coder/skills`, and a working-dir-relative
  `.agents/skills`, which here resolves to `/home/coder/.agents/skills` - the same folder
  the Grok Build CLI looks in.
- Neither `main.tf` sets `CODER_AGENT_EXP_SKILLS_DIRS` or the
  `CODER_AGENT_EXP_INSTRUCTIONS_*` keys: those *replace* the default lists rather than
  appending, and the seeded copies already sit where the unmodified defaults point. Chat
  itself is on by default in 2.36.6 - no experiment name and no entitlement gates it.
- Each file also gets a twin in the `~/.agents` tree, because the `execute`-lane delegation
  this stack teaches starts `grok -p` inside the workspace and that CLI reads the
  `~/.agents` convention. The chat agent would only ever take the `~/.coder` copies - skill
  dedupe is first-match-wins, home scope before working-dir paths - so one agent never
  loads a skill twice; the twins exist for the CLI, not as a second source for chat.
- A twin is copied only while absent, and only from the managed `~/.coder` copy, so a
  hand-placed file in `~/.agents` is never overwritten and the dedupe keeps exactly one
  live source. The CLI-side spelling of the instruction file keeps the `INSTRUCTIONS.md`
  name because that is the name the `~/.agents` convention was seeded under.
- In `devcontainer`, working-dir resolution has a second case: with the dev-container
  toggle off the agent's working dir is `/home/coder`, exactly as in `workspace`; with it
  on, the dev container's own working dir is the cloned folder under
  `/srv/coder-devcontainers/...`, and that folder ships no skill tree, so the `~/.coder`
  copies remain the live source either way.
- In a `SKILL.md` the marker sits *after* the `---` frontmatter: the skill parser needs
  `---` on line 1 and silently drops a skill whose first line is anything else. In an
  injected instruction file the marker is pure provenance, because injected content has its
  HTML comments stripped anyway. The stage is best-effort: a read-only or missing `$HOME`
  changes nothing observable.
- `/learn` is seeded on the same absent-only contract because upstream `/learn` is a
  *bundled* skill and the bundle download runs through the CLI's proxy endpoints, which need
  an x.ai sign-in this stack deliberately does not have: LiteLLM is the only transport, so
  `~/.grok/bundled/` is never created and the slash name would simply be missing. Writing
  the file is what makes `/learn` exist, and deleting or editing either copy keeps your own.

### Startup script templatefile rules

- `startup.sh.tftpl` is rendered by `templatefile()`, so every braced shell expansion has
  to be written `$${name}`; the one-dollar braced form is swallowed as an interpolation.
  The unbraced form (`$name`) needs no escape.
- Only the variables `main.tf` passes interpolate. The `workspace` startup script gets
  thirteen: `grok_build_agents`, `grok_config`, `repo_url`, `additional_repos`,
  `vscode_settings`, `notes_setup`, `tmux_conf`, `grok_build_terminal`,
  `vscode_terminal_tmux`, `grok_build_delegation_skill`, `learn_skill`, `coder_agents`,
  `mcp_cache_proxy`. The `devcontainer` twin adds `dc_dir` and `build_devcontainer`.
- That is why the `.git` suffix is stripped with `sed` rather than the shorter
  `${leaf%.git}`: a braced expansion would add an interpolation `main.tf` does not pass.
- The repository URLs arrive as rendered literals and are read through a *quoted* heredoc,
  so no shell quoting has to survive and the value is only ever expanded as data. An empty
  Git repository field means a home-directory workspace, so the whole clone stage is
  skipped rather than attempted with an empty URL.
- `~/.grok/config.toml` is emitted from a quoted heredoc for the same reason: a
  `Bearer $${GH_TOKEN}` line the config template emits travels through as literal text
  instead of being expanded there, and the CLI expands it from the agent environment. The
  same holds for the `CONTEXT7_API_KEY` reference.
- `grok_config` arrives already rendered from `grok-config.toml.tftpl`. Its boolean keys
  `github_mcp`, `search_mcp` and `context7_mcp` only decide whether their
  `[mcp_servers.*]` block appears, and no credential byte is part of that decision;
  `search_url` supplies the URL the searxng block dials, and the workspace affinity key is
  a per-workspace routing hint (a workspace UUID, not a secret).

### Cloning as the workspace user

- `clone_owner` is whichever user the workspace really belongs to: the owner of `$HOME`
  when the agent runs as root, otherwise whoever is running the script. It decides both the
  chown target and whose git credentials the clone consults.
- The parent folder (`/home/coder/workspace`, or the `/srv/coder-devcontainers/<wsid>` bind
  in `devcontainer`) is chowned before git runs, and *non-recursively*: other clones live
  alongside this one and are not ours to take over. The clone folder itself is chowned too,
  or a root agent leaves it root-owned and the clone dies writing `.git` inside it.
- git never runs as root, so the credentials it consults - a helper, `~/.git-credentials`,
  ssh keys - are the workspace user's. `HOME` is passed explicitly through `env` because
  `runuser` keeps the invoker's environment; a root agent would otherwise hand git `/root`
  and miss those files entirely. An empty prefix means "run git directly", which is correct
  for a non-root agent and for a root agent with no derivable workspace user.
- A folder that already holds a `.git` is left alone: re-fetching is the user's call,
  because a pull there could conflict mid-edit or fail on a dirty tree, and either way the
  workspace would start on code nobody chose.
- A failed clone is loud and non-fatal. The workspace still boots, an empty editor folder
  is fixable from a terminal, git removes its own partial clone on failure, and nothing in
  the script deletes a folder that may hold someone's work.

### MCP command reachability advisory

- Every `[mcp_servers.*]` block the render writes names its binary by the absolute path the
  golden image bakes (`/opt/npm-global/bin/...`), so the config and the image are two
  artifacts that have to agree - and they do not always. A workspace running an image built
  before that binary was added boots with a lane that can never start, and the CLI only
  says so in its own MCP log.
- The stage reads the *rendered* file, pulls every `command = "..."` value out of it, and
  names the ones that are not executable files, in the same startup log that wrote the
  config. `sed` keeps only a double-quoted value and a TOML path carries no spaces, so an
  empty entry there is an odd line rather than a missing binary.
- It is advisory only: one warning line per missing path, never a failed start, so the call
  swallows whatever status the function returns.

### Dev-container preflight

- It runs after the clone because it is about what the clone holds, and it also runs on a
  re-start that cloned nothing, because the devcontainer build re-runs then too.
- The six paths it probes are the ones `@devcontainers/cli` looks in: `devcontainer.json`
  and `devcontainer.yml` at the root, under `.devcontainer/`, and under
  `.github/devcontainers/`.
- Nothing here changes what the build does. With the toggle on, a clone carrying no
  devcontainer configuration fails the build either way, and the editor hangs off the dev
  container, so no dev container also means no editor and no in-container terminal; the
  warning is only early notice in the same log the clone warnings use. With the toggle off
  the same miss is expected and the editor opens the clone directly.

### Editor, terminal, and the metadata tiles

- `display_apps` gives: the **VS Code Desktop** helper (a locally installed VS Code /
  Cursor / Windsurf plus the `coder.coder-remote` extension), port forwarding, and the
  SSH helper.
- A separate in-browser **code-server** editor is Coder's VS Code fork (no local VS
  Code), labelled **VS Code Web** with `order = 5` so it sorts before GitHub reauth (7),
  Install GitHub App (8), LiteLLM (10) and Coder UI (11) and reads apart from the
  **VS Code Desktop** helper.
- A custom **Web Terminal** command-app at `order = 6` takes the terminal slot. Custom
  apps are ordered among themselves; static helper buttons have no `order` or `icon` knob
  in this Coder release and are not reorderable.
- A **GitHub reauth** external app (`order = 7`, `/icon/github.svg`) opens Coder's
  `/external-auth/<id>` page in a slim window on the user's Coder session: connect, or
  **Reauthenticate** when the account is already linked. It stays on the main agent so
  a failed clone (or a `devcontainer` subagent that never starts) still leaves the
  button on the workspace page. Device-flow login is not the App install: with the
  injected App (id `github`) that page prints "You must install the GitHub App to
  clone private repositories" as unlinked plaintext, because Coder omits
  `AppInstallURL` on the default provider.
- An **Install GitHub App** external app (`order = 8`, same icon, opens in a tab)
  is the clickable install path for that default App:
  `https://github.com/apps/coder/installations/new`. It is declared only while
  `github_auth_id` is `github`. After installing, grant the private repos the
  workspace clones, then restart so `GH_TOKEN` remints.
- Memory (90 percent) and disk (85 percent, `/home/coder`) usage gauges, six resource
  metadata tiles sampled every 30s - four `coder stat` calls (`cpu --host`,
  `mem --host`, `disk --path /home/coder`, `cpu --host`) and two awk one-liners for swap
  and load average.
- A **LiteLLM** tile (`/health/liveliness`, `share = "owner"`) that health-checks the
  proxy and is visible only to the workspace owner, plus a **Coder** external app.
- `coder_metadata.workspace_info` shows the image, the cloned repository (in `workspace`,
  or `none` when the Git repository field is empty), the LiteLLM URL, the default Grok
  model, whether DinD is `on (tcp://dind:2375)` or `off`, and - redacted - which key is
  wired in. A misconfigured workspace is therefore visible in the UI without shell
  access. `devcontainer` adds a `devcontainer folder` tile and always reads
  `on (tcp://dind:2375)` for Docker-in-docker.

### The inlined code-server fork

- Neither template installs code-server through the Registry. Each `main.tf` carries an
  inlined fork (`coder_script.code_server` + `coder_app.code_server`) because that
  upstream module hardcodes `/icon/code.svg` and has no icon input. The script body
  lives in a sibling `code-server.sh.tftpl` and is rendered with `templatefile()`
  (workspace: `{ editor_folder = local.editor_folder }`; devcontainer: that plus
  `settings_b64`). Do not wrap that `templatefile()` in `chomp()`.
- The `workspace` fork installs code-server **only when it is missing** from
  `/home/coder/.local/share/code-server`, and starts it with
  `--auth none --port 13337 --app-name "VS Code Web" --ignore-last-opened <folder>`,
  passing no settings payload. Before that launch it `mkdir -p`s the folder and, when
  the folder is not `/home/coder`, waits up to 60 s for `<folder>/.git` so a first-start
  clone and the editor no longer race. That wait loop increments with
  `waited=$((waited + 1))` (one dollar) inside the tftpl: `templatefile()` interpolates
  `${…}` and leaves `$((` alone. `$$((` would expand `$$` to the PID. `coder_agent.dir` stays unset: the agent would
  chdir there before `startup.sh`, and a missing clone folder would fail the agent. The
  editor's settings live on the per-owner `vscode-settings-<owner-id>` volume seed, not
  in a per-start merge.
- The `devcontainer` fork has no persistent prefix to reuse - both toggle modes rebuild
  the container that hosts the editor - so it installs fresh under `/tmp/code-server` on
  every start, and bakes the settings seed as base64 into `settings_b64` (empty when the
  toggle is off, so the shell skips the merge). The DinD wait lives in
  `templates/devcontainer/dind-bootstrap.sh.tftpl`.
- Both twins' `coder_app` opens on `http://localhost:13337/?folder=<urlencoded>`. The
  `coder_app` resource in `coder/coder` `~> 2.18` has no `folder` argument, so the
  folder rides in the URL, in the Web Terminal's `command`, and as a positional
  argument to the code-server binary with `--ignore-last-opened` (path-based apps
  drop the query string, and without that flag the last restored workspace wins).
- `coder_app` resources are not gated on `start_count`. `coder/preview` warns
  `Unexpanded count argument on block coder_app.*` when they are: that value is
  not expanded at workspace-create preview. Scripts, metadata and the container
  stay gated.
- The `devcontainer` editor cannot set `agent_id` with
  `local.use_dc ? coder_devcontainer.repo[0].subagent_id : coder_agent.main.id`.
  `coder_devcontainer.repo` is also gated on `start_count`, so the stop /
  template-import ephemeral plan has an empty tuple even with the toggle on
  (the default), and that ternary then fails with `Invalid index` / `empty
  tuple`. `local.code_server_agent_id` is
  `concat(coder_devcontainer.repo[*].subagent_id, [coder_agent.main.id])[0]`:
  the sub-agent when that resource exists, the parent agent on the stopped
  page. The start-gated `coder_script.code_server` uses the same local.
- The custom icon `templates/common/vscode-alt.svg` travels as a
  `data:image/svg+xml;base64` data URL read from `templates/common/`. Coder serves icons
  only from its bundled `/icon/*` set or from a full `https`/`data` URL, and that icon is
  not bundled. `workspace_apps.icon` is `varchar(256)` on Coder v2.36, so the SVG is a
  compact ribbon whose data URL fits that column; a larger file fails `templates push`
  with `pq: value too long for type character varying(256)`. `push-template` rejects
  that locally, before the CLI runs.

### Editor settings seed

- `settings.json.tftpl` is copied once, the first time `~/.shared/vscode/settings.json`
  is missing, onto the per-owner volume `vscode-settings-<owner-id>`. Startup chowns
  that volume (and the shared `~/.grok` profile volume) to the home owner before
  the write: an empty Docker named volume is `root:root` 755, and the agent runs
  as `coder`. A failed write logs a warning instead of running `jq`/`python`
  against a file that was never created.
- code-server's User settings file is a symlink to that path, so every workspace that
  owner has opens the same file, and an edit - in any workspace, or from the host by
  mounting the volume - is not overwritten on the next start. Delete the file to reseed
  from the template.
- A built dev container sees neither the volume nor that symlink, so it is the one place
  the seed is merged instead of linked.
- The code-server module is deliberately given no settings map in plain mode: its merge
  runs on every start and `mv`s over that symlink, which would fork a private copy and
  discard the sharing. (`devcontainer` passes the seed to the module only in the mode where
  the merge is wanted, and bakes it as `settings_b64` for the built container.)
- The seed in git carries no API key. Cline and Roo read their key out of `settings.json`
  and have no `env_key` field, so when `LITELLM_API_KEY` is set the startup script injects
  it into the seed once (`jq`, falling back to `python3`) and nowhere else.
- A *regular* file at the User settings path is the old per-workspace copy: the startup
  script keeps it beside the link once, as `<path>.pre-shared`, then points the editor at
  the shared file on every start so a workspace cannot drift off it. GNU `ln -sfn` replaces
  a symlink and does not follow it.
- `subdomain = false` everywhere: there is no `CODER_WILDCARD_ACCESS_URL` on this box, so
  the editor is proxied on the path-based access URL.

## Terminal and editor defaults

Template-side facts only; the long prose lives in
[docs/grok-build-and-agents.md](grok-build-and-agents.md).

- `terminal.integrated.defaultProfile.linux` is `"tmux"`. The automation profile stays
  `/bin/bash`, so build/tasks commands never wait on tmux. Plain `bash` and **Grok
  Build** stay available as extra profiles.
- Two helpers are seeded into `~/.grok/bin` on every start, both `chmod +x`:
  `vscode-terminal-tmux` (the default profile) and `grok-build-terminal`.
- `vscode-terminal-tmux` keeps `vscode-<folder>-<hash>` as its base session name. It
  re-joins one of that folder's sessions while no client is attached to it, oldest
  first (the closed-tab rejoin: an unattached session is reused even while sibling
  terminals are live); it takes the next numbered sibling, `vscode-<folder>-<hash>-2`,
  `-3`, ... only when every session of the folder already has a client. With no
  `tmux` on PATH it falls back to a plain login shell.
- `grok-build-terminal` keeps its own session, `grok-build-<folder>-<hash>`, keyed off
  the repository root found with `git rev-parse --show-toplevel` (or the terminal's own
  `$PWD` outside a clone) and runs `grok --cwd <that root>` inside it. It is the
  always-reattach case on purpose: every tab of the clone watches the one agent run.
- The seed also pins `terminal.integrated.cwd` and `terminal.integrated.splitCwd` to the
  opened folder, adds a `terminal.integrated.env.linux` block, and carries a
  `commandsToSkipShell` list - all described in the sibling doc.

## Cloning more than one repository

- One repository per workspace is the default, and that is what `repo_url` and the
  **Git repository** field mean: one URL, cloned into one folder.
- That folder is what code-server, the Web Terminal button and the Grok Build session
  open on. Inside a dev container, code-server sees that same folder under its mount
  target, `/workspaces/<repo-name>`.
- Keep it that way unless a workspace genuinely needs two trees open at once.

`--additional-repos` is the opt-in escape hatch for the service-and-the-library-it-uses
case. It takes a comma-separated list (`"url1,url2"`), one URL per line works too, and
the spaces around each entry are trimmed. It joins the list into one `additional_repos`
parameter, so `"a , b"` and `"a\nb"` both arrive in the template as `a,b`.

Without the flag the script passes exactly the parameters it used to pass, and the create
form's **Git repositories (additional)** textarea stays empty.

```sh
bazelisk run //scripts:new-workspace -- --additional-repos "https://github.com/foo/lib.git,https://github.com/foo/tool.git" https://github.com/foo/bar.git
```

- The extras are cloned **beside** the primary repository, into sibling folders, by the
  same clone-once rule (a folder that already holds a `.git` is left alone on later
  starts, never pulled on).
- `workspace` keeps the clone tree under `/home/coder/workspace/<repo-name>`;
  `devcontainer` keeps it under `/srv/coder-devcontainers/<workspace-id>/<repo-name>`.
- An extra folder never becomes the folder the tools open on: the editor, the Web
  Terminal button and the tmux helpers all stay on the primary clone.
- A private extra repository still has to be GRANTED to the connected GitHub account, or
  its clone is refused, just like the primary one.
- `--dry-run` prints the list under `also:` before it creates anything, so the decision
  is readable first.

## GitHub credentials for a workspace

GitHub credentials arrive by one path only: opt-in, and HTTPS-only.

- An `ssh://` or `git@` URL reaches nothing here - this stack provisions no SSH keys.
- The path is Coder's external-auth broker. With no `coder.env`, Coder CE injects
  a GitHub App whose id is `github`, and both templates declare that id by
  default. A custom OAuth app lives in `coder.env` (beside `docker-compose.yml`);
  `push-template.sh` forwards `CODER_EXTERNAL_AUTH_0_ID` so the templates declare
  the same id. Link that provider to **both** templates.
- Fill every `CODER_EXTERNAL_AUTH_0_*` key or omit them all. A defined-but-empty key
  crash-loops the server, which is why these keys live in `coder.env` and not in `.env`.
- Then connect your GitHub account. On a running workspace, click **GitHub reauth** on
  the agent bar (Coder v2.36's `/external-auth/<id>` page; use **Reauthenticate** if the
  page says you are already authenticated). First-time connect also works from the
  workspace create/update form and from Settings -> Tokens / external auth. Device-flow
  login is not enough for private repos: install Coder's GitHub App with **Install
  GitHub App** on the same bar (or open
  [github.com/apps/coder/installations/new](https://github.com/apps/coder/installations/new)),
  grant those repositories, then restart. An empty
  [github.com/settings/apps](https://github.com/settings/apps) page is not a misconfiguration:
  with `auth_type=client_secret` Coder has no App to install, and Coder's built-in GitHub
  App only earns a page there once it is installed on the account. Until something is
  installed and granted, that page simply has nothing to **Configure**, and the credential
  the provider mints still authenticates - it just cannot write to a private repository.
- Each workspace's agent then injects a `GIT_ASKPASS` helper that mints short-lived
  per-host tokens on demand, alongside a `GH_TOKEN`/`GITHUB_TOKEN` pair in the agent
  environment.
- `gh_token_refresh` (a `coder_script`) re-mints that pair on start and every 6 hours;
  the minted token expires in about an hour, so between refreshes the gh auth store
  can hold an expired credential for hours mid-day (check reports that staleness as
  REJECTED). `coder external-auth access-token` is the live path when the store goes
  stale: it re-mints on demand and answers with a live token, or with the
  re-authentication URL and exit 1; with no connected account the refresh script
  prints its one note (pointing at **GitHub reauth**, and at **Install GitHub App**
  when the injected App is in use) and exits 0, and mints nothing.
  After a reconnect, restart the workspace (or wait for the next `gh_token_refresh`)
  so `GH_TOKEN` and the gh auth store match the new grant. `git` can mint live through
  `GIT_ASKPASS` without that restart, where that helper answers prompts at all; the
  push-denied entry in `docs/troubleshooting.md` covers the case where it stays silent.
  `GH_TOKEN` itself only refreshes with the workspace or the refresh script. The refresh
  script unsets `GH_TOKEN`/`GITHUB_TOKEN` before `gh auth login --with-token`, because gh
  refuses stdin while those names are set.
- A token that authenticates but was never GRANTED the repository still fails clone and
  push, and reads prove nothing about write: a private repository hidden from the
  credential answers 403 or 404 on both lanes, and a public one answers a read probe
  with 200 for any authenticated caller, so a read-only credential passes a read test
  while every write to that repo is denied.
  `bazelisk run //scripts:github-auth -- check <repo-url>` asks the write question
  directly: one GET of
  `<repo>.git/info/refs?service=git-receive-pack`, the endpoint `git push` itself
  negotiates through.
- Nothing long-lived lives in any file, env or template: the rendered `config.toml`
  names `GH_TOKEN` and nothing else, and the pair stops at the workspace container's edge
  (a dev container built on the sidecar is not handed either key).
- One connection covers every workspace, and `gh auth status` inside a workspace is how
  you check it landed.
- `~/.gitconfig` seeding reads that environment: an idempotent
  `credential.https://github.com.helper = !gh auth git-credential` entry (scoped to
  `github.com`) lets `git push`, `gh pr create` and `gh api` authenticate from the minted
  token rather than from a token stored in a file. It is skipped when your `gitconfig`
  already names a helper, because git takes the **last** value it finds for that host - a
  hand-written `[credential "https://github.com"]` section would otherwise be overridden by
  the appended line. It is scoped to `github.com` on purpose: `gist.github.com` is not what
  these workspaces push, and a gist credential would be a second scope to audit.
- The one copy on disk is the per-workspace gh auth store (0600) that `gh_token_refresh`
  maintains.

### `scripts/github-auth.sh`, the per-workspace doctor

- `check [container] [repo-url] [--source=<slot>]` names the credentials a workspace's
  git and gh could present and answers "can this credential WRITE to the repository you
  point it at?", by probing the receive-pack ref advertisement that endpoint `git push`
  negotiates through (full usage:
  `bazelisk run //scripts:github-auth -- --help`). On the host it
  enumerates the labeled workspace containers with docker, or probes a named container
  alone. Inside a workspace it runs SELF mode with no docker: this environment's own
  credential chain, one `self:` line per credential, and a named container there is
  refused with a pointer to the host. `--source=chain` (the default) answers every
  credential that could cover that repository; `--source=env`, `--source=gh` or
  `--source=mint` answers one slot and marks the answer shadowed while the env pair
  stands, because git and gh consult that pair first and never reach the store.
  `GH_TOKEN= GITHUB_TOKEN= <command>` is how you make them use the stored credential.
- `auth <container> - < PAT` installs a write-capable PAT into that workspace's gh auth
  store. That is legitimate in two cases: the owner connected no Coder account, so
  nothing can be minted, or the minted (or GitHub App) credential is revoked, expired,
  or simply was never granted the repository you are pointed at.
- Installing one REPLACES the credential that workspace was presenting. While an
  account *is* connected the store holds a minted pair and the next `gh_token_refresh`
  run (start, then every 6 hours) rewrites it, so the PAT is a stand-in, not a second
  permanent credential: rotate or remove it in GitHub -> Settings -> Applications when
  the work ends. `gh auth logout`, or a rebuild, clears the store either way.
- A PAT is never typed as an argument any more. `auth <container> <PAT>` is refused
  because argv is readable through `ps` and lands in shell history, so the script takes
  the token on stdin only: pipe it in (`echo "$TOKEN" | bazelisk run
  //scripts:github-auth -- auth <container> -`) or run `auth <container>` alone and
  answer the hidden prompt.
