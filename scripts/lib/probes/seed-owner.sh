#!/bin/sh
# shellcheck shell=sh
#
# ## probes/seed-owner.sh — answer who owns one config file inside a container: absent,
# unreadable, managed (it carries a stack marker) or user (POSIX probe; run with sh, never sourced by the remote)
#
# Args: $1 the path, $2 the comment marker, $3 the JSON key marker, and $4 the
# TOML key marker, optional. The marker list is whatever the caller hands over
# and never a default baked in here, so one probe answers for the JSON payloads
# and for ~/.grok/config.toml alike; a three-arg call still asks exactly two
# questions, which is what the callers that predate the TOML key do.

if [ ! -e "${1}" ]; then
  printf "absent"
  exit 0
fi
if [ ! -r "${1}" ]; then
  printf "unreadable"
  exit 0
fi
# The 4th marker is grepped separately because an empty -e "" matches anything:
# a caller that passes no TOML key must not get "managed" for every file.
if grep -qF -e "${2}" -e "${3}" "${1}" 2>/dev/null ||
  { [ -n "${4:-}" ] && grep -qF -e "${4}" "${1}" 2>/dev/null; }; then
  printf "managed"
  exit 0
fi
printf "user"
