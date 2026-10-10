#!/usr/bin/env bash
# spark-configure.sh — assert the per-Spark setup of the Qwen3.8-Flash-Next fleet and,
# with --apply, write the per-host override file that keeps the three boxes identical.
#
# Usage:
#   ./scripts/spark-configure.sh                          # assert-only, the fleet named in .env
#   ./scripts/spark-configure.sh spark-1.lan              # assert-only, one host
#   ./scripts/spark-configure.sh --json spark-1.lan       # one JSON object per host
#   ./scripts/spark-configure.sh --apply 192.168.64.10    # write sparks/192.168.64.10.env
#   ./scripts/spark-configure.sh --apply --restart <host> # and restart a RUNNING server
#   SPARK_CFG_PARALLEL=4 ./scripts/spark-configure.sh --apply <host>
#
# With no host arguments the fleet named in .env is used — the host parts of the
# SPARKn_OLLAMA_URL/SPARKn_OPENAI_URL keys — falling back to the placeholder trio
# spark-1.lan spark-2.lan spark-3.lan, whose names do not resolve. Pass real hostnames
# or IPs, or set SPARK_HOSTS="host1 host2 ..." in the process environment, to override.
#
# WHY one override file per host: three boxes behind one `agent` model group must stay
# identical in everything that affects outputs — same parallel stream count, same
# context length, same KV cache dtype — because a box that differs answers with a
# degraded or wrong completion rather than an error, and the proxy happily keeps
# handing it requests — pinned workspaces stay glued to their box and least-busy
# still hands a drifted box new sessions. The recipe
# (MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold, pinned v0.6.1 =
# commit 17c73e1) keeps the per-host settings in
# scripts/config.sh and reads overrides from a .env file next to start.sh, so one
# generated file per host is the whole mechanism: start.sh re-runs scripts/prepare.sh
# only when the setup differs from what prepare last left ready, so an unchanged
# re-run skips it in about two and a half seconds instead of another 5-15 minutes.
#
# The generated file is a per-host override file, NOT a fork of the recipe: the clone
# stays pristine, so `git -C <clone> status` on the Spark still reads clean, and a
# recipe bump cannot silently rewrite one box's stream count behind the fleet's back.
#
# Values come from process env SPARK_CFG_<NAME> (process environment only — the
# repo-root .env is read only to name the default HOST list, never for values) or
# from an existing sparks/<host>.env, which is this script's own output.
#
# No interactive prompts and no reboots: assert-only is the default mode, --apply
# writes, and --restart (which implies --apply) only ever restarts a server that is
# ALREADY running. A cold server is never started, and a server that runs outside any
# recipe clone gets a hand-run command printed instead of having it executed: a blind
# `docker stop && docker run` on a box that may be mid-stream is not a reviewable
# action, which is the same rule the rest of this stack follows.
#
# Exit: 0 when every host is ready or skipped — unreachable, no recipe clone and no
# ssh credentials are "not yet" states, not errors; 1 when --apply was attempted and
# something failed (write refused, no start.sh to restart with, restart failed) or a
# host could not be checked at all, because leaving one box on other settings than its
# peers is the drift this script exists to prevent.
# ## spark-configure.sh — assert, and with --apply write, the Spark fleet config

# shellcheck disable=SC2016 # usage() prints the header block above, where $SPARK_HOSTS
# and $HOME are literal text in this script's own comments, not expansions.
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
usage() { sed -n '2,27p' "$0"; }

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
  # stderr instead, so `spark-configure.sh --json | jq` parses and `2>/dev/null` silences
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
# Expected states, not errors: exit 0 so callers (bootstrap) keep going.
# @function skip
# Print a not-yet line and exit 0 so callers such as bootstrap keep going.
# Globals:
#   None
# Arguments:
#   $* - reason text
# Outputs:
#   The reason on stdout (spark-configure routes it through log)
# Returns:
#   Does not return; exits 0
skip() {
  log "$*"
  exit 0
}

# The twelve settings this script owns. The defaults are the recipe's own and stay as
# shipped: PARALLEL 5 is the recipe default (4 is the escape hatch for a box ALSO
# running other GPU work), TENSORFOLD_MEMORY_RESERVE_GIB 2 is already the floor
# (raising it shrinks the KV pool instead of the reserve), and KV_DTYPE int8 halves KV
# memory against bf16 but is the recipe default and does change outputs against full
# precision — keep it. PORT is also the port the two HTTP probes below dial, so a host
# that runs its server elsewhere is checked against its own setting, not against 8888.
keys="PARALLEL=5 CONTEXT=262144 KV_DTYPE=int8 SERVED_NAME=Qwen3.8-Flash-Next \
PORT=8888 MAX_TOKENS=32768 TENSORFOLD_MEMORY_RESERVE_GIB=2 \
TENSORFOLD_PREFILL_ROWS=2048 TENSORFOLD_MTP_COPY=1 VISION=1 \
TENSORFOLD_IMAGE_TOKENS=16384 VISION_MAX_IMAGES=50"

apply=""
restart=""
json=""
ssh_user="${SPARK_SSH_USER:-${LOGNAME:-}}"
ssh_port=22
timeout_s=120
probe_cap=15
http_cap=8
recipe_dir='${HOME}/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
container="qwen38-flash-next-tf"
JSON_ESCAPE_SED='s/["\\]/\\&/g' # one sed program, quoted: escape \ and " in one pass
model_id="Qwen3.8-Flash-Next"
container_env="/opt/qwen38-flash-next/.env"

# The pinned recipe, named in full because this script neither clones it nor forks
# it: the clone lives at ${recipe_dir} on each Spark, cloned per host from the repo
# below at the tag in the comment above, and nothing in this repo vendors it.
recipe_repo="MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold"
recipe_ref="v0.6.1 = 17c73e1"

hosts=()
if [ "$#" -gt 0 ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply)
        apply=1
        shift
        ;;
      --restart)
        apply=1
        restart=1
        shift
        ;;
      --json)
        json=1
        shift
        ;;
      --dry-run)
        apply=""
        shift
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
      --recipe-dir)
        [ "$#" -ge 2 ] || die "--recipe-dir needs a value"
        recipe_dir="$2"
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || die "--timeout needs a value"
        timeout_s="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option '$1' — usage: ./scripts/spark-configure.sh [options] [host ...] (see --help)"
        ;;
      *)
        hosts+=("$1")
        shift
        ;;
    esac
  done
fi

if [ "${#hosts[@]}" -eq 0 ]; then
  if [ -n "${SPARK_HOSTS:-}" ]; then
    # Word-splitting is the point here: SPARK_HOSTS is a space-separated list in the
    # process environment, and a stray glob in it cannot name a host anyway.
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
      log "note: no host given and SPARK_HOSTS is not set — checking the hosts named by the SPARKn_OLLAMA_URL/SPARKn_OPENAI_URL keys in .env:${derived_hosts}"
      for host in ${derived_hosts}; do
        hosts+=("${host}")
      done
    else
      log 'note: no host given and SPARK_HOSTS is not set, and no SPARK*_URL key in .env names a host — checking the placeholder trio spark-1.lan spark-2.lan spark-3.lan, which .env.sample and docker-compose.yml also ship as placeholders. Those names do not resolve: pass your real Spark hostnames or IPs, or set SPARK_HOSTS="host1 host2 ..." in the environment.'
      hosts=("spark-1.lan" "spark-2.lan" "spark-3.lan")
    fi
  fi
fi

command -v ssh >/dev/null 2>&1 ||
  skip "skipped: ssh is not on PATH, so no Spark can be inspected or configured"

# timeout(1) is optional here, unlike in push-template.sh where its absence is a
# reason to skip: an uncapped ssh or curl to a black-holed address hangs until the
# operating system gives up, so every probe and remote command below is capped.
if command -v timeout >/dev/null 2>&1; then
  has_timeout=1
  probe_tool=(timeout "${http_cap}" curl -fsS -m 5)
else
  log "note: timeout(1) is not available — the probes below run uncapped, so a host that drops packets can stall this run until the operating system times it out"
  has_timeout=""
  probe_tool=(curl -fsS -m 5)
fi

# One scratch directory per run, for the per-host probe script and its response.
# Neither script nor response is ever a shell argument: each host gets its own pair of
# files under this directory, and the repo-root .env is read above only to name the
# default host list — never written, and never read for config values.
work="$(mktemp -d 2>/dev/null || true)"
[ -n "${work}" ] || die "could not create a scratch directory for the probe scripts"
trap 'rm -f "${work}"/*' EXIT

# One ssh target per host, and one remote script per target. -n keeps ssh from
# stealing this script's stdin, -o BatchMode=yes and -o StrictHostKeyChecking=accept-new
# are what keep a run non-interactive: an unknown host key or a key passphrase would
# otherwise block until the cap below instead of failing, and a blocked probe loop is
# how a fleet check turns into a 40-minute one.
# @function ssh_run
# Run one remote command over ssh, capped when timeout(1) exists.
# Globals:
#   has_timeout, timeout_s, ssh_port
# Arguments:
#   $1 - user@host; $2 - remote command; $3 - cap seconds, optional
# Outputs:
#   The remote command's stdout and stderr
# Returns:
#   ssh's status, or 124 when timeout cuts it off
ssh_run() {
  # $1 = user@host, $2 = the remote command, $3 = optional wall-clock cap in seconds.
  # timeout(1) takes the duration and the command as separate argv words, which is why
  # the cap is a quoted argument here and an array element in probe_tool above.
  if [ -n "${has_timeout}" ]; then
    timeout "${3:-${timeout_s}}" ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -p "${ssh_port}" -- "$1" "$2"
  else
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -p "${ssh_port}" -- "$1" "$2"
  fi
}

# json_value: print $1 as a JSON value. A check that never ran prints null, because a
# quoted string would claim a number was taken and a bare one would not parse; a pair
# of values prints as a JSON array, which is how the two context-window figures stay
# distinguishable from one measurement.
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

# json_escape: strip the JSON delimiters this script could ever interpolate into a
# value and cap the length, so --json stays one parseable object per host even when a
# remote tool answers with a multi-line error.
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
  # $1 = text; print its first non-blank line, so a remote tool's own complaint can be
  # quoted without dumping its whole output into this script's output. The `|| true` is
  # load-bearing: pipefail makes an all-blank input (grep exits 1) abort the caller,
  # and that caller is an assignment under `set -e`.
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

# want_value: the value this fleet wants for key $1 on this host, from the per-host
# override file this script wrote on an earlier run when there is one (that is why a
# second --apply stays silent), else from process env SPARK_CFG_<NAME>, else the
# default in $keys. The repo-root .env is none of those sources (it is read above
# only to name the default host list, never for values like these).
# @function want_value
# Print the fleet's desired value for one key on one host.
# Globals:
#   keys, SPARK_CFG_<KEY>
# Arguments:
#   $1 - key; $2 - per-host override file, optional
# Outputs:
#   The value from the override file, else SPARK_CFG_<KEY>, else keys
# Returns:
#   0
want_value() {
  # $1 = key, $2 = per-host override file (may be missing)
  local key="$1" file="${2:-}" value="" entry
  if [ -n "${file}" ] && [ -f "${file}" ]; then
    value="$(sed -n "s|^${key}=||p" "${file}" | tail -n 1)"
  fi
  if [ -z "${value}" ]; then
    value="$(eval "printf '%s' \"\${SPARK_CFG_${key}:-}\"")"
  fi
  if [ -z "${value}" ]; then
    # shellcheck disable=SC2086 # $keys is this script's own literal default list,
    # assembled above with no whitespace inside any entry, so splitting it cannot
    # lose or merge a key.
    for entry in $keys; do
      if [ "${entry%%=*}" = "${key}" ]; then
        value="${entry#*=}"
        break
      fi
    done
  fi
  printf '%s' "${value}"
}

# live_value: what this box actually runs with for key $1 — the environment the
# running container was started with first, then the file next to start.sh, because
# the container's environment is what start.sh read the last time it ran. $2 is the
# per-host probe response, one key=value line per fact.
# @function live_value
# Print the value a probed host is actually running for one key.
# Globals:
#   None
# Arguments:
#   $1 - key; $2 - probe report file
# Outputs:
#   The inspect value, else the recipe value, else nothing
# Returns:
#   0
live_value() {
  local key="$1" report="$2" value="" source
  for source in inspect recipe; do
    value="$(sed -n "s|^${source}\.${key}=||p" "${report}" | tail -n 1)"
    if [ -n "${value}" ] && [ "${value}" != NOTSET ]; then
      break
    fi
  done
  printf '%s' "${value}"
}

# probe_script: the remote half, one ssh round trip. It travels to the Spark base64
# encoded inside the ssh command string, because a heredoc on ssh's stdin would end
# the session's stdin instead of becoming the script's stdin, and a single base64 blob
# cannot break out of the quoting around the printf that carries it. Running it
# through `sh -c` rather than a login shell keeps the environment sshd inherited from
# the docker daemon's launch, which is what separates a box that has docker from one
# that does not (a docker installed by get.docker.com keeps its socket group, and the
# nvidia runtime is a daemon setting, not a file). One key=value line per fact, and
# `report_end` on its own line ends the report, so a truncated or hostile response
# stops the reader instead of poisoning the checks that read it.
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
  value="NOTSET"
  if [ -f "${RECIPE_DIR:-/nonexistent}/scripts/config.sh" ]; then
    # shellcheck disable=SC1091 # this runs on the Spark, inside the pinned recipe
    # clone, where scripts/config.sh is where the recipe keeps the same twelve keys.
    . "${RECIPE_DIR}/scripts/config.sh" 2>/dev/null || true
  fi
  if [ -f "${RECIPE_DIR:-/nonexistent}/.env" ]; then
    . "${RECIPE_DIR}/.env" 2>/dev/null || true
  fi
  value="$(eval "printf '%s' \"\${${key}:-}\")" | sed -n '1p')"
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
PROBE
}

# probe_http: one capped HTTP GET, printing the body or nothing at all. "Nothing
# answered" is a result and not an error here, and it stays distinguishable from
# "answered and looks right": an empty body means unmeasured, never a pass. The
# command substitution below holds no nested one — that nesting is what the ssh
# plumbing in this file has to avoid, so it is avoided everywhere else too.
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
  # $1 = URL, and probe_tool is either `timeout <cap> curl -m 5` or `curl -m 5`.
  local out=""
  out="$("${probe_tool[@]}" "$1" 2>/dev/null || true)"
  printf '%s' "${out}"
}

# report_get: the value the probe script recorded for key $1 in report file $2, or
# $3 when the file, the key or the value is missing. Read with sed and never
# sourced: a truncated or hostile answer must not be able to name a variable and
# supply the command that fills it (see the note above probe_script).
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

log "spark-configure: fleet config check for ${#hosts[@]} host(s) — read-only; add --apply to write"
if [ -n "${apply}" ]; then
  log "note: --apply is set, so sparks/<host>.env and the per-host .env on the Spark may be rewritten (no key this script writes holds a secret: the api_key for the model group lives in LiteLLM's environment, not on a Spark)"
fi

hosts_checked=0
hosts_ready=0
hosts_skipped=0
hosts_failed=0
blank=0

for host in ${hosts[@]+"${hosts[@]}"}; do
  # One JSON object per line in --json mode, with no blank line between them, so the
  # whole run can be piped straight into jq or tee'd into sparks/<host>.jsonl.
  if [ -z "${json}" ] && [ "${blank}" = 1 ]; then
    printf '\n'
  fi
  blank=1
  hosts_checked=$((hosts_checked + 1))

  probe="${work}/${host}.probe"
  report="${work}/${host}.report"
  stderr_file="${work}/${host}.err"
  models="${work}/${host}.models"
  local_env="sparks/${host}.env"
  target="${host}"
  if [ -n "${ssh_user}" ]; then
    target="${ssh_user}@${host}"
  fi

  server_port="$(want_value PORT "${local_env}")"

  # The two HTTP probes are dialled from the workstation and not through ssh: a
  # Spark may expose :8888 straight to the LAN, and a probe that had to open an ssh
  # session first would report a healthy server as unreachable. Each one is capped
  # twice over — timeout(1) around a curl that carries its own -m — because a
  # black-holed address must not be able to stall this loop (see probe_tool above).
  "${probe_tool[@]}" "http://${host}:${server_port}/v1/models" >"${models}" 2>/dev/null || true
  health="$(probe_http "http://${host}:${server_port}/health")"

  # ── the remote half: one flat script, one ssh round trip ────────────────────
  # probe_script below emits the whole remote body as ONE flat sh script into
  # ${probe}: the two per-host assignments first, then the probe itself. Nothing in
  # it is assembled by nesting a command substitution inside another one, so the
  # file is checkable with `bash -n`/shellcheck here before it ever travels, and
  # what travels is exactly that file, base64'd into one single-quoted ssh
  # argument. base64's alphabet holds no quote and no space, so the payload cannot
  # close the printf that carries it, and ssh's stdin stays untouched.

  # The recipe dir and container name go out in double quotes, not single: the default
  # recipe dir holds a literal $HOME, which has to expand ON THE SPARK. Single-quoted it
  # would arrive as those six characters and every clone would read as "no clone".
  {
    printf '%s\n' "RECIPE_DIR=\"${recipe_dir}\"" "CONTAINER=\"${container}\""
    probe_script
  } >"${probe}"
  payload="$(base64 <"${probe}" | tr -d '\n')"

  ssh_rc=0
  ssh_out="$(ssh_run "${target}" "printf '%s' '${payload}' | base64 -d | sh" "${probe_cap}" 2>"${stderr_file}")" ||
    ssh_rc=$?

  if [ "${ssh_rc}" = "124" ] || [ "${ssh_rc}" = "143" ]; then
    reason="ssh to ${host} was cut off after ${probe_cap}s (timeout(1) guard)"
  elif [ "${ssh_rc}" != "0" ]; then
    probe_err="$(cat "${stderr_file}" 2>/dev/null || true)"
    reason="$(first_line "${probe_err}")"
    [ -n "${reason}" ] || reason="ssh to ${host} returned ${ssh_rc} and printed nothing"
  elif ! printf '%s\n' "${ssh_out}" | tail -n 1 | grep -qx report_end; then
    # A session that opened and answered is not the same thing as a report: a host
    # that prints a banner, or a shell that prints an error, would otherwise be read
    # as "every prerequisite is missing". The probe's own terminator has to be the
    # last line, so an answer cut off mid-way counts as nothing having been measured.
    reason="$(first_line "${ssh_out}")"
    [ -n "${reason}" ] || reason="ssh to ${host} answered but did not produce a probe report"
  else
    reason=""
    printf '%s\n' "${ssh_out}" >"${report}"
  fi

  # Everything past here reads ${report} instead of dialling the box a second time.
  # A host with no report gets "unmeasured" in every field and prints the reason
  # instead of the checks, because "docker is not on PATH" said about a box that was
  # never reached is a statement about this run, not about that box.
  if [ -z "${reason}" ]; then
    have_docker="$(report_get have_docker "${report}" unmeasured)"
    docker_runtimes="$(report_get docker_runtimes "${report}" unmeasured)"
    dri="$(report_get dri "${report}" unmeasured)"
    clone_state="$(report_get clone "${report}" unmeasured)"
    env_file="$(report_get env_file "${report}" unmeasured)"
    config_sh="$(report_get config_sh "${report}" unmeasured)"
    gpu_env="$(report_get gpu_env "${report}" unmeasured)"
    container_state="$(report_get container_state "${report}" absent)"
    disk_gib="$(report_get disk_free_gib "${report}" 0)"
    mem_gib="$(report_get mem_free_gib "${report}" 0)"

    # The two figures the recipe needs before it can serve at all: ~160 GB free
    # disk (~125 GB checkpoint + ~24 GB image + headroom) and ~103 GiB free memory
    # (its startup estimate is ~102.5 GiB of a 128 GB unified-memory machine).
    disk_enough="$(awk -v g="${disk_gib}" 'BEGIN { print (g + 0 >= 160) ? 1 : 0 }')"
    mem_enough="$(awk -v g="${mem_gib}" 'BEGIN { print (g + 0 >= 103) ? 1 : 0 }')"
    if [ "${disk_enough}" = 1 ]; then disk_ok=ok; else disk_ok=""; fi
    if [ "${mem_enough}" = 1 ]; then mem_ok=ok; else mem_ok=""; fi

    # ── the five prerequisites, one line each, plus the clone and the served id ──
    # None of them is fatal: this script reports and, with --apply, writes. It does
    # not decide to reformat a disk, and it never starts a cold server.
    missing_prereq=""
    if [ "${have_docker}" = present ]; then
      log "  ok: docker on PATH"
    else
      log "  warn: docker is not on PATH — no container can be started or inspected on this box"
      missing_prereq="${missing_prereq}${missing_prereq:+, }docker"
    fi
    case "${docker_runtimes}" in
      *nvidia*)
        log "  ok: nvidia container runtime: $(json_escape "${docker_runtimes}")"
        ;;
      missing | unmeasured)
        log "  warn: no nvidia container runtime found — TensorFold needs the NVIDIA runtime (the recipe's prepare.sh installs it)"
        missing_prereq="${missing_prereq}${missing_prereq:+, }nvidia-runtime"
        ;;
      *)
        log "  warn: docker answers but lists no nvidia runtime — TensorFold needs the NVIDIA runtime (the recipe's prepare.sh installs it)"
        missing_prereq="${missing_prereq}${missing_prereq:+, }nvidia-runtime"
        ;;
    esac
    if [ "${clone_state}" = present ]; then
      log "  ok: recipe clone at ${recipe_dir} (config.sh: $(json_escape "${config_sh}"), .env: $(json_escape "${env_file}"))"
    else
      log "  warn: no recipe clone at ${recipe_dir} — the pinned recipe is ${recipe_repo} @ ${recipe_ref}; this script does not clone it (see the note below)"
    fi
    if [ "${disk_ok}" = ok ]; then
      log "  ok: ${disk_gib} GiB free on / (a fresh machine needs ~160 GB: ~125 GB checkpoint + ~24 GB image + headroom)"
    else
      log "  warn: ${disk_gib} GiB free on / — a fresh machine needs ~160 GB: ~125 GB checkpoint + ~24 GB image + headroom"
      missing_prereq="${missing_prereq}${missing_prereq:+, }disk"
    fi
    if [ "${mem_ok}" = ok ]; then
      log "  ok: ${mem_gib} GiB of memory available (start.sh's startup estimate needs ~103 GiB free, and a second workload on the same box eats into that)"
    else
      log "  warn: only ${mem_gib} GiB of memory available — the startup estimate is ~102.5 GiB of a 128 GB unified-memory machine, so the server would not come up"
      missing_prereq="${missing_prereq}${missing_prereq:+, }memory"
    fi
    if [ "${dri}" = present ]; then
      log "  ok: /dev/dri present"
    else
      log "  warn: /dev/dri not found — irrelevant to a CUDA Spark, but it is what tells a healthy GPU box from an Arc-style one, so check nvidia-smi yourself if the next lines look thin"
    fi
  else
    have_docker=unmeasured
    docker_runtimes=unmeasured
    dri=unmeasured
    clone_state=unmeasured
    env_file=unmeasured
    config_sh=unmeasured
    gpu_env=unmeasured
    container_state=unmeasured
    disk_gib=unmeasured
    mem_gib=unmeasured
    disk_ok=unmeasured
    mem_ok=unmeasured
    missing_prereq=""
  fi

  # The fleet's contract for a fleet check: one comparable fingerprint per box, so a
  # box left on other settings than its two peers shows up in the output instead of
  # only in a diff someone has to think to go and read.
  fingerprint="$(printf '%s\n' "${keys}" | tr ' ' '\n' | sed -n 's|^\([A-Z_0-9]*\)=\(.*\)$|\1=\2|p' |
    tr '\n' ' ')"
  if [ -n "${reason}" ]; then
    # Nothing was compared, so there is no fingerprint to compare and --json must not
    # claim there was one.
    fingerprint=""
  fi

  # streams.max is how many full-length streams the box was offered, requests_running
  # how many it holds right now, and context_length the window it answers with. All
  # three are read out of the /health body and all three are advisory in this script:
  # spark-verify.sh is where a box that disagrees with its peers is a failure.
  streams_max="$(printf '%s' "${health}" | sed -n 's|.*"streams": *{[^{}]*"max": *\([0-9][0-9]*\).*|\1|p')"
  requests_running="$(printf '%s' "${health}" | sed -n 's|.*"requests_running": *\([0-9][0-9]*\).*|\1|p')"
  context_length="$(printf '%s' "${health}" | sed -n 's|.*"context_length": *\([0-9][0-9]*\).*|\1|p')"
  # Read out of the body and compared as a whole id: a substring search would also
  # match a body that serves a differently-spelled model, which is the one case that
  # matters here (see the note in spark-verify.sh's header on ignore_invalid_deployments).
  # ${models} is the FILE the probe wrote, hence cat — the path is not the payload.
  models_body=""
  if [ -s "${models}" ]; then
    models_body="$(cat "${models}")"
  fi
  model_seen="$(printf '%s' "${models_body}" | grep -o '"id" *: *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
  model_served=unmeasured
  if [ "${model_seen}" = "${model_id}" ]; then
    model_served=present
  elif [ -s "${models}" ]; then
    model_served="a model id with different spelling is served (${model_seen:-no id at all})"
  fi

  # docker ps without -a only lists RUNNING containers, so an answer that starts with
  # Up is the healthy shape of this key and not a finding. Everything else that is
  # neither empty (no container) nor absent means a container that is not serving,
  # which is the one case where comparing settings and refusing to write .env matter.
  case "${container_state}" in
    '' | unmeasured)
      container_running=""
      ;;
    Up* | running)
      container_running=1
      ;;
    *)
      container_running=""
      ;;
  esac

  if [ -z "${reason}" ] && [ -z "${container_running}" ] && [ -n "${container_state}" ] &&
    [ "${container_state}" != absent ]; then
    reason="container state: ${container_state}"
  fi
  if [ -z "${reason}" ]; then
    reason="no ${container} container on this box, and a cold server is never started here"
  fi

  if [ "${json}" = 1 ]; then
    # --json: one JSON object per host, one line each, for jq or for a dashboard. A
    # check that never ran prints null (see json_value) rather than a plausible 0.
    printf '{"host":"%s","checked":%s,"reason":"%s","model_id":"%s","served":%s,"streams_max":%s,"requests_running":%s,"context_length":%s,"missing_prereq":"%s","config":"%s","gpu_env":"%s"}\n' \
      "${host}" \
      "$(json_value "${container_running}")" \
      "$(json_escape "${reason}")" \
      "${model_id}" \
      "$(json_value "${model_served}")" \
      "$(json_value "${streams_max}")" \
      "$(json_value "${requests_running}")" \
      "$(json_value "${context_length}")" \
      "$(json_escape "${missing_prereq}")" \
      "$(json_escape "${fingerprint}")" \
      "$(json_escape "${gpu_env}")"
  else
    if [ -n "${reason}" ]; then
      printf 'spark-configure: %s — SKIP (%s)\n' "${host}" "$(json_escape "${reason}")"
    fi
    log "  served model id: ${model_served} (streams.max: ${streams_max:-unmeasured}, context_length: ${context_length:-unmeasured})"
    log "  config: ${fingerprint}"
    log "  gpu env marker: ${gpu_env}"
  fi

  if [ -n "${reason}" ]; then
    hosts_skipped=$((hosts_skipped + 1))
    if [ -n "${apply}" ]; then
      # Nothing was compared, so this box keeps whatever it ran with before — exactly
      # the drift --apply exists to prevent. That is a failure to act, not a clean run.
      hosts_failed=$((hosts_failed + 1))
      log "  error: --apply refused for ${host}: nothing could be read over ssh, so its settings were not compared with the other two hosts (check --user/--port or SPARK_SSH_USER)"
    fi
    continue
  fi
  hosts_ready=$((hosts_ready + 1))

  # Drift: the file next to start.sh and the environment the running container was
  # started with, both against the override file this script would write right now.
  drift=""
  while IFS= read -r key; do
    want="$(want_value "${key}" "${local_env}")"
    have="$(live_value "${key}" "${report}")"
    if [ -n "${have}" ] && [ "${have}" != "${want}" ]; then
      drift="${drift}${drift:+; }${key}=${have} (want ${want})"
    fi
  done <<EOF2
$(sed -n 's|^recipe\.[A-Z_0-9]*=.*|\1|p' "${report}")
EOF2

  if [ -n "${drift}" ]; then
    log "  drift: ${drift}"
    if [ -z "${apply}" ]; then
      log "  note: nothing was written (assert-only mode) — add --apply to write ${local_env}"
    fi
  else
    log "  config: the live container and the recipe's .env already agree with what this script would write"
  fi

  parallel_now="$(live_value PARALLEL "${report}")"
  case "${parallel_now}" in
    '' | NOTSET | [1-5]) ;;
    *)
      log "  note: PARALLEL=${parallel_now} is above the recipe default of 5 — the escape hatch the recipe documents for a box ALSO running other GPU work is 4, and nothing above 5 is supported (see docs/v061.md)"
      ;;
  esac
  kv_now="$(live_value KV_DTYPE "${report}")"
  case "${kv_now}" in
    int4 | bf16)
      log "  note: KV_DTYPE=${kv_now} — int8 is the recipe default, it halves KV memory against bf16, and it does change outputs against full precision; do not mix dtypes across the three boxes"
      ;;
  esac

  if [ -z "${apply}" ]; then
    continue
  fi

  # ── --apply ──
  candidate="${work}/${host}.env"
  {
    printf '%s\n' \
      "# Generated by ./scripts/spark-configure.sh --apply — NOT a fork of the recipe." \
      "# Every key below is optional (start.sh sources this after scripts/config.sh, so" \
      '# an omitted key is not "unset"), and the three Sparks must agree on all of them.' \
      "# PARALLEL 5 is the recipe default; 4 is the escape hatch for a box ALSO running" \
      "# other GPU work. TENSORFOLD_MEMORY_RESERVE_GIB 2 is already the floor." \
      "# KV_DTYPE int8 halves KV memory against bf16, is the recipe default, and does" \
      "# change outputs against full precision — which is why no box runs bf16."
    for entry in $keys; do
      printf '%s\n' "${entry}"
    done
    printf '\n'
  } >"${candidate}"

  if [ ! -f "${local_env}" ]; then
    mkdir -p sparks
    if cp "${candidate}" "${local_env}"; then
      log "  changed: ${local_env} (written; gitignored, and the input to spark-verify.sh's drift and readiness checks)"
    else
      log "  error: --apply refused for ${host}: ${local_env} could not be written"
      hosts_failed=$((hosts_failed + 1))
    fi
  elif cmp -s "${candidate}" "${local_env}"; then
    log "  config: ${local_env} already holds the fleet's values (unchanged)"
  else
    if cp "${candidate}" "${local_env}"; then
      log "  changed: ${local_env} (rewritten with the fleet's values)"
    else
      log "  error: --apply refused for ${host}: ${local_env} could not be rewritten"
      hosts_failed=$((hosts_failed + 1))
    fi
  fi

  # A cold server is never started here, so there is nothing to reconfigure on a box
  # that is not serving: copying .env there would only make start.sh pay a full
  # prepare run the moment someone does start one, with nothing to verify afterwards.
  if [ "${container_state}" = absent ]; then
    log "  note: nothing was copied to ${host} (no running server to reconfigure, and this script never starts a cold one) — start it first, then re-run with --apply"
    continue
  fi
  if [ "${gpu_env}" = present ]; then
    log "  note: ${host} runs the server outside any recipe clone, so start.sh restart cannot re-derive its settings and this script will not run docker rm/create through ssh. Take it through the recipe instead, or recreate it by hand and read the streaming requests that would die first:"
    log "        docker stop ${container} && docker run --rm -it --gpus all --network host --shm-size 32G --name ${container} -e TENSORFOLD_DISABLE_MTP=1 -e CUDA_VISIBLE_DEVICES=0 tensorfold/decode-native:0.6.1-cu130 ./start.sh --serve"
    log "        (the -e list is what this script compares: add the twelve keys above to that command, or to the container's env_file, before restarting)"
    continue
  fi
  if [ "${clone_state}" != present ]; then
    log "  note: no recipe clone at ${recipe_dir} and no start.sh to restart with — put the recipe there first (git clone --depth 1 ${recipe_repo} ${recipe_dir} on the Spark), then re-run with --apply"
    continue
  fi
  if [ ! -s "${models}" ] || ! grep -qF "${model_id}" "${models}"; then
    log "  warn: ${host} served no model id under the fleet's spelling over HTTP, so this script cannot tell what that container was started with; nothing was copied to ${host} (a copied .env that start.sh reads on the next start would reconfigure a server this run cannot see)"
    continue
  fi

  # Both remote copies are the same file, so one transfer carries it: the recipe-dir
  # copy is what start.sh reads on the next start, and the copy inside the container is
  # what a recreate would read without a restart.
  if ssh_run "${target}" "cat > '${recipe_dir}/.env' && docker cp '${recipe_dir}/.env' '${container}:${container_env}'"; then
    log "  changed: ${recipe_dir}/.env and ${container}:${container_env} on ${host} (identical content, from ${local_env})"
  else
    log "  error: --apply could not write ${recipe_dir}/.env on ${host}"
    hosts_failed=$((hosts_failed + 1))
    continue
  fi

  if [ -n "${restart}" ]; then
    if [ "${container_state}" = absent ]; then
      log "  note: --restart skipped: no container named ${container} on ${host}, and this script never starts a cold server"
    elif [ "${gpu_env}" = present ]; then
      log "  note: --restart skipped: ${host} runs the server outside any recipe clone, so there is no start.sh to restart with (see the hand-run command above)"
    else
      log "  restarting the server through the recipe's start.sh, so prepare.sh runs only if the recipe thinks anything really changed (expect ~2.5 s per stream of weight load, not a full 5-15 minute setup) ..."
      restart_rc=0
      restart_out="$(ssh_run "${target}" "cd '${recipe_dir}' && ./start.sh restart" "${timeout_s}")" || restart_rc=$?
      if [ "${restart_rc}" != 0 ]; then
        log "  error: --apply could not restart the server (exit ${restart_rc})"
        printf '%s\n' "${restart_out}"
        hosts_failed=$((hosts_failed + 1))
      elif printf '%s\n' "${restart_out}" | grep -qF "${model_id}"; then
        log "  ok: start.sh restart answered — ${host} is serving again"
      else
        log "  warn: start.sh restart returned no error but never printed the serving line, so ${host} is probably NOT serving again"
        printf '%s\n' "${restart_out}"
        hosts_failed=$((hosts_failed + 1))
      fi
    fi
  fi
done

if [ "${hosts_checked}" = "${#hosts[@]}" ] && [ "${hosts_skipped}" != "${hosts_checked}" ]; then
  log ""
  log "summary: ${hosts_checked} of ${#hosts[@]} host(s) checked (${hosts_ready} with a server to compare against) and ${hosts_failed} failed — see the lines above (no host was skipped, so no SPARK_HOSTS or SPARK_SSH_USER short-circuit applies)"
elif [ "${hosts_skipped}" = "${hosts_checked}" ]; then
  log ""
  log "summary: no Spark could be reached with these credentials, so nothing was verified"
  log "note: none of the ${#hosts[@]} host(s) answered over ssh — check SPARK_HOSTS (spark-1.lan/2/3 are placeholders, not addresses) and SPARK_SSH_USER, or pass --user/--port; this is a \"not yet\" state, so the exit code stays 0"
fi

if [ -n "${apply}" ] && [ "${hosts_failed}" != 0 ]; then
  exit 1
fi
exit 0
