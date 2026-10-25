#!/bin/sh
# shellcheck shell=sh
#
# ## probes/spark-configure.sh — Print one Spark recipe's container facts and recipe-probe verdicts as key=value lines for one ssh round trip (POSIX probe; run with sh, never sourced by the remote)

# @function say
# Print one key=value line on the remote probe host.
# Globals:
#   None
# Arguments:
#   $1 - line to print
# Outputs:
#   The line on stdout
# Returns:
#   0
say() {
  printf '%s\n' "$1"
}
if command -v docker >/dev/null 2>&1; then
  have_docker=present
  docker_runtimes="$(docker info --format '{{.ServerVersion}} {{.SecurityOptions}} {{.Runtimes}}' 2>/dev/null | cut -c1-200)"
else
  have_docker=missing
  docker_runtimes=missing
fi
if [ -d /dev/dri ]; then
  dri=present
else
  dri=missing
fi
disk_kb="$(df -Pbk / 2>/dev/null | tail -n 1 | awk '{print $4}')"
[ -n "${disk_kb}" ] || disk_kb=0
disk_gib="$(awk -v kb="${disk_kb}" 'BEGIN { printf "%.1f", kb / 1048576 }')"
mem_gib="$(awk '/MemAvailable/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo 2>/dev/null)"
[ -n "${mem_gib}" ] || mem_gib=0
keys="PARALLEL CONTEXT KV_DTYPE SERVED_NAME PORT MAX_TOKENS TENSORFOLD_MEMORY_RESERVE_GIB TENSORFOLD_PREFILL_ROWS TENSORFOLD_MTP_COPY VISION TENSORFOLD_IMAGE_TOKENS VISION_MAX_IMAGES"
say "have_docker=${have_docker}"
say "docker_runtimes=${docker_runtimes}"
say "dri=${dri}"
say "disk_free_gib=${disk_gib}"
say "mem_free_gib=${mem_gib}"
say "recipe_dir=${RECIPE_DIR:-}"
if [ -d "${RECIPE_DIR:-/nonexistent}" ]; then
  say "clone=present"
else
  say "clone=missing"
fi
if [ -f "${RECIPE_DIR:-/nonexistent}/.env" ]; then
  say "env_file=present"
else
  say "env_file=missing"
fi
if [ -f "${RECIPE_DIR:-/nonexistent}/scripts/config.sh" ]; then
  say "config_sh=present"
else
  say "config_sh=missing"
fi
say "container_state=$(docker ps --no-trunc --format '{{.Names}} {{.State}}' 2>/dev/null | grep "^${CONTAINER} " | tail -n 1 | cut -d' ' -f2-)"
cenv="$(docker inspect "${CONTAINER}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
# A server started with plain docker run and -e flags has CUDA_VISIBLE_DEVICES in its
# environment and no recipe clone behind it, so start.sh restart cannot re-derive its
# settings: that is the case that gets a hand-run command printed, never executed.
say "gpu_env=missing"
printf '%s\n' "${cenv}" | grep -q 'CUDA_VISIBLE_DEVICES=' && say "gpu_env=present"
for key in $keys; do
  # Read the two files as text, never source them: this body runs under `sh` on the
  # box, where one bad line in a hand-edited .env would abort the whole probe, and
  # the reason the repo's own env_get reads with sed instead of sourcing is the same.
  value=""
  for recipe_file in "${RECIPE_DIR:-/nonexistent}/scripts/config.sh" "${RECIPE_DIR:-/nonexistent}/.env"; do
    if [ -f "${recipe_file}" ]; then
      found="$(sed -n "s|^${key}=||p" "${recipe_file}" 2>/dev/null | tail -n 1 | tr -d "\"'")"
      if [ -n "${found}" ]; then
        value="${found}"
      fi
    fi
  done
  [ -n "${value}" ] || value=NOTSET
  say "recipe.${key}=${value}"
done
if [ -n "${cenv}" ]; then
  for key in $keys; do
    value="$(printf '%s\n' "${cenv}" | grep "^${key}=" | tail -n 1 | cut -d= -f2- | tr ' ' '_')"
    [ -n "${value}" ] || value=NOTSET
    say "inspect.${key}=${value}"
  done
fi
say report_end
