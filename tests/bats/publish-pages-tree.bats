#!/usr/bin/env bats
#
# ## publish-pages-tree.bats — hermetic coverage for scripts/ci/publish-pages-tree.sh.
#
# The publish contract pinned here: an assembled tree is refused unless it carries
# index.html, .nojekyll and at least one alias directory — and "at least one" is any
# directory, because the alias set is one-name-per-branch and no fixed list may be
# baked in. Oversize blobs are named before the push (GitHub rejects them at
# 100 MiB), the identity is the Actions bot, and the gh-pages .gitignore keeps every
# top-level alias dir with `!/*/` so an alias built by an earlier run survives.
#
# Usage: bazelisk test //tests:bats_publish_pages_tree_test   (from any cwd)
# Safety: builds throwaway repos under BATS_TEST_TMPDIR against a local bare
# origin. No network, no Docker, and the real checkout is never the target.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/ci/publish-pages-tree.sh"
  [[ -f "${SCRIPT}" ]] || skip "publish-pages-tree.sh is not reachable from ${REPO_ROOT}"
  # A private HOME keeps an operator's ~/.gitconfig (and any ~-relative include it
  # carries) out of a suite that creates repositories of its own.
  export HOME="${BATS_TEST_TMPDIR}"
  mkdir -p "${HOME}"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
}

# assembled_tree <dir> <alias...> — a minimal tree the publisher should accept.
assembled_tree() {
  local dir="$1"
  shift
  mkdir -p "${dir}"
  printf '<!doctype html><p>root</p>\n' >"${dir}/index.html"
  : >"${dir}/.nojekyll"
  local alias
  for alias in "$@"; do
    mkdir -p "${dir}/${alias}/_next"
    printf '<html></html>\n' >"${dir}/${alias}/index.html"
    printf 'x\n' >"${dir}/${alias}/_next/app.js"
  done
}

# seeded_origin <origin> <clone> — a bare origin carrying main, cloned for the publisher
# to stand in. The publisher only ever pushes gh-pages, so main must exist already.
seeded_origin() {
  local origin="$1" clone="$2"
  git init -q --bare "${origin}"
  git clone -q "${origin}" "${clone}"
  (
    cd "${clone}" &&
      git checkout -q -b main &&
      printf '# x\n' >README.md &&
      git add README.md &&
      git commit -qm "seed" &&
      git push -q origin main
  )
}

# load_publish_unit — publish_pages_tree and everything it calls. extract_fn.py loads one
# function at a time, so an end-to-end run against a local origin needs the whole set.
load_publish_unit() {
  local fn
  for fn in publish_pages_tree assert_assembled_pages_tree assert_pages_tree_file_sizes \
    export_pages_git_identity add_pages_worktree cleanup_pages_worktree; do
    load_shell_function "${SCRIPT}" "${fn}"
  done
}

@test "publish-pages-tree: a tree with a root page, .nojekyll and one alias is accepted" {
  load_shell_function "${SCRIPT}" assert_assembled_pages_tree
  assembled_tree "${BATS_TEST_TMPDIR}/site" latest
  run assert_assembled_pages_tree "${BATS_TEST_TMPDIR}/site"
  [ "${status}" -eq 0 ]
}

@test "publish-pages-tree: any alias dir counts, so a work-branch alias is not refused" {
  load_shell_function "${SCRIPT}" assert_assembled_pages_tree
  assembled_tree "${BATS_TEST_TMPDIR}/feat" feat-foo
  run assert_assembled_pages_tree "${BATS_TEST_TMPDIR}/feat"
  [ "${status}" -eq 0 ]
}

@test "publish-pages-tree: a missing index.html, .nojekyll or alias dir is refused by name" {
  load_shell_function "${SCRIPT}" assert_assembled_pages_tree
  assembled_tree "${BATS_TEST_TMPDIR}/noidx" latest
  rm "${BATS_TEST_TMPDIR}/noidx/index.html"
  run --separate-stderr assert_assembled_pages_tree "${BATS_TEST_TMPDIR}/noidx"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"needs index.html"* ]]

  assembled_tree "${BATS_TEST_TMPDIR}/nojekyll" latest
  rm "${BATS_TEST_TMPDIR}/nojekyll/.nojekyll"
  run --separate-stderr assert_assembled_pages_tree "${BATS_TEST_TMPDIR}/nojekyll"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"needs .nojekyll"* ]]

  mkdir -p "${BATS_TEST_TMPDIR}/bare"
  printf '<p>root</p>\n' >"${BATS_TEST_TMPDIR}/bare/index.html"
  : >"${BATS_TEST_TMPDIR}/bare/.nojekyll"
  run --separate-stderr assert_assembled_pages_tree "${BATS_TEST_TMPDIR}/bare"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"at least one alias directory"* ]]

  run --separate-stderr assert_assembled_pages_tree "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"missing assembled dir"* ]]
}

@test "publish-pages-tree: a file at the blob limit is named and blocks the run" {
  load_shell_function "${SCRIPT}" assert_pages_tree_file_sizes
  assembled_tree "${BATS_TEST_TMPDIR}/sizes" latest
  # The assignment is temporary to the run subshell, so no limit leaks onward.
  PAGES_MAX_FILE_BYTES=100 run assert_pages_tree_file_sizes "${BATS_TEST_TMPDIR}/sizes"
  [ "${status}" -eq 0 ]

  printf 'x%.0s' {1..200} >"${BATS_TEST_TMPDIR}/sizes/latest/big.js"
  PAGES_MAX_FILE_BYTES=100 run --separate-stderr assert_pages_tree_file_sizes "${BATS_TEST_TMPDIR}/sizes"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"latest/big.js is 200 bytes"* ]]
}

@test "publish-pages-tree: a missing argument is answered with usage, before any git work" {
  load_shell_function "${SCRIPT}" publish_pages_tree
  run --separate-stderr publish_pages_tree
  [ "${status}" -eq 2 ]
  [[ ${stderr} == *"Usage: publish-pages-tree.sh <assembled-dir>"* ]]
}

@test "publish-pages-tree: the gh-pages commit is the Actions bot's and the checkout's config stays clean" {
  # The identity has to land on the commit, not in .git/config: that config is shared by
  # the checkout and its worktrees, so writing it would author the operator's next commits.
  load_publish_unit
  local origin clone
  origin="${BATS_TEST_TMPDIR}/ident-origin.git"
  clone="${BATS_TEST_TMPDIR}/ident-clone"
  seeded_origin "${origin}" "${clone}"
  assembled_tree "${BATS_TEST_TMPDIR}/ident" latest
  (
    cd "${clone}" &&
      export RUNNER_TEMP="${BATS_TEST_TMPDIR}/tmp" GITHUB_REF_NAME=feat/foo GITHUB_SHA=deadbeef &&
      publish_pages_tree "${BATS_TEST_TMPDIR}/ident"
  )

  local bot="github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
  run git -C "${origin}" log --format='%an <%ae> %cn <%ce>' -1 gh-pages
  [ "${output}" = "${bot} ${bot}" ]

  run git -C "${clone}" config --local --get user.name
  [ -z "${output}" ]
}

@test "publish-pages-tree: the worktree is created off origin and cleaned up again" {
  load_shell_function "${SCRIPT}" add_pages_worktree
  load_shell_function "${SCRIPT}" cleanup_pages_worktree
  git init -q "${BATS_TEST_TMPDIR}/wt"
  (
    cd "${BATS_TEST_TMPDIR}/wt" &&
      export RUNNER_TEMP="${BATS_TEST_TMPDIR}/tmp" &&
      add_pages_worktree &&
      [[ ${PAGES_WORKTREE} == *evo-t1-pages.* ]] &&
      [ -d "${PAGES_WORKTREE}" ] &&
      cleanup_pages_worktree &&
      [ -z "${PAGES_WORKTREE}" ] &&
      [ ! -d "${PAGES_WORKTREE}" ]
  )
}

@test "publish-pages-tree: publishing keeps every alias dir in the gh-pages gitignore" {
  load_publish_unit
  local origin clone
  origin="${BATS_TEST_TMPDIR}/origin.git"
  clone="${BATS_TEST_TMPDIR}/clone"
  seeded_origin "${origin}" "${clone}"

  assembled_tree "${BATS_TEST_TMPDIR}/pub" feat-foo
  (
    cd "${clone}" &&
      export RUNNER_TEMP="${BATS_TEST_TMPDIR}/tmp" GITHUB_REF_NAME=feat/foo GITHUB_SHA=deadbeef &&
      publish_pages_tree "${BATS_TEST_TMPDIR}/pub"
  )

  run git -C "${origin}" ls-tree --name-only -r gh-pages
  [[ ${output} == *"index.html"* ]]
  [[ ${output} == *".nojekyll"* ]]
  [[ ${output} == *"feat-foo/index.html"* ]]
  [[ ${output} == *".gitignore"* ]]

  local ignore
  ignore="$(git -C "${origin}" show gh-pages:.gitignore)"
  assert_match "everything is ignored by default" '^/\*$' "${ignore}"
  assert_match "every top-level alias dir survives" '^!/\*/$' "${ignore}"
  assert_match "the root page survives" '^!/index\.html$' "${ignore}"
  assert_match "the jekyll opt-out survives" '^!/\.nojekyll$' "${ignore}"

  run git -C "${origin}" log --format=%s -1 gh-pages
  [[ ${output} == *"publish feat/foo from deadbeef"* ]]
}
