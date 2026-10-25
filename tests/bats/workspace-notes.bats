#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## workspace-notes.bats — the private per-repo scratch notes.md
#
# Pins templates/common/notes-setup.sh, the library the startup twins source
# before their clone stage: the remote-to-key normalization every clone is
# filed under (one key per repository, port spellings included), the
# profile-volume path that copy survives a workspace recreate at, the name used
# when a repository tracks notes.md itself, and the restore-then-seed-then-copy
# back order notes_materialize runs in. Also pins the excludes it writes — a
# repo-root scratch file must never be committable, and a global excludesFile
# the developer owns is only ever appended to, expanded and absolute or not —
# and the wiring both templates need: main.tf's file() feed, the atomic and
# clone-user-readable write that publishes the library into ~/.grok, and running
# the stage as the clone owner whenever the clone stage does the same.
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
    "ssh://git@github.com:22/Owner/Repo.git" \
    "ssh://git@github.com:2222/Owner/Repo.git" \
    "https://github.com:8080/Owner/Repo.git" \
    "https://github.com/Owner/Repo.git/" \
    "https://github.com/Owner/Repo" \
    "git@github.com:owner/repo/"; do
    run notes_repo_key "${url}"
    [ "${status}" -eq 0 ] || { printf 'FAIL: %s rejected\n' "${url}" >&2; return 1; }
    [ "${lines[0]}" = "github.com/owner/repo" ] ||
      { printf 'FAIL: %s -> %s\n' "${url}" "${lines[0]}" >&2; return 1; }
  done
  # One repository, one canonical file: a port is transport, not part of the key,
  # so the ssh-with-port and scp spellings must not fork it in two.
  [ "$(notes_repo_key "ssh://git@github.com:22/acme/repo.git")" = "$(notes_repo_key "git@github.com:acme/repo")" ]
}

@test "notes_repo_key: an input with no owner/repo fails instead of inventing a key" {
  local url
  for url in "" "garbage" "https://github.com/owner" "github.com/repo.git" "/just/a/path" "ssh://git@github.com:22"; do
    run notes_repo_key "${url}"
    [ "${status}" -eq 1 ] || { printf 'FAIL: %s accepted\n' "${url}" >&2; return 1; }
    [ -z "${output}" ]
  done
}

@test "notes_repo_key: a dot segment is refused rather than kept as path" {
  # The key becomes a path suffix under ~/.grok/notes/, so ./ and ../ in a URL
  # would put the canonical copy outside that tree.
  local url
  for url in \
    "https://github.com/../../foo/bar" \
    "https://github.com/acme/./repo" \
    "https://github.com/acme/repo/.." \
    "ssh://git@github.com/acme/../../etc/passwd"; do
    run notes_repo_key "${url}"
    [ "${status}" -eq 1 ] || { printf 'FAIL: %s accepted\n' "${url}" >&2; return 1; }
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
  local clone want
  clone="$(make_clone "https://github.com/acme/stub.git")"
  notes_materialize "${clone}"
  [ -f "${clone}/notes.md" ]
  [ -f "$(canon_of "github.com/acme/stub")" ]
  # What the stub has to get right is where the copy that survives a recreate
  # lives, and it has to be spelled as a real path: the workspace container's
  # ~/.grok is not a directory a nested dev container can open, so a ~-prefixed
  # one would send the reader somewhere that does not exist.
  want="$(notes_canonical_path "github.com/acme/stub")"
  run cat "${clone}/notes.md"
  [[ ${lines[0]} == *"${want}"* ]]
  [[ ${lines[0]} != "~/.grok/"* ]]
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
  # The stack's own exclude file exists only to be the global one. With the
  # developer's file named, nothing would ever read it, so it stays unwritten —
  # while the directory under it still holds the canonical notes copies.
  [ ! -e "${HOME}/.grok/notes/exclude" ]
  [ -d "${HOME}/.grok/notes" ]
}

@test "notes_ensure_excludes: an excludesFile with no final newline is not fused" {
  local mine
  mine="${HOME}/.config/git/ignore"
  mkdir -p "$(dirname "${mine}")"
  # Hand-edited ignore files routinely end without the newline, and appending
  # straight into that would destroy the developer's last pattern.
  printf '%s' '*.swp' >"${mine}"
  git config --global core.excludesFile "${mine}"
  notes_ensure_excludes "$(make_clone "https://github.com/acme/nonl.git")"
  [ "$(sed -n '1p' "${mine}")" = "*.swp" ]
  grep -qxF '*.swp' "${mine}"
  grep -qxF 'notes.md' "${mine}"
  grep -qxF '.scratch-notes.md' "${mine}"
  if grep -qF 'swpnotes.md' "${mine}"; then
    printf 'FAIL: the appended line fused with the last one:\n%s\n' "$(cat "${mine}")" >&2
    return 1
  fi
  # The next start still sees both names as whole lines.
  notes_ensure_excludes "$(make_clone "https://github.com/acme/nonl.git")"
  [ "$(grep -cxF 'notes.md' "${mine}")" -eq 1 ]
}

@test "notes_ensure_excludes: a ~ in core.excludesFile expands to HOME" {
  local workdir
  git config --global core.excludesFile '~/.gitignore_global'
  # The cwd matters: an unexpanded path is created relative to wherever git
  # happens to run, which is how a literal ./~ directory shows up in a clone.
  workdir="$(make_scratch)/cwd"
  mkdir -p "${workdir}"
  (cd "${workdir}" && notes_ensure_excludes "$(make_clone "https://github.com/acme/tilde.git")")
  grep -qxF 'notes.md' "${HOME}/.gitignore_global"
  grep -qxF '.scratch-notes.md' "${HOME}/.gitignore_global"
  [ "$(git config --global --get core.excludesFile)" = '~/.gitignore_global' ]
  [ -z "$(ls -A "${workdir}")" ]
  if [ -e "${HOME}/~" ]; then
    printf 'FAIL: a literal ~ directory was created under HOME\n' >&2
    return 1
  fi
}

@test "notes_ensure_excludes: a relative core.excludesFile is left alone, not written next to the clone" {
  local clone workdir
  clone="$(make_clone "https://github.com/acme/relative.git")"
  git config --global core.excludesFile 'my-ignores'
  workdir="$(make_scratch)/cwd"
  mkdir -p "${workdir}"
  (cd "${workdir}" && notes_ensure_excludes "${clone}") 2>"${BATS_TEST_TMPDIR}/err.txt"
  # git resolves that value against the cwd, so appending here would drop a file
  # beside a clone instead of where it applies. The clone's own exclude still
  # covers both names, and the file git would never read stays unwritten.
  grep -qxF 'notes.md' "${clone}/.git/info/exclude"
  grep -qxF '.scratch-notes.md' "${clone}/.git/info/exclude"
  [ ! -e "${HOME}/.grok/notes/exclude" ]
  [ ! -e "${workdir}/my-ignores" ]
  [ ! -e "${clone}/my-ignores" ]
  grep -qF 'not absolute' "${BATS_TEST_TMPDIR}/err.txt"
  [ "$(git config --global --get core.excludesFile)" = 'my-ignores' ]
}

@test "notes_ensure_excludes: a core.excludesFile that names a directory is refused" {
  local clone workdir
  clone="$(make_clone "https://github.com/acme/direxclude.git")"
  # '~' expands to HOME, a directory: being absolute is not enough, and appending
  # into a directory can only fail — twice per start, once per name.
  git config --global core.excludesFile '~'
  workdir="$(make_scratch)/cwd"
  mkdir -p "${workdir}"
  (cd "${workdir}" && notes_ensure_excludes "${clone}") 2>"${BATS_TEST_TMPDIR}/err.txt"
  grep -qF 'is a directory' "${BATS_TEST_TMPDIR}/err.txt"
  # Nothing was invented inside the named directory, nothing beside the clone,
  # and the value the developer set survives untouched.
  [ ! -e "${HOME}/notes.md" ]
  [ ! -e "${HOME}/.scratch-notes.md" ]
  [ ! -e "${HOME}/.grok/notes/exclude" ]
  [ ! -e "${workdir}/~" ]
  [ ! -e "${clone}/~" ]
  grep -qxF 'notes.md' "${clone}/.git/info/exclude"
  [ "$(git config --global --get core.excludesFile)" = '~' ]
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
  # home-directory workspace produces, HOME unset included.
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    cat "${NOTES_LIB}"
    printf '%s\n' \
      'notes_materialize "" ""' \
      'notes_ensure_excludes ""' \
      'notes_live_name ""' \
      'notes_repo_key' \
      'HOME= notes_canonical_path "github.com/a/b" || true' \
      'HOME= notes_ensure_excludes "" ' \
      'HOME= notes_materialize "$PWD" "https://github.com/a/b.git"' \
      'declare -F notes_materialize >/dev/null'
  } >"${rendered}"
  run bash "${rendered}"
  [ "${status}" -eq 0 ]
}

@test "startup wiring: both twins publish, source and run the library as the clone owner" {
  local tpl pat q="'"
  for tpl in "${REPO_ROOT}/templates/workspace/startup.sh.tftpl" \
    "${REPO_ROOT}/templates/devcontainer/startup.sh.tftpl"; do
    [[ -f "${tpl}" ]] || skip "startup template not reachable from ${REPO_ROOT}"
    # Every pattern is anchored on the notes stage, so each one can still fail:
    # a generic 'mktemp ' or '$clone_runner env HOME=' also matches other stages.
    for pat in '${notes_setup}' 'mv -f "$notes_lib_tmp"' '. "$notes_lib"' \
      '$clone_runner env HOME="$clone_home" NOTES_SETUP_LIB' '. "$NOTES_SETUP_LIB"'; do
      if ! grep -qF -- "${pat}" "${tpl}"; then
        printf 'FAIL: %s lost the wiring for "%s"\n' "${tpl}" "${pat}" >&2
        return 1
      fi
    done
    # The heredoc has to stay quoted, or the shell expands the library's own
    # $1 and $HOME on the way in.
    if ! grep -qF -- "<<${q}NOTES_SETUP_EOF${q}" "${tpl}"; then
      printf 'FAIL: %s feeds the library through an unquoted heredoc\n' "${tpl}" >&2
      return 1
    fi
    # Published world-readable, before the rename: mv keeps mktemp's 0600, and
    # the rename is what puts the path in reach of a sibling boot.
    if ! sed -n '/mktemp "$notes_lib/,/rm -f "$notes_lib_tmp"/p' "${tpl}" |
      grep -q 'chmod 0644 "$notes_lib_tmp"'; then
      printf 'FAIL: %s publishes the library without making it readable\n' "${tpl}" >&2
      return 1
    fi
    # Both run_notes branches materialize: the privileged one inside the runner's
    # shell, the plain one directly. Only the stage comment names the function
    # otherwise, so the count is what pins the unprivileged path.
    [ "$(grep -c 'notes_materialize "\$1" "\$2"' "${tpl}")" -eq 2 ]
    # Every clone path gets the call: primary and extras, on both the already
    # cloned branch and the just-cloned one.
    [ "$(grep -c 'run_notes "\$target"' "${tpl}")" -eq 2 ]
    [ "$(grep -c 'run_notes "\$extra_target"' "${tpl}")" -eq 2 ]
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
