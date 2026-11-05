#!/bin/sh
# shellcheck shell=sh
#
# ## probes/github-auth.sh — Ask github.com, from inside one container, whether the credential git would really send can write to a repo (POSIX probe; run with sh, never sourced by the remote)

ws="$1"
repo="${2:-}"
fix="${3:-self}"
sel="${4:-chain}"
envtok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
ghtok=""
mktok=""
id="${CODER_GITHUB_AUTH_ID:-github}"
if command -v gh >/dev/null 2>&1; then
  # Read the store with the env pair cleared: `gh auth token` echoes
  # GITHUB_TOKEN/GH_TOKEN when either is set, so asking it with them standing
  # would name the env token twice and hide a PAT pasted into the store.
  # shellcheck disable=SC1007 # the space after = is how an empty env assignment reads
  ghtok="$(GITHUB_TOKEN= GH_TOKEN= gh auth token 2>/dev/null)" || ghtok=""
fi
# A mint costs a live coder external-auth call, so chain asks for one only
# when nothing else can answer, and --source=mint asks for one every time.
mktok=""
if [ "${sel}" = mint ] || { [ "${sel}" = chain ] && [ -z "${envtok}${ghtok}" ]; }; then
  mktok="$(timeout -k 2 15 coder external-auth access-token "${id}" 2>/dev/null)" || mktok=""
  if [ -z "${mktok}" ] && [ "${id}" != "primary-github" ]; then
    mktok="$(timeout -k 2 15 coder external-auth access-token primary-github 2>/dev/null)" || mktok=""
  fi
fi
# @function slot_name
# Inside the probe: name one credential slot the way the report reads it.
# Globals:
#   None
# Arguments:
#   $1 - git, askpass, env, gh or mint
# Outputs:
#   The slot name on stdout
# Returns:
#   0
slot_name() {
  case "$1" in
    git) printf 'git credential helper' ;;
    askpass) printf 'GIT_ASKPASS helper' ;;
    env) printf 'env token (GITHUB_TOKEN/GH_TOKEN)' ;;
    gh) printf 'gh stored login' ;;
    mint) printf 'Coder external-auth minted token' ;;
    *) printf 'unknown slot %s (use chain, env, gh or mint)' "$1" ;;
  esac
}
# @function helper_credential
# Inside the probe: ask git's own credential helper the question git asks it,
# and print the password it would send. git walks its helpers in order and
# sends the first answer, and the stack points github.com at
# `gh auth git-credential`, which echoes GH_TOKEN/GITHUB_TOKEN when either is
# set. Reading the environment instead would miss a helper that answers with a
# token no slot holds, and would miss the case where the helper answers
# nothing and git falls through to prompting. A helper value that starts with
# ! is a shell command, which is how git runs it: through sh -c, with `get`
# appended and the lookup on stdin.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The token the helper would supply, on stdout; nothing when git is absent,
#   no helper is configured for github.com, or the helper answers no password
# Returns:
#   0 always, so an absent git or a silent helper is a finding, not a failure
helper_credential() {
  hlp=""
  command -v git >/dev/null 2>&1 || return 0
  hlp="$(git config --get-all 'credential.https://github.com.helper' 2>/dev/null |
    grep -v '^[[:space:]]*$' | tail -n 1)"
  [ -n "${hlp}" ] || return 0
  case "${hlp}" in
    '!'*) printf 'protocol=https\nhost=github.com\n\n' |
      sh -c "${hlp#!} get" 2>/dev/null | sed -n 's/^password=//p' | head -n 1 ;;
    *) printf 'protocol=https\nhost=github.com\n\n' |
      "${hlp}" get 2>/dev/null | sed -n 's/^password=//p' | head -n 1 ;;
  esac
  return 0
}
# @function askpass_credential
# Inside the probe: ask the injected GIT_ASKPASS for the password git would be
# handed, and report whether that helper is alive. Coder stages GIT_ASKPASS at
# a `coder` binary, and a build of it answers every prompt with
# `unrecognized subcommand` and a non-zero exit. A dead askpass is why a stale
# token surfaces as the misleading `Password authentication is not supported
# for Git operations.` rather than as an expired token: git gets no answer,
# falls through to prompting, and a non-interactive push is refused. Naming it
# is the difference between repairing the credential and chasing a grant that
# was never the problem.
# Globals:
#   GIT_ASKPASS
# Arguments:
#   None
# Outputs:
#   "<state> <token>" on stdout, where state is alive, dead or unset and the
#   token is empty unless the helper answered one
# Returns:
#   0 always
askpass_credential() {
  [ -n "${GIT_ASKPASS:-}" ] || {
    printf 'unset \n'
    return 0
  }
  [ -x "${GIT_ASKPASS}" ] || {
    printf 'dead \n'
    return 0
  }
  ask_out=""
  if ! ask_out="$("${GIT_ASKPASS}" 'Password for https://github.com:' 2>/dev/null)"; then
    printf 'dead \n'
    return 0
  fi
  ask_tok="$(printf '%s\n' "${ask_out}" | head -n 1)"
  if [ -z "${ask_tok}" ]; then
    printf 'dead \n'
  else
    printf 'alive %s\n' "${ask_tok}"
  fi
  return 0
}
gitok="$(helper_credential)"
ask_state="unset"
ask_tok=""
ask_reply="$(askpass_credential)"
ask_state="${ask_reply%% *}"
[ "${ask_state}" = "alive" ] && ask_tok="${ask_reply#* }"
# The slots in the exact order git consults them: the first helper that
# answers wins, then GIT_ASKPASS, then the env pair the gh helper itself
# echoes, then the store, then a mint. Slots past the winner exist but a real
# push never reaches them, which is the whole difference between a credential
# that works and a push that works.
slots=""
tok=""
# @function add_slot
# Inside the probe: add one slot to the candidate list, folding it into the
# entry that already holds the same token wherever that entry sits. Two slots
# holding one token are one credential with two names, and github.com gets
# asked once - the old probe only compared neighbours, so a helper token that
# also sat in the store was probed twice whenever the env pair differed.
# Position comes from the first slot that held the token, and slots are added in
# git's own consult order, so the first entry is the credential a push would
# really send and everything after it is reachable only by clearing what
# shadows it.
# Globals:
#   slots
# Arguments:
#   $1 - the slot name (git, askpass, env, gh or mint)
#   $2 - the token, or empty for a slot nothing holds
# Outputs:
#   Nothing; rebuilds the slots list in the global
# Returns:
#   0
add_slot() {
  case "${2:-}" in
    '') return 0 ;;
  esac
  rebuilt=""
  found=""
  for e in ${slots}; do
    if [ "${e%%|*}" = "${2}" ]; then
      e="${e}|$1"
      found=1
    fi
    rebuilt="${rebuilt:+${rebuilt} }${e}"
  done
  if [ -z "${found}" ]; then
    rebuilt="${rebuilt:+${rebuilt} }${2}|$1"
  fi
  slots="${rebuilt}"
}
add_slot git "${gitok}"
add_slot askpass "${ask_tok}"
add_slot env "${envtok}"
add_slot gh "${ghtok}"
add_slot mint "${mktok}"
if [ "${sel}" != chain ]; then
  kept=""
  for e in ${slots}; do
    case "|${e#*|}|" in
      *"|${sel}|"*) kept="${kept:+${kept} }${e}" ;;
    esac
  done
  slots="${kept}"
fi
if [ -z "${slots}" ]; then
  printf '%s: NO GitHub credential in the %s slot (git will prompt and be refused); fix: bazelisk run //scripts:github-auth -- fix %s\n' "${ws}" "${sel}" "${fix}"
  printf '%s: push would FAIL (no credential to send)\n' "${ws}"
  exit 3
fi
# @function kind_of
# Inside the probe: name the credential family from its prefix, because the fix
# for a refused write differs completely between a GitHub App token that needs
# a repository grant and a personal token that needs a scope.
# Globals:
#   None
# Arguments:
#   $1 - the token
# Outputs:
#   The kind on stdout
# Returns:
#   0
kind_of() {
  case "${1:-}" in
    ghu_*) printf 'GitHub App user-to-server token' ;;
    ghp_* | gho_*) printf 'classic personal access token' ;;
    github_pat_*) printf 'fine-grained personal access token' ;;
    *) printf 'credential' ;;
  esac
}
# @function verdict_for
# Inside the probe: turn one HTTP status plus the saved body into the verdict
# word and the clause that explains it, on one line separated by a tab. One
# table so the per-credential report and the push verdict can never disagree
# about what a 403 means.
# Globals:
#   None
# Arguments:
#   $1 - the HTTP status, or empty when github.com never answered
#   $2 - the path of the file the body was written to
#   $3 - the credential kind
# Outputs:
#   "<verdict> :: <clause>" on stdout, one line, so the caller can split it
#   with shell prefix removal alone (no tab literal, no external splitter)
# Returns:
#   0
verdict_for() {
  case "$1" in
    200)
      if grep -qF 'service=git-receive-pack' "$2" 2>/dev/null; then
        printf 'PUSH-READY :: the receive-pack advertisement came back through this %s, so a push would negotiate\n' "$3"
      else
        printf 'no useful answer :: github.com answered 200 without advertising refs on the write endpoint, so a push is not proven\n'
      fi
      ;;
    403)
      printf 'REFUSED-GRANT :: that %s authenticates and every write to the repo is denied, which is the push 403\n' "$3"
      ;;
    404)
      printf 'NOT VISIBLE :: a private repo hidden from it answers 404, and so does an absent one: clone and push would both fail\n'
      ;;
    401)
      printf 'REJECTED :: github.com refused the credential itself, as it refuses an expired or revoked token\n'
      ;;
    *)
      printf 'no useful answer :: github.com gave no useful answer (offline? probe again)\n'
      ;;
  esac
}
if [ -z "${repo}" ]; then
  names=""
  for e in ${slots}; do
    for s in $(printf '%s' "${e#*|}" | tr '|' ' '); do
      names="${names:+${names}, }$(slot_name "${s}")"
    done
  done
  printf '%s: credential present (source: %s); pass the repo URL to check its grants\n' "${ws}" "${names}"
  first="${slots%% *}"
  printf '%s: git would send the %s\n' "${ws}" "$(slot_name "${first##*|}")"
  printf '%s: push cannot be answered (pass a repo URL to ask the write question)\n' "${ws}"
  exit 0
fi
tmp="$(mktemp 2>/dev/null)" || tmp="${TMPDIR:-/tmp}/github-auth-probe.$$"
effective_verdict=""
first_slot=""
# @function slot_list
# Inside the probe: render one entry's owner list the way the report reads it,
# so a token that several slots hold is named as one credential with several
# names rather than as separate rows a reader has to compare.
# Globals:
#   None
# Arguments:
#   $1 - pipe-separated slot names, as add_slot built them
# Outputs:
#   Comma-separated slot names on stdout
# Returns:
#   0
slot_list() {
  out=""
  for s in $(printf '%s' "$1" | tr '|' ' '); do
    out="${out:+${out}, }$(slot_name "${s}")"
  done
  printf '%s' "${out}"
}
for e in ${slots}; do
  tok="${e%%|*}"
  own="${e#*|}"
  first_slot="${first_slot:-${own%%|*}}"
  kind="$(kind_of "${tok}")"
  line="${ws}: credential present (source: $(slot_list "${own}"))"
  if [ "${own%%|*}" = "${first_slot}" ]; then
    # One line shape for every credential: the leading phrase says whether git
    # would reach this one, and the source label stays so the two reports read
    # the same way side by side.
    line="${ws}: git would send this credential (source: $(slot_list "${own}"))"
    if [ "${own#*|}" != "${own%%|*}" ]; then
      line="${line}, the same token the $(slot_list "${own#*|}") holds"
    fi
  elif [ -n "${envtok}" ]; then
    line="${line} [shadowed: the credential above outranks this slot, so git and gh consult that token first; env -u GH_TOKEN -u GITHUB_TOKEN <command> is how you make them use this slot instead]"
  fi
  answer=$(printf 'user = "x-access-token:%s"\n' "${tok}" | curl -s --max-time 10 --config - -o "${tmp}" -w '%{http_code}' "https://github.com/${repo}.git/info/refs?service=git-receive-pack" 2>/dev/null) || answer=""
  reply="$(verdict_for "${answer}" "${tmp}" "${kind}")"
  verdict="${reply%% :: *}"
  clause="${reply#* :: }"
  if [ "${own%%|*}" = "${first_slot}" ]; then
    effective_verdict="${verdict}"
  fi
  hint=""
  case "${answer}" in
    403 | 404)
      case "${kind}" in
        *personal*)
          hint="that is no grant on this repo: a classic PAT needs the repo scope and a fine-grained token needs that repository ticked, so mint one that has it and pipe it into bazelisk run //scripts:github-auth -- auth ${fix} -"
          ;;
        *)
          hint="grant the GitHub App behind that token access to this repo (GitHub -> Settings -> Applications -> <app> -> Configure -> Repository access); an empty Applications page means no App is installed under your account, so install Coder's at https://github.com/apps/coder/installations/new (or click Install GitHub App on the workspace), grant this repo, then restart; the other way out is a write-capable credential of your own, piped into bazelisk run //scripts:github-auth -- auth ${fix} -"
          ;;
      esac
      ;;
    401)
      case "${own}" in
        *env*)
          hint="the env pair is the copy Coder injected when this workspace started, and it expires while the workspace keeps running; the gh store copy and a fresh mint are the live ones, so bazelisk run //scripts:github-auth -- fix ${fix} is the repair. It cannot help the GitHub MCP lane, though: ~/.grok/config.toml hands api.githubcopilot.com a Bearer header read from that same pair when the agent process started, so the GitHub tools die with it and only a workspace restart brings them back (bazelisk run //scripts:mcp-check names the dead lane)"
          ;;
      esac
      ;;
  esac
  case "${verdict}" in
    PUSH-READY)
      printf '%s and %s answered PUSH-READY (%s)\n' "${line}" "${repo}" "${clause}"
      ;;
    REJECTED)
      printf '%s but REJECTED (%s): re-mint it with coder external-auth access-token %s from a workspace shell, or click GitHub reauth on the workspace in the Coder UI\n' "${line}" "${clause}" "${id}"
      ;;
    "no useful answer")
      printf '%s and %s gave no useful answer (%s)\n' "${line}" "${repo}" "${clause}"
      ;;
    *)
      printf '%s but %s (%s); %s\n' "${line}" "${verdict}" "${clause}" "${hint}"
      ;;
  esac
done
rm -f "${tmp}"
if [ "${ask_state}" = "dead" ] && [ "${sel}" = chain ]; then
  printf '%s: note: GIT_ASKPASS is set but answers no credential, which is what turns a refused token into "Password authentication is not supported for Git operations."; a working credential helper makes it moot\n' "${ws}"
fi
# @function push_verdict
# Inside the probe: print the one line the caller gates on. Everything else in
# this report is prose for a human; this line is the machine-checkable answer
# to "would git push from here right now", keyed to the credential git would
# actually send. Printing a pass beside a credential that is healthy but
# unreachable is the false pass that sent agents chasing grants for an hour, so
# a healthy-but-shadowed credential reports FAIL and names the one repair.
# Globals:
#   None
# Arguments:
#   $1 - the verdict word the effective credential answered, or empty
# Outputs:
#   One "push would ..." line on stdout
# Returns:
#   0
push_verdict() {
  case "${1:-}" in
    PUSH-READY)
      printf '%s: push would WORK (the credential git consults writes %s)\n' "${ws}" "${repo}"
      ;;
    "")
      printf '%s: push would FAIL (git has no credential to send; run bazelisk run //scripts:github-auth -- fix %s)\n' "${ws}" "${fix}"
      ;;
    *)
      printf '%s: push would FAIL now (the credential git consults answered %s; run bazelisk run //scripts:github-auth -- fix %s)\n' "${ws}" "${1}" "${fix}"
      ;;
  esac
}
push_verdict "${effective_verdict}"
if [ "${effective_verdict}" = "PUSH-READY" ]; then
  exit 0
fi
exit 3
