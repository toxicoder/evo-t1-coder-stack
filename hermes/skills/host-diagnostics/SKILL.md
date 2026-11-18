---
name: host-diagnostics
description: Triage what is broken on this host - slow box, full disk, thermal throttle, failing service, docker daemon, DNS or TLS, model lane down - with read-only playbooks in order, and what the host exporters and the Spark boxes answer.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [linux, triage, diagnostics, docker, systemd, observability, metrics, spark]
---

# host-diagnostics

Use when something is wrong and nobody has said why: the box is slow, a service is
restart-looping, a public name 502s, a model call hangs, a workspace will not
start. Work the symptom, not the guess.

## The order that saves time

1. **When did it start.** `uptime`, then `journalctl --since '1 hour ago' -p
   warning..alert --no-pager | tail -50`. A change that lines up with the onset is
   usually the cause.
2. **Is it resource starvation.** `free -h`, `df -h`, `vmstat 1 5`,
   `ps -eo pid,user,etime,pcpu,pmem,comm --sort=-pmem | head -15`. Three of these
   answer most "the box is slow" tickets.
3. **Is it one service or the whole box.** `bazelisk run //scripts:prod-stack --
   status` (or `docker compose -p evo-t1-prod -f "$STACK_HOST_PATH/docker-compose.yml"
   ps` here) - a single restarting container is an application problem; everything
   unhappy is a host problem.
4. **Then the matching playbook below**, read-only to the end, before any restart.
5. Fix, verify with the same command that found it, and say what changed.

A restart is a diagnosis-destroyer: it clears the evidence and, if the cause is a
config or a full disk, it comes back in ten minutes. Read first, restart once,
with a reason.

## Two doors, two toolchains

The official image ships git, curl, rg, vmstat, df, du and the Docker CLI. It has
no bazelisk, and no `jq`, `sqlite3`, `sensors`, `iotop`, `sar`, `mpstat`, `iostat`
or `ollama` either. So a line below that starts with `bazelisk run //scripts:...`
or names one of those tools is the **operator's host command**: run
`command -v <tool>` before you rely on anything, and when it is missing, print the
line and hand it over instead of inventing an output. The same question from inside
this container goes through compose against the same project and file:

```sh
ROOT="${STACK_HOST_PATH:-/opt/stack}"
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" ps
docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml" logs --tail 200 litellm
docker stats --no-stream            # per-container CPU and memory, no host tools
```

`//scripts:hermes-shell -- check` is the host-side readiness report for this very
container, so it is a hand-over too.

## Playbooks

**Slow / unresponsive.** `vmstat 1 5` first: high `wa` is I/O, high `si` is
network, sustained `r` above the core count is CPU. Then `iotop -oPa` or
`sar -d 1 5`, then the process list sorted by the resource you just found. OOM
check: `dmesg -T | grep -i -E 'oom|killed process'` - an OOM-killed model server
restarts "silently" and looks like a slow box.

**Hot / throttling (this is an 8-core mini PC in a closed shelf).**
`sensors` or `cat /sys/class/thermal/thermal_zone*/temp`, then
`grep . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`. Sustained 95+ C
means airflow, not software: check the vents and the shelf, then reduce what is
running here. The iGPU model lane (`ollama` on the Arc) is the heat this chassis
has to carry; a loaded Spark box is a different machine and does not warm this
one, so `bazelisk run //scripts:spark-verify` (the operator's host command) tells
you whether the heat source is even local. From here, `docker compose -p
evo-t1-prod -f "$ROOT/docker-compose.yml" ps` and `docker stats --no-stream` name
what on this box is busy.

**Disk full.** `df -h` and `df -i` (inode exhaustion looks identical). Then walk
it: `du -xh -d1 / | sort -h | tail -15` and repeat on the fat branch. The usual
four on this box, in order: `/var/lib/docker` (images and volumes - check
`docker system df -v`), the Ollama model directory (do not delete weights
without naming which model), the Coder Postgres data directory (never delete),
and logs (`journalctl --disk-usage`, then `vacuum` - never `rm` the journal
files).

**Container restart loop.** `docker logs --tail 200 <name>`, then
`docker inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.Error}}'
<name>`, then the compose env it started with (`docker inspect -f '{{range
.Config.Env}}{{println .}}{{end}}' <name>`, checked for empty interpolations
rather than printed). An exit 0 loop is a command that thinks it is done; a
non-zero loop with no log lines is usually a bind source that does not exist on
the host.

**Docker daemon itself.** `systemctl status docker`, `journalctl -u docker
--since '-30 min'`, `docker info | head -30`. If the CLI here cannot reach it,
that is a finding to report, not a reason to restart the daemon under a running
stack.

**Public name 502 or wrong page.** The chain is Cloudflare → Traefik → `router`
on `:8080` → the service. Ask each hop in turn: does the Host header route
(`docker exec`-free check: read `proxy/router.gen.conf` / `proxy/router.conf` for
that `server_name`), is the upstream name resolvable on the compose network, is
the upstream answering (`curl -fsS http://<service>:<port>/`)? A WebSocket page
that dies on close code 4403 is Hermes' Host/Origin guard, not a network fault.

**Model lane down.** `docker compose -p evo-t1-prod -f "$ROOT/docker-compose.yml"
ps` here, then the LiteLLM health endpoint
(`curl -fsS http://litellm:4000/health/liveliness` - the compose name, from this
container), then `bazelisk run //scripts:spark-verify` on the host for the Spark
fleet. If every Spark is
dark, the `agent` alias falls back inside LiteLLM to a model that cannot emit
tool calls - say that out loud and offer `chat`, do not let a session quietly
lose its tools.

**Search returns nothing.** First ask the instance yourself:
`curl -s -H 'Accept: application/json' "$SEARXNG_URL/search?q=<terms>&format=json"`.
`SEARXNG_URL` is what registers the `web_search` provider, so an empty one is the
first finding, and a body carrying `unresponsive_engines` is the instance naming
the engines it gave up on. Then `bazelisk run //scripts:search-check` on the host
(it probes per
engine and distinguishes "engine refused" from "json format disabled" from
"network dead", and prints each parked engine with the reason its backend gave).
A 200 that carries no results while the service is up is normally the engines
being bot-walled, not a broken deployment: check what the probe names as parked
before touching the container, and remember a park expires on its own after
`search.suspended_times`. An agent that pinned one engine in its call can get
zero rows from a lane that answers twenty unpinned - that is an agent-usage
fault, not a host fault.

**A workspace misbehaves.** `bazelisk run //scripts:github-auth -- check` for the
credential chain (host command: it enumerates the labeled workspace containers
through the daemon), `docker logs --tail 100 coder-<owner>-<ws>` for the agent
tunnel, and remember the `dind` sidecar inside it is not a workspace.

## The host and Spark metrics surface

The `observability` profile carries four exporters, all compose services in
`evo-t1-prod`, all published on the host's loopback only - so each is the operator's
host command, never a `host.docker.internal` dial from here. Ask
`bazelisk run //scripts:prod-stack -- status` for the live mapping, not the dotenv file.

| service | published under | ask it |
|---|---|---|
| `node_exporter` | `OBS_NODE_EXPORTER_PORT` (9101) | `/metrics` - host cpu, memory, disk, network |
| `cadvisor` | `OBS_CADVISOR_PORT` (9290) | `/metrics` per container, `/healthz` |
| `blackbox_exporter` | `OBS_BLACKBOX_PORT` (9115) | `/metrics`, `/probe?target=<url>&module=<name>` |
| `alertmanager` | `OBS_ALERTMANAGER_PORT` (9093) | `/-/healthy`, `/api/v2/status` |

Dead exporter and empty query need different fixes. Connection refused (curl exit 7)
means nothing is bound - and with all four behind `profiles: ["observability"]` the
usual cause is a stack that never enabled the profile, not a crashed container. HTTP
200 with no matching line means the exporter is healthy and the name or collector is
wrong (`node_processes_*` needs `--collector.processes`). A 404 is the wrong path:
`/metrics` is the only endpoint all four answer, and blackbox's `/probe` needs both
`target` and `module`.

**Which of the four is the bottleneck.** The PSI counters answer it in one read and
carry no labels at all, so a selector with `operation=` or `pressure=` matches
nothing: `node_pressure_cpu_waiting_seconds_total`,
`node_memory_waiting_seconds_total`, `node_io_waiting_seconds_total` are the cpu,
memory and disk queues. Above a 5-minute rate near 0.10, tasks waited that share of
the wall clock and the largest is the bottleneck. Cross-check it:
`node_memory_MemAvailable_bytes` against total, `node_cpu_seconds_total{mode="iowait"}`
for disk arriving as CPU, and `node_network_receive_bytes_total` with
`device!~"lo|veth.*|br.*|docker.*|virbr.*"` for the wire - there is no PSI series for
network, so that one is `si` and retransmits. Memory and IO both hot means memory is
the cause and IO the symptom.

**The Spark boxes.** All host commands; this image has no bazelisk.

```sh
bazelisk run //scripts:spark-monitor                 # plan only, and the default
bazelisk run //scripts:spark-monitor -- --status     # per-box probe table
bazelisk run //scripts:spark-monitor -- --targets    # the sparks.json it expects
bazelisk run //scripts:spark-monitor -- --restart    # restart both exporters
bazelisk run //scripts:spark-monitor -- --apply      # the only flag that changes a box
```

Plan is the default (`--dry-run` says it out loud), so "how is the fleet doing" is a
`--status` question. `--box <n>` narrows to one box; `--json` prints one object and
this image has no `jq`; a box with nothing installed is a `warning:` line, not a
failure.

**GPU series, when you are reading a Spark.** The prefix is `DCGM_FI_*`, never
`dcgm_*`: utilisation `DCGM_FI_DEV_GPU_UTIL`, copy engine `DCGM_FI_DEV_MEM_COPY_UTIL`,
framebuffer fill `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE`, temperature
`DCGM_FI_DEV_GPU_TEMP` / `DCGM_FI_DEV_MEMORY_TEMP`, power `DCGM_FI_DEV_POWER_USAGE`,
ECC and row remap `DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS` /
`DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS` / `DCGM_FI_DEV_ROW_REMAP_FAILURE`. The
profiling family (`DCGM_FI_PROF_*`) needs the exporter container to carry
`--cap-add SYS_ADMIN`: a box without it returns **no** `DCGM_FI_PROF_*` rows at all,
so an empty result is a privilege gap - say "that exporter is not running with what
it needs", never "the GPU is idle", and `--status` prints `dcgm_counter_count` and
`gpu_count` to tell them apart. The same privilege honesty applies to the host:
`cadvisor` only means anything because it runs `privileged: true` with `pid: host`,
and `node_exporter` needs `pid: host` to see the host's processes at all.

## Do not

- Do not restart, prune, recreate, or `reset` as a way of "seeing if that fixes
  it". Name the cause first, then the one command.
- Do not delete anything under `/var/lib/docker/volumes`, the Postgres data
  directory, or the model weights to free space. Stop and say what is big.
- Do not raise a limit (`ulimit`, `sysctl`, swap, rpm/tpm) to outrun a symptom you
  have not identified. LiteLLM owns routing; nothing in this stack gets a cap.
- Do not run every probe at once. Print the one you ran and what it said, then
  decide. The operator is reading your transcript, not your command history.
- Do not answer a question about the Spark fleet with
  `bazelisk run //scripts:spark-monitor -- --apply`. It installs and starts
  containers, it is the only flag that does, and `--status` answers the question
  without changing anything.
- Do not put a Spark hostname in a log, a file, or your reply. The boxes come from
  `SPARK1_HOST` / `SPARK2_HOST` / `SPARK3_HOST`, `--targets` prints them into a
  generated gitignored file, and the count is the part anyone needs.
