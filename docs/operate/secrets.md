---
title: Secrets with Infisical
description: "The opt-in secrets vault: the twelve managed keys, the operator CLI verbs and their exit codes, the adoption sequence, what the workspace boot publishes and what it refuses, what happens when the vault is unreachable, and how a rotated credential reaches its service."
tags: [secrets, infisical, operate, credentials]
---

# Secrets with Infisical

**What's on this page**

- What the integration is, and the one property it deliberately does not change
- The flag that decides whether the bundle exists, and the second gate on the workspace side
- What the workspace boot publishes into `~/.infisical/agent.env`, what it refuses, and the residual it cannot refuse
- The three `secrets`-profile containers, and the CLI verb that reads the flag
- The adoption sequence, one command per step, with the container each step touches
- The twelve managed keys, who consumes each one, and what breaks when it is wrong
- The three runners that refresh the env file from the vault before compose renders
- What a vault outage does and does not do to `up`, to `pull`, and to a workspace boot
- The `CODER_PG_PASSWORD` rotation path, the volume-init trap under it, and the probe defect that blocks the verb today

**What this enables**

- Holding the stack's credentials in one place instead of in twelve lines of a dotenv file
- Rotating a key without opening an editor, and knowing when the running service picks it up
- Deciding whether adopting the vault is worth it, from what is actually wired

Self-hosted Infisical is the source of record for twelve of this stack's credentials,
behind a flag that defaults off. Three Compose services under profile `secrets` hold the
vault, its Postgres and its Redis; one operator CLI moves keys between the vault and the
host's dotenv file; and every service keeps reading credentials the way it always did.

That last sentence is the design, so it is worth stating exactly. Compose interpolates
`${VAR:-default}` against the `.env` beside `docker-compose.yml`, and nothing in the
compose layer ever opens a connection to a secrets service. An unreachable vault must not
be able to stop `up`, so the integration does not replace the dotenv chain - it feeds it.
`pull` writes the managed keys into `.env` and compose reads that file exactly as it
always has. The vault is an editor for `.env`, not a dependency of the project. Read that
as the whole delivery path: a credential change reaches a service through the env file and
a recreate, never through a live call to the vault. The one place the deploy path dials the
vault at all is the runners' own refresh before compose interpolates, and that call is
best-effort - one `warning:` and the bring-up continues on whatever the file already held.

This is the **free self-hosted tier**. No dynamic secrets, no cross-project sharing, and
no `LICENSE_KEY` anywhere in the checkout: both of those features are paid, and the
bundle ships neither. What is here is static shared secrets in one project, exported as
dotenv.

## The flag

One key decides whether the bundle exists: `INFISICAL_ENABLED`, default `false`, in
`.env.example` beside its own comment block. Owner: `platform`. Expiry: `2026-12-31`.

Unlike `OBSERVABILITY_ENABLED`, which ships on, **an unset key means off**. The
acceptance test is `truthy()` in `scripts/lib/common.sh` - `on`, `1`, `true`, `yes` - and
anything else, including the key being absent entirely, is off. Off means the three
containers are never selected (`profiles: ["secrets"]`), the runner CLIs pass no profile
argv (`compose_infisical_args` in `scripts/lib/infisical.sh` prints nothing, mirroring
`compose_observability_args`), and every mutating verb of the CLI refuses with a `note:`
that names the key to set. That is deliberate: a subsystem nobody opted into must not be
able to hold the stack's credentials hostage.

To adopt it, set the key in the env file that belongs to the project you run - `.env` for
the stable stack, `dev-stack.env` for the dev one - and bring the stack up as usual:

```sh
bazelisk run //scripts:dev-stack -- up
```

The runner appends the profile argv, so the three services come up with the rest of the
project. A profile selects services; it does not delete what is already running, so
flipping the key back off needs a `down` (or deleting the three by name) before the
containers actually go away. Their named volumes survive that, and `reset` is the verb
that destroys them.

There is a **second gate** under the first: `INFISICAL_PULL_ON_START`, default `false`.
It decides only whether a workspace's boot fetch dials the vault at all. It is off by
default so a workspace never waits on the vault, and it does nothing while
`INFISICAL_ENABLED` is off. Both gates are read inside the boot body itself, so the rendered
script is one text for every workspace and the flag pair arrives on the agent environment.

Both gates reach the templates through `bazelisk run //scripts:push-template`: the CLI forwards
`--var infisical_enabled=true` and `--var infisical_pull_on_start=true` only for a truthy value in
`.env`, so the shipped state pushes neither word and each template's own `default = false` stands.
With the flag off the `coder_script` resource is absent outright - no script, no boot log line,
no `INFISICAL_*` key on the agent environment - and the `.bashrc` hook is not written either,
because that line is gated on `infisical_hook`, which both twins set from `var.infisical_enabled`.

## The workspace boot fetch

`templates/common/infisical-secrets.sh.tftpl` is the body both twins render into
`coder_script "infisical_secrets"` (`run_on_start`, 120s timeout). One fact about its output
decides everything else in this section: `~/.infisical/agent.env` is sourced by every shell the
workspace starts, under `set -a`, from the line the startup script appends to `~/.bashrc`. It is
not a config file one process reads; it is an `export` line per key in the environment of every
terminal, tmux pane and command from then on, and it outlives the start that wrote it.

Two kinds of volume meet in that path and they are not the same thing. What rides per owner is
state only: `~/.grok/notes`, `~/.grok/memory` and `~/.grok/sessions` on `grok-notes-<owner-id>`,
`grok-memory-<owner-id>` and `grok-sessions-<owner-id>`, plus the `vscode-settings-<owner-id>`
overlay at `~/.shared/vscode`. Everything else under `~/.grok` is a real file on that workspace's
own home volume, `config.toml` above all - it carries this workspace's own model lanes, its
session-affinity key and its Grok theme. `~/.infisical` rides no per-owner mount at all, so
`agent.env` sits on this workspace's own home and only this workspace reads it. That asymmetry is
why the body filters rather than trusting a share boundary: a file a workspace can read is a file
anything running inside it can read.

The body gates itself twice before it dials anything. First the **six configured names**:
`INFISICAL_DOMAIN`, `INFISICAL_PROJECT_ID`, `INFISICAL_MACHINE_IDENTITY_ID`,
`INFISICAL_ENVIRONMENT`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` and
`INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`. Any one of them empty prints which names are missing and
where they come from, and exits 0. Then `INFISICAL_PULL_ON_START`, whose off path prints that the
boot "keeps the credentials it already has" and also exits 0. Every other failure path - no
`infisical` binary in the image, no `HOME`, a refused Universal Auth login, an empty export, a
refused publish - exits 0 as well. The golden image bakes the pinned CLI (`images/dev/Dockerfile`,
`INFISICAL_CLI_VERSION` in `images/dev/tool-versions.env`), so the missing-binary path is what an
image older than that pin hits. A vault outage has never once stopped a workspace.

What gets published is whatever the workspace's own machine identity can read in the project,
which is what the vault scopes - the twelve-key inventory is a host-side list
(`infisical/managed-secrets.txt`) and is deliberately not repeated in the body. So the workspace is
not limited to those twelve names, and two filters run on the key name before a line is written:

- Every key beginning `INFISICAL_` is dropped, so the vault's address and its Universal Auth pair -
  both plausible keys in the very project being exported - are never republished as workspace
  environment. Those names reach the workspace only on the agent environment, which Coder renders
  per start and never writes to disk.
- Every name on the body's deny list is dropped, compared on the key upper-cased so `BASH_ENV`,
  `bash_env` and `Bash_Env` all fall in one arm. The list is what a shell, the dynamic loader, an
  interpreter or git treats as code or as loader configuration rather than as data: `BASH_ENV` and
  `ENV` (executed by every non-interactive bash), `PROMPT_COMMAND` (by every interactive one),
  `PS4` and `IFS` (how the sourcing shell parses itself), `PATH` and `HOME` (which binary and
  which config the next command reads), the `LD_*` group (`LD_PRELOAD`, `LD_LIBRARY_PATH`,
  `LD_AUDIT`, `LD_DEBUG`), the interpreter-option group (`NODE_OPTIONS`, `PYTHONPATH`,
  `PYTHONSTARTUP`, `PERL5OPT`, `PERL5LIB`, `RUBYOPT`), the `GIT_*` group (`GIT_SSH_COMMAND`,
  `GIT_CONFIG_GLOBAL`, `GIT_EXTERNAL_DIFF`, `GIT_DIR`), and the program-choice group (`PAGER`,
  `LESS`, `EDITOR`, `VISUAL`, `SSH_ASKPASS`, `SUDO_ASKPASS`).

After the loop the staged file is read once more against one alternation built from that same
variable, and a match makes the body **refuse to publish**: it removes the staged file, prints
`infisical: refused to publish <home>/.infisical/agent.env; the staged file names a
shell-control variable. Nothing was written and no secret value is shown.` and exits 0. The
`agent.env` a previous boot wrote then stays exactly as it was, which is the point of refusing
rather than correcting. The obvious alternative - appending `unset PATH HOME IFS` lines to the
file - is the wrong shape: those names would be gone from every shell that sourced the file and
from everything those shells then launch. A refusal costs one refresh; that would cost the
workspace.

Every value is rewritten rather than copied, and that is a security step, not a stylistic one -
see the last bullet of [The credential boundary](#the-credential-boundary) for the upstream
quoting bug that makes it necessary. Two shapes still do not land, and the log says a different
thing for each:

- **A value whose opening single quote does not close on its own line** - a PEM or a multi-line
  certificate is the shape - is dropped whole. Its continuation lines are swallowed until one
  carries a quote, because publishing them would invent keys out of secret bytes. One note per
  boot, naming neither key nor value: `infisical: skipped a secret whose value spans more than
  one line; only single-line secrets are published.` The body carries no other shape, so a
  credential of that shape has to reach a workspace by some path other than this fetch.
- **A key the shell could not use as an identifier** - empty, starting with a digit, or holding a
  character outside `[A-Za-z0-9_]`, which is also where blank and comment lines fall out - is
  skipped silently. Nothing is printed for it; the only line that says how many keys landed is the
  success line, `infisical: loaded N secret keys into <home>/.infisical/agent.env`, and it counts
  what the publish loop actually wrote.

**The security boundary**, stated so no operator has to guess at it: because `agent.env` is
sourced by every shell a workspace starts, a vault key that the shell, the dynamic loader, an
interpreter or git would treat as code is not a secret, it is a command line chosen by whoever can
write a secret in the project. The two defences are the deny list above, matched on the
normalised case, and the pre-publish pass that refuses to write the file at all and leaves the
previous `agent.env` in place.

**The residual, honestly.** That list names what a shell or a loader *executes*. It is not a list
of every environment variable that changes what a program does, and it cannot be one. Anyone with
write access to the Infisical project still chooses which ordinary variables a workspace boots
with, and because the fetch's line is appended to `~/.bashrc` and runs under `set -a`, one of
those names can overwrite whatever that file set earlier in it. Treat write access
to the vault project as the trust boundary it is: it is shell access to every workspace that boots
with the fetch on. Read access is a much smaller grant than write, and the machine identity the
workspaces authenticate as should hold only the former.

The file itself is written mode 600 inside a mode 700 `~/.infisical`, staged beside its
destination and moved into place in one step rather than appended, so a reader never sees a
half-written file. `docs/coder-templates.md` carries the template side of all of this: the eight
`infisical_*` variables, why the credential pair rides the agent environment rather than the
rendered script body, and the order the boot body runs in.

## The three services

| Service | Image | Job | Published | Volume |
|---|---|---|---|---|
| `infisical` | `infisical/infisical:v0.167.10` | The vault. Serves the UI and the API on container port `8080`, runs its own cron and queue loop against Postgres and Redis. | `"${INFISICAL_PORT:-8182}:8080"` - published plainly, the way `:4000` and `:8181` are, so a workspace reaches it through the host-gateway | - |
| `infisical-db` | `postgres:16-alpine` | Infisical's store. Infisical is PostgreSQL-only; the Mongo path is retired. | nothing - compose DNS only | `infisical-db-data` -> `/var/lib/postgresql/data` |
| `infisical-redis` | `redis:7-alpine` | Job queue and cache. Runs `--save '' --appendonly no` under the `noeviction` policy: a `volatile-*` policy evicts queued jobs under memory pressure, and a dropped job is a sync that silently never runs. | nothing - compose DNS only | `infisical-redis-data` -> `/data` (empty while persistence is off; declared so a future change lands on a volume, not the writable layer) |

All three carry `restart: unless-stopped`, the `secrets` profile, and the same three-line
`json-file` logging block the rest of the stack uses, with `tag:` equal to the service
name so Alloy ships each container to Loki under `container=<name>`. None of the three is
a Prometheus target - Infisical publishes no `/metrics` endpoint the stack can rely on and
neither alpine image ships one - so they are recorded as log-only in
[observability.md](../observability.md).

The `infisical` container takes `ENCRYPTION_KEY`, `AUTH_SECRET`, `SITE_URL`,
`DB_CONNECTION_URI`, `REDIS_URL`, `HOST=0.0.0.0` and `PORT=8080` from the environment.
`DB_CONNECTION_URI` and the db service's `POSTGRES_PASSWORD` both interpolate
`INFISICAL_DB_PASSWORD`, which is the only thing keeping the role and its pointer in step
across a rotation. The public name, when you turn one on, is `STACK_INFISICAL_NAME`
(default label `infisical`) composed by `scripts/lib/domain.sh` like every other name;
the router sends that Host to `http://infisical:8080`. See
[public-access.md](../public-access.md).

## The operator CLI

Everything an operator does goes through one CLI, from any cwd:

```sh
bazelisk run //scripts:infisical -- <verb>
```

| Verb | What it does | Writes |
|---|---|---|
| `status` | What this box is configured to do: the flag, the profile argv, the port, the vault URL, the inventory size, and which required keys are still empty. Contacts nothing. | nothing |
| `check` | `status` plus whether the CLI binary is installed, whether the required keys are all set, and whether the machine identity can actually exchange a token. Run this first. | nothing |
| `install-cli` | Fetch the pinned release (`INFISICAL_CLI_VERSION`) and install the binary. Never pipes a download into a shell. | the binary |
| `bootstrap` | Create the super admin, the organization and the machine identity on a fresh instance, then record the identifiers into the env file. | the instance, then `.env` |
| `push` | Seed or migrate the managed keys from the env file into the vault, then read the vault back and compare a hash per key. | the vault |
| `pull` | Reconcile the managed keys from the vault into the env file. | `.env` |
| `rotate KEY` | Mint a fresh value for one managed key, vault first, env file second. | the vault, then `.env` |
| `run -- CMD` | Exec a command with the project's secrets in its environment. | nothing |

`--env-file PATH` points the verb at a dotenv file other than the `.env` compose itself
reads. `--help` prints the usage block above.

Exit codes, which are how a script tells "the vault said no" from "the vault is switched
off":

- **0** - the verb did its job. Always for `status` and `check`: a check that fails on a
  stack that never adopted Infisical is a check nobody runs. `run` exits 0 on the
  flag-off refusal too, having printed the `note:`; every other mutating verb exits 5.
- **1** - a real failure. The CLI errored, a read-back hash disagreed, a `rotate` target
  is not a managed key. A `rotate` or `run` that names no key and no command lands here as
  well, on an `error:` line.
- **2** - an unknown subcommand, always raised before any work starts.
- **5** - refused, because `INFISICAL_ENABLED` is off or a prerequisite is empty. Printed
  as a `note:` that names the key to set.

There is deliberately no `--json` mode: a JSON answer about a credential is an answer that
leaks it in a different font.

Nothing else in the repo shells out to this CLI. The three runners that address the compose
project - `bazelisk run //scripts:dev-stack`, `//scripts:prod-stack` and `//scripts:update-stack` -
source `scripts/lib/infisical.sh` and call `infisical_pull` themselves, immediately before compose
interpolates the env file, so a key rotated in the vault lands on the bring-up in front of you
instead of waiting for a human to run the verb. Each prints one `-> vault: refreshing the env file
from Infisical` phase line when the flag is on, and each treats a failed pull as one `warning:`
naming the retry - `the env file was not refreshed from Infisical; <file> keeps the credentials it
already has - retry with bazelisk run //scripts:infisical -- pull` - and then continues. The
branch never runs while the flag is off, so a stack that never adopted the vault reads and prints
exactly what it did before. `bazelisk run //scripts:update-stack -- --dry-run` plans that fetch
(`note: dry run: would refresh <file> from Infisical`) and writes nothing; the two stack runners
have no dry-run mode, so their refresh happens only on a real `up`.

## Adopting the vault

The sequence, in this order. Each step names what it changes.

1.  Give the vault its own bootstrap credentials and its admin address in `.env`.
    `INFISICAL_DB_PASSWORD`, `INFISICAL_ENCRYPTION_KEY` and `INFISICAL_AUTH_SECRET` ship
    as `change-me-*` placeholders in `.env.example`, and `INFISICAL_ADMIN_EMAIL` ships
    empty while `INFISICAL_ADMIN_PASSWORD` ships as a placeholder - `bootstrap` refuses
    either if it is still empty or still starts with `change-me`. These four cannot come
    from the vault, because the vault needs them to start.

2.  Turn the flag on: `INFISICAL_ENABLED=true` in the project's env file.

3.  Install the CLI binary on the host.

    ```sh
    bazelisk run //scripts:infisical -- install-cli
    ```

    This writes only the binary, at the path `infisical_cli_install_path` prints, and nothing
    else changes. The release it fetches is the pin: `INFISICAL_CLI_VERSION` in `.env.example`
    (0.45.8 as shipped), from the goreleaser asset name the seam builds. Nothing here pulls a
    version out of the network.

4.  Start the three services. `up` selects the profile now that the flag is on:

    ```sh
    bazelisk run //scripts:dev-stack -- up
    ```

    That creates `infisical`, `infisical-db` and `infisical-redis`, on the image tags the
    `image:` lines in `docker-compose.yml` pin (`infisical/infisical:v0.167.10` as shipped). The
    vault answers on `http://127.0.0.1:8182` (`INFISICAL_PORT`) on the stack host, and on the
    published LAN face. Expect the two alpine containers to read `running` rather than `healthy`:
    neither declares a healthcheck, because the only consumer waits on `service_started`. With
    the flag already on, this first `up` also tries the env-file refresh and gets nothing: there
    is no `INFISICAL_PROJECT_ID` yet, so the seam prints `note: the pull was refused before it
    ran; <file> keeps the values it has` and the runner follows with its `warning:` line. That
    pair is noise until step 5 writes the identifiers - it is not a failed bring-up.

5.  Bootstrap the instance:

    ```sh
    bazelisk run //scripts:infisical -- bootstrap
    ```

    This creates the super admin, the organization and the machine identity **inside the
    `infisical` container**, and writes the returned identifiers into `.env`. It is
    idempotent in the safe direction: if `INFISICAL_PROJECT_ID` or
    `INFISICAL_MACHINE_IDENTITY_ID` is already set it prints a `note:` and refuses to run
    again. It needs `python3` on PATH to parse the response, and the CLI from step 3. The
    machine identity's own token is checked for presence and deliberately not stored: it stays
    inside Infisical and every later run exchanges the pair below for a fresh one.

6.  Paste the machine identity's Universal Auth pair into `.env`. `bootstrap` prints the `note:`
    that says so once it has written the identifiers, and nothing downstream guesses:
    `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` and `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET` are two of
    the six keys `check` reports as empty, and a `push` or `pull` with either blank is refused
    before it authenticates. Create the credentials for that identity in the Infisical UI and put
    both values in the env file; neither belongs in a commit.

7.  Adopt what is already in `.env`:

    ```sh
    bazelisk run //scripts:infisical -- push
    ```

    This seeds the twelve managed keys into the vault, skipping any key the env file does
    not hold or holds empty - with a `warning:`, never an empty write. It then exports the
    project again and compares a hash per key, so a set the server accepted and dropped is
    reported as a failure rather than a clean seed.

8.  Prove the round trip:

    ```sh
    bazelisk run //scripts:infisical -- pull
    ```

    With the vault and `.env` agreeing this writes nothing new. It is the read path, so it
    is the one to run before you trust `push`.

9.  Recreate the consumers so they pick up what the vault holds:

    ```sh
    bazelisk run //scripts:dev-stack -- up
    ```

    Compose reads `.env` when it creates a container, and this `up` refreshes that file from
    the vault first (see [The operator CLI](#the-operator-cli) for the runners' own pull).
    Nothing is recreated until
    you ask for it, so the `pull` in step 8 alone changes no running service - this step does.

Then, any time after, `check` is the single command that asks every precondition at once:

```sh
bazelisk run //scripts:infisical -- check
```

## The twelve managed keys

The inventory is data, not code: `infisical/managed-secrets.txt`, read through
`infisical_managed_keys()`. Never re-hardcode the list. The count is asserted - `check`
warns when the inventory is not exactly twelve, because a silently-short list would leave
a credential outside the vault while still reporting a clean sync. Every key must also
exist in `.env.example`, since compose keeps interpolating that file.

| Key | Consumed by | What breaks if it is wrong |
|---|---|---|
| `CODER_PG_PASSWORD` | Coder's PostgreSQL URL and the `db` container's `POSTGRES_PASSWORD` | Coder cannot open its database; it crash-loops until the two halves agree again. Rotation has its own trap - see below. |
| `LITELLM_MASTER_KEY` | LiteLLM, and every agent lane that authenticates with it | Every agent lane is refused. The Prometheus scrape of LiteLLM's `/metrics` carries this key as its bearer token too, so that target goes down with it. |
| `HOMEPAGE_AUTH_SECRET` | Homepage | The dashboard's own login is refused. |
| `HOMEPAGE_AUTH_PASSWORD` | Homepage basic auth | The dashboard asks for a credential nobody holds. |
| `HERMES_DASHBOARD_PASSWORD` | Hermes dashboard basic auth | The dashboard on `:9119` and its public name both refuse the login, on every door. |
| `HERMES_DASHBOARD_SECRET` | Hermes dashboard | The dashboard session does not hold; the Chat tab will not stay signed in. |
| `HERMES_API_SERVER_KEY` | Hermes API server | The programmatic door the agents call with answers unauthorised; the Chat tab still works. |
| `GRAFANA_ADMIN_PASSWORD` | Grafana (observability) | The observability admin login fails. `GRAFANA_ADMIN_USER` is not managed, so an operator who changed only the password is locked out by a half-sync. |
| `STACK_SEARCH_SECRET_KEY` | SearXNG, handed to the service as `SEARXNG_SECRET` | SearXNG cannot sign its own requests; the MCP `search` lane answers empty rather than with an error. |
| `SPARK_1_API_KEY` | LiteLLM's upstream config, Spark box 1 | That box's deployments fail upstream auth and every alias riding them errors - while the other two boxes keep serving, which is what makes it read as a partial outage. |
| `SPARK_2_API_KEY` | LiteLLM's upstream config, Spark box 2 | As above, for that box. |
| `SPARK_3_API_KEY` | LiteLLM's upstream config, Spark box 3 | As above, for that box. |

The first eight are the list `scripts/bootstrap.sh` used to carry twice; that duplication
is what this inventory replaced.

## Keys the vault does not hold

Two lists sit outside the inventory, and they are outside for different reasons.

Four secret-shaped keys compose interpolates are among them, and each one is
outside for a reason worth knowing before you add it:

- `INFISICAL_DB_PASSWORD`, `INFISICAL_ENCRYPTION_KEY`, `INFISICAL_AUTH_SECRET` - the
  vault's own bootstrap credentials. By definition they cannot come from the vault: it
  needs them to start. They live in `.env`, and you set them.
- `CODER_DEFAULT_TOKEN_LIFETIME` - a duration, not a secret.

Three more are credentials that never appear in a compose interpolation, so they
travel to their consumer through a CLI rather than through `${VAR}`:

- `INFISICAL_ADMIN_PASSWORD` - the login `bootstrap` uses to create the project and the
  machine identity (`scripts/lib/infisical.sh:1216`), minted by
  `scripts/bootstrap.sh:119`. It is spent before the project exists, so there is no
  vault to read it from yet.
- `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET` - the machine identity's Universal Auth
  secret, which is the credential every fetch authenticates with
  (`scripts/lib/infisical.sh:803`). Storing it in the project it unlocks would make the
  vault a precondition of reading the vault.
- `CONTEXT7_API_KEY` - the optional Context7 MCP lane's upstream key, forwarded as
  `context7_api_key` by `scripts/push-template.sh:573-577` and seeded into
  `~/.grok/config.toml` by `//scripts:seed-dev-env`. Most operators never set it, and
  `pull` prints one `warning:` per inventory key the vault does not carry, so shipping
  it in the inventory would make the default state a warning on every fetch.

Anything compose interpolates that looks like a credential and appears nowhere on this
page is either a bug in the inventory or a bug in the compose file, and `check` is the
command that catches the first.

## When Infisical is unreachable

The outage is bounded, because the only read the deploy path makes is a best-effort refresh
whose failure is one `warning:` line.

- **`up` cannot be stopped by it.** Compose never contacts Infisical: it interpolates `.env`,
  which is a file on disk, and whether the three containers are part of the project is a
  profile decision made from one key, not a network result. The runner's own pull runs before
  that interpolation and a failed one costs a line, not the bring-up - `warning: the env file
  was not refreshed from Infisical; <file> keeps the credentials it already has - retry with
  bazelisk run //scripts:infisical -- pull` - and compose recreates against what the file
  already held. `//scripts:prod-stack` and `//scripts:update-stack` behave the same way; the
  latter plans the fetch instead of running it under `--dry-run`.
- **`pull` leaves `.env` alone and says so.** A failed export is an `error:` line naming
  the file as untouched, and the verb exits 1. An export that comes back empty is a
  `warning:` and the same untouched file. A key the vault does not carry, or carries
  empty, is a `warning:` per key and the existing value in `.env` stays exactly as it was
  - a half-seeded project must not lock every service out of its own credential.
- **A workspace still starts.** The boot fetch is best-effort: with the flag off, with
  `INFISICAL_PULL_ON_START` off, with no CLI in the image (the golden image bakes the
  pinned release, so that is an image older than the pin), with a refused Universal Auth
  login, with an empty export, or with a refused publish, it exits 0 and the workspace
  continues its startup. `agent.env` keeps whatever the last start wrote, since the body
  stages beside the destination and moves in one step rather than truncating first. A vault
  outage has never once stopped a workspace.
- **`rotate` stops at the first half.** If the vault refuses the write, `.env` is left
  untouched and the verb exits 1 - the stack keeps running on the old value. The reverse
  case prints the recovery in the error line: if the vault took the new value and the env
  write failed, re-run `pull` to converge.

So neither side can fail to *start* over a vault that is down. The workspace is the one that
never can: every path in the boot body, refusals included, exits 0 and the agent goes on with
the environment it already had. The stack is the one with state to corrupt, and the way it
breaks is the opposite of an outage - the refresh succeeds by writing, so a vault that answers
but holds a value nothing authenticates with is what brings `coder`, `litellm`, `homepage`,
`hermes`, `grafana` or `searxng` up unable to log in. That is a converge-and-recreate problem,
not a start problem: fix the value in the vault, run `up` again, and read the `db` and `coder`
logs if Coder takes longer than a recreate to come back.

## Rotating CODER_PG_PASSWORD

```sh
bazelisk run //scripts:infisical -- rotate CODER_PG_PASSWORD
```

The verb mints a fresh value, writes the **vault first**, and only touches `.env` once the
vault accepted it - so there is no moment where `.env` holds a password the vault does not
know about. `rotate` names one managed key; naming anything outside the inventory is an
`error:` and exit 1.

Whether a name counts as managed is decided by `infisical_is_managed_key` in
`scripts/lib/infisical.sh`, which reads the inventory and compares the names inside the
shell. The first version piped the reader into `grep -qx` instead, and under the CLI's
`set -euo pipefail` that lost: `grep -q` exits on its first match, the reader then died of
SIGPIPE, the pipeline reported 141, and the verb called a genuinely managed key unmanaged
on 195 of 200 attempts. Two suites now hold the line - one drives all twelve names through
the predicate inside a `pipefail` shell, the other runs the verb against each of them - so
the shape cannot come back unnoticed. A name outside the inventory is still an `error:` and
exit 1, and the inventory itself stays the only list.

Then the note the CLI prints is the real edge, and it is worth repeating here: compose
reads `.env` only when a container is recreated, so the rotated password reaches Coder on
the next `up`. Nothing hot-reloads it.

Under that sits one trap. The Postgres image honours `POSTGRES_PASSWORD` **only at first
volume init**, so changing it in `.env` and recreating `db` would leave the stored
password unchanged and lock Coder out of its own database. Two things cover it:

- `scripts/lib/pg-apply-password.sh` reconciles the password at the `db` entrypoint, so
  the stored credential is brought in line with `CODER_PG_PASSWORD` on every start of that
  container.
- `restart_coder_if_pg_auth_failed`, sourced by both stack runners, bounces `coder` when
  its logs show `password authentication failed` - which is the failure mode a stale
  password produces when the two halves land in the wrong order.

Both run as part of `up`, so the operator's job is one `up` after the rotate. Read the
`db` and `coder` logs if Coder takes longer than a recreate to come back:

```sh
bazelisk run //scripts:dev-stack -- logs --tail 200 coder
```

`INFISICAL_DB_PASSWORD` has the same first-init behaviour and no reconciler beside it - the
compose block says so at its own comment - so rotating it needs the `infisical-db-data`
volume reset, not a recreate.

## The credential boundary

The rules that shape every write in this subsystem, inherited from
`scripts/dashboard-password.sh`:

- A value does not travel in argv except where upstream offers no other channel. The seam's
  header names the exceptions: `--client-secret=` on the Universal Auth login and `--password=`
  on `bootstrap`, because that CLI takes neither on stdin; and the `KEY=@<file>` form for a
  single write, which names a file rather than the value, as `--file=<tmp600>` does for a bulk
  set. Everything else that carries a managed value crosses the seam by redirect into a
  mode-600 file, never through `$( )`, a pipeline, or a variable the CLI fills.
- A value never appears in a log line, including a failure line. Every ok, warning and
  error names the **key**, never the value, and counts rather than listing. The one function
  allowed to put a credential on a stream is `infisical_login`, whose whole job is handing the
  access token to its caller on stdout while its commentary goes to stderr; the callers that do
  not need it send that stream to `/dev/null`. The boot body scrubs the token and the client
  secret out of the CLI's own error text before it prints what the export said.
- A file that holds one is mode 600 and is removed on the failure path too, by the `EXIT`
  trap the seam installs - export, push payload, verify read-back and rotate value all go
  through it. bash keeps one `EXIT` handler, so the seam captures whatever the caller had
  installed and runs it after its own temps are gone; what an entry script must never do is
  take that slot back after sourcing the seam, which would strand a file of secrets on the
  failure path.
- A write is verified by hashing the value read back before anything claims `ok:`.
- A key the vault does not carry is a warning, never a blanked line.
- **A vault value is never sourced in the shape the CLI wrote it.** Measured against
  `infisical/infisical:v0.167.10` with CLI v0.45.8: `secrets export --format=dotenv` wraps
  each value in single quotes and leaves an embedded quote raw, so a secret carrying an
  apostrophe closes its quote early and the rest of the line is shell - sourcing it either
  aborts or runs the tail as a command. `--format=dotenv-export` uses the same writer and
  fails the same way. The boot body therefore takes every value apart and re-emits it under
  quoting that has no escape hatch, which is what makes `~/.bashrc`'s `set -a; . agent.env`
  safe to keep. Anything else that reads that file inherits the guarantee; nothing should
  feed the CLI's own dotenv output to a shell.

There is no reason to open `.env` by hand while this subsystem is adopted, and no command
here prints a credential. If you are cat-ing the env file to debug a sync, you are reading
the wrong file: `status` and `check` answer the same question.

## What is deliberately not here

- **No dynamic secrets, no cross-project sharing.** Both are paid features of Infisical
  and neither is used: no `LICENSE_KEY` is read, generated, or referenced. The model is
  static shared secrets exported as dotenv.
- **No vault dependency in the deploy path.** Compose reads `.env`, and the one call the
  runners make before it is best-effort: warn, continue, bring the stack up on the values the
  file already held. The follow-up that would change that is a compose-secrets rewrite of every
  service block, and it would make every bring-up wait on a server nothing here waits on today.
- **No multi-line value reaches a workspace.** The boot fetch publishes single-line values only
  and drops the rest with one note; see
  [The workspace boot fetch](#the-workspace-boot-fetch).
- **No scrape, no alert.** The three containers are log-only, like `ollama`, `kasm` and
  the rest. `bazelisk run //scripts:observability-check` does not walk them; their state
  is `dev-stack -- status` and their logs are in Loki under their `container=` tag.
- **No second inventory.** Twelve keys, one file. A key added to compose without joining
  `infisical/managed-secrets.txt` stays outside the vault silently, which is why `check`
  asserts the count rather than trusting the file.

Related: [observability.md](../observability.md) (the `GRAFANA_ADMIN_PASSWORD` login and
the log stream these containers ship), [public-access.md](../public-access.md) (the
`infisical-*` public name), [troubleshooting.md](../troubleshooting.md).
