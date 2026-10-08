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

# The create form asks two questions: which repository to open, and whether to
# build that repository's dev container. The repo, not this repo, decides the
# toolchain — its .devcontainer/devcontainer.json (and the Dockerfile or image
# that file names) is built and started by the Coder agent through
# @devcontainers/cli, which is what the question below decides.
data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git repository"
  description  = "Clone URL of the repository to open. With the dev-container toggle below on it must contain .devcontainer/devcontainer.json, otherwise the build fails and the workspace comes up without an editor; with the toggle off any repository works and the editor opens the clone directly. The clone runs unauthenticated as the workspace user — a private repo needs git credentials inside the workspace first. Everything the repo builds runs on this workspace's privileged docker:29.8.1-dind sidecar, so a Dockerfile in the repo is root-equivalent on the stack host: only point this at repositories you trust."
  type         = "string"
  form_type    = "input"
  # Mutable: switching repository is a re-clone plus a devcontainer build, not a
  # different topology, so it does not cost a rebuild the way docker-dev's DinD
  # toggle does.
  mutable = true
  default = var.repo_url
  order   = 1
}

# The second question: whether to attempt the devcontainer build at all. Without
# it there was no answer for a repository that ships no devcontainer.json — the
# build fails, and because code-server hangs off the dev-container sub-agent,
# such a workspace got no editor and no terminal profile at all.
data "coder_parameter" "use_devcontainer" {
  name         = "use_devcontainer"
  display_name = "Build repo's dev container"
  description  = "Build the repository's own .devcontainer/devcontainer.json on the DinD sidecar and run code-server inside the result. That file is mandatory for this to work: without it the build fails and no dev container, hence no editor, ever appears. Choose No for a repository without one and the editor and Grok run on the plain workspace container instead."
  type         = "bool"
  # Same reason docker-dev gives for its dind toggle: "radio" is only legal for a
  # bool once options exist, and the options are what put wording on each choice
  # (a switch would render a bare on/off toggle with no description).
  form_type = "radio"
  # Off means the dev container never exists, which is a different topology, not
  # an edit — one container instead of two, and the editor on the other side of
  # that line. Fixed at create time for the same reason docker-dev rebuilds.
  mutable = false
  default = "true"
  order   = 2

  # Values must stay the literal strings "true"/"false": .value is always a
  # string, and the preset below has to set the same value to match.
  option {
    name        = "Yes"
    value       = "true"
    description = "Build the dev container from the repository's own devcontainer.json and run code-server inside it. Requires the repository to contain that file, otherwise the build fails and the editor never appears — for repositories without one, choose No."
  }

  option {
    name        = "No"
    value       = "false"
    description = "Skip the build: code-server and Grok run on the plain workspace container, opened on the cloned folder."
  }
}

# The two Grok-config knobs, per workspace. Both exist because the stack-wide
# answer used to be the only answer: the ~/.grok mount was all-or-nothing for
# every workspace a user owns, and the model alias was frozen in the template.
# Neither is a topology question, so unlike the toggle above these two cost a
# rebuild for a different reason — see each block below.

# Which ~/.grok this workspace gets. Immutable for the same reason the dev-container
# toggle is: in one mode the nested mount exists and in the other it does not, so
# an in-place edit would change the container's mount topology under a running
# agent. The default comes from the template variable, so an operator can flip the
# whole stack with `--var grok_profile_mode` on a push.
data "coder_parameter" "grok_profile_mode" {
  name         = "grok_profile_mode"
  display_name = "Grok profile"
  description  = "Where this workspace's ~/.grok lives. Shared = one per-user profile volume, shared by every workspace this owner owns: config.toml, the MCP caches, memory and skills are shared between them, and the last workspace started re-renders that one shared config.toml. Private = this workspace gets its own private ~/.grok on its own home volume, so its config.toml (and its memory and skills) are independent of the owner's other workspaces and die with the workspace. Changing this needs a rebuild: the nested mount either exists or it does not."
  type         = "string"
  # "dropdown", not a text field, because only these two spellings mean anything;
  # anything else reads as private, which is the safe half of the mistake (it
  # leaks nothing, it just costs sharing).
  form_type = "dropdown"
  mutable   = false
  default   = var.grok_profile_mode
  order     = 3

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

# The model alias, which the create form could not express before (it was a
# stack-wide variable, and a per-workspace one only made sense once the profile
# could be private). It differs observably per workspace only while the profile
# is private, or while config.toml is unmanaged: on a shared profile volume one
# file serves all of the owner's workspaces and whoever starts last re-renders it
# for everyone. The options are the aliases grok-config.toml.tftpl declares, and
# local.model_options below keeps the provider's default-must-be-an-option rule
# true for a custom `--var grok_default_model`.
data "coder_parameter" "grok_default_model" {
  name         = "grok_default_model"
  display_name = "Grok default model"
  description  = "The model alias new Grok Build sessions in this workspace start on. Written into the rendered ~/.grok/config.toml as [models] default, and into the workspace environment as GROK_DEFAULT_MODEL. Only the Spark vLLM aliases return a real tool_calls array on this runtime; the Arc aliases answer tool calls as plain text, so they suit chat and summarisation."
  type         = "string"
  form_type    = "dropdown"
  # Fixed at create time for the same reason as the profile mode: the file that
  # carries the alias is rewritten on every start, so this dropdown is the only
  # honest seam, and a silent model swap under a running workspace is not worth it.
  mutable = false
  default = var.grok_default_model
  order   = 4

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
# already holds a shell in that container, so nothing is gained by restricting it.
data "coder_parameter" "grok_config_extra" {
  name         = "grok_config_extra"
  display_name = "Grok config extras"
  description  = "Free-form TOML appended verbatim to the rendered ~/.grok/config.toml, under its own comment header. Use it for per-workspace keys the managed block does not set — an extra [mcp_servers.*] entry, a permission deny list, a different subagent cap. This trusts whoever fills it in, exactly like the Git repository field above: this workspace's owner already holds a shell in that container. Leave it empty unless needed; empty renders nothing at all."
  type         = "string"
  # Mutable because it writes one text file, not topology: no rebuild has to
  # happen to take a key back out again, and a restart re-renders the whole file.
  form_type = "textarea"
  mutable   = true
  default   = ""
  order     = 5
}

# One preset per answer to the second question, so the default repository never
# has to be typed and the no-devcontainer path is one click too. Keys are
# parameter *names* (display_name is UI-only and would be ignored); an unset key
# keeps the parameter's own default, which is why only plain_clone names the
# toggle — the three parameters above are deliberately not pinned here, so a
# preset never silently picks a Grok profile or a model for the person clicking it.
data "coder_workspace_preset" "devcontainer_default" {
  name        = "Devcontainer default"
  description = "Clone the template's default repository and start its .devcontainer/devcontainer.json on the DinD sidecar."
  default     = true

  parameters = {
    (data.coder_parameter.repo_url.name) = var.repo_url
  }
}

# The same repository, for a repository that brings no devcontainer.json of its
# own (and for anyone who wants the editor on the plain container regardless).
data "coder_workspace_preset" "plain_clone" {
  name        = "Plain clone"
  description = "Clone the default repository and open the editor on it in the plain workspace container; no dev container build."
  default     = false

  parameters = {
    (data.coder_parameter.repo_url.name)         = var.repo_url
    (data.coder_parameter.use_devcontainer.name) = "false"
  }
}

# The create form's model dropdown needs one option per alias, and the provider
# rejects a parameter whose default is not among its options. Same rule and same
# trick as docker-dev's image_options: a custom `--var grok_default_model=<key>`
# becomes an option of its own instead of being dropped, which would otherwise
# either fail the plan or leave the form showing `agent` while the build used
# something else. The descriptions are the ones the [model.*] blocks in
# grok-config.toml.tftpl carry, so the form says what the config says.
locals {
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
      description = "Fast Arc fallback; completion-style on this runtime (no tool_calls)"
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

  # The same folder as one path, for every consumer that has to name it: the
  # devcontainer build, code-server's window (in either mode) and the
  # workspace-info metadata. Spelled out here rather than indexed off
  # coder_devcontainer.repo[0] so the metadata survives the toggle being off —
  # that resource does not exist then, and its count would be an empty tuple.
  project_folder = "${local.dc_host_dir}/${local.repo_folder}"

  # Only the exact string "true" builds a dev container, per docker-dev's
  # dind_enabled rule: a stray or misspelled value errs towards the cheaper
  # topology. The plain_clone preset below is what hands in "false".
  use_dc = data.coder_parameter.use_devcontainer.value == "true"

  # The VS Code settings payload, rendered once and reused: the code_server
  # module decodes it into its settings inputs; the startup script no longer
  # seeds any settings file, and code-server never reads ~/.config/Code.
  vscode_settings = templatefile("${path.module}/settings.json.tftpl", {
    litellm_url = var.litellm_url
    litellm_key = var.litellm_key
  })

  # DinD topology. Same shape as docker-dev's opt-in version, minus the toggle:
  # the daemon is always on here, because a devcontainer workspace is useless
  # without one and a plain-mode workspace still wants a daemon its own `docker`
  # commands and the devcontainer CLI can reach.
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
  # flag (no such flag family exists in v2.36). display_apps.vscode is the
  # desktop helper: a locally installed VS Code plus the coder.coder-remote
  # extension. The in-browser editor is the code-server app attached to the
  # dev-container sub-agent below. web_terminal stays off on purpose: the
  # built-in terminal hardwires to coder_agent.dir, which is unset here and
  # therefore /home/coder, and the custom coder_app below replaces it with one
  # that opens on the clone (same path, shared bind, in both toggle modes) —
  # the documented replace pattern.
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
    # resolve, so all five are declared together. github_token is a *boolean* gate
    # in there — it only decides whether the [mcp_servers.github] block appears —
    # so no token bytes are ever interpolated into the rendered script or into
    # config.toml; the rendered file names GH_TOKEN and the CLI expands that
    # reference from the environment.
    grok_config = templatefile("${path.module}/grok-config.toml.tftpl", {
      litellm_url        = var.litellm_url
      grok_default_model = data.coder_parameter.grok_default_model.value
      grok_config_extra  = data.coder_parameter.grok_config_extra.value
      github_token       = var.github_token
      github_mcp         = var.github_mcp && var.github_token != ""
    })
    # Injected verbatim into the script, which is safe enough: this is the
    # workspace creator's own input and they already hold a shell in this
    # container. The script quotes it anyway so a URL with spaces survives.
    repo_url = data.coder_parameter.repo_url.value
    dc_dir   = local.dc_host_dir
    # What the clone preflight in the script has to say about a repo that ships
    # no devcontainer.json: a fallback it chose, or a build that will now fail.
    build_devcontainer = local.use_dc ? "yes" : "no"
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
    # The same alias the rendered config.toml puts in [models] default, for shell
    # prompts, Makefiles and CI overrides. Both read the create-form parameter, so
    # inside one workspace the two cannot disagree — what a *shared* profile volume
    # can still do is carry another workspace's alias, see startup.sh.tftpl.
    GROK_DEFAULT_MODEL = data.coder_parameter.grok_default_model.value
    # Unconditional, unlike docker-dev's conditional injection: the devcontainer
    # CLI must talk to the sidecar's daemon, and the agent merges manifest env into
    # the shell environment it uses for that invocation (agent.go wires
    # agentssh.CommandEnv into the containers API), so both `devcontainer` and a
    # user's `docker` reach tcp://dind:2375 rather than a socket the workspace
    # never had. That holds in either mode: the toggle only decides whether the
    # CLI is driven at all, and a plain-mode workspace still gets a daemon for its
    # own docker commands. Pointing DOCKER_HOST at a daemon that does not exist is
    # not a risk here: this template always provisions the sidecar.
    DOCKER_HOST = local.dind_host
    # Same trio as docker-dev/main.tf, same verification (v2.36.6 binary + its
    # agentcontextconfig source): the _DIRS keys list DIRECTORIES and _FILE
    # names the file to look for inside each of them (default AGENTS.md), not
    # a path. Defaults are replaced, not appended to, by these keys — so the
    # upstream defaults (~/.coder, ~/.coder/skills, .agents/skills, relative to
    # the agent's working dir) stay in the lists and /home/coder/.agents rides
    # along. That matters here specifically: the dev container's own working
    # dir is the cloned folder under /srv/coder-devcontainers/..., where a
    # cwd-relative .agents/skills would not find the seeded skill.
    CODER_AGENT_EXP_SKILLS_DIRS       = "~/.coder/skills,.agents/skills,/home/coder/.agents/skills"
    CODER_AGENT_EXP_INSTRUCTIONS_DIRS = "~/.coder,/home/coder/.agents"
    CODER_AGENT_EXP_INSTRUCTIONS_FILE = "INSTRUCTIONS.md"
    },
    # An empty token adds NEITHER key, so a workspace that declares no GitHub
    # credential gets exactly the environment it got before. When present the
    # token travels env-only, like LITELLM_API_KEY above: startup.sh.tftpl seeds
    # the gh/git credential helper from it, so `git push` and `gh pr create` can
    # work with the token never written to a file, and the rendered config.toml
    # only names GH_TOKEN by name. Scope, stated because this repo verifies
    # neither half of it: the pair lands on the *agent's* environment, which is
    # what the workspace's shells, run_on_start scripts and coder_exec/SSH
    # sessions inherit, and `coder_devcontainer.repo` below sets no env of its
    # own — so nothing here claims that a dev container built on the sidecar
    # receives either key. Both the env pair and the ~/.grok mount stop at the
    # workspace container's edge; what happens inside a built dev container is
    # whatever its own devcontainer.json asks for.
    var.github_token != "" ? { GH_TOKEN = var.github_token, GITHUB_TOKEN = var.github_token } : {},
  )
}

# Ordering guard, not a starter. The agent runs every run_on_start script — the
# startup_script alias included — concurrently, and only afterwards calls
# containerAPI.Start() and creates the dev containers (agent.go: ExecuteStartScripts
# first, createDevcontainer after). So waiting for the daemon here is what keeps
# `devcontainer up` from racing a sidecar that has not opened 2375 yet; nothing
# here starts a devcontainer, coder_devcontainer.repo owns that, and only when
# use_devcontainer is on. Kept unconditional: with the toggle off this probe is
# still the only proof that the daemon the workspace's own docker commands point
# at is answering.
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

# @devcontainers/cli is what the agent drives to build coder_devcontainer.repo;
# the golden image does not ship it. This module is a run_on_start script on
# the parent agent. Coder runs every run_on_start script (this one, the clone in
# startup_script, and dind_bootstrap) before it creates the dev containers, which
# is what makes the CLI install early enough for the build. The sidecar wait in
# dind_bootstrap still has to stay ahead of that build because `devcontainer up`
# talks to DOCKER_HOST = tcp://dind:2375. Gated on use_dc: with the toggle off
# there is no build to run, and nothing may talk to the sidecar's daemon at all.
module "devcontainers_cli" {
  count    = local.use_dc ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/devcontainers-cli/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
}

# The Coder built-in: the agent drives @devcontainers/cli against this folder
# during startup and exposes the result as a devcontainer sub-agent with its own
# terminal and apps. count matches the agent's lifecycle so a stopped workspace
# has nothing left to autostart, and rides on the same toggle. With the toggle on
# but no devcontainer.json anywhere in the repo the CLI still errors — there is
# nothing for it to build — which is what startup.sh.tftpl's preflight now warns
# about before the build is attempted.
resource "coder_devcontainer" "repo" {
  count    = local.use_dc ? data.coder_workspace.me.start_count : 0
  agent_id = coder_agent.main.id
  # No config_path: let the CLI find .devcontainer/devcontainer.json itself, so a
  # repo that uses the other legal locations (docker-compose.yml, .devcontainer/)
  # behaves the same as it does in VS Code.
  workspace_folder = local.project_folder
}

# In-browser VS Code (Coder's code-server fork) on port 13337, on the cloned
# folder in either mode: inside the dev container when the toggle is on, on the
# plain workspace container when it is off. That second branch is the whole point
# of the toggle — the editor hung off the dev-container sub-agent alone, so a repo
# that ships no devcontainer.json got no dev container, hence no sub-agent, hence
# no editor and no terminal profile at all. HCL does not evaluate the untaken
# branch of a ternary, so coder_devcontainer.repo[0] never indexes an empty tuple
# in the off case — the same shape docker-dev uses for its count-gated
# data.docker_image.dind[0].id. Attaching any app/script/env to the dev-container
# sub-agent makes the dev container terraform-managed: a repo's own
# customizations.coder.apps are then ignored (displayApps still apply).
# display_apps.vscode on the parent agent is only the desktop helper.
# install_prefix stays at the module default (/tmp/code-server): both modes
# rebuild the container that hosts the editor on every start, so a persistent
# prefix buys nothing. No CODER_WILDCARD_ACCESS_URL on this box, so subdomain
# routing is unavailable.
module "code_server" {
  count     = data.coder_workspace.me.start_count
  source    = "registry.coder.com/coder/code-server/coder"
  version   = "~> 1.0"
  agent_id  = local.use_dc ? coder_devcontainer.repo[0].subagent_id : coder_agent.main.id
  folder    = local.project_folder
  port      = 13337
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

# The agent-bar terminal button, replacing the built-in one (display_apps
# .web_terminal stays off because it hardwires to coder_agent.dir = /home/coder
# here, and this app takes its slot in the bar). A command-type coder_app opens
# a terminal running its command, so the clone folder is pinned inside the
# command: coder_app in coder/coder 2.18 has no `folder` argument. The clone
# lives on the shared bind in BOTH toggle modes, so this button lands on the
# repository either way: inside the dev container's build context when the
# toggle is on, on the plain workspace container when it is off. `cd` is
# best-effort (`2>/dev/null;`) because with && a failed clone would leave the
# button starting a dead terminal instead of a shell someone can fix the clone
# from. Spelled out against `terraform validate` only.
resource "coder_app" "web_terminal" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "web-terminal"
  display_name = "Web Terminal"
  icon         = "/icon/terminal.svg"
  command      = "cd ${local.project_folder} 2>/dev/null; exec /bin/bash -l"
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
    value = var.image
  }

  item {
    key   = "repo"
    value = data.coder_parameter.repo_url.value
  }

  # Not indexed off coder_devcontainer.repo[0] — that resource is absent when the
  # dev-container toggle is off, and the folder exists either way.
  item {
    key   = "devcontainer folder"
    value = local.project_folder
  }

  item {
    key   = "litellm"
    value = var.litellm_url
  }

  # Which profile shape this workspace got: the shared per-user volume or a
  # private ~/.grok. Named on the page because the two are otherwise
  # indistinguishable from the outside.
  item {
    key   = "grok profile"
    value = data.coder_parameter.grok_profile_mode.value
  }

  # The alias this workspace's config.toml is rendered with. On a shared profile
  # volume the file itself may carry another workspace's answer, because whoever
  # starts last re-renders the one shared file — so this tile states what THIS
  # workspace asked for, which is the closest thing to a per-workspace answer.
  item {
    key   = "grok default model"
    value = data.coder_parameter.grok_default_model.value
  }

  # Same redaction stance as the litellm key item below: this says only whether a
  # credential exists, never what it is, and `sensitive` keeps even that
  # "set"/"none" answer masked. There is nothing more to show — the token never
  # reaches a rendered file, only its name does.
  item {
    key       = "github token"
    value     = var.github_token != "" ? "set" : "none"
    sensitive = true
  }

  # Which of the two modes this workspace got — the only place the create form's
  # second answer is still readable after create.
  item {
    key   = "devcontainer"
    value = local.use_dc ? "on (built on ${local.dind_alias} sidecar)" : "off (plain workspace container)"
  }

  # Always on in this template, so the item states which daemon is reachable:
  # with the toggle off that daemon is still there for the workspace's own docker
  # commands, it just has no dev container build to serve.
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

# One Grok Build profile per *user*, mounted into every workspace that user owns,
# instead of one ~/.grok per workspace that dies on a rebuild — but only in
# `shared` mode, which the grok_profile_mode parameter above decides. `private`
# gives that workspace a private ~/.grok on its own home volume, which dies with
# it, and renders a container that is byte-for-byte the shape this template had
# before the profile volume existed. Same shape as docker-dev's either way: the
# volume is referenced by plain string name and never declared as a docker_volume
# resource, so Docker creates it on the first container start that names it, and a
# workspace stop never has to unmount a volume another of the same user's
# workspaces still holds open.
locals {
  # Anything but "shared" — "private" included — means no extra volumes entry at
  # all, so the planned container is byte-identical to the pre-profile-volume
  # shape. lower() + trimspace() so a form value typed as "Shared " still reads as
  # shared instead of quietly provisioning private.
  grok_profile_shared = lower(trimspace(data.coder_parameter.grok_profile_mode.value)) == "shared"
  # Keyed by owner id, not by workspace id: that is the whole privacy boundary.
  grok_profile_volume = "grok-profile-${data.coder_workspace_owner.me.id}"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count

  # var.image, not a dropdown: with the dev-container toggle on, the workspace
  # container is only the launcher and the clone target, and the editor's real
  # environment is whatever the repo's devcontainer.json builds on the sidecar.
  # With the toggle off this container hosts the editor itself, so the golden
  # image is what the editor runs on — either way it still has to ship the
  # docker client, git, tmux and the Grok CLI.
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

  # Rides alongside the two above rather than replacing either: /home/coder/.grok
  # is resolved *inside* the home volume's mount, so Docker covers it with the
  # owner's shared profile volume and the CLI's state tree is one directory tree
  # shared live by every workspace this user owns. Only in `shared` mode: in
  # `private` mode .grok stays a plain folder on this workspace's own home volume,
  # and either way the mount is on the workspace container, never on a dev
  # container built on the sidecar, which has always had its own home. Gated on
  # local.grok_profile_shared because an empty for_each emits no volumes entry at
  # all — in private mode the planned container is exactly the pre-profile shape.
  dynamic "volumes" {
    for_each = local.grok_profile_shared ? [1] : []
    content {
      container_path = "/home/coder/.grok"
      volume_name    = local.grok_profile_volume
      read_only      = false
    }
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
