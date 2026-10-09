# shellcheck shell=bash
#
# ## image.sh — golden-image pin checks (sourced; never executed)
#
# scripts/build-dev-image.sh refuses to build when a KEY in
# images/dev/tool-versions.env has no matching ARG in images/dev/Dockerfile.
# The comparison lives here so that drift is unit-tested without a docker build.
#
# Invariants:
#   - Sourcing this file changes no shell options and runs no docker command.
#   - The ARG scan matches the historical awk in build-dev-image.sh, including
#     backslash-continued ARG lines and comment skipping.
#
# Usage (after the repo-root cd):
#   # shellcheck source=lib/image.sh disable=SC1091
#   source "scripts/lib/image.sh"

# @function dockerfile_arg_names
# Print the ARG names a Dockerfile declares, one per line, sorted and unique.
# Globals:
#   None
# Arguments:
#   $1 - path to the Dockerfile
# Outputs:
#   ARG names, one per line
# Returns:
#   0
dockerfile_arg_names() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*ARG[[:space:]]/ { inblk = 1 }
    inblk {
      line = $0
      sub(/^[[:space:]]*ARG[[:space:]]+/, "", line)
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      gsub(/^[[:space:]]+/, "", line)
      split(line, kv, /=/)
      if (kv[1] ~ /^[A-Z0-9_]+$/) print kv[1]
      inblk = ($0 ~ /[[:space:]]\\[[:space:]]*$/)
    }
  ' "$1" | sort -u
}

# @function missing_version_pins
# Print version-file keys that the Dockerfile does not declare as ARG.
# Globals:
#   None
# Arguments:
#   $1 - Dockerfile path
#   $2 - tool-versions.env path
# Outputs:
#   Missing keys, one per line; nothing when every key has an ARG
# Returns:
#   0
missing_version_pins() {
  local dockerfile="$1" versions="$2" key declared
  declared="$(dockerfile_arg_names "${dockerfile}")"
  while IFS= read -r key; do
    [ -n "${key}" ] || continue
    if ! grep -qx "${key}" <<<"${declared}"; then
      printf '%s\n' "${key}"
    fi
  done < <(grep -oE '^[A-Z0-9_]+=' "${versions}" | tr -d '=' || true)
}
