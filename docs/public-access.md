---
title: Public subdomains
description: Serving the same five services on public names over real TLS, additively, with the LAN shape left intact.
tags: [public, tls, traefik, authelia, hermes, operate]
---

**What's on this page**

- The path a public request takes, from the browser to the container
- The naming rule, and what `auto` composes from the parts you set
- What `bootstrap.sh` changes when the names are set
- The Traefik file-provider config the other box needs, pasted as-is
- Checking the other machine (including the Hermes WebSocket), Authelia, and the two follow-ups left by hand

**What this enables**

- Exposing the stack without breaking the LAN routes anyone at home uses
- Telling a router problem apart from an Authelia problem when a name fails
- Putting the five routers on the Traefik box without guessing its timeouts

The default shape is LAN-only. `STACK_PUBLIC_HOSTS=auto` additionally serves the same
five services on public names over real TLS, each name composed from the parts you set
once. It is purely additive: every LAN route keeps working.

## The path a public request takes

```text
browser
  |
  v
Cloudflare (orange-cloud proxy; WebSockets on by default)
  |
  v
Traefik (the other LAN server) -- TLS terminates here on *.overeazy.io; Authelia middleware
  | plain HTTP, original Host header preserved
  v
nginx `router` sidecar (this box: the conf STACK_ROUTER_CONF names, published on :8080)
  | picks one upstream from the Host header
  v
the service container (homepage:3000 / coder:3000 / kasm:4443 / litellm:4000 / hermes:9119)
```

- TLS terminates at Traefik. The `router` sidecar holds no certificate.
- Cloudflare proxies the name (orange cloud) in front of Traefik. WebSockets are on
  there by default, which is what the Hermes Chat tab needs.
- The router's whole job is picking an upstream from the Host header, and an unmatched
  Host answers `421` rather than a guess, so a mistyped or rewritten Host fails loudly
  instead of landing in the wrong service. A rewritten Host matches no server block
  here, so it also arrives as `421`.
- Kasm is the only hop that speaks TLS to its origin. `proxy_ssl_verify` is off there
  because the certificate is the one Kasm's installer generates and reissues. Hermes,
  like Homepage, Coder and LiteLLM, is plain HTTP at the origin (`http://hermes:9119`).
- Nothing in this path replaces the LAN routes: `https://<lan-ip>/` still serves the
  dashboard on the self-signed cert, `https://<lan-ip>:3001` still serves Coder's
  own TLS listener, and `http://<STACK_LAN_HOST>:9119` still serves Hermes.
- A workspace **app** link (the **LiteLLM** and **Open VS Code Web** buttons) rides the
  coder row of that table. Both `coder_app` blocks set `subdomain = false`, so their
  URL keeps the `/@<owner>/<ws>.<agent>/apps/<slug>` path form and goes to `coder:3000`
  on its way to `host.docker.internal:4000`. A 502 on that link is an app-lane failure
  and `litellm-gmktecbeast.` took no part in it.
- Every `location` adds `X-Evo-Proxy` with the upstream name, and `always` is what
  makes it survive a 502. Read it beside `X-Coder-Request-Id`, which Coder's own proxy
  sets on an answered request: neither header means the request stopped at Traefik or
  Cloudflare, and `421` means the Host header matched no server block here.

## The composed names

These are what the shipped defaults compose. The operator sets the parts, not these
strings: the grammar is `<service>-<environment>-<suffix>.<base>`, always ONE label
under the zone.

| Name | Router upstream |
|---|---|
| `gmktecbeast.overeazy.io` | `homepage:3000` |
| `coder-gmktecbeast.overeazy.io` | `coder:3000` - plain listener |
| `coder-dev-gmktecbeast.overeazy.io` | `coder:3000` - the dev stack's own name |
| `kasm-gmktecbeast.overeazy.io` | `https://kasm:4443` (`proxy_ssl_verify off`) |
| `litellm-gmktecbeast.overeazy.io` | `litellm:4000` |
| `hermes-gmktecbeast.overeazy.io` | `hermes:9119` |

The dev row is what `bazelisk run //scripts:dev-stack -- up` composes for the
`evo-t1-dev` project: that command applies `STACK_ENV_LABEL=dev` when neither the shell
nor the env file already sets a label, and only for that project, so
`--project-name evo-t1-review` gets none. A label goes on every name, so that stack's
dashboard is `dev-gmktecbeast.overeazy.io` too, and all five need their own Traefik
routers (see below). `bazelisk run //scripts:prod-stack -- up` never invents a label.

Hermes is the same additive hop as the other four. Traefik forwards
`http://<this-box-lan-ip>:8080` with the original Host, and the router sends that
Host to `http://hermes:9119`. The LAN URL `http://<STACK_LAN_HOST>:9119` stays.
HTTP basic auth on the dashboard stays too; Authelia is the extra public gate.
See [hermes.md](hermes.md).

## Getting the naming right

`scripts/lib/domain.sh` owns the grammar and every part is normalized before it is
joined, so a value copied out of a browser bar cannot leak into an origin or a
`server_name`:

- `STACK_DOMAIN_BASE` (default `overeazy.io`) is the zone the edge terminates TLS for;
  `STACK_SUBDOMAIN_SUFFIX` (default `gmktecbeast`) is this box's label, shared by every
  name.
- `STACK_CODER_NAME` / `STACK_KASM_NAME` / `STACK_LITELLM_NAME` / `STACK_HERMES_NAME`
  (defaults `coder` / `kasm` / `litellm` / `hermes`) are the service prefixes.
  `STACK_DASHBOARD_NAME` is empty by default, which puts the dashboard on the zone apex.
- `STACK_ENV_LABEL` is empty for the stable stack and sits **after** the service prefix.
  Two reasons: the one-label rule below rules the dotted form out anyway, and
  `classify_public_entry` in `scripts/lib/bootstrap.sh` routes an entry by its service
  prefix, so `coder-dev-box.example.com` is Coder while `dev-coder-box.example.com`
  falls through to the dashboard.
- The shape is load-bearing: each name is **one label under the zone**, and each service
  prefix joins it with a **hyphen**. A wildcard certificate covers exactly one label, so
  the dotted two-label form (`coder.gmktecbeast.`) has no certificate at the public edge:
  the browser aborts with `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` and Traefik never sees the
  request. Measured on this box - `coder-gmktecbeast.overeazy.io` completes the handshake
  with the zone's `*.overeazy.io` cert, while the dotted form fails with a TLS alert 40
  and presents no certificate at all.

`STACK_PUBLIC_HOSTS` has three states, and only the middle one composes:

- empty is LAN-only;
- `auto` composes the five names from the parts above;
- a comma-separated list is used verbatim, which is how you pin a name by hand (leave
  `STACK_PUBLIC_HOSTS_MODE` empty, or that key keeps re-deriving).

A part that cannot be a DNS label composes nothing: that service is left out of the list
rather than sent as an empty entry, and a missing zone keeps the whole stack LAN-only.

## What `bootstrap` changes when the names are set

`bazelisk run //scripts:bootstrap` derives:

- `STACK_DASHBOARD_URL`, which compose feeds to `HOMEPAGE_EXTERNAL_URL` so NextAuth
  builds its redirects and Secure cookie from the public origin;
- `STACK_CODER_URL` / `STACK_KASM_URL` / `STACK_LITELLM_URL` / `STACK_HERMES_URL`,
  the card `href`s. A `hermes-*` or `hermes.*` entry is what fills `STACK_HERMES_URL`.
  Compose copies that value into `HERMES_DASHBOARD_PUBLIC_URL`, the Host and Origin
  the Chat tab checks;
- an upgraded `CODER_ACCESS_URL` (the public coder name);
- an extended `HOMEPAGE_ALLOWED_HOSTS` - homepage validates the incoming Host against
  that exact-match list, so an unlisted name fails its host check;
- a Coder certificate whose DNS SANs now carry the public names alongside the existing
  ones. The LAN cert keeps working; in public mode the browser never sees it, since
  Traefik presents real ones;
- `STACK_PUBLIC_HOSTS_MODE=auto`, which records that the names are derived. Under `auto`
  the parts are the source of truth and `STACK_PUBLIC_HOSTS` is output only, so a list
  edited by hand there is ignored and bootstrap prints a `note:` naming the key to
  clear. It clears itself on the LAN-only and explicit-list paths;
- the router's vhost table: `proxy/router.conf.template` is rendered into
  `proxy/router.gen.conf` (gitignored) and `STACK_ROUTER_CONF=router.gen.conf` is
  written, because compose mounts `./proxy/${STACK_ROUTER_CONF:-router.conf}`. The
  `warn_missing_router_hosts` check runs against that rendered file, so a name the
  table does not answer is reported before the recreate rather than as a `421` after
  it.

Set the naming parts in `.env` and put `auto` in `STACK_PUBLIC_HOSTS` (`.env.sample`
documents every part and shows the explicit-list shape beside it), and in
`dev-stack.env` too when a dev stack runs beside the stable one. Then re-run `bootstrap`
and recreate the stack you switched. The commands are in the [README](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/README.md#public-subdomains-optional).

## Traefik configuration

Nothing in this repo configures Traefik. This is the file the other box needs: drop it
in the directory that box's `providers.file.directory` watches and Traefik picks it up
without a restart. The shape below is the one Traefik v2 and v3 both read; the
entryPoint name, the certificate and the middleware name have to match what that box
already defines, so treat those three as the values to align, not as new requirements.

```yaml
# evo-t1.yml -- file-provider dynamic config for the EVO-T1 stack.
# Replace <this-box-lan-ip> with the LAN address of this box.
http:
  routers:
    evo-t1-dashboard:
      rule: "Host(`gmktecbeast.overeazy.io`)"
      entryPoints: [websecure]
      service: evo-t1-router
      middlewares: [authelia@file]
      tls: {}
    evo-t1-coder:
      rule: "Host(`coder-gmktecbeast.overeazy.io`)"
      entryPoints: [websecure]
      service: evo-t1-router
      middlewares: [authelia@file]
      tls: {}
    evo-t1-kasm:
      rule: "Host(`kasm-gmktecbeast.overeazy.io`)"
      entryPoints: [websecure]
      service: evo-t1-router
      middlewares: [authelia@file]
      tls: {}
    evo-t1-litellm:
      rule: "Host(`litellm-gmktecbeast.overeazy.io`)"
      entryPoints: [websecure]
      service: evo-t1-router
      # No Authelia on this one, on purpose: LiteLLM authenticates from the
      # Authorization header, and header-carried API traffic cannot pass an
      # interactive sign-in. LITELLM_MASTER_KEY is the credential here.
      tls: {}
    evo-t1-hermes:
      rule: "Host(`hermes-gmktecbeast.overeazy.io`)"
      entryPoints: [websecure]
      service: evo-t1-router
      middlewares: [authelia@file]
      tls: {}

  services:
    evo-t1-router:
      loadBalancer:
        # One backend for all five names: the nginx `router` sidecar on this box,
        # which picks the upstream from the Host header. Never :9119, :3001 or
        # :4000 -- a router aimed at a container port skips this box's vhost
        # table and its Host header entirely.
        servers:
          - url: "http://<this-box-lan-ip>:8080"
        passHostHeader: true
        serversTransport: evo-t1-long

  serversTransports:
    evo-t1-long:
      forwardingTimeouts:
        # 0 = never cut a request off waiting for upstream response headers,
        # which is what a slow first token from LiteLLM needs.
        responseHeaderTimeout: "0s"
        # One transport for every name at Kasm's floor; see the timeouts below.
        idleConnTimeout: "3600s"
```

- `passHostHeader: true` is the line that makes this work at all. Without it Traefik
  sends the upstream URL's host, no `server_name` matches, and this box answers `421`.
- **A published dev stack needs its own routers here.** The `dev-stack.env` behind
  `bazelisk run //scripts:dev-stack` moves every published port by 10000 (the recipe is
  in the
  [README](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/README.md#give-the-dev-stack-its-own-ports)),
  so that stack's `router` answers on `18080` (`STACK_PROXY_HTTP_PORT` default 8080) and
  its names carry the environment label
  (`coder-dev-gmktecbeast.overeazy.io`). A dev name is a different `Host` rule and a
  different backend port: add a router per dev name to the file above aimed at
  `http://<this-box-lan-ip>:18080`, and the DNS records for those names have to exist
  too, or the browser fails before this box is ever asked.
- `authelia@file` is a placeholder for the Authelia middleware that box already
  declares. Name it exactly as that box names it - a middleware created by labels is
  `authelia@docker`, and a name Traefik cannot resolve fails the router rather than
  serving it unauthenticated. The four interactive names carry it; LiteLLM must not.
- `tls: {}` means "serve whatever certificate matches the SNI", which is the zone's
  `*.overeazy.io` pair. Add `tls: { certResolver: <name> }` if that box issues through
  an ACME resolver instead. SNI has to be the public name itself - the wildcard covers
  exactly one label, which is why the hyphenated one-label form is the only one that
  handshakes.
- **WebSockets need nothing here.** Traefik forwards `Upgrade` and `Connection`
  as-is; there is no `protocol: websocket` to set and no middleware to add. The Hermes
  Chat tab's `/api/pty` and `/api/ws` open on that alone. They fail only when
  something in between drops the upgrade, and Cloudflare has WebSockets on by
  default, so the usual suspect is an Authelia middleware configured to buffer.
- **Timeouts.** `proxy/router.conf` on this box already holds per-service read
  timeouts - dashboard 60s, coder and hermes 300s, LiteLLM 600s, Kasm 3600s - so
  Traefik must not be the shorter link. One transport for all five at `3600s` is the
  simple choice because Kasm needs that floor anyway. To cap each tier separately,
  declare one `loadBalancer` service per tier, each pointing at the same
  `http://<this-box-lan-ip>:8080` with `passHostHeader: true` and its own transport
  (`evo-t1-coder` / `evo-t1-hermes` at `300s`, `evo-t1-litellm` at `600s`,
  `evo-t1-kasm` at `3600s`), and point each router at its own service. If a session
  dies at about a minute with the page still loaded, check the client-facing side
  too: an entryPoint's `transport.respondingTimeouts.readTimeout` (default 60s) and
  `idleTimeout` (default 180s) apply to the browser-to-Traefik hop.
- SearXNG is deliberately absent. It stays LAN-only on `:8181`, which is where the
  workspaces reach it through `host.docker.internal`; putting it behind Traefik would
  expose a search box that has no authentication of its own.

## Checking the other machine

This repo cannot verify any of it; check it on the Traefik box.

1. A router per name pointing at `http://<this-box-lan-ip>:8080`, including
   `hermes-gmktecbeast.overeazy.io`. That backend is `:8080` with the original Host,
   the same as the other four - not `:9119`. A router aimed at `:9119` skips this
   box's vhost. The file in [Traefik configuration](#traefik-configuration) is that
   config; diff what the box runs against it.
2. The original Host header preserved - a rewritten one comes back as `421`.
3. Any authentication as the Traefik router's middleware. Authelia already fronts
   `hermes-gmktecbeast.overeazy.io` (the name 302s), the same interactive policy as
   the homepage and Coder names. The sidecar forwards what it receives and
   authenticates nothing, so a name whose router skips the auth middleware reaches
   its container the same way the LAN does. The app path is behind that policy
   like the rest of its name, so an expired session surfaces there too.
4. DNS records for all five names, each one label deep and Cloudflare-proxied (orange
   cloud). WebSockets are on there by default. A missing record shows up as a DNS
   error, a rewritten Host as `421`. Homepage, Coder, Kasm and LiteLLM resolve
   that way and complete the TLS handshake, checked from this box; the Hermes
   name is the same zone and the same proxy.
5. WebSocket `Upgrade` forwarded by Traefik and Authelia on the Hermes router. The
   Chat tab uses `/api/pty` and `/api/ws`, and Hermes sends a keepalive every 20
   seconds. A proxy that drops `Upgrade` loads the page and then fails the tab.

## Authelia

- `https://gmktecbeast.overeazy.io/`, `coder-gmktecbeast.overeazy.io`,
  `kasm-gmktecbeast.overeazy.io` and `hermes-gmktecbeast.overeazy.io` 302 to
  `https://authelia.overeazy.io/`. Homepage, Coder, Kasm and Hermes are interactive
  sessions, and the Hermes policy is already in place. Covering a newly named host
  is an Authelia-side config choice; nothing here adds or requires a policy. Hermes
  is not an API bypass: it stays behind that interactive policy, and after Authelia
  it asks for its own HTTP basic auth. Both prompts on the public URL are expected.
- Put LiteLLM behind it and every client breaks: LiteLLM authenticates from the
  `Authorization` header, and header-carried API traffic cannot pass an interactive
  sign-in. Either leave `litellm-gmktecbeast` outside any policy or add an explicit
  bypass - and then `LITELLM_MASTER_KEY` is the only credential in front of an
  endpoint that went from LAN-only to reachable WAN-wide (see
  [SECURITY.md](https://github.com/toxicoder/evo-t1-coder-stack/blob/main/SECURITY.md)).
- Workspace agents never reach Authelia either way. The template rewrites the agent URL
  to `http://host.docker.internal:3002`, the plain listener published through
  `CODER_AGENT_TUNNEL_PORT`, so agent traffic stays on the box.

## Two follow-ups, both by hand

1. Workspaces created before public mode existed need a template re-push plus a
   restart, to pick up the template's `coder_agent_url` variable (default
   `http://host.docker.internal:3002`). That variable is what keeps agents dialing the
   local plain listener whatever the access URL says.
2. Kasm stores its connection endpoints in its own setup database (first-boot wizard or
   admin UI), so the endpoint has to change there too or streams keep dialing the LAN
   address.
