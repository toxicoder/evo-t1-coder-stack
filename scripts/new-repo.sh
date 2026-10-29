#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## new-repo.sh -- Create a new GitHub repository from the project template, in one command.
#
# Four things happen here, in this order.
#
# 0. Fetch. The scaffold lives in its own repository, by default
#    `https://github.com/toxicoder/ezrepo`, and a shallow single-branch clone of it
#    becomes the render source for this run. The scaffold is deliberately not vendored
#    here: the template is a product with its own CI and its own release rhythm, and a
#    vendored copy drifts from the day it is committed. `--template-dir` skips the
#    network and renders a tree you already hold, which is also how the hermetic tests
#    drive this script. Nothing here pushes to the template repository.
#
# 1. Render. The fetched tree is copied into the output directory, the selected
#    language lanes are overlaid on top of it (a lane file replaces the core file
#    at the same path), each lane's `gitignore.fragment` is appended to
#    `.gitignore`, and every `__PROJECT_*__` token is replaced in file contents and
#    in file and directory names. A token left unsubstituted fails the render: a
#    repository that ships with its placeholders showing is worse than no template
#    at all, so this is a hard check and not a warning.
#
# 2. Publish. The rendered tree becomes a real repository: `git init` on `main`,
#    one initial commit, then the GitHub side. The GitHub side runs as a ladder of
#    independent steps (create, settings, topics, vulnerability alerts, push) and
#    each one reports `ok:` or `warning:` on its own. None of them is fatal. The
#    credential this stack has is a Coder External Auth GitHub App user-to-server
#    token, and an App can be granted or refused any one of these endpoints without
#    the others changing, so a CLI that aborts on the first refusal would refuse to
#    do the eight steps it was allowed to do.
#
# 3. Hand off. Nothing here creates a workspace. It prints the exact
#    `bazelisk run //scripts:new-workspace -- <url>` line instead, because that
#    script owns the dev-container probe and the template choice, and duplicating
#    that decision here would let the two of them disagree. With `--task` this also
#    offers a Coder Task for the new repository, and prints the command to type
#    when this environment cannot reach the Coder API.
#
# The token slot matters: git and gh consult `GH_TOKEN`/`GITHUB_TOKEN` before the
# `gh` stored login, so an expired pair from an old Coder token refresh shadows a
# working stored credential. Every call here therefore tries the environment first
# and, on a credential refusal, retries once with the pair unset and says so in a
# `warning:` naming the shadowed slot. Nothing here mints, reads or stores a
# credential, and no token value is ever put on a command line.
#
# Usage (Bazel is the entry point; every example below is the whole command):
#   bazelisk run //scripts:new-repo -- --dry-run demo-tool
#   bazelisk run //scripts:new-repo -- demo-tool --description "Does the thing" --lane python
#   bazelisk run //scripts:new-repo -- --private demo-tool --lane go --lane shell
#   bazelisk run //scripts:new-repo -- --no-push --out /tmp/try demo-tool
#   bazelisk run //scripts:new-repo -- --as-template demo-tool
#   bazelisk run //scripts:new-repo -- --task demo-tool
#   bazelisk run //scripts:new-repo -- --template-dir /tmp/ezrepo demo-tool
#   bazelisk run //scripts:new-repo -- --template-ref v1 --lane python demo-tool
#
# Options:
#   --dry-run             render, report, create nothing on GitHub
#   --out <dir>           parent directory for the rendered repository (default: cwd)
#   --no-push             render and commit locally only
#   --no-remote           skip every GitHub step (same as --no-push without the commit)
#   --private             create the repository private (default: public)
#   --as-template         mark the new repository as a template repository
#   --description <text>  one-line description (sanitized to a safe single line)
#   --owner <login>       GitHub owner (default: the authenticated account)
#   --holder <name>       copyright holder for LICENSE (default: the owner)
#   --lane <id>           add a language lane; repeatable (default: shell). The known
#                         ids are discovered from the fetched scaffold, so a lane that
#                         template repository adds needs no change here.
#   --lane none           render the neutral core with no lane at all
#   --template-url <url>  scaffold repository to clone
#                         (default: $EZREPO_URL, else https://github.com/toxicoder/ezrepo.git)
#   --template-ref <ref>  branch or tag to fetch (default: $EZREPO_REF, else main)
#   --template-dir <dir>  render this local tree and fetch nothing ($EZREPO_DIR)
#   --year <YYYY>         copyright year (default: this year)
#   --topic <t>           extra topic; repeatable
#   --task                also offer a Coder Task for the new repository
#   --task-template <n>   Coder template the task is created against
#   --branch <name>       default branch (default: main)
#   -h, --help            this text
#
# Positional: <name>  the repository name, and the directory it is rendered into.
#
# Exit codes: 0 when the render succeeded (a refused GitHub step is a warning),
# 1 on a render failure, a bad argument, or a scaffold that cannot be fetched.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SELF_DIR}/lib/common.sh"

# This CLI has no --json mode, so the machine-parseable routing that
# lib/common.sh sets up stays off and stdout stays human output.
unset JSON_MODE

# The token set is the whole contract between this script and the scaffold repository.
# A token listed here may be used by the template; a token the template uses but this
# list omits is left showing in the render and caught by the check below. The list is
# a ceiling, not an equality, so the template is free to use a subset of it.
readonly NEW_REPO_TOKENS=(
  __PROJECT_NAME__
  __PROJECT_SLUG__
  __PROJECT_MODULE__
  __PROJECT_DESCRIPTION__
  __PROJECT_OWNER__
  __PROJECT_LICENSE_HOLDER__
  __PROJECT_YEAR__
)

# Where the scaffold lives, and what of it belongs to the generator. The lane ids are
# discovered from <template>/.template-lanes/ at run time, so the template repository
# can ship a new lane without a change here; this list is what survives discovery when
# the operator asks for a lane the fetched tree does not have.
readonly NEW_REPO_LANE_DIR=".template-lanes"

# Reserved lane metadata: these names at a lane root are read by this script and
# stripped from the rendered tree, so a lane may never ship them as real files.
readonly NEW_REPO_LANE_META=(LANE.md gitignore.fragment)

# Generator-only paths that ride in the scaffold repository and are stripped from every
# render. `.template-lanes` is the overlay source this script reads, and `.self-check`
# is the scaffold's own conformance suite: it asserts things about the template, so a
# copy of it in a real project goes stale the moment that project diverges. `.git`
# would hand the new repository the template's history and origin remote.
readonly NEW_REPO_TEMPLATE_META=(.template-lanes .self-check .git)

REPO_NAME=""
OUT_DIR="${PWD}"
DESCRIPTION=""
OWNER=""
HOLDER=""
YEAR=""
PRIVATE=false
AS_TEMPLATE=false
NO_PUSH=false
NO_REMOTE=false
DRY_RUN=false
MAKE_TASK=false
TASK_TEMPLATE=""
BRANCH="main"
# The scaffold source. An explicit --template-dir wins over the URL, and the URL and
# ref fall back to the environment so a deployment can point at a mirror or a fork
# without a flag. A URL is left unquoted here on purpose: a leading/trailing space in
# an operator's env value is a broken config, not something to paper over.
TEMPLATE_URL="${EZREPO_URL:-https://github.com/toxicoder/ezrepo.git}"
TEMPLATE_REF="${EZREPO_REF:-main}"
TEMPLATE_DIR="${EZREPO_DIR:-}"
# Set when the scaffold was cloned for this run, so the trap knows what to clean up.
TEMPLATE_TMP=""
# The scaffold tree this run renders from, set by fetch_template.
TEMPLATE_SRC=""
# Where this render's scaffold came from, recorded in the new repository's first commit
# so a project can always say which template revision it started from.
TEMPLATE_PROVENANCE=""
# Lane ids discovered from the fetched scaffold by discover_lanes.
KNOWN_LANES=()
LANES=(shell)
# Tracks whether the operator named a lane. The default is shell because the core
# tests/run.sh dispatcher dies on "no test lane found" when the render carries none, so
# a no-flag render has to be a working repository, not a skeleton. The first explicit
# --lane replaces the default rather than joining it, which is what makes
# `--lane python --lane go` mean exactly those two.
LANES_DEFAULTED=true
EXTRA_TOPICS=()

# @function usage
# Print the option summary taken from this file's own header.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0, always
usage() {
  sed -n 's/^#//p' "${BASH_SOURCE[0]}" |
    sed -n '/^ Usage (/,/^ Exit codes:/p' |
    sed 's|^ ||'
}

# @function normalize
# Lowercase a value and fold characters a path or a package name cannot carry.
# Globals:
#   None
# Arguments:
#   $1 - the raw value
#   $2 - the fold character: "-" for the slug, "_" for the module identifier
# Outputs:
#   The normalized value on stdout
# Returns:
#   0, always
normalize() {
  local raw="${1:-}" fold="${2:--}"
  printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' |
    sed -E "s/[^a-z0-9]+/${fold}/g; s/^${fold}+//; s/${fold}+$//"
}

# @function sanitize_line
# Reduce caller-supplied prose to one line that sed can safely substitute.
# Globals:
#   None
# Arguments:
#   $1 - the raw text
# Outputs:
#   The sanitized text on stdout
# Returns:
#   0, always
sanitize_line() {
  # A free-text value arrives here before it is pasted into a double-quoted YAML scalar
  # (template.yml), a JSON string (package.json) and a TOML basic string
  # (pyproject.toml). Those three parsers agree on only two characters that would end
  # the string early or start an escape, so both go, along with every line break. The
  # repository name needs no such treatment: it is already restricted by the name
  # pattern in main.
  printf '%s' "${1:-}" | tr -d '\r\n"\\' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# @function escape_replacement
# Escape a replacement string for sed with a "|" delimiter.
# Globals:
#   None
# Arguments:
#   $1 - the replacement text
# Outputs:
#   The escaped text on stdout
# Returns:
#   0, always
escape_replacement() {
  printf '%s' "${1:-}" | sed -E 's/[\\&|]/\\&/g'
}

# @function discover_lanes
# List the lane ids the scaffold at a given path offers.
# Globals:
#   NEW_REPO_LANE_DIR
# Arguments:
#   $1 - scaffold source directory
# Outputs:
#   One lane id per line on stdout
# Returns:
#   0, always: a scaffold with no lane directory is a valid neutral core
discover_lanes() {
  local dir="$1/${NEW_REPO_LANE_DIR}" entry
  [ -d "${dir}" ] || return 0
  for entry in "${dir}"/*/; do
    # With nullglob off an empty directory leaves the pattern itself here, and the
    # -d test is what keeps that phantom out of the list.
    [ -d "${entry}" ] || continue
    basename "${entry%/}"
  done
  return 0
}

# @function validate_lane
# Decide whether a lane id is one the fetched scaffold actually ships.
# Globals:
#   KNOWN_LANES
# Arguments:
#   $1 - candidate lane id
# Outputs:
#   Nothing
# Returns:
#   0 when known or the literal "none", 1 otherwise
validate_lane() {
  local candidate="${1:-}" lane
  [ "${candidate}" = "none" ] && return 0
  # Lane ids become path components, so an id that escapes its directory is refused
  # on shape before it is looked up.
  [[ ${candidate} =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
  for lane in "${KNOWN_LANES[@]+"${KNOWN_LANES[@]}"}"; do
    [ "${lane}" = "${candidate}" ] && return 0
  done
  return 1
}

# @function fetch_template
# Put a usable scaffold tree on disk for this run.
# Globals:
#   TEMPLATE_DIR TEMPLATE_URL TEMPLATE_REF TEMPLATE_TMP TEMPLATE_SRC
# Arguments:
#   None
# Outputs:
#   phase:/ok:/note: lines, and TEMPLATE_SRC set to the tree to render from
# Returns:
#   0 when a scaffold with a manifest is on disk, 1 when the clone fails or the
#   tree has no template.yml
fetch_template() {
  local src sha
  if [ -n "${TEMPLATE_DIR}" ]; then
    [ -d "${TEMPLATE_DIR}" ] || {
      err "no scaffold at --template-dir: ${TEMPLATE_DIR}"
      return 1
    }
    src="$(cd "${TEMPLATE_DIR}" && pwd)"
    TEMPLATE_PROVENANCE="local tree ${src}"
    phase "using the local scaffold ${src}"
    note "a local tree is rendered as it stands: --template-ref has no effect"
  else
    phase "fetch ${TEMPLATE_URL} at ${TEMPLATE_REF}"
    TEMPLATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/new-repo-scaffold.XXXXXX")" || {
      err "cannot make a scratch directory for the scaffold"
      return 1
    }
    src="${TEMPLATE_TMP}/scaffold"
    # depth 1 because only this ref's tree is rendered, and single-branch so a
    # scaffold with a long history stays a one-second clone. GIT_TERMINAL_PROMPT=0
    # keeps a scaffold that turned private from hanging on a credential prompt
    # nobody can answer inside a workspace, and the empty credential helper stops
    # git consulting a helper that would prompt anyway.
    if ! GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --quiet --depth 1 \
      --single-branch --branch "${TEMPLATE_REF}" -- "${TEMPLATE_URL}" "${src}" \
      2>/dev/null; then
      err "cannot fetch the scaffold from ${TEMPLATE_URL} at ${TEMPLATE_REF}"
      note "check the network and the ref, or render a tree you already hold with --template-dir <dir>"
      return 1
    fi
    sha="$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    TEMPLATE_PROVENANCE="${TEMPLATE_URL}@${sha}"
    ok "fetched scaffold ${sha}"
  fi

  if [ ! -f "${src}/template.yml" ]; then
    err "no scaffold manifest at ${src}/template.yml"
    note "the scaffold repository owns template.yml; pick a ref that has it"
    return 1
  fi

  TEMPLATE_SRC="${src}"
  return 0
}

# @function cleanup_template
# Remove the scratch clone this run made, if any.
# Globals:
#   TEMPLATE_TMP
# Arguments:
#   None
# Outputs:
#   Nothing
# Returns:
#   0, always
cleanup_template() {
  [ -n "${TEMPLATE_TMP}" ] && [ -d "${TEMPLATE_TMP}" ] &&
    rm -r -- "${TEMPLATE_TMP}" 2>/dev/null
  return 0
}

# @function substitute_tokens
# Replace every render token in file contents, then in file and directory names.
# Two spellings of a token are honoured: the canonical __NAME__ and the markdown
# alias **NAME**, which is what a markdown formatter leaves behind when it reads the
# canonical form as emphasis. Without the alias a token that survived "make fmt" in a
# .md file would ship to the new repository verbatim.
# Globals:
#   NEW_REPO_TOKENS
# Arguments:
#   $1 - rendered tree root
#   $2..$15 - the seven token values, in NEW_REPO_TOKENS order
# Outputs:
#   Nothing
# Returns:
#   0 always; a file that cannot be rewritten is reported by the caller's check
substitute_tokens() {
  local root="$1"
  shift
  local -a values=("$@")
  local -a sed_args=() name_args=()
  local i token bare value escaped file
  for i in "${!NEW_REPO_TOKENS[@]}"; do
    token="${NEW_REPO_TOKENS[$i]}"
    bare="${token#__}"
    bare="${bare%__}"
    escaped="$(escape_replacement "${values[$i]:-}")"
    sed_args+=(-e "s|${token}|${escaped}|g")
    sed_args+=(-e "s|\\*\\*${bare}\\*\\*|${escaped}|g")
    # The same shape assert_no_tokens greps for, so a path the check would flag is a
    # path this pass renames. A suffix-anchored pattern would leave `__PROJECT_X__.md`
    # behind and the render would fail on its own output.
    name_args+=(-o -name "*${token}*")
  done

  while IFS= read -r -d '' file; do
    grep -qF -- "__PROJECT_" "${file}" 2>/dev/null ||
      grep -qE -- '\*\*PROJECT_[A-Z_]+\*\*' "${file}" 2>/dev/null || continue
    sed -i "${sed_args[@]}" "${file}"
  done < <(find "${root}" -type f -print0)

  # Deepest paths first, so a token in a directory name is still intact when its
  # children are renamed and the parent rename still finds it afterwards.
  while IFS= read -r -d '' file; do
    mv -- "${file}" "$(dirname "${file}")/$(basename "${file}" |
      sed "${sed_args[@]}")"
  done < <(find "${root}" -depth \( "${name_args[@]:1}" \) -print0)
}

# @function append_ignore_fragments
# Append each selected lane's gitignore.fragment to the rendered .gitignore.
# Globals:
#   None
# Arguments:
#   $1 - template source directory
#   $2 - rendered tree root
#   $3.. - the selected lane ids
# Outputs:
#   One note: line per appended fragment
# Returns:
#   0, always
append_ignore_fragments() {
  local src="$1" dest="$2"
  shift 2
  local lane fragment
  for lane in "$@"; do
    fragment="${src}/${NEW_REPO_LANE_DIR}/${lane}/gitignore.fragment"
    [ -f "${fragment}" ] || continue
    printf '\n# --- lane: %s ---\n' "${lane}" >>"${dest}/.gitignore"
    cat "${fragment}" >>"${dest}/.gitignore"
    note "appended ${lane} gitignore.fragment"
  done
}

# @function overlay_lanes
# Copy each selected lane over the rendered tree and strip its reserved metadata.
# Globals:
#   NEW_REPO_LANE_META
# Arguments:
#   $1 - template source directory
#   $2 - rendered tree root
#   $3.. - the selected lane ids
# Outputs:
#   One ok: line per lane, one error: line per failure
# Returns:
#   1 when a named lane has no directory or cannot be copied
overlay_lanes() {
  local src="$1" dest="$2"
  shift 2
  local lane root meta
  for lane in "$@"; do
    root="${src}/${NEW_REPO_LANE_DIR}/${lane}"
    if [ ! -d "${root}" ]; then
      fail_item "lane has no directory: ${lane} (expected ${root})"
      return 1
    fi
    phase "overlay lane ${lane}"
    # -L rather than -a: a source tree reached through Bazel runfiles is a forest of
    # symlinks, and a preserved symlink makes the "copy" an alias of the source, so the
    # token substitution would edit the fixture instead of the render. It also breaks
    # discovery, because tests/run.sh finds a lane with `find -type f`, which never
    # matches a symlink. Mode and timestamps still come along, which is what -a bought.
    cp -RL --preserve=mode,timestamps "${root}/." "${dest}/" || {
      fail_item "cannot copy lane ${lane} to ${dest}"
      return 1
    }
    for meta in "${NEW_REPO_LANE_META[@]}"; do
      rm -f "${dest}/${meta}"
    done
    ok "lane ${lane}"
  done
  return 0
}

# @function rename_env_template
# Write the template's env twin out under its conventional dotted name.
# Globals:
#   None
# Arguments:
#   $1 - rendered tree root
# Outputs:
#   One note: line when the twin was renamed
# Returns:
#   0, always: an absent twin is the lane owner's business, not a render failure
rename_env_template() {
  local dest="$1"
  [ -f "${dest}/env.example" ] || return 0
  # The scaffold ships this file undotted, so its own tree never holds a dotted
  # dotenv name. The Grok seed denies the populated dotenv shapes and names the
  # secret-free template twins in its allow rules; the scaffold keeps out of that
  # question by spelling the twin without the dot. The dotted name is what a
  # rendered project should carry, and only this rename introduces it.
  mv -- "${dest}/env.example" "${dest}/.env.example"
  note "wrote env.example as .env.example"
}

# @function assert_no_tokens
# Fail when any render token survived into the rendered tree or its paths.
# Globals:
#   None
# Arguments:
#   $1 - rendered tree root
# Outputs:
#   One error: line naming up to ten surviving locations
# Returns:
#   0 when clean, 1 when a token is still showing
assert_no_tokens() {
  local root="$1" hits
  local -a token_args=() name_args=()
  local token bare
  # Match the seven tokens the renderer actually substitutes, by exact string. Grepping
  # the `__PROJECT_` prefix instead would reject the scaffold's own prose, which
  # spells the prefix to explain the mechanism. A typo'd token is a different bug and
  # is caught by the scaffold's own conformance suite (.self-check in that repository).
  # The markdown alias is checked too: it is the spelling a formatter leaves behind, and
  # a render that ships it publishes the placeholder into the new repository's README.
  for token in "${NEW_REPO_TOKENS[@]}"; do
    bare="${token#__}"
    bare="${bare%__}"
    token_args+=(-e "${token}" -e "\*\*${bare}\*\*")
    name_args+=(-o -name "*${token}*")
  done
  hits="$({
    grep -rl "${token_args[@]}" "${root}" 2>/dev/null
    find "${root}" \( "${name_args[@]:1}" \)
  } | sed "s|^${root}/||" | sort -u | head -10)"
  if [ -n "${hits}" ]; then
    fail_item "unsubstituted token in: $(printf '%s' "${hits}" | tr '\n' ' ')"
    return 1
  fi
  return 0
}

# @function render_tree
# Build the rendered repository from the template, the lanes, and the token values.
# Globals:
#   REPO_NAME DESCRIPTION OWNER HOLDER YEAR LANES
# Arguments:
#   $1 - template source directory
#   $2 - destination directory (must not exist)
# Outputs:
#   Phases and per-step ok:/warning: lines
# Returns:
#   0 on success, 1 on a failed copy, overlay, substitution or token check
render_tree() {
  local src="$1" dest="$2"
  local slug module
  slug="$(normalize "${REPO_NAME}" -)"
  module="$(normalize "${REPO_NAME}" _)"

  phase "copy ${src} -> ${dest}"
  mkdir -p "${dest%/*}" 2>/dev/null || true
  # -L rather than -a: a scaffold reached through Bazel runfiles is a forest of
  # symlinks, and a preserved symlink makes this "copy" an alias of the template, so the
  # token substitution below would edit the template instead of the render. Mode and
  # timestamps still come along, which is what -a was buying.
  cp -RL --preserve=mode,timestamps "${src}" "${dest}" || {
    fail_item "cannot copy ${src} to ${dest}"
    return 1
  }

  # Paths the scaffold owns and a rendered project must not carry, stripped before
  # anything else so a lane may still add a file of the same name if a project
  # genuinely wants one.
  local meta stripped=""
  for meta in "${NEW_REPO_TEMPLATE_META[@]}"; do
    if [ -e "${dest}/${meta}" ]; then
      rm -r -- "${dest:?}/${meta:?}"
      stripped="${stripped} ${meta}"
    fi
  done
  [ -z "${stripped}" ] || note "stripped scaffold-only paths:${stripped}"

  if [ "${#LANES[@]}" -gt 0 ]; then
    overlay_lanes "${src}" "${dest}" "${LANES[@]}" || return 1
    append_ignore_fragments "${src}" "${dest}" "${LANES[@]}"
  else
    note "no lane selected: rendered the language-neutral core"
    note "the neutral core ships no test lane; make test will ask for one until you add a lane"
  fi

  rename_env_template "${dest}"

  phase "substitute render tokens"
  substitute_tokens "${dest}" \
    "${REPO_NAME}" "${slug}" "${module}" \
    "$(sanitize_line "${DESCRIPTION}")" "$(sanitize_line "${OWNER}")" \
    "$(sanitize_line "${HOLDER}")" "${YEAR}"

  assert_no_tokens "${dest}" || return 1
  ok "rendered ${#LANES[@]} lane(s) into ${dest}"
  return 0
}

# @function gh_api
# Run one GitHub API call, falling back to the stored login when the env pair is stale.
# Globals:
#   GH_TOKEN, GITHUB_TOKEN (consulted by gh, cleared on the retry only)
# Arguments:
#   $@ - the gh api arguments, starting with the METHOD or the path
# Outputs:
#   The response of the ONE attempt whose status is returned, on stdout. A refused
#   attempt keeps its stdout and stderr to itself: gh puts an error body on stdout,
#   and `log` (so `warn`) writes to stdout, so a caller that captured both would find
#   commentary and an error body where it asked for a value - an OWNER of two lines
#   breaks every later repos/${OWNER}/... path. The ladder's own line therefore goes to
#   stderr, the way `err` does. gh's error text for the returned attempt is stderr too.
# Returns:
#   gh's exit status
gh_api() {
  local status=0 response=""
  response="$(gh api "$@" 2>/dev/null)" || status=$?
  if [ "${status}" -eq 0 ]; then
    if [ -n "${response}" ]; then printf '%s\n' "${response}"; fi
    return 0
  fi
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    warn "credential refused with the environment token pair; retrying with GH_TOKEN/GITHUB_TOKEN unset (the pair shadows the gh stored login)" >&2
    status=0
    response=""
    response="$(GH_TOKEN="" GITHUB_TOKEN="" gh api "$@")" || status=$?
    if [ -n "${response}" ]; then printf '%s\n' "${response}"; fi
    return "${status}"
  fi
  status=0
  response=""
  response="$(gh api "$@")" || status=$?
  if [ -n "${response}" ]; then printf '%s\n' "${response}"; fi
  return "${status}"
}

# @function permission_hint
# Translate a refused endpoint into the App permission the operator needs.
# Globals:
#   None
# Arguments:
#   $1 - the endpoint family that was refused
# Outputs:
#   One or two error: lines on stderr
# Returns:
#   0, always
permission_hint() {
  local what="${1:-github}"
  case "${what}" in
    create)
      err "hint: creating a repository needs the Coder GitHub App to hold Administration:write (or Repository creation:write) and your approval of it; grant it, then re-run the workspace GitHub reauth"
      ;;
    settings)
      err "hint: repository settings, topics and alerts are Administration:write on the Coder GitHub App"
      ;;
    alerts)
      err "hint: dependency alerts need Administration:write; Dependabot secrets are commonly refused for an App and are left to you"
      ;;
    *)
      err "hint: the App is missing a permission for ${what}; check it at the Coder GitHub App installation"
      ;;
  esac
  err "hint: coder external-auth access-token github re-mints this workspace's credential"
  return 0
}

# @function create_remote
# Create the empty remote repository, or report the route to create it by hand.
# Globals:
#   OWNER REPO_NAME DESCRIPTION PRIVATE DRY_RUN
# Arguments:
#   None
# Outputs:
#   A phase line, ok:/warning:, and on refusal the curl-free manual route
# Returns:
#   0 when created or when already present, 1 when the create was refused
create_remote() {
  section "Remote"
  local -a body=(-X POST /user/repos
    -f "name=${REPO_NAME}"
    -f "description=${DESCRIPTION}"
    -F "private=${PRIVATE}"
    -F "has_issues=true"
    -F "auto_init=false")
  if [ "${DRY_RUN}" = true ]; then
    log "would run: gh api -X POST /user/repos name=${REPO_NAME} private=${PRIVATE}"
    return 0
  fi
  phase "create ${OWNER}/${REPO_NAME}"
  if gh_api "${body[@]}" >/dev/null; then
    ok "created ${OWNER}/${REPO_NAME}"
    return 0
  fi
  if gh_api "repos/${OWNER}/${REPO_NAME}" --jq '.full_name' >/dev/null 2>&1; then
    warn "${OWNER}/${REPO_NAME} already exists; continuing against it"
    return 0
  fi
  fail_item "create ${OWNER}/${REPO_NAME}"
  permission_hint create
  log "manual route: gh repo create ${OWNER}/${REPO_NAME} --public --description \"${DESCRIPTION}\""
  return 1
}

# @function apply_settings
# Apply the repository settings a fresh project should never have to remember.
# Globals:
#   OWNER REPO_NAME AS_TEMPLATE DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:/warning: per step
# Returns:
#   0, always: every step here is advisory
apply_settings() {
  section "Settings"
  local -a body=(-X PATCH "repos/${OWNER}/${REPO_NAME}"
    -F "has_issues=true"
    -F "has_wiki=false"
    -F "delete_branch_on_merge=true"
    -F "auto_delete_head_branches=true"
    -F "allow_merge_commit=false"
    -F "allow_squash_merge=true"
    -F "allow_rebase_merge=true")
  if [ "${AS_TEMPLATE}" = true ]; then
    body+=(-F "is_template=true")
  fi
  if [ "${DRY_RUN}" = true ]; then
    log "would run: gh api -X PATCH repos/${OWNER}/${REPO_NAME} delete_branch_on_merge=true is_template=${AS_TEMPLATE}"
    return 0
  fi
  phase "branch hygiene for ${OWNER}/${REPO_NAME}"
  if gh_api "${body[@]}" >/dev/null 2>&1; then
    ok "settings applied"
  else
    warn "settings refused; branch hygiene is left at GitHub's defaults"
    permission_hint settings
  fi
  return 0
}

# @function apply_topics
# Tag the repository with the base topics and one per selected lane.
# Globals:
#   OWNER REPO_NAME LANES EXTRA_TOPICS AS_TEMPLATE DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:/warning:
# Returns:
#   0, always
apply_topics() {
  section "Topics"
  local -a topics=(coder evo-t1)
  local lane extra
  for lane in "${LANES[@]+"${LANES[@]}"}"; do
    topics+=("${lane}")
  done
  for extra in "${EXTRA_TOPICS[@]+"${EXTRA_TOPICS[@]}"}"; do
    topics+=("${extra}")
  done
  [ "${AS_TEMPLATE}" = true ] && topics+=(template starter)

  local -a body=(-X PUT "repos/${OWNER}/${REPO_NAME}/topics"
    -H "Accept: application/vnd.github+json")
  for extra in "${topics[@]}"; do
    body+=(-F "names[]=${extra}")
  done
  if [ "${DRY_RUN}" = true ]; then
    log "would run: gh api -X PUT repos/${OWNER}/${REPO_NAME}/topics names[]=${topics[*]}"
    return 0
  fi
  phase "topics: ${topics[*]}"
  if gh_api "${body[@]}" >/dev/null 2>&1; then
    ok "topics set (${#topics[@]})"
  else
    warn "topics refused; the repository stays undiscoverable"
    permission_hint settings
  fi
  return 0
}

# @function enable_vulnerability_alerts
# Turn on dependency vulnerability alerts, the cheapest supply-chain signal there is.
# Globals:
#   OWNER REPO_NAME DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:/warning:
# Returns:
#   0, always
enable_vulnerability_alerts() {
  section "Alerts"
  if [ "${DRY_RUN}" = true ]; then
    log "would run: gh api -X PUT repos/${OWNER}/${REPO_NAME}/vulnerability-alerts"
    return 0
  fi
  phase "dependency vulnerability alerts"
  if gh_api -X PUT "repos/${OWNER}/${REPO_NAME}/vulnerability-alerts" >/dev/null 2>&1; then
    ok "vulnerability alerts on"
  else
    warn "vulnerability alerts refused (common for an App); enable them in Settings > Code security"
    permission_hint alerts
  fi
  return 0
}

# @function init_and_push
# Turn the rendered tree into a committed repository on the default branch and push it.
# Globals:
#   REPO_NAME OWNER BRANCH PRIVATE DRY_RUN NO_REMOTE
# Arguments:
#   $1 - rendered tree root
# Outputs:
#   Phases and per-step ok:/warning: lines
# Returns:
#   0 when committed (and pushed unless pushing was skipped), 1 on a git or push failure
init_and_push() {
  local dest="$1"
  local remote_url="https://github.com/${OWNER}/${REPO_NAME}.git"
  require_tool git || die "git is missing; install it before rendering a repository"

  section "Git"
  if [ "${DRY_RUN}" = true ]; then
    log "would run: git init -b ${BRANCH} && git add -A && git commit && git push -u origin ${BRANCH} to ${remote_url}"
    return 0
  fi

  phase "init ${BRANCH} in ${dest}"
  git -C "${dest}" init -q -b "${BRANCH}" || {
    fail_item "git init"
    return 1
  }
  # An identity is required to commit, and a machine that has never committed
  # should not fail here for a reason unrelated to what the operator asked for.
  git -C "${dest}" config user.email >/dev/null 2>&1 ||
    git -C "${dest}" config user.email "${OWNER}@users.noreply.github.com"
  git -C "${dest}" config user.name >/dev/null 2>&1 ||
    git -C "${dest}" config user.name "${OWNER}"
  git -C "${dest}" add -A || {
    fail_item "git add"
    return 1
  }
  if ! git -C "${dest}" commit -q \
    -m "chore: bootstrap ${REPO_NAME} from the project template" \
    -m "- Scaffold: ${TEMPLATE_PROVENANCE}." \
    -m "- Lanes: ${LANES[*]:-none}." \
    -m "- The initial commit carries the full quality gate so the first PR has something to run against."; then
    fail_item "git commit"
    return 1
  fi
  ok "committed on ${BRANCH}"

  if [ "${NO_REMOTE}" = true ] || [ "${NO_PUSH}" = true ]; then
    note "push skipped by request; the repository is local at ${dest}"
    return 0
  fi

  phase "push ${remote_url}"
  git -C "${dest}" remote add origin "${remote_url}" 2>/dev/null ||
    git -C "${dest}" remote set-url origin "${remote_url}"
  if git -C "${dest}" push -q -u origin "${BRANCH}" >/dev/null 2>&1; then
    ok "pushed ${BRANCH}"
    return 0
  fi
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] &&
    env -u GH_TOKEN -u GITHUB_TOKEN git -C "${dest}" push -q -u origin "${BRANCH}" >/dev/null 2>&1; then
    ok "pushed ${BRANCH} with the stored login"
    return 0
  fi
  fail_item "push ${remote_url}"
  permission_hint create
  log "manual route: cd ${dest} && git remote add origin ${remote_url} && git push -u origin ${BRANCH}"
  return 1
}

# @function create_coder_task
# Offer a Coder Task that bootstraps the new repository, or print the command to type.
# Globals:
#   REPO_NAME OWNER MAKE_TASK TASK_TEMPLATE DRY_RUN
# Arguments:
#   None
# Outputs:
#   ok:/warning:/note:, and the coder command line when it cannot run
# Returns:
#   0, always: a task is a convenience and its absence is never a failure
create_coder_task() {
  [ "${MAKE_TASK}" = true ] || return 0
  section "Coder Task"
  local input="Bootstrap ${REPO_NAME}: read AGENTS.md, run make doctor and make test, then replace the placeholder README description and record the first architecture decision in docs/adr/."
  local -a cmd=(coder task create --name "${REPO_NAME}-bootstrap")
  [ -n "${TASK_TEMPLATE}" ] && cmd+=(--template "${TASK_TEMPLATE}")
  cmd+=("${input}")

  if [ "${DRY_RUN}" = true ]; then
    log "would run: ${cmd[*]}"
    return 0
  fi
  if ! has_tool coder; then
    warn "coder CLI is not on PATH here; a workspace shell has it"
    log "manual route: ${cmd[*]}"
    return 0
  fi
  phase "create task for ${OWNER}/${REPO_NAME}"
  if "${cmd[@]}" >/dev/null 2>&1; then
    ok "created Coder task ${REPO_NAME}-bootstrap"
  else
    warn "the Coder task could not be created from here (typically an unauthenticated CLI on this host)"
    log "manual route: ${cmd[*]}"
  fi
  return 0
}

# @function main
# Fetch the scaffold, parse arguments, render, publish, and close with a summary.
# Globals:
#   every configuration variable in this file
# Arguments:
#   $@ - the operator's command line
# Outputs:
#   The full section/phase/summary transcript
# Returns:
#   0 on success, 1 on a render or publish failure, a bad argument, or a bad ref
main() {
  local template dest
  trap cleanup_template EXIT
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --out)
        [ $# -ge 2 ] || die "--out needs a directory"
        [ -n "$2" ] || die "--out needs a directory"
        OUT_DIR="$2"
        shift
        ;;
      --no-push) NO_PUSH=true ;;
      --no-remote)
        NO_REMOTE=true
        NO_PUSH=true
        ;;
      --private) PRIVATE=true ;;
      --as-template) AS_TEMPLATE=true ;;
      --description)
        [ $# -ge 2 ] || die "--description needs text"
        DESCRIPTION="$2"
        shift
        ;;
      --owner)
        [ $# -ge 2 ] || die "--owner needs a login"
        OWNER="$2"
        shift
        ;;
      --holder)
        [ $# -ge 2 ] || die "--holder needs a name"
        HOLDER="$2"
        shift
        ;;
      --year)
        [ $# -ge 2 ] || die "--year needs a four-digit year"
        YEAR="$2"
        shift
        ;;
      --lane)
        [ $# -ge 2 ] || die "--lane needs a lane id"
        # Not validated here: the lane set belongs to the scaffold, and the scaffold is
        # only known a few lines after this loop. A typo is caught against the
        # discovered set, which is the only list that cannot drift.
        if [ "${LANES_DEFAULTED}" = true ]; then
          LANES=()
          LANES_DEFAULTED=false
        fi
        if [ "$2" = "none" ]; then
          # The sentinel is a reset, not an append, and the neutral core ships no test
          # lane, so say both out loud rather than let `make test` be the one to find it.
          if [ "${#LANES[@]}" -gt 0 ]; then
            note "--lane none clears the lanes named so far (${LANES[*]})"
          fi
          LANES=()
          LANES_DEFAULTED=true
        else
          LANES+=("$2")
        fi
        shift
        ;;
      --topic)
        [ $# -ge 2 ] || die "--topic needs a topic"
        EXTRA_TOPICS+=("$2")
        shift
        ;;
      --template-url)
        [ $# -ge 2 ] || die "--template-url needs a git URL"
        [ -n "$2" ] || die "--template-url needs a git URL"
        TEMPLATE_URL="$2"
        shift
        ;;
      --template-ref)
        [ $# -ge 2 ] || die "--template-ref needs a branch or tag"
        [ -n "$2" ] || die "--template-ref needs a branch or tag"
        TEMPLATE_REF="$2"
        shift
        ;;
      --template-dir)
        [ $# -ge 2 ] || die "--template-dir needs a directory"
        [ -n "$2" ] || die "--template-dir needs a directory"
        TEMPLATE_DIR="$2"
        shift
        ;;
      --task) MAKE_TASK=true ;;
      --task-template)
        [ $# -ge 2 ] || die "--task-template needs a name"
        TASK_TEMPLATE="$2"
        shift
        ;;
      --branch)
        [ $# -ge 2 ] || die "--branch needs a name"
        BRANCH="$2"
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*) die "unknown option: $1 (try --help)" ;;
      *)
        [ -z "${REPO_NAME}" ] || die "one repository name only (got ${REPO_NAME} and $1)"
        REPO_NAME="$1"
        ;;
    esac
    shift
  done
  [ "$#" -eq 0 ] || die "unexpected argument: $1"
  [ -n "${REPO_NAME}" ] || die "a repository name is required (try --help)"

  [[ ${REPO_NAME} =~ ^[A-Za-z0-9._-]{1,100}$ ]] ||
    die "invalid repository name: ${REPO_NAME} (letters, digits, dot, dash, underscore)"

  fetch_template || die "cannot obtain the scaffold"
  template="${TEMPLATE_SRC}"

  local requested
  KNOWN_LANES=()
  while IFS= read -r requested; do
    [ -n "${requested}" ] && KNOWN_LANES+=("${requested}")
  done < <(discover_lanes "${template}")
  for requested in "${LANES[@]+"${LANES[@]}"}"; do
    validate_lane "${requested}" ||
      die "unknown lane: ${requested} (the scaffold offers: ${KNOWN_LANES[*]:-no lanes}, or none)"
  done

  if [ -z "${OWNER}" ]; then
    OWNER="$(gh_api user --jq .login 2>/dev/null || true)"
    [ -n "${OWNER}" ] || die "cannot determine the GitHub owner; pass --owner"
  fi
  [ -n "${HOLDER}" ] || HOLDER="${OWNER}"
  [ -n "${YEAR}" ] || YEAR="$(date +%Y)"
  [ -n "${DESCRIPTION}" ] || DESCRIPTION="${REPO_NAME}: a new project built from the ezrepo scaffold."

  section "Plan"
  log "name: ${REPO_NAME}"
  log "owner: ${OWNER}"
  log "lanes: ${LANES[*]:-none}"
  log "scaffold lanes available: ${KNOWN_LANES[*]:-none}"
  log "visibility: $([ "${PRIVATE}" = true ] && echo private || echo public)"
  log "scaffold: $([ -n "${TEMPLATE_DIR}" ] && echo "local ${TEMPLATE_DIR}" ||
    echo "${TEMPLATE_URL}@${TEMPLATE_REF}")"

  local dest="${OUT_DIR%/}/${REPO_NAME}"
  if [ -e "${dest}" ]; then
    die "refusing to render over an existing path: ${dest} (pass --out or remove it)"
  fi

  render_tree "${template}" "${dest}" || {
    summary
    return 1
  }
  if [ "${NO_REMOTE}" != true ]; then
    create_remote || {
      summary
      return 1
    }
  fi
  init_and_push "${dest}" || {
    summary
    return 1
  }
  if [ "${NO_REMOTE}" != true ]; then
    apply_settings
    apply_topics
    enable_vulnerability_alerts
  fi
  create_coder_task

  section "Next"
  log "local: ${dest}"
  log "remote: https://github.com/${OWNER}/${REPO_NAME}.git"
  summary "bazelisk run //scripts:new-workspace -- https://github.com/${OWNER}/${REPO_NAME}.git"
  return 0
}

main "$@"
