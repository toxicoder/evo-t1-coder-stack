#!/bin/sh
# shellcheck shell=sh
#
# ## probes/spark-monitor.sh - Print what one Spark box exposes to monitoring - docker, node_exporter, the DCGM exporter, the GPUs - as key=value lines for one ssh round trip (POSIX probe; run with sh, never sourced by the remote)
#
# Ferried by probe_transport in scripts/lib/spark.sh (this whole file travels
# base64-encoded as one quoted ssh argument, is decoded on the box and run
# through sh) on behalf of scripts/spark-monitor.sh --status and --json, which
# parse these lines into the table. The caller may prepend assignments; the one
# this body reads is SPARK_DCGM_EXPORTER_IMAGE, and only to look that tag up in
# the box's LOCAL image store - the probe never pulls.
#
# Read-only by construction: nothing here installs, writes, starts, restarts, or
# pulls, and no temp file is needed. A tool the box does not have is an answer
# rather than a failure, so every unavailable thing prints <key>=absent and the
# probe exits 0 even when nothing at all is installed.
#
# Twelve keys, printed in this order, exactly once each, no spaces in any value:
#   probe_version, spark_host, docker_available, node_exporter_running,
#   node_exporter_port, node_exporter_image, dcgm_running, dcgm_port,
#   dcgm_image, dcgm_counter_count, gpu_count, gpu_names
# gpu_names joins the models with + because a value may not carry a space.

PROBE_VERSION=1
DCGM_IMAGE_DEFAULT="nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04"

# @function say_key
# Print one KEY=value line, sanitised so the CLI's parser always gets one line
# with a value: spaces and carriage returns out, absent in place of empty.
# Globals:
#   None
# Arguments:
#   $1 - key; $2 - raw value
# Outputs:
#   key=value on stdout
# Returns:
#   0
say_key() {
  value="${2:-}"
  value="$(printf '%s' "${value}" | tr -d ' \t\r\n')"
  if [ -z "${value}" ]; then
    value=absent
  fi
  printf '%s=%s\n' "$1" "${value}"
}

# @function docker_run
# Run one docker command with the daemon's own complaint silenced, so a missing
# daemon, a permission denial, or a bad container name yields no output here
# instead of a stack of stderr over the ssh channel.
# Globals:
#   None
# Arguments:
#   $1... - docker subcommand and its arguments
# Outputs:
#   Whatever docker printed on stdout, or nothing
# Returns:
#   0
docker_run() {
  docker "$@" 2>/dev/null || true
}

# @function exporter_cid
# Find one exporter container by image, not by name: --apply names the two it
# starts, but a box someone started by hand from the same image is still a box
# that answers scrapes, and a name the operator chose must not read as nothing.
# Globals:
#   None
# Arguments:
#   $1 - substring the image must contain
# Outputs:
#   One container id, or nothing
# Returns:
#   0
exporter_cid() {
  # Matched with index() rather than a leading-space grep: the image a box runs is
  # the full reference (quay.io/prometheus/node-exporter:v1.12.1), so anchoring the
  # substring on a space only ever matched a name that begins a path component, and
  # a real box read as having no exporter at all. The last match wins, which is the
  # newest container when docker ps lists in its default created-descending order.
  docker_run ps --format '{{.ID}} {{.Image}}' |
    awk -v want="${1:-}" 'want != "" && index($2, want) > 0 { id = $1 } END { if (id != "") print id }'
}

# @function exporter_port
# The port the exporter answers on: the published host port when the container
# publishes one, otherwise the port it exposes, since a --network host box
# publishes nothing and is scraped on the container's own port.
# Globals:
#   None
# Arguments:
#   $1 - container id
# Outputs:
#   One port number, or nothing
# Returns:
#   0
exporter_port() {
  cid="${1:-}"
  [ -n "${cid}" ] || return 0
  port="$(docker_run inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}} {{end}}{{end}}' "${cid}" | tr ' ' '\n' | grep -E '^[0-9]+$' | head -n 1)"
  if [ -z "${port}" ]; then
    port="$(docker_run inspect --format '{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "${cid}" | tr ' ' '\n' | grep -E '^[0-9]+/' | head -n 1 | cut -d/ -f1)"
  fi
  printf '%s' "${port}"
}

# @function exporter_image
# The image the running container was created from, which is the tag the caller
# has to compare against the pin.
# Globals:
#   None
# Arguments:
#   $1 - container id
# Outputs:
#   One image reference, or nothing
# Returns:
#   0
exporter_image() {
  cid="${1:-}"
  [ -n "${cid}" ] || return 0
  docker_run inspect --format '{{.Config.Image}}' "${cid}" | head -n 1
}

# @function http_metrics
# One capped scrape of a local metrics endpoint. Empty means "did not answer",
# which is a result: nothing here retries, waits, or reports an error.
# Globals:
#   None
# Arguments:
#   $1 - URL
# Outputs:
#   The response body, or nothing
# Returns:
#   0
http_metrics() {
  body=""
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsS -m 5 "$1" 2>/dev/null || true)"
  fi
  if [ -z "${body}" ] && command -v wget >/dev/null 2>&1; then
    body="$(wget -q -T 5 -t 1 -O - "$1" 2>/dev/null || true)"
  fi
  printf '%s' "${body}"
}

# @function counter_names
# Count the distinct DCGM_FI_* counter names in a scrape body or in the
# exporter's own counters file. DCGM series are DCGM_FI_*, never dcgm_*, and a
# box with one GPU emits each of them once, so counting series would report the
# GPU count rather than the counter set.
# Globals:
#   None
# Arguments:
#   $1 - text to read the counter names out of
# Outputs:
#   One number, or nothing when there were none
# Returns:
#   0
counter_names() {
  counted="$(printf '%s\n' "${1:-}" | grep -oE '^[[:space:]]*DCGM_FI_[A-Za-z0-9_]+' | tr -d ' \t' | sort -u | grep -c 'DCGM_FI_')"
  if [ "${counted}" = 0 ]; then
    printf '%s' ""
  else
    printf '%s' "${counted}"
  fi
}

have_docker=absent
if command -v docker >/dev/null 2>&1; then
  have_docker=present
fi

spark_host="$(hostname 2>/dev/null | head -n 1 | cut -d. -f1)"
if [ -z "${spark_host}" ]; then
  spark_host="$(uname -n 2>/dev/null | head -n 1 | cut -d. -f1)"
fi

node_cid=""
dcgm_cid=""
if [ "${have_docker}" = present ]; then
  node_cid="$(exporter_cid node-exporter)"
  dcgm_cid="$(exporter_cid dcgm-exporter)"
fi

node_state=absent
node_port=""
node_image=""
if [ -n "${node_cid}" ]; then
  node_state=running
  node_port="$(exporter_port "${node_cid}")"
  node_image="$(exporter_image "${node_cid}")"
fi

dcgm_state=absent
dcgm_port=""
dcgm_image=""
dcgm_counters=""
if [ -n "${dcgm_cid}" ]; then
  dcgm_state=running
  dcgm_port="$(exporter_port "${dcgm_cid}")"
  dcgm_image="$(exporter_image "${dcgm_cid}")"
  scraped=""
  case "${dcgm_port}" in
    '' | *[!0-9]*) ;;
    *) scraped="$(http_metrics "http://127.0.0.1:${dcgm_port}/metrics")" ;;
  esac
  dcgm_counters="$(counter_names "${scraped}")"
  if [ -z "${dcgm_counters}" ]; then
    # No scrape to count, so count what the exporter itself ships: the CSV the
    # container was started with is the counter set, and reading it out of the
    # running container needs no image pull and no write.
    dcgm_counters="$(counter_names "$(docker_run exec "${dcgm_cid}" cat /etc/dcgm-exporter/default-counters.csv)")"
  fi
fi

gpu_count=absent
gpu_names=absent
gpu_lines=""
have_nvidia_smi=absent
if command -v nvidia-smi >/dev/null 2>&1; then
  have_nvidia_smi=present
  gpu_lines="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | grep -v '^[[:space:]]*$')"
fi
if [ "${have_nvidia_smi}" = absent ] && [ "${have_docker}" = present ] &&
  command -v timeout >/dev/null 2>&1; then
  # The last resort for a box whose driver is fine and whose host PATH is not:
  # ask the exporter image's own nvidia-smi. Only ever an image the box already
  # has, and only under a wall-clock cap, because a docker run with nothing
  # local would spend its time pulling.
  probe_image="${SPARK_DCGM_EXPORTER_IMAGE:-${DCGM_IMAGE_DEFAULT}}"
  if [ -n "${dcgm_image}" ]; then
    probe_image="${dcgm_image}"
  fi
  if [ -n "$(docker_run image ls -q "${probe_image}" | head -n 1)" ]; then
    gpu_lines="$(timeout 20 docker run --rm --gpus all --entrypoint nvidia-smi \
      "${probe_image}" --query-gpu=name --format=csv,noheader 2>/dev/null)"
  fi
fi
if [ "${have_nvidia_smi}" = present ] || [ -n "${gpu_lines}" ]; then
  gpu_count="$(printf '%s\n' "${gpu_lines}" | grep -c '.')"
  joined="$(printf '%s\n' "${gpu_lines}" | tr '\n' ' ' | tr ' ' '+' | sed 's/++*/+/g; s/^+//; s/+$//')"
  if [ -n "${joined}" ]; then
    gpu_names="${joined}"
  fi
fi

say_key probe_version "${PROBE_VERSION}"
say_key spark_host "${spark_host}"
say_key docker_available "${have_docker}"
say_key node_exporter_running "${node_state}"
say_key node_exporter_port "${node_port}"
say_key node_exporter_image "${node_image}"
say_key dcgm_running "${dcgm_state}"
say_key dcgm_port "${dcgm_port}"
say_key dcgm_image "${dcgm_image}"
say_key dcgm_counter_count "${dcgm_counters}"
say_key gpu_count "${gpu_count}"
say_key gpu_names "${gpu_names}"

# Always 0: a box with nothing installed is a state the CLI reports as a
# warning, never a probe failure.
exit 0
