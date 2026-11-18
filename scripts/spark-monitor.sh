#!/usr/bin/env bash
# spark-monitor.sh -- make the three DGX Sparks Prometheus targets: plan the two exporter
# containers every box needs, prove with --status what a box actually runs, and with
# --apply create and start them.
#
# Usage:
#   bazelisk run //scripts:spark-monitor                           # plan only (the default)
#   bazelisk run //scripts:spark-monitor -- --dry-run              # the same plan, named
#   bazelisk run //scripts:spark-monitor -- --box 2                # one box: 1, 2 or 3
#   bazelisk run //scripts:spark-monitor -- --status               # run the probe, print the table
#   bazelisk run //scripts:spark-monitor -- --apply                # create/start both exporters
#   bazelisk run //scripts:spark-monitor -- --restart              # restart both exporter containers
#   bazelisk run //scripts:spark-monitor -- --targets              # print sparks.json for file_sd_configs
#   bazelisk run //scripts:spark-monitor -- --json                 # one JSON object on stdout
#   SPARK1_HOST=spark-1.lan bazelisk run //scripts:spark-monitor    # process env names the fleet
#
# Plan is the default: it runs no ssh and no docker, and prints per box what is
# configured, what is unmeasured, and the exact `docker run` lines --apply would ferry.
# That is the run an operator makes before pointing Prometheus at three boxes they have
# not looked at yet, and a gate asserts this path opens no ssh session at all.
#
# The two exporters are the ones //observability scrapes: node_exporter on
# SPARK_NODE_EXPORTER_PORT (9100) and the NVIDIA DCGM exporter on
# SPARK_DCGM_EXPORTER_PORT (9400), gated by SPARK_MONITOR_ENABLED and imaged by
# SPARK_DCGM_EXPORTER_IMAGE. Nothing here opens a dotenv file by hand: every value is
# read from the process environment first and from .env second through the env_get
# reader, which is compose's own precedence, so a run cannot disagree with how the stack
# was published.
#
# The DCGM tag is the one pin this stack could not verify upstream (nvcr.io answers 404
# to an anonymous token), so --apply surfaces whatever the registry says instead of
# swallowing it, and --status prints the tag a box actually runs.
#
# Both containers are provisioned from this checkout: the DCGM exporter gets
# observability/dcgm/custom-counters.csv ferried to it and mounted read-only, so the
# DCGM_FI_* series Prometheus sees are the ones this repo reviews, not the image's list.
#
# Exit: 0 when every box answered or is simply not set up yet -- a box with nothing
# installed is a warning, not a failure. Non-zero only when a mutator (--apply or
# --restart) ran and a box failed, because three Sparks of which two are scraped is the
# drift this CLI exists to remove.
# ## spark-monitor.sh -- the Spark fleet's Prometheus exporters

# shellcheck disable=SC2016 # usage() prints the header block above, where $SPARK1_HOST
# is literal text in this script's own comments, not an expansion.
# @function usage
# Print this script's help text.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The help text on stdout
# Returns:
#   0
usage() { sed -n '2,41p' "$0"; }

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/spark.sh disable=SC1091
source "${SELF_DIR}/lib/spark.sh" # sources scripts/lib/common.sh
# A leftover JSON_MODE in the environment would hide the human output before --json is
# ever parsed; --json below is the only thing that sets it.
unset JSON_MODE

# The fleet and the exporter ports come from the checkout's .env, so the checkout is
# resolved before either is read: `bazelisk run` executes the runfiles copy, where .env
# is absent and the fleet would fall back to the placeholder trio.
ROOT_DIR="$(resolve_checkout "${SELF_DIR}")" || exit 5
cd "${ROOT_DIR}"

# -- Knobs --------------------------------------------------------------------

# The two container names this CLI owns on every box. Both are idempotent by name: a
# second --apply starts what is there instead of creating a second container on a port
# the first one already holds.
node_container="spark-node-exporter"
dcgm_container="spark-dcgm-exporter"

# node_exporter's pin is verified (github tag prometheus/node_exporter v1.12.1, HTTP
# 200). The DCGM pin is NOT: nvcr.io manifests answer 404 to an anonymous token, so the
# tag is a .env key the operator can correct without a code change.
node_exporter_image="quay.io/prometheus/node-exporter:v1.12.1"
node_port_default=9100
dcgm_port_default=9400
dcgm_image_default="nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04"

# The probe the box runs, as a payload of this script next to the other two Spark probes.
probe_file="scripts/lib/probes/spark-monitor.sh"

# The DCGM field list, declared as this CLI's payload in scripts/BUILD.bazel and as
# //observability:dcgm_counters. It is ferried to every box and bind-mounted read-only
# into the exporter, so the DCGM_FI_* series Prometheus sees are the ones this repo
# reviews rather than whatever the image ships.
counters_file="observability/dcgm/custom-counters.csv"
counters_remote="/opt/evo-t1/dcgm/custom-counters.csv"
counters_container="/etc/dcgm-exporter/custom-counters.csv"

ssh_user="${SPARK_SSH_USER:-${LOGNAME:-}}"
ssh_port=22
probe_cap=20
apply_cap=180

mode=plan
mode_given=""
box_wanted=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      mode=plan
      shift
      ;;
    --status)
      [ -z "${mode_given}" ] || die "--status cannot be combined with ${mode_given}; pick one mode"
      mode=status
      mode_given="--status"
      shift
      ;;
    --apply)
      [ -z "${mode_given}" ] || die "--apply cannot be combined with ${mode_given}; pick one mode"
      mode=apply
      mode_given="--apply"
      shift
      ;;
    --restart)
      [ -z "${mode_given}" ] || die "--restart cannot be combined with ${mode_given}; pick one mode"
      mode=restart
      mode_given="--restart"
      shift
      ;;
    --targets)
      [ -z "${mode_given}" ] || die "--targets cannot be combined with ${mode_given}; pick one mode"
      mode=targets
      mode_given="--targets"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --box)
      [ "$#" -ge 2 ] || die "--box needs a box number (1, 2 or 3)"
      case "$2" in '' | *[!0-9]*) die "--box needs a number, got '$2'" ;; esac
      box_wanted="$2"
      shift 2
      ;;
    --user)
      [ "$#" -ge 2 ] || die "--user needs a value"
      ssh_user="$2"
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || die "--port needs a value"
      ssh_port="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option '$1' -- usage: bazelisk run //scripts:spark-monitor -- [options] (see --help)"
      ;;
    *)
      die "unexpected argument '$1' -- this CLI takes no host arguments; the fleet is SPARK_HOSTS or the SPARKn_HOST keys, and one box is --box <n>"
      ;;
  esac
done

# @function setting_value
# Print the value this run uses for one .env key: the process environment first, then
# .env, then the caller's default. That is compose's own precedence for interpolation,
# so a run cannot plan against ports the stack was not published with. Read with env_get
# and never sourced: .env is user-editable.
# Globals:
#   None
# Arguments:
#   $1 - key name; $2 - default when neither source carries a value
# Outputs:
#   The value on stdout, without a trailing newline
# Returns:
#   0
setting_value() {
  local key="$1" default="${2:-}" indirect="$1" value=""
  value="${!indirect:-}"
  if [ -z "${value}" ]; then
    value="$(env_get .env "${key}" | tr -d ' \r' || true)"
  fi
  printf '%s' "${value:-${default}}"
}

# @function probe_script
# Print the remote probe script that one ssh round trip will run.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The script text on stdout
# Returns:
#   0
probe_script() {
  cat "${probe_file}"
}

node_port="$(setting_value SPARK_NODE_EXPORTER_PORT "${node_port_default}")"
dcgm_port="$(setting_value SPARK_DCGM_EXPORTER_PORT "${dcgm_port_default}")"
dcgm_image="$(setting_value SPARK_DCGM_EXPORTER_IMAGE "${dcgm_image_default}")"
monitor_enabled="$(setting_value SPARK_MONITOR_ENABLED false)"

for port_pair in "SPARK_NODE_EXPORTER_PORT=${node_port}" "SPARK_DCGM_EXPORTER_PORT=${dcgm_port}"; do
  case "${port_pair#*=}" in '' | *[!0-9]*) die "${port_pair% *}='${port_pair#*=}' is not a port number" ;; esac
done
if [ -z "${dcgm_image}" ]; then
  die "SPARK_DCGM_EXPORTER_IMAGE is set but empty; leave it unset for the shipped pin or name an image"
fi

# The --web.listen-address / -a arguments are what pin each exporter to the port
# Prometheus is told to scrape, and node_exporter needs --collector.processes spelled
# out or node_processes_* is simply absent. Kept as one string each so the plan prints
# exactly what --apply ferries, with nothing to drift between the two. The DCGM mount and
# --collectors flag are only there when the checked-in counter list exists: without it the
# exporter falls
# back to its built-in list rather than failing to start, and the run says so.
node_args="--pid host --net host --restart unless-stopped -v /:/host:ro,rslave ${node_exporter_image} --path.rootfs=/host --collector.processes --web.listen-address=:${node_port}"
if [ -f "${counters_file}" ]; then
  dcgm_mount="-v ${counters_remote}:${counters_container}:ro"
  # --collectors is dcgm-exporter's own name for the custom counter file (-f is its
  # short form); spelled out because observability/dcgm/custom-counters.csv documents the
  # mount by that name.
  dcgm_counter_flag="--collectors ${counters_container}"
else
  dcgm_mount=""
  dcgm_counter_flag=""
fi
dcgm_args="--gpus all --net host --restart unless-stopped ${dcgm_mount} ${dcgm_image} -a :${dcgm_port} ${dcgm_counter_flag}"

# -- the fleet ----------------------------------------------------------------

# A SPARKn_HOST exported in the process environment outranks .env, which is the same
# precedence compose_observability_args applies to OBSERVABILITY_ENABLED and compose
# itself applies to interpolation. The list is still resolved by derive_spark_hosts: the
# process environment is that function's own documented top-precedence input, so no host
# is ever derived here.
if [ -z "${SPARK_HOSTS:-}" ]; then
  env_hosts=""
  for box_no in 1 2 3; do
    host_indirect="SPARK${box_no}_HOST"
    env_host="$(canonical_url "${!host_indirect:-}")"
    case "${env_host}" in '' | *[!A-Za-z0-9.-]*) continue ;; esac
    case " ${env_hosts} " in *" ${env_host} "*) continue ;; esac
    env_hosts="${env_hosts:+${env_hosts} }${env_host}"
  done
  [ -z "${env_hosts}" ] || SPARK_HOSTS="${env_hosts}"
fi

derive_spark_hosts .env
hosts=()
boxes=()
box_index=0
# shellcheck disable=SC2086 # word splitting over the resolved list is the point
for host in ${SPARK_HOSTS_RESOLVED}; do
  box_index=$((box_index + 1))
  hosts+=("${host}")
  boxes+=("spark-${box_index}")
done
if [ -n "${box_wanted}" ]; then
  if [ "${box_wanted}" -lt 1 ] || [ "${box_wanted}" -gt "${#hosts[@]}" ]; then
    die "--box ${box_wanted}: the resolved fleet has ${#hosts[@]} box(es): ${SPARK_HOSTS_RESOLVED}"
  fi
  hosts=("${hosts[$((box_wanted - 1))]}")
  boxes=("spark-${box_wanted}")
fi

# -- --targets: the file_sd file, to stdout, never written --------------------

if [ "${mode}" = targets ]; then
  # stdout is the document Prometheus reads, so the commentary goes to stderr the same way
  # --json does it. The file itself (observability/spark-targets/sparks.json) is
  # written on the stack host by the operator redirecting this output: printing only
  # is what keeps a laptop run from rewriting the host's target set.
  JSON_MODE=1
  # Joined into one string before anything is printed: the array has to be one valid
  # document even when the flag is off and there is nothing in it, which is when a
  # trailing comma or an empty line would be the whole output.
  target_lines=""
  target_idx=0
  if truthy "${monitor_enabled}"; then
    while [ "${target_idx}" -lt "${#hosts[@]}" ]; do
      target_host="${hosts[${target_idx}]}"
      target_idx=$((target_idx + 1))
      target_lines="${target_lines}${target_lines:+,}"
      target_lines="${target_lines}{\"targets\":[\"${target_host}:${node_port}\"],\"labels\":{\"box\":\"spark-${target_idx}\",\"exporter\":\"node_exporter\"}}"
      target_lines="${target_lines},{\"targets\":[\"${target_host}:${dcgm_port}\"],\"labels\":{\"box\":\"spark-${target_idx}\",\"exporter\":\"dcgm\"}}"
    done
  fi
  printf '[%s]\n' "${target_lines}"
  if ! truthy "${monitor_enabled}"; then
    note "SPARK_MONITOR_ENABLED is '${monitor_enabled}', so this is the empty target set: set it to true in .env (or the process environment) to emit the two groups per box"
  else
    note "print only -- nothing was written; on the stack host, redirect this into observability/spark-targets/sparks.json (see that directory's README) and Prometheus picks it up within a minute"
  fi
  summary
  exit 0
fi

# -- the run ------------------------------------------------------------------

work="$(mktemp -d 2>/dev/null || true)"
[ -n "${work}" ] || die "could not create a scratch directory for the probe scripts"
trap 'rm -f "${work}"/*' EXIT

case "${mode}" in
  plan)
    log "spark-monitor: plan for ${#hosts[@]} box(es) -- read-only: this run opens no ssh session and starts no container"
    next_step="bazelisk run //scripts:spark-monitor -- --status to see what each box runs, or --apply to create both exporters"
    ;;
  status)
    log "spark-monitor: status for ${#hosts[@]} box(es) -- read-only: the probe runs on each box over ssh and changes nothing"
    next_step="bazelisk run //scripts:spark-monitor -- --apply to create and start what is missing"
    ;;
  apply)
    log "spark-monitor: --apply for ${#hosts[@]} box(es) -- this is the only mode that mutates a Spark"
    phase "--apply: ${node_container} and ${dcgm_container} will be created or started on every box below"
    next_step="bazelisk run //scripts:spark-monitor -- --status to read back what is now running"
    ;;
  restart)
    log "spark-monitor: --restart for ${#hosts[@]} box(es) -- a mutator: both exporter containers are restarted, which drops the scrape gap until they answer again"
    phase "--restart: docker restart ${node_container} ${dcgm_container} on every box below"
    next_step="bazelisk run //scripts:spark-monitor -- --status to confirm both are serving again"
    ;;
esac

mutating=""
if [ "${mode}" = apply ] || [ "${mode}" = restart ]; then
  mutating=1
fi

case "${SPARK_HOSTS_SOURCE}" in
  env)
    note "fleet taken from SPARK_HOSTS in the process environment: ${SPARK_HOSTS_RESOLVED}"
    ;;
  derived)
    note "fleet taken from the SPARKn_HOST / SPARKn_OPENAI_URL keys in .env: ${SPARK_HOSTS_RESOLVED}"
    ;;
  *)
    warn "no SPARK_HOSTS, no exported SPARKn_HOST and no SPARKn_HOST key in .env: checking the placeholder trio ${SPARK_HOSTS_RESOLVED}, whose names do not resolve -- export SPARK1_HOST (and 2, 3) or set them in .env"
    ;;
esac

if ! truthy "${monitor_enabled}"; then
  warn "SPARK_MONITOR_ENABLED is '${monitor_enabled}': --apply starts nothing and --targets prints an empty set, so no Spark is a scrape target. Set it to true in .env when the boxes should be scraped. --status still probes."
fi

if [ ! -f "${probe_file}" ]; then
  warn "${probe_file} is not in this checkout, so --status has nothing to ferry and --apply/--restart cannot report back; the plan needs no probe"
fi

if [ ! -f "${counters_file}" ]; then
  warn "${counters_file} is not in this checkout, so --apply starts the DCGM exporter on the image's built-in counter list and the DCGM_FI_* series Prometheus sees are not the ones this repo reviews"
fi

if [ "${mode}" != plan ] && ! has_tool ssh; then
  warn "ssh is not on PATH, so no box can be probed or changed from here"
fi
if [ "${mode}" != plan ] && ! has_tool timeout; then
  note "timeout(1) is not available -- the ssh round trips below run uncapped, so a box that drops packets can stall this run until the operating system gives up"
fi

# The twelve keys scripts/lib/probes/spark-monitor.sh is contracted to print, one per
# line. Listed here so a probe that answers with a truncated or old body is reported as
# what it is instead of reading as "nothing is installed".
probe_keys="probe_version spark_host docker_available node_exporter_running node_exporter_port
node_exporter_image dcgm_running dcgm_port dcgm_image dcgm_counter_count gpu_count gpu_names"

for idx in "${!hosts[@]}"; do
  host="${hosts[${idx}]}"
  box="${boxes[${idx}]}"
  box_no=$((idx + 1))
  section "box ${box} (${host})"
  warn_before="${SUMMARY_WARN:-0}"
  fail_before="${SUMMARY_FAIL:-0}"

  # Every answer this box gives, defaulted to "never measured" before the mode runs, so
  # the one --json object written at the bottom of the loop always describes the same
  # measurement the human lines above it do.
  probed=false
  docker_state=unmeasured
  node_state=unmeasured
  node_seen_port=""
  node_seen_image=""
  dcgm_state=unmeasured
  dcgm_seen_port=""
  dcgm_seen_image=""
  dcgm_counters=""
  gpu_count=""
  gpu_names=""
  probe_version=""
  verdict=plan
  detail=""

  ssh_target="${ssh_user:+${ssh_user}@}${host}"

  if [ "${mode}" = plan ]; then
    # Nothing is measured here on purpose: an operator reads this before the boxes are
    # reachable from their keyboard, and a plan that hung on three ssh timeouts is not a
    # plan. What is missing is therefore stated as unmeasured, with the command that
    # would settle it and the exact container --apply would create.
    ok "${host}: scrape pair is ${host}:${node_port} (node_exporter ${node_exporter_image}) and ${host}:${dcgm_port} (DCGM ${dcgm_image})"
    if truthy "${monitor_enabled}"; then
      note "${host}: --apply would ferry over ssh as ${ssh_target}: docker run -d --name ${node_container} ${node_args}"
      note "${host}: --apply would ferry over ssh as ${ssh_target}: docker run -d --name ${dcgm_container} ${dcgm_args}"
      if [ -f "${counters_file}" ]; then
        note "${host}: --apply would also ferry ${counters_file} to ${counters_remote} and mount it read-only, so the DCGM field list is the one this repo reviews"
      else
        note "${host}: ${counters_file} is absent, so DCGM would start on the image's built-in counter list"
      fi
    else
      note "${host}: SPARK_MONITOR_ENABLED is '${monitor_enabled}', so --apply would start nothing on this box and --targets would publish no group for it"
    fi
    if [ ! -f "${probe_file}" ]; then
      note "${host}: --status could not run even with ssh, because ${probe_file} is absent"
    else
      warn "${host}: nothing has been measured -- a plan run opens no ssh session, so whether either exporter runs here is unknown until --status"
    fi
    verdict=plan
    detail="unmeasured: plan mode runs no ssh"
  else
    # One pass per box, and every bail-out below breaks out of this inner loop rather than
    # continuing the box loop: the --json object written at the bottom has to describe a
    # box that went unanswered or failed too, or the document would silently drop exactly
    # the boxes an operator needs to see.
    while :; do
      script_file="${work}/${host}.sh"
      report="${work}/${host}.report"
      err_file="${work}/${host}.err"

      if [ "${mode}" = status ]; then
        if [ ! -f "${probe_file}" ]; then
          warn "${host}: ${probe_file} is absent, so this box could not be probed"
          verdict=skip
          detail="no probe payload in this checkout"
          break
        fi
        cap="${probe_cap}"
        terminator="spark_host="
        # The one prepended assignment the probe accepts: it uses it only for a local
        # `docker image ls -q` lookup of the tag this run would install, and never pulls.
        {
          printf '%s\n' "SPARK_DCGM_EXPORTER_IMAGE=\"${dcgm_image}\""
          probe_script
        } >"${script_file}"
      else
        cap="${apply_cap}"
        {
          printf '%s\n' \
            "NODE_NAME=\"${node_container}\"" "NODE_ARGS=\"${node_args}\"" \
            "DCGM_NAME=\"${dcgm_container}\"" "DCGM_ARGS=\"${dcgm_args}\"" \
            "COUNTERS_REMOTE=\"${counters_remote}\"" \
            "COUNTERS_B64=\"$(base64 <"${counters_file}" 2>/dev/null | tr -d '\n')\""
          if [ "${mode}" = apply ]; then
            terminator="apply_end"
            cat <<'MONITOR_APPLY'
    # Runs under sh on the box: create or start one exporter container, idempotently by
    # name, and answer one KEY=value line per decision. Exit 0 always: this script reports
    # and the CLI decides what is a warning and what is a failure.
    if ! command -v docker >/dev/null 2>&1; then
      printf 'docker_available=absent\napply.node_exporter=skipped\napply.dcgm=skipped\nreason.docker=docker is not on PATH on this box\napply_end\n'
      exit 0
    fi
    printf 'docker_available=present\n'
    # The counter list travels with the run rather than living on the box: written to a
    # sibling file and moved only when it differs, so an exporter that is already running
    # never reads a half-written file, and --restart is what makes it reread a new one.
    if [ -n "${COUNTERS_B64}" ]; then
      mkdir -p "${COUNTERS_REMOTE%/*}" 2>/dev/null
      printf '%s' "${COUNTERS_B64}" | base64 -d >"${COUNTERS_REMOTE}.new" 2>/dev/null
      if [ -f "${COUNTERS_REMOTE}" ] && cmp -s "${COUNTERS_REMOTE}.new" "${COUNTERS_REMOTE}"; then
        rm -f "${COUNTERS_REMOTE}.new"
        printf 'counters=same\n'
      elif mv -f "${COUNTERS_REMOTE}.new" "${COUNTERS_REMOTE}" 2>/dev/null; then
        printf 'counters=updated\n'
      else
        rm -f "${COUNTERS_REMOTE}.new"
        printf 'counters=failed\nreason.counters=could not write %s\n' "${COUNTERS_REMOTE}"
      fi
    else
      printf 'counters=absent\n'
    fi
    ensure_exporter() {
      key="$1" name="$2" args="$3"
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        printf 'apply.%s=running\n' "${key}"
        return 0
      fi
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        out="$(docker start "${name}" 2>&1)" && printf 'apply.%s=started\n' "${key}" && return 0
      else
        out="$(docker run -d --name "${name}" ${args} 2>&1)" && printf 'apply.%s=created\n' "${key}" && return 0
      fi
      printf 'apply.%s=failed\nreason.%s=%s\n' "${key}" "${key}" \
        "$(printf '%s' "${out}" | tr '\n' ' ' | tr -d '\r')"
    }
    ensure_exporter node_exporter "${NODE_NAME}" "${NODE_ARGS}"
    ensure_exporter dcgm "${DCGM_NAME}" "${DCGM_ARGS}"
    printf 'apply_end\n'
MONITOR_APPLY
          else
            terminator="restart_end"
            cat <<'MONITOR_RESTART'
    # Runs under sh on the box: restart both exporters by name. A container that is not
    # there is reported as absent, never as an error: --apply installs, --restart only
    # restarts, and a box that was never provisioned is the operator's next step, not a
    # failed run of this one.
    if ! command -v docker >/dev/null 2>&1; then
      printf 'docker_available=absent\nrestart.node_exporter=skipped\nrestart.dcgm=skipped\nreason.docker=docker is not on PATH on this box\nrestart_end\n'
      exit 0
    fi
    printf 'docker_available=present\n'
    for pair in "node_exporter ${NODE_NAME}" "dcgm ${DCGM_NAME}"; do
      key="${pair%% *}"
      name="${pair#* }"
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        out="$(docker restart "${name}" 2>&1)" && printf 'restart.%s=restarted\n' "${key}" && continue
        printf 'restart.%s=failed\nreason.%s=%s\n' "${key}" "${key}" \
          "$(printf '%s' "${out}" | tr '\n' ' ' | tr -d '\r')"
      else
        printf 'restart.%s=absent\n' "${key}"
      fi
    done
    printf 'restart_end\n'
MONITOR_RESTART
          fi
        } >"${script_file}"
      fi

      if ! truthy "${monitor_enabled}" && [ "${mode}" != status ]; then
        note "${host}: SPARK_MONITOR_ENABLED is '${monitor_enabled}', so ${mode_given} skips this box rather than installing a container nothing scrapes"
        verdict=skipped
        detail="SPARK_MONITOR_ENABLED=${monitor_enabled}"
        break
      fi

      # One flat script, base64'd into one quoted ssh argument, ferried by the shared
      # transport: same plumbing spark-configure.sh and spark-verify.sh use, so a box that
      # answers for those answers for this one too.
      phase "probing ${ssh_target} over ssh"
      payload="$(base64 <"${script_file}" | tr -d '\n')"
      ssh_rc=0
      ssh_out="$(probe_transport "${cap}" "${ssh_port}" "${ssh_target}" "${payload}" 2>"${err_file}")" ||
        ssh_rc=$?

      if [ "${ssh_rc}" = "124" ] || [ "${ssh_rc}" = "143" ]; then
        warn "${host}: ssh was cut off after ${cap}s (timeout(1) guard) -- nothing below describes this box"
        verdict=unreachable
        detail="ssh cut off after ${cap}s"
        break
      fi
      if [ "${ssh_rc}" != "0" ]; then
        ssh_err="$(cat "${err_file}" 2>/dev/null || true)"
        reason="$(first_line "${ssh_err}")"
        [ -n "${reason}" ] || reason="ssh exited ${ssh_rc} and printed nothing"
        if [ -n "${mutating}" ]; then
          fail_item "${host}: ${mode_given} could not run over ssh (${reason}) -- check SPARK_SSH_USER/--port; the box keeps whatever it ran before, which is the drift this CLI is for"
          verdict=fail
          detail="${reason}"
        else
          warn "${host}: no probe report (${reason}) -- a box that is switched off or has no ssh credentials is a not-yet state, not a failure"
          verdict=unreachable
          detail="${reason}"
        fi
        break
      fi
      if ! printf '%s\n' "${ssh_out}" | grep -qF "${terminator}"; then
        reason="$(first_line "${ssh_out}")"
        [ -n "${reason}" ] || reason="ssh answered but printed no report"
        if [ -n "${mutating}" ]; then
          fail_item "${host}: ${mode_given} answered without a report (${reason}), so this run cannot say what the box runs now"
        else
          warn "${host}: ssh answered without a probe report (${reason})"
        fi
        verdict=fail
        detail="${reason}"
        break
      fi
      printf '%s\n' "${ssh_out}" >"${report}"
      probed=true

      missing_keys=""
      for key in ${probe_keys}; do
        printf '%s\n' "${ssh_out}" | grep -q "^${key}=" ||
          missing_keys="${missing_keys}${missing_keys:+,}${key}"
      done

      docker_state="$(fact_get "${report}" docker_available absent)"
      probe_version="$(fact_get "${report}" probe_version unknown)"

      if [ "${mode}" = status ]; then
        if [ -n "${missing_keys}" ]; then
          warn "${host}: probe ${probe_version} answered but is missing ${missing_keys} -- the probe on this box is older than this CLI, which prints all twelve keys exactly once"
        elif [ -s "${err_file}" ]; then
          # The probe's contract is 0 bytes on stderr and exit 0 on every path, so anything
          # here is either an ssh banner or a probe bug. Printed rather than swallowed.
          warn "${host}: the probe wrote to stderr, which its contract forbids: $(first_line "$(cat "${err_file}" 2>/dev/null || true)")"
        fi
        if [ "${docker_state}" = absent ]; then
          warn "${host}: docker is not on PATH, so no exporter can run on this box"
        else
          ok "${host}: probe version ${probe_version}, docker available, ${#hosts[@]} box(es) in this run's fleet"
        fi

        # Every missing thing on the box comes back as the literal sentinel `absent`, never
        # as an empty value, so the three states are absent (not installed), a running
        # answer, and anything else (a container that exists and is not serving).
        node_state="$(fact_get "${report}" node_exporter_running absent)"
        node_seen_port="$(fact_get "${report}" node_exporter_port "${node_port}")"
        node_seen_image="$(fact_get "${report}" node_exporter_image absent)"
        if [ "${node_state}" = absent ]; then
          warn "${host}: node_exporter is absent -- Prometheus scrapes ${host}:${node_port} and gets nothing; bazelisk run //scripts:spark-monitor -- --apply --box ${box_no} creates it"
        elif truthy "${node_state}" || [ "${node_state}" = running ] || [ "${node_state}" = present ]; then
          ok "${host}: node_exporter is running on :${node_seen_port} (${node_seen_image})"
        else
          warn "${host}: node_exporter is '${node_state}', not running -- Prometheus scrapes ${host}:${node_port} and gets nothing"
        fi

        dcgm_state="$(fact_get "${report}" dcgm_running absent)"
        dcgm_seen_port="$(fact_get "${report}" dcgm_port "${dcgm_port}")"
        dcgm_seen_image="$(fact_get "${report}" dcgm_image absent)"
        # `absent` as the default, not 0: a probe that never measured counters and a probe
        # that measured zero of them are different answers, and 0 GPUs with gpu_names
        # absent is a real answer about the box, not a parse failure.
        dcgm_counters="$(fact_get "${report}" dcgm_counter_count absent)"
        gpu_count="$(fact_get "${report}" gpu_count absent)"
        gpu_names="$(fact_get "${report}" gpu_names absent)"
        if [ "${dcgm_state}" = absent ]; then
          warn "${host}: DCGM exporter is absent -- the GPU panels stay empty for this box; bazelisk run //scripts:spark-monitor -- --apply --box ${box_no} creates it"
        elif truthy "${dcgm_state}" || [ "${dcgm_state}" = running ] || [ "${dcgm_state}" = present ]; then
          ok "${host}: DCGM exporter is running on :${dcgm_seen_port}, tag ${dcgm_seen_image}"
          note "${host}: DCGM counters ${dcgm_counters}, GPUs ${gpu_count} (${gpu_names})"
          if [ "${dcgm_seen_image}" != "${dcgm_image}" ]; then
            note "${host}: the running tag is not the pin this CLI would install (${dcgm_image}) -- a box left on another tag is the drift --status exists to show"
          fi
        else
          warn "${host}: DCGM exporter is '${dcgm_state}', not running -- the GPU panels stay empty for this box"
        fi

        case "${gpu_count}" in
          0)
            warn "${host}: the probe measured 0 GPUs, so DCGM has nothing to export even with its container up (absent would mean unmeasured)"
            ;;
          '' | absent)
            warn "${host}: the probe reported no GPU count for ${host}, so this run cannot say whether DCGM has devices to export"
            ;;
        esac

        verdict=ok
        detail="docker=${docker_state} node_exporter=${node_state} dcgm=${dcgm_state} gpus=${gpu_count}"
      elif [ "${mode}" = apply ]; then
        node_state="$(fact_get "${report}" apply.node_exporter skipped)"
        dcgm_state="$(fact_get "${report}" apply.dcgm skipped)"
        if [ "${docker_state}" = absent ]; then
          fail_item "${host}: docker is not on PATH, so neither exporter can run on this box -- install docker or point the fleet elsewhere"
          verdict=fail
          detail="docker absent on ${host}"
          break
        fi
        case "${node_state}" in
          created) ok "${host}: created ${node_container} on :${node_port} (${node_exporter_image})" ;;
          started) ok "${host}: started the existing ${node_container} on :${node_port}" ;;
          running) ok "${host}: ${node_container} was already running on :${node_port}" ;;
          *)
            fail_item "${host}: ${node_container} is not running (${node_state}): $(fact_get "${report}" reason.node_exporter 'docker run gave no reason')"
            ;;
        esac
        case "${dcgm_state}" in
          created) ok "${host}: created ${dcgm_container} on :${dcgm_port} (${dcgm_image})" ;;
          started) ok "${host}: started the existing ${dcgm_container} on :${dcgm_port}" ;;
          running) ok "${host}: ${dcgm_container} was already running on :${dcgm_port}" ;;
          *)
            # The unverified DCGM pin shows up here: whatever nvcr.io answered is printed
            # rather than swallowed, because "it did not come up" is not actionable.
            fail_item "${host}: ${dcgm_container} is not running (${dcgm_state}): $(fact_get "${report}" reason.dcgm 'docker run gave no reason')"
            ;;
        esac
        # The counter list is reported apart from the containers: a box can be up on a
        # stale list, and that is one --restart away rather than a reinstall.
        report_counters="$(fact_get "${report}" counters absent)"
        case "${report_counters}" in
          same | updated)
            ok "${host}: ${counters_file} is in place at ${counters_remote} (${report_counters})"
            if [ "${report_counters}" = updated ] && [ "${node_state}" = running ] &&
              [ "${dcgm_state}" = running ]; then
              note "${host}: the counter list changed under a running exporter -- bazelisk run //scripts:spark-monitor -- --restart --box ${box_no} makes DCGM reread it"
            fi
            ;;
          absent)
            note "${host}: no counter list was ferried, so the exporter stays on the image's own field list (${counters_file} is absent from this checkout)"
            ;;
          *)
            fail_item "${host}: ${counters_remote} could not be written: $(fact_get "${report}" reason.counters 'no reason given')"
            ;;
        esac
        verdict=ok
        detail="node_exporter=${node_state} dcgm=${dcgm_state} counters=${report_counters}"
      else
        node_state="$(fact_get "${report}" restart.node_exporter skipped)"
        dcgm_state="$(fact_get "${report}" restart.dcgm skipped)"
        if [ "${docker_state}" = absent ]; then
          fail_item "${host}: docker is not on PATH, so no container could be restarted"
          verdict=fail
          detail="docker absent on ${host}"
          break
        fi
        for pair in "node_exporter:${node_state}:${node_container}:${node_port}" \
          "dcgm:${dcgm_state}:${dcgm_container}:${dcgm_port}"; do
          key="${pair%%:*}"
          state="$(printf '%s' "${pair}" | cut -d: -f2)"
          name="$(printf '%s' "${pair}" | cut -d: -f3)"
          port="$(printf '%s' "${pair}" | cut -d: -f4)"
          case "${state}" in
            restarted) ok "${host}: restarted ${name} on :${port}" ;;
            absent) warn "${host}: no ${name} container to restart -- bazelisk run //scripts:spark-monitor -- --apply installs it" ;;
            *)
              fail_item "${host}: ${name} could not be restarted (${state}): $(fact_get "${report}" "reason.${key}" 'docker restart gave no reason')"
              ;;
          esac
        done
        verdict=ok
        detail="node_exporter=${node_state} dcgm=${dcgm_state}"
      fi
      break
    done
  fi

  # The verdict is taken from what this box actually added to the counters, so the JSON
  # cannot call a box ok while three warning lines about it are on screen above.
  if [ "${SUMMARY_FAIL:-0}" != "${fail_before}" ]; then
    verdict=fail
  elif [ "${SUMMARY_WARN:-0}" != "${warn_before}" ] && [ "${verdict}" = ok ]; then
    verdict=warn
  fi

  printf '{"host":"%s","box":"%s","mode":"%s","probed":%s,"docker":"%s","node_exporter":"%s","node_exporter_port":"%s","node_exporter_image":"%s","dcgm":"%s","dcgm_port":"%s","dcgm_image":"%s","dcgm_counter_count":"%s","gpu_count":%s,"gpu_names":"%s","probe_version":"%s","verdict":"%s","detail":"%s"}\n' \
    "${host}" "${box}" "${mode}" "${probed}" "$(json_escape "${docker_state}")" \
    "$(json_escape "${node_state}")" "$(json_escape "${node_seen_port}")" \
    "$(json_escape "${node_seen_image}")" "$(json_escape "${dcgm_state}")" \
    "$(json_escape "${dcgm_seen_port}")" "$(json_escape "${dcgm_seen_image}")" \
    "$(json_escape "${dcgm_counters}")" "$(json_value "${gpu_count}")" \
    "$(json_escape "${gpu_names}")" "$(json_escape "${probe_version}")" \
    "${verdict}" "$(json_escape "${detail}")" >"${work}/${host}.jsonl"
done

if [ -n "${JSON_MODE:-}" ]; then
  # stdout is exactly one JSON object: log/warn/note/summary all route to stderr while
  # JSON_MODE is set, so a pipe into jq sees the document and nothing else.
  box_json=""
  for host in ${hosts[@]+"${hosts[@]}"}; do
    [ -s "${work}/${host}.jsonl" ] || continue
    box_json="${box_json}${box_json:+,}$(cat "${work}/${host}.jsonl")"
  done
  printf '{"mode":"%s","host_source":"%s","monitor_enabled":%s,"node_exporter_image":"%s","node_exporter_port":%s,"dcgm_exporter_image":"%s","dcgm_exporter_port":%s,"ssh_port":%s,"boxes":[%s],"summary":{"ok":%s,"warnings":%s,"failed":%s}}\n' \
    "${mode}" "${SPARK_HOSTS_SOURCE}" "$(truthy "${monitor_enabled}" && printf true || printf false)" \
    "$(json_escape "${node_exporter_image}")" "${node_port}" \
    "$(json_escape "${dcgm_image}")" "${dcgm_port}" "${ssh_port}" \
    "${box_json}" "${SUMMARY_OK:-0}" "${SUMMARY_WARN:-0}" "${SUMMARY_FAIL:-0}"
fi

summary "${next_step:-}"

if [ -n "${mutating}" ] && [ "${SUMMARY_FAIL:-0}" != "0" ]; then
  exit 1
fi
exit 0
