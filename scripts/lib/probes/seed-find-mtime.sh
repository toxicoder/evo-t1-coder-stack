#!/bin/sh
# shellcheck shell=sh
#
# ## probes/seed-find-mtime.sh — list the files under each root given that are older
# than N days, one path per line (POSIX probe; run with sh, never sourced by the remote)

days="${1}"
shift
for root in "${@}"; do
  if [ -d "${root}" ]; then
    find "${root}" -type f -mtime +"${days}" -print
  fi
done
