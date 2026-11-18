---
title: Observability bundle
description: "The ten profile-gated monitoring services: what each one does, how metrics, logs and traces reach Grafana, how an alert reaches Alertmanager, where each config file lives, what the data costs on disk, and what is deliberately left out."
tags: [observability, prometheus, grafana, loki, tempo, mimir, operate]
---

# Observability bundle

**What's on this page**

- What each of the ten services does, and why this stack ships it at all
- The path a metric, a log line and a span take before Grafana renders them
- The one flag that decides whether the bundle exists, and how to turn it off
- Where each component's config lives in the checkout, and what it costs to change
- Retention caps, the named volumes the data lands on, and how to reach each UI
- What is not here - no pager destination until you set one, no object storage, no trace client

**What this enables**

- Reading the box's history from Grafana instead of from `docker compose logs`
- Telling a scrape fault from a write fault from a read fault in three commands
- Deciding what to add next without guessing what is already wired

Ten services sit behind one Compose profile. Six of them store and read - `prometheus`,
`mimir`, `loki`, `tempo`, `grafana` and `alloy` - and four watch the box and speak up -
`node_exporter`, `cadvisor`, `blackbox_exporter` and `alertmanager`. They answer one
question the rest of the stack cannot - what this box was doing ten minutes ago - and they
are the only part of the stack that keeps data after a container is gone. Everything else on this page is about the seams between them,
because that is where a monitoring stack silently stops working: a service can be
`running`, a dashboard can be green, and a panel can still be empty.

## The ten services

| Service | Image | Job on this box |
|---|---|---|
| `prometheus` | `prom/prometheus:v3.16.0` | Scrape. Holds the last `PROMETHEUS_RETENTION_TIME` of series on its own TSDB and copies every sample to Mimir. |
| `mimir` | `grafana/mimir:3.2.5` | Long-term metric store. Prometheus `remote_write`s into it; Grafana queries the long view out of it. |
| `loki` | `grafana/loki:3.7.10` | Log store. Takes the lines Alloy ships and answers LogQL from Grafana's Explore. |
| `tempo` | `grafana/tempo:3.1.1` | Trace store. Listens for OTLP on `4317` and answers trace queries on `3200`. |
| `grafana` | `grafana/grafana:13.3.1` | The only read path and the only published UI. Metrics, logs and traces all render here, from four provisioned datasources. |
| `alloy` | `grafana/alloy:v1.22.0` | The collector. Tails the host's Docker json-file logs and pushes them to Loki. |
| `node_exporter` | `quay.io/prometheus/node-exporter:v1.12.1` | The stack host as a machine. Reads `/proc` and `/sys` read-only under `--path.rootfs=/host` with `pid: host`, and adds `--collector.processes` so the process series exist at all. |
| `cadvisor` | `ghcr.io/google/cadvisor:v0.61.0` | Per-container metrics. The bundle's one privileged container, `--docker_only` with `image,name` whitelisted as labels. |
| `blackbox_exporter` | `prom/blackbox-exporter:v0.29.1` | The prober for anything with no `/metrics` to scrape: Prometheus hands it each URL as `__param_target`, so one container probes every Spark. |
| `alertmanager` | `prom/alertmanager:v0.35.0` | Delivery. Groups, inhibits and silences what the rule files fire, and holds the repeat interval. |

The split is upstream's own: Prometheus is a fast local scratch store, Mimir is the same
PromQL over longer retention, and Alloy is the single agent that touches the host
filesystem. This box needs all three because a container that dies takes its own log
file out of `docker compose logs` reach only if you are too late - but a workspace that
was slow at 03:00 is unrecoverable without retention.

## How the data moves

```text
app /metrics                        host docker log files
coder:2112  litellm:4000            /var/lib/docker/containers/*-json.log
     |        |                          |  (mounted read-only into alloy)
     v        v                          v
  prometheus:9090 ----remote_write---->  mimir:8080/api/v1/push
     |                                     ^
     |                                     |  /prometheus (long view)
     |                                     |
     +--> local TSDB (short view)           |
                                            |
  alloy ---> loki:3100  (log push)          |
  any OTLP client ---> tempo:4317 (grpc)    |
                                            v
                                       grafana:3000
                              four datasources, one login
```

Four things are worth naming precisely, because each is a place a panel goes empty while
every container stays up:

- **Prometheus is the only scraper.** Its scrape config targets the apps that publish
  `/metrics` - `coder:2112` and `litellm:4000` - plus the six components that publish
  their own (`prometheus:9090`, `mimir:8080`, `loki:3100`, `tempo:3200`,
  `grafana:3000`, `alloy:12345`), the stack host through `node_exporter:9101` and
  `cadvisor:8080`, Alertmanager itself at `alertmanager:9093`, and the Spark jobs that
  reach `blackbox_exporter:9115` as their prober. Fourteen jobs in all. The LiteLLM
  scrape carries a bearer token, so the
  metrics stay behind `LITELLM_MASTER_KEY` the way every other LiteLLM endpoint is; the
  key arrives in Prometheus' own environment and is expanded there, which is why it is
  not written into the committed scrape file.
- **The apps with no `/metrics` are observed by logs alone, on purpose.** `ollama`,
  `searxng`, `kasm`, `homepage`, the two nginx hops, `hermes`, and the three Infisical
  containers (`infisical`, `infisical-db`, `infisical-redis`) publish no Prometheus
  endpoint, so scraping them would leave a target answering 404 forever and a tally no
  one trusts. Ollama is the one operators ask about: upstream has had the request for a
  `/metrics` endpoint open since 2024 (ollama/ollama#3144), and the IPEX-LLM image runs a
  stock `ollama serve`, so there is nothing to scrape. Its traffic is measured anyway,
  because every request reaches it through LiteLLM, which does publish. What every one of
  those containers does contribute is its log stream, which is where a SearXNG rate limit
  or a Kasm start failure lands.
- **Mimir is written to, not scraped from.** Prometheus `remote_write`s to
  `http://mimir:8080/api/v1/push`. A query against the `prometheus` datasource answers
  from the local TSDB; the `mimir` datasource answers through
  `http://mimir:8080/prometheus`. Those two disagreeing is the diagnostic, not a bug.
- **Alloy, not Loki, reads the disk.** Loki has no Docker credential and no host mount.
  The only container that sees the host's container log directory is Alloy, and it sees
  it read-only. That directory is `${STACK_DOCKER_LOG_DIR:-/var/lib/docker/containers}`,
  mounted at the same path inside the collector, so a host whose daemon keeps its logs
  somewhere else (rootless Docker does) needs that key set or the collector tails
  nothing.
- **Traces arrive over OTLP only, and one client already speaks it.** Anything that wants
  traces in this stack sends OTLP gRPC to `tempo:4317`. Grafana is the one shipped
  caller: `GF_TRACING_ENABLED` points its own exporter at `tempo:4317`, so the trace
  viewer has the product's own spans before any workspace emits one. Tempo's
  metrics_generator then computes span-metrics and service-graph series and
  `remote_write`s them back into Prometheus, which is why Prometheus carries
  `--web.enable-remote-write-receiver`: without that flag the write is refused with a 404
  and the traces dashboard has nothing to plot.

Grafana's four datasources carry fixed UIDs - `prometheus` (the default), `mimir`,
`loki`, `tempo` - and every shipped dashboard references those UIDs, so renaming one in
the UI breaks the dashboards that were provisioned against it.

## Alerts and rules

Rules are evaluated by Prometheus and delivered by Alertmanager: the `alerting:` block at
`observability/prometheus/prometheus.yml:52` names `alertmanager:9093`, so grouping,
inhibition, silences and the repeat interval all belong to that one service.

| Rule file | Recording-rule prefix | Alerts | Critical |
|---|---|---|---|
| `observability/prometheus/rules/stack.rules.yml` | `host:` (one `container:` for the cAdvisor throttle ratio) | 9, all `tier="host"` | `HostCpuPegged`, `HostMemoryNearExhaustion`, `HostFilesystemNearFull`, `HostNodeExporterGap`, `HostCadvisorGap` |
| `observability/prometheus/rules/spark.rules.yml` | `spark:` | 7, all `tier="spark"` and each stamped `spark=<hostname>` | `SparkDown`, `SparkGpuRowRemapFailure`, `SparkGpuEccUncorrectable`, `SparkGpuSeriesSilent` |
| `observability/prometheus/rules/inference.rules.yml` | `litellm:` | 10, all `tier="inference"` | `LiteLLMModelErrorRatioSustained`, `LiteLLMDeploymentUnhealthy`, `LiteLLMDeploymentCoolingDownRepeatedly`, `LiteLLMBackendSeriesGone`, `LiteLLMMetricsAbsent` |

Four things about that wiring are worth knowing before you edit it:

- **The gap alerts select on the job name.** `HostNodeExporterGap` and `HostCadvisorGap`
  fire when `job="node_exporter"` or `job="cadvisor"` carries no series, which is why the
  job name is the Compose service name (`observability/prometheus/prometheus.yml:124` and
  `:133`). Renaming either service without renaming its job makes two alerts permanently
  quiet, and no test will tell you.
- **The Spark tier is quiet until the boxes are enrolled.** Those two jobs read their
  targets from `observability/spark-targets/sparks.json` through `file_sd_configs`, a file
  the stack host generates and `.gitignore:76` keeps out of git. No file means no target
  groups, which reads as zero Sparks rather than as a broken probe. The boxes' own
  node_exporter and DCGM exporter are installed on the boxes by `scripts/spark-monitor.sh`,
  not by this Compose file.
- **Grafana lists the rules because the datasource says to.** The Prometheus datasource is
  registered `alerting: true` (`observability/grafana/provisioning/datasources/stack.yaml:26`);
  without that flag the rules answer only on Prometheus' own `/alerts` page and never
  appear under Alerting -> Rules. Delivery still belongs to Alertmanager.
- **An alert a person builds in Grafana goes to the same Alertmanager.** The provisioned
  contact point is `type: alertmanager` at `http://alertmanager:9093`
  (`observability/grafana/provisioning/alerting/stack.yaml:28`), not a webhook, so it
  speaks `/api/v2/alerts` and Alertmanager's grouping, inhibition and silences apply to
  Grafana-originated alerts exactly as they do to Prometheus'. One place holds the
  silences, whichever engine fired.

Nothing leaves the box until the operator says who to tell. Alertmanager's own config
parser cannot expand an environment variable inside a webhook URL, so
`observability/alertmanager/alertmanager.yml` carries no URL at all: all four webhook
receivers read `url_file: /alertmanager/webhook_url`. That file is written at container
start by the image's entrypoint, `observability/alertmanager/boot-webhook-url.sh`, from
the `ALERTMANAGER_WEBHOOK_URL` key (`.env.example:635`, empty as shipped), and the script
then `exec`s the binary. An empty key is a working configuration: the container starts,
the rules fire, the receivers are no-ops, and the entrypoint regenerates the file every
start so a removed key cannot survive as a stale destination on disk. The Alertmanager UI
is loopback-bound for the same reason it has no auth - it can silence alerts - so read it
from a shell on the stack host, or use Grafana's Alerting pages, which need no extra port.

## The flag

One key decides whether the bundle exists: `OBSERVABILITY_ENABLED`, default `true`, in
`.env.example` and `.env.sample` beside it. All ten services carry
`profiles: ["observability"]`, and `compose_observability_args()` in
`scripts/lib/common.sh` is the single place that reads the key - it prints
`--profile observability` when the value is truthy and nothing for `false`, `0`, `no` or
`off`. Every stack runner goes through it: `dev-stack.sh` and `prod-stack.sh` in their
`compose_prefix()` and `run_compose()`, and `update-stack.sh` in `stack_compose()`.

To turn the bundle off, set the key in the env file that belongs to that project -
`.env` for the stable stack, `dev-stack.env` for the dev one - and bring the stack up:

```sh
bazelisk run //scripts:prod-stack -- up
```

A profile decides which services a command *selects*; it does not delete what is already
running. The ten containers stay up until you stop them, so after flipping the key off
either take the project down (`bazelisk run //scripts:prod-stack -- down`) or delete the
ten by name through compose. Their named volumes survive either way, and `reset` is the
one that destroys them.

Both flag paths are gated: `bazelisk run //scripts:validate` runs
`docker compose config -q` twice, once plain and once with `--profile observability`, so
a compose file that only parses with the bundle on (or only with it off) fails the build
rather than the deploy.

## Where each config lives

The bundle's payloads are one directory of their own, bind-mounted read-only, so
`git diff` is the record of every monitoring change and nothing is edited in the running
container:

| Path | Read by |
|---|---|
| `observability/prometheus/prometheus.yml` | Prometheus: the fourteen scrape jobs, the `alerting:` block that names Alertmanager, the three `rule_files:` and the Mimir `remote_write` |
| `observability/loki/loki.yml` | Loki |
| `observability/tempo/tempo.yml` | Tempo |
| `observability/mimir/mimir.yml` | Mimir, including `multitenancy_enabled: false` - see the query path below |
| `observability/grafana/provisioning/datasources/stack.yaml` | The four datasources and their fixed UIDs |
| `observability/grafana/provisioning/dashboards/stack.yaml` | The provider that loads the JSON below: folder `EVO-T1`, `allowUiUpdates: false`, `disableDeletion: true` |
| `observability/grafana/dashboards/` | `stack-overview.json`, `stack-logs.json`, `stack-traces.json`, `litellm.json` - mounted again at `/var/lib/grafana/dashboards`, which is the path the provider reads |
| `observability/alloy/config.alloy` | The log pipeline: which files to tail, what to ship to Loki |
| `observability/prometheus/rules/` | Prometheus, through that `rule_files:` block: `stack.rules.yml`, `spark.rules.yml`, `inference.rules.yml`. They arrive with the directory this file is mounted from, so there is no second place to register a rule |
| `observability/alertmanager/alertmanager.yml` | Alertmanager: the `tier` routes, three inhibit rules, and five receivers (four webhook, one blackhole for the heartbeat) |
| `observability/alertmanager/boot-webhook-url.sh` | The container's `entrypoint:`: writes `/alertmanager/webhook_url` from `ALERTMANAGER_WEBHOOK_URL`, then execs the binary |
| `observability/blackbox/blackbox.yml` | blackbox_exporter: the two HTTP probe modules the Spark jobs pass by name, `spark_health` and `spark_models` |
| `observability/grafana/provisioning/alerting/stack.yaml` | The `stack-alertmanager` contact point and Grafana's default alerting policy |

Two consequences of the `:ro` mounts, both the same rule the other payload directories
follow: edit the checkout and recreate the service (`up -d`, not `restart`, since a
restart keeps the old mounts), and treat the provisioned dashboards and datasources as
read-only in the UI. `allowUiUpdates: false` and `disableDeletion: true` stop a save
from overwriting the JSON, so anything you build by hand lands in Grafana's own database
in `grafana-data` instead - it works, and it drifts from git invisibly.

The four dashboards are provisioned, so they appear on a fresh Grafana in the `EVO-T1`
folder with no clicking: a stack overview, the logs board, the traces board, and a board
for LiteLLM. They are the whole set, so a board you want is a JSON file added to the
checkout and a recreate, not a browser session. The LiteLLM board is the one that depends
on a credential: its metrics sit behind `LITELLM_MASTER_KEY`, so with the key unset every
panel on it reads empty while the other three stay full.

## Retention and disk

Everything lands on named volumes under Docker's volume root on the host disk. Nothing
here reaches an object store, so the caps are what protect that disk:

| Component | Cap (env key, default) | Volume -> container path |
|---|---|---|
| Prometheus | `PROMETHEUS_RETENTION_TIME` (15d), `PROMETHEUS_RETENTION_SIZE` (10GB) - whichever hits first | `prometheus-data` -> `/prometheus` |
| Mimir | `MIMIR_RETENTION_PERIOD` (2160h, 90 days) | `mimir-data` -> `/data/mimir` |
| Loki | `LOKI_RETENTION_PERIOD` (168h, 7 days) | `loki-data` -> `/loki` |
| Tempo | `TEMPO_BLOCK_RETENTION_TIME` (168h), applied by the backend-scheduler's compaction work | `tempo-data` -> `/var/tempo` |
| Grafana | n/a (dashboards, not series) | `grafana-data` -> `/var/lib/grafana` |
| Alloy | none shipped; it keeps its own state under `--storage.path` | `alloy-data` -> `/var/lib/alloy/data` |
| Alertmanager | none; it keeps silences and notification state, not series | `alertmanager-data` -> `/alertmanager` |

The four exporters keep nothing between runs: what they hold is a scrape interval deep, so
recreating one costs no history and needs no volume of its own.

Change a cap in the env file and recreate. The Prometheus size cap is the one that
actually bounds the box: it is the only figure that does not depend on how fast the
series arrive. Tempo's cap is the odd one, because Tempo 3.x moved it out of the config
file - it reaches the container as `-backend-scheduler.provider.work.compaction.block-retention`
on the command line in docker-compose.yml, so editing tempo.yml for it changes nothing.
`bazelisk run //scripts:storage-clean` is the interactive janitor for the persistent
layer if a volume outgrows what you meant it to hold.

## Reaching the UIs

| What | Where | Notes |
|---|---|---|
| Grafana | `http://<lan>:3005` (`GRAFANA_PORT`), and `grafana-<suffix>.<base>` when `STACK_PUBLIC_HOSTS` names it | The only published name in the bundle. Login is `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`; anonymous access and analytics reporting are off. |
| Prometheus | `http://127.0.0.1:9090` (`PROMETHEUS_PORT`) | Loopback-bound on purpose, with the Coder `:2112` metrics port. Reading a graph there needs a shell on the stack host. |
| Mimir | nothing published - `mimir:8080` on the compose network | Reach it through Grafana's `mimir` datasource. |
| Loki | nothing published - `loki:3100` | Reach it through Grafana Explore. |
| Tempo | nothing published - `tempo:3200` query, `tempo:4317` OTLP | Reach it through Grafana Explore. |
| Alloy | nothing published - `alloy:12345` | The component graph UI stays inside the network; read the container's log instead. |
| Alertmanager | `http://127.0.0.1:9093` (`OBS_ALERTMANAGER_PORT`) | Loopback on purpose. Its UI silences alerts and the service ships no auth, so an Alertmanager reachable by the whole LAN is not something to hand a network. Read silences here from a shell on the stack host, or through Grafana's Alerting pages. |
| The three exporters | `node_exporter` on `127.0.0.1:9101` (`OBS_NODE_EXPORTER_PORT`), `cadvisor` on `127.0.0.1:9290` (`OBS_CADVISOR_PORT`), `blackbox_exporter` on `127.0.0.1:9115` (`OBS_BLACKBOX_PORT`) | Prometheus reaches all three by service name on the compose network; the loopback mapping exists so you can read a metric off the box itself. None reaches the LAN, which matters most for blackbox: it is a general-purpose outbound HTTP prober. |

Public mode follows the same path as the other names: `STACK_GRAFANA_NAME` (default label
`grafana`) is composed by `scripts/lib/domain.sh` with the rest, `bootstrap` writes
`STACK_GRAFANA_URL`, and the router sends that Host to `grafana:3000`. Only Grafana gets
a name - the other nine have no reason to answer the LAN, let alone the WAN, and
Alertmanager least of all. Full
detail on the naming parts and the Traefik side is in
[public-access.md](public-access.md).

## Operator checks

Start with the one command that asks all of these at once, then drop to the individual
probes when it names a section:

```sh
bazelisk run //scripts:observability-check
```

It walks the bundle outward from the dotenv - the operator keys, the host's log
directory, the profile render, each container's state, each endpoint, whether data is
actually moving - and prints the stack's usual `summary: N ok, W warnings, F failed`. It
is the check that catches the two failures a `running` state hides: an Alloy pointed at
an empty log root, and a Prometheus that scraped everything for a day and never wrote a
sample to Mimir. `--no-docker` skips the four unpublished backends when you are not on a
shell that can address the daemon.

Its service list is still the original six (`OBS_SERVICES`, `scripts/observability-check.sh:146`).
The four exporters and Alertmanager declare no `healthcheck` and publish no readiness path
of their own, so their state comes from the `status` rows and the container logs below,
not from this check.

Then, from the checkout on the stack host, in this order. Each one splits one symptom from
the next.

Is the bundle selected at all:

```sh
bazelisk run //scripts:prod-stack -- status
```

Ten rows when `OBSERVABILITY_ENABLED` is on, none when it is off. Expect `running`, not
`healthy`, on the eight that declare no `healthcheck`: `mimir`, `loki`, `tempo` and
`alloy` (those four images are distroless, so they carry no shell and no `wget`/`curl`
for a healthcheck to run), plus `node_exporter`, `cadvisor`, `blackbox_exporter` and
`alertmanager`. Only `prometheus` and `grafana` declare one. A missing row means the
profile was not selected - see the
troubleshooting entry on which env file the dev project actually reads.

Did Grafana come up and can it read its own database:

```sh
curl -s http://127.0.0.1:3005/api/health
```

Are the scrapes up:

```sh
curl -s http://127.0.0.1:9090/api/v1/targets
```

Every target should read `"health":"up"`. A target missing entirely is the scrape config;
a target present and `down` is the app not serving `/metrics`, or the LiteLLM bearer
token not matching.

Is the write to Mimir landing:

```sh
bazelisk run //scripts:prod-stack -- logs --tail 200 prometheus
```

A refused or failing `remote_write` shows up in the Prometheus log. The clean version of
the same question is asked in the UI: the `prometheus` datasource has the series and the
`mimir` one does not, which is a write fault, not a query fault.

Are the three unpublished backends alive: their health endpoints are
`http://loki:3100/ready`, `http://tempo:3200/ready` and `http://mimir:8080/ready`, all
compose-DNS only. Those exact URLs are the `siteMonitor` of the **Observability** group's
cards on the dashboard, so the card badge is the probe - and because those four
containers have no healthcheck, it is the only automatic one. For the logs behind a red
badge, use the container log rather than an exec, since a distroless image has no shell
to exec into:

```sh
bazelisk run //scripts:prod-stack -- logs --tail 200 alloy
```

Is the whole thing still well-formed on both flag paths:

```sh
bazelisk run //scripts:validate
```

That gate is what makes the monitoring payloads ordinary source: it parses the three rule
files, `alertmanager.yml`, `blackbox.yml` and the Grafana alerting policy, and parses every
dashboard JSON through `scripts/lib/parse_json.py` (`scripts/validate.sh:104`). A panel
that is not well-formed JSON, a dashboard whose `title` is blank, and the generated Spark
file-SD document are gate failures now rather than an empty tile someone notices in the
browser.

And the shipped payload checks, which cover the dashboard group and its card URLs:

```sh
bazelisk test //tests:bats_homepage_config_test
```

## What is deliberately not here

- **No destination is configured, so nothing pages anyone as shipped.** The rules, the
  routes and the receivers all exist; only the URL is missing. `ALERTMANAGER_WEBHOOK_URL`
  is empty in `.env.example`, so on a box nobody edited every alert is visible - on
  Prometheus' own alerts page and under Grafana's Alerting pages - and is delivered
  nowhere. Who gets woken is an operator decision, made in the env file.
- **No healthcheck or dashboard card for the four new services.** None of
  `node_exporter`, `cadvisor`, `blackbox_exporter` or `alertmanager` declares a
  `healthcheck`, and the dashboard's **Observability** group still carries five cards
  ([dashboard.md](dashboard.md)), so their liveness is the `status` row plus the container
  log.
- **No object storage.** Loki, Mimir and Tempo keep blocks on named volumes on this
  box's disk. The follow-up is a bucket and the storage config in each of those three
  files; nothing about the read path changes when it lands.
- **No trace client.** Tempo has an OTLP door and a datasource, and no caller. Pointing
  the first service at `tempo:4317` is a change in that service, not in this bundle.

When a symptom shows up as an empty panel, start at
[troubleshooting.md](troubleshooting.md), Observability section: the failures an operator
actually hits are all on one side of a seam - the scrape, the write, the tenant path, or
the log root Alloy was given.
