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
- Which of the thirteen provisioned dashboards answers which question, and how a panel actually gets changed
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
  scrape carries a bearer token, so the metrics stay behind `LITELLM_MASTER_KEY` the way
  every other LiteLLM endpoint is. The collector expands `$VAR` and `${VAR}` only in
  `global.external_labels` values - a scrape target address and
  `authorization.credentials` get no expansion at all, and `$(VAR)`, `${VAR}` and `$VAR`
  in the latter each go out verbatim on v3.16.0 - so the key cannot travel that way, and
  it arrives as a file instead. Compose renders `configs.litellm_metrics_token` into
  `/etc/prometheus-secrets/litellm_token` in the container (`docker-compose.yml:839-841`,
  `:1452`), and the `litellm` job presents that file through
  `authorization.credentials_file` (`observability/prometheus/prometheus.yml:126-129`).
  The config's `content:` interpolates the very same
  `${LITELLM_MASTER_KEY:-change-me-litellm}` the proxy boots with
  (`docker-compose.yml:1452`), so with no dotenv both ends land on the shipped
  placeholder and the scrape works, and the fault an operator actually meets is the two
  ends disagreeing: rotate the key without recreating `prometheus` and the file still
  holds the old one.
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
  job name is the Compose service name (`observability/prometheus/prometheus.yml:142` and
  `:151`). Renaming either service without renaming its job makes two alerts permanently
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
| `observability/grafana/dashboards/` | The thirteen provisioned dashboard JSONs - the section below names each one and what it answers - mounted again at `/var/lib/grafana/dashboards` (`docker-compose.yml:1049`), which is the path the provider reads |
| `observability/grafana/unified-storage/overrides.yml` | Grafana's unified-storage quota overrides, mounted read-only at `/etc/grafana/stack-overrides.yml` and named there by `GF_UNIFIED_STORAGE_OVERRIDES_PATH` (`docker-compose.yml:1035`, `:1055`) - the note below says what its presence buys |
| `observability/alloy/config.alloy` | The log pipeline: which files to tail, what to ship to Loki |
| `observability/prometheus/rules/` | Prometheus, through that `rule_files:` block: `stack.rules.yml`, `spark.rules.yml`, `inference.rules.yml`. They arrive with the directory this file is mounted from, so there is no second place to register a rule |
| `observability/alertmanager/alertmanager.yml` | Alertmanager: the `tier` routes, three inhibit rules, and five receivers (four webhook, one blackhole for the heartbeat) |
| `observability/alertmanager/boot-webhook-url.sh` | The container's `entrypoint:`: writes `/alertmanager/webhook_url` from `ALERTMANAGER_WEBHOOK_URL`, then execs the binary |
| `observability/blackbox/blackbox.yml` | blackbox_exporter: the two HTTP probe modules the Spark jobs pass by name, `spark_health` and `spark_models` |
| `observability/grafana/provisioning/alerting/stack.yaml` | The `stack-alertmanager` contact point and Grafana's default alerting policy |

Two consequences of the `:ro` mounts, both the same rule the other payload directories
follow. A bind follows the *path*, so an edit made in the checkout is already inside the
running container, and the only question left is when the process reads it again:
measured against the pinned image, an in-place rewrite of a mounted file and a rename of
a new one over it both reached the container with no restart and no recreate, which is
why the dashboards section below can promise a minute rather than a redeploy. The one
credential that behaves differently is the LiteLLM bearer token, and the reason is that
it is not a bind - Compose writes a `configs` entry when it creates the container, so
rotating `LITELLM_MASTER_KEY` takes `up -d --force-recreate prometheus`, where a plain
`up -d` leaves the old bytes in place, and so does a `restart`. And treat the provisioned
dashboards and datasources as read-only in the UI: `allowUiUpdates: false` and
`disableDeletion: true` stop a save from overwriting the JSON, so anything you build by
hand lands in Grafana's own database in `grafana-data` instead - it works, and it drifts
from git invisibly.

The `grafana` service carries two settings that live in its `environment:` block
(`docker-compose.yml:1034-1035`) rather than in any file above, each one there to quiet a
Grafana 13.3.1 defect this box pays for as log noise.
`GF_LOG_FILTERS: search-manifest-watcher:error` drops that one logger to `error` and
leaves every other logger at its default. The watcher warns twice each poll, and the
polls in the log this branch was cut from were 41 to 59 s apart -
`source listed zero manifests`, then `zero manifests, keeping previous set` - whenever no
app publishes a search manifest, which is every OSS install with nothing provisioned into
the app platform; upstream calls that a logging defect (grafana/grafana#137058) and
confirms search keeps working, because retrying an empty source is intended and only the
level is wrong. The filter is a workaround for that defect, not a preference: it comes
out when the pin moves to a release carrying the fix, and the pin today is
`grafana/grafana:13.3.1` (`docker-compose.yml:976`).
`GF_UNIFIED_STORAGE_OVERRIDES_PATH: /etc/grafana/stack-overrides.yml`
points the unified-storage resource server at the file the table names: without it the
quota lookup the browse view fires on every dashboard page answers 501, since that
server's quota service is nil with nothing pointed at it (grafana/grafana#136271), and the
box prints one error line per page load while the browser console fills with 501s; with it
the same call answers 200. Both were measured on `grafana/grafana:13.3.1`: 12
`search-manifest-watcher` warnings became 0 and the quota call went from 501 to 200, with
`/api/health` still 200. The overrides file itself says `overrides: {}`, which is
Grafana's own defaults - it is the file's presence that clears the 501, not any limit set
in it. What the quota call then reports is that default, `{"usage":0,"limit":1000}` for
dashboards and for folders on 13.3.1; four plausible cap shapes left the number where it
was, and a scalar or an unparseable document under `overrides:` stops the container at
boot, so the file's header asks for a limit to be proven on the pinned image before it is
written down.

The thirteen dashboards are provisioned, so they appear on a fresh Grafana in the
`EVO-T1` folder with no clicking - the section below names each one and the question it
answers. The LiteLLM board is the one that depends on a credential: its metrics sit behind
`LITELLM_MASTER_KEY` like every other LiteLLM route, and the bearer Prometheus presents is
the file Compose rendered from that key, so anything that puts the two ends out of step -
a key rotated in the env file with `prometheus` never recreated, a token file that is
missing or wrong - leaves every panel on that board reading empty while the others stay
full.

## The dashboards

Thirteen JSON files in `observability/grafana/dashboards/` are the only dashboards this
stack ships. `observability/grafana/provisioning/dashboards/stack.yaml:11` loads them all
into one `EVO-T1` folder (`:14`) with `disableDeletion: true` (`:16`),
`updateIntervalSeconds: 60` (`:17`) and `allowUiUpdates: false` (`:18`). Read those three
values before you try to fix a panel. Then find your question in the tables below: every
page name and every panel name quoted here is copied out of the JSON, so you can search
the UI for it. Panel counts include the panels a collapsed row holds.

### Which page answers which question

The stack host - the box the bundle itself runs on:

| Question | Page | UID | Panels |
|---|---|---|---|
| What is the box doing as a machine: per-core CPU, load, the PSI pressure stats, memory and swap, IOPS and throughput per device, `Space and inode headroom per mount`, dropped packets, conntrack, file descriptors, `Top containers by CPU` | Stack host task manager | `evo-host-taskmanager` | 36 |
| Which container is at fault: `CPU usage against CFS throttling`, `Memory working set against its limit`, `OOM kills`, `Uptime since last start`, `Reported containers and how stale each is` | Containers | `evo-containers` | 12 |

The DGX Sparks - the off-stack boxes Prometheus probes through blackbox:

| Question | Page | UID | Panels |
|---|---|---|---|
| Which box needs looking at: one repeated stat strip per enrolled box, then `Every Spark, one row per box` and `Serving request rate, by deployment` | DGX Sparks overview | `evo-sparks-overview` | 11 |
| Everything about the one box you have picked: the host rows, the GPU rows (`GPU utilisation`, `Framebuffer used and free`, `GPU and memory temperature against the slowdown point`, `ECC row remaps in the last hour`), the blackbox probe rows, and that box's own deployments | One DGX Spark | `evo-spark-host` | 41 |
| The fleet as one number: `Total GPU utilisation`, `Total GPU power draw`, `Hottest GPU core`, `Fullest framebuffer`, `Uncorrectable ECC rows, last hour`, the per-box comparison tables, and the fleet admission queue | DGX Spark fleet | `evo-sparks-fleet` | 15 |

The inference backends - the software that serves the models, not the machines it runs
on, which are two rows above:

| Question | Page | UID | Panels |
|---|---|---|---|
| What callers see, per model: `Request rate by model`, `Error ratio by model, 4xx vs 5xx`, the three latency panels, `Time to first token by model (p50/p95/p99)`, `Cache hit ratio`, `Served models, one row per deployment` | Models | `evo-inference-models` | 24 |
| What the router is doing, per deployment: `Deployment inventory and state`, `Backends off the healthy state`, `Cooldown transitions per deployment`, `Admission rejections by reason`, `Balance per deployment`, `Aliases served per deployment`, `Upstream p95 against total p95, per deployment` | Inference backends | `evo-inference-backends` | 24 |

The bundle itself:

| Question | Page | UID | Panels |
|---|---|---|---|
| Start here: the `EVO-T1 dashboards` list and one link panel per board, then a stat per bundle service beside `Targets up`, `Targets configured` and `Scrape freshness` | EVO-T1 stack | `evo-home` | 33 |
| Is the monitoring still working: `Scrape targets up`, `Prometheus TSDB on disk`, `Remote write to Mimir`, and one reporting-stat per exporter and per bundle process, each reading `0` while that process answers its scrape and `1` when it has no series at all | Stack overview | `evo-stack-overview` | 28 |
| What is firing and did it get out: `Firing alerts`, the three severity counts, `Firing series by alert`, `Alertmanager intake`, `Notifications dropped`, `Slowest rule group` | Alerts | `evo-alerts` | 16 |
| What did a container say: `Log volume`, `stdout and stderr`, `Errors only` | Container logs | `evo-stack-logs` | 3 |
| Where did a request spend its time: `Span rate by service`, `Span latency, p95 by service`, `Span errors` | Traces and service map | `evo-stack-traces` | 4 |
| What did the proxy cost and do: `Spend in the selected range`, `Spend per model, selected range`, `Requests by status code`, `Deployment state`, `Cooldown events per deployment` | LiteLLM proxy | `evo-litellm` | 17 |

Four of those carry a `How to read this page` text panel - `evo-alerts`,
`evo-inference-models`, `evo-litellm` and `evo-stack-traces` - and it is worth reading
before you chase a flat line on one of them.

### How the Sparks pages reach one machine

`evo-sparks-overview` and `evo-spark-host` each declare a `host` templating variable, both
of them a `query` variable whose query is `label_values(spark:box_up, hostname)`, so the
dropdown lists the boxes Prometheus actually sees and nothing else. On `evo-spark-host` the
variable is labelled `Spark` and every panel on the page filters to whatever it holds.

The overview does not ask you to choose first. Seven stat panels - `Spark $host`,
`GPU util`, `Framebuffer fill`, `Temp headroom`, `Power`, `CPU`, `Memory` - each carry
`repeat` on that same variable with `repeatDirection: h`, so the strip renders one column
per enrolled box. The link panel `Open this Spark` repeats alongside them and points at
`/d/evo-spark-host/one-dgx-spark?var-host=${var:queryparam}`: the tile under the box you
are reading opens that box's page with `host` already set. That is the path from a red tile
on the overview to the GPU rows for that machine, and it is the only link between the two
boards. `evo-sparks-fleet` declares no variable at all, because it aggregates across every
box by design.

### A dashboard is a committed file

The provider owns the `EVO-T1` folder, so nothing you do in the browser to a shipped panel
survives: `allowUiUpdates: false` refuses the save, `disableDeletion: true` refuses the
delete, and the 60-second poll quietly undoes whatever the UI let you stage. A board you
build from scratch is not thrown away - it lands in Grafana's own database on `grafana-data`
- but it is invisible to git and to the gate below, which is the same drift the `:ro` mounts
above exist to prevent.

So the way to change a panel is to edit its JSON and let the interval apply it. The folder
is bind-mounted read-only onto the path the provider scans (`docker-compose.yml:1049`), so
an edit to a file that is already there is visible to the running container and shows up
within a minute - no restart, and no recreate. A new file needs no registration either, for
the same reason. Recreate only when the mount line or the provisioning tree itself changed
(`docker-compose.yml:1047-1048`), and then with the `up -d` rule from the section above:

```sh
bazelisk run //scripts:prod-stack -- up
```

### The gate

The folder is source, so it is tested as source:

```sh
bazelisk test //tests:bats_observability_dashboards_test
```

`tests/bats/observability-dashboards.bats` asserts seventeen properties over every file in
it: the folder is non-empty and each file parses with the repo's own parser; each is pure
ASCII, LF-only, one trailing newline; the pinned top-level keys and house values are
present; UIDs and titles are unique across the folder; panel ids are unique integers;
every panel carries a full `gridPos` and no two visible panels overlap; every panel stays
inside the house key set; every target opens with `refId` and carries its own datasource;
every datasource is one of the four provisioned UIDs; every querying panel carries a
`description`; every stat states its own empty reading rather than leaving it to Grafana;
every referenced variable is declared; every templating variable is well
formed; every link names a dashboard that exists in the folder; every UID besides
`evo-home` is named by a link panel or a `links:` entry there; and no file carries an
import block, a host name, or a dead metric shape.

The one to read before you write an `expr`: every metric name in every `expr` has to sit on
a pinned allow-list, and that list is assembled at test time from the recording rules this
repo ships under `observability/prometheus/rules/` as well as the pinned names
(`tests/bats/observability-dashboards.bats:688`). A new recording rule therefore needs no
test edit, and a metric nothing here records fails the build instead of rendering an empty
tile. `bazelisk run //scripts:validate` covers the coarser layer: it parses every dashboard
JSON through `scripts/lib/parse_json.py` (`scripts/validate.sh:104`), the gate that already
covers the three rule files.

Nothing in this section has been rendered in a live Grafana from this checkout: the pages
are proven by that structure and by metric names a source in this repo backs, not by
pixels.

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

Its service list is still the original six (`OBS_SERVICES`, `scripts/observability-check.sh:165`).
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
a target present and `down` is the app not serving `/metrics`, or - for `litellm` alone -
the bearer file not holding the key the proxy answers with. That failure describes itself
twice over: a file that is not there leaves one red target whose `lastError` names
`/etc/prometheus-secrets/litellm_token` while Prometheus loads the rest of the config
normally, and a file holding the wrong key brings LiteLLM's 401 body `No connected db.`,
which at v1.102.1 is the wrong-token branch rather than a database complaint - its auth
path compares the bearer against `LITELLM_MASTER_KEY` and returns PROXY_ADMIN before it
looks for a DB. Either way the fix is the file and a recreate of `prometheus` so Compose
renders it again; the metrics stay authenticated. What that 401 offers instead is turning
the endpoint's auth off (`litellm_settings.require_auth_for_metrics_endpoint`), and this
stack refuses it: `:4000` is published to the LAN, and these metrics name model aliases
and traffic volumes.

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
