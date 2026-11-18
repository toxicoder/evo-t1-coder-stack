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
  # Assembled from fragments the way every other refused shape here is: this file is
  # itself a write, and a guard that can deny the test which proves it would be a guard
  # nobody can commit.
  local block
  block="-----BEGIN RSA $(printf 'PRIVATE KEY')-----"
  run_hook secret-guard.sh "$(event_json write new_string "${block}")"
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

@test "secret-guard: allows the environment indirection this repo's own litellm config writes" {
  # LiteLLM points at the environment the way Python says it, and the value class in the
  # assignment patterns only excludes a shell reference -- so the guard denied a write to
  # litellm/config.yaml, the file the agent edits most in this repo. The line is read out
  # of that file rather than quoted here, so the test moves when the spelling moves.
  local line
  line="$(grep -m1 'api_key: os\.environ/' "${REPO_ROOT}/litellm/config.yaml")"
  [ -n "${line}" ] || {
    printf 'litellm/config.yaml carries no os.environ api_key any more: re-measure this\n' >&2
    return 1; }
  run_hook secret-guard.sh "$(event_json write new_string "${line}")"
  assert_decision || { printf 'the guard refuses its own repo config: %s -> %s\n' "${line}" "${hook_out}" >&2; return 1; }
}

@test "secret-guard: lets a value that is a reference or a call through" {
  # The digit gate is what separates a secret from a name, and both the case-folded pass
  # and the plain one have to carry it: an SDK sample assigns a credential from a getter,
  # and a guard that denies those teaches everyone to delete the guard.
  local sample
  for sample in "api_key: os.environ/LITELLM_BASE?http://127.0.0.1:4000" \
    "api_key: base64_environ/SPARK_MASTER_KEY" \
    "const apiKey = getUserSuppliedValue();" \
    "password = readFromVault()" \
    "client_secret=getCredentialsFromStore()"; do
    run_hook secret-guard.sh "$(event_json write new_string "${sample}")"
    assert_decision || { printf 'a reference refused as a secret: %s -> %s\n' "${sample}" "${hook_out}" >&2; return 1; }
  done
}

@test "secret-guard: the digit gate is what convicts, in either case" {
  # Paired with the two tests above: the same names WITH entropy still deny, so widening
  # the reference path cannot have widened these.
  local sample
  for sample in "apiKey = \"abc123def456ghi789jkl\"" \
    "client_secret: s3cr3tvalue0987654321" \
    "AWS_SECRET_ACCESS_KEY = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"; do
    run_hook secret-guard.sh "$(event_json write new_string "${sample}")"
    assert_decision deny || { printf 'an assignment with entropy was allowed: %s -> %s\n' "${sample}" "${hook_out}" >&2; return 1; }
  done
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

@test "secret-guard: sweeps every write-side field, a batched edits array included" {
  # A tool call that carries five edits puts its text in toolInput.edits[].new_string, and a
  # text-only write puts it in toolInput.text. A scan of the four flat fields alone passes
  # every other test in this section and lets both shapes through, which is the difference
  # between a guard and a speed bump.
  local ev
  for ev in \
    '{"toolName":"write","toolInput":{"edits":[{"old_string":"x","new_string":"apiKey = \"abc123def456ghi789jkl\""}]},"toolInputTruncated":false}' \
    '{"toolName":"write","toolInput":{"edits":[{"new_string":"x = 1"},{"new_string":"token: gh'"$(printf 'p')"'_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"}]},"toolInputTruncated":false}' \
    '{"toolName":"write","toolInput":{"text":"aws_access_key_id: AKI'"$(printf 'A')"'IOSFODNN7EXAMPLE"},"toolInputTruncated":false}'; do
    run_hook secret-guard.sh "${ev}"
    assert_decision deny || { printf 'a credential in a write-side field was allowed: %s -> %s\n' "${ev}" "${hook_out}" >&2; return 1; }
  done

  # An edits key that is not an array is a malformed event, and a malformed event is an
  # allow: this guard's error paths stay out of the way whatever shape arrives.
  run_hook secret-guard.sh '{"toolName":"write","toolInput":{"edits":{"new_string":"x = 1"}},"toolInputTruncated":false}'
  assert_decision || { printf 'a malformed edits key blocked a write: %s\n' "${hook_out}" >&2; return 1; }

  # And the sweep is of what the write PUTS INTO the file. old_string quotes text already on
  # disk; convicting it would deny every later edit beside a credential an older commit
  # wrote, which wedges the session that has to remove it rather than preventing a leak.
  run_hook secret-guard.sh "$(event_json search_replace old_string \
    "AWS_SECRET_ACCESS_KEY = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")"
  assert_decision || { printf 'the read-side field was swept, so every edit near an old secret is denied: %s\n' "${hook_out}" >&2; return 1; }
}

@test "secret-guard: an environment reference is the correct pattern in every spelling" {
  # This repo's own litellm config writes os.environ/NAME; a Node config reads
  # process.env.NAME and a Python one os.environ["NAME"] or getenv("NAME"). Each is the
  # indirection the rulebook tells an agent to use, and each reaches the assignment scan as
  # a long value on a credential name, so each has to be folded away before the scan runs.
  # The trailing comment carries a digit on purpose: it is what turns the digit gate off as
  # a defence and leaves the fold as the only thing standing between this line and a deny.
  local spelling
  for spelling in 'process.env.SPARK_API_KEY_V2' 'os.environ["DB_PASSWORD_1"]' \
    'os.getenv("CLIENT_SECRET_V1")' 'os.environ/DB_PASSWORD_1'; do
    run_hook secret-guard.sh "$(event_json write new_string \
      "aws_secret_access_key = ${spelling}  # pool sized for 5432 conns")"
    assert_decision || { printf 'a write that points at the environment was refused: %s -> %s\n' "${spelling}" "${hook_out}" >&2; return 1; }
  done
}

@test "secret-guard: the fold token stays shorter than the shortest value the scan asks for" {
  # The fold above only works while the token it substitutes is shorter than the eight
  # characters the upper-case list asks for. The first draft used ENVIRON_REF, eleven
  # characters, and a reference carrying any digit anywhere on the line was still denied --
  # so the length is part of the fix, and it is measured here rather than asserted: the
  # same event run against a copy with a longer token has to deny.
  local ev long_guard
  ev="$(event_json write new_string "aws_secret_access_key = os.environ/DB_PASSWORD_1  # pool sized for 5432 conns")"
  run_hook secret-guard.sh "${ev}"
  assert_decision || { printf 'the shipped guard refuses an environment reference: %s\n' "${hook_out}" >&2; return 1; }

  long_guard="${BATS_TEST_TMPDIR}/long-token-guard.sh"
  sed 's/ENVREF/ENVIRON_REF/g' "${BINDIR}/secret-guard.sh" >"${long_guard}"
  hook_out="$(printf '%s' "${ev}" | sh "${long_guard}" 2>/dev/null)" && hook_rc=0 || hook_rc=$?
  assert_decision deny || {
    printf 'lengthening the fold token changed nothing, so this test pins nothing\n' >&2
    return 1; }
}

@test "secret-guard: the fold reaches every call form that names the environment" {
  # Python reads a variable with os.environ.get("NAME") as well as os.environ["NAME"], Node
  # indexes process.env["NAME"], Rust calls std::env::var("NAME"). Each begins with a prefix
  # long enough to satisfy the value class on its own, so an unfolded one is denied as a
  # credential with the fold never having applied.
  local spelling
  for spelling in 'os.environ.get("DB_PASSWORD_1")' 'process.env["SPARK_API_KEY_1"]' \
    'std::env::var("SPARK_API_KEY_1")' 'ENV.get("DB_PASSWORD_1")'; do
    run_hook secret-guard.sh "$(event_json write new_string \
      "aws_secret_access_key = ${spelling}  # pool sized for 5432 conns")"
    assert_decision || { printf 'a call that names the environment was refused: %s -> %s\n' "${spelling}" "${hook_out}" >&2; return 1; }
  done
}

@test "secret-guard: a vendor key inside a reference call is still a vendor key" {
  # The fold excuses a reference, and a credential pasted into the position a reference
  # usually occupies is a leak wearing that shape. The exact-format scans therefore run on
  # the text before the fold, so the AKIA id below is seen even though getenv() ate it.
  local sample
  for sample in \
    "aws_access_key_id = getenv(\"AKI$(printf 'A')IOSFODNN7EXAMPLE\")" \
    "api_key: os.environ[\"gh$(printf 'p')_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij\"]"; do
    run_hook secret-guard.sh "$(event_json write new_string "${sample}")"
    assert_decision deny || { printf 'a literal credential hid behind a reference call: %s -> %s\n' "${sample}" "${hook_out}" >&2; return 1; }
  done
}

@test "secret-guard: an aligned assignment is as swept as a tight one" {
  # Aligned YAML and a columned settings block put more than a handful of spaces between the
  # separator and the value. A capped separator let exactly those through, which is the
  # shape a hand-written config file is most often in.
  local sample
  for sample in 'api_key:      abc123def456ghi789jkl' \
    'client_secret    =      s3cr3tvalue0987654321x' \
    'aws_secret_access_key:       wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'; do
    run_hook secret-guard.sh "$(event_json write new_string "${sample}")"
    assert_decision deny || { printf 'an aligned assignment was allowed: %s -> %s\n' "${sample}" "${hook_out}" >&2; return 1; }
  done
  # And widening the gap cannot turn prose into a credential: without a real separator the
  # keyword is just a word in a sentence.
  for sample in 'the token list for this lane is long and has no separator at all 42' \
    'password rotation is documented in the runbook, section 4'; do
    run_hook secret-guard.sh "$(event_json write new_string "${sample}")"
    assert_decision || { printf 'prose was read as an assignment: %s -> %s\n' "${sample}" "${hook_out}" >&2; return 1; }
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
    "kill-pgid-named:${KILL} -TERM -1234" \
    "kill-pgid-signum:${KILL} -9 -1234" \
    "rm-rf-dot:${RMR} ${RFOPT} ." \
    "rm-flags-split:${RMR} -f -r dist" \
    "rm-quoted-glob:${RMR} ${RFOPT} 'my dir'/*" \
    "rm-long-recursive:${RMR} --recursive build" \
    "rm-recursive-upper:${RMR} -R build" \
    "pkill-uid:${PKILL} -u coder" \
    "pkill-pid:${PKILL} -P 4321" \
    "pkill-long-user:${PKILL} --user root" \
    "pkill-full-cmdline:${PKILL} -f grok" \
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

@test "dangerous-command-guard: denies what the first list missed" {
  # Each of these was measured walking through the guard: discarding the working tree the
  # rulebook names as how a day of work is destroyed, zeroing a file the seed materializes
  # under the profile, and the docker forms that take out one of the grok volumes there is
  # no image to rebuild. They live in this file rather than in a shell command so the tool
  # that runs this suite never carries one in its own command text.
  local case_name cmd
  for case_name in \
    "find-dot-delete:find . -type f -delete" \
    "git-checkout-discard:git checkout -- ." \
    "git-restore-dot:git restore ." \
    "git-restore-flagged:git restore --source=HEAD ." \
    "git-stash-drop:git stash drop" \
    "git-stash-clear:git stash clear" \
    "truncate-profile:truncate -s 0 ~/.grok/config.toml" \
    "redirect-truncate: : > ~/.grok/config.toml" \
    "devnull-overwrite:cp /dev/null ~/.grok/AGENTS.md" \
    "rm-hooks-dir:rm -f ~/.grok/hooks/evo-t1-hooks.json" \
    "chmod-777-root:chmod -R 777 /" \
    "docker-volume-rm:docker volume rm grok-profile-me" \
    "docker-volume-rm-notes:docker volume rm grok-notes-me" \
    "docker-volume-rm-memory:docker volume rm grok-memory-me" \
    "docker-volume-rm-sessions:docker volume rm grok-sessions-me" \
    "docker-volume-prune:docker volume prune -f" \
    "docker-system-prune:docker system prune -a --volumes" \
    "compose-down-volumes:docker compose -p evo-t1 down -v" \
    "compose-down-long:docker compose down --remove-orphans --volumes" \
    "docker-rm-stack:docker rm -f coder-dev" \
    "find-dot-quoted:find \".\" -type f -delete" \
    "find-dot-single:find '.' -type f -delete" \
    "find-dot-relative:find ./tmp -type f -delete" \
    "checkout-dot-quoted:git checkout -- '.'" \
    "checkout-dot-ref:git checkout HEAD -- ." \
    "restore-dot-slash:git restore ./" \
    "stash-clear-terminated:git stash clear;"; do
    cmd="${case_name#*:}"
    run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${cmd}")"
    assert_decision deny || { printf 'not denied: %s (%s) -> %s\n' "${case_name}" "${cmd}" "${hook_out}" >&2; return 1; }
  done
}

@test "dangerous-command-guard: leaves the sibling of every new rule alone" {
  # The half that keeps the list above honest. Each new rule has a legitimate command one
  # character away from it -- a named scratch dir rather than a dot, one path rather than
  # the tree, a log rather than the profile, a workspace container rather than a stack one,
  # and the two `rm` calls the ez-learn dream flow documents for the logs it consumed --
  # and a rule that denies those is a rule an operator deletes.
  local cmd
  for cmd in "find /tmp/scratch -type f -delete" \
    "find . -name '*.orig' -print" \
    "git checkout -- scripts/x.sh" \
    "git checkout HEAD~1 -- scripts/x.sh" \
    "git restore 'scripts/x.sh'" \
    "git restore --source=HEAD~1 scripts/x.sh" \
    "find ./data -name '*.orig' -print" \
    "git stash push -m wip" \
    "git stash list" \
    "truncate -s 0 /tmp/evo-t1-hook-tests/run.log" \
    "cp /dev/null /tmp/scratch/empty" \
    "rm -f /tmp/scratch/one-file" \
    "rm -f ~/.grok/notes/git/host/owner/repo/notes.md" \
    "rm -f ~/.grok/memory/evo-t1-a1b2c3d4/session-2026-11-16.md" \
    "chmod 777 /tmp/scratch/x" \
    "chmod -R u+rwX ." \
    "docker ps -a" \
    "docker rm -f my-build-container" \
    "docker compose -p evo-t1 down" \
    "docker logs coder-dev" \
    "grep -rn 'docker volume rm' docs"; do
    run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${cmd}")"
    assert_decision || { printf 'a legitimate command blocked: %s -> %s\n' "${cmd}" "${hook_out}" >&2; return 1; }
  done
}

@test "dangerous-command-guard: reads the command as text, and says so in the reason" {
  # Matching the whole string is the choice, not an oversight: stripping quoted regions would
  # clear the two prose probes below and would equally blind the guard to sh -c "..." and
  # bash -c "...", the way a real command usually travels. So a command that QUOTES a denied
  # form followed by a space reads as that form -- the same edge the stack's own
  # Bash(rm -rf *) permission deny has. Pinned both ways so either half changing is a
  # decision someone made rather than a surprise.
  local cmd
  for cmd in "awk '/dd if=/' notes.txt" "echo 'rm -rf is denied here'"; do
    run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${cmd}")"
    assert_decision deny || { printf 'expected the accepted text-match edge to deny: %s\n' "${cmd}" >&2; return 1; }
    printf '%s' "${hook_out}" | grep -q 'line [0-9]' || {
      printf 'an accepted false positive still has to point at the rule: %s\n' "${hook_out}" >&2; return 1; }
  done
  # The same tokens with nothing after the flag read as prose and pass, which is what makes
  # the remedy a rewrite of the sentence and not a fight with the guard.
  for cmd in "grep -rn 'rm -rf' scripts" "echo 'the rm deny rules'"; do
    run_hook dangerous-command-guard.sh "$(event_json run_terminal_command command "${cmd}")"
    assert_decision || { printf 'prose blocked where it should read as text: %s -> %s\n' "${cmd}" "${hook_out}" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# The two PostToolUse hooks must never obstruct the edit they follow. Both bail on
# their first environment check, so every test here sets CLAUDE_PROJECT_DIR and points
# TMPDIR at scratch: an assertion made without those passes against a hook that never
# got past line one, which is how both of these tests stayed green over a no-op.
# ---------------------------------------------------------------------------

# One project tree, and one mis-indented shell file whose bytes a formatter has every
# reason to change -- so "untouched" and "reformatted" are both observable.
make_project() {
  project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "${project}/scripts/lib" "${project}/tests/bats"
  CLAUDE_PROJECT_DIR="${project}"
  export CLAUDE_PROJECT_DIR
  TMPDIR="${BATS_TEST_TMPDIR}"
  export TMPDIR
}

dirty_shell() {
  printf '#!/bin/sh\nif true; then\n        echo    "hi"\nfi\n'
}

plant_dirty() {
  mkdir -p "$(dirname "$1")"
  dirty_shell >"$1"
}

# The runner's own bazelisk. It records each invocation, so "a test was started" is a
# line this suite reads off a file rather than an adjective in a report: `run` answers
# the tests-for lookup with one label and `test` is the backgrounded run.
stub_bazelisk() {
  local dir="${BATS_TEST_TMPDIR}/stubbin"
  mkdir -p "${dir}"
  cat >"${dir}/bazelisk" <<'STUB_EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${EVO_T1_STUB_LOG}"
if [ "$1" = "run" ]; then
  printf '//tests:bats_demo_test\n'
else
  printf 'stub-bazelisk ran: %s\n' "$*"
fi
exit 0
STUB_EOF
  chmod 755 "${dir}/bazelisk"
  printf '%s' "${dir}"
}

# The hook detaches its bazelisk, so the record lands after the hook returns. Bounded,
# and it prints what did arrive when the wait runs out.
wait_for_line() {
  local path="$1" needle="$2" i=0
  while [ "${i}" -lt 50 ]; do
    [ -f "${path}" ] && grep -qF -- "${needle}" "${path}" && return 0
    i=$((i + 1))
    sleep 0.1
  done
  printf 'timed out waiting for "%s" in %s\n' "${needle}" "${path}" >&2
  [ -f "${path}" ] && sed -n '1,10p' "${path}" >&2
  return 1
}

@test "post-edit-format: reformats a file the project owns and says so on stdout" {
  # The positive half, because a formatter that quietly became a no-op would have kept
  # every other test in this file green. shfmt ships in the golden image, so its
  # absence is a broken environment and not a reason to pass.
  command -v shfmt >/dev/null 2>&1 || {
    printf 'shfmt is not on PATH, so this test cannot see a format happen\n' >&2
    return 1; }
  make_project
  local path before after
  path="${project}/scripts/lib/demo.sh"
  dirty_shell >"${path}"
  before="$(cat "${path}")"
  run_hook post-edit-format.sh "$(event_json write file_path "${path}")"
  assert_quiet || { printf 'the formatter obstructed the edit it just made: %s\n' "${hook_out}" >&2; return 1; }
  after="$(cat "${path}")"
  [ "${before}" != "${after}" ] || { printf 'a mis-indented shell file came back unchanged\n' >&2; return 1; }
  printf '%s\n' "${after}" | grep -q '^  echo "hi"$' || {
    printf 'it changed bytes but not into the gate shape: %s\n' "${after}" >&2
    return 1; }
  # Verified with the gate's own flags, read out of both places rather than repeated
  # here: the hook's whole claim is that it formats the way the lint gate formats, so a
  # flag list that drifted from lints/run_shfmt.sh is exactly the drift to catch. Bare
  # "shfmt -d" would ask for tabs and call a correct file wrong.
  local gate_flags hook_flags
  gate_flags="$(sed -nE 's/^shfmt -d (.*[^ ]) .*/\1/p' "${REPO_ROOT}/lints/run_shfmt.sh" | head -1)"
  hook_flags="$(sed -nE 's/.*shfmt -w (.*) -- .*/\1/p' "${BINDIR}/post-edit-format.sh" | head -1)"
  [ -n "${gate_flags}" ] && [ -n "${hook_flags}" ] || {
    printf 'neither the gate nor the hook names its shfmt flags any more\n' >&2
    return 1; }
  assert_eq "the hook formats with the gate's flags" "${gate_flags}" "${hook_flags}"
  local -a shfmt_flags
  read -r -a shfmt_flags <<<"${gate_flags}"
  run env shfmt -d "${shfmt_flags[@]}" -- "${path}"
  [ "${status}" -eq 0 ] || { printf 'the file is still not clean under the gate flags: %s\n' "${output}" >&2; return 1; }
  printf '%s' "${hook_out}" | grep -q 'additionalContext' || {
    printf 'bytes changed without telling the model to re-read: %s\n' "${hook_out}" >&2
    return 1; }
}

@test "post-edit-format: leaves every refused path byte-for-byte alone" {
  # Each of these is a file a formatter would happily rewrite, planted inside the
  # project so the containment test is what refuses it rather than the path simply
  # being unresolvable, and compared by bytes rather than by exit status.
  make_project
  local path before after
  for path in "${project}/.git/hooks/pre-commit.sh" "${project}/.grok/hooks/bin/x.sh" \
    "${project}/.agents/skills/x/STYLE.sh" "${project}/.coder/skills/x/STYLE.sh" \
    "${project}/bazel-out/stale.sh" "${project}/node_modules/pack/index.py" \
    "${project}/.env.local.sh" "${BATS_TEST_TMPDIR}/outside/keep.sh"; do
    plant_dirty "${path}"
    before="$(cat "${path}")"
    run_hook post-edit-format.sh "$(event_json write file_path "${path}")"
    assert_quiet || { printf 'a formatter must not obstruct an edit: %s -> %s\n' "${path}" "${hook_out}" >&2; return 1; }
    after="$(cat "${path}")"
    [ "${before}" = "${after}" ] || { printf 'the formatter rewrote a path it refuses: %s\n' "${path}" >&2; return 1; }
  done
}

@test "post-edit-format: a link further up the path cannot carry it out of the project" {
  # The containment test is a string compare, so `linkdir/keep.sh` reads as inside the project
  # while the formatter follows the link and rewrites a file the project does not own. The
  # hook resolves what it would really open and tests that too; addressed directly the same
  # file is refused, and both halves have to leave the bytes alone.
  make_project
  local outside target before after
  outside="${BATS_TEST_TMPDIR}/outside"
  mkdir -p "${outside}"
  plant_dirty "${outside}/keep.sh"
  ln -s "${outside}" "${project}/linkdir"
  for target in "${project}/linkdir/keep.sh" "${outside}/keep.sh"; do
    before="$(cat "${outside}/keep.sh")"
    run_hook post-edit-format.sh "$(event_json write file_path "${target}")"
    assert_quiet || { printf 'the formatter obstructed the edit: %s\n' "${hook_out}" >&2; return 1; }
    after="$(cat "${outside}/keep.sh")"
    [ "${before}" = "${after}" ] || {
      printf 'the formatter wrote through a link out of the project: %s\n' "${target}" >&2
      return 1; }
  done
}

@test "selective-test-runner: stays off until the operator opts in" {
  # The stub is on PATH and the project is set, so the only thing between this edit and
  # a test run is the flag. Off by default is the hook's whole cost model, and the
  # stub's empty record is what proves it, not the absence of a directory.
  make_project
  local stub; stub="$(stub_bazelisk)"
  EVO_T1_STUB_LOG="${BATS_TEST_TMPDIR}/stub-off.log"
  export EVO_T1_STUB_LOG
  PATH="${stub}:${PATH}"
  export PATH
  unset EVO_T1_HOOK_TESTS
  local path="${project}/scripts/lib/config_seed.sh"
  plant_dirty "${path}"
  run_hook selective-test-runner.sh "$(event_json write file_path "${path}")"
  assert_quiet
  [ -z "${hook_out}" ] || { printf 'the opt-in hook spoke without being asked: %s\n' "${hook_out}" >&2; return 1; }
  [ ! -s "${EVO_T1_STUB_LOG}" ] || {
    printf 'bazelisk was called with the opt-in unset: %s\n' "$(cat "${EVO_T1_STUB_LOG}")" >&2
    return 1; }
  [ ! -d "${TMPDIR}/evo-t1-hook-tests" ] || {
    printf 'the runner wrote a log dir with the opt-in unset: %s\n' "${TMPDIR}/evo-t1-hook-tests" >&2
    return 1; }
}

@test "selective-test-runner: starts the target bazel-map derives for the edited file" {
  make_project
  local stub; stub="$(stub_bazelisk)"
  EVO_T1_STUB_LOG="${BATS_TEST_TMPDIR}/stub-on.log"
  export EVO_T1_STUB_LOG
  PATH="${stub}:${PATH}"
  export PATH
  EVO_T1_HOOK_TESTS=1
  export EVO_T1_HOOK_TESTS
  local path="${project}/scripts/lib/demo.sh" log
  plant_dirty "${path}"
  run_hook selective-test-runner.sh "$(event_json write file_path "${path}")"
  assert_quiet || { printf 'the runner obstructed the edit: %s\n' "${hook_out}" >&2; return 1; }
  wait_for_line "${EVO_T1_STUB_LOG}" "run //scripts:bazel-map -- tests-for scripts/lib/demo.sh" || return 1
  wait_for_line "${EVO_T1_STUB_LOG}" "test //tests:bats_demo_test --test_output=errors" || return 1
  log="${TMPDIR}/evo-t1-hook-tests/__tests_bats_demo_test.log"
  wait_for_line "${log}" "stub-bazelisk ran: test" || return 1
  printf '%s' "${hook_out}" | grep -qF -- "${log}" || {
    printf 'the model was never handed the log path: %s\n' "${hook_out}" >&2
    return 1; }
  # The edit itself is the formatter's business, not this hook's: it formats nothing.
  grep -qF -- '        echo    "hi"' "${path}" || {
    printf 'the runner formatted a file it was only asked to test for\n' >&2
    return 1; }
}

@test "selective-test-runner: derives the label from the suite naming for a .bats edit" {
  # The one branch that needs no bazelisk to answer, which is also the one an agent
  # edits most: the naming rule (dashes to underscores, //tests:bats_<stem>_test) is
  # pinned here so a drift sends the run to a label that does not exist.
  make_project
  local stub; stub="$(stub_bazelisk)"
  EVO_T1_STUB_LOG="${BATS_TEST_TMPDIR}/stub-bats.log"
  export EVO_T1_STUB_LOG
  PATH="${stub}:${PATH}"
  export PATH
  EVO_T1_HOOK_TESTS=1
  export EVO_T1_HOOK_TESTS
  local path="${project}/tests/bats/my-demo.bats"
  printf '#!/usr/bin/env bats\n' >"${path}"
  run_hook selective-test-runner.sh "$(event_json write file_path "${path}")"
  assert_quiet
  wait_for_line "${EVO_T1_STUB_LOG}" "test //tests:bats_my_demo_test --test_output=errors" || return 1
  grep -qF -- 'bazel-map' "${EVO_T1_STUB_LOG}" && {
    printf 'a .bats edit asked bazel-map for a label the naming rule already answers\n' >&2
    return 1; }
  return 0
}

@test "selective-test-runner: ignores paths outside the project and under a refusal" {
  # With the opt-in set and the stub on PATH, a call reaching bazelisk is the failure.
  make_project
  local stub; stub="$(stub_bazelisk)"
  EVO_T1_STUB_LOG="${BATS_TEST_TMPDIR}/stub-outside.log"
  export EVO_T1_STUB_LOG
  PATH="${stub}:${PATH}"
  export PATH
  EVO_T1_HOOK_TESTS=1
  export EVO_T1_HOOK_TESTS
  local path
  for path in "${project}/.git/hooks/commit-msg.sh" "${project}/.grok/config.sh" \
    "${project}/.agents/skills/x/SKILL.sh" "${project}/bazel-out/gen.sh" \
    "${project}/.env.sh" "${BATS_TEST_TMPDIR}/outside/keep.sh"; do
    plant_dirty "${path}"
    run_hook selective-test-runner.sh "$(event_json write file_path "${path}")"
    assert_quiet || { printf 'the runner obstructed an edit under %s: %s\n' "${path}" "${hook_out}" >&2; return 1; }
  done
  [ ! -s "${EVO_T1_STUB_LOG}" ] || {
    printf 'bazelisk was called for a refused path: %s\n' "$(cat "${EVO_T1_STUB_LOG}")" >&2
    return 1; }
}

@test "the guards treat this clone's bazel-map files as ordinary sources" {
  # The artifact refusals name the three directories Bazel links into the workspace. A
  # `bazel-` prefix match also reads scripts/bazel-map.sh and tests/bats/bazel-map.bats as
  # generated output: the formatter skips the first and the test lookup never runs for the
  # second, and both look exactly like a session that needed nothing. Named one by one in
  # the seed, and this is the test that keeps them named.
  command -v shfmt >/dev/null 2>&1 || {
    printf 'shfmt is not on PATH, so the formatter half of this test cannot see a format happen\n' >&2
    return 1; }
  make_project
  local stub; stub="$(stub_bazelisk)"
  EVO_T1_STUB_LOG="${BATS_TEST_TMPDIR}/stub-bazelmap.log"
  export EVO_T1_STUB_LOG
  PATH="${stub}:${PATH}"
  export PATH
  EVO_T1_HOOK_TESTS=1
  export EVO_T1_HOOK_TESTS

  local path before after
  path="${project}/scripts/bazel-map.sh"
  plant_dirty "${path}"
  before="$(cat "${path}")"
  run_hook post-edit-format.sh "$(event_json write file_path "${path}")"
  assert_quiet || { printf 'the formatter obstructed the edit: %s\n' "${hook_out}" >&2; return 1; }
  after="$(cat "${path}")"
  [ "${before}" != "${after}" ] || {
    printf 'post-edit-format skipped %s, which a bazel- prefix match reads as build output\n' "${path}" >&2
    return 1; }

  path="${project}/tests/bats/bazel-map.bats"
  printf '#!/usr/bin/env bats\n' >"${path}"
  run_hook selective-test-runner.sh "$(event_json write file_path "${path}")"
  assert_quiet || { printf 'the runner obstructed the edit: %s\n' "${hook_out}" >&2; return 1; }
  wait_for_line "${EVO_T1_STUB_LOG}" "test //tests:bats_bazel_map_test --test_output=errors" || {
    printf 'selective-test-runner refused to look up a test for %s\n' "${path}" >&2
    return 1; }
}

@test "registration: the seed body installs the family, keeps a marker-free copy alone, and refuses a linked directory loudly" {
  # Everything the registration greps above claim, run for real: terraform renders
  # $${var} to ${var} and ${key} to the payload, so the same substitution here lets the
  # body itself be the thing under test. Three things can go wrong quietly -- the mode,
  # the marker contract, and a silent bail-out -- and each gets one assertion.
  local home rendered script mode
  home="${BATS_TEST_TMPDIR}/seedhome"
  rendered="${BATS_TEST_TMPDIR}/hooks-seed.sh"
  mkdir -p "${home}"
  render_hooks_seed "${rendered}"

  run env HOME="${home}" sh "${rendered}"
  [ "${status}" -eq 0 ] || { printf 'the seed exited %s: %s\n' "${status}" "${output}" >&2; return 1; }
  assert_file_exists "the manifest" "${home}/.grok/hooks/evo-t1-hooks.json"
  assert_file_exists "the deny list" "${home}/.grok/hooks/bin/deny-patterns.txt"
  for script in secret-guard dangerous-command-guard post-edit-format selective-test-runner; do
    assert_file_exists "bin/${script}.sh" "${home}/.grok/hooks/bin/${script}.sh"
    mode="$(stat -c '%a' "${home}/.grok/hooks/bin/${script}.sh")"
    [ "${mode}" = "755" ] || { printf 'bin/%s.sh seeded mode %s; the runner execs it directly\n' "${script}" "${mode}" >&2; return 1; }
    grep -q 'managed-by: evo-t1-coder-stack' "${home}/.grok/hooks/bin/${script}.sh" || {
      printf 'bin/%s.sh carries no marker, so the next boot leaves it stale forever\n' "${script}" >&2
      return 1; }
  done
  grep -q '"__evoT1Stack": true' "${home}/.grok/hooks/evo-t1-hooks.json" || {
    printf 'the manifest marker is missing, which makes the next boot refuse to touch it\n' >&2
    return 1; }

  # A person deleted the marker: that copy is theirs now, drift and all.
  printf '%s\n' '#!/bin/sh' >"${home}/.grok/hooks/bin/post-edit-format.sh"
  run env HOME="${home}" sh "${rendered}"
  [ "${status}" -eq 0 ] || { printf 'the reseed exited %s\n' "${status}" >&2; return 1; }
  [ "$(wc -l <"${home}/.grok/hooks/bin/post-edit-format.sh")" -eq 1 ] || {
    printf 'the seed rewrote a copy whose marker was deleted\n' >&2
    return 1; }
  grep -q 'managed-by: evo-t1-coder-stack' "${home}/.grok/hooks/bin/secret-guard.sh" || {
    printf 'the reseed stopped refreshing the copies that kept their marker\n' >&2
    return 1; }

  # A symlinked hooks dir means zero guards. It has to say so.
  local linkhome="${BATS_TEST_TMPDIR}/linkhome" elsewhere="${BATS_TEST_TMPDIR}/elsewhere"
  mkdir -p "${linkhome}/.grok" "${elsewhere}"
  ln -s "${elsewhere}" "${linkhome}/.grok/hooks"
  run env HOME="${linkhome}" sh "${rendered}"
  [ "${status}" -eq 0 ] || { printf 'a refused install must not fail the boot: %s\n' "${status}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -q 'warning:' || {
    printf 'the whole family was declined without a word: %s\n' "${output}" >&2
    return 1; }
  printf '%s\n' "${output}" | grep -q 'hooks is a symlink' || {
    printf 'the warning did not name what it refused: %s\n' "${output}" >&2
    return 1; }
  [ ! -e "${elsewhere}/evo-t1-hooks.json" ] || {
    printf 'the bail-out wrote through the link anyway\n' >&2
    return 1; }
}

# render_hooks_seed <out> -- the seed body the way terraform would render it: the $$
# escapes collapse to shell vars and every map key becomes its payload.
render_hooks_seed() {
  local out="${1}" key
  sed -e 's/\$\${/${/g' "${COMMON}/stack-hooks.sh.tftpl" >"${out}"
  # The manifest carries its marker as a JSON key of its own, so the render hands it a
  # minimal document that does; the shell payloads get theirs from the body.
  sed -i "s|^\${evo_t1_hooks_json}$|{\"__evoT1Stack\": true}|" "${out}"
  for key in secret_guard_sh dangerous_command_guard_sh \
    post_edit_format_sh selective_test_runner_sh deny_patterns_txt; do
    sed -i "s|^\${${key}}$|RENDERED ${key}|" "${out}"
  done
}

# ---------------------------------------------------------------------------
# Registration.
# ---------------------------------------------------------------------------

@test "registration: seed_ensure_mode asserts the mode an exec payload needs and none other" {
  # The unit under the integration test below: the runner starts a relative command out
  # of the manifest, so the executable bit is part of the payload, while a data file
  # that never gets exec'd must not acquire it.
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/config_seed.sh"
  local dir="${BATS_TEST_TMPDIR}/modes" script data missing
  mkdir -p "${dir}"
  script="${dir}/secret-guard.sh"
  data="${dir}/deny-patterns.txt"
  missing="${dir}/gone.sh"
  printf '#!/bin/sh\n' >"${script}"
  printf '# comment\n' >"${data}"

  chmod 644 "${script}"
  run seed_ensure_mode exec "${script}" "" "secret-guard.sh"
  [ "${status}" -eq 0 ] || { printf 'a chmod that works returned %s: %s\n' "${status}" "${output}" >&2; return 1; }
  [ "$(stat -c '%a' "${script}")" = "755" ] || {
    printf 'seed_ensure_mode left an exec: payload at mode %s\n' "$(stat -c '%a' "${script}")" >&2
    return 1; }
  # A mode it already has is not a report: refresh-configs counts one decision line per
  # payload off the seeder's stdout, so a second line per hook is a second entry.
  run seed_ensure_mode exec "${script}" "" "secret-guard.sh"
  [ "${status}" -eq 0 ] && [ -z "${output}" ] || {
    printf 'a hook already at 755 printed %s\n' "${output}" >&2
    return 1; }

  chmod 644 "${data}"
  run seed_ensure_mode file "${data}" "" "deny-patterns.txt"
  [ "${status}" -eq 0 ] || { printf 'a data payload should need nothing, got %s\n' "${status}" >&2; return 1; }
  [ "$(stat -c '%a' "${data}")" = "644" ] || {
    printf 'seed_ensure_mode made a file: payload executable\n' >&2
    return 1; }

  run seed_ensure_mode exec "${missing}" "" "gone.sh"
  [ "${status}" -eq 0 ] || { printf 'a payload that is not there yet is the write'"'"'s business, not this one'"'"'\n' >&2; return 1; }
}

@test "registration: reseeding restores a hook's executable bit even when its bytes already match" {
  # The byte compare is what makes a reseed cheap, and it is also what lets a guard stop
  # running: a hook copied by hand or checked out by a tool that dropped the mode still
  # "already matches this checkout", and the runner starts a relative command out of the
  # manifest directly, so it never runs again. The seeder has to re-assert the mode on
  # that path, and a data payload must not gain an executable bit it never needed.
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/config_seed.sh"
  local home stage hook data mode
  home="${BATS_TEST_TMPDIR}/seed-home"
  stage="${BATS_TEST_TMPDIR}/seed-stage"
  mkdir -p "${home}" "${stage}"

  run --separate-stderr seed_container_seed "" "${home}" "${REPO_ROOT}" "${stage}" 0 0
  [ "${status}" -eq 0 ] || { printf 'the first seed failed: %s\n' "${output}" >&2; return 1; }

  hook="${home}/.grok/hooks/bin/secret-guard.sh"
  data="${home}/.grok/hooks/bin/deny-patterns.txt"
  assert_file_exists "the hook landed" "${hook}"
  assert_file_exists "the deny list landed" "${data}"
  mode="$(stat -c '%a' "${hook}")"
  [ "${mode}" = "755" ] || { printf 'a fresh hook seeded mode %s; the runner execs it directly\n' "${mode}" >&2; return 1; }
  mode="$(stat -c '%a' "${data}")"
  [ "${mode}" != "755" ] || { printf 'the deny list, which nothing execs, seeded executable\n' >&2; return 1; }

  # The mutation: same bytes, mode dropped, reseed. This is the path that prints
  # "already matches this checkout".
  chmod 644 "${hook}"
  run --separate-stderr seed_container_seed "" "${home}" "${REPO_ROOT}" "${stage}" 0 0
  [ "${status}" -eq 0 ] || { printf 'the reseed failed: %s\n' "${output}" >&2; return 1; }
  printf '%s\n' "${output}" | grep -qF 'secret-guard.sh: already matches this checkout' || {
    printf 'the reseed did not take the cheap path, so it proved nothing about the mode: %s\n' "${output}" >&2
    return 1; }
  mode="$(stat -c '%a' "${hook}")"
  [ "${mode}" = "755" ] || {
    printf 'a hook left at mode %s by a reseed that saw its bytes match never runs again\n' "${mode}" >&2
    return 1; }
}

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
