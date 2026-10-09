#!/usr/bin/env bats
#
# ## spark-configure.bats — unit coverage for scripts/lib/spark.sh
#
# Entry-script cases for spark-configure.sh are added beside these lib cases.
# Hermetic: curl, ssh, and timeout resolve through tests/bats/tool_stubs.
# Usage: bats tests/bats/spark-configure.bats
# Safety: no daemon, no network, no Spark box.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs timeout curl ssh
}

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/spark.sh"
}

@test "spark: derive_spark_hosts honours the SPARK_HOSTS environment override" {
  source_libs
  SPARK_HOSTS="h1 h2"
  derive_spark_hosts "${BATS_TEST_TMPDIR}/.env"
  [ "${SPARK_HOSTS_SOURCE}" = "env" ]
  [ "${SPARK_HOSTS_RESOLVED}" = "h1 h2" ]
}

@test "spark: derive_spark_hosts derives and dedupes hosts from .env" {
  source_libs
  printf '%s\n' 'SPARK1_OLLAMA_URL="http://10.9.8.7:11434"' 'SPARK2_OLLAMA_URL=http://10.9.8.7:11434' 'SPARK1_OPENAI_URL=http://10.9.8.6:4000/v1' > "${BATS_TEST_TMPDIR}/.env"
  derive_spark_hosts "${BATS_TEST_TMPDIR}/.env"
  [ "${SPARK_HOSTS_SOURCE}" = "derived" ]
  [ "${SPARK_HOSTS_RESOLVED}" = "10.9.8.7 10.9.8.6" ]
}

@test "spark: derive_spark_hosts falls back to the placeholder trio" {
  source_libs
  derive_spark_hosts "${BATS_TEST_TMPDIR}/.env"
  [ "${SPARK_HOSTS_SOURCE}" = "default" ]
  [ "${SPARK_HOSTS_RESOLVED}" = "spark-1.lan spark-2.lan spark-3.lan" ]
}

@test "spark: probe_http treats an unanswered probe as empty, not as a pass" {
  source_libs
  x="$(probe_http 8 "http://10.255.255.1:11434/version")"
  [ -z "${x}" ]
  [[ "$(stub_log_last timeout)" == timeout* ]]
}

@test "spark: probe_http passes an answering body through" {
  source_libs
  export STUB_CURL_OUT="DGX Spark GB10"
  x="$(probe_http 8 "http://10.0.0.9:11434/version")"
  [ "${x}" = "DGX Spark GB10" ]
}

@test "spark: probe_transport ferries one base64 script, capped and quoted" {
  source_libs
  export STUB_SSH_EXEC=1
  payload="$(printf '%s' 'echo reported: 424242' | base64 | tr -d '\n')"
  probe_transport 30 22 "spark-1@10.0.0.1" "${payload}" > "${BATS_TEST_TMPDIR}/got"
  grep -qx "reported: 424242" "${BATS_TEST_TMPDIR}/got"
  [[ "$(stub_log_last timeout)" == "timeout 30 ssh -n "*"-p 22 -- spark-1@10.0.0.1 "* ]]
  [[ "$(stub_log_last ssh)" == *"base64 -d | sh"* ]]
}

