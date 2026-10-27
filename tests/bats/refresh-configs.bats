#!/usr/bin/env bats
#
# ## refresh-configs.bats - hermetic coverage for scripts/refresh-configs.sh
# and the config_seed plumbing it sources.
#
# The contract pinned here: the reseed list stays home-relative (no dev-only
# path is ever a reseed target), a marker-free config file is user-owned and
# survives a reseed unless --force names the tool's prerogative, a reseed
# renders the template payloads (dollar-brace unfolding, the LiteLLM URL, the
# carried API keys) and leaves JSON that still parses, --dry-run writes
# nothing, and no docker run helper container is ever started. Docker only
# ever resolves through the tool stub; --home points the whole flow at a
# scratch tree so no test needs a daemon. The LiteLLM address is never
# hardcoded either: --litellm-url (and the STACK_LITELLM_URL default) repoint
# a reseed at a stack environment that remapped LITELLM_PORT.
#
# The whole suite skips while scripts/refresh-configs.sh is absent: a suite
# for a script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_refresh_configs_test   (from any cwd)
# Safety: reads the template payloads and the two scripts; writes only under
# the per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
REFRESH=""
LIB=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  REFRESH="${REPO_ROOT}/scripts/refresh-configs.sh"
  LIB="${REPO_ROOT}/scripts/lib/config_seed.sh"
  if [ ! -f "${REFRESH}" ] || [ ! -f "${LIB}" ]; then
    skip "the refresh-configs script or its lib is not in the tree"
  fi
  use_stubs docker
}

# scratch_home <dir> - build a scratch tree shaped like a workspace HOME so a
# host --home run has real targets to reason about.
scratch_home() {
  mkdir -p "${1}/.shared/vscode" "${1}/.coder/skills/grok-build-delegation" \
    "${1}/.coder/skills/learn"
  printf 'set -g mouse off\n' >"${1}/.tmux.conf"
  printf '{\n  "__evoT1Stack": true,\n  "cline.apiKey": "SECRET-KEEP-ME",\n  "terminal.integrated.scrollback": 2000\n}\n' \
    >"${1}/.shared/vscode/settings.json"
}

@test "refresh-configs: --help and an unknown option both print the usage" {
  run --separate-stderr bash "${REFRESH}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: bazelisk run //scripts:refresh-configs --' "${output}"

  run --separate-stderr bash "${REFRESH}" --bogus
  [ "${status}" -ne 0 ]
  assert_match "usage shown on a bad flag" 'usage: bazelisk run //scripts:refresh-configs --' "${output}"
  # The usage paths never consult the (stubbed) docker CLI.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "config_seed: seed_seed_targets lists only home-relative reseed targets" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local lines target
  lines="$(seed_seed_targets)"
  [ "$(printf '%s\n' "${lines}" | grep -c .)" -eq 9 ]
  # Home-relative targets keep dev-only paths (scripts/, tests/) out of any
  # workspace volume: an absolute target would put this script's trust
  # boundary in the wrong place.
  assert_not_match "no absolute paths" '^/' "${lines}"
  assert_not_match "no dev-only sources" '(scripts|tests)/' "${lines}"
  # Payloads are repo files (file:) or rendered tftpl (render:). Heredoc
  # extraction (block:) is gone; tmux and the agent skill live under common/.
  assert_match "tmux from common" $'file:templates/common/tmux.conf' "${lines}"
  # Both learn skill copies reseed from the one common payload: the chat agent
  # reads ~/.coder/skills/ and the Grok Build CLI reads ~/.agents/skills/, and
  # skill dedupe is first-match-wins, so the twins exist for the two consumers.
  assert_match "learn skill from common (coder)" \
    $'~/.coder/skills/learn/SKILL.md\tfile:templates/common/learn.SKILL.md' "${lines}"
  assert_match "learn skill from common (agents)" \
    $'~/.agents/skills/learn/SKILL.md\tfile:templates/common/learn.SKILL.md' "${lines}"
  assert_not_match "no block kind" $'\tblock:' "${lines}"
}

@test "config_seed: seed_target_owner tells managed from user from absent" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local scratch state
  scratch="$(make_scratch)"
  state="$(seed_target_owner "" "${scratch}/absent.conf")"
  [ "${state}" = "absent" ]
  printf 'set -g mouse off\n' >"${scratch}/user.conf"
  state="$(seed_target_owner "" "${scratch}/user.conf")"
  [ "${state}" = "user" ]
  printf '# managed-by: evo-t1-coder-stack\nset -g mouse on\n' >"${scratch}/managed.conf"
  state="$(seed_target_owner "" "${scratch}/managed.conf")"
  [ "${state}" = "managed" ]
  printf '{"__evoT1Stack": true}\n' >"${scratch}/json.conf"
  state="$(seed_target_owner "" "${scratch}/json.conf")"
  [ "${state}" = "managed" ]
}

@test "config_seed: a config.toml whose comments the CLI deleted still reads as managed" {
  # The regression this pins. `grok mcp add` persists its own settings by
  # parsing ~/.grok/config.toml and writing it back, and that round trip
  # deletes every comment line -- no human involved. When only the comment
  # marker and the JSON key were known, the file silently became user-owned,
  # refresh-configs stopped reseeding it, and mcp-check reported the stack had
  # abandoned it. The plain TOML key survives the same write, so it alone has
  # to read as managed.
  # shellcheck source=/dev/null
  source "${LIB}"
  local scratch state
  scratch="$(make_scratch)"
  printf 'model = "agent"\n[mcp_servers.searxng]\nenabled = true\n__evoT1Stack = true\n' \
    >"${scratch}/config.toml"
  # No comment line left to match: this is the post-rewrite shape, not a
  # hypothetical one.
  [ "$(grep -c '#' "${scratch}/config.toml")" -eq 0 ]
  state="$(seed_target_owner "" "${scratch}/config.toml")"
  [ "${state}" = "managed" ]
}

@test "config_seed: the container probe call carries all three markers as argv words" {
  # The container branch reaches the probe through
  # `docker exec -i <name> sh -c <probe> ... <path> <markers...>`, and the
  # marker texts are separate argv words rather than text folded into the
  # script body. A marker the caller forgets to pass is a marker the workspace
  # never honors, which is exactly how the CLI-dropped-comment bug returned
  # "user" for a config.toml the stack still owned. The docker stub records the
  # exact argv, so this pins what the far-end probe is handed.
  # shellcheck source=/dev/null
  source "${LIB}"
  local scratch logged
  scratch="$(make_scratch)"
  printf 'model = "agent"\n__evoT1Stack = true\n' >"${scratch}/config.toml"
  seed_target_owner "coder-demo-abc" "${scratch}/config.toml" >/dev/null
  logged="$(stub_log docker)"
  assert_match "the probe ran under docker exec" 'exec -i coder-demo-abc sh -c ' "${logged}"
  assert_match "path then the three markers, each its own argv word" \
    "${scratch}/config.toml managed-by: evo-t1-coder-stack \"__evoT1Stack\": true __evoT1Stack = true\$" \
    "${logged}"
}

@test "markers: every file that spells a stack marker spells it as config_seed.sh does" {
  # Ownership is decided by grep -F against these strings, in the lib and in
  # both startup twins alike, so one drifted space in any payload turns a
  # stack-owned file into a user-owned one nothing reseeds. The three canonical
  # spellings are read out of the lib rather than restated here, so the lib
  # stays the only place that spells them out.
  local lib="${REPO_ROOT}/scripts/lib/config_seed.sh"
  local text json toml f bad
  text="$(sed -n "s/^STACK_MARKER_TEXT='\(.*\)'$/\1/p" "${lib}" | tail -n 1)"
  json="$(sed -n "s/^STACK_MARKER_JSON='\(.*\)'$/\1/p" "${lib}" | tail -n 1)"
  toml="$(sed -n "s/^STACK_MARKER_TOML='\(.*\)'$/\1/p" "${lib}" | tail -n 1)"
  [ -n "${text}" ] && [ -n "${json}" ] && [ -n "${toml}" ] ||
    fail "config_seed.sh no longer defines the three marker constants"

  for f in scripts/lib/config_seed.sh scripts/mcp-check.sh \
    templates/workspace/startup.sh.tftpl templates/devcontainer/startup.sh.tftpl \
    templates/workspace/grok-config.toml.tftpl templates/devcontainer/grok-config.toml.tftpl; do
    assert_file_exists "${f} is in the tree" "${REPO_ROOT}/${f}"
    if ! grep -qF -- "${text}" "${REPO_ROOT}/${f}"; then
      fail "${f}: spells no comment marker; expected '${text}'"
    fi
    # Each key form is matched loosely, then required to equal the constant:
    # a missing space or a renamed key is a different string to grep -F.
    bad="$(grep -oE '"__evoT1Stack"[[:space:]]*:[[:space:]]*[A-Za-z0-9_]*' "${REPO_ROOT}/${f}" |
      grep -vxF -- "${json}" || true)"
    [ -z "${bad}" ] || fail "${f}: spells the JSON marker '${bad}', not '${json}'"
    bad="$(grep -oE '__evoT1Stack[[:space:]]*=[[:space:]]*[A-Za-z0-9_]*' "${REPO_ROOT}/${f}" |
      grep -vxF -- "${toml}" || true)"
    [ -z "${bad}" ] || fail "${f}: spells the TOML marker '${bad}', not '${toml}'"
    bad="$(grep -oE 'managed-by:[[:space:]]*[A-Za-z0-9_-]+' "${REPO_ROOT}/${f}" |
      grep -vxF -- "${text}" || true)"
    [ -z "${bad}" ] || fail "${f}: spells the comment marker '${bad}', not '${text}'"
  done
}

@test "config_seed: seed_key_value and seed_render_settings carry API keys" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local scratch out
  scratch="$(make_scratch)"
  local sample='{"cline.apiKey": "sk-from-boot"}'
  local value
  value="$(seed_key_value "${sample}" cline.apiKey)"
  [ "${value}" = "sk-from-boot" ]

  out="${scratch}/rendered.json"
  printf '%s\n' '{"cline.apiKey": "sk-from-boot", "roo.openaiApiKey": "sk-from-boot"}' >"${scratch}/current.json"
  seed_render_settings "${REPO_ROOT}/templates/workspace/settings.json.tftpl" "${out}" "${scratch}/current.json"
  assert_contains_file "url rendered" "${out}" 'host.docker.internal:4000/v1'
  assert_contains_file "key carried" "${out}" 'sk-from-boot'
  assert_not_match "dollar-brace unfolded" '\$\$\{' "$(cat "${out}")"
  python3 -c 'import json,sys; json.load(sys.stdin)' <"${out}"
}

@test "refresh-configs: --dry-run --home reports the plan and writes nothing" {
  local scratch
  scratch="$(make_scratch)"
  scratch_home "${scratch}/home"
  local before="${scratch}/before.sha"
  ( cd "${scratch}/home" && find . -type f -exec sha256sum {} + | sort ) >"${before}"

  run bash "${REFRESH}" --dry-run --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_match "user file named" 'left alone \(--force overrides\)' "${output}"
  assert_match "drift reported" 'would re-materialize' "${output}"

  local after="${scratch}/after.sha"
  ( cd "${scratch}/home" && find . -type f -exec sha256sum {} + | sort ) >"${after}"
  cmp -s "${before}" "${after}"
}

@test "refresh-configs: a reseed seeds what is absent and spares what the user owns" {
  local scratch
  scratch="$(make_scratch)"
  scratch_home "${scratch}/home"
  run bash "${REFRESH}" --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  # The marker-free tmux.conf predates the stack default: it is user-owned
  # and stays byte-identical.
  assert_match "user tmux.conf untouched" 'mouse off' "$(cat "${scratch}/home/.tmux.conf")"
  # The managed settings.json was re-rendered from the repo template...
  assert_contains_file "fresh scrollback" "${scratch}/home/.shared/vscode/settings.json" '"terminal.integrated.scrollback": 10000'
  # ...and it kept the key the workspace was handed on its first boot.
  assert_contains_file "key carried" "${scratch}/home/.shared/vscode/settings.json" 'SECRET-KEEP-ME'
  # Absent targets get seeded, twins included.
  assert_file_exists "agents twin" "${scratch}/home/.agents/INSTRUCTIONS.md"
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/grok-build-delegation/SKILL.md"
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/learn/SKILL.md"
  assert_file_exists "agents skill" "${scratch}/home/.agents/skills/learn/SKILL.md"
  # Every docker call that ran was an exec through the stub or none at all:
  # this tool must never spawn a helper container.
  run grep -E 'docker (run|cp)' <<<"$(stub_log docker)"
  [ "${status}" -ne 0 ]
}

@test "refresh-configs: --force re-materializes a marker-free file too" {
  local scratch
  scratch="$(make_scratch)"
  scratch_home "${scratch}/home"
  run bash "${REFRESH}" --force --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_match "user file replaced under force" 'OVERWRITTEN under --force' "${output}"
  assert_contains_file "tmux.conf reseeded" "${scratch}/home/.tmux.conf" 'set -g mouse on'
}

@test "refresh-configs: discovery names coder- containers and skips the sidecar" {
  # The daemon never exists here; docker resolves through the stub, which
  # replays this exact ps output and refuses every exec (exec runs canned,
  # not passed through, so nothing touches a real filesystem).
  export STUB_COMPOSE_PS='coder-demo-abc
random-x
coder-ws2-dind-sidecar'
  run bash "${REFRESH}" --dry-run --container-root "${BATS_TEST_TMPDIR}/nowhere"
  [ "${status}" -eq 0 ]
  assert_match "workspace container addressed" 'coder-demo-abc' "$(stub_log docker)"
  assert_not_match "sidecar not addressed" 'dind-sidecar' "$(stub_log docker)"
  assert_not_match "foreign container not addressed" 'random-x' "$(stub_log docker)"
}

@test "refresh-configs: --json keeps stdout machine-readable JSON" {
  local scratch
  scratch="$(make_scratch)"
  scratch_home "${scratch}/home"
  run --separate-stderr bash "${REFRESH}" --json --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  # The one-line JSON object sits on stdout; prose went to stderr.
  grep -m1 '^{' <<<"${output}" >"${scratch}/out.json"
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["dry_run"] is False and d["force"] is False and len(d["entries"]) == 9' <"${scratch}/out.json"
}

@test "refresh-configs: against a named container every call is an exec, never a run" {
  # With exec passed through, the seed script runs ON THE HOST against the
  # --container-root tree the stub hands it, so this pins the whole
  # docker-exec plumbing shape the real daemon would see.
  export STUB_COMPOSE_PS='coder-demo-abc'
  local scratch
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/root/.shared/vscode"
  printf 'set -g mouse off\n' >"${scratch}/root/.tmux.conf"
  run bash "${REFRESH}" --container coder-demo-abc --container-root "${scratch}/root"
  [ "${status}" -eq 0 ]
  assert_match "execs were issued" 'exec -i coder-demo-abc' "$(stub_log docker)"
  assert_not_match "no helper container spawned" 'docker run' "$(stub_log docker)"
  assert_not_match "no docker cp used" 'docker cp' "$(stub_log docker)"
  # seed_container_exec and seed_target_owner ran their probe scripts, and
  # seed_container_seed drove the whole reseed list through them.
  [ "$(stub_log_count docker)" -gt 0 ]
}

@test "refresh-configs: --litellm-url renders the url this stack environment publishes" {
  local scratch
  scratch="$(make_scratch)"
  scratch_home "${scratch}/home"
  # A dev stack that remapped LITELLM_PORT has to reseed a settings.json
  # pointing at ITS LiteLLM: 4000 is stable's port, so a hardcoded default
  # would repoint the workspace at the other stack environment.
  run --separate-stderr bash "${REFRESH}" --litellm-url http://host.docker.internal:14000/v1 --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_contains_file "remapped url rendered" "${scratch}/home/.shared/vscode/settings.json" ':14000/v1'
  assert_not_match "stable url absent" ':4000/v1' "$(cat "${scratch}/home/.shared/vscode/settings.json")"
}

@test "refresh-configs: STACK_LITELLM_URL from the environment repoints the reseed too" {
  local scratch
  scratch="$(make_scratch)"
  scratch_home "${scratch}/home"
  run --separate-stderr env STACK_LITELLM_URL=http://host.docker.internal:14000/v1 bash "${REFRESH}" --home "${scratch}/home"
  [ "${status}" -eq 0 ]
  assert_contains_file "env url rendered" "${scratch}/home/.shared/vscode/settings.json" ':14000/v1'
}

@test "refresh-configs: --litellm-url without a value is a usage error" {
  run --separate-stderr bash "${REFRESH}" --litellm-url
  [ "${status}" -ne 0 ]
  assert_match "usage shown on a valueless flag" 'usage: bazelisk run //scripts:refresh-configs --' "${output}"
  assert_match "flag named on stderr" 'litellm-url needs a url' "${stderr}"
}
