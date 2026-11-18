---
title: Monitoring and alerts
description: "Running the observability bundle day to day: where the 26 alerts live, what Alertmanager pages on and off, why its UI stays on loopback, where a silence belongs, and how the three DGX Sparks become Prometheus targets."
tags: [operate, observability, prometheus, alertmanager, spark]
---

# Monitoring and alerts

**What's on this page**

- The alerts the bundle ships, and the two pages that show them
- What an empty `ALERTMANAGER_WEBHOOK_URL` means for who gets paged
- Why Alertmanager's UI is loopback-only, and where a silence belongs
- Making the three DGX Sparks Prometheus targets with `//scripts:spark-monitor`

**What this enables**

- Telling a firing alert from a missing exporter before you restart anything
- Enrolling the Sparks without hand-editing a Prometheus config

Every command here is a Bazel target run from a **host** shell. Inside a Coder workspace
the `docker` CLI only reaches that workspace's own DinD sidecar, so a check aimed at the
stack's own containers has to be run where the stack lives.

## Alerts

Three rule files arrive with Prometheus and need no second registration:
`observability/prometheus/rules/stack.rules.yml` carries the nine host alerts,
`spark.rules.yml` the seven Spark alerts, and `inference.rules.yml` the ten inference
alerts - 26 in all. Prometheus evaluates them. The bundle now also runs Alertmanager
(`prom/alertmanager:v0.35.0`) to group them, hold them, and decide who hears about them.

What that means day to day:

- **An empty `ALERTMANAGER_WEBHOOK_URL` is the shipped state, and it pages nobody.**
  The rules still fire and stay readable on Prometheus's `/alerts` page and on Grafana's
  Alerting page; only the delivery step is silent. Set the key to a webhook URL when you
  want a person told, and never put a URL that carries a credential in `.env`.
- **Alertmanager's UI is published on loopback only** (`OBS_ALERTMANAGER_PORT`, 9093),
  for the same reason Coder's `:2112` metrics port is: that UI can silence a firing
  alert, so an unauthenticated silencer on the LAN is a way to make a real fault
  invisible. Read it from a shell on the stack host.
- **Make silences in Alertmanager, not in Grafana.** Alertmanager owns grouping,
  silences and the repeat interval, so a silence created anywhere else does not stop the
  route - and the two views then disagree about why nobody was paged.

The three exporters feeding those rules sit beside the bundle on the same
`observability` profile, all published to `127.0.0.1` only: node_exporter
(`quay.io/prometheus/node-exporter:v1.12.1`) on `OBS_NODE_EXPORTER_PORT` (9101), cAdvisor
(`ghcr.io/google/cadvisor:v0.61.0`) on `OBS_CADVISOR_PORT` (9290), and blackbox_exporter
(`prom/blackbox-exporter:v0.29.1`) on `OBS_BLACKBOX_PORT` (9115). The data path behind
them, and what each config file costs to change, is
[observability.md](../observability.md).

## The Spark exporters

The three DGX Sparks are not scrape targets until you make them one. Each box needs two
containers - node_exporter on `SPARK_NODE_EXPORTER_PORT` (9100) and the NVIDIA DCGM
exporter on `SPARK_DCGM_EXPORTER_PORT` (9400) - and neither exists on a box until
`--apply` creates it:

```sh
bazelisk run //scripts:spark-monitor
```

```sh
bazelisk run //scripts:spark-monitor -- --status
```

```sh
bazelisk run //scripts:spark-monitor -- --apply
```

Plan is the default and opens no ssh session and no docker call, so the first two are
safe to run before anything is decided. `SPARK_MONITOR_ENABLED` (false as shipped) is the
opt-in that decides whether `--targets` prints the three boxes or an empty array, and the
DCGM image comes from `SPARK_DCGM_EXPORTER_IMAGE`. That one tag -
`nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04` - is the pin this stack could
not verify upstream, so `--apply` is what proves it: it surfaces whatever the registry
answers when the pull fails, and `--status` prints the tag a box actually runs.

`--targets` prints the `sparks.json` that Prometheus reads through `file_sd_configs`; the
redirect that writes it on the host, the refresh interval, and what an absent file mean
are in `observability/spark-targets/README.md`. The box-by-box walkthrough, the counter
file the DCGM container is handed, and the failure modes are
[spark-monitoring.md](../spark-monitoring.md).

## Where to look next

- [Observability bundle](../observability.md) - the ten profile-gated services, the path
  a metric takes, the retention, and what the bundle costs on disk
- [Spark monitoring](../spark-monitoring.md) - enrolling the three DGX Sparks: the two
  exporter containers, the `SPARK_MONITOR_ENABLED` opt-in, and what `--apply` does to a
  box.
- [Rotate a credential](secrets.md) - what to re-check after a key the bundle reads moves
