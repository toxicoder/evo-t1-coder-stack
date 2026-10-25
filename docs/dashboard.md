---
title: Dashboard and desktops
description: "The Homepage dashboard and Kasm Workspaces: what each card reads, how the password is issued, and how a desktop gets streamed."
tags: [homepage, kasm, dashboard, operate]
---

**What's on this page**

- What each dashboard card shows and which API it reads
- The header tiles: CPU, memory, temperature, disk, interface throughput
- The password gate, the proxy in front of it, and how to rotate the password
- Kasm's wizard-and-UI port pair, and what resetting it destroys

**What this enables**

- Reading the box's health from one page without a shell
- Fixing a card that reports down when the service itself is up

Two services that read the box rather than serve code: the Homepage dashboard (the
landing page) and Kasm Workspaces (streamed desktops).

## Homepage dashboard

### What it shows

A card per service, with status pulled from each service's own API over the compose
network - `http://coder:3000`, `http://litellm:4000`, `http://ollama:11434`,
`http://hermes:9119/api/status` - so nothing here needs a daemon credential. The
header carries boxed tiles for host CPU, memory, CPU temperature, disk and `eth0`
throughput, beside the clock, local weather (open-meteo, keyless) and a DuckDuckGo
search.

Card `href`s come from `STACK_CODER_URL` / `STACK_KASM_URL` / `STACK_LITELLM_URL` /
`STACK_HERMES_URL`, which default to LAN URLs built from `STACK_LAN_HOST` and the
port variables. Change a port or re-detect the LAN IP and the links follow; set
`STACK_PUBLIC_HOSTS` and the cards follow the public names. The Hermes card
follows `STACK_HERMES_URL` when bootstrap sets it, and stays on
`http://<STACK_LAN_HOST>:9119` when that key is empty. See [hermes.md](hermes.md).

### Login

`https://<host>/` serves the dashboard behind a self-signed certificate that
`scripts/bootstrap.sh` issues, so expect a one-time browser warning. Port 80 redirects
to HTTPS.

The password gate is homepage v2's built-in one, and it is worth keeping: the page
lists every service on the box. `HOMEPAGE_AUTH_PASSWORD` holds the plaintext, because
homepage hashes that env var itself but still needs the value.

```sh
bazelisk run //scripts:dashboard-password
```

```sh
bazelisk run //scripts:dashboard-password -- --prompt
```

Either form rewrites `.env`, recreates the container and verifies the new value landed.
The script's job is keeping the secret out of shell history, `ps` and git, and leaving
`.env` at mode 600.

### Config files

`homepage/config/*.yaml` plus `custom.css` are bind-mounted read-only, so `git diff`
stays the record of dashboard changes, and the directory itself has to stay writable
because the app creates `logs/` inside it. A new config file (`kubernetes.yaml`, ...)
needs its own mount line in `docker-compose.yml` before the app sees it.

`custom.css` lives in `/app/config` and is served by the allow-listed
`/api/config/custom.css` route. It styles the sign-in page too, so keep internal
hostnames out of it.

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

The docker socket stays unmounted: service status comes from each service's API, which
avoids handing the dashboard a root-equivalent host credential. The Hermes card in the
**Host** group is the same pattern (`siteMonitor` of `http://hermes:9119/api/status`);
the Hermes container itself *does* mount the socket — that credential lives there, not
here. See [hermes.md](hermes.md).

### Look

The layout follows the upstream README example - logo plus greeting top-left, boxed
resource tiles, clock, weather and search top-right, cards on a wallpaper. The
wallpaper (`background.webp`) and the logo (`evo-t1.svg`) live in
`homepage/assets/icons/`, mounted at `/app/public/icons` and served as `/icons/...`.
Homepage's auth middleware exempts only that path from the sign-in redirect, which is
what lets the same wallpaper render on the login page.

## Kasm Workspaces

- **First boot:** `https://<host>:3000` - run the install wizard once.
- **After install:** the UI is on `https://<host>:4443`. Both ports serve TLS with the
  self-signed certificate Kasm's own installer generates, and plain `http://` reaches
  neither port.
- `KASM_UI_PORT` has to match on **both** sides of the port mapping. The daemon-side
  listener listens on that number, so the mapping is `4443:4443`.
- The image ships default users (`admin@kasm.local` / `user@kasm.local`); change them
  during the wizard.
- Kasm is a privileged Docker-in-Docker container and the only **always-on** privileged
  service in this stack - the other privileged container is the opt-in workspace DinD
  sidecar. Keep Kasm LAN-only unless you have decided who may reach the public name
  (see [SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md)).
- Losing the wizard after install is expected: use `:4443`. Resetting Kasm means
  removing the `kasm-data` volume, which destroys all Kasm config.
