variable "image" {
  type        = string
  description = "Default for the Workspace image dropdown. Build the golden image with scripts/build-dev-image.sh, or point this at a Coder base image; a custom value is injected into the dropdown as its own option."
  default     = "evo-t1-dev:latest"
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

variable "dind" {
  type        = bool
  description = "Default for the docker-in-docker toggle. When on, the workspace gets a dedicated privileged docker:29.8.1-dind sidecar on a network private to that workspace, plus DOCKER_HOST pointed at it, so docker build, docker run and docker compose work inside. The sidecar runs privileged, so keep this off unless someone is actually testing container builds; the daemon image is never pulled by Terraform, so docker:29.8.1-dind must already be in the host's local image store (docker pull docker:29.8.1-dind)."
  default     = false
}

# Optional create-form default for the Git repository field, not a mandate: an
# empty value clones nothing and leaves the editor on /home/coder, which is what
# this template did before the field existed. scripts/push-template.sh passes
# --var repo_url= to *every* template from a shared vars array, so this variable
# has to exist here too or a push with REPO_URL set dies on an undeclared
# variable.
variable "repo_url" {
  type        = string
  description = "Optional default for the Git repository field. A non-empty value is cloned on the first workspace start into /home/coder/workspace/<repo-name>, and that folder is the one code-server opens. The clone runs unauthenticated as the workspace user, so a private repository needs git credentials inside the workspace first. A Dockerfile or toolchain in the cloned repo executes as that same workspace user, so only point this at repositories you trust."
  default     = ""
}

# Was `variable "grok_profile_share"` (a bool) until the per-workspace mode needed
# to say *which* layout a workspace gets, not just whether a shared volume exists.
# It stays a plain string with exactly those two values because
# scripts/push-template.sh may forward it with `--var grok_profile_mode`, and a
# create-form dropdown can only offer options the pushed default actually has.
variable "grok_profile_mode" {
  type        = string
  description = "How a workspace gets its ~/.grok. 'shared' = one per-user Docker volume (grok-profile-<owner-id>) mounted at /home/coder/.grok, nested inside that workspace's own home volume — exactly what the old grok_profile_share = true did: everything the CLI keeps there (config.toml, MCP caches, memory-v2, skills, a self-installed CLI) is written once and read by every workspace this user owns, and survives a rebuild. 'private' = no nested mount, so each workspace gets its own private ~/.grok on its own home volume, and that workspace's config.toml, MCP caches, memory and skills die with it. Per-user, not host-wide, in shared mode: the volume name is keyed by owner id, so another user's workspaces never see it. Changing the mode changes the mount topology, so it needs a workspace rebuild."
  default     = "shared"
}

# Optional, and empty by default: this box is offline-first and most workspaces
# never talk to GitHub, so the default keeps no credential anywhere — in the
# rendered file, in the agent environment, or on disk.
variable "github_token" {
  type        = string
  description = "Optional GitHub fine-grained personal access token. When non-empty it is injected into the agent environment as GH_TOKEN and GITHUB_TOKEN, and the startup script seeds the gh/git credential helper from it so git push and gh pr create work. Use a least-privilege fine-grained token scoped to only the repositories these workspaces touch, and rotate it when a workspace is done with it. Empty (the default) means no GitHub credential exists anywhere in the workspace."
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
