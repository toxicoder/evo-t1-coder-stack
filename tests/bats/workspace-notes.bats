#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## workspace-notes.bats — the private per-repo scratch notes.md
#
# Pins templates/common/notes-setup.sh, the library the startup twins source
# before their clone stage: the remote-to-key normalization every clone is
# filed under, the profile-volume path that copy survives a workspace recreate
# at, the name used when a repository tracks notes.md itself, and the
# restore-then-seed-then-copy-back order notes_materialize runs in. Also pins
# the excludes it writes (a repo-root scratch file must never be committable)
# and the wiring both templates need: main.tf's file() feed, the heredoc that
# writes the library into ~/.grok, and the sourcing that makes notes_materialize
# a command.
#
# Usage: bazelisk test //tests:bats_workspace_notes_test   (from any cwd)
#
# Safety: real git, but only ever on throwaway repos under BATS_TEST_TMPDIR, so
# no network and no daemon. HOME is redirected per test — it is the profile
# volume this library writes into, and the file `git config --global` edits.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
NOTES_LIB=""
PROFILE_HOME=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  NOTES_LIB="${REPO_ROOT}/templates/common/notes-setup.sh"
  [ -f "${NOTES_LIB}" ] ||
    skip "no common notes-setup.sh payload under ${REPO_ROOT}/templates/common"
  # shellcheck source=/dev/null
  source "${NOTES_LIB}"
  # Everything this library writes hangs off HOME, including the global
  # core.excludesFile git config writes, so the whole test runs on a scratch one.
  PROFILE_HOME="$(make_scratch)/profile"
  mkdir -p "${PROFILE_HOME}"
  export HOME="${PROFILE_HOME}"
}

# make_clone <url> [leaf] — a throwaway local repo whose origin is <url>.
make_clone() {
  local url="${1:-}" dir
  dir="$(make_scratch)/${2:-repo}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" remote add origin "${url}"
  printf '%s' "${dir}"
}

# canon_of <key> — the profile-volume path a key's notes live at.
canon_of() {
  printf '%s/.grok/notes/%s/notes.md' "${HOME}" "${1}"
}

@test "notes_repo_key: every accepted remote spelling lands on one key" {
  local url
  for url in \
    "https://github.com/Owner/Repo.git" \
    "git@github.com:Owner/Repo.git" \
    "ssh://git@github.com/Owner/Repo.git" \
    "https://github.com/Owner/Repo.git/" \
    "https://github.com/Owner/Repo" \
    "git@github.com:owner/repo/"; do
    run notes_repo_key "${url}"
    [ "${status}" -eq 0 ] || { printf 'FAIL: %s rejected\n' "${url}" >&2; return 1; }
    [ "${lines[0]}" = "github.com/owner/repo" ] ||
      { printf 'FAIL: %s -> %s\n' "${url}" "${lines[0]}" >&2; return 1; }
  done
}

@test "notes_repo_key: an input with no owner/repo fails instead of inventing a key" {
  local url
  for url in "" "garbage" "https://github.com/owner" "github.com/repo.git" "/just/a/path"; do
    run notes_repo_key "${url}"
    [ "${status}" -eq 1 ] || { printf 'FAIL: %s accepted\n' "${url}" >&2; return 1; }
    [ -z "${output}" ]
  done
}

@test "notes_canonical_path: the key keeps its slashes under ~/.grok/notes" {
  run notes_canonical_path "github.com/acme/widget"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${HOME}/.grok/notes/github.com/acme/widget/notes.md" ]
  # A subgroup is part of the key, so two same-named repos cannot share a file.
  run notes_canonical_path "gitlab.com/grp/sub/widget"
  [ "${lines[0]}" = "${HOME}/.grok/notes/gitlab.com/grp/sub/widget/notes.md" ]
  run notes_canonical_path ""
  [ "${status}" -eq 1 ]
}

@test "notes_live_name: notes.md, unless the repository tracks notes.md itself" {
  local plain tracked
  plain="$(make_clone "https://github.com/acme/plain.git")"
  tracked="$(make_clone "https://github.com/acme/tracked.git")"
  run notes_live_name "${plain}"
  [ "${lines[0]}" = "notes.md" ]
  printf '%s\n' 'the project README-style notes' >"${tracked}/notes.md"
  git -C "${tracked}" add notes.md
  run notes_live_name "${tracked}"
  [ "${lines[0]}" = ".scratch-notes.md" ]
  # A directory that is not a repo still answers a name rather than failing.
  run notes_live_name "$(make_scratch)/not-a-repo"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "notes.md" ]
}

@test "notes_materialize: a workspace recreate restores the canonical copy" {
  local clone canon
  clone="$(make_clone "https://github.com/acme/restore.git")"
  canon="$(canon_of "github.com/acme/restore")"
  mkdir -p "$(dirname "${canon}")"
  printf '%s\n' 'left here by the previous workspace' >"${canon}"
  notes_materialize "${clone}"
  [ -f "${clone}/notes.md" ]
  [ "$(cat "${clone}/notes.md")" = "left here by the previous workspace" ]
}

@test "notes_materialize: the clone's file is copied back to the profile volume" {
  local clone canon
  clone="$(make_clone "git@github.com:acme/backcopy.git")"
  notes_materialize "${clone}"
  printf '%s\n' 'edited during this session' >"${clone}/notes.md"
  notes_materialize "${clone}"
  canon="$(canon_of "github.com/acme/backcopy")"
  [ "$(cat "${canon}")" = "edited during this session" ]
}

@test "notes_materialize: neither copy existing seeds the stub header" {
  local clone
  clone="$(make_clone "https://github.com/acme/stub.git")"
  notes_materialize "${clone}"
  [ -f "${clone}/notes.md" ]
  [ -f "$(canon_of "github.com/acme/stub")" ]
  run cat "${clone}/notes.md"
  [[ ${lines[0]} == *"Not committed"* ]]
  [[ ${lines[0]} == *"~/.grok/notes/github.com/acme/stub/notes.md"* ]]
  [[ ${lines[0]} == *"survives workspace recreate"* ]]
}

@test "notes_materialize: a tracked notes.md is left alone and the scratch name is used" {
  local clone
  clone="$(make_clone "https://github.com/acme/tracked2.git")"
  printf '%s\n' 'committed project notes' >"${clone}/notes.md"
  git -C "${clone}" add notes.md
  notes_materialize "${clone}"
  [ "$(cat "${clone}/notes.md")" = "committed project notes" ]
  [ -f "${clone}/.scratch-notes.md" ]
  [ -f "$(canon_of "github.com/acme/tracked2")" ]
}

@test "notes_materialize: the remote wins, and the fallback URL only fills a gap" {
  local with_origin no_origin
  with_origin="$(make_clone "https://github.com/acme/real.git")"
  # An origin is the key even when the caller passes a different fallback.
  notes_materialize "${with_origin}" "https://github.com/acme/wrong.git"
  [ -f "$(canon_of "github.com/acme/real")" ]
  if [ -e "$(canon_of "github.com/acme/wrong")" ]; then
    printf 'FAIL: the fallback URL produced a second canonical file\n' >&2
    return 1
  fi
  no_origin="$(make_scratch)/plain-dir"
  mkdir -p "${no_origin}"
  notes_materialize "${no_origin}" "https://github.com/acme/fallback.git"
  [ -f "$(canon_of "github.com/acme/fallback")" ]
}

@test "notes_materialize: two remotes in one workspace get two files" {
  local a b
  a="$(make_clone "https://github.com/acme/one.git" "one")"
  b="$(make_clone "https://github.com/other/two.git" "two")"
  notes_materialize "${a}"
  notes_materialize "${b}"
  printf '%s\n' 'notes for one' >"${a}/notes.md"
  printf '%s\n' 'notes for two' >"${b}/notes.md"
  notes_materialize "${a}"
  notes_materialize "${b}"
  [ "$(cat "$(canon_of "github.com/acme/one")")" = "notes for one" ]
  [ "$(cat "$(canon_of "github.com/other/two")")" = "notes for two" ]
}

@test "notes_materialize: an empty or non-directory argument is a no-op" {
  notes_materialize ""
  notes_materialize "$(make_scratch)/never-created"
  [ ! -e "${HOME}/.grok/notes" ]
}

@test "notes_ensure_excludes: the profile exclude, the global one, and the clone's own" {
  local clone
  clone="$(make_clone "https://github.com/acme/excl.git")"
  notes_ensure_excludes "${clone}"
  run cat "${HOME}/.grok/notes/exclude"
  grep -qxF 'notes.md' "${HOME}/.grok/notes/exclude"
  grep -qxF '.scratch-notes.md' "${HOME}/.grok/notes/exclude"
  [ "$(git config --global --get core.excludesFile)" = "${HOME}/.grok/notes/exclude" ]
  grep -qxF 'notes.md' "${clone}/.git/info/exclude"
  grep -qxF '.scratch-notes.md' "${clone}/.git/info/exclude"
  # Idempotent: a second start must not duplicate either line.
  notes_ensure_excludes "${clone}"
  [ "$(grep -cxF 'notes.md' "${HOME}/.grok/notes/exclude")" -eq 1 ]
  [ "$(grep -cxF 'notes.md' "${clone}/.git/info/exclude")" -eq 1 ]
}

@test "notes_ensure_excludes: an excludesFile the developer set is appended to, not replaced" {
  local mine
  mine="${HOME}/.config/git/ignore"
  mkdir -p "$(dirname "${mine}")"
  printf '%s\n' '*.swp' >"${mine}"
  git config --global core.excludesFile "${mine}"
  notes_ensure_excludes "$(make_clone "https://github.com/acme/keep.git")"
  [ "$(git config --global --get core.excludesFile)" = "${mine}" ]
  grep -qxF '*.swp' "${mine}"
  grep -qxF 'notes.md' "${mine}"
  grep -qxF '.scratch-notes.md' "${mine}"
}

@test "a clone ends up with nothing untracked to commit" {
  local clone status_line
  clone="$(make_clone "https://github.com/acme/clean.git")"
  printf '%s\n' 'work in progress' >"${clone}/notes.md"
  notes_materialize "${clone}"
  run git -C "${clone}" status --porcelain
  [ -z "${output}" ]
}

@test "the library is inlinable: no heredoc delimiter clash, clean under set -u" {
  local rendered="${BATS_TEST_TMPDIR}/rendered-notes-setup.sh"
  if grep -qxF 'NOTES_SETUP_EOF' "${NOTES_LIB}"; then
    printf 'FAIL: the payload holds the heredoc delimiter the startup twins use\n' >&2
    return 1
  fi
  # What the rendered startup script actually runs: the heredoc body, sourced
  # under the script's own `set -u`, then called with the empty inputs a
  # home-directory workspace produces.
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    cat "${NOTES_LIB}"
    printf '%s\n' \
      'notes_materialize "" ""' \
      'notes_ensure_excludes ""' \
      'notes_live_name ""' \
      'notes_repo_key' \
      'declare -F notes_materialize >/dev/null'
  } >"${rendered}"
  run bash "${rendered}"
  [ "${status}" -eq 0 ]
}

@test "startup wiring: both twins write, source and call the library" {
  local tpl
  for tpl in "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"; do
    [[ -f "${tpl}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    run grep -F '${notes_setup}' "${tpl}"
    [ "${status}" -eq 0 ] || { printf 'FAIL: %s lost the notes_setup interpolation\n' "${tpl}" >&2; return 1; }
    run grep -F "cat >\"\$HOME/.grok/notes-setup.sh\" <<'NOTES_SETUP_EOF'" "${tpl}"
    [ "${status}" -eq 0 ]
    run grep -F '. "$HOME/.grok/notes-setup.sh"' "${tpl}"
    [ "${status}" -eq 0 ]
    # Every clone path gets the call: primary and extras, on both the already
    # cloned branch and the just-cloned one.
    [ "$(grep -c 'notes_materialize "\$target"' "${tpl}")" -eq 2 ]
    [ "$(grep -c 'notes_materialize "\$extra_target"' "${tpl}")" -eq 2 ]
  done
}

@test "main.tf wiring: both twins feed notes_setup from templates/common" {
  local tf
  for tf in "${REPO_ROOT}/templates/workspace/main.tf" \
    "${REPO_ROOT}/templates/devcontainer/main.tf"; do
    [[ -f "${tf}" ]] || skip "template main.tf not reachable from ${REPO_ROOT}"
    run grep -F 'notes_setup = file("${path.module}/notes-setup.sh")' "${tf}"
    [ "${status}" -eq 0 ] || { printf 'FAIL: %s has no notes_setup feed\n' "${tf}" >&2; return 1; }
  done
}
