---
name: deploy-from-github
description: Take a GitHub repository to running on this host - read it first, pin a ref, isolate it, preflight ports and disk, deploy, health-check, and keep a rollback.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [github, deploy, docker, compose, release, rollback]
---

# deploy-from-github

Use when the operator names a repository and wants it running: "deploy
<org>/<repo>", "get this dashboard up", "run this project so the team can see
it". Also use it before saying yes to a README's quickstart - those assume a
laptop, not a box that serves other people's workspaces.

If what the operator wants is a *development* environment for the repository,
that is a Coder workspace, not a host deployment: `bazelisk run
//scripts:new-workspace -- --dry-run <git-url>` plans one, and `bazelisk run
//scripts:github-auth -- check` proves a workspace's credential chain. Deploy
here is for something that should keep running and serve a port.

## 1. Read before you run

Clone into the deploy workspace, never into the stack checkout:

```sh
ROOT="${STACK_DEPLOY_PATH:-/opt/stack-deploy}/<project>"
git clone --depth 1 --branch <tag-or-branch> <git-url> "$ROOT"
git -C "$ROOT" rev-parse HEAD        # record this: it is your rollback point
```

A public repository needs no credential. Never paste a token, never put one in
argv, and never mint a PAT - GitHub auth in this stack is Coder External Auth
only, and a private repository is a workspace job.

Then read, and say what you found: `README*`, `docker-compose*.yml`, any
`Dockerfile`, the manifest for the runtime (`package.json`, `pyproject.toml`,
`go.mod`, `Cargo.toml`), `.env.example`, `LICENSE`, and the open issues tagged
"install". Four questions get answered before anything starts:

- What does it need to run (runtime version, database, GPU, Redis, object store)?
- What does it want to bind (ports, volumes, host paths, `network_mode: host`,
  `privileged: true`, `--cap-add`)?
- Does it want to write to the host, and where?
- What is the licence, and is the README's "quickstart" a curl-to-shell pipe?

Anything that asks for `privileged: true`, a docker socket mount, `--net=host`, or
a host path outside the deploy directory is a finding to raise with the operator,
not a detail to satisfy.

## 2. Preflight, out loud

```sh
df -h /var/lib/docker && free -h            # room for the image and the runtime
ss -ltnp                                    # every port this box already answers on
docker network ls                            # the compose networks in play
```

Name the port you intend to use and confirm it is free - on this box the usual
collision is the dev sandbox (`evo-t1-dev`) holding a shifted copy of a stable
port. Say what the image pull costs, because a 6 GB image on a busy box is a
decision, not a step. Confirm the ref you pinned is the ref you meant
(`git -C "$ROOT" describe --tags --always`).

## 3. Deploy isolated, never inline

Give the project its own compose project and its own directory:

```sh
cd "$ROOT"
docker compose -p <project> config          # parse and interpolate before anything starts
docker compose -p <project> up -d
docker compose -p <project> ps
```

Rules that keep this box recoverable:

- Never edit `docker-compose.yml` of evo-t1-coder-stack to add a service. This
  project is not part of the stack; a project the stack does not know about
  cannot break the stack's gate.
- Secrets come from the project's own `.env` beside its compose file. Generate
  strong values, name the keys in chat, and never print a value or echo one into
  a log.
- Bind mounts and named volumes: keep them under `$ROOT` unless the operator
  asked for a location. An absolute host path in a compose file resolves on the
  daemon, which is why the deploy directory is mounted at its own path.
- Persist with a restart policy (`restart: unless-stopped`), not with a systemd
  unit or a cron job you install on the host - those are host state the stack's
  gates cannot see, and they need their own approval.
- No rpm/tpm caps, no model-routing changes, no edits to another service's
  payload to make room.

## 4. Verify like an operator, not a believer

`up -d` exiting 0 proves nothing. Check the thing itself:

```sh
docker compose -p <project> ps                     # Up, and not Restarting
docker compose -p <project> logs --tail 100
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/<healthz>
docker inspect -f '{{.State.Health.Status}}' <container>   # when it defines a healthcheck
```

Then the two paths a real user takes: the LAN URL (`http://<STACK_LAN_HOST>:<port>`)
and, if the operator asked for a public name, that name - which this stack only
ever composes from its naming parts, so say what belongs in
`STACK_PUBLIC_HOSTS` and let `bootstrap` write the conf. Never hand-edit
`proxy/router.conf`; it is a render.

Report what you measured: status, the health code, the log line that says it is
listening, and the URL.

## 5. Leave the keys labelled

Write down, in the project directory or the hand-off message: the pinned tag and
commit, the compose project name, the port, where its `.env` lives and which keys
it holds (names only), how to see logs, and the rollback:

```sh
docker compose -p <project> logs --tail 200         # first place to look
git -C "$ROOT" checkout <previous-tag> && docker compose -p <project> up -d --build
docker compose -p <project> down                    # stops it; keeps its volumes
docker compose -p <project> down --volumes          # destroys them: only on request
```

Update by tag, not by `latest`. `git -C "$ROOT" fetch --tags`, check out the new
tag, `up -d --build`, verify with the same two commands as step 4, and keep the
previous tag one checkout away.

## Do not

- Do not run `curl … | sh` or `bash <(curl …)` unseen. Download it, read it,
  quote the parts that touch the system, then run the file you read.
- Do not run an installer, migration, or test suite that writes outside the
  deploy directory, and do not point a project at the stack's Postgres or its
  model weights to "save a container".
- Do not disable TLS, drop `--read-only`/`user:` from a compose file, or turn off
  an approval mode to make a deployment go through.
- Do not reuse a stack port, a stack volume name, or a stack compose project name
  for a third-party project.
- Do not call it deployed without the health check and the log line. An image
  that is present is not a service that is answering.
