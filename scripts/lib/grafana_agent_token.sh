# shellcheck shell=bash
#
# ## grafana_agent_token.sh - the rules behind scripts/grafana-agent-token.sh (sourced; never executed)
#
# Invariants:
#   - The minted token is data, never prose: nothing here prints it. Every string the
#     caller shows an operator goes through gat_redact first, because the one response
#     body that carries the token is also the one body a transport is free to quote
#     back when it fails.
#   - The credential reaches the API through a curl config file written 0600 inside a
#     0700 scratch directory, never through argv, so neither the admin password nor
#     the token can appear in a process listing, a shell history line, or a test
#     stub's argv log.
#   - What a run may delete is bounded by the naming scheme: only a token whose name
#     this CLI minted (${ACCOUNT_NAME}-token, or that name with a -<n> suffix) is
#     ever revoked, so a rerun cannot leave a second live credential behind without
#     reaching a token another tool minted against the same account.
#   - The alphabet a token may hold is the one obsq_read_token (scripts/lib/
#     observability_query.sh:306) will accept from the file this writes. The two
#     checks are deliberately the same shape: a value this CLI is willing to write is
#     always a value the query CLI is willing to read, and anything carrying a CR or
#     LF is refused here rather than becoming a second header there.
#
# Like every file under scripts/lib/, this one sets no shell options and inherits the
# caller's.

# The alphabet Grafana mints a service-account key from, plus the four characters
# obsq_read_token tolerates. One line, no whitespace, no CR, no LF.
GAT_TOKEN_PATTERN='^[A-Za-z0-9._~-]+$'

# What a redacted token looks like in anything this CLI prints. Same shape as
# OBSQ_TOKEN_REDACTION so an operator reading either CLI's output reads the same word.
GAT_REDACTION='[redacted]'

# @function gat_is_token_shape
# Decide whether a value is one token-shaped string: the alphabet above, non-empty,
# and holding no CR or LF. This is the gate a value passes before it is written to the
# file the query CLI reads, so a truncated response or a whole JSON body cannot become
# a credential.
# Globals:
#   GAT_TOKEN_PATTERN
# Arguments:
#   $1 - the candidate value
# Outputs:
#   None
# Returns:
#   0 when $1 is one token-shaped line, 1 otherwise
gat_is_token_shape() {
  local value="${1:-}"
  [ -n "${value}" ] || return 1
  [[ ${value} =~ ${GAT_TOKEN_PATTERN} ]] || return 1
  return 0
}

# @function gat_refuses_overwrite
# Decide whether writing TOKEN_FILE is a write the operator asked for. Four answers
# are kept apart, because each one needs a different flag:
#
#   a file that holds a token-shaped line is a credential an agent may be holding
#     right now, so it is refused unless --rotate was asked for;
#   a file that is absent, empty, or holds nothing token-shaped is not a credential
#     and is not silently minted into either: at a single box-wide path a mint that
#     nobody asked for is how a credential appears on a box nobody meant to change,
#     so it is refused unless --repair says this run is the mint that establishes it.
#
# The one exception the caller makes itself is --dry-run, which writes nothing.
# Globals:
#   None
# Arguments:
#   $1 - path of the token file
#   $2 - "1" when --rotate was asked for
#   $3 - "1" when --repair was asked for (or when nothing will be written at all)
# Outputs:
#   None
# Returns:
#   0 when the write is safe to perform, 1 when it would rotate a live credential
#   without --rotate, 2 when the path exists and cannot be read, 3 when the path is
#   absent or holds no credential and --repair was not asked for
gat_refuses_overwrite() {
  local path="${1:-}" rotate="${2:-0}" repair="${3:-0}" line=""
  [ -n "${path}" ] || return 1
  if [ ! -e "${path}" ]; then
    [ "${repair}" = "1" ] || return 3
    return 0
  fi
  [ -r "${path}" ] || return 2
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "${line}" ] || continue
    if gat_is_token_shape "${line}"; then
      [ "${rotate}" = "1" ] || return 1
      return 0
    fi
  done <"${path}"
  [ "${repair}" = "1" ] || return 3
  return 0
}

# @function gat_write_token_file
# Write one token to one file the way the reader expects it: one line, mode 0600,
# created in the destination directory and moved into place so a reader never sees a
# half-written value. The value is validated before anything is created, so a rejected
# response leaves the previous credential untouched.
# Globals:
#   None
# Arguments:
#   $1 - destination path
#   $2 - the token to write
# Outputs:
#   The file at $1; nothing on stdout
# Returns:
#   0 on success, 1 when $2 is not token-shaped (nothing written), 3 when the
#   directory or the file could not be created
gat_write_token_file() {
  local path="${1:-}" token="${2:-}" dir="" tmp=""
  gat_is_token_shape "${token}" || return 1
  [ -n "${path}" ] || return 3
  dir="$(dirname "${path}")"
  [ -d "${dir}" ] || mkdir -p "${dir}" || return 3
  umask 077
  tmp="$(mktemp "${dir}/.grafana-query-token.XXXXXX" 2>/dev/null)" || return 3
  if ! printf '%s\n' "${token}" >"${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    return 3
  fi
  if ! chmod 0600 "${tmp}" 2>/dev/null || ! mv -f "${tmp}" "${path}" 2>/dev/null; then
    rm -f "${tmp}"
    return 3
  fi
  return 0
}

# @function gat_curl_config
# Write the one curl config file this CLI hands the container: Basic auth for the
# admin credential and the JSON content type. The credential is a config line, the
# same seam scripts/observability-query.sh:392 uses for the bearer token, because a
# -H or -u on the command line would put the admin password in the process listing of
# every host on this box. Quotes and backslashes in either half are escaped first, or
# a password carrying a double quote would end the string and start a new option.
# Globals:
#   None
# Arguments:
#   $1 - path to write (inside the scratch directory)
#   $2 - admin user
#   $3 - admin password
# Outputs:
#   The config file at $1, mode 0600
# Returns:
#   0 on success, 1 when either half is empty, 3 when the file cannot be written
gat_curl_config() {
  local path="${1:-}" user="${2:-}" pass="${3:-}"
  [ -n "${path}" ] || return 1
  [ -n "${user}" ] || return 1
  [ -n "${pass}" ] || return 1
  user="${user//\\/\\\\}"
  user="${user//\"/\\\"}"
  pass="${pass//\\/\\\\}"
  pass="${pass//\"/\\\"}"
  umask 077
  {
    printf 'silent\n'
    printf 'show-error\n'
    printf 'user = "%s:%s"\n' "${user}" "${pass}"
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "Accept: application/json"\n'
  } >"${path}" 2>/dev/null || return 3
  chmod 0600 "${path}" 2>/dev/null || return 3
  return 0
}

# @function gat_json_field
# Pull one top-level scalar out of one JSON body by key. This CLI reads exactly three
# fields from two responses (id, key, message), and each is a flat top-level string or
# integer, so a key-anchored extraction is enough and is honest about what it is. The
# key is validated before it reaches the pattern, so a caller cannot widen it into a
# regex.
# Globals:
#   None
# Arguments:
#   $1 - the body file
#   $2 - the field name, letters/digits/underscore only
# Outputs:
#   The value on stdout, with no trailing newline
# Returns:
#   0 with the value, 1 when the field is absent, the file is unreadable, or the
#   field name is not a word
gat_json_field() {
  local file="${1:-}" field="${2:-}" hit=""
  [[ ${field} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [ -r "${file}" ] || return 1
  hit="$(grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" "${file}" 2>/dev/null |
    head -n 1)" || true
  [ -n "${hit}" ] || return 1
  hit="${hit#*:}"
  hit="${hit#"${hit%%[![:space:]]*}"}"
  hit="${hit%\"}"
  hit="${hit#\"}"
  [ -n "${hit}" ] || return 1
  printf '%s' "${hit}"
  return 0
}

# @function gat_find_service_account_id
# Find the id of the one service account named NAME in a /api/serviceaccounts/search
# body. The search endpoint answers a page of matches rather than the exact account,
# so the name is matched inside a single flat object and its id read from that same
# object; scanning the whole body for "id" would happily return another account's.
# Globals:
#   None
# Arguments:
#   $1 - the body file
#   $2 - the service-account name (letters, digits, dash, underscore, dot)
# Outputs:
#   The id on stdout, with no trailing newline
# Returns:
#   0 with the id, 1 when no object in the page carries that exact name
gat_find_service_account_id() {
  local file="${1:-}" name="${2:-}" object=""
  [[ ${name} =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [ -r "${file}" ] || return 1
  while IFS= read -r object; do
    [[ ${object} == *"\"name\":\"${name}\""* ]] || continue
    gat_json_field <(printf '%s' "${object}") id
    return 0
  done < <(grep -oE '\{[^{}]*\}' "${file}" 2>/dev/null) || true
  return 1
}

# @function gat_token_name_owned
# Decide whether one service-account token name belongs to this CLI's naming scheme,
# which is the only set a run of this CLI may delete. The scheme is the token name it
# mints, ${ACCOUNT_NAME}-token, plus the -<n> suffixed shape a hand-renamed token of
# that name would still match: anything else on the account belongs to another tool
# that shares it and is left alone. The scheme is a caller-supplied literal, so it is
# validated as a plain name first and its dots are escaped before the match, or a
# name carrying a dot would match itself and everything that dot stands for.
# Globals:
#   None
# Arguments:
#   $1 - the token name from Grafana's answer
#   $2 - the naming scheme, normally ${ACCOUNT_NAME}-token
# Outputs:
#   None
# Returns:
#   0 when the name is one this CLI minted, 1 otherwise, including any scheme that
#   is not a plain name
gat_token_name_owned() {
  local name="${1:-}" scheme="${2:-}" pattern=""
  [ -n "${name}" ] || return 1
  [[ ${scheme} =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  pattern="${scheme//./\\.}"
  [[ ${name} == "${scheme}" ]] && return 0
  [[ ${name} =~ ^${pattern}-[0-9]+$ ]] && return 0
  return 1
}

# @function gat_list_token_ids
# List the token ids currently held by one service account, from a
# /api/serviceaccounts/{id}/tokens body, one id per line. With a naming scheme the
# list is narrowed to the tokens that scheme owns, and that is the list the mint
# revokes: every previous run of this CLI has to leave no live credential behind, so
# one rerun cannot stack a second one on top of it, while a token another tool minted
# against the same account survives a run of this one. Without a scheme every id is
# listed, which is what a report asks for.
# Globals:
#   None
# Arguments:
#   $1 - the body file
#   $2 - optional naming scheme to narrow the list to
# Outputs:
#   One id per line on stdout, nothing when nothing matches
# Returns:
#   0, always: an empty list is the answer to "what needs deleting"
gat_list_token_ids() {
  local file="${1:-}" scheme="${2:-}" object="" name="" id=""
  [ -r "${file}" ] || return 0
  while IFS= read -r object; do
    [[ ${object} == *'"tokenId"'* ]] || [[ ${object} == *'"id"'* ]] || continue
    if [ -n "${scheme}" ]; then
      name="$(gat_json_field <(printf '%s' "${object}") name 2>/dev/null)" || continue
      gat_token_name_owned "${name}" "${scheme}" || continue
    fi
    id="$(gat_json_field <(printf '%s' "${object}") tokenId 2>/dev/null || true)"
    [ -n "${id}" ] || id="$(gat_json_field <(printf '%s' "${object}") id 2>/dev/null || true)"
    [ -n "${id}" ] || continue
    printf '%s\n' "${id}"
  done < <(grep -oE '\{[^{}]*\}' "${file}" 2>/dev/null) || true
  return 0
}

# @function gat_redact
# Replace every occurrence of the token with GAT_REDACTION. Everything this CLI prints
# about a request - the HTTP code, curl's own complaint, and any message Grafana
# echoes back - passes through here before it reaches an operator, because the create
# response is the one body that holds the credential and a failing request is exactly
# the case where a transport quotes a body or a header back. The pattern is a bash
# glob, so the four characters a glob reads as syntax are escaped first; without that
# a token holding a * would silently stop matching itself.
# Globals:
#   GAT_TOKEN, GAT_REDACTION
# Arguments:
#   $1 - the text to scrub
# Outputs:
#   The scrubbed text on stdout, with no trailing newline
# Returns:
#   0, always
gat_redact() {
  local text="${1:-}" pattern="${GAT_TOKEN:-}"
  if [ -z "${pattern}" ]; then
    printf '%s' "${text}"
    return 0
  fi
  pattern="${pattern//\\/\\\\}"
  pattern="${pattern//\*/\\*}"
  pattern="${pattern//\?/\\?}"
  pattern="${pattern//\[/\\[}"
  printf '%s' "${text//${pattern}/${GAT_REDACTION}}"
  return 0
}
