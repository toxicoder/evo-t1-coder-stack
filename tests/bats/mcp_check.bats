#!/usr/bin/env bats
#
# ## mcp-check.bats - hermetic coverage for scripts/mcp-check.sh
#
# The contract pinned here: the exit code answers the same question the printout
# does (a missing lane is a failure, a missing binary is a warning, a usage error
# is its own code), every warning names a remedy an operator can run, the parser
# helper keeps its tab-separated line shape, and --json reports the same counts
# the prose did. Nothing here touches the network: curl and grok are per-test
# stubs on PATH.
#
# Usage: bazelisk test //tests:bats_mcp_check_test   (from any cwd)
# Safety: reads the script, the parser and images/dev/tool-versions.env; writes
# only under the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
PARSER=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/mcp-check.sh"
  PARSER="${REPO_ROOT}/scripts/lib/mcp_lane_report.py"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${PARSER}" ]; then
    skip "mcp-check or its parser is not in the tree"
  fi
  # Neither pass-through may leak in: one decides the context7 credential check,
  # the other would put a real CLI on PATH.
  unset CONTEXT7_API_KEY GH_TOKEN GITHUB_TOKEN SEARXNG_URL
  # A fixture writes under $HOME (the cache-proxy config it seeds), so HOME has
  # to be the per-test scratch or a run would edit the developer's real profile.
  export HOME="${BATS_TEST_TMPDIR}"
}

# make_stub <name> [body] -- put an executable stub on PATH for this test only and
# print the bin directory. An empty body still leaves a runnable no-op.
make_stub() {
  local name="$1" body="${2:-}" dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${dir}"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" >"${dir}/${name}"
  chmod 755 "${dir}/${name}"
  printf '%s' "${dir}"
}

# stub_curl [code] [body] - answer every service probe with a fixed status, so no test
# ever depends on a resolvable host. Prints the bin directory. A caller that
# asks for a status template (-w, which is how probe_search reads) gets the
# code; a caller that asks for the document gets the body, which is how
# probe_search_depth sees its result set. Defaulting the body to the code keeps
# every caller that passes only a status behaving as it did before.
stub_curl() {
  local code="${1:-200}" dir="${BATS_TEST_TMPDIR}/bin" body="${2:-${1:-200}}"
  mkdir -p "${dir}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'want=0\n'
    printf 'for a in "$@"; do [ "$a" = "-w" ] && want=1; done\n'
    printf 'if [ "$want" = 1 ]; then printf %%s %s; else printf %%s %s; fi\n' \
      "'${code}'" "'${body}'"
  } >"${dir}/curl"
  chmod 755 "${dir}/curl"
  printf '%s' "${dir}"
}

# write_config <path> [marker] - a three-lane config whose binaries exist, plus the
# stack marker unless a caller asks for the unmanaged shape. github is declared
# but never required, which is what makes it exercise the "extra" path. marker
# takes 1 (the comment the render writes), key (only the plain TOML key, which is
# what survives the CLI rewriting this file) or 0 (no ownership marker at all).
write_config() {
  local path="$1" marker="${2:-1}"
  {
    if [ "${marker}" = "1" ]; then
      printf '# managed-by: evo-t1-coder-stack\n'
    elif [ "${marker}" = "key" ]; then
      printf '__evoT1Stack = true\n'
    fi
    printf '[mcp_servers.searxng]\n'
    printf 'command = "/opt/npm-global/bin/searxng-mcp-server"\n'
    printf 'enabled = true\n'
    printf 'env = { SEARXNG_URL = "http://searx.test:8181" }\n\n'
    printf '[mcp_servers.context7]\n'
    printf 'command = "/opt/npm-global/bin/mcp-cache-proxy"\n'
    printf 'args = ["--config", "%s/.grok/mcp-cache-proxy/config.json"]\n' "${HOME}"
    printf 'enabled = true\n'
    printf 'env = { CONTEXT7_API_KEY = "$CONTEXT7_API_KEY" }\n\n'
    printf '[mcp_servers.github]\n'
    printf 'url = "https://api.githubcopilot.com/mcp/"\n'
    printf 'enabled = true\n'
  } >"${path}"
}

# stub_ok_binaries - put the two stdio binaries the fixture names where they can
# be found, so a test that is not about drift starts from a healthy box.
stub_ok_binaries() {
  local dir="${BATS_TEST_TMPDIR}/optbin"
  mkdir -p "${dir}"
  : >"${dir}/searxng-mcp-server"
  : >"${dir}/mcp-cache-proxy"
  chmod 755 "${dir}/searxng-mcp-server" "${dir}/mcp-cache-proxy"
  printf '%s' "${dir}"
}

# run_check <config> [args...] - run the CLI the way an operator does, with the
# service probe stubbed so no test needs a network.
run_check() {
  local config="$1" dir
  shift
  dir="$(stub_curl 200)"
  run env HOME="${BATS_TEST_TMPDIR}" PATH="${dir}:${PATH}" bash "${SCRIPT}" \
    --config "${config}" --no-handshake --url http://searx.test:8181 "$@"
}

@test "mcp-check: --help prints the usage block and exits 0" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "usage line" 'usage: bazelisk run //scripts:mcp-check' "${output}"
  assert_match "names the lanes flag" '--lanes' "${output}"
  assert_match "names the exit codes" '2 on a usage error' "${output}"
}

@test "mcp-check: an unknown option is a usage error, not a result" {
  run bash "${SCRIPT}" --bogus
  [ "${status}" -eq 2 ]
  assert_match "names the flag" 'unknown option: --bogus' "${output}"
}

@test "mcp-check: a missing or malformed option value is a usage error" {
  run bash "${SCRIPT}" --lanes
  [ "${status}" -eq 2 ]
  assert_match "complains about lanes" '--lanes needs' "${output}"

  run bash "${SCRIPT}" --config
  [ "${status}" -eq 2 ]

  run bash "${SCRIPT}" --lanes 'searxng; rm'
  [ "${status}" -eq 2 ]
  assert_match "rejects a list that is not names" 'comma-separated' "${output}"
}

@test "mcp-check: no config at all is a failure that says where it looked" {
  run_check "${BATS_TEST_TMPDIR}/absent.toml"
  [ "${status}" -eq 1 ]
  assert_match "names the path" 'no config at' "${output}"
  assert_match "summarizes" 'summary: ' "${output}"
}

@test "mcp-check: a lane the config never declared is an error" {
  local cfg="${BATS_TEST_TMPDIR}/one.toml"
  printf '# managed-by: evo-t1-coder-stack\n[mcp_servers.searxng]\ncommand = "/bin/sh"\nenabled = true\n' >"${cfg}"
  run_check "${cfg}"
  [ "${status}" -eq 1 ]
  assert_match "names the missing lane" 'context7: declared not declared' "${output}"
  assert_match "says why that is suspicious" 'the default render declares it' "${output}"
}

@test "mcp-check: a missing block with its binaries baked names the re-materialize route" {
  # The context7 block is absent from a stack-managed render while the image
  # carries all three lane binaries: a lost block, not drift. The error must
  # name the re-materialize route and the deliberate-park gate, and stay
  # distinct from the missing-binary remedy (the pinned npm install).
  local cfg="${BATS_TEST_TMPDIR}/no-ctx.toml" bins curl_dir empty
  bins="${BATS_TEST_TMPDIR}/npmglobal"
  mkdir -p "${bins}/bin"
  : >"${bins}/bin/searxng-mcp-server"
  : >"${bins}/bin/mcp-cache-proxy"
  : >"${bins}/bin/context7-mcp"
  chmod 755 "${bins}/bin/searxng-mcp-server" "${bins}/bin/mcp-cache-proxy" \
    "${bins}/bin/context7-mcp"
  curl_dir="$(stub_curl 200)"
  {
    printf '# managed-by: evo-t1-coder-stack\n'
    printf '[mcp_servers.searxng]\n'
    printf 'command = "%s/bin/searxng-mcp-server"\n' "${bins}"
    printf 'enabled = true\n'
    printf 'env = { SEARXNG_URL = "http://searx.test:8181" }\n'
  } >"${cfg}"

  run env HOME="${BATS_TEST_TMPDIR}" NPM_GLOBAL_PREFIX="${bins}" \
    PATH="${curl_dir}:${PATH}" \
    bash "${SCRIPT}" --config "${cfg}" --no-handshake --url http://searx.test:8181
  [ "${status}" -eq 1 ]
  assert_match "the missing block stays a failure" 'context7: declared not declared' "${output}"
  assert_match "says the declared block is what is missing" 'the declared block is missing' "${output}"
  assert_match "names the container re-materialize route" \
    'bazelisk run //scripts:refresh-configs -- --container coder-<owner>-<ws>' "${output}"
  assert_match "names the host-home re-materialize route" \
    'bazelisk run //scripts:seed-dev-env -- --home <dir>' "${output}"
  assert_match "names the gate that parks this lane on purpose" \
    'CONTEXT7_MCP=false in .env' "${output}"
  assert_match "names the push that relays the gate" 'push-template.sh' "${output}"
  assert_not_match "no install advice on this path" 'npm i -g --prefix' "${output}"

  # Same config on a box without the baked binaries: that is image drift, so
  # the re-materialize advice must not print.
  empty="${BATS_TEST_TMPDIR}/no-bins"
  mkdir -p "${empty}/bin"
  run env HOME="${BATS_TEST_TMPDIR}" NPM_GLOBAL_PREFIX="${empty}" \
    PATH="${curl_dir}:${PATH}" \
    bash "${SCRIPT}" --config "${cfg}" --no-handshake --url http://searx.test:8181
  [ "${status}" -eq 1 ]
  assert_not_match "no re-materialize advice when the binaries are absent" \
    'the declared block is missing' "${output}"
}

@test "mcp-check: --lanes narrows what has to be there" {
  local cfg="${BATS_TEST_TMPDIR}/one.toml"
  printf '# managed-by: evo-t1-coder-stack\n[mcp_servers.searxng]\ncommand = "/bin/sh"\nenabled = true\n' >"${cfg}"
  run_check "${cfg}" --lanes searxng
  [ "${status}" -eq 0 ]
  assert_match "the required lane was checked" 'searxng: declared block present' "${output}"
  assert_not_match "the unrequired lane was not judged" 'context7: declared not declared' "${output}"
}

@test "mcp-check: a missing binary is a warning that names the pinned install" {
  local cfg="${BATS_TEST_TMPDIR}/drift.toml" pin
  pin="$(sed -n 's|^SEARXNG_MCP_SERVER_VERSION=||p' "${REPO_ROOT}/images/dev/tool-versions.env" | tail -n 1)"
  [ -n "${pin}" ] || skip "no SEARXNG_MCP_SERVER_VERSION pin to assert against"
  printf '# managed-by: evo-t1-coder-stack\n[mcp_servers.searxng]\ncommand = "/opt/npm-global/bin/not-baked"\nenabled = true\n\n[mcp_servers.context7]\ncommand = "/bin/sh"\nargs = ["--config", "/etc/hostname"]\n' >"${cfg}"

  run_check "${cfg}" --lanes searxng
  [ "${status}" -eq 0 ]
  assert_match "warns about the binary" 'command missing /opt/npm-global/bin/not-baked' "${output}"
  assert_match "names the install command" 'npm i -g --prefix /opt/npm-global' "${output}"
  assert_match "names the pinned version" "searxng-mcp-server@${pin}" "${output}"
  assert_match "counts it as a warning" '0 failed' "${output}"

  run_check "${cfg}" --lanes searxng --strict
  [ "${status}" -eq 1 ]
  assert_match "strict promotes the warnings" '[1-9][0-9]* warnings' "${output}"
  assert_match "nothing was counted as a failure" '0 failed' "${output}"
}

@test "mcp-check: an unmanaged config warns with both ways back" {
  local cfg="${BATS_TEST_TMPDIR}/foreign.toml"
  printf '[mcp_servers.searxng]\ncommand = "/bin/sh"\nenabled = true\n\n[mcp_servers.context7]\ncommand = "/bin/sh"\nargs = ["--config", "/etc/hostname"]\n' >"${cfg}"
  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "names the marker" 'managed-by: evo-t1-coder-stack marker' "${output}"
  assert_match "names the key spelling too" '__evoT1Stack = true key' "${output}"
  assert_match "names the consequence" 'stopped managing this file' "${output}"
  assert_match "names the re-materialize path" 'seed-dev-env -- --force' "${output}"
}

@test "mcp-check: a config owned only by the TOML key is stack-managed" {
  local cfg="${BATS_TEST_TMPDIR}/key-only.toml" bins
  bins="$(stub_ok_binaries)"
  write_config "${cfg}" key
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the key alone counts as ownership" 'stack-managed' "${output}"
  assert_not_match "no marker warning" 'stopped managing this file' "${output}"
  assert_match "the lanes were still judged" 'searxng: declared block present' "${output}"
}

@test "mcp-check: a lane missing from an unmanaged config blames the file, not a gate" {
  local cfg="${BATS_TEST_TMPDIR}/unmanaged.toml"
  printf '[mcp_servers.searxng]\ncommand = "/bin/sh"\nenabled = true\n' >"${cfg}"
  run_check "${cfg}"
  [ "${status}" -eq 1 ]
  assert_match "names the missing lane" 'context7: declared not declared' "${output}"
  assert_match "blames the unowned file" 'no stack ownership marker' "${output}"
  assert_match "names the re-materialize remedy" 'seed-dev-env -- --force' "${output}"
  assert_not_match "no gate blame without a marker" 'a push passed its gate false' "${output}"
}

@test "mcp-check: context7 without a key or its cache config warns, never fails" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"

  run_check "${cfg}"
  [ "${status}" -eq 0 ]
  assert_match "the missing key is a warning" 'CONTEXT7_API_KEY is empty' "${output}"
  assert_match "and it says the lane still answers without the key" 'public rate limits' "${output}"
  assert_match "the missing cache config is a warning" 'args_config missing' "${output}"
  assert_match "nothing failed" '0 failed' "${output}"
}

@test "mcp-check: a key in the environment satisfies the credential check" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins curl_dir
  bins="$(stub_ok_binaries)"
  curl_dir="$(stub_curl 200)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  mkdir -p "${HOME}/.grok/mcp-cache-proxy"
  printf '{"servers":{"context7":{"command":"%s/searxng-mcp-server"}}}' "${bins}" \
    >"${HOME}/.grok/mcp-cache-proxy/config.json"

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${curl_dir}:${PATH}" \
    CONTEXT7_API_KEY='ctx7sk-testvalue' \
    bash "${SCRIPT}" --config "${cfg}" --no-handshake --url http://searx.test:8181
  [ "${status}" -eq 0 ]
  assert_match "the key reads as set" 'api_key CONTEXT7_API_KEY' "${output}"
  assert_match "the proxy config is found" 'args_config' "${output}"
  assert_match "the upstream binary is checked" 'upstream of context7' "${output}"
  assert_not_match "the key value is never printed" 'ctx7sk-testvalue' "${output}"
}

@test "mcp-check: --no-handshake never launches grok" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins dir
  bins="$(stub_ok_binaries)"
  dir="$(make_stub grok "touch '${BATS_TEST_TMPDIR}/grok-ran'")"
  stub_curl 200 >/dev/null
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${dir}:${PATH}" CONTEXT7_API_KEY='k' \
    bash "${SCRIPT}" --config "${cfg}" --no-handshake --url http://searx.test:8181
  [ "${status}" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/grok-ran" ]
  assert_match "says what it skipped" 'judging from the config' "${output}"
}

@test "mcp-check: the handshake section folds in what doctor reported" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins dir
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  mkdir -p "${HOME}/.grok/mcp-cache-proxy"
  printf '{"servers":{"context7":{"command":"%s/searxng-mcp-server"}}}' "${bins}" \
    >"${HOME}/.grok/mcp-cache-proxy/config.json"
  dir="$(make_stub grok "cat <<'JSON'
{\"servers\":[{\"name\":\"searxng\",\"healthy\":true,\"checks\":[]},{\"name\":\"context7\",\"healthy\":false,\"checks\":[{\"label\":\"handshake failed\",\"passed\":false}]},{\"name\":\"github\",\"healthy\":false,\"checks\":[{\"label\":\"Auth required\",\"passed\":false}]}],\"healthy_count\":1}
JSON
")"
  stub_curl 200 >/dev/null

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${dir}:${PATH}" CONTEXT7_API_KEY='k' \
    bash "${SCRIPT}" --config "${cfg}" --url http://searx.test:8181
  [ "${status}" -eq 1 ]
  assert_match "a healthy lane passes" 'searxng: doctor handshake OK' "${output}"
  assert_match "an unhealthy lane fails" 'context7: doctor handshake failed: handshake failed' "${output}"
  assert_match "an extra lane is only reported" 'github: extra not healthy: Auth required' "${output}"
}

@test "mcp-check: a missing service answer is a failure naming the URL" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins dir
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  dir="$(make_stub curl "printf '000'")"

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${dir}:${PATH}" CONTEXT7_API_KEY='k' \
    bash "${SCRIPT}" --config "${cfg}" --no-handshake
  [ "${status}" -eq 1 ]
  assert_match "names the URL it dialled" 'http://searx.test:8181 gave no HTTP answer' "${output}"
}

@test "mcp-check: the config's own SEARXNG_URL is the address it dials" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins out
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  run_check "${cfg}" --lanes searxng
  assert_match "dials the block's URL" 'searxng: service http://searx.test:8181' "${output}"
}

@test "mcp-check: --json carries the same counts the prose did" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins curl_dir summary_line counts json
  bins="$(stub_ok_binaries)"
  curl_dir="$(stub_curl 200)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  mkdir -p "${HOME}/.grok/mcp-cache-proxy"

  # The object is stdout alone: under --json the prose moves to stderr, and this
  # asserts the two channels agree rather than mixing them.
  json="$(env HOME="${BATS_TEST_TMPDIR}" PATH="${curl_dir}:${PATH}" bash "${SCRIPT}" \
    --config "${cfg}" --no-handshake --url http://searx.test:8181 --json 2>/dev/null)"
  printf '%s\n' "${json}" | python3 -m json.tool >/dev/null
  summary_line="$(env HOME="${BATS_TEST_TMPDIR}" PATH="${curl_dir}:${PATH}" bash "${SCRIPT}" --config "${cfg}" \
    --no-handshake --url http://searx.test:8181 2>/dev/null | grep '^summary: ')"
  counts="$(printf '%s\n' "${json}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("%d ok, %d warnings, %d failed" % (d["ok"], d["warnings"], d["failed"]))')"
  assert_eq "json counts match the summary line" "${summary_line#summary: }" "${counts}"
  [ "${#counts}" -gt 0 ]
}

@test "mcp_lane_report: the parser keeps its tab-separated line shape" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" bins fields
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"

  run env HOME="${BATS_TEST_TMPDIR}" CONTEXT7_API_KEY='k' python3 "${PARSER}" \
    --config "${cfg}" --lanes searxng,context7
  [ "${status}" -eq 0 ]
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    fields="$(printf '%s' "${line}" | awk -F'\t' '{print NF}')"
    assert_eq "every line has four fields" "4" "${fields}"
  done <<<"${output}"
  assert_match "a required lane reports declared" 'searxng.declared.ok' "${output}"
  assert_match "an unrequired server is a note" 'github.extra.note' "${output}"

  # Without the key the same lane reports the credential as a warning, not a
  # failure: the server still starts and answers at the public rate limit.
  run env HOME="${BATS_TEST_TMPDIR}" python3 "${PARSER}" \
    --config "${cfg}" --lanes context7
  [ "${status}" -eq 0 ]
  assert_match "a missing credential is a warn" 'context7.api_key.warn' "${output}"
}

@test "mcp_lane_report: an unreadable config is one error line, not a traceback" {
  local cfg="${BATS_TEST_TMPDIR}/broken.toml"
  printf 'this is = = not toml [[[\n' >"${cfg}"

  run python3 "${PARSER}" --config "${cfg}" --lanes searxng
  [ "${status}" -eq 0 ]
  assert_match "one error line names the config" 'config.declared.error' "${output}"
  assert_match "it says the file does not parse" 'does not parse' "${output}"
  assert_not_match "no python traceback" 'Traceback' "${output}"

  run python3 "${PARSER}" --config "${cfg}/absent" --lanes searxng
  [ "${status}" -eq 0 ]
  assert_match "an absent file is reported the same way" 'no config file at' "${output}"
}

@test "mcp_lane_report: a doctor report is folded in per server" {
  local cfg="${BATS_TEST_TMPDIR}/ctx.toml" doctor bins
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  doctor="${BATS_TEST_TMPDIR}/doctor.json"
  printf '{"servers":[{"name":"searxng","healthy":false,"checks":[{"label":"command not found","passed":false}]}]}' >"${doctor}"

  run env HOME="${BATS_TEST_TMPDIR}" CONTEXT7_API_KEY='k' python3 "${PARSER}" \
    --config "${cfg}" --lanes searxng,context7 --doctor "${doctor}"
  [ "${status}" -eq 0 ]
  assert_match "the failing lane is an error carrying the doctor label" 'searxng.doctor.error.handshake failed: command not found' "${output}"
  assert_match "a lane the report omits is a note" 'context7.doctor.note.not in the doctor report' "${output}"
}

# -- the pieces the CLI is built from, tested where they are defined --------------
#
# The end-to-end runs above prove the exit code; these pin the four helpers that
# decide *what* an operator reads: where a pin comes from, what the install
# advice says, which address the service probe dials, and whether a doctor
# report survives a non-zero exit.

# load_common - the house vocabulary the reporting helpers call into. common.sh
# is documented as side-effect free to source, and it defines its own `skip`,
# so this runs after every guard that would otherwise want the bats builtin.
load_common() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
}

@test "mcp-check: tool_pin reads one pin out of tool-versions.env" {
  local root="${BATS_TEST_TMPDIR}/pinroot" pinned
  mkdir -p "${root}/images/dev"
  printf 'SEARXNG_MCP_SERVER_VERSION="9.9.9"\nPLAIN=8.8.8\n' >"${root}/images/dev/tool-versions.env"

  load_shell_function "${SCRIPT}" tool_pin
  REPO_ROOT_RESOLVED="${root}"
  assert_eq "quotes come off" "9.9.9" "$(tool_pin SEARXNG_MCP_SERVER_VERSION)"
  assert_eq "a bare value passes through" "8.8.8" "$(tool_pin PLAIN)"
  assert_eq "an unknown key is empty" "" "$(tool_pin NO_SUCH_VERSION)"

  # The real pins are what the remedy text must carry, so a drift between the
  # image and the advice is caught here and not on an operator's box.
  REPO_ROOT_RESOLVED="${REPO_ROOT}"
  pinned="$(tool_pin SEARXNG_MCP_SERVER_VERSION)"
  [ -n "${pinned}" ] || fail "the repo should pin SEARXNG_MCP_SERVER_VERSION"
  assert_eq "the repo pin is the version the image bakes" \
    "1" "$(grep -c "SEARXNG_MCP_SERVER_VERSION=${pinned}" "${REPO_ROOT}/images/dev/Dockerfile" || true)"
}

@test "mcp-check: lane_remedy names every package the lane needs, pinned" {
  load_shell_function "${SCRIPT}" tool_pin
  load_shell_function "${SCRIPT}" lane_remedy
  REPO_ROOT_RESOLVED="${REPO_ROOT}"

  local searxng_pin context7_pin proxy_pin text
  searxng_pin="$(tool_pin SEARXNG_MCP_SERVER_VERSION)"
  context7_pin="$(tool_pin CONTEXT7_MCP_VERSION)"
  proxy_pin="$(tool_pin MCP_CACHE_PROXY_VERSION)"

  text="$(lane_remedy searxng)"
  assert_match "searxng advice is a runnable global install" \
    "^npm i -g --prefix /opt/npm-global searxng-mcp-server@${searxng_pin}$" "${text}"

  text="$(lane_remedy context7)"
  assert_match "context7 installs the proxy and the upstream it wraps" \
    "mcp-cache-proxy@${proxy_pin} @upstash/context7-mcp@${context7_pin}$" "${text}"

  assert_eq "an http lane has nothing to install" "" "$(lane_remedy github)"
}

@test "mcp-check: config_search_url reads the searxng block only" {
  local cfg="${BATS_TEST_TMPDIR}/url.toml" other="${BATS_TEST_TMPDIR}/other.toml"
  write_config "${cfg}"
  load_shell_function "${SCRIPT}" config_search_url

  assert_eq "the block's own URL is the address to dial" \
    "http://searx.test:8181" "$(config_search_url "${cfg}")"

  {
    printf '[mcp_servers.context7]\n'
    printf 'command = "/bin/true"\n'
    printf 'env = { SEARXNG_URL = "http://elsewhere:9999" }\n'
  } >"${other}"
  assert_eq "another block's SEARXNG_URL does not count" "" "$(config_search_url "${other}")"
  assert_eq "a config that is not there yields nothing" "" "$(config_search_url "${cfg}/absent")"
}

@test "mcp-check: probe_search answers with a status or says nothing answered" {
  local dir empty code
  load_shell_function "${SCRIPT}" probe_search
  empty="${BATS_TEST_TMPDIR}/empty-path"
  mkdir -p "${empty}"

  dir="$(stub_curl 404)"
  PATH="${dir}:${PATH}"
  code="$(probe_search http://searx.test:8181)"
  assert_eq "a non-2xx status comes back verbatim" "404" "${code}"

  dir="$(make_stub curl 'exit 7')"
  PATH="${dir}:${PATH}"
  code="$(probe_search http://searx.test:8181)"
  assert_eq "a curl that cannot connect is no-answer" "no-answer" "${code}"

  code="$(PATH="${empty}" probe_search http://searx.test:8181)"
  assert_eq "no curl at all is its own answer" "no-curl" "${code}"
}

@test "mcp-check: probe_search_depth counts the results a reply actually carries" {
  # The status line cannot tell a working lane from one whose engines are all
  # parked, so this counts rows the way scripts/search-check.sh counts them.
  local dir empty depth
  load_shell_function "${SCRIPT}" probe_search_depth
  empty="${BATS_TEST_TMPDIR}/empty-path-d"
  mkdir -p "${empty}"

  dir="$(stub_curl 200 '{"results":[{"url":"http://a"},{"url":"http://b"},{"url":"http://c"}]}')"
  PATH="${dir}:${PATH}"
  depth="$(probe_search_depth http://searx.test:8181)"
  assert_eq "three results count as three" "3" "${depth}"

  dir="$(stub_curl 200 '{"results":[],"unresponsive_engines":[["brave","too many requests"]]}')"
  PATH="${dir}:${PATH}"
  depth="$(probe_search_depth http://searx.test:8181)"
  assert_eq "a 200 that carries nothing counts as zero" "0" "${depth}"

  dir="$(make_stub curl 'exit 7')"
  PATH="${dir}:${PATH}"
  depth="$(probe_search_depth http://searx.test:8181)"
  assert_eq "a request that never completed is no-answer" "no-answer" "${depth}"

  depth="$(PATH="${empty}" probe_search_depth http://searx.test:8181)"
  assert_eq "no curl at all is its own answer" "no-curl" "${depth}"
}

@test "mcp-check: a 200 that returns no results is a warning, not a healthy lane" {
  # The state this CLI used to call healthy: the service answers 200, every
  # engine is parked, and every agent search comes back empty. The hop line has
  # to say so and point at the tool that names the engines.
  local cfg="${BATS_TEST_TMPDIR}/empty-report.toml" bins out="${BATS_TEST_TMPDIR}/empty-report.out" text
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  load_common
  load_shell_function "${SCRIPT}" tool_pin
  load_shell_function "${SCRIPT}" lane_remedy
  load_shell_function "${SCRIPT}" emit_finding
  load_shell_function "${SCRIPT}" probe_search
  load_shell_function "${SCRIPT}" probe_search_depth
  load_shell_function "${SCRIPT}" report_lanes
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS="" JSON_MODE="" JSON_FINDINGS=""
  REPO_ROOT_RESOLVED="${REPO_ROOT}"
  REPORT_PY="${PARSER}" DOCTOR_OK=0 DOCTOR_FILE="${BATS_TEST_TMPDIR}/doctor.json"
  CONFIG="${cfg}" LANE_LIST="searxng" SEARCH_URL="http://searx.test:8181"
  CONFIG_MANAGED=1
  PATH="$(stub_curl 200 '{"results":[],"unresponsive_engines":[["brave","too many requests"]]}'):${PATH}"

  report_lanes >"${out}" 2>&1
  text="$(cat "${out}")"
  assert_contains_file "the empty lane is a warning" "${out}" \
    "warning: searxng: service http://searx.test:8181 answered HTTP 200 with zero results"
  assert_contains_file "and it names the tool that identifies the engines" "${out}" \
    "search-check"
  assert_not_match "the hop is not also reported as healthy" 'ok: searxng: service ' "${text}"
  assert_eq "one warning, nothing failed" "1" "${SUMMARY_WARN}"
  assert_eq "the service itself is up, so nothing failed" "0" "${SUMMARY_FAIL}"
}

@test "mcp-check: take_doctor keeps a report doctor exits non-zero on" {
  local bin rc msg
  load_common
  load_shell_function "${SCRIPT}" take_doctor
  DOCTOR_FILE="${BATS_TEST_TMPDIR}/doctor.json"

  # An unhealthy server makes doctor exit non-zero. That is a finding to report,
  # so the JSON it printed has to survive; losing it would silently drop the
  # handshake half of the run.
  bin="$(make_stub grok 'printf %s "{\"servers\":[]}"' )"
  PATH="${bin}:${PATH}"
  rc=0
  take_doctor || rc=$?
  assert_eq "a non-zero doctor with a report still counts as captured" "0" "${rc}"
  assert_contains_file "the report is on disk" "${DOCTOR_FILE}" 'servers'

  bin="$(make_stub grok 'exit 3')"
  PATH="${bin}:${PATH}"
  rc=0
  msg="$(take_doctor 2>&1)" || rc=$?
  assert_eq "an empty report is not captured" "1" "${rc}"
  assert_match "and the operator is told the run is config-only" 'no report' "${msg}"

  rc=0
  msg="$(PATH="${BATS_TEST_TMPDIR}/empty-path" take_doctor 2>&1)" || rc=$?
  assert_eq "no grok is not captured either" "1" "${rc}"
  assert_match "and it says the handshake was skipped" 'not on PATH' "${msg}"
}

@test "mcp-check: emit_finding prints the vocabulary and feeds --json from one call" {
  local out="${BATS_TEST_TMPDIR}/prose"
  load_common
  load_shell_function "${SCRIPT}" emit_finding
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS="" JSON_MODE="" JSON_FINDINGS=""

  {
    emit_finding ok "searxng: declared ok"
    emit_finding warn "searxng: command missing"
    emit_finding note "github: extra note"
    emit_finding error "searxng: no config"
  } >"${out}" 2>&1
  assert_contains_file "ok line" "${out}" "ok: searxng: declared ok"
  assert_contains_file "warning line" "${out}" "warning: searxng: command missing"
  assert_contains_file "note line" "${out}" "note: github: extra note"
  assert_contains_file "error line" "${out}" "error: searxng: no config"
  assert_eq "the counters follow the statuses" "1 1 1" \
    "${SUMMARY_OK} ${SUMMARY_WARN} ${SUMMARY_FAIL}"
  assert_eq "no json while JSON_MODE is unset" "" "${JSON_FINDINGS}"

  JSON_MODE=1 JSON_FINDINGS=""
  emit_finding ok 'a "quoted" path' >/dev/null 2>&1
  emit_finding warn "second" >/dev/null 2>&1
  assert_match "findings are joined with a comma" '^\{"status":"ok".*\},\{"status":"warn","text":"second"\}$' "${JSON_FINDINGS}"
  assert_match "a quote inside the text is escaped" 'a \\"quoted\\" path' "${JSON_FINDINGS}"
}

@test "mcp-check: report_lanes groups by lane and appends the remedy to a drift warning" {
  local cfg="${BATS_TEST_TMPDIR}/report.toml" bins out="${BATS_TEST_TMPDIR}/report.out" text gone
  bins="$(stub_ok_binaries)"
  write_config "${cfg}"
  sed -i "s|/opt/npm-global/bin/|${bins}/|g" "${cfg}"
  gone="${BATS_TEST_TMPDIR}/gone/mcp-cache-proxy"
  sed -i "s|command = \"${bins}/mcp-cache-proxy\"|command = \"${gone}\"|" "${cfg}"
  # context7 now points at a binary that is not on this box, which is the drift
  # this CLI exists to catch, while searxng stays healthy. Its key and cache file
  # are seeded so that drift is the only warning left to find.
  mkdir -p "${HOME}/.grok/mcp-cache-proxy"
  printf '{"servers":{}}' >"${HOME}/.grok/mcp-cache-proxy/config.json"
  export CONTEXT7_API_KEY='a-test-key'
  load_common
  load_shell_function "${SCRIPT}" tool_pin
  load_shell_function "${SCRIPT}" lane_remedy
  load_shell_function "${SCRIPT}" probe_search
  load_shell_function "${SCRIPT}" emit_finding
  load_shell_function "${SCRIPT}" probe_search_depth
  load_shell_function "${SCRIPT}" report_lanes
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS="" JSON_MODE="" JSON_FINDINGS=""
  REPO_ROOT_RESOLVED="${REPO_ROOT}"
  REPORT_PY="${PARSER}" DOCTOR_OK=0 DOCTOR_FILE="${BATS_TEST_TMPDIR}/doctor.json"
  CONFIG="${cfg}" LANE_LIST="searxng,context7" SEARCH_URL="http://searx.test:8181"
  CONFIG_MANAGED=1
  # A body that carries results: a bare 200 with nothing in it is now a warning,
  # and this test is about the healthy lane, so the stub has to answer like a
  # search that worked.
  PATH="$(stub_curl 200 '{"results":[{"url":"http://a"},{"url":"http://b"},{"url":"http://c"}]}'):${PATH}"

  # Called in this shell, not a subshell, so the counters it writes are the ones
  # the assertions read.
  report_lanes >"${out}" 2>&1
  text="$(cat "${out}")"
  assert_contains_file "each lane gets its own phase line" "${out}" "-> checking searxng"
  assert_contains_file "and the next lane too" "${out}" "-> checking context7"
  assert_contains_file "the healthy lane reports its binary" "${out}" "ok: searxng: command "
  assert_contains_file "the service hop is reported from the probe" "${out}" \
    "ok: searxng: service http://searx.test:8181 answered HTTP 200"
  assert_contains_file "a missing binary is a warning carrying the pinned install" "${out}" \
    "warning: context7: command missing ${gone} - npm i -g --prefix /opt/npm-global"
  assert_not_match "the healthy lane carries no install advice" 'searxng: command missing' "${text}"
  assert_eq "one lane drifted, so the counters say one warning" "1" "${SUMMARY_WARN}"
  assert_eq "and nothing failed" "0" "${SUMMARY_FAIL}"
}
