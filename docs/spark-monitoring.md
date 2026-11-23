---
title: Spark monitoring
description: "Enrolling the three DGX Sparks into the Prometheus stack: the two exporter containers a box needs, the one opt-in key, the plan/prove/install commands, how the boxes reach Prometheus through file_sd, and what this change leaves unproven."
tags: [observability, prometheus, spark, dcgm, operate]
---

# Spark monitoring

**What's on this page**

- The two containers that make a Spark a Prometheus target, and the fact that neither
  exists until you run `--apply`
- The one key that decides whether the fleet is monitored at all, and what reads it
- The three commands - plan, prove, install - plus one box, JSON, and the target document
- How the boxes get into Prometheus, and why an unenrolled fleet reads as zero Sparks
- What this change does not prove: the DCGM tag, the profiling counters, NVLink
- The three failures worth recognising from the CLI's own words

**What this enables**

- Reading GPU utilisation, temperature, power and framebuffer pressure per Spark in
  Grafana instead of ssh-ing into a box and running `nvidia-smi`
- Catching a box left on an old exporter tag before someone asks why its panels differ
  from its neighbours'
- Enrolling or un-enrolling the fleet with one key, without editing a compose file

Run every command here in a **shell on the stack host**.

The probe reaches each box over ssh, and a Coder workspace container is not a shell that
resolves the LAN names the `SPARKn_HOST` keys hold - the workspace-side run in the examples
below shows exactly what that costs.

The whole bundle this depends on sits behind the Compose profile
`profiles: ["observability"]`, and [observability.md](observability.md) is the page for
the six services that do the scraping.

## What lands on a Spark

Two containers per box, both created by this CLI and by nothing else:

| Container | Image | Port (.env key, default) | What it answers |
|---|---|---|---|
| `spark-node-exporter` | `quay.io/prometheus/node-exporter:v1.12.1` | `SPARK_NODE_EXPORTER_PORT` (9100) | CPU, memory, disk, filesystems, network, conntrack, file descriptors, `node_processes_*` |
| `spark-dcgm-exporter` | `nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04` | `SPARK_DCGM_EXPORTER_PORT` (9400) | The `DCGM_FI_*` GPU series - utilisation, memory copy, framebuffer used and free, temperatures, clocks, power, PCIe replays, remapped rows |

**Neither of them exists until you run `--apply`.** A box that has never been enrolled
runs no exporter, so Prometheus scrapes nothing and the Spark panels stay empty.

This change installs nothing on its own: no deploy, no `up`, no `refresh-configs` creates
a container on a Spark. `--apply` is the only flag that touches a box, and it says so in
its own header line before the first one (`scripts/spark-monitor.sh:327`).

Both containers are idempotent by name (`scripts/spark-monitor.sh:79-80`), so a second
`--apply` starts what is already there rather than creating a duplicate on a port the
first one holds.

The DCGM exporter is not run on the image's own field list:

- the CLI ferries `observability/dcgm/custom-counters.csv` to
  `/opt/evo-t1/dcgm/custom-counters.csv` on the box
- bind-mounts it read-only (`scripts/spark-monitor.sh:97-98`,
  `scripts/spark-monitor.sh:239`), so the `DCGM_FI_*` series Prometheus sees are the ones
  this repo reviews

Editing that CSV and re-running `--apply` reports `updated`, and the CLI then tells you to
`--restart` so the running exporter rereads it (`scripts/spark-monitor.sh:696-697`).

## The flag

```dotenv
SPARK_MONITOR_ENABLED=false
```

`.env.example:629`. It is read by **this CLI**, at `scripts/spark-monitor.sh:212` - not
by Compose. Nothing in `docker-compose.yml` consults it, because the exporters do not run
in the stack's project at all; they run on the boxes. With the key off:

- `--apply` skips every box instead of installing a container nothing scrapes
  (`scripts/spark-monitor.sh:541`)
- `--targets` prints the empty document `[]` (`scripts/spark-monitor.sh:302`)
- `--status` still probes, because knowing what a box runs never needs the flag.

The other keys, all in `.env.example`:

- `SPARK_NODE_EXPORTER_PORT` (line 607)
- `SPARK_DCGM_EXPORTER_PORT` (line 612)
- `SPARK_DCGM_EXPORTER_IMAGE` (line 621, the pin above, and the knob you correct if the
  registry refuses that tag)

The host-side exporters this bundle adds live beside them - `OBS_NODE_EXPORTER_PORT`
(583), `OBS_CADVISOR_PORT` (590), `OBS_BLACKBOX_PORT` (596), `OBS_ALERTMANAGER_PORT`
(601) - and `ALERTMANAGER_WEBHOOK_URL` (635) is empty by default; nothing requires it.

Those four host exporters publish on the **host's loopback only**, so a probe of them runs
in a host shell, the same as Prometheus' own UI on `PROMETHEUS_PORT`.

The fleet itself comes from `SPARK_HOSTS` or the `SPARKn_HOST` keys and is resolved by
`derive_spark_hosts` (`scripts/lib/spark.sh:67`); this CLI derives no hostname, and every
box line it prints names the host, because three Sparks of which one is quiet is otherwise
indistinguishable from three Sparks of which one is down.

## The commands

### Plan (the default, and the one that is safe anywhere)

```sh
bazelisk run //scripts:spark-monitor --
```

No flag, or `--dry-run`, is a plan: it opens no ssh session, starts no container, and
prints what is configured plus the exact `docker run` lines `--apply` would ferry.

This is the run to make before pointing Prometheus at three boxes you have not looked at.

Captured output, with the CLI's placeholder host names replaced by `<host>`:

```text
spark-monitor: plan for 3 box(es) -- read-only: this run opens no ssh session and starts no container
warning: no SPARK_HOSTS, no exported SPARKn_HOST and no SPARKn_HOST key in .env: checking the placeholder trio, whose names do not resolve -- export SPARK1_HOST (and 2, 3) or set them in .env
warning: SPARK_MONITOR_ENABLED is 'false': --apply starts nothing and --targets prints an empty set, so no Spark is a scrape target. Set it to true in .env when the boxes should be scraped. --status still probes.

== box <host> ==
ok: <host>: scrape pair is <host>:9100 (node_exporter quay.io/prometheus/node-exporter:v1.12.1) and <host>:9400 (DCGM nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04)
note: <host>: SPARK_MONITOR_ENABLED is 'false', so --apply would start nothing on this box and --targets would publish no group for it
warning: <host>: nothing has been measured -- a plan run opens no ssh session, so whether either exporter runs here is unknown until --status
summary: 3 ok, 5 warnings, 0 failed
next: bazelisk run //scripts:spark-monitor -- --status to see what each box runs, or --apply to create both exporters
```

That run was made from a Coder workspace, which is why the fleet fell back to the
placeholder trio.

From the host shell, with the `SPARKn_HOST` keys in the checkout's `.env`, the same
command prints three real boxes and no host warning, and adds the `docker run` lines the
plan promises (`scripts/spark-monitor.sh:412-425`).

### Prove (`--status`)

```sh
bazelisk run //scripts:spark-monitor -- --status
```

This is the only mode that looks at a box. It ferries one read-only probe
(`scripts/lib/probes/spark-monitor.sh`) base64-encoded through `probe_transport`
(`scripts/lib/spark.sh:173`), which prints twelve `KEY=value` lines per box:

- docker availability
- both exporters' state, port and image
- the DCGM counter count
- the GPU count and models

The probe never pulls, never writes, never installs, and exits 0 even when the box has
nothing on it - the CLI decides what is a warning.

Captured output from this workspace, host names elided:

```text
spark-monitor: status for 3 box(es) -- read-only: the probe runs on each box over ssh and changes nothing
== box <host> ==
-> probing <user>@<host> over ssh
warning: <host>: no probe report (ssh: Could not resolve hostname <host>: Name or service not known) -- a box that is switched off or has no ssh credentials is a not-yet state, not a failure
summary: 0 ok, 5 warnings, 0 failed
```

A box that answers prints `ok:` lines instead of that warning - docker available with
the probe version, `node_exporter is running on :<port> (<image>)`, `DCGM exporter is
running on :<port>, tag <image>`, and a `note:` with the counter count, the GPU count and
the models (`scripts/spark-monitor.sh:612-644`).

**Not verified from a live box**: no Spark was reachable from where these commands ran, so
the answering-`box` table above is quoted from those source lines, not from an observed
run. The unreachable form is what was actually measured.

### Install (`--apply`)

```sh
bazelisk run //scripts:spark-monitor -- --apply
```

The only mutator. Set `SPARK_MONITOR_ENABLED=true` first or every box is skipped.

Per box it reports each container as `created`, `started` (an existing one), or
`already running`, and the counter list as `same`, `updated` or `absent`
(`scripts/spark-monitor.sh:662-700`).

Exit status is 0 when every box answered or is simply not set up yet, and non-zero only
when a mutator ran and a box failed - a Spark with nothing installed is a `warning:`, not
a failure, because that is the state a freshly imaged box is in.

`--apply` was **not run for this page**: it creates containers on real hardware, and no
Spark answered ssh from where the other commands ran. Read the plan output above as the
contract for what it does.

The `--` separator is not decoration. Measured:

```sh
bazelisk run //scripts:spark-monitor --apply
```

```text
ERROR: --apply :: Unrecognized option: --apply
```

with exit 2 - Bazel claims the flag as its own build option and the script never starts.
Every flag this CLI takes goes after `--`.

### The rest

#### `--restart`

```sh
bazelisk run //scripts:spark-monitor -- --restart
```

`docker restart` on both containers per box (`scripts/spark-monitor.sh:332`). This is what
you run after editing `observability/dcgm/custom-counters.csv`, since a running exporter
keeps the field list it started with.

A box with no such container is a `warning:` naming `--apply`
(`scripts/spark-monitor.sh:725`).

#### `--box` (one box number)

```sh
bazelisk run //scripts:spark-monitor -- --box 1
```

Restricts any mode to one box number (`1`, `2`, `3`). A number outside the resolved fleet
is refused with the fleet size and the resolved list.

Measured, plan mode with `--box 1`:

```text
spark-monitor: plan for 1 box(es) -- read-only: this run opens no ssh session and starts no container
summary: 1 ok, 3 warnings, 0 failed
```

#### `--json`

```sh
bazelisk run //scripts:spark-monitor -- --json
```

One JSON object on **stdout** and nothing else; every `ok:` / `warning:` / `summary:` line
routes to stderr while `--json` is set, so `| jq` sees a document.

Verified: stdout was one line, 1397 bytes, parseable, carrying:

- `mode`, `host_source`, `monitor_enabled`, both images, both ports, `ssh_port`
- a `boxes` array with one object per box (`probed`, `docker`, `node_exporter`, `dcgm`,
  `dcgm_counter_count`, `gpu_count`, `gpu_names`, `probe_version`, `verdict`, `detail`)
- a `summary` object

#### `--targets`

```sh
bazelisk run //scripts:spark-monitor -- --targets
```

The `file_sd` document, to stdout, writing nothing. With the flag off, verified output:

```text
[]
note: SPARK_MONITOR_ENABLED is 'false', so this is the empty target set: set it to true in .env (or the process environment) to emit the four groups per box
summary: 0 ok, 0 warnings, 0 failed
```

With it on, four groups per box:

- the node_exporter on `SPARK_NODE_EXPORTER_PORT`
- the DCGM exporter on `SPARK_DCGM_EXPORTER_PORT`
- the two blackbox probe URLs on `SPARK_HTTP_PORT` (`/health` and `/v1/models`)

Every group carries the three labels the rule files and the dashboards group by - `box`,
`exporter`, and `hostname` - so the GPU rows, the host rows and the probe rows of one box
all land on the same identity.

`--help` prints the usage block from the script's own header. The modes are mutually
exclusive: `--status cannot be combined with --apply; pick one mode`.

## How the boxes get into Prometheus

`--targets` prints the document; it never writes it (`scripts/spark-monitor.sh:340`).

The file lives at `observability/spark-targets/sparks.json` on the **stack host**, and that
path is gitignored (`.gitignore:76`) precisely because it names your boxes - three
addresses are not something this repo commits.

`//scripts:spark-monitor` is what generates it on the host, from the three ports above.

Prometheus reads that one file with `file_sd_configs` at `refresh_interval: 60s` on all
three Spark jobs (`observability/prometheus/prometheus.yml:149`, `:171`, `:195`), so a
changed file is picked up within a minute without a restart.

Because four kinds of target share the file, each job keeps only its own with a relabel
`action: keep` on the `exporter` label - without those filters the two probe URLs would be
scraped as metric endpoints and every box would carry two permanently failing targets.

The two blackbox jobs take the address from the same file and pass it as `__param_target`,
so the target label carries the box rather than the prober.

The prober itself is scraped as a service of its own
(`observability/prometheus/prometheus.yml:219`), which is what makes
`up{job="blackbox"}` exist for `BlackboxProbeGap` to fire on.

Spark alerts stamp `tier=spark` and `spark=<hostname>`.

The consequence of the empty document above: **an unenrolled fleet reads as zero Sparks.**

No group in `sparks.json` means no target, which means no `up` series, which means an
empty panel rather than a red one - the symptom looks like "nothing is wrong" from
Grafana.

Check it with `--targets` before you blame the dashboard.

## What this change does not prove

Say these plainly, because each one costs someone an afternoon if they meet it
unexpected:

- **The DCGM tag has never been pulled.** `nvcr.io` answers 404 to an anonymous token, so
  the pin `nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04` was not verifiable
  upstream the way the other three were. The first `--apply` against a box is what proves
  it, and a wrong tag surfaces there as the registry's own error: `--apply` prints
  docker's reason rather than swallowing it (`scripts/spark-monitor.sh:675`,
  `scripts/spark-monitor.sh:685`), so you read what the registry said. Correct the tag in
  `SPARK_DCGM_EXPORTER_IMAGE` and re-run - it is a key, not a code change.
- **`--status` prints the tag a box is really running**, taken from the container
  (`scripts/lib/probes/spark-monitor.sh:111-114`), and says so when it is not the pin this
  CLI would install (`scripts/spark-monitor.sh:644`). That `note:` line is how a stale pin
  gets caught: the box that was enrolled last spring keeps answering on the old tag and
  nobody looks.
- **Profiling counters return nothing without `SYS_ADMIN`.** Every `DCGM_FI_PROF_*` field
  needs the exporter started with `--cap-add SYS_ADMIN` (plus
  `NVreg_RestrictProfilingToAdminUsers=0` on the box), and this CLI does not pass that cap
  (`scripts/spark-monitor.sh:239`). A box answers those fields with no rows at all rather
  than an error - `DCGM_FI_PROF_*` being absent from a scrape is the expected result, not
  a broken exporter (`observability/dcgm/custom-counters.csv:98-99`).
- **A box without NVLink logs nothing for NVLink fields.** The per-link
  `DCGM_FI_DEV_NVLINK_*_L<n>` counters are commented out of the shipped field list for
  that reason: on a GPU that exposes no NVLink each one is a per-field error in the
  exporter log on every scrape (`observability/dcgm/custom-counters.csv:72-81`). The
  aggregate `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` ships and reads zero.

## Failure modes

### ssh reachability

**ssh will not reach a box.** In `--status` this is a `warning:` naming the ssh error, and
the exit status stays 0 (`scripts/spark-monitor.sh:566-576`): a box that is off, or one
this shell has no credentials for, is a not-yet state.

Under `--apply` or `--restart` the same box is a `fail_item` and the run exits non-zero,
because a fleet where two of three boxes were enrolled is precisely the drift this CLI
exists to remove.

Check `SPARK_SSH_USER` (default: your login name, `scripts/spark-monitor.sh:101`) and
`--port`, and run it from the host shell - a workspace cannot resolve the LAN names.

If the box drops packets rather than refusing, you see
`ssh was cut off after <n>s (timeout(1)
guard)`; on a host without `timeout(1)` the CLI warns up front that the round trips run
uncapped.

### A port already in use

**A port is already taken on a box.**

`--apply` reports it per container as `<name> is not running (<state>): <what docker said>`
(`scripts/spark-monitor.sh:675`, `scripts/spark-monitor.sh:685`) - the text after the colon
is docker's, so `port is already allocated` names the process holding 9100 or 9400.

The containers are idempotent by name, so this is a *different* process on the port, not
this CLI double-booking itself.

Move the port with `SPARK_NODE_EXPORTER_PORT` / `SPARK_DCGM_EXPORTER_PORT` - the target
document and the scrape follow the key - and re-run `--apply`.

### An exporter running but not answering

**An exporter container exists and is not answering.** Two shapes, and they read
differently:

- A container that `docker ps` does not list (exited, restarting) comes back
`absent`, so the CLI says `node_exporter is absent -- Prometheus scrapes <host>:9100 and
gets nothing` and points at `--apply --box <n>`
(`scripts/spark-monitor.sh:616-624`).

- A container that *is* listed but does not serve still counts as running for
  node_exporter, and shows up one line later on the DCGM side: the probe counts counters
  from a live local scrape of `:<port>/metrics` and only falls back to the field list baked
  into the image when that scrape returns nothing
  (`scripts/lib/probes/spark-monitor.sh:196-206`), so a `note:` whose counter count matches
  the image's default list rather than this repo's file means the exporter is up and not
  serving your field list.

`--restart` is the first thing to try; `--apply` re-ferries the CSV if the file changed.

### A panel stays empty

When a Spark panel stays empty, work outward in this order:

1. `--status` (is the container there and serving)
2. `--targets` (is the box in the document at all)
3. the scrape on the host through `bazelisk run //scripts:observability-check`

Symptoms that outgrow those three commands belong in [troubleshooting.md](troubleshooting.md).
