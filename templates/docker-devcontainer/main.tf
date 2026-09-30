terraform {
  required_providers {
    # Pinned to what .terraform.lock.hcl records, so a provider release cannot
    # break a rebuild. The coder provider 2.x requires a Coder server >= 2.18
    # (this stack runs v2.36.6); coder_devcontainer itself needs >= 2.21.
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

# The whole create form is one question: which repository to open. The repo, not
# this repo, decides the toolchain — its .devcontainer/devcontainer.json (and the
# Dockerfile or image that file names) is built and started by the Coder agent
# through @devcontainers/cli.
data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git repository"
  description  = "Clone URL of the repository to open. It must contain .devcontainer/devcontainer.json, otherwise the dev container never starts and only the workspace itself comes up. The clone runs unauthenticated as the workspace user — a private repo needs git credentials inside the workspace first. Everything the repo builds runs on this workspace's privileged docker:29.8.1-dind sidecar, so a Dockerfile in the repo is root-equivalent on the stack host: only point this at repositories you trust."
  type         = "string"
  form_type    = "input"
  # Mutable: switching repository is a re-clone plus a devcontainer build, not a
  # different topology, so it does not cost a rebuild the way docker-dev's DinD
  # toggle does.
  mutable = true
  default = var.repo_url
  order   = 1
}

# One preset is enough when the form has one question: it makes the default
# repository a one-click workspace instead of requiring the input to be typed.
# Keys are parameter *names* (display_name is UI-only and would be ignored).
data "coder_workspace_preset" "devcontainer_default" {
  name        = "Devcontainer default"
  description = "Clone the template's default repository and start its .devcontainer/devcontainer.json on the DinD sidecar."
  default     = true

  parameters = {
    (data.coder_parameter.repo_url.name) = var.repo_url
  }
}

locals {
  # THE load-bearing trick of this template. The devcontainer CLI always
  # bind-mounts the workspace folder into the dev container it creates, and a
  # bind mount's source is resolved by the daemon that runs the container — here
  # that is the DinD sidecar, not the daemon that runs the workspace. So the
  # clone must live at a path that exists *inside the sidecar* too, at the exact
  # same path, or the build fails with "bind source path does not exist".
  # A host_path bind of one directory into both containers is what achieves
  # that; named volumes cannot, because a volume is a daemon-local object and
  # does not cross from the workspace's daemon to the sidecar's.
  dc_host_dir = "/srv/coder-devcontainers/${data.coder_workspace.me.id}"

  # Folder name the clone lands in. Derived here for coder_devcontainer's
  # workspace_folder and re-derived in shell by startup.sh.tftpl, which is the
  # one that actually runs git — the two derivations must agree or the agent
  # looks for a devcontainer.json in a folder that was never cloned. Both do:
  # split on "/", drop empty segments (so a trailing slash is harmless), take
  # the last one, drop a trailing ".git", and map every character outside
  # [A-Za-z0-9._-] to "-" (which also keeps "../" out of a root-owned bind).
  repo_leaf = element(concat(compact(split("/", trimspace(data.coder_parameter.repo_url.value))), [""]), -1)
  repo_stripped = replace(
    replace(local.repo_leaf, "\\.git$", ""),
    "[^A-Za-z0-9._-]", "-",
  )
  repo_folder = can(regex("^[A-Za-z0-9]", local.repo_stripped)) ? local.repo_stripped : "repo"

  # DinD topology. Same shape as docker-dev's opt-in version, minus the toggle:
  # a devcontainer workspace is useless without a daemon the CLI can reach.
  dind_image = "docker:29.8.1-dind"
  dind_alias = "dind"
  dind_host  = "tcp://${local.dind_alias}:2375"
  # Same shape as docker_volume.home's name: coder- prefix plus the workspace id.
  dind_network = "coder-${data.coder_workspace.me.id}-dind"
  # Separate from the network name so `docker volume ls` reads unambiguously.
  dind_store   = "coder-${data.coder_workspace.me.id}-dind-lib"
  dind_sidecar = "coder-${data.coder_workspace.me.id}-dind-sidecar"
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # Without this a failed container hangs the workspace until the provider
  # default; a wrong image tag or a broken init script is otherwise invisible.
  connection_timeout = 300

  # Gate login on the setup stages finishing, so nobody lands in a half-built
  # home directory with no Grok CLI or VS Code settings — and, in this
  # template, so the clone has landed before the agent starts the dev container.
  startup_script_behavior = "blocking"

  # Agent-bar buttons. These are driven here, not by any CODER_*IDE* server
  # flag (no such flag family exists in v2.36). code-server for the dev
  # container comes from the devcontainer's own sub-agent.
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
    vscode_settings = templatefile("${path.module}/settings.json.tftpl", {
      litellm_url = var.litellm_url
      litellm_key = var.litellm_key
    })
    grok_config = templatefile("${path.module}/grok-config.toml.tftpl", {
      litellm_url        = var.litellm_url
      grok_default_model = var.grok_default_model
    })
    # Injected verbatim into the script, which is safe enough: this is the
    # workspace creator's own input and they already hold a shell in this
    # container. The script quotes it anyway so a URL with spaces survives.
    repo_url = data.coder_parameter.repo_url.value
    dc_dir   = local.dc_host_dir
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
    # Unconditional, unlike docker-dev's conditional injection: the devcontainer
    # CLI must talk to the sidecar's daemon, and the agent merges manifest env into
    # the shell environment it uses for that invocation (agent.go wires
    # agentssh.CommandEnv into the containers API), so both `devcontainer` and a
    # user's `docker` reach tcp://dind:2375 rather than a socket the workspace
    # never had. Pointing DOCKER_HOST at a daemon that does not exist is not a
    # risk here: this template always provisions the sidecar.
    DOCKER_HOST = local.dind_host
  })
}

# Ordering guard, not a starter. The agent runs every run_on_start script — the
# startup_script alias included — concurrently, and only afterwards calls
# containerAPI.Start() and creates the dev containers (agent.go: ExecuteStartScripts
# first, createDevcontainer after). So waiting for the daemon here is what keeps
# `devcontainer up` from racing a sidecar that has not opened 2375 yet; nothing
# here starts a devcontainer, coder_devcontainer.repo owns that.
resource "coder_script" "dind_bootstrap" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  display_name = "Start Docker-in-Docker daemon check"
  icon         = "/icon/docker.svg"
  run_on_start = true
  # Backstop for a docker CLI that hangs rather than fails (a socket that accepts
  # but never answers); the retry loop below is what normally bounds this.
  timeout = 180

  script = <<-EOT
    #!/bin/bash
    set -u
    if ! command -v docker >/dev/null 2>&1; then
      echo "the docker CLI is missing — this template needs the golden image (scripts/build-dev-image.sh), which ships the client" >&2
      exit 1
    fi
    # Explicit -H rather than relying on the inherited DOCKER_HOST, so the log
    # line below always names the endpoint that was actually probed.
    deadline=$(( $(date +%s) + 120 ))
    while ! docker -H ${local.dind_host} version >/dev/null 2>&1; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "the DinD daemon at ${local.dind_host} never answered 'docker version' within 120s" >&2
        echo "from the stack host, inspect the sidecar and its logs: docker ps -a --filter name=${local.dind_sidecar}" >&2
        exit 1
      fi
      sleep 2
    done
    echo "DinD daemon is answering at ${local.dind_host}"
  EOT
}

# The Coder built-in: the agent drives @devcontainers/cli against this folder
# during startup and exposes the result as a devcontainer sub-agent with its own
# terminal and apps. count matches the agent's lifecycle so a stopped workspace
# has nothing left to autostart.
resource "coder_devcontainer" "repo" {
  count    = data.coder_workspace.me.start_count
  agent_id = coder_agent.main.id
  # No config_path: let the CLI find .devcontainer/devcontainer.json itself, so a
  # repo that uses the other legal locations (docker-compose.yml, .devcontainer/)
  # behaves the same as it does in VS Code.
  workspace_folder = "${local.dc_host_dir}/${local.repo_folder}"
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
    value = var.image
  }

  item {
    key   = "repo"
    value = data.coder_parameter.repo_url.value
  }

  item {
    key   = "devcontainer folder"
    value = coder_devcontainer.repo[0].workspace_folder
  }

  item {
    key   = "litellm"
    value = var.litellm_url
  }

  item {
    key   = "grok default model"
    value = var.grok_default_model
  }

  # Always on in this template, so the item states which daemon the devcontainer
  # CLI is talking to rather than whether one exists.
  item {
    key   = "docker-in-docker"
    value = "on (${local.dind_host})"
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

# Inspects the local image store and never pulls, which is what this stack wants
# (see scripts/build-dev-image.sh: a registry pull at workspace-create time is
# untestable on a LAN box with no internet). Chosen over the docker_image
# resource with keep_locally, which pulls on a miss *mid-apply* and would leave
# a half-built workspace behind; this fails at plan time, before anything is
# created, with "did not find docker image 'docker:29.8.1-dind'". Counter that
# with: docker pull docker:29.8.1-dind
data "docker_image" "dind" {
  name = local.dind_image
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

# The inner daemon's image store. Without this every workspace start re-builds
# the repo's dev image from scratch, which is the slowest part of a devcontainer
# workspace. Not gated on start_count, so it survives a stop and is reused by
# the next start; it is torn down only when the workspace is deleted.
resource "docker_volume" "dind_store" {
  name = local.dind_store

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
# namespace control (it came up as storage-driver=overlayfs on cgroupv2=2 here),
# and the repo's own Dockerfile is what builds on it — which is why the create
# form warns about trusting the repository. Gated on start_count exactly like the
# workspace container, so a stopped workspace leaves no privileged daemon.
resource "docker_container" "dind" {
  count = data.coder_workspace.me.start_count
  name  = local.dind_sidecar
  # The data source's id, not the tag: create_docker_container pulls whenever a
  # tag is not already resolvable, so passing the sha256 id is what keeps the
  # "never pulls" promise of the data source all the way through apply.
  image      = data.docker_image.dind.id
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
    volume_name    = docker_volume.dind_store.name
    read_only      = false
  }

  # Same host bind as the workspace container below, at the same container path:
  # this is what lets the daemon resolve the bind source the devcontainer CLI
  # asks it to mount (see locals.dc_host_dir). The directory does not have to
  # exist on the host beforehand — Docker creates a missing bind source itself,
  # root-owned; startup.sh.tftpl chowns it for the workspace user.
  volumes {
    container_path = local.dc_host_dir
    host_path      = local.dc_host_dir
    read_only      = false
  }

  # The alias, not the image's own "docker" hostname: Docker's embedded DNS
  # answers for network aliases and container names, so linking by hostname
  # failed here with "lookup docker on 127.0.0.11:53: server misbehaving".
  networks_advanced {
    name    = docker_network.dind.name
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

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count

  # var.image, not a dropdown: the workspace container is only the launcher and
  # the clone target here — the editor's real environment is whatever the repo's
  # devcontainer.json builds on the sidecar.
  image    = var.image
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

  # The identical bind the sidecar got above, so the devcontainer CLI and the
  # daemon agree on where the workspace folder lives. Writeable on both sides:
  # the clone happens in the workspace, the dev container bind-mounts it back.
  volumes {
    container_path = local.dc_host_dir
    host_path      = local.dc_host_dir
    read_only      = false
  }

  # Only the sidecar reference matters: it makes Terraform attach the daemon to
  # the network before starting the workspace, so `dind` already resolves in the
  # embedded DNS the moment someone types a docker command. The daemon's own
  # health is reported by its healthcheck and re-proved at startup by
  # coder_script.dind_bootstrap, which is what `devcontainer up` waits behind.
  depends_on = [docker_container.dind]

  # Both attachments have to be listed: once a networks_advanced block appears
  # the provider stops letting network_mode alone do the attaching, so bridge is
  # spelled out next to the DinD network rather than assumed. Verified against
  # the host daemon: bridge + a second network both attach, and the host-gateway
  # entry above still lands in /etc/hosts.
  networks_advanced {
    name = "bridge"
  }

  networks_advanced {
    name = docker_network.dind.name
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
