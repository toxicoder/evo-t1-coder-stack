variable "image" {
  type        = string
  description = "Image for the *workspace* container — the one the agent runs in and where the repo is cloned. The dev container itself is defined by the repo's own .devcontainer/devcontainer.json and built on the DinD sidecar, so this image never decides the toolchain inside the editor. Build the golden image with scripts/build-dev-image.sh; a bare Ubuntu still boots but without the Docker CLI, Node or the Grok CLI."
  default     = "evo-t1-dev:latest"
}

variable "repo_url" {
  type        = string
  description = "Default for the create form's Git repository field. The repo must carry .devcontainer/devcontainer.json; the clone runs unauthenticated as the workspace user, so a private repo needs git credentials inside the workspace (~/.git-credentials or an SSH key) before it will fetch."
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

variable "grok_profile_share" {
  type        = bool
  description = "Mount the workspace owner's shared Grok Build profile volume (grok-profile-<owner-id>) at /home/coder/.grok, nested inside that workspace's own home volume, so the CLI's state tree (config.toml, skills, memory-v2, sessions, MCP warm caches, a self-installed CLI under ~/.grok/bin) is written once and shared by every workspace this user owns and survives a rebuild. Per-user, not host-wide: the volume name is keyed by owner id, so another user's workspaces never see it. Off gives each workspace a private ~/.grok that dies with it. Changing this needs a workspace rebuild."
  default     = true
}
