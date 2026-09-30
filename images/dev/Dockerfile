# syntax=docker/dockerfile:1
#
# ## Golden workspace image — EVO-T1 Coder stack
#
# Coder workspaces on the LAN box are provisioned from this image
# (templates/docker-dev: `image = <this image>`), and the Coder agent is injected
# by Terraform through `coder_agent.main.init_script`, so this image is a *runtime
# host* for the agent, not a service image.
#
# Agent-bootstrap contract (coder/provisionersdk/scripts/bootstrap_linux.sh at
# v2.36.6) — the image must satisfy this or workspace creation hangs:
#   - a working /bin/sh            (Ubuntu's dash is fine; the script is POSIX)
#   - mktemp                       (coreutils)
#   - curl, wget, or busybox wget  (curl is installed below)
#   - /bin/bash                    (the agent runs startup_script through the
#                                   user's login shell, so bash must exist AND
#                                   coder's login shell must be bash — useradd)
#   - a writable $HOME             (the docker provider mounts a volume on
#                                   /home/coder; Docker seeds a fresh volume from
#                                   this image's directory, which is how the
#                                   dotfiles written here reach a new workspace)
# The agent binary itself is a static Go binary fetched from the Coder server on
# the LAN, so nothing here needs the internet at *workspace start* — only at
# *image build* time.
#
# Why we pin our own base: the template's previous default,
# codercom/example-base:ubuntu, ships no node/tmux/ripgrep/gh/git-lfs/uv and —
# being an untagged `ubuntu` tag — silently re-based itself to a new Ubuntu
# release underneath us.
#
# No GPU/CUDA dependency: ffmpeg and the GL libs are userspace only, so this
# builds and runs on any amd64 box regardless of driver state.

# Ubuntu 24.04 LTS = "noble". Pinned to the numeric LTS tag rather than
# `ubuntu:latest`; digest observed for that tag on 2026-09-27 was
# sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3.
# Every other pin lives in images/dev/tool-versions.env and arrives as a
# --build-arg from scripts/build-dev-image.sh; the defaults here mirror that file
# so a bare `docker build` still works.
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/toxicoder/evo-t1-coder-stack" \
      org.opencontainers.image.title="evo-t1-dev" \
      org.opencontainers.image.description="Golden Coder workspace image for the EVO-T1 (Arc 140T) LAN stack"

# ── Version pins (see images/dev/tool-versions.env) ──────────────────────────
ARG NODE_VERSION_DEFAULT=24 \
    NODE_22_VERSION=22.23.3 \
    NODE_24_VERSION=24.21.0 \
    PRETTIER_VERSION=3.9.4 \
    PYTHON_DEFAULT_VERSION=3.12 \
    PYTHON_311_VERSION=3.11 \
    UV_VERSION=0.12.19 \
    RUFF_VERSION=0.16.9 \
    MYPY_VERSION=2.3.1 \
    MCP_NODE_SERVERS_VERSION=2026.8.31 \
    MCP_PY_SERVERS_VERSION=2026.8.18 \
    GO_VERSION=1.24.13 \
    PROTOBUF_GO_MODULE=google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12 \
    PROTOC_GEN_GO_GRPC_MODULE=google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.1 \
    STRINGER_MODULE=golang.org/x/tools/cmd/stringer@v0.40.0 \
    PROTOC_VERSION=36.2 \
    TERRAFORM_VERSION=1.16.4 \
    TFLINT_VERSION=0.64.0 \
    TERRAGRUNT_VERSION=1.1.6 \
    GH_VERSION=2.101.0 \
    CODER_CLI_VERSION=v2.36.6 \
    BAZELISK_VERSION=v1.25.0 \
    BUILDIFIER_VERSION=v8.2.1 \
    SHFMT_ASSET_VERSION=3.10.0 \
    KUBECONFORM_VERSION=v0.8.0 \
    HELM_VERSION=v3.15.0 \
    KUBECTL_VERSION=v1.30.14 \
    DOCKER_CLI_VERSION=29.8.1 \
    BUILDX_VERSION=v0.37.1 \
    COMPOSE_VERSION=v5.5.1 \
    GROK_VERSION=1.0.44

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    # Tool homes are system-wide (root-owned, world-readable) rather than baked
    # into /home/coder: /home/coder is replaced by a per-workspace volume at
    # runtime, so anything the agent depends on must live outside it.
    UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/opt/uv-tools/bin \
    # uv must not fetch a managed CPython at build time just to run four tools
    # when a matching system interpreter is already installed.
    UV_PYTHON_PREFERENCE=only-system \
    # Auto is set, but the three plugin pins below are deliberately the newest
    # releases whose `go` directive still fits Go 1.24 — see the Go layer.
    GOTOOLCHAIN=auto \
    CGO_ENABLED=0 \
    GOPATH=/home/coder/go \
    GOMODCACHE=/home/coder/go/pkg/mod \
    PROTOC_HOME=/usr/local/protoc \
    # Prepend order: /usr/local/bin first so our symlinks win over apt copies,
    # then the pinned tool homes. ~/.grok/bin is added by /etc/profile.d/evo-dev.sh
    # for login shells (the Coder agent runs startup_script through one).
    PATH=/usr/local/bin:/usr/local/go/bin:/opt/node/current/bin:/opt/npm-global/bin:/opt/uv-tools/bin:/usr/local/protoc/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# Ubuntu's /bin/sh is dash; the `set -u`/pipefail these RUN layers rely on need
# bash. It also keeps the shell used here identical to the agent's login shell.
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# ── apt: base, CLI tools, Python ─────────────────────────────────────────────
# Keep apt's .debs and lists in BuildKit cache mounts (the ez-comfy-stack idiom)
# instead of the image layer, so editing the package list below costs seconds.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/keep-cache

# One apt layer on purpose. Three names differ from the usual Ubuntu-22.04-era
# spellings, each of which fails the build if copied blind:
#   - libglib2.0-0 does not exist on noble (time_t 64-bit transition); the real
#     package is libglib2.0-0t64.
#   - fd installs its binary as `fdfind` and bat as `batcat`, so both are
#     symlinked to the names the repos' Makefiles actually call.
#   - apt's gh is 2.45 and predates several subcommands the agent experience uses,
#     so gh comes from a pinned tarball in the CLI layer instead.
# ansible-lint comes from apt (it pulls ansible-core, which supplies the `ansible`
# CLI too) — a noble-native ansible-core is current enough for inkorporated's
# roles and installs no extra Python venv.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      apt-transport-https \
      build-essential \
      ca-certificates \
      curl \
      wget \
      git \
      git-lfs \
      gnupg \
      openssh-client \
      jq \
      rsync \
      unzip \
      zip \
      vim \
      less \
      locales \
      pipx \
      sudo \
      tmux \
      htop \
      iproute2 \
      procps \
      make \
      g++ \
      ffmpeg \
      libgl1 \
      libglib2.0-0t64 \
      ripgrep \
      fd-find \
      bat \
      shellcheck \
      bats \
      yamllint \
      ansible-lint \
      python3 \
      python3-pip \
      python3-venv \
      python3-dev \
      python3-full \
      xz-utils \
      zstd \
    # Python 3.11 is not in noble's own archive; deadsnakes is the maintained
    # source and lists noble as a supported suite. Fingerprint-pinned key fetched
    # over TLS from the Ubuntu keyserver, dearmored by hand — no apt-key.
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
         "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
       | gpg --batch --yes --dearmor >/etc/apt/keyrings/deadsnakes.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/deadsnakes.gpg] https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu noble main" \
       >/etc/apt/sources.list.d/deadsnakes.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      "python${PYTHON_311_VERSION}" \
      "python${PYTHON_311_VERSION}-dev" \
      "python${PYTHON_311_VERSION}-venv" \
    # No `rm -rf /var/lib/apt/lists/*`: both apt dirs are cache mounts above, so
    # their contents are already absent from the layer and clearing them would
    # only throw away the index cache the mount exists to preserve.
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -sf "$(command -v batcat)" /usr/local/bin/bat \
    && locale-gen en_US.UTF-8 \
    # Registers the LFS filters in /etc/gitconfig so every user — including the
    # agent's non-login shells — gets working `git lfs` without a per-repo install.
    && git lfs install --system \
    # Smoke checks: a broken mirror or a bad pin must fail here, not surface as a
    # half-working workspace three steps later.
    && git --version \
    && tmux -V \
    && rg --version | head -1 \
    && fd --version \
    && bat --version \
    && shellcheck --version \
    && bats --version \
    && yamllint --version \
    && ansible-lint --version \
    && python3 --version \
    && "python${PYTHON_311_VERSION}" --version \
    && command -v mktemp \
    && test -x /bin/bash \
    && test -x /bin/sh

# ── coder user ───────────────────────────────────────────────────────────────
# uid/gid 1000 matters twice over: the docker provider mounts a volume at
# /home/coder (whose ownership cannot be changed from inside the container), and
# docker-compose.yml runs the Coder server itself as uid 1000.
#
# Ubuntu's base image already occupies uid 1000 with a default `ubuntu` user, so
# it is deleted first — otherwise `useradd --uid 1000` exits 9 ("UID already in
# use") and every build fails. Deleting it also keeps a stale second home out of
# every workspace.
#
# --shell=/bin/bash is not cosmetic: the Coder agent executes startup_script
# through the user's login shell, and startup.sh.tftpl uses bashisms.
# NOPASSWD sudo mirrors Coder's own coder/images base pattern, and startup.sh.tftpl
# probes for sudo before using it.
RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
    && useradd --create-home --shell=/bin/bash --uid 1000 --user-group coder \
    && install -d -m 0755 -o coder -g coder \
         /home/coder/go/bin \
         /home/coder/go/pkg \
         /home/coder/.local/bin \
         /home/coder/.npm-global \
         /home/coder/.cache \
    && chown -R coder:coder /home/coder \
    && printf '%s\n' 'coder ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/coder \
    && chmod 0440 /etc/sudoers.d/coder \
    && visudo -cf /etc/sudoers.d/coder \
    && adduser coder sudo \
    && id coder \
    && getent passwd coder

# ── Pinned single-binary CLIs ────────────────────────────────────────────────
# All from official upstream release assets. The Bazel/k8s pins are inherited
# verbatim from toxicoder/nvidia-dgx-spark-lab's .devcontainer/tool-versions.env so
# both repos drive the same toolchain.
#
# The `coder` CLI is baked at the server's version: `coder template push` from
# inside a workspace needs a CLI that agrees with ghcr.io/coder/coder:v2.36.6 in
# docker-compose.yml, and baking it keeps workspace start working with no internet
# (a startup-script download would not).
#
# No `bazelisk version` smoke check: it would download a full Bazel release at
# build time, which is exactly the network dependency this image exists to avoid.
RUN case "${TARGETARCH}" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH} (need amd64 or arm64)" >&2; exit 1 ;; \
    esac; \
    echo "Installing pinned CLIs for linux/${ARCH}..."; \
    fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --http1.1 -o "$1" "$2"; }; \
    # kubectl / helm / kubeconform — kubectl is pinned to the same minor as the
    # 1.30 schemas kubeconform validates against.
    fetch /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl \
    && fetch /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz "/tmp/linux-${ARCH}" \
    && fetch /tmp/kubeconform.tgz "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
    && tar -xzf /tmp/kubeconform.tgz -C /usr/local/bin kubeconform \
    && chmod 0755 /usr/local/bin/kubeconform \
    && rm -f /tmp/kubeconform.tgz \
    # Bazelisk + buildifier + shfmt — Bazel itself is fetched by Bazelisk from a
    # repo's .bazelversion on first use inside a workspace, not here.
    && fetch /usr/local/bin/bazelisk "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${ARCH}" \
    && chmod 0755 /usr/local/bin/bazelisk \
    && ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel \
    && fetch /usr/local/bin/buildifier "https://github.com/bazelbuild/buildtools/releases/download/${BUILDIFIER_VERSION}/buildifier-linux-${ARCH}" \
    && chmod 0755 /usr/local/bin/buildifier \
    && fetch /usr/local/bin/shfmt "https://github.com/mvdan/sh/releases/download/v${SHFMT_ASSET_VERSION}/shfmt_v${SHFMT_ASSET_VERSION}_linux_${ARCH}" \
    && chmod 0755 /usr/local/bin/shfmt \
    # Terraform / tflint / terragrunt — templates/docker-dev plus inkorporated.
    && fetch /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
    && unzip -q -d /usr/local/bin /tmp/terraform.zip terraform \
    # tflint is published under terraform-linters/tflint; the old
    # aquasecurity/tflint repo path 404s upstream. The pin is bare semver and the
    # GitHub tag carries a leading "v", so the URL adds it (verified against the
    # release API: v0.64.0 serves tflint_linux_amd64.zip).
    && fetch /tmp/tflint.zip "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${ARCH}.zip" \
    && unzip -q -d /usr/local/bin /tmp/tflint.zip tflint \
    # terragrunt keeps the leading "v" in its 1.x tags (v1.1.6) while the asset
    # name is unprefixed, so only the tag part of the URL is prefixed here.
    && fetch /usr/local/bin/terragrunt "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_${ARCH}" \
    && chmod 0755 /usr/local/bin/terragrunt \
    && rm -f /tmp/terraform.zip /tmp/tflint.zip \
    # gh — pinned tarball (asset name is the version without a leading "v").
    # The archive unpacks a versioned directory, so the path below is absolute:
    # the layer's cwd is / (no WORKDIR yet), which would miss a relative path.
    && fetch /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION#v}_linux_${ARCH}.tar.gz" \
    && tar -xzf /tmp/gh.tgz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION#v}_linux_${ARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION#v}_linux_${ARCH}" \
    # Coder CLI (same unprefixed asset convention, from a ${CODER_CLI_VERSION}
    # that does carry the leading "v").
    #
    # The archive stores every member under "./" (./coder, ./LICENSE, …), so GNU
    # tar cannot match a bare `coder` member name — extracting the whole archive
    # and installing from the ./ path is what works. The first build of this layer
    # failed here with "tar: coder: Not found in archive".
    && fetch /tmp/coder.tgz "https://github.com/coder/coder/releases/download/${CODER_CLI_VERSION}/coder_${CODER_CLI_VERSION#v}_linux_${ARCH}.tar.gz" \
    && mkdir -p /tmp/coder-cli \
    && tar -xzf /tmp/coder.tgz -C /tmp/coder-cli \
    && install -m 0755 /tmp/coder-cli/coder /usr/local/bin/coder \
    && rm -rf /tmp/coder.tgz /tmp/coder-cli \
    # Docker client toolchain — the *client* only, so a workspace can drive a
    # Docker daemon. download.docker.com's static tarball also ships dockerd,
    # containerd, containerd-shim-runc-v2, docker-proxy and runc, so it must
    # never be unpacked wholesale: selecting the docker/docker member alone is
    # what keeps the daemon out of this image (it runs as the per-workspace
    # docker:29.8.1-dind sidecar that templates/docker-dev provisions). The
    # selected member is a static ELF, so noble needs no extra libs for it.
    #
    # No `ENV DOCKER_HOST`: the endpoint differs per workspace (sidecar vs. a
    # mounted host socket), so baking one here would break the host-socket case;
    # Terraform sets it instead.
    #
    # The upstream arch spellings differ — download.docker.com and compose name
    # their assets x86_64/aarch64, buildx uses amd64/arm64 — so DOCKER_ARCH is
    # derived from the ${ARCH} already validated above, not from TARGETARCH again.
    && case "${ARCH}" in amd64) DOCKER_ARCH=x86_64 ;; arm64) DOCKER_ARCH=aarch64 ;; esac \
    && fetch /tmp/docker-cli.tgz "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
    && mkdir -p /tmp/docker-cli \
    && tar -xzf /tmp/docker-cli.tgz --strip-components=1 -C /tmp/docker-cli docker/docker \
    && install -m 0755 /tmp/docker-cli/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker-cli.tgz /tmp/docker-cli \
    # buildx and compose are docker CLI *plugins*, which the CLI discovers by
    # exact file name under /usr/local/lib/docker/cli-plugins — a differently
    # named copy there is silently invisible to `docker buildx`. Both are
    # client-only commands, so they answer version output with no daemon
    # reachable and are usable as build-time smoke checks.
    && install -d -m 0755 /usr/local/lib/docker/cli-plugins \
    && fetch /usr/local/lib/docker/cli-plugins/docker-buildx "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${ARCH}" \
    && fetch /usr/local/lib/docker/cli-plugins/docker-compose "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${DOCKER_ARCH}" \
    && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx /usr/local/lib/docker/cli-plugins/docker-compose \
    # The plugin dir is root-owned while workspaces run as coder, so the tree has
    # to stay world-readable/executable or the agent's user cannot run a build.
    && chmod -R a+rX /usr/local/lib/docker \
    # protoc — the official zip carries both the binary and the well-known .proto
    # includes, so it unpacks under /usr/local/protoc (PROTOC_HOME) and only bin/
    # is linked out; the include tree must stay put for protoc-gen-go.
    && case "${ARCH}" in amd64) PROTOC_ARCH=x86_64 ;; arm64) PROTOC_ARCH=aarch_64 ;; esac \
    && fetch /tmp/protoc.zip "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${PROTOC_ARCH}.zip" \
    && install -d -m 0755 /usr/local/protoc \
    && unzip -q /tmp/protoc.zip -d /usr/local/protoc \
    && rm -f /tmp/protoc.zip \
    && chmod -R a+rX /usr/local/protoc \
    && ln -sf /usr/local/protoc/bin/protoc /usr/local/bin/protoc \
    && ln -sf /opt/uv-tools/bin/ruff /usr/local/bin/ruff \
    && ln -sf /opt/uv-tools/bin/mypy /usr/local/bin/mypy \
    && ln -sf /opt/npm-global/bin/prettier /usr/local/bin/prettier \
    && ln -sf /opt/npm-global/bin/mcp-server-filesystem /usr/local/bin/mcp-server-filesystem \
    && ln -sf /opt/npm-global/bin/mcp-server-memory /usr/local/bin/mcp-server-memory \
    && ln -sf /opt/npm-global/bin/mcp-server-sequential-thinking /usr/local/bin/mcp-server-sequential-thinking \
    && ln -sf /usr/local/go/bin/stringer /usr/local/bin/stringer \
    # The protoc release zip ships bin/protoc alone — the Go plugins come from
    # `go install` below, which writes them to GOBIN (/usr/local/go/bin). They are
    # linked to /usr/local/go/bin (matching stringer) because /usr/local/bin is
    # FIRST on PATH: a link pointing at a path that never exists would shadow the
    # real binary and make protoc fail to load the plugin at runtime.
    && ln -sf /usr/local/go/bin/protoc-gen-go /usr/local/bin/protoc-gen-go \
    && ln -sf /usr/local/go/bin/protoc-gen-go-grpc /usr/local/bin/protoc-gen-go-grpc \
    && kubectl version --client \
    && helm version --short \
    && kubeconform -v \
    && buildifier --version \
    && shfmt --version \
    && terraform version \
    && tflint --version \
    && terragrunt --version \
    && gh --version \
    && coder --version \
    && protoc --version \
    && docker --version \
    && docker buildx version \
    && docker compose version \
    # Negative check: a layer that unpacked the whole tarball passes every
    # positive check above and still ships a daemon binary in the image, so prove
    # the rest of the archive stayed out — the dind sidecar owns the daemon.
    && test ! -x /usr/local/bin/dockerd \
    && test ! -x /usr/local/bin/containerd \
    && test ! -x /usr/local/bin/runc \
    && test ! -x /usr/local/bin/docker-proxy

# ── Grok Build CLI (the coding agent this stack exists to serve) ────────────
# The binary is fetched pinned (GROK_VERSION; the default here mirrors
# tool-versions.env, per the naming contract at the top of this file) and
# unpacked into /usr/local/bin/grok with an `agent` link beside it — the same
# pair `curl https://x.ai/cli/install.sh | bash` would lay down, placed OUTSIDE
# /home/coder on purpose: the home volume is seeded from the image only when it
# is first created, so a CLI under $HOME freezes (or is absent) with the
# volume, while this copy exists in every container built from the image.
# `templates/*/startup.sh.tftpl` probes `command -v grok` before downloading:
# on a golden-image boot that probe answers YES, so boot needs no internet at
# all (the rule this file's header states). Without the bake-in, one start on
# this box burned its whole startup budget on one stalled unbounded connection
# to x.ai ("curl: (28) SSL connection timeout" in /tmp/coder-startup-script.log)
# and booted WITHOUT the CLI, while another start streamed the same ~170 MiB
# across the same link with no trouble — a pin removes that coin flip.
# Upgrade path: bump GROK_VERSION here + in tool-versions.env, rebuild, re-push
# the templates; a user's self-installed newer CLI in ~/.grok/bin stays first
# on the login-shell PATH (profile.d) and wins over the baked copy there.
RUN case "${TARGETARCH}" in \
      amd64) GROK_ARCH=x86_64 ;; arm64) GROK_ARCH=aarch64 ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH} (need amd64 or arm64)" >&2; exit 1 ;; \
    esac; \
    echo "Unpacking Grok CLI ${GROK_VERSION} for linux/${GROK_ARCH}..."; \
    fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --http1.1 -o "$1" "$2"; }; \
    fetch /tmp/grok.zst "https://x.ai/cli/grok-${GROK_VERSION}-linux-${GROK_ARCH}.zst" \
    && zstd -q -dc /tmp/grok.zst >/usr/local/bin/grok \
    && rm -f /tmp/grok.zst \
    && test -s /usr/local/bin/grok \
    && chmod 0755 /usr/local/bin/grok \
    && ln -sf grok /usr/local/bin/agent \
    && /usr/local/bin/grok --version \
    && /usr/local/bin/agent --version

# ── Go 1.24 + protoc/stringer plugins ───────────────────────────────────────
# Official tarball, not the golang-1.24 apt package: the Debian package puts its
# binaries in /usr/lib/go-1.24/bin, which breaks every snippet that expects
# /usr/local/go/bin.
#
# The tarball is gzip (.tar.gz), not xz — `tar -xJf` fails on it with
# "File format not recognized".
#
# go.dev/dl intermittently aborts HTTP/2 streams from this host ("was not closed
# cleanly: INTERNAL_ERROR"), so the download goes straight to dl.google.com with
# --http1.1 and retries.
#
# GOTOOLCHAIN=auto is on, but the three plugin pins below are deliberately the
# newest releases whose `go` directive still fits Go 1.24 (protoc-gen-go v1.36.12
# → 1.23, protoc-gen-go-grpc v1.6.1 → 1.24.0, x/tools v0.40.0 → 1.24.0). The next
# patch of each needs 1.25/1.26 and would make this layer quietly download a newer
# toolchain, so bump GO_VERSION together with these three.
#
# Build/module caches are cache mounts, so their contents stay in the mount and
# never enter the layer — there is nothing to prune (and `rm -rf` on a mount point
# fails with "Device or resource busy", which is how this layer first broke).
# GOBIN targets /usr/local/go/bin so the plugins are on PATH for every user, while
# the ENV GOPATH stays in the coder home for users' own `go install`s.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg/mod \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --http1.1 \
      -o /tmp/go.tgz "https://dl.google.com/go/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz \
    && export PATH="/usr/local/go/bin:${PATH}" \
    && export GOPATH=/root/go GOBIN=/usr/local/go/bin \
    && go version \
    && go install "${PROTOBUF_GO_MODULE}" \
    && go install "${PROTOC_GEN_GO_GRPC_MODULE}" \
    && go install "${STRINGER_MODULE}" \
    && protoc-gen-go --version \
    && protoc-gen-go-grpc --version \
    && test -x /usr/local/go/bin/stringer \
    && test -x /usr/local/bin/stringer \
    # End-to-end proof the codegen trio works together, resolving the
    # /usr/local/bin symlinks exactly as a workspace would: protoc must find both
    # plugins by name on PATH and produce non-empty generated code.
    && mkdir -p /tmp/proto-smoke/in /tmp/proto-smoke/out \
    && printf '%s\n' 'syntax = "proto3";' 'package smoke;' 'option go_package = "example.com/smoke";' 'message Ping { string msg = 1; }' 'service Echo { rpc Say (Ping) returns (Ping); }' >/tmp/proto-smoke/in/smoke.proto \
    && protoc --proto_path=/tmp/proto-smoke/in --go_out=/tmp/proto-smoke/out --go-grpc_out=/tmp/proto-smoke/out /tmp/proto-smoke/in/smoke.proto \
    && test -n "$(find /tmp/proto-smoke/out -name '*.pb.go' -size +500c -print -quit)" \
    && test -n "$(find /tmp/proto-smoke/out -name '*_grpc.pb.go' -size +500c -print -quit)" \
    && rm -rf /tmp/proto-smoke \
    && go version

# ── Node 22 + Node 24 side by side ──────────────────────────────────────────
# Tarballs from nodejs.org rather than NodeSource: the node_22.x and node_24.x apt
# repos both ship a package named `nodejs`, so registering both makes the second
# replace the first — NodeSource cannot deliver two majors in one image. nvm was
# the other option and is rejected: it is a shell function, so it is invisible to
# the non-interactive, non-login shells the Coder agent and the VS Code server
# spawn, which is precisely where a missing node shows up.
#
# Layout: /opt/node/<major> per runtime, /opt/node/current → the default. Both
# majors share one npm prefix (/opt/npm-global), so the globals below install once
# and work under either. The prefix is exported only inside this layer: making it
# a global ENV would send a workspace user's own `npm i -g` at a root-owned
# directory (EACCES), so /etc/profile.d gives them ~/.npm-global instead.
#
# Default is 24 (cyborg-conductor-core and dgx-spark-it-up pin 24; the
# nvidia-dgx-spark-lab dashboard needs engines.node >=22, which 24 satisfies).
# A workspace selects the other with NODE_VERSION=22 in its env — see profile.d.
RUN for pair in "22:${NODE_22_VERSION}" "24:${NODE_24_VERSION}"; do \
      major="${pair%%:*}"; ver="${pair#*:}"; \
      case "${TARGETARCH}" in amd64) NODE_ARCH=x64 ;; arm64) NODE_ARCH=arm64 ;; esac; \
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --http1.1 \
        -o /tmp/node.tgz "https://nodejs.org/dist/v${ver}/node-v${ver}-linux-${NODE_ARCH}.tar.xz" \
      && install -d -m 0755 "/opt/node/${major}" \
      && tar -xJf /tmp/node.tgz -C "/opt/node/${major}" --strip-components=1 \
      && rm -f /tmp/node.tgz; \
    done \
    && ln -sfn "/opt/node/${NODE_VERSION_DEFAULT}" /opt/node/current \
    && export PATH="/opt/node/current/bin:${PATH}" \
    && export NPM_CONFIG_PREFIX=/opt/npm-global \
    && node -v \
    && npm -v \
    && /opt/node/22/bin/node -v \
    # Globals once, into the shared prefix. prettier is held at the
    # nvidia-dgx-spark-lab pin (3.9.4) rather than npm `latest` (3.9.9) so `//:fix`
    # and `//:lints:yaml_format` stay byte-identical with that repo.
    && npm install -g --no-audit --no-fund \
         "prettier@${PRETTIER_VERSION}" \
         "@modelcontextprotocol/server-filesystem@${MCP_NODE_SERVERS_VERSION}" \
         "@modelcontextprotocol/server-memory@${MCP_NODE_SERVERS_VERSION}" \
         "@modelcontextprotocol/server-sequential-thinking@${MCP_NODE_SERVERS_VERSION}" \
    && npm cache clean --force \
    && chmod -R a+rX /opt/node /opt/npm-global \
    && prettier --version \
    && ls /opt/npm-global/bin

# ── uv + Python tool envs (ruff, mypy, offline MCP servers) ─────────────────
# Official pinned installer. UV_INSTALL_DIR puts `uv` itself on the system PATH;
# UV_NO_MODIFY_PATH stops the script rewriting shell rc files in a layer, where a
# later COPY could undo it. The tool envs go to /opt/uv-tools (not under
# /home/coder, which becomes a volume) via UV_TOOL_DIR / UV_TOOL_BIN_DIR —
# `uv tool install` has no --install-dir flag, so these two env vars are the
# supported way to relocate it.
#
# mcp-server-git and mcp-server-time are the same CalVer release on PyPI and both
# come from modelcontextprotocol/servers. mcp-server-time publishes no PyPI author,
# but its project_urls point at src/time in that repo — checked, not a third-party
# lookalike.
RUN --mount=type=cache,target=/root/.cache/uv \
    export UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --http1.1 \
         https://astral.sh/uv/${UV_VERSION}/install.sh \
       | sh \
    && uv --version \
    && uv tool install "ruff@${RUFF_VERSION}" --python "${PYTHON_DEFAULT_VERSION}" \
    && uv tool install "mypy@${MYPY_VERSION}" --python "${PYTHON_DEFAULT_VERSION}" \
    && uv tool install "mcp-server-git==${MCP_PY_SERVERS_VERSION}" --python "${PYTHON_DEFAULT_VERSION}" \
    && uv tool install "mcp-server-time==${MCP_PY_SERVERS_VERSION}" --python "${PYTHON_DEFAULT_VERSION}" \
    # No `uv cache clean`: /root/.cache/uv is a BuildKit cache mount, so its
    # contents never enter the layer (clearing it would also throw away the cache
    # the mount exists to keep, and `uv cache clean` fails on the mount point with
    # "Device or resource busy").
    && chmod -R a+rX /opt/uv-tools \
    && ruff --version \
    && mypy --version \
    && test -x /opt/uv-tools/bin/mcp-server-git \
    && test -x /opt/uv-tools/bin/mcp-server-time

# ── Login-shell PATH ────────────────────────────────────────────────────────
# The ENV PATH above covers exec/run, but the Coder agent runs startup_script
# through a *login* shell, so that path has to be honest too. ~/.grok/bin leads
# because startup.sh.tftpl installs the Grok CLI there at first boot. A workspace
# can switch Node majors with NODE_VERSION=22 without an image rebuild, and its
# own `npm i -g` lands in ~/.npm-global rather than the root-owned shared prefix.
RUN printf '%s\n' \
  '# EVO-T1 dev image — login-shell PATH (see images/dev/Dockerfile).' \
  '# Prepended, so a per-user go/npm/pipx install wins over the baked copy.' \
  '_node_major="${NODE_VERSION:-'"${NODE_VERSION_DEFAULT}"'}"' \
  'if [ -d "/opt/node/${_node_major}/bin" ]; then' \
  '  PATH="/opt/node/${_node_major}/bin:${PATH}"' \
  'fi' \
  'export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-${HOME}/.npm-global}"' \
  'PATH="${HOME}/.grok/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/.npm-global/bin:${PATH}"' \
  'export PATH' \
  >'/etc/profile.d/evo-dev.sh' \
    && chmod 0644 /etc/profile.d/evo-dev.sh \
    # Self-test as the coder user through a login shell — this is exactly how the
    # Coder agent runs startup_script, so a broken profile shows up at build time
    # instead of as a workspace with no tmux. HOME is overridden because RUN here is
    # still root (USER coder only takes effect on the next line).
    && su coder -c 'env -i HOME=/home/coder USER=coder LOGNAME=coder PATH=/usr/local/bin:/usr/bin:/bin TERM=dumb bash -l -c '"'"'set -e; for d in /home/coder/.grok/bin /opt/node/24/bin /usr/local/bin; do printf "%s\n" "$PATH" | tr : "\n" | grep -qx "$d"; done; node -v; tmux -V; git --version; grok --version'"'"''

USER coder
WORKDIR /home/coder
