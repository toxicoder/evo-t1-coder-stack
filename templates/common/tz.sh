#!/bin/sh
# shellcheck shell=sh
#
# ## tz.sh - Answer one IANA zone name for the host this runs on (POSIX probe;
# run with sh, never sourced by the remote)
#
# The golden image carries one default zone and the stack host lives in another, so a
# container that inherits nothing prints a time its host does not. The boot body in
# templates/*/startup.sh.tftpl ferries this file in through the templatefile key
# main.tf calls tz_probe, writes it to a temp path, runs it here, and applies what it
# answers to /etc/timezone and /etc/localtime.
#
# Resolution order, first answer wins:
#   1. TZ in the environment - the workspace agent env injects the host's zone, and an
#      injected value outranks anything the container itself carries;
#   2. the timezone file - one zone name per Debian-derived image;
#   3. the localtime symlink - its leaf under zoneinfo/ is the zone name.
# The documented fallback is Etc/UTC, printed with exit 1: it is the image's own
# default, so a caller that treats the fallback as "no zone found" can tell it apart
# from a zone it actually resolved.
#
# A candidate has to look like a zone name to be taken: one or more
# [A-Za-z0-9_+-] segments separated by single slashes, no leading slash, no dot
# component. That rejects the three things these sources really do carry - a POSIX
# rule string (TZ="EST5EDT"), an absolute path (TZ=/usr/share/zoneinfo/Etc/UTC), and
# junk read out of a hand-edited /etc/timezone. When the zoneinfo tree is present the
# candidate must also name a readable file inside it, which is what rejects a rule
# string that happens to look like a name (TZ="UTC+8" on an image that ships tzdata).
#
# Arguments:
#   $1 - zoneinfo tree   (default /usr/share/zoneinfo)
#   $2 - timezone file   (default /etc/timezone)
#   $3 - localtime link  (default /etc/localtime)
# Outputs:
#   One zone name on stdout, nothing else
# Returns:
#   0 when a source answered, 1 when the Etc/UTC fallback answered

TZ_FALLBACK="Etc/UTC"

# @function tz_candidate_ok
# Decide whether one string is usable as an IANA zone name, given the zoneinfo tree
# this host has. Shape always has to hold; the file check runs only when the tree is
# there to check against, so a tzdata-less image still answers on shape.
# Globals:
#   TZ_ZONEINFO - the zoneinfo tree the caller resolved to
# Arguments:
#   $1 - candidate zone name
# Outputs:
#   Nothing
# Returns:
#   0 when the candidate is usable, 1 when it is not
tz_candidate_ok() {
  candidate="${1:-}"
  if [ -z "${candidate}" ]; then
    return 1
  fi
  case "${candidate}" in
    /*) return 1 ;;
    *[/]*) : ;;
    *) return 1 ;;
  esac
  if ! printf '%s' "${candidate}" | grep -qE '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$'; then
    return 1
  fi
  if [ -d "${TZ_ZONEINFO}" ] && [ ! -f "${TZ_ZONEINFO}/${candidate}" ]; then
    return 1
  fi
  return 0
}

# @function tz_from_localtime
# Read the zone name out of the localtime symlink. A copied file rather than a link
# carries no name, so the leaf is taken only from a link whose target names zoneinfo/.
# Globals:
#   TZ_LOCALTIME - the localtime path the caller resolved to
# Arguments:
#   None
# Outputs:
#   The zone name on stdout when the link named one
# Returns:
#   0 when a name was printed, 1 when the path named none
tz_from_localtime() {
  link=""
  if command -v readlink >/dev/null 2>&1; then
    link="$(readlink "${TZ_LOCALTIME}" 2>/dev/null || true)"
  fi
  if [ -z "${link}" ]; then
    return 1
  fi
  case "${link}" in
    *zoneinfo/*)
      printf '%s\n' "${link##*zoneinfo/}"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# @function tz_resolve
# Walk the three sources in order and print the first zone name that holds.
# Globals:
#   TZ - the injected zone, source 1
#   TZ_ZONEINFO, TZ_TIMEZONE, TZ_LOCALTIME - the paths the three sources read
#   TZ_FALLBACK - the answer when no source holds
# Arguments:
#   None
# Outputs:
#   One zone name on stdout
# Returns:
#   0 when a source answered, 1 when TZ_FALLBACK answered
tz_resolve() {
  candidate="$(printf '%s' "${TZ:-}" | tr -d ' \t\r\n')"
  if [ -n "${candidate}" ] && tz_candidate_ok "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  if [ -f "${TZ_TIMEZONE}" ]; then
    candidate="$(tr -d ' \t\r\n' <"${TZ_TIMEZONE}" 2>/dev/null || true)"
    if [ -n "${candidate}" ] && tz_candidate_ok "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  if candidate="$(tz_from_localtime)" && [ -n "${candidate}" ] &&
    tz_candidate_ok "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  printf '%s\n' "${TZ_FALLBACK}"
  return 1
}

TZ_ZONEINFO="${1:-/usr/share/zoneinfo}"
TZ_TIMEZONE="${2:-/etc/timezone}"
TZ_LOCALTIME="${3:-/etc/localtime}"

tz_resolve
