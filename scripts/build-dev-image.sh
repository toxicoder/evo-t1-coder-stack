#!/usr/bin/env bash
#
# ## build-dev-image.sh — build the local golden Coder workspace image
#
# Build the golden Coder workspace image (images/dev/Dockerfile) as
# evo-t1-dev:latest, taking every version pin from images/dev/tool-versions.env.
#
# Safe to re-run: the tag is a local, always-rebuilt name, so a second run just
# replaces it (BuildKit reuses cached layers). No registry push happens here.
#
# The image tag is what templates/docker-dev/main.tf provisions with, so it must
# resolve from the LOCAL daemon store. Two things guarantee that the Coder docker
# provider never attempts a registry pull:
#   - the name has no registry host and no dot, so Docker treats it as a local
#     name rather than docker.io/<name> (a "docker.io/" prefix or a "." in the
#     first path element would make it a remote reference and the provider's
#     pull-on-missing would then fail on a LAN box with no internet);
#   - it is "latest"-tagged ONLY because this is a mutable local build tag; every
#     toolchain version inside is pinned in tool-versions.env. Set DEV_IMAGE_TAG to
#     a versioned value if you want an immutable reference.
#
# Usage:
#   ./scripts/build-dev-image.sh                 # build evo-t1-dev:latest
#   DEV_IMAGE_TAG=evo-t1-dev:v1 ./scripts/build-dev-image.sh
#   DOCKER="sudo docker" ./scripts/build-dev-image.sh   # if docker needs root
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_DIR="images/dev"
DOCKERFILE="${IMAGE_DIR}/Dockerfile"
VERSIONS="${IMAGE_DIR}/tool-versions.env"

# shellcheck source=lib/image.sh disable=SC1091
source "scripts/lib/image.sh"

# Defaults so the script still works if .env is unreadable; the build then fails
# loudly on the missing-ARG check below rather than building something unknown.
DEV_IMAGE_TAG="${DEV_IMAGE_TAG:-evo-t1-dev:latest}"
DOCKER="${DOCKER:-docker}"

# @function log
# Print one status line. Spark scripts send it to stderr when --json is set.
# Globals:
#   json (Spark scripts; empty means stdout)
# Arguments:
#   $* - text to print
# Outputs:
#   The text on stdout, or stderr when json is set
# Returns:
#   0
log() { printf '%s\n' "$*"; }
# @function die
# Print an error on stderr and exit 1.
# Globals:
#   None
# Arguments:
#   $* - error text, without the "error: " prefix
# Outputs:
#   "error: ..." on stderr
# Returns:
#   Does not return; exits 1
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ -f "${DOCKERFILE}" ] || die "${DOCKERFILE} not found (run this from the repo root)"
[ -f "${VERSIONS}" ] || die "${VERSIONS} not found — it is the single source of version pins"

command -v "${DOCKER%% *}" >/dev/null 2>&1 ||
  die 'docker not found on PATH (set DOCKER="sudo docker" if only root can talk to the daemon)'
if ! ${DOCKER} info >/dev/null 2>&1; then
  die "cannot reach the Docker daemon — this script needs docker access; run it with sudo, or add your user to the docker group (then re-login)"
fi

# BuildKit is required: the Dockerfile uses cache mounts and the # syntax line.
# Docker 23+ has it on by default; older engines need the explicit opt-in.
export DOCKER_BUILDKIT=1
# The build-node summary is pure noise on a re-run and buries the layer output
# this script exists to show.
export DOCKER_BUILD_SUMMARY=false
export DOCKER_BUILD_HISTORYNAME="build-dev-image"

# ── Read the pins ────────────────────────────────────────────────────────────
# BASH_SOURCE/pipefail and the KEY=value contract make a plain source safe here;
# set -a exports each one so the checks below see them.
set -a
# shellcheck disable=SC1090
. "${VERSIONS}"
set +a

# ── Validate before building ────────────────────────────────────────────────
# A KEY in tool-versions.env with no matching ARG in the Dockerfile would build
# silently with the Dockerfile's own default — the failure mode this whole design
# is meant to remove. Checked up front so it costs no build time.
# dockerfile_arg_names / missing_version_pins (scripts/lib/image.sh) read the
# ARG stanzas, including backslash-continued lines, so the two files cannot
# drift apart unnoticed.
missing=()
while IFS= read -r key; do
  [ -n "${key}" ] || continue
  missing+=("${key}")
done < <(missing_version_pins "${DOCKERFILE}" "${VERSIONS}")

if [ "${#missing[@]}" -gt 0 ]; then
  printf 'error: these pins have no matching ARG in %s:\n' "${DOCKERFILE}" >&2
  printf '       %s\n' "${missing[@]}" >&2
  die "add the ARG to the Dockerfile (and pass it) or remove it from ${VERSIONS}"
fi

# ── Translate the pins into --build-args ────────────────────────────────────
# Every key in tool-versions.env is forwarded, which is what keeps the single
# source of truth single. UBUNTU_VERSION is the one that must not be blank: it
# feeds `FROM ubuntu:${UBUNTU_VERSION}`, and a pre-FROM ARG takes its value from
# --build-arg alone (an exported environment variable never reaches it), so an
# empty value there would produce `FROM ubuntu:` and fail the build.
args=()
while IFS= read -r key; do
  [ -n "${key}" ] || continue
  value="${!key:-}"
  [ -n "${value}" ] || continue
  args+=("--build-arg" "${key}=${value}")
done < <(grep -oE '^[A-Z0-9_]+=' "${VERSIONS}" | tr -d '=')

[ "${#args[@]}" -gt 0 ] || die "no version pins found in ${VERSIONS}"

# ── Build ────────────────────────────────────────────────────────────────────
# No --network=host: every fetch here goes to a public HTTPS host by name and the
# LAN resolver handles it. Host networking would also let the build see the host's
# localhost (where the Coder server, Postgres and LiteLLM all listen), so the
# default bridge network is both sufficient and the safer default. Add it only if
# this box genuinely cannot resolve public hostnames during a build:
#   extra_args=(--network=host)   # last resort: DNS for the fetches above
extra_args=()

log "building ${DEV_IMAGE_TAG} from ${DOCKERFILE}"
${DOCKER} build \
  -f "${DOCKERFILE}" \
  -t "${DEV_IMAGE_TAG}" \
  "${extra_args[@]+"${extra_args[@]}"}" \
  "${args[@]+"${args[@]}"}" \
  "${IMAGE_DIR}"

# ── Prove the tag is local, then report it ───────────────────────────────────
# If the daemon cannot find it, the build silently did not produce this tag and a
# workspace creation would fail later with a pull error on a box with no internet.
if ! ${DOCKER} image inspect "${DEV_IMAGE_TAG}" --format '{{.Id}}' >/dev/null 2>&1; then
  die "${DEV_IMAGE_TAG} is not in the local image store after building — workspace creation would try (and fail) to pull it"
fi

image_id="$(${DOCKER} image inspect "${DEV_IMAGE_TAG}" --format '{{.Id}}' | sed 's/^sha256://')"
size_bytes="$(${DOCKER} image inspect "${DEV_IMAGE_TAG}" --format '{{.Size}}')"
created="$(${DOCKER} image inspect "${DEV_IMAGE_TAG}" --format '{{.Created}}')"

# docker reports Size as uncompressed bytes across all layers.
human_size="$(awk -v b="${size_bytes}" 'BEGIN {
  split("B KiB MiB GiB TiB", u, " "); i = 1
  while (b >= 1024 && i < 5) { b /= 1024; i++ }
  printf "%.1f %s", b, u[i]
}')"

log
log "image          ${DEV_IMAGE_TAG}"
log "image id       ${image_id:0:19}"
log "built          ${created}"
log "size           ${human_size} uncompressed (${size_bytes} bytes)"
log
log "Pin it into a template with:"
log "  coder templates push ./templates/docker-dev --var image=${DEV_IMAGE_TAG}"
