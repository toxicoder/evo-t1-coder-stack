#!/usr/bin/env bats
#
# ## host_gpu.bats - hermetic coverage for scripts/lib/probes/host_gpu.sh, the
# stack host's Intel Arc sampler.
#
# The sampler has one contract with four moving parts. It samples what the box
# actually has (drm sysfs clocks, RAPL package energy, hwmon temps, intel_gpu_top
# when installed), writes one atomically published node_exporter textfile .prom,
# and never fails because a source is missing - an absent source leaves its metric
# out of the file and prints one warning: line instead. Four gauge names are pinned
# here because the homepage host-GPU card and the Grafana host row query them by
# name: evo_t1_host_gpu_clock_mhz, evo_t1_host_gpu_utilisation_pct,
# evo_t1_host_gpu_power_watts, evo_t1_host_gpu_temp_celsius.
#
# Nothing here reads the real /sys, /proc/uptime, or /var/lib/node_exporter: every
# path is one of the sampler's documented seams pointed at a per-test fixture, the
# intel_gpu_top path is driven by a stub written into this test's own bin/, and the
# absent-binary path strips it from the PATH it hands the sampler.
#
# Usage: bazelisk test //tests:bats_host_gpu_test   (from any cwd)
# Safety: no network, no daemon, no write outside BATS_TEST_TMPDIR.

# bats assigns output and stderr through run, calls the fixture helpers the cases
# below define, and gives every @test its own subshell.
# shellcheck disable=SC2154,SC2030,SC2031,SC2317
bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

CHECKOUT=""
PROBE=""
FX_SYSFS=""
FX_TEXTFILE=""
FX_STATE=""
FX_UPTIME=""
FX_BIN=""

# The four names the dashboard and this suite agree on. A rename in the sampler
# that the homepage card did not follow has to be a red test here.
PINNED_METRICS="evo_t1_host_gpu_clock_mhz evo_t1_host_gpu_utilisation_pct evo_t1_host_gpu_power_watts evo_t1_host_gpu_temp_celsius"

# Every function the probe defines. The unit test below loads each one, which is
# also how shell_inventory finds these names under tests/.
probe_functions() {
  printf '%s\n' \
    note read_sysfs_value is_unsigned max_of_lines emit_card_hwmon_temps \
    sample_temp_celsius sample_clock_mhz sample_freq_ratio_pct sum_rapl_field \
    compute_power_watts run_gpu_top gpu_top_json gpu_top_field gpu_top_busy_max \
    gpu_top_power_watts emit_metric looks_like_json is_prom_float \
    window_is_wide_enough unwrap_energy_delta gpu_top_binary acquire_textfile_lock
}

setup() {
  CHECKOUT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PROBE="${CHECKOUT}/scripts/lib/probes/host_gpu.sh"
  [[ -f ${PROBE} ]] || skip "scripts/lib/probes/host_gpu.sh is not in the tree"

  FX_SYSFS="${BATS_TEST_TMPDIR?}/sys"
  FX_TEXTFILE="${BATS_TEST_TMPDIR?}/textfile"
  FX_STATE="${BATS_TEST_TMPDIR?}/state"
  FX_UPTIME="${BATS_TEST_TMPDIR?}/uptime"
  FX_BIN="${BATS_TEST_TMPDIR?}/bin"

  build_sysfs_full "${FX_SYSFS}"
  build_powercap_full "${FX_SYSFS}"
  mkdir -p "${FX_TEXTFILE}"
  printf '100.00\n' >"${FX_UPTIME}"

  export HOST_GPU_SYSFS_ROOT="${FX_SYSFS}"
  export HOST_GPU_TEXTFILE_DIR="${FX_TEXTFILE}"
  export HOST_GPU_OUT_FILE=host_gpu.prom
  export HOST_GPU_STATE_DIR="${FX_STATE}"
  export HOST_GPU_UPTIME_FILE="${FX_UPTIME}"
  export HOST_GPU_TOP_SAMPLE_MS=10
  export HOST_GPU_TOP_CAP=2
  unset HOST_GPU_INTEL_GPU_TOP
  mkdir -p "${FX_BIN}"
  export STUB_LOG="${BATS_TEST_TMPDIR?}/stub-logs"
  mkdir -p "${STUB_LOG}"
}

# build_sysfs_full <root> - the drm half of an Arc host: two cards (only the
# first exposes an hwmon), plus a flat hwmon tree holding a CPU sensor that must
# never be mistaken for the GPU and an i915 sensor that must be.
build_sysfs_full() {
  local root="$1"
  mkdir -p "${root}/class/drm/card0/hwmon/hwmon3" "${root}/class/drm/card1" \
    "${root}/class/hwmon/hwmon0" "${root}/class/hwmon/hwmon1"
  printf '1200\n' >"${root}/class/drm/card0/gt_cur_freq_mhz"
  printf '1600\n' >"${root}/class/drm/card0/gt_max_freq_mhz"
  printf '900\n' >"${root}/class/drm/card1/gt_cur_freq_mhz"
  printf '1600\n' >"${root}/class/drm/card1/gt_max_freq_mhz"
  printf '47000\n' >"${root}/class/drm/card0/hwmon/hwmon3/temp1_input"
  printf '52000\n' >"${root}/class/drm/card0/hwmon/hwmon3/temp2_input"
  printf 'coretemp\n' >"${root}/class/hwmon/hwmon0/name"
  printf '95000\n' >"${root}/class/hwmon/hwmon0/temp1_input"
  printf 'i915\n' >"${root}/class/hwmon/hwmon1/name"
  printf '44000\n' >"${root}/class/hwmon/hwmon1/temp1_input"
}

# build_powercap_full <root> - one RAPL package plus a domain inside it. The
# domain's counter is 900 MJ on purpose: a sampler that sums both reports a
# machine burning 90 W rather than the 0.5 W it is actually drawing.
build_powercap_full() {
  local root="$1"
  mkdir -p "${root}/class/powercap/intel-rapl:0" "${root}/class/powercap/intel-rapl:0:0"
  printf '5000000\n' >"${root}/class/powercap/intel-rapl:0/energy_uj"
  printf '100000000\n' >"${root}/class/powercap/intel-rapl:0/max_energy_uj"
  printf '0\n' >"${root}/class/powercap/intel-rapl:0:0/energy_uj"
  printf '100000000\n' >"${root}/class/powercap/intel-rapl:0:0/max_energy_uj"
}

# seed_power_baseline <uptime> <energy_uj> - the previous run's sample, which is
# what turns the energy counter into a wattage.
seed_power_baseline() {
  mkdir -p "${FX_STATE}"
  printf '%s\n%s\n' "$1" "$2" >"${FX_STATE}/power.state"
}

# stub_intel_gpu_top <json> - an intel_gpu_top that answers with <json> however it
# is asked, and records the argv it was handed.
stub_intel_gpu_top() {
  local json="$1" stub
  mkdir -p "${FX_BIN}"
  stub="${FX_BIN}/intel_gpu_top"
  cat >"${stub}" <<STUB
#!/bin/sh
if [ -n "\${STUB_LOG:-}" ]; then
  mkdir -p "\${STUB_LOG}"
  printf '%s\n' "intel_gpu_top \$*" >>"\${STUB_LOG}/intel_gpu_top.log"
fi
printf '%s\n' '${json}'
STUB
  chmod 755 "${stub}"
  export PATH="${FX_BIN}:${PATH}"
}

# hide_intel_gpu_top - a PATH that cannot find the binary in any directory, so the
# degrade-to-sysfs branch drives a box that never installed it rather than one
# whose stub this suite forgot to remove.
hide_intel_gpu_top() {
  local stripped
  stripped="$(path_without_exe intel_gpu_top)" ||
    skip "cannot build a PATH without intel_gpu_top"
  export PATH="${stripped}"
}

# run_sampler - the probe under sh with this test's fixtures, stdout and stderr
# kept apart so the silence of a healthy run is assertable.
run_sampler() {
  run --separate-stderr sh "${PROBE}"
}

# prom_value <name> - the sample value of one metric in the published file, with
# any label set taken off the name first. The two frequency gauges carry
# source="...", so a bare $1 comparison would read the whole brace and answer
# nothing for a series that is plainly there.
prom_value() {
  awk -v want="${1}" '
    {
      name = $1
      sub(/\{[^{}]*\}$/, "", name)
      if (name == want) print $2
    }' "${FX_TEXTFILE}/host_gpu.prom"
}

# prom_line <name> <label-set> - the whole sample line for one metric carrying one
# label set, or nothing. The source label is the only thing telling a reader a
# measured busy percentage from a clock ratio, so it is asserted on the line
# itself rather than inferred from the number.
prom_line() {
  awk -v want="${1}" -v labels="${2:-}" '
    {
      name = $1
      sub(/\{.*$/, "", name)
      if (name != want) next
      if (labels == "") { if (index($0, "{") == 0) print; next }
      if (index($0, want "{" labels "}") == 1) print
    }' "${FX_TEXTFILE}/host_gpu.prom"
}

# assert_valid_prom <file> - a strict pass over the Prometheus text exposition
# format: names are legal, a sample is name plus one float, a # comment is only
# ever a well-formed HELP or TYPE, every sample's family was declared by a TYPE
# line, and neither HELP nor TYPE nor a series name repeats. The textfile
# collector rejects the whole file for any break here, so the gap this asserts is
# the one that turns the host card into "no data" rather than a wrong number.
assert_valid_prom() {
  awk -v labelre='^\\{[a-zA-Z_][a-zA-Z0-9_]*="[^"\\\\]*"(,[a-zA-Z_][a-zA-Z0-9_]*="[^"\\\\]*")*\\}$' '
    function isname(s) { return s ~ /^[a-zA-Z_:][a-zA-Z0-9_:]*$/ }
    function isfloat(s) { return s ~ /^-?([0-9]+(\.[0-9]+)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/ }
    {
      line = $0
      if (line == "") next
      if (substr(line, 1, 1) == "#") {
        if (line ~ /^# HELP [a-zA-Z_:][a-zA-Z0-9_:]* [^ ].*$/ && NF >= 3) {
          family = $3
          if (isname(family) != 1) { printf "HELP names an illegal metric: %s\n", line; bad = 1 }
          if (help[family]++) { printf "duplicate HELP for %s\n", family; bad = 1 }
          if (sampled[family]) { printf "HELP after its samples: %s\n", line; bad = 1 }
          next
        }
        if (line ~ /^# TYPE [a-zA-Z_:][a-zA-Z0-9_:]* (counter|gauge|untyped|histogram|summary)$/) {
          family = $3
          if (type[family]++) { printf "duplicate TYPE for %s\n", family; bad = 1 }
          next
        }
        printf "comment that is neither HELP nor TYPE: %s\n", line
        bad = 1
        next
      }
      # name, an optional {label="value",...} set, then exactly one value. A
      # comma-decimal locale writes `75,00` here and the collector rejects the
      # whole file for it, so the value shape is checked, not trusted.
      if (match(line, /^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^{}]*\})?[ \t]+[^ \t]+$/) != 1) {
        printf "sample is not name plus one value: %s\n", line
        bad = 1
        next
      }
      name = line
      sub(/[ \t]+[^ \t]+$/, "", name)
      value = line
      sub(/^.*[ \t]/, "", value)
      # The label pattern arrives as a variable, not as a literal: a quote inside a
      # /.../ regex literal is not something every awk on every gate image lexes.
      if (index(name, "{") > 0) {
        family = substr(name, 1, index(name, "{") - 1)
        labels = substr(name, index(name, "{"))
        if (isname(family) != 1) { printf "illegal metric name: %s\n", line; bad = 1 }
        if (labels !~ labelre) {
          printf "malformed label set: %s\n", line
          bad = 1
        }
      } else {
        family = name
        if (isname(family) != 1) { printf "illegal metric name: %s\n", line; bad = 1 }
      }
      if (isfloat(value) != 1) { printf "value is not a float: %s\n", line; bad = 1 }
      if (type[family] != 1) { printf "sample with no TYPE line: %s\n", family; bad = 1 }
      if (series[line]++) { printf "duplicate series: %s\n", line; bad = 1 }
      sampled[family] = 1
    }
    END { if (bad) exit 1 }
  ' "${file}"
}

# -- the sampler: the healthy host ------------------------------------------

@test "sampler: a full Arc host writes all four pinned series and exits 0 in silence" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
  assert_file_exists "the textfile collector file" "${FX_TEXTFILE}/host_gpu.prom"
  local name
  for name in ${PINNED_METRICS}; do
    assert_contains_file "${name} is emitted" "${FX_TEXTFILE}/host_gpu.prom" \
      "^${name}[{ ]"
  done
  assert_eq "clock is the highest card clock" "1200" "$(prom_value evo_t1_host_gpu_clock_mhz)"
  assert_eq "power is the package delta, not the domain delta" "0.50" "$(prom_value evo_t1_host_gpu_power_watts)"
  assert_eq "temp is the hottest GPU sensor, not coretemp" "52.00" "$(prom_value evo_t1_host_gpu_temp_celsius)"
}

@test "sampler: the published file is valid Prometheus exposition format" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_valid_prom "${FX_TEXTFILE}"
  # The gauge type is what a Grafana axis and a Homepage value query both expect.
  [ "$(grep -c '^# TYPE ' "${FX_TEXTFILE}/host_gpu.prom")" -eq 4 ]
  [[ $(grep -c ' gauge$' "${FX_TEXTFILE}/host_gpu.prom") -eq 4 ]]
  # Every family carries a one-line HELP so the metric page explains itself.
  [ "$(grep -c '^# HELP evo_t1_host_gpu' "${FX_TEXTFILE}/host_gpu.prom")" -eq 4 ]
}

@test "sampler: the file is published atomically, world-readable, with no temp left behind" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "no dot-prefixed build file survives" "0" "$(find "${FX_TEXTFILE}" -name '*.building' | wc -l | tr -d ' ')"
  # The drop holds one *.prom; the flock path beside it is deliberately not named
  # that, which is the only reason the collector parses the sample and not the lock.
  assert_eq "only the one .prom is in the directory" "1" "$(find "${FX_TEXTFILE}" -maxdepth 1 -type f -name '*.prom' | wc -l | tr -d ' ')"
  # node_exporter reads the textfile dir as nobody, so a 0600 file is a series
  # that exists on disk and never appears in Prometheus.
  run stat -c '%a' "${FX_TEXTFILE}/host_gpu.prom"
  assert_eq "the collector can read it" "644" "${output}"
}

@test "power: no RAPL and no intel_gpu_top leaves the wattage out, not at zero" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  rm -rf "${FX_SYSFS}/class/powercap"
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "no RAPL and no intel_gpu_top means no wattage" "$(grep -c '^evo_t1_host_gpu_power_watts' "${FX_TEXTFILE}/host_gpu.prom")" "0"
  assert_match "the gap names its source" 'evo_t1_host_gpu_power_watts not sampled' "${output}"
}

# -- the sampler: each source, on its own -----------------------------------

@test "sysfs only: utilisation is the current-over-maximum frequency ratio" {
  hide_intel_gpu_top
  seed_power_baseline 99.50 4500000
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "1200 of 1600 MHz is 75 percent" "75.00" "$(prom_value evo_t1_host_gpu_utilisation_pct)"
  assert_match "the run says intel_gpu_top was missing" 'intel_gpu_top absent' "${output}"
}

@test "intel_gpu_top: the busiest engine wins, whatever the frequency ratio says" {
  stub_intel_gpu_top '{"timestamp":1.0,"Engines":{"Render/3D/0":{"busy":33.5},"Blitter/13/0":{"busy":4.0}},"freq":{"actual":1450,"nominal":1600},"power":{"card":7.25,"gt":1.5,"pkg":18.0}}'
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "busiest engine, not max" "33.50" "$(prom_value evo_t1_host_gpu_utilisation_pct)"
  assert_eq "RAPL still outranks the intel_gpu_top rail" "0.50" "$(prom_value evo_t1_host_gpu_power_watts)"
  assert_match "it was asked for one JSON sample" 'intel_gpu_top .*-J .*-c 1' "$(cat "${STUB_LOG}/intel_gpu_top.log")"
}

@test "intel_gpu_top: an engine reporting over 100 percent is clamped" {
  stub_intel_gpu_top '{"Engines":{"Render/3D/0":{"busy":133.0}}}'
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "a saturated engine caps the gauge" "100.00" "$(prom_value evo_t1_host_gpu_utilisation_pct)"
}

@test "intel_gpu_top: clock and power fall back to it when sysfs has neither knob" {
  stub_intel_gpu_top '{"Engines":{"Render/3D/0":{"busy":12.0}},"freq":{"actual":1450,"nominal":1600},"power":{"card":7.25,"gt":1.5,"pkg":18.0}}'
  rm -f "${FX_SYSFS}/class/drm/card0/gt_cur_freq_mhz" "${FX_SYSFS}/class/drm/card1/gt_cur_freq_mhz"
  rm -rf "${FX_SYSFS}/class/powercap"
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "freq actual is the clock of last resort" "1450" "$(prom_value evo_t1_host_gpu_clock_mhz)"
  assert_eq "the card rail is the power of last resort" "7.25" "$(prom_value evo_t1_host_gpu_power_watts)"
  assert_match "the clock gap is still narrated" 'clock taken from intel_gpu_top' "${output}"
}

@test "power: the first run records a baseline and refuses to guess a wattage" {
  hide_intel_gpu_top
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "no baseline means no power series" "$(grep -c '^evo_t1_host_gpu_power_watts' "${FX_TEXTFILE}/host_gpu.prom")" "0"
  assert_eq "a false zero is not emitted" "$(grep -c 'evo_t1_host_gpu_power_watts 0' "${FX_TEXTFILE}/host_gpu.prom")" "0"
  assert_file_exists "the baseline is on disk for the next run" "${FX_STATE}/power.state"
  assert_eq "the baseline is uptime then energy" "2" "$(wc -l <"${FX_STATE}/power.state" | tr -d ' ')"
  assert_eq "uptime is the first line" "100.00" "$(sed -n '1p' "${FX_STATE}/power.state")"
  assert_eq "energy is the second" "5000000" "$(sed -n '2p' "${FX_STATE}/power.state")"
}

@test "power: a baseline whose clock did not advance is dropped, not divided by" {
  hide_intel_gpu_top
  seed_power_baseline 100.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "a zero-length window is no measurement" "$(grep -c '^evo_t1_host_gpu_power_watts' "${FX_TEXTFILE}/host_gpu.prom")" "0"
}

@test "power: a rolled-over energy counter is unwrapped with max_energy_uj" {
  hide_intel_gpu_top
  # The package counter wrapped at its 100 MJ maximum between the two runs: 95 MJ
  # read last time, 5 MJ now, so 10 MJ went into the socket over the 10 s window
  # and the honest answer is 1.00 W. Without the unwrap the gauge reads minus
  # nine kilowatts and the homepage card shows a machine generating power.
  seed_power_baseline 90.00 95000000
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "rollover reads as a positive wattage" "1.00" "$(prom_value evo_t1_host_gpu_power_watts)"
}

@test "power: a rolled-over counter with no max_energy_uj is dropped" {
  hide_intel_gpu_top
  rm -f "${FX_SYSFS}/class/powercap/intel-rapl:0/max_energy_uj" \
    "${FX_SYSFS}/class/powercap/intel-rapl:0:0/max_energy_uj"
  seed_power_baseline 90.00 95000000
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "no way to unwrap means no negative gauge" "$(grep -c '^evo_t1_host_gpu_power_watts' "${FX_TEXTFILE}/host_gpu.prom")" "0"
}

# -- the sampler: absent sources, which is the whole point -------------------

@test "missing sources: nothing sampled still exits 0, writes no metrics, and says so" {
  hide_intel_gpu_top
  rm -rf "${FX_SYSFS}/class" "${FX_UPTIME}"
  run_sampler
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
  assert_file_not_exists "no file for a host with nothing to say" "${FX_TEXTFILE}/host_gpu.prom"
  local name
  for name in ${PINNED_METRICS}; do
    assert_match "the gap is narrated for ${name}" "${name} not sampled" "${output}"
  done
}

@test "missing sources: a file from a previous run is removed rather than left stale" {
  mkdir -p "${FX_TEXTFILE}"
  printf '# TYPE stale_gauge gauge\nstale_gauge 1\n' >"${FX_TEXTFILE}/host_gpu.prom"
  hide_intel_gpu_top
  rm -rf "${FX_SYSFS}/class" "${FX_UPTIME}"
  run_sampler
  [ "${status}" -eq 0 ]
  assert_file_not_exists "yesterday's numbers do not graph as today's" "${FX_TEXTFILE}/host_gpu.prom"
}

@test "missing sources: one dead source costs one metric and nothing else" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  rm -f "${FX_SYSFS}/class/drm/card0/hwmon/hwmon3/temp1_input" \
    "${FX_SYSFS}/class/drm/card0/hwmon/hwmon3/temp2_input" \
    "${FX_SYSFS}/class/hwmon/hwmon1/temp1_input"
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "the card clocks still got written" "1200" "$(prom_value evo_t1_host_gpu_clock_mhz)"
  assert_eq "the wattage still got written" "0.50" "$(prom_value evo_t1_host_gpu_power_watts)"
  assert_eq "clock, utilisation and power all still got written" "3" "$(grep -c '^evo_t1_host_gpu' "${FX_TEXTFILE}/host_gpu.prom")"
  assert_match "and it is named" 'evo_t1_host_gpu_temp_celsius not sampled' "${output}"
}

@test "sampler: a textfile directory that cannot be written is an error, not a shrug" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  local blocker="${BATS_TEST_TMPDIR?}/blocked"
  printf 'not a directory\n' >"${blocker}"
  HOST_GPU_TEXTFILE_DIR="${blocker}/textfile"
  export HOST_GPU_TEXTFILE_DIR
  run_sampler
  [ "${status}" -ne 0 ]
  assert_match "the operator is told which path failed" 'error: cannot write the textfile directory' "${output}"
}

# -- the pieces, loaded straight out of the probe ---------------------------

@test "probe: every function it defines loads as valid sh" {
  local name
  for name in $(probe_functions); do
    load_shell_function "${PROBE}" "${name}"
    declare -F "${name}" >/dev/null ||
      fail "${name} did not load out of scripts/lib/probes/host_gpu.sh"
  done
}

@test "units: read_sysfs_value and is_unsigned reject junk at the source" {
  load_shell_function "${PROBE}" read_sysfs_value
  load_shell_function "${PROBE}" is_unsigned
  local probe_dir="${BATS_TEST_TMPDIR?}/knob"
  mkdir -p "${probe_dir}"
  printf '  1200  \n' >"${probe_dir}/spaces"
  printf 'none\n' >"${probe_dir}/none"
  assert_eq "whitespace is stripped" "1200" "$(read_sysfs_value "${probe_dir}/spaces")"
  assert_eq "an absent file reads as nothing" "" "$(read_sysfs_value "${probe_dir}/missing")"
  run is_unsigned "1200"
  [ "${status}" -eq 0 ]
  run is_unsigned "none"
  [ "${status}" -ne 0 ]
  run is_unsigned ""
  [ "${status}" -ne 0 ]
}

@test "units: max_of_lines reports nothing rather than zero for an empty set" {
  load_shell_function "${PROBE}" max_of_lines
  assert_eq "the max across cards" "1200" "$(printf '900\n1200\n' | max_of_lines 0)"
  assert_eq "an empty set is not a measured zero" "" "$(printf '' | max_of_lines 2)"
  assert_eq "two decimals when asked" "33.50" "$(printf '4.0\n33.5\n' | max_of_lines 2)"
}

@test "units: sum_rapl_field counts packages and skips the domains inside them" {
  # sum_rapl_field reads through its two helpers rather than inlining them, so the
  # unit loads the trio the way the file defines it.
  load_shell_function "${PROBE}" read_sysfs_value
  load_shell_function "${PROBE}" is_unsigned
  load_shell_function "${PROBE}" sum_rapl_field
  # The probe sets SYSFS_ROOT once at the top of the file, which a body loaded on
  # its own does not get, so the unit hands it the same global the whole run uses.
  SYSFS_ROOT="${FX_SYSFS}"
  assert_eq "one package only" "5000000" "$(sum_rapl_field energy_uj)"
  assert_eq "max_energy_uj sums the same one package" "100000000" "$(sum_rapl_field max_energy_uj)"
  # shellcheck disable=SC2034 # sum_rapl_field reads this global it cannot see declared
  SYSFS_ROOT="${BATS_TEST_TMPDIR?}/nothing"
  assert_eq "no powercap at all is nothing, not zero" "" "$(sum_rapl_field energy_uj)"
}

@test "units: gpu_top_field, gpu_top_busy_max and gpu_top_power_watts read both JSON spellings" {
  load_shell_function "${PROBE}" gpu_top_field
  load_shell_function "${PROBE}" gpu_top_busy_max
  load_shell_function "${PROBE}" gpu_top_power_watts
  local modern='{"freq":{"actual":1450,"throttle_reason":"none"},"Engines":{"Render/3D/0":{"busy":8.5}},"power":{"card":4.25}}'
  local legacy='{"render":6.0,"blitter":0.0,"video":0.0}'
  assert_eq "freq actual" "1450" "$(gpu_top_field "${modern}" actual)"
  assert_eq "a reason string is not a number" "" "$(gpu_top_field "${modern}" throttle_reason)"
  assert_eq "busy from the 2.x engine objects" "8.50" "$(gpu_top_busy_max "${modern}")"
  assert_eq "flat render/blitter from the 1.x spelling" "6.00" "$(gpu_top_busy_max "${legacy}")"
  assert_eq "no engines is no measurement" "" "$(gpu_top_busy_max '{"freq":{"actual":1}}')"
  assert_eq "the card rail" "4.25" "$(gpu_top_power_watts "${modern}")"
  assert_eq "no power block is nothing" "" "$(gpu_top_power_watts '{"Engines":{}}')"
}

@test "units: emit_metric writes a gauge or a gap, never a zero" {
  load_shell_function "${PROBE}" note
  load_shell_function "${PROBE}" is_prom_float
  load_shell_function "${PROBE}" emit_metric
  BUILD_FILE="${BATS_TEST_TMPDIR?}/built.prom"
  METRIC_COUNT=0
  : >"${BUILD_FILE}"
  emit_metric evo_t1_host_gpu_clock_mhz "MHz." 1200 "no knob"
  emit_metric evo_t1_host_gpu_temp_celsius "C." "" "no hwmon"
  assert_eq "one gauge counted" "1" "${METRIC_COUNT}"
  assert_contains_file "the sample line" "${BUILD_FILE}" '^evo_t1_host_gpu_clock_mhz 1200$'
  assert_not_match "an unmeasured metric is absent, not zero" 'evo_t1_host_gpu_temp_celsius' "$(cat "${BUILD_FILE}")"
  assert_not_match "no zero was invented" ' 0$' "$(cat "${BUILD_FILE}")"
}

@test "units: note prints the operator CLI's own vocabulary" {
  load_shell_function "${PROBE}" note
  assert_eq "ok" "ok: clock=1200" "$(note ok "clock=1200")"
  assert_eq "warning" "warning: no hwmon" "$(note warning "no hwmon")"
}

@test "units: looks_like_json separates a sample from a usage banner or an error" {
  load_shell_function "${PROBE}" looks_like_json
  # The pattern is built from the probe's own JSON_QUOTE constant; unset it and the
  # pattern degrades to "has a colon", which would pass an error line.
  # shellcheck disable=SC2034 # the loaded body builds its case pattern from this global
  JSON_QUOTE='"'
  run looks_like_json '{"Engines":{"Render/3D/0":{"busy":8.5}}}'
  [ "${status}" -eq 0 ]
  run looks_like_json ''
  [ "${status}" -ne 0 ]
  run looks_like_json 'intel_gpu_top: error: no such option -J'
  [ "${status}" -ne 0 ]
}

@test "probe: it is a POSIX sh probe and its four names are pinned in the file" {
  local probe_src
  probe_src="$(bats_source_repo_root)/scripts/lib/probes/host_gpu.sh"
  [[ -f ${probe_src} ]] || skip "the probe is not in the source tree"
  assert_eq "it runs under sh, not bash" '#!/bin/sh' "$(head -n 1 "${probe_src}")"
  assert_contains_file "shellcheck is told it is sh" "${probe_src}" '^# shellcheck shell=sh$'
  assert_not_match "it is never sourced" '^# shellcheck shell=bash' "$(head -n 3 "${probe_src}")"
  local name
  for name in ${PINNED_METRICS}; do
    assert_contains_file "${name} is named in the probe" "${probe_src}" "${name}"
  done
  # Pure ASCII: a smart dash copied out of a design doc breaks the awk regexes.
  run env LC_ALL=C grep -n '[^ -~]' "${probe_src}"
  [ "${status}" -ne 0 ]
}

# -- the source label: which producer answered for the frequency gauges ------
#
# The utilisation gauge has two producers and only one of them measures busyness.
# The shipped sampler container holds no perf permission, so the clock ratio is the
# reading it produces every run, and a card that showed that number plain would
# have an operator reading an idle card pinned at its ceiling as a saturated GPU.
# The label is the whole defence, so it is asserted on the sample line.

@test "source label: the sysfs fallback labels both frequency gauges freq_ratio and says so" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "the clock came from gt_cur_freq_mhz" \
    'evo_t1_host_gpu_clock_mhz{source="freq_ratio"} 1200' \
    "$(prom_line evo_t1_host_gpu_clock_mhz 'source="freq_ratio"')"
  assert_eq "the busy number came from the clock ratio" \
    'evo_t1_host_gpu_utilisation_pct{source="freq_ratio"} 75.00' \
    "$(prom_line evo_t1_host_gpu_utilisation_pct 'source="freq_ratio"')"
  assert_match "the run says the number is not measured busyness" \
    'not measured engine busy' "${output}"
  assert_match "and names the label it wrote" 'source="freq_ratio"' "${output}"
}

@test "source label: a measured intel_gpu_top sample labels the busy gauge and stays quiet about the ratio" {
  stub_intel_gpu_top '{"Engines":{"Render/3D/0":{"busy":33.5}},"freq":{"actual":1450,"nominal":1600}}'
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "the engine reading carries the measured source" \
    'evo_t1_host_gpu_utilisation_pct{source="intel_gpu_top"} 33.50' \
    "$(prom_line evo_t1_host_gpu_utilisation_pct 'source="intel_gpu_top"')"
  assert_eq "and the clock still came from sysfs, labelled as such" \
    'evo_t1_host_gpu_clock_mhz{source="freq_ratio"} 1200' \
    "$(prom_line evo_t1_host_gpu_clock_mhz 'source="freq_ratio"')"
  assert_not_match "no fallback warning for a measured reading" \
    'not measured engine busy' "${output}"
}

@test "source label: a clock with no sysfs knob carries intel_gpu_top as its source" {
  stub_intel_gpu_top '{"Engines":{"Render/3D/0":{"busy":12.0}},"freq":{"actual":1450}}'
  rm -f "${FX_SYSFS}/class/drm/card0/gt_cur_freq_mhz" \
    "${FX_SYSFS}/class/drm/card1/gt_cur_freq_mhz"
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "the of-last-resort clock says where it came from" \
    'evo_t1_host_gpu_clock_mhz{source="intel_gpu_top"} 1450' \
    "$(prom_line evo_t1_host_gpu_clock_mhz 'source="intel_gpu_top"')"
}

@test "intel_gpu_top: a binary that answers nothing is reported as denied, not swallowed into the fallback" {
  mkdir -p "${FX_BIN}"
  cat >"${FX_BIN}/intel_gpu_top" <<'STUB'
#!/bin/sh
# Installed but refused: what perf_event_open, a capability drop, seccomp or
# AppArmor looks like from the probe's side.
exit 1
STUB
  chmod 755 "${FX_BIN}/intel_gpu_top"
  export PATH="${FX_BIN}:${PATH}"
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_match "the run names the binary that failed to answer" 'returned no JSON' "${output}"
  assert_match "and names the grant the host owes it" 'perf_event_open' "${output}"
  assert_eq "the ratio stands, labelled as the ratio" \
    'evo_t1_host_gpu_utilisation_pct{source="freq_ratio"} 75.00' \
    "$(prom_line evo_t1_host_gpu_utilisation_pct 'source="freq_ratio"')"
}

# -- the bounded read: a wedged perf session must not park the sampler --------
#
# One unbounded intel_gpu_top read is a sampler that never returns, a textfile
# whose mtime stops moving, and a service still reporting Up. Each case bounds the
# probe itself as well, so a regression fails this test rather than hanging it.

@test "intel_gpu_top: a binary that never exits is cut off at the cap" {
  local tmo
  tmo="$(command -v timeout)" || skip "no timeout on this box to bound the case itself"
  mkdir -p "${FX_BIN}"
  cat >"${FX_BIN}/intel_gpu_top" <<'STUB'
#!/bin/sh
# Ignores its argv and its stdin and never returns: the wedge the cap exists for.
sleep 120
STUB
  chmod 755 "${FX_BIN}/intel_gpu_top"
  export PATH="${FX_BIN}:${PATH}"
  seed_power_baseline 90.00 0
  export HOST_GPU_TOP_CAP=1
  run --separate-stderr "${tmo}" 20 sh "${PROBE}"
  [ "${status}" -eq 0 ]
  assert_eq "the sample still published" \
    'evo_t1_host_gpu_utilisation_pct{source="freq_ratio"} 75.00' \
    "$(prom_line evo_t1_host_gpu_utilisation_pct 'source="freq_ratio"')"
}

# -- the wattage: wraps, the window, and the race ----------------------------

@test "power: an energy sum that crossed several rolls unwraps every one of them" {
  load_shell_function "${PROBE}" unwrap_energy_delta
  # A 100 MJ roll and a summed counter that fell 800 MJ: eight full rolls plus
  # 100 MJ, so 100 J into the socket over the 60 s window is 1.67 W. Adding one
  # roll leaves the delta negative, which is the single-pass answer this replaces.
  assert_eq "nine rolls added back" "1.67" \
    "$(unwrap_energy_delta 1000000000 200000000 100 160 100000000 5)"
  assert_eq "one roll still unwraps" "1.00" \
    "$(unwrap_energy_delta 95000000 5000000 90 100 100000000 5)"
  assert_eq "a monotonic delta needs no unwrap" "0.50" \
    "$(unwrap_energy_delta 0 5000000 90 100 100000000 5)"
}

@test "power: a summed counter far below its baseline still reads as positive watts" {
  hide_intel_gpu_top
  # Two packages, so the counter the probe differences is a sum that sits well
  # above one package's own maximum and crossed more than one roll since the
  # baseline. A single-pass unwrap adds 200 MJ once, stays negative, and drops.
  mkdir -p "${FX_SYSFS}/class/powercap/intel-rapl:1"
  printf '0\n' >"${FX_SYSFS}/class/powercap/intel-rapl:1/energy_uj"
  printf '100000000\n' >"${FX_SYSFS}/class/powercap/intel-rapl:1/max_energy_uj"
  seed_power_baseline 90.00 250000000
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "155 J over 10 s, not a negative wattage and not a gap" \
    "15.50" "$(prom_value evo_t1_host_gpu_power_watts)"
}

@test "power: a window shorter than the minimum yields no gauge and names itself" {
  load_shell_function "${PROBE}" window_is_wide_enough
  load_shell_function "${PROBE}" unwrap_energy_delta
  run window_is_wide_enough 100 100.5 5
  [ "${status}" -ne 0 ]
  run window_is_wide_enough 100 105 5
  [ "${status}" -eq 0 ]
  assert_eq "the short window is refused before the divide" "" \
    "$(unwrap_energy_delta 0 5000000 100 100.5 100000000 5)"
  hide_intel_gpu_top
  # The compose sampler and a host-shell run share one baseline file, so two
  # samples a tenth of a second apart is a reachable state, and 5 J over 0.1 s is
  # a 50 kW Arc.
  seed_power_baseline 99.90 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "no wattage from a tenth-of-a-second window" "0" \
    "$(grep -c '^evo_t1_host_gpu_power_watts' "${FX_TEXTFILE}/host_gpu.prom")"
  assert_match "and the gap says the window was too short, not that the box is silent" \
    'minimum window was not reached' "${output}"
}

@test "power: a counter that cannot be made monotonic is still dropped" {
  hide_intel_gpu_top
  rm -f "${FX_SYSFS}/class/powercap/intel-rapl:0/max_energy_uj" \
    "${FX_SYSFS}/class/powercap/intel-rapl:0:0/max_energy_uj"
  seed_power_baseline 90.00 95000000
  run_sampler
  [ "${status}" -eq 0 ]
  assert_eq "no way to unwrap means no negative gauge" "0" \
    "$(grep -c '^evo_t1_host_gpu_power_watts' "${FX_TEXTFILE}/host_gpu.prom")"
  assert_match "named as a counter that would not unwrap" 'not monotonic' "${output}"
}

# -- the textfile write: one build file, so one writer at a time -------------

@test "textfile: the drop carries a flock path beside the output that the collector ignores" {
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  run_sampler
  [ "${status}" -eq 0 ]
  assert_file_exists "the lock sits beside the sample" "${FX_TEXTFILE}/.host_gpu.prom.lock"
  assert_eq "and it is not named *.prom, so the textfile collector never parses it" \
    "1" "$(find "${FX_TEXTFILE}" -maxdepth 1 -type f -name '*.prom' | wc -l | tr -d ' ')"
}

@test "textfile: a lock another sampler holds skips this sample rather than interleaving it" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this box"
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  mkdir -p "${FX_TEXTFILE}"
  : >"${FX_TEXTFILE}/.host_gpu.prom.lock"
  local holder
  flock "${FX_TEXTFILE}/.host_gpu.prom.lock" -c 'sleep 5' >/dev/null 2>&1 &
  holder=$!
  sleep 0.5
  export HOST_GPU_LOCK_WAIT_S=1
  run_sampler
  kill "${holder}" 2>/dev/null || true
  wait "${holder}" 2>/dev/null || true
  [ "${status}" -eq 0 ]
  assert_match "the run says it gave up on the lock" 'this sample is skipped' "${output}"
  assert_file_not_exists "and published nothing rather than a half-written file" \
    "${FX_TEXTFILE}/host_gpu.prom"
}

# -- the locale: one comma costs the whole file ------------------------------

@test "units: is_prom_float accepts only what the exposition format parses" {
  load_shell_function "${PROBE}" is_prom_float
  local good
  for good in "75.00" "1200" "-0.50" "0.00" "100.00"; do
    run is_prom_float "${good}"
    [ "${status}" -eq 0 ] || fail "'${good}' is a legal Prometheus float"
  done
  local bad
  for bad in "75,00" "" "-" "." "1.2.3" "none" "12e3" "0x10" "+5"; do
    run is_prom_float "${bad}"
    [ "${status}" -ne 0 ] || fail "'${bad}' is not a legal Prometheus float"
  done
}

@test "locale: the probe pins the C locale so a comma decimal cannot blank the drop" {
  local probe_src comma_locale
  probe_src="$(bats_source_repo_root)/scripts/lib/probes/host_gpu.sh"
  [[ -f ${probe_src} ]] || skip "the probe is not in the source tree"
  assert_contains_file "LC_ALL is pinned to C" "${probe_src}" '^LC_ALL=C$'
  assert_contains_file "and exported, so every awk printf inherits it" \
    "${probe_src}" '^export LC_ALL LANG$'
  hide_intel_gpu_top
  seed_power_baseline 90.00 0
  # A comma-decimal locale the box actually has, if it has one: the pin is what
  # makes the output the same either way, and a value that got through with a
  # comma is a scrape error for all four series, not for one row.
  comma_locale="$(locale -a 2>/dev/null | grep -i -m 1 'de_DE\|fr_FR' || true)"
  if [[ -n ${comma_locale} ]]; then
    export LC_ALL="${comma_locale}" LC_NUMERIC="${comma_locale}" LANG="${comma_locale}"
  fi
  run_sampler
  [ "${status}" -eq 0 ]
  # Comments carry prose and prose carries commas: only a sample line can hold a
  # number, so only a sample line is checked.
  run env LC_ALL=C grep -n '^[^#].*,' "${FX_TEXTFILE}/host_gpu.prom"
  [ "${status}" -ne 0 ]
  assert_eq "the utilisation row is still a dot decimal" "75.00" \
    "$(prom_value evo_t1_host_gpu_utilisation_pct)"
}

@test "units: emit_metric writes the label set verbatim and drops a value it cannot name" {
  load_shell_function "${PROBE}" note
  load_shell_function "${PROBE}" is_prom_float
  load_shell_function "${PROBE}" emit_metric
  BUILD_FILE="${BATS_TEST_TMPDIR?}/labelled.prom"
  METRIC_COUNT=0
  : >"${BUILD_FILE}"
  local spoken="${BATS_TEST_TMPDIR}/spoken.txt"
  emit_metric evo_t1_host_gpu_utilisation_pct "Busy ratio." "75.00" "no source" 'source="freq_ratio"' >"${spoken}" 2>&1
  emit_metric evo_t1_host_gpu_clock_mhz "MHz." "75,00" "no knob" 'source="freq_ratio"' >>"${spoken}" 2>&1
  assert_eq "the good gauge counted" "1" "${METRIC_COUNT}"
  assert_contains_file "the sample carries its labels" "${BUILD_FILE}" \
    '^evo_t1_host_gpu_utilisation_pct\{source="freq_ratio"\} 75\.00$'
  assert_contains_file "its TYPE is unlabelled, as the format wants" "${BUILD_FILE}" \
    '^# TYPE evo_t1_host_gpu_utilisation_pct gauge$'
  assert_not_match "the comma value never reached the file" \
    'evo_t1_host_gpu_clock_mhz' "$(cat "${BUILD_FILE}")"
  assert_match "and the run said why in its own vocabulary" \
    'is not a Prometheus float' "$(cat "${spoken}")"
}

@test "run_gpu_top: with no timeout available it refuses to exec the binary at all" {
  # The stub records that it ran rather than hanging, so this proves the guard
  # without the case itself needing a clock: an unbounded exec would leave the
  # marker behind and the assertion below would be the one that goes red.
  mkdir -p "${FX_BIN}"
  export STUB_MARKER="${BATS_TEST_TMPDIR?}/ran"
  cat >"${FX_BIN}/intel_gpu_top" <<'STUB'
#!/bin/sh
printf ran >"${STUB_MARKER}"
printf '{"Engines":{"Render/3D/0":{"busy":9.0}}}\n'
STUB
  chmod 755 "${FX_BIN}/intel_gpu_top"
  load_shell_function "${PROBE}" run_gpu_top
  load_shell_function "${PROBE}" gpu_top_binary
  load_shell_function "${PROBE}" looks_like_json
  export HOST_GPU_INTEL_GPU_TOP="${FX_BIN}/intel_gpu_top"
  # The loaded body reads these from the file's own top level, which a function
  # loaded on its own never gets.
  TOP_CAP=2
  TOP_SAMPLE_MS=10
  # A subshell, so the emptied PATH cannot follow this case into the next one. The
  # stub is reached by absolute path, so the only PATH lookup left is the guard's.
  local out
  out="$(PATH=/nonexistent run_gpu_top 2>/dev/null)"
  assert_eq "an unbounded read is refused, so nothing came back" "" "${out}"
  assert_file_not_exists "and the binary was never exec'd" "${STUB_MARKER}"
  out="$(run_gpu_top)"
  assert_match "with timeout present it does run and answer" '9' "${out}"
}
