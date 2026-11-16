---
title: Secrets with Infisical
description: "The opt-in secrets vault: the twelve managed keys, the operator CLI verbs and their exit codes, the adoption sequence, what happens when the vault is unreachable, and how a rotated credential reaches its service."
tags: [secrets, infisical, operate, credentials]
---

# Secrets with Infisical

**What's on this page**

- What the integration is, and the one property it deliberately does not change
- The flag that decides whether the bundle exists, and the second gate on the workspace side
- The three `secrets`-profile containers, and the CLI verb that reads the flag
- The adoption sequence, one command per step, with the container each step touches
- The twelve managed keys, who consumes each one, and what breaks when it is wrong
- What a vault outage does and does not do to `up`, to `pull`, and to a workspace boot
- The `CODER_PG_PASSWORD` rotation path and the one volume-init trap under it

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
always has. The vault is an editor for `.env`, not a dependency of the project.

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
It decides only whether a workspace's boot fetch tries to pull the managed keys into the
workspace environment before the rest of its startup. It is off by default so a workspace
never waits on the vault, and it does nothing while `INFISICAL_ENABLED` is off.

Both gates reach the templates through `bazelisk run //scripts:push-template`: the CLI forwards
`--var infisical_enabled=true` and `--var infisical_pull_on_start=true` only for a truthy value in
`.env`, so the shipped state pushes neither word and each template's own `default = false` stands.

When both are on, the fetch is a `coder_script` (`"infisical_secrets"`, `run_on_start`, 120s
timeout) that logs in as the machine identity, exports the project's dotenv, and publishes it to
`~/.infisical/agent.env` at mode 600 on the shared profile volume. Two things about that file are
deliberate. Keys beginning `INFISICAL_` are filtered out of it, so the vault's own address and
Universal Auth pair never get republished as workspace environment. And `~/.bashrc` sources it
under `set -a` - the reader is what makes the fetch worth doing, since a login shell is what every
terminal, tmux pane and command in the workspace inherits from. `docs/coder-templates.md` carries
the template side of that: the eight `infisical_*` variables, why the credential pair rides the
agent environment rather than the rendered script body, and the order the boot body runs in.

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
  stack that never adopted Infisical is a check nobody runs.
- **1** - a real failure. The CLI errored, a read-back hash disagreed, a `rotate` target
  is not a managed key.
- **2** - usage error, always raised before any work starts.
- **5** - refused, because `INFISICAL_ENABLED` is off or a prerequisite is empty. Printed
  as a `note:` that names the key to set.

There is deliberately no `--json` mode: a JSON answer about a credential is an answer that
leaks it in a different font.

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

    This writes only the binary. Nothing else changes, and no container is touched.

4.  Start the three services. `up` selects the profile now that the flag is on:

    ```sh
    bazelisk run //scripts:dev-stack -- up
    ```

    That creates `infisical`, `infisical-db` and `infisical-redis`. The vault answers on
    `http://127.0.0.1:8182` (`INFISICAL_PORT`) on the stack host, and on the published LAN
    face. Expect the two alpine containers to read `running` rather than `healthy`: neither
    declares a healthcheck, because the only consumer waits on `service_started`.

5.  Bootstrap the instance:

    ```sh
    bazelisk run //scripts:infisical -- bootstrap
    ```

    This creates the super admin, the organization and the machine identity **inside the
    `infisical` container**, and writes the returned identifiers into `.env`. It is
    idempotent in the safe direction: if `INFISICAL_PROJECT_ID` or
    `INFISICAL_MACHINE_IDENTITY_ID` is already set it prints a `note:` and refuses to run
    again. It needs `python3` on PATH to parse the response, and the CLI from step 3.

6.  Adopt what is already in `.env`:

    ```sh
    bazelisk run //scripts:infisical -- push
    ```

    This seeds the twelve managed keys into the vault, skipping any key the env file does
    not hold or holds empty - with a `warning:`, never an empty write. It then exports the
    project again and compares a hash per key, so a set the server accepted and dropped is
    reported as a failure rather than a clean seed.

7.  Prove the round trip:

    ```sh
    bazelisk run //scripts:infisical -- pull
    ```

    With the vault and `.env` agreeing this writes nothing new. It is the read path, so it
    is the one to run before you trust `push`.

8.  Recreate the consumers so they pick up what the vault holds:

    ```sh
    bazelisk run //scripts:dev-stack -- up
    ```

    Compose reads `.env` when it creates a container. Nothing is recreated until you ask
    for it, so `pull` alone changes no running service.

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

Four secret-shaped keys compose interpolates sit outside the inventory, and each one is
outside for a reason worth knowing before you add it:

- `INFISICAL_DB_PASSWORD`, `INFISICAL_ENCRYPTION_KEY`, `INFISICAL_AUTH_SECRET` - the
  vault's own bootstrap credentials. By definition they cannot come from the vault: it
  needs them to start. They live in `.env`, and you set them.
- `CODER_DEFAULT_TOKEN_LIFETIME` - a duration, not a secret.

Anything else that looks like a credential and is not on this page is either a bug in the
inventory or a bug in the compose file, and `check` is the command that catches the first.

## When Infisical is unreachable

The outage is bounded, because the integration has no read path inside the deploy path.

- **`up` cannot be stopped by it.** Compose never contacts Infisical. It interpolates
  `.env`, which is a file on disk. Whether the three containers are part of the project is
  a profile decision made from one key, not a network result.
- **`pull` leaves `.env` alone and says so.** A failed export is an `error:` line naming
  the file as untouched, and the verb exits 1. An export that comes back empty is a
  `warning:` and the same untouched file. A key the vault does not carry, or carries
  empty, is a `warning:` per key and the existing value in `.env` stays exactly as it was
  - a half-seeded project must not lock every service out of its own credential.
- **A workspace still starts.** The boot fetch is best-effort: with the flag off, with
  `INFISICAL_PULL_ON_START` off, or with the vault unreachable, it exits 0 and the
  workspace continues its startup. A vault outage has never once stopped a workspace.
- **`rotate` stops at the first half.** If the vault refuses the write, `.env` is left
  untouched and the verb exits 1 - the stack keeps running on the old value. The reverse
  case prints the recovery in the error line: if the vault took the new value and the env
  write failed, re-run `pull` to converge.

## Rotating CODER_PG_PASSWORD

```sh
bazelisk run //scripts:infisical -- rotate CODER_PG_PASSWORD
```

The verb mints a fresh value, writes the **vault first**, and only touches `.env` once the
vault accepted it - so there is no moment where `.env` holds a password the vault does not
know about. `rotate` names one managed key; naming anything outside the inventory is an
`error:` and exit 1.

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

- A value never travels in argv, so it cannot be read out of another user's `ps`. The CLI
  passes secrets only as file paths - `--file=<tmp600>` for a bulk set, `KEY=@<file>` for
  a single one. There is no stdin path upstream, so the `@path` form is the whole
  argv-safe channel.
- A value never appears in a log line, including a failure line. Every ok, warning and
  error names the **key**, never the value, and counts rather than listing.
- A file that holds one is mode 600 and is removed on the failure path too, by the `EXIT`
  trap - export, push payload, verify read-back and rotate value all go through it.
- A write is verified by hashing the value read back before anything claims `ok:`.
- A key the vault does not carry is a warning, never a blanked line.

There is no reason to open `.env` by hand while this subsystem is adopted, and no command
here prints a credential. If you are cat-ing the env file to debug a sync, you are reading
the wrong file: `status` and `check` answer the same question.

## What is deliberately not here

- **No dynamic secrets, no cross-project sharing.** Both are paid features of Infisical
  and neither is used: no `LICENSE_KEY` is read, generated, or referenced. The model is
  static shared secrets exported as dotenv.
- **No vault dependency in the deploy path.** Compose reads `.env`. The follow-up that
  would change that is a compose-secrets rewrite of every service block, and it would
  import the outage this page says cannot happen.
- **No scrape, no alert.** The three containers are log-only, like `ollama`, `kasm` and
  the rest. `bazelisk run //scripts:observability-check` does not walk them; their state
  is `dev-stack -- status` and their logs are in Loki under their `container=` tag.
- **No second inventory.** Twelve keys, one file. A key added to compose without joining
  `infisical/managed-secrets.txt` stays outside the vault silently, which is why `check`
  asserts the count rather than trusting the file.

Related: [observability.md](../observability.md) (the `GRAFANA_ADMIN_PASSWORD` login and
the log stream these containers ship), [public-access.md](../public-access.md) (the
`infisical-*` public name), [troubleshooting.md](troubleshooting.md).
