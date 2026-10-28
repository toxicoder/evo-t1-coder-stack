#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## run.sh -- run every language lane present in this checkout (fixture twin)
#
# The canned scaffold's dispatcher. It discovers lanes by the artifact each lane
# leaves behind, so a render that carried only one lane runs only that lane. The
# stack's suite drives this through `--lanes` to prove the renderer overlaid
# exactly what the operator asked for.
#
#   lane      what turns it on                     runner
#   shell     tests/**/*.bats                      the lane's bats suite
#   python    pytest.ini or tests/python/          the lane's pytest suite
#
# No shell function is defined in this file, and no function docstring block
# appears in it: the stack's shell-function inventory reads this tree, and a
# fixture is not production shell.
#
# Usage:
#   run.sh                  run every lane present
#   run.sh --lane shell     run one lane only (error when it is absent)
#   run.sh --list           print the plan, run nothing
#   run.sh --lanes          print one present lane id per line, exit 0 always
#
# Returns: 0 when every selected lane passed or --lanes/--list was asked for;
# 1 when a lane failed or nothing was discovered.

set -euo pipefail

# Lane discovery is rooted at the checkout, never at the caller's cwd, so the
# dispatcher answers the same question from any directory.
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${ROOT_DIR}"

readonly KNOWN_LANES=(shell python)

mode="run"
selected=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lanes) mode="lanes" ;;
    --list) mode="list" ;;
    --lane)
      [ "$#" -ge 2 ] || {
        printf 'error: --lane needs an id (%s)\n' "${KNOWN_LANES[*]}" >&2
        exit 1
      }
      selected="$2"
      shift
      ;;
    --lane=*) selected="${1#*=}" ;;
    -h | --help)
      printf 'usage: run.sh [--lanes] [--list] [--lane <id>]\n'
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s (try --help)\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

# Discovery, written inline for the same reason there are no functions here. A
# lane turns itself on by the artifact it leaves in the tree, so the question is
# asked once per lane and answered by the filesystem, not by a flag.
LANE_PLAN=()
if [ -n "$(find tests -type f -name '*.bats' -print -quit 2>/dev/null)" ]; then
  LANE_PLAN+=(shell)
fi
if [ -f pytest.ini ] || [ -d tests/python ]; then
  LANE_PLAN+=(python)
fi

if [ "${mode}" = "lanes" ]; then
  # The machine-readable form, and it never fails, not even on an empty tree:
  # `make doctor` calls it to learn which pins this checkout may demand, and no
  # lane is a legitimate answer there in a way it is not in the run path.
  for lane in "${LANE_PLAN[@]}"; do
    printf '%s\n' "${lane}"
  done
  exit 0
fi

if [ "${mode}" = "list" ]; then
  for lane in "${LANE_PLAN[@]}"; do
    printf -- '-> lane: %s (planned, not executed)\n' "${lane}"
  done
  [ "${#LANE_PLAN[@]}" -gt 0 ] || printf 'none\n'
  exit 0
fi

if [ -n "${selected}" ]; then
  chosen=0
  for lane in "${LANE_PLAN[@]}"; do
    [ "${lane}" = "${selected}" ] && chosen=1
  done
  if [ "${chosen}" -eq 0 ]; then
    known=0
    for lane in "${KNOWN_LANES[@]}"; do
      [ "${lane}" = "${selected}" ] && known=1
    done
    if [ "${known}" -eq 0 ]; then
      printf 'error: unknown lane %s; known lanes are: %s\n' \
        "${selected}" "${KNOWN_LANES[*]}" >&2
    else
      printf 'error: lane %s is not present in this checkout\n' "${selected}" >&2
    fi
    exit 1
  fi
  LANE_PLAN=("${selected}")
fi

if [ "${#LANE_PLAN[@]}" -eq 0 ]; then
  printf 'error: no test lane found; render a lane\n' >&2
  exit 1
fi

for lane in "${LANE_PLAN[@]}"; do
  printf 'ok: lane %s passed (fixture)\n' "${lane}"
done
