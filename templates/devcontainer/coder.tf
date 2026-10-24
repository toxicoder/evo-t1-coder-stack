variable "image" {
  type        = string
  description = "Image for the *workspace* container — the one the agent runs in and where the repo is cloned. The dev container itself is defined by the repo's own .devcontainer/devcontainer.json and built on the DinD sidecar, so this image never decides the toolchain inside the editor. Build the golden image with scripts/build-dev-image.sh; a bare Ubuntu still boots but without the Docker CLI, Node or the Grok CLI."
  default     = "evo-t1-dev:latest"
}

variable "repo_url" {
  type        = string
  description = "Default for the create form's Git repository field — the clone source in either mode: built into a dev container when the dev-container toggle is on, opened directly by the editor when it is off. With the toggle on the repo must carry .devcontainer/devcontainer.json, otherwise that build fails and no editor appears; with it off any repo works. The clone runs as the workspace user and consults whatever HTTPS credential it finds (a credential helper, ~/.git-credentials, or the external-auth account connected in Coder — which must also GRANT the repo, or the fetch is refused; a `git@`/`ssh://` URL gets none of these)."
  default     = "https://github.com/coder/coder"
}

variable "grok_default_model" {
  type        = string
  description = "Grok catalog key used for new sessions. The Qwen2.5-Coder weights on the Arc Ollama return tool calls as plain text, so keep this on a Spark vLLM alias; the Arc qwen2.5:7b (the `chat` alias) does emit structured tool calls and is a viable offline substitute."
  default     = "agent"
}

variable "litellm_url" {
  type        = string
  description = "LiteLLM proxy base URL reachable from the workspace (via the Docker host gateway)."
  default     = "http://host.docker.internal:4000/v1"
}

variable "litellm_key" {
  type        = string
  description = "LiteLLM master key handed to the workspace as LITELLM_API_KEY for Grok Build, Cline and Roo."
  default     = ""
  sensitive   = true
}

variable "coder_agent_url" {
  type        = string
  description = "URL workspace agents dial to reach the Coder server. Defaults to the plain listener via the Docker host gateway so agents stay on-box even when CODER_ACCESS_URL is a public hostname behind the reverse proxy; a public URL would hairpin agent traffic through Cloudflare and Authelia, which rejects token-only requests. Empty string keeps the provider-rendered access URL, which is only correct on a dev box whose access URL is directly routable from workspaces."
  default     = "http://host.docker.internal:3002"
}

# Was a bool (`grok_profile_share`) until the private mode needed a third state to
# mean "no nested mount at all". It stays a plain string with exactly two values
# because scripts/push-template.sh may forward it with `--var grok_profile_mode`,
# and a template variable cannot take a value the create form has no option for.
variable "grok_profile_mode" {
  type        = string
  description = "How a workspace gets its ~/.grok. 'shared' = one per-user Docker volume (grok-profile-<owner-id>) mounted at /home/coder/.grok, nested inside that workspace's own home volume — exactly what the old grok_profile_share = true did: everything the CLI keeps there (config.toml, MCP caches, memory-v2, skills, a self-installed CLI) is written once and read by every workspace this user owns, and survives a rebuild, with the last workspace to start re-rendering the shared config.toml. 'private' = no nested mount, so this workspace gets its own private ~/.grok on its own home volume, and that workspace's config.toml, MCP caches, memory and skills die with it. Per-user, not host-wide, in shared mode: the volume name is keyed by owner id, so another user's workspaces never see it. The mount covers the workspace container only — a dev container built on the DinD sidecar keeps its own home either way. Changing the mode changes the mount topology, so it needs a workspace rebuild."
  default     = "shared"
  sensitive   = false
}

# There is deliberately no GitHub *token* variable in this file. A workspace's
# GitHub credential comes from the Coder External Auth provider named by
# github_auth_id (see the data source in main.tf), which mints a short-lived
# per-host token for the workspace owner's own connected account — nothing
# long-lived is declared here, pushed with the template, or written to a file.
# The id is not a credential: Coder CE v2.36 injects a managed GitHub App whose
# id is "github" when coder.env is absent; a custom OAuth app in coder.env keeps
# its own CODER_EXTERNAL_AUTH_0_ID, which push-template.sh forwards here so
# existing account links keep working.
variable "github_auth_id" {
  type        = string
  description = "Coder External Auth provider id the template declares. Default matches Coder's injected GitHub App (id github) so a deploy with no coder.env can push. When coder.env sets CODER_EXTERNAL_AUTH_0_ID, push-template.sh forwards that value."
  default     = "github"
}

# Declaring the github MCP server is not enough for it to be usable, and a server
# that cannot handshake is dead weight in every session, so this switch decides
# on its own whether the [mcp_servers.github] block is rendered. With no GitHub
# account connected, the block still appears and pays one failed handshake per
# session, which is the cheaper failure: no credential exists to leak.
variable "github_mcp" {
  type        = bool
  description = "When true, the rendered ~/.grok/config.toml declares the github MCP HTTP server, which is how Grok Build gets its GitHub tools. It authenticates with the $GH_TOKEN reference the agent environment fills from the External Auth provider, so with no provider linked — or no GitHub account connected by the workspace owner — the server has nothing to authenticate with and Grok Build loses its GitHub tools. Off by default keeps the offline-first MCP list lean."
  default     = false
}

# The self-hosted SearXNG lane reaches Grok Build as an MCP stdio server: the
# searxng-mcp-server package is pinned in the golden image and needs to be told
# which instance to dial. Unlike github_mcp this switch is on by default: search
# is the one lane every session may want, and nothing else in the box answers it.
variable "search_mcp" {
  type        = bool
  description = "When true (the default), the rendered ~/.grok/config.toml declares the searxng MCP stdio server, which is how Grok Build gets its search lane. Set SEARCH_MCP=false in the stack's env file and re-push to drop the block everywhere."
  default     = true
}

# The SearXNG base URL as the dev container reaches it: through the host gateway,
# at the port the compose file publishes (8181 by default; a dev stack that
# remapped STACK_SEARCH_PORT gets its own port through push-template.sh). The
# package's compiled-in default (localhost:8888) names nothing that exists on
# this box, so the URL is always supplied.
variable "searxng_url" {
  type        = string
  description = "Base URL of the self-hosted SearXNG instance the rendered search lane dials, e.g. http://host.docker.internal:8181."
  default     = "http://host.docker.internal:8181"
}

# Cached Context7 MCP is network-dependent and needs a CONTEXT7_API_KEY, so this
# switch decides on its own whether the [mcp_servers.context7] block is rendered.
# Off by default keeps the offline-first MCP list lean. A true value with an
# empty key still renders the block and pays one failed handshake per session.
variable "context7_mcp" {
  type        = bool
  description = "When true, the rendered ~/.grok/config.toml declares the cached context7 MCP stdio server (mcp-cache-proxy wrapping the official @upstash/context7-mcp). It authenticates with the $CONTEXT7_API_KEY reference the agent environment fills from var.context7_api_key, so with no key the server has nothing to authenticate with. Off by default keeps the offline-first MCP list lean."
  default     = false
}

# The Context7 API key. Sensitive: never printed, never interpolated into
# config.toml or startup.sh. Empty default means the agent env omits the key.
variable "context7_api_key" {
  type        = string
  description = "Context7 API key handed to the workspace as CONTEXT7_API_KEY when non-empty. The rendered config.toml only names the variable."
  default     = ""
  sensitive   = true
}
