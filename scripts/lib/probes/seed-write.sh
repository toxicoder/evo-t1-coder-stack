#!/bin/sh
# shellcheck shell=sh
#
# ## probes/seed-write.sh — write stdin to one path, making its parent directory when
# the file is absent (POSIX probe; run with sh, never sourced by the remote)

if [ ! -e "${1}" ]; then
  mkdir -p "$(dirname "${1}")" || exit 1
fi
cat >"${1}"
