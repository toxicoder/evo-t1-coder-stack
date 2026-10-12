# shellcheck shell=bash
#
# ## template-push.sh — push Coder template sources (sourced; never executed)
#
# The two Coder templates (`workspace`, `devcontainer`) travel to the
# server as tar streams on stdin, get confirmed through their versions list,
# and then carry their chat-agent routing hint and their autostop default via
# `templates edit`. push-template does both writes per template; the same
# plumbing shape reappears around the devcontainer flow. The primitives live
# here so the entry scripts keep their
# policy and log wording while the plumbing itself stays unit-testable in
# isolation.
#
# Invariants:
#   - Sourcing this file changes no shell options and no cwd. The functions run
#     with the CALLER's options: under `set -e -o pipefail` a failed tar or a
#     non-zero CLI exit surfaces to the caller as a failed command line, which
#     is exactly what the entry scripts count and report.
#   - What ships is a staging copy, never the template dir itself: the stack's
#     one seed payload (GROK_BUILD_AGENTS.md, kept one level above the
#     template dirs under common/) rides along in every staged copy, because
#     that is where the server-side Terraform reads it from.
#   - No timeout cap on the push itself: a server-side Terraform plan+apply
#     legitimately takes minutes; capping it would fail correct pushes.
#   - Credentials travel in the environment (via compose -e NAME flags), never
#     in argv, where `ps` would show them.
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root `cd`):
#   # shellcheck source=lib/template-push.sh disable=SC1091
#   source "scripts/lib/template-push.sh"   # sources common.sh + coder_api.sh when needed
# The caller is expected to have set DOCKER_BIN, CODER_SERVICE,
# CONTAINER_API_URL and session_token (defaults and knobs: scripts/lib/coder_api.sh).

if ! declare -f has_tool >/dev/null 2>&1; then
  # shellcheck source=lib/common.sh disable=SC1091
  source "${BASH_SOURCE[0]%/*}/common.sh"
fi
if ! declare -f coder_exec >/dev/null 2>&1; then
  # shellcheck source=lib/coder_api.sh disable=SC1091
  source "${BASH_SOURCE[0]%/*}/coder_api.sh"
fi

# UUID_RE — the version/workspace id shape. template_verify_active lifts the
# ACTIVE version's id out of table output with it; entry scripts that carry
# their own copy may keep it, the guard below only supplies a default.
if [ -z "${UUID_RE:-}" ]; then
  # Quoted literal: the {8}-style quantifiers survive literally, which the
  # ${VAR:-default} form would mangle (expansion ends inside the braces).
  UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
fi

# template_push_one <name> <dir> [push-args...] — push <dir> as template
# <name>, but never <dir> itself: copy it into a throwaway staging dir,
# overwrite GROK_BUILD_AGENTS.md there with the stack's one common copy (the
# seed lives in <dir>'s sibling common/ dir; both templates' main.tf reads it
# with file() and inlines it into the startup script, and the server resolves
# that reference inside the pushed copy, which is why the copy must carry the
# seed). The staged tree then streams as the tar on stdin. .terraform/ is
# excluded: it is gitignored provider cache, and pushing it would put the
# plan's provider binaries into the version's Filestore row. A missing seed is
# a hard stop — the push would die in the server's Terraform anyway; naming
# the missing file here costs the operator one line instead of a confused
# debugging session there. Trailing arguments are appended verbatim to the CLI
# line, so a caller's shared `--var` array passes through:
#   template_push_one "$name" "$dir" ${vars[@]+"${vars[@]}"}
# The token stays out of argv via -e NAME (value through the environment);
# stdin is the tar, which is why -T -i stay on the compose exec flags.
# @function template_push_one
# Stage a template dir with the common seed payload, then push it as a tar.
# .terraform is excluded; a staged copy always carries the seed, and a
# missing seed fails the push before the CLI runs.
# Globals:
#   DOCKER_BIN, CODER_SERVICE, CONTAINER_API_URL, session_token
# Arguments:
#   $1 - template name; $2 - directory; remaining args pass to templates push
# Outputs:
#   The coder CLI's output; the reason on stderr when staging cannot run
# Returns:
#   The pipeline's status; 1 when the staging dir, the seed, or the copy fails
template_push_one() {
  local name="$1" dir="$2"
  shift 2
  local stage="" seed="" push_rc=0
  stage="$(mktemp -d)" || return 1
  seed="$(dirname "${dir}")/common/GROK_BUILD_AGENTS.md"
  if [ ! -f "${seed}" ]; then
    rm -rf "${stage}"
    printf 'error: %s: %s is missing — main.tf inlines it into the startup script, so no push works without it\n' \
      "${name}" "${seed}" >&2
    return 1
  fi
  # The staging copy is built rather than streamed from the template dir
  # directly, so the common seed copy can be dropped in beside main.tf — and
  # it overwrites any same-named file the dir still carries: one source of
  # truth per payload, so the per-template twins cannot drift back apart.
  if ! { tar -C "${dir}" --exclude=./.terraform -cf - . | tar -xf - -C "${stage}" &&
    cp -f "${seed}" "${stage}/GROK_BUILD_AGENTS.md"; }; then
    rm -rf "${stage}"
    printf 'error: %s: could not stage %s (with %s) — nothing was pushed\n' \
      "${name}" "${dir}" "${seed}" >&2
    return 1
  fi
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  tar -C "${stage}" -cf - . |
    CODER_URL="${CONTAINER_API_URL:-}" CODER_SESSION_TOKEN="${session_token:-}" \
      ${DOCKER_BIN} compose exec -T -i \
      -e CODER_URL -e CODER_SESSION_TOKEN "${CODER_SERVICE}" \
      coder templates push "${name}" --directory - --yes "$@"
  push_rc=$?
  rm -rf "${stage}"
  return "${push_rc}"
}

# template_verify_active <name> — confirm <name> reached an ACTIVE version: a
# push can exit 0 while leaving the template inactive (a failing Terraform run
# produces a version that is present but never activated), and an inactive
# template offers no workspace dropdown. Prints the active version's id on
# success; on failure prints the CLI output plus one error line to stderr and
# returns non-zero, leaving the caller to count failures.
# Table output, not -o json: the JSON form nests the whole TemplateVersion, so
# finding the active version's id would need a JSON parser this repo does not
# depend on. The active cell renders as the word "Active" (ANSI-wrapped, but
# contiguous), so the id is taken from that row; the header row carries the
# same word and no uuid.
# @function template_verify_active
# Print the ACTIVE version id of a template, or fail when there is none.
# Globals:
#   UUID_RE, coder_exec, CODER_SERVICE
# Arguments:
#   $1 - template name
# Outputs:
#   The version id on stdout; the CLI dump and an error line on failure
# Returns:
#   0 when an active id is found; 1 otherwise
template_verify_active() {
  local name="$1" verify_rc=0 verify_out="" active_id=""
  verify_out="$(coder_exec templates versions list "${name}" --column id --column active 2>&1)" || verify_rc=$?
  if [ "${verify_rc}" != "0" ]; then
    printf '%s\n' "${verify_out}" >&2
    printf 'error: pushed %s but could not read its versions (exit %s) — inspect from the host: docker compose exec %s coder templates versions list %s\n' \
      "${name}" "${verify_rc}" "${CODER_SERVICE}" "${name}" >&2
    return 1
  fi
  active_id="$(printf '%s\n' "${verify_out}" |
    grep -i active |
    grep -oE "${UUID_RE}" |
    sed -n '1p' || true)"
  if [ -z "${active_id}" ]; then
    printf '%s\n' "${verify_out}" >&2
    printf 'error: pushed %s but it has no active version — new workspaces cannot use it; inspect: docker compose exec %s coder templates versions list %s\n' \
      "${name}" "${CODER_SERVICE}" "${name}" >&2
    return 1
  fi
  printf '%s' "${active_id}"
}

# template_set_description <name> <text> — send the routing hint the Coder
# Agents chat reads to pick a template (push has no --description flag, so the
# text travels on the template row; the same write the UI's editor makes).
# Advisory by design: prints nothing, returns non-zero on failure, and treats
# an empty <text> as a skip (return 0) — the caller owns the log wording.
# @function template_set_description
# Set a template description. An empty description is a skip.
# Globals:
#   coder_exec
# Arguments:
#   $1 - template name; $2 - description text
# Outputs:
#   None
# Returns:
#   0 on success or an empty description; the CLI's status otherwise
template_set_description() {
  if [ "$#" -lt 2 ] || [ -z "${2}" ]; then
    return 0
  fi
  coder_exec templates edit "${1}" --description "${2}" >/dev/null 2>&1
}

# template_set_autostop_off <name> — pin <name>'s autostop defaults OFF: a 0 default TTL
# and a 0 activity bump. Coder reads the template's default TTL ("Default autostop" in the
# UI) when it seeds a workspace, and that field defaults to 24 h — the same 24 h
# `coder templates create --default-ttl` carries. Non-nil is what gives a new workspace a
# stop deadline and pre-ticks the create form's "Enable Autostop" checkbox; pinned to 0
# there is no deadline and nothing to extend, so a workspace stays up until its owner
# stops it. `templates push` has no TTL flag, which makes this the only write that can
# move the value, and it is advisory like the description write: prints nothing, returns
# non-zero on failure, and leaves the log wording to the caller.
# @function template_set_autostop_off
# Set a template's default TTL and activity bump to 0, which leaves autostop disabled.
# Globals:
#   coder_exec
# Arguments:
#   $1 - template name
# Outputs:
#   None
# Returns:
#   0 on success; the CLI's status otherwise
template_set_autostop_off() {
  coder_exec templates edit "${1}" --default-ttl 0 --activity-bump 0 >/dev/null 2>&1
}
