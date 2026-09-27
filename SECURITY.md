# Security

This stack assumes a trusted LAN or VPN. The only TLS in it is the self-signed
certificate on the dashboard; there is no proper reverse proxy or SSO.

- **Network exposure.** Coder (:3001) and LiteLLM (:4000) bind to the host for
  LAN use. Do not port-forward them to the internet. LiteLLM requires
  `LITELLM_MASTER_KEY` for every request; Coder has its own login, but a
  public Coder instance should not be run from this stack.
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
- **Kasm is privileged (DinD).** Kasm runs with `privileged: true` because it
  uses Docker-in-Docker to stream containers. Treat it as high-trust: keep it
  LAN-only and review image updates before pulling a new tag.
- **Reporting.** Report vulnerabilities by opening an issue marked
  `security`; please do not disclose working exploits publicly.
