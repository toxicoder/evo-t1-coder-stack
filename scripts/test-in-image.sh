#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## test-in-image.sh - run the Bazel gates inside the golden dev image (entry point).
#
# Why this exists: a Mac or Linux host that is not attached to .devcontainer
# still has to prove //:test-fast, //:lint and //:validate before a pull request
# is reviewable, and a laptop's own shellcheck, shfmt, buildifier, bazelisk and
# node are not the versions the gate is defined against. This script runs the
# gates INSIDE the golden image (images/dev/Dockerfile, tagged
# evo-t1-dev:latest) — the same image Coder workspaces boot and GitHub Actions
# builds — so one green answer means the same thing on a laptop, in the
# contributor dev container, and in CI.
#
# What it does:
#   - resolves the checkout root the way the other entry scripts do (a marker
#     file, never a cwd assumption), so it works from a foreign cwd and from a
#     Bazel runfiles copy;
#   - makes sure the tag is in the local image store, building it from
#     images/dev/Dockerfile when it is not, or when --build says to anyway;
#   - docker runs that image with the checkout bind-mounted at /work and
#     bazelisk as the command, so the gates see the image's toolchain and the
#     operator's tree stays the tree under test.
#
# What it never does:
#   - push the tag anywhere, or re-implement the pin checks
#     scripts/build-dev-image.sh owns; it asks docker for the same Dockerfile,
#     whose ARG defaults already match images/dev/tool-versions.env;
#   - touch docker at all when EVO_T1_DEVCONTAINER=1: that environment already
#     IS this image, so a nested container would mount nothing and buy nothing,
#     and bazelisk is exec'd here instead;
#   - install anything: every tool the gates need lives in the image.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:test-in-image
#   bazelisk run //scripts:test-in-image -- --build
#   bazelisk run //scripts:test-in-image -- --image evo-t1-dev:v1
#   bazelisk run //scripts:test-in-image -- --user coder
#   bazelisk run //scripts:test-in-image -- -- test //:lint --test_tag_filters=manual
#   bazelisk run //scripts:test-in-image -- --help
#
# Options (accepted anywhere before --):
#   --image TAG    image to run; default $DEV_IMAGE_TAG when set, else
#                  evo-t1-dev:latest
#   --build        docker build even when the tag is already present
#   --user USER    user the container runs as (default this process's
#                  uid:gid, so the bind mount stays writable and chmod-based
#                  tests still see a non-root identity)
#   --             everything after this is handed to bazelisk verbatim
#   -h, --help     print this usage and exit 0
#
# Environment:
#   DEV_IMAGE_TAG            the default tag when --image is absent
#   EVO_T1_DEVCONTAINER=1    already inside the golden image: no docker call at
#                            all, bazelisk is exec'd in this environment
#
# Exit codes: 0 when the gates passed; 1 on a usage error, a missing docker CLI,
# or a failed gate; 5 when no checkout can be proven (no docker-compose.yml).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"

# DEFAULT_IMAGE_TAG — the local golden tag build-dev-image.sh produces. No
# registry host and no dot in it, so the daemon reads it as a local name and
# never turns the run into a registry pull.
DEFAULT_IMAGE_TAG="evo-t1-dev:latest"

# @function usage
# Print the flag list on stdout, so a typo prints something readable.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE'
usage: bazelisk run //scripts:test-in-image -- [--image TAG] [--build]
                       [--user USER] [--] [bazelisk-args...]

Runs the Bazel gates inside the golden dev image (images/dev/Dockerfile,
evo-t1-dev:latest) with this checkout bind-mounted at /work, so a host that is
not the contributor dev container still proves the gates against the image's
own toolchain. The image is built first when the tag is missing.

Defaults: image evo-t1-dev:latest (or $DEV_IMAGE_TAG), user this process's
uid:gid, and the bazelisk args are "test //:test-fast". With
EVO_T1_DEVCONTAINER=1 this is already that image, so no container is
started and bazelisk runs here.

Options: --image TAG, --build (build even when the tag exists), --user USER,
-- (hand everything after it to bazelisk), -h/--help.

Examples (each line is the whole command, run from the repo root):
  bazelisk run //scripts:test-in-image
  bazelisk run //scripts:test-in-image -- --build
  bazelisk run //scripts:test-in-image -- --image evo-t1-dev:v1
  bazelisk run //scripts:test-in-image -- -- test //:lint --test_tag_filters=manual
USAGE
}

# @function resolve_repo_root
# Print the checkout root this run reads from: the first candidate that holds a
# docker-compose.yml marker. A Bazel sandbox holds a COPY of the tree, so the
# probe is a marker file and never a cwd assumption.
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE, PWD, SELF_DIR
# Arguments:
#   None
# Outputs:
#   The root on stdout, or one complaint line on stderr
# Returns:
#   0 with the root on stdout; 5 when no candidate holds the marker
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}" "${SELF_DIR}/..")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}/docker-compose.yml" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: unresolvable repo root: no proven checkout in %s (need docker-compose.yml)\n' \
    "${candidates[*]}" >&2
  return 5
}

# @function test_in_image_tag
# Print the image tag this run should use: an explicit tag wins, then
# DEV_IMAGE_TAG, then the local golden tag.
# Globals:
#   DEV_IMAGE_TAG, DEFAULT_IMAGE_TAG
# Arguments:
#   $1 - tag from --image, optional (empty falls through to the environment)
# Outputs:
#   The tag on stdout
# Returns:
#   0
test_in_image_tag() {
  local explicit="${1:-}"
  if [ -n "${explicit}" ]; then
    printf '%s\n' "${explicit}"
    return 0
  fi
  printf '%s\n' "${DEV_IMAGE_TAG:-${DEFAULT_IMAGE_TAG}}"
}

# @function test_in_image_in_contributor_env
# Say whether this shell is already the golden image: the contributor dev
# container sets EVO_T1_DEVCONTAINER=1, and nesting a container there would
# mount nothing and buy nothing.
# Globals:
#   EVO_T1_DEVCONTAINER
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 when EVO_T1_DEVCONTAINER=1, 1 for every other value or when unset
test_in_image_in_contributor_env() {
  [ "${EVO_T1_DEVCONTAINER:-}" = "1" ]
}

# @function test_in_image_image_present
# Ask the local image store whether the tag exists, so a re-run costs no build.
# Globals:
#   None
# Arguments:
#   $1 - image tag
# Outputs:
#   Nothing (the inspect output is discarded)
# Returns:
#   0 when the tag is in the local store, 1 when it is absent or unnamed
test_in_image_image_present() {
  local tag="${1:-}"
  [ -n "${tag}" ] || return 1
  docker image inspect "${tag}" --format '{{.Id}}' >/dev/null 2>&1
}

# @function test_in_image_build
# Build the golden image from images/dev/Dockerfile with this checkout as the
# build context. The Dockerfile's ARG defaults already match
# images/dev/tool-versions.env, so no --build-arg is needed for a plain build;
# scripts/build-dev-image.sh stays the tool that overrides pins.
# Globals:
#   None
# Arguments:
#   $1 - image tag to produce
#   $2 - proven repo root
# Outputs:
#   One status line on stdout, then docker's own build log
# Returns:
#   0 when docker reported success; 1 on a missing argument
test_in_image_build() {
  local tag="${1:-}" root="${2:-}"
  if [ -z "${tag}" ]; then
    err "test_in_image_build: no image tag"
    return 1
  fi
  if [ -z "${root}" ]; then
    err "test_in_image_build: no repo root"
    return 1
  fi
  log "building ${tag} from ${root}/images/dev/Dockerfile"
  docker build \
    -f "${root}/images/dev/Dockerfile" \
    -t "${tag}" \
    "${root}/images/dev"
}

# @function test_in_image_run
# Run the gates in the image: the checkout bind-mounted read-write at /work,
# that as the cwd, and bazelisk as the command. --user defaults to this
# process's uid:gid so the bind mount stays writable and permission tests
# still see a non-root identity. HOME=/tmp and USER=${USER:-$(id -un)} give
# Bazel a writable home and a name for a uid the image passwd file does not
# list; host.docker.internal is mapped so a gate that probes the stack host
# resolves the same way it does in a workspace.
# Globals:
#   CI (passed through when the caller exported it)
#   USER (passed through when set, else this process's login name)
# Arguments:
#   $1 - image tag
#   $2 - proven repo root (the source of the /work bind mount)
#   $3 - user to run as (empty means this process's uid:gid)
#   $4... - the bazelisk argv
# Outputs:
#   One status line, then the bazelisk output
# Returns:
#   The container's exit status; 1 when no tag or bazelisk argv was given
test_in_image_run() {
  if [ "$#" -lt 4 ]; then
    err "test_in_image_run: needs a tag, a repo root, a user and at least one bazelisk arg"
    return 1
  fi
  local tag="$1" root="$2" user="$3"
  shift 3
  if [ -z "${tag}" ] || [ -z "${root}" ]; then
    err "test_in_image_run: the tag and the repo root must be non-empty"
    return 1
  fi
  if [ -z "${user}" ]; then
    user="$(id -u):$(id -g)"
  fi
  log "running bazelisk $* in ${tag} as ${user} against ${root}"
  docker run --rm \
    --user "${user}" \
    -v "${root}:/work" \
    -w /work \
    -e CI \
    -e HOME=/tmp \
    -e "USER=${USER:-$(id -un)}" \
    --add-host=host.docker.internal:host-gateway \
    "${tag}" \
    bazelisk "$@"
}

# @function main
# Parse argv, then either exec bazelisk here (contributor container) or make
# sure the image exists and run the gates inside it.
# Globals:
#   DEV_IMAGE_TAG, EVO_T1_DEVCONTAINER, DEFAULT_IMAGE_TAG
# Arguments:
#   "$@" - the argv documented in the file header
# Outputs:
#   Status lines and the bazelisk output of the run
# Returns:
#   0 when the gates passed; 1 on a usage error, a missing docker CLI, or a
#   failed gate; 5 when no repo root can be proven
main() {
  local image="" user="" force_build=0
  local -a passthru=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --image)
        if [ $# -lt 2 ]; then
          err "--image needs an image tag"
          usage
          exit 1
        fi
        image="$2"
        shift
        ;;
      --user)
        if [ $# -lt 2 ]; then
          err "--user needs a user name"
          usage
          exit 1
        fi
        user="$2"
        shift
        ;;
      --build) force_build=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        while [ $# -gt 0 ]; do
          passthru+=("$1")
          shift
        done
        break
        ;;
      --*)
        err "unknown option: $1"
        usage
        exit 1
        ;;
      *)
        passthru+=("$1")
        ;;
    esac
    shift
  done

  local -a bazel_args=()
  if [ "${#passthru[@]}" -gt 0 ]; then
    bazel_args=("${passthru[@]}")
  else
    bazel_args=(test //:test-fast)
  fi

  # Inside the contributor container this environment is already the image: no
  # docker, no bind mount, no root probe - just run the gates here.
  if test_in_image_in_contributor_env; then
    note "contributor dev container - running bazelisk ${bazel_args[*]} in this environment"
    exec bazelisk "${bazel_args[@]}"
  fi

  if ! has_tool docker; then
    die "docker is not on PATH - run this on a host with the docker CLI, or use the contributor dev container (EVO_T1_DEVCONTAINER=1)"
  fi

  local root tag
  root="$(resolve_repo_root)" || exit 5
  tag="$(test_in_image_tag "${image}")"

  if [ "${force_build}" -eq 1 ]; then
    note "--build - rebuilding ${tag}"
    test_in_image_build "${tag}" "${root}"
  elif ! test_in_image_image_present "${tag}"; then
    note "${tag} is not in the local image store - building it"
    test_in_image_build "${tag}" "${root}"
  else
    note "${tag} is already in the local image store"
  fi

  test_in_image_run "${tag}" "${root}" "${user}" "${bazel_args[@]}"
  return 0
}

main "$@"
