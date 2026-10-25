#!/bin/sh
# shellcheck shell=sh
#
# ## probes/seed-owner.sh — answer who owns one config file inside a container: absent,
# unreadable, managed (it carries a stack marker) or user (POSIX probe; run with sh, never sourced by the remote)

if [ ! -e "${1}" ]; then
  printf "absent"
  exit 0
fi
if [ ! -r "${1}" ]; then
  printf "unreadable"
  exit 0
fi
if grep -qF -e "${2}" -e "${3}" "${1}" 2>/dev/null; then
  printf "managed"
  exit 0
fi
printf "user"
