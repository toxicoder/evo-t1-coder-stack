#!/bin/sh
# shellcheck shell=sh
#
# ## probes/github-auth.sh — Ask github.com, from inside one container, whether each credential slot git and gh would consult can write to a repo (POSIX probe; run with sh, never sourced by the remote)

ws="$1"
repo="${2:-}"
fix="${3:-self}"
sel="${4:-chain}"
envtok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
ghtok=""
mktok=""
id="${CODER_GITHUB_AUTH_ID:-github}"
cands=""
if [ -n "${envtok}" ]; then
  cands="env=${envtok}"
fi
if command -v gh >/dev/null 2>&1; then
  # Read the store with the env pair cleared: `gh auth token` echoes
  # GITHUB_TOKEN/GH_TOKEN when either is set, so asking it with them standing
  # would name the env token twice and hide a PAT pasted into the store.
  # shellcheck disable=SC1007 # the space after = is how an empty env assignment reads
  ghtok="$(GITHUB_TOKEN= GH_TOKEN= gh auth token 2>/dev/null)" || ghtok=""
fi
if [ -n "${ghtok}" ]; then
  cands="${cands:+${cands} }gh=${ghtok}"
fi
# A mint costs a live coder external-auth call, so chain asks for one only
# when nothing else can answer, and --source=mint asks for one every time.
mktok=""
if [ "${sel}" = mint ] || { [ "${sel}" = chain ] && [ -z "${cands}" ]; }; then
  mktok="$(timeout -k 2 15 coder external-auth access-token "${id}" 2>/dev/null)" || mktok=""
  if [ -z "${mktok}" ] && [ "${id}" != "primary-github" ]; then
    mktok="$(timeout -k 2 15 coder external-auth access-token primary-github 2>/dev/null)" || mktok=""
  fi
fi
if [ -n "${mktok}" ]; then
  if [ "${sel}" != chain ] || { [ "${mktok}" != "${envtok}" ] && [ "${mktok}" != "${ghtok}" ]; }; then
    cands="${cands:+${cands} }mint=${mktok}"
  fi
fi
if [ "${sel}" = chain ]; then
  want="env gh mint"
else
  want="${sel}"
fi
if [ -z "${cands}" ]; then
  printf '%s: NO GitHub credential (git will prompt and be refused); fix: pipe a PAT into bazelisk run //scripts:github-auth -- auth %s -\n' "${ws}" "${fix}"
  exit 0
fi
# @function slot_name
# Inside the probe: name one credential slot the way the report reads it.
# Globals:
#   None
# Arguments:
#   $1 - env, gh or mint
# Outputs:
#   The slot name on stdout
# Returns:
#   0
slot_name() {
  case "$1" in
    env) printf 'env token (GITHUB_TOKEN/GH_TOKEN)' ;;
    gh) printf 'gh stored login' ;;
    mint) printf 'Coder external-auth minted token' ;;
    *) printf 'unknown slot %s (use chain, env, gh or mint)' "$1" ;;
  esac
}
if [ -z "${repo}" ]; then
  slots=""
  for pair in ${cands}; do
    slots="${slots:+${slots}, }${pair%%=*}"
  done
  names=""
  for slot in ${slots}; do
    names="${names:+${names}, }$(slot_name "${slot}")"
  done
  printf '%s: credential present (source: %s); pass the repo URL to check its grants\n' "${ws}" "${names}"
  exit 0
fi
tmp="$(mktemp 2>/dev/null)" || tmp="${TMPDIR:-/tmp}/github-auth-probe.$$"
for slot in ${want}; do
  for pair in ${cands}; do
    case "${pair}" in "${slot}="*) ;; *) continue ;; esac
    tok="${pair#*=}"
    kind="credential"
    case "${tok}" in
      ghu_*) kind="GitHub App user-to-server token" ;;
      ghp_* | gho_*) kind="classic personal access token" ;;
      github_pat_*) kind="fine-grained personal access token" ;;
    esac
    if [ "${slot}" != env ] && [ "${tok}" = "${envtok}" ]; then
      if [ "${sel}" = chain ]; then continue; fi
      printf '%s: %s holds the same token as the env pair, so it is the credential named above and nothing more\n' "${ws}" "$(slot_name "${slot}")"
      continue
    fi
    line="${ws}: credential present (source: $(slot_name "${slot}"))"
    if [ -n "${envtok}" ] && [ "${slot}" != env ]; then
      line="${line} [shadowed: the env pair outranks this slot, so git and gh would consult that token first; GH_TOKEN= GITHUB_TOKEN= <command> is how you make them use this slot instead]"
    fi
    answer=$(printf 'user = "x-access-token:%s"\n' "${tok}" | curl -s --max-time 10 --config - -o "${tmp}" -w '%{http_code}' "https://github.com/${repo}.git/info/refs?service=git-receive-pack" 2>/dev/null) || answer=""
    verdict="no useful answer"
    clause="github.com gave no useful answer for ${repo} (offline? probe again)"
    case "${answer}" in
      200)
        if grep -qF 'service=git-receive-pack' "${tmp}" 2>/dev/null; then
          verdict="PUSH-READY"
          clause="the receive-pack advertisement came back through this ${kind}, so a push would negotiate"
        fi
        ;;
      403)
        verdict="REFUSED-GRANT on ${repo}"
        clause="that ${kind} authenticates and every write to the repo is denied, which is the push 403"
        ;;
      404)
        verdict="NOT VISIBLE to this credential"
        clause="a private repo hidden from it answers 404, and so does an absent one: clone and push would both fail"
        ;;
      401)
        verdict="REJECTED"
        clause="github.com refused the credential itself, as it refuses an expired or revoked token"
        ;;
    esac
    rm -f "${tmp}"
    hint=""
    case "${answer}" in
      403 | 404)
        case "${kind}" in
          *personal*)
            hint="that is no grant on this repo: a classic PAT needs the repo scope and a fine-grained token needs that repository ticked, so mint one that has it and pipe it into bazelisk run //scripts:github-auth -- auth ${fix} -"
            ;;
          *)
            hint="grant the GitHub App behind that token access to this repo (GitHub -> Settings -> Applications -> <app> -> Configure -> Repository access); an empty Applications page means no App is installed under your account, so install Coder's at https://github.com/apps/coder/installations/new (or click Install GitHub App on the workspace), grant this repo, then restart; the other way out is a write-scope PAT (check --source=gh says whether the gh auth store already holds one that can write; if it does not, install one with bazelisk run //scripts:github-auth -- auth ${fix} -)"
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
done
