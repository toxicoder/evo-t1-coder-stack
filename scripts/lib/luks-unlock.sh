# shellcheck shell=bash
# shellcheck disable=SC2034 # LUKS_* paths are the output-variable contract for the
# scripts that source this file: luks_unlock_paths writes them for the caller to read,
# which is why no line in this file appears to consume them.
#
# ## luks-unlock.sh — the read/write helpers behind scripts/luks-unlock.sh
# (sourced; never executed)
#
# A headless Ubuntu server with a LUKS root has one dangerous moment: every
# reboot stops in the initramfs waiting for a passphrase that nobody is
# standing at the console to type. The distro answer is to put an SSH server
# and cryptsetup's own unlock prompt inside the initramfs, which is a handful
# of config files spread over three packages (cryptsetup-initramfs,
# dropbear-initramfs, initramfs-tools). Getting one line wrong is not a
# warning you read at boot - it is a box that comes back unreachable and
# stays down until someone is physically at it.
#
# So this library is only the provable half of that setup: every function
# reads a file or runs one named tool and answers one question, and none of
# them decides policy. scripts/luks-unlock.sh owns the verdict.
#
# Invariants:
#   - Sourcing this file changes no shell options and touches nothing; it
#     sources common.sh first when that has not been sourced yet, so it never
#     depends on the entry script's source order.
#   - Every path is derived from a sysroot prefix (LUKS_ROOT, default /). A
#     test points the whole library at a scratch tree, and an operator can
#     stage the same files onto a mounted disk image. Nothing here reads an
#     absolute path that the caller cannot redirect.
#   - A tool that is not on PATH answers "did not answer" (empty stdout,
#     non-zero return) rather than crashing the caller: a check that could not
#     run has to stay distinguishable from a check that ran and disagreed.
#
# Usage (from an entry script, after `set -euo pipefail`):
#   # shellcheck source=lib/luks-unlock.sh disable=SC1091
#   source "scripts/lib/luks-unlock.sh"   # sources scripts/lib/common.sh when needed

if ! declare -f has_tool >/dev/null 2>&1; then
  # shellcheck source=lib/common.sh disable=SC1091
  source "${BASH_SOURCE[0]%/*}/common.sh"
fi

# ── Constants ─────────────────────────────────────────────────────────────────

# LUKS_UNLOCK_DEFAULT_PORT — the port the initramfs SSH server listens on.
# Deliberately not 22: the initramfs host keys are not the installed sshd's,
# so sharing the port makes an ssh client report "REMOTE HOST IDENTIFICATION
# HAS CHANGED" on the one connection you cannot afford to dismiss.
LUKS_UNLOCK_DEFAULT_PORT="${LUKS_UNLOCK_DEFAULT_PORT:-2222}"

# LUKS_UNLOCK_DEFAULT_IDLE — dropbear's -I idle timeout in seconds. A session
# left open by someone who walked away keeps no lock on the boot; a dead
# client that never times out does.
LUKS_UNLOCK_DEFAULT_IDLE="${LUKS_UNLOCK_DEFAULT_IDLE:-60}"

# LUKS_UNLOCK_CONF_D_FILE — the basename this CLI owns under
# /etc/initramfs-tools/conf.d/. initramfs-tools sources initramfs.conf first
# and conf.d/* after it in sort order, so a name that sorts last wins over
# every other drop-in, and one file means one thing to inspect and one thing
# to delete.
LUKS_UNLOCK_CONF_D_FILE="${LUKS_UNLOCK_CONF_D_FILE:-zz-luks-unlock}"

# LUKS_UNLOCK_HOST_KEYS — the host key file names the initramfs dropbear needs.
# The package creates these on install; a box that has none gets a dropbear
# that fails to start, which is the silent version of unreachable.
LUKS_UNLOCK_HOST_KEYS="dropbear_ed25519_host_key dropbear_ecdsa_host_key dropbear_rsa_host_key"

# LUKS_UNLOCK_FALLBACK_KEY_FILES — the two authorized_keys locations in the
# wild. Ubuntu's dropbear-initramfs reads /etc/dropbear/initramfs/ and Debian's
# reads /etc/dropbear-initramfs/, so which one the installed hook honours is a
# fact about the hook, not a constant. luks_unlock_key_files derives it from
# the hook and falls back to both.
LUKS_UNLOCK_FALLBACK_KEY_FILES="/etc/dropbear/initramfs/authorized_keys /etc/dropbear-initramfs/authorized_keys"

# LUKS_UNLOCK_NEED_HOOKS — the initramfs hooks that have to be in the effective
# HOOKS list for an unlockable boot: cryptroot maps the root, cryptroot-unlock
# is the command the operator types, net brings the NIC up, dropbear answers.
LUKS_UNLOCK_NEED_HOOKS="cryptroot cryptroot-unlock net dropbear"

# ── Paths ─────────────────────────────────────────────────────────────────────

# @function luks_unlock_paths
# Set every path this CLI reads or writes, rooted at a sysroot prefix.
# Globals:
#   LUKS_ROOT (in, default "/"); LUKS_CRYPTTAB, LUKS_FSTAB, LUKS_CONF_HOOK,
#   LUKS_INITRAMFS_CONF, LUKS_INITRAMFS_MODULES, LUKS_CONF_D_DIR,
#   LUKS_CONF_D_FILE_PATH, LUKS_DROPBEAR_DIR, LUKS_DROPBEAR_CONF,
#   LUKS_HOOKS_DIR, LUKS_CRYPTROOT_UNLOCK, LUKS_BOOT_DIR, LUKS_CMDLINE,
#   LUKS_NET_DIR, LUKS_OS_RELEASE, LUKS_SSHD_CONFIG (out)
# Arguments:
#   $1 - sysroot prefix, optional (default ${LUKS_ROOT:-/})
# Outputs:
#   Nothing; assigns the globals listed above
# Returns:
#   0
luks_unlock_paths() {
  local root="${1:-${LUKS_ROOT:-/}}"
  root="${root%/}"
  LUKS_ROOT="${root}"
  LUKS_CRYPTTAB="${root}/etc/crypttab"
  LUKS_FSTAB="${root}/etc/fstab"
  LUKS_CONF_HOOK="${root}/etc/cryptsetup-initramfs/conf-hook"
  LUKS_INITRAMFS_CONF="${root}/etc/initramfs-tools/initramfs.conf"
  LUKS_INITRAMFS_MODULES="${root}/etc/initramfs-tools/modules"
  LUKS_CONF_D_DIR="${root}/etc/initramfs-tools/conf.d"
  LUKS_CONF_D_FILE_PATH="${LUKS_CONF_D_DIR}/${LUKS_UNLOCK_CONF_D_FILE}"
  LUKS_DROPBEAR_DIR="${root}/etc/dropbear/initramfs"
  LUKS_DROPBEAR_CONF="${LUKS_DROPBEAR_DIR}/dropbear.conf"
  LUKS_HOOKS_DIR="${root}/usr/share/initramfs-tools/hooks"
  LUKS_CRYPTROOT_UNLOCK="${root}/usr/share/cryptsetup/initramfs/bin/cryptroot-unlock"
  LUKS_BOOT_DIR="${root}/boot"
  LUKS_CMDLINE="${root}/proc/cmdline"
  LUKS_NET_DIR="${root}/sys/class/net"
  LUKS_OS_RELEASE="${root}/etc/os-release"
  LUKS_SSHD_CONFIG="${root}/etc/ssh/sshd_config"
}

# ── Host identity ─────────────────────────────────────────────────────────────

# @function luks_unlock_os_name
# Print the distro id and version from os-release, or UNKNOWN when the file is
# absent. The recipe this CLI writes is Ubuntu's; on another distro the paths
# move and the operator should know that before trusting the report.
# Globals:
#   None
# Arguments:
#   $1 - path to os-release
# Outputs:
#   "<id> <version_id>" on stdout, or "UNKNOWN"
# Returns:
#   0, always
luks_unlock_os_name() {
  local file="${1:-}" id="" version=""
  if [ -f "${file}" ]; then
    id="$(sed -n 's/^ID=//p' "${file}" 2>/dev/null | tail -n 1 | tr -d '"')"
    version="$(sed -n 's/^VERSION_ID=//p' "${file}" 2>/dev/null | tail -n 1 | tr -d '"')"
  fi
  if [ -z "${id}" ]; then
    printf 'UNKNOWN\n'
    return 0
  fi
  printf '%s %s\n' "${id}" "${version}"
}

# @function luks_unlock_os_supported
# Decide whether a distro id/version pair is one this recipe is written for.
# Globals:
#   LUKS_UNLOCK_SUPPORTED (space-separated "id:version" pairs; defaults to
#   ubuntu:22.04 and ubuntu:24.04)
# Arguments:
#   $1 - id (like "ubuntu")
#   $2 - version (like "24.04")
# Outputs:
#   Nothing
# Returns:
#   0 when the pair is supported, 1 otherwise
luks_unlock_os_supported() {
  local want="${1:-}:${2:-}" pair
  local supported="${LUKS_UNLOCK_SUPPORTED:-ubuntu:22.04 ubuntu:24.04}"
  for pair in ${supported}; do
    [ "${pair}" = "${want}" ] && return 0
  done
  return 1
}

# ── crypttab and fstab ────────────────────────────────────────────────────────

# @function luks_unlock_crypttab_rows
# Print one row per active crypttab entry as name, device, key and options
# separated by tabs. Comment and blank lines are dropped; a short line gets
# empty trailing fields rather than being skipped, because an entry missing its
# key column is exactly the kind of mistake worth reporting.
# Globals:
#   None
# Arguments:
#   $1 - path to crypttab
# Outputs:
#   Tab-separated rows on stdout, or nothing for an unreadable file
# Returns:
#   0, always
luks_unlock_crypttab_rows() {
  local file="${1:-}"
  [ -r "${file}" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      name = $1; dev = $2; key = $3; opt = $4
      printf "%s\t%s\t%s\t%s\n", name, dev, key, opt
    }
  ' "${file}" 2>/dev/null || true
}

# @function luks_unlock_root_name
# Print the crypttab target name that backs the root filesystem, found by
# asking fstab which /dev/mapper/<name> is mounted at /. The initramfs scripts
# make this determination the same way, so a root that is absent from fstab is
# a root that nothing will prompt for.
# Globals:
#   None
# Arguments:
#   $1 - path to fstab
# Outputs:
#   The mapper name on stdout, or nothing when fstab names no mapper root
# Returns:
#   0, always
luks_unlock_root_name() {
  local file="${1:-}"
  [ -r "${file}" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $2 == "/" && $1 ~ /^\/dev\/(mapper\/|disk\/by-)/ {
      target = $1
      sub(/^\/dev\/mapper\//, "", target)
      if (target != $1) { print target; exit }
    }
  ' "${file}" 2>/dev/null || true
}

# @function luks_unlock_key_gap
# Explain why a crypttab entry cannot be unlocked by the operator over SSH, or
# print nothing when it can. "none" means the passphrase prompt we are setting
# up; /dev/urandom and keyscripts need nobody; a keyfile only works at boot if
# the cryptsetup hook copies it into the initramfs, which it does only for
# files matching KEYFILE_PATTERN.
# Globals:
#   None
# Arguments:
#   $1 - the key column from crypttab
#   $2 - the options column from crypttab
#   $3 - the KEYFILE_PATTERN value from conf-hook, may be empty
# Outputs:
#   One reason line on stdout when the entry is unreachable, nothing otherwise
# Returns:
#   0, always
luks_unlock_key_gap() {
  local key="${1:-}" options="${2:-}" pattern="${3:-}"
  case "${key}" in
    "" | none | NONE | /dev/urandom | /dev/random) return 0 ;;
  esac
  case "${options}" in
    *keyscript=* | *keyfile-offset* | *decrypt_*) return 0 ;;
  esac
  # KEYFILE_PATTERN is a shell pattern on purpose: cryptsetup's own hook matches
  # the crypttab key column against it the same way, so a quoted compare here
  # would disagree with the tool whose behaviour this predicts. The unquoted
  # right side stays inside [[ ]] on purpose too - a malformed pattern that a
  # case statement would fail to parse is simply no match here.
  if [ -n "${pattern}" ]; then
    # shellcheck disable=SC2053,SC2254
    if [[ ${key} == ${pattern} ]]; then
      return 0
    fi
  fi
  printf 'key file %s is not covered by KEYFILE_PATTERN, so it never reaches the initramfs\n' "${key}"
}

# ── initramfs configuration ───────────────────────────────────────────────────

# @function luks_unlock_conf_set
# Ensure one KEY=value assignment is the effective last word in a key=value
# config file, leaving every other line untouched. Absent keys are appended;
# an existing line is rewritten in place. The write goes through a sibling
# temp file and a rename, so a crash cannot leave a half-written config that
# the next boot reads.
# Globals:
#   None
# Arguments:
#   $1 - file to write
#   $2 - key name
#   $3 - value (empty removes the assignment instead of writing KEY=)
# Outputs:
#   Nothing on stdout; creates or rewrites $1 and its parent directory
# Returns:
#   0 when the file holds the assignment; 1 when it could not be written
luks_unlock_conf_set() {
  local file="${1:-}" key="${2:-}" value="${3:-}"
  local part=""
  [ -n "${file}" ] && [ -n "${key}" ] || return 1
  mkdir -p "$(dirname "${file}")" 2>/dev/null || return 1
  part="${file}.luks-unlock.tmp"
  if [ -f "${file}" ]; then
    # The match operand is spelled $0 because mawk is Ubuntu's default awk and
    # it rejects a bare ~ as a syntax error, which would silently take every
    # rewrite of an existing file down with it.
    awk -v key="${key}" -v value="${value}" '
      BEGIN { done = 0 }
      $0 ~ "^" key "=" {
        if (!done) { if (value != "") print key "=" value; done = 1; next }
        next
      }
      { print }
      END { if (!done && value != "") print key "=" value }
    ' "${file}" >"${part}" 2>/dev/null || {
      rm -f "${part}"
      return 1
    }
  else
    if [ -z "${value}" ]; then
      return 0
    fi
    printf '%s=%s\n' "${key}" "${value}" >"${part}" 2>/dev/null || {
      rm -f "${part}"
      return 1
    }
  fi
  chmod 0644 "${part}" 2>/dev/null || true
  mv -f "${part}" "${file}" 2>/dev/null || {
    rm -f "${part}"
    return 1
  }
}

# @function luks_unlock_hooks_effective
# Print the hook names initramfs-tools will actually run: the last HOOKS
# assignment in initramfs.conf, overridden by conf.d/* in sort order the way
# the generator reads them. An empty answer means no HOOKS line anywhere, and
# initramfs-tools then runs every hook it finds, which is a pass rather than a
# gap.
# Globals:
#   None
# Arguments:
#   $1 - path to initramfs.conf
#   $2 - path to the conf.d directory
# Outputs:
#   Space-separated hook names on stdout, or nothing
# Returns:
#   0, always
luks_unlock_hooks_effective() {
  local conf="${1:-}" confd="${2:-}" out="" dropin=""
  out="$(env_get "${conf}" HOOKS)"
  if [ -d "${confd}" ]; then
    for dropin in "${confd}"/*; do
      [ -f "${dropin}" ] || continue
      if [ -n "$(env_get "${dropin}" HOOKS)" ]; then
        out="$(env_get "${dropin}" HOOKS)"
      fi
    done
  fi
  printf '%s\n' "${out}"
}

# @function luks_unlock_hooks_missing
# Print the needed hook names that the effective HOOKS list leaves out, so the
# caller can name them instead of guessing which of four hooks a silent boot
# skipped. An empty effective list means all hooks run and nothing is missing.
# Globals:
#   LUKS_UNLOCK_NEED_HOOKS
# Arguments:
#   $1 - the effective HOOKS string
# Outputs:
#   Space-separated missing names on stdout, or nothing
# Returns:
#   0, always
luks_unlock_hooks_missing() {
  local effective="${1:-}" need="${2:-${LUKS_UNLOCK_NEED_HOOKS}}" want missing=""
  [ -n "${effective}" ] || {
    printf '\n'
    return 0
  }
  for want in ${need}; do
    case " ${effective} " in
      *" ${want} "*) ;;
      *) missing="${missing:+${missing} }${want}" ;;
    esac
  done
  printf '%s\n' "${missing}"
}

# @function luks_unlock_net_state
# Say how the initramfs will get an address, from the IP= key the generator
# will read and the kernel's own cmdline. "none" is the answer that matters:
# with no address the SSH server has nothing to answer on and the box is
# unreachable by design.
# Globals:
#   None
# Arguments:
#   $1 - path to initramfs.conf
#   $2 - path to the conf.d directory
#   $3 - path to the kernel cmdline file
# Outputs:
#   One of "dhcp", "static", "cmdline", "off" or "none" on stdout
# Returns:
#   0, always
luks_unlock_net_state() {
  local conf="${1:-}" confd="${2:-}" cmdline="${3:-}" ip="" dropin="" state=""
  local line="" word="" from=""
  ip="$(env_get "${conf}" IP)"
  [ -n "${ip}" ] && from="conf"
  if [ -d "${confd}" ]; then
    for dropin in "${confd}"/*; do
      [ -f "${dropin}" ] || continue
      if [ -n "$(env_get "${dropin}" IP)" ]; then
        ip="$(env_get "${dropin}" IP)"
        from="confd"
      fi
    done
  fi
  if [ -z "${ip}" ] && [ -r "${cmdline}" ]; then
    # The kernel hands the initramfs one line of space-separated parameters, so
    # ip= has to be found among the words of that line and not in the line as a
    # whole: a line-at-a-time read answers "no ip= here" for every real cmdline,
    # which is the difference between "reachable" and an unrecoverable box.
    while read -r line || [ -n "${line}" ]; do
      # shellcheck disable=SC2086 # the cmdline is a word list by definition
      for word in ${line}; do
        case "${word}" in
          ip=*)
            ip="${word#ip=}"
            from="cmdline"
            ;;
        esac
      done
    done <"${cmdline}"
  fi
  case "${ip}" in
    "" | none | off | None | OFF) state="${ip:-none}" ;;
    dhcp | DHCP | on | ON)
      # A DHCP address that arrives via the kernel cmdline is reported as its
      # own state: it works, and it is the one configuration nobody owns in a
      # file, so a grub or BLS edit can drop it without a trace.
      if [ "${from}" = "cmdline" ]; then
        state="cmdline"
      else
        state="dhcp"
      fi
      ;;
    *) state="static" ;;
  esac
  printf '%s\n' "${state}"
}

# @function luks_unlock_ip_value
# Build the IP= value for the requested network mode. dhcp with no pinned
# interface is the plain word; pinning an interface needs the netboot form,
# where the device sits in the sixth field and autoconf stays dhcp. A raw
# spec is passed through because initramfs-tools parses it, not us.
# Globals:
#   None
# Arguments:
#   $1 - "dhcp", "none", "off", or a raw netboot spec
#   $2 - interface name to pin, may be empty
# Outputs:
#   The value to assign to IP= on stdout
# Returns:
#   0 when the value is usable; 1 when the mode is unknown
luks_unlock_ip_value() {
  local mode="${1:-dhcp}" iface="${2:-}"
  case "${mode}" in
    none | off)
      printf '%s\n' "${mode}"
      ;;
    dhcp)
      if [ -n "${iface}" ]; then
        printf ':::::%s:dhcp\n' "${iface}"
      else
        printf 'dhcp\n'
      fi
      ;;
    *)
      case "${mode}" in
        *:*) printf '%s\n' "${mode}" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# @function luks_unlock_net_ifaces
# Print the network interfaces the kernel named, one per line, from sysfs. The
# initramfs brings up one of these, so a typo in --iface is worth catching
# before a reboot rather than after one.
# Globals:
#   None
# Arguments:
#   $1 - path to the sysfs net directory
# Outputs:
#   Interface names on stdout, or nothing when sysfs is unreadable
# Returns:
#   0, always
luks_unlock_net_ifaces() {
  local dir="${1:-}" entry
  [ -d "${dir}" ] || return 0
  for entry in "${dir}"/*; do
    [ -d "${entry}" ] || continue
    printf '%s\n' "${entry##*/}"
  done
}

# @function luks_unlock_modules_state
# Print initramfs-tools' MODULES setting, defaulting to "most" the way the
# generator does. "dep" is the mode that can strand a box: it packs only the
# drivers the running kernel is using right now, so a NIC whose driver is not
# loaded today is simply absent from the initramfs.
# Globals:
#   None
# Arguments:
#   $1 - path to initramfs.conf
#   $2 - path to the conf.d directory
# Outputs:
#   "most", "dep", "netboot" or the literal value on stdout
# Returns:
#   0, always
luks_unlock_modules_state() {
  local conf="${1:-}" confd="${2:-}" value="" dropin=""
  value="$(env_get "${conf}" MODULES)"
  if [ -d "${confd}" ]; then
    for dropin in "${confd}"/*; do
      [ -f "${dropin}" ] || continue
      if [ -n "$(env_get "${dropin}" MODULES)" ]; then
        value="$(env_get "${dropin}" MODULES)"
      fi
    done
  fi
  printf '%s\n' "${value:-most}"
}

# ── Dropbear in the initramfs ─────────────────────────────────────────────────

# @function luks_unlock_key_files
# Print the authorized_keys file the installed dropbear hook actually reads.
# Ubuntu and Debian spell the path differently, so the hook text is the
# evidence; when the hook is missing or names neither path, both are returned
# and the caller writes to each.
# Globals:
#   LUKS_UNLOCK_FALLBACK_KEY_FILES
# Arguments:
#   $1 - path to the dropbear initramfs hook
# Outputs:
#   One or two absolute paths on stdout, space-separated
# Returns:
#   0, always
luks_unlock_key_files() {
  local hook="${1:-}" found="" candidate
  for candidate in ${LUKS_UNLOCK_FALLBACK_KEY_FILES}; do
    if [ -r "${hook}" ] && grep -qF -- "${candidate}" "${hook}" 2>/dev/null; then
      found="${found:+${found} }${candidate}"
    fi
  done
  [ -n "${found}" ] || found="${LUKS_UNLOCK_FALLBACK_KEY_FILES}"
  printf '%s\n' "${found}"
}

# @function luks_unlock_pubkey_check
# Validate one authorized_keys line: a key type this stack can generate, a
# base64 body long enough to be a real key, and an optional comment. A line
# with a stray newline or a wrapped paste is the failure that produces an
# unlock key that silently never works, so it is rejected here rather than at
# the boot it would have saved.
# Globals:
#   None
# Arguments:
#   $1 - the line to check
# Outputs:
#   "ok" or one reason on stdout
# Returns:
#   0 when the line is usable, 1 when it is not
luks_unlock_pubkey_check() {
  local line="${1:-}" body=""
  case "${line}" in
    "")
      printf 'empty line\n'
      return 1
      ;;
    \#*)
      printf 'comment\n'
      return 1
      ;;
  esac
  # An options list precedes the type when present; dropbear separates it from
  # the type by the first space, so the type is the first field that is not a
  # quoted options blob.
  case "${line}" in
    *'"'*) line="${line#*\" }" ;;
  esac
  case "${line}" in
    ssh-ed25519\ * | ssh-rsa\ * | ssh-ecdsa\ * | ecdsa-sha2-nistp256\ * | ssh-ed448\ * | ssh-dss\ *) ;;
    *)
      printf 'no known key type at the front of the line\n'
      return 1
      ;;
  esac
  body="$(printf '%s\n' "${line}" | awk '{print $2}')"
  if [ "${#body}" -lt 40 ]; then
    printf 'the key body is too short to be a real public key\n'
    return 1
  fi
  case "${body}" in
    *[!A-Za-z0-9+/=]*)
      printf 'the key body holds characters that are not base64 (a wrapped paste?)\n'
      return 1
      ;;
  esac
  printf 'ok\n'
}

# @function luks_unlock_authorized_keys_report
# Print one "<status>\t<reason>" line per key line of an authorized_keys file,
# so a caller can count the good ones and quote the bad ones. Missing and
# unreadable files are reported rather than treated as empty.
# Globals:
#   None
# Arguments:
#   $1 - path to the authorized_keys file
# Outputs:
#   One tab-separated line per key on stdout
# Returns:
#   0, always
luks_unlock_authorized_keys_report() {
  local file="${1:-}" line reason
  if [ ! -e "${file}" ]; then
    printf 'missing\tno authorized_keys file; dropbear refuses to start without one\n'
    return 0
  fi
  if [ ! -s "${file}" ]; then
    printf 'missing\tthe authorized_keys file is empty; dropbear refuses to start without a key\n'
    return 0
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "" | \#*) continue ;;
    esac
    if reason="$(luks_unlock_pubkey_check "${line}")"; then
      printf 'ok\t%s\n' "${reason}"
    else
      printf 'bad\t%s\n' "${reason}"
    fi
  done <"${file}"
}

# @function luks_unlock_authorized_keys_install
# Put an operator's public keys at a destination the initramfs hook will read,
# keeping a copy of whatever was there and pinning the mode: this file is the
# only thing standing between an unencrypted /boot and a root shell on a box
# that is not yet unlocked.
# Globals:
#   None
# Arguments:
#   $1 - path to the file to install from
#   $2 - destination path
# Outputs:
#   Nothing on stdout; writes $2 and, when a file was replaced, $2.bak
# Returns:
#   0 when the destination holds the keys; 1 when source or destination failed
luks_unlock_authorized_keys_install() {
  local src="${1:-}" dest="${2:-}" part=""
  [ -n "${src}" ] && [ -n "${dest}" ] || return 1
  [ -s "${src}" ] || return 1
  mkdir -p "$(dirname "${dest}")" 2>/dev/null || return 1
  if [ -f "${dest}" ]; then
    cp -p "${dest}" "${dest}.bak" 2>/dev/null || return 1
  fi
  part="${dest}.luks-unlock.tmp"
  cat "${src}" >"${part}" 2>/dev/null || {
    rm -f "${part}"
    return 1
  }
  chmod 0600 "${part}" 2>/dev/null || true
  mv -f "${part}" "${dest}" 2>/dev/null || {
    rm -f "${part}"
    return 1
  }
  chmod 0600 "${dest}" 2>/dev/null || true
}

# @function luks_unlock_host_keys_missing
# Name the initramfs host keys a box does not have. dropbear refuses to start
# with none of them, and the package only generates them at install time, so a
# host that installed the package before this CLI exists may have none.
# Globals:
#   LUKS_UNLOCK_HOST_KEYS
# Arguments:
#   $1 - the initramfs dropbear directory
# Outputs:
#   One key file name per absent key on stdout, or nothing when all are there
# Returns:
#   0, always
luks_unlock_host_keys_missing() {
  local dir="${1:-}" name missing=""
  for name in ${LUKS_UNLOCK_HOST_KEYS}; do
    [ -s "${dir}/${name}" ] || missing="${missing:+${missing} }${name}"
  done
  printf '%s\n' "${missing}"
}

# @function luks_unlock_dropbear_options
# Render the DROPBEAR_OPTIONS value for the initramfs daemon. -s keeps
# password logins off (there is no root password worth trying and a prompt
# invites brute force), -I bounds a session a client abandoned, -j and -k skip
# utmp and lastlog bookkeeping the initramfs has no use for, and -p moves it
# off the installed sshd's port so the different host keys do not look like an
# attack on the client's known_hosts.
# Globals:
#   None
# Arguments:
#   $1 - port
#   $2 - idle timeout in seconds
# Outputs:
#   The options string on stdout, without the DROPBEAR_OPTIONS= prefix
# Returns:
#   0
luks_unlock_dropbear_options() {
  local port="${1:-${LUKS_UNLOCK_DEFAULT_PORT}}" idle="${2:-${LUKS_UNLOCK_DEFAULT_IDLE}}"
  printf -- '-p %s -s -I %s -j -k\n' "${port}" "${idle}"
}

# @function luks_unlock_dropbear_port
# Print the port the initramfs dropbear will listen on, read from the -p flag
# of DROPBEAR_OPTIONS, falling back to the default when the option is absent.
# Globals:
#   LUKS_UNLOCK_DEFAULT_PORT
# Arguments:
#   $1 - path to the initramfs dropbear.conf
# Outputs:
#   A port number on stdout
# Returns:
#   0, always
luks_unlock_dropbear_port() {
  local conf="${1:-}" options="" token="" want_next=0
  options="$(env_get "${conf}" DROPBEAR_OPTIONS)"
  # shellcheck disable=SC2086 # word splitting on the options string is the parse
  for token in ${options}; do
    if [ "${want_next}" = "1" ]; then
      printf '%s\n' "${token}"
      return 0
    fi
    case "${token}" in
      -p) want_next=1 ;;
      -p*)
        printf '%s\n' "${token#-p}"
        return 0
        ;;
    esac
  done
  printf '%s\n' "${LUKS_UNLOCK_DEFAULT_PORT}"
}

# @function luks_unlock_ssh_hint
# Print the exact command to run from the operator's laptop, pointing ssh at a
# known_hosts file of its own. Sharing the default known_hosts with the
# installed sshd makes the second connection fail a host key check that looks
# like a man-in-the-middle and is really just a different key.
# Globals:
#   None
# Arguments:
#   $1 - host to reach
#   $2 - port
# Outputs:
#   The command on stdout
# Returns:
#   0
luks_unlock_ssh_hint() {
  local host="${1:-<server>}" port="${2:-${LUKS_UNLOCK_DEFAULT_PORT}}"
  printf 'ssh -o UserKnownHostsFile=~/.luks/known_hosts -o StrictHostKeyChecking=accept-new -p %s root@%s\n' \
    "${port}" "${host}"
}

# ── The generated initramfs ───────────────────────────────────────────────────

# @function luks_unlock_initrd_for
# Print the initrd path for one kernel version, and nothing when /boot holds
# no such image. A missing initrd is not a check that failed, it is a check
# that has no subject.
# Globals:
#   None
# Arguments:
#   $1 - the boot directory
#   $2 - kernel version (like 6.8.0-41-generic)
# Outputs:
#   An initrd path on stdout, or nothing
# Returns:
#   0, always
luks_unlock_initrd_for() {
  local boot="${1:-}" version="${2:-}" candidate
  for candidate in "${boot}/initrd.img-${version}" "${boot}/initrd-${version}.img"; do
    if [ -s "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf '\n'
}

# @function luks_unlock_initrd_list
# Print the file list inside one initrd, using whichever listing tool the box
# has. This is the only evidence that matters: a config file can say DROPBEAR=y
# all day and the hook can still have skipped copying the binary.
# Globals:
#   None
# Arguments:
#   $1 - path to the initrd
# Outputs:
#   The member listing on stdout; nothing when no listing tool answered
# Returns:
#   0 when a tool answered, 1 when none is present or all failed
luks_unlock_initrd_list() {
  local initrd="${1:-}" tool="" out=""
  [ -s "${initrd}" ] || return 1
  for tool in lsinitramfs lsinitrd; do
    has_tool "${tool}" || continue
    if out="$(capped_run 60 "${tool}" "${initrd}" 2>/dev/null)" && [ -n "${out}" ]; then
      printf '%s\n' "${out}"
      return 0
    fi
  done
  return 1
}

# @function luks_unlock_initrd_has
# Decide whether an initrd listing holds a path, matched on a path boundary so
# "bin/dropbear" does not report a hit for "bin/dropbearkey".
# Globals:
#   None
# Arguments:
#   $1 - the initrd listing, already captured
#   $2 - the path fragment to look for
# Outputs:
#   Nothing
# Returns:
#   0 when the listing names it, 1 when it does not
luks_unlock_initrd_has() {
  local listing="${1:-}" needle="${2:-}"
  [ -n "${listing}" ] || return 1
  [ -n "${needle}" ] || return 1
  printf '%s\n' "${listing}" | grep -qE -- "(^|[[:space:]/])${needle}([[:space:]]|$)"
}

# @function luks_unlock_fingerprint
# Print the SHA256 fingerprint of one host key, so the operator can pin it
# before the reboot and recognise the initramfs daemon when it answers.
# Globals:
#   None
# Arguments:
#   $1 - path to a dropbear or ssh host key file
# Outputs:
#   The fingerprint line on stdout; nothing when ssh-keygen could not read it
# Returns:
#   0 when a fingerprint was printed, 1 otherwise
luks_unlock_fingerprint() {
  local key="${1:-}" out=""
  [ -s "${key}" ] || return 1
  has_tool ssh-keygen || return 1
  if out="$(capped_run 20 ssh-keygen -lf "${key}" 2>/dev/null)" && [ -n "${out}" ]; then
    printf '%s\n' "${out}"
    return 0
  fi
  return 1
}
