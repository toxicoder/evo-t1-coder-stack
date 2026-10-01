# Security

This stack's default shape assumes a trusted LAN or VPN. Its own TLS is self-signed —
the dashboard's proxy cert and the cert Coder serves on :3001; it has no reverse proxy
or SSO of its own. Publishing the services on public names through the external
Traefik (README, "Public subdomains (optional)") is a supported opt-in rather than a
prohibition, and it changes this threat model: TLS then comes from real certificates on
that machine, and every access decision beyond the application's own credential is
whatever Traefik, Cloudflare and Authelia are configured to enforce — none of which this
repo can verify.

- **Network exposure.** Coder (:3001) and LiteLLM (:4000) bind to the host for
  LAN use. Coder's published port carries TLS (the self-signed cert
  `bootstrap.sh` issues); LiteLLM stays plain HTTP, so its traffic is not
  encrypted in transit. Reach them from outside the LAN through the supported path —
  the `router` sidecar behind the external Traefik, which brings real TLS and whatever
  proxy-side policy you configure — not by ad-hoc port-forwarding, which skips both.
  LiteLLM requires `LITELLM_MASTER_KEY` for every request; Coder has its own login, and
  once either name resolves publicly assume it is being probed.
- **Public exposure.** With `STACK_PUBLIC_HOSTS` set, Coder and the dashboard can be
  reachable from the WAN. Keep the Coder login strong: that account is the site admin
  and the control plane it authenticates to creates containers on this host's docker
  socket. The dashboard's NextAuth password (`HOMEPAGE_AUTH_PASSWORD`) stays the only
  gate unless an Authelia policy covers the new names too, and that policy is an
  Authelia-side choice, not something this stack configures. `LITELLM_MASTER_KEY` is
  the sole credential on the public model endpoint — if Authelia is not exempting that
  host (it must not gate `Authorization`-header API traffic), a leaked or weak master
  key exposes the local iGPU models and the Spark boxes behind it, since that proxy was
  LAN-oriented and is now WAN-reachable. The `router` sidecar itself publishes plain HTTP
  (`${STACK_PROXY_HTTP_PORT:-8080}`) and enforces no policy beyond refusing an unknown
  Host: on the LAN, sending a matching Host header to that port reaches the same upstreams
  without Traefik or Authelia in the path, so treat 8080 as a LAN-only port.
- **Ollama is internal-only.** IPEX-LLM Ollama listens on 11434 inside the
  compose network only and is deliberately not published to the host.
  Never add a `11434:11434` port mapping.
- **Dashboard.** The Homepage container publishes no port; `homepage-proxy`
  owns :80 / :443 with a self-signed cert that `bootstrap.sh` issues, so the
  encryption is real but untrusted, and the redirect on :80 is the only thing
  keeping the dashboard off plain HTTP. Homepage v2's password gate
  (`HOMEPAGE_AUTH_PASSWORD`) is a single shared password with no rate limiting
  — leave it enabled, since the dashboard enumerates every service on the box.
  The dashboard is handed the LAN IP and `LITELLM_MASTER_KEY` in its
  environment, so treat the homepage container as holding LiteLLM credentials.
- **Secrets.** `.env` is git-ignored. `.env.sample` / `.env.example` ship
  only `change-me-*` placeholders. `scripts/bootstrap.sh` generates fresh
  values; rotate any value that was ever shared. Never commit `.env`, API
  keys, or SSH material. `proxy/certs/` is git-ignored too — the private key
  never enters git.
- **The push token.** `scripts/push-template.sh` cannot use a CLI session (the
  public API is gated by Authelia, which answers unauthenticated CLI probes with an
  HTML page), so it mints an API key by inserting a row into the stack's own Postgres
  — the same route `coder reset-password` takes, and it needs docker access to the
  database container, which is already root-equivalent here. The key is scoped
  `coder:all`, so treat it as you would an admin token: it is named
  `stack-template-push`, lives for `CODER_PUSH_TOKEN_MINUTES` (default 10) minutes, is
  deleted on the way out including on a failed or interrupted run, and is never
  printed. If a run is SIGKILLed mid-push the row survives until it expires; check
  with `docker compose exec db psql -U coder -d coder -c "select id, token_name,
  scopes, expires_at from api_keys where login_type = 'token';"`.
- **Metrics stay on the host.** The Coder control plane publishes Prometheus
  metrics on 2112, mapped to `127.0.0.1` only, so a scrape needs a shell on the
  stack host. LiteLLM's `/metrics` sits behind `LITELLM_MASTER_KEY` like every
  other LiteLLM endpoint — keep it that way, since the metrics name your model
  aliases and traffic volumes.
- **Workspace credentials.** The LiteLLM master key reaches each workspace as the
  `LITELLM_API_KEY` environment variable, which the startup script injects into the
  rendered `~/.grok/config.toml` (the key lives in the file as an `env_key`
  reference, so nothing secret is written to disk by the template). It is also shown
  redacted in `coder_metadata.workspace_info`. Anyone with that key can use every
  alias, including the Spark boxes, so treat a workspace as holding LAN credentials.
- **Spark endpoints.** `SPARK1_OPENAI_URL` / `SPARK2_OPENAI_URL` point off-box at
  vLLM servers. vLLM accepts any non-empty bearer token unless it was started with
  `--api-key`, so an unset `SPARK_n_API_KEY` means the only thing gating that endpoint
  is LAN reachability. Set the keys to match how the servers were launched.
- **Kasm is privileged (DinD).** Kasm runs with `privileged: true` because it
  uses Docker-in-Docker to stream containers, which makes it root-equivalent on
  the host kernel. It is the only *always-on* privileged service here; the other
  is the opt-in workspace DinD sidecar below. Treat it as high-trust: keep it
  LAN-only — publishing its public name puts a privileged container behind nothing
  but Kasm's own login unless Authelia covers that host — and review image updates
  before pulling a new tag.
- **Workspace DinD sidecars are privileged too.** With the template's `dind`
  toggle on, a workspace gets its own `docker:29.8.1-dind` container running
  `privileged: true` — the same root-equivalent-on-the-host-kernel standing Kasm
  has, so a compromised workspace reaches the host kernel and the blast radius
  widens from the workspace to the machine. The daemon is started with
  `DOCKER_TLS_CERTDIR=`, which means no TLS and no authentication on
  `tcp://0.0.0.0:2375`; what contains that is the per-workspace bridge network
  (`coder-<wsid>-dind`) — no published host port, and two workspaces never share a
  network, because a shared one would let each reach the other's daemon and
  therefore each other's builds. That network is deliberately not `internal` — an
  internal network has no NAT, which would break the workspace's
  `host.docker.internal` route to the Coder agent listener — so the isolation is
  simply that nothing else is attached to it and nothing is published to the host.
  Keep the toggle off unless someone is actually building containers. See README,
  "Coder workspace template".
- **The Grok Build profile volume is per-user, not host-wide.** Each workspace mounts its
  owner's `grok-profile-<owner-id>` volume read-write at `/home/coder/.grok`, keyed by
  workspace **owner** id, so one human's cross-workspace state sharing is the intent and no
  other user's workspace is ever configured to mount it. The accepted cost is that the
  SQLite memory/index files in there are opened live by every holder, so concurrent writers
  can race; nothing credential-bearing lives in `~/.grok` either, because `config.toml`
  names `LITELLM_API_KEY` through `env_key` and the key itself travels in the workspace
  environment. See README, "Grok Build state: one shared profile per user".
- **Workspace code-server.** Each workspace runs Coder's code-server fork on
  13337 with `--auth none`, published as a `coder_app` with `share = "owner"`
  and `subdomain = false` (this stack sets no `CODER_WILDCARD_ACCESS_URL`, so
  only path-based routing is available). It listens on all interfaces inside
  the workspace; access control is the Coder app proxy plus Authelia/Cloudflare
  in front of the public URL. Extension installs are manual from Open VSX;
  neither editor auto-installs them.
- **Reporting.** Report vulnerabilities by opening an issue marked
  `security`; please do not disclose working exploits publicly.
