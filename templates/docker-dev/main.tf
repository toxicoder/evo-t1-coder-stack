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

  # The VS Code settings payload, rendered once and reused: the code_server
  # module decodes it into its settings inputs; the startup script no longer
  # seeds any settings file, and code-server never reads ~/.config/Code.
  vscode_settings = templatefile("${path.module}/settings.json.tftpl", {
    litellm_url = var.litellm_url
    litellm_key = var.litellm_key
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
  display_apps {
    vscode                 = true
    vscode_insiders        = false
    web_terminal           = true
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
    grok_config = templatefile("${path.module}/grok-config.toml.tftpl", {
      litellm_url        = var.litellm_url
      grok_default_model = var.grok_default_model
    })
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
    # Local model aliases, for shell prompts, Makefiles and CI overrides.
    GROK_DEFAULT_MODEL = var.grok_default_model
    # Coder Agents (the `agents` EXPERIMENT, gated by CODER_EXPERIMENTS in
    # docker-compose.yml) discovers per-workspace skills and instructions from
    # exactly these keys — spelling verified against the v2.36.6 binary and its
    # agentcontextconfig source: the two _DIRS keys are comma-separated
    # DIRECTORIES, and _FILE names the file to look for inside each of them
    # (default AGENTS.md), not a path. Setting any of these keys REPLACES its
    # upstream default, so the defaults (~/.coder, ~/.coder/skills,
    # .agents/skills, relative to the agent's working dir) are kept and the
    # seeded /home/coder/.agents paths ride along with them. One name only
    # where AGENTS.md used to be: rename a seeded AGENTS.md over INSTRUCTIONS.md
    # here if that trade is wrong for you, rather than adding a second name.
    # The files themselves are written by startup.sh.tftpl on every boot, but
    # only while they are absent, so a hand-edited copy survives restarts.
    CODER_AGENT_EXP_SKILLS_DIRS       = "~/.coder/skills,.agents/skills,/home/coder/.agents/skills"
    CODER_AGENT_EXP_INSTRUCTIONS_DIRS = "~/.coder,/home/coder/.agents"
    CODER_AGENT_EXP_INSTRUCTIONS_FILE = "INSTRUCTIONS.md"
    },
    # Only present when DinD is on: a DOCKER_HOST that pointed at a daemon that
    # does not exist would make every docker command in the workspace fail with
    # a confusing connection error instead of the plain "command not found".
    local.dind_enabled ? { DOCKER_HOST = local.dind_host } : {},
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
  version        = "~> 1.0"
  agent_id       = coder_agent.main.id
  folder         = "/home/coder"
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

  # code-server reads its User/Machine settings from its user-data-dir, not
  # from ~/.config/Code — the module merges this map into
  # ~/.local/share/code-server/User/settings.json and .../Machine/settings.json
  # on startup (per-key merge, so user-edited files survive). Same JSON goes
  # to both files; the Machine copy is the fallback if the key resolves as
  # machine-scoped in the editor's settings scope.
  settings         = jsondecode(local.vscode_settings)
  machine_settings = jsondecode(local.vscode_settings)
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

  item {
    key   = "litellm"
    value = var.litellm_url
  }

  item {
    key   = "grok default model"
    value = var.grok_default_model
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

# One Grok Build profile per *user*, mounted into every workspace that user
# owns, instead of one ~/.grok per workspace that dies on a rebuild.
#
# The volume is deliberately NOT declared as a docker_volume resource. A
# declared volume would be one resource per workspace, which is the opposite of
# sharing, and a workspace stop would then have to unmount a volume another of
# the same user's workspaces still holds open ("volume is in use"). Referencing
# it by plain string name means Docker creates it on the first container start
# that names it and reuses it afterwards.
locals {
  # Off => no extra volumes entry at all, so the container spec is byte-identical
  # to what it was before the profile volume existed.
  grok_profile_enabled = var.grok_profile_share
  # Keyed by owner id, not by workspace id: that is the whole privacy boundary.
  grok_profile_volume = "grok-profile-${data.coder_workspace_owner.me.id}"
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
  # live by every workspace that user owns. Gated on grok_profile_share because
  # an empty for_each emits no volumes entry at all — with the knob off the
  # planned container is exactly the pre-profile shape.
  dynamic "volumes" {
    for_each = local.grok_profile_enabled ? [1] : []
    content {
      container_path = "/home/coder/.grok"
      volume_name    = local.grok_profile_volume
      read_only      = false
    }
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
