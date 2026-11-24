#!/bin/sh
# shellcheck shell=sh
#
# ## probes/host_gpu.sh - Sample the stack host's Intel Arc card from sysfs and write one node_exporter textfile-collector .prom file (POSIX sh; run ON the host, never ferried over ssh)
#
# Why this file exists: the evo-t1 stack host is the Intel Arc box, and it runs
# no DCGM exporter, so it exports none of the DCGM_FI_* series the Spark cards
# carry (observability/prometheus/prometheus.yml scrapes those off the Sparks).
# The host card therefore has to be measured with what this platform actually
# has: the i915/xe drm sysfs knobs, the RAPL package energy counters, the drm
# hwmon temperatures, and intel_gpu_top when the operator installed it. No new
# dependency is required for any of it - the first three are plain files.
#
# Four gauge series, one each, no labels, in this order. The names are pinned:
# the homepage host-GPU card and the Grafana host row query them by name, so a
# rename here is a rename there.
#   evo_t1_host_gpu_clock_mhz        MHz    /sys/class/drm/card*/gt_cur_freq_mhz,
#                                           else intel_gpu_top "freq"."actual"
#   evo_t1_host_gpu_utilisation_pct  percent intel_gpu_top engine "busy" when the
#                                           binary exists, else the
#                                           gt_cur_freq_mhz / gt_max_freq_mhz ratio
#   evo_t1_host_gpu_power_watts      watts  joule delta of the package-level
#                                           /sys/class/powercap/intel-rapl:N
#                                           counters over the uptime delta since
#                                           the last run, else intel_gpu_top
#                                           "power".  The Arc iGPU has no rail of
#                                           its own, so this is whole-package
#                                           power attributed to the card because
#                                           it is the only rail the box exposes.
#   evo_t1_host_gpu_temp_celsius     C      max temp*_input under
#                                           /sys/class/drm/card*/hwmon/hwmon*, or
#                                           under /sys/class/hwmon/hwmon* whose
#                                           name file reads i915 or xe
# A max is taken across cards and sensors because the box has one Arc and a
# dashboard that has to average or sum a one-element set reads better as one
# series than as a set.
#
# The output is one file in the node_exporter textfile directory (compose mounts
# that directory into the exporter; scripts/lib/probes/host_gpu.sh does not start
# it). It is built as a dot-prefixed sibling and mv'd into place, because the
# textfile collector parses whatever it finds at scrape time and a half-written
# file is a scrape error rather than a stale gauge.
#
# Missing sources are a result, never a failure: every absent file, absent
# directory and absent binary leaves its metric out of the file and prints one
# warning: line naming what could not be read. The only thing that exits non-zero
# here is a textfile directory that cannot be written, because then the sampler
# can never be scraped and an operator has to hear about it.
#
# Seams a test or an operator sets (all optional, all default to the host's real
# paths, so an unmodified run samples the machine):
#   HOST_GPU_SYSFS_ROOT     default /sys
#   HOST_GPU_TEXTFILE_DIR   default /var/lib/node_exporter/textfile_collector
#   HOST_GPU_OUT_FILE       default host_gpu.prom
#   HOST_GPU_STATE_DIR      default /var/tmp/evo-t1-host-gpu (power baseline)
#   HOST_GPU_UPTIME_FILE    default /proc/uptime (the power window's clock)
#   HOST_GPU_INTEL_GPU_TOP  path to intel_gpu_top; else looked up on PATH
#   HOST_GPU_TOP_SAMPLE_MS  intel_gpu_top sample window, default 500
#   HOST_GPU_TOP_CAP        wall-clock cap seconds for that run, default 5
#
# Usage: sh scripts/lib/probes/host_gpu.sh   (from any cwd; needs write access
# to HOST_GPU_TEXTFILE_DIR and HOST_GPU_STATE_DIR)

SYSFS_ROOT="${HOST_GPU_SYSFS_ROOT:-/sys}"
TEXTFILE_DIR="${HOST_GPU_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT_FILE="${HOST_GPU_OUT_FILE:-host_gpu.prom}"
STATE_DIR="${HOST_GPU_STATE_DIR:-/var/tmp/evo-t1-host-gpu}"
UPTIME_FILE="${HOST_GPU_UPTIME_FILE:-/proc/uptime}"
TOP_SAMPLE_MS="${HOST_GPU_TOP_SAMPLE_MS:-500}"
TOP_CAP="${HOST_GPU_TOP_CAP:-5}"

METRIC_CLOCK="evo_t1_host_gpu_clock_mhz"
METRIC_UTIL="evo_t1_host_gpu_utilisation_pct"
METRIC_POWER="evo_t1_host_gpu_power_watts"
METRIC_TEMP="evo_t1_host_gpu_temp_celsius"

# A double quote, held in a variable so the JSON sniff below can use it in a case
# pattern without mixing quote styles the parser cannot follow.
JSON_QUOTE='"'

PROM_FILE="${TEXTFILE_DIR}/${OUT_FILE}"
BUILD_FILE="${TEXTFILE_DIR}/.${OUT_FILE}.building"
STATE_FILE="${STATE_DIR}/power.state"

# GPU_TOP_JSON is read at most once per run, so the two metrics that can fall
# back to it do not fork the binary twice.
GPU_TOP_JSON=""
GPU_TOP_JSON_READY=0
METRIC_COUNT=0

# @function note
# Print one narration line in the operator CLI's vocabulary, so a timer's log and
# a CLI run read the same.
# Globals:
#   None
# Arguments:
#   $1 - level word (ok, note, warning, error); $2 - text
# Outputs:
#   "level: text" on stdout
# Returns:
#   0
note() {
  printf '%s: %s\n' "${1:-note}" "${2:-}"
}

# @function read_sysfs_value
# The first line of one sysfs file with all whitespace out, or nothing when the
# file is absent, unreadable, or empty. Never an error: a knob this kernel does
# not have is one fewer metric, not a failed run.
# Globals:
#   None
# Arguments:
#   $1 - file to read
# Outputs:
#   The value, or nothing
# Returns:
#   0
read_sysfs_value() {
  [ -r "${1:-}" ] || return 0
  head -n 1 "${1}" 2>/dev/null | tr -d ' \t\r\n'
}

# @function is_unsigned
# 0 when the argument is a run of digits, which is the shape every sysfs counter
# here has. Non-digit text (a "none" or a kernel error string) is rejected at the
# source rather than reaching awk as 0 and reporting a real zero measurement.
# Globals:
#   None
# Arguments:
#   $1 - candidate text
# Outputs:
#   None
# Returns:
#   0 when it is all digits, 1 otherwise
is_unsigned() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# @function max_of_lines
# Max of the numbers on stdin, one per line, formatted to <digits> decimals.
# Prints nothing when stdin held no number, which the caller reads as "no
# measurement" and turns into a gap note.
# Globals:
#   None
# Arguments:
#   $1 - decimals to print with
# Outputs:
#   One number, or nothing
# Returns:
#   0
max_of_lines() {
  awk -v digits="${1:-2}" '
    NF > 0 {
      value = $1 + 0
      if (!have || value > max) {
        max = value
        have = 1
      }
    }
    END {
      if (have) {
        fmt = "%." digits "f"
        printf fmt, max
      }
    }'
}

# @function emit_card_hwmon_temps
# Print every temperature sensor under one hwmon directory in millidegrees, one
# per line. A directory with no readable sensor prints nothing.
# Globals:
#   None
# Arguments:
#   $1 - hwmon directory
# Outputs:
#   Millidegree values, one per line
# Returns:
#   0
emit_card_hwmon_temps() {
  hwmon_dir="${1:-}"
  [ -d "${hwmon_dir}" ] || return 0
  for temp_file in "${hwmon_dir}"/temp*_input; do
    [ -r "${temp_file}" ] || continue
    raw="$(read_sysfs_value "${temp_file}")"
    is_unsigned "${raw}" || continue
    printf '%s\n' "${raw}"
  done
}

# @function sample_temp_celsius
# Hottest GPU sensor on the box. The drm card paths are the i915/xe hwmon and are
# always read; the flat /sys/class/hwmon tree is read only for a sensor that names
# itself i915 or xe, because that tree also holds coretemp, acpitz and every NVMe
# drive, and the max of those would report the CPU package as the GPU.
# Globals:
#   SYSFS_ROOT
# Arguments:
#   None
# Outputs:
#   Degrees Celsius with two decimals, or nothing
# Returns:
#   0
sample_temp_celsius() {
  {
    for card_dir in "${SYSFS_ROOT}"/class/drm/card*; do
      [ -d "${card_dir}" ] || continue
      for hwmon_dir in "${card_dir}"/hwmon/hwmon*; do
        emit_card_hwmon_temps "${hwmon_dir}"
      done
    done
    for hwmon_dir in "${SYSFS_ROOT}"/class/hwmon/hwmon*; do
      [ -d "${hwmon_dir}" ] || continue
      hwmon_name="$(read_sysfs_value "${hwmon_dir}/name")"
      case "${hwmon_name}" in
        i915 | xe) emit_card_hwmon_temps "${hwmon_dir}" ;;
        *) continue ;;
      esac
    done
  } | awk '
    NF > 0 {
      value = $1 / 1000
      if (!have || value > max) {
        max = value
        have = 1
      }
    }
    END {
      if (have) printf "%.2f", max
    }'
}

# @function sample_clock_mhz
# Current GPU clock, the highest any card reports.
# Globals:
#   SYSFS_ROOT
# Arguments:
#   None
# Outputs:
#   MHz, or nothing when no card exposes the knob
# Returns:
#   0
sample_clock_mhz() {
  for card_dir in "${SYSFS_ROOT}"/class/drm/card*; do
    [ -d "${card_dir}" ] || continue
    cur="$(read_sysfs_value "${card_dir}/gt_cur_freq_mhz")"
    is_unsigned "${cur}" || continue
    printf '%s\n' "${cur}"
  done | max_of_lines 0
}

# @function sample_freq_ratio_pct
# Utilisation proxy for a box without intel_gpu_top: how close the card is running
# to its own ceiling. It is a frequency ratio, not engine busyness, so it reads 100
# for an idle card pinned at max - the reason intel_gpu_top is preferred and the
# reason the HELP text says which of the two produced the number.
# Globals:
#   SYSFS_ROOT
# Arguments:
#   None
# Outputs:
#   Percent with two decimals, or nothing
# Returns:
#   0
sample_freq_ratio_pct() {
  for card_dir in "${SYSFS_ROOT}"/class/drm/card*; do
    [ -d "${card_dir}" ] || continue
    cur="$(read_sysfs_value "${card_dir}/gt_cur_freq_mhz")"
    ceiling="$(read_sysfs_value "${card_dir}/gt_max_freq_mhz")"
    is_unsigned "${cur}" || continue
    is_unsigned "${ceiling}" || continue
    [ "${ceiling}" -gt 0 ] || continue
    awk -v now="${cur}" -v top="${ceiling}" 'BEGIN {
      pct = now * 100 / top
      if (pct > 100) pct = 100
      printf "%.2f\n", pct
    }'
  done | max_of_lines 2
}

# @function sum_rapl_field
# Sum one counter across the package-level RAPL domains. A second colon in the
# directory name (intel-rapl:0:0) marks a domain inside a package, so summing it
# with its own package charges the same joules twice; those paths are skipped.
# Globals:
#   SYSFS_ROOT
# Arguments:
#   $1 - counter file to sum (energy_uj, max_energy_uj)
# Outputs:
#   The summed integer, or nothing when no package exposes it
# Returns:
#   0
sum_rapl_field() {
  wanted="${1:-}"
  [ -n "${wanted}" ] || return 0
  for rapl_dir in "${SYSFS_ROOT}"/class/powercap/intel-rapl:*; do
    [ -d "${rapl_dir}" ] || continue
    rapl_base="${rapl_dir##*/}"
    case "${rapl_base}" in
      intel-rapl:*:*) continue ;;
    esac
    counter="$(read_sysfs_value "${rapl_dir}/${wanted}")"
    is_unsigned "${counter}" || continue
    printf '%s\n' "${counter}"
  done | awk '
    NF > 0 {
      total += $1
      have = 1
    }
    END {
      if (have) printf "%.0f", total
    }'
}

# @function compute_power_watts
# Watts since the previous run: the package energy delta divided by the uptime
# delta. Energy is a counter, so it needs the baseline kept in STATE_FILE; with no
# baseline the first run prints nothing and only records where it started, which
# keeps "never measured" out of the file instead of reporting a false 0 W. A
# negative delta is a counter rollover and is unwrapped with max_energy_uj when
# that counter exists; without it the sample is dropped rather than reported
# negative.
# Globals:
#   UPTIME_FILE, STATE_FILE, STATE_DIR
# Arguments:
#   $1 - current summed package energy in microjoules
# Outputs:
#   Watts with two decimals, or nothing; the new baseline on disk
# Returns:
#   0
compute_power_watts() {
  energy_now="${1:-}"
  is_unsigned "${energy_now}" || return 0
  uptime_now="$(read_sysfs_value "${UPTIME_FILE}")"
  [ -n "${uptime_now}" ] || return 0
  baseline_uptime=""
  baseline_energy=""
  if [ -r "${STATE_FILE}" ]; then
    baseline_uptime="$(read_sysfs_value "${STATE_FILE}")"
    baseline_energy="$(sed -n '2p' "${STATE_FILE}" 2>/dev/null | tr -d ' \t\r\n')"
  fi
  watts=""
  if [ -n "${baseline_uptime}" ] && is_unsigned "${baseline_energy}"; then
    watts="$(awk -v e0="${baseline_energy}" -v e1="${energy_now}" \
      -v t0="${baseline_uptime}" -v t1="${uptime_now}" \
      -v emax="$(sum_rapl_field max_energy_uj)" '
      BEGIN {
        if (t1 + 0 <= t0 + 0) exit
        delta = e1 - e0
        if (delta < 0) {
          if (emax + 0 <= 0) exit
          delta += emax
        }
        printf "%.2f", (delta / 1000000) / (t1 - t0)
      }')"
  fi
  if mkdir -p "${STATE_DIR}" 2>/dev/null; then
    {
      printf '%s\n%s\n' "${uptime_now}" "${energy_now}" >"${STATE_FILE}.tmp" &&
        mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
    } 2>/dev/null ||
      note warning "no baseline for the next run: ${STATE_FILE} is not writable"
  else
    note warning "no baseline for the next run: ${STATE_DIR} is not writable"
  fi
  printf '%s' "${watts}"
}

# @function looks_like_json
# 0 when the text carries a quoted key followed by a colon, which is the shape any
# intel_gpu_top JSON sample has and an empty run, a usage banner, or an error line
# does not. The retry below needs that distinction and cannot open a brace without
# tripping the brace-counting function extractor the tests slice bodies with.
# Globals:
#   None
# Arguments:
#   $1 - candidate text
# Outputs:
#   None
# Returns:
#   0 when it looks like JSON, 1 otherwise
looks_like_json() {
  case "${1:-}" in
    *"${JSON_QUOTE}"*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# @function run_gpu_top
# One JSON sample from intel_gpu_top. The binary is optional by design: a host
# that never installed perf tooling has no business failing its metrics over it.
# -o - is the modern spelling and /dev/stdout the older one, so both are tried.
# Under a wall-clock cap when timeout exists, because a hung perf session must not
# outlive the scrape that asked for it.
# Globals:
#   HOST_GPU_INTEL_GPU_TOP, TOP_SAMPLE_MS, TOP_CAP
# Arguments:
#   None
# Outputs:
#   The JSON body on one line, or nothing
# Returns:
#   0
run_gpu_top() {
  top_bin="${HOST_GPU_INTEL_GPU_TOP:-}"
  if [ -z "${top_bin}" ] && command -v intel_gpu_top >/dev/null 2>&1; then
    top_bin="$(command -v intel_gpu_top)"
  fi
  [ -n "${top_bin}" ] || return 0
  [ -x "${top_bin}" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    json="$(timeout "${TOP_CAP}" "${top_bin}" -J -s "${TOP_SAMPLE_MS}" -c 1 -o - 2>/dev/null || true)"
  else
    json="$("${top_bin}" -J -s "${TOP_SAMPLE_MS}" -c 1 -o - 2>/dev/null || true)"
  fi
  if ! looks_like_json "${json}"; then
    json="$("${top_bin}" -J -s "${TOP_SAMPLE_MS}" -c 1 -o /dev/stdout 2>/dev/null || true)"
  fi
  if looks_like_json "${json}"; then
    printf '%s' "${json}" | tr -d '\n'
  fi
}

# @function gpu_top_json
# The one intel_gpu_top sample this run takes, cached so the clock and the
# utilisation fallbacks share it.
# Globals:
#   GPU_TOP_JSON, GPU_TOP_JSON_READY
# Arguments:
#   None
# Outputs:
#   The JSON body, or nothing when the binary is absent or silent
# Returns:
#   0
gpu_top_json() {
  if [ "${GPU_TOP_JSON_READY}" -eq 0 ]; then
    GPU_TOP_JSON_READY=1
    GPU_TOP_JSON="$(run_gpu_top)"
  fi
  printf '%s' "${GPU_TOP_JSON}"
}

# @function gpu_top_field
# First number held under a JSON key, found by text scan so the probe needs no
# JSON parser on the host. The key is quoted and colon-terminated before the
# search, so "actual" cannot match inside "throttle_reason".
# Globals:
#   None
# Arguments:
#   $1 - JSON body; $2 - key
# Outputs:
#   The number as written, or nothing
# Returns:
#   0
gpu_top_field() {
  printf '%s' "${1:-}" | tr -d '\n' | awk -v needle="\"${2:-}\":" '
    {
      at = index($0, needle)
      if (at == 0) exit
      tail = substr($0, at + length(needle))
      if (match(tail, /^[ \t]*-?[0-9]+(\.[0-9]+)?/)) {
        printf "%s", substr(tail, RSTART, RLENGTH)
      }
    }'
}

# @function gpu_top_busy_max
# Busiest engine, as a percentage. 2.x reports one object per engine holding
# "busy"; 1.x reports flat "render"/"blitter"/"video" numbers, so both spellings
# are read. A value over 100 is clamped: intel_gpu_top has been known to round a
# saturated engine above its own ceiling, and a gauge that exceeds 100 breaks every
# dashboard axis set to that range.
# Globals:
#   None
# Arguments:
#   $1 - JSON body
# Outputs:
#   Percent with two decimals, or nothing
# Returns:
#   0
gpu_top_busy_max() {
  printf '%s' "${1:-}" | tr -d '\n' | awk '
    {
      text = $0
      while (match(text, /"(busy|render|blitter|video|video-enhance|Video|Compute|VG|Enhance)"[ \t]*:[ \t]*[0-9]+(\.[0-9]+)?/)) {
        piece = substr(text, RSTART, RLENGTH)
        sub(/^.*:[ \t]*/, "", piece)
        value = piece + 0
        if (value > 100) value = 100
        if (!have || value > max) {
          max = value
          have = 1
        }
        text = substr(text, RSTART + RLENGTH)
      }
      if (have) printf "%.2f", max
    }'
}

# @function gpu_top_power_watts
# Power from intel_gpu_top when the box has no RAPL counters at all: the card rail
# first, then the GT rail, then the package. A host with RAPL never gets here.
# Globals:
#   None
# Arguments:
#   $1 - JSON body
# Outputs:
#   Watts with two decimals, or nothing
# Returns:
#   0
gpu_top_power_watts() {
  body="${1:-}"
  [ -n "${body}" ] || return 0
  for rail in card gt pkg; do
    rail_watts="$(gpu_top_field "${body}" "${rail}")"
    case "${rail_watts}" in
      '' | *[!0-9.-]*) continue ;;
    esac
    awk -v w="${rail_watts}" 'BEGIN { printf "%.2f", w }'
    return 0
  done
}

# @function emit_metric
# Append one gauge to the file being built, or record the gap. An unmeasured metric
# is left out of the .prom entirely rather than written as 0, because 0 is a real
# reading for a clock, a utilisation, a wattage and a temperature alike, and a
# dashboard cannot tell a measured zero from an absent sensor.
# Globals:
#   BUILD_FILE, METRIC_COUNT
# Arguments:
#   $1 - metric name; $2 - HELP text; $3 - value; $4 - why it is missing
# Outputs:
#   HELP, TYPE and the sample on the build file, or one warning: line
# Returns:
#   0
emit_metric() {
  metric_name="${1:-}"
  [ -n "${metric_name}" ] || return 0
  if [ -z "${3:-}" ]; then
    note warning "${metric_name} not sampled: ${4:-source absent}"
    return 0
  fi
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' \
    "${metric_name}" "${2:-}" "${metric_name}" "${metric_name}" "${3}" >>"${BUILD_FILE}"
  METRIC_COUNT=$((METRIC_COUNT + 1))
  note ok "${metric_name}=${3}"
}

# ---------------------------------------------------------------------------

if ! mkdir -p "${TEXTFILE_DIR}" 2>/dev/null; then
  note error "cannot write the textfile directory ${TEXTFILE_DIR}"
  exit 1
fi
: >"${BUILD_FILE}" 2>/dev/null || {
  note error "cannot write ${BUILD_FILE}"
  exit 1
}

TOP_BODY="$(gpu_top_json)"
if [ -z "${TOP_BODY}" ]; then
  note note "intel_gpu_top absent: utilisation falls back to the sysfs frequency ratio"
fi

clock_value="$(sample_clock_mhz)"
if [ -z "${clock_value}" ]; then
  clock_value="$(gpu_top_field "${TOP_BODY}" actual)"
  case "${clock_value}" in '' | *[!0-9]*) clock_value="" ;; esac
  [ -n "${clock_value}" ] && note note "no gt_cur_freq_mhz: clock taken from intel_gpu_top"
fi
emit_metric "${METRIC_CLOCK}" \
  "Current GPU clock in MHz from the Intel Arc card (gt_cur_freq_mhz, or intel_gpu_top freq actual when sysfs has no knob)." \
  "${clock_value}" \
  "no /sys/class/drm/card*/gt_cur_freq_mhz and no intel_gpu_top freq actual"

util_value="$(gpu_top_busy_max "${TOP_BODY}")"
if [ -z "${util_value}" ]; then
  util_value="$(sample_freq_ratio_pct)"
  util_source="sysfs gt_cur_freq_mhz over gt_max_freq_mhz ratio"
fi
emit_metric "${METRIC_UTIL}" \
  "GPU utilisation percent: busiest intel_gpu_top engine, or the sysfs current-over-maximum frequency ratio when intel_gpu_top is absent." \
  "${util_value}" \
  "no intel_gpu_top engine busy and no ${util_source}"

energy_uj="$(sum_rapl_field energy_uj)"
power_source="RAPL package energy delta"
power_value=""
if [ -n "${energy_uj}" ]; then
  power_value="$(compute_power_watts "${energy_uj}")"
  if [ -z "${power_value}" ]; then
    power_source="no baseline yet"
  fi
else
  power_value="$(gpu_top_power_watts "${TOP_BODY}")"
  [ -n "${power_value}" ] && power_source="intel_gpu_top power rail"
fi
emit_metric "${METRIC_POWER}" \
  "Package power watts for the Intel Arc host, from the RAPL package energy delta over the uptime delta (the Arc iGPU exposes no rail of its own)." \
  "${power_value}" \
  "no /sys/class/powercap/intel-rapl energy_uj baseline and no intel_gpu_top power rail (${power_source})"

temp_value="$(sample_temp_celsius)"
emit_metric "${METRIC_TEMP}" \
  "Hottest Intel Arc GPU temperature sensor in Celsius, from the drm hwmon temp inputs." \
  "${temp_value}" \
  "no hwmon temp*_input under card*/hwmon and no i915 or xe sensor under /sys/class/hwmon"

if [ "${METRIC_COUNT}" -eq 0 ]; then
  # Nothing to report. Drop any file from an earlier run so the dashboard ages
  # out instead of graphing hours-old numbers as if they were current.
  rm -f "${PROM_FILE}" "${BUILD_FILE}" 2>/dev/null
  note note "no GPU source answered; ${PROM_FILE} removed rather than left stale"
  exit 0
fi

mv -f "${BUILD_FILE}" "${PROM_FILE}" 2>/dev/null || {
  rm -f "${BUILD_FILE}" 2>/dev/null
  note error "cannot publish ${PROM_FILE}"
  exit 1
}
chmod 0644 "${PROM_FILE}" 2>/dev/null
note ok "wrote ${METRIC_COUNT} metric(s) to ${PROM_FILE}"
exit 0
