# Coder workspace templates

Deep reference for `templates/workspace/` and `templates/devcontainer/`: what they build,
how they get pushed, what each template variable means, and how the create form and the
in-editor terminal and editor behave.

Contents:

1. [What the two templates make](#what-the-two-templates-make)
2. [How `push-template` works](#how-push-template-works)
3. [The same push, by hand](#the-same-push-by-hand)
4. [Create-form fields](#create-form-fields)
5. [Template variables](#template-variables)
6. [Autostop and TTLs](#autostop-and-ttls)
7. [Docker-in-docker](#docker-in-docker)
8. [The `devcontainer` template](#the-devcontainer-template)
9. [From a git URL: `bazelisk run //scripts:new-workspace`](#from-a-git-url-bazelisk-run-scriptsnew-workspace)
10. [Inside the workspace container](#inside-the-workspace-container)
11. [Terminal and editor defaults](#terminal-and-editor-defaults)
12. [Cloning more than one repository](#cloning-more-than-one-repository)
13. [GitHub credentials for a workspace](#github-credentials-for-a-workspace)

Related: [project-conventions.md](project-conventions.md) (shell and payload conventions),
[SECURITY.md](../SECURITY.md), and
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

- `GROK_BUILD_AGENTS.md` is the orchestration-protocol seed text the startup scripts
  inline into every workspace's `~/.grok/AGENTS.md` (read with `file()`).
- `vscode-alt.svg` is the editor icon (read with `filebase64()`). It stays small
  enough that the resulting `data:image/svg+xml;base64,...` URL fits Coder
  v2.36's `workspace_apps.icon` column (`varchar(256)`).
- `notes-setup.sh` is the library behind each clone's private `notes.md`. The
  startup script inlines it with `file()` the same way, writes it into
  `~/.grok/`, sources it, and calls `notes_materialize` per clone. That call also
  seeds the ignore entries that keep the file uncommitted; see "What is shared" in
  `docs/grok-build-and-agents.md` for what it writes into git config.
- All three are staged by the push plumbing beside each staged `main.tf` copy, which is the
  only place the server-side Terraform can read them from.
- A push whose staged copy is missing any of them fails early, by design.
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
| `GITHUB_MCP` | `--var github_mcp=true` | only when the value is `true` |
| `CONTEXT7_MCP` | `--var context7_mcp=true` | only when the value is `true` |
| `CONTEXT7_API_KEY` | `--var context7_api_key=...` | only when non-empty; the value is never logged |
| `SEARCH_MCP` | `--var search_mcp=false` | only when the value is `false` (the SearXNG MCP fallback is on by default; any other value pushes nothing and the template default stands) |
| `STACK_SEARCH_PORT` | `--var searxng_url=http://host.docker.internal:<port>` | always; a blank or non-numeric value falls back to `8181` |

- A dev stack that moved the search port needs its own template push: `searxng_url`
  is derived from `STACK_SEARCH_PORT` as read from `.env`, so a push made while
  `dev-stack.env` carries `18181` still names `8181` unless the key is set in `.env`
  too. A workspace dials the host gateway, where the compose network does not help,
  so the port in the rendered `SEARXNG_URL` has to be the one actually published.
- `repo_url` prefills the Git repository field on both create forms. `workspace` defaults
  to no clone and `devcontainer` to the coder/coder demo repo, which is why a blank
  `REPO_URL=` line stays unpassed.
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
3. **Git repository** (`repo_url`, input, mutable, default empty). Anything you type is
   cloned into the workspace on the next start.
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
| `grok_default_model` | `agent` | One of the four LiteLLM aliases. `agent` is the tool-capable Spark lane; each Spark box is a deployment inside `agent`. |
| `docker_socket` | `""` | Optional Docker socket URI; empty means the provider default. |
| `coder_agent_url` | `http://host.docker.internal:3002` | The URL the agent dials. Kept on the local plain listener so a public `CODER_ACCESS_URL` does not hairpin agent traffic through the reverse proxy. Empty keeps the provider-rendered access URL. |
| `dind` | `false` | Turns on the per-workspace privileged daemon described below. Does not exist in `devcontainer`. |
| `repo_url` | `""` in `workspace`, `https://github.com/coder/coder` in `devcontainer` | Prefills the **Git repository** field. Both templates clone that URL on the first start; a later start leaves a folder that already holds a `.git` alone. `REPO_URL` in `.env` overrides the default. |
| `additional_repos` | `""` | The **Git repositories (additional)** textarea under the repository field. Extra URLs cloned into their own folder beside `repo_url`. |
| `grok_profile_mode` | `shared` | `shared` mounts the owner's shared `~/.grok` profile volume; `private` gives that workspace a private `~/.grok` on its own home volume. Also the default behind the per-workspace **Grok profile** dropdown; switching a live workspace between the two modes needs a rebuild. |
| `github_mcp` | `false` | Wires the `github` MCP HTTP server into Grok's rendered `config.toml`. Its `Authorization` header names `$GH_TOKEN` and nothing else, so no token value is ever part of a template variable. |
| `context7_mcp` | `false` | Wires the cached `context7` MCP stdio server into Grok's rendered `config.toml`. |
| `context7_api_key` | `""`, `sensitive` | Handed to the workspace as `CONTEXT7_API_KEY`. The rendered file names the variable. |
| `grok_config_extra` | `""` | The **Grok config extras** textarea: free-form TOML appended verbatim, under a comment header, to that workspace's rendered `~/.grok/config.toml`. |

Notes on the two dropdowns that take a custom value:

- The four `grok_default_model` aliases are `agent`, `coder`, `coder-fast` and `chat`,
  plus a **Custom** entry when the variable names another one.
- The provider requires a parameter default to be one of its options, which is why a
  custom `--var` value is injected as its own option instead of being dropped.
- A `github_mcp` of `true` with no GitHub account connected gives that workspace a server
  that fails its handshake once per session. A `context7_mcp` of `true` with an empty
  `context7_api_key` is the same shape: the block renders, and the server fails its
  handshake once per session.

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
  agent would strand. See [SECURITY.md](../SECURITY.md).
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
4. Writes the two terminal-profile tmux helpers (see below).
5. Seeds the shared code-server User settings and the Coder Agents context files, only
   for files that are absent.
6. Renders `~/.grok/config.toml` (no MCP servers declared by default).
7. **Clones a non-empty Git repository field** into `/home/coder/workspace/<repo-name>`
   (in `devcontainer`, onto the `/srv/coder-devcontainers/<workspace-id>` bind). This is
   idempotent, runs as the workspace user so their git credentials are consulted, and
   refuses to touch an existing non-git folder there.

The repository leaf is derived the same way in `main.tf` and in `startup.sh.tftpl`:
split on `/`, drop empty segments, take the last, drop a trailing `.git`, map every
character outside `[A-Za-z0-9._-]` to `-`, and fall back to `repo` when that leaves no
leading alphanumeric. Both derivations must agree, or the editor and the terminal
helpers point at a folder that was never cloned.

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
  upstream module hardcodes `/icon/code.svg` and has no icon input.
- The `workspace` fork installs code-server **only when it is missing** from
  `/home/coder/.local/share/code-server`, and starts it with
  `--auth none --port 13337 --app-name "VS Code Web" --ignore-last-opened <folder>`,
  passing no settings payload. The
  editor's settings live on the per-owner `vscode-settings-<owner-id>` volume seed, not
  in a per-start merge.
- The `devcontainer` fork has no persistent prefix to reuse - both toggle modes rebuild
  the container that hosts the editor - so it installs fresh under `/tmp/code-server` on
  every start, and bakes the settings seed as base64 into the dev container's private
  User settings copy.
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
- `vscode-terminal-tmux` re-joins or starts one shared session per folder, named
  `vscode-<folder>-<hash>`; with no `tmux` on PATH it falls back to a plain login shell.
- `grok-build-terminal` keeps its own session, `grok-build-<folder>-<hash>`, keyed off
  the repository root found with `git rev-parse --show-toplevel` (or the terminal's own
  `$PWD` outside a clone) and runs `grok --cwd <that root>` inside it.
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
  so `GH_TOKEN` and the gh auth store match the new grant; `GIT_ASKPASS` remints live
  without that. The refresh script unsets `GH_TOKEN`/`GITHUB_TOKEN` before
  `gh auth login --with-token`, because gh refuses stdin while those names are set.
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
  already names a helper, because git takes the **last** value it finds.
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
