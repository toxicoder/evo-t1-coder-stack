---
name: evo-stack-ops
description: Pull, status, restart, and logs for the evo-t1-coder-stack via Bazel or docker compose.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [evo-t1, stack, docker, bazel]
---

# evo-stack-ops

Use when the operator asks to pull the stack repo, bring the stack up or down,
restart a service, or read logs.

## Order of operations

1. `cd "${STACK_HOST_PATH:-/opt/stack}" && git status` — never pull over
   uncommitted work; report what is dirty instead.
2. `git pull` (feature branches off `main`; `main` is the trunk).
3. Then act on the stack. Propose the plan, say what goes down, wait for the yes.

## Preferred: Bazel targets (stack host)

```sh
bazelisk run //scripts:prod-stack -- status
bazelisk run //scripts:prod-stack -- up
bazelisk run //scripts:prod-stack -- down
bazelisk run //scripts:prod-stack -- logs --tail 200 coder
bazelisk run //scripts:dev-stack  -- status        # the evo-t1-dev sandbox
```

`prod-stack` addresses compose project `evo-t1-prod` (stable, default ports);
`dev-stack` addresses `evo-t1-dev`. Both take `-p/--project-name`,
`-f/--file`, `-e/--env-file`.

## Fallback: compose directly

The official image has no bazelisk. Same project, same file, same `.env` beside
that file:

```sh
ROOT="${STACK_HOST_PATH:-/opt/stack}"
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" ps
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" up -d
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" restart litellm
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" logs --tail 100 coder
```

Services: `coder`, `db`, `litellm`, `ollama`, `searxng`, `kasm`, `homepage`,
`homepage-proxy`, `router`, `hermes`, `hermes-init`.

The stack's own health, from the host: `bazelisk run //scripts:hermes-shell -- check`
reports this container's state, its seed, and the model lane.

## Related skills

`host-linux-ops` for the right Linux command and what each flag means,
`host-diagnostics` when something is broken and nobody knows why, and
`deploy-from-github` when the request is about a third-party repository — that
one belongs in `${STACK_DEPLOY_PATH:-/opt/stack-deploy}` and never in this checkout.

## Do not

- Do not run `storage-clean`, `pull-models`, or any `reset` unless the operator
  named that command. `reset` destroys volumes.
- Do not edit bind-mounted payloads (`litellm/config.yaml`, `searxng/settings.yml`,
  `homepage/**`, `proxy/*.conf`) in the running container — edit the checkout and
  recreate the service.
- Do not print `.env` values. Restarting `litellm` re-reads them; that is usually
  the fix without opening the file.
