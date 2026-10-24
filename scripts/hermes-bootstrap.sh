#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## hermes-bootstrap.sh - seed the Hermes data directory with its two config files.
#
# Hermes reads two files out of its data directory on every boot: config.yaml
# (which model lane it routes through LiteLLM, which tools it may reach) and
# SOUL.md (the operator's standing instructions to the assistant). That
# directory is a named volume, so a first boot finds it empty and Hermes comes
# up on its shipped defaults instead of this stack's. This script closes that
# gap and then stays out of the way.
#
# The contract is copy-only-when-absent, and that rule is the whole point: an
# operator who edits config.yaml inside the volume keeps their edit across
# every re-create, and --force is the single deliberate way to throw it away.
# Each file answers with one line — seeded, left (already present), or
# re-seeded — so a run reads as a report and not as a diff nobody asked for.
#
# Exactly two names are copied. Skills are NOT: compose bind-mounts the skills
# tree at /opt/stack-skills at runtime, so a copy here would be a second
# source of truth that silently drifts from the checkout the first time
# someone edits one side.
#
# Two modes, one code path:
#   host           resolve the checkout, default the seed to <root>/hermes,
#                  cd there, and write wherever --data points (an operator
#                  names a volume mountpoint; the Bats suites name a tmpdir).
#   --in-container the shape the compose hermes-init service runs: no repo
#                  marker is probed, because an init container carries the
#                  scripts mount and nothing else from the checkout, and the
#                  two paths default to the compose mountpoints /seed and
#                  /opt/data. --seed and --data still override, so the default
#                  is a convenience and never an assumption.
#
# Nothing secret crosses argv: Hermes reads its own credentials from the
# environment, so no flag here takes a password, a token or a key.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:hermes-bootstrap -- --data /srv/stack-data/hermes
#   bazelisk run //scripts:hermes-bootstrap -- --data /srv/stack-data/hermes --force
#   bazelisk run //scripts:hermes-bootstrap -- --seed ./hermes --data ./tmp/hermes
#   bazelisk run //scripts:hermes-bootstrap -- --help
#   # inside the hermes-init container, where compose mounts ./scripts there:
#   /scripts/hermes-bootstrap.sh --in-container
#
# Options (accepted anywhere in argv):
#   --in-container  seed as the compose init service does: --seed defaults to
#                   /seed and --data to /opt/data, and no repo-root probe runs
#   --force         overwrite a config.yaml / SOUL.md that is already there
#   --seed DIR      read config.yaml and SOUL.md from DIR (host default:
#                   <repo root>/hermes; in-container default: /seed)
#   --data DIR      write into DIR. Required on the host, because a host run
#                   has no way to know which volume backs the service;
#                   in-container default: /opt/data
#   -h, --help      print this usage and exit 0
#
# Exit codes: 0 when both files were seeded or left alone; 1 on any error - an
# unknown flag, a flag with no value, a seed directory or seed file that is
# not there, an unusable --data path, or a host run with no --data.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function hermes_seed_files
# Print the file names this script seeds, one per line: the two files Hermes
# reads out of its data directory on every boot. A function and not an array
# so a Bats suite can eval the seed path without inheriting a file-level
# global. Skills are deliberately absent: compose bind-mounts that tree at
# /opt/stack-skills instead of seeding a second copy of it.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One file name per line, in the order they are seeded
# Returns:
#   0
hermes_seed_files() {
  printf '%s\n' config.yaml SOUL.md
}

# @function resolve_repo_root
# Print the checkout root this host run seeds hermes/ from: the first
# candidate that holds a docker-compose.yml marker. A Bazel sandbox holds a
# COPY of the tree, so the probe is a marker file and never a cwd assumption
# (project-conventions.md).
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE, PWD, SELF_DIR
# Arguments:
#   None
# Outputs:
#   The root on stdout, or one complaint line on stderr
# Returns:
#   0 with the root, 5 when no candidate holds the marker
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  # PWD first of the two path probes: under `bazelisk run` the cwd is the
  # checkout, and the two SELF_DIR candidates are what a runfiles copy or a
  # foreign cwd falls back to.
  candidates+=("${PWD}" "${SELF_DIR}" "${SELF_DIR}/..")

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

# @function find_common_lib
# Print the path scripts/lib/common.sh is reachable from: the env-named root
# first, then this script's own directory. Under `bazelisk run` both exist
# inside the runfiles copy (//scripts:doc_sources carries scripts/**/*.sh
# beside the entry script), and under --in-container only the second does,
# because compose mounts ./scripts beside this file and brings no checkout.
# Globals:
#   SELF_DIR
# Arguments:
#   $1 - lib file name, relative to the lib directory
#   $2 - root to probe first, possibly empty
# Outputs:
#   The lib path on stdout, or one complaint line on stderr
# Returns:
#   0 when the lib was found, 1 otherwise
find_common_lib() {
  local name="$1" root="${2:-}" candidate
  local -a candidates=()
  if [ -n "${root}" ]; then
    candidates+=("${root}/scripts/lib/${name}")
  fi
  candidates+=("${SELF_DIR}/lib/${name}")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: %s is not reachable from %s\n' "${name}" "${candidates[*]}" >&2
  return 1
}

# The env-named roots are the only ones tried before SELF_DIR: this runs
# before argv is parsed, so --in-container cannot be known yet, and an init
# container sets neither variable and must not need a checkout marker.
COMMON_LIB="$(find_common_lib common.sh "${REPO_ROOT:-${GITHUB_WORKSPACE:-}}")" || {
  printf 'error: hermes-bootstrap cannot run without its helpers: no scripts/lib/common.sh beside %s\n' \
    "${SELF_DIR}" >&2
  exit 1
}

# shellcheck source=lib/common.sh disable=SC1091
source "${COMMON_LIB}"

# @function usage
# Print the flag list and the exit-code contract on stdout, so a typo prints
# something readable instead of nothing.
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
usage: bazelisk run //scripts:hermes-bootstrap -- [--in-container] [--force]
                    [--seed DIR] [--data DIR] [-h|--help]

Seeds the Hermes data directory with the two files Hermes reads on every
boot: config.yaml and SOUL.md. A file that is already there is left alone, so
an operator's edits survive a re-create; --force is the one way to overwrite
them. Skills are never copied here - compose bind-mounts that tree at
/opt/stack-skills.

One line per file: "seeded <name>", "left <name> (already present)", or
"re-seeded <name>".

Options: --in-container (the compose hermes-init shape: --seed defaults to
/seed, --data to /opt/data, and no repo-root probe runs), --force, --seed DIR
(host default <repo root>/hermes), --data DIR (required on the host),
-h/--help.

Exit codes: 0 = both files seeded or left alone; 1 = unknown flag, a flag
with no value, a missing seed file, an unusable data path, or a host run with
no --data.

Run it as a Bazel target from anywhere:
  bazelisk run //scripts:hermes-bootstrap -- --data /srv/stack-data/hermes
  bazelisk run //scripts:hermes-bootstrap -- --seed ./hermes --data ./tmp
USAGE
}

# @function seed_one_file
# Copy one named file from a seed directory into a data directory, or leave the
# copy that is already there. Absent gets seeded, present stays, --force wins:
# those three answers are the whole contract, and the one line printed names
# which of them happened.
# Globals:
#   None
# Arguments:
#   $1 - seed directory holding the file
#   $2 - data directory to write into (created)
#   $3 - file name, one of the names hermes_seed_files prints
#   $4 - force flag, 1 overwrites an existing copy, anything else does not
# Outputs:
#   "seeded <name>", "left <name> (already present)", or "re-seeded <name>"
# Returns:
#   0 when the data directory holds the file; exits 1 when the seed file is
#   missing or the copy cannot be made
seed_one_file() {
  local src_dir="$1" dest_dir="$2" name="$3" force="${4:-0}"
  local src="${src_dir}/${name}" dest="${dest_dir}/${name}"

  if [ ! -f "${src}" ]; then
    die "seed file ${src} is missing: nothing to seed for ${name}"
  fi

  if [ -f "${dest}" ] && [ "${force}" != "1" ]; then
    log "left ${name} (already present)"
    return 0
  fi

  # Reaching here with a destination that exists means --force, and that is
  # the only difference in the line printed: the copy itself is the same.
  local action="seeded"
  if [ -f "${dest}" ]; then
    action="re-seeded"
  fi

  mkdir -p "${dest_dir}" || die "could not create the data directory ${dest_dir}"
  cp "${src}" "${dest}" || die "could not copy ${src} to ${dest}"
  log "${action} ${name}"
}

# @function seed_hermes_data
# Seed every name hermes_seed_files prints from one seed directory into one
# data directory. Only those names are read: the skills tree is bind-mounted
# at /opt/stack-skills by compose, so copying it here would put a second copy
# of it where nobody edits it.
# Globals:
#   None (reads the name list from hermes_seed_files)
# Arguments:
#   $1 - seed directory (host default <repo root>/hermes, in-container /seed)
#   $2 - data directory (created when missing)
#   $3 - force flag, 1 overwrites existing copies
# Outputs:
#   One line per file, from seed_one_file
# Returns:
#   0 when every name is in place; exits 1 when the seed directory is not a
#   directory or one of its files cannot be seeded
seed_hermes_data() {
  local seed_dir="$1" data_dir="$2" force="${3:-0}" name

  [ -d "${seed_dir}" ] || die "seed directory ${seed_dir} is not a directory"
  mkdir -p "${data_dir}" || die "could not create the data directory ${data_dir}"

  while IFS= read -r name; do
    seed_one_file "${seed_dir}" "${data_dir}" "${name}" "${force}"
  done < <(hermes_seed_files)
  return 0
}

# @function main
# Parse argv, settle the seed and data directories for this mode, and seed.
# Globals:
#   None (everything it settles is a local; the name list comes from
#   hermes_seed_files through seed_hermes_data)
# Arguments:
#   "$@" - the CLI contract in the file header
# Outputs:
#   The usage block, or one line per file from seed_hermes_data
# Returns:
#   0 on a completed run; exits 1 on an unknown flag, a valueless flag, a
#   host run with no --data, or an unresolvable checkout
main() {
  local in_container=0 force=0 seed_dir="" data_dir="" root=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --in-container)
        in_container=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      --seed)
        [ "$#" -ge 2 ] || die "--seed needs a directory"
        seed_dir="$2"
        shift 2
        ;;
      --data)
        [ "$#" -ge 2 ] || die "--data needs a directory"
        data_dir="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument '$1' (see --help)"
        usage
        exit 1
        ;;
    esac
  done

  if [ "${in_container}" = "1" ]; then
    # Compose owns both paths here: ./hermes on /seed, the named volume on
    # /opt/data. The two defaults answer for the init container, whose only
    # mount from this repo is the scripts tree that carries lib/common.sh.
    seed_dir="${seed_dir:-/seed}"
    data_dir="${data_dir:-/opt/data}"
  else
    root="$(resolve_repo_root)" || {
      err "a host run seeds from the checkout; pass --seed DIR (or --in-container)"
      exit 1
    }
    cd "${root}" || die "cannot enter the resolved checkout ${root}"
    seed_dir="${seed_dir:-${root}/hermes}"
    # No host default for the destination: a host cannot know which volume
    # backs the service, and seeding the wrong directory is worse than doing
    # nothing and saying why.
    [ -n "${data_dir}" ] ||
      die "--data is required on the host: point it at the Hermes data directory (the volume compose mounts at /opt/data)"
  fi

  seed_hermes_data "${seed_dir}" "${data_dir}" "${force}"
}

main "$@"
