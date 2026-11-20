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

# boot_ensure_dir <path> - make <path> exist and be writable by this boot's user, and
# say so when it cannot.
#
# Why a body has to ask for this itself: the workspace home carries the per-owner Grok
# volumes as bind mounts at ~/.grok/notes, /memory and /sessions, and the Docker daemon
# creates a bind mount's target path as root, so ~/.grok arrives root-owned on every
# boot where those mount points are new. The startup script does repair that ownership,
# and nothing orders it before this body: on Coder v2.36 the start scripts fan out in
# one concurrent errgroup, startup script included, so a seed that writes under $HOME
# can reach a directory it cannot write. mkdir alone then fails quietly and the body
# goes on printing ok: about a file that never landed. So each body makes the directory
# it is about to write into its own precondition: create it, and take back the ownership
# of every component of it that exists and is not ours to write. $HOME itself is left
# alone - a home this boot cannot write is past what a seed can repair. Prints error: and
# returns 1 when the directory still cannot be written, which is what lets the caller
# refuse to claim a file it did not land.
boot_ensure_dir() {
  _bed_target="${1:-}"
  if [ -z "${_bed_target}" ]; then
    boot_err "boot_ensure_dir: called with no path"
    return 1
  fi

  _bed_home="${HOME:-}"
  if [ -z "${_bed_home}" ]; then
    boot_err "boot_ensure_dir: no HOME, so ${_bed_target} has no owner to restore"
    return 1
  fi

  # The owner a repair restores: the home's own, which is the workspace user. The two
  # fallbacks are the startup script's, kept identical so the two bodies that chown under
  # $HOME cannot disagree about who the workspace user is.
  _bed_owner="$(stat -Lc '%u:%g' "${_bed_home}" 2>/dev/null || printf '')"
  if [ "${_bed_owner}" = "0:0" ]; then
    _bed_owner=""
  fi
  if [ -z "${_bed_owner}" ] && id coder >/dev/null 2>&1; then
    _bed_owner="$(id -u coder):$(id -g coder)"
  fi
  if [ -z "${_bed_owner}" ]; then
    _bed_owner="$(id -u):$(id -g)"
  fi

  _bed_sudo=""
  if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    _bed_sudo="sudo"
  fi

  # Walk the target's own components from the home down, not recursively: the component
  # the daemon created as root is the one mkdir cannot enter, and a recursive chown would
  # reach into the mounted volumes beside it.
  _bed_rel="${_bed_target#"${_bed_home%/}/"}"
  if [ "${_bed_rel}" != "${_bed_target}" ]; then
    _bed_walk="${_bed_home%/}"
    while [ -n "${_bed_rel}" ]; do
      _bed_name="${_bed_rel%%/*}"
      if [ "${_bed_rel}" = "${_bed_name}" ]; then
        _bed_rel=""
      else
        _bed_rel="${_bed_rel#*/}"
      fi
      _bed_walk="${_bed_walk}/${_bed_name}"
      if [ -e "${_bed_walk}" ] && [ ! -w "${_bed_walk}" ]; then
        # shellcheck disable=SC2086  # an empty $_bed_sudo has to vanish, not be one argument
        ${_bed_sudo} chown "${_bed_owner}" "${_bed_walk}" 2>/dev/null || true
      fi
    done
  fi

  mkdir -p "${_bed_target}" 2>/dev/null || true
  if [ ! -d "${_bed_target}" ] || [ ! -w "${_bed_target}" ]; then
    boot_err "${_bed_target} is not writable by this boot; whatever it should hold is missing"
    return 1
  fi
  return 0
}
