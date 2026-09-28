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
