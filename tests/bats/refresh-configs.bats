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
    "${1}/.coder/skills/ez-learn" "${1}/.coder/skills/learn" "${1}/.agents/skills/learn" \
    "${1}/.coder/skills/ez-skillify" "${1}/.agents/skills/ez-skillify" \
    "${1}/.coder/skills/ez-create-skill" "${1}/.agents/skills/ez-create-skill" \
    "${1}/.coder/skills/ez-bazel-first" "${1}/.agents/skills/ez-bazel-first" \
    "${1}/.coder/skills/ez-strong-types" "${1}/.agents/skills/ez-strong-types"
  # The two command skills carry helper scripts one level deeper, under the
  # skill directory's own scripts/. That nesting is left uncreated on purpose:
  # the reseed has to make the parent directory itself, so a seeder that only
  # ever mkdir'd one level down fails the seed-what-is-absent test below.
  # What the stack left under /learn when the skill moved: the marker-carrying
  # copy is the stack's own and a reseed retires it, the marker-free one is
  # someone else's and survives every reseed.
  printf -- '---\nname: learn\n---\nmanaged-by: evo-t1-coder-stack\n' \
    >"${1}/.coder/skills/learn/SKILL.md"
  printf -- '---\nname: learn\n---\nwritten by hand\n' \
    >"${1}/.agents/skills/learn/SKILL.md"
  # The user's own tmux.conf: marker-free, and carrying a value the stack never
  # writes, so a reseed that clobbered it is visible below.
  printf 'set -g mouse on\n' >"${1}/.tmux.conf"
  printf '{\n  "__evoT1Stack": true,\n  "cline.apiKey": "SECRET-KEEP-ME",\n  "terminal.integrated.scrollback": 40000\n}\n' \
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
  # Twenty-three reseed targets: the five non-skill targets, then grok-build-delegation,
  # ez-learn, ez-skillify and ez-create-skill as one SKILL.md per home (8), then
  # ez-bazel-first as a SKILL.md per home plus two helper scripts per home (6),
  # then ez-strong-types as a SKILL.md per home plus one helper per home (4).
  # The count is a claim about the manifest, so a target that quietly
  # disappears from config_seed.sh fails here before anything else notices.
  [ "$(printf '%s\n' "${lines}" | grep -c .)" -eq 23 ]
  # Home-relative targets keep dev-only paths (scripts/, tests/) out of any
  # workspace volume: an absolute target would put this script's trust
  # boundary in the wrong place.
  assert_not_match "no absolute paths" '^/' "${lines}"
  # Every payload reads from this repo's templates/ tree, in the one file:/render:
  # form the seeder knows. Anchored on the source column rather than grepping the
  # whole line, because a skill's own helper directory is a legitimate nested
  # target path (~/.coder/skills/ez-bazel-first/scripts/owned_files_check.py)
  # while a source of scripts/foo.sh or tests/foo.bats is not a payload at all.
  local bad_source="" source
  while IFS=$'\t' read -r target source; do
    [[ -n ${target} ]] || continue
    [[ ${source} == "file:templates/"* || ${source} == "render:templates/"* ]] ||
      bad_source="${target} -> ${source}"
  done <<<"${lines}"
  [ -z "${bad_source}" ] || fail "a reseed source reads outside templates/: ${bad_source}"
  # Payloads are repo files (file:) or rendered tftpl (render:). Heredoc
  # extraction (block:) is gone; tmux and the agent skill live under common/.
  assert_match "tmux from common" $'file:templates/common/tmux.conf' "${lines}"
  # Both ez-learn skill copies reseed from the one common payload: the chat agent
  # reads ~/.coder/skills/ and the Grok Build CLI reads ~/.agents/skills/, and
  # skill dedupe is first-match-wins, so the twins exist for the two consumers.
  # The ez- prefix keeps the name clear of the upstream built-in memory commands
  # and of the bundled platform skills the CLI would otherwise fetch.
  assert_match "ez-learn skill from common (coder)" \
    $'~/.coder/skills/ez-learn/SKILL.md\tfile:templates/common/ez-learn.SKILL.md' "${lines}"
  assert_match "ez-learn skill from common (agents)" \
    $'~/.agents/skills/ez-learn/SKILL.md\tfile:templates/common/ez-learn.SKILL.md' "${lines}"
  # The two authoring skills ride the same twins-for-two-consumers contract:
  # /ez-skillify and /ez-create-skill are user-invocable in both the chat agent
  # and the CLI, so each needs its own SKILL.md in each home.
  assert_match "ez-skillify skill from common (coder)" \
    $'~/.coder/skills/ez-skillify/SKILL.md\tfile:templates/common/ez-skillify.SKILL.md' "${lines}"
  assert_match "ez-skillify skill from common (agents)" \
    $'~/.agents/skills/ez-skillify/SKILL.md\tfile:templates/common/ez-skillify.SKILL.md' "${lines}"
  assert_match "ez-create-skill skill from common (coder)" \
    $'~/.coder/skills/ez-create-skill/SKILL.md\tfile:templates/common/ez-create-skill.SKILL.md' "${lines}"
  assert_match "ez-create-skill skill from common (agents)" \
    $'~/.agents/skills/ez-create-skill/SKILL.md\tfile:templates/common/ez-create-skill.SKILL.md' "${lines}"
  # The two command skills ship helper programs beside their SKILL.md, and those
  # sit one level deeper, in the skill directory's own scripts/. Both homes need
  # them: the chat agent runs the ~/.coder copy and the CLI runs the ~/.agents
  # copy, and a helper that only landed in one home is a command that half works.
  assert_match "ez-bazel-first skill from common (coder)" \
    $'~/.coder/skills/ez-bazel-first/SKILL.md\tfile:templates/common/ez-bazel-first.SKILL.md' "${lines}"
  assert_match "ez-bazel-first skill from common (agents)" \
    $'~/.agents/skills/ez-bazel-first/SKILL.md\tfile:templates/common/ez-bazel-first.SKILL.md' "${lines}"
  assert_match "ez-bazel-first owned_files_check from common (coder)" \
    $'~/.coder/skills/ez-bazel-first/scripts/owned_files_check.py\tfile:templates/common/ez-bazel-first.owned_files_check.py' "${lines}"
  assert_match "ez-bazel-first owned_files_check from common (agents)" \
    $'~/.agents/skills/ez-bazel-first/scripts/owned_files_check.py\tfile:templates/common/ez-bazel-first.owned_files_check.py' "${lines}"
  assert_match "ez-bazel-first glob_budget from common (coder)" \
    $'~/.coder/skills/ez-bazel-first/scripts/glob_budget.py\tfile:templates/common/ez-bazel-first.glob_budget.py' "${lines}"
  assert_match "ez-bazel-first glob_budget from common (agents)" \
    $'~/.agents/skills/ez-bazel-first/scripts/glob_budget.py\tfile:templates/common/ez-bazel-first.glob_budget.py' "${lines}"
  assert_match "ez-strong-types skill from common (coder)" \
    $'~/.coder/skills/ez-strong-types/SKILL.md\tfile:templates/common/ez-strong-types.SKILL.md' "${lines}"
  assert_match "ez-strong-types skill from common (agents)" \
    $'~/.agents/skills/ez-strong-types/SKILL.md\tfile:templates/common/ez-strong-types.SKILL.md' "${lines}"
  assert_match "ez-strong-types type_baseline from common (coder)" \
    $'~/.coder/skills/ez-strong-types/scripts/type_baseline.py\tfile:templates/common/ez-strong-types.type_baseline.py' "${lines}"
  assert_match "ez-strong-types type_baseline from common (agents)" \
    $'~/.agents/skills/ez-strong-types/scripts/type_baseline.py\tfile:templates/common/ez-strong-types.type_baseline.py' "${lines}"
  # Six of the twenty-three are those nested helpers, named here as a count so a
  # nested target dropped from the manifest is caught even when the total is
  # restored by some unrelated target.
  [ "$(printf '%s\n' "${lines}" | grep -c '/scripts/')" -eq 6 ]
  assert_not_match "no block kind" $'\tblock:' "${lines}"
}

@test "config_seed: seed_target_owner tells managed from user from absent" {
  # shellcheck source=/dev/null
  source "${LIB}"
  local scratch state
  scratch="$(make_scratch)"
  state="$(seed_target_owner "" "${scratch}/absent.conf")"
  [ "${state}" = "absent" ]
  # Same bytes as the managed copy below: the marker alone decides the owner.
  printf 'set -g mouse on\n' >"${scratch}/user.conf"
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
  # The marker-free tmux.conf is user-owned and stays byte-identical: its own
  # mouse on survives, where the stack default the reseed would write is off.
  assert_match "user tmux.conf untouched" 'mouse on' "$(cat "${scratch}/home/.tmux.conf")"
  # The managed settings.json was re-rendered from the repo template...
  assert_contains_file "fresh scrollback" "${scratch}/home/.shared/vscode/settings.json" '"terminal.integrated.scrollback": 2000'
  # ...and it kept the key the workspace was handed on its first boot.
  assert_contains_file "key carried" "${scratch}/home/.shared/vscode/settings.json" 'SECRET-KEEP-ME'
  # Absent targets get seeded, twins included.
  assert_file_exists "agents twin" "${scratch}/home/.agents/INSTRUCTIONS.md"
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/grok-build-delegation/SKILL.md"
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/ez-learn/SKILL.md"
  assert_file_exists "agents skill" "${scratch}/home/.agents/skills/ez-learn/SKILL.md"
  # Each new skill seeds in both homes: an absent twin means that consumer's
  # slash-command silently never exists, so name every target, not one per skill.
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/ez-skillify/SKILL.md"
  assert_file_exists "agents skill" "${scratch}/home/.agents/skills/ez-skillify/SKILL.md"
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/ez-create-skill/SKILL.md"
  assert_file_exists "agents skill" "${scratch}/home/.agents/skills/ez-create-skill/SKILL.md"
  # The two command skills, both homes, SKILL.md and every nested helper. The
  # helpers are the ones worth naming: their parent scripts/ directory does not
  # exist in the fixture, so this is where a seeder that cannot create a nested
  # parent is caught.
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/ez-bazel-first/SKILL.md"
  assert_file_exists "agents skill" "${scratch}/home/.agents/skills/ez-bazel-first/SKILL.md"
  assert_file_exists "coder nested helper" \
    "${scratch}/home/.coder/skills/ez-bazel-first/scripts/owned_files_check.py"
  assert_file_exists "agents nested helper" \
    "${scratch}/home/.agents/skills/ez-bazel-first/scripts/owned_files_check.py"
  assert_file_exists "coder nested helper" \
    "${scratch}/home/.coder/skills/ez-bazel-first/scripts/glob_budget.py"
  assert_file_exists "agents nested helper" \
    "${scratch}/home/.agents/skills/ez-bazel-first/scripts/glob_budget.py"
  assert_file_exists "coder skill" "${scratch}/home/.coder/skills/ez-strong-types/SKILL.md"
  assert_file_exists "agents skill" "${scratch}/home/.agents/skills/ez-strong-types/SKILL.md"
  assert_file_exists "coder nested helper" \
    "${scratch}/home/.coder/skills/ez-strong-types/scripts/type_baseline.py"
  assert_file_exists "agents nested helper" \
    "${scratch}/home/.agents/skills/ez-strong-types/scripts/type_baseline.py"
  # A seeded helper is the payload, not an empty placeholder: the command's
  # behaviour depends on this program being there and being itself.
  assert_contains_file "owned_files_check is the repo payload" \
    "${scratch}/home/.coder/skills/ez-bazel-first/scripts/owned_files_check.py" 'def '
  assert_contains_file "type_baseline is the repo payload" \
    "${scratch}/home/.agents/skills/ez-strong-types/scripts/type_baseline.py" 'def '
  # The copy the stack seeded under /learn before the rename goes, because it
  # still carries the marker; the marker-free one is whoever's it is, and it
  # stays.
  assert_file_not_exists "retired managed copy" \
    "${scratch}/home/.coder/skills/learn/SKILL.md"
  assert_file_exists "retired user copy spared" \
    "${scratch}/home/.agents/skills/learn/SKILL.md"
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
  assert_contains_file "tmux.conf reseeded" "${scratch}/home/.tmux.conf" 'set -g mouse off'
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
  python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["dry_run"] is False and d["force"] is False, d
# The twenty-three reseed targets, plus the one /learn copy the reseed retired from
# this home (its ~/.agents twin is user-owned, so it earns no entry below).
# Every target earns exactly one entry, the user-owned tmux.conf included, so
# this count is the size of the manifest read back through the JSON channel: a
# target dropped from config_seed.sh drops an entry and fails here.
assert len(d["entries"]) == 24, d["entries"]
# A seeded entry names its target home-relative but already stripped the tilde
# (the seeder prints the path it rooted at the home), while a retired entry
# keeps the ~/ spelling it is listed under. Check the nested helpers by the
# name the reseed reports, in both homes.
targets = [e["target"] for e in d["entries"]]
for want in [".coder/skills/ez-bazel-first/scripts/owned_files_check.py",
             ".agents/skills/ez-bazel-first/scripts/owned_files_check.py",
             ".coder/skills/ez-bazel-first/scripts/glob_budget.py",
             ".agents/skills/ez-bazel-first/scripts/glob_budget.py",
             ".coder/skills/ez-strong-types/scripts/type_baseline.py",
             ".agents/skills/ez-strong-types/scripts/type_baseline.py"]:
    assert want in targets, (want, targets)
retired = [e for e in d["entries"] if e["target"] == "~/.coder/skills/learn/SKILL.md"]
assert len(retired) == 1 and retired[0]["action"].startswith("retired"), retired
# The marker-free copy is user-owned, so it earns no entry at all.
assert not [e for e in d["entries"] if e["target"] == "~/.agents/skills/learn/SKILL.md"], d
' <"${scratch}/out.json"
}

@test "refresh-configs: against a named container every call is an exec, never a run" {
  # With exec passed through, the seed script runs ON THE HOST against the
  # --container-root tree the stub hands it, so this pins the whole
  # docker-exec plumbing shape the real daemon would see.
  export STUB_COMPOSE_PS='coder-demo-abc'
  local scratch
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/root/.shared/vscode"
  printf 'set -g mouse on\n' >"${scratch}/root/.tmux.conf"
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
