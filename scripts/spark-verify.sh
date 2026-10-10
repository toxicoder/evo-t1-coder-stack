#!/usr/bin/env bash
# spark-verify.sh — READ-ONLY fleet check for the three Qwen3.8-Flash-Next Sparks. It is
# the other half of scripts/spark-configure.sh: that script asserts the setup and, with
# --apply, writes the per-host override file; this one proves that the fleet still
# agrees with itself and that each box can actually serve at the settings the fleet
# routes to.
#
# Usage:
#   ./scripts/spark-verify.sh                              # assert-only, the fleet named in .env
#   ./scripts/spark-verify.sh spark-1.lan                  # assert-only, one host
#   ./scripts/spark-verify.sh --json                       # one JSON object per host
#   ./scripts/spark-verify.sh --no-tests <host>            # skip the recipe's own probes
#   VISION=1 ./scripts/spark-verify.sh <host>               # also run visioncheck.py
#   SPARK_HOSTS="host1 host2" ./scripts/spark-verify.sh    # process env; overrides the .env-derived fleet
#
# Callable on its own and callable from scripts/bootstrap.sh, which runs it with
# --no-tests as its last step. Nothing here writes to a Spark and nothing here starts or
# restarts a server: the only files this creates are sparks/<host>.jsonl inside this
# repo, and the recipe probes below are read-only calls against a server that is already
# running (the four of them still occupy streams, which is why they are opt-out).
#
# WHAT EVERY BOX HAS TO ANSWER, and why the spelling of the first one is a check:
#   1. GET http://<host>:8888/v1/models must answer with EXACTLY the id
#      "Qwen3.8-Flash-Next" — case and hyphens matter. LiteLLM sends the `model` field
#      to the backend verbatim, and LiteLLM v1.102.1 builds its Router with
#      ignore_invalid_deployments forced to True (it is not settable from
#      litellm/config.yaml), so a box whose id is spelled even one character differently
#      is dropped from the `agent` model group at boot and then answers curl perfectly
#      well while the proxy calls it "No deployments available" / "deployment
#      unavailable". A wrong id reads as nothing-wrong-with-the-proxy, so it is a
#      failure here and not a note, and it is why the exact spelling is compared across
#      all three boxes as well as against the one id litellm/config.yaml declares.
#   2. GET :8888/health must be green and must show requests_running capacity for
#      ${parallel_want} streams — the "streams": {..., "max": N} object plus the
#      "requests_running" count.
#   3. With a recipe clone on the box, its own four probes, in this order:
#        scripts/toolcheck.py
#        scripts/needle.py --length 195000   the window proof: a 195k needle only fits a
#                                             server whose real max_model_len is the
#                                             262144-token window the fleet expects, so
#                                             this is what catches a box quietly rebuilt
#                                             with a shorter window
#        scripts/visioncheck.py              only when VISION=1
#        scripts/bench.py --suite --seed 1 --jsonl run.jsonl --clients 1,2,4,5
#      --no-tests skips all four. scripts/bootstrap.sh passes it: a 195k prompt plus a
#      1/2/4/5-client sweep costs minutes per box and would stall a re-run of bootstrap
#      on a box that already works.
#   4. Drift, which is the point of this script: model id, served model, PARALLEL and
#      streams.max, the CONTEXT window, the image tag and the KV dtype are collected for
#      every box that answered and compared with each other. Any key that comes back
#      with two different values is a FAIL (exit 1). A mixed fleet — two boxes on
#      tensorfold/decode-native:0.6.1-cu130 and one on another tag, or PARALLEL 5 beside
#      PARALLEL 4 — is exactly what this exists to catch: the three boxes sit behind one
#      `agent` model group whose session pins ride on top of `least-busy` and
#      have no `order:` tier, so a differently-configured box is not shunned:
#      its pinned workspaces keep riding on it and new sessions still land on
#      it, and it answers with a degraded or wrong completion instead of an error.
#
# Unreachable is not a failure. A host that does not answer — no DNS entry (a default
# fleet derived from .env can name placeholder hostnames, which never resolve), no
# route, no ssh credentials, or a box with no server on it — prints WHY and still exits
# 0, because that is a "not yet" state and re-running this script is the recovery path.
# Exit 1 means a box that COULD be reached disagrees with the fleet's contract or with
# one of its peers.
#
# The same object is written to sparks/<host>.jsonl, one per host: gitignored
# generated state holding this run's answer, and printed to stdout with --json as well,
# ## spark-verify.sh — check the Spark fleet against the serving contract
# one object per host, for jq or for a dashboard.

set -euo pipefail

cd "$(dirname "$0")/.."

# @function log
# Print one status line. Spark scripts send it to stderr when --json is set.
# Globals:
#   json (Spark scripts; empty means stdout)
# Arguments:
#   $* - text to print
# Outputs:
#   The text on stdout, or stderr when json is set
# Returns:
#   0
log() {
  # With --json, stdout stays exactly one JSON object per host: every prose line goes to
  # stderr instead, so `spark-verify.sh --json | jq` parses and `2>/dev/null` silences
  # the commentary without losing it.
  if [ -n "${json:-}" ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi
}
# @function die
# Print an error on stderr and exit 1.
# Globals:
#   None
# Arguments:
#   $* - error text, without the "error: " prefix
# Outputs:
#   "error: ..." on stderr
# Returns:
#   Does not return; exits 1
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# The fleet's contract, as facts to CHECK. Nothing here is ever written anywhere: use
# scripts/spark-configure.sh --apply to change what a box actually runs with.
JSON_ESCAPE_SED='s/["\\]/\\&/g' # one sed program, quoted: escape \ and " in one pass
model_id="Qwen3.8-Flash-Next"
parallel_want=5
context_want=262144
container="qwen38-flash-next-tf"
recipe_dir='${HOME}/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'

# The six keys this fleet refuses to run mixed. Everything in the list is a fact that
# changes what a box can serve, not a label, which is why a difference is fatal.
drift_keys="model_id_seen served_name parallel streams_max context_length context_pairs container_image kv_dtype spark1_openai spark2_openai spark3_openai"

json=""
tests=1
ssh_user="${SPARK_SSH_USER:-${LOGNAME:-}}"
ssh_port=22
server_port=8888
http_cap=12
ssh_cap=25
test_cap=900
hosts=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      json=1
      shift
      ;;
    --no-tests)
      tests=""
      shift
      ;;
    --tests)
      tests=1
      shift
      ;;
    --user)
      [ "$#" -ge 2 ] || die "--user needs a value"
      ssh_user="$2"
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || die "--port needs a value"
      server_port="$2"
      shift 2
      ;;
    --recipe-dir)
      [ "$#" -ge 2 ] || die "--recipe-dir needs a value"
      recipe_dir="$2"
      shift 2
      ;;
    --parallel)
      [ "$#" -ge 2 ] || die "--parallel needs a value"
      parallel_want="$2"
      shift 2
      ;;
    --context)
      [ "$#" -ge 2 ] || die "--context needs a value"
      context_want="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs a value"
      ssh_cap="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,66p' "$0"
      exit 0
      ;;
    -*)
      die "unknown option '$1' — usage: ./scripts/spark-verify.sh [options] [host ...] (see --help)"
      ;;
    *)
      hosts+=("$1")
      shift
      ;;
  esac
done

if [ "${#hosts[@]}" -eq 0 ]; then
  if [ -n "${SPARK_HOSTS:-}" ]; then
    # Word-splitting is the point: SPARK_HOSTS is a space-separated list taken from the
    # process environment, and it overrides the .env-derived default below.
    for host in ${SPARK_HOSTS}; do
      hosts+=("${host}")
    done
  else
    # No host list from the caller: check the fleet this checkout already points at.
    # The per-Spark URL keys in .env name its addresses as far as the stack is
    # concerned — LiteLLM routes to the SPARKn_OPENAI_URL ones and the dashboard
    # probes them — so the host part of each (scheme and port stripped, deduplicated)
    # becomes the default list. A .env filled with real Spark IPs therefore gets
    # those boxes checked with nothing to retype; a .env left on the shipped
    # spark-<n>.lan placeholders (or with no Spark URLs at all) still checks the
    # placeholder trio, whose names do not resolve — checked and skipped as a
    # "not yet" state, exactly as before.
    derived_hosts=""
    if [ -f .env ]; then
      for key in SPARK1_OLLAMA_URL SPARK2_OLLAMA_URL SPARK1_OPENAI_URL SPARK2_OPENAI_URL SPARK3_OPENAI_URL; do
        url="$(sed -n "s|^${key}=||p" .env 2>/dev/null | tail -n 1 | sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|' | tr -d ' \r' || true)"
        [ -n "${url}" ] || continue
        host="$(printf '%s' "${url}" | sed -E 's|^https?://||; s|[:/].*$||')"
        case "${host}" in '' | *[!A-Za-z0-9.-]*) continue ;; esac
        case " ${derived_hosts} " in *" ${host} "*) continue ;; esac
        derived_hosts="${derived_hosts} ${host}"
      done
    fi
    if [ -n "${derived_hosts}" ]; then
      log "note: no host given and SPARK_HOSTS is not set or empty — checking the hosts named by the SPARKn_OLLAMA_URL/SPARKn_OPENAI_URL keys in .env:${derived_hosts}"
      for host in ${derived_hosts}; do
        hosts+=("${host}")
      done
    else
      log 'note: no host given and SPARK_HOSTS is not set or empty, and no SPARK*_URL key in .env names a host — checking the placeholder trio spark-1.lan spark-2.lan spark-3.lan, which .env.sample and docker-compose.yml also ship as placeholders. Those names do not resolve: pass your real Spark hostnames or IPs, or set SPARK_HOSTS="host1 host2 ..." in the environment.'
      hosts=("spark-1.lan" "spark-2.lan" "spark-3.lan")
    fi
  fi
fi

# VISION decides whether visioncheck.py runs, not whether the box has a GPU: it is read
# from the process environment, defaulting to the recipe's own VISION=1, so
# `VISION=0 ./scripts/spark-verify.sh` is how you re-check a box you know is text-only.
vision="${VISION:-1}"

# Neither probe needs ssh, so neither waits for it. The boxes may publish :8888
# straight to the LAN, and a box that answers HTTP is a box worth reading even from a
# workstation that has no ssh credentials for it — hence "over ssh when possible, over
# HTTP otherwise", in that order, with the HTTP answers always taken.
if ! command -v curl >/dev/null 2>&1; then
  log "skipped: curl is not on PATH, so no Spark can be probed over HTTP and no recipe probe can be read — nothing was verified"
  exit 0
fi

# timeout(1) is optional, but everything it guards is capped either way: an uncapped
# ssh or curl to a black-holed address hangs until the operating system gives up, which
# is how a fleet check turns into a 40-minute one.
if command -v timeout >/dev/null 2>&1; then
  has_timeout=1
else
  log "note: timeout(1) is not available — the probes below run uncapped, so a Spark that drops packets can stall this run until the operating system times it out"
  has_timeout=""
fi

# One scratch directory per run, one flat remote script per host inside it, and one
# report per host back. Nothing here is a shell argument built out of remote data.
work="$(mktemp -d 2>/dev/null || true)"
[ -n "${work}" ] || die "could not create a scratch directory for the probe scripts"
trap 'rm -f "${work}"/*' EXIT

# first_line: print $1's first non-blank line, so a remote tool's own one-line
# complaint can be quoted without its whole stack trace. The `|| true` is load-bearing:
# pipefail makes an all-blank input abort the caller, and every caller is an assignment
# under `set -e`.
# @function first_line
# Print the first non-blank line of a block of text.
# Globals:
#   None
# Arguments:
#   $1 - text, which may be empty or all blank
# Outputs:
#   That line, or nothing; an all-blank input does not abort the caller
# Returns:
#   0
first_line() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

# report_get / fact_value: read one key out of a per-host key=value file — the probe's
# answer, or the per-host facts gathered from it. An empty answer means "never
# measured" and stays empty on purpose: every comparison below treats that as an
# absence, never as a match, which is the difference between "this box was not checked"
# and "this box agrees with the other two". Read with sed and never sourced, so a
# truncated or hostile answer cannot name a variable and supply the command filling it.
# @function report_get
# Read one key from a key=value report. Empty and NOTSET use the fallback.
# Globals:
#   None
# Arguments:
#   $1 - key; $2 - report file; $3 - fallback, optional
# Outputs:
#   The value or the fallback
# Returns:
#   0
report_get() {
  local value=""
  if [ -s "$2" ]; then
    value="$(sed -n "s|^${1}=||p" "$2" | tail -n 1)"
  fi
  case "${value}" in
    '' | NOTSET) printf '%s' "${3:-}" ;;
    *) printf '%s' "${value}" ;;
  esac
}

# @function fact_value
# Read one fact gathered for one host.
# Globals:
#   work, report_get
# Arguments:
#   $1 - host; $2 - fact name
# Outputs:
#   The fact value, or nothing when it was never measured
# Returns:
#   0
fact_value() {
  report_get "$2" "${work}/${1}.facts"
}

# env_get: read one key out of .env without sourcing it — the file is user-editable and
# a parse error in it must not be able to abort this script. Only the three
# SPARKn_OPENAI_URL routing URLs are read here (the default host list above strips the
# same keys plus the Ollama URLs), and only to compare them with each other.
# @function env_get
# Read the last assignment of one key from .env without sourcing the file.
# Globals:
#   None
# Arguments:
#   $1 - key name
# Outputs:
#   The value with one layer of wrapping quotes removed, or nothing
# Returns:
#   0
env_get() {
  sed -n "s|^${1}=||p" .env 2>/dev/null | tail -n 1 | sed -E 's|^"(.*)"$|\1|; s|^'\''(.*)'\''$|\1|'
}

# json_value / json_escape: keep --json one parseable object per host. A check that
# never ran prints null rather than a number that was never taken, and a remote tool's
# reply is stripped of the delimiters it could otherwise close.
# @function json_value
# Print one JSON scalar: null when empty, a bare integer, or a quoted string.
# Globals:
#   None
# Arguments:
#   $1 - value, optional
# Outputs:
#   null, a bare integer, or a quoted string
# Returns:
#   0
json_value() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    printf 'null'
    return
  fi
  case "$1" in
    *[!0-9]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# @function json_escape
# Escape text so it can sit inside one JSON string.
# Globals:
#   JSON_ESCAPE_SED when this copy clips remote replies
# Arguments:
#   $1 - raw text
# Outputs:
#   Escaped text. The coder-agents copy also turns newlines into \\n.
# Returns:
#   0
json_escape() {
  local trimmed
  trimmed="$(printf '%s' "$1" | sed -E "${JSON_ESCAPE_SED}" | tr -d '\n\r')"
  printf '%s' "${trimmed:0:180}"
}

# probe_http: one capped HTTP GET, printing the body or nothing. "Nothing answered" is a
# result here and not an error: an empty body stays distinguishable from a body that
# says something, which is what lets a box with no server on it be a skip and not a
# failure.
# @function probe_http
# Print the body of one capped HTTP GET, or nothing when it does not answer.
# Globals:
#   probe_tool or has_timeout and http_cap, depending on the caller
# Arguments:
#   Spark entry scripts: $1 - URL. spark.sh: $1 - cap seconds, $2 - URL.
# Outputs:
#   The body, or nothing
# Returns:
#   0
probe_http() {
  # $1 = URL, printed on stdout. One command substitution per call, and no nested one
  # inside it: the whole file keeps that rule so ssh's argument string stays flat too.
  local out=""
  if [ -n "${has_timeout}" ]; then
    out="$(timeout "${http_cap}" curl -fsS -m 8 "$1" 2>/dev/null || true)"
  else
    out="$(curl -fsS -m 8 "$1" 2>/dev/null || true)"
  fi
  printf '%s' "${out}"
}

# probe_script: the remote half, one ssh round trip per host, emitted as ONE flat
# script. It travels base64-encoded inside the ssh command string below, because a
# heredoc on ssh's stdin would end the session's stdin instead of becoming this
# script's stdin, and because a single base64 blob cannot break out of the quoting that
# carries it. It runs under `sh` on the far end, so it stays POSIX: no arrays, no
# [[, no process substitution. One `key=value` line per fact and `report_end` last, so
# a truncated answer stops the reader instead of poisoning the checks that read it.
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
  cat <<'PROBE'
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

# fact: what this box runs with for key $1 — the environment the RUNNING container was
# started with first, because that is what answers the proxy right now, then the file
# next to start.sh, because that is what a restart would read. Both are read with grep,
# never sourced: an answer is data, and a config.sh that had been edited into something
# hostile must not be executed by this check.
# @function fact
# On the remote host, print what key $1 is set to, or NOTSET.
# Globals:
#   cenv, RECIPE_DIR
# Arguments:
#   $1 - key
# Outputs:
#   The value
# Returns:
#   0
fact() {
  key="$1"
  value=""
  if [ -n "${cenv}" ]; then
    value="$(printf '%s\n' "${cenv}" | grep "^${key}=" | tail -n 1 | cut -d= -f2-)"
  fi
  if [ -z "${value}" ]; then
    file="${RECIPE_DIR}/.env"
    if [ -f "${file}" ]; then
      value="$(grep "^${key}=" "${file}" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
    fi
  fi
  if [ -z "${value}" ] && [ -f "${RECIPE_DIR}/scripts/config.sh" ]; then
    value="$(grep "^${key}=" "${RECIPE_DIR}/scripts/config.sh" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
  fi
  [ -n "${value}" ] || value=NOTSET
  printf '%s' "${value}"
}

# run_test: run one of the recipe's own probes and print one line — pass or fail plus
# the first line of whatever it said. A missing script is reported as absent, never
# guessed at, and none of these four starts a server or restarts one.
# @function run_test
# On the remote host, run one recipe probe and print pass or fail.
# Globals:
#   RECIPE_DIR, have_timeout, test_cap
# Arguments:
#   $1 - probe name; $2... - command to run inside the recipe directory
# Outputs:
#   One line: the name, ok or FAIL, and the first line of output
# Returns:
#   0
run_test() {
  name="$1"
  shift
  if [ -n "${have_timeout}" ]; then
    out="$(cd "${RECIPE_DIR}" && timeout "${test_cap}" "$@" 2>&1 | tail -n 12)"
  else
    out="$(cd "${RECIPE_DIR}" && "$@" 2>&1 | tail -n 12)"
  fi
  if [ -z "${out}" ]; then
    printf '%s' "${name}: no output"
  elif printf '%s\n' "${out}" | tail -n 1 | grep -qEi '^(FAIL|ERROR|Traceback)|failed|error'; then
    printf '%s' "${name}: FAIL — $(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | sed -n '1p' | cut -c1-160)"
  else
    printf '%s' "${name}: ok — $(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | sed -n '1p' | cut -c1-160)"
  fi
}

if command -v docker >/dev/null 2>&1; then
  have_docker=present
else
  have_docker=missing
fi
if [ -d /dev/dri ]; then
  dri=present
else
  dri=missing
fi
if [ -d "${RECIPE_DIR:-/nonexistent}" ]; then
  clone_state=present
else
  clone_state=missing
fi
say "have_docker=${have_docker}"
say "dri=${dri}"
say "clone=${clone_state}"

# The image tag, from the container that is running if there is one and from the image
# store if there is not: two boxes on two different TensorFold builds answer the same
# model id differently, and nothing else here would notice.
container_state=absent
container_image=NOTSET
if [ "${have_docker}" = present ]; then
  running="$(docker ps --no-trunc --format '{{.Names}} {{.State}} {{.Image}}' 2>/dev/null | grep "^${CONTAINER} " | tail -n 1)"
  if [ -n "${running}" ]; then
    container_state="$(printf '%s' "${running}" | cut -d' ' -f2)"
    container_image="$(printf '%s' "${running}" | cut -d' ' -f3)"
  else
    container_image="$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 tensorfold)"
    [ -n "${container_image}" ] || container_image=NOTSET
  fi
fi
say "container_state=${container_state}"
say "container_image=${container_image}"

cenv=""
if [ "${have_docker}" = present ]; then
  cenv="$(docker inspect "${CONTAINER}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
fi
say "served_name=$(fact SERVED_NAME)"
say "kv_dtype=$(fact KV_DTYPE)"
say "parallel=$(fact PARALLEL)"
say "context=$(fact CONTEXT)"

# The window, twice over and from two different places: the four "streams of N
# prompt/reply tokens (MMMM MiB a stream)" lines and the "startup estimate ... within
# ... NNNNN tokens" line are what a vLLM-lineage server prints when it was offered the
# window it actually has, which is a measurement and not a setting someone typed.
startup_lines="$(docker logs --tail 400 "${CONTAINER}" 2>/dev/null | grep -o 'streams of [0-9]* prompt/reply tokens ([0-9.]* MiB a stream)' | tail -n 1)"
[ -n "${startup_lines}" ] || startup_lines=NOTSET
say "context_pairs=${startup_lines}"
startup_estimate="$(docker logs --tail 400 "${CONTAINER}" 2>/dev/null | grep -o 'startup estimate.*within.*' | tail -n 1)"
[ -n "${startup_estimate}" ] || startup_estimate=NOTSET
say "startup_estimate=${startup_estimate}"

# The four read-only probes, in the order the fleet contract lists them. Each one needs
# a server that is already up, so a box with no container on it runs none of them and
# says so rather than spending a timeout on each.
if [ "${clone_state}" = present ] && [ "${RUN_TESTS}" = yes ] && [ "${container_state}" != absent ]; then
  cd "${RECIPE_DIR}" || say "clone_unreadable=${RECIPE_DIR}"
  if [ -f scripts/toolcheck.py ]; then
    say "toolcheck=$(run_test toolcheck.py scripts/toolcheck.py)"
  else
    say "toolcheck=absent (no scripts/toolcheck.py in the clone)"
  fi
  if [ -f scripts/needle.py ]; then
    say "needle=$(run_test needle.py scripts/needle.py --length 195000)"
  else
    say "needle=absent (no scripts/needle.py in the clone)"
  fi
  if [ "${VISION_WANTED}" = 1 ]; then
    if [ -f scripts/visioncheck.py ]; then
      say "visioncheck=$(run_test visioncheck.py scripts/visioncheck.py)"
    else
      say "visioncheck=absent (no scripts/visioncheck.py in the clone)"
    fi
  else
    say "visioncheck=skipped (VISION is not 1, so a text-only check was not asked for)"
  fi
  if [ -f scripts/bench.py ]; then
    say "bench=$(run_test bench.py scripts/bench.py --suite --seed 1 --jsonl run.jsonl --clients 1,2,4,5)"
  else
    say "bench=absent (no scripts/bench.py in the clone)"
  fi
fi
say report_end
PROBE
}

log "spark-verify: fleet verify for ${#hosts[@]} host(s) — read-only, nothing here writes to a Spark"
if [ -n "${tests}" ]; then
  log "note: with the recipe probes enabled, each box that has a recipe clone and a running server gets a 195k-token prompt and a 1/2/4/5-client sweep — minutes per box, and it holds streams on a server that may be live. Pass --no-tests for a read-only check that stays quick."
fi

if [ -n "${tests}" ]; then
  ssh_cap_run="${test_cap}"
else
  ssh_cap_run="${ssh_cap}"
fi

hosts_checked=0
hosts_unreachable=0
hosts_failed=0
blank=0

for host in ${hosts[@]+"${hosts[@]}"}; do
  # One JSON object per line in --json mode, with nothing printed between them.
  if [ -z "${json}" ] && [ "${blank}" = 1 ]; then
    printf '\n'
  fi
  blank=1
  hosts_checked=$((hosts_checked + 1))

  models="${work}/${host}.models"
  health="${work}/${host}.health"
  report="${work}/${host}.report"
  script_file="${work}/${host}.sh"
  facts="${work}/${host}.facts"

  # HTTP first, from this box, whatever ssh does afterwards: that is the path the
  # proxy's own health checks and the dashboard's Spark cards take, so it is the
  # answer that describes what the fleet actually sees.
  models="$(probe_http "http://${host}:${server_port}/v1/models")"
  health="$(probe_http "http://${host}:${server_port}/health")"

  # Then ssh, for what only the box itself can say: the image tag, the container's
  # environment, the recipe clone's config.sh, and the recipe's own probes.
  target="${host}"
  if [ -n "${ssh_user}" ]; then
    target="${ssh_user}@${host}"
  fi
  ssh_note=""
  report_rc=0
  ssh_out=""
  if command -v ssh >/dev/null 2>&1; then
    # One flat script, assembled in a file, base64'd into one quoted argument. The five
    # leading assignments are part of that same script, so the remote half still reads
    # as one flat body and the per-host body below keeps appending to it.
    # Double quotes, not single: the default recipe dir holds a literal $HOME that has
    # to expand on the far side, and the rest of these are read as paths on the far side.
    {
      printf '%s\n' "RECIPE_DIR=\"${recipe_dir}\"" "CONTAINER=\"${container}\"" "RUN_TESTS=\"${tests}\"" "VISION_WANTED=\"${vision}\"" "TEST_CAP=\"${test_cap}\"" "have_timeout=\"${has_timeout}\""
      probe_script
    } >"${script_file}"
    payload="$(base64 <"${script_file}" | tr -d '\n')"
    if [ -n "${has_timeout}" ]; then
      ssh_out="$(timeout "${ssh_cap_run}" ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 -p "${ssh_port}" -- "${target}" "printf '%s' '${payload}' | base64 -d | sh" 2>"${work}/${host}.err")" || report_rc=$?
    else
      ssh_out="$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 -p "${ssh_port}" -- "${target}" "printf '%s' '${payload}' | base64 -d | sh" 2>"${work}/${host}.err")" || report_rc=$?
    fi
    if [ "${report_rc}" = "124" ] || [ "${report_rc}" = "143" ]; then
      ssh_note="ssh was cut off after ${ssh_cap_run}s (timeout(1) guard)"
    elif [ "${report_rc}" != "0" ]; then
      ssh_err="$(cat "${work}/${host}.err" 2>/dev/null || true)"
      ssh_note="$(first_line "${ssh_err}")"
      [ -n "${ssh_note}" ] || ssh_note="ssh to ${host} exited ${report_rc} and printed nothing"
    elif ! printf '%s\n' "${ssh_out}" | tail -n 1 | grep -qx report_end; then
      # An opened session that did not answer with a report is not a report: a host
      # that prints a login banner, or a shell that prints an error, would otherwise be
      # read as "every prerequisite is missing".
      ssh_note="$(first_line "${ssh_out}")"
      [ -n "${ssh_note}" ] || ssh_note="ssh to ${host} answered but did not produce a probe report"
    fi
    if [ -z "${ssh_note}" ]; then
      printf '%s\n' "${ssh_out}" >"${report}"
    fi
  fi
  [ -n "${ssh_note}" ] || ssh_note="no ssh session — probed over the LAN only"

  # ── the four checks, in the order the header comment lists them ──────────────
  # 1 and 2: the exact served id, then a green /health with room for five streams.
  # The served id, taken out of the body and compared as a whole string: "exactly the
  # id" means the id and nothing around it, which a substring search cannot express
  # (one body may list several ids, and a prefix of the right one would pass there).
  model_seen="$(printf '%s' "${models}" | grep -o '"id" *: *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
  if [ "${model_seen}" = "${model_id}" ]; then
    model_served=exact
  elif [ -n "${models}" ]; then
    model_served="a model id with different spelling is served (${model_seen:-no id at all})"
  else
    model_served=unmeasurable
  fi

  health_state=no-answer
  if [ -n "${health}" ]; then
    if printf '%s' "${health}" | grep -qE '"(status|error)"[[:space:]]*:[[:space:]]*"(unhealthy|degraded|error)"'; then
      health_state=red
    else
      health_state=green
    fi
  fi
  # The two figures the fleet contract is written in, from the /health body. Anchored
  # with a leading .* so the whole prefix is eaten: without it sed starts matching at
  # the first `"calls":` and hands back the line up to the number as well.
  streams_max="$(printf '%s' "${health}" | sed -n 's|.*"streams": *{[^{}]*"max": *\([0-9][0-9]*\).*|\1|p')"
  context_length="$(printf '%s' "${health}" | sed -n 's|.*"context_length": *\([0-9][0-9]*\).*|\1|p')"
  requests_running="$(printf '%s' "${health}" | sed -n 's|.*"requests_running": *\([0-9][0-9]*\).*|\1|p')"
  [ -n "${requests_running}" ] || requests_running=unmeasured

  # Everything the fleet refuses to run mixed, gathered per host so the peer
  # comparison after the loop has something to compare. A key that was never measured
  # keeps its empty value: that is an absence, and comparing absences is how a check
  # would pass on a fleet where nothing answered.
  : >"${facts}"
  {
    printf 'model_id_seen=%s\n' "${model_seen}"
    printf 'model_served=%s\n' "${model_served}"
    printf 'health_state=%s\n' "${health_state}"
    printf 'streams_max=%s\n' "${streams_max}"
    printf 'requests_running=%s\n' "${requests_running}"
    printf 'context_length=%s\n' "${context_length}"
  } >>"${facts}"
  # The three proxy-side URLs come from .env.sample / docker-compose.yml, not from the
  # box: an :8888 that answers on its plain path is a V1OpenAIChatProvider deployment
  # (chat completions), not a /v1/messages one, and the proxy would not say so.
  printf 'spark1_openai=%s\n' "$(env_get SPARK1_OPENAI_URL)" >>"${facts}"
  printf 'spark2_openai=%s\n' "$(env_get SPARK2_OPENAI_URL)" >>"${facts}"
  printf 'spark3_openai=%s\n' "$(env_get SPARK3_OPENAI_URL)" >>"${facts}"
  if [ -s "${report}" ]; then
    {
      printf 'context_pairs=%s\n' "$(report_get context_pairs "${report}")"
      printf 'startup_estimate=%s\n' "$(report_get startup_estimate "${report}")"
      printf 'container_state=%s\n' "$(report_get container_state "${report}")"
      printf 'container_image=%s\n' "$(report_get container_image "${report}")"
      printf 'served_name=%s\n' "$(report_get served_name "${report}")"
      printf 'kv_dtype=%s\n' "$(report_get kv_dtype "${report}")"
      printf 'parallel=%s\n' "$(report_get PARALLEL "${report}")"
      printf 'context=%s\n' "$(report_get CONTEXT "${report}")"
      printf 'toolcheck=%s\n' "$(report_get toolcheck "${report}")"
      printf 'needle=%s\n' "$(report_get needle "${report}")"
      printf 'visioncheck=%s\n' "$(report_get visioncheck "${report}")"
      printf 'bench=%s\n' "$(report_get bench "${report}")"
    } >>"${facts}"
  fi

  # ── the verdict ────────────────────────────────────────────────────────────
  # One decision per host, taken before anything is printed, so the human lines, the
  # --json object and sparks/<host>.jsonl all describe the same measurement.
  #
  # A host that answered on no port and opened no ssh session is a "not yet" box:
  # nothing was compared, so nothing can be claimed about it. That is a skip, printed
  # with the reason, and it does not touch the exit code — the same graceful-degradation
  # contract bootstrap.sh follows, and the reason this script is safe to run on a fleet
  # where one box is switched off.
  failed_here=""
  reachable=true
  verdict=OK
  detail=""
  if [ "${model_served}" = unmeasurable ]; then
    reachable=false
    verdict=SKIP
    detail="nothing answered on :${server_port} and no ssh session opened either (${ssh_note}) — nothing was verified on this box, and that is a \"not yet\" state rather than a failure: a Spark that is switched off, has no server on it, or is not an ssh target from this box cannot disagree with its peers"
    hosts_unreachable=$((hosts_unreachable + 1))
  elif [ "${model_served}" != exact ]; then
    verdict=FAIL
    detail="answers /v1/models with \"${model_seen}\" instead of \"${model_id}\" — LiteLLM sends the id verbatim and drops this deployment at boot, so the fleet reads \"No deployments available\" and nothing that looks like an error"
    failed_here=1
  elif [ "${health_state}" = red ]; then
    verdict=FAIL
    detail="answered /health, but not green — read it yourself with: docker logs ${container}"
    failed_here=1
  else
    if [ -n "${streams_max}" ] && [ "${streams_max}" != "${parallel_want}" ]; then
      detail="was offered ${streams_max} streams and the fleet routes with ${parallel_want} — pinned workspaces stay glued to this box and least-busy keeps handing it new sessions either way, so a client's fifth parallel stream lands on a box with no room for it"
      failed_here=1
    fi
    if [ -n "${context_length}" ] && [ "${context_length}" != "${context_want}" ]; then
      detail="${detail}${detail:+; }reports context_length ${context_length} and the fleet's window is ${context_want} — a 195k-token prompt routes here and comes back truncated rather than refused"
      failed_here=1
    fi
    if [ -n "${failed_here}" ]; then
      verdict=FAIL
    fi
  fi
  if [ -n "${failed_here}" ]; then
    hosts_failed=$((hosts_failed + 1))
  fi

  # The four facts, looked up once, so the two outputs below cannot disagree.
  seen_state="$(fact_value "${host}" container_state)"
  seen_image="$(fact_value "${host}" container_image)"
  seen_parallel="$(fact_value "${host}" PARALLEL)"
  seen_context="$(fact_value "${host}" CONTEXT)"
  seen_kv="$(fact_value "${host}" kv_dtype)"
  seen_name="$(fact_value "${host}" served_name)"
  # The three proxy-side routing URLs, printed only when there is a .env to read them
  # from: three blanks would read as "no Spark is wired into the proxy" when all it
  # really means is that this checkout has no .env at all.
  routing="$(fact_value "${host}" spark1_openai) $(fact_value "${host}" spark2_openai) $(fact_value "${host}" spark3_openai)"
  case "${routing}" in
    *http*) ;;
    *) routing="no SPARKn_OPENAI_URL to compare (no .env here, or all three are empty)" ;;
  esac

  if [ "${json}" != 1 ]; then
    if [ "${verdict}" = OK ]; then
      log "${host} — serving ${model_id}"
    else
      log "${host} — ${verdict} (${detail})"
    fi
    log "  health: ${health_state} (requests_running: ${requests_running}, streams.max: ${streams_max:-unmeasured} — the fleet routes with ${parallel_want} streams; context_length: ${context_length:-unmeasured} — the fleet's window is ${context_want})"
    log "  container: ${container} is ${seen_state:-unmeasured} on ${seen_image:-unmeasured}"
    log "  routing: ${routing}"
    log "  config: PARALLEL=${seen_parallel:-unmeasured} CONTEXT=${seen_context:-unmeasured} KV_DTYPE=${seen_kv:-unmeasured} SERVED_NAME=${seen_name:-unmeasured}"
  fi

  # One JSON object per host, on one line, carrying the same six facts the drift check
  # compares, written once and read back for stdout so the two cannot disagree and a run
  # piped into jq answers the same question the human output does. sparks/ is
  # gitignored generated state: this file holds this run's answer, not a log.
  printf '{"host":"%s","reachable":%s,"verdict":"%s","probed_via":"%s","model_id":"%s","served":%s,"health":"%s","requests_running":%s,"streams_max":%s,"context_length":%s,"image":"%s","kv_dtype":"%s","parallel":"%s","detail":"%s"}\n' \
    "${host}" "${reachable}" "${verdict}" \
    "$(json_escape "${ssh_note}")" "${model_id}" "$(json_value "${model_served}")" \
    "$(json_escape "${health_state}")" "$(json_value "${requests_running}")" \
    "$(json_value "${streams_max}")" "$(json_value "${context_length}")" \
    "$(json_escape "${seen_image}")" "$(json_escape "${seen_kv}")" \
    "$(json_escape "${seen_parallel}")" "$(json_escape "${detail}")" >"${work}/${host}.jsonl"

  if [ "${json}" = 1 ]; then
    cat "${work}/${host}.jsonl"
  fi
  if ! mkdir -p sparks 2>/dev/null; then
    log "  note: sparks/ could not be created, so ${host}'s result stays on stdout"
  elif ! cat "${work}/${host}.jsonl" >"sparks/${host}.jsonl" 2>/dev/null; then
    log "  note: ${host}'s result could not be written to sparks/${host}.jsonl (read-only checkout?) — it is still on stdout above"
  fi
done

# ── the drift check ──────────────────────────────────────────────────────────
# Compare each of the drift keys across every host that was measured, and fail when one
# of them comes back with more than one value. Comparing what was MEASURED is what
# makes this a fleet check instead of three host checks: two boxes on
# tensorfold/decode-native:0.6.1-cu130 beside one on anything else, or PARALLEL 5
# beside PARALLEL 4, is the drift this script exists to catch. A host that never
# answered contributes nothing here — see the header comment.
drift=""
for key in ${drift_keys}; do
  first_value=""
  first_host=""
  differs=""
  for host in ${hosts[@]+"${hosts[@]}"}; do
    value="$(fact_value "${host}" "${key}")"
    [ -n "${value}" ] || continue
    if [ -z "${first_value}" ]; then
      first_value="${value}"
      first_host="${host}"
    elif [ "${value}" != "${first_value}" ]; then
      differs="${differs}${differs:+, }${host}=${value}"
    fi
  done
  if [ -n "${differs}" ]; then
    drift="${drift}${drift:+; }${key}: ${first_host}=${first_value} vs ${differs}"
  fi
done

if [ -n "${drift}" ]; then
  log ""
  log "FAIL: the checked boxes do not agree — ${drift}"
  log 'note: mixed images or mixed parallel settings across the boxes is exactly what this check is for, and the proxy cannot see it: they all sit behind one `agent` model group whose session pins ride on top of least-busy routing, so pinned and unpinned requests keep going to the odd box.'
  log "note: read the details with ./scripts/spark-configure.sh <host> and write the fleet's values with ./scripts/spark-configure.sh --apply <host> (add --restart to restart a running server), then re-run this script."
  exit 1
fi

if [ "${hosts_checked}" = "${#hosts[@]}" ] && [ "${hosts_unreachable}" != "${hosts_checked}" ]; then
  log ""
  log "summary: ${hosts_checked} of ${#hosts[@]} host(s) checked (${hosts_unreachable} unreachable) and ${hosts_failed} failed — see the lines above"
elif [ "${hosts_unreachable}" = "${hosts_checked}" ]; then
  log ""
  log "summary: no Spark answered on :${server_port} and no ssh session opened, so nothing was verified"
  log "note: none of the ${#hosts[@]} host(s) could be reached — check SPARK_HOSTS (spark-1.lan/2/3 are placeholders, not addresses) or pass --user/--port; this is a \"not yet\" state, so the exit code stays 0"
fi

if [ "${hosts_failed}" != 0 ]; then
  exit 1
fi
exit 0
