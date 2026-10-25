#!/bin/sh
# shellcheck shell=sh
#
# ## probes/seed-rm-mtime.sh — delete the files under each root given that are older
# than N days (POSIX probe; run with sh, never sourced by the remote)

days="${1}"
shift
for root in "${@}"; do
  if [ -d "${root}" ]; then
    find "${root}" -type f -mtime +"${days}" -exec rm -f {} +
  fi
done
