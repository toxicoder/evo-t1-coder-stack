#!/usr/bin/env bats
#
# ## probes.bats - unit coverage for the sh payloads under scripts/lib/probes/
#
# These are the probe bodies that used to travel inside quoted heredocs and in
# inline `sh -c` strings. They run under `sh` on a remote host or through
# `docker exec sh -c`, so every case here runs them with sh and never sources
# them: a payload that only works when the caller's bash env is already set up
# would pass here and fail on the far end.
#
# The github-auth pair is the credential doctor's far end. probes/github-auth.sh
# asks git's own credential helper the way git runs it, judges the credential
# git would ACTUALLY send (not the ones the environment merely holds), and
# answers one machine-checkable `push would ...` line with a matching exit code;
# probes/github-auth-fix.sh is the repair: mint through Coder, write the gh auth
# store, and point git's helper at that store through a form that clears the
# injected GH_TOKEN/GITHUB_TOKEN first, because the stack's plain
# `!gh auth git-credential` helper echoes that pair and the pair Coder injects
# at workspace start expires an hour later. The cases below pin the helper and
# GIT_ASKPASS reads, the verdict table, the slot folding, and the exit codes,
# against a curl that records the credential it was handed on stdin, because
# argv proves nothing about a token the probe deliberately keeps out of argv.
#
# Hermetic: docker resolves through tests/bats/tool_stubs, every credential
# probe gets the curl stub (never the network), and HOME plus GIT_CONFIG_GLOBAL
# point at per-test scratch so no case reads the developer's own git config.
# Usage: bazelisk test //tests:bats_probes_test   (from any cwd)
# Safety: no daemon, no network, no ssh, no Spark box.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
PROBES_DIR=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PROBES_DIR="${REPO_ROOT}/scripts/lib/probes"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker
  # The credential probe asks git which helper answers for github.com, so the
  # answer has to come from scratch (or from the git stub), never from the
  # developer's own config.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"
  export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  unset GIT_ASKPASS CODER_GITHUB_AUTH_ID EVO_T1_FIX_MODE EVO_T1_GITCONFIG
}

last_line() {
  printf '%s\n' "${output}" | tail -n 1
}

# assert_line <label> <text> <line> - <text> must hold <line> as one whole line.
# The probe reports are multi-line, so matching a verdict needs line equality,
# not a substring that any prose could satisfy.
assert_line() {
  if ! printf '%s\n' "$3" | grep -qxF -- "$2"; then
    printf 'FAIL: %s: no line equal to [%s], got [%s]\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

# count_report_lines <text> - how many per-credential report lines a probe
# printed. The machine-checkable `push would ...` line is not one of them.
count_report_lines() {
  printf '%s\n' "$1" | grep -c '^self: \(git would send\|credential present\)' || true
}

# make_bin <name> - read a script body on stdin, write it as an executable
# fixture under the per-test scratch bin, print its path. The fixtures here are
# the credential helpers and GIT_ASKPASS programs a probe asks questions of.
make_bin() {
  local path="${BATS_TEST_TMPDIR}/bin/$1"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${path}"
  chmod 755 "${path}"
  printf '%s' "${path}"
}

# make_curl_shim - a curl that keeps the credential it was given. The probe
# hands curl `user = "x-access-token:<token>"` on stdin through --config -, so
# this is the only way a case can name the token that would really go on the
# wire; it records every call's stdin, in order, into $CRED_LOG, and answers
# $STUB_CURL_STATUS with $STUB_CURL_BODY as the saved body, or nothing at all
# (curl -f's exit 22) when no status is canned, which is how an offline github.com
# reads to the probe.
make_curl_shim() {
  make_bin curl <<'CURL'
#!/bin/sh
out=""
prev=""
for a in "$@"; do
  [ "${prev}" = "-o" ] && out="${a}"
  prev="${a}"
done
if [ ! -t 0 ] && [ -n "${CRED_LOG:-}" ]; then
  {
    printf '== call ==\n'
    cat
  } >>"${CRED_LOG}"
fi
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "curl $*" >>"${STUB_LOG}/curl.log"
[ -n "${out}" ] && printf '%s' "${STUB_CURL_BODY:-}" >"${out}"
# No canned status means github.com never answered: curl -f's HTTP-fail code
# and no write-out, which is the answer a probe must read as "not measured".
if [ -z "${STUB_CURL_STATUS:-}" ]; then
  exit 22
fi
printf '%s\n' "${STUB_CURL_STATUS}"
exit 0
CURL
}

# probe_credential - run the read probe the way its caller runs it: sh with the
# label, the repo, the name the fix pointers carry, and the slot selector, then
# the per-case env assignments first.
probe_credential() {
  local sel="$1"
  shift
  run env "$@" sh "${PROBES_DIR}/github-auth.sh" self alx/notes self "${sel}"
}

# -- probes/github-auth.sh and probes/github-auth-fix.sh -----------------------------

@test "probes/github-auth: credential probe names its slots and its push verdict" {
  grep -Eq '^slot_name\(\) \{' "${PROBES_DIR}/github-auth.sh"
  grep -q 'PUSH-READY' "${PROBES_DIR}/github-auth.sh"
}

@test "probes/github-auth: helper_credential asks git's helper the git question and probes the token it returns" {
  # git walks its helpers and sends the first answer, and the stack's helper is
  # `!gh auth git-credential`, which echoes GH_TOKEN/GITHUB_TOKEN. Reading the
  # environment instead would miss a helper that answers with a token no slot
  # holds, so the token the helper prints has to be the one probed, and the
  # lookup has to be the one git sends it.
  use_stubs curl gh coder timeout git
  local helper
  helper="$(make_bin helper-answer <<'HELPER'
#!/bin/sh
cat >>"${HELPER_LOG:-/dev/null}"
printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' "${HELPER_TOKEN}"
HELPER
)"
  make_curl_shim >/dev/null
  export CRED_LOG="${BATS_TEST_TMPDIR}/credentials.txt"
  export HELPER_LOG="${BATS_TEST_TMPDIR}/helper-stdin.txt"
  probe_credential chain STUB_GIT_HELPER='!'"${helper}" HELPER_TOKEN=HELPERTOK123 \
    GH_TOKEN=ghu_ENVPAIR STUB_CURL_STATUS=200 STUB_CURL_BODY='001f# service=git-receive-pack 0000'
  [ "${status}" -eq 0 ]
  assert_line "the helper is the credential git would send" "${output}" \
    "self: git would send this credential (source: git credential helper) and alx/notes answered PUSH-READY (the receive-pack advertisement came back through this credential, so a push would negotiate)"
  # The lookup git puts on stdin for a `get`, and the helper sees exactly it.
  assert_eq "the helper got git's own lookup" \
    "$(printf 'protocol=https\nhost=github.com')" "$(sed -e '/^$/d' "${HELPER_LOG}")"
  # The helper's token, not the environment's, is what would go on the wire, and
  # it goes first: that is the credential a push really sends.
  assert_eq "the helper token was the first credential sent" \
    'user = "x-access-token:HELPERTOK123"' "$(sed -n '2p' "${CRED_LOG}")"
  assert_eq "and the env pair was probed only as the shadowed slot, second" \
    'user = "x-access-token:ghu_ENVPAIR"' "$(sed -n '4p' "${CRED_LOG}")"
  assert_eq "two credentials answered, no more" "2" "$(count_report_lines "${output}")"
}

@test "probes/github-auth: helper_credential takes the plain-program helper form too" {
  # A helper value without the leading ! is a program, and git runs it as one.
  use_stubs curl gh coder timeout git
  local helper
  helper="$(make_bin helper-answer <<'HELPER'
#!/bin/sh
cat >/dev/null
printf 'password=%s\n' "${HELPER_TOKEN}"
HELPER
)"
  make_curl_shim >/dev/null
  export CRED_LOG="${BATS_TEST_TMPDIR}/credentials.txt"
  probe_credential chain STUB_GIT_HELPER="${helper}" HELPER_TOKEN=PLAINTOK9 \
    STUB_CURL_STATUS=200 STUB_CURL_BODY='001f# service=git-receive-pack 0000'
  [ "${status}" -eq 0 ]
  assert_line "the plain helper is what git would send" "${output}" \
    "self: git would send this credential (source: git credential helper) and alx/notes answered PUSH-READY (the receive-pack advertisement came back through this credential, so a push would negotiate)"
  assert_eq "the plain helper's token is what git would send" \
    'user = "x-access-token:PLAINTOK9"' "$(sed -n '2p' "${CRED_LOG}")"
}

@test "probes/github-auth: a helper that answers nothing falls through to the next slot" {
  # An absent answer is a finding, not a failure: git falls through to
  # GIT_ASKPASS and then to prompting, so the env pair is what a push sends.
  use_stubs curl gh coder timeout git
  local helper
  helper="$(make_bin helper-silent <<'HELPER'
#!/bin/sh
cat >/dev/null
exit 0
HELPER
)"
  make_curl_shim >/dev/null
  export CRED_LOG="${BATS_TEST_TMPDIR}/credentials.txt"
  probe_credential chain STUB_GIT_HELPER='!'"${helper}" GH_TOKEN=ghu_ENVPAIR \
    STUB_CURL_STATUS=401 STUB_CURL_BODY='Bad credentials'
  [ "${status}" -eq 3 ]
  assert_line "the next slot took over" "${output}" \
    "self: git would send this credential (source: env token (GITHUB_TOKEN/GH_TOKEN)) but REJECTED (github.com refused the credential itself, as it refuses an expired or revoked token): re-mint it with coder external-auth access-token github from a workspace shell, or click GitHub reauth on the workspace in the Coder UI"
  assert_eq "the silent helper was still asked" "1" "$(printf '%s\n' "$(stub_log git)" | grep -c 'config --get-all')"
  assert_eq "and the env pair is what would have gone on the wire" \
    'user = "x-access-token:ghu_ENVPAIR"' "$(sed -n '2p' "${CRED_LOG}")"
}

@test "probes/github-auth: askpass_credential reports a GIT_ASKPASS that exits non-zero as dead, and says so" {
  # The staged coder binary answers some builds with `unrecognized subcommand`,
  # which is why a dead token surfaces as "Password authentication is not
  # supported for Git operations." rather than as an expired token.
  use_stubs curl gh coder timeout git
  local askpass
  askpass="$(make_bin askpass-fail <<'ASK'
#!/bin/sh
printf 'unrecognized subcommand\n'
exit 1
ASK
)"
  probe_credential chain GIT_ASKPASS="${askpass}" GH_TOKEN=ghu_ENVPAIR \
    STUB_CURL_STATUS=401 STUB_CURL_BODY='Bad credentials'
  [ "${status}" -eq 3 ]
  assert_line "the dead helper is named as the reason the error misleads" "${output}" \
    'self: note: GIT_ASKPASS is set but answers no credential, which is what turns a refused token into "Password authentication is not supported for Git operations."; a working credential helper makes it moot'
  assert_line "and the push line names the repair" "${output}" \
    "self: push would FAIL now (the credential git consults answered REJECTED; run bazelisk run //scripts:github-auth -- fix self)"
  [[ "${output}" != *"GIT_ASKPASS helper"* ]]
}

@test "probes/github-auth: askpass_credential reports an askpass that prints nothing as dead too" {
  use_stubs curl gh coder timeout git
  local askpass
  askpass="$(make_bin askpass-empty <<'ASK'
#!/bin/sh
exit 0
ASK
)"
  probe_credential chain GIT_ASKPASS="${askpass}" GH_TOKEN=ghu_ENVPAIR \
    STUB_CURL_STATUS=401 STUB_CURL_BODY='Bad credentials'
  [ "${status}" -eq 3 ]
  assert_line "an empty answer is as dead as a failing one" "${output}" \
    'self: note: GIT_ASKPASS is set but answers no credential, which is what turns a refused token into "Password authentication is not supported for Git operations."; a working credential helper makes it moot'
}

@test "probes/github-auth: askpass_credential alive makes that answer the credential git would send" {
  use_stubs curl gh coder timeout git
  local askpass
  askpass="$(make_bin askpass-answer <<'ASK'
#!/bin/sh
printf '%s\n' "${ASK_TOKEN}"
ASK
)"
  make_curl_shim >/dev/null
  export CRED_LOG="${BATS_TEST_TMPDIR}/credentials.txt"
  probe_credential chain GIT_ASKPASS="${askpass}" ASK_TOKEN=ASKPASSTOK7 GH_TOKEN=ghu_ENVPAIR \
    STUB_CURL_STATUS=200 STUB_CURL_BODY='001f# service=git-receive-pack 0000'
  [ "${status}" -eq 0 ]
  assert_line "git would send the askpass answer, not the env pair" "${output}" \
    "self: git would send this credential (source: GIT_ASKPASS helper) and alx/notes answered PUSH-READY (the receive-pack advertisement came back through this credential, so a push would negotiate)"
  [[ "${output}" != *"note: GIT_ASKPASS"* ]]
  assert_eq "git would really send what the askpass answered" \
    'user = "x-access-token:ASKPASSTOK7"' "$(sed -n '2p' "${CRED_LOG}")"
}

@test "probes/github-auth: push_verdict prints push would FAIL naming fix, and the probe exits 3" {
  # The exit code is the contract probe_self and probe_workspace gate on: 3 is
  # "the credential git consults cannot write", which check turns into a counted
  # failure and a non-zero exit.
  use_stubs curl gh coder timeout git
  make_curl_shim >/dev/null
  probe_credential chain GH_TOKEN=ghu_EXPIRED STUB_CURL_STATUS=401 STUB_CURL_BODY='Bad credentials'
  [ "${status}" -eq 3 ]
  assert_line "the machine-checkable line names the repair" "${output}" \
    "self: push would FAIL now (the credential git consults answered REJECTED; run bazelisk run //scripts:github-auth -- fix self)"
  assert_eq "the push line is the last line the caller reads" "1" \
    "$(printf '%s\n' "${lines[@]}" | grep -c '^self: push would ')"
  [[ "${output}" != *"push would WORK"* ]]
}

@test "probes/github-auth: push_verdict prints push would WORK and the probe exits 0" {
  use_stubs curl gh coder timeout git
  make_curl_shim >/dev/null
  probe_credential chain GH_TOKEN=ghu_GOOD STUB_CURL_STATUS=200 \
    STUB_CURL_BODY='001f# service=git-receive-pack 0000'
  [ "${status}" -eq 0 ]
  assert_line "one machine-checkable line" "${output}" \
    "self: push would WORK (the credential git consults writes alx/notes)"
  assert_eq "and it is the only push line" "1" \
    "$(printf '%s\n' "${lines[@]}" | grep -c '^self: push would ')"
}

@test "probes/github-auth: kind_of names the credential family, because the repair differs per family" {
  # A GitHub App token needs a repository grant; a personal token needs a scope.
  # Naming the family is what makes the two hints differ, so an operator is not
  # sent to install an App for a PAT that simply lacks the repo scope.
  use_stubs curl gh coder timeout git
  make_curl_shim >/dev/null
  probe_credential chain GH_TOKEN=ghu_APPTOKEN STUB_CURL_STATUS=403 STUB_CURL_BODY='denied'
  [[ "${output}" == *"that GitHub App user-to-server token authenticates"* ]]
  assert_not_match "no personal-token hint for an App token" 'fine-grained token needs' "${output}"
  [[ "${output}" == *"https://github.com/apps/coder/installations/new"* ]]

  probe_credential chain GH_TOKEN=github_pat_FINE STUB_CURL_STATUS=403 STUB_CURL_BODY='denied'
  [[ "${output}" == *"that fine-grained personal access token authenticates"* ]]
  [[ "${output}" == *"fine-grained token needs that repository ticked"* ]]
  assert_not_match "no App-grant lecture for a fine-grained token" 'apps/coder/installations/new' "${output}"

  probe_credential chain GH_TOKEN=ghp_CLASSIC STUB_CURL_STATUS=403 STUB_CURL_BODY='denied'
  [[ "${output}" == *"that classic personal access token authenticates"* ]]
  [[ "${output}" == *"a classic PAT needs the repo scope"* ]]
}

@test "probes/github-auth: verdict_for keys on the status and the body, so a 200 without refs is no pass" {
  # The read endpoint answers 200 for any authenticated caller, which is how the
  # first doctor printed a false pass. Only a 200 that came back advertising
  # service=git-receive-pack counts, and one table has to answer both the
  # per-credential report and the push line so they can never disagree.
  use_stubs curl gh coder timeout git
  make_curl_shim >/dev/null
  probe_credential chain GH_TOKEN=ghu_X STUB_CURL_STATUS=200 STUB_CURL_BODY='{}'
  [[ "${output}" == *"answered 200 without advertising refs"* ]]
  [[ "${output}" != *"PUSH-READY"* ]]
  [ "${status}" -eq 3 ]
  assert_line "the push line agrees with the report" "${output}" \
    "self: push would FAIL now (the credential git consults answered no useful answer; run bazelisk run //scripts:github-auth -- fix self)"

  probe_credential chain GH_TOKEN=ghu_X
  assert_line "offline is its own answer, never a pass" "${output}" \
    "self: git would send this credential (source: env token (GITHUB_TOKEN/GH_TOKEN)) and alx/notes gave no useful answer (github.com gave no useful answer (offline? probe again))"
  [[ "${output}" != *"PUSH-READY"* ]]
  [ "${status}" -eq 3 ]

  probe_credential chain GH_TOKEN=ghu_X STUB_CURL_STATUS=404 STUB_CURL_BODY='Not Found'
  [[ "${output}" == *"but NOT VISIBLE"* ]]
  [[ "${output}" == *"clone and push would both fail"* ]]
  [ "${status}" -eq 3 ]

  probe_credential chain GH_TOKEN=ghu_X STUB_CURL_STATUS=403 STUB_CURL_BODY='denied'
  [[ "${output}" == *"but REFUSED-GRANT"* ]]
  [ "${status}" -eq 3 ]
}

@test "probes/github-auth: add_slot folds one token held twice, and slot_list names every holder" {
  # Two slots holding one token are one credential with two names: github.com
  # is asked once, and the report names both holders instead of showing two rows
  # a reader has to compare.
  use_stubs curl gh coder timeout git
  local helper
  helper="$(make_bin helper-answer <<'HELPER'
#!/bin/sh
cat >/dev/null
printf 'password=%s\n' "${HELPER_TOKEN}"
HELPER
)"
  make_curl_shim >/dev/null
  export CRED_LOG="${BATS_TEST_TMPDIR}/credentials.txt"
  probe_credential chain STUB_GIT_HELPER='!'"${helper}" HELPER_TOKEN=SHARED1 \
    STUB_GH_TOKEN='SHARED1' STUB_CURL_STATUS=200 STUB_CURL_BODY='001f# service=git-receive-pack'
  [ "${status}" -eq 0 ]
  assert_line "both holders are named on one line" "${output}" \
    "self: git would send this credential (source: git credential helper, gh stored login), the same token the gh stored login holds and alx/notes answered PUSH-READY (the receive-pack advertisement came back through this credential, so a push would negotiate)"
  assert_eq "one credential reported, not two" "1" "$(count_report_lines "${output}")"
  assert_eq "and github.com was asked once" "1" "$(grep -c '== call ==' "${CRED_LOG}")"
  assert_eq "with the shared token on the wire" \
    'user = "x-access-token:SHARED1"' "$(sed -n '2p' "${CRED_LOG}")"
}

@test "probes/github-auth-fix: install_helper mints through Coder, clears the pair, and points both hosts at the store" {
  # install_helper is the repair: git's helper for github.com AND
  # gist.github.com must go through a form that clears the injected pair first,
  # or the healthy store stays unreachable and every push keeps failing with the
  # password-authentication error while the store beside it is fine.
  use_stubs coder gh timeout
  export EVO_T1_GITCONFIG="${BATS_TEST_TMPDIR}/gitconfig"
  run env STUB_CODER_OUT='ghu_FRESH' sh "${PROBES_DIR}/github-auth-fix.sh" self alx/notes ''
  [ "${status}" -eq 0 ]
  assert_contains_file "github.com got the env-proof helper" "${EVO_T1_GITCONFIG}" \
    'helper = !env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN .* auth git-credential'
  assert_contains_file "gist.github.com too" "${EVO_T1_GITCONFIG}" \
    '\[credential "https://gist.github.com"\]'
  assert_contains_file "the empty entry that resets inherited helpers is written first" "${EVO_T1_GITCONFIG}" \
    $'^\thelper = $'
  assert_line "the mint is what was stored" "${output}" \
    "self: writing the token minted from Coder external-auth into the gh auth store"
  assert_line "the helper is in place" "${output}" \
    "self: git now reads the gh auth store for github.com, whatever GH_TOKEN holds"
  assert_line "and the caller is told the proof is still to come" "${output}" \
    "self: repaired with the token minted from Coder external-auth; the caller re-probes the write endpoint to prove it"
  assert_match "minted through the default provider id" 'access-token github' "$(stub_log coder)"
}

@test "probes/github-auth-fix: mint_token falls back to the legacy provider id, and store_token keeps a store it cannot mint over" {
  # mint_token asks CODER_GITHUB_AUTH_ID and then the legacy primary-github id,
  # which is what a workspace configured before the rename still answers on.
  # When nothing can be minted, store_token's answer is the credential: the
  # repair may not throw away a healthy store.
  use_stubs coder gh timeout
  export EVO_T1_GITCONFIG="${BATS_TEST_TMPDIR}/gitconfig"
  printf 'ghp_STOREHEALTHY\n' >"${BATS_TEST_TMPDIR}/store"
  STUB_GH_TOKEN="${BATS_TEST_TMPDIR}/store" STUB_CODER_RC=1 CODER_GITHUB_AUTH_ID=my-github \
    run sh "${PROBES_DIR}/github-auth-fix.sh" self '' ''
  [ "${status}" -eq 0 ]
  assert_match "the custom id was asked first" 'access-token my-github' "$(stub_log coder)"
  assert_match "then the legacy id" 'access-token primary-github' "$(stub_log coder)"
  assert_line "the store copy was kept, not discarded" "${output}" \
    "self: repaired with the token already in the gh auth store"
  assert_line "and git was still pointed at it" "${output}" \
    "self: git now reads the gh auth store for github.com, whatever GH_TOKEN holds"
  assert_not_match "the store was not rewritten" 'auth login' "$(stub_log gh)"
}

@test "probes/github-auth-fix: HANDOFF with a counted reason, and no helper written when there is nothing to install" {
  # Nothing mintable and an empty store is not a repairable state, and a git
  # config written on the way to that answer would read as fixed.
  use_stubs coder gh timeout
  export EVO_T1_GITCONFIG="${BATS_TEST_TMPDIR}/gitconfig"
  STUB_CODER_RC=1 STUB_GH_RC=1 run sh "${PROBES_DIR}/github-auth-fix.sh" self alx/notes ws1
  [ "${status}" -eq 4 ]
  assert_line "the handoff says why" "${output}" \
    "self: HANDOFF - nothing can be minted and the gh store is empty, so no command run in this workspace can fix it. The human has to: (1) open the workspace in the Coder UI and click GitHub reauth, finishing the GitHub device-code login; (2) for private repos, click Install GitHub App and grant this repository at https://github.com/apps/coder/installations/new; (3) restart the workspace. Then run bazelisk run //scripts:github-auth -- check again."
  assert_file_not_exists "and no credential helper was written" "${EVO_T1_GITCONFIG}"
}

@test "probes/github-auth-fix: helper-only mode installs the helper and touches no credential" {
  # `github-auth.sh auth` ends in gh auth setup-git, whose plain helper would
  # echo a stale pair over the token just pasted; this mode rewires git and mints
  # and stores nothing.
  use_stubs coder gh timeout
  export EVO_T1_GITCONFIG="${BATS_TEST_TMPDIR}/gitconfig"
  STUB_CODER_OUT='SHOULD_NOT_BE_MINTED' run env EVO_T1_FIX_MODE=helper-only \
    sh "${PROBES_DIR}/github-auth-fix.sh" self '' ''
  [ "${status}" -eq 0 ]
  assert_line "the helper is installed" "${output}" \
    "self: credential helper installed; the credential already in the gh auth store is now the one git reads"
  assert_contains_file "the helper is really in the file" "${EVO_T1_GITCONFIG}" \
    'helper = !env -u GH_TOKEN -u GITHUB_TOKEN'
  assert_eq "nothing was minted" "0" "$(stub_log_count coder)"
  assert_eq "nothing was stored" "0" "$(stub_log_count gh)"
  [[ "${output}" != *"writing the token"* ]]
}

@test "probes/github-auth-fix: install_helper leaves an env-proof helper alone, so fix is idempotent" {
  use_stubs coder gh timeout
  export EVO_T1_GITCONFIG="${BATS_TEST_TMPDIR}/gitconfig"
  git config --file "${EVO_T1_GITCONFIG}" --replace-all credential.https://github.com.helper ''
  git config --file "${EVO_T1_GITCONFIG}" --add credential.https://github.com.helper \
    '!env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN /usr/bin/gh auth git-credential'
  local before after
  before="$(cat "${EVO_T1_GITCONFIG}")"
  STUB_CODER_OUT='ghu_FRESH' STUB_GH_TOKEN='ghu_FRESH' run sh "${PROBES_DIR}/github-auth-fix.sh" self '' ''
  [ "${status}" -eq 0 ]
  assert_line "a helper that already ignores the pair is left alone" "${output}" \
    "self: credential helper already ignores the agent env pair"
  after="$(cat "${EVO_T1_GITCONFIG}")"
  assert_eq "the git config is byte-for-byte unchanged" "${before}" "${after}"
  assert_eq "and one helper entry is still all it holds" "1" \
    "$(git config --file "${EVO_T1_GITCONFIG}" --get-all credential.https://github.com.helper |
      grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')"
  [[ "${output}" != *"writing the token"* ]]
}

# ── probes/spark-configure.sh ───────────────────────────────────────────────

@test "probes/spark-configure: the report ends with report_end" {
  grep -q '^say report_end$' "${PROBES_DIR}/spark-configure.sh"
}

@test "probes/spark-configure: no clone and no container still answers a full report" {
  run env -u CONTAINER -u RUN_TESTS RECIPE_DIR="${BATS_TEST_TMPDIR}/no-such-recipe" \
    sh "${PROBES_DIR}/spark-configure.sh"
  [ "${status}" -eq 0 ]
  [ "$(last_line)" = "report_end" ]
  [[ "${output}" == *"clone=missing"* ]]
}

# ── probes/spark-verify.sh ──────────────────────────────────────────────────

@test "probes/spark-verify: the report helpers are defined at column 0" {
  grep -Eq '^say\(\) \{' "${PROBES_DIR}/spark-verify.sh"
  grep -Eq '^fact\(\) \{' "${PROBES_DIR}/spark-verify.sh"
  grep -Eq '^run_test\(\) \{' "${PROBES_DIR}/spark-verify.sh"
}

@test "probes/spark-verify: a box with no recipe clone still closes its report" {
  run env -u CONTAINER -u RUN_TESTS RECIPE_DIR="${BATS_TEST_TMPDIR}/no-such-recipe" \
    sh "${PROBES_DIR}/spark-verify.sh"
  [ "${status}" -eq 0 ]
  [ "$(last_line)" = "report_end" ]
}

# A recipe clone with the four probes present and runnable, so the only thing a case
# varies is the gate. Each stub records its own name in ran.log, which is how a case
# proves a probe was not merely reported as skipped but never started.
make_recipe_clone() {
  local dir="$1" probe
  mkdir -p "${dir}/scripts"
  for probe in toolcheck needle visioncheck bench; do
    {
      printf '#!/bin/sh\n'
      printf 'printf "%%s\\n" "%s" >>"${RECIPE_DIR}/ran.log"\n' "${probe}"
      printf 'echo "%s ran"\n' "${probe}"
    } >"${dir}/scripts/${probe}.py"
    chmod +x "${dir}/scripts/${probe}.py"
  done
}

# Run the probe the way the caller runs it: container up, clone present, tests asked
# for. The needle gate is the argument under test, so it is the one the case passes,
# ahead of the fixed assignments because env wants its -u options first.
run_spark_probe() {
  local recipe="$1"
  shift
  run env "$@" STUB_COMPOSE_PS="tf-server running tensorfold/decode-native:0.6.1-cu130" \
    CONTAINER=tf-server RECIPE_DIR="${recipe}" RUN_TESTS=yes have_timeout="" \
    sh "${PROBES_DIR}/spark-verify.sh"
}

@test "probes/spark-verify: the 195k needle is held off a box that has work in flight" {
  local recipe="${BATS_TEST_TMPDIR}/recipe"
  make_recipe_clone "${recipe}"
  run_spark_probe "${recipe}" NEEDLE_WANTED=""
  [ "${status}" -eq 0 ]
  [ "$(last_line)" = "report_end" ]
  assert_match "the needle reports itself skipped" '^needle=skipped' "${output}"
  assert_match "the skip says how to force it" 'needle=skipped.*--needle' "${output}"
  if [ -e "${recipe}/ran.log" ]; then
    ! grep -qx needle "${recipe}/ran.log" ||
      fail "the 195k needle was started on a busy box; ran.log: $(tr '\n' ' ' <"${recipe}/ran.log")"
  fi
  # The other three are cheap and stay scheduled.
  grep -qx toolcheck "${recipe}/ran.log" || fail "toolcheck should still run: $(tr '\n' ' ' <"${recipe}/ran.log")"
}

@test "probes/spark-verify: NEEDLE_WANTED=yes runs the window proof" {
  local recipe="${BATS_TEST_TMPDIR}/recipe"
  make_recipe_clone "${recipe}"
  run_spark_probe "${recipe}" NEEDLE_WANTED=yes
  [ "${status}" -eq 0 ]
  assert_match "the needle ran" '^needle=needle\.py: ok' "${output}"
  grep -qx needle "${recipe}/ran.log" || fail "the needle never started"
}

@test "probes/spark-verify: an unset needle gate does not run the window proof" {
  # The destructive probe fails closed: a caller that forgot the assignment gets a skip.
  local recipe="${BATS_TEST_TMPDIR}/recipe"
  make_recipe_clone "${recipe}"
  run_spark_probe "${recipe}" -u NEEDLE_WANTED
  [ "${status}" -eq 0 ]
  assert_match "the needle reports itself skipped" '^needle=skipped' "${output}"
  if [ -e "${recipe}/ran.log" ] && grep -qx needle "${recipe}/ran.log"; then
    fail "the needle ran without being asked for"
  fi
}

# ── probes/seed-owner.sh ────────────────────────────────────────────────────

@test "probes/seed-owner: a path that is not there answers absent" {
  run sh "${PROBES_DIR}/seed-owner.sh" /no/such/file 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "absent" ]
}

@test "probes/seed-owner: the optional 4th marker reads a comment-free TOML config as managed" {
  # The CLI-dropped-comment bug, at the probe level: `grok mcp add` rewrites
  # ~/.grok/config.toml through a parse-and-write-back that deletes every
  # comment line, so the one marker such a file still carries is the TOML key.
  # A caller that hands the probe that 4th marker must get "managed".
  local cfg="${BATS_TEST_TMPDIR}/config.toml"
  printf 'model = "agent"\n[mcp_servers.searxng]\nenabled = true\n__evoT1Stack = true\n' >"${cfg}"
  run sh "${PROBES_DIR}/seed-owner.sh" "${cfg}" 'managed-by: evo-t1-coder-stack' \
    '"__evoT1Stack": true' '__evoT1Stack = true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "managed" ]

  # Three args is still the old probe: the marker list comes from the caller,
  # so the same file is user-owned when nobody asked about the TOML key.
  run sh "${PROBES_DIR}/seed-owner.sh" "${cfg}" 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true'
  [ "${status}" -eq 0 ]
  [ "${output}" = "user" ]

  # And an empty 4th argument is no marker at all: grep -e "" matches every
  # file, which would hand "managed" to everything.
  run sh "${PROBES_DIR}/seed-owner.sh" "${cfg}" 'managed-by: evo-t1-coder-stack' '"__evoT1Stack": true' ''
  [ "${status}" -eq 0 ]
  [ "${output}" = "user" ]
}

# ── probes/seed-find-mtime.sh and probes/seed-rm-mtime.sh ───────────────────

@test "probes/seed-*-mtime: the sweep lists what it would delete, then deletes it" {
  root="${BATS_TEST_TMPDIR}/stale"
  mkdir -p "${root}"
  printf 'old' > "${root}/old.txt"
  printf 'new' > "${root}/new.txt"
  touch -t 202001010000 "${root}/old.txt"
  run sh "${PROBES_DIR}/seed-find-mtime.sh" 30 "${root}" "${BATS_TEST_TMPDIR}/no-such-root"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${root}/old.txt" ]
  run sh "${PROBES_DIR}/seed-rm-mtime.sh" 30 "${root}"
  [ "${status}" -eq 0 ]
  [ ! -e "${root}/old.txt" ]
  [ -f "${root}/new.txt" ]
}

# ── probes/seed-write.sh ────────────────────────────────────────────────────

@test "probes/seed-write: stdin lands at the named path, parent created" {
  dest="${BATS_TEST_TMPDIR}/deep/inner/config.toml"
  printf 'hi' | sh "${PROBES_DIR}/seed-write.sh" "${dest}"
  [ -f "${dest}" ]
  [ "$(cat "${dest}")" = "hi" ]
}
