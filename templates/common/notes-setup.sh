# shellcheck shell=bash
# managed-by: evo-t1-coder-stack
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
#     startup scripts run with `set -u`, so an unset or empty argument — HOME
#     included — is a normal input here, not an error.
#   - The live file is never a symlink to ~/.grok. On the devcontainer template the
#     inner container mounts the clone bind and gets a different ~/.grok, so a
#     symlink there would point at nothing inside it.
#   - The canonical copy tracks the live one: last-started workspace wins for the
#     same owner and repository, the same rule ~/.grok/config.toml already follows.
#   - Nothing here commits the file. The excludes it writes (global excludesFile
#     plus the clone's own .git/info/exclude) are the belt; this repo's .gitignore
#     is the braces for clones of this repo itself.
#   - A file the developer owns is never rewritten, only appended to, and only
#     when core.excludesFile names an absolute file: git expands a leading ~ when
#     it reads that value and this shell does not, so an unexpanded path would
#     create a stray "./~" instead of touching the real file, and a value that
#     names a directory has no file to append to at all.
#   - A key is only ever used as a path suffix, so dot segments are refused
#     rather than allowed to walk out of ~/.grok/notes/.
#
# Usage (from the rendered startup script, which inlines this file from
# templates/common/ through main.tf's notes_setup key). The script sources the copy
# it just published and then reaches this library only through its run_notes
# wrapper, which is what calls notes_materialize for one clone:
#   # shellcheck disable=SC1090
#   . "$HOME/.grok/notes-setup.sh" 2>/dev/null || true
#   run_notes "$clone_dir" "$clone_url"
# run_notes runs it as the uid that owns the workspace home.

# notes_repo_key <url> — normalize a git remote or clone URL to host/owner/repo.
# @function notes_repo_key
# Print <url> lowercased and reduced to host/owner/repo.
# Globals:
#   None
# Arguments:
#   $1 - remote or clone URL: https://, ssh:// (with or without a port) or the
#     scp-style git@host: form, with or without a trailing slash and .git
# Outputs:
#   Lowercased host/owner/repo on stdout; nothing for an unusable input
# Returns:
#   0 on success; 1 when the input is empty, carries no owner/repo pair, or holds
#   a . or .. segment
notes_repo_key() {
  local raw="${1:-}" rest="" host="" owner="" repo="" tail=""
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
  # A colon ends the host in both remaining shapes: host:owner/repo is the scp
  # spelling and host:22/owner/repo is a ported ssh:// URL. What follows the
  # colon decides which, because the two spellings of one repository have to
  # produce one key — a port kept as a path segment would split them.
  if [[ ${rest} == *:* && ${rest%%:*} != */* ]]; then
    tail="${rest#*:}"
    if [[ ${tail%%/*} =~ ^[0-9]+$ ]]; then
      rest="${rest%%:*}/${tail#*/}"
    else
      rest="${rest%%:*}/${tail}"
    fi
  fi
  rest="${rest%.git}"
  # host plus at least owner/repo; anything shallower is not a repository.
  case "${rest}" in
    */*/*) : ;;
    *) return 1 ;;
  esac
  # Padded so a leading or trailing dot segment still reads as /./ or /../.
  case "/${rest}/" in
    *"/./"* | *"/../"*) return 1 ;;
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
#   $HOME/.grok/notes/<key>/notes.md on stdout; nothing for a unusable input
# Returns:
#   0 on success; 1 when the key or HOME is empty, so the caller skips
notes_canonical_path() {
  local key="${1:-}" home="${HOME:-}"
  if [ -z "${key}" ] || [ -z "${home}" ]; then
    return 1
  fi
  printf '%s\n' "${home}/.grok/notes/${key}/notes.md"
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

# notes_append_once <file> <line...> — append each line to a file when absent.
# @function notes_append_once
# Append lines to a gitignore-style file, leaving the lines already in it alone.
# Globals:
#   None
# Arguments:
#   $1 - file to append to (created when missing); remaining args - the lines
# Outputs:
#   One line per entry that could not be written, on stderr
# Returns:
#   0 always — an unwritable excludes file must not stop a workspace start
notes_append_once() {
  local file="${1:-}" line=""
  if [ "$#" -lt 2 ] || [ -z "${file}" ]; then
    return 0
  fi
  shift
  # A hand-edited ignore file often has no final newline, and appending into
  # that would fuse the developer's last pattern with ours.
  if [ -s "${file}" ] && [ -n "$(tail -c 1 "${file}" 2>/dev/null)" ]; then
    # Braces, not a redirect on the command: a failed > is reported by the shell
    # itself, on the stderr that redirect has not been installed on yet.
    { printf '\n' >>"${file}"; } 2>/dev/null || true
  fi
  for line in "$@"; do
    if [ -n "${line}" ] && ! grep -qxF -- "${line}" "${file}" 2>/dev/null; then
      if ! { printf '%s\n' "${line}" >>"${file}"; } 2>/dev/null; then
        printf 'notes: could not add %s to %s\n' "${line}" "${file}" >&2
      fi
    fi
  done
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
#   One line per excludes file it could not write, or per unusable
#   core.excludesFile, on stderr
# Returns:
#   0 always
notes_ensure_excludes() {
  local root="${1:-}" home="${HOME:-}" stack_exclude="" user_exclude=""
  if [ -n "${home}" ]; then
    stack_exclude="${home}/.grok/notes/exclude"
    # The canonical copies of every repo's notes live under here, so the directory
    # is made whatever config says; the exclude file inside it is only written
    # when git is actually going to read it.
    mkdir -p "${home}/.grok/notes" 2>/dev/null || true
    # Never clobber a file the developer owns: when core.excludesFile already
    # points somewhere, that file gets the two lines instead of being replaced.
    user_exclude="$(git config --global --get core.excludesFile 2>/dev/null || true)"
    # git expands a leading ~ when it reads the value; the shell here has to do
    # the same before the path means anything. A ~user form stays as it is and
    # falls through to the absolute-path rule below.
    case "${user_exclude}" in
      \~) user_exclude="${home}" ;;
      \~/*) user_exclude="${home}/${user_exclude#\~/}" ;;
    esac
    if [ -z "${user_exclude}" ]; then
      # Nothing was named, so the file set here is the one git will consult.
      notes_append_once "${stack_exclude}" notes.md .scratch-notes.md
      git config --global core.excludesFile "${stack_exclude}" 2>/dev/null || true
    elif [[ ${user_exclude} != /* ]]; then
      # A relative value resolves against whatever directory git runs in, so
      # appending here would write next to a clone rather than where it applies.
      printf 'notes: core.excludesFile=%s is not absolute\n' "${user_exclude}" >&2
    elif [ -d "${user_exclude}" ]; then
      # An absolute path is not enough: a directory has no lines to append to,
      # and a doomed write there would say so twice per start.
      printf 'notes: core.excludesFile=%s is a directory\n' "${user_exclude}" >&2
    else
      mkdir -p "$(dirname "${user_exclude}")" 2>/dev/null || true
      notes_append_once "${user_exclude}" notes.md .scratch-notes.md
    fi
  fi
  if [ -n "${root}" ] && [ -d "${root}/.git" ]; then
    mkdir -p "${root}/.git/info" 2>/dev/null || true
    notes_append_once "${root}/.git/info/exclude" notes.md .scratch-notes.md
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
  mkdir -p "$(dirname "${canon}")" 2>/dev/null || true
  if [ ! -e "${live}" ]; then
    if [ -f "${canon}" ]; then
      cp -f "${canon}" "${live}" 2>/dev/null || true
    else
      # The profile-volume path is the workspace container's, which is not the
      # home a nested dev container sees, so it is named as the volume's entry
      # rather than as a file the reader can cd to.
      stub="Private scratch notes for this repository. Not committed. Canonical copy on this owner's shared Grok profile volume: ${canon} (survives workspace recreate)."
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
