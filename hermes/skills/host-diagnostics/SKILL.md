---
name: host-diagnostics
description: Triage what is broken on this host - slow box, full disk, thermal throttle, failing service, docker daemon, DNS or TLS, model lane down - with read-only playbooks in order.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [linux, triage, diagnostics, docker, systemd, observability]
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
one, so `bazelisk run //scripts:spark-verify` tells you whether the heat source
is even local.

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

**Model lane down.** `bazelisk run //scripts:prod-stack -- status`, then the
LiteLLM health endpoint on the host (`:4000/health/liveliness`), then
`bazelisk run //scripts:spark-verify` for the Spark fleet. If every Spark is
dark, the `agent` alias falls back inside LiteLLM to a model that cannot emit
tool calls - say that out loud and offer `chat`, do not let a session quietly
lose its tools.

**Search returns nothing.** `bazelisk run //scripts:search-check` (it probes per
engine and distinguishes "engine refused" from "json format disabled" from
"network dead").

**A workspace misbehaves.** `bazelisk run //scripts:github-auth -- check` for the
credential chain, `docker logs --tail 100 coder-<owner>-<ws>` for the agent
tunnel, and remember the `dind` sidecar inside it is not a workspace.

## Do not

- Do not restart, prune, recreate, or `reset` as a way of "seeing if that fixes
  it". Name the cause first, then the one command.
- Do not delete anything under `/var/lib/docker/volumes`, the Postgres data
  directory, or the model weights to free space. Stop and say what is big.
- Do not raise a limit (`ulimit`, `sysctl`, swap, rpm/tpm) to outrun a symptom you
  have not identified. LiteLLM owns routing; nothing in this stack gets a cap.
- Do not run every probe at once. Print the one you ran and what it said, then
  decide. The operator is reading your transcript, not your command history.
