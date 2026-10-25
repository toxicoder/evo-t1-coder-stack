#!/usr/bin/env bash
#
# ## publish-pages-tree.sh - push a pre-assembled Pages tree onto origin/gh-pages.
#
# The deploy job assembles the site into _site/ (root index.html, .nojekyll and one
# alias directory) and this script publishes it from a throwaway git worktree. The
# worktree is the point: publishing replaces an entire branch tree, and checking
# gh-pages out inside the source checkout would move the branch the operator is
# standing on and mix its work with the published files.
#
# One alias is built per run, so every other alias directory has to survive from the
# previous tree. That is what the gh-pages .gitignore is for: it ignores everything at
# the top level except the alias directories, the root page and the Jekyll opt-out, so
# `git add -A` publishes this run's alias and leaves the others tracked.
#
# Safety:
# - Pushes only gh-pages, never main or a work branch, and never with --force.
# - Does not switch the source worktree off its branch.
# - Touches no Docker, Compose, restart policy or download-limit setting.
#
# Usage:
#   ./scripts/ci/publish-pages-tree.sh _site

set -euo pipefail

PAGES_WORKTREE=""

# @function assert_assembled_pages_tree
# Fail unless the assembled tree has both root files and at least one alias dir.
# "At least one" is any directory: the alias set is one name per branch and is not
# knowable here, so it must not be matched against a fixed list.
# Globals:
#   None
# Arguments:
#   $1 - assembled Pages directory
# Outputs:
#   One complaint line on stderr
# Returns:
#   0 when valid, 1 otherwise
assert_assembled_pages_tree() {
  local root="${1}"
  if [[ ! -d ${root} ]]; then
    echo "publish-pages-tree: missing assembled dir ${root}" >&2
    return 1
  fi
  if [[ ! -f "${root}/index.html" ]]; then
    echo "publish-pages-tree: assembled tree needs index.html" >&2
    return 1
  fi
  if [[ ! -f "${root}/.nojekyll" ]]; then
    echo "publish-pages-tree: assembled tree needs .nojekyll" >&2
    return 1
  fi
  if [[ -z "$(find "${root}" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]; then
    echo "publish-pages-tree: assembled tree needs at least one alias directory" >&2
    return 1
  fi
}

# @function assert_pages_tree_file_sizes
# Name every file at or over GitHub's blob limit and fail, before the push is tried.
# The exported search index is the file most likely to reach the limit.
# Globals:
#   PAGES_MAX_FILE_BYTES (read, optional; defaults to GitHub's 100 MiB)
# Arguments:
#   $1 - assembled Pages directory
# Outputs:
#   One line per oversize path on stderr
# Returns:
#   0 when every file is under the limit, 1 otherwise
assert_pages_tree_file_sizes() {
  local root="${1}"
  local max_bytes="${PAGES_MAX_FILE_BYTES:-104857600}"
  local too_big=0
  local f sz rel
  while IFS= read -r -d '' f; do
    sz="$(wc -c <"${f}" | tr -d '[:space:]')"
    if [[ ${sz} -ge ${max_bytes} ]]; then
      rel="${f#"${root}"/}"
      echo "publish-pages-tree: ${rel} is ${sz} bytes (GitHub limit ${max_bytes})" >&2
      too_big=1
    fi
  done < <(find "${root}" -type f -print0)
  if [[ ${too_big} -eq 1 ]]; then
    return 1
  fi
}

# @function configure_pages_git_identity
# Attribute the gh-pages commit to the Actions bot on the current repository.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
configure_pages_git_identity() {
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
}

# @function cleanup_pages_worktree
# Remove the Pages worktree when add_pages_worktree created one; the EXIT trap and
# any early return both land here, so it must tolerate being called twice.
# Globals:
#   PAGES_WORKTREE (read/write)
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
cleanup_pages_worktree() {
  local wt="${PAGES_WORKTREE:-}"
  PAGES_WORKTREE=""
  if [[ -z ${wt} ]]; then
    return 0
  fi
  git worktree remove --force "${wt}" >/dev/null 2>&1 || rm -rf "${wt}" || true
}

# @function add_pages_worktree
# Check origin/gh-pages out into a new worktree, orphaning the branch when the
# repository has no Pages branch yet.
# Globals:
#   PAGES_WORKTREE (write), RUNNER_TEMP, TMPDIR
# Arguments:
#   None
# Outputs:
#   Git fetch and worktree chatter
# Returns:
#   0 on success
add_pages_worktree() {
  local tmpdir tmp
  tmpdir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  mkdir -p "${tmpdir}"
  tmp="$(mktemp -d "${tmpdir}/evo-t1-pages.XXXXXX")"
  rmdir "${tmp}"
  PAGES_WORKTREE="${tmp}"

  git fetch origin gh-pages || true
  if git show-ref --verify --quiet refs/remotes/origin/gh-pages; then
    git worktree add -B gh-pages "${PAGES_WORKTREE}" origin/gh-pages
  else
    git worktree add --orphan -b gh-pages "${PAGES_WORKTREE}"
  fi
}

# @function publish_pages_tree
# Replace origin/gh-pages with the assembled tree through a throwaway worktree.
# Globals:
#   PAGES_WORKTREE, GITHUB_REF_NAME, GITHUB_SHA, RUNNER_TEMP, TMPDIR
# Arguments:
#   $1 - assembled Pages directory
# Outputs:
#   Git fetch, commit and push chatter
# Returns:
#   0 on success, 2 on a wrong argument count, non-zero on validation or git errors
publish_pages_tree() {
  if [[ $# -ne 1 ]]; then
    echo "Usage: publish-pages-tree.sh <assembled-dir>" >&2
    return 2
  fi
  local assembled repo_root
  assembled="$(cd "${1}" && pwd)"
  assert_assembled_pages_tree "${assembled}"
  assert_pages_tree_file_sizes "${assembled}"
  repo_root="$(git rev-parse --show-toplevel)"
  cd "${repo_root}"

  PAGES_WORKTREE=""
  trap cleanup_pages_worktree EXIT

  configure_pages_git_identity
  add_pages_worktree

  git -C "${PAGES_WORKTREE}" rm -rf --quiet . 2>/dev/null || true
  cp -a "${assembled}/." "${PAGES_WORKTREE}/"
  cat >"${PAGES_WORKTREE}/.gitignore" <<'GITIGNORE'
/*
!/*/
!/index.html
!/.nojekyll
GITIGNORE

  git -C "${PAGES_WORKTREE}" add -A
  # `/*` ignores the ignore file itself, so it needs adding explicitly or the next run
  # finds no rules and starts publishing whatever is lying in the worktree.
  git -C "${PAGES_WORKTREE}" add -f .gitignore
  git -C "${PAGES_WORKTREE}" commit \
    --allow-empty \
    -m "docs: publish ${GITHUB_REF_NAME:-unknown} from ${GITHUB_SHA:-unknown}"
  git -C "${PAGES_WORKTREE}" push origin HEAD:gh-pages
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  publish_pages_tree "$@"
fi
