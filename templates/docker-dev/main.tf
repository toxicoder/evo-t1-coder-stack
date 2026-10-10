terraform {
  required_providers {
    # Pinned to what .terraform.lock.hcl records, so a provider release cannot
    # break a rebuild. The coder provider 2.x requires a Coder server >= 2.18
    # (this stack runs v2.36.6).
    coder = {
      source  = "coder/coder"
      version = "~> 2.18"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.6"
    }
  }
}

variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

provider "docker" {
  # Defaulting to null when the variable is an empty string lets us have an
  # optional variable without having to set our own default.
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# The image picker on the create form. The provider requires a parameter
# default to be one of the option values, so a custom --var image=<tag> is
# injected as its own option rather than being dropped (which would leave the
# form showing the golden image while the build used something else).
locals {
  image_choices = [
    {
      value       = "evo-t1-dev:latest"
      name        = "EVO-T1 golden image"
      description = "Pinned polyglot toolchain with pre-warmed uv/npm caches and the MCP servers baked in. Build it first: scripts/build-dev-image.sh."
    },
    {
      value       = "ubuntu:24.04"
      name        = "Ubuntu 24.04 (bare)"
      description = "Nothing preinstalled. The startup script still installs tmux and the Grok CLI, but expect a slow first start."
    },
  ]
  image_options = contains([for c in local.image_choices : c.value], var.image) ? local.image_choices : concat(
    local.image_choices,
    [{ value = var.image, name = "Custom (${var.image})", description = "Pushed with --var image." }],
  )

  # Same rule as image_options, same trick: the provider requires a parameter
  # default to be one of its options, so a custom --var grok_default_model=<key>
  # is added as its own option rather than dropped (which would leave the form
  # showing `agent` while the build used something else). The descriptions are the
  # ones the [model.*] blocks in grok-config.toml.tftpl carry, so the create form
  # says the same thing about each alias as the rendered config does.
  model_choices = [
    {
      value       = "agent"
      name        = "agent (DGX Spark vLLM)"
      description = "Primary agent model; emits native tool_calls"
    },
    {
      value       = "coder"
      name        = "coder (Arc iGPU)"
      description = "Arc fallback; completion-style on this runtime (no tool_calls)"
    },
    {
      value       = "coder-fast"
      name        = "coder-fast (Arc iGPU)"
      description = "Arc fallback; completion-style on this runtime (no tool_calls)"
    },
    {
      value       = "chat"
      name        = "chat (Arc iGPU)"
      description = "Arc chat fallback; returns real tool_calls on this runtime (measured)"
    },
  ]
  model_options = contains([for c in local.model_choices : c.value], var.grok_default_model) ? local.model_choices : concat(
    local.model_choices,
    [{ value = var.grok_default_model, name = "Custom (${var.grok_default_model})", description = "Pushed with --var grok_default_model." }],
  )

  # The folder a cloned repository lands in. Derived here *and* in
  # startup.sh.tftpl on purpose: this file only names the path, the script is
  # the side that runs git, and the two derivations must agree or the editor and
  # the terminal helpers point at a folder that was never cloned. Both do —
  # split on "/", drop empty segments (so a trailing slash is harmless), take
  # the last, drop a trailing ".git", map every character outside
  # [A-Za-z0-9._-] to "-", and fall back to "repo" when that leaves no leading
  # alphanumeric — which also keeps "../" out of a root-owned path the editor,
  # the web terminal and Grok Build all open on.
  repo_leaf = element(concat(compact(split("/", trimspace(data.coder_parameter.repo_url.value))), [""]), -1)
  repo_stripped = replace(
    replace(local.repo_leaf, "\\.git$", ""),
    "[^A-Za-z0-9._-]", "-",
  )
  repo_folder = can(regex("^[A-Za-z0-9]", local.repo_stripped)) ? local.repo_stripped : "repo"
  # An empty field clones nothing and keeps every folder below on /home/coder.
  repo_set = trimspace(data.coder_parameter.repo_url.value) != ""

  # The VS Code settings seed. startup.sh.tftpl copies it onto the per-owner
  # shared volume the first time that file is absent, then points code-server's
  # User settings at it. The code-server module does not receive this map: its
  # merge replaces that symlink on every start. The LiteLLM key is not in the
  # seed — the script adds it from the agent environment at seed time — so a
  # template render never contains the key. code-server never reads ~/.config/Code.
  vscode_settings = templatefile("${path.module}/settings.json.tftpl", {
    litellm_url = var.litellm_url
  })
}

data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "Workspace image"
  description  = "Base image for the dev container. The golden image is what the startup script's Grok and MCP setup was verified against."
  type         = "string"
  form_type    = "dropdown"
  # Fixed at create time: switching image means a rebuild anyway, and a mutable
  # dropdown invites someone swapping the golden image out from under the stack.
  mutable = false
  default = var.image
  order   = 1

  dynamic "option" {
    for_each = local.image_options
    content {
      name        = option.value.name
      value       = option.value.value
      description = option.value.description
    }
  }
}

# Docker-in-docker is opt-in because it costs a privileged container: the inner
# daemon mounts /var/lib/docker on its own volume and needs cgroup/namespace
# control the workspace itself never gets. Off by default so a normal workspace
# stays as unprivileged as it was before this existed.
data "coder_parameter" "dind" {
  name         = "dind"
  display_name = "Docker-in-docker"
  description  = "Provision a dedicated privileged docker:29.8.1-dind sidecar for this workspace, on a network private to it, and point DOCKER_HOST at that daemon. docker build, docker run and docker compose then work inside the workspace. The daemon image is never pulled by Terraform, so docker:29.8.1-dind must already exist in the host image store. Turn this on only when you actually need to build containers: privileged means the workspace can reach the host kernel."
  type         = "bool"
  # "radio" is only legal for a bool once options exist — the provider errors
  # with: "form_type" attribute="radio" is not supported for "type"="bool" when
  # options do not exist, choose one of [checkbox switch]. The option blocks
  # below are what make the yes/no wording possible; switch would work without
  # them but renders a bare on/off toggle with no description per choice.
  form_type = "radio"
  # Toggling this changes topology (a network, a volume and a second container
  # appear or vanish), so an in-place edit would leave a half-wired workspace.
  # A rebuild is the honest answer; the preset makes redoing it one click.
  mutable = false
  default = tostring(var.dind)
  order   = 2

  # Values must stay the literal strings "true"/"false": .value is always a
  # string, and the preset below has to set the same value to match.
  option {
    name        = "Yes"
    value       = "true"
    description = "Provision the privileged DinD sidecar and point DOCKER_HOST at it."
  }

  option {
    name        = "No"
    value       = "false"
    description = "No sidecar; the workspace sees no Docker daemon at all."
  }
}

# Empty by default: a workspace that names no repository is exactly what this
# template used to be — editor, web terminal and Grok Build all on /home/coder.
# Mutable because switching repository clones a folder and reopens the editor;
# unlike the DinD toggle that changes no topology, so no rebuild is needed.
data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git repository"
  description  = "Optional clone URL. The repository is fetched into /home/coder/workspace/<repo-name> on workspace create and on every start, and when this is filled the editor, the terminal and Grok Build all open and run on that folder. Leave it empty for a home-directory workspace."
  type         = "string"
  form_type    = "input"
  mutable      = true
  default      = var.repo_url
  order        = 3
}

# Immutable in place, like the DinD toggle: which mode a workspace is in decides
# whether the nested ~/.grok mount exists at all, so an in-place edit would change
# the mount topology under a running workspace. The default comes from the template
# variable so an operator can flip the whole stack with --var grok_profile_mode on
# push, exactly like the image and DinD defaults above.
data "coder_parameter" "grok_profile_mode" {
  name         = "grok_profile_mode"
  display_name = "Grok profile"
  description  = "Where this workspace's ~/.grok lives. Shared = one per-user profile volume, shared by every workspace this owner owns: config.toml, the MCP caches, memory and skills are shared between them, and the last workspace started re-renders that one shared config.toml. Private = this workspace gets its own private ~/.grok on its own home volume, so its config.toml (and its memory and skills) are independent of the owner's other workspaces and die with the workspace. Changing this needs a rebuild: the nested mount either exists or it does not."
  type         = "string"
  # Same reason as the DinD toggle: the choice is the mount topology, and a
  # mutable field would let someone pull the mount out from under a running agent.
  form_type = "dropdown"
  mutable   = false
  default   = var.grok_profile_mode
  order     = 4

  # Only these two spellings mean anything; anything else reads as private, which
  # is the safe half of the mistake (it leaks nothing, it just costs sharing).
  option {
    name        = "Shared (one profile per user)"
    value       = "shared"
    description = "One per-user profile volume, shared by every workspace this owner owns: config.toml, MCP caches, memory and skills are shared, and the last workspace started re-renders that one shared config.toml."
  }

  option {
    name        = "Private (this workspace only)"
    value       = "private"
    description = "This workspace gets its own private ~/.grok on its own home volume, so its config.toml (and its memory and skills) are independent of the owner's other workspaces and die with the workspace."
  }
}

# The default model per workspace, which the create form could not express before
# (it was a stack-wide variable). It only differs observably per workspace while
# the profile is private, or while config.toml is unmanaged: on a shared profile
# volume one file serves all of the owner's workspaces, and whoever starts last
# re-renders it for everyone. Options follow the aliases in
# grok-config.toml.tftpl, and local.model_options keeps the provider's
# default-must-be-an-option rule true for a custom --var grok_default_model.
data "coder_parameter" "grok_default_model" {
  name         = "grok_default_model"
  display_name = "Grok default model"
  description  = "The model alias new Grok Build sessions in this workspace start on. Written into the rendered ~/.grok/config.toml as [models] default. Only the Spark vLLM aliases return a real tool_calls array on this runtime; the Arc aliases answer tool calls as plain text, so they suit chat and summarisation."
  type         = "string"
  form_type    = "dropdown"
  # Fixed at create time for the same reason as the profile mode: the file that
  # carries it is rewritten on start, so this is the only honest seam, and a
  # silent model swap under a running workspace is not worth one dropdown.
  mutable = false
  default = var.grok_default_model
  order   = 5

  dynamic "option" {
    for_each = local.model_options
    content {
      name        = option.value.name
      value       = option.value.value
      description = option.value.description
    }
  }
}

# Trusted, not validated: appended verbatim into a file the CLI reads, by the same
# argument that makes repo_url a free-text field (see above) — whoever fills this in
# already holds a shell in that container, so nothing gained by restricting it.
data "coder_parameter" "grok_config_extra" {
  name         = "grok_config_extra"
  display_name = "Grok config extras"
  description  = "Free-form TOML appended verbatim to the rendered ~/.grok/config.toml, under its own comment header. Use it for per-workspace keys the managed block does not set — an extra [mcp_servers.*] entry, a permission deny list, a different subagent cap. This trusts whoever fills it in, exactly like the Git repository field above: this workspace's owner already holds a shell in that container. Leave it empty unless needed; empty renders nothing at all."
  type         = "string"
  # Mutable because it writes one text file, not topology: no rebuild has to
  # happen to take a key back out again, and restart re-renders the whole file.
  form_type = "textarea"
  mutable   = true
  default   = ""
  order     = 6
}

# Presets collapse the create form to one click. Keys here are parameter *names*
# (display_name is UI-only and would be ignored).
data "coder_workspace_preset" "ai_workspace" {
  name        = "AI workspace"
  description = "Golden image with the Grok Build terminal, MCP servers and LiteLLM wiring."
  default     = true

  parameters = {
    (data.coder_parameter.workspace_image.name) = "evo-t1-dev:latest"
  }
}

data "coder_workspace_preset" "minimal" {
  name        = "Minimal shell"
  description = "Bare Ubuntu for when the golden image is being rebuilt."

  parameters = {
    (data.coder_parameter.workspace_image.name) = "ubuntu:24.04"
  }
}

# Separate from ai_workspace rather than a variant of it: this preset exists to
# be picked when someone wants to build containers, and it turns on a privileged
# sidecar, so it should be its own visible choice, not a default.
data "coder_workspace_preset" "dind_workspace" {
  name        = "AI workspace + DinD"
  description = "Golden image plus a privileged docker:29.8.1-dind sidecar, for workspaces that build or run containers themselves."

  parameters = {
    (data.coder_parameter.workspace_image.name) = "evo-t1-dev:latest"
    (data.coder_parameter.dind.name)            = "true"
  }
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # Without this a failed container hangs the workspace until the provider
  # default; a wrong image tag or a broken init script is otherwise invisible.
  connection_timeout = 300

  # Gate login on the setup stages finishing, so nobody lands in a half-built
  # home directory with no Grok CLI or VS Code settings.
  startup_script_behavior = "blocking"

  # Agent-bar buttons. These are driven here, not by any CODER_*IDE* server
  # flag (no such flag family exists in v2.36). display_apps.vscode is the
  # desktop helper: a locally installed VS Code plus the coder.coder-remote
  # extension. The in-browser editor is the separate code-server app below.
  # web_terminal stays off on purpose: the built-in terminal is hardwired to
  # open in coder_agent.dir, which is unset here and therefore /home/coder,
  # and the custom coder_app below replaces it with one that opens on the
  # cloned repository instead. That is the documented replace pattern (set the
  # display_apps key false and add a command-type coder_app); leaving this on
  # would only add a second terminal button that lands on the home folder.
  display_apps {
    vscode                 = true
    vscode_insiders        = false
    web_terminal           = false
    ssh_helper             = true
    port_forwarding_helper = true
  }

  # Native threshold alerts. A full /home/coder volume is the realistic failure
  # mode on a single-disk box, and volume monitoring surfaces it in the UI.
  resources_monitoring {
    memory {
      enabled   = true
      threshold = 90
    }
    volume {
      enabled   = true
      path      = "/home/coder"
      threshold = 85
    }
  }

  # Live resource gauges on the workspace page, sampled agent-side by
  # `coder stat` at CODER_AGENT_STATS_REFRESH_INTERVAL (30s default). The
  # --host variants read the host, which on this box is also the inference
  # host, so they are the useful ones for deciding when to stop a workspace.
  dynamic "metadata" {
    for_each = [
      { key = "0_cpu_usage", display_name = "CPU Usage", script = "coder stat cpu --host" },
      { key = "1_mem_usage", display_name = "Memory Usage", script = "coder stat mem --host" },
      { key = "2_disk_usage", display_name = "Disk Usage", script = "coder stat disk --path /home/coder" },
      { key = "3_cpu_core_usage", display_name = "CPU Core Usage", script = "coder stat cpu --host" },
      { key = "4_swap_usage", display_name = "Swap Usage", script = "awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if(t>0) printf \"%.0f%% used (%d/%dMB)\", (t-f)*100/t, (t-f)/1024, t/1024; else print \"none\"}' /proc/meminfo" },
      { key = "5_load_average", display_name = "Load Average", script = "awk '{print $1\", \"$2\", \"$3}' /proc/loadavg" },
    ]
    content {
      key          = metadata.value.key
      display_name = metadata.value.display_name
      script       = metadata.value.script
      interval     = 30
      timeout      = 5
    }
  }

  startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    # Every key of the inner map is an interpolation grok-config.toml.tftpl has to
    # resolve, so all six are declared together. github_token is a *boolean* gate
    # in there — it only decides whether the [mcp_servers.github] block appears —
    # so no token bytes are ever interpolated into the rendered script or into
    # config.toml; the rendered file names GH_TOKEN and the CLI expands that
    # reference from the environment. workspace_affinity_key is the per-workspace
    # LiteLLM session-affinity key, rendered into the [models] extra_headers.
    grok_config = templatefile("${path.module}/grok-config.toml.tftpl", {
      litellm_url            = var.litellm_url
      grok_default_model     = data.coder_parameter.grok_default_model.value
      grok_config_extra      = data.coder_parameter.grok_config_extra.value
      github_token           = var.github_token
      github_mcp             = var.github_mcp && var.github_token != ""
      workspace_affinity_key = "ws-${data.coder_workspace.me.id}"
    })
    # Injected verbatim into the script, which is safe enough: this is the
    # workspace creator's own input and they already hold a shell in this
    # container. The script quotes it anyway so a URL with spaces survives.
    repo_url = data.coder_parameter.repo_url.value
    # Rendered settings seed, inserted verbatim into a quoted heredoc. Already
    # resolved, so VS Code $${workspaceFolder} values inside it are not
    # interpolated again here. No key bytes: the script fills those from
    # LITELLM_API_KEY when it copies the file in.
    vscode_settings = local.vscode_settings
  })

  # These environment variables allow you to make Git commits right away
  # after creating a workspace. They take precedence over ~/.gitconfig.
  env = merge({
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    # The Grok config references this by name (env_key) so the key never lands
    # in a rendered file in the workspace.
    LITELLM_API_KEY  = var.litellm_key
    LITELLM_BASE_URL = var.litellm_url
    # Local model aliases, for shell prompts, Makefiles and CI overrides. Read
    # from the create-form dropdown, so it always agrees with the [models] default
    # the startup script renders.
    GROK_DEFAULT_MODEL = data.coder_parameter.grok_default_model.value
    # No CODER_AGENT_EXP_* overrides on purpose (verified against the v2.36.6
    # binary + its agentcontextconfig source): these keys REPLACE the agent's
    # discovery defaults rather than appending to them, and the defaults are
    # exactly what the stack seeds — the instruction file AGENTS.md under
    # ~/.coder plus the working dir, and skills under ~/.coder/skills plus a
    # working-dir-relative .agents/skills. The agent's working dir here is
    # /home/coder, so even the cwd-relative entry resolves inside the home
    # volume this stack manages, and a workspace that later clones a repo
    # carrying project-scoped instruction or skill files is discovered with
    # no change here. The files themselves are written by startup.sh.tftpl
    # on every boot, but only while absent, so a hand-edited copy survives
    # restarts.
    },
    # Only present when DinD is on: a DOCKER_HOST that pointed at a daemon that
    # does not exist would make every docker command in the workspace fail with
    # a confusing connection error instead of the plain "command not found".
    local.dind_enabled ? { DOCKER_HOST = local.dind_host } : {},
    # An empty token adds NEITHER key, so a workspace that declares no GitHub
    # credential gets exactly the environment it got before. When present the
    # token travels env-only, like LITELLM_API_KEY above: the startup script
    # seeds the gh/git credential helper from it, so `git push` and
    # `gh pr create` work with the token never written to a file, and the
    # rendered config.toml only ever references GH_TOKEN by name.
    var.github_token != "" ? { GH_TOKEN = var.github_token, GITHUB_TOKEN = var.github_token } : {},
  )
}

# In-browser VS Code (Coder's code-server fork) on port 13337. display_apps.vscode
# above is only the desktop helper; this module installs the binary into the
# home volume and exposes it as a path-based coder_app.
module "code_server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"
  # Pinned: this module is downloaded from registry.coder.com on every
  # `terraform init`, so an unpinned constraint lets an upstream module release
  # change every workspace's editor without a commit in this repo.
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  # Not just where the file tree starts: VS Code opens every new terminal with
  # cwd = the workspace root, and the Grok Build and tmux terminal profiles in
  # startup.sh.tftpl key their tmux session name and their `grok --cwd` off that
  # cwd. Move the folder and the editor's terminals and the Grok agent move with
  # it; leave it on /home/coder and they all keep working from the home folder.
  folder         = local.repo_set ? "/home/coder/workspace/${local.repo_folder}" : "/home/coder"
  port           = 13337
  install_prefix = "/home/coder/.local/share/code-server"
  use_cached     = true
  # No CODER_WILDCARD_ACCESS_URL on this box, so subdomain routing is not
  # available: the editor is proxied on the path-based access URL.
  subdomain = false
  open_in   = "tab"

  # The agent bar shows this as "VS Code Web" (display_name; the static
  # "VS Code Desktop" helper from display_apps keeps its own label, so the two
  # editor buttons read differently now) and sorts it before the LiteLLM (10)
  # and Coder UI (11) custom apps (lowest order first; static helper buttons
  # are not reorderable per Coder's resource-ordering docs).
  display_name = "VS Code Web"
  order        = 5

  # User settings are intentionally not passed. The module merges `settings`
  # into ~/.local/share/code-server/User/settings.json on every start, and the
  # merge `mv`s a regular file over whatever is there — including the symlink
  # startup.sh.tftpl maintains onto the shared volume. Machine settings stay
  # at the module default (empty) so a machine-scoped copy cannot override
  # the shared user file. code-server never reads ~/.config/Code.
}

# The agent-bar terminal button, replacing the built-in one (which stays off in
# display_apps above because it hardwires to coder_agent.dir = /home/coder).
# coder_app in coder/coder 2.18 has no `folder` argument — terraform validate
# rejects one with `An argument named "folder" is not expected here` — so the
# folder is pinned inside `command` instead: a command-type coder_app opens a
# terminal running that command, and this one lands the shell on the cloned
# repository when there is one, or on /home/coder when there is not. The `cd`
# is best-effort (`2>/dev/null;`): with && a failed clone would leave the only
# terminal button starting a shell in /home/coder and one in a dead folder, and
# a workspace whose clone failed still needs a working terminal to fix it from.
# Verified against `terraform validate` only — the shell-semantics behaviour
# needs one try in a real workspace.
resource "coder_app" "web_terminal" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "web-terminal"
  display_name = "Web Terminal"
  icon         = "/icon/terminal.svg"
  command      = "cd ${local.repo_set ? "/home/coder/workspace/${local.repo_folder}" : "/home/coder"} 2>/dev/null; exec /bin/bash -l"
  order        = 6
}

# The LiteLLM proxy is reachable from the workspace through the host gateway,
# so the agent can proxy it as an app. share = "owner" keeps it off the rest of
# the LAN; healthcheck needs all three of url, interval and threshold.
resource "coder_app" "litellm" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "litellm"
  display_name = "LiteLLM"
  url          = "http://host.docker.internal:4000"
  share        = "owner"
  subdomain    = false
  open_in      = "tab"
  order        = 10

  healthcheck {
    url       = "http://host.docker.internal:4000/health/liveliness"
    interval  = 10
    threshold = 12
  }
}

# Surfaced rather than proxied: these are host services the agent cannot proxy
# on the workspace's loopback, so they open on the client machine.
resource "coder_app" "coder_ui" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "coder"
  display_name = "Coder"
  # external apps open on the client machine, so there is nothing to share;
  # the attribute is mutually exclusive with share in the provider schema.
  external = true
  url      = data.coder_workspace.me.access_url
  order    = 11
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = coder_agent.main.id

  item {
    key   = "image"
    value = data.coder_parameter.workspace_image.value
  }

  # Which repository this workspace opened, and on an empty field say so, rather
  # than leaving a blank tile that reads like a failure.
  item {
    key   = "repo"
    value = local.repo_set ? data.coder_parameter.repo_url.value : "none"
  }

  item {
    key   = "litellm"
    value = var.litellm_url
  }

  item {
    key   = "grok default model"
    value = data.coder_parameter.grok_default_model.value
  }

  # Which ~/.grok topology this workspace got: `shared` means it mounts the
  # owner's one per-user profile volume, `private` means a private ~/.grok that
  # dies with the workspace. Without this the two look identical on the page.
  item {
    key   = "grok profile"
    value = data.coder_parameter.grok_profile_mode.value
  }

  # Which topology this workspace actually got. Without it the only way to tell
  # is running `docker version` inside the workspace and reading the failure.
  item {
    key   = "docker-in-docker"
    value = local.dind_enabled ? "on (${local.dind_host})" : "off"
  }

  item {
    key       = "litellm key"
    value     = var.litellm_key
    sensitive = true
  }

  # Same redaction stance as the two items above, for the same reason: this says
  # only whether a credential exists, never what it is, and `sensitive` keeps even
  # that "set"/"none" answer masked in the UI. There is nothing more to show —
  # the token never reaches the rendered config.toml, only its name does.
  item {
    key       = "github token"
    value     = var.github_token != "" ? "set" : "none"
    sensitive = true
  }
}

resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"

  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }

  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }

  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }

  labels {
    label = "coder.workspace_name"
    value = lower(data.coder_workspace.me.name)
  }
}

# DinD topology, all count-gated so a workspace that leaves the toggle off
# provisions exactly what it provisioned before this feature existed.
locals {
  # Only the exact string "true" enables it. Erring towards disabled is
  # deliberate: what the gate protects is a privileged container.
  dind_enabled = data.coder_parameter.dind.value == "true"

  dind_image = "docker:29.8.1-dind"
  dind_alias = "dind"
  dind_host  = "tcp://${local.dind_alias}:2375"
  # Same shape as docker_volume.home's name: coder- prefix plus the workspace id.
  dind_network = "coder-${data.coder_workspace.me.id}-dind"
  # Separate from the network name so `docker volume ls` reads unambiguously.
  dind_store   = "coder-${data.coder_workspace.me.id}-dind-lib"
  dind_sidecar = "coder-${data.coder_workspace.me.id}-dind-sidecar"
}

# Inspects the local image store and never pulls, which is what this stack wants
# (see scripts/build-dev-image.sh: a registry pull at workspace-create time is
# untestable on a LAN box with no internet). Chosen over the docker_image
# resource with keep_locally, which pulls on a miss *mid-apply* and would leave
# a half-built workspace behind; this fails at plan time, before anything is
# created, with "did not find docker image 'docker:29.8.1-dind'". Counter that
# with: docker pull docker:29.8.1-dind
data "docker_image" "dind" {
  count = local.dind_enabled ? 1 : 0
  name  = local.dind_image
}

# Per-workspace, not shared: two workspaces on one network could reach each
# other's daemon and therefore each other's builds.
#
# `internal` stays false (the provider default). An internal network gets no
# gateway route, so the host-gateway entry on the workspace container below
# would resolve but not answer — verified from a workspace-style container on a
# plain bridge network, where host.docker.internal resolves to the bridge
# gateway and the Coder server's plain listener on 3002 accepts the connection.
# Making this internal would strand the agent and the workspace would never
# become ready.
resource "docker_network" "dind" {
  count  = local.dind_enabled ? 1 : 0
  name   = local.dind_network
  driver = "bridge"

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }

  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }

  labels {
    label = "coder.workspace_name"
    value = lower(data.coder_workspace.me.name)
  }
}

# The inner daemon's image store. Without this every workspace start re-pulls
# every image the builds used, which defeats the point on a slow link.
# Not gated on start_count, so it survives a stop and is reused by the next
# start; it is torn down only when the workspace is deleted or rebuilt with
# DinD off.
resource "docker_volume" "dind_store" {
  count = local.dind_enabled ? 1 : 0
  name  = local.dind_store

  # Same protection as docker_volume.home: a rebuild must never lose the store.
  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }

  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }

  labels {
    label = "coder.workspace_name"
    value = lower(data.coder_workspace.me.name)
  }
}

# Privileged by necessity: the inner daemon needs mount, cgroup and network
# namespace control (it came up as storage-driver=overlayfs on cgroupv2=2 here).
# Gated on start_count as well as the toggle, exactly like the workspace
# container, so a stopped workspace leaves no privileged daemon running.
resource "docker_container" "dind" {
  count = local.dind_enabled ? data.coder_workspace.me.start_count : 0
  name  = local.dind_sidecar
  # The data source's id, not the tag: create_docker_container pulls whenever a
  # tag is not already resolvable, so passing the sha256 id is what keeps the
  # "never pulls" promise of the data source all the way through apply.
  image      = data.docker_image.dind[0].id
  privileged = true

  # A private cgroup namespace keeps the inner daemon's view of /sys/fs/cgroup
  # consistent with what it sees as its own cgroup; host would let it read the
  # whole host hierarchy.
  cgroupns_mode = "private"
  restart       = "unless-stopped"

  # Must be the EMPTY value, not a size: DOCKER_TLS_CERTDIR="" is what makes the
  # entrypoint skip TLS and serve plain tcp://0.0.0.0:2375. DOCKER_TLS_CERTSIZE=0
  # does not do this — the daemon then listens on 2376 with TLS only and the
  # client fails with "Cannot connect to the Docker daemon at tcp://dind:2375".
  # Docker logs a deprecation warning about unauthenticated TCP; that is
  # acceptable because 2375 is reachable only from this workspace's network.
  env = ["DOCKER_TLS_CERTDIR="]

  # The provider takes MBs here despite the Docker API taking bytes: 1024
  # lands as HostConfig.ShmSize = 1073741824 (1 GiB), which inner builds want.
  shm_size = 1024

  volumes {
    container_path = "/var/lib/docker"
    volume_name    = docker_volume.dind_store[0].name
    read_only      = false
  }

  # The alias, not the image's own "docker" hostname: Docker's embedded DNS
  # answers for network aliases and container names, so linking by hostname
  # failed here with "lookup docker on 127.0.0.11:53: server misbehaving".
  networks_advanced {
    name    = docker_network.dind[0].name
    aliases = [local.dind_alias]
  }

  healthcheck {
    test         = ["CMD-SHELL", "docker version >/dev/null 2>&1 || exit 1"]
    interval     = "15s"
    timeout      = "5s"
    start_period = "10s"
    retries      = 5
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }

  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }

  labels {
    label = "coder.workspace_name"
    value = lower(data.coder_workspace.me.name)
  }
}

# One Grok Build profile per *user*, mounted into every workspace that user owns,
# instead of one ~/.grok per workspace that dies on a rebuild — but only in
# `shared` mode: the grok_profile_mode parameter above decides. `private` gives that
# workspace a private ~/.grok on its own home volume, which dies with it.
#
# The volume is deliberately NOT declared as a docker_volume resource. A
# declared volume would be one resource per workspace, which is the opposite of
# sharing, and a workspace stop would then have to unmount a volume another of
# the same user's workspaces still holds open ("volume is in use"). Referencing
# it by plain string name means Docker creates it on the first container start
# that names it and reuses it afterwards.
locals {
  # Anything but "shared" — "private" included — means no extra volumes entry at
  # all, so the container spec is byte-identical to what it was before the
  # profile volume existed. lower() + trimspace() so a form value typed as
  # "Shared " still reads as shared instead of silently provisioning private.
  grok_profile_shared = lower(trimspace(data.coder_parameter.grok_profile_mode.value)) == "shared"
  # Keyed by owner id, not by workspace id: that is the whole privacy boundary.
  grok_profile_volume = "grok-profile-${data.coder_workspace_owner.me.id}"
  # Editor settings, same sharing rule and the same reason this is not a
  # docker_volume resource: one volume per owner, created on first use, and a
  # workspace stop must not try to unmount a volume another workspace holds.
  # Not gated on grok_profile_mode — these are editor preferences, not the CLI
  # profile, and every workspace this owner has is supposed to share them.
  vscode_settings_volume = "vscode-settings-${data.coder_workspace_owner.me.id}"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count

  # The dropdown decides the image; var.image only seeds its default, so the
  # rendered container always matches what the create form showed.
  image    = data.coder_parameter.workspace_image.value
  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = data.coder_workspace.me.name

  # Two rewrites, both load-bearing, on the provider-rendered init script:
  # the inner one points a loopback access URL at the Docker host gateway, and
  # the outer one swaps a public access URL (CODER_ACCESS_URL behind Traefik
  # and Authelia) for the plain listener on that gateway. Without the second,
  # agents hairpin through Cloudflare and Authelia, which rejects their
  # token-only requests; the Coder server has no agent-facing URL setting, so
  # this is the only seam. Skipped when var.coder_agent_url is empty.
  entrypoint = ["sh", "-c", var.coder_agent_url == "" ? replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal") : replace(replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"), data.coder_workspace.me.access_url, var.coder_agent_url)]

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }

  # Nested inside the mount above, not instead of it: Docker resolves the
  # /home/coder volume first and then covers /home/coder/.grok with the owner's
  # shared profile volume, so the CLI's state tree is one directory tree shared
  # live by every workspace that user owns. Only in `shared` mode — in `private`
  # mode .grok stays a plain folder on this workspace's own home volume. Gated on
  # local.grok_profile_shared because an empty for_each emits no volumes entry at
  # all — with the mode off the planned container is exactly the pre-profile shape.
  dynamic "volumes" {
    for_each = local.grok_profile_shared ? [1] : []
    content {
      container_path = "/home/coder/.grok"
      volume_name    = local.grok_profile_volume
      read_only      = false
    }
  }

  # Nested the same way as .grok above: the home volume is mounted first, then
  # this covers /home/coder/.shared/vscode with the owner's one settings
  # volume. startup.sh.tftpl copies the seed in only while settings.json is
  # absent and symlinks code-server's User settings at it, so an edit in any
  # workspace — or from the host, by mounting vscode-settings-<owner-id> — is
  # the file every workspace opens. Read-write on purpose.
  volumes {
    container_path = "/home/coder/.shared/vscode"
    volume_name    = local.vscode_settings_volume
    read_only      = false
  }

  # Only the sidecar reference matters: it makes Terraform attach the daemon to
  # the network before starting the workspace, so `dind` already resolves in the
  # embedded DNS the moment someone types a docker command. The reference is to
  # a count-gated resource, so it is an empty list — and a no-op — when DinD is
  # off. The daemon's own health is reported by its healthcheck instead of
  # gating startup; nothing in startup.sh.tftpl talks to Docker.
  depends_on = [docker_container.dind]

  # Left empty when DinD is off, which leaves network_mode = "bridge" (the
  # provider default) as the only attachment — i.e. today's behaviour, and a
  # byte-identical plan. Once a networks_advanced block appears the provider
  # stops letting network_mode alone do the attaching, so bridge has to be
  # listed explicitly next to the DinD network rather than assumed. Verified
  # against the host daemon: bridge + a second network both attach, and the
  # host-gateway entry above still lands in /etc/hosts.
  dynamic "networks_advanced" {
    for_each = local.dind_enabled ? [1] : []
    content {
      name = "bridge"
    }
  }

  dynamic "networks_advanced" {
    for_each = local.dind_enabled ? [1] : []
    content {
      name = docker_network.dind[0].name
    }
  }

  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }

  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }

  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}
