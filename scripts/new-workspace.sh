#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## new-workspace.sh — Create a Coder workspace for one git repository, in one command.
#
# Two things are decided here, in this order.
#
# 1. Which template the workspace gets. The repository is cloned (depth 1,
#    --no-checkout) into a temporary directory on the host and searched for a
#    dev container: .devcontainer/, .github/devcontainers/, or a
#    devcontainer.json/.yml at the top level or in a subdirectory. Found ->
#    devcontainer, which builds that file on a privileged DinD sidecar. Not
#    found -> workspace, which clones the repository itself and starts
#    code-server plus Grok Build on the clone.
#
# 2. Which parameter values travel with it. Both templates carry a repo_url
#    parameter, so the clone URL is passed instead of being retyped in the form.
#    --additional-repos adds to that list rather than replacing it: the extra
#    URLs ride along as the template's additional_repos parameter, one
#    comma-separated string, whatever separator the caller used.
#
#    use_devcontainer belongs to the devcontainer template only, defaults to true, and
#    gates whether the dev container is built at all — and that build also decides
#    where code-server attaches, because the editor lives inside the dev container
#    when one is built. So on a repository that carries no devcontainer.json,
#    leaving the toggle at its default buys nothing: no dev container comes up, and
#    the editor that would have attached to it never appears either. That is the
#    one case this script passes --parameter use_devcontainer=false for.
#    The workspace template never receives that parameter, because it has none.
#
#    dind belongs to the workspace template only (default false, and immutable:
#    switching it later means a rebuild). --dind passes it as true.
#
# Everything else is left to --use-parameter-defaults.
#
# Nothing here mints, reads or stores a Coder token and there is no database
# access: unlike scripts/push-template.sh, which inserts a short-lived key into
# api_keys because a template push has no other credential path, this script either
# uses a credential you already have or prints what to type yourself. When it
# cannot create anything it says so, prints the manual route (Coder UI, or the
# same command run inside the coder container), and exits 0 — a logged-out CLI or
# a stopped daemon is a "not yet" state rather than an error, and this script is
# meant to be safe to re-run.
#
# Usage (Bazel is the entry point; every example below is the whole command):
#   bazelisk run //scripts:new-workspace -- --dry-run https://github.com/foo/bar.git
#   bazelisk run //scripts:new-workspace -- https://github.com/foo/bar.git   # auto
#   bazelisk run //scripts:new-workspace -- --dry-run /srv/repos/my-tool     # local path
#   bazelisk run //scripts:new-workspace -- --plain https://github.com/foo/bar.git
#   bazelisk run //scripts:new-workspace -- --dind https://github.com/foo/bar.git
#   bazelisk run //scripts:new-workspace -- --devcontainer git@git.example.com:org/private.git
#   bazelisk run //scripts:new-workspace -- --additional-repos "one.git,two.git" https://github.com/foo/bar.git
#   bazelisk run //scripts:new-workspace -- --template workspace --name ml-scratch repo.git
#
# Options:
#   --dry-run          print the decision and the exact command, create nothing
#   --plain            force the workspace template even where a dev container exists
#   --devcontainer     force the devcontainer template even where the probe
#                      finds nothing — that create gets --parameter
#                      use_devcontainer=false, which starts no dev container and
#                      opens the editor on the clone instead (it needs a rebuild to
#                      flip, so the workspace template is usually what is meant)
#   --dind             the workspace template plus --parameter dind=true, for a
#                      repository you trust and a machine you own: a private daemon
#                      on a shared box is what SECURITY.md is about
#   --template <name>  full override of the template choice, workspace or
#                      devcontainer; the probe still runs for devcontainer (it
#                      decides use_devcontainer there) and is skipped for anything else
#   --additional-repos <list>
#                      repositories to clone beside <git-url>, comma- or
#                      newline-separated with the spaces around each entry
#                      trimmed; passed through as additional_repos, so a template
#                      without that parameter ignores it
#   --name <name>      workspace name, otherwise derived from the URL leaf
#   -h, --help         this help
#
# Auth, read from the environment only: CODER_URL + CODER_SESSION_TOKEN, or the
# host coder CLI's own login state when CODER_SESSION_TOKEN is unset. With neither
# you get the manual route, whose URL is http://127.0.0.1:3000 because inside the
# coder container that is the same API the server serves, reached without crossing
# Traefik, Authelia, or the WAN (see scripts/push-template.sh for why that
# matters). A token embedded in the URL is printed as given — it is what the
# template would be handed anyway — and is kept out of the derived name.
#
# The clone URL is passed after a literal `--`, and the probe clone runs as the
# person running this script: a private repository needs git credentials on this
# host (an SSH agent, or ~/.git-credentials) and fails with a warning without
# them, never silently.
#
# Safety:
#   - Nothing here mints, reads, prints or stores a credential: an existing token
#     reaches the CLI by name, never by value, so it stays out of argv (`ps`) and
#     out of any log.
#   - Not being able to create anything — no coder CLI, or one that is logged out —
#     prints the manual route and exits 0. That is a "not yet" state, not an error,
#     and re-running bazelisk run //scripts:new-workspace is always safe.
#   - The probe clone is --depth 1 --no-checkout under a mktemp -d tree that the
#     EXIT trap removes, so no copy of the repository is left on disk.

set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────────────
# SELF_DIR, not pwd: this script never cds, and the seam must be findable however
# it is invoked (bazelisk run //scripts:new-workspace, from any cwd).
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# die, first_line and has_tool come from the shared seam. This script has no
# --json mode, so an inherited JSON_MODE must not move the report to stderr.
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
unset JSON_MODE
# The name/folder derivations and the probe clone live in lib/workspace.sh, which
# is pure: sourcing it creates no workspace, runs no clone and writes no file.
# shellcheck source=lib/workspace.sh disable=SC1091
source "${SELF_DIR}/lib/workspace.sh"

# @function usage
# Print this script's own help — the same flag list as the header block above.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The help text on stdout
# Returns:
#   0
usage() {
  cat <<'EOF'
usage: bazelisk run //scripts:new-workspace -- [options] <git-url> [workspace-name]

Probe <git-url> for a dev container, then create a Coder workspace on the
matching template: devcontainer when the repository carries one, workspace
when it does not.

  --dry-run          print the decision and the exact command, create nothing
  --plain            force the workspace template even if a dev container exists
  --devcontainer     force the devcontainer template even if the probe finds
                     none (that create gets --parameter use_devcontainer=false)
  --dind             the workspace template plus --parameter dind=true (trusted
                     repositories only)
  --template <name>  full override of the template choice, workspace or
                     devcontainer (the probe still decides use_devcontainer for
                     devcontainer)
  --additional-repos <list>
                     extra repositories to clone beside <git-url>, comma- or
                     newline-separated; passed through as additional_repos
  --name <name>      workspace name (otherwise derived from the URL leaf)
  -h, --help         this help

A dev container is .devcontainer/, .github/devcontainers/, or a
devcontainer.json/.yml anywhere in the repository.

Auth: CODER_URL + CODER_SESSION_TOKEN, or the host coder CLI's own login state.
With neither, the manual route is printed instead of a create.

Examples (Bazel is the entry point, so every line below is a whole command;
add `--` before the arguments when the URL begins with a dash):
  bazelisk run //scripts:new-workspace -- --dry-run https://github.com/foo/bar.git
  bazelisk run //scripts:new-workspace -- --plain --dind https://github.com/foo/bar.git
  bazelisk run //scripts:new-workspace -- --devcontainer git@git.example.com:org/private.git
  bazelisk run //scripts:new-workspace -- --additional-repos "one.git,two.git" https://github.com/foo/bar.git
  bazelisk run //scripts:new-workspace -- --additional-repos $'one.git\ntwo.git' --name ml-scratch https://github.com/foo/bar.git
  bazelisk run //scripts:new-workspace -- --template workspace --name ml-scratch repo.git
EOF
}

# ── Arguments ──────────────────────────────────────────────────────────────
DRY_RUN=0
FORCE_PLAIN=0
FORCE_DC=0
DIND_SET=0
TEMPLATE=""
NAME=""
ADDITIONAL_REPOS=""
positional=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --plain) FORCE_PLAIN=1 ;;
    --devcontainer) FORCE_DC=1 ;;
    --dind) DIND_SET=1 ;;
    --template)
      [ "$#" -ge 2 ] || die "--template needs a template name"
      TEMPLATE="$2"
      shift
      ;;
    --additional-repos)
      [ "$#" -ge 2 ] || die "--additional-repos needs one or more git URLs"
      # Comma-separated or one URL per line, and either way the spaces around an
      # entry are trimmed and blank entries drop out, so a pasted list and a
      # quoted multi-line string agree. The template takes one comma-separated
      # string, which is what the join at the end of this pipeline builds.
      ADDITIONAL_REPOS="$(printf '%s\n' "$2" | tr ',\r' '\n\n' |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sed '/^$/d' | paste -sd, -)"
      shift
      ;;
    --name)
      [ "$#" -ge 2 ] || die "--name needs a workspace name"
      NAME="$2"
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --)
      # Everything after -- is positional, so a URL that begins with a dash stays
      # reachable. These shifts drain the argument list, hence the continue.
      while [ "$#" -gt 0 ]; do
        positional+=("$1")
        shift
      done
      continue
      ;;
    -?*) die "unknown option '$1' (see --help)" ;;
    *) positional+=("$1") ;;
  esac
  shift
done

[ "${#positional[@]}" -le 2 ] ||
  die "expected <git-url> and at most one workspace name, got ${#positional[@]} arguments (see --help)"
URL="${positional[0]-}"
NAME_FORCED="${positional[1]-}"

[ -n "$URL" ] || die "no git URL given (usage: bazelisk run //scripts:new-workspace -- [options] <git-url> [workspace-name])"

if [ "$FORCE_PLAIN" = 1 ] && [ "$FORCE_DC" = 1 ]; then
  die "--plain forces the workspace template and --devcontainer forces the devcontainer template: pick one"
fi

if [ "$DIND_SET" = 1 ]; then
  if [ "$FORCE_DC" = 1 ]; then
    die "--dind sets the workspace template's dind parameter; --devcontainer picks the other template: pick one (devcontainer always provisions its own DinD sidecar)"
  fi
  case "${TEMPLATE}" in
    devcontainer)
      die "--dind sets the workspace template's dind parameter, which devcontainer does not define: drop --dind, or use --template workspace"
      ;;
  esac
fi

# A named template is a full override, so the probe that would have chosen between
# the two stack templates has nothing left to decide — except for
# devcontainer, where the probe result still decides use_devcontainer.
PROBE_SKIPPED=0
if [ -n "$TEMPLATE" ]; then
  case "$TEMPLATE" in
    workspace | devcontainer) ;;
    *)
      note "template '${TEMPLATE}' is not one this stack ships (workspace, devcontainer) — no probe, and no use_devcontainer or dind parameter is passed"
      PROBE_SKIPPED=1
      ;;
  esac
  [ "$TEMPLATE" = devcontainer ] || PROBE_SKIPPED=1
elif [ "$FORCE_PLAIN" = 1 ] || [ "$DIND_SET" = 1 ]; then
  PROBE_SKIPPED=1
fi

# ── Workspace name ─────────────────────────────────────────────────────────
NAME_IS_FORCED=0
if [ -n "$NAME_FORCED" ]; then
  case "$NAME_FORCED" in
    [A-Za-z]*)
      [ "${#NAME_FORCED}" -le 40 ] || die "workspace name '${NAME_FORCED}' is ${#NAME_FORCED} characters; keep it to 40"
      ;;
    *) die "workspace name '${NAME_FORCED}' must start with a letter (Coder wants letters, digits and hyphens)" ;;
  esac
  if printf '%s' "$NAME_FORCED" | grep -qE '[^A-Za-z0-9-]'; then
    die "workspace name '${NAME_FORCED}' carries a character outside letters, digits and '-'"
  fi
  NAME="$NAME_FORCED"
  NAME_IS_FORCED=1
fi

# ── Probe ───────────────────────────────────────────────────────────────────
# The probe clone and its file listing live under one temporary directory,
# deleted on the way out by the trap below.
if [ "$NAME_IS_FORCED" = 0 ]; then
  NAME="$(name_from_url "$URL")"
fi

WORK=""
if ! WORK="$(mktemp -d 2>/dev/null)"; then WORK=""; fi
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  # No mktemp (or a TMPDIR that does not exist): fall back to a name that cannot
  # collide with another run on this box, rather than writing nothing anywhere.
  WORK="${TMPDIR:-/tmp}/new-workspace.$$"
  rm -rf -- "$WORK"
  mkdir -p -- "$WORK"
fi
# @function cleanup
# Delete this run's temporary tree, if it still exists.
# Globals:
#   WORK (the temporary directory this script made)
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
cleanup() {
  # Quoted in full, including the directory itself: a temp path with a space in it
  # is a working directory here, not a quoting accident.
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT
# TERM reaches the EXIT trap on its own; INT does not — bash dies from the default
# disposition without running it — so Ctrl-C gets its own handler. HUP is a covered
# case rather than a guess: a closed terminal is how a run gets interrupted here.
trap 'trap - EXIT; cleanup; exit 130' INT HUP

CLONE="${WORK}/repo"
DC_FOUND=0
PROBE_STATE="skipped (a --plain/--dind/--template choice decided the template already)"

# probe_repo (lib/workspace.sh) clones <src> into <dst> under the temporary
# directory and lists what it tracks. It returns 0 when a dev container is
# tracked, 3 for "checked, nothing found", and 1 or 2 for "could not check" (a
# failed clone or a failed ls-tree) — the last of which the case below reports.

section "Probe"
if [ "$PROBE_SKIPPED" = 0 ]; then
  phase "clone ${URL} and look for a dev container"
  if ! has_tool git; then
    PROBE_STATE="probe skipped: git is not installed on this host"
    note "git is not installed here, so the repository cannot be probed — assuming no dev container (the workspace template), which clones inside the workspace anyway; install git and re-run if that assumption matters"
  else
    probe_rc=0
    probe_repo "${WORK}" "$URL" "${CLONE}" || probe_rc=$?
    case "$probe_rc" in
      0)
        DC_FOUND=1
        PROBE_STATE="dev container found"
        ;;
      3)
        PROBE_STATE="no dev container found"
        ;;
      *)
        # A failed probe clone is a credential problem far more often than a
        # missing repository, so the credential check leads and the raw git line
        # trails as a quote. Printing the git error bare reads as "bad URL" and
        # sends whoever reads it nowhere: the private repository usually exists
        # and this host simply has nothing to authenticate the clone with.
        git_error="$(first_line "$(cat "${WORK}/probe.err" 2>/dev/null || true)")"
        PROBE_STATE="probe failed: no usable git credential for ${URL} — check the SSH agent (ssh-add -l) or ~/.git-credentials, then re-run; git said: \"${git_error}\""
        note "$PROBE_STATE"
        note "could not check the repository, so no dev container is assumed and the workspace template is used — pass --devcontainer to force devcontainer anyway, or --plain to say you already know it has none"
        ;;
    esac
  fi
fi

# ── Template and parameter values ──────────────────────────────────────────
if [ -n "$TEMPLATE" ]; then
  TEMPLATE_CHOSEN="$TEMPLATE"
elif [ "$FORCE_DC" = 1 ]; then
  TEMPLATE_CHOSEN=devcontainer
elif [ "$FORCE_PLAIN" = 1 ] || [ "$DIND_SET" = 1 ]; then
  TEMPLATE_CHOSEN=workspace
elif [ "$DC_FOUND" = 1 ]; then
  TEMPLATE_CHOSEN=devcontainer
else
  TEMPLATE_CHOSEN=workspace
fi

# Where the clone lands. The workspace template clones into the workspace's home
# volume; devcontainer clones onto the host bind that the DinD sidecar mounts at
# the same path, because a bind source is resolved by the daemon that runs the dev
# container, not only by the one that runs the workspace. The folder name is the
# template's own case-preserving derivation (clone_folder_of_url), so the printed
# path is the path that will actually exist.
case "$TEMPLATE_CHOSEN" in
  workspace) CLONE_PATH="/home/coder/workspace/$(clone_folder_of_url "$URL")" ;;
  devcontainer) CLONE_PATH="/srv/coder-devcontainers/<workspace-id>/$(clone_folder_of_url "$URL")" ;;
  *) CLONE_PATH="(whatever template ${TEMPLATE_CHOSEN} clones)" ;;
esac

params=(--parameter "repo_url=${URL}")
if [ -n "$ADDITIONAL_REPOS" ]; then
  # One comma-separated string, which is the shape the template re-splits into
  # URLs. Sent only when asked for: without the flag this script passes exactly
  # the parameters it used to pass.
  params+=(--parameter "additional_repos=${ADDITIONAL_REPOS}")
fi
if [ "$TEMPLATE_CHOSEN" = "devcontainer" ] && [ "$DC_FOUND" != 1 ]; then
  # Without this the create would try to build a dev container that cannot exist,
  # and the editor would have no folder to open in either; with the parameter set
  # to false the workspace serves the repository through the plain container
  # instead. This is the ONLY case where devcontainer gets this parameter —
  # the workspace template has no such parameter, and never sees this line.
  params+=(--parameter "use_devcontainer=false")
  if [ "$FORCE_DC" = 1 ] || [ -n "$TEMPLATE" ]; then
    note "devcontainer on a repository with no dev container: the dev container will not build, so --parameter use_devcontainer=false keeps the clone folder usable (code-server + Grok run on the plain container). Recreate with the workspace template instead unless you meant exactly this."
  fi
fi
if [ "$DIND_SET" = 1 ]; then
  params+=(--parameter "dind=true")
  note "dind=true passed for a privileged DinD sidecar on this workspace (docker:29.8.1-dind must be in the host image store, and switching it later means a rebuild)"
fi
params+=(--use-parameter-defaults --yes --no-wait)

# ── Print the decision ─────────────────────────────────────────────────────
log "probe:    ${PROBE_STATE}"
log "template: ${TEMPLATE_CHOSEN}"
log "name:     ${NAME}"
log "clone:    ${CLONE_PATH} (cloned during provisioning, not before the create)"
if [ -n "$ADDITIONAL_REPOS" ]; then
  log "also:     ${ADDITIONAL_REPOS} (beside the URL above, and cloned by the same rule)"
fi

create_line="coder create -t ${TEMPLATE_CHOSEN} ${params[*]} ${NAME}"
if [ "$DRY_RUN" = 1 ]; then
  log ""
  log "would run:"
  log "  ${create_line}"
  summary "bazelisk run //scripts:new-workspace -- ${URL} ${NAME}"
  exit 0
fi

# ── Run it, or print what to type by hand ──────────────────────────────────
# Three states, kept apart: a host coder CLI to drive, an explicit URL+token
# pair from the environment (the shape scripts/push-template.sh uses), or
# neither — which lands in the manual route rather than in a guess.
section "Create"
phase "create workspace ${NAME} on template ${TEMPLATE_CHOSEN}"
log "creating workspace '${NAME}' (build runs in the background — --no-wait; watch it with: coder ls, coder logs ${NAME})"
create_rc=0
create_hint=""
if ! has_tool coder; then
  create_hint="no coder CLI on PATH, so nothing was created: install the 'coder' CLI (https://coder.com/docs/install — the binary is 'coder'), then run 'coder login <url>' with this stack's Coder URL (https://<host>:3001 on the LAN, or http://127.0.0.1:3000 from inside the coder container) and re-run bazelisk run //scripts:new-workspace -- ${URL} ${NAME}"
  create_rc=1
elif [ -n "${CODER_SESSION_TOKEN:-}" ]; then
  if [ -z "${CODER_URL:-}" ]; then
    note "CODER_SESSION_TOKEN is set but CODER_URL is not, so the CLI would dial whatever login URL you last used — that is almost never what this wants"
    create_rc=1
  else
    log '$ coder create ... (CODER_URL=${CODER_URL} with the token by name, not by value)'
    if ! CODER_URL="$CODER_URL" CODER_SESSION_TOKEN="$CODER_SESSION_TOKEN" \
      coder create -t "$TEMPLATE_CHOSEN" "${params[@]}" "$NAME"; then
      create_hint="the create failed with the token from the environment: a rejected token means it belongs to another deployment, so mint a fresh one in the Coder UI (Settings → Tokens, or 'coder tokens create' inside the coder container), export CODER_URL and CODER_SESSION_TOKEN again, and re-run bazelisk run //scripts:new-workspace -- ${URL} ${NAME}"
      create_rc=1
    fi
  fi
else
  # No token in the environment: the CLI either has a login session of its own or
  # it fails with "You are not currently logged in", and the failure text is the
  # honest way to tell. One attempt, then the manual route — no login is faked.
  log "\$ ${create_line}"
  if ! coder create -t "$TEMPLATE_CHOSEN" "${params[@]}" "$NAME"; then
    create_hint="if that read 'You are not currently logged in', the CLI has no session to spend: run 'coder login <url>' with this stack's Coder URL (https://<host>:3001 on the LAN, or http://127.0.0.1:3000 from inside the coder container) and re-run bazelisk run //scripts:new-workspace -- ${URL} ${NAME}"
    create_rc=1
  fi
fi

if [ "$create_rc" = 0 ]; then
  log ""
  log "started ${NAME} from template ${TEMPLATE_CHOSEN}"
  log "the workspace clones the repository to ${CLONE_PATH}, and code-server and"
  log "Grok Build open and run on that folder; watch the build with coder ls /"
  log "coder logs ${NAME}, or open the workspace in the Coder UI."
  summary "coder logs ${NAME}"
  exit 0
fi

if [ -n "${create_hint}" ]; then
  printf '\nnext step: %s\n' "${create_hint}"
fi

cat <<EOF

Nothing was created. Two ways to do it by hand, with the same values:

1. Coder UI — create workspace, pick template '${TEMPLATE_CHOSEN}', and fill the
   'Git repository' field with the URL above (devcontainer defaults it to a
   demo repository — replace it; add any --additional-repos URLs in the
   'Git repositories (additional)' field below it), leaving the dev-container
   toggle at its default when the probe said 'found' and setting it to 'No'
   when it did not, then pick the matching preset or set the fields by hand,
   and press Create.

2. Terminal, from the checkout on the stack host — log the host coder CLI in
   (coder login https://<host>:3001) then re-run:

   bazelisk run //scripts:new-workspace -- ${URL} ${NAME}

   Or, with a token from the Coder Tokens page or 'coder tokens create' inside
   the coder container, pasted by name so it stays out of shell history:

   docker compose -p evo-t1-prod exec -T -e CODER_URL=http://127.0.0.1:3000 -e CODER_SESSION_TOKEN \\
     coder coder create -t ${TEMPLATE_CHOSEN} ${params[*]} ${NAME}

   (The first 'coder' names the compose service, the second is the CLI inside
   it — see scripts/push-template.sh for why the CLI belongs inside the
   container. Use -p evo-t1-dev when that is the stack you are on. Keep
   'use_devcontainer=false' out of the line if that template got it while your
   repository actually carries a dev container — then the probe was wrong, and
   the flag was not needed.)
EOF
exit 0
