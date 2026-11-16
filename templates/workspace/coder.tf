variable "image" {
  type        = string
  description = "Default for the Workspace image dropdown. Build the golden image with bazelisk run //scripts:build-dev-image, or point this at a Coder base image; a custom value is injected into the dropdown as its own option."
  default     = "evo-t1-dev:latest"
}

variable "grok_default_model" {
  type        = string
  description = "Grok catalog key used for new sessions. The Qwen2.5-Coder weights on the Arc Ollama return tool calls as plain text, so keep this on a Spark vLLM alias; the Arc qwen2.5:7b (the `chat` alias) does emit structured tool calls and is a viable offline substitute."
  default     = "agent"
}

variable "grok_subagents_lane" {
  type        = string
  description = "Grok catalog key every subagent a session spawns runs on, rendered into [subagents.models] in the workspace's ~/.grok/config.toml for all three built-in types (general-purpose, explore, plan). The default puts subagents on the unpinned `agent-swarm` fan-out lane, and `agent` is the rollback that puts them back on the same pinned Spark lane as the parent session. `agent-swarm` is the fan-out choice: it is the one Spark group with no LiteLLM session pin, so the least-busy picker spreads a fan-out over all three boxes instead of queueing them behind one box's streams. It decides placement only: the in-flight width comes from grok_swarm_width, so this is the knob a workspace turns on to spread a fan-out over every box rather than queue it behind one. It now drives the writer types only; the read/search and skeptic lanes have their own variables below."
  default     = "agent-swarm"
}

# The three role lanes. Each is its own --var so one role can be put back on the parent's
# lane without moving the others, which is the rollback an operator needs when a workspace
# is older than the LiteLLM config that registers the alias. Every default is a Spark alias
# in litellm/config.yaml, so no lane can drift onto a cloud endpoint from here.

variable "grok_explore_lane" {
  type        = string
  description = "Grok catalog key the `explore` subagent type runs on. The default `agent-explore` is the read/search lane: the same three Spark boxes as `agent`, thinking baked to low, and the second group with no LiteLLM session pin, so a wave of read-only mappers is placed across the whole fleet rather than queueing behind one box's streams. Set `agent-low` to keep the pin at the same thinking level, or `agent` to send mapping work at full depth."
  default     = "agent-explore"
  validation {
    condition     = can(regex("^[a-z0-9._-]+$", var.grok_explore_lane))
    error_message = "grok_explore_lane must be a single Grok catalog key, for example agent-explore, agent-low or agent."
  }
}

variable "grok_plan_lane" {
  type        = string
  description = "Grok catalog key the `plan` subagent type runs on. A planner is one conversation that re-reads what it just read and steers every wave after it, so the default keeps the session pin (`agent`) and the depth that goes with it, rather than spreading. Set `agent-medium` to trade depth for turnaround on a busy fleet."
  default     = "agent"
  validation {
    condition     = can(regex("^[a-z0-9._-]+$", var.grok_plan_lane))
    error_message = "grok_plan_lane must be a single Grok catalog key, for example agent, agent-medium or agent-xhigh."
  }
}

variable "grok_review_lane" {
  type        = string
  description = "Grok catalog key the skeptical roles run on - `reviewer` and `security-auditor` in [subagents.models], which is where the mandatory independent-review phase of a multi-file change gets its thinking level. The default `agent-review` bakes xhigh and lifts the session pin, so a wave of reviewers spreads and each one thinks as hard as the parent. It is also the single seam for the cost of that phase: set `agent-medium` here and the alias in litellm/config.yaml to make reviews cheaper without touching any other lane."
  default     = "agent-review"
  validation {
    condition     = can(regex("^[a-z0-9._-]+$", var.grok_review_lane))
    error_message = "grok_review_lane must be a single Grok catalog key, for example agent-review, agent-xhigh or agent."
  }
}

variable "grok_swarm_width" {
  type        = number
  description = "The fleet's own fan-out width, and the default for [subagents] max_concurrent whatever lane the operator picked. 15 is 3 Spark boxes x PARALLEL 5 (scripts/spark-configure.sh): the number of full-length streams the whole fleet can hold at once. It is the default rather than a lane-conditional 4 because `agent-swarm` is always selectable - the alias block ships ungated in grok-config.toml.tftpl, and a session on a pinned default lane can still name it on any spawn - so a config that sized itself at one box's PARALLEL would cap a swarm the user had only to ask for. An operator who pins every lane to one box and wants the narrower queue sets grok_subagent_max_concurrent explicitly."
  default     = 15
  validation {
    condition     = var.grok_swarm_width >= 1 && var.grok_swarm_width <= 32
    error_message = "grok_swarm_width must be a whole number between 1 and 32; above the fleet's 15 streams it deepens LiteLLM's queue rather than buying capacity."
  }
}

variable "grok_subagent_max_concurrent" {
  type        = number
  description = "How many subagents one session may have in flight, rendered into [subagents] max_concurrent in the workspace's ~/.grok/config.toml. Leave it unset to take grok_swarm_width, the fleet ceiling, so the session is sized for a swarm on every lane; set a number to override, which is how an operator who pins everything to one box narrows the queue to that box's PARALLEL. The 1..32 validation accepts any explicit value, and above the fleet's 15 streams a number deepens LiteLLM's queue rather than buying capacity. Only the unpinned agent-swarm lane spreads a fan-out over more than one box."
  default     = null
  validation {
    condition     = var.grok_subagent_max_concurrent == null || (var.grok_subagent_max_concurrent >= 1 && var.grok_subagent_max_concurrent <= 32)
    error_message = "grok_subagent_max_concurrent must be null (take grok_swarm_width, the fleet's width) or a whole number between 1 and 32."
  }
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
  description = "Optional default for the Git repository field. A non-empty value is cloned on the first workspace start into /home/coder/workspace/<repo-name>, and that folder is the one code-server opens. The clone runs as the workspace user and consults whatever HTTPS credential it finds there (a credential helper, ~/.git-credentials, or the external-auth account connected in Coder — which must also GRANT the repo, or the fetch is refused). A Dockerfile or toolchain in the cloned repo executes as that same workspace user, so only point this at repositories you trust."
  default     = ""
}

# The canonical URL of this stack's own repository. It exists as a variable rather
# than a literal in the preset so a fork that hosts the stack elsewhere gets a
# "New project" preset that clones its own stack, not the upstream one. The
# scaffold preset passes it as additional_repos, which is how scripts/new-repo.sh
# reaches a fresh workspace. The scaffold that CLI renders is cloned from its own
# repository at run time, so no copy of it rides along in this repo.
variable "stack_repo_url" {
  type        = string
  description = "Git URL of this stack's repository, cloned as an additional repo by the New project preset so the scaffold CLI is available."
  default     = "https://github.com/toxicoder/evo-t1-coder-stack"
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
# on its own whether the [mcp_servers.github] block is rendered. It is on by
# default, because the GitHub lane is what most sessions here want. With no
# GitHub account connected the block still appears and pays one failed handshake
# per session, which is the cheaper failure: no credential exists to leak.
variable "github_mcp" {
  type        = bool
  description = "When true (the default), the rendered ~/.grok/config.toml declares the github MCP HTTP server, which is how Grok Build gets its GitHub tools. It authenticates with the $GH_TOKEN reference the agent environment fills from the External Auth provider, so with no provider linked — or no GitHub account connected by the workspace owner — the server has nothing to authenticate with and Grok Build loses its GitHub tools. Set GITHUB_MCP=false in the stack's env file and re-push to drop the block everywhere."
  default     = true
}

# The self-hosted SearXNG lane reaches Grok Build as an MCP stdio server: the
# searxng-mcp-server package is pinned in the golden image and needs to be told
# which instance to dial. Like github_mcp and context7_mcp this switch is on by
# default: search is the one lane every session may want, and nothing else in the
# box answers it.
variable "search_mcp" {
  type        = bool
  description = "When true (the default), the rendered ~/.grok/config.toml declares the searxng MCP stdio server, which is how Grok Build gets its search lane. Set SEARCH_MCP=false in the stack's env file and re-push to drop the block everywhere."
  default     = true
}

# The SearXNG base URL as the workspace reaches it: through the host gateway, at
# the port the compose file publishes (8181 by default; a dev stack that remapped
# STACK_SEARCH_PORT gets its own port through push-template.sh). The package's
# compiled-in default (localhost:8888) names nothing that exists on this box, so
# the URL is always supplied.
variable "searxng_url" {
  type        = string
  description = "Base URL of the self-hosted SearXNG instance the rendered search lane dials, e.g. http://host.docker.internal:8181."
  default     = "http://host.docker.internal:8181"
}

# Cached Context7 MCP is network-dependent and wants a CONTEXT7_API_KEY, so this
# switch decides on its own whether the [mcp_servers.context7] block is rendered.
# It is on by default like the other two: the key is optional, and a true value
# with an empty key still renders the block and pays one failed handshake per
# session, which is the cheaper failure next to a workspace with no docs lane.
variable "context7_mcp" {
  type        = bool
  description = "When true (the default), the rendered ~/.grok/config.toml declares the cached context7 MCP stdio server (mcp-cache-proxy wrapping the official @upstash/context7-mcp). It authenticates with the $CONTEXT7_API_KEY reference the agent environment fills from var.context7_api_key, so with no key the server has nothing to authenticate with. Set CONTEXT7_MCP=false in the stack's env file and re-push to drop the block everywhere."
  default     = true
}

# The Context7 API key. Sensitive: never printed, never interpolated into
# config.toml or startup.sh. Empty default means the agent env omits the key.
variable "context7_api_key" {
  type        = string
  description = "Context7 API key handed to the workspace as CONTEXT7_API_KEY when non-empty. The rendered config.toml only names the variable."
  default     = ""
  sensitive   = true
}

# Self-hosted Infisical is the source of record for the stack's credentials, and this
# switch is the one seam that turns the workspace-side fetch on. It is off by default,
# like the stack-wide INFISICAL_ENABLED flag: with false the boot fetch exits 0 without
# acting and the agent environment carries no INFISICAL_* key at all.
variable "infisical_enabled" {
  type        = bool
  description = "When true, the workspace boot fetches its credentials from the self-hosted Infisical instance named by infisical_url. Default false leaves the fetch disabled: the boot script exits without acting and the agent environment omits every INFISICAL_* key, so the workspace keeps the credentials the agent env already carries."
  default     = false
}

# The instance the boot fetch dials. The Infisical CLI needs the domain on every call or
# it dials Infisical Cloud, so an empty value disables the fetch instead of guessing one.
variable "infisical_url" {
  type        = string
  description = "Base URL of the self-hosted Infisical instance the workspace dials, e.g. http://host.docker.internal:8182, handed to it as INFISICAL_DOMAIN. Empty default means the workspace boot fetch stays disabled rather than dialing Infisical Cloud."
  default     = ""
}

# The project the secrets are read from. Not a credential, but no read works without it,
# so an empty value disables the fetch the way an empty URL does.
variable "infisical_project_id" {
  type        = string
  description = "Infisical project id the workspace boot reads its secrets from, handed to it as INFISICAL_PROJECT_ID. Empty default means the workspace boot fetch stays disabled."
  default     = ""
}

# The Universal Auth principal the boot authenticates as -- the id, never the token.
variable "infisical_machine_identity_id" {
  type        = string
  description = "Infisical machine identity id the workspace authenticates as, handed to it as INFISICAL_MACHINE_IDENTITY_ID. Empty default means the workspace boot fetch stays disabled."
  default     = ""
}

# The client id pairs with the secret below. It identifies the machine identity but
# cannot authenticate alone, so it is not marked sensitive.
variable "infisical_client_id" {
  type        = string
  description = "Universal Auth client id the workspace boots with, handed to it as INFISICAL_UNIVERSAL_AUTH_CLIENT_ID. Empty default means the workspace boot fetch stays disabled."
  default     = ""
}

# The Universal Auth client secret. Sensitive: never printed, never interpolated into
# the rendered boot script -- that body only names the environment variable, and this
# value reaches the workspace through the agent env.
variable "infisical_client_secret" {
  type        = string
  description = "Universal Auth client secret the workspace boots with, handed to it as INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET when non-empty. The rendered boot script only names the variable. Empty default means the workspace boot fetch stays disabled."
  default     = ""
  sensitive   = true
}

# Which Infisical environment the fetch reads. The stack keeps one, so this rarely
# moves; it is a variable because the CLI takes --env on every read and a fork with
# another environment slug has no default that fits it.
variable "infisical_environment" {
  type        = string
  description = "Infisical environment name the workspace boot reads, handed to it as INFISICAL_ENVIRONMENT. Defaults to prod; set it to the slug of another environment in the project. An empty value means the workspace boot fetch stays disabled."
  default     = "prod"
}

# The second gate, under infisical_enabled. The first decides whether the vault is
# part of this workspace at all; this one decides whether a workspace start waits
# on it. A boot fetch is bounded by coder_script's 120s timeout, so an unreachable
# vault is a slow start, and an operator adopting the vault usually wants to run one
# `pull` by hand and watch the keys settle before every start depends on the round
# trip. Off by default for exactly that reason. Handed to the boot script as
# INFISICAL_PULL_ON_START so the rendered script text stays identical either way.
variable "infisical_pull_on_start" {
  type        = bool
  description = "When true, the workspace boot fetch pulls the managed keys on its own start, in no promised order with the startup script. Default false keeps the coder_script present but idle: it logs that the gate is off and exits 0, so a workspace never waits on Infisical being up. Has no effect while infisical_enabled is false."
  default     = false
}
