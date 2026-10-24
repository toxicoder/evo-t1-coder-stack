---
name: coder-workspace
description: Inspect, restart, and prepare Coder workspaces on the evo-t1 stack; check their GitHub auth.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [evo-t1, coder, workspace, github-auth]
---

# coder-workspace

Use when the operator asks about Coder workspaces: what is running, restart one,
or whether its GitHub auth works.

## Reach Coder

Compose DNS inside the network: `http://coder:3000` (plain listener). TLS is the
host's `:3001`, fronted by `router` — from this container use `:3000`.

The Docker socket is mounted here, so `docker` talks to the **host** daemon:

```sh
docker ps --format '{{.Names}}\t{{.Status}}'          # stack + coder-<owner>-<ws>
docker restart coder-<owner>-<ws>
docker logs --tail 100 coder-<owner>-<ws>
```

A workspace container is `coder-<owner>-<ws>`; the `dind` sidecar inside it is not
a workspace and should be skipped when enumerating.

## Preflight from the mounted checkout

Run these from a host context (they address the stack host, not a workspace):

```sh
bazelisk run //scripts:new-workspace -- --dry-run <git-url>   # plan only, creates nothing
bazelisk run //scripts:github-auth -- check                   # every workspace container
bazelisk run //scripts:github-auth -- check <repo-url>        # one repo, one container
```

`github-auth check` prints one line per credential slot and marks a slot
`shadowed` when the `GH_TOKEN`/`GITHUB_TOKEN` pair outranks it.

## Do not

- Do not mint, paste, or recommend a PAT. GitHub auth is Coder External Auth only
  (id `github`, or `CODER_EXTERNAL_AUTH_0_ID` in `coder.env`).
- Do not create workspaces by hand. Creation happens in the Coder UI (Templates →
  `workspace` or `devcontainer`). This skill inspects and restarts; it never
  bypasses Coder's provisioning.
- Do not exec into a workspace to fix its config — the seed lives in this repo;
  re-materialize it with `bazelisk run //scripts:update-configs -- workspace`.
