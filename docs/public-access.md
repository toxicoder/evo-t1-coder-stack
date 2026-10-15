# Public subdomains

The default shape is LAN-only. Setting `STACK_PUBLIC_HOSTS` additionally serves the same
four services on public names over real TLS. It is purely additive: every LAN route
keeps working.

## The path a public request takes

```text
browser
  |
  v
Traefik (the other machine) -- TLS terminates here on *.overeazy.io
  | plain HTTP, original Host header preserved
  v
nginx `router` sidecar (this box: proxy/router.conf, published on :8080)
  | picks one upstream from the Host header
  v
the service container (homepage:3000 / coder:3000 / kasm:4443 / litellm:4000)
```

- TLS terminates at Traefik. The `router` sidecar holds no certificate.
- Its whole job is picking an upstream from the Host header, and an unmatched Host
  answers `421` rather than a guess, so a mistyped or rewritten Host fails loudly
  instead of landing in the wrong service. A rewritten Host matches no server block
  here, so it also arrives as `421`.
- Kasm is the only hop that speaks TLS to its origin. `proxy_ssl_verify` is off there
  because the certificate is the one Kasm's installer generates and reissues.
- Nothing in this path replaces the LAN routes: `https://<lan-ip>/` still serves the
  dashboard on the self-signed cert, and `https://<lan-ip>:3001` still serves Coder's
  own TLS listener.
- A workspace **app** link (the **LiteLLM** and **Open VS Code Web** buttons) rides the
  coder row of that table. Both `coder_app` blocks set `subdomain = false`, so their
  URL keeps the `/@<owner>/<ws>.<agent>/apps/<slug>` path form and goes to `coder:3000`
  on its way to `host.docker.internal:4000`. A 502 on that link is an app-lane failure
  and `litellm-gmktecbeast.` took no part in it.
- Every `location` adds `X-Evo-Proxy` with the upstream name, and `always` is what
  makes it survive a 502. Read it beside `X-Coder-Request-Id`, which Coder's own proxy
  sets on an answered request: neither header means the request stopped at Traefik or
  Cloudflare, and `421` means the Host header matched no server block here.

## The four names

| Name | `proxy/router.conf` upstream |
|---|---|
| `gmktecbeast.overeazy.io` | `homepage:3000` |
| `coder-gmktecbeast.overeazy.io` | `coder:3000` - plain listener |
| `kasm-gmktecbeast.overeazy.io` | `https://kasm:4443` (`proxy_ssl_verify off`) |
| `litellm-gmktecbeast.overeazy.io` | `litellm:4000` |

## Getting the naming right

- Each name is **one label under the zone**, and each service prefix joins it with a
  **hyphen**.
- A wildcard certificate covers exactly one label, so the dotted two-label form
  (`coder.gmktecbeast.`) has no certificate at the public edge: the browser aborts with
  `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` and Traefik never sees the request. Measured on
  this box - `coder-gmktecbeast.overeazy.io` completes the handshake with the zone's
  `*.overeazy.io` cert, while the dotted form fails with a TLS alert 40 and presents
  no certificate at all.

## What `bootstrap` changes when the names are set

`bazelisk run //scripts:bootstrap` derives:

- `STACK_DASHBOARD_URL`, which compose feeds to `HOMEPAGE_EXTERNAL_URL` so NextAuth
  builds its redirects and Secure cookie from the public origin;
- `STACK_CODER_URL` / `STACK_KASM_URL` / `STACK_LITELLM_URL`, the card `href`s;
- an upgraded `CODER_ACCESS_URL` (the public coder name);
- an extended `HOMEPAGE_ALLOWED_HOSTS` - homepage validates the incoming Host against
  that exact-match list, so an unlisted name fails its host check;
- a Coder certificate whose DNS SANs now carry the public names alongside the existing
  ones. The LAN cert keeps working; in public mode the browser never sees it, since
  Traefik presents real ones.

Set the four names in `.env`, and in `dev-stack.env` too when a dev stack runs beside
the stable one. Then re-run `bootstrap` and recreate the stack you switched. The
commands are in the [README](../README.md#public-subdomains-optional).

## Checking the other machine

This repo cannot verify any of it; check it on the Traefik box.

1. A router per name pointing at `http://<this-box-lan-ip>:8080`.
2. The original Host header preserved - a rewritten one comes back as `421`.
3. Any authentication as the Traefik router's middleware. The sidecar forwards what it
   receives and authenticates nothing, so a name whose router skips the auth middleware
   reaches its container the same way the LAN does. The app path is behind that policy
   like the rest of its name, so an expired session surfaces there too.
4. DNS records for all four names, each one label deep. A missing record shows up as a
   DNS error, a rewritten Host as `421`. All four names resolve Cloudflare-proxied and
   complete the TLS handshake, verified from this box.

## Authelia

- `https://gmktecbeast.overeazy.io/` and the three hyphenated service names 302 to
  `https://authelia.overeazy.io/`: those zones already have an Authelia policy in front
  of them (checked from here; the policy itself lives on the Traefik side). Covering a
  newly named host is an Authelia-side config choice; nothing here adds or requires a
  policy.
- Put LiteLLM behind it and every client breaks: LiteLLM authenticates from the
  `Authorization` header, and header-carried API traffic cannot pass an interactive
  sign-in. Either leave `litellm-gmktecbeast` outside any policy or add an explicit
  bypass - and then `LITELLM_MASTER_KEY` is the only credential in front of an
  endpoint that went from LAN-only to reachable WAN-wide (see
  [SECURITY.md](../SECURITY.md)).
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
