#!/usr/bin/env bats
#
# ## spark-monitor.bats - hermetic coverage for scripts/spark-monitor.sh and its
# remote half, scripts/lib/probes/spark-monitor.sh.
#
# Two contracts are pinned here. The CLI's is the operator's safety guarantee: plan
# is the default and opens no ssh session and starts no container, --apply is the
# only flag that mutates a box with --restart the one other mutator, --targets only
# prints, --status turns the probe's KEY=value lines into the table with `absent`
# meaning unmeasured and 0 meaning measured, a box that refuses ssh is a warning
# with exit 0, and only a failed mutator exits non-zero. The probe's is its own
# promise: twelve keys in one order, one line each, exit 0 on every path, zero bytes
# on stderr, including the path where the box has nothing installed.
#
# Nothing here dials a host: ssh, docker, curl, timeout and hostname all resolve
# through tests/bats/tool_stubs, the CLI runs inside a scratch checkout whose .env
# the test writes, and the probe body runs under sh against those same stubs.
#
# Usage: bazelisk test //tests:bats_spark_monitor_test   (from any cwd)
# Safety: stub only. No daemon, no network, no ssh session, and no read of the real
# checkout's .env.

# bats assigns output and stderr through run, calls the stub functions the cases
# below define, and gives every @test its own subshell.
# shellcheck disable=SC2154,SC2030,SC2031,SC2317
bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

CHECKOUT=""
SCRIPT=""
PROBE=""
SCRATCH=""

setup() {
  CHECKOUT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${CHECKOUT}/scripts/spark-monitor.sh"
  PROBE="${CHECKOUT}/scripts/lib/probes/spark-monitor.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/spark-monitor.sh is not in the tree"
  [[ -f ${PROBE} ]] || skip "scripts/lib/probes/spark-monitor.sh is not in the tree"
  use_stubs docker ssh curl timeout hostname
  SCRATCH="$(scratch_checkout)"
  # resolve_checkout honours REPO_ROOT, so the CLI reads .env, the probe payload and
  # the counter list out of this scratch tree and never out of the real checkout.
  export REPO_ROOT="${SCRATCH}"
  export SPARK_SSH_USER=ops
  export SPARK1_HOST=alpha.test SPARK2_HOST=beta.test SPARK3_HOST=""
  export SPARK_MONITOR_ENABLED=true
  unset SPARK_HOSTS JSON_MODE STUB_SSH_RC STUB_SSH_OUT STUB_SSH_EXEC
  unset SPARK_NODE_EXPORTER_PORT SPARK_DCGM_EXPORTER_PORT
  unset SPARK_DCGM_EXPORTER_IMAGE STUB_COMPOSE_PS
}

# scratch_checkout - a directory resolve_checkout accepts as the checkout, holding
# the two files the CLI cats by relative path: the probe body it ferries and the
# DCGM counter list it mounts. No .env: an absent key must fall to the shipped
# default, and the tests that want one write it into this tree.
scratch_checkout() {
  local scratch
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/scripts/lib/probes" "${scratch}/observability/dcgm"
  printf 'services: {}\n' >"${scratch}/docker-compose.yml"
  cp "${PROBE}" "${scratch}/scripts/lib/probes/spark-monitor.sh"
  printf '%s\n' 'DCGM_FI_DEV_GPU_UTIL, gauge, util, GPU utilization' \
    'DCGM_FI_DEV_FB_USED, gauge, fb_used, Frame buffer used' >"${scratch}/observability/dcgm/custom-counters.csv"
  printf '%s' "${scratch}"
}

# run_cli <flag...> - run the CLI against the scratch checkout with the stub PATH,
# keeping the narration and the document on one stream.
run_cli() {
  run bash "${SCRIPT}" "$@"
}

# run_cli_only <flag...> - the same run with stdout alone in ${output}: the shape
# --json and --targets promise, so the parse sees the document and nothing else.
run_cli_only() {
  run --separate-stderr bash "${SCRIPT}" "$@"
}

# load_probe_fn <function> - load one function out of the POSIX probe into this
# bash, the way entry-fns.bats loads one out of an entry script.
load_probe_fn() {
  load_shell_function "${PROBE}" "$1"
}

# bare_bin - print a directory holding only the tools the probe needs when the box
# has no docker, no curl, no wget and no nvidia-smi: stripping whole PATH
# directories would take sh, grep and cut with them, so the absent-tool case is
# built by handing the probe a PATH of its own instead.
bare_bin() {
  local dir tool
  dir="${BATS_TEST_TMPDIR?}/bare"
  mkdir -p "${dir}"
  cp "${STUB_BIN_DIR?}/hostname" "${dir}/hostname"
  for tool in sh bash uname head cut tr grep sed sort tail; do
    if command -v "${tool}" >/dev/null 2>&1; then
      cp "$(command -v "${tool}")" "${dir}/${tool}"
      chmod 755 "${dir}/${tool}"
    fi
  done
  printf '%s' "${dir}"
}

# -- the probe: its twelve keys, its exit code, its silence ------------------

@test "probe: a box with nothing installed prints all twelve keys, exits 0, and writes nothing to stderr" {
  local bare keys expected
  bare="$(bare_bin)"
  run --separate-stderr env PATH="${bare}" STUB_HOSTNAME=sparkbox9 sh "${PROBE}"
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
  expected="$(printf '%s\n' probe_version spark_host docker_available node_exporter_running \
    node_exporter_port node_exporter_image dcgm_running dcgm_port dcgm_image \
    dcgm_counter_count gpu_count gpu_names)"
  keys="$(printf '%s\n' "${output}" | cut -d= -f1)"
  [[ ${keys} == "${expected}" ]]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 12 ]
  assert_match "an absent tool is an answer, not an abort" '^docker_available=absent$' "${output}"
  assert_match "an unmeasured exporter is the sentinel, never empty" '^node_exporter_running=absent$' "${output}"
  assert_match "an unmeasured counter set is the sentinel too" '^dcgm_counter_count=absent$' "${output}"
  assert_not_match "no value carries a space" '=[^ ]* ' "${output}"
}

@test "probe: exporters found by image answer running and count their counters" {
  # exporter_cid greps the image column for " <name>", so the fixture carries the
  # tag form that matcher can reach.
  local ps_file counters
  ps_file="${BATS_TEST_TMPDIR}/ps.txt"
  printf '%s\n' 'i1 node-exporter:v1.12.1' \
    'i2 dcgm-exporter:4.4.2-4.7.0-ubuntu22.04' >"${ps_file}"
  counters="$(printf '%s\n' 'DCGM_FI_DEV_GPU_UTIL, gauge, util' \
    'DCGM_FI_DEV_FB_USED, gauge, fb' 'DCGM_FI_DEV_GPU_UTIL, gauge, dup')"
  run --separate-stderr env STUB_HOSTNAME=sparkbox9 STUB_COMPOSE_PS="${ps_file}" \
    STUB_DOCKER_EXEC_RUN=0 STUB_DOCKER_EXEC_OUT="${counters}" sh "${PROBE}"
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
  assert_match "the host name is the box's own" '^spark_host=sparkbox9$' "${output}"
  assert_match "docker answers present" '^docker_available=present$' "${output}"
  assert_match "node_exporter matched by image is running" '^node_exporter_running=running$' "${output}"
  assert_match "dcgm matched by image is running" '^dcgm_running=running$' "${output}"
  # The port and the tag are exporter_port's and exporter_image's own cases: the
  # shared docker stub answers no inspect format, so this run proves discovery by
  # image and the counter set, and those two cases drive inspect themselves.
  assert_match "the counter set counts distinct DCGM_FI_ names" '^dcgm_counter_count=2$' "${output}"
}

@test "probe: gpu_count=0 is a measurement, not the absent sentinel" {
  local smi
  smi="${BATS_TEST_TMPDIR}/bin/nvidia-smi"
  printf '#!/bin/sh\nexit 0\n' >"${smi}"
  chmod 755 "${smi}"
  run --separate-stderr env STUB_HOSTNAME=sparkbox9 sh "${PROBE}"
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
  assert_match "a box that answers with no device reports 0" '^gpu_count=0$' "${output}"
  assert_match "and still no model names" '^gpu_names=absent$' "${output}"
}

@test "probe: gpu_names joins the models with + because a value may not hold a space" {
  local smi
  smi="${BATS_TEST_TMPDIR}/bin/nvidia-smi"
  printf '#!/bin/sh\nprintf "%%s\\n" "NVIDIA GB200" "NVIDIA GB300"\n' >"${smi}"
  chmod 755 "${smi}"
  run --separate-stderr env STUB_HOSTNAME=sparkbox9 sh "${PROBE}"
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
  assert_match "two lines are two GPUs" '^gpu_count=2$' "${output}"
  assert_match "the models join on +" '^gpu_names=NVIDIA\+GB200\+NVIDIA\+GB300$' "${output}"
}

# -- the probe's helpers, each driven with a stubbed environment --------------

@test "probe: say_key sanitises one value onto one line and defaults it to absent" {
  load_probe_fn say_key
  [[ "$(say_key gpu_names 'NVIDIA GB200')" == "gpu_names=NVIDIAGB200" ]]
  [[ "$(say_key dcgm_port '')" == "dcgm_port=absent" ]]
  [[ "$(say_key dcgm_port)" == "dcgm_port=absent" ]]
  [[ "$(say_key probe_version 1)" == "probe_version=1" ]]
}

@test "probe: docker_run keeps the daemon's complaint off the ssh channel" {
  local err_file
  load_probe_fn docker_run
  err_file="${BATS_TEST_TMPDIR}/docker-stderr"
  docker() {
    printf 'Error: No such image: nope\n' >&2
    printf 'stdout-survives\n'
    return 1
  }
  [[ "$(docker_run ps 2>"${err_file}")" == "stdout-survives" ]]
  [ ! -s "${err_file}" ]
}

@test "probe: exporter_cid matches on the image and keeps the newest match" {
  load_probe_fn docker_run
  load_probe_fn exporter_cid
  # The matcher is grep " <name>" over the "id image" line, so it reaches the tag
  # form of a name, not one namespaced behind a slash; the fixture is that form.
  docker() {
    printf '%s\n' 'i1 node-exporter:v1.12.1' \
      'i2 dcgm-exporter:4.4.2-4.7.0-ubuntu22.04' \
      'i3 node-exporter:v1.12.1'
  }
  [[ "$(exporter_cid node-exporter)" == "i3" ]]
  [[ "$(exporter_cid dcgm-exporter)" == "i2" ]]
  [[ -z "$(exporter_cid cadvisor)" ]]
}

@test "probe: exporter_port takes the published port and falls back to the exposed one" {
  load_probe_fn docker_run
  load_probe_fn exporter_port
  docker() {
    case "${3:-}" in
      *NetworkSettings.Ports*) printf '%s\n' '9400 ' ;;
      *Config.ExposedPorts*) printf '%s\n' '' ;;
    esac
  }
  [[ "$(exporter_port abc123)" == "9400" ]]
  docker() {
    case "${3:-}" in
      *NetworkSettings.Ports*) printf '%s\n' ' ' ;;
      *Config.ExposedPorts*) printf '%s\n' '9100/tcp ' ;;
    esac
  }
  [[ "$(exporter_port abc123)" == "9100" ]]
  [[ -z "$(exporter_port '')" ]]
}

@test "probe: exporter_image prints the image the container was created from" {
  load_probe_fn docker_run
  load_probe_fn exporter_image
  docker() {
    case "${3:-}" in
      *Config.Image*) printf '%s\n' 'nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04' ;;
    esac
  }
  [[ "$(exporter_image abc123)" == "nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-ubuntu22.04" ]]
  [[ -z "$(exporter_image '')" ]]
}

@test "probe: http_metrics returns one scrape body and nothing when nothing answers" {
  load_probe_fn http_metrics
  wget() { return 1; }
  export STUB_CURL_OUT='DCGM_FI_DEV_GPU_UTIL{gpu="0"} 42'
  [[ "$(http_metrics 'http://127.0.0.1:9400/metrics')" == 'DCGM_FI_DEV_GPU_UTIL{gpu="0"} 42' ]]
  unset STUB_CURL_OUT
  [[ -z "$(http_metrics 'http://127.0.0.1:9400/metrics')" ]]
}

@test "probe: counter_names counts distinct DCGM_FI_ names and ignores the dcgm_ spelling" {
  load_probe_fn counter_names
  local body
  body="$(printf '%s\n' 'DCGM_FI_DEV_GPU_UTIL 1' 'DCGM_FI_DEV_FB_USED 5' \
    'DCGM_FI_DEV_GPU_UTIL 2' 'dcgm_fi_dev_gpu_util 9')"
  [[ "$(counter_names "${body}")" == "2" ]]
  [[ -z "$(counter_names 'nothing here')" ]]
  [[ -z "$(counter_names '')" ]]
}

# -- the CLI: plan is the default and touches nothing ------------------------

@test "cli: the default plan opens no ssh session and starts no container" {
  run_cli
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_count ssh)" == "0" ]]
  [[ "$(stub_log_count docker)" == "0" ]]
  assert_match "the run names itself read-only" 'read-only: this run opens no ssh session' "${output}"
  assert_match "every box gets a section" '^== box spark-1 \(alpha\.test\) ==$' "${output}"
  assert_match "a plan states that nothing was measured" \
    'opens no ssh session, so whether either exporter runs here is unknown' "${output}"
}

@test "cli: the plan prints both pinned images and the scrape pair for each box" {
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "node_exporter's pin is the verified tag" 'quay\.io/prometheus/node-exporter:v1\.12\.1' "${output}"
  assert_match "dcgm's pin is the corrected tag" 'nvcr\.io/nvidia/k8s/dcgm-exporter:4\.4\.2-4\.7\.0-ubuntu22\.04' "${output}"
  assert_match "the node scrape pair names the default port" 'alpha\.test:9100' "${output}"
  assert_match "the dcgm scrape pair names the default port" 'alpha\.test:9400' "${output}"
  assert_match "the ferried node run pins the port" '\-\-web\.listen-address=:9100' "${output}"
  assert_match "node_exporter gets the processes collector" '\-\-collector\.processes' "${output}"
}

@test "cli: the fleet comes from the environment, never from a committed hostname" {
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "the host this test exported is the host the plan names" \
    '^ok: alpha\.test: scrape pair is alpha\.test:9100' "${output}"
  assert_match "and so is the second" '^ok: beta\.test: scrape pair is beta\.test:9100' "${output}"
  assert_not_match "the placeholder trio is not used when the env names the fleet" 'spark-1\.lan' "${output}"
  assert_match "the run says where the fleet came from" \
    'fleet taken from SPARK_HOSTS in the process environment' "${output}"
}

@test "cli: --dry-run is the plan and still opens no ssh session" {
  run_cli --dry-run
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_count ssh)" == "0" ]]
  [[ "$(stub_log_count docker)" == "0" ]]
  assert_match "the plan is still printed" '^== box spark-2 \(beta\.test\) ==$' "${output}"
}

@test "cli: setting_value reads the .env keys the CLI documents" {
  printf '%s\n' 'SPARK_NODE_EXPORTER_PORT=9111' 'SPARK_DCGM_EXPORTER_PORT=9411' \
    'SPARK_DCGM_EXPORTER_IMAGE=registry.invalid/dcgm-exporter:pinned' \
    'SPARK_MONITOR_ENABLED=true' 'SPARK1_HOST=gamma.test' 'SPARK2_HOST=' 'SPARK3_HOST=' \
    >"${SCRATCH}/.env"
  unset SPARK1_HOST SPARK2_HOST SPARK3_HOST
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "the port from .env is the port the plan prints" 'gamma\.test:9111' "${output}"
  assert_match "the dcgm port from .env is the port the plan prints" 'gamma\.test:9411' "${output}"
  assert_match "the image from .env is the image the plan ferries" \
    'registry\.invalid/dcgm-exporter:pinned' "${output}"
  assert_match "the fleet came from the .env keys" \
    'fleet taken from the SPARKn_HOST .*keys in \.env' "${output}"
  assert_not_match "a box .env leaves empty is not in the fleet" 'beta\.test' "${output}"
}

@test "cli: setting_value lets the process environment outrank .env" {
  printf '%s\n' 'SPARK_NODE_EXPORTER_PORT=9111' >"${SCRATCH}/.env"
  export SPARK_NODE_EXPORTER_PORT=9122
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "the exported port wins" 'alpha\.test:9122' "${output}"
  assert_not_match "the .env port loses" 'alpha\.test:9111' "${output}"
}

@test "cli: a port that is not a number is refused before any box is named" {
  export SPARK_DCGM_EXPORTER_PORT=notaport
  run_cli
  [ "${status}" -ne 0 ]
  assert_match "the refusal names the key" 'SPARK_DCGM_EXPORTER_PORT' "${output}"
  assert_match "and says the value is not a port number" \
    "notaport' is not a port number" "${output}"
  [[ "$(stub_log_count ssh)" == "0" ]]
}

@test "cli: setting_value falls back to the shipped pin when the image key is empty" {
  local body
  export SPARK_DCGM_EXPORTER_IMAGE=""
  run_cli_only --json
  [ "${status}" -eq 0 ]
  body="${output}"
  assert_match "an empty value reads as unset and the pin answers" \
    '"dcgm_exporter_image":"nvcr\.io/nvidia/k8s/dcgm-exporter:4\.4\.2-4\.7\.0-ubuntu22\.04"' "${body}"
}

@test "cli: --targets prints the sparks.json document and writes no file" {
  local body
  run_cli_only --targets
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_count ssh)" == "0" ]]
  body="${output}"
  printf '%s\n' "${body}" >"${BATS_TEST_TMPDIR}/targets.json"
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if len(d) == 4 else 1)' \
    "${BATS_TEST_TMPDIR}/targets.json"
  [ "${status}" -eq 0 ]
  assert_match "the node group is there" '"targets":\["alpha\.test:9100"\]' "${body}"
  assert_match "the dcgm group is there" '"targets":\["beta\.test:9400"\]' "${body}"
  assert_match "each group carries its box label" '"box":"spark-2","exporter":"dcgm"' "${body}"
  [ ! -e "${SCRATCH}/observability/spark-targets/sparks.json" ]
}

@test "cli: --targets with the gate off prints the empty target set" {
  export SPARK_MONITOR_ENABLED=false
  run_cli_only --targets
  [ "${status}" -eq 0 ]
  [[ ${output} == "[]" ]]
  assert_match "and says why" \
    "SPARK_MONITOR_ENABLED is 'false', so this is the empty target set" "${stderr}"
}

@test "cli: --json keeps stdout to one object that python can load" {
  local body
  run_cli_only --json
  [ "${status}" -eq 0 ]
  body="${output}"
  printf '%s\n' "${body}" >"${BATS_TEST_TMPDIR}/plan.json"
  run python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
    "${BATS_TEST_TMPDIR}/plan.json"
  [ "${status}" -eq 0 ]
  assert_match "the mode is in the document" '"mode":"plan"' "${body}"
  assert_match "the node pin is in the document" \
    '"node_exporter_image":"quay\.io/prometheus/node-exporter:v1\.12\.1"' "${body}"
  assert_match "the summary is in the document" '"summary":\{' "${body}"
  [[ "$(stub_log_count ssh)" == "0" ]]
}

@test "cli: --box restricts the run to one box of the resolved fleet" {
  run_cli --box 2
  [ "${status}" -eq 0 ]
  assert_match "the chosen box is named" '^== box spark-2 \(beta\.test\) ==$' "${output}"
  assert_not_match "the other box is not visited" '^== box spark-1 \(alpha\.test\) ==$' "${output}"
  [[ "$(stub_log_count ssh)" == "0" ]]
}

@test "cli: --box outside the fleet is refused with the fleet it resolved" {
  run_cli --box 9
  [ "${status}" -ne 0 ]
  assert_match "the refusal lists what exists" '\-\-box 9: the resolved fleet has 2 box\(es\)' "${output}"
}

@test "cli: --help names the flags and the .env keys the CLI reads" {
  run_cli --help
  [ "${status}" -eq 0 ]
  assert_match "usage names --apply" '\-\-apply' "${output}"
  assert_match "usage names --status" '\-\-status' "${output}"
  assert_match "usage names the node port key" 'SPARK_NODE_EXPORTER_PORT' "${output}"
  assert_match "usage names the dcgm port key" 'SPARK_DCGM_EXPORTER_PORT' "${output}"
  assert_match "usage names the dcgm image key" 'SPARK_DCGM_EXPORTER_IMAGE' "${output}"
  assert_match "usage names the gate key" 'SPARK_MONITOR_ENABLED' "${output}"
  [[ "$(stub_log_count ssh)" == "0" ]]
}

@test "cli: two modes at once, an unknown flag, and a host argument are all refused" {
  run_cli --status --apply
  [ "${status}" -ne 0 ]
  assert_match "the refusal says pick one mode" \
    'cannot be combined with \-\-status; pick one mode' "${output}"
  run_cli --nope
  [ "${status}" -ne 0 ]
  assert_match "an unknown option is refused" "unknown option '\-\-nope'" "${output}"
  run_cli 10.0.0.1
  [ "${status}" -ne 0 ]
  assert_match "a host argument is refused, the fleet is env-derived" \
    'this CLI takes no host arguments' "${output}"
  run_cli --box
  [ "${status}" -ne 0 ]
  assert_match "--box needs a value" '\-\-box needs a box number' "${output}"
  [[ "$(stub_log_count ssh)" == "0" ]]
}

# -- the CLI: the probe report parsed into the table -------------------------

@test "cli: --status ferries the probe over exactly one ssh per box" {
  run_cli --status
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_count ssh)" == "2" ]]
  [[ "$(stub_log_count docker)" == "0" ]]
  assert_match "the transport is BatchMode" 'BatchMode=yes' "$(stub_log_last ssh)"
  assert_match "the payload travels base64-encoded as one quoted command" \
    '\| base64 \-d \| sh' "$(stub_log_last ssh)"
  assert_match "the target carries the ssh user" 'ops@beta\.test' "$(stub_log_last ssh)"
  assert_match "the run says it changes nothing" \
    'the probe runs on each box over ssh and changes nothing' "${output}"
}

@test "cli: --status reads the absent sentinel as unmeasured and stays at exit 0" {
  export STUB_SSH_EXEC=1
  run_cli --status --box 1
  [ "${status}" -eq 0 ]
  assert_match "the probe version the box answered" 'probe version 1, docker available' "${output}"
  assert_match "an absent node_exporter is a warning with the fix spelled out" \
    'warning: alpha\.test: node_exporter is absent' "${output}"
  assert_match "an absent dcgm exporter is a warning too" \
    'warning: alpha\.test: DCGM exporter is absent' "${output}"
  assert_match "an unmeasured gpu count is said as unmeasured" \
    'the probe reported no GPU count' "${output}"
  assert_match "the run still closes with a summary" \
    '^summary: [0-9]* ok, [0-9]* warnings, 0 failed' "${output}"
  [[ "$(stub_log_count ssh)" == "1" ]]
}

@test "cli: --status prints what the box runs, including a tag that drifted from the pin" {
  local report
  report="${BATS_TEST_TMPDIR}/report"
  printf '%s\n' 'probe_version=1' 'spark_host=alpha' 'docker_available=present' \
    'node_exporter_running=running' 'node_exporter_port=9100' \
    'node_exporter_image=quay.io/prometheus/node-exporter:v1.12.1' \
    'dcgm_running=running' 'dcgm_port=9400' \
    'dcgm_image=nvcr.io/nvidia/k8s/dcgm-exporter:4.3.0-4.7.0-ubuntu22.04' \
    'dcgm_counter_count=18' 'gpu_count=0' 'gpu_names=absent' >"${report}"
  export STUB_SSH_OUT="${report}"
  run_cli --status --box 1
  [ "${status}" -eq 0 ]
  assert_match "the running node_exporter is an ok with its port and tag" \
    'ok: alpha\.test: node_exporter is running on :9100 \(quay\.io/prometheus/node-exporter:v1\.12\.1\)' "${output}"
  assert_match "the running dcgm exporter is an ok with its tag" \
    'ok: alpha\.test: DCGM exporter is running on :9400, tag nvcr\.io/nvidia/k8s/dcgm-exporter:4\.3\.0-4\.7\.0-ubuntu22\.04' "${output}"
  assert_match "the counters and the gpu count are noted" \
    'DCGM counters 18, GPUs 0 \(absent\)' "${output}"
  assert_match "a tag off the pin is reported as drift" \
    'the running tag is not the pin this CLI would install' "${output}"
  # 0 is a measurement: the CLI has to say so, not fold it into unmeasured.
  assert_match "gpu_count 0 is read as measured-zero" 'the probe measured 0 GPUs' "${output}"
  [[ "$(stub_log_count docker)" == "0" ]]
}

@test "cli: --status reports a probe that answers with fewer than twelve keys" {
  local report
  report="${BATS_TEST_TMPDIR}/short"
  printf '%s\n' 'probe_version=1' 'spark_host=alpha' 'docker_available=present' \
    'node_exporter_running=absent' 'node_exporter_port=absent' \
    'node_exporter_image=absent' 'dcgm_running=absent' 'dcgm_port=absent' \
    'dcgm_image=absent' 'gpu_count=absent' 'gpu_names=absent' >"${report}"
  export STUB_SSH_OUT="${report}"
  run_cli --status --box 1
  [ "${status}" -eq 0 ]
  assert_match "the missing key is named" 'missing dcgm_counter_count' "${output}"
  assert_match "and the cause is named" 'older than this CLI' "${output}"
}

@test "cli: a box that refuses ssh is a warning and a zero exit, not a crash" {
  export STUB_SSH_RC=255
  run_cli --status --box 1
  [ "${status}" -eq 0 ]
  assert_match "ssh's own complaint is quoted" 'no probe report \(ssh: stub failure\)' "${output}"
  assert_match "a not-yet box is called what it is" 'not-yet state, not a failure' "${output}"
  assert_match "the summary reports no failure" \
    '^summary: [0-9]* ok, [0-9]* warnings, 0 failed' "${output}"
}

@test "cli: --status --json still parses when the box never answered" {
  local body
  export STUB_SSH_RC=255
  run_cli_only --status --json --box 1
  body="${output}"
  printf '%s\n' "${body}" >"${BATS_TEST_TMPDIR}/dead.json"
  run python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
    "${BATS_TEST_TMPDIR}/dead.json"
  [ "${status}" -eq 0 ]
  assert_match "the unreachable box is still in the document" '"verdict":"unreachable"' "${body}"
}

# -- the CLI: the two mutators -------------------------------------------------

@test "cli: --apply is the mutator that fails loudly when a box cannot be reached" {
  export STUB_SSH_RC=255
  run_cli --apply --box 1
  [ "${status}" -ne 0 ]
  assert_match "a mutator that could not run is an error, not a warning" \
    'error: alpha\.test: \-\-apply could not run over ssh' "${output}"
  assert_match "the failure is counted" \
    '^summary: [0-9]* ok, [0-9]* warnings, 1 failed' "${output}"
  [[ "$(stub_log_count ssh)" == "1" ]]
  [[ "$(stub_log_count docker)" == "0" ]]
}

@test "cli: --apply on a box without docker fails rather than claiming containers" {
  # The report the remote half prints when the box has no docker on PATH, canned
  # here so the case is deterministic instead of dependent on this test host.
  local report
  report="${BATS_TEST_TMPDIR}/nodocker"
  printf '%s\n' 'docker=absent' 'apply.node_exporter=skipped' 'apply.dcgm=skipped' \
    'reason.docker=docker is not on PATH on this box' 'apply_end' >"${report}"
  export STUB_SSH_OUT="${report}"
  run_cli --apply --box 1
  [ "${status}" -ne 0 ]
  assert_match "the box's own docker=absent answer is what decided it" \
    'docker is not on PATH' "${output}"
  assert_match "the run says it is the only mode that mutates" \
    'this is the only mode that mutates a Spark' "${output}"
  [[ "$(stub_log_count docker)" == "0" ]]
}

@test "cli: --restart is the other mutator and fails the same way" {
  export STUB_SSH_RC=255
  run_cli --restart --box 1
  [ "${status}" -ne 0 ]
  assert_match "a restart that could not run is an error" \
    'error: alpha\.test: \-\-restart could not run over ssh' "${output}"
  assert_match "the phase names both containers" \
    'docker restart spark-node-exporter spark-dcgm-exporter' "${output}"
  [[ "$(stub_log_count ssh)" == "1" ]]
}

@test "cli: no flag other than --apply and --restart can produce a non-zero exit" {
  export STUB_SSH_RC=255
  run_cli --box 1
  [ "${status}" -eq 0 ]
  run_cli --status --box 1
  [ "${status}" -eq 0 ]
  run_cli --targets
  [ "${status}" -eq 0 ]
  run_cli --json --box 1
  [ "${status}" -eq 0 ]
}
