#!/usr/bin/env bash
# Create a Coder workspace for one git repository, in one command.
#
# Two things are decided here, in this order.
#
# 1. Which template the workspace gets. The repository is cloned (depth 1,
#    --no-checkout) into a temporary directory on the host and searched for a
#    dev container: .devcontainer/, .github/devcontainers/, or a
#    devcontainer.json/.yml at the top level or in a subdirectory. Found ->
#    docker-devcontainer, which builds that file on a privileged DinD sidecar. Not
#    found -> docker-dev, which clones the repository itself and starts code-server
#    plus Grok Build on the clone.
#
# 2. Which parameter values travel with it. Both templates carry a repo_url
#    parameter, so the clone URL is passed instead of being retyped in the form.
#
#    use_devcontainer belongs to docker-devcontainer only, defaults to true, and
#    gates whether the dev container is built at all — and that build also decides
#    where code-server attaches, because the editor lives inside the dev container
#    when one is built. So on a repository that carries no devcontainer.json,
#    leaving the toggle at its default buys nothing: no dev container comes up, and
#    the editor that would have attached to it never appears either. That is the
#    one case this script passes --parameter use_devcontainer=false for.
#    docker-dev never receives that parameter, because that template has none.
#
#    dind belongs to docker-dev only (default false, and immutable: switching it
#    later means a rebuild). --dind passes it as true.
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
# Usage:
#   bash scripts/new-workspace.sh --dry-run https://github.com/foo/bar.git
#   bash scripts/new-workspace.sh https://github.com/foo/bar.git             # auto
#   bash scripts/new-workspace.sh --dry-run /srv/repos/my-tool               # local path
#   bash scripts/new-workspace.sh --plain https://github.com/foo/bar.git     # docker-dev
#   bash scripts/new-workspace.sh --dind https://github.com/foo/bar.git      # + DinD
#   bash scripts/new-workspace.sh --devcontainer git@git.example.com:org/private.git
#   bash scripts/new-workspace.sh --template docker-dev --name ml-scratch repo.git
#
# Options:
#   --dry-run          print the decision and the exact command, create nothing
#   --plain            force template docker-dev even where a dev container exists
#   --devcontainer     force template docker-devcontainer even where the probe
#                      finds nothing — that create gets --parameter
#                      use_devcontainer=false, which starts no dev container and
#                      opens the editor on the clone instead (it needs a rebuild to
#                      flip, so docker-dev is usually what is meant)
#   --dind             docker-dev plus --parameter dind=true, for a repository you
#                      trust and a machine you own: a private daemon on a shared
#                      box is what SECURITY.md is about
#   --template <name>  full override of the template choice; the probe still runs
#                      for docker-devcontainer (it decides use_devcontainer there)
#                      and is skipped for anything else
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
set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────────────
log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf 'note: %s\n' "$*"; }

first_line() {
  # $1 = text; prints its first non-blank line, so a tool's own complaint can be
  # quoted without dumping its whole stderr into this script's output. The
  # `|| true` is load-bearing: pipefail makes an all-blank input (grep exits 1)
  # abort the caller, and every caller below reads a command substitution.
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p' || true
}

sanitize_leaf() {
  # $1 = text; lowercase it, map every character outside [a-z0-9-] to "-",
  # collapse those runs, and trim the ends. tr -c works byte by byte, so a
  # multi-byte character becomes one run of dashes rather than one dash per byte.
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' \
    | sed -e 's/--*-/-/g' -e 's/^-//' -e 's/-$//'
}

leaf_of_url() {
  # $1 = clone URL or local path; prints the lowercase leaf used for the
  # workspace NAME (Coder names are lowercase; see name_from_url and
  # sanitize_leaf). The clone FOLDER keeps the source case — that is derived by
  # clone_folder_of_url, because the templates re-derive it with case intact.
  local leaf
  leaf="$(printf '%s' "$1" | tr '/' '\n' | grep -v '^[[:space:]]*$' | tail -n 1)"
  leaf="$(printf '%s' "$leaf" | sed -e 's|?.*$||' -e 's|#.*$||' -e 's|\.git$||')"
  sanitize_leaf "$leaf"
}

name_from_url() {
  # $1 = clone URL; prints the workspace name to use: leaf_of_url plus the two
  # rules Coder's own name check needs — start with a letter, stay under 40.
  local leaf
  leaf="$(leaf_of_url "$1")"
  [ -n "$leaf" ] || leaf="repo"
  case "$leaf" in [a-z]*) ;; *) leaf="x${leaf}" ;; esac
  printf '%s' "$leaf" | cut -c1-40 | sed -e 's/-$//'
}

clone_folder_of_url() {
  # $1 = clone URL or local path; prints the folder the TEMPLATE will clone into,
  # case kept intact — an exact mirror of the templates' repo_folder re-derivation
  # (take the last "/" segment, drop a query/fragment and a trailing ".git", map
  # every character outside [A-Za-z0-9._-] to "-", and fall back to "repo" when
  # that leaves no leading alphanumeric). Used only to print the clone path; the
  # workspace NAME uses the lowercase leaf_of_url, which is why this exists
  # separately — printing "…/imagesharp" for a repo cloned into "ImageSharp"
  # would send someone looking for a folder that does not exist.
  local leaf
  leaf="$(printf '%s' "$1" | tr '/' '\n' | grep -v '^[[:space:]]*$' | tail -n 1)"
  leaf="$(printf '%s' "$leaf" | sed -e 's|?.*$||' -e 's|#.*$||' -e 's|\.git$||')"
  leaf="$(printf '%s' "$leaf" | tr -c 'A-Za-z0-9._-' '-')"
  if printf '%s' "$leaf" | grep -qE '^[A-Za-z0-9]'; then printf '%s' "$leaf"; else printf 'repo'; fi
}

usage() {
  cat <<'EOF'
usage: new-workspace.sh [options] <git-url> [workspace-name]

Probe <git-url> for a dev container, then create a Coder workspace on the
matching template: docker-devcontainer when the repository carries one,
docker-dev when it does not.

  --dry-run          print the decision and the exact command, create nothing
  --plain            force template docker-dev even if a dev container exists
  --devcontainer     force template docker-devcontainer even if the probe finds
                     none (that create gets --parameter use_devcontainer=false)
  --dind             docker-dev plus --parameter dind=true (trusted repos only)
  --template <name>  full override of the template choice (probe still decides
                     use_devcontainer when the name is docker-devcontainer)
  --name <name>      workspace name (otherwise derived from the URL leaf)
  -h, --help         this help

A dev container is .devcontainer/, .github/devcontainers/, or a
devcontainer.json/.yml anywhere in the repository.

Auth: CODER_URL + CODER_SESSION_TOKEN, or the host coder CLI's own login state.
With neither, the manual route is printed instead of a create.
EOF
}

# ── Arguments ──────────────────────────────────────────────────────────────
DRY_RUN=0
FORCE_PLAIN=0
FORCE_DC=0
DIND_SET=0
TEMPLATE=""
NAME=""
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

[ "${#positional[@]}" -le 2 ] \
  || die "expected <git-url> and at most one workspace name, got ${#positional[@]} arguments (see --help)"
URL="${positional[0]-}"
NAME_FORCED="${positional[1]-}"

[ -n "$URL" ] || die "no git URL given (usage: new-workspace.sh [options] <git-url> [workspace-name])"

if [ "$FORCE_PLAIN" = 1 ] && [ "$FORCE_DC" = 1 ]; then
  die "--plain forces docker-dev and --devcontainer forces docker-devcontainer: pick one"
fi

if [ "$DIND_SET" = 1 ]; then
  if [ "$FORCE_DC" = 1 ]; then
    die "--dind sets docker-dev's dind parameter; --devcontainer picks the other template: pick one (docker-devcontainer always provisions its own DinD sidecar)"
  fi
  case "${TEMPLATE}" in
    docker-devcontainer)
      die "--dind sets docker-dev's dind parameter, which docker-devcontainer does not define: drop --dind, or use --template docker-dev"
      ;;
  esac
fi

# A named template is a full override, so the probe that would have chosen between
# the two stack templates has nothing left to decide — except for
# docker-devcontainer, where the probe result still decides use_devcontainer.
PROBE_SKIPPED=0
if [ -n "$TEMPLATE" ]; then
  case "$TEMPLATE" in
    docker-dev | docker-devcontainer) ;;
    *)
      note "template '${TEMPLATE}' is not one this stack ships (docker-dev, docker-devcontainer) — no probe, and no use_devcontainer or dind parameter is passed"
      PROBE_SKIPPED=1
      ;;
  esac
  [ "$TEMPLATE" = docker-devcontainer ] || PROBE_SKIPPED=1
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

probe_repo() {
  # $1 = clone source, $2 = where to put it. Returns 0 when a dev container is
  # tracked, and non-zero for "could not check" (a failed clone or a failed
  # ls-tree) versus 3 for "checked, nothing found". --filter=blob:none is
  # deliberately absent: it is not honoured by older servers, and a private
  # Gitea on the LAN is where it would be tried.
  local src="$1" dst="$2" listing rc=0
  if ! git -C "${WORK}" clone --quiet --depth 1 --no-checkout --single-branch \
      -- "$src" "$dst" 2>"${WORK}/probe.err"; then
    return 1
  fi
  listing="$(git -C "$dst" ls-tree -r --name-only HEAD 2>>"${WORK}/probe.err")" || rc=$?
  if [ "$rc" != 0 ]; then
    return 2
  fi
  if printf '%s\n' "$listing" | grep -qE \
    '(^|/)\.devcontainer/|(^|/)\.github/devcontainers/|(^|/)devcontainer\.(json|yml)$'; then
    return 0
  fi
  return 3
}

if [ "$PROBE_SKIPPED" = 0 ]; then
  if ! command -v git >/dev/null 2>&1; then
    PROBE_STATE="probe skipped: git is not installed on this host"
    note "git is not installed here, so the repository cannot be probed — assuming no dev container (docker-dev), which clones inside the workspace anyway; install git and re-run if that assumption matters"
  else
    probe_rc=0
    probe_repo "$URL" "${CLONE}" || probe_rc=$?
    case "$probe_rc" in
      0)
        DC_FOUND=1
        PROBE_STATE="dev container found"
        ;;
      3)
        PROBE_STATE="no dev container found"
        ;;
      *)
        PROBE_STATE="probe failed: $(first_line "$(cat "${WORK}/probe.err" 2>/dev/null || true)")"
        note "$PROBE_STATE"
        note "could not check the repository, so no dev container is assumed and docker-dev is used — pass --devcontainer to force docker-devcontainer anyway, or --plain to say you already know it has none"
        ;;
    esac
  fi
fi

# ── Template and parameter values ──────────────────────────────────────────
if [ -n "$TEMPLATE" ]; then
  TEMPLATE_CHOSEN="$TEMPLATE"
elif [ "$FORCE_DC" = 1 ]; then
  TEMPLATE_CHOSEN=docker-devcontainer
elif [ "$FORCE_PLAIN" = 1 ] || [ "$DIND_SET" = 1 ]; then
  TEMPLATE_CHOSEN=docker-dev
elif [ "$DC_FOUND" = 1 ]; then
  TEMPLATE_CHOSEN=docker-devcontainer
else
  TEMPLATE_CHOSEN=docker-dev
fi

# Where the clone lands. docker-dev clones into the workspace's home volume;
# docker-devcontainer clones onto the host bind that the DinD sidecar mounts at the
# same path, because a bind source is resolved by the daemon that runs the dev
# container, not only by the one that runs the workspace. The folder name is the
# template's own case-preserving derivation (clone_folder_of_url), so the printed
# path is the path that will actually exist.
case "$TEMPLATE_CHOSEN" in
  docker-dev) CLONE_PATH="/home/coder/workspace/$(clone_folder_of_url "$URL")" ;;
  docker-devcontainer) CLONE_PATH="/srv/coder-devcontainers/<workspace-id>/$(clone_folder_of_url "$URL")" ;;
  *) CLONE_PATH="(whatever template ${TEMPLATE_CHOSEN} clones)" ;;
esac

params=(--parameter "repo_url=${URL}")
if [ "$TEMPLATE_CHOSEN" = "docker-devcontainer" ] && [ "$DC_FOUND" != 1 ]; then
  # Without this the create would try to build a dev container that cannot exist,
  # and the editor would have no folder to open in either; with the parameter set
  # to false the workspace serves the repository through the plain container
  # instead. This is the ONLY case where docker-devcontainer gets this parameter —
  # docker-dev has no such parameter, and never sees this line.
  params+=(--parameter "use_devcontainer=false")
  if [ "$FORCE_DC" = 1 ] || [ -n "$TEMPLATE" ]; then
    note "docker-devcontainer on a repository with no dev container: the dev container will not build, so --parameter use_devcontainer=false keeps the clone folder usable (code-server + Grok run on the plain container). Recreate with docker-dev instead unless you meant exactly this."
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

create_line="coder create -t ${TEMPLATE_CHOSEN} ${params[*]} ${NAME}"
if [ "$DRY_RUN" = 1 ]; then
  log ""
  log "would run:"
  log "  ${create_line}"
  exit 0
fi

# ── Run it, or print what to type by hand ──────────────────────────────────
# Three states, kept apart: a host coder CLI to drive, an explicit URL+token
# pair from the environment (the shape scripts/push-template.sh uses), or
# neither — which lands in the manual route rather than in a guess.
log ""
log "creating workspace '${NAME}' (build runs in the background — --no-wait; watch it with: coder ls, coder logs ${NAME})"
create_rc=0
if ! command -v coder >/dev/null 2>&1; then
  note "no coder CLI on PATH — printing the manual route instead"
  create_rc=1
elif [ -n "${CODER_SESSION_TOKEN:-}" ]; then
  if [ -z "${CODER_URL:-}" ]; then
    note "CODER_SESSION_TOKEN is set but CODER_URL is not, so the CLI would dial whatever login URL you last used — that is almost never what this wants"
    create_rc=1
  else
    log "\$ coder create ... (CODER_URL=\${CODER_URL} with the token by name, not by value)"
    if ! CODER_URL="$CODER_URL" CODER_SESSION_TOKEN="$CODER_SESSION_TOKEN" \
        coder create -t "$TEMPLATE_CHOSEN" "${params[@]}" "$NAME"; then
      create_rc=1
    fi
  fi
else
  # No token in the environment: the CLI either has a login session of its own or
  # it fails with "You are not currently logged in", and the failure text is the
  # honest way to tell. One attempt, then the manual route — no login is faked.
  log "\$ ${create_line}"
  if ! coder create -t "$TEMPLATE_CHOSEN" "${params[@]}" "$NAME"; then
    create_rc=1
  fi
fi

if [ "$create_rc" = 0 ]; then
  log ""
  log "started ${NAME} from template ${TEMPLATE_CHOSEN}"
  log "the workspace clones the repository to ${CLONE_PATH}, and code-server and"
  log "Grok Build open and run on that folder; watch the build with coder ls /"
  log "coder logs ${NAME}, or open the workspace in the Coder UI."
  exit 0
fi

cat <<EOF

Nothing was created. Two ways to do it by hand, with the same values:

1. Coder UI — create workspace, pick template '${TEMPLATE_CHOSEN}', and fill the
   'Git repository' field with the URL above (docker-devcontainer defaults it to
   a demo repository — replace it), leaving the dev-container toggle at its
   default when the probe said 'found' and setting it to 'No' when it did not,
   then pick the matching preset or set the fields by hand, and press Create.

2. Terminal, from the stack repository on the stack host — a token from the
   Coder Tokens page or 'coder tokens create', pasted by name so it stays out
   of shell history:

   docker compose exec -T -e CODER_URL=http://127.0.0.1:3000 -e CODER_SESSION_TOKEN \\
     coder coder create -t ${TEMPLATE_CHOSEN} ${params[*]} ${NAME}

   (The first 'coder' names the compose service, the second is the CLI inside
   it — see scripts/push-template.sh for why the CLI belongs inside the
   container. Keep 'use_devcontainer=false' out of the line if that template
   got it while your repository actually carries a dev container — then the
   probe was wrong, and the flag was not needed.)
EOF
exit 0
