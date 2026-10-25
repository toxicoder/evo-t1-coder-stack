# shellcheck shell=bash
#
# ## notes-setup.sh — private per-repository scratch notes (sourced; never
# executed)
#
# A developer's own notes.md sits at each clone root, so the editor, the web
# terminal and a nested dev container all open on the same regular file, and the
# copy that survives lives on the shared grok-profile-<owner-id> volume under
# ~/.grok/notes/<host>/<owner>/<repo>/. Keyed per git remote, so every clone in a
# workspace — the primary and each additional_repos entry — gets its own file, and
# the per-owner volume is what keeps one developer's notes out of another's.
#
# Invariants:
#   - Best-effort throughout: every function returns 0 after putting its complaint
#     on stderr, because a workspace start must not hinge on a scratch file. The
#     startup scripts run with `set -u`, so an unset or empty argument is a normal
#     input here, not an error.
#   - The live file is never a symlink to ~/.grok. On the devcontainer template the
#     inner container mounts the clone bind and gets a different ~/.grok, so a
#     symlink there would point at nothing inside it.
#   - The canonical copy tracks the live one: last-started workspace wins for the
#     same owner and repository, the same rule ~/.grok/config.toml already follows.
#   - Nothing here commits the file. The excludes it writes (global excludesFile
#     plus the clone's own .git/info/exclude) are the belt; this repo's .gitignore
#     is the braces for clones of this repo itself.
#
# Usage (from the rendered startup script, which inlines this file from
# templates/common/ through main.tf's notes_setup key):
#   # shellcheck disable=SC1090
#   . "$HOME/.grok/notes-setup.sh" 2>/dev/null || true
#   notes_materialize "$clone_dir" "$clone_url" || true

# notes_repo_key <url> — normalize a git remote or clone URL to host/owner/repo.
# @function notes_repo_key
# Print <url> lowercased and reduced to host/owner/repo.
# Globals:
#   None
# Arguments:
#   $1 - remote or clone URL: https://, ssh:// or the scp-style git@host: form,
#     with or without a trailing slash and .git
# Outputs:
#   Lowercased host/owner/repo on stdout; nothing when the URL has no owner/repo
# Returns:
#   0 on success; 1 when the input is empty or carries no owner/repo pair
notes_repo_key() {
  local raw="${1:-}" rest="" host="" owner="" repo=""
  if [ -z "${raw}" ]; then
    return 1
  fi
  # Lowercased whole: host, owner and repo all normalize the same way, and git
  # treats the case of a repository path as cosmetic on the hosts that matter.
  rest="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  while [ "${rest}" != "${rest%/}" ]; do
    rest="${rest%/}"
  done
  case "${rest}" in
    *"://"*) rest="${rest#*://}" ;;
  esac
  # The login is a credential slot, never part of the key.
  case "${rest}" in
    *"@"*) rest="${rest#*@}" ;;
  esac
  # The scp form separates host from path with a colon rather than a slash; a
  # colon that follows a slash is a port, which the split below drops anyway.
  if [[ ${rest} == *:* && ${rest%%:*} != */* ]]; then
    rest="${rest%%:*}/${rest#*:}"
  fi
  rest="${rest%.git}"
  # host plus at least owner/repo; anything shallower is not a repository.
  case "${rest}" in
    */*/*) : ;;
    *) return 1 ;;
  esac
  host="${rest%%/*}"
  repo="${rest##*/}"
  owner="${rest#*/}"
  owner="${owner%/*}"
  if [ -z "${host}" ] || [ -z "${owner}" ] || [ -z "${repo}" ]; then
    return 1
  fi
  printf '%s\n' "${host}/${owner}/${repo}"
}

# notes_canonical_path <key> — where the copy that survives a recreate lives.
# @function notes_canonical_path
# Print the profile-volume path a repo key's notes live at.
# Globals:
#   HOME
# Arguments:
#   $1 - repo key as host/owner/repo (may hold more slashes; a GitLab subgroup
#     keeps them all, which is what keeps two same-named repos apart)
# Outputs:
#   $HOME/.grok/notes/<key>/notes.md on stdout; nothing for an empty key
# Returns:
#   0 always (the empty-key case is a 1, so a caller can skip)
notes_canonical_path() {
  local key="${1:-}"
  if [ -z "${key}" ]; then
    return 1
  fi
  printf '%s\n' "${HOME}/.grok/notes/${key}/notes.md"
}

# notes_live_name <clone-root> — the file name a clone may hold notes under.
# @function notes_live_name
# Print the notes file name to use inside a clone.
# Globals:
#   None
# Arguments:
#   $1 - clone root
# Outputs:
#   .scratch-notes.md when the repository tracks notes.md itself, notes.md
#   otherwise. An unreadable directory, or no git on PATH, answers notes.md.
# Returns:
#   0 always — the default name is a valid answer for any input
notes_live_name() {
  local root="${1:-}"
  if [ -n "${root}" ] && git -C "${root}" ls-files --error-unmatch notes.md >/dev/null 2>&1; then
    printf '%s\n' ".scratch-notes.md"
  else
    printf '%s\n' "notes.md"
  fi
}

# notes_append_once <file> <line> — append <line> to <file> when it is absent.
# @function notes_append_once
# Append one line to a gitignore-style file, leaving it untouched when present.
# Globals:
#   None
# Arguments:
#   $1 - file to append to (created when missing); $2 - the line
# Outputs:
#   A write error on stderr
# Returns:
#   0 always — an unwritable excludes file must not stop a workspace start
notes_append_once() {
  local file="${1:-}" line="${2:-}"
  if [ -z "${file}" ] || [ -z "${line}" ]; then
    return 0
  fi
  if ! grep -qxF -- "${line}" "${file}" 2>/dev/null; then
    if ! printf '%s\n' "${line}" >>"${file}" 2>/dev/null; then
      printf 'notes: could not add %s to %s\n' "${line}" "${file}" >&2
    fi
  fi
  return 0
}

# notes_ensure_excludes <clone-root> — hide the scratch file from git.
# @function notes_ensure_excludes
# Make git ignore both scratch names, globally and inside one clone.
# Globals:
#   HOME
# Arguments:
#   $1 - clone root (the per-clone excludes; skipped when it holds no .git)
# Outputs:
#   One line per unwritable excludes file on stderr
# Returns:
#   0 always
notes_ensure_excludes() {
  local root="${1:-}" dir="${HOME}/.grok/notes" stack_exclude="" user_exclude="" name=""
  stack_exclude="${dir}/exclude"
  mkdir -p "${dir}" 2>/dev/null || true
  for name in notes.md .scratch-notes.md; do
    notes_append_once "${stack_exclude}" "${name}"
  done
  # Never clobber a file the developer owns: when core.excludesFile already points
  # somewhere, that file gets the two lines instead of being replaced.
  user_exclude="$(git config --global --get core.excludesFile 2>/dev/null || true)"
  if [ -z "${user_exclude}" ]; then
    git config --global core.excludesFile "${stack_exclude}" 2>/dev/null || true
  else
    mkdir -p "$(dirname "${user_exclude}")" 2>/dev/null || true
    for name in notes.md .scratch-notes.md; do
      notes_append_once "${user_exclude}" "${name}"
    done
  fi
  if [ -n "${root}" ] && [ -d "${root}/.git" ]; then
    mkdir -p "${root}/.git/info" 2>/dev/null || true
    for name in notes.md .scratch-notes.md; do
      notes_append_once "${root}/.git/info/exclude" "${name}"
    done
  fi
  return 0
}

# notes_materialize <clone-root> [fallback-url] — put the clone's notes in place.
# @function notes_materialize
# Restore the canonical copy into a clone, seed a stub when there is none, and
# copy the live file back so the profile volume tracks it.
# Globals:
#   HOME
# Arguments:
#   $1 - clone root; $2 - clone URL used only when the clone has no origin
# Outputs:
#   The clone's notes file and its canonical copy; warnings on stderr
# Returns:
#   0 always — a clone with no derivable key is skipped, not an error
notes_materialize() {
  local root="${1:-}" fallback="${2:-}" key="" live="" canon="" stub=""
  if [ -z "${root}" ] || [ ! -d "${root}" ]; then
    return 0
  fi
  key="$(git -C "${root}" remote get-url origin 2>/dev/null || true)"
  [ -n "${key}" ] || key="${fallback}"
  key="$(notes_repo_key "${key}")" || {
    printf 'notes: no repo key for %s — leaving its notes alone\n' "${root}" >&2
    return 0
  }
  live="${root}/$(notes_live_name "${root}")"
  canon="$(notes_canonical_path "${key}")" || return 0
  mkdir -p "$(dirname "${live}")" 2>/dev/null || true
  mkdir -p "$(dirname "${canon}")" 2>/dev/null || true
  if [ ! -e "${live}" ]; then
    if [ -f "${canon}" ]; then
      cp -f "${canon}" "${live}" 2>/dev/null || true
    else
      stub="Private scratch notes for this repository. Not committed. Canonical copy: ~/.grok/notes/${key}/notes.md (survives workspace recreate)."
      printf '%s\n' "${stub}" >"${live}" 2>/dev/null || true
    fi
  fi
  # Back to the profile volume last, so a recreate finds whatever the last
  # session left in the clone rather than the stub it started from.
  if [ -f "${live}" ]; then
    cp -f "${live}" "${canon}" 2>/dev/null || true
  fi
  notes_ensure_excludes "${root}"
  return 0
}
