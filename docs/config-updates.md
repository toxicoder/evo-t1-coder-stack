---
title: Keeping a checkout's config current
description: What goes stale after a `git pull`, what `update-configs` refreshes, and what it deliberately will not touch.
tags: [env, config, update-configs, maintenance]
---

**What's on this page**

- Which files go stale and why `git pull` cannot fix them
- The two passes of `update-configs`, and the flags that select one
- That env comments always refresh from the twin, even when values stay
- Where the command may run, and where it refuses to
- The long form of the `.env.sample` comments: GitHub external auth, Grok profile mode, public hosts, the Spark `agent` group

**What this enables**

- Bringing an old checkout back to a runnable state with one command
- Telling a ported env key apart from a value you set yourself and must keep

Two kinds of file go stale in this repo, and because neither of them is
checked in, `git pull` cannot fix either one for you. `update-configs` is the
one command that refreshes both, and it is written to be safe to run when you
are not looking closely at the diff.

These four sections are also the long form of the `.env.sample` comments that
point here: GitHub external auth, Grok profile mode, public hosts, and the
Spark `agent` model group. Where a topic page already owns a subject, this page
points at it instead of restating it.

```sh
bazelisk run //scripts:update-configs -- env --dry-run
bazelisk run //scripts:update-configs -- env
bazelisk run //scripts:update-configs -- env --non-interactive
bazelisk run //scripts:update-configs -- workspace --dry-run
bazelisk run //scripts:update-configs -- all
```

Run it after you pull, not before: a pull is what changes the templates these
tools copy from. `bazelisk run` feeds the real checkout (`BUILD_WORKSPACE_DIRECTORY`),
not the runfiles copy, so the env pass rewrites the live `.env` beside
`docker-compose.yml`.

## What goes stale

**The env files.** `docker-compose.yml` builds its variable references in two
steps: `${VAR}` inside `expose` expands during the shell phase, so compose
never sees those variables and a changed value needs a rebuild, and an unset
variable collapses to `127.0.0.1:57620:57620/tcp`, which fails to bind. So the
host ports and addresses live in a key=value env file - `.env` for the stable
stack, `dev-stack.env` for the dev one - and each has a checked-in twin beside
it that carries the keys and explains them in the comment lines above. A pull
that renames, adds or retires a key silently changes what the stack runs on.

**The workspace config.** `~/.grok/AGENTS.md`, `~/.grok/config.toml`,
`~/.shared/vscode/settings.json`, `~/.tmux.conf` and the `~/.coder` and
`~/.agents` seeds are materialised inside each workspace when it first boots and
are never revisited after that. A re-pushed template only reaches workspaces
that have been **start**ed or **restart**ed since the push - **stop** and
**start** is what re-runs the provisioning script and therefore re-runs
`before_config`.

## The two passes

`env` reconciles one env file with its twin. It keeps every value you have set,
fills a key the twin adds with the twin's default (or a reusable value already
set in a sibling live file - `.env` filling `dev-stack.env`), and moves a key
the twin no longer declares into a commented trailer at the end of the file -
parked, with its value and its explanation still readable, rather than deleted.
Comment lines always come from the twin, even when every value stays as you
set it, so a pull that only rewrote an explanation still lands in `.env`. The
rewrite lands in a staging file and replaces the live file only at the end,
with mode `600` kept. On a TTY the pass then walks every key that is new this
pull or still a placeholder (`change-me…`, `NOTSET`, `YOUR_LAN_IP`). An empty
value whose example default is also empty is the intended value (LAN-only
`STACK_PUBLIC_HOSTS`, a parked MCP flag) and is not asked again. Enter keeps a
sibling's value or the example default. A missing live file is created from
the twin only after a `Y/n` confirm. `--non-interactive` (and `--dry-run`)
list those keys and write no answers. A `summary:` line closes the pass.

`workspace` re-materialises the stack-owned config inside the targets you name.
The reseed set is the nine home-relative targets the templates seed -
`~/.tmux.conf`, `~/.grok/AGENTS.md`, `~/.coder/AGENTS.md`,
`~/.agents/INSTRUCTIONS.md`, the two `grok-build-delegation/SKILL.md` copies, the two
`learn/SKILL.md` copies and `~/.shared/vscode/settings.json` - and the same rule
applies as in `refresh-configs`: a file is replaced only while it still carries its
stack marker - the `managed-by: evo-t1-coder-stack` comment, the
`"__evoT1Stack": true` JSON key (settings files) or the `__evoT1Stack = true` TOML
key (`~/.grok/config.toml`) - so a config you hand-edit in a terminal is your
file and this tool will not move it. `--force` overrides that, per run, and says
so. The two `learn/SKILL.md` copies are `~/.coder/skills/learn/SKILL.md` and its
`~/.agents` twin, the stack's `/learn` skill. To take a seeded copy over, edit it and
delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
user-owned, and the seeder leaves it alone unless you pass `--force`. A deletion is
undone - the workspace boot writes the file again whenever it is absent, and
`refresh-configs` re-seeds an absent target, so the next boot restores the stack's
copy. To hide the slash command, set `disabled = ["learn"]` under `[skills]` in
`~/.grok/config.toml`. An edited copy which keeps its marker is still rewritten back
to `templates/common/learn.SKILL.md` by this tool.

`all` runs `env` and then `workspace`.

## Flags

| Flag | Effect |
|---|---|
| `--dry-run` | print the plan, write nothing |
| `-i`, `--interactive` | stop and ask about every key that still needs a value (the default on a TTY) |
| `--non-interactive` | never prompt; list what would be asked |
| `--force` | reseed workspace files that carry none of the three markers |
| `--from <dir>` | read the payloads from that checkout instead of this one |
| `--home <dir>` | treat that host directory as a workspace `HOME` |
| `--container <name>` | address one container by name |

Every flag goes **after** the subcommand, so `update-configs --dry-run env` is a
usage error and prints the usage rather than guessing.

On a TTY the env pass asks by default (`-i`/`--interactive` is then a no-op;
`--non-interactive` turns it off). For every key that is new this pull or still
`change-me…`/`NOTSET`/`YOUR_LAN_IP` it prints the explanation the twin carries
above that key and prompts for a value. Enter keeps a reusable value already
set in a sibling env file, or the example default. A key whose
name carries `KEY`, `SECRET`, `TOKEN` or `PASSWORD` is echoed nowhere - the
report says `set` or `empty` and the prompt does not echo what you type - so a
screenful of this output is safe to paste into an issue. With no terminal to
prompt through the pass warns and leaves those keys alone, which is why
`--dry-run` / `--non-interactive` is the shape that belongs in a script or CI.

## Where to run it

`workspace` addresses docker, so run it from a **host** shell. A terminal inside a
workspace is not a host shell: the `docker` CLI there is only installed so you can
drive that workspace's own DinD sidecar, so `docker ps` answers empty and an empty
`docker ps` means "wrong vantage", not "stack down". The pass now prints which
daemon it addressed and tells you to use a host shell, or to name the target:

```sh
bazelisk run //scripts:update-configs -- workspace --home ~/scratch/home
bazelisk run //scripts:update-configs -- workspace --container coder-alx-main
```

`--home` takes a host directory shaped like a workspace `HOME`, which is also how
you try a change on a scratch tree before pointing a live stack at it. See
[troubleshooting.md](troubleshooting.md) for the docker-vantage rules.

## What it will not do

- It never prints an env value that looks like a credential.
- It never drops a key your env file still sets; retired keys are commented out
  in place.
- It does not touch `~/.grok/config.toml`. That file is rendered *inside* the
  workspace, and `~/.grok` is one profile volume per owner, so a copy from the
  host would move the model list, the session-affinity key and the editor keys
  of every workspace sharing the profile. A **start/restart** re-renders it from
  this checkout, which is the only way a per-workspace value gets in, and the
  pass says so after it reseeds.
- `~/.shared/vscode/settings.json` is the one rendered target it does reseed, and
  it re-*renders* rather than copies: `${litellm_url}` and the `$${...}`
  dollar-brace unfoldings are rewritten, and that workspace's own `cline.apiKey`
  and `roo.openaiApiKey` are carried forward.

Inside a running container the same nine targets are `refresh-configs`'s job
too: same reseed set, same marker rule, `--json` for a machine-readable
answer, and `--litellm-url <url>` for a stack environment that publishes
LiteLLM on a port other than 4000 (the reseeded `settings.json` then still
names that stack's own model transport). [grok-build-and-agents.md](grok-build-and-agents.md) covers the profile
volume and what seeds on first boot.

## GitHub external auth and coder.env

`.env.sample` deliberately carries no GitHub credential of any kind, so the env
pass has nothing to reconcile here: the twin declares no `CODER_EXTERNAL_AUTH_0_*`
key and `update-configs` will never add one. Those keys belong in `coder.env`
beside `docker-compose.yml` (gitignored), which is not a file this tool touches.

**A defined-but-empty key crash-loops the server.** Any `CODER_EXTERNAL_AUTH_0_*`
counts as a configured provider even when its value is empty, and an empty key
makes `coder server` exit at boot with `external auth provider "" doesn't have a
valid id` - which the compose restart policy turns into a crash loop. Do not set
only `CODER_EXTERNAL_AUTH_0_APP_INSTALL_URL` either: it suppresses the injected
App like any other key in the set. A custom GitHub App belongs in `coder.env`
fully filled, including
`APP_INSTALL_URL=https://github.com/apps/<slug>/installations/new`.

**Leave `coder.env` absent for the usual case.** Coder CE injects its own GitHub
App (provider id `github`, device flow) and both templates declare that id by
default, so `bazelisk run //scripts:push-template` works with no extra file.
Workspace owners connect GitHub under Settings -> Tokens / external auth.

**Create `coder.env` only for a *custom* GitHub OAuth app**, and fill EVERY key -
`ID` names the provider and `TYPE` says what kind it is. Restart coder to apply
the file.

```dotenv
CODER_EXTERNAL_AUTH_0_ID=primary-github
CODER_EXTERNAL_AUTH_0_TYPE=github
CODER_EXTERNAL_AUTH_0_CLIENT_ID=<GitHub OAuth App client id>
CODER_EXTERNAL_AUTH_0_CLIENT_SECRET=<GitHub OAuth App client secret>
CODER_EXTERNAL_AUTH_0_REVOKE_URL=https://github.com/settings/connections/applications/<client id>
#CODER_EXTERNAL_AUTH_0_REGEX=github\.com
```

- `CODER_EXTERNAL_AUTH_0_REGEX` is only for telling providers or hosts apart;
  omitted, it matches every `github.com` remote.
- `push-template.sh` reads `CODER_EXTERNAL_AUTH_0_ID` from `coder.env` and
  forwards it as `--var github_auth_id=` so the templates declare the same id.
  Changing the id orphans existing GitHub account links.
- Then connect your GitHub account in Coder (Settings -> Tokens / external auth)
  and link the same provider to **both** workspace templates (Templates -> edit
  -> External Auth).
- The callback URL on the GitHub side is
  `<CODER_ACCESS_URL>/external-auth/<id>/callback` - `github` for the injected
  App, `primary-github` for the sample app above.

**Device-flow login is not the App install.** Private repos need the Coder GitHub
App installed from
[github.com/apps/coder/installations/new](https://github.com/apps/coder/installations/new)
(the workspace "Install GitHub App" button), then a restart so `GH_TOKEN` remints.
The grant must include the repos you clone, or a connected credential authenticates
and is still 403.

**How the token reaches a workspace.** It arrives as `GH_TOKEN` and `GITHUB_TOKEN`
in the agent environment, and the template's `gh_token_refresh` coder_script
re-mints that pair on start and every 6 hours (`0 0 */6 * * *`) because a minted
token expires first. Check it with `gh auth status` inside the workspace, or
`bazelisk run //scripts:github-auth -- check` for one line per credential slot.
[coder-templates.md](coder-templates.md#github-credentials-for-a-workspace) owns
the template-side detail.

**Never a static PAT in `.env`.** `.env.sample` used to carry a `GITHUB_TOKEN=`
line holding a long-lived fine-grained PAT, which `push-template.sh` forwarded to
both templates as a template variable, into every workspace's environment. That
path is gone: there is no such template variable and no such key in the twin. A
workspace's GitHub credential comes from the External Auth provider alone, so an
owner who connected nothing has no GitHub credential anywhere - unless they install
one per workspace:

```sh
bazelisk run //scripts:github-auth -- auth <container> - < PAT
```

That pipes a PAT straight into that container's `gh` credential store - no `.env`
edit, no template push - and `gh auth logout` inside the container, or a rebuild,
removes it. The repositories a token can reach are whatever that GitHub app
installation was granted.

## Grok profile mode

`GROK_PROFILE_MODE` in the twin is the default for the template variable
`grok_profile_mode`, which the create form also shows per workspace as the **Grok
profile** dropdown. Read once per push, so changing the default here needs
`bazelisk run //scripts:push-template`. Overriding it for one workspace happens on
that dropdown and needs a rebuild, like `dind`.

- `shared` (the default): every workspace of a user mounts that user's shared
  grok-profile volume nested inside `/home/coder`, so `config.toml`, the MCP warm
  caches, `memory-v2`, skills and a self-installed CLI are one profile shared by
  that account's workspaces. It is re-rendered on every start and the
  **last-started workspace wins** for all of them.
- `private`: no nested mount. Each workspace gets a private `~/.grok` on its own
  home volume, so its `config.toml` - plus memory, skills and logs - differs per
  workspace and dies with the workspace.
- A workspace moving `shared` -> `private` starts on an empty profile: nothing is
  copied and the shared volume is left alone.

Switching either way is a **rebuild**, not a stop/start, because the nested mount
is decided when the workspace is built.
[grok-build-and-agents.md](grok-build-and-agents.md) covers what the shared
profile holds and what seeds on first boot; the `workspace` pass above never
reseeds `~/.grok/config.toml` for exactly that reason.

## Public hosts and the dashboard

`STACK_PUBLIC_HOSTS` is the one switch, and it has three states. Empty keeps everything
below LAN-only and every derived `STACK_*_URL` stays empty. `auto` composes the five
names from the naming parts - `STACK_DOMAIN_BASE`, `STACK_SUBDOMAIN_SUFFIX`,
`STACK_ENV_LABEL` and the per-service `STACK_*_NAME` prefixes, all documented in
`.env.sample`. A comma-separated list is the hand-pin: those names are used verbatim.

- Entries are DNS names, not URLs: no scheme, no port, no path. The entry with no
  prefix is the dashboard.
- Each service name is **one label** under the zone and carries its prefix with a
  **HYPHEN**: a wildcard certificate covers exactly one label, so the dotted
  two-label form has no certificate at the public edge.
- Under `auto` the parts are the source of truth and `STACK_PUBLIC_HOSTS` is output
  only: bootstrap writes the resolved list back and records the intent in
  `STACK_PUBLIC_HOSTS_MODE=auto`, so a later run re-composes and a list edited by hand
  in `STACK_PUBLIC_HOSTS` is ignored. Bootstrap prints a `note:` naming the key to
  clear when that happens.
- `bootstrap.sh` derives `STACK_DASHBOARD_URL` / `STACK_CODER_URL` /
  `STACK_KASM_URL` / `STACK_LITELLM_URL` / `STACK_HERMES_URL` from the prefix on
  each entry (`coder-` / `kasm-` / `litellm-` / `hermes-`, dotted form still
  recognised) and upgrades `CODER_ACCESS_URL` to the coder name, so Coder builds
  workspace links on a secure context with a real certificate. Compose sets
  `HERMES_DASHBOARD_PUBLIC_URL` from `STACK_HERMES_URL` (the Chat tab's Host and
  Origin).
- The names also go into `HOMEPAGE_ALLOWED_HOSTS` (compose appends this raw value)
  and into the Coder certificate's subjectAltName.
- The Traefik on the other box owns TLS for those names and must forward plain
  HTTP to this box's router container **with the original Host header intact** -
  `STACK_ROUTER_CONF` names the conf that container mounts (`proxy/router.gen.conf`,
  rendered by bootstrap from `proxy/router.conf.template`, or the checked-in
  `proxy/router.conf` while the key is empty), and it picks the service from
  `$http_host` on `STACK_PROXY_HTTP_PORT` (default 8080). A rewritten Host comes back
  as `421`.
  That box needs one file, and the paste-ready version of it - one `loadBalancer`
  at `:8080`, a router per name, Authelia on the four interactive names, the
  long-lived timeouts - is
  [public-access.md#traefik-configuration](public-access.md#traefik-configuration).

Set the parts in `.env`, and in `dev-stack.env` too when a dev stack runs beside
the stable one, then re-run `bazelisk run //scripts:bootstrap` and recreate the
stack you switched. That one command is the whole rename: it re-renders the router's
vhost table and rewrites the derived URLs, so a hostname is no longer an edit split
across `proxy/router.conf`, `scripts/bootstrap.sh` and `docker-compose.yml`. A
`hermes-*` or `hermes.*` entry is part of that list:
bootstrap writes `STACK_HERMES_URL`, and the LAN `:9119` listener stays either
way. Leave the hermes name out and the Homepage card keeps the LAN URL.
[public-access.md](public-access.md) owns the naming rule, the measured
`ERR_SSL_VERSION_OR_CIPHER_MISMATCH` on the dotted form, the request path and the
checks to run on the Traefik box.

## Spark agent model group

The `agent` model group is three deployments behind one LiteLLM alias, one per
Spark box, and these are the keys that fill it:

- `SPARKn_OLLAMA_URL` are the Ollama endpoints behind the `spark-<n>` aliases. The
  placeholder hostnames are on purpose: replace them with real Ollama URLs or
  leave them as-is, and those aliases simply fail when used.
- `SPARKn_OPENAI_URL` are the OpenAI-compatible `/v1` endpoints. A workspace pins
  its session to one healthy box; fresh session-id-less traffic fans out by
  `least-busy`, shortest in-flight queue first.
- `SPARK_n_API_KEY` is the bearer token for each endpoint. TensorFold is
  vLLM-lineage, so treat it like vLLM/SGLang: any non-empty string is accepted
  unless the server was started with `--api-key`, in which case set the REAL key
  per box. Empty is not a working value - LiteLLM v1.102.1 fails every request at
  client construction (`AuthenticationError`, before reaching the box) and `agent`
  falls back to `coder`. The placeholder `local-spark` is not a secret and is
  ignored by a keyless backend.
- `SPARKn_HEALTH_URL` (kept commented in the twin) feed the dashboard's per-box
  Spark cards - one widget per box, so no card assumes one "usual" box.
- `AGENT_MODEL_URL` is the single `/v1/models` URL the "Agent backend" card uses
  for both its browser link and its status probe. All three boxes serve the same
  model id, so point it at any reachable one; the per-box health keys are what tell
  you which box answered.

Leaving all three `SPARKn_OPENAI_URL` keys empty keeps `agent` defined but
unusable: LiteLLM then falls back to `coder`, the Arc alias. That fallback is what
the "Agent backend" card exists to catch - Grok Build, Cline and Roo need
structured tool calls, which the Arc IPEX-LLM Ollama returns as plain text for the
Qwen2.5-Coder weights. [litellm-routing.md](litellm-routing.md) owns the alias
table, the picker, the pin, and the measured tool-call limitation (including which
aliases do emit real calls).
