#!/bin/sh
# shellcheck shell=sh
#
# ## probes/seed-rm-managed.sh — delete one config file only while it still carries a
# stack marker, and prune the directory it left once that holds nothing else
# (POSIX probe; run with sh, never sourced by the remote)
#
# Args: $1 the path, $2.. the marker spellings, optional. The marker list is
# whatever the caller hands over and never a default baked in here, matching
# probes/seed-owner.sh. A file with no marker is user-owned, so this probe
# leaves it standing; an absent path is not an error.

path="${1:-}"
if [ -z "${path}" ] || [ ! -f "${path}" ]; then
  exit 0
fi
shift

found=0
# Each marker is grepped on its own because an empty -e "" matches anything: a
# caller that passes no TOML key must not have every file read as stack-owned.
for marker in "$@"; do
  if [ -n "${marker}" ] && grep -qF -e "${marker}" -- "${path}" 2>/dev/null; then
    found=1
    break
  fi
done
if [ "${found}" -eq 0 ]; then
  exit 0
fi

dir=${path%/*}
rm -f -- "${path}" || exit 1
if [ "${dir}" != "${path}" ] && [ -d "${dir}" ]; then
  rmdir "${dir}" 2>/dev/null
fi
exit 0
