#!/usr/bin/env bats
#
# ## hermes-doctor.bats — hermetic coverage for scripts/hermes-doctor.sh.
#
# What is pinned here, in the order the audit has to hold it:
#
#   The tool is a report with teeth. A clean bill exits 0; a check that failed
#   exits 1 and says which one in the summary; a bad invocation exits 2 and
#   prints the usage block; a checkout it cannot find exits 5.
#
#   Every posture claim is checked against a mutated fixture, so the assertion
#   is that the audit *notices*. Approvals moved off manual, a keyless switch
#   turned back on, the search backend swapped for a vendor's free tier, a
#   vendor credential in the container, an unrendered working directory, a
#   relative one, a STACK_HOST_PATH naming a directory with no compose file, an
#   off-pin image, the shipped placeholder key, an unset dashboard pair, a
#   password equal to its own username, an mcp_servers block the gates never
#   saw — each has to land as a failure or a warning, with the name of the
#   thing that drifted in the line.
#
#   It reads, it does not write. A full report must ask the daemon nothing but
#   inspect and ps, and --dry-run must invoke docker zero times while printing
#   the compose line it would have run.
#
#   It keeps a secret out of its own output. The model key and the vendor key
#   are reported by name; the value that was put into the fixture must not
#   appear anywhere in the report.
#
#   The drift comparison forgives the render and nothing else: a volume whose
#   cwd was rendered to the host's path matches, and an operator's edit to any
#   other line is called out by file name.
#
# Hermetic by construction. Every run gets a scratch checkout (the marker
# compose file plus its own hermes/ seed pair), a scratch data directory, a
# scratch dotenv, and a scratch docker CLI that answers the four questions this
# audit asks from environment knobs. Nothing reaches a daemon, a socket, or the
# stack's real hermes/ tree — except the two tests that bless the shipped seed,
# which point REPO_ROOT at the checkout on purpose.
#
# Usage: bazelisk test //tests:bats_hermes_doctor_test   (from any cwd)
# Safety: scratch directories only. No Docker, no daemon, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

CANONICAL_ROOT=""
SCRIPT=""
SCRATCH=""
CHECKOUT=""
VOL=""

# setup - build the world one run of the audit reads: a scratch checkout that
# resolve_checkout will accept, its seed pair, its dotenv, a data directory, and
# a docker CLI that answers only from the knobs a test sets.
# Globals:
#   CANONICAL_ROOT, SCRIPT, SCRATCH, CHECKOUT, VOL, STUB_LOG, REPO_ROOT, PATH
# Arguments:
#   None
# Outputs:
#   One scratch tree under BATS_TEST_TMPDIR
# Returns:
#   0, or a skip when the script or the repo root is not available
setup() {
  CANONICAL_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${CANONICAL_ROOT}/scripts/hermes-doctor.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/hermes-doctor.sh is not in the tree"
  fi

  SCRATCH="$(make_scratch)"
  CHECKOUT="${SCRATCH}/checkout"
  VOL="${SCRATCH}/volume"
  STUB_LOG="${SCRATCH}/stub-logs"
  mkdir -p "${CHECKOUT}/hermes" "${VOL}" "${SCRATCH}/bin" "${STUB_LOG}"

  # The checkout the audit resolves. The compose file carries the same pin the
  # stack ships, because check_image_pin compares a live container against it.
  printf 'services:\n  hermes:\n    image: nousresearch/hermes-agent:v0.22.5\n' >"${CHECKOUT}/docker-compose.yml"
  printf 'You are the host assistant.\n' >"${CHECKOUT}/hermes/SOUL.md"
  # The coding-agent control plane the assistant is meant to be able to reach. The
  # default world is a healthy one, so a clean bill stays clean; the test that wants
  # the audit to notice removes this file.
  mkdir -p "${CHECKOUT}/scripts"
  printf '#!/usr/bin/env bash\n' >"${CHECKOUT}/scripts/coder-sessions.sh"
  write_default_seed
  write_env "LITELLM_MASTER_KEY=real-model-key-value" \
    "HERMES_DASHBOARD_USER=operator" \
    "HERMES_DASHBOARD_PASSWORD=a-long-passphrase" \
    "HERMES_DASHBOARD_SECRET=a-long-secret" \
    "STACK_HOST_PATH=${CHECKOUT}"

  write_docker_stub "${SCRATCH}/bin/docker"
  PATH="$(with_path "${SCRATCH}/bin")"
  export PATH STUB_LOG REPO_ROOT="${CHECKOUT}"
  # The report helpers every check calls come from the lib, so a unit can be
  # driven on its own. Sourced after the skips above: the lib defines its own
  # skip(), and a suite that shadowed bats's would stop skipping out loud.
  # shellcheck source=/dev/null
  source "${CANONICAL_ROOT}/scripts/lib/common.sh"
  # The audit falls back to these when the dotenv is silent; a value inherited
  # from the developer's shell would make a fixture mean something different on
  # every machine.
  unset STACK_HOST_PATH STUB_PS_OUT STUB_PS_NAMES STUB_ENV_FILE STUB_IMAGE \
    STUB_VOLUME_NAME STUB_VOLUME_MOUNT STUB_MOUNTS
}

# write_default_seed - the config this audit exists to bless: approvals gated
# three ways, a working directory the seeder still has to render, and the web
# toolset pinned to the stack's own instance with both keyless switches off.
# Globals:
#   CHECKOUT
# Arguments:
#   None
# Outputs:
#   One config.yaml in the scratch checkout's hermes/ directory
# Returns:
#   0
write_default_seed() {
  cat >"${CHECKOUT}/hermes/config.yaml" <<'YAML'
_config_version: 51
model:
  default: stack/coder
  provider: openai
  api_key: ${LITELLM_MASTER_KEY}
approvals:
  mode: manual
  cron_mode: deny
  unattended_mode: deny
terminal:
  backend: local
  cwd: ${STACK_HOST_PATH}
  timeout: 120
toolsets:
  - hermes-cli
  - web
web:
  search_backend: searxng
  keyless_fallback: false
  keyless_rescue: false
dashboard:
  enabled: true
  host: 0.0.0.0
memories:
  enabled: true
YAML
}

# seed_volume [CWD] - lay the data directory out the way hermes-bootstrap does:
# both files copied, every ${STACK_HOST_PATH} in the config replaced by CWD.
# Globals:
#   CHECKOUT, VOL
# Arguments:
#   $1 - the path to render into terminal.cwd (default: the scratch checkout)
# Outputs:
#   config.yaml and SOUL.md in the scratch data directory
# Returns:
#   0
seed_volume() {
  local rendered="${1:-${CHECKOUT}}"
  mkdir -p "${VOL}"
  # shellcheck disable=SC2016  # ${STACK_HOST_PATH} is the literal seed token
  sed "s|\${STACK_HOST_PATH}|${rendered}|g" "${CHECKOUT}/hermes/config.yaml" >"${VOL}/config.yaml"
  cp "${CHECKOUT}/hermes/SOUL.md" "${VOL}/SOUL.md"
}

# write_env KEY=VALUE... - the dotenv compose would have interpolated at create
# time. The audit reads it as the intention behind the container.
# Globals:
#   CHECKOUT
# Arguments:
#   $@ - each one KEY=VALUE
# Outputs:
#   One .env beside the scratch compose file
# Returns:
#   0
write_env() {
  local kv
  : >"${CHECKOUT}/.env"
  for kv in "$@"; do
    printf '%s\n' "${kv}" >>"${CHECKOUT}/.env"
  done
}

# container_env KEY=VALUE... - the environment the container was *created* with,
# which is the fact the audit trusts, and the container id that owns it.
# Globals:
#   SCRATCH, STUB_ENV_FILE, STUB_PS_OUT
# Arguments:
#   $@ - each one KEY=VALUE
# Outputs:
#   One file the docker stub replays for a .Config.Env inspect
# Returns:
#   0
container_env() {
  local kv
  : >"${SCRATCH}/container.env"
  for kv in "$@"; do
    printf '%s\n' "${kv}" >>"${SCRATCH}/container.env"
  done
  export STUB_ENV_FILE="${SCRATCH}/container.env" STUB_PS_OUT="cafebabe01"
}

# write_docker_stub <path> - the four answers this audit asks the daemon, from
# knobs, recording every argv so the read-only promise is checkable.
#   STUB_PS_OUT         the id `compose ps -q` prints (empty = nothing running)
#   STUB_PS_NAMES       names `docker ps` prints (the label lookup fallback)
#   STUB_ENV_FILE       file of KEY=VALUE lines a .Config.Env inspect replays
#   STUB_IMAGE          what .Config.Image reports
#   STUB_VOLUME_NAME    the volume `volume ls` finds for the project
#   STUB_VOLUME_MOUNT   its Mountpoint
# Globals:
#   STUB_LOG
# Arguments:
#   $1 - where to write the stub
# Outputs:
#   One executable stub
# Returns:
#   0
write_docker_stub() {
  local target="${1}"
  mkdir -p "$(dirname "${target}")"
  cat >"${target}" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "docker $*" >>"${STUB_LOG}/docker.log"; fi
case "$*" in
  *"volume ls"*)
    if [ -n "${STUB_VOLUME_NAME:-}" ]; then printf '%s\n' "${STUB_VOLUME_NAME}"; fi
    exit 0
    ;;
  *"volume inspect"*)
    if [ -n "${STUB_VOLUME_MOUNT:-}" ]; then printf '%s\n' "${STUB_VOLUME_MOUNT}"; fi
    exit 0
    ;;
  *"ps -q"*)
    if [ -n "${STUB_PS_OUT:-}" ]; then printf '%s\n' "${STUB_PS_OUT}"; fi
    exit 0
    ;;
  *"ps --format"*)
    if [ -n "${STUB_PS_NAMES:-}" ]; then printf '%s\n' "${STUB_PS_NAMES}"; fi
    exit 0
    ;;
  *inspect*)
    case "$*" in
      *".Config.Env"*)
        if [ -n "${STUB_ENV_FILE:-}" ] && [ -f "${STUB_ENV_FILE}" ]; then cat "${STUB_ENV_FILE}"; fi
        exit 0
        ;;
      *".Mounts"*)
        # One source path per line, the way the range over .Mounts prints them.
        if [ -n "${STUB_MOUNTS:-}" ]; then printf '%s\n' "${STUB_MOUNTS}"; fi
        exit 0
        ;;
      *".Config.Image"*)
        if [ -n "${STUB_IMAGE:-}" ]; then printf '%s\n' "${STUB_IMAGE}"; fi
        exit 0
        ;;
      *)
        # A container exists for the purpose of an id probe whenever any id
        # source is set, whether it came from compose or from the label lookup.
        if [ -n "${STUB_PS_OUT:-}${STUB_PS_NAMES:-}" ]; then
          printf '%s\n' "${STUB_PS_OUT:-${STUB_PS_NAMES}}"
        fi
        exit 0
        ;;
    esac
    ;;
esac
exit 0
STUB
  chmod 755 "${target}"
}

# run_doctor <args...> - audit the scratch project with the data directory in
# reach, which is what an operator on the stack host gets.
# Globals:
#   SCRIPT, CHECKOUT, VOL
# Arguments:
#   $@ - flags and the subcommand
# Outputs:
#   Captured into BATS's `output`
# Returns:
#   Captured into BATS's `status`
run_doctor() {
  run bash "${SCRIPT}" --file "${CHECKOUT}/docker-compose.yml" --data "${VOL}" "$@"
}

# run_doctor_bare <args...> - the same, with no data directory to read, which is
# the shape of a run from a laptop that has the checkout but not the volume.
# Globals:
#   SCRIPT, CHECKOUT
# Arguments:
#   $@ - flags and the subcommand
# Outputs:
#   Captured into BATS's `output`
# Returns:
#   Captured into BATS's `status`
run_doctor_bare() {
  run bash "${SCRIPT}" --file "${CHECKOUT}/docker-compose.yml" --data "${SCRATCH}/no-such-volume" "$@"
}

# assert_status <want> <label> - fail with the whole report attached, so a
# misread verdict is debuggable from the test log alone.
# Globals:
#   status, output
# Arguments:
#   $1 - the exit status the run should have produced
#   $2 - what the run was
# Outputs:
#   The report on stderr when the status is wrong
# Returns:
#   0 when it matches, 1 when it does not
assert_status() {
  if [ "${status}" -ne "${1}" ]; then
    printf 'FAIL: %s: expected exit %s, got %s\n--- output ---\n%s\n' "$2" "${1}" "${status}" "${output}" >&2
    return 1
  fi
}

# assert_report_has <label> <regex> - the report must say this.
# Globals:
#   output
# Arguments:
#   $1 - what the line is
#   $2 - the regex it must match
# Outputs:
#   The report on stderr when nothing matched
# Returns:
#   0 when found, 1 when absent
assert_report_has() {
  if ! printf '%s\n' "${output}" | grep -Eq -- "$2"; then
    printf 'FAIL: %s: no line matched /%s/\n--- output ---\n%s\n' "$1" "$2" "${output}" >&2
    return 1
  fi
}

# assert_report_lacks <label> <regex> - the report must never say this.
# Globals:
#   output
# Arguments:
#   $1 - what must not appear
#   $2 - the regex that must not match
# Outputs:
#   The report on stderr when it did match
# Returns:
#   0 when absent, 1 when present
assert_report_lacks() {
  if printf '%s\n' "${output}" | grep -Eq -- "$2"; then
    printf 'FAIL: %s: unexpected match for /%s/\n--- output ---\n%s\n' "$1" "$2" "${output}" >&2
    return 1
  fi
}

# ── the shape of the tool ────────────────────────────────────────────────────

@test "doctor: --help exits 0 and names every check the tool can run" {
  run bash "${SCRIPT}" --help
  assert_status 0 "--help"
  # checks_for is the roster the tool actually runs; the usage block has to
  # agree with it, so the pair is compared rather than each pinned by hand.
  load_shell_function "${SCRIPT}" checks_for || fail "could not load checks_for from the CLI"
  local name
  for name in $(checks_for report); do
    assert_report_has "the usage block lists ${name}" "(^| )${name}( |$)"
  done
}

@test "doctor: the subcommand views are re-orderings of the same checks" {
  load_shell_function "${SCRIPT}" checks_for || fail "could not load checks_for"
  local view name all
  all="$(checks_for report)"
  # A view is a re-ordering of the same checks, never a second implementation.
  assert_match "posture opens on the gate" '^approvals$' "$(checks_for posture)"
  assert_match "web opens on the lane" '^web-lane$' "$(checks_for web)"
  assert_match "diff opens on the pair" '^seed-drift$' "$(checks_for diff)"
  for view in posture web diff; do
    while read -r name; do
      [ -n "${name}" ] || continue
      assert_match "${view} draws on a check report runs too" "^${name}$" "${all}"
    done < <(checks_for "${view}")
  done
}

@test "doctor: an unknown subcommand is a usage error that prints the usage block" {
  run_doctor diagnose
  assert_status 2 "an unknown subcommand"
  assert_report_has "names the mistake" 'unknown subcommand: diagnose'
  assert_report_has "prints the usage block" '^usage: bazelisk run //scripts:hermes-doctor'
}

@test "doctor: an unknown flag is a usage error" {
  run_doctor --frobnicate
  assert_status 2 "an unknown flag"
  assert_report_has "names the flag" 'unknown option: --frobnicate'
}

@test "doctor: a flag with no value is refused before any check runs" {
  run_doctor --data
  assert_status 1 "--data with no value"
  assert_report_has "names the flag" '^error: --data needs a value'
  assert_report_lacks "no report was started" 'summary:'
}

@test "doctor: an unknown check name is a usage error" {
  run_doctor --check vibes
  assert_status 2 "an unknown check name"
  assert_report_has "names the check" 'unknown check: vibes'
}

@test "doctor: --check outranks the subcommand and runs exactly that one" {
  seed_volume
  run_doctor report --check approvals
  assert_status 0 "--check approvals"
  assert_report_has "ran the one check" '^== approvals ==$'
  assert_report_lacks "ran nothing else" '^== memories ==$'
}

@test "doctor: the report prints one section per check and one summary" {
  seed_volume
  run_doctor
  assert_status 0 "the full report"
  assert_report_has "opens with the project" '^== Hermes doctor \(report\) on evo-t1-prod ==$'
  assert_report_has "closes with the tally" '^summary: [0-9]+ ok, [0-9]+ warnings, [0-9]+ failed$'
  local sections want
  sections="$(printf '%s\n' "${output}" | grep -c '^== ')"
  # Derived from the roster rather than counted by hand: the day a check is added is
  # not the day this assertion should start lying.
  load_shell_function "${SCRIPT}" checks_for || fail "could not load checks_for from the CLI"
  want="$(( $(checks_for report | wc -l) + 1 ))"
  [ "${sections}" -eq "${want}" ] || \
    fail "expected $(($(checks_for report | wc -l))) check sections plus the header, got ${sections}"
}

# ── the shipped seed is the good case ────────────────────────────────────────

@test "doctor: the seed this repo ships passes the posture view" {
  export REPO_ROOT="${CANONICAL_ROOT}"
  run_doctor posture
  assert_status 0 "posture on the shipped seed"
  assert_report_has "approvals are gated" 'ok: approvals: manual, with cron and unattended both deny'
  assert_report_has "nothing failed" '^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$'
}

@test "doctor: the seed keeps every web search on the stack's own instance" {
  export REPO_ROOT="${CANONICAL_ROOT}"
  run_doctor web
  assert_status 0 "web on the shipped seed"
  assert_report_has "names the pin" 'ok: web lane: pinned to searxng, both keyless switches off'
}

# ── approvals: the gate on the docker socket ─────────────────────────────────

@test "doctor: approvals moved off manual is a failure" {
  sed -i 's/^  mode: manual/  mode: smart/' "${CHECKOUT}/hermes/config.yaml"
  run_doctor --check approvals
  assert_status 1 "approvals on smart"
  assert_report_has "says what stopped being pinned" 'the seed no longer pins mode: manual'
  assert_report_has "names the consequence" 'every flagged command can run unasked'
}

@test "doctor: an approval mode that a timer can answer is a failure" {
  sed -i 's/^  cron_mode: deny/  cron_mode: approve/' "${CHECKOUT}/hermes/config.yaml"
  run_doctor --check approvals
  assert_status 1 "cron_mode on approve"
  assert_report_has "names the switch" 'cron_mode: deny'
}

@test "doctor: a seed with no approvals block at all is a failure" {
  printf 'model:\n  default: stack/coder\n' >"${CHECKOUT}/hermes/config.yaml"
  run_doctor --check approvals
  assert_status 1 "a seed with no approvals block"
  assert_report_has "lists all three pins it missed" 'the seed no longer pins mode: manual cron_mode: deny unattended_mode: deny'
}

# ── the web lane: the local-only promise ─────────────────────────────────────

@test "doctor: a keyless fallback turned back on is a failure" {
  sed -i 's/^  keyless_fallback: false/  keyless_fallback: true/' "${CHECKOUT}/hermes/config.yaml"
  run_doctor web
  assert_status 1 "keyless_fallback on"
  assert_report_has "names the switch that moved" 'web.keyless_fallback'
  assert_report_has "names the consequence" "a search can reach a vendor's free tier"
}

@test "doctor: the rescue switch turned back on is a failure" {
  sed -i 's/^  keyless_rescue: false/  keyless_rescue: true/' "${CHECKOUT}/hermes/config.yaml"
  run_doctor web
  assert_status 1 "keyless_rescue on"
  assert_report_has "names the switch that moved" 'web.keyless_rescue'
}

@test "doctor: pointing the search capability at a vendor is a failure" {
  sed -i 's/^  search_backend: searxng/  search_backend: brave-free/' "${CHECKOUT}/hermes/config.yaml"
  run_doctor web
  assert_status 1 "the backend swapped for a vendor"
  assert_report_has "names the pin that went missing" 'web.search_backend'
}

@test "doctor: a container with no SEARXNG_URL has no lane at all" {
  container_env "PATH=/usr/bin"
  run_doctor --check web-lane
  assert_status 0 "a lane that never registered"
  assert_report_has "says the provider never registers" 'SEARXNG_URL is not set in the container'
}

@test "doctor: a container with SEARXNG_URL is reported by value" {
  container_env "SEARXNG_URL=http://searxng:8181"
  run_doctor --check web-lane
  assert_status 0 "a registered lane"
  assert_report_has "prints the route it will dial" 'ok: SEARXNG_URL: http://searxng:8181'
}

@test "doctor: a vendor credential in the container is called out by name" {
  container_env "SEARXNG_URL=http://searxng:8181" "TAVILY_API_KEY=tvly-super-secret-value"
  run_doctor --check keyless-egress
  assert_status 0 "a vendor key present"
  assert_report_has "names the key" 'a web vendor credential is in this container: TAVILY_API_KEY'
  assert_report_lacks "never prints the key's value" 'tvly-super-secret-value'
}

@test "doctor: a container holding only the model key is clean" {
  container_env "SEARXNG_URL=http://searxng:8181" "LITELLM_MASTER_KEY=real-model-key-value"
  run_doctor --check keyless-egress
  assert_status 0 "no vendor key"
  assert_report_has "says the assistant holds one key" 'no web vendor credential present'
}

@test "doctor: an mcp_servers block the gates never saw is a warning" {
  printf 'mcp_servers:\n  context7:\n    command: npx\n' >>"${CHECKOUT}/hermes/config.yaml"
  run_doctor --check mcp-servers
  assert_status 0 "an mcp block in the seed"
  assert_report_has "says the gates never saw it" 'the gates here never saw those tools'
}

# ── the working directory: the bug that hid as health ────────────────────────

@test "doctor: an unrendered working directory is a failure with the fix named" {
  seed_volume '${STACK_HOST_PATH}'
  run_doctor --check terminal-cwd
  assert_status 1 "a token left in terminal.cwd"
  assert_report_has "says it is still a token" 'the seeded working directory is still a token'
  assert_report_has "names the command that renders it" 'hermes-bootstrap --data <mount> --force renders it'
}

@test "doctor: a rendered working directory that exists is clean" {
  seed_volume "${CHECKOUT}"
  run_doctor --check terminal-cwd
  assert_status 0 "a rendered cwd"
  assert_report_has "reports the path and that it is a directory" "ok: terminal.cwd: ${CHECKOUT}, and it is a directory"
}

@test "doctor: a relative working directory is a failure" {
  seed_volume "relative/path"
  run_doctor --check terminal-cwd
  assert_status 1 "a relative cwd"
  assert_report_has "says Hermes resolves it against the gateway's start" 'terminal.cwd is not an absolute path'
}

@test "doctor: a cwd that exists only inside the container is a warning" {
  seed_volume '/opt/stack'
  container_env "SEARXNG_URL=http://searxng:8181"
  run_doctor --check terminal-cwd
  assert_status 0 "a container-side cwd"
  assert_report_has "says it has to exist inside the container" 'it has to exist inside the container'
}

@test "doctor: a seed that names no working directory is warned about" {
  sed -i '/^  cwd: /d' "${CHECKOUT}/hermes/config.yaml"
  run_doctor --check terminal-cwd
  assert_status 0 "a seed with no cwd"
  assert_report_has "says the assistant inherits the gateway's cwd" 'the seed names no terminal.cwd'
}

# ── the mount: the shape that hid on a live box ──────────────────────────────

@test "doctor: a STACK_HOST_PATH naming no checkout is a failure" {
  write_env "STACK_HOST_PATH=${SCRATCH}/nowhere"
  mkdir -p "${SCRATCH}/nowhere"
  run_doctor --check mount-identity
  assert_status 1 "a mount that is not the stack"
  assert_report_has "names the directory it checked" 'which holds no docker-compose.yml'
  assert_report_has "says what the assistant is mounting" 'a directory that is not the stack'
}

@test "doctor: a STACK_HOST_PATH that is the checkout is clean" {
  run_doctor --check mount-identity
  assert_status 0 "a mount that is the stack"
  assert_report_has "reports the path and the file it found" 'ok: STACK_HOST_PATH: .* and the compose file is there'
}

@test "doctor: a relative STACK_HOST_PATH is a failure" {
  write_env "STACK_HOST_PATH=opt/stack"
  run_doctor --check mount-identity
  assert_status 1 "a relative mount source"
  assert_report_has "says compose would mount it relative to the invocation" 'STACK_HOST_PATH is not absolute'
}

@test "doctor: no STACK_HOST_PATH anywhere warns about the compose fallback" {
  write_env "LITELLM_MASTER_KEY=real-model-key-value"
  run_doctor --check mount-identity
  assert_status 0 "no mount key at all"
  assert_report_has "names the .:/opt/stack fallback" 'STACK_HOST_PATH is unset'
}

# ── the image pin, the model key, the dashboard door ─────────────────────────

@test "doctor: a container on an off-pin image is a warning naming both tags" {
  seed_volume
  export STUB_PS_OUT="cafebabe01" STUB_IMAGE="nousresearch/hermes-agent:v0.23.0"
  run_doctor --check image-pin
  assert_status 0 "an off-pin container"
  assert_report_has "names what is running and what is pinned" \
    'running nousresearch/hermes-agent:v0.23.0, this checkout pins nousresearch/hermes-agent:v0.22.5'
  assert_report_has "says why the pair matters" 'the docs and the agent may disagree'
}

@test "doctor: a container on the pin is clean" {
  seed_volume
  export STUB_PS_OUT="cafebabe01" STUB_IMAGE="nousresearch/hermes-agent:v0.22.5"
  run_doctor --check image-pin
  assert_status 0 "an on-pin container"
  assert_report_has "reports the pin" 'ok: image: nousresearch/hermes-agent:v0.22.5, the pin this checkout names'
}

@test "doctor: no container running leaves the pin as the only fact" {
  run_doctor --check image-pin
  assert_status 0 "no container at all"
  assert_report_has "says only the pin is known" 'the container is not running, so only the pin is known'
}

@test "doctor: the shipped placeholder model key is a failure" {
  write_env "LITELLM_MASTER_KEY=change-me-not-actually-a-key"
  run_doctor --check model-key
  assert_status 1 "the placeholder key"
  assert_report_has "says the container boots and every call is refused" 'still the shipped placeholder'
}

@test "doctor: a real model key is reported without its value" {
  container_env "LITELLM_MASTER_KEY=a-real-secret-model-key"
  run_doctor --check model-key
  assert_status 0 "a real key"
  assert_report_has "says the key is set" 'ok: model key: LITELLM_MASTER_KEY is set'
  assert_report_lacks "never prints the key itself" 'a-real-secret-model-key'
}

@test "doctor: a model key set nowhere is a failure" {
  write_env "HERMES_DASHBOARD_USER=operator"
  run_doctor --check model-key
  assert_status 1 "no key anywhere"
  assert_report_has "says there is no model transport" 'the assistant has no model transport'
}

@test "doctor: an unset dashboard credential is a warning naming the key" {
  write_env "LITELLM_MASTER_KEY=real-model-key-value" \
    "HERMES_DASHBOARD_USER=operator" \
    "HERMES_DASHBOARD_PASSWORD=a-long-passphrase"
  run_doctor --check dashboard
  assert_status 0 "one unset dashboard key"
  assert_report_has "names the missing key" 'HERMES_DASHBOARD_SECRET is unset'
}

@test "doctor: a dashboard password equal to its username is a warning" {
  write_env "HERMES_DASHBOARD_USER=operator" \
    "HERMES_DASHBOARD_PASSWORD=operator" \
    "HERMES_DASHBOARD_SECRET=a-long-secret"
  run_doctor --check dashboard
  assert_status 0 "a password that is the username"
  assert_report_has "says the pair is the same string" 'the basic-auth user and the password are the same string'
  assert_report_lacks "never prints the credential" 'operator'
}

@test "doctor: a healthy dashboard is one ok line, not two" {
  # The audit's value is that one line means one fact. The duplicate also made the
  # function's status depend on whether anything had failed, which is the contract
  # every check here breaks by returning 0 always.
  run_doctor --check dashboard
  assert_status 0 "a healthy dashboard"
  [ "$(printf '%s\n' "${output}" | grep -c 'basic auth is set on all three keys')" -eq 1 ] || \
    fail "the dashboard verdict printed more than once"
}

@test "doctor: a dashboard on plain http is a warning" {
  container_env "HERMES_DASHBOARD_USER=operator" "HERMES_DASHBOARD_PASSWORD=a-long-passphrase" \
    "HERMES_DASHBOARD_SECRET=a-long-secret" "HERMES_DASHBOARD_PUBLIC_URL=http://hermes.example.test"
  run_doctor --check dashboard
  assert_status 0 "a public URL on http"
  assert_report_has "names the router's https" 'public URL is plain http'
}

# ── the volume against the seed ──────────────────────────────────────────────

@test "doctor: a volume the seeder rendered is not drift" {
  seed_volume '/opt/src/evo-t1-coder-stack'
  run_doctor --check seed-drift
  assert_status 0 "a rendered volume"
  assert_report_has "says the copies match" 'ok: seed drift: the volume copy matches this checkout'
}

@test "doctor: an operator's edit inside the volume is named by file" {
  seed_volume
  printf '\nsafety:\n  redaction:\n    enabled: false\n' >>"${VOL}/config.yaml"
  run_doctor --check seed-drift
  assert_status 0 "an edited volume copy"
  assert_report_has "names the file that differs" 'the volume copy differs from the seed: config.yaml'
  assert_report_has "names the command that re-seeds" 'hermes-bootstrap --data <mount> --force re-seeds it'
}

@test "doctor: a volume missing a seeded file says so" {
  mkdir -p "${VOL}"
  cp "${CHECKOUT}/hermes/config.yaml" "${VOL}/config.yaml"
  run_doctor --check seed-drift
  assert_status 0 "a volume with one file"
  assert_report_has "names the missing file" 'the volume holds no SOUL.md'
}

@test "doctor: SOUL.md is compared byte for byte" {
  seed_volume
  printf 'and a line the operator added\n' >>"${VOL}/SOUL.md"
  run_doctor --check seed-drift
  assert_status 0 "an edited SOUL.md"
  assert_report_has "names the file that differs" 'differs from the seed:.*SOUL.md'
}

@test "doctor: a seed file that is gone from the checkout is a failure" {
  rm -f "${CHECKOUT}/hermes/config.yaml"
  run_doctor --check seed-drift
  assert_status 1 "a missing seed file"
  assert_report_has "names the file and the root" 'the seed file hermes/config.yaml is missing from'
}

@test "doctor: a volume out of reach is a note, not a failure" {
  run_doctor_bare --check seed-drift
  assert_status 0 "no volume to read"
  assert_report_has "says how to name one" 'seed drift: the volume is not readable from here'
}

@test "doctor: the volume is found through the daemon when --data is not given" {
  seed_volume
  export STUB_VOLUME_NAME="evo-t1-prod_hermes-data" STUB_VOLUME_MOUNT="${VOL}"
  run bash "${SCRIPT}" --file "${CHECKOUT}/docker-compose.yml" --check seed-drift
  assert_status 0 "a daemon-resolved volume"
  assert_report_has "read it and found it matching" 'ok: seed drift: the volume copy matches this checkout'
}

# ── the write fence and the memory store ─────────────────────────────────────

@test "doctor: the shipped write fence is reported as the fence working" {
  container_env "HERMES_WRITE_SAFE_ROOT=/opt/data"
  run_doctor --check write-root
  assert_status 0 "the shipped fence"
  assert_report_has "says a write outside the state is refused" 'ok: write root: /opt/data'
}

@test "doctor: a write fence widened past /opt/data is a warning" {
  container_env "HERMES_WRITE_SAFE_ROOT=/"
  run_doctor --check write-root
  assert_status 0 "a widened fence"
  assert_report_has "says it is wider than shipped" 'write root: /, which is wider than the shipped /opt/data fence'
}

@test "doctor: a .env in the data directory outranks the container" {
  seed_volume
  printf 'LITELLM_MASTER_KEY=from-the-volume\n' >"${VOL}/.env"
  run_doctor --check memories
  assert_status 0 "a .env in the volume"
  assert_report_has "says a key there outranks the environment" 'a key there outranks the container environment'
  assert_report_lacks "never prints the key's value" 'from-the-volume'
}

@test "doctor: a store that does not exist yet is a note" {
  seed_volume
  run_doctor --check memories
  assert_status 0 "no store yet"
  assert_report_has "says the assistant has not had a session" 'no SQLite store yet'
}

@test "doctor: a memory store in the volume is reported" {
  seed_volume
  : >"${VOL}/memories.sqlite"
  run_doctor --check memories
  assert_status 0 "a store present"
  assert_report_has "says a store is present" 'a store is present in the volume'
}

# ── the anywhere door: the API server and the push channel ──────────────────

@test "doctor: the shipped anywhere-door state is a clean bill, not a finding" {
  # An operator who never opened either door has to read healthy. A report that
  # warns about the shipped defaults is how a real finding gets skimmed past.
  run_doctor --check anywhere-door
  assert_status 0 "an API server that was never enabled is healthy"
  assert_report_has "says it is closed" 'api server: closed'
  assert_report_has "names the absent push channel as a note" 'no ntfy channel configured'
}

@test "doctor: an enabled API server on the placeholder key is a failure" {
  container_env API_SERVER_ENABLED=true API_SERVER_KEY=change-me-hermes-api
  run_doctor --check anywhere-door
  assert_status 1 "a door opened on a well-known key"
  assert_report_has "names the placeholder and the fix" 'shipped placeholder key'
}

@test "doctor: an enabled API server with no key is a failure, not a silent door" {
  container_env API_SERVER_ENABLED=true
  run_doctor --check anywhere-door
  assert_status 1 "no key at all"
  assert_report_has "says what the operator will experience" 'reads as a dead assistant'
}

@test "doctor: a keyed API server on a wide bind warns and never prints the token" {
  container_env API_SERVER_ENABLED=true API_SERVER_KEY=a-real-bearer-token
  write_env "HERMES_API_BIND=0.0.0.0"
  run_doctor --check anywhere-door
  assert_status 0 "keyed and reachable is a warning, not a failure"
  assert_report_has "names the interface it published on" 'HERMES_API_BIND=0[.]0[.]0[.]0'
  assert_report_lacks "never prints the bearer token" 'a-real-bearer-token'
}

@test "doctor: a loopback bind is the ok half of the same check" {
  container_env API_SERVER_ENABLED=true API_SERVER_KEY=a-real-bearer-token
  write_env "HERMES_API_BIND=127.0.0.1"
  run_doctor --check anywhere-door
  assert_report_has "says nothing off-host can dial it" 'published on loopback only'
}

@test "doctor: a wildcard CORS allowlist is called out" {
  container_env API_SERVER_ENABLED=true API_SERVER_KEY=a-key API_SERVER_CORS_ORIGINS='*'
  run_doctor --check anywhere-door
  assert_report_has "names the wildcard and what to do instead" 'never a wildcard'
}

@test "doctor: a push topic anyone can publish to is a warning" {
  # No allowlist is the recommended shape. With one, the topic is a two-way door
  # whose only credential is its name, so the audit has to say that out loud.
  seed_volume
  printf '%s\n' 'NTFY_TOPIC=s3cret-topic-name' 'NTFY_ALLOWED_USERS=s3cret-topic-name' \
    'NTFY_SERVER_URL=https://ntfy.example' >"${VOL}/.env"
  run_doctor --check anywhere-door
  assert_report_has "calls the channel open" 'inbound is open on this topic'
  assert_report_has "explains the identity model" 'every publisher to it is one identity'
  assert_report_lacks "never prints the topic" 's3cret-topic-name'
}

@test "doctor: the push-only shape is an ok, and the public server is a warning" {
  seed_volume
  printf '%s\n' 'NTFY_TOPIC=s3cret-topic-name' >"${VOL}/.env"
  run_doctor --check anywhere-door
  assert_report_has "confirms nobody can answer through it" 'push-only'
  assert_report_has "names the public server the notices will reach" 'public ntfy[.]sh'
  assert_report_lacks "never prints the topic" 's3cret-topic-name'
}

# ── the coding-agent control plane ──────────────────────────────────────────

@test "doctor: a checkout without the sessions CLI is a failure the skill would hit" {
  rm -f "${CHECKOUT}/scripts/coder-sessions.sh"
  run_doctor --check agent-verbs
  assert_status 1 "the missing CLI"
  assert_report_has "names the file and where it is missing from" 'coder-sessions[.]sh is missing'
  assert_report_has "points at the skill that dials it" 'coding-agents skill'
}

@test "doctor: the verbs need the docker socket, and say so when it is gone" {
  container_env
  STUB_MOUNTS="/opt/stack
/var/lib/docker/volumes/hermes-data/_data"
  export STUB_MOUNTS
  run_doctor --check agent-verbs
  assert_report_has "reports the missing socket as the consequence" 'no docker socket in the container'

  STUB_MOUNTS="/var/run/docker.sock
/opt/stack"
  export STUB_MOUNTS
  run_doctor --check agent-verbs
  assert_report_has "and credits the socket when it is mounted" 'the docker socket is mounted'
}

@test "doctor: no running container is a note about the socket, never a guess" {
  # An empty container argument would have the daemon answer about something else
  # entirely, and the report would present that as the assistant's mounts.
  run_doctor --check agent-verbs
  assert_report_has "says it did not look" 'the assistant'"'"'s container is not running'
}

# ── the read-only promise ────────────────────────────────────────────────────

@test "doctor: a full report asks the daemon only to look" {
  seed_volume
  container_env "SEARXNG_URL=http://searxng:8181" "LITELLM_MASTER_KEY=real-model-key-value"
  run_doctor
  # Scan argv token by token, and drop anything holding a slash first: the
  # scratch tree is named bats-run-XXXX, and a path segment is not a verb.
  local mutators
  mutators="$(stub_log docker | tr ' ' '\n' | grep -vF '/' |
    grep -Ew -- 'up|down|restart|exec|run|rm|create|kill|stop|pull|build|cp|logs' || true)"
  [ -z "${mutators}" ] || fail "the audit ran a container command it should never run: ${mutators}"
  [ "$(stub_log_count docker)" -gt 0 ] || fail "the audit asked the daemon nothing, so the assertion proved nothing"
}

@test "doctor: --dry-run prints the compose line and touches nothing" {
  seed_volume
  run_doctor --dry-run
  assert_status 0 "the dry run"
  assert_report_has "says nothing is inspected" 'dry run: nothing is inspected'
  assert_report_has "prints the compose line it would have run" 'dry run: docker compose -p evo-t1-prod'
  [ "$(stub_log_count docker)" -eq 0 ] || \
    fail "--dry-run invoked docker $(stub_log_count docker) time(s):$(printf '\n%s' "$(stub_log docker)")"
}

@test "doctor: the compose line carries the addressing flags together" {
  run_doctor --dry-run
  assert_status 0 "the dry run"
  assert_report_has "names the project" 'docker compose -p evo-t1-prod'
  assert_report_has "names the file with -f" "[[:space:]]-f ${CHECKOUT}/docker-compose.yml"
  # The dotenv goes to compose as --env-file. As a second -f it is not YAML,
  # and compose answers with a parse error that names the wrong file.
  assert_report_lacks "never passes the dotenv as a compose fragment" '[[:space:]]-f [^[:space:]]*[/][.]env'
}

@test "doctor: --project-name reaches the compose line" {
  run_doctor --dry-run --project-name evo-t1-dev
  assert_status 0 "a named project"
  assert_report_has "addresses that project" 'docker compose -p evo-t1-dev'
}

@test "doctor: --container addresses the name it is given" {
  export STUB_PS_OUT="cafebabe01" STUB_IMAGE="nousresearch/hermes-agent:v0.22.5"
  run_doctor --container hermes-by-hand --check image-pin
  assert_status 0 "a named container"
  assert_match "inspected that container and no other" '^docker inspect .* hermes-by-hand$' "$(stub_log docker)"
  assert_report_has "reported the image it was given" 'ok: image: nousresearch/hermes-agent:v0.22.5'
}

@test "doctor: the label lookup finds the service container when compose says nothing" {
  export STUB_PS_NAMES="evo-t1-prod-hermes-1" STUB_IMAGE="nousresearch/hermes-agent:v0.22.5"
  run_doctor --check image-pin
  assert_status 0 "the label fallback"
  assert_match "resolved through docker ps" '^docker ps --format' "$(stub_log docker)"
  assert_report_has "reported the image" 'ok: image: nousresearch/hermes-agent:v0.22.5'
}

@test "doctor: no checkout to audit is exit 5" {
  # The script is copied somewhere no candidate can resolve: no REPO_ROOT, no
  # Bazel or CI variable, and a cwd with no docker-compose.yml above it.
  local orphan="${SCRATCH}/orphan"
  mkdir -p "${orphan}/scripts/lib"
  cp "${SCRIPT}" "${orphan}/scripts/hermes-doctor.sh"
  cp "${CANONICAL_ROOT}/scripts/lib/common.sh" "${orphan}/scripts/lib/common.sh"
  cd "${orphan}" || fail "could not enter ${orphan}"
  run env -u REPO_ROOT -u BUILD_WORKSPACE_DIRECTORY -u GITHUB_WORKSPACE \
    bash "${orphan}/scripts/hermes-doctor.sh" report
  assert_status 5 "a script with no checkout around it"
  assert_report_has "says how to name one" 'cannot find the stack checkout'
}

# ── the helpers, unit by unit ────────────────────────────────────────────────

# load_cli_fn <name...> - pull each named production function into this shell
# with the globals main() would have settled before calling it, so a unit is
# driven with its collaborators named instead of through the whole CLI. Loading
# a function brings no file-level state with it, which is why every global the
# units read is set here to what a real run would have.
# Globals:
#   PROJECT, COMPOSE_FILE, ENV_FILE, CONTAINER, DATA_DIR, DRY_RUN, ROOT,
#   DOCTOR_CONTAINER_CACHE, SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL
# Arguments:
#   $@ - the function names to load
# Outputs:
#   The function definitions into this shell
# Returns:
#   0, or non-zero when a name is not in the CLI
load_cli_fn() {
  local name
  PROJECT="evo-t1-prod"
  COMPOSE_FILE="${CHECKOUT}/docker-compose.yml"
  ENV_FILE=""
  CONTAINER=""
  DATA_DIR="${VOL}"
  DRY_RUN=0
  ROOT="${CHECKOUT}"
  DOCTOR_CONTAINER_CACHE=""
  HERMES_IMAGE_DEFAULT="nousresearch/hermes-agent:v0.22.5"
  WEB_VENDOR_KEYS="TAVILY_API_KEY FIRECRAWL_API_KEY BRAVE_SEARCH_API_KEY EXA_API_KEY PARALLEL_API_KEY KEENABLE_API_KEY PERPLEXITY_API_KEY"
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  SUMMARY_FAIL_ITEMS=""
  for name in "$@"; do
    load_shell_function "${SCRIPT}" "${name}" || return 1
  done
}

@test "doctor_compose: the dotenv goes to compose as --env-file and the file as -f" {
  load_cli_fn doctor_compose || fail "could not load doctor_compose"
  DRY_RUN=1
  ENV_FILE="${CHECKOUT}/.env"
  local line
  line="$(doctor_compose ps -q hermes)"
  assert_match "one compose line" '^dry run: docker compose -p evo-t1-prod' "${line}"
  assert_match "the compose file is -f" '[[:space:]]-f [^[:space:]]*docker-compose[.]yml' "${line}"
  assert_match "the dotenv is --env-file" '[[:space:]]--env-file [^[:space:]]*/[.]env' "${line}"
  # As a second -f the dotenv is parsed as YAML, and compose answers with a
  # parse error that names the wrong file.
  assert_not_match "never a second -f" '[[:space:]]-f [^[:space:]]*/[.]env' "${line}"
  assert_eq "nothing ran" "0" "$(stub_log_count docker)"
}

@test "doctor_container: a named container is answered verbatim and cached" {
  load_cli_fn doctor_container || fail "could not load doctor_container"
  CONTAINER="hermes-by-hand"
  assert_eq "the name is returned as given" "hermes-by-hand" "$(doctor_container)"
  assert_eq "the daemon was never asked" "0" "$(stub_log_count docker)"
}

@test "doctor_container: with no name it resolves the service through compose" {
  export STUB_PS_OUT="cafebabe01"
  load_cli_fn doctor_container doctor_compose || fail "could not load the pair"
  assert_eq "the id compose reports" "cafebabe01" "$(doctor_container)"
  # The cache lives in this shell, so the two calls below have to run in it: a
  # command substitution would resolve the id and throw the cache away.
  doctor_container >/dev/null
  doctor_container >/dev/null
  assert_eq "the answer was cached, so the daemon was asked once more" "2" "$(stub_log_count docker)"
}

@test "doctor_container_running: nothing resolving is not a running container" {
  load_cli_fn doctor_container_running doctor_container doctor_compose || \
    fail "could not load the trio"
  if doctor_container_running; then
    fail "an unresolvable container was reported as running, so inspect would have been handed an empty argument"
  fi
}

@test "doctor_container_running: a container the daemon knows is running" {
  export STUB_PS_OUT="cafebabe01"
  load_cli_fn doctor_container_running doctor_container doctor_compose || \
    fail "could not load the trio"
  if ! doctor_container_running; then
    fail "a container the daemon answered for was reported as not running"
  fi
}

@test "doctor_env_of: one key out of the created environment, and nothing else" {
  container_env "SEARXNG_URL=http://searxng:8181" "PATH=/usr/bin:/bin"
  load_cli_fn doctor_env_of doctor_container doctor_compose || fail "could not load the trio"
  assert_eq "the value, with its name stripped" "http://searxng:8181" "$(doctor_env_of SEARXNG_URL)"
  assert_eq "an absent key is an empty answer" "" "$(doctor_env_of NOT_IN_THE_ENV)"
}

@test "doctor_volume_dir: a --data path that is no directory is not a volume" {
  seed_volume
  load_cli_fn doctor_volume_dir doctor_compose || fail "could not load the pair"
  DATA_DIR="${SCRATCH}/no-such-volume"
  if doctor_volume_dir >/dev/null; then
    fail "a typo in --data was taken for a volume, which reports an empty volume instead of a bad flag"
  fi
  DATA_DIR="${VOL}"
  assert_eq "a directory that is there is honoured" "${VOL}" "$(doctor_volume_dir)"
}

@test "doctor_volume_dir: the daemon says where the volume is when --data is not given" {
  seed_volume
  load_cli_fn doctor_volume_dir doctor_compose || fail "could not load the pair"
  DATA_DIR=""
  export STUB_VOLUME_NAME="evo-t1-prod_hermes-data" STUB_VOLUME_MOUNT="${VOL}"
  assert_eq "the daemon's mountpoint" "${VOL}" "$(doctor_volume_dir)"
  export STUB_VOLUME_NAME="" STUB_VOLUME_MOUNT=""
  if doctor_volume_dir >/dev/null; then
    fail "a daemon with no such volume produced a directory anyway"
  fi
}

@test "doctor_pinned_image: reads the assistant's own image and no other service's" {
  load_cli_fn doctor_pinned_image || fail "could not load doctor_pinned_image"
  printf 'services:\n  db:\n    image: postgres:17\n  hermes:\n    image: nousresearch/hermes-agent:v0.22.5\n  litellm:\n    image: ghcr.io/berriai/litellm:v1.102.1\n' \
    >"${CHECKOUT}/docker-compose.yml"
  assert_eq "the assistant's image, not postgres or litellm" \
    "nousresearch/hermes-agent:v0.22.5" "$(doctor_pinned_image)"
}

@test "doctor_pinned_image: a compose file naming no image falls back to the shipped pin" {
  load_cli_fn doctor_pinned_image || fail "could not load doctor_pinned_image"
  printf 'services:\n  coder:\n    image: coder/coder:v2.36.0\n' >"${CHECKOUT}/docker-compose.yml"
  assert_eq "the pin this repo ships" "nousresearch/hermes-agent:v0.22.5" "$(doctor_pinned_image)"
}

@test "doctor_same_file: the render is forgiven and a flipped switch is not" {
  load_cli_fn doctor_same_file || fail "could not load doctor_same_file"
  seed_volume '/opt/src/evo-t1-coder-stack'
  if ! doctor_same_file "${CHECKOUT}/hermes/config.yaml" "${VOL}/config.yaml" config.yaml; then
    fail "a volume whose cwd was rendered to the host's path was called drift"
  fi
  sed -i 's/^  keyless_rescue: false/  keyless_rescue: true/' "${VOL}/config.yaml"
  if doctor_same_file "${CHECKOUT}/hermes/config.yaml" "${VOL}/config.yaml" config.yaml; then
    fail "a switch flipped inside the volume was called a match"
  fi
  seed_volume
  printf 'bytes the operator wrote\n' >"${VOL}/SOUL.md"
  if doctor_same_file "${CHECKOUT}/hermes/SOUL.md" "${VOL}/SOUL.md" SOUL.md; then
    fail "SOUL.md is meant to be compared byte for byte"
  fi
}

# The roster and the functions behind it are two lists that have to move
# together, so both are named here and each unit is called against a box the
# fixtures keep well kept: a check that stopped printing its verdict, or a
# function no roster entry reaches, fails here by name.
@test "doctor: every check on the roster is a function that reports its verdict" {
  seed_volume
  container_env "SEARXNG_URL=http://searxng:8181" "LITELLM_MASTER_KEY=real-model-key-value" \
    "HERMES_WRITE_SAFE_ROOT=/opt/data"
  export STUB_PS_OUT="cafebabe01" STUB_IMAGE="nousresearch/hermes-agent:v0.22.5"
  load_cli_fn check_approvals check_terminal_cwd check_write_root check_web_lane \
    check_keyless_egress check_mcp_servers check_seed_drift check_mount_identity \
    check_image_pin check_model_key check_dashboard check_memories \
    check_anywhere_door check_agent_verbs \
    doctor_compose doctor_container doctor_container_running doctor_env_of \
    doctor_volume_dir doctor_pinned_image doctor_same_file || \
    fail "could not load the check functions"
  local pair fn want out
  for pair in \
    'check_approvals|^ok: approvals: manual' \
    'check_terminal_cwd|^ok: terminal.cwd: ' \
    'check_write_root|^ok: write root: /opt/data' \
    'check_web_lane|^ok: web lane: pinned to searxng' \
    'check_keyless_egress|^ok: no web vendor credential present' \
    'check_mcp_servers|^ok: mcp_servers: none declared' \
    'check_seed_drift|^ok: seed drift: the volume copy matches' \
    'check_mount_identity|^ok: STACK_HOST_PATH: ' \
    'check_image_pin|^ok: image: nousresearch/hermes-agent:v0.22.5' \
    'check_model_key|^ok: model key: LITELLM_MASTER_KEY is set' \
    'check_dashboard|^ok: dashboard: basic auth is set' \
    'check_anywhere_door|^ok: api server: closed' \
    'check_agent_verbs|^ok: agent verbs: scripts/coder-sessions[.]sh is on the checkout' \
    'check_memories|^note: memories: no SQLite store yet'; do
    fn="${pair%%|*}"
    want="${pair#*|}"
    out="$("${fn}")"
    assert_match "${fn} prints its clean-bill line" "${want}" "${out}"
  done
}
