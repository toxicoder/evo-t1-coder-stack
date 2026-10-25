# shellcheck shell=bash
#
# ## image.sh — golden-image pin checks (sourced; never executed)
#
# scripts/build-dev-image.sh refuses to build when a KEY in
# images/dev/tool-versions.env has no matching ARG in images/dev/Dockerfile, and
# when an ARG default there drifts from the pin. Both comparisons live here — the
# name scan and the value scan — so drift is unit-tested without a docker build.
#
# Invariants:
#   - Sourcing this file changes no shell options and runs no docker command.
#   - The ARG scan matches the historical awk in build-dev-image.sh, including
#     backslash-continued ARG lines and comment skipping.
#   - Pure text comparison: no docker, no extra dependencies, no sourcing of
#     scripts/lib/tool_pins.sh.
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

# @function dockerfile_arg_defaults
# Print KEY=value for every ARG that declares a default; ARGs without one (the
# reserved TARGETARCH) are omitted.
# Globals:
#   None
# Arguments:
#   $1 - path to the Dockerfile
# Outputs:
#   KEY=value pairs, one per line, sorted and unique
# Returns:
#   0
dockerfile_arg_defaults() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*ARG[[:space:]]/ { inblk = 1 }
    inblk {
      line = $0
      sub(/^[[:space:]]*ARG[[:space:]]+/, "", line)
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      gsub(/^[[:space:]]+/, "", line)
      eq = index(line, "=")
      if (eq > 0) {
        name = substr(line, 1, eq - 1)
        value = substr(line, eq + 1)
        sub(/[[:space:]]+$/, "", name)
        sub(/[[:space:]]+$/, "", value)
        if (name ~ /^[A-Z0-9_]+$/) print name "=" value
      }
      inblk = ($0 ~ /[[:space:]]\\[[:space:]]*$/)
    }
  ' "$1" | sort -u
}

# @function mismatched_arg_defaults
# Print version-file keys whose Dockerfile ARG default is missing or differs.
# Globals:
#   None
# Arguments:
#   $1 - Dockerfile path
#   $2 - tool-versions.env path
# Outputs:
#   "KEY pin=<val> dockerfile=<default>" per drift; an absent ARG default
#   prints an empty dockerfile= field. Nothing when every pin matches.
# Returns:
#   0
mismatched_arg_defaults() {
  local dockerfile="$1" versions="$2" line key pin have want
  have="$(dockerfile_arg_defaults "${dockerfile}")"
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    key="${line%%=*}"
    pin="${line#*=}"
    want="$(grep -m 1 "^${key}=" <<<"${have}" || true)"
    want="${want#"${key}="}"
    if [ "${want}" != "${pin}" ]; then
      printf '%s pin=%s dockerfile=%s\n' "${key}" "${pin}" "${want}"
    fi
  done < <(grep -E '^[A-Z0-9_]+=' "${versions}" || true)
}
