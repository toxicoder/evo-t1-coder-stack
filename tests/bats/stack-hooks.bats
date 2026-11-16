#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## stack-hooks.bats - the guard family's own wiring and behaviour gate.
#
# Six payloads in templates/common/ become one manifest and four scripts under
# ~/.grok/hooks/: hooks.evo-t1-hooks.json, hooks.deny-patterns.txt, and the four
# *.sh guards. The coder_script "stack_hooks" block in both main.tf twins renders
# templates/common/stack-hooks.sh.tftpl, which writes them marker-aware (a copy
# that still carries the stack marker gets the current text on every start; a copy
# whose marker a person deleted stays theirs). scripts/lib/config_seed.sh names the
# same six targets for a host tree or a workspace that missed a boot, using the
# exec: kind so a script that the runner starts directly keeps its mode.
#
# Every one of those seams fails quietly. A manifest whose command does not resolve
# to an executable file is a hook that never runs and never errors. A deny pattern
# that is not a valid ERE is skipped by the guard with one stderr line, so the rule
# it carried simply stops existing -- which is why the compile check here reads exit
# status 2 and not "did it match", the mistake that would demand every deny rule
# match the literal x. A script that lost its marker is left alone by the seed
# forever. And a script whose first line is not its shebang cannot be exec'd at all,
# because the runner starts a relative command out of the manifest directly.
#
# The suite is hermetic: it stages a hook directory in its own scratch space, pipes
# one event JSON at each script on stdin, and reads the decision off stdout and the
# exit status. It runs no network, no docker, no Bazel, and no git operation.

bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper'

  REPO_ROOT="$(bats_canonical_repo_root)" || return 1
  COMMON="${REPO_ROOT}/templates/common"
  HOOKS_JSON="${COMMON}/hooks.evo-t1-hooks.json"
  DENY_LIST="${COMMON}/hooks.deny-patterns.txt"

  # The guards resolve the deny list against their own directory, the way they will
  # at runtime under ~/.grok/hooks/bin/. Staging them under their runtime names is
  # what makes that resolution testable here rather than only on a booted box.
  BINDIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BINDIR}"
  cp "${COMMON}/hooks.secret-guard.sh" "${BINDIR}/secret-guard.sh"
  cp "${COMMON}/hooks.dangerous-command-guard.sh" "${BINDIR}/dangerous-command-guard.sh"
  cp "${COMMON}/hooks.post-edit-format.sh" "${BINDIR}/post-edit-format.sh"
  cp "${COMMON}/hooks.selective-test-runner.sh" "${BINDIR}/selective-test-runner.sh"
  cp "${DENY_LIST}" "${BINDIR}/deny-patterns.txt"
  chmod 755 "${BINDIR}"/*.sh

  # The dangerous command strings live in this file rather than in a shell command,
  # so the tool that runs this suite never carries one in its own command text.
  RMR='rm'
  RFOPT='-r'"$(printf 'f')"
  KILL='ki'"$(printf 'll')"
  PKILL="p${KILL}"
  KALL='k'"$(printf 'illall')"
}

# event_json <tool> <key> <value> [truncated] -- one PreToolUse/PostToolUse event.
# toolInputTruncated is a top-level key and the guide says it is always present.
event_json() {
  local tool="$1" key="$2" value="$3" truncated="${4:-false}"
  local escaped
  escaped="$(printf '%s' "${value}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"toolName":"%s","toolUseId":"t1","toolInput":{"%s":"%s"},"toolInputTruncated":%s}' \
    "${tool}" "${key}" "${escaped}" "${truncated}"
}

# run_hook <script> <event> -> sets hook_out / hook_rc
# A deny exits 2, and under bats' 1.5.0 errexit a command substitution that returns
# non-zero ends the test before the assertion can read the status, so the status is
# folded into the assignment.
run_hook() {
  local script="$1" event="$2"
  hook_out="$(printf '%s' "${event}" | sh "${BINDIR}/${script}" 2>/dev/null)" && hook_rc=0 || hook_rc=$?
}

# assert_decision <expect: deny|allow>
assert_decision() {
  local expect="$1"
  if [ "${expect}" = "deny" ]; then
    [ "${hook_rc}" -eq 2 ] || { printf 'expected deny (exit 2), got exit %s: %s\n' "${hook_rc}" "${hook_out}" >&2; return 1; }
    printf '%s' "${hook_out}" | grep -q '"deny"' || { printf 'exit 2 without a deny decision: %s\n' "${hook_out}" >&2; return 1; }
    printf '%s' "${hook_out}" | grep -q '"reason"' || { printf 'a deny has to say why: %s\n' "${hook_out}" >&2; return 1; }
  else
    [ "${hook_rc}" -eq 0 ] || { printf 'expected allow (exit 0), got exit %s: %s\n' "${hook_rc}" "${hook_out}" >&2; return 1; }
    printf '%s' "${hook_out}" | grep -q '"allow"' || { printf 'no allow decision on stdout: %s\n' "${hook_out}" >&2; return 1; }
  fi
}

# A PostToolUse hook runs after the tool, so it cannot block and its exit code is not
# a decision: exit 0 with empty stdout is that event's "continue", and anything it
# does print is read as JSON. assert_decision's allow branch asks for the PreToolUse
# shape, so the two post-edit hooks get their own.
assert_quiet() {
  [ "${hook_rc}" -eq 0 ] || { printf 'a PostToolUse hook has to exit 0, got %s: %s\n' "${hook_rc}" "${hook_out}" >&2; return 1; }
  if printf '%s' "${hook_out}" | grep -q '"block"'; then
    printf 'a post-edit hook fed the model a block on a path it should ignore: %s\n' "${hook_out}" >&2
    return 1
  fi
  if [ -n "${hook_out}" ]; then
    if ! printf '%s' "${hook_out}" | jq -e . >/dev/null 2>&1; then
      printf 'the stdout of a PostToolUse hook is read as JSON, and this is not: %s\n' "${hook_out}" >&2
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The manifest.
# ---------------------------------------------------------------------------

@test "manifest: parses as JSON and carries the stack marker as its first key" {
  assert_file_exists "the hooks manifest" "${HOOKS_JSON}"
  run jq -e '."__evoT1Stack" == true' "${HOOKS_JSON}"
  [ "${status}" -eq 0 ] || { printf 'manifest has no "__evoT1Stack": true key, so the seed cannot tell it apart from a file the operator owns\n' >&2; return 1; }

  # The marker has to be readable before anything else is, and jq keys are ordered
  # as written, so the first key is the marker.
  local first
  first="$(tr -d ' \n\t' <"${HOOKS_JSON}" | sed 's/^{//' | cut -d: -f1)"
  [ "${first}" = '"__evoT1Stack"' ] || { printf 'first key is %s; the marker has to lead or a reader skips it\n' "${first}" >&2; return 1; }
}

@test "manifest: two PreToolUse groups and two PostToolUse groups" {
  run jq -e '(.hooks.PreToolUse | length) == 2 and (.hooks.PostToolUse | length) == 2' "${HOOKS_JSON}"
  [ "${status}" -eq 0 ] || { printf 'expected 2 PreToolUse and 2 PostToolUse groups: %s\n' "$(jq -c '.hooks | keys' "${HOOKS_JSON}" 2>/dev/null)" >&2; return 1; }
}

@test "manifest: every command it names resolves to a script that exists and is executable" {
  local cmd
  while IFS= read -r cmd; do
    [ -n "${cmd}" ] || continue
    local target="${BINDIR}/${cmd#bin/}"
    [ -f "${target}" ] || { printf 'the manifest starts %s, which is not a file beside it\n' "${cmd}" >&2; return 1; }
    [ -x "${target}" ] || { printf '%s is not executable, and the runner starts it directly\n' "${cmd}" >&2; return 1; }
  done < <(jq -r '.hooks[][] | .hooks[] | .command' "${HOOKS_JSON}")
}

@test "manifest: the matchers cover the write tools and the shell tool" {
  local all
  all="$(jq -r '.hooks.PreToolUse[].matcher' "${HOOKS_JSON}")"
  printf '%s' "${all}" | grep -q 'Write' || { printf 'no write tool in any PreToolUse matcher: %s\n' "${all}" >&2; return 1; }
  printf '%s' "${all}" | grep -q 'run_terminal_command' || { printf 'the shell tool is unmatched, so no command is ever guarded: %s\n' "${all}" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Every payload keeps the shape the seed and the runner need.
# ---------------------------------------------------------------------------

@test "payloads: each script is ASCII, parses under sh, and leads with its shebang" {
  local f
  for f in "${BINDIR}"/*.sh; do
    run env LC_ALL=C grep -c '[^ -~]' "${f}"
    [ "${status}" -ne 0 ] || [ "${lines[0]}" = "0" ] || { printf '%s carries a non-ASCII byte\n' "${f}" >&2; return 1; }
    run sh -n "${f}"
    [ "${status}" -eq 0 ] || { printf '%s does not parse under sh: %s\n' "${f}" "${output}" >&2; return 1; }
    # execve reads row 1 for the interpreter, so the marker has to sit below it.
    run head -1 "${f}"
    [ "${lines[0]}" = '#!/bin/sh' ] || { printf '%s line 1 is %s; the runner starts it directly, so it must be the shebang\n' "${f}" "${lines[0]}" >&2; return 1; }
    run grep -c 'managed-by: evo-t1-coder-stack' "${f}"
    [ "${lines[0]}" -ge 1 ] || { printf '%s carries no stack marker, so the seed treats it as operator-owned and never refreshes it\n' "${f}" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# secret-guard.
# ---------------------------------------------------------------------------

@test "secret-guard: denies a planted AWS access key id" {
  # AKIA plus exactly 16 characters; the split keeps the literal out of this file's
  # own text, which is what the deny-pattern list would otherwise read as a hit.
  run_hook secret-guard.sh "$(event_json write new_string "aws_key = AKI$(printf 'A')IOSFODNN7EXAMPLE")"
  assert_decision deny
  printf '%s' "${hook_out}" | grep -qi 'aws' || { printf 'the reason should name the class that fired: %s\n' "${hook_out}" >&2; return 1; }
}

@test "secret-guard: denies a planted GitHub token" {
  local tok
  tok="gh$(printf 'p')_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
  run_hook secret-guard.sh "$(event_json write content "token: ${tok}")"
  assert_decision deny
}

@test "secret-guard: denies a private key block" {
  run_hook secret-guard.sh "$(event_json write new_string "-----BEGIN RSA PRIVATE KEY-----")"
  assert_decision deny
}

@test "secret-guard: denies an upper-case credential assignment" {
  run_hook secret-guard.sh "$(event_json write new_string "AWS_SECRET_ACCESS_KEY = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")"
  assert_decision deny
}

@test "secret-guard: denies a quoted password assignment" {
  run_hook secret-guard.sh "$(event_json write new_string 'password = "hunter2sup3rs3cret"')"
  assert_decision deny
}

@test "secret-guard: allows code, a config name, a bare sha, and a reference to the environment" {
  local sample
  for sample in "def main(): return 1" "name: evo-t1-coder-stack" \
    "sha: 0123456789abcdef0123456789abcdef01234567" \
    'token: ${GITLlm_TOKEN_FROM_ENVIRONMENT}' \
    "# AKIA-style examples are documented here, not used as keys"; do
    run_hook secret-guard.sh "$(event_json write new_string "${sample}")"
    assert_decision || { printf 'innocent text refused: %s -> %s\n' "${sample}" "${hook_out}" >&2; return 1; }
  done
}

@test "secret-guard: denies when the runner says the input was clipped" {
  run_hook secret-guard.sh "$(event_json write new_string "x = 1" true)"
  assert_decision deny
  run_hook secret-guard.sh "$(event_json write new_string "x = 1" null)"
  assert_decision deny
}

@test "secret-guard: fails open on an event it cannot read" {
  local event
  for event in '' 'not json at all' '{"toolName":"write","toolInput":"a-string","toolInputTruncated":false}'; do
    hook_out="$(printf '%s' "${event}" | sh "${BINDIR}/secret-guard.sh" 2>/dev/null)" && hook_rc=0 || hook_rc=$?
    assert_decision || { printf 'a broken event blocked a write: %s -> %s\n' "${event}" "${hook_out}" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# dangerous-command-guard and its list.
# ---------------------------------------------------------------------------

@test "deny list: every pattern compiles, judged on exit status 2" {
  # grep exits 1 for "compiles and matched nothing" and 2 for "does not compile".
  # Reading 1 as failure would demand that every deny rule match the literal x, and
  # a rule that did match x would deny every command there is.
  local pattern bad=0 n=0 rc
  while IFS= read -r pattern; do
    case "${pattern}" in '' | '#'*) continue ;; esac
    n=$((n + 1))
    rc=0
    LC_ALL=C grep -E -q -- "${pattern}" </dev/null || rc=$?
    if [ "${rc}" -gt 1 ]; then
      printf 'invalid ERE: %s\n' "${pattern}" >&2
      bad=$((bad + 1))
    fi
  done <"${DENY_LIST}"
  [ "${bad}" -eq 0 ] || return 1
  [ "${n}" -ge 20 ] || { printf 'only %s patterns; the list is meant to cover six families\n' "${n}" >&2; return 1; }
}

@test "deny list: no trailing whitespace and pure ASCII" {
  run env LC_ALL=C grep -c '[^ -~]' "${DENY_LIST}"
  [ "${status}" -ne 0 ] || [ "${lines[0]}" = "0" ]
  ! grep -nE ' +$' "${DENY_LIST}" | grep -q .
}

@test "dangerous-command-guard: denies the irreversible and the session-ending forms" {
  local case_name cmd
  for case_name in "rm-rf-glob:${RMR} ${RFOPT} build/*" \
    "rm-rf-root:${RMR} ${RFOPT} /" \
    "kill-zero:${KILL} 0" \
    "kill-pgid:${KILL} -- -1234" \
    "pkill-uid:${PKILL} -u coder" \
    "pkill-pid:${PKILL} -P 4321" \
    "killall:${KALL} grok"; do
    cmd="${case_name#*:}"
    run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${cmd}")"
    assert_decision deny || { printf 'not denied: %s (%s) -> %s\n' "${case_name}" "${cmd}" "${hook_out}" >&2; return 1; }
  done
}

@test "dangerous-command-guard: names the deny-list line it matched" {
  run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${RMR} ${RFOPT} build/*")"
  assert_decision deny
  printf '%s' "${hook_out}" | grep -q 'line [0-9]' || { printf 'a deny should point at the rule: %s\n' "${hook_out}" >&2; return 1; }
}

@test "dangerous-command-guard: leaves the sanctioned forms alone" {
  local cmd
  for cmd in "ls -1" \
    "bazelisk test //:test-fast" \
    "bazelisk run //scripts:bazel-map -- files //tests" \
    "git add scripts/x.sh" \
    "git commit -m msg" \
    "git push -u origin feat/x" \
    "rm -f /tmp/one-file" \
    "find /tmp/scratch -type f -delete" \
    "grep -rn 'rm -rf' scripts" \
    "tmux ls"; do
    run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${cmd}")"
    assert_decision || { printf 'sanctioned command blocked: %s -> %s\n' "${cmd}" "${hook_out}" >&2; return 1; }
  done
}

@test "dangerous-command-guard: denies a command it could not see whole" {
  run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "ls -1" true)"
  assert_decision deny
}

# ---------------------------------------------------------------------------
# The two PostToolUse hooks must never obstruct the edit they follow.
# ---------------------------------------------------------------------------

@test "post-edit-format: leaves every refused path untouched and exits 0" {
  local path
  for path in ".git/config" "$HOME/.grok/config.toml" "$HOME/.agents/skills/x/SKILL.md" \
    "$HOME/.coder/skills/x/SKILL.md" "bazel-out/stale.sh" "node_modules/pack/index.js"; do
    run_hook post-edit-format.sh "$(event_json write file_path "${path}")"
    assert_quiet || { printf 'a formatter must not obstruct an edit: %s -> %s\n' "${path}" "${hook_out}" >&2; return 1; }
  done
}

@test "selective-test-runner: stays off until the operator opts in" {
  # No EVO_T1_HOOK_TESTS in the environment, so a test run is never started for a
  # small edit: the hook's whole cost model depends on this being the default.
  unset EVO_T1_HOOK_TESTS
  run_hook selective-test-runner.sh "$(event_json write file_path "scripts/lib/config_seed.sh")"
  assert_quiet
  [ ! -d "${TMPDIR:-/tmp}/evo-t1-hook-tests" ] || {
    printf 'the runner wrote a log dir with the opt-in unset: %s\n' "${TMPDIR:-/tmp}/evo-t1-hook-tests" >&2
    return 1; }
}

@test "selective-test-runner: ignores paths outside the project and under a refusal" {
  unset EVO_T1_HOOK_TESTS
  EVO_T1_HOOK_TESTS=1
  local path
  for path in ".git/hooks/commit-msg" "$HOME/.grok/config.toml" "$HOME/.agents/skills/x/SKILL.md"; do
    run_hook selective-test-runner.sh "$(event_json write file_path "${path}")"
    assert_quiet || { printf 'the runner obstructed an edit under %s: %s\n' "${path}" "${hook_out}" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# Registration.
# ---------------------------------------------------------------------------

@test "registration: config_seed names all six hook targets, executable for the scripts" {
  local seed="${REPO_ROOT}/scripts/lib/config_seed.sh"
  assert_file_exists "the seed library" "${seed}"

  # A row that lost its trailing backslash makes the whole list unextractable, so a
  # failure here is as fatal as a missing row and is reported as its own defect.
  if ! load_shell_function "${seed}" seed_seed_targets; then
    printf 'FAIL: seed_seed_targets in %s cannot be extracted - its printf list is malformed\n' "${seed}" >&2
    return 1
  fi
  local targets
  targets="$(seed_seed_targets)"

  printf '%s\n' "${targets}" | grep -qF '~/.grok/hooks/evo-t1-hooks.json	file:templates/common/hooks.evo-t1-hooks.json' || {
    printf 'FAIL: the manifest is not registered as a file: payload\n' >&2; return 1; }
  printf '%s\n' "${targets}" | grep -qF '~/.grok/hooks/bin/deny-patterns.txt	file:templates/common/hooks.deny-patterns.txt' || {
    printf 'FAIL: the deny list is not registered\n' >&2; return 1; }

  local name
  for name in secret-guard dangerous-command-guard post-edit-format selective-test-runner; do
    printf '%s\n' "${targets}" | grep -qF "~/.grok/hooks/bin/${name}.sh	exec:templates/common/hooks.${name}.sh" || {
      printf 'FAIL: ~/.grok/hooks/bin/%s.sh is not registered as exec:; the runner starts it directly, so a lost mode bit breaks it silently\n' "${name}" >&2
      return 1; }
  done
}

@test "registration: both main.tf twins feed all six hook keys into stack_hooks" {
  local twin key
  for twin in workspace devcontainer; do
    local block="${REPO_ROOT}/templates/${twin}/main.tf"
    assert_file_exists "the ${twin} twin" "${block}"
    for key in evo_t1_hooks_json secret_guard_sh dangerous_command_guard_sh \
      post_edit_format_sh selective_test_runner_sh deny_patterns_txt; do
      grep -qE "${key}[[:space:]]*=[[:space:]]*chomp\(file\(\"\\\$\{path\.module\}/hooks\." "${block}" || {
        printf 'FAIL: %s/main.tf does not feed %s, chomped, into the stack_hooks block\n' "${twin}" "${key}" >&2
        return 1; }
    done
  done
}

@test "registration: the seed body is marker-aware and makes every script executable" {
  local body="${COMMON}/stack-hooks.sh.tftpl"
  assert_file_exists "the hooks seed body" "${body}"
  run sh -n "${body}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: the seed body does not parse under sh: %s\n' "${output}" >&2; return 1; }

  # Marker-aware, unlike every other family: a guard that drifted from the seed is a
  # silent behaviour change, so the boot rewrites it while the marker stands.
  local n
  n="$(grep -c 'managed-by: evo-t1-coder-stack' "${body}")"
  [ "${n}" -ge 4 ] || { printf 'FAIL: the seed body tests for the marker only %s times; a family of five needs one guard per payload\n' "${n}" >&2; return 1; }
  n="$(grep -c 'chmod 0755' "${body}")"
  [ "${n}" -ge 4 ] || { printf 'FAIL: only %s chmod lines for four scripts the runner starts directly\n' "${n}" >&2; return 1; }

  # Every single-dollar ${name} in the body is a Terraform interpolation the twins have
  # to feed: an unmapped key fails the render at workspace start, which is the loudest
  # failure this family can have. The $$ escapes are shell vars and belong here, so
  # those are stripped first rather than demanding the file carry none at all.
  local key w hit seen=0
  local -a want=(evo_t1_hooks_json secret_guard_sh dangerous_command_guard_sh \
    post_edit_format_sh selective_test_runner_sh deny_patterns_txt)
  while IFS= read -r key; do
    [ -n "${key}" ] || continue
    seen=$((seen + 1))
    hit=0
    for w in "${want[@]}"; do
      if [ "${key}" = "${w}" ]; then hit=1; fi
    done
    [ "${hit}" -eq 1 ] || { printf 'FAIL: the seed body interpolates ${%s}, which no main.tf twin feeds\n' "${key}" >&2; return 1; }
  done < <(sed -E 's/\$\$\{[a-z0-9_]+\}//g' "${body}" | grep -oE '\$\{[a-z0-9_]+\}' | sed -E 's/^\$\{([a-z0-9_]+)\}$/\1/' | sort -u)
  [ "${seen}" -eq 6 ] || { printf 'FAIL: only %s of the six payload keys are interpolated, so a hook file would seed empty\n' "${seen}" >&2; return 1; }
}
