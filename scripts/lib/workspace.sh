# shellcheck shell=bash
#
# ## workspace.sh — pure helpers behind scripts/new-workspace.sh (sourced; never
# executed)
#
# Two jobs, neither of which may touch anything. Deriving the workspace NAME and
# the clone FOLDER that one repository URL maps to, and probing a repository for a
# dev container out of a depth-1 --no-checkout clone.
#
# Invariants:
#   - Sourcing this file creates no workspace, runs no clone and writes no file:
#     it only defines functions, inherits the caller's shell options, and reads no
#     caller variable. Everything a helper needs arrives as an argument, which is
#     what lets tests/bats/workspace.bats call these directly.
#   - A clone FOLDER keeps the source case and a workspace NAME does not. That
#     split is deliberate (see clone_folder_of_url and leaf_of_url): Coder names
#     are lowercase, the templates re-derive the folder with case intact, and one
#     function cannot serve both masters.
#
# Usage (from an entry script, which never cds, hence SELF_DIR):
#   # shellcheck source=lib/workspace.sh disable=SC1091
#   source "${SELF_DIR}/lib/workspace.sh"

# ── Names and folders ────────────────────────────────────────────────────────

# @function sanitize_leaf
# Lowercase a name and map every character outside [a-z0-9-] to "-", collapse
# those runs, and trim the ends.
# Globals:
#   None
# Arguments:
#   $1 - text to sanitize
# Outputs:
#   The sanitized text, which may be empty
# Returns:
#   0
sanitize_leaf() {
  # tr -c works byte by byte, so a multi-byte character becomes one run of
  # dashes rather than one dash per byte.
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' |
    sed -e 's/--*-/-/g' -e 's/^-//' -e 's/-$//'
}

# @function leaf_of_url
# Print the lowercase leaf used for the workspace NAME (Coder names are lowercase;
# see name_from_url and sanitize_leaf). The clone FOLDER keeps the source case and
# is derived by clone_folder_of_url instead, because the templates re-derive it
# with case intact.
# Globals:
#   None
# Arguments:
#   $1 - repository URL or local path
# Outputs:
#   The lowercase leaf, possibly empty
# Returns:
#   0
leaf_of_url() {
  local leaf
  leaf="$(printf '%s' "$1" | tr '/' '\n' | grep -v '^[[:space:]]*$' | tail -n 1)"
  leaf="$(printf '%s' "$leaf" | sed -e 's|?.*$||' -e 's|#.*$||' -e 's|\.git$||')"
  sanitize_leaf "$leaf"
}

# @function name_from_url
# Print the workspace name to use: leaf_of_url plus the two rules Coder's own name
# check needs — start with a letter, stay under 40 characters.
# Globals:
#   None
# Arguments:
#   $1 - repository URL or local path
# Outputs:
#   The workspace name, "repo" for a URL whose leaf leaves nothing behind
# Returns:
#   0
name_from_url() {
  local leaf
  leaf="$(leaf_of_url "$1")"
  [ -n "$leaf" ] || leaf="repo"
  case "$leaf" in [a-z]*) ;; *) leaf="x${leaf}" ;; esac
  printf '%s' "$leaf" | cut -c1-40 | sed -e 's/-$//'
}

# @function clone_folder_of_url
# Print the folder the TEMPLATE will clone into, case kept intact: the last "/"
# segment with any query/fragment and a trailing ".git" dropped, every character
# outside [A-Za-z0-9._-] mapped to "-", and "repo" when that leaves no leading
# alphanumeric. An exact mirror of the templates' own repo_folder re-derivation,
# which is the parity this buys: print "…/imagesharp" for a repository the template
# clones into "ImageSharp" and the printed path names a folder that will never
# exist. The workspace NAME takes the lowercase leaf_of_url instead, which is why
# this exists separately.
# Globals:
#   None
# Arguments:
#   $1 - repository URL or local path
# Outputs:
#   The case-preserving clone folder, "repo" when no folder would be usable
# Returns:
#   0
clone_folder_of_url() {
  local leaf
  leaf="$(printf '%s' "$1" | tr '/' '\n' | grep -v '^[[:space:]]*$' | tail -n 1)"
  leaf="$(printf '%s' "$leaf" | sed -e 's|?.*$||' -e 's|#.*$||' -e 's|\.git$||')"
  leaf="$(printf '%s' "$leaf" | tr -c 'A-Za-z0-9._-' '-')"
  if printf '%s' "$leaf" | grep -qE '^[A-Za-z0-9]'; then printf '%s' "$leaf"; else printf 'repo'; fi
}

# ── Probe ────────────────────────────────────────────────────────────────────

# @function probe_repo
# Clone one repository (depth 1, --no-checkout) under <work> and ask git for its
# tracked files, so a dev container can be recognised without a working copy.
# <work> arrives as an argument rather than being read from the caller, so nothing
# here depends on a global the entry script happens to own.
# Globals:
#   None
# Arguments:
#   $1 - temporary directory holding the probe clone (and probe.err, which the
#        clone and the listing write their stderr to; the caller deletes the tree)
#   $2 - repository URL or local path
#   $3 - folder to clone into, under $1
# Outputs:
#   Nothing on stdout; the file listing stays inside the function
# Returns:
#   0 when a dev container is tracked, 1 when the clone fails, 2 when the listing
#   fails, 3 when it lists no dev container
probe_repo() {
  # --filter=blob:none is deliberately absent: it is not honoured by older
  # servers, and a private Gitea on the LAN is where it would be tried.
  local work="$1" src="$2" dst="$3" listing rc=0
  if ! git -C "${work}" clone --quiet --depth 1 --no-checkout --single-branch \
    -- "$src" "$dst" 2>"${work}/probe.err"; then
    return 1
  fi
  listing="$(git -C "$dst" ls-tree -r --name-only HEAD 2>>"${work}/probe.err")" || rc=$?
  if [ "$rc" != 0 ]; then
    return 2
  fi
  if printf '%s\n' "$listing" | grep -qE \
    '(^|/)\.devcontainer/|(^|/)\.github/devcontainers/|(^|/)devcontainer\.(json|yml)$'; then
    return 0
  fi
  return 3
}
