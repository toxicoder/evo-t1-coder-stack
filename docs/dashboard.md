---
title: Dashboard and desktops
description: "The Homepage dashboard and Kasm Workspaces: what each card reads, how the password is issued, and how a desktop gets streamed."
tags: [homepage, kasm, dashboard, operate]
---

# Dashboard and desktops

**What's on this page**

- What each dashboard card shows and which API it reads, the search lane included
- The header tiles: CPU, memory, temperature, disk, interface throughput, clock, search
- The password gate, the proxy in front of it, and how to rotate the password
- The payload gate: which dashboard mistakes the build catches before a deploy does
- Kasm's wizard-and-UI port pair, and what resetting it destroys

**What this enables**

- Reading the box's health from one page without a shell
- Fixing a card that reports down when the service itself is up

Two services that read the box rather than serve code: the Homepage dashboard (the
landing page) and Kasm Workspaces (streamed desktops).

## Homepage dashboard

### What it shows

#### Service cards

A card per service, with status pulled from each service's own API over the compose
network - `http://coder:3000`, `http://litellm:4000`, `http://ollama:11434`,
`http://hermes:9119/api/status` - so nothing here needs a daemon credential.

The header carries boxed tiles for host CPU, memory, CPU temperature, disk and `eth0`
throughput, beside the clock (date and 24-hour time), local weather (open-meteo,
keyless) and a search box.

#### The search box and the SearXNG card

That box asks the stack's own SearXNG rather than a public engine, so a search from the
dashboard goes to the same instance the workspace agents and Hermes dial.

The **Host** group carries the matching card: its badge probes `http://searxng:8181/healthz`, which
answers from the instance's own state without querying an upstream engine, and its three
fields come from `GET /config` on the same port - the release tag, and the two switches
that decide whether the box is a public instance (`limiter`, `public_instance`).

The dashboard never asks the instance for result rows: a polled `/search` would park engines
on the rate-limit and CAPTCHA walls, which is why that probe is
`bazelisk run //scripts:search-check`'s job, run on demand. See
[troubleshooting.md](troubleshooting.md).

#### The secrets vault card

The **Host** group carries one more card, for the secrets vault: its badge probes
`http://infisical:8080/` - the container port, not the published `INFISICAL_PORT`,
because this dashboard reaches every service over compose DNS - and `/` is the path the
pinned image's own healthcheck calls live. Its `href` rides
`{{HOMEPAGE_VAR_INFISICAL_URL}}`, which bootstrap fills from `STACK_INFISICAL_URL` when
the public names are set.

The bundle is one flag, `INFISICAL_ENABLED`, off as shipped:
with it off compose starts none of the three containers and the badge reads down with
them, so run `bazelisk run //scripts:infisical -- status` before chasing the card.

#### Card links

Card `href`s come from `STACK_CODER_URL` / `STACK_KASM_URL` / `STACK_LITELLM_URL` /
`STACK_HERMES_URL`, which default to LAN URLs built from `STACK_LAN_HOST` and the
port variables. Change a port or re-detect the LAN IP and the links follow; set `auto`
in `STACK_PUBLIC_HOSTS` and the cards follow the names bootstrap composes from the
naming parts ([public-access.md](public-access.md)).

The Hermes card
follows `STACK_HERMES_URL` when bootstrap sets it, and stays on
`http://<STACK_LAN_HOST>:9119` when that key is empty. See [hermes.md](hermes.md).

The search card and the header box share `STACK_SEARCH_URL`. The router composes public
names for the dashboard, coder, kasm, litellm and hermes only, so search has no public
name to fall to: leave the key empty and both stay on the LAN, where the card's status
still reports for anyone who can reach the dashboard.

#### The Observability group

The **Observability** group is the one group that reports on services publishing no port.

Its five cards - Grafana, Prometheus, Loki, Tempo, Mimir - carry a `siteMonitor` on
compose DNS (`http://grafana:3000/api/health`, `http://prometheus:9090/-/healthy`,
`http://loki:3100/ready`, `http://tempo:3200/ready`, `http://mimir:8080/ready`), which is
what proves the bundle is wired up: four of those six containers ship no healthcheck at
all (distroless image, no shell), so the badge is the only automatic signal they have.

The bundle's four other services - `node_exporter`, `cadvisor`, `blackbox_exporter` and
`alertmanager` - carry no card and publish nothing beyond the stack host's loopback, so
their liveness is read there, not here.

The hrefs go through `HOMEPAGE_VAR_GRAFANA_URL` and `HOMEPAGE_VAR_PROMETHEUS_URL`, which
default to the LAN URLs built from `STACK_LAN_HOST`, `GRAFANA_PORT` and
`PROMETHEUS_PORT`, and follow `STACK_GRAFANA_URL` once bootstrap composes the public name
- so the card that opens Grafana Explore for Loki and Tempo opens the same Grafana the
datasources point at.

The Grafana card also carries a `customapi` widget on
`/api/health` - the one endpoint that needs no session or API key - so the tile shows the
storage state and the running version, which is what you compare against the image pin in
`docker-compose.yml` after a pull.

Only Grafana has a URL a browser can resolve; the
three backends are reached from inside it. See [observability.md](observability.md).

### Login

`https://<host>/` serves the dashboard behind a self-signed certificate that
`scripts/bootstrap.sh` issues, so expect a one-time browser warning. Port 80 redirects
to HTTPS.

The password gate is homepage v2's built-in one, and it is worth keeping: the page
lists every service on the box.

`HOMEPAGE_AUTH_PASSWORD` holds the plaintext, because
homepage hashes that env var itself but still needs the value.

```sh
bazelisk run //scripts:dashboard-password
```

```sh
bazelisk run //scripts:dashboard-password -- --prompt
```

Either form:

1. rewrites `.env`
2. recreates the container
3. verifies the new value landed

The script's job is keeping the secret out of shell history, `ps` and git, and leaving
`.env` at mode 600.

### Config files

`homepage/config/*.yaml` plus `custom.css` are bind-mounted read-only, so `git diff`
stays the record of dashboard changes, and the directory itself has to stay writable
because the app creates `logs/` inside it.

A new config file (`kubernetes.yaml`, ...)
needs its own mount line in `docker-compose.yml` before the app sees it.

`custom.css` lives in `/app/config` and is served by the allow-listed
`/api/config/custom.css` route. It styles the sign-in page too, so keep internal
hostnames out of it.

### What the gate checks

#### What the check runs

`//:validate` proves these files parse. `tests/homepage_config_check.py` reads them the
way the app does and fails on the mistakes that parse happily:

```sh
bazelisk test //tests:bats_homepage_config_test
```

#### Invariants across the configs

- every `{{HOMEPAGE_VAR_*}}` token has a key in `docker-compose.yml`, and every
  `HOMEPAGE_VAR_*` key is used by some config file
- every service and bookmark group has a `layout` entry, and every `layout` key names a
  real group; a `style: row` group's `columns` equals the number of cards it holds
- a card `href` is a token or a public URL, never a compose service name: the browser
  cannot resolve `http://coder:3000`, only the dashboard server can
- a `siteMonitor` or widget `url` names a compose service or a token, never a loopback
  or LAN-address literal, which would bake the LAN into git

#### The Observability group, card by card

- the **Observability** group, card by card: five cards, one per bundle service, each
  probing its own health path over compose DNS - `http://grafana:3000/api/health`,
  `http://prometheus:9090/-/healthy`, `http://loki:3100/ready`,
  `http://tempo:3200/ready`, `http://mimir:8080/ready`. Those four distroless containers
  ship no in-container healthcheck, so this probe is the only liveness read the stack has
  for them, and a badge pointed anywhere else is caught here
- the same group's links: every href rides a `{{HOMEPAGE_VAR_*}}` token and none carries
  a URL literal (Loki, Tempo and Mimir publish no port, so their two hrefs open
  `{{HOMEPAGE_VAR_GRAFANA_URL}}/explore` rather than a store nobody can reach), and no
  probe bakes a loopback or LAN address
- the group's place on the page: `Observability` has its own `layout` entry, renders as
  one `style: row` band whose `columns` equals the cards it holds, and sits after the
  **Host** group

#### The two GPU cards in the Host group

- both cards query the Prometheus HTTP API over the compose network - `http://prometheus:9090/api/v1/query`
  with the PromQL carried inline - and both badge on `http://prometheus:9090/-/healthy`.
  Neither badges an exporter: `OBSERVABILITY_ENABLED=false` starts no Prometheus, so both
  cards read `down` together with a stack that was never asked to run the bundle, which is
  the same honest signal the **Observability** band gives. A gauge nobody writes is a
  different answer - the query succeeds with an empty vector, so that one row stays blank
  while the badge still says `UP`
- the **Spark fleet GPU** card reads the DCGM series per box: `DCGM_FI_DEV_GPU_UTIL`,
  `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_POWER_USAGE`. One `customapi`
  widget per field, because one widget is one endpoint, and four mappings each: the number
  of boxes reporting that field, reduced from the same response with `format: size`, then
  the three box rows
- no box is named in the file: the fleet target list is generated on the host by
  `//scripts:spark-monitor` into `observability/spark-targets/sparks.json`, which stamps
  every group with `hostname`, so `box 1` / `box 2` / `box 3` are positions in Prometheus'
  own sort of that label, not machines. It is the same rule that keeps `SPARKn_HOST` in
  `.env` instead of a `spark-1.lan` literal in a committed file (see the last bullet below)
- the **evo-t1 host GPU** card reads the four `evo_t1_host_gpu_*` gauges the host sampler
  (`scripts/lib/probes/host_gpu.sh`) writes into the node_exporter textfile directory:
  `evo_t1_host_gpu_utilisation_pct`, `evo_t1_host_gpu_clock_mhz`,
  `evo_t1_host_gpu_power_watts`, `evo_t1_host_gpu_temp_celsius`. The Arc exports no DCGM
  series, so none of these can ride the fleet queries, and `utilisation` is the row that
  may honestly stay blank - the sampler reads it from `intel_gpu_top`, which the box may
  not carry
- that sampler is not a daemon the host has to run: the `host-gpu-sampler` compose
  service, in the same `observability` profile, runs the script every 60 seconds and
  writes `/var/lib/node_exporter/textfile_collector`, which `node_exporter` mounts
  read-only at `/textfile` under `--collector.textfile.directory=/textfile`. So the
  bundle being up is what puts numbers on this card: with the profile off every row
  answers an empty vector, which is the same blank the card shows for a sensor the box
  does not carry

#### Widgets, bookmarks, icons, and search hosts

- no `block` customapi widget declares more than four mappings - the shipped bundle
  slices the list, so a fifth row silently never renders
- a bookmark's value is a list of single-key mappings carrying both `abbr` and `href`;
  written as a plain mapping the entry loads with a name and nothing else, because the
  app drops the keys it did not ask for
- a local `icon:` path is under `/icons/`, the one path the auth middleware exempts from
  the sign-in redirect
- a `search` widget with `provider: custom` carries a url ending in `=`, because v2.4.0
  appends the encoded query to whatever `url` says and has no `{{query}}` token
- a Spark URL in `docker-compose.yml` takes its host from an env var. The boxes are
  off-stack, so compose DNS cannot reach them and a hostname written here names a
  machine nobody owns: `SPARKn_HOST` in `.env` names each box once and compose
  composes the card's probe URL from it (see
  [config-updates.md](config-updates.md#spark-agent-model-group))

The suite also breaks each invariant in a scratch copy, so a check that has stopped
failing fails the build.

### After a recreate: revalidate once

v2.4.0 serves a prerendered page with the settings baked in, so a freshly created
container shows an empty default layout (`initialSettings {}`) until the config is
re-read. Click the refresh button in the header, or:

```sh
curl -k -X POST https://<host>/api/revalidate
```

A plain `restart` keeps the generated page, so day-to-day YAML edits need nothing.
New asset files do need a recreate (`up -d`), since `restart` keeps the old mounts.

### Host stats, and the docker socket

CPU, memory, CPU temperature and disk are host-wide through `/proc`. A network widget
only sees the container's own netns (`lo`/`eth0`) - `/sys/class/net` is namespaced, so
the host Wi-Fi NIC stays invisible even with `/sys` mounted. That tile reads `eth0`.

Those numbers are also series now: `node_exporter` reads the same `/proc` and `/sys`
read-only and `cadvisor` covers the containers, so the tile answers "what is the box doing
now, as the dashboard sees it" and the Grafana board answers "and what was it at 03:00".
The tile survives the bundle being off; the board does not.

Which board, exactly, is catalogued in [observability.md](observability.md) under
`## The dashboards` - four families of them:

- the stack host (`evo-host-taskmanager`, `evo-containers`)
- the DGX Sparks (`evo-sparks-overview`, `evo-spark-host`, `evo-sparks-fleet`)
- the inference backends (`evo-inference-models`, `evo-inference-backends`)
- the bundle itself (`evo-home`, `evo-stack-overview`, `evo-alerts`, `evo-stack-logs`,
  `evo-stack-traces`, `evo-litellm`)

The question-to-page table lives there; this page stays about the dashboard and the
desktops.

The docker socket stays unmounted: service status comes from each service's API, which
avoids handing the dashboard a root-equivalent host credential.

The Hermes card in the
**Host** group is the same pattern (`siteMonitor` of `http://hermes:9119/api/status`);
the Hermes container itself *does* mount the socket — that credential lives there, not
here. See [hermes.md](hermes.md).

### Look

The layout follows the upstream README example - logo plus greeting top-left, boxed
resource tiles, clock, weather and search top-right, cards on a wallpaper.

The
wallpaper (`background.webp`) and the logo (`evo-t1.svg`) live in
`homepage/assets/icons/`, mounted at `/app/public/icons` and served as `/icons/...`.

Homepage's auth middleware exempts only that path from the sign-in redirect, which is
what lets the same wallpaper render on the login page, and is why `favicon` points at
`/icons/evo-t1.svg` too: a tab icon from anywhere else 307s to `/auth/signin`.

`disableIndexing: true` is the whole anti-crawler measure: the app then serves
`/robots.txt` with `User-agent: *` / `Disallow: /`, and writes no robots meta tag into
the page.

It matters only when `STACK_PUBLIC_HOSTS` gives the dashboard a public name -
the page already sits behind the password, and its paths should not reach a crawler
either.

## Kasm Workspaces

- **First boot:** `https://<host>:3000` - run the install wizard once.
- **After install:** the UI is on `https://<host>:4443`. Both ports serve TLS with the
  self-signed certificate Kasm's own installer generates, and plain `http://` reaches
  neither port.
- `KASM_UI_PORT` has to match on **both** sides of the port mapping. The daemon-side
  listener listens on that number, so the mapping is `4443:4443`.
- The image ships default users (`admin@kasm.local` / `user@kasm.local`); change them
  during the wizard.
- Kasm is a privileged Docker-in-Docker container, and privileged whether or not the
  observability bundle is on. The other privileged containers are `cadvisor`, which comes
  up only with the `observability` profile
  ([observability.md](observability.md)), and the opt-in workspace DinD sidecar. Keep Kasm
  LAN-only unless you have decided who may reach the public name
  (see [SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md)).
- Losing the wizard after install is expected: use `:4443`. Resetting Kasm means
  removing the `kasm-data` volume, which destroys all Kasm config.
