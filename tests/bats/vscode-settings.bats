#!/usr/bin/env bats
#
# ## vscode-settings.bats — the shared code-server User settings seed.
#
# The desktop settings dump is adapted for this stack and checked in. The
# seed must stay free of desktop paths and secrets, both template copies must
# stay byte-identical, and the startup twins each copy it once onto the
# per-owner volume, while the dev-container template's code-server fork
# merges it into the dev container's private copy only while the toggle is on.
# The startup script's two merge branches (jq, then the python3 fallback) are
# lifted out of the shipped twin and executed over one fixture, so the two
# implementations of the precedence are held to the same result.
#
# Usage: bazelisk test //tests:bats_vscode_settings_test   (from any cwd)
# Safety: reads the two template dirs; writes only inside the per-test scratch
# tree, which is where the two merge branches are executed.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
}

# lift_jq_merge <startup> - print the jq program of the shipped merge branch,
# which is the single-quoted argument on the line running `jq -s`. Lifting it
# instead of retyping it is the point: a rewrite of the twin is what runs here.
lift_jq_merge() {
  local line q
  q="'"
  line="$(grep -F '(.[0] * .[1])' "$1" | head -n 1)"
  [ -n "${line}" ] || return 1
  line="${line#*"$q"}"
  line="${line%%"$q"*}"
  [ -n "${line}" ] || return 1
  printf '%s' "${line}"
}

# lift_python_merge <startup> - print the source of the shipped python3 fallback,
# which is the single-quoted -c argument of the SETTINGS_OUT= line. That line is
# the merge, not the SETTINGS_PATH seed check further up the script. The program
# carries no single quote of its own, so the outer pair is unambiguous.
lift_python_merge() {
  local line q
  q="'"
  line="$(grep -F 'SETTINGS_OUT=' "$1" | grep -F "python3 -c '" | head -n 1)"
  [ -n "${line}" ] || return 1
  line="${line#*python3 -c }"
  line="${line#*"$q"}"
  line="${line%%"$q"*}"
  [ -n "${line}" ] || return 1
  printf '%s' "${line}"
}

@test "settings: the two settings.json.tftpl copies are byte-identical" {
  local a="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  local b="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  [[ -f "${a}" && -f "${b}" ]]
  cmp -s "${a}" "${b}"
}

@test "settings: the seed is JSON once Terraform escapes are unfolded" {
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  # $${workspaceFolder} is how the tftpl emits a VS Code substitution.
  # ${litellm_url} is a real Terraform interpolation and stays as text here.
  local unfolded
  unfolded="$(sed 's/\$\${/${/g' "${seed}")"
  printf '%s' "${unfolded}" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "settings: shell-integration decorations are off, because tmux swallows their marks" {
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  # The decorations are drawn from OSC 133 "command started / finished" marks, and an
  # unwrapped OSC reaches no tmux client under any allow-passthrough value (measured in
  # the tmux seed's own reasoning): tmux drops them on the floor. So for the default
  # tmux profile xterm.js pays the per-line decoration pass to render nothing. The key
  # is global in VS Code, which is the honest trade here: a plain shell loses a gutter
  # marker, the tmux profile that every workspace opens by default stops repainting.
  assert_contains_file "no decoration pass for marks that never arrive" "${seed}" \
    '"terminal.integrated.shellIntegration.decorationsEnabled": "none"'
}

@test "settings: no desktop paths, personal words, or API key in the seed" {
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  local banned
  for banned in \
    '/Users/' \
    'homebrew' \
    'parallels' \
    'kilo-code' \
    'toxicoder' \
    '/home/vscode' \
    'continue.continue' \
    'app.kilo.ai' \
    'prlctl' \
    'litellm_key' \
    'profiles.osx' \
    'spark0'; do
    run grep -F "${banned}" "${seed}"
    [ "${status}" -ne 0 ] || { echo "banned string ${banned} is in the seed" >&2; return 1; }
  done
}

@test "settings: coder terminal profiles and the LiteLLM endpoint stay" {
  local seed="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  local need
  for need in \
    'grok-build-terminal' \
    'vscode-terminal-tmux' \
    '${litellm_url}' \
    '"terminal.integrated.defaultProfile.linux": "tmux"' \
    '"python.defaultInterpreterPath": "/usr/bin/python3"' \
    '"chat.disableAIFeatures": true' \
    '"workbench.colorTheme": "${vscode_color_theme}"' \
    '$${workspaceFolder}'; do
    run grep -F "${need}" "${seed}"
    [ "${status}" -eq 0 ] || { echo "missing ${need} in the seed" >&2; return 1; }
  done
}

@test "settings: the model list names every alias the Grok config catalogues" {
  # The editor's model picker reads this array; it has to carry the Spark lane,
  # its three baked-thinking aliases, the unpinned swarm alias and both
  # fast-compaction twins, alongside the Arc fallbacks, or the extensions offer
  # aliases the rendered ~/.grok/config.toml does not define.
  # `high` stays out of every spelling: Qwen3.8-Flash-Next does not answer it.
  local a b f need unfolded models
  a="${REPO_ROOT}/templates/workspace/settings.json.tftpl"
  b="${REPO_ROOT}/templates/devcontainer/settings.json.tftpl"
  for need in \
    '"agent"' '"agent-low"' '"agent-medium"' '"agent-xhigh"' '"agent-xhigh-fast"' \
    '"agent-swarm"' '"agent-swarm-fast"' \
    '"coder"' '"coder-fast"' '"chat"'; do
    run grep -F "${need}" "${a}"
    [ "${status}" -eq 0 ] || { echo "missing ${need} in ${a}" >&2; return 1; }
  done
  # The swarm aliases are the only ones that reach all three Spark boxes, so a
  # twin that lost either cannot fan a workspace out at all.
  for f in "${a}" "${b}"; do
    for need in '"agent-swarm"' '"agent-swarm-fast"'; do
      run grep -F "${need}" "${f}"
      [ "${status}" -eq 0 ] || { echo "missing ${need} in ${f}" >&2; return 1; }
    done
  done
  run grep -F '"agent-high"' "${a}"
  [ "${status}" -ne 0 ] || { echo "agent-high is not a level this runtime answers" >&2; return 1; }
  # Same array, both copies, in the pinned order.
  unfolded="$(sed 's/\$\${/${/g' "${a}")"
  models="$(printf '%s' "${unfolded}" | python3 -c \
    'import json,sys; print(" ".join(json.load(sys.stdin)["__evoT1StackModels"]))')"
  assert_eq "the seed lists every stack alias" \
    "agent agent-low agent-medium agent-xhigh agent-xhigh-fast agent-swarm agent-swarm-fast coder coder-fast chat" "${models}"
  cmp -s "${a}" "${b}"
  # The keys that make the editor open on the folder the script pins: no
  # restored window, no startup editor.
  for need in '"window.restoreWindows": "none"' '"workbench.startupEditor": "none"'; do
    run grep -F "${need}" "${a}"
    [ "${status}" -eq 0 ] || { echo "missing ${need} in the seed" >&2; return 1; }
  done
}

@test "settings: both startups seed once and both mains mount the shared volume" {
  local startup main
  for startup in \
    "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"; do
    run grep -F 'shared_settings="$HOME/.shared/vscode/settings.json"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'if [ ! -f "$shared_settings" ]; then' "${startup}"
    [ "${status}" -eq 0 ]
    # Empty named volumes are root:root 755; chown before the first write, and
    # do not run jq/python against a file the cat never created.
    run grep -F '$SUDO chown -R "$home_owner" "$HOME/.shared" "$HOME/.grok"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'if cat >"$shared_settings"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'the vscode-settings volume is not writable' "${startup}"
    [ "${status}" -eq 0 ]
    # The stack creates no symlink any more: settings.json is a real per-workspace
    # file written to a .tmp and moved, and a symlink the operator made is left be.
    run grep -F 'ln -sfn "$shared_settings" "$user_settings"' "${startup}"
    [ "${status}" -ne 0 ] || { echo "${startup} still symlinks settings.json onto the shared volume" >&2; return 1; }
    run grep -F '$${user_settings}.pre-shared' "${startup}"
    [ "${status}" -ne 0 ] || { echo "${startup} still archives the real file on every boot" >&2; return 1; }
    run grep -F 'if [ -L "$user_settings" ]; then' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'the stack leaves it alone' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'user_settings_new="$${user_settings}.tmp"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'mv -f "$user_settings_new" "$user_settings"' "${startup}"
    [ "${status}" -eq 0 ]
    # The python3 fallback is reached only when jq is absent, so its seam is
    # pinned here and its behaviour is executed by the merge test below.
    run grep -F 'SETTINGS_BASE="$user_settings_new" SETTINGS_OVERLAY="$shared_settings"' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F 'SETTINGS_OUT="$${user_settings_new}.m"' "${startup}"
    [ "${status}" -eq 0 ]
    # The theme re-assert on the jq path; the python path's own re-assert is
    # proved behaviourally, so a rewrite of that lambda cannot slip past.
    run grep -F '"workbench.colorTheme": (.[0]["workbench.colorTheme"]' "${startup}"
    [ "${status}" -eq 0 ]
    run grep -F '$${LITELLM_API_KEY:-}' "${startup}"
    [ "${status}" -eq 0 ]
  done
  for main in \
    "${REPO_ROOT}/templates/workspace/main.tf" \
    "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    run grep -F 'vscode-settings-${data.coder_workspace_owner.me.id}' "${main}"
    [ "${status}" -eq 0 ]
    run grep -F 'container_path = "/home/coder/.shared/vscode"' "${main}"
    [ "${status}" -eq 0 ]
    run grep -F 'litellm_key = var.litellm_key' "${main}"
    [ "${status}" -ne 0 ]
  done
}

@test "settings: both merge branches execute to one deep merge with the render's theme last" {
  # The jq path and the python3 fallback are two independent implementations of
  # one precedence, and only one of them runs on any given boot. So both programs
  # are lifted out of the shipped workspace twin and EXECUTED over the same
  # fixture, then held to the same object: the render's theme wins over the
  # overlay's, the overlay wins inside a nested object, a key either side holds
  # alone survives, and neither path may flatten the nested object.
  local startup dir jq_prog py_prog base overlay jq_out py_out jq_canon py_canon f
  startup="${REPO_ROOT}/templates/workspace/startup.sh.tftpl"
  dir="$(make_scratch)"
  if ! jq_prog="$(lift_jq_merge "${startup}")"; then
    echo "no jq merge branch to lift out of ${startup}" >&2
    return 1
  fi
  if ! py_prog="$(lift_python_merge "${startup}")"; then
    echo "no python3 merge branch to lift out of ${startup}" >&2
    return 1
  fi
  base="${dir}/base.json"
  overlay="${dir}/overlay.json"
  cat >"${base}" <<'SETTINGS_BASE_JSON'
{"workbench.colorTheme": "Grokked", "workbench.colorCustomizations": {"editor.background": "#111111", "statusBar.background": "#222222"}, "operator.kept": 1}
SETTINGS_BASE_JSON
  cat >"${overlay}" <<'SETTINGS_OVERLAY_JSON'
{"workbench.colorTheme": "Monokai", "workbench.colorCustomizations": {"editor.background": "#999999"}, "operator.added": 2}
SETTINGS_OVERLAY_JSON
  jq_out="${dir}/jq.json"
  py_out="${dir}/python.json"
  jq -s "${jq_prog}" "${base}" "${overlay}" >"${jq_out}"
  SETTINGS_BASE="${base}" SETTINGS_OVERLAY="${overlay}" SETTINGS_OUT="${py_out}" \
    python3 -c "${py_prog}"
  [ -s "${py_out}" ] || { echo "the python3 branch wrote nothing to ${py_out}" >&2; return 1; }
  # One object from both paths. A shallow {**b,**o} fallback fails here first.
  jq_canon="$(jq -S -c . "${jq_out}")"
  py_canon="$(jq -S -c . "${py_out}")"
  [ "${jq_canon}" = "${py_canon}" ] || {
    echo "the two merge branches disagree:"
    echo "  jq     ${jq_canon}" >&2
    echo "  python ${py_canon}" >&2
    return 1
  }
  # Each precedence rule, checked on both paths. jq reads a dotted key as a path,
  # so every one of these is quoted as a single key.
  for f in "${jq_out}" "${py_out}"; do
    [ "$(jq -r '."workbench.colorTheme"' "${f}")" = "Grokked" ] || {
      echo "${f}: the shared overlay vetoed this workspace's own theme" >&2
      return 1
    }
    [ "$(jq -r '."workbench.colorCustomizations"."editor.background"' "${f}")" = "#999999" ] || {
      echo "${f}: the overlay did not win inside workbench.colorCustomizations" >&2
      return 1
    }
    [ "$(jq -r '."workbench.colorCustomizations"."statusBar.background"' "${f}")" = "#222222" ] || {
      echo "${f}: the merge flattened the nested object" >&2
      return 1
    }
    [ "$(jq -r '."operator.added"' "${f}")" = "2" ] || {
      echo "${f}: an overlay-only key was dropped" >&2
      return 1
    }
    [ "$(jq -r '."operator.kept"' "${f}")" = "1" ] || {
      echo "${f}: a render-only key was dropped" >&2
      return 1
    }
  done
}

@test "settings: workspace template does not hand the seed to the inlined code-server fork" {
  local main="${REPO_ROOT}/templates/workspace/main.tf"
  # The fork carries a seed (if any) in its script's SETTINGS_B64 line;
  # the workspace fork has none, because the startup script writes the real
  # settings.json there (render, then overlay, then the template's theme).
  run grep -F 'SETTINGS_B64' "${main}"
  [ "${status}" -ne 0 ]
  run grep -F 'machine_settings' "${main}"
  [ "${status}" -ne 0 ]
}

@test "settings: devcontainer merges the seed only while the dev container is on" {
  local main="${REPO_ROOT}/templates/devcontainer/main.tf"
  local cs="${REPO_ROOT}/templates/devcontainer/code-server.sh.tftpl"
  # The seed rides in templatefile's settings_b64, empty (so the shell
  # skips the whole seed/merge block) when the toggle is off.
  run grep -F 'settings_b64' "${main}"
  [ "${status}" -eq 0 ]
  run grep -F 'base64encode(jsonencode(local.vscode_module_settings))' "${main}"
  [ "${status}" -eq 0 ]
  run grep -F "SETTINGS_B64='\${settings_b64}'" "${cs}"
  [ "${status}" -eq 0 ]
  run grep -F 'machine_settings' "${main}"
  [ "${status}" -ne 0 ]
}
