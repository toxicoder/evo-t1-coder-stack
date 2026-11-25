# shellcheck shell=bash
#
# ## stack_prs.sh - the stacked-PR rules over the GitHub stacks REST API (sourced; never executed)
#
# A stack is a chain of pull requests where each layer's base is the branch of the
# layer under it. Nothing in this tree could create, read, retarget, or land one:
# `gh pr create` sets one base by hand, and a rebase of the bottom layer leaves every
# layer above it pointing at a commit main already has. The GitHub stacks API owns the
# chain and this lib is the one place in the stack that speaks it, so the verbs have a
# single seam to test.
#
# What that chain's endpoints are is a measured fact, not a guess. On 2026-11-24
# `gh api --method GET /repos/toxicoder/evo-t1-coder-stack/stacks` answered HTTP 200
# with a body opening
# `[{"id":3949966,"number":193,"node_id":"PRS_...","base":{"ref":"main"},"open":false,`
# and each entry carrying `pull_requests[]` whose items hold `number`, `state`, `draft`,
# `merged_at`, `head.ref`, `head.sha`. That one response pinned `GET /repos/{o}/{r}/stacks`,
# a stack's two identities (a global `id` and a repository-scoped `number`), the stack's
# `base.ref`, and the ordered list key `pull_requests[]`. The paths and fields this CLI
# still sends without that evidence - `GET /stacks/{number}`, `POST /stacks/{number}/add`,
# `POST /stacks/{number}/unstack`, and the request-body field names `pull_requests` and
# `pull_request` - are this CLI's own convention: the three operator-cited pages enumerate
# no stacks REST endpoint at all, and the endpoint list at
# https://docs.github.com/en/rest/pulls/stacks keeps its method/path tables in a form the
# fetch lane cannot extract, so those names stay unconfirmed by documentation.
#
# Two facts about this API are documented, and this lib leans on both:
#
#   - a merge must go through the asynchronous merge API: "a stack cannot be merged with
#     the legacy synchronous merge endpoints or mutations".
#     https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks
#   - there is no dedicated stack webhook event. GitHub adds a `stack` property to the
#     `pull_request` object in `pull_request` payloads for lifecycle events that happen
#     while the PR is part of a stack, on the same URL.
#     https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks
#
# Two rules are load-bearing here and each is a function rather than a habit:
#
#   - every call goes through `env -u GH_TOKEN -u GITHUB_TOKEN gh api`. Coder injects
#     that pair at workspace start and it dies about an hour later; gh prefers it over
#     the gh auth store the refresh job keeps live, so an un-unset pair makes every
#     call fail with a token-age error nothing else in the output explains. gh_api is
#     the only place that builds the command, which is why no verb can forget it.
#   - a stack lands bottom-up, and only through the asynchronous merge endpoint:
#     PUT /repos/{o}/{r}/pulls/{n}/merge-async plus
#     GET /repos/{o}/{r}/pulls/{n}/merge-async/{uuid}. The synchronous
#     PUT .../pulls/{n}/merge is refused outright by assert_async_only: merging a
#     twelve-layer stack through it holds one HTTP request per layer open until
#     GitHub's own timeout, which reads as a hung CLI and can leave a layer merged
#     with the run already dead. The rule is GitHub's own words: a stack cannot be
#     merged with the legacy synchronous merge endpoints "or mutations".
#
# Whether a layer is a draft is the operator's decision, made when they opened the pull
# request: this lib creates no pull requests, only stacks over existing ones, so it
# never sets a draft state and claims no API default for one. `--open` is this CLI's own
# convention for clearing draft on layers the operator says are ready, through
# POST /repos/{o}/{r}/pulls/{n}/ready. (Draft-by-default is the `gh stack link`
# behaviour, which "creates a draft pull request with the correct base branch" unless
# --open; the REST create example shows draft:false.)
#
# A repository with stacks turned off is not a failure an operator can fix from the
# shell, so it maps to a HANDOFF note. It is read from the HTTP status and error text of
# the /stacks calls, because exit code 9 belongs to the `gh stack` extension - see
# https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands#exit-codes -
# and this CLI's only transport is `gh api`, for which no page gives code 9 any meaning.
#
# Usage (from an entry script, after `set -euo pipefail` and the common.sh source):
#   # shellcheck source=lib/stack_prs.sh disable=SC1091
#   source "scripts/lib/stack_prs.sh"

VERB=""
REPO_ARG=""
REPO_SLUG=""
STACK_NUMBER=""
PR_NUMBER=""
TRUNK="main"
MERGE_METHOD="merge"
DRY_RUN=0
OPEN_LAYERS=0
RAW_VIEW=0
POLL_INTERVAL=2
POLL_TIMEOUT=300
INVOKE_DIR="${BUILD_WORKSPACE_DIRECTORY:-${PWD}}"

# Set by gh_api when the repository has no stacks; main turns it into exit 3.
STACKS_DISABLED=0
# The response body and the exit code of the last gh_api call, for the verb that made
# it. Globals rather than command substitutions so a caller can read the code without
# `if out="$(...)"` swallowing it into a subshell it cannot exit.
GH_RESPONSE=""
GH_RC=0

declare -ga PR_NUMBERS=()

# The two shapes `view` asks gh to render. They live here rather than inline because
# the response schema is GitHub's to change and a verb that reads it in three places
# breaks in three places.
#
# `.[]` at the top level is measured, not guessed: the 200 body recorded in the header
# is a bare JSON array of stack objects, not an object wrapping a `stacks` key, so a
# `.stacks[]` here would answer every list view with nothing.
JQ_STACK_LAYERS='.pull_requests[] | "\(.number)\t\(.head.ref)\t\(.base.ref)\t\(.draft)"'
JQ_STACK_LIST='.[] | "\(.number)\t\(.pull_requests | length)"'

# @function usage
# Print the invocation summary and the flag list.
# Globals:
#   none
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'EOF'
Usage: stack-prs.sh <verb> [--repo DIR | --slug owner/repo] [verb flags]

Verbs:
  create-stack --prs N,N,... [--open]   POST /stacks with the layers bottom-first
  add          --stack N --pr N         POST /stacks/{n}/add
  view         [--stack N] [--raw]      GET /stacks or GET /stacks/{n}
  retarget     --stack N                PATCH each layer's base onto its parent branch
  unstack      --stack N                POST /stacks/{n}/unstack
  merge        [--stack N | --pr N] [--method M]  merge-async only, bottom-up

Flags:
  --repo DIR      checkout whose origin names the repository (also $EVO_T1_REPO)
  --slug o/r      name the repository directly and read no git at all
  --prs N,N,...   the layer PR numbers, bottom of the stack first
  --stack N       the stack number
  --pr N          a single pull request number
  --trunk NAME    the base the bottom layer sits on; default main
  --open          mark the layers ready; without it a layer stays a draft
  --method M      merge|squash|rebase for merge; default merge
  --raw           print the API JSON instead of the rendered rows
  --dry-run       print the calls and send none
  --poll-interval S  seconds between merge-async polls; default 2
  --poll-timeout S   give up on one layer after this many seconds; default 300
EOF
}

# @function require_value
# Refuse a long option that arrived without its value.
# A missing value has to leave on 2 with the reason rather than on whatever the verb
# then did with an empty string: `--stack` with nothing after it would otherwise send
# POST /repos/o/r/stacks//add and blame the API for the 404.
# Globals:
#   VALUE - set to the value the operator gave, when there was one
# Arguments:
#   $1 - the flag as typed; $2 - the value the operator may or may not have given
# Outputs:
#   error: ... plus the usage block on stderr, then exits 2
# Returns:
#   0 when there is a usable value
require_value() {
  local flag="$1" value="${2:-}"
  if [ -z "${value}" ] || [[ ${value} == -* ]]; then
    err "${flag} needs a value"
    usage >&2
    exit 2
  fi
  VALUE="${value}"
}

# @function is_number
# Decide whether a string is a bare positive integer.
# Every PR and stack number reaches a URL path, so this is the one place that decides
# whether `--pr ../foo` or `--stack "1; curl ..."` can become a path segment.
# Globals:
#   none
# Arguments:
#   $1 - the candidate
# Outputs:
#   None
# Returns:
#   0 for a positive integer, 1 for anything else
is_number() {
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]]
}

# @function set_pr_numbers
# Split a comma-separated layer list and refuse anything that is not a number.
# Both --prs forms land here: a value the operator typed after the flag and one they
# glued to it with = have to be held to the same rule, or `--prs=12,x` would reach the
# request body where `--prs 12 x` would not.
# Globals:
#   PR_NUMBERS - replaced by the parsed list
# Arguments:
#   $1 - the raw comma-separated value
# Outputs:
#   error: plus exit 2 for the first entry that is not a number
# Returns:
#   0 when every entry parsed
set_pr_numbers() {
  local raw="$1" part
  IFS=',' read -r -a PR_NUMBERS <<<"${raw}"
  for part in ${PR_NUMBERS[@]+"${PR_NUMBERS[@]}"}; do
    is_number "${part}" || {
      err "--prs wants comma-separated pull request numbers, got: ${part}"
      exit 2
    }
  done
}

# @function parse_args
# Fill the run's options from argv, refusing anything unrecognized.
# Globals:
#   VERB, REPO_ARG, REPO_SLUG, STACK_NUMBER, PR_NUMBER, PR_NUMBERS, TRUNK,
#   MERGE_METHOD, DRY_RUN, OPEN_LAYERS, RAW_VIEW, POLL_INTERVAL, POLL_TIMEOUT, VALUE
# Arguments:
#   $@ - the CLI arguments, verb first
# Outputs:
#   One "error: ..." line on stderr for a bad argument
# Returns:
#   0 on success; exits 2 on a bad argument
# shellcheck disable=SC2034 # the option variables are read by the verbs and main()
# in this lib and by scripts/stack-prs.sh, which shellcheck cannot see from here.
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      create-stack | add | view | retarget | unstack | merge)
        [ -z "${VERB}" ] || {
          err "two verbs given: ${VERB} and $1"
          exit 2
        }
        VERB="$1"
        shift
        ;;
      --repo)
        require_value --repo "${2:-}"
        REPO_ARG="${VALUE}"
        shift 2
        ;;
      --repo=*)
        REPO_ARG="${1#*=}"
        shift
        ;;
      --slug)
        require_value --slug "${2:-}"
        REPO_SLUG="${VALUE}"
        shift 2
        ;;
      --slug=*)
        REPO_SLUG="${1#*=}"
        shift
        ;;
      --prs)
        require_value --prs "${2:-}"
        set_pr_numbers "${VALUE}"
        shift 2
        ;;
      --prs=*)
        set_pr_numbers "${1#*=}"
        shift
        ;;
      --stack)
        require_value --stack "${2:-}"
        STACK_NUMBER="${VALUE}"
        shift 2
        ;;
      --stack=*)
        STACK_NUMBER="${1#*=}"
        shift
        ;;
      --pr)
        require_value --pr "${2:-}"
        PR_NUMBER="${VALUE}"
        shift 2
        ;;
      --pr=*)
        PR_NUMBER="${1#*=}"
        shift
        ;;
      --trunk)
        require_value --trunk "${2:-}"
        TRUNK="${VALUE}"
        shift 2
        ;;
      --trunk=*)
        TRUNK="${1#*=}"
        shift
        ;;
      --method)
        require_value --method "${2:-}"
        MERGE_METHOD="${VALUE}"
        shift 2
        ;;
      --method=*)
        MERGE_METHOD="${1#*=}"
        shift
        ;;
      --poll-interval)
        require_value --poll-interval "${2:-}"
        POLL_INTERVAL="${VALUE}"
        shift 2
        ;;
      --poll-timeout)
        require_value --poll-timeout "${2:-}"
        POLL_TIMEOUT="${VALUE}"
        shift 2
        ;;
      --open)
        OPEN_LAYERS=1
        shift
        ;;
      --raw)
        RAW_VIEW=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  [ -n "${VERB}" ] || {
    err "no verb: pass one of create-stack, add, view, retarget, unstack, merge"
    usage >&2
    exit 2
  }
  [[ ${MERGE_METHOD} =~ ^(merge|squash|rebase)$ ]] || {
    err "--method wants merge, squash, or rebase, got: ${MERGE_METHOD}"
    exit 2
  }
  [[ ${POLL_INTERVAL} =~ ^[0-9]+$ ]] || {
    err "--poll-interval wants a whole number of seconds, got: ${POLL_INTERVAL}"
    exit 2
  }
  # A zero-second interval with a pending job never advances the elapsed counter, so
  # the wait would spin on gh forever instead of honouring --poll-timeout.
  [ "${POLL_INTERVAL}" -ge 1 ] || {
    err "--poll-interval wants at least 1 second, got: ${POLL_INTERVAL}"
    exit 2
  }
  [[ ${POLL_TIMEOUT} =~ ^[0-9]+$ ]] || {
    err "--poll-timeout wants a whole number of seconds, got: ${POLL_TIMEOUT}"
    exit 2
  }
  [ -n "${STACK_NUMBER}" ] && ! is_number "${STACK_NUMBER}" && {
    err "--stack wants a pull request number, got: ${STACK_NUMBER}"
    exit 2
  }
  [ -n "${PR_NUMBER}" ] && ! is_number "${PR_NUMBER}" && {
    err "--pr wants a pull request number, got: ${PR_NUMBER}"
    exit 2
  }
  # The verdict is "the options are usable", not the status of the last test: with no
  # --stack and no --pr given, that last [ -n ] is false and parse_args would return 1
  # to a caller under set -e, ending the run before main ever printed a line.
  return 0
}

# @function resolve_repo_dir
# Print --repo as a directory this process can actually enter.
# Under `bazelisk run` the launcher starts inside the runfiles tree, so a relative
# --repo has to be anchored where the operator stood, which is what INVOKE_DIR holds.
# The cd runs in the command substitution's subshell, so resolving never moves the
# caller, which needs its own cwd for nothing else.
# Globals:
#   INVOKE_DIR - the anchoring directory
# Arguments:
#   $1 - the --repo value as the operator typed it
# Outputs:
#   The absolute path on stdout, or nothing when the path does not resolve
# Returns:
#   0 with the path on stdout, 1 when it cannot be entered
resolve_repo_dir() {
  local given="$1" candidate
  local base="${INVOKE_DIR:-${BUILD_WORKSPACE_DIRECTORY:-${PWD}}}"
  if [[ ${given} == /* ]]; then
    candidate="${given}"
  else
    candidate="${base}/${given}"
  fi
  cd "${candidate}" 2>/dev/null || return 1
  pwd
}

# @function parse_repo_slug
# Print owner/repo for a git remote URL, or nothing when it is not a GitHub remote.
# Three shapes are accepted because origin is any of them depending on how the clone
# was made: https://github.com/o/r(.git), ssh://git@github.com/o/r(.git), and the
# scp-like git@github.com:o/r(.git). The .git suffix is dropped because the stacks API
# path takes the bare repo name and a trailing .git answers 404.
# Globals:
#   none
# Arguments:
#   $1 - the remote URL as `git remote get-url` prints it
# Outputs:
#   "owner/repo" on stdout, or nothing
# Returns:
#   0 when a GitHub slug was found, 1 otherwise
parse_repo_slug() {
  local url="${1:-}" path
  path=""
  case "${url}" in
    *github.com[:/]*)
      path="${url#*github.com}"
      path="${path#:}"
      path="${path#/}"
      ;;
    *)
      return 1
      ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  [[ ${path} =~ ^[^/]+/[^/]+$ ]] || return 1
  printf '%s' "${path}"
}

# @function resolve_repo_slug
# Set REPO_SLUG from --slug, or from the checkout's origin remote.
# --slug short-circuits git entirely: the operator who knows the slug should not need
# a checkout that has an origin, and a test should not need a fixture to name one.
# Globals:
#   REPO_SLUG, REPO_ARG, EVO_T1_REPO
# Arguments:
#   None
# Outputs:
#   An error line naming what was tried, when nothing answered
# Returns:
#   0 with REPO_SLUG set, 1 when the repository could not be named
resolve_repo_slug() {
  if [ -n "${REPO_SLUG}" ]; then
    [[ ${REPO_SLUG} =~ ^[^/]+/[^/]+$ ]] || {
      err "--slug wants owner/repo, got: ${REPO_SLUG}"
      return 1
    }
    return 0
  fi
  REPO_ARG="${REPO_ARG:-${EVO_T1_REPO:-}}"
  local root url
  if [ -n "${REPO_ARG}" ]; then
    root="$(resolve_repo_dir "${REPO_ARG}")" || {
      err "cannot enter --repo ${REPO_ARG}"
      return 1
    }
  else
    root="$(resolve_checkout "${SELF_DIR:-${PWD}}")" || {
      err "no checkout: pass --repo DIR or --slug owner/repo"
      return 1
    }
  fi
  url="$(git -C "${root}" remote get-url origin 2>/dev/null || true)"
  [ -n "${url}" ] || {
    err "no origin remote in ${root}; pass --slug owner/repo"
    return 1
  }
  if ! REPO_SLUG="$(parse_repo_slug "${url}")"; then
    err "origin ${url} is not a github.com repository; pass --slug owner/repo"
    REPO_SLUG=""
    return 1
  fi
  return 0
}

# @function assert_async_only
# Refuse an endpoint that merges through the synchronous route.
# The merge-async pair is the only merge path this CLI may use. A synchronous
# PUT /pulls/{n}/merge is refused here rather than merely left unused, so the rule
# survives the next person who reaches for the endpoint they already know.
# Globals:
#   none
# Arguments:
#   $1 - the API path the caller is about to send
# Outputs:
#   An error line naming the endpoint pair a merge has to use
# Returns:
#   0 for every endpoint but the synchronous merge, 1 for that one
assert_async_only() {
  local endpoint="${1:-}"
  if [[ ${endpoint} =~ /pulls/[0-9]+/merge(\?|$) ]]; then
    err "refusing the synchronous merge endpoint: ${endpoint}"
    err "a merge goes through PUT /pulls/{n}/merge-async then GET /pulls/{n}/merge-async/{uuid}"
    return 1
  fi
  return 0
}

# @function stacks_disabled_shape
# Decide whether a failed /stacks call is the repository having stacks turned off.
# No page names a status or a message for that case, so this is the CLI's own
# inference from what `gh api` can actually report: a call to the stacks collection or
# to one stack that came back HTTP 404 or HTTP 422, either with text that names a
# feature or an enablement problem or bare, which is what a repository without the
# feature answers. A 404 anywhere else is an ordinary failed call and has to stay one:
# off the two collection paths it means a wrong PR number or a stack that is not there,
# so the path check comes first.
# Globals:
#   none
# Arguments:
#   $1 - the API path that was called; $2 - the gh exit code; $3 - gh's stderr text
# Outputs:
#   Nothing; the decision is the return code
# Returns:
#   0 when the call looks like the missing repository setting, 1 otherwise
stacks_disabled_shape() {
  local endpoint="${1:-}" gh_rc="${2:-0}" err_text="${3:-}"
  [[ ${endpoint} =~ /stacks(/[0-9]+)?$ ]] || return 1
  [[ ${gh_rc} -ne 0 ]] || return 1
  if [[ ${err_text} =~ HTTP[[:space:]]+(404|422)($|[^0-9]) ]]; then
    if [[ ${err_text} =~ [Nn]ot[[:space:]]+[Ff]ound ||
      ${err_text} =~ [Uu]nprocessable ||
      (${err_text} =~ [Ss]tack && ${err_text} =~ [Nn]ot[[:space:]]+([Ee]nabled|[Ss]upported|[Aa]vailable)) ]]; then
      return 0
    fi
  fi
  return 1
}

# @function stacks_disabled_note
# Print what an operator has to do when the repository has no stacks.
# No shell invocation can turn the feature on, so the note is a HANDOFF line in the
# shape this stack's auth checks use: the three clicks a human owes. It names where to
# look (Settings -> General -> the stacked-pull-requests feature) and not the label of
# the switch, because no GitHub page in the cited set names that label and an invented
# one reads as a fact somebody verified.
# Globals:
#   REPO_SLUG
# Arguments:
#   None
# Outputs:
#   The HANDOFF lines on stderr
# Returns:
#   0
stacks_disabled_note() {
  err "HANDOFF: stacks are not enabled for ${REPO_SLUG:-this repository}"
  err "a human has to turn them on: github.com/${REPO_SLUG:-o/r}/settings -> General ->"
  err "  the stacked-pull-requests feature (GitHub names no switch label), then re-run"
}

# @function gh_api
# The one seam every GitHub call goes through.
# It builds `env -u GH_TOKEN -u GITHUB_TOKEN gh api` so the stale pair Coder injected
# at workspace start cannot shadow the gh auth store the refresh job keeps live, and it
# clears the response and the code before every call so a verb can never read a stale
# GH_RESPONSE after a failed exchange. gh's own stderr goes to a scratch file rather
# than the terminal on purpose: this CLI prints its own error: line naming the endpoint
# and the code, and a bare gh `error:` above it would be counted as a second failure by
# anything grepping the output. The file is read once, for the one thing the status text
# decides below, and never echoed.
# Globals:
#   GH_RESPONSE, GH_RC, STACKS_DISABLED, DRY_RUN
# Arguments:
#   $1 - the HTTP method; $2 - the API path; $3 - the --jq expression, or empty for
#     the raw body; $4 - the JSON request body, or empty for none
# Outputs:
#   The response on stdout (the caller captures nothing; it reads GH_RESPONSE)
# Returns:
#   0 on success, 2 for a refused endpoint, 3 when stacks are not enabled, the gh
#   exit code otherwise
gh_api() {
  local method="$1" endpoint="$2" jq_expr="${3:-}" json_body="${4:-}"
  local -a cmd
  local rc=0 err_file err_text=""

  GH_RESPONSE=""
  GH_RC=0

  assert_async_only "${endpoint}" || {
    GH_RC=2
    return 2
  }

  # A dry run still reads: an operator asking "what would this merge do" has to be
  # shown the real layer list, and a GET changes nothing. Only the writes are held back.
  if [ "${DRY_RUN}" -eq 1 ] && [ "${method}" != "GET" ]; then
    phase "would ${method} ${endpoint}"
    [ -n "${json_body}" ] && log "    body ${json_body}"
    return 0
  fi

  err_file="$(mktemp "${TMPDIR:-/tmp}/stack-prs-gh-err.XXXXXX")"
  cmd=(env -u GH_TOKEN -u GITHUB_TOKEN gh api --method "${method}" "${endpoint}")
  if [ -n "${jq_expr}" ]; then
    cmd+=(--jq "${jq_expr}")
  fi
  if [ -n "${json_body}" ]; then
    cmd+=(--input -)
    GH_RESPONSE="$(printf '%s' "${json_body}" | "${cmd[@]}" 2>"${err_file}")" || rc=$?
  else
    GH_RESPONSE="$("${cmd[@]}" 2>"${err_file}")" || rc=$?
  fi
  GH_RC="${rc}"
  err_text="$(cat "${err_file}" 2>/dev/null || true)"
  rm -f "${err_file}"

  # The missing repository setting is read from what gh api returned, not from its exit
  # code. Code 9 is the `gh stack` *extension*'s documented answer for a repository
  # without stacks
  # (https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands#exit-codes),
  # and this CLI's only transport is `gh api`, for which no page gives code 9 any
  # meaning -- so gh_api no longer branches on it, and an unexplained 9 falls through to
  # the ordinary failed call below.
  if stacks_disabled_shape "${endpoint}" "${rc}" "${err_text}"; then
    stacks_disabled_note
    # shellcheck disable=SC2034 # written here, read by main() in the entry script
    STACKS_DISABLED=1
    return 3
  fi
  if [ "${rc}" -ne 0 ]; then
    err "gh api ${method} ${endpoint} failed (exit ${rc})"
    return "${rc}"
  fi
  return 0
}

# @function body_pull_requests
# Print the create-stack body: the layer numbers, bottom of the stack first.
# The order is the contract the API reads as the chain, so it is preserved exactly as
# --prs gave it rather than sorted: the operator states which layer sits on which.
# The response key `pull_requests[]` is measured (see the header); the request-body
# field name of the same spelling is this CLI's own and stays unconfirmed by docs.
# Globals:
#   PR_NUMBERS
# Arguments:
#   None
# Outputs:
#   {"pull_requests":[N,N,...]} on stdout
# Returns:
#   0
body_pull_requests() {
  local joined="" n
  for n in ${PR_NUMBERS[@]+"${PR_NUMBERS[@]}"}; do
    joined="${joined:+${joined},}${n}"
  done
  printf '{"pull_requests":[%s]}' "${joined}"
}

# @function open_layer
# Take one layer out of draft.
# This CLI never sets a draft state: it stacks over pull requests the operator already
# opened, so each layer keeps whatever draft state it was opened with. `--open` is this
# CLI's own convention for clearing draft on the layers the operator says are ready, so
# nobody has to hand-edit six PRs after one create-stack. (Draft-by-default is the
# `gh stack link` behaviour, not a REST default: the REST create example shows
# draft:false.
# https://docs.github.com/en/pull-requests/reference/use-other-tools-with-stacked-pull-requests)
# Globals:
#   REPO_SLUG
# Arguments:
#   $1 - the pull request number to mark ready
# Outputs:
#   ok: / error: lines
# Returns:
#   0 when the layer is ready, 1 when the call failed
open_layer() {
  local pr="$1"
  if gh_api POST "/repos/${REPO_SLUG}/pulls/${pr}/ready" '' ''; then
    ok "PR ${pr} is ready for review"
    return 0
  fi
  fail_item "could not mark PR ${pr} ready (exit ${GH_RC})"
  return 1
}

# @function verb_create_stack
# Group existing pull requests into a new stack.
# Globals:
#   REPO_SLUG, PR_NUMBERS, OPEN_LAYERS
# Arguments:
#   None
# Outputs:
#   One phase line, the new stack number, and the summary contributions
# Returns:
#   0 on success, 1 on a failed call, 2 on missing arguments
verb_create_stack() {
  [ "${#PR_NUMBERS[@]}" -gt 0 ] || {
    err "create-stack needs --prs N,N,... with at least two layers"
    return 2
  }
  [ "${#PR_NUMBERS[@]}" -gt 1 ] ||
    warn "a one-PR stack is just a pull request; --prs named only ${PR_NUMBERS[0]}"
  local body
  body="$(body_pull_requests)"
  phase "create stack from PRs ${PR_NUMBERS[*]}"
  if ! gh_api POST "/repos/${REPO_SLUG}/stacks" '.number' "${body}"; then
    fail_item "create-stack failed (exit ${GH_RC})"
    return 1
  fi
  ok "stack ${GH_RESPONSE} created from ${#PR_NUMBERS[@]} layers"
  local pr
  if [ "${OPEN_LAYERS}" -eq 1 ]; then
    for pr in "${PR_NUMBERS[@]}"; do
      open_layer "${pr}" || return 1
    done
  else
    note "layers keep the draft state they were opened with; pass --open to mark them ready"
  fi
  return 0
}

# @function verb_add
# Attach one pull request to an existing stack.
# Globals:
#   REPO_SLUG, STACK_NUMBER, PR_NUMBER, OPEN_LAYERS
# Arguments:
#   None
# Outputs:
#   ok: / error: lines
# Returns:
#   0 on success, 1 on a failed call, 2 on missing arguments
verb_add() {
  is_number "${STACK_NUMBER}" || {
    err "add needs --stack N"
    return 2
  }
  is_number "${PR_NUMBER}" || {
    err "add needs --pr N"
    return 2
  }
  phase "add PR ${PR_NUMBER} to stack ${STACK_NUMBER}"
  if ! gh_api POST "/repos/${REPO_SLUG}/stacks/${STACK_NUMBER}/add" '' \
    "$(printf '{"pull_request":%s}' "${PR_NUMBER}")"; then
    fail_item "could not add PR ${PR_NUMBER} to stack ${STACK_NUMBER} (exit ${GH_RC})"
    return 1
  fi
  ok "PR ${PR_NUMBER} joined stack ${STACK_NUMBER}"
  [ "${OPEN_LAYERS}" -eq 1 ] && open_layer "${PR_NUMBER}"
  return 0
}

# @function verb_view
# Read a stack, or every stack in the repository.
# --raw prints the API JSON, which is what a reader reaches for when the rendered rows
# come back empty because GitHub changed a field name: the row expressions are this
# file's guess at the schema and the raw body is the ground truth.
# Globals:
#   REPO_SLUG, STACK_NUMBER, RAW_VIEW, JQ_STACK_LAYERS, JQ_STACK_LIST
# Arguments:
#   None
# Outputs:
#   The rendered rows, or the JSON body
# Returns:
#   0 on success, 1 on a failed call
verb_view() {
  local endpoint jq_expr
  if [ -n "${STACK_NUMBER}" ]; then
    is_number "${STACK_NUMBER}" || {
      err "--stack wants a number, got: ${STACK_NUMBER}"
      return 2
    }
    endpoint="/repos/${REPO_SLUG}/stacks/${STACK_NUMBER}"
    jq_expr="${JQ_STACK_LAYERS}"
    phase "stack ${STACK_NUMBER} in ${REPO_SLUG}"
  else
    endpoint="/repos/${REPO_SLUG}/stacks"
    jq_expr="${JQ_STACK_LIST}"
    phase "stacks in ${REPO_SLUG}"
  fi
  if [ "${RAW_VIEW}" -eq 1 ]; then
    jq_expr=""
  fi
  if ! gh_api GET "${endpoint}" "${jq_expr}" ''; then
    fail_item "could not read ${endpoint} (exit ${GH_RC})"
    return 1
  fi
  if [ -z "${GH_RESPONSE}" ]; then
    note "no stacks to show"
    return 0
  fi
  local row
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    log "${row}"
  done <<<"${GH_RESPONSE}"
  return 0
}

# @function verb_retarget
# Point every layer above the bottom at its parent's branch.
# A stack drifts the moment someone pushes a new branch under a layer or unstacks the
# middle of it, and a wrong base is invisible until the review lands on the wrong diff.
# What this does not do is rebase. GitHub retargets a stack onto a new base but "does
# not rebase" its branches, and until something rebases it, `push` and `submit` stop
# (https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands#retargeted-stacks);
# this CLI has no rebase verb, so a stack left in that state needs a rebase from the
# operator on each layer branch before it can move again.
# The bottom layer is left alone: its base is the trunk, which is the one base nobody
# retargets, and PATCHing it would silently merge an unmerged branch's work into main's
# review surface.
# Globals:
#   REPO_SLUG, STACK_NUMBER, TRUNK
# Arguments:
#   None
# Outputs:
#   One phase and one ok:/error: line per layer whose base moved
# Returns:
#   0 when every layer is on its parent, 1 when a call failed, 2 on missing arguments
verb_retarget() {
  is_number "${STACK_NUMBER}" || {
    err "retarget needs --stack N"
    return 2
  }
  phase "read stack ${STACK_NUMBER}"
  if ! gh_api GET "/repos/${REPO_SLUG}/stacks/${STACK_NUMBER}" "${JQ_STACK_LAYERS}" ''; then
    fail_item "could not read stack ${STACK_NUMBER} (exit ${GH_RC})"
    return 1
  fi
  local -a numbers=() heads=() bases=()
  local row n head_ref base_ref i parent
  while IFS=$'\t' read -r n head_ref base_ref _; do
    [ -n "${n}" ] || continue
    numbers+=("${n}")
    heads+=("${head_ref}")
    bases+=("${base_ref}")
  done <<<"${GH_RESPONSE}"

  [ "${#numbers[@]}" -gt 0 ] || {
    note "stack ${STACK_NUMBER} has no layers to retarget"
    return 0
  }
  for i in "${!numbers[@]}"; do
    if [ "${i}" -eq 0 ]; then
      if [ "${bases[$i]}" != "${TRUNK}" ]; then
        warn "bottom layer PR ${numbers[$i]} is based on ${bases[$i]}, not ${TRUNK}"
      else
        ok "bottom layer PR ${numbers[$i]} is based on ${TRUNK}"
      fi
      continue
    fi
    parent="${heads[$((i - 1))]}"
    if [ "${bases[$i]}" = "${parent}" ]; then
      ok "PR ${numbers[$i]} already based on ${parent}"
      continue
    fi
    phase "retarget PR ${numbers[$i]} from ${bases[$i]} to ${parent}"
    if ! gh_api PATCH "/repos/${REPO_SLUG}/pulls/${numbers[$i]}" '' \
      "$(printf '{"base":"%s"}' "${parent}")"; then
      fail_item "could not retarget PR ${numbers[$i]} onto ${parent} (exit ${GH_RC})"
      return 1
    fi
    ok "PR ${numbers[$i]} now based on ${parent}"
  done
  return 0
}

# @function verb_unstack
# Detach a pull request from its stack.
# Globals:
#   REPO_SLUG, STACK_NUMBER
# Arguments:
#   None
# Outputs:
#   ok: / error: lines
# Returns:
#   0 on success, 1 on a failed call, 2 on missing arguments
verb_unstack() {
  is_number "${STACK_NUMBER}" || {
    err "unstack needs --stack N"
    return 2
  }
  phase "unstack from stack ${STACK_NUMBER}"
  if ! gh_api POST "/repos/${REPO_SLUG}/stacks/${STACK_NUMBER}/unstack" '' ''; then
    fail_item "could not unstack from stack ${STACK_NUMBER} (exit ${GH_RC})"
    return 1
  fi
  ok "stack ${STACK_NUMBER} unstacked"
  return 0
}

# @function merge_layer_async
# Land one pull request through the asynchronous merge pair, and wait for its verdict.
# The PUT answers a job id, not a result; the result only exists at
# GET /pulls/{n}/merge-async/{id}. Waiting here is what lets the caller merge a stack
# bottom-up at all: landing layer two before layer one has actually landed is how a
# stack gets a layer merged on a base main does not have yet.
# Globals:
#   REPO_SLUG, MERGE_METHOD, POLL_INTERVAL, POLL_TIMEOUT, DRY_RUN
# Arguments:
#   $1 - the pull request number to merge
# Outputs:
#   phase / ok: / error: lines
# Returns:
#   0 when GitHub reports the layer landed, 1 otherwise
merge_layer_async() {
  local pr="$1" job_id status waited=0
  if [ "${DRY_RUN}" -eq 1 ]; then
    phase "would merge-async PR ${pr} with method ${MERGE_METHOD}"
    return 0
  fi
  # The method is sent on every call. GitHub documents that the merge-method flags are
  # ignored, with a warning, when the base is on a merge queue, so a merge queue on the
  # trunk decides the method and this value is advisory there.
  # https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands
  phase "merge-async PR ${pr} (${MERGE_METHOD})"
  if ! gh_api PUT "/repos/${REPO_SLUG}/pulls/${pr}/merge-async" '.id' \
    "$(printf '{"merge_method":"%s"}' "${MERGE_METHOD}")"; then
    fail_item "could not queue PR ${pr} for merge (exit ${GH_RC})"
    return 1
  fi
  job_id="${GH_RESPONSE}"
  [[ ${job_id} =~ ^[0-9A-Za-z-]+$ ]] || {
    fail_item "merge-async for PR ${pr} returned no job id"
    return 1
  }
  while :; do
    if ! gh_api GET "/repos/${REPO_SLUG}/pulls/${pr}/merge-async/${job_id}" '.status' ''; then
      fail_item "could not read the merge job for PR ${pr} (exit ${GH_RC})"
      return 1
    fi
    status="${GH_RESPONSE}"
    case "${status}" in
      success | completed | merged)
        ok "PR ${pr} merged"
        return 0
        ;;
      pending | queued | "") ;;
      *)
        fail_item "PR ${pr} merge job reported status: ${status}"
        return 1
        ;;
    esac
    waited=$((waited + POLL_INTERVAL))
    if [ "${waited}" -gt "${POLL_TIMEOUT}" ]; then
      fail_item "PR ${pr} merge job still pending after ${POLL_TIMEOUT}s (job ${job_id})"
      return 1
    fi
    sleep "${POLL_INTERVAL}"
  done
}

# @function verb_merge
# Land a stack bottom-up, or a single pull request.
# The layer order is the order the stack was created in, so the bottom lands first and
# each layer above it merges onto a base that already carries the one under it.
# Globals:
#   REPO_SLUG, STACK_NUMBER, PR_NUMBER
# Arguments:
#   None
# Outputs:
#   One phase and one ok:/error: line per layer
# Returns:
#   0 when everything landed, 1 when a layer failed, 2 on missing arguments
verb_merge() {
  if [ -z "${STACK_NUMBER}" ] && [ -z "${PR_NUMBER}" ]; then
    err "merge needs --stack N or --pr N"
    return 2
  fi
  if [ -n "${PR_NUMBER}" ] && [ -z "${STACK_NUMBER}" ]; then
    merge_layer_async "${PR_NUMBER}"
    return
  fi
  is_number "${STACK_NUMBER}" || {
    err "--stack wants a number, got: ${STACK_NUMBER}"
    return 2
  }
  phase "read stack ${STACK_NUMBER} for merge order"
  if ! gh_api GET "/repos/${REPO_SLUG}/stacks/${STACK_NUMBER}" "${JQ_STACK_LAYERS}" ''; then
    fail_item "could not read stack ${STACK_NUMBER} (exit ${GH_RC})"
    return 1
  fi
  local row n merged=0
  while IFS=$'\t' read -r n _ _ _; do
    [ -n "${n}" ] || continue
    merge_layer_async "${n}" || return 1
    merged=$((merged + 1))
  done <<<"${GH_RESPONSE}"
  [ "${merged}" -gt 0 ] || {
    note "stack ${STACK_NUMBER} has nothing to merge"
    return 0
  }
  ok "merged ${merged} layers of stack ${STACK_NUMBER}, bottom-up"
  return 0
}

# @function run_verb
# Run the verb the operator named.
# Globals:
#   VERB
# Arguments:
#   None
# Outputs:
#   Whatever the verb prints
# Returns:
#   the verb's own code: 0, 1, or 2 for a bad combination of flags
run_verb() {
  case "${VERB}" in
    create-stack) verb_create_stack ;;
    add) verb_add ;;
    view) verb_view ;;
    retarget) verb_retarget ;;
    unstack) verb_unstack ;;
    merge) verb_merge ;;
    *)
      err "unknown verb: ${VERB}"
      return 2
      ;;
  esac
}
