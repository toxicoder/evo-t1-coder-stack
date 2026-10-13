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
# scratch tree so no test needs a daemon.
#
# The whole suite skips while scripts/refresh-configs.sh is absent: a suite
# for a script that does not exist yet has no right to fail the gate.
#
# Usage: bats tests/bats/refresh-configs.bats
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
  mkdir -p "${1}/.shared/vscode" "${1}/.coder/skills/grok-build-delegation"
  printf 'set -g mouse off\n' >"${1}/.tmux.conf"
  printf '{\n  "__evoT1Stack": true,\n  "cline.apiKey": "SECRET-KEEP-ME",\n  "terminal.integrated.scrollback": 2000\n}\n' \
    >"${1}/.shared/vscode/settings.json"
}

@test "refresh-configs: --help and an unknown option both print the usage" {
  run --separate-stderr bash "${REFRESH}" --help
  [ "${status}" -eq 0 ]
  assert_match "help text" 'usage: refresh-configs' "${output}"

  run --separate-stderr bash "${REFRESH}" --bogus
  [ "${status}" -ne 0 ]
  assert_match "usage shown on a bad flag" 'usage: refresh-configs' "${output}"
  # The usage paths never consult the (stubbed) docker CLI.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "config_seed: seed_extract_tftpl_block lifts the real block and refuses a miss" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local body
  body="$(seed_extract_tftpl_block "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" TMUX_CONF_EOF)"
  assert_match "block body" 'set -g mouse on' "${body}"
  run seed_extract_tftpl_block "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" NO_SUCH_DELIM
  [ "${status}" -ne 0 ]
  assert_match "miss is a note" 'skipped' "${output}"
}

@test "config_seed: seed_seed_targets lists only home-relative reseed targets" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local lines target
  lines="$(seed_seed_targets)"
  [ "$(printf '%s\n' "${lines}" | grep -c .)" -eq 7 ]
  # Home-relative targets keep dev-only paths (scripts/, tests/) out of any
  # workspace volume: an absolute target would put this script's trust
  # boundary in the wrong place.
  assert_not_match "no absolute paths" '^/' "${lines}"
  assert_not_match "no dev-only sources" '(scripts|tests)/' "${lines}"
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
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["dry_run"] is False and d["force"] is False and len(d["entries"]) == 7' <"${scratch}/out.json"
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
