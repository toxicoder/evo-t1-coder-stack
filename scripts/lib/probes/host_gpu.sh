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
# Four gauge series, in this order. The names are pinned: the homepage host-GPU
# card and the Grafana host row query them by name, so a rename here is a rename
# there. The two frequency-derived ones carry a source label, because they each
# have two producers and a reader has to be able to tell them apart:
# source="intel_gpu_top" is a measured reading and source="freq_ratio" is the
# sysfs clock fallback the paragraph below explains. The other two carry no label.
#   evo_t1_host_gpu_clock_mhz{source=..}  MHz  /sys/class/drm/card*/gt_cur_freq_mhz
#                                           (freq_ratio), else intel_gpu_top
#                                           "freq"."actual" (intel_gpu_top)
#   evo_t1_host_gpu_utilisation_pct{source=..}  percent  intel_gpu_top  engine
#                                           "busy"  (intel_gpu_top),  else  the
#                                           gt_cur_freq_mhz / gt_max_freq_mhz
#                                           ratio (freq_ratio)
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
# The utilisation gauge is two different measurements wearing one name, so it
# says which one it is in its label and in the log line, never in silence. The
# frequency ratio is not engine busyness: an idle card held at its ceiling reads
# 100, and a card doing heavy work at a low clock reads low. The shipped sampler
# container has no perf permission at all (see the host-gpu-sampler block in
# docker-compose.yml), so the ratio is what that service writes today, and the
# label plus one warning: line per run are what stop a reader taking it for a
# measured busy percentage. What the host has to grant for the real path, none
# of which this file or the compose block grants for you:
#   - intel_gpu_top installed on the host and reachable inside the sampler
#     container (a read-only bind of its own), with HOST_GPU_INTEL_GPU_TOP
#     pointing the probe at that container-side path - the opt-in that turns the
#     real path on, and off by leaving it unset;
#   - perf_event_open allowed: CAP_PERFMON (CAP_SYS_ADMIN on a pre-5.8 kernel),
#     a seccomp posture that does not errno the syscall back, an AppArmor that
#     does not restrict unprivileged perf_event, and a host
#     kernel.perf_event_paranoid the container's uid satisfies;
#   - the card's drm device node and the /dev/dri render node it drives.
# Without all of it the binary runs, answers nothing, and the ratio stands -
# labelled as the ratio, which is the point.
#
# The output is one file in the node_exporter textfile directory (compose mounts
# that directory into the exporter; scripts/lib/probes/host_gpu.sh does not start
# it). It is built as a dot-prefixed sibling and mv'd into place, because the
# textfile collector parses whatever it finds at scrape time and a half-written
# file is a scrape error rather than a stale gauge. The build file has one name,
# so the whole sample-and-publish run is held under flock on a dot-prefixed lock
# path beside the output: two samplers writing that one sibling is how a scrape
# gets a file of interleaved lines. The lock path ends in .lock, not .prom, which
# is what keeps the collector from ever parsing it.
#
# Every number this file writes is awk's printf "%.2f", and awk takes its decimal
# separator from LC_NUMERIC. Under a comma-decimal locale that is "75,00", which
# the textfile collector cannot parse - and it rejects the whole file, not just
# the row, so one locale takes the clock, the watts and the temperature with it.
# LC_ALL is pinned to C below for that reason, and is_prom_float is the backstop
# that drops a malformed value instead of publishing it.
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
#   HOST_GPU_MIN_WINDOW_S   shortest uptime delta the wattage divides by, default 5
#   HOST_GPU_LOCK_WAIT_S    seconds to wait for the textfile lock, default 10
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
MIN_WINDOW_S="${HOST_GPU_MIN_WINDOW_S:-5}"
LOCK_WAIT_S="${HOST_GPU_LOCK_WAIT_S:-10}"

# The decimal separator is not a locale question here. See the header: a comma in
# a gauge value is the whole textfile rejected at scrape time.
LC_ALL=C
LANG=C
export LC_ALL LANG

METRIC_CLOCK="evo_t1_host_gpu_clock_mhz"
METRIC_UTIL="evo_t1_host_gpu_utilisation_pct"
METRIC_POWER="evo_t1_host_gpu_power_watts"
METRIC_TEMP="evo_t1_host_gpu_temp_celsius"

# The two producers of the labelled gauges, as the only values those labels take.
# The homepage card and the Grafana row select on these strings.
SOURCE_TOP="intel_gpu_top"
SOURCE_RATIO="freq_ratio"

# A double quote, held in a variable so the JSON sniff below can use it in a case
# pattern without mixing quote styles the parser cannot follow.
JSON_QUOTE='"'

PROM_FILE="${TEXTFILE_DIR}/${OUT_FILE}"
BUILD_FILE="${TEXTFILE_DIR}/.${OUT_FILE}.building"
LOCK_FILE="${TEXTFILE_DIR}/.${OUT_FILE}.lock"
STATE_FILE="${STATE_DIR}/power.state"

# GPU_TOP_JSON is read at most once per run, so the two metrics that can fall
# back to it do not fork the binary twice.
GPU_TOP_JSON=""
GPU_TOP_JSON_READY=0
METRIC_COUNT=0
# Why the wattage is missing, in the words the gap note and the HELP line carry:
# set by compute_power_watts, which is the only function that can tell these
# apart. The probe never runs in a command substitution, so a plain global is
# enough to carry it back.
POWER_GAP="no baseline recorded yet"

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

# @function is_prom_float
# 0 when the text is a number the Prometheus text exposition format accepts: an
# optional minus, digits, and at most one dot with a digit on at least one side of
# it. This is the locale backstop - a comma decimal, an empty field, a hex string
# or a kernel error line all fail here rather than reaching the file, where one
# unparseable line costs every series in it.
# Globals:
#   None
# Arguments:
#   $1 - candidate value
# Outputs:
#   None
# Returns:
#   0 when it is a Prometheus float, 1 otherwise
is_prom_float() {
  text="${1:-}"
  [ -n "${text}" ] || return 1
  case "${text}" in
    -*) text="${text#-}" ;;
  esac
  [ -n "${text}" ] || return 1
  case "${text}" in
    *[!0-9.]*) return 1 ;;
  esac
  case "${text}" in
    *.*)
      whole="${text%%.*}"
      frac="${text#*.}"
      case "${frac}" in
        *.*) return 1 ;;
      esac
      case "${whole}${frac}" in
        '' | *[!0-9]*) return 1 ;;
      esac
      ;;
  esac
  return 0
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
# reason the gauge carries source="freq_ratio" and the run prints one warning: line
# naming it. The label is what keeps the homepage card honest.
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

# @function window_is_wide_enough
# 0 when the span between two uptime readings is at least <min> seconds. The
# wattage is a joule delta over this span, so a near-zero denominator is not a
# noisy reading, it is an absurd one: two samples a few milliseconds apart turn
# one microjoule of counting jitter into kilowatts. The sampler loop and a host
# shell run share one baseline file, so the short window is reachable and has to
# be refused rather than divided by.
# Globals:
#   None
# Arguments:
#   $1 - window start in seconds; $2 - window end in seconds; $3 - minimum seconds
# Outputs:
#   None
# Returns:
#   0 when the window is wide enough, 1 when it is not or is not a number
window_is_wide_enough() {
  awk -v t0="${1:-0}" -v t1="${2:-0}" -v min="${3:-0}" '
    BEGIN {
      if ((t1 + 0) - (t0 + 0) >= min + 0) exit 0
      exit 1
    }'
}

# @function unwrap_energy_delta
# Watts between two samples of a wrapping energy counter: the unwrap and the
# division in one place, so the guard and the unwrap cannot drift apart. The
# counter is unsigned and rolls at max_energy_uj, so a negative delta is a roll,
# not a bug. The roll is added back as many times as the gap needs, not once: the
# counter this probe reads is the SUM across packages, and one sum can sit far
# enough below its baseline to have crossed several rolls since the last sample,
# which a single-pass unwrap turns into a negative wattage or a dropped sample.
# Refuses to print anything rather than print a wrong number: too short a window
# (see window_is_wide_enough), no max_energy_uj to unwrap with, or a delta the
# unwrap still cannot make monotonic.
# Globals:
#   None
# Arguments:
#   $1 - baseline energy_uj; $2 - current energy_uj; $3 - baseline uptime;
#   $4 - current uptime; $5 - summed max_energy_uj; $6 - minimum window seconds
# Outputs:
#   Watts with two decimals, or nothing
# Returns:
#   0
unwrap_energy_delta() {
  awk -v e0="${1:-0}" -v e1="${2:-0}" -v t0="${3:-0}" -v t1="${4:-0}" \
    -v emax="${5:-0}" -v min_window="${6:-5}" '
    BEGIN {
      span = (t1 + 0) - (t0 + 0)
      if (span < min_window + 0) exit
      delta = (e1 + 0) - (e0 + 0)
      if (delta < 0) {
        range = emax + 0
        if (range <= 0) exit
        wraps = int((0 - delta) / range) + 1
        delta += wraps * range
        if (delta < 0) exit
      }
      printf "%.2f", (delta / 1000000) / span
    }'
}

# @function compute_power_watts
# Watts since the previous run: the package energy delta divided by the uptime
# delta, delegated to unwrap_energy_delta. Energy is a counter, so it needs the
# baseline kept in STATE_FILE; with no baseline the first run prints nothing and
# only records where it started, which keeps "never measured" out of the file
# instead of reporting a false 0 W. Every reason there is for printing nothing is
# named in POWER_GAP, which the gap note and the HELP line carry, so "no watts"
# and "no watts because the two samples were 0.1 s apart" are not the same
# silence. The baseline is written either way, so the next run has a window.
# Globals:
#   UPTIME_FILE, STATE_FILE, STATE_DIR, MIN_WINDOW_S, POWER_GAP
# Arguments:
#   $1 - current summed package energy in microjoules
# Outputs:
#   "<watts>|<reason>" on one line - the watts with two decimals, or an empty
#   field before the delimiter, and the reason naming itself in the other; the new
#   baseline on disk
# Returns:
#   0
compute_power_watts() {
  energy_now="${1:-}"
  POWER_GAP="no baseline recorded yet"
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
  if [ -z "${baseline_uptime}" ] || ! is_unsigned "${baseline_energy}"; then
    POWER_GAP="no baseline recorded yet"
  elif ! window_is_wide_enough "${baseline_uptime}" "${uptime_now}" "${MIN_WINDOW_S}"; then
    POWER_GAP="the ${MIN_WINDOW_S}s minimum window was not reached"
  else
    watts="$(unwrap_energy_delta "${baseline_energy}" "${energy_now}" \
      "${baseline_uptime}" "${uptime_now}" \
      "$(sum_rapl_field max_energy_uj)" "${MIN_WINDOW_S}")"
    [ -n "${watts}" ] ||
      POWER_GAP="the package energy counter was not monotonic and max_energy_uj could not unwrap it"
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
  [ -n "${watts}" ] && POWER_GAP=""
  # watts and reason travel together on one pipe-delimited line rather than in a
  # global: the caller reads this through a command substitution, and a global set
  # on this side of one is invisible on the other side. No reason text below
  # carries the delimiter, so the split is exact.
  printf '%s|%s' "${watts}" "${POWER_GAP}"
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

# @function gpu_top_binary
# The path of a usable intel_gpu_top, or nothing. Split out of run_gpu_top so the
# main flow can tell "nobody installed it" from "it ran and answered nothing"
# without exec'ing it twice - and because that distinction is a log line the
# operator reads, it has to be made outside a command substitution, where a note
# would be swallowed into the JSON.
# Globals:
#   HOST_GPU_INTEL_GPU_TOP
# Arguments:
#   None
# Outputs:
#   The path, or nothing
# Returns:
#   0
gpu_top_binary() {
  top_bin="${HOST_GPU_INTEL_GPU_TOP:-}"
  if [ -z "${top_bin}" ] && command -v intel_gpu_top >/dev/null 2>&1; then
    top_bin="$(command -v intel_gpu_top)"
  fi
  [ -n "${top_bin}" ] || return 0
  [ -x "${top_bin}" ] || return 0
  printf '%s' "${top_bin}"
}

# @function run_gpu_top
# One JSON sample from intel_gpu_top. The binary is optional by design: a host
# that never installed perf tooling has no business failing its metrics over it.
# -o - is the modern spelling and /dev/stdout the older one, so both are tried.
# Both attempts are bounded twice over: stdin comes from /dev/null, because a
# perf tool that reaches for a terminal parks forever the moment nobody is
# attached, and the run sits under timeout, because a wedged perf session must
# not outlive the scrape that asked for it - it would hold the sampler's flock and
# freeze the textfile's mtime, which is the only thing the service's healthcheck
# has to go on. With no timeout on the box the read is refused outright: an
# unbounded read is the wedge the healthcheck exists to catch.
# Globals:
#   HOST_GPU_INTEL_GPU_TOP, TOP_SAMPLE_MS, TOP_CAP
# Arguments:
#   None
# Outputs:
#   The JSON body on one line, or nothing
# Returns:
#   0
run_gpu_top() {
  top_bin="$(gpu_top_binary)"
  [ -n "${top_bin}" ] || return 0
  command -v timeout >/dev/null 2>&1 || return 0
  json="$(timeout "${TOP_CAP}" "${top_bin}" -J -s "${TOP_SAMPLE_MS}" -c 1 -o - </dev/null 2>/dev/null || true)"
  if ! looks_like_json "${json}"; then
    json="$(timeout "${TOP_CAP}" "${top_bin}" -J -s "${TOP_SAMPLE_MS}" -c 1 -o /dev/stdout </dev/null 2>/dev/null || true)"
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

# @function acquire_textfile_lock
# Hold the drop directory's write lock for the rest of this run. The build file
# has one name for the whole tree, so two samplers that overlap interleave their
# lines into it and the exporter scrapes a file that is not valid exposition
# text. flock is taken on a dot-prefixed path beside the output and held until
# this process exits, which is also what makes the file's mtime mean "a sample
# finished". A box with no flock applet samples anyway and says so once: the
# serialisation is the safety, not the reading. A lock another sampler will not
# give up is this sample skipped, not two writers in one file.
# Globals:
#   LOCK_WAIT_S
# Arguments:
#   $1 - lock path
# Outputs:
#   One note: or warning: line when the lock is not held
# Returns:
#   0 when it is safe to write (held, or nothing to hold it with), 1 when another
#   writer would not release it
acquire_textfile_lock() {
  lock_path="${1:-}"
  [ -n "${lock_path}" ] || return 0
  if ! command -v flock >/dev/null 2>&1; then
    note note "flock is absent: nothing serialises two samplers writing ${BUILD_FILE}"
    return 0
  fi
  if ! touch "${lock_path}" 2>/dev/null; then
    note warning "cannot open the lock path ${lock_path}: nothing serialises two samplers writing ${BUILD_FILE}"
    return 0
  fi
  exec 9>"${lock_path}"
  if flock -w "${LOCK_WAIT_S}" 9; then
    return 0
  fi
  note error "another sampler still held ${lock_path} after ${LOCK_WAIT_S}s: this sample is skipped"
  return 1
}

# @function emit_metric
# Append one gauge to the file being built, or record the gap. An unmeasured metric
# is left out of the .prom entirely rather than written as 0, because 0 is a real
# reading for a clock, a utilisation, a wattage and a temperature alike, and a
# dashboard cannot tell a measured zero from an absent sensor. The fifth argument
# is the label set, written verbatim between braces; it is how the two producers
# of the labelled gauges stay distinguishable in Prometheus. A value that is not a
# Prometheus float is a gap too: one bad line costs the whole file at scrape time.
# Globals:
#   BUILD_FILE, METRIC_COUNT
# Arguments:
#   $1 - metric name; $2 - HELP text; $3 - value; $4 - why it is missing;
#   $5 - label set without braces, optional
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
  if ! is_prom_float "${3}"; then
    note warning "${metric_name} not sampled: '${3}' is not a Prometheus float"
    return 0
  fi
  sample_line="${metric_name} ${3}"
  if [ -n "${5:-}" ]; then
    sample_line="${metric_name}{${5}} ${3}"
  fi
  printf '# HELP %s %s\n# TYPE %s gauge\n%s\n' \
    "${metric_name}" "${2:-}" "${metric_name}" "${sample_line}" >>"${BUILD_FILE}"
  METRIC_COUNT=$((METRIC_COUNT + 1))
  note ok "${metric_name}=${3}"
}

# ---------------------------------------------------------------------------

if ! mkdir -p "${TEXTFILE_DIR}" 2>/dev/null; then
  note error "cannot write the textfile directory ${TEXTFILE_DIR}"
  exit 1
fi

# Before the build file is truncated, not after: the file this run writes has one
# name for the whole tree, so the window two samplers can collide in starts here.
acquire_textfile_lock "${LOCK_FILE}" || exit 0

: >"${BUILD_FILE}" 2>/dev/null || {
  note error "cannot write ${BUILD_FILE}"
  exit 1
}

TOP_BODY="$(gpu_top_json)"
TOP_BIN_PATH="$(gpu_top_binary)"
if command -v timeout >/dev/null 2>&1; then
  have_timeout=1
else
  have_timeout=0
fi

# Which of the two producers is about to answer for the labelled gauges, said out
# loud. The shipped sampler container has no perf permission, so the ratio branch
# is the normal one and the normal one is the one that must not read as measured.
if [ -z "${TOP_BIN_PATH}" ]; then
  note warning "intel_gpu_top absent: utilisation and clock fall back to the sysfs clock knobs and are labelled source=\"${SOURCE_RATIO}\""
elif [ "${have_timeout}" -eq 0 ]; then
  note warning "timeout is absent, so the unbounded intel_gpu_top read was refused: utilisation is the sysfs clock ratio, labelled source=\"${SOURCE_RATIO}\""
elif [ -z "${TOP_BODY}" ]; then
  note warning "intel_gpu_top returned no JSON (perf_event_open, the capability, the seccomp or AppArmor posture, or the drm node is denying it): utilisation is the sysfs clock ratio, labelled source=\"${SOURCE_RATIO}\""
fi

clock_value="$(sample_clock_mhz)"
if [ -n "${clock_value}" ]; then
  clock_source="${SOURCE_RATIO}"
else
  clock_source="${SOURCE_TOP}"
  clock_value="$(gpu_top_field "${TOP_BODY}" actual)"
  case "${clock_value}" in '' | *[!0-9]*) clock_value="" ;; esac
  [ -n "${clock_value}" ] && note note "no gt_cur_freq_mhz: clock taken from intel_gpu_top"
fi
emit_metric "${METRIC_CLOCK}" \
  "Current GPU clock in MHz from the Intel Arc card. source=${SOURCE_RATIO} is /sys/class/drm/card*/gt_cur_freq_mhz; source=${SOURCE_TOP} is the intel_gpu_top freq actual reading used when sysfs has no knob." \
  "${clock_value}" \
  "no /sys/class/drm/card*/gt_cur_freq_mhz and no intel_gpu_top freq actual" \
  "source=\"${clock_source}\""

util_value="$(gpu_top_busy_max "${TOP_BODY}")"
if [ -n "${util_value}" ]; then
  util_source="${SOURCE_TOP}"
  note ok "utilisation is the busiest intel_gpu_top engine, source=\"${SOURCE_TOP}\""
else
  util_value="$(sample_freq_ratio_pct)"
  util_source="${SOURCE_RATIO}"
  if [ -n "${util_value}" ]; then
    note warning "evo_t1_host_gpu_utilisation_pct is the gt_cur_freq_mhz over gt_max_freq_mhz clock ratio, not measured engine busy: source=\"${SOURCE_RATIO}\""
  fi
fi
emit_metric "${METRIC_UTIL}" \
  "GPU busy ratio percent for the Intel Arc host. source=${SOURCE_TOP} is the busiest intel_gpu_top engine, a measured reading. source=${SOURCE_RATIO} is gt_cur_freq_mhz over gt_max_freq_mhz, a clock ratio that reads 100 for an idle card pinned at its ceiling and is not engine busyness." \
  "${util_value}" \
  "no intel_gpu_top engine busy and no sysfs gt_cur_freq_mhz over gt_max_freq_mhz ratio" \
  "source=\"${util_source}\""

energy_uj="$(sum_rapl_field energy_uj)"
power_value=""
if [ -n "${energy_uj}" ]; then
  power_sample="$(compute_power_watts "${energy_uj}")"
  power_value="${power_sample%%|*}"
  if [ "${power_value}" != "${power_sample}" ]; then
    POWER_GAP="${power_sample#*|}"
  else
    power_value=""
    POWER_GAP="the energy counter read was not a number"
  fi
else
  POWER_GAP="no /sys/class/powercap/intel-rapl energy_uj to difference"
  power_value="$(gpu_top_power_watts "${TOP_BODY}")"
  [ -n "${power_value}" ] && POWER_GAP=""
fi
emit_metric "${METRIC_POWER}" \
  "Package power watts for the Intel Arc host, from the RAPL package energy delta over the uptime delta (the Arc iGPU exposes no rail of its own). Counter wraps are unwrapped with max_energy_uj, and a window shorter than the probe's minimum yields no sample rather than an absurd wattage." \
  "${power_value}" \
  "${POWER_GAP}"

temp_value="$(sample_temp_celsius)"
emit_metric "${METRIC_TEMP}" \
  "Hottest Intel Arc GPU temperature sensor in Celsius, from the drm hwmon temp inputs." \
  "${temp_value}" \
  "no hwmon temp*_input under card*/hwmon and no i915 or xe sensor under /sys/class/hwmon"

if [ "${METRIC_COUNT}" -eq 0 ]; then
  # Nothing to report. Drop any file from an earlier run so the dashboard ages
  # out instead of graphing hours-old numbers as if they were current. The lock
  # path stays: it is a lock, not a sample, and it is not named *.prom.
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
