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
# the stage as the clone owner whenever the clone stage does the same. It also
# pins the hardening around that copy: the stub line that marks a clone nobody
# wrote in, the guards notes_back_sync puts on every live-to-canonical copy, the
# archives notes_backup_canon keeps before a replace, the two-second stability
# window notes_sync_once leaves a half-saved file in, and the one flock holder
# notes_sync_start leaves the container with.
#
# Usage: bazelisk test //tests:bats_workspace_notes_test   (from any cwd)
#
# Safety: real git, but only ever on throwaway repos under BATS_TEST_TMPDIR, so
# no network and no daemon. HOME is redirected per test — it is the profile
# volume this library writes into, and the file `git config --global` edits. The
# watcher notes_sync_start detaches is killed in teardown by its own scratch paths
# and nothing else, so no test leaves a loop running on the host.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
NOTES_LIB=""
PROFILE_HOME=""
# The workspace root a test told notes_sync_start to watch, empty unless it did.
# teardown() keys the watcher kill on it, so only a test that started a loop
# ever kills one.
WATCH_ROOT=""

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

# The watcher notes_sync_start leaves behind is detached on purpose (setsid plus
# nohup), so it outlives the test that started it. Both command lines carry a
# path from this test's own scratch tree, so the kill can be anchored on those and
# cannot reach a watcher belonging to anything else on the host. The wait is for
# the same reason BATS removes the scratch tree right after: a loop still alive
# would keep writing into a directory that has just been deleted.
teardown() {
  local tries=0
  if [ -n "${WATCH_ROOT}" ]; then
    pkill -f -- "${PROFILE_HOME}/[.]notes-sync[.]lock" 2>/dev/null || true
    pkill -f -- "${WATCH_ROOT} " 2>/dev/null || true
    while [ "${tries}" -lt 10 ]; do
      pgrep -f -- "${WATCH_ROOT} " >/dev/null 2>&1 || break
      sleep 0.1
      tries=$((tries + 1))
    done
  fi
  WATCH_ROOT=""
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

# The one line notes_materialize seeds into a clone that has no notes yet. Spelled
# out here instead of lifted out of the library: notes_is_stub matches on these two
# fixed ends, so the wording is part of what this suite pins.
STUB_PREFIX="Private scratch notes for this repository. Not committed. Canonical copy on this owner's shared Grok profile volume: "
STUB_SUFFIX=" (survives workspace recreate)."

# write_stub <file> <path-in-the-line> — seed a file the way the library seeds one.
write_stub() {
  printf '%s\n' "${STUB_PREFIX}${2}${STUB_SUFFIX}" >"${1}"
}

# make_clone_under <root> <url> [leaf] — make_clone moved in as a direct child of
# <root>, which is the only shape notes_sync_once walks.
make_clone_under() {
  local root="${1}" leaf="${3:-repo}" dir
  dir="$(make_clone "${2}" "${leaf}")"
  mv "${dir}" "${root}/${leaf}"
  printf '%s' "${root}/${leaf}"
}

# age_live <file> — push mtime back past the stability window notes_sync_once
# reserves for a file that may still be mid-save.
age_live() {
  touch -d '1 minute ago' "${1}"
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
  # What the stub has to get right is where the copy that survives a recreate
  # lives, and it has to be spelled as a real path: the workspace container's
  # ~/.grok is not a directory a nested dev container can open, so a ~-prefixed
  # one would send the reader somewhere that does not exist.
  want="$(notes_canonical_path "github.com/acme/stub")"
  run cat "${clone}/notes.md"
  [[ ${lines[0]} == *"${want}"* ]]
  [[ ${lines[0]} != "~/.grok/"* ]]
  # A seed is not notes, so it earns no copy on the volume: the key's directory
  # is there, the file is not, until somebody writes something real.
  [ -d "$(dirname "${want}")" ]
  [ ! -e "${want}" ]
  printf '%s\n' 'the first real line' >"${clone}/notes.md"
  notes_materialize "${clone}"
  [ "$(cat "${want}")" = "the first real line" ]
}

@test "notes_materialize: a tracked notes.md is left alone and the scratch name is used" {
  local clone
  clone="$(make_clone "https://github.com/acme/tracked2.git")"
  printf '%s\n' 'committed project notes' >"${clone}/notes.md"
  git -C "${clone}" add notes.md
  notes_materialize "${clone}"
  [ "$(cat "${clone}/notes.md")" = "committed project notes" ]
  [ -f "${clone}/.scratch-notes.md" ]
  # What the scratch name holds at this point is the seed, and a seed is nothing
  # to file under the key.
  [ ! -e "$(canon_of "github.com/acme/tracked2")" ]
  printf '%s\n' 'scratch notes for the tracked repo' >"${clone}/.scratch-notes.md"
  notes_materialize "${clone}"
  [ "$(cat "$(canon_of "github.com/acme/tracked2")")" = "scratch notes for the tracked repo" ]
}

@test "notes_materialize: the remote wins, and the fallback URL only fills a gap" {
  local with_origin no_origin
  with_origin="$(make_clone "https://github.com/acme/real.git")"
  printf '%s\n' 'keyed on the origin' >"${with_origin}/notes.md"
  # An origin is the key even when the caller passes a different fallback.
  notes_materialize "${with_origin}" "https://github.com/acme/wrong.git"
  [ "$(cat "$(canon_of "github.com/acme/real")")" = "keyed on the origin" ]
  if [ -e "$(canon_of "github.com/acme/wrong")" ]; then
    printf 'FAIL: the fallback URL produced a second canonical file\n' >&2
    return 1
  fi
  no_origin="$(make_scratch)/plain-dir"
  mkdir -p "${no_origin}"
  printf '%s\n' 'keyed on the fallback' >"${no_origin}/notes.md"
  notes_materialize "${no_origin}" "https://github.com/acme/fallback.git"
  [ "$(cat "$(canon_of "github.com/acme/fallback")")" = "keyed on the fallback" ]
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

@test "notes_is_stub: only the exact one-line seed reads as a stub" {
  local file="${BATS_TEST_TMPDIR}/live.md" path="${HOME}/.grok/notes/github.com/a/b/notes.md"
  write_stub "${file}" "${path}"
  run notes_is_stub "${file}"
  [ "${status}" -eq 0 ]
  # A file that was never written, and one written but never filled in, both say
  # "nothing here", which is a different claim from "this is the seeded stub".
  run notes_is_stub "${BATS_TEST_TMPDIR}/never-written"
  [ "${status}" -eq 1 ]
  run notes_is_stub ""
  [ "${status}" -eq 1 ]
  : >"${file}"
  run notes_is_stub "${file}"
  [ "${status}" -eq 1 ]
  # A second line is a developer writing something, and the one line that does
  # match has to match at both ends: the tail is what says the copy is still only
  # the seed.
  printf '%s\n%s\n' "${STUB_PREFIX}${path}${STUB_SUFFIX}" 'and a thought of my own' >"${file}"
  run notes_is_stub "${file}"
  [ "${status}" -eq 1 ]
  printf '%s\n' "${STUB_PREFIX}${path}${STUB_SUFFIX} (edited)" >"${file}"
  run notes_is_stub "${file}"
  [ "${status}" -eq 1 ]
  printf '%s\n' "Notes for this project." >"${file}"
  run notes_is_stub "${file}"
  [ "${status}" -eq 1 ]
}

@test "notes_is_stub: a blank line under the seed must not hide the notes below it" {
  # A developer who presses Enter under the seed and then writes notes there
  # must not have the file read as a stub: notes_back_sync would refuse to copy
  # it, and notes_materialize's restore branch would cp -f the canonical copy
  # straight over it. The guard counts lines through mapfile, so the trailing
  # blank line that $(...) would strip still counts.
  local file="${BATS_TEST_TMPDIR}/live.md" path="${HOME}/.grok/notes/github.com/a/b/notes.md"
  printf '%s\n\n%s\n' "${STUB_PREFIX}${path}${STUB_SUFFIX}" 'the notes a human added' >"${file}"
  run notes_is_stub "${file}"
  [ "${status}" -eq 1 ]
}

@test "notes_back_sync: neither a stub nor an empty live file touches a canonical copy that holds notes" {
  local live canon
  live="$(make_scratch)/notes.md"
  canon="$(canon_of "github.com/acme/guarded")"
  mkdir -p "$(dirname "${canon}")"
  printf '%s\n' 'what the last workspace wrote' >"${canon}"
  # This is the erasure the guards exist against: a recreated clone arrives
  # holding only the seed, and an unguarded copy back would bury the real notes.
  write_stub "${live}" "${canon}"
  notes_back_sync "${live}" "${canon}"
  [ "$(cat "${canon}")" = "what the last workspace wrote" ]
  : >"${live}"
  notes_back_sync "${live}" "${canon}"
  [ "$(cat "${canon}")" = "what the last workspace wrote" ]
  rm -f "${live}"
  notes_back_sync "${live}" "${canon}"
  [ "$(cat "${canon}")" = "what the last workspace wrote" ]
  # A refused copy has no previous content to keep, so it archives nothing.
  [ ! -e "$(dirname "${canon}")/backups" ]
}

@test "notes_back_sync: an identical live file copies nothing, a real change archives the previous copy" {
  local live canon fresh
  live="$(make_scratch)/notes.md"
  canon="$(canon_of "github.com/acme/archived")"
  mkdir -p "$(dirname "${canon}")"
  printf '%s\n' 'v1 on the volume' >"${canon}"
  cp "${canon}" "${live}"
  notes_back_sync "${live}" "${canon}"
  # Equal content is not a change: no copy, and no archive to show for it.
  [ ! -e "$(dirname "${canon}")/backups" ]
  printf '%s\n' 'v2 from this session' >"${live}"
  notes_back_sync "${live}" "${canon}"
  [ "$(cat "${canon}")" = "v2 from this session" ]
  # The copy that replaced real notes archives what was there first, under the
  # repo's own notes directory, where the owner can find it.
  [ -d "$(dirname "${canon}")/backups" ]
  [ "$(ls -1 "$(dirname "${canon}")/backups" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(cat "$(dirname "${canon}")/backups"/notes-*.md)" = "v1 on the volume" ]
  # A canonical copy that does not exist yet is only created: there is nothing to
  # archive, so a first sync must not leave a backups directory behind either.
  fresh="$(canon_of "github.com/acme/brandnew")"
  printf '%s\n' 'the first write' >"${live}"
  notes_back_sync "${live}" "${fresh}"
  [ "$(cat "${fresh}")" = "the first write" ]
  [ ! -e "$(dirname "${fresh}")/backups" ]
}

@test "notes_backup_canon: a stub or an empty canonical copy archives nothing" {
  local canon backups
  canon="$(canon_of "github.com/acme/keptempty")"
  backups="$(dirname "${canon}")/backups"
  mkdir -p "${backups}"
  write_stub "${canon}" "${canon}"
  notes_backup_canon "${canon}"
  [ -z "$(ls -A "${backups}")" ]
  : >"${canon}"
  notes_backup_canon "${canon}"
  [ -z "$(ls -A "${backups}")" ]
  # An empty argument is the same "nothing to keep" answer, and it invents no
  # archive next to the notes directory.
  notes_backup_canon ""
  [ -z "$(ls -A "${backups}")" ]
  [ ! -e "${HOME}/.grok/notes/backups" ]
}

@test "notes_backup_canon: NOTES_BACKUP_KEEP trims to the newest archives only" {
  local canon backups i ts kept=()
  canon="$(canon_of "github.com/acme/trimmed")"
  backups="$(dirname "${canon}")/backups"
  mkdir -p "${backups}"
  printf '%s\n' 'the content being archived now' >"${canon}"
  # Four archives already on the clock, older than anything this call can name,
  # so a keep of two must leave the newest of these plus the new one.
  for i in 1 2 3 4; do
    ts="$(printf '20260101-00000%s' "${i}")"
    printf '%s\n' "archived ${ts}" >"${backups}/notes-${ts}.md"
    touch -d "2026-01-01 00:00:0${i}" "${backups}/notes-${ts}.md"
  done
  NOTES_BACKUP_KEEP=2 notes_backup_canon "${canon}"
  mapfile -t kept < <(ls -1 "${backups}")
  [ "${#kept[@]}" -eq 2 ] ||
    { printf 'FAIL: kept %s of 5: %s\n' "${#kept[@]}" "${kept[*]}" >&2; return 1; }
  [ "${kept[0]}" = "notes-20260101-000004.md" ]
  [ "$(cat "${backups}/notes-20260101-000004.md")" = "archived 20260101-000004" ]
  [[ ${kept[1]} == notes-* ]]
  [ "${kept[1]}" != "notes-20260101-000004.md" ]
  [ "$(cat "${backups}/${kept[1]}")" = "the content being archived now" ]
}

@test "notes_materialize: a stale stub in the clone is replaced by the canonical copy" {
  local clone canon
  clone="$(make_clone "https://github.com/acme/stalestub.git")"
  canon="$(canon_of "github.com/acme/stalestub")"
  mkdir -p "$(dirname "${canon}")"
  printf '%s\n' 'what the last workspace wrote' >"${canon}"
  # The recreate case the restore branch was added for: the clone booted with its
  # seed, the volume holds the real notes, and an owner opening notes.md must not
  # sit on the stub forever just because the back-sync rightly refuses to let a
  # stub touch the canonical copy.
  write_stub "${clone}/notes.md" "${canon}"
  notes_materialize "${clone}"
  [ "$(cat "${clone}/notes.md")" = "what the last workspace wrote" ]
  [ "$(cat "${canon}")" = "what the last workspace wrote" ]
  # Restoring and then syncing an identical file is not a change, so the previous
  # canonical content is not archived either.
  [ ! -e "$(dirname "${canon}")/backups" ]
}

@test "notes_materialize: a stub live file never replaces the canonical copy" {
  local clone canon
  clone="$(make_clone "https://github.com/acme/stubkeep.git")"
  canon="$(canon_of "github.com/acme/stubkeep")"
  mkdir -p "$(dirname "${canon}")"
  # Both copies are stubs, and they name different paths, so nothing here may be
  # treated as the owner's work: the canonical line has to survive byte for byte.
  printf '%s\n' "${STUB_PREFIX}/somewhere/else/notes.md${STUB_SUFFIX}" >"${canon}"
  write_stub "${clone}/notes.md" "/another/place/notes.md"
  notes_materialize "${clone}"
  [ "$(cat "${canon}")" = "${STUB_PREFIX}/somewhere/else/notes.md${STUB_SUFFIX}" ]
  [ "$(cat "${clone}/notes.md")" = "${STUB_PREFIX}/another/place/notes.md${STUB_SUFFIX}" ]
  [ ! -e "$(dirname "${canon}")/backups" ]
}

@test "notes_sync_once: a past-dated live file is copied back and a just-written one waits" {
  local root clone canon
  root="$(make_scratch)/workspace"
  mkdir -p "${root}"
  clone="$(make_clone_under "${root}" "https://github.com/acme/ticked.git" "ticked")"
  canon="$(canon_of "github.com/acme/ticked")"
  printf '%s\n' 'written long after the start' >"${clone}/notes.md"
  # Written this very instant: the pass must leave it alone rather than archive or
  # copy a file the editor may still be saving.
  notes_sync_once "${root}"
  [ ! -e "${canon}" ]
  age_live "${clone}/notes.md"
  notes_sync_once "${root}"
  [ "$(cat "${canon}")" = "written long after the start" ]
}

@test "notes_sync_once: a plain directory, a keyless clone and a stub live file are all skipped" {
  local root plain keyless stubbed emptylive
  root="$(make_scratch)/workspace"
  mkdir -p "${root}"
  plain="${root}/plain-dir"
  mkdir -p "${plain}"
  printf '%s\n' 'notes with no repository behind them' >"${plain}/notes.md"
  keyless="${root}/no-origin"
  mkdir -p "${keyless}"
  git -C "${keyless}" init -q
  printf '%s\n' 'a clone with no remote to key on' >"${keyless}/notes.md"
  stubbed="$(make_clone_under "${root}" "https://github.com/acme/stubtick.git" "stubtick")"
  write_stub "${stubbed}/notes.md" "$(canon_of "github.com/acme/stubtick")"
  emptylive="$(make_clone_under "${root}" "https://github.com/acme/nolive.git" "nolive")"
  : >"${emptylive}/notes.md"
  # Every one of these is past the stability window, so what skips them is the
  # shape of the entry, not the clock.
  age_live "${plain}/notes.md"
  age_live "${keyless}/notes.md"
  age_live "${stubbed}/notes.md"
  age_live "${emptylive}/notes.md"
  notes_sync_once "${root}"
  # Nothing was copied, and nothing was filed under it either: the pass creates no
  # canonical tree at all when no clone has real notes.
  [ ! -e "${HOME}/.grok/notes" ]
}

@test "notes_sync_start: the detached watcher copies notes to the profile volume on its own" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this host"
  local root clone canon waited=0
  root="$(make_scratch)/workspace"
  mkdir -p "${root}"
  clone="$(make_clone_under "${root}" "https://github.com/acme/watched.git" "watched")"
  canon="$(canon_of "github.com/acme/watched")"
  printf '%s\n' 'written after the workspace started' >"${clone}/notes.md"
  age_live "${clone}/notes.md"
  notes_sync_start 1 "${root}"
  WATCH_ROOT="${root}"
  while [ ! -e "${canon}" ] && [ "${waited}" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "${canon}" ] ||
    { printf 'FAIL: the watcher left %s unsynced after 3s\n' "${clone}/notes.md" >&2; return 1; }
  [ "$(cat "${canon}")" = "written after the workspace started" ]
}

@test "notes_sync_start: a second start leaves the container one flock holder" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this host"
  command -v pgrep >/dev/null 2>&1 || skip "no pgrep on this host"
  local root holders="" waited=0
  root="$(make_scratch)/workspace"
  mkdir -p "${root}"
  notes_sync_start 1 "${root}"
  notes_sync_start 1 "${root}"
  WATCH_ROOT="${root}"
  # The second flock -n cannot take the lock and exits at once, so the count is
  # only settled once it is gone; the bracket keeps this pattern from matching
  # pgrep's own command line.
  while [ "${waited}" -lt 30 ]; do
    holders="$(pgrep -f -- "${PROFILE_HOME}/[.]notes-sync[.]lock" 2>/dev/null | wc -l | tr -d ' ' || true)"
    [ "${holders}" = "1" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "${holders}" = "1" ] ||
    { printf 'FAIL: %s processes hold %s/.notes-sync.lock\n' "${holders}" "${PROFILE_HOME}" >&2; return 1; }
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
