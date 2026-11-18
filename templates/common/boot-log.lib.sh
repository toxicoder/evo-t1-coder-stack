# shellcheck shell=sh
# boot-log.lib.sh - the vocabulary every workspace boot body prints with.
#
# Sourced by coder_agent.startup_script and by each coder_script body, so the Coder
# workspace start log reads as one staged run: which stage the boot is in, what it is
# doing, and what it cost. The words are scripts/lib/common.sh's own ('== section ==',
# '-> phase', 'ok:', 'warning:', 'note:', 'error:', and a closing 'summary:'), each
# stage stamped with elapsed seconds. Bodies run under sh or bash, so this stays POSIX
# (no SECONDS, and no format operand that starts with '-'). Nothing here exits or
# writes a file: a body keeps its own failure policy.

# _boot_say <line> - the one print every verb goes through.
_boot_say() { printf '%s\n' "$*"; }

# _boot_t - seconds since boot_begin, 0 before it or without date(1).
_boot_t() {
  _boot_now="$(date +%s 2>/dev/null || printf '0')"
  printf '%s' "$((_boot_now - ${BOOT_T0:-${_boot_now}}))"
}

# boot_begin <name> [stages] - name this body, zero the counters, start the clock.
boot_begin() {
  BOOT_NAME="${1:-boot}"
  BOOT_STAGES="${2:-}"
  BOOT_T0="$(date +%s 2>/dev/null || printf '0')"
  BOOT_OK=0 BOOT_WARN=0 BOOT_FAIL=0
  _boot_say "== ${BOOT_NAME}: start =="
}

# boot_stage <i> <title> - open stage i of the run.
boot_stage() {
  _boot_say "== ${BOOT_NAME:-boot}: stage ${1:-?}/${BOOT_STAGES:-?}: ${2:-} == (+$(_boot_t)s)"
}

# boot_phase <text> - say what is happening before a step that can take seconds.
boot_phase() { _boot_say "-> ${1:-} (+$(_boot_t)s)"; }

# boot_ok <text> - count and print a completed item.
boot_ok() {
  BOOT_OK=$((${BOOT_OK:-0} + 1))
  _boot_say "ok: ${1:-}"
}

# boot_warn <text> - count and print a soft failure that did not stop the boot.
boot_warn() {
  BOOT_WARN=$((${BOOT_WARN:-0} + 1))
  _boot_say "warning: ${1:-}"
}

# boot_note <text> - commentary worth reading, with no counter.
boot_note() { _boot_say "note: ${1:-}"; }

# boot_err <text> - count and print a failure, on stderr so pipes stay clean.
boot_err() {
  BOOT_FAIL=$((${BOOT_FAIL:-0} + 1))
  printf 'error: %s\n' "${1:-}" >&2
}

# boot_summary - close the run with what it did and what it cost.
boot_summary() {
  _boot_say \
    "summary: ${BOOT_OK:-0} ok, ${BOOT_WARN:-0} warnings, ${BOOT_FAIL:-0} failed (+$(_boot_t)s, ${BOOT_NAME:-boot})"
}
