variable "image" {
  type        = string
  description = "Image for the *workspace* container — the one the agent runs in and where the repo is cloned. The dev container itself is defined by the repo's own .devcontainer/devcontainer.json and built on the DinD sidecar, so this image never decides the toolchain inside the editor. Build the golden image with scripts/build-dev-image.sh; a bare Ubuntu still boots but without the Docker CLI, Node or the Grok CLI."
  default     = "evo-t1-dev:latest"
}

variable "repo_url" {
  type        = string
  description = "Default for the create form's Git repository field — the clone source in either mode: built into a dev container when the dev-container toggle is on, opened directly by the editor when it is off. With the toggle on the repo must carry .devcontainer/devcontainer.json, otherwise that build fails and no editor appears; with it off any repo works. The clone runs unauthenticated as the workspace user, so a private repo needs git credentials inside the workspace (~/.git-credentials or an SSH key) before it will fetch."
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

# Optional, and empty by default: this box is offline-first and most workspaces
# never talk to GitHub, so the default keeps no credential anywhere — in the
# rendered file, in the agent environment, or on disk.
variable "github_token" {
  type        = string
  description = "Optional GitHub fine-grained personal access token. When non-empty it is injected into the agent environment as GH_TOKEN and GITHUB_TOKEN, and the startup script seeds the git credential helper that shells out to `gh auth git-credential` from it, so git push and gh pr create work. Use a least-privilege fine-grained token scoped to only the repositories these workspaces touch, and rotate it when a workspace is done with it. Empty (the default) means no GitHub credential exists anywhere in the workspace."
  default     = ""
  sensitive   = true
}

# Declaring the server is not enough for a token to be usable, and a server that
# cannot handshake is dead weight in every session, so both switches are needed.
variable "github_mcp" {
  type        = bool
  description = "When true AND github_token is non-empty, the rendered ~/.grok/config.toml declares the github MCP HTTP server, which is how Grok Build gets its GitHub tools. Off by default keeps the offline-first MCP list lean: with no token there is nothing for that server to authenticate against anyway, and a session would pay a failed handshake on every start."
  default     = false
}
