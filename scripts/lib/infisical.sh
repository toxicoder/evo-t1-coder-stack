# shellcheck shell=bash
#
# ## infisical.sh - the one Infisical seam (sourced; never executed)
#
# The only file in this repo that knows how to talk to Infisical. Everything else
# (scripts/infisical.sh, scripts/bootstrap.sh, the workspace boot fetch, the compose
# argv builders) calls these functions and never shells out to the CLI itself.
#
# Secrets policy, in one place. A managed value crosses this file exactly once, from
# the CLI's own --output-file to .env, and:
#   - never reaches the stdout of the CLI in a form this shell captures: the export
#     and the bootstrap JSON go to a mode-600 file by redirect, never through $( ),
#     a pipeline, or a variable the CLI fills;
#   - is copied line by line, never through sed or awk, both of which give a
#     password's &, \, / and | a special meaning (scripts/dashboard-password.sh:252
#     is the idiom this file copies);
#   - never appears in a log, warn, note, ok, die or summary argument. Only key
#     names, counts, ids and paths are printed. The one deliberate exception is
#     infisical_login, which exists to hand the access token to its caller on
#     stdout and prints nothing of its own;
#   - never reaches the argv of an external command, with the two exceptions upstream
#     requires and no other: --client-secret= on login and --password= on bootstrap
#     (the CLI offers no stdin path), and the KEY=@<file> form for a single write,
#     which names a file rather than the value.
# Every temp this file makes is chmod 600 the instant mktemp returns it and is
# removed by the EXIT trap infisical_install_exit_trap installs. bash keeps a single
# handler, so the seam captures whatever the caller had installed first and
# infisical_tmp_cleanup runs it once the temps are off the disk: taking the caller's
# EXIT slot is not a licence to delete its cleanup. What an entry script must not do
# is install its own EXIT trap AFTER sourcing this file, because taking the slot back
# would strand a file of secrets on the failure path. The seam suite pins both halves.
# infisical_mktemp hands its path back in a global and must be called plainly for that
# reason: in a command substitution the registration dies with the subshell and the
# secret outlives the run.
#
# The flag: INFISICAL_ENABLED is read in exactly one place, infisical_enabled, and
# only through truthy(). It defaults OFF, which is the deliberate opposite of
# OBSERVABILITY_ENABLED in scripts/lib/common.sh:349, where an absent key means on.
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root cd):
#   # shellcheck source=lib/infisical.sh disable=SC1091
#   source "scripts/lib/infisical.sh"

if ! declare -f die >/dev/null 2>&1; then
  # shellcheck source=lib/common.sh disable=SC1091
  source "${BASH_SOURCE[0]%/*}/common.sh"
fi

# Temps this shell made, one "pid:path" entry per line, cleaned by the EXIT trap below.
# One entry per line rather than one per space because the template is caller-supplied:
# a whitespace-split list breaks a path that holds a space into two entries, and the
# mode-600 file holding vault values is then never matched and never removed.
INFISICAL_TMP_FILES=""
# The last path infisical_mktemp created; see that function for why it is a global.
INFISICAL_MKTEMP=""
# The pid whose shell already owns the EXIT slot for this lib. See
# infisical_install_exit_trap.
INFISICAL_EXIT_TRAP_SET=""
# The caller's own EXIT handler, captured verbatim before the seam took the slot, and
# the pid of the shell that already ran it. See infisical_install_exit_trap and
# infisical_tmp_cleanup, which runs this once the temps are gone.
INFISICAL_EXIT_TRAP_PRIOR=""
INFISICAL_EXIT_TRAP_RAN=""

# The release asset name is goreleaser's, pinned by .env.example's INFISICAL_CLI_VERSION.
# The version token is substituted literally, not through a printf format string.
INFISICAL_CLI_ASSET="cli_{version}_linux_amd64.tar.gz"
INFISICAL_CLI_RELEASE_BASE="https://github.com/Infisical/cli/releases/download"

# @function infisical_trap_body
# Print the handler text one `trap -p EXIT` line carries, unwrapped from the single
# quotes bash puts around it. This is the only way to read a handler the caller
# installed before the seam took the EXIT slot, so the caller's own cleanup can be run
# afterwards rather than silently dropped. No eval: the text is taken apart with
# parameter expansion and executed by infisical_tmp_cleanup.
#
# bash's own quoting wraps the handler in single quotes and spells each embedded single
# quote as the four-character run '\'' ; stripping the wrapper and folding that run back
# to one quote is the inverse, and it is the reason this is a function rather than a
# line of the caller. The fold pattern is written inline on purpose: built from a
# variable the backslash survives expansion and the run stops matching.
# Globals:
#   None
# Arguments:
#   $1 - one `trap -p EXIT` line, verbatim
# Outputs:
#   The handler text on stdout, with no trailing newline, when there was one
# Returns:
#   0 with the handler printed; 1 when the line names no handler at all (no trap set,
#   an empty handler, or a trap for some other signal), which callers read as "the
#   caller had nothing to preserve"
infisical_trap_body() {
  local line="${1:-}" body=""
  case "${line}" in
    'trap -- '*\ EXIT) ;;
    *) return 1 ;;
  esac
  body="${line#trap -- }"
  body="${body% EXIT}"
  if [[ ${body} == \'*\' ]]; then
    body="${body#\'}"
    body="${body%\'}"
    body="${body//\'\\\'\'/\'}"
  fi
  [ -n "${body}" ] || return 1
  printf '%s' "${body}"
}

# @function infisical_install_exit_trap
# Install the seam's EXIT cleanup once per shell, keeping whatever handler the caller
# had installed first. bash keeps a single EXIT handler and the last setter wins, so the
# slot is captured with `trap -p EXIT` before it is overwritten and
# infisical_tmp_cleanup runs the caller's handler once the temps are gone. What an entry
# script must still not do is install an EXIT trap of its own AFTER sourcing the seam,
# because taking the slot back would leave a mode-600 file of secrets behind on the
# failure path. The seam suite pins that no script which sources this file does so.
#
# The guard is keyed on BASHPID rather than a yes/no because a command substitution is
# a forked subshell that inherits the parent's environment and needs a handler of its
# own to clean what it created. Such a subshell never re-emits a handler: the shell it
# forked from still holds its own copy and will run it at its own exit, so running it
# here would run the caller's cleanup twice, or run it in a shell whose caller never
# asked for it.
# Globals:
#   INFISICAL_EXIT_TRAP_SET, INFISICAL_EXIT_TRAP_PRIOR, INFISICAL_EXIT_TRAP_RAN, BASHPID
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0, always
infisical_install_exit_trap() {
  local prior="" body="" flat=""
  if [ "${INFISICAL_EXIT_TRAP_SET:-}" != "${BASHPID}" ]; then
    if [ "${BASHPID}" = "$$" ]; then
      prior="$(trap -p EXIT)" || prior=""
      body="$(infisical_trap_body "${prior}")" || body=""
      flat="${body//[[:space:]]/}"
      flat="${flat//;/}"
      # A handler that is the seam's own cleanup is not a caller's: re-emitting it would
      # clean the list twice in one shell and hand a caller that had none a phantom one.
      if [ -n "${body}" ] && [ "${flat}" != "infisical_tmp_cleanup" ]; then
        INFISICAL_EXIT_TRAP_PRIOR="${body}"
        INFISICAL_EXIT_TRAP_RAN=""
      else
        INFISICAL_EXIT_TRAP_PRIOR=""
      fi
    else
      INFISICAL_EXIT_TRAP_PRIOR=""
    fi
    INFISICAL_EXIT_TRAP_SET="${BASHPID}"
    trap 'infisical_tmp_cleanup' EXIT
  fi
  return 0
}

# @function infisical_tmp_cleanup
# Remove the temps this shell created, and only those. Each entry carries the pid of
# the shell that made it, which is what makes a caller wrapping a pull or a push in
# $( ) safe: the command substitution is a forked subshell, it inherits the parent's
# list, and without the tag it would either delete a dump the parent is still reading
# or, cleaned by nobody, leave a file of secrets behind when it exits. The caller's
# entries stay in the list for the caller's own trap.
#
# Entries are read one per line with `IFS= read -r`, never by word splitting: a template
# is caller-supplied and may hold a space, and a split path matches no file, so the
# mode-600 dump survives. Once the temps are gone the handler infisical_install_exit_trap
# captured from the caller runs, once per shell, so taking the EXIT slot costs the caller
# nothing.
# Globals:
#   INFISICAL_TMP_FILES, INFISICAL_EXIT_TRAP_PRIOR, INFISICAL_EXIT_TRAP_RAN, BASHPID
# Arguments:
#   None
# Outputs:
#   Whatever the caller's own EXIT handler prints
# Returns:
#   0, always: cleanup runs on a failure path and must not mask the failure
infisical_tmp_cleanup() {
  local entry own="" mine=""
  while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    if [ "${entry%%:*}" = "${BASHPID}" ]; then
      own="${entry#*:}"
      if [ -d "${own}" ]; then
        # A dir temp is this lib's own and nothing is ever written into it, so a plain
        # rmdir removes it. rm -rf is not needed and has no business next to a path
        # built from a caller-supplied template.
        rmdir -- "${own}" 2>/dev/null || true
      elif [ -e "${own}" ]; then
        rm -f -- "${own}"
      fi
    else
      mine="${mine}${entry}"$'\n'
    fi
  done <<<"${INFISICAL_TMP_FILES:-}"
  INFISICAL_TMP_FILES="${mine}"
  if [ -n "${INFISICAL_EXIT_TRAP_PRIOR:-}" ] &&
    [ "${INFISICAL_EXIT_TRAP_RAN:-}" != "${BASHPID}" ]; then
    INFISICAL_EXIT_TRAP_RAN="${BASHPID}"
    # The captured handler runs here, in this shell, so it still sees the caller's
    # functions and variables. A here-string and source is the one way to run a handler
    # text without eval.
    # shellcheck source=/dev/null disable=SC1090
    source /dev/stdin <<<"${INFISICAL_EXIT_TRAP_PRIOR}" || true
  fi
  return 0
}

# @function infisical_mktemp
# Make one temp file or directory this lib owns, tightened the moment it exists, and
# register it with infisical_tmp_cleanup, whose EXIT trap covers both the success and
# the failure path. Call this plainly rather than inside $( ) when you need the path
# back: the path comes out in INFISICAL_MKTEMP, and a subshell keeps that assignment
# to itself. The temp is still cleaned either way, because the subshell gets its own
# trap and its own pid tag.
# Globals:
#   INFISICAL_TMP_FILES, INFISICAL_MKTEMP (the new path),
#   BASHPID
# Arguments:
#   $1 - mktemp template: an absolute path prefix, without the XXXXXX. A relative
#     template is refused rather than passed on, because mktemp then writes the file
#     into whatever directory the caller happens to be standing in, next to the repo,
#     holding secret values, where no EXIT trap was asked to look for it. A newline is
#     refused for the same reason in the other direction: one entry per line is what
#     infisical_tmp_cleanup reads back.
#   $2 - "dir" for a directory, anything else for a file
# Outputs:
#   None; the path lands in INFISICAL_MKTEMP
# Returns:
#   0 with the path set; 1 when mktemp failed, with the global left empty; 2 when the
#   template is not an absolute path or holds a newline, with one error line naming it
#   and no file created
infisical_mktemp() {
  local template="${1:-}" kind="${2:-file}" made=""
  INFISICAL_MKTEMP=""
  if [[ ${template} != /* ]] || [[ ${template} == *$'\n'* ]]; then
    err "infisical_mktemp needs an absolute template, got '${1:-}'"
    return 2
  fi
  if [ "${kind}" = "dir" ]; then
    made="$(mktemp -d "${template}.XXXXXX" 2>/dev/null)" || return 1
    chmod 700 "${made}"
  else
    made="$(mktemp "${template}.XXXXXX" 2>/dev/null)" || return 1
    chmod 600 "${made}"
  fi
  INFISICAL_TMP_FILES="${INFISICAL_TMP_FILES}${BASHPID}:${made}"$'\n'
  # Set on every call rather than once per shell: a command substitution inherits the
  # parent's environment, and it needs a trap of its own to clean what it created.
  infisical_install_exit_trap
  INFISICAL_MKTEMP="${made}"
}

# @function infisical_dotenv_get
# Print one key's value out of a dotenv file, byte for byte. Read line by line and
# never with sed or awk: both eat backslashes and give & a meaning, and a managed
# value may hold all of them. Unlike env_get this strips no quotes, because Infisical
# stores the value as it was pushed and .env has to end up holding the same bytes.
# Globals:
#   None
# Arguments:
#   $1 - dotenv file
#   $2 - key name
# Outputs:
#   The value on stdout, with no trailing newline
# Returns:
#   0 when the key was found (empty value included); 1 when the file or the key is
#   absent, which is how callers tell "blank in the vault" from "not in the vault"
infisical_dotenv_get() {
  local file="$1" key="$2" line="" out="" found=1
  [ -f "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${key}"=*)
        out="${line#"${key}="}"
        found=0
        ;;
    esac
  done <"${file}"
  [ "${found}" = 0 ] || return 1
  printf '%s' "${out}"
}

# @function infisical_default_env_file
# Print the env file to read and write when the caller names none. One resolution for
# the whole file, so a pull, a push and the profile flag can never disagree about
# which .env they mean: ENV_FILE wins, then the .env beside COMPOSE_FILE (which is the
# file compose itself interpolates), then the cwd .env the entry scripts land on after
# their repo-root cd.
# Globals:
#   ENV_FILE, COMPOSE_FILE
# Arguments:
#   None
# Outputs:
#   One path on stdout
# Returns:
#   0
infisical_default_env_file() {
  if [ -n "${ENV_FILE:-}" ]; then
    printf '%s\n' "${ENV_FILE}"
  elif [ -n "${COMPOSE_FILE:-}" ]; then
    printf '%s/.env\n' "$(dirname "${COMPOSE_FILE}")"
  else
    printf '%s\n' '.env'
  fi
}

# @function infisical_env_value
# Print one configuration value for the Infisical CLI: the process environment first,
# then the env file. A process value that is set but empty counts as "not stated",
# because every key here ships empty in .env.example and an empty credential means
# unconfigured rather than deliberately blank.
# Globals:
#   ENV_FILE (the default env file when the caller names none)
# Arguments:
#   $1 - key name
#   $2 - env file to fall back to; empty means infisical_default_env_file's answer
# Outputs:
#   The value on stdout, with no trailing newline; nothing when neither source has it
# Returns:
#   0, always: a missing key is a state to branch on, not a command failure
infisical_env_value() {
  local key="$1" env_file="${2:-}" value=""
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if [[ ${key} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [ -n "${!key:-}" ]; then
    value="${!key}"
  else
    value="$(infisical_dotenv_get "${env_file}" "${key}")" || value=""
  fi
  printf '%s' "${value}"
}

# @function infisical_hash_of
# Print the sha256 hex of a value, used only to compare what was written with what
# came back. The value reaches the hasher through a pipe and never through argv: an
# exec'd process's argv is world-readable through /proc.
# Globals:
#   None
# Arguments:
#   $1 - text to hash
# Outputs:
#   The hex digest on stdout
# Returns:
#   0
infisical_hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

# @function infisical_write_env
# Replace or append one key in an env file and prove it landed, the way
# scripts/dashboard-password.sh:252 does: copy the file line by line so no byte
# outside the one line moves, mktemp in the SAME directory so the mv is an atomic
# rename rather than a window where .env does not exist, keep exactly one occurrence
# of the key, then re-read and compare a hash before claiming success.
# Globals:
#   INFISICAL_TMP_FILES, INFISICAL_MKTEMP (via infisical_mktemp)
# Arguments:
#   $1 - key name, which must look like an env key
#   $2 - value, copied verbatim; the caller got it from a file, never from the CLI's
#     stdout
#   $3 - env file path
# Outputs:
#   None. Rewrites the env file mode 600; creates it mode 600 when absent.
# Returns:
#   0 when the read-back hash matches; 1 when the write or the verify failed; 2 on a
#   bad key name
infisical_write_env() {
  if [ "$#" -lt 3 ]; then
    err "infisical_write_env needs <key> <value> <env-file>"
    return 2
  fi
  local key="$1" value="$2" env_file="$3"
  local tmp="" line="" seen=0 back=""
  if [[ ! ${key} =~ ^[A-Z0-9_]+$ ]]; then
    err "refusing to write '${key}' to ${env_file}: not an upper-case env key"
    return 2
  fi
  if [ ! -f "${env_file}" ]; then
    : >"${env_file}" 2>/dev/null || {
      err "cannot create ${env_file}"
      return 1
    }
    chmod 600 "${env_file}"
  fi
  infisical_mktemp "${env_file}.tmp" || {
    err "cannot make a temp beside ${env_file}"
    return 1
  }
  tmp="${INFISICAL_MKTEMP}"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${key}"=*)
        # Compose resolves a duplicated key by last match, so a stale later line
        # would leave the file disagreeing with what this run wrote.
        if [ "${seen}" = 0 ]; then
          printf '%s=%s\n' "${key}" "${value}"
        fi
        seen=1
        continue
        ;;
    esac
    printf '%s\n' "${line}"
  done <"${env_file}" >"${tmp}"
  if [ "${seen}" = 0 ]; then
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
  fi
  if ! mv -- "${tmp}" "${env_file}"; then
    err "cannot replace ${env_file}"
    return 1
  fi
  chmod 600 "${env_file}"
  back="$(infisical_dotenv_get "${env_file}" "${key}")" || back=""
  if [ "$(infisical_hash_of "${back}")" != "$(infisical_hash_of "${value}")" ]; then
    err "${key} does not hold the value that was written into ${env_file}"
    return 1
  fi
  return 0
}

# @function infisical_enabled
# The one reader of the INFISICAL_ENABLED flag. Off unless truthy accepts the value,
# so an absent key and a blank one both mean off -- the deliberate opposite of
# compose_observability_args in scripts/lib/common.sh:349, where absent means on.
# The process environment outranks the file, which is compose's own interpolation
# precedence, so a profile cannot disagree with the values it was interpolated with.
# Globals:
#   INFISICAL_ENABLED (when set non-empty, it wins), ENV_FILE
# Arguments:
#   $1 - env file carrying the key; empty means infisical_default_env_file's answer
# Outputs:
#   Nothing (this is a predicate, not a printer)
# Returns:
#   0 when the flag is truthy, 1 otherwise
infisical_enabled() {
  local env_file="${1:-}" value=""
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  value="$(infisical_env_value INFISICAL_ENABLED "${env_file}")"
  truthy "${value}"
}

# @function compose_infisical_args
# Print the compose argv words that select the `secrets` profile, or nothing when the
# tier is switched off. Mirrors compose_observability_args (scripts/lib/common.sh:349)
# on purpose: every command that addresses the compose project passes what this
# prints, so the three profile-gated services are either in every invocation or in
# none. Off is the shipped default, so the common answer here is no output at all.
# Globals:
#   INFISICAL_ENABLED, ENV_FILE, COMPOSE_FILE (through infisical_enabled and
#   infisical_default_env_file)
# Arguments:
#   $1 - env file that carries the key; empty means infisical_default_env_file's
#     answer, which is the file compose itself interpolates
# Outputs:
#   "--profile secrets" on one line when enabled; nothing otherwise
# Returns:
#   0, always: callers expand this inside a command substitution under `set -e`,
#   where a non-zero answer would abort the argv build
compose_infisical_args() {
  if infisical_enabled "${1:-}"; then
    printf '%s\n' '--profile secrets'
  fi
  return 0
}

# @function infisical_managed_keys
# Print the stack's secret surface, one key per line. The inventory file is the only
# list; nothing here or elsewhere re-hardcodes it. A '#' comment, a blank line, and
# anything that is not an upper-case key name is dropped by the one grep, so the
# banners in that file document who consumes each group without becoming structure.
# Globals:
#   REPO_ROOT, BUILD_WORKSPACE_DIRECTORY, GITHUB_WORKSPACE, PWD (through
#   resolve_checkout, which locates the default inventory; the directory beside
#   this file is the fallback)
# Arguments:
#   $1 - inventory path; defaults to <checkout>/infisical/managed-secrets.txt
# Outputs:
#   One KEY per line on stdout
# Returns:
#   0 when at least one key was printed; 5 when the file is missing, unreadable, or
#   holds no key
infisical_managed_keys() {
  local inventory="${1:-}" root="" own="" candidate=""
  if [ -z "${inventory}" ]; then
    # The checkout first: that is the copy an operator edits. The directory beside
    # this file is the fallback, because `bazelisk run` executes from a runfiles
    # tree whose cwd holds no inventory of its own, and this list is read-only
    # payload, so reading the copy that sits with the code is never wrong here.
    own="${BASH_SOURCE[0]%/*}"
    root="$(resolve_checkout "${own}" docker-compose.yml 2>/dev/null)" || root=""
    for candidate in "${root:+${root}/infisical/managed-secrets.txt}" \
      "${own}/../infisical/managed-secrets.txt"; do
      if [ -r "${candidate}" ]; then
        inventory="${candidate}"
        break
      fi
    done
  fi
  if [ ! -r "${inventory}" ]; then
    err "no readable managed-key inventory at ${inventory:-<checkout>/infisical/managed-secrets.txt}"
    return 5
  fi
  local printed=0 line=""
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ ${line} =~ ^[A-Z0-9_]+$ ]]; then
      printf '%s\n' "${line}"
      printed=1
    fi
  done <"${inventory}"
  [ "${printed}" = 1 ] || {
    err "no managed keys in ${inventory}"
    return 5
  }
  return 0
}

# @function infisical_cli_install_path
# Print where infisical_install_cli puts its own copy of the binary. It sits under
# $HOME rather than in the checkout: an ignored-but-present binary in the tree would
# show up in git status, and this file may not add a .gitignore entry.
# Globals:
#   XDG_DATA_HOME, HOME
# Arguments:
#   None
# Outputs:
#   One absolute path on stdout
# Returns:
#   0
infisical_cli_install_path() {
  local base="${XDG_DATA_HOME:-${HOME:-/tmp}/.local/share}"
  printf '%s\n' "${base}/evo-t1/infisical/bin/infisical"
}

# @function infisical_cli_bin
# Print the Infisical CLI to run: the operator's override, then PATH, then the copy
# this stack installed. Prints nothing when there is no binary, so a caller can
# command-substitute it into an empty variable and branch on the status.
# Globals:
#   INFISICAL_CLI_BIN (absolute path the operator set by hand)
# Arguments:
#   None
# Outputs:
#   One executable path on stdout when one exists
# Returns:
#   0 with the path; 5 when no Infisical CLI is installed anywhere
infisical_cli_bin() {
  local candidate=""
  candidate="$(infisical_env_value INFISICAL_CLI_BIN)"
  if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  candidate="$(command -v infisical 2>/dev/null)" || candidate=""
  if [ -n "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  candidate="$(infisical_cli_install_path)"
  if [ -x "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  return 5
}

# @function infisical_cli_url
# Print the release tarball URL for the pinned version, built from the goreleaser
# asset name upstream ships. The version is validated before it reaches a URL: this
# string is handed to curl, so a value with a slash or a dot-dot in it is refused
# rather than interpolated.
# Globals:
#   INFISICAL_CLI_VERSION (a released version with no leading v; default 0.45.8)
# Arguments:
#   None
# Outputs:
#   The https URL on stdout
# Returns:
#   0 with the URL; 5 when INFISICAL_CLI_VERSION is not a plain version string
infisical_cli_url() {
  local version="" asset=""
  version="$(infisical_env_value INFISICAL_CLI_VERSION)"
  [ -n "${version}" ] || version="0.45.8"
  if [[ ! ${version} =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; then
    err "INFISICAL_CLI_VERSION='${version}' is not a release version (no leading v, no path)"
    return 5
  fi
  asset="${INFISICAL_CLI_ASSET//\{version\}/${version}}"
  printf '%s/v%s/%s\n' "${INFISICAL_CLI_RELEASE_BASE}" "${version}" "${asset}"
}

# @function infisical_run_cli
# Run the Infisical CLI with the one global every call needs: INFISICAL_DOMAIN, which
# self-hosted requires or the CLI dials Infisical's US cloud instead of this box.
# Every other call in this file goes through here so that cannot be forgotten.
# Globals:
#   INFISICAL_DOMAIN (honoured when already set), INFISICAL_URL, INFISICAL_PORT
# Arguments:
#   $1... - the CLI's own arguments
# Outputs:
#   The CLI's own stdout and stderr
# Returns:
#   The CLI's status; 5 when no CLI binary exists
infisical_run_cli() {
  local bin=""
  bin="$(infisical_cli_bin)" || return 5
  if [ -z "${INFISICAL_DOMAIN:-}" ]; then
    INFISICAL_DOMAIN="$(infisical_env_value INFISICAL_URL)"
  fi
  if [ -z "${INFISICAL_DOMAIN}" ]; then
    INFISICAL_DOMAIN="http://127.0.0.1:$(infisical_env_value INFISICAL_PORT)"
    [ "${INFISICAL_DOMAIN}" != "http://127.0.0.1:" ] ||
      INFISICAL_DOMAIN="http://127.0.0.1:8182"
  fi
  export INFISICAL_DOMAIN
  "${bin}" "$@"
}

# @function infisical_install_cli
# Download the pinned release, prove the tarball is a tarball that holds the binary,
# then install it mode 0755. The download is fetched to a file and unpacked from it:
# curl is never piped into a shell, and a truncated or HTML-error body fails the
# member listing instead of running.
# Globals:
#   INFISICAL_CLI_ASSET, INFISICAL_TMP_FILES, INFISICAL_MKTEMP (via infisical_mktemp)
# Arguments:
#   None
# Outputs:
#   phase/ok lines naming only the URL, the version, and the install path
# Returns:
#   0 on success; 1 on a missing curl, a failed download, a tarball without the
#   binary, or a failed install; 5 when the pinned version is not a version
infisical_install_cli() {
  local url="" tarball="" member="" dest="" dir=""
  url="$(infisical_cli_url)" || return 5
  if ! has_tool curl; then
    err "curl is not on PATH, so the Infisical CLI cannot be fetched"
    return 1
  fi
  if ! has_tool tar; then
    err "tar is not on PATH, so the Infisical CLI archive cannot be verified"
    return 1
  fi
  dest="$(infisical_cli_install_path)"
  dir="${dest%/*}"

  phase "fetching the Infisical CLI from ${url}"
  infisical_mktemp "${TMPDIR:-/tmp}/infisical-cli" || {
    err "cannot make a temp file for the download"
    return 1
  }
  tarball="${INFISICAL_MKTEMP}"
  if ! capped_run 300 curl -fsSL --retry 2 -o "${tarball}" "${url}"; then
    err "download failed: ${url}"
    return 1
  fi
  if [ ! -s "${tarball}" ]; then
    err "download wrote no bytes: ${url}"
    return 1
  fi
  # The member listing is the integrity check: a gzip or tar that will not open the
  # archive fails here, before anything from it is run. tar's own status is kept in
  # its own assignment rather than left to the pipeline's last command, because a
  # caller that did not set pipefail would otherwise see head(1)'s exit 0 and read a
  # corrupt download as an archive with no member in it.
  local listing=""
  if ! listing="$(tar -tzf "${tarball}" 2>/dev/null)"; then
    err "the download is not a readable tar.gz: ${url}"
    return 1
  fi
  member="$(printf '%s\n' "${listing}" | grep -E '(^|/)infisical$' | head -n 1)" || member=""
  if [ -z "${member}" ] || [[ ${member} == *..* ]] || [[ ${member} == /* ]]; then
    err "the archive holds no plain infisical member"
    return 1
  fi
  phase "installing it mode 0755 at ${dest}"
  if ! mkdir -p -- "${dir}"; then
    err "cannot create ${dir}"
    return 1
  fi
  chmod 755 -- "${dir}"
  # One member to stdout, into a temp this run owns, so the archive never writes a
  # path of its own choosing, and so the install is not a partial file on a failure.
  local staged=""
  infisical_mktemp "${dir}/infisical.new" || {
    err "cannot make a temp beside ${dest}"
    return 1
  }
  staged="${INFISICAL_MKTEMP}"
  if ! tar -xzf "${tarball}" -O -- "${member}" >"${staged}"; then
    err "cannot extract ${member} from the archive"
    return 1
  fi
  chmod 755 "${staged}"
  if ! mv -- "${staged}" "${dest}"; then
    err "cannot install ${dest}"
    return 1
  fi
  chmod 755 "${dest}"
  ok "installed the Infisical CLI at ${dest}"
  return 0
}

# @function infisical_login
# Exchange the machine identity's Universal Auth pair for an access token and print
# that token on stdout and nowhere else. This is the one function allowed to put a
# credential on a stream, because handing it to its caller is its whole job; it logs
# nothing. Upstream takes the pair only as flags, so the secret does reach this
# process's argv; it never reaches a log line, a file, or a shell history entry.
# Globals:
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID, INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
# Arguments:
#   $1 - env file to read the pair from; empty means infisical_default_env_file's
#     answer
# Outputs:
#   The access token alone on stdout; every commentary line this function can print is
#   written on stderr, so a caller that captures stdout gets the credential and nothing
#   else, on every branch
# Returns:
#   0 with the token; 5 when the flag is off or the pair is unconfigured; the CLI's
#   status otherwise
infisical_login() {
  local env_file="${1:-}" client_id="" client_secret=""
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if ! infisical_enabled "${env_file}"; then
    printf '%s\n' "note: INFISICAL_ENABLED is off; not authenticating." >&2
    return 5
  fi
  client_id="$(infisical_env_value INFISICAL_UNIVERSAL_AUTH_CLIENT_ID "${env_file}")"
  client_secret="$(infisical_env_value INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET "${env_file}")"
  if [ -z "${client_id}" ] || [ -z "${client_secret}" ]; then
    err "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID or INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET is empty in ${env_file}; create the machine identity's Universal Auth credentials and paste both"
    return 5
  fi
  # The commentary goes to stderr, not through phase(): this function's stdout is the
  # access token and nothing else, and a caller that captures it with $( ) would
  # otherwise glue a "-> ..." line onto the front of the credential.
  printf '%s\n' "-> exchanging the machine identity credentials for an access token" >&2
  infisical_run_cli login \
    --method=universal-auth \
    --client-id="${client_id}" \
    --client-secret="${client_secret}" \
    --plain \
    --silent
}

# @function infisical_ensure_auth
# Authenticate before a read or write, for the login command's session side effect
# only. Its stdout is dropped rather than captured: the token is not needed here, and
# keeping it out of this shell keeps it out of every later argv and log line.
# Globals:
#   None
# Arguments:
#   $1 - env file to read the credentials from
# Outputs:
#   infisical_login's commentary; its token goes to /dev/null
# Returns:
#   0 on success; 5 when login refused (flag off, pair unset); its status otherwise
infisical_ensure_auth() {
  infisical_login "${1:-}" >/dev/null
}

# @function infisical_secrets_dump
# Export the project's secrets straight into a mode-600 file with the CLI's own
# --output-file. The values never cross this shell: no command substitution, no pipe,
# no variable, no log line. The caller names the destination, which it made with
# infisical_mktemp so the EXIT trap owns it, and gets the path back as the only thing
# this prints.
# Globals:
#   INFISICAL_PROJECT_ID, INFISICAL_ENVIRONMENT
# Arguments:
#   $1 - destination path (required; make it with infisical_mktemp)
#   $2 - env file the two keys above are read from
# Outputs:
#   The destination path on stdout; the CLI's own diagnostics on its stderr
# Returns:
#   0 with the path on stdout; 2 when no destination was given; 5 when the flag is
#   off, the project is unset or the login was refused; the CLI's status when the
#   export failed
infisical_secrets_dump() {
  local dest="${1:-}" env_file="${2:-}"
  local project_id="" environment=""
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if [ -z "${dest}" ]; then
    err "infisical_secrets_dump needs a destination path"
    return 2
  fi
  if ! infisical_enabled "${env_file}"; then
    note "INFISICAL_ENABLED is off; not exporting secrets."
    return 5
  fi
  project_id="$(infisical_env_value INFISICAL_PROJECT_ID "${env_file}")"
  if [ -z "${project_id}" ]; then
    err "INFISICAL_PROJECT_ID is empty; run //scripts:infisical bootstrap first"
    return 5
  fi
  environment="$(infisical_env_value INFISICAL_ENVIRONMENT "${env_file}")"
  [ -n "${environment}" ] || environment="prod"

  if [ ! -e "${dest}" ]; then
    : >"${dest}" 2>/dev/null || {
      err "cannot create ${dest}"
      return 1
    }
  fi
  chmod 600 "${dest}"
  infisical_ensure_auth "${env_file}" || return 5
  infisical_run_cli sm secrets export \
    --env="${environment}" \
    --projectId="${project_id}" \
    --format=dotenv \
    --expand=true \
    --include-imports=true \
    --output-file="${dest}" || return 1
  printf '%s\n' "${dest}"
}

# @function infisical_secret_set
# Write one secret, taking the value from a file rather than from argv: the @path
# form is the only channel upstream offers that keeps a password out of ps, since
# there is no stdin path. The caller owns the file's lifetime.
# Globals:
#   INFISICAL_PROJECT_ID, INFISICAL_ENVIRONMENT
# Arguments:
#   $1 - key name, which must look like an env key
#   $2 - file holding the value alone (no trailing newline needed; the CLI takes the
#     file's bytes)
#   $3 - env file the two globals above are read from
# Outputs:
#   The CLI's own output; this function adds no line naming a value
# Returns:
#   0 on success; 2 on a bad key or a missing file; 5 when the flag is off, the
#   project is unset or the login was refused; the CLI's status otherwise
infisical_secret_set() {
  local key="${1:-}" value_file="${2:-}" env_file="${3:-}"
  local project_id="" environment=""
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if [[ ! ${key} =~ ^[A-Z0-9_]+$ ]]; then
    err "infisical_secret_set needs an upper-case KEY, got '${key}'"
    return 2
  fi
  if [ -z "${value_file}" ] || [ ! -r "${value_file}" ]; then
    err "infisical_secret_set needs a readable file holding ${key}'s value"
    return 2
  fi
  if ! infisical_enabled "${env_file}"; then
    note "INFISICAL_ENABLED is off; not writing ${key}."
    return 5
  fi
  project_id="$(infisical_env_value INFISICAL_PROJECT_ID "${env_file}")"
  if [ -z "${project_id}" ]; then
    err "INFISICAL_PROJECT_ID is empty; run //scripts:infisical bootstrap first"
    return 5
  fi
  environment="$(infisical_env_value INFISICAL_ENVIRONMENT "${env_file}")"
  [ -n "${environment}" ] || environment="prod"
  chmod 600 "${value_file}"
  phase "writing ${key} to the Infisical project"
  infisical_ensure_auth "${env_file}" || return 5
  infisical_run_cli sm secrets set "${key}=@${value_file}" \
    --env="${environment}" \
    --path=/ \
    --projectId="${project_id}" \
    --type=shared
}

# @function infisical_pull
# Reconcile the managed keys from Infisical into the env file, then let compose
# recreate. Only keys the export actually carries are written: a managed key that is
# absent from the vault is a warning, never a blanked line, because a half-seeded
# project would otherwise lock every service out of its own credential. Each write
# goes through infisical_write_env, which re-reads and hashes before it claims ok.
# Globals:
#   INFISICAL_ENABLED, INFISICAL_PROJECT_ID, INFISICAL_ENVIRONMENT
# Arguments:
#   $1 - env file to write; empty means infisical_default_env_file's answer
#   $2 - inventory path; defaults to infisical_managed_keys' own
# Outputs:
#   one warning per key the vault does not hold or holds empty, and one count line;
#   no line names a value
# Returns:
#   0 when every key the vault holds landed, with warnings when the vault is short
#   some key; 0 with a note when the flag is off, the file left alone; 1 when a write
#   or the export failed; 5 when the project id is unset
infisical_pull() {
  local env_file="${1:-}" inventory="${2:-}"
  local dump="" key="" value="" dump_rc=0 wrote=0 skipped=0 failed=0
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if ! infisical_enabled "${env_file}"; then
    note "INFISICAL_ENABLED is off; ${env_file} keeps the values it has."
    return 0
  fi
  local -a keys=()
  while IFS= read -r key || [ -n "${key}" ]; do
    [ -n "${key}" ] && keys+=("${key}")
  done < <(infisical_managed_keys "${inventory}")
  if [ "${#keys[@]}" = 0 ]; then
    err "no managed keys to pull"
    return 1
  fi
  phase "exporting ${#keys[@]} managed keys from Infisical"
  infisical_mktemp "${TMPDIR:-/tmp}/infisical-dump" || {
    err "cannot make a temp file for the export"
    return 1
  }
  dump="${INFISICAL_MKTEMP}"
  infisical_secrets_dump "${dump}" "${env_file}" >/dev/null
  dump_rc=$?
  if [ "${dump_rc}" != 0 ]; then
    if [ "${dump_rc}" = 5 ]; then
      note "the pull was refused before it ran; ${env_file} keeps the values it has"
    else
      err "the Infisical export failed; ${env_file} is untouched"
    fi
    return "${dump_rc}"
  fi
  if [ ! -s "${dump}" ]; then
    warn "the Infisical export produced an empty file; ${env_file} is untouched"
    return 1
  fi
  for key in "${keys[@]}"; do
    if ! value="$(infisical_dotenv_get "${dump}" "${key}")"; then
      warn "${key} is not in the Infisical project; the existing value in ${env_file} stays as it is"
      skipped=$((skipped + 1))
      continue
    fi
    if [ -z "${value}" ]; then
      warn "${key} is empty in the Infisical project; refusing to blank it in ${env_file}"
      skipped=$((skipped + 1))
      continue
    fi
    if infisical_write_env "${key}" "${value}" "${env_file}"; then
      wrote=$((wrote + 1))
    else
      failed=$((failed + 1))
    fi
  done
  if [ "${failed}" != 0 ]; then
    err "${failed} of ${#keys[@]} managed keys did not land in ${env_file}"
    return 1
  fi
  ok "pulled ${wrote} managed key(s) into ${env_file} (mode 600), ${skipped} left alone"
  return 0
}

# @function infisical_push
# Seed or migrate the managed keys from the env file into Infisical, and then prove
# it by exporting again and comparing a hash per key. Keys the env file does not hold
# are skipped with a warning rather than pushed empty, which would blank them in the
# vault for every later pull.
# Globals:
#   INFISICAL_ENABLED, INFISICAL_PROJECT_ID, INFISICAL_ENVIRONMENT
# Arguments:
#   $1 - env file to read; empty means infisical_default_env_file's answer
#   $2 - inventory path; defaults to infisical_managed_keys' own
# Outputs:
#   one warning per key with nothing to push, one ok line naming counts only, and the
#   CLI's own output
# Returns:
#   0 when every key the env file held is present and equal in the vault; 0 with a
#   note when the flag is off, nothing pushed; 1 when the set failed or a read-back
#   hash disagreed; 5 when the project id is unset
infisical_push() {
  local env_file="${1:-}" inventory="${2:-}"
  local pushfile="" verify="" key="" value="" want="" got=""
  local set_rc=0 dump_rc=0
  local pushed=0 skipped=0 failed=0
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if ! infisical_enabled "${env_file}"; then
    note "INFISICAL_ENABLED is off; nothing pushed."
    return 0
  fi
  local -a keys=()
  while IFS= read -r key || [ -n "${key}" ]; do
    [ -n "${key}" ] && keys+=("${key}")
  done < <(infisical_managed_keys "${inventory}")
  if [ "${#keys[@]}" = 0 ]; then
    err "no managed keys to push"
    return 1
  fi
  infisical_mktemp "${TMPDIR:-/tmp}/infisical-push" || {
    err "cannot make a temp file for the push"
    return 1
  }
  pushfile="${INFISICAL_MKTEMP}"
  for key in "${keys[@]}"; do
    if ! value="$(infisical_dotenv_get "${env_file}" "${key}")"; then
      warn "${key} is not in ${env_file}; nothing pushed for it"
      skipped=$((skipped + 1))
      continue
    fi
    if [ -z "${value}" ]; then
      warn "${key} is empty in ${env_file}; not pushing an empty value"
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s=%s\n' "${key}" "${value}" >>"${pushfile}"
    pushed=$((pushed + 1))
  done
  if [ "${pushed}" = 0 ]; then
    warn "no managed key has a value in ${env_file}; nothing was pushed"
    return 0
  fi
  phase "pushing ${pushed} managed key(s) to Infisical"
  infisical_secrets_set_file "${pushfile}" "${env_file}"
  set_rc=$?
  if [ "${set_rc}" != 0 ]; then
    if [ "${set_rc}" = 5 ]; then
      note "the push was refused before it ran; nothing was verified"
    else
      err "the Infisical set failed; nothing was verified"
    fi
    return "${set_rc}"
  fi
  # Read the vault back: a set that the server accepted and then dropped, or rewrote
  # through an import, must not be reported as a successful seed.
  phase "reading the vault back to confirm it"
  infisical_mktemp "${TMPDIR:-/tmp}/infisical-verify" || {
    err "cannot make a temp file for the read-back"
    return 1
  }
  verify="${INFISICAL_MKTEMP}"
  infisical_secrets_dump "${verify}" "${env_file}" >/dev/null
  dump_rc=$?
  if [ "${dump_rc}" != 0 ]; then
    warn "the push ran but the read-back export failed; check //scripts:infisical status"
    return 1
  fi
  for key in "${keys[@]}"; do
    value="$(infisical_dotenv_get "${pushfile}" "${key}")" || continue
    if ! got="$(infisical_dotenv_get "${verify}" "${key}")"; then
      warn "${key} is not in the vault after the push"
      failed=$((failed + 1))
      continue
    fi
    want="$(infisical_hash_of "${value}")"
    if [ "${want}" != "$(infisical_hash_of "${got}")" ]; then
      warn "${key} differs in the vault after the push; check for an import that overrides it"
      failed=$((failed + 1))
    fi
  done
  if [ "${failed}" != 0 ]; then
    err "${failed} managed key(s) did not read back unchanged"
    return 1
  fi
  ok "pushed ${pushed} managed key(s) to Infisical, ${skipped} skipped as absent"
  return 0
}

# @function infisical_secrets_set_file
# Push every KEY=value line of a dotenv file into the project as shared secrets. The
# file is the only channel the values travel through, so this is the bulk twin of
# infisical_secret_set and the primitive infisical_push builds on.
# Globals:
#   INFISICAL_PROJECT_ID, INFISICAL_ENVIRONMENT
# Arguments:
#   $1 - dotenv file to send (the caller made it and the EXIT trap owns it)
#   $2 - env file the two globals above are read from
# Outputs:
#   a phase line naming the count, and the CLI's own output
# Returns:
#   0 on success; 2 on a missing file or one that holds no KEY=value line; 5 when the
#   flag is off, the project is unset or the login was refused; the CLI's status
#   otherwise
infisical_secrets_set_file() {
  local pushfile="${1:-}" env_file="${2:-}"
  local project_id="" environment="" lines=0
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if [ -z "${pushfile}" ] || [ ! -r "${pushfile}" ]; then
    err "infisical_secrets_set_file needs a readable dotenv file"
    return 2
  fi
  if ! infisical_enabled "${env_file}"; then
    note "INFISICAL_ENABLED is off; nothing pushed."
    return 5
  fi
  project_id="$(infisical_env_value INFISICAL_PROJECT_ID "${env_file}")"
  if [ -z "${project_id}" ]; then
    err "INFISICAL_PROJECT_ID is empty; run //scripts:infisical bootstrap first"
    return 5
  fi
  environment="$(infisical_env_value INFISICAL_ENVIRONMENT "${env_file}")"
  [ -n "${environment}" ] || environment="prod"
  chmod 600 "${pushfile}"
  lines="$(grep -cE '^[A-Z0-9_]+=' "${pushfile}" 2>/dev/null)" || lines=0
  if [ "${lines}" -eq 0 ]; then
    # An empty batch is a caller bug, and sending it would report a successful push of
    # nothing, which is how a vault silently stops holding any of the stack's secrets.
    err "infisical_secrets_set_file: ${pushfile} holds no KEY=value line; nothing sent"
    return 2
  fi
  phase "sending ${lines} secret(s) to project ${project_id} as shared"
  infisical_ensure_auth "${env_file}" || return 5
  # --type is shared on set and personal on delete, so it is named on both rather than
  # letting a later delete look for a secret this push wrote as shared.
  infisical_run_cli sm secrets set --file="${pushfile}" \
    --env="${environment}" \
    --path=/ \
    --projectId="${project_id}" \
    --type=shared
}

# @function infisical_bootstrap
# Create the super admin, the organization, and the machine identity on a fresh
# self-hosted instance, and record the identifiers a later call needs. The JSON goes
# to a mode-600 temp by redirect and is parsed with python3 -- there is no jq
# guarantee here. The identity token is checked for presence and deliberately not
# stored: .env.example:696 keeps it inside Infisical, and every later run exchanges
# the Universal Auth pair for a fresh one.
# Globals:
#   INFISICAL_ENABLED, INFISICAL_URL, INFISICAL_ORGANIZATION, INFISICAL_ADMIN_EMAIL,
#   INFISICAL_ADMIN_PASSWORD, INFISICAL_PROJECT_ID, INFISICAL_MACHINE_IDENTITY_ID
# Arguments:
#   $1 - env file to read and write; empty means infisical_default_env_file's answer
# Outputs:
#   phase/ok/note lines naming the domain, the organization id, the identity id and
#   the env file. The password, the token, and the JSON itself are never printed
# Returns:
#   0 when the run landed and the machine identity id was written; the organization id
#   is reported on the ok line and deliberately not stored, since nothing in the stack
#   reads it; 0 with a note when the instance already looks bootstrapped; 5 when the
#   flag is off or a prerequisite is missing, still a placeholder, or the CLI is absent;
#   1 when the CLI failed, the JSON was unparsable, or an id did not land
infisical_bootstrap() {
  local env_file="${1:-}"
  local json="" domain="" email="" password="" organization=""
  local identity_id="" org_id="" project_id="" token_seen="no"
  local parsed="" field="" value=""
  [ -n "${env_file}" ] || env_file="$(infisical_default_env_file)"
  if ! infisical_enabled "${env_file}"; then
    note "INFISICAL_ENABLED is off; bootstrap does nothing. Set it in ${env_file} first."
    return 5
  fi
  project_id="$(infisical_env_value INFISICAL_PROJECT_ID "${env_file}")"
  identity_id="$(infisical_env_value INFISICAL_MACHINE_IDENTITY_ID "${env_file}")"
  if [ -n "${project_id}" ] || [ -n "${identity_id}" ]; then
    note "this instance already looks bootstrapped (INFISICAL_PROJECT_ID or INFISICAL_MACHINE_IDENTITY_ID is set in ${env_file}); refusing to run it again"
    return 0
  fi
  domain="$(infisical_env_value INFISICAL_URL "${env_file}")"
  [ -n "${domain}" ] || domain="http://127.0.0.1:8182"
  email="$(infisical_env_value INFISICAL_ADMIN_EMAIL "${env_file}")"
  password="$(infisical_env_value INFISICAL_ADMIN_PASSWORD "${env_file}")"
  organization="$(infisical_env_value INFISICAL_ORGANIZATION "${env_file}")"
  [ -n "${organization}" ] || organization="evo-t1"
  if [ -z "${email}" ]; then
    err "INFISICAL_ADMIN_EMAIL is empty in ${env_file}; there is no signup toggle upstream, so bootstrap needs the one super admin's address"
    return 5
  fi
  if [ -z "${password}" ] || [[ ${password} == change-me* ]]; then
    err "INFISICAL_ADMIN_PASSWORD is empty or still the shipped change-me placeholder in ${env_file}"
    return 5
  fi
  infisical_cli_bin >/dev/null || {
    err "no Infisical CLI is installed; run //scripts:infisical install-cli first"
    return 5
  }
  if ! has_tool python3; then
    err "python3 is not on PATH, so the bootstrap JSON cannot be parsed"
    return 5
  fi

  infisical_mktemp "${TMPDIR:-/tmp}/infisical-bootstrap" || {
    err "cannot make a temp file for the bootstrap JSON"
    return 1
  }
  json="${INFISICAL_MKTEMP}"
  phase "bootstrapping the Infisical instance at ${domain}"
  # The password reaches the CLI as a flag because upstream offers no other channel;
  # the response is redirected to the mode-600 temp so no token crosses this shell.
  if ! infisical_run_cli bootstrap \
    --domain="${domain}" \
    --email="${email}" \
    --password="${password}" \
    --organization="${organization}" \
    --output=json >"${json}"; then
    err "the Infisical bootstrap run failed; nothing was written to ${env_file}"
    return 1
  fi
  if [ ! -s "${json}" ]; then
    err "the bootstrap run returned no JSON; nothing was written to ${env_file}"
    return 1
  fi

  # One python3 pass prints the fields worth keeping and only a yes/no for the token,
  # so the credential never leaves the file it was written into. Unpinned paths
  # answer empty rather than failing: the pinned output names identity, organization
  # and user, and a release that drops one must not break the run.
  if ! parsed="$(
    python3 - "${json}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)


def get(path):
    node = data
    for part in path.split("."):
        if not isinstance(node, dict):
            return ""
        node = node.get(part)
    if node is None:
        return ""
    return node if isinstance(node, str) else ""


print("INFISICAL_MACHINE_IDENTITY_ID\t" + get("identity.id"))
print("INFISICAL_ORGANIZATION_ID\t" + get("organization.id"))
print("INFISICAL_ADMIN_EMAIL\t" + get("user.email"))
print("INFISICAL_PROJECT_ID\t" + get("project.id"))
print("TOKEN\t" + ("yes" if get("identity.credentials.token") else "no"))
PY
  )"; then
    err "the bootstrap JSON was not readable as JSON; nothing was written to ${env_file}"
    return 1
  fi

  while IFS=$'\t' read -r field value; do
    case "${field}" in
      TOKEN) token_seen="${value}" ;;
      # Report-only: nothing in the stack reads an organization id, so it names the ok
      # line and never lands in .env, where an unconsumed key would outlive its use.
      INFISICAL_ORGANIZATION_ID) org_id="${value}" ;;
      INFISICAL_MACHINE_IDENTITY_ID)
        identity_id="${value}"
        [ -n "${value}" ] || continue
        if ! infisical_write_env "${field}" "${value}" "${env_file}"; then
          err "${field} did not land in ${env_file}"
          return 1
        fi
        ;;
      INFISICAL_ADMIN_EMAIL | INFISICAL_PROJECT_ID)
        [ -n "${value}" ] || continue
        if ! infisical_write_env "${field}" "${value}" "${env_file}"; then
          err "${field} did not land in ${env_file}"
          return 1
        fi
        ;;
    esac
  done <<<"${parsed}"

  if [ -z "${identity_id}" ]; then
    err "the bootstrap JSON carried no machine identity id; check the instance at ${domain}"
    return 1
  fi
  ok "bootstrapped organization ${org_id:-unnamed} at ${domain}"
  ok "recorded the machine identity and its id in ${env_file} (mode 600)"
  if [ "${token_seen}" = "yes" ]; then
    note "the machine identity token was received and not stored: it stays inside Infisical, and every later run exchanges the Universal Auth pair for a fresh one"
  fi
  if [ -z "$(infisical_env_value INFISICAL_UNIVERSAL_AUTH_CLIENT_ID "${env_file}")" ]; then
    note "create Universal Auth credentials for that machine identity in the Infisical UI, then paste INFISICAL_UNIVERSAL_AUTH_CLIENT_ID and INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET into ${env_file}"
  fi
  return 0
}
