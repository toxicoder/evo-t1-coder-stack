#!/bin/sh
# shellcheck shell=sh
#
# ## probes/spark-verify.sh — Print what one Spark box runs with — docker, runtimes, disk, memory, recipe env — as key=value lines for one ssh round trip (POSIX probe; run with sh, never sourced by the remote)

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
    # shellcheck disable=SC2154 # test_cap comes from the caller's leading assignments
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
  if [ "${NEEDLE_WANTED}" != yes ]; then
    # The 195k needle is the window proof, and it is the one probe that is not free to
    # schedule: it prefills 195k tokens the server has never seen, so the server evicts
    # warm prompt state to make room and the conversations that were riding on that
    # prefix re-prefill in full. The caller skips it while the box has work in flight;
    # --needle on the caller is what sets this back to yes.
    say "needle=skipped (the box had requests running; the 195k window proof evicts the server's warm prompt state and holds a stream for minutes -- re-run on a quiet box, or pass --needle to force it)"
  elif [ -f scripts/needle.py ]; then
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
