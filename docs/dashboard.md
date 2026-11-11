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

A card per service, with status pulled from each service's own API over the compose
network - `http://coder:3000`, `http://litellm:4000`, `http://ollama:11434`,
`http://hermes:9119/api/status` - so nothing here needs a daemon credential. The
header carries boxed tiles for host CPU, memory, CPU temperature, disk and `eth0`
throughput, beside the clock (date and 24-hour time), local weather (open-meteo,
keyless) and a search box.

That box asks the stack's own SearXNG rather than a public engine, so a search from the
dashboard goes to the same instance the workspace agents and Hermes dial. The **Host**
group carries the matching card: its badge probes `http://searxng:8181/healthz`, which
answers from the instance's own state without querying an upstream engine, and its three
fields come from `GET /config` on the same port - the release tag, and the two switches
that decide whether the box is a public instance (`limiter`, `public_instance`). The
dashboard never asks the instance for result rows: a polled `/search` would park engines
on the rate-limit and CAPTCHA walls, which is why that probe is
`bazelisk run //scripts:search-check`'s job, run on demand. See
[troubleshooting.md](troubleshooting.md).

Card `href`s come from `STACK_CODER_URL` / `STACK_KASM_URL` / `STACK_LITELLM_URL` /
`STACK_HERMES_URL`, which default to LAN URLs built from `STACK_LAN_HOST` and the
port variables. Change a port or re-detect the LAN IP and the links follow; set `auto`
in `STACK_PUBLIC_HOSTS` and the cards follow the names bootstrap composes from the
naming parts ([public-access.md](public-access.md)). The Hermes card
follows `STACK_HERMES_URL` when bootstrap sets it, and stays on
`http://<STACK_LAN_HOST>:9119` when that key is empty. See [hermes.md](hermes.md).
The search card and the header box share `STACK_SEARCH_URL`. The router composes public
names for the dashboard, coder, kasm, litellm and hermes only, so search has no public
name to fall to: leave the key empty and both stay on the LAN, where the card's status
still reports for anyone who can reach the dashboard.

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

### What the gate checks

`//:validate` proves these files parse. `tests/homepage_config_check.py` reads them the
way the app does and fails on the mistakes that parse happily:

```sh
bazelisk test //tests:bats_homepage_config_test
```

- every `{{HOMEPAGE_VAR_*}}` token has a key in `docker-compose.yml`, and every
  `HOMEPAGE_VAR_*` key is used by some config file
- every service and bookmark group has a `layout` entry, and every `layout` key names a
  real group; a `style: row` group's `columns` equals the number of cards it holds
- a card `href` is a token or a public URL, never a compose service name: the browser
  cannot resolve `http://coder:3000`, only the dashboard server can
- a `siteMonitor` or widget `url` names a compose service or a token, never a loopback
  or LAN-address literal, which would bake the LAN into git
- no `block` customapi widget declares more than four mappings - the shipped bundle
  slices the list, so a fifth row silently never renders
- a bookmark's value is a list of single-key mappings carrying both `abbr` and `href`;
  written as a plain mapping the entry loads with a name and nothing else, because the
  app drops the keys it did not ask for
- a local `icon:` path is under `/icons/`, the one path the auth middleware exempts from
  the sign-in redirect
- a `search` widget with `provider: custom` carries a url ending in `=`, because v2.4.0
  appends the encoded query to whatever `url` says and has no `{{query}}` token

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
what lets the same wallpaper render on the login page, and is why `favicon` points at
`/icons/evo-t1.svg` too: a tab icon from anywhere else 307s to `/auth/signin`.

`disableIndexing: true` is the whole anti-crawler measure: the app then serves
`/robots.txt` with `User-agent: *` / `Disallow: /`, and writes no robots meta tag into
the page. It matters only when `STACK_PUBLIC_HOSTS` gives the dashboard a public name -
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
- Kasm is a privileged Docker-in-Docker container and the only **always-on** privileged
  service in this stack - the other privileged container is the opt-in workspace DinD
  sidecar. Keep Kasm LAN-only unless you have decided who may reach the public name
  (see [SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md)).
- Losing the wizard after install is expected: use `:4443`. Resetting Kasm means
  removing the `kasm-data` volume, which destroys all Kasm config.
