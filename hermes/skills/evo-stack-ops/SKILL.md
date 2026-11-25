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

### The bazelisk commands

```sh
bazelisk run //scripts:prod-stack -- status
bazelisk run //scripts:prod-stack -- up
bazelisk run //scripts:prod-stack -- down
bazelisk run //scripts:prod-stack -- logs --tail 200 coder
bazelisk run //scripts:dev-stack  -- status        # the evo-t1-dev sandbox
```

### Which project each CLI drives

`prod-stack` addresses compose project `evo-t1-prod` (stable, default ports);
`dev-stack` addresses `evo-t1-dev`.

Both take `-p/--project-name`, `-f/--file`, `-e/--env-file`.

## Fallback: compose directly

### The docker compose commands

The official image has no bazelisk. Same project, same file, same `.env` beside
that file:

```sh
ROOT="${STACK_HOST_PATH:-/opt/stack}"
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" ps
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" up -d
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" restart litellm
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" logs --tail 100 coder
```

### Service names

Services:

- `coder`, `db`, `litellm`, `ollama`, `searxng`, `kasm`, `homepage`, `homepage-proxy`,
  `router`, `hermes`, `hermes-init`
- `prometheus`, `mimir`, `loki`, `tempo`, `grafana`, `alloy`
- `node_exporter` (host CPU, memory, disk and process metrics)
- `cadvisor` (per-container CPU, memory and the process table; the one privileged
  container in this stack)
- `blackbox_exporter` (outbound HTTP prober, called by Prometheus on the compose
  network)
- `alertmanager` (deduplication, grouping and silencing of the alerts the rule files
  define)
- `host-gpu-sampler` (writes the Arc's four `evo_t1_host_gpu_*` gauges into the
  node_exporter textfile drop directory the host GPU card reads; a sampler, so nothing
  publishes a port on it and nothing scrapes it, and its healthcheck goes unhealthy when
  the drop stops advancing rather than when the container stops, because the sampling
  loop never exits; the busy gauge carries a source label, freq_ratio from the clock over
  the card's ceiling rather than measured utilisation, unless the operator granted the
  host the intel_gpu_top read through perf_event_open, which flips it to intel_gpu_top -
  the card says which one you are looking at, and docs/dashboard.md carries the recipe)
- `infisical`, `infisical-db`, `infisical-redis`

`node_exporter`, `cadvisor`, `blackbox_exporter`, `alertmanager` and `host-gpu-sampler`
sit behind the observability compose profile and publish on the host's loopback only or
on no port at all, so reaching them is a host-shell act, not a workspace one.

### The Spark boxes

The Sparks run their own node_exporter on 9100 and DCGM exporter on 9400, and
`bazelisk run //scripts:spark-monitor -- --apply` is the only thing that installs
them.

Same CLI:

- no flag or `--dry-run` plans only
- `--status` prints the per-box probe table
- `--targets` the sparks.json it expects
- `--restart` restarts both containers
- `--box <n>` narrows it to one box

Detail in docs/spark-monitoring.md; the metrics themselves are `host-diagnostics`.

### The stack's own health

The stack's own health, from the host: `bazelisk run //scripts:hermes-shell -- check`
reports this container's state, its seed, and the model lane.

## Related skills

- `host-linux-ops` for the right Linux command and what each flag means
- `host-diagnostics` when something is broken and nobody knows why
- `web-research` when the answer is off this box
- `deploy-from-github` when the request is about a third-party repository — that one
  belongs in `${STACK_DEPLOY_PATH:-/opt/stack-deploy}` and never in this checkout

## Do not

- Do not run `storage-clean`, `pull-models`, or any `reset` unless the operator
  named that command. `reset` destroys volumes.
- Do not edit bind-mounted payloads (`litellm/config.yaml`, `searxng/settings.yml`,
  `homepage/**`, `proxy/*.conf`) in the running container — edit the checkout and
  recreate the service.
- Do not print `.env` values. Restarting `litellm` re-reads them; that is usually
  the fix without opening the file.
