variable "image" {
  type        = string
  description = "Workspace container image. Use a Coder base image (agent runtime included)."
  default     = "codercom/example-base:ubuntu"
}

variable "litellm_url" {
  type        = string
  description = "LiteLLM proxy base URL reachable from the workspace (via the Docker host gateway)."
  default     = "http://host.docker.internal:4000/v1"
}

variable "litellm_key" {
  type        = string
  description = "LiteLLM master key handed to Cline / Kilo Code in the workspace."
  default     = ""
  sensitive   = true
}
