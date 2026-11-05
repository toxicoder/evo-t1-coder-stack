#!/usr/bin/env bash
#
# ## luks-unlock.sh — make an encrypted Ubuntu host answer SSH inside the initramfs.
#
# A headless server with a LUKS root stops on every reboot in the initramfs,
# waiting for a passphrase nobody is standing at the console to type. The
# distro answer is to move an SSH server and cryptsetup's own unlock prompt
# into the initramfs: cryptsetup-initramfs puts cryptroot-unlock in the boot
# image, dropbear-initramfs runs a key-only SSH daemon there, and
# initramfs-tools gives the NIC an address before the root is mapped. The
# pieces are three packages and about six config lines spread over four files.
#
# Those six lines are the problem. Each one fails the same way: the box comes
# back, nobody can reach it, and the only fix is a person at the machine. A
# DROPBEAR=y that the effective HOOKS list never runs, a key pasted with a
# wrapped line, a NIC whose driver MODULES=dep left out, an IP= nobody set, a
# host key directory the package filled only on the box that installed it -
# every one of them is invisible until the reboot that needs it. This CLI
# writes the config and then proves the generated initramfs actually contains
# the unlock path, which is the only claim worth making about a machine you
# cannot walk to.
#
# check is the default and writes nothing. It answers one question: if this
# box rebooted right now, could you unlock it from a laptop? install is the
# same list executed, and it ends with the same proof rather than a promise.
#
# What it will not do:
#   - Reboot anything. The reboot is the operator's call, made after the check.
#   - Touch /etc/crypttab, the LUKS headers, or any key slot. The volumes are
#     read to decide whether the boot can unlock them; they are never written.
#   - Enroll a TPM. systemd-cryptenroll is a different design with a different
#     failure mode (a firmware update that changes the PCR policy locks the box
#     with nobody in the loop), and neither belongs in this script.
#   - Open a port beyond the initramfs. dropbear lives only in the boot image
#     and is stopped by its own init-bottom script once the root is mounted.
#
# Usage (from any directory):
#   bazelisk run //scripts:luks-unlock                       # the report
#   bazelisk run //scripts:luks-unlock -- check              # the same, named
#   bazelisk run //scripts:luks-unlock -- install --pubkey ~/.ssh/id_ed25519.pub
#   bazelisk run //scripts:luks-unlock -- install --dry-run  # what would change
#   bazelisk run //scripts:luks-unlock -- fingerprint        # what ssh will offer
#
# Options:
#   --pubkey FILE       authorized_keys source for the unlock (install);
#                       default $LUKS_UNLOCK_PUBKEY_FILE, then the first of
#                       $HOME/.ssh/id_ed25519.pub, id_rsa.pub, id_ecdsa.pub
#   --port N            port for the initramfs SSH server (default 2222)
#   --ip MODE           dhcp (default), none, off, or a raw initramfs netboot
#                       spec such as :::::ens3:dhcp
#   --iface NAME        pin the interface the initramfs brings up
#   --idle SECONDS      dropbear idle timeout for one session (default 60)
#   --no-pkgs           skip apt-get install (packages already in place)
#   --no-regenerate     skip update-initramfs (regenerate by hand instead)
#   --dry-run           print every write and command; change nothing
#   -h, --help          print this help and exit 0
#
# Environment:
#   LUKS_ROOT                 sysroot to inspect and write (default /) - a test
#                             points it at a scratch tree, an operator can
#                             stage the same files onto a mounted disk
#   LUKS_UNLOCK_DRY_RUN=1     same as --dry-run
#   LUKS_UNLOCK_PUBKEY_FILE   the --pubkey default
#   LUKS_UNLOCK_HOST          the hostname the report names in its ssh hint
#   LUKS_UNLOCK_UNAME_R       override the kernel version being checked
#
# Exit codes: 0 when nothing blocks a remote unlock (warnings are allowed, and
# an initramfs that could not be inspected is a warning with its reason); 1
# when a blocker was found, an install step failed, or an argument was bad.

set -euo pipefail

# SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL and SUMMARY_FAIL_ITEMS are the counters
# scripts/lib/common.sh's ok, warn, fail_item and summary write and read; this
# file only zeroes them before a report.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/luks-unlock.sh disable=SC1091
source "${SELF_DIR}/lib/luks-unlock.sh"
# This CLI has no --json mode: a leftover JSON_MODE would route every report
# line to stderr and leave stdout empty.
unset JSON_MODE

VERB="check"
PUBKEY_FILE="${LUKS_UNLOCK_PUBKEY_FILE:-}"
UNLOCK_PORT="${LUKS_UNLOCK_DEFAULT_PORT}"
UNLOCK_IP_MODE="dhcp"
UNLOCK_IFACE=""
UNLOCK_IDLE="${LUKS_UNLOCK_DEFAULT_IDLE}"
DO_PKGS=1
DO_REGENERATE=1
LUKS_ROOT="${LUKS_ROOT:-/}"

if [ "${LUKS_UNLOCK_DRY_RUN:-}" = "1" ]; then
  DRY_RUN=1
else
  DRY_RUN=0
fi

# Kept for the sudo re-exec below: the option loop consumes "$@", and a
# re-exec that lost the verb would quietly run the default check as root.
ORIG_ARGS=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
    check | install | fingerprint)
      VERB="$1"
      ;;
    --pubkey)
      [ "$#" -ge 2 ] || die "luks-unlock: --pubkey needs a file"
      PUBKEY_FILE="$2"
      shift
      ;;
    --port)
      [ "$#" -ge 2 ] || die "luks-unlock: --port needs a number"
      UNLOCK_PORT="$2"
      shift
      ;;
    --ip)
      [ "$#" -ge 2 ] || die "luks-unlock: --ip needs a mode"
      UNLOCK_IP_MODE="$2"
      shift
      ;;
    --iface)
      [ "$#" -ge 2 ] || die "luks-unlock: --iface needs a name"
      UNLOCK_IFACE="$2"
      shift
      ;;
    --idle)
      [ "$#" -ge 2 ] || die "luks-unlock: --idle needs a number"
      UNLOCK_IDLE="$2"
      shift
      ;;
    --no-pkgs) DO_PKGS=0 ;;
    --no-regenerate) DO_REGENERATE=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      cat <<'HELP'
usage: bazelisk run //scripts:luks-unlock -- [verb] [options]

Configure an Ubuntu host with an encrypted root so a reboot can be answered
remotely: an SSH server inside the initramfs, and cryptsetup's unlock prompt
behind it.

  check        (default) write nothing and answer one question: if this box
               rebooted now, could you decrypt it from a laptop?
  install      install the packages, write the config, regenerate the
               initramfs, then run the same check over what was produced
  fingerprint  print the initramfs host key fingerprints to pin beforehand

  --pubkey FILE    public key(s) allowed to unlock (install)
  --port N         initramfs SSH port (default 2222; a different port from the
                   installed sshd keeps its host key from looking like an attack)
  --ip MODE        dhcp | none | off | a raw initramfs netboot spec
  --iface NAME     pin the interface the initramfs brings up
  --idle SECONDS   dropbear idle timeout (default 60)
  --no-pkgs        skip apt-get install
  --no-regenerate  skip update-initramfs
  --dry-run        print every write and command; change nothing
  -h, --help       this help

  Nothing here reboots the box, and nothing here edits /etc/crypttab or the
  LUKS headers. Run check, read the verdict, then reboot when it says so.
HELP
      exit 0
      ;;
    *)
      die "luks-unlock: unknown argument ${1} (try --help)"
      ;;
  esac
  shift
done

[[ ${UNLOCK_PORT} =~ ^[0-9]+$ ]] || die "luks-unlock: --port wants a number, got ${UNLOCK_PORT}"
[[ ${UNLOCK_IDLE} =~ ^[0-9]+$ ]] || die "luks-unlock: --idle wants a number, got ${UNLOCK_IDLE}"
[ "${UNLOCK_PORT}" -ge 1 ] && [ "${UNLOCK_PORT}" -le 65535 ] ||
  die "luks-unlock: --port ${UNLOCK_PORT} is outside 1-65535"

luks_unlock_paths "${LUKS_ROOT}"
IP_VALUE="$(luks_unlock_ip_value "${UNLOCK_IP_MODE}" "${UNLOCK_IFACE}")" ||
  die "luks-unlock: --ip ${UNLOCK_IP_MODE} is not dhcp, none, off, or a netboot spec (it needs the colons)"

# ── Execution helpers ─────────────────────────────────────────────────────────

# @function luks_unlock_run
# Run one privileged command through the house rules: sudo when the caller is
# not root, and nothing at all under --dry-run, where the command is printed
# instead. A privileged CLI that executes on the first run cannot be reviewed,
# and reviewing it is the point of running it.
# Globals:
#   DRY_RUN
# Arguments:
#   $@ - the command and its arguments
# Outputs:
#   The command's stdout and stderr, or "would: <command>" under --dry-run
# Returns:
#   The command's status, or 0 under --dry-run
luks_unlock_run() {
  if [ "${DRY_RUN}" = "1" ]; then
    log "would: $*"
    return 0
  fi
  if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

# @function luks_unlock_write
# Apply one key=value assignment through the dry-run rule, so every config
# change this CLI makes is either printed or executed by the same line of
# policy. Privilege is not this function's concern: an install run that needs
# it has already re-executed the whole script as root.
# Globals:
#   DRY_RUN
# Arguments:
#   $1 - file, $2 - key, $3 - value
# Outputs:
#   "would: set KEY=value in <file>" under --dry-run; a failed write is a
#   fail_item line, so a step that could not be written is counted and named
#   rather than only reflected in the exit code
# Returns:
#   0 when written or printed; 1 when the write failed
luks_unlock_write() {
  local file="${1:-}" key="${2:-}" value="${3:-}"
  if [ "${DRY_RUN}" = "1" ]; then
    log "would: set ${key}=${value} in ${file}"
    return 0
  fi
  if ! luks_unlock_conf_set "${file}" "${key}" "${value}"; then
    fail_item "could not set ${key} in ${file}"
    return 1
  fi
}

# @function luks_unlock_pick_pubkey
# Print the public key file to install, or nothing when no source was named.
# Globals:
#   HOME
# Arguments:
#   $1 - the --pubkey value, may be empty
# Outputs:
#   A readable file path on stdout, or nothing
# Returns:
#   0, always
luks_unlock_pick_pubkey() {
  local want="${1:-${LUKS_UNLOCK_PUBKEY_FILE:-}}" candidate
  if [ -n "${want}" ]; then
    [ -r "${want}" ] && printf '%s\n' "${want}"
    return 0
  fi
  for candidate in "${HOME:-/root}/.ssh/id_ed25519.pub" "${HOME:-/root}/.ssh/id_rsa.pub" \
    "${HOME:-/root}/.ssh/id_ecdsa.pub"; do
    if [ -r "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf '\n'
}

# ── Report ────────────────────────────────────────────────────────────────────

# @function luks_unlock_check_host
# Report the box-level preconditions: the distro this recipe is written for, a
# bootable initrd for the running kernel, and whether /boot is readable without
# a passphrase.
# Globals:
#   LUKS_OS_RELEASE, LUKS_BOOT_DIR, LUKS_UNLOCK_UNAME_R
# Arguments:
#   None
# Outputs:
#   One section of ok/warning/error lines
# Returns:
#   0
luks_unlock_check_host() {
  local distro="" id="" version="" kernel="" initrd="" source=""
  section "Host"
  distro="$(luks_unlock_os_name "${LUKS_OS_RELEASE}")"
  id="${distro% *}"
  version="${distro#* }"
  if luks_unlock_os_supported "${id}" "${version}"; then
    ok "distro ${distro}"
  else
    warn "distro ${distro} is not the one this recipe is written for (ubuntu 22.04 / 24.04): the file paths below are Ubuntu's"
  fi

  kernel="${LUKS_UNLOCK_UNAME_R:-$(uname -r 2>/dev/null || true)}"
  if [ -z "${kernel}" ]; then
    warn "no kernel version to check: set LUKS_UNLOCK_UNAME_R"
    return 0
  fi
  initrd="$(luks_unlock_initrd_for "${LUKS_BOOT_DIR}" "${kernel}")"
  if [ -n "${initrd}" ]; then
    ok "initrd for ${kernel}: ${initrd##*/}"
  else
    fail_item "no initrd for the running kernel ${kernel} in ${LUKS_BOOT_DIR}: nothing to verify and nothing to boot"
  fi

  if has_tool findmnt; then
    source="$(findmnt -no SOURCE --target "${LUKS_BOOT_DIR}" 2>/dev/null | head -n 1)"
    case "${source}" in
      /dev/mapper/*)
        warn "/boot sits on ${source}: an encrypted /boot needs GRUB to read the initrd before anyone can unlock it - verify that separately before a reboot"
        ;;
      "") ;;
      *) ok "/boot on ${source}, readable without a passphrase" ;;
    esac
  fi
}

# @function luks_unlock_check_volumes
# Report the volumes that have to be open before the root can mount, and
# whether each one can be opened by a passphrase typed over SSH.
# Globals:
#   LUKS_CRYPTTAB, LUKS_FSTAB, LUKS_CONF_HOOK
# Arguments:
#   None
# Outputs:
#   One section of ok/warning/error lines
# Returns:
#   0
luks_unlock_check_volumes() {
  local rows="" root_name="" pattern="" name="" device="" key="" options="" gap=""
  section "Volumes"
  rows="$(luks_unlock_crypttab_rows "${LUKS_CRYPTTAB}")"
  if [ -z "${rows}" ]; then
    fail_item "${LUKS_CRYPTTAB} names no encrypted volume: this box has no LUKS root to unlock"
    return 0
  fi
  root_name="$(luks_unlock_root_name "${LUKS_FSTAB}")"
  pattern="$(env_get "${LUKS_CONF_HOOK}" KEYFILE_PATTERN)"
  while IFS=$'\t' read -r name device key options; do
    [ -n "${name}" ] || continue
    gap="$(luks_unlock_key_gap "${key}" "${options}" "${pattern}")"
    if [ -n "${gap}" ]; then
      fail_item "${name}: ${gap}"
    elif [ "${name}" = "${root_name}" ]; then
      ok "${name} is the root volume and answers a passphrase prompt"
    else
      ok "${name} unlocks without a key file"
    fi
    case "${options}" in
      *keyscript=*)
        warn "${name}: options carry ${options##*keyscript=}: a keyscript runs instead of prompting, so this volume may never ask you"
        ;;
    esac
    if [ ! -e "${device}" ]; then
      warn "${name} device ${device} is absent right now: the initramfs will wait for a device that may never appear"
    elif [ "$(id -u)" = "0" ] && has_tool cryptsetup; then
      if cryptsetup isLuks "${device}" 2>/dev/null; then
        ok "${name} device ${device} is a LUKS volume"
      else
        warn "${name} device ${device} has no LUKS header: a plain dm-crypt volume needs its cipher and hash spelled out in crypttab"
      fi
    fi
  done <<<"${rows}"
  if [ -z "${root_name}" ]; then
    fail_item "${LUKS_FSTAB} mounts / from no /dev/mapper volume: the initramfs cannot tell which crypttab entry is the root"
  fi
}

# @function luks_unlock_check_initramfs
# Report the generator-side settings: the cryptsetup switch, the hook list that
# decides what actually gets packed, the driver policy, and the address the
# initramfs will have.
# Globals:
#   LUKS_CONF_HOOK, LUKS_INITRAMFS_CONF, LUKS_CONF_D_DIR, LUKS_CMDLINE,
#   LUKS_INITRAMFS_MODULES
# Arguments:
#   None
# Outputs:
#   One section of ok/warning/error lines
# Returns:
#   0
luks_unlock_check_initramfs() {
  local hooks="" missing="" state="" modules="" ifaces=""
  section "Initramfs"
  if [ -x "${LUKS_CRYPTROOT_UNLOCK}" ]; then
    ok "cryptsetup-initramfs is installed"
  else
    fail_item "no ${LUKS_CRYPTROOT_UNLOCK}: cryptsetup-initramfs is not installed, so nothing in the boot image will read a passphrase"
  fi

  if [ "$(env_get "${LUKS_CONF_HOOK}" CRYPTSETUP)" = "y" ]; then
    ok "cryptsetup ships its unlock scripts (CRYPTSETUP=y)"
  else
    fail_item "${LUKS_CONF_HOOK} has no CRYPTSETUP=y: cryptroot-unlock is not in the boot image and there is nothing to type a passphrase into"
  fi

  hooks="$(luks_unlock_hooks_effective "${LUKS_INITRAMFS_CONF}" "${LUKS_CONF_D_DIR}")"
  missing="$(luks_unlock_hooks_missing "${hooks}")"
  if [ -z "${hooks}" ]; then
    ok "no HOOKS restriction in effect: every installed hook is run"
  elif [ -z "${missing}" ]; then
    ok "HOOKS covers ${LUKS_UNLOCK_NEED_HOOKS}"
  else
    fail_item "HOOKS leaves out ${missing}: the generator will skip it and the boot will not be unlockable"
  fi

  modules="$(luks_unlock_modules_state "${LUKS_INITRAMFS_CONF}" "${LUKS_CONF_D_DIR}")"
  if [ "${modules}" = "dep" ]; then
    warn "MODULES=dep packs only drivers loaded right now: confirm the NIC driver is named in ${LUKS_INITRAMFS_MODULES}, or a fresh NIC comes up with no driver in the initramfs"
  else
    ok "MODULES=${modules}: driver coverage is wide enough for the NIC"
  fi

  state="$(luks_unlock_net_state "${LUKS_INITRAMFS_CONF}" "${LUKS_CONF_D_DIR}" "${LUKS_CMDLINE}")"
  case "${state}" in
    dhcp) ok "the initramfs takes an address over DHCP" ;;
    static) ok "the initramfs has a static netboot configuration" ;;
    cmdline) ok "the kernel cmdline carries ip= for the initramfs" ;;
    off | none)
      fail_item "no initramfs address (IP is unset, none, or off): dropbear has no interface to answer on and the box is unreachable by design"
      ;;
    *) warn "initramfs network state ${state} is not understood" ;;
  esac

  if [ -n "${UNLOCK_IFACE}" ]; then
    ifaces="$(luks_unlock_net_ifaces "${LUKS_NET_DIR}")"
    if [ -z "${ifaces}" ]; then
      note "${LUKS_NET_DIR} is not readable here, so the pinned interface ${UNLOCK_IFACE} was not confirmed"
    elif printf '%s\n' "${ifaces}" | grep -qxF -- "${UNLOCK_IFACE}"; then
      ok "the pinned interface ${UNLOCK_IFACE} exists"
    else
      fail_item "no interface ${UNLOCK_IFACE} in ${LUKS_NET_DIR}: the initramfs would be told to bring up a device the kernel never named"
    fi
  fi

  if [ "$(env_get "${LUKS_INITRAMFS_CONF}" UMASK)" != "0077" ]; then
    note "UMASK is not 0077: the initrd carries the unlock key and anyone who can read /boot can read it"
  fi
}

# @function luks_unlock_check_dropbear
# Report the SSH side: the hook that has to exist, the host keys the daemon
# refuses to start without, the keys that let anyone in, and the port.
# Globals:
#   LUKS_HOOKS_DIR, LUKS_DROPBEAR_DIR, LUKS_DROPBEAR_CONF, LUKS_SSHD_CONFIG
# Arguments:
#   None
# Outputs:
#   One section of ok/warning/error lines
# Returns:
#   0
luks_unlock_check_dropbear() {
  local hook="" files="" file="" report="" goods="" bads="" missing_keys="" port="" sshd_port=""
  section "Initramfs SSH"
  hook="${LUKS_HOOKS_DIR}/dropbear"
  if [ -r "${hook}" ]; then
    ok "dropbear-initramfs is installed"
  else
    fail_item "no ${hook}: dropbear-initramfs is not installed, so the boot image holds no SSH server"
  fi

  missing_keys="$(luks_unlock_host_keys_missing "${LUKS_DROPBEAR_DIR}")"
  if [ -z "${missing_keys}" ]; then
    ok "initramfs host keys are present"
  elif [ ! -d "${LUKS_DROPBEAR_DIR}" ]; then
    fail_item "no ${LUKS_DROPBEAR_DIR}: dropbear has no host key and will not start"
  else
    warn "initramfs host keys missing: ${missing_keys} (dropbear starts with any one of them)"
  fi

  files="$(luks_unlock_key_files "${hook}")"
  for file in ${files}; do
    report="$(luks_unlock_authorized_keys_report "${LUKS_ROOT}${file}")"
    if [ -z "${report}" ]; then
      fail_item "no usable key in ${file}: dropbear refuses to start without an authorized key"
      continue
    fi
    goods="$(printf '%s\n' "${report}" | grep -c '^ok' || true)"
    bads="$(printf '%s\n' "${report}" | grep -c '^bad' || true)"
    if [ "${goods}" -gt 0 ] && [ "${bads}" = "0" ]; then
      ok "${goods} authorized key(s) in ${file}"
    elif [ "${goods}" -gt 0 ]; then
      fail_item "${file} holds ${goods} usable key(s) and ${bads} broken line(s): fix the broken ones, a wrapped paste is the usual cause"
    else
      fail_item "${file}: $(printf '%s\n' "${report}" | head -n 1 | cut -f2-)"
    fi
  done

  port="$(luks_unlock_dropbear_port "${LUKS_DROPBEAR_CONF}")"
  sshd_port="$(sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' "${LUKS_SSHD_CONFIG}" 2>/dev/null | tail -n 1)"
  if [ -n "${sshd_port}" ] && [ "${port}" = "${sshd_port}" ]; then
    warn "the initramfs listens on ${port}, the same port the installed sshd uses: the host keys differ, and the client will report a changed identity on the connection you cannot afford to dismiss"
  else
    ok "the initramfs listens on port ${port}"
  fi
}

# @function luks_unlock_check_initrd
# Report the only evidence that counts: what the generated initramfs for the
# running kernel actually holds. Every setting above is an intent; this is the
# result.
# Globals:
#   LUKS_BOOT_DIR, LUKS_HOOKS_DIR
# Arguments:
#   None
# Outputs:
#   One section of ok/warning/error lines
# Returns:
#   0
luks_unlock_check_initrd() {
  local kernel="" initrd="" listing=""
  section "Generated initramfs"
  kernel="${LUKS_UNLOCK_UNAME_R:-$(uname -r 2>/dev/null || true)}"
  initrd="$(luks_unlock_initrd_for "${LUKS_BOOT_DIR}" "${kernel}")"
  if [ -z "${initrd}" ]; then
    warn "no initrd to inspect for ${kernel:-unknown}: run install to generate one"
    return 0
  fi
  if ! listing="$(luks_unlock_initrd_list "${initrd}")"; then
    warn "${initrd} could not be listed (no lsinitramfs or lsinitrd on PATH): the settings above are unverified"
    return 0
  fi
  if luks_unlock_initrd_has "${listing}" "bin/dropbear"; then
    ok "the boot image holds the SSH server"
  else
    fail_item "the boot image holds no bin/dropbear: the SSH server will not be there to answer"
  fi
  if luks_unlock_initrd_has "${listing}" "cryptroot-unlock"; then
    ok "the boot image holds cryptroot-unlock"
  else
    fail_item "the boot image holds no cryptroot-unlock: an SSH session would land in a shell with nothing to type the passphrase into"
  fi
  # The hook lands the operator's key under either name inside the image, so
  # either one proves a login is possible and neither proves the other.
  if luks_unlock_initrd_has "${listing}" "authorized_keys" ||
    luks_unlock_initrd_has "${listing}" "authorized_keys2"; then
    ok "an authorized key was packed into the boot image"
  else
    fail_item "no authorized key was packed into the boot image: the SSH server will refuse every login"
  fi
}

# @function luks_unlock_verdict
# Close the report with the answer the operator came for, and the two commands
# that turn the answer into an action.
# Globals:
#   SUMMARY_FAIL, UNLOCK_PORT
# Arguments:
#   $1 - the host to name in the ssh hint, optional
# Outputs:
#   The verdict lines and summary
# Returns:
#   0 when nothing blocks, 1 when something does
luks_unlock_verdict() {
  local host="${1:-<server>}"
  section "Verdict"
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    err "do not reboot yet - ${SUMMARY_FAIL:-0} blocker(s) above stand between you and a remote unlock"
    summary "bazelisk run //scripts:luks-unlock -- install --pubkey ~/.ssh/id_ed25519.pub"
    return 1
  fi
  ok "this box can be unlocked from a laptop after a reboot"
  log "  reach it with: $(luks_unlock_ssh_hint "${host}" "${UNLOCK_PORT}")"
  log "  then type:     cryptroot-unlock"
  summary
  return 0
}

# ── Verbs ─────────────────────────────────────────────────────────────────────

# @function luks_unlock_check
# Run every report in order and close with the verdict.
# Globals:
#   SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL
# Arguments:
#   None
# Outputs:
#   The whole report
# Returns:
#   0 when nothing blocks; 1 when a blocker was recorded
luks_unlock_check() {
  # Start the counters from nothing: install calls this after its own phases, and
  # a verdict that carried their counts forward would report work the report below
  # never did. common.sh reads each one as ${SUMMARY_*:-0}, so unset is the empty
  # state it was written for.
  unset SUMMARY_OK SUMMARY_WARN SUMMARY_FAIL SUMMARY_FAIL_ITEMS
  luks_unlock_check_host
  luks_unlock_check_volumes
  luks_unlock_check_initramfs
  luks_unlock_check_dropbear
  luks_unlock_check_initrd
  luks_unlock_verdict "${LUKS_UNLOCK_HOST:-<server>}"
}

# @function luks_unlock_install
# Write the config the check reads back. Package install, the cryptsetup
# switch, the generator drop-in, the SSH options, the operator's key, the host
# keys, then one regeneration - in that order, because the hook that packs the
# authorized key reads the file at generation time and a key written afterwards
# is not in the image.
# Globals:
#   DO_PKGS, DO_REGENERATE, DRY_RUN, PUBKEY_FILE, UNLOCK_PORT, UNLOCK_IDLE,
#   IP_VALUE, LUKS_CONF_HOOK, LUKS_CONF_D_FILE_PATH, LUKS_DROPBEAR_CONF,
#   LUKS_DROPBEAR_DIR, LUKS_INITRAMFS_CONF, LUKS_CONF_D_DIR, LUKS_HOOKS_DIR
# Arguments:
#   None
# Outputs:
#   The install phases, then the full check
# Returns:
#   0 when every step and the final check passed; 1 otherwise
luks_unlock_install() {
  local pubkey="" files="" file="" missing_keys="" name="" hooks="" merged=""
  local failed=0
  section "Install"

  if [ "${DO_PKGS}" = "1" ]; then
    phase "install the initramfs packages"
    if ! luks_unlock_run apt-get install -y cryptsetup-initramfs dropbear-initramfs; then
      fail_item "apt-get could not install cryptsetup-initramfs and dropbear-initramfs"
      failed=1
    fi
  else
    note "--no-pkgs: apt-get was skipped"
  fi

  phase "enable the cryptsetup unlock scripts"
  luks_unlock_write "${LUKS_CONF_HOOK}" CRYPTSETUP y || failed=1

  phase "configure the generator (dropbear, network, umask)"
  luks_unlock_write "${LUKS_CONF_D_FILE_PATH}" DROPBEAR y || failed=1
  luks_unlock_write "${LUKS_CONF_D_FILE_PATH}" IP "${IP_VALUE}" || failed=1
  luks_unlock_write "${LUKS_CONF_D_FILE_PATH}" UMASK 0077 || failed=1
  hooks="$(luks_unlock_hooks_effective "${LUKS_INITRAMFS_CONF}" "${LUKS_CONF_D_DIR}")"
  if [ -n "${hooks}" ]; then
    merged="${hooks}"
    for name in ${LUKS_UNLOCK_NEED_HOOKS}; do
      case " ${merged} " in
        *" ${name} "*) ;;
        *) merged="${merged} ${name}" ;;
      esac
    done
    if [ "${merged}" != "${hooks}" ]; then
      luks_unlock_write "${LUKS_CONF_D_FILE_PATH}" HOOKS "${merged}" || failed=1
    fi
  fi

  phase "set the initramfs SSH options"
  if [ ! -s "${LUKS_DROPBEAR_CONF}" ] || [ -z "$(env_get "${LUKS_DROPBEAR_CONF}" DROPBEAR_OPTIONS)" ]; then
    luks_unlock_write "${LUKS_DROPBEAR_CONF}" DROPBEAR_OPTIONS \
      "$(luks_unlock_dropbear_options "${UNLOCK_PORT}" "${UNLOCK_IDLE}")" || failed=1
  else
    note "${LUKS_DROPBEAR_CONF} already sets DROPBEAR_OPTIONS; it was left as the operator wrote it"
  fi

  phase "install the unlock key"
  pubkey="$(luks_unlock_pick_pubkey "${PUBKEY_FILE}")"
  if [ -z "${pubkey}" ]; then
    fail_item "no public key to install - pass --pubkey FILE or set LUKS_UNLOCK_PUBKEY_FILE"
    failed=1
  elif ! cat "${pubkey}" | grep -q .; then
    fail_item "${pubkey} is empty; there is nothing to authorize"
    failed=1
  else
    files="$(luks_unlock_key_files "${LUKS_HOOKS_DIR}/dropbear")"
    for file in ${files}; do
      phase "authorize ${pubkey##*/} in ${file}"
      if ! luks_unlock_privileged_cp "${pubkey}" "${LUKS_ROOT}${file}"; then
        fail_item "could not install the authorized key at ${file}"
        failed=1
      fi
    done
  fi

  phase "create the initramfs host keys"
  missing_keys="$(luks_unlock_host_keys_missing "${LUKS_DROPBEAR_DIR}")"
  for name in ${missing_keys}; do
    case "${name}" in
      *_ed25519_*) luks_unlock_run dropbearkey -t ed25519 -f "${LUKS_DROPBEAR_DIR}/${name}" || failed=1 ;;
      *_ecdsa_*) luks_unlock_run dropbearkey -t ecdsa -f "${LUKS_DROPBEAR_DIR}/${name}" || failed=1 ;;
      *) luks_unlock_run dropbearkey -t rsa -f "${LUKS_DROPBEAR_DIR}/${name}" || failed=1 ;;
    esac
  done

  if [ "${DO_REGENERATE}" = "1" ]; then
    phase "regenerate the initramfs for every kernel"
    luks_unlock_run update-initramfs -u -k all || failed=1
  else
    note "--no-regenerate: the boot image was not rebuilt, so the checks below describe the OLD image"
  fi

  if [ "${failed}" = "1" ]; then
    summary
    return 1
  fi
  luks_unlock_check
}

# @function luks_unlock_privileged_cp
# Copy one file into place with the mode it must have. Split out of the install
# flow so the key placement stays one auditable step rather than an inline
# pipeline; privilege is settled once, by the re-exec at the bottom of this
# file.
# Globals:
#   DRY_RUN
# Arguments:
#   $1 - source path
#   $2 - destination path
# Outputs:
#   "would: install <src> -> <dest> (mode 0600)" under --dry-run; otherwise the
#   destination, plus a <dest>.bak copy of whatever it replaced
# Returns:
#   0 when the destination holds the source; 1 otherwise
luks_unlock_privileged_cp() {
  local src="${1:-}" dest="${2:-}"
  [ -r "${src}" ] || return 1
  [ -s "${src}" ] || return 1
  if [ "${DRY_RUN}" = "1" ]; then
    log "would: install ${src} -> ${dest} (mode 0600)"
    return 0
  fi
  luks_unlock_authorized_keys_install "${src}" "${dest}"
}

# @function luks_unlock_fingerprint_cmd
# Print what the initramfs SSH daemon will offer as its identity, so the
# operator can pin it before the reboot and tell it apart from the installed
# sshd afterwards.
# Globals:
#   LUKS_DROPBEAR_DIR, UNLOCK_PORT
# Arguments:
#   None
# Outputs:
#   One fingerprint line per host key, or a note naming why there are none
# Returns:
#   0 always: an absent key is a report, and check is the verb that fails on it
luks_unlock_fingerprint_cmd() {
  local name="" printed=0
  section "Initramfs host keys"
  for name in ${LUKS_UNLOCK_HOST_KEYS}; do
    if luks_unlock_fingerprint "${LUKS_DROPBEAR_DIR}/${name}"; then
      printed=1
    fi
  done
  if [ "${printed}" = "0" ]; then
    note "no host key to fingerprint in ${LUKS_DROPBEAR_DIR} yet: install creates them, and pin one before you reboot"
  fi
  log "  expect them on port ${UNLOCK_PORT}: $(luks_unlock_ssh_hint "<server>" "${UNLOCK_PORT}")"
  return 0
}

# ── Entry ─────────────────────────────────────────────────────────────────────

# A mutating run needs root. Escalating the whole process once keeps every
# writer in this script free of sudo policy of its own, and the marker stops a
# sudo that does not preserve the environment from looping.
if [ "${VERB}" = "install" ] && [ "${DRY_RUN}" != "1" ] && [ "${LUKS_ROOT}" = "/" ] &&
  [ "$(id -u)" != "0" ]; then
  if [ -n "${LUKS_UNLOCK_ESCALATED:-}" ]; then
    die "luks-unlock: install still is not root after sudo; run it as root"
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    die "luks-unlock: install needs root and sudo is not on PATH"
  fi
  log "install writes /etc and regenerates the boot image; re-running under sudo"
  export LUKS_UNLOCK_ESCALATED=1
  exec sudo -E "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
fi

case "${VERB}" in
  check) luks_unlock_check ;;
  install) luks_unlock_install ;;
  fingerprint) luks_unlock_fingerprint_cmd ;;
esac
