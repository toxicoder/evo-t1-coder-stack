#!/usr/bin/env bats
#
# ## luks-unlock.bats — the remote-unlock recipe: what blocks a reboot, and what
# install writes to clear it.
#
# Usage:
#   bazelisk test //tests:bats_luks_unlock_test
#
# Safety:
#   Every file the CLI reads or writes is derived from LUKS_ROOT, which every
#   case points at a scratch tree, and the mutating verb runs under
#   LUKS_UNLOCK_DRY_RUN unless a case drops that gate on purpose. A sudo that
#   escaped PATH would still have nowhere to land, so no case here can touch the
#   host that runs it.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
KERNEL="6.8.0-41-generic"
GOOD_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJTstubstubstubstubstubstubstubstubstubstubstub operator@laptop"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "no repo root to test"
  SCRIPT="${REPO_ROOT}/scripts/luks-unlock.sh"
  LIB="${REPO_ROOT}/scripts/lib/luks-unlock.sh"
  # The gate that keeps a mutating verb from ever reaching the host.
  export LUKS_UNLOCK_DRY_RUN=1
  unset CI
  SUMMARY_OK=0
  SUMMARY_WARN=0
  SUMMARY_FAIL=0
  SUMMARY_FAIL_ITEMS=""
}

# ── Loading and fixtures ───────────────────────────────────────────────────────

load_lib() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "${LIB}"
}

load_entry() {
  load_shell_function "${SCRIPT}" "$1"
}

# strict <fn...> — one production function under `set -u`, which is how the entry
# script runs it. A helper that only works with the options off passes here only
# by accident, so pin the options instead of leaving that to chance.
strict() {
  set -u
  "$@"
}

# run_strict <fn...> — the same through run, which is what puts the result in
# $status. run forks, so `set -u` cannot leak into the rest of the test.
run_strict() {
  run strict "$@"
}

# capture <fn...> — call a report function in THIS shell with both streams into
# $captured. It has to be this shell because ok, warn and fail_item move the
# summary counters, and a command substitution would fork them away; both
# streams because ok and warn print on stdout while fail_item prints on stderr.
capture() {
  local file="${BATS_TEST_TMPDIR}/captured"
  captured=""
  "$@" >"${file}" 2>&1
  captured="$(cat "${file}")"
}

# make_sysroot — a tree a fully-configured Ubuntu 24.04 LUKS host would present.
# A test that wants a broken box breaks one thing in it and says which.
make_sysroot() {
  local root key
  root="$(make_scratch)"
  mkdir -p "${root}/etc/cryptsetup-initramfs" "${root}/etc/initramfs-tools/conf.d" \
    "${root}/etc/dropbear/initramfs" "${root}/etc/ssh" "${root}/boot" "${root}/proc" \
    "${root}/sys/class/net/ens3" "${root}/usr/share/initramfs-tools/hooks" \
    "${root}/usr/share/cryptsetup/initramfs/bin" "${root}/bin"

  cat >"${root}/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
EOF
  printf 'cryptroot /dev/sda2 none luks,discard\n' >"${root}/etc/crypttab"
  printf '/dev/mapper/cryptroot / ext4 defaults 0 1\n' >"${root}/etc/fstab"
  printf 'CRYPTSETUP=y\n' >"${root}/etc/cryptsetup-initramfs/conf-hook"
  {
    printf 'UMASK=0077\n'
    printf 'MODULES=most\n'
    printf 'HOOKS="base udev autodisk modctl cryptroot cryptroot-unlock net dropbear"\n'
  } >"${root}/etc/initramfs-tools/initramfs.conf"
  printf 'DROPBEAR=y\nIP=dhcp\n' >"${root}/etc/initramfs-tools/conf.d/zz-luks-unlock"
  printf '# the hook reads /etc/dropbear/initramfs/authorized_keys\n' \
    >"${root}/usr/share/initramfs-tools/hooks/dropbear"
  printf '#!/bin/sh\n' >"${root}/usr/share/cryptsetup/initramfs/bin/cryptroot-unlock"
  chmod +x "${root}/usr/share/cryptsetup/initramfs/bin/cryptroot-unlock"
  for key in ed25519 ecdsa rsa; do
    printf 'hostkey-%s\n' "${key}" >"${root}/etc/dropbear/initramfs/dropbear_${key}_host_key"
  done
  printf '%s\n' "${GOOD_KEY}" >"${root}/etc/dropbear/initramfs/authorized_keys"
  printf 'Port 22\n' >"${root}/etc/ssh/sshd_config"
  printf 'fake-initrd\n' >"${root}/boot/initrd.img-${KERNEL}"
  printf 'BOOT_IMAGE=/vmlinuz-%s root=/dev/mapper/cryptroot ro quiet\n' "${KERNEL}" \
    >"${root}/proc/cmdline"
  make_list_stub "${root}/bin/lsinitramfs"
  make_findmnt_stub "${root}/bin/findmnt"
  make_keygen_stub "${root}/bin/ssh-keygen"
  printf '%s\n' "${root}"
}

make_list_stub() {
  local path="$1"
  cat >"${path}" <<'STUB'
#!/bin/sh
printf '%s\n' . bin bin/busybox bin/dropbear usr usr/bin usr/bin/cryptroot-unlock \
  root root/.ssh root/.ssh/authorized_keys2
STUB
  chmod 755 "${path}"
}

make_findmnt_stub() {
  local path="$1"
  cat >"${path}" <<'STUB'
#!/bin/sh
printf '/dev/sda1\n'
STUB
  chmod 755 "${path}"
}

make_keygen_stub() {
  local path="$1"
  cat >"${path}" <<'STUB'
#!/bin/sh
printf '256 SHA256:stubbedfingerprint operator@laptop (ed25519)\n'
STUB
  chmod 755 "${path}"
}

# make_sudo_stub <dir> <uid> — pin which privilege branch luks_unlock_run takes.
# It asks id -u and shells through sudo for a non-root caller, so a case that
# leaves that to the runtime passes on a developer laptop and dies in the CI
# image, whose uid has no passwd entry and whose sudo answers "you do not exist
# in the passwd database". The sudo stub records its argv in $SUDO_LOG and then
# execs the command, so the case sees both the routing and the effect.
make_sudo_stub() {
  local dir="$1" uid="$2"
  cat >"${dir}/id" <<STUB
#!/bin/sh
printf '%s\n' ${uid}
STUB
  cat >"${dir}/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"${SUDO_LOG:?}"
exec "$@"
STUB
  chmod 755 "${dir}/id" "${dir}/sudo"
}

# run_cli <sysroot> <args...> — the CLI as an operator runs it, stub bin first
# and no CI, so a missing tool is a report rather than a failure. The dry-run
# gate setup() exports stays in force: an install verb here prints its intent.
run_cli() {
  local root="$1"
  shift
  run --separate-stderr env -u CI \
    PATH="${root}/bin:/usr/local/bin:/usr/bin:/bin" \
    LUKS_ROOT="${root}" LUKS_UNLOCK_UNAME_R="${KERNEL}" \
    LUKS_UNLOCK_PUBKEY_FILE="${root}/key.pub" \
    bash "${SCRIPT}" "$@"
}

# run_cli_write <sysroot> <args...> — the same with the dry-run gate dropped,
# for the cases whose whole point is the bytes on disk. Every write is still
# sysroot-relative, so the only way out of the scratch tree is a bug in
# luks_unlock_paths, which the path test pins. Callers add --no-pkgs
# --no-regenerate so no external command runs either.
run_cli_write() {
  local root="$1"
  shift
  run --separate-stderr env -u CI -u LUKS_UNLOCK_DRY_RUN \
    PATH="${root}/bin:/usr/local/bin:/usr/bin:/bin" \
    LUKS_ROOT="${root}" LUKS_UNLOCK_UNAME_R="${KERNEL}" \
    LUKS_UNLOCK_PUBKEY_FILE="${root}/key.pub" \
    bash "${SCRIPT}" "$@"
}

# ── Paths and distro ──────────────────────────────────────────────────────────

@test "luks_unlock_paths: every path hangs off the sysroot it is given" {
  load_lib
  local root
  root="$(make_scratch)"
  luks_unlock_paths "${root}"
  assert_eq "the crypttab" "${root}/etc/crypttab" "${LUKS_CRYPTTAB}"
  assert_eq "the fstab" "${root}/etc/fstab" "${LUKS_FSTAB}"
  assert_eq "the cryptsetup hook conf" "${root}/etc/cryptsetup-initramfs/conf-hook" "${LUKS_CONF_HOOK}"
  assert_eq "the generator conf" "${root}/etc/initramfs-tools/initramfs.conf" "${LUKS_INITRAMFS_CONF}"
  assert_eq "the owned drop-in" \
    "${root}/etc/initramfs-tools/conf.d/${LUKS_UNLOCK_CONF_D_FILE}" "${LUKS_CONF_D_FILE_PATH}"
  assert_eq "the initramfs dropbear conf" "${root}/etc/dropbear/initramfs/dropbear.conf" \
    "${LUKS_DROPBEAR_CONF}"
  assert_eq "the unlock command" \
    "${root}/usr/share/cryptsetup/initramfs/bin/cryptroot-unlock" "${LUKS_CRYPTROOT_UNLOCK}"
  assert_eq "the boot dir" "${root}/boot" "${LUKS_BOOT_DIR}"
  luks_unlock_paths "${root}/"
  assert_eq "a trailing slash does not double up" "${root}/boot" "${LUKS_BOOT_DIR}"
}

@test "luks_unlock_paths: the default root is the real filesystem" {
  load_lib
  luks_unlock_paths "/"
  assert_eq "the real crypttab" "/etc/crypttab" "${LUKS_CRYPTTAB}"
  assert_eq "the real boot dir" "/boot" "${LUKS_BOOT_DIR}"
}

@test "luks_unlock_os_name: reads ID and VERSION_ID, and says UNKNOWN without the file" {
  load_lib
  local root
  root="$(make_scratch)"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"${root}/os-release"
  assert_eq "ubuntu reports its version" "ubuntu 24.04" \
    "$(luks_unlock_os_name "${root}/os-release")"
  assert_eq "no file is not a crash" "UNKNOWN" "$(luks_unlock_os_name "${root}/absent")"
}

@test "luks_unlock_os_supported: the two LTS releases are, everything else is not" {
  load_lib
  run_strict luks_unlock_os_supported ubuntu 24.04
  [ "${status}" -eq 0 ]
  run_strict luks_unlock_os_supported ubuntu 22.04
  [ "${status}" -eq 0 ]
  run_strict luks_unlock_os_supported ubuntu 25.10
  [ "${status}" -eq 1 ]
  run_strict luks_unlock_os_supported debian 12
  [ "${status}" -eq 1 ]
  LUKS_UNLOCK_SUPPORTED="linuxmint:22"
  run_strict luks_unlock_os_supported linuxmint 22
  [ "${status}" -eq 0 ]
}

# ── crypttab and fstab ────────────────────────────────────────────────────────

@test "luks_unlock_crypttab_rows: skips comments, keeps fields tab-separated" {
  load_lib
  local root out
  root="$(make_scratch)"
  cat >"${root}/crypttab" <<'EOF'
# comment line

cryptroot /dev/sda2 none luks,discard
cryptswap /dev/sda3 /dev/urandom swap,cipher=aes-xts-plain64
EOF
  out="$(luks_unlock_crypttab_rows "${root}/crypttab")"
  assert_eq "two entries survive" "2" "$(printf '%s\n' "${out}" | grep -c .)"
  assert_match "the root row is intact" \
    "^cryptroot$(printf '\t')/dev/sda2$(printf '\t')none$(printf '\t')luks,discard$" "${out}"
  assert_not_match "the comment did not become a row" "comment" "${out}"
  assert_eq "an unreadable file answers nothing" "" "$(luks_unlock_crypttab_rows "${root}/nope")"
}

@test "luks_unlock_root_name: reads the mapper mounted at / and nothing else" {
  load_lib
  local root
  root="$(make_scratch)"
  cat >"${root}/fstab" <<'EOF'
# /dev/mapper/decoy / ext4 defaults 0 1
UUID=abcd /boot ext4 defaults 0 2
/dev/mapper/cryptroot / ext4 defaults 0 1
/dev/mapper/data /data ext4 defaults 0 0
EOF
  assert_eq "the live root line wins over the commented one" "cryptroot" \
    "$(luks_unlock_root_name "${root}/fstab")"
  printf 'UUID=abcd / ext4 defaults 0 1\n' >"${root}/plain"
  assert_eq "an unencrypted root names no mapper" "" "$(luks_unlock_root_name "${root}/plain")"
  assert_eq "a missing fstab is not a crash" "" "$(luks_unlock_root_name "${root}/absent")"
}

@test "luks_unlock_key_gap: a passphrase and a random key answer nobody; a stray keyfile does" {
  load_lib
  assert_eq "none prompts, so it is reachable" "" "$(luks_unlock_key_gap none luks,discard '')"
  assert_eq "urandom needs nobody" "" "$(luks_unlock_key_gap /dev/urandom swap '')"
  assert_eq "a keyscript is the operator's own business" "" \
    "$(luks_unlock_key_gap /dev/sdb1 'luks,keyscript=/sbin/cryptkey' '')"
  assert_eq "a keyfile matching the pattern reaches the initramfs" "" \
    "$(luks_unlock_key_gap /etc/keys/root.key luks '/etc/keys/*.key')"
  local gap
  gap="$(luks_unlock_key_gap /etc/keys/root.key luks,discard '')"
  assert_match "an uncovered keyfile is named" "root.key" "${gap}"
  assert_match "and the reason is the initramfs" "KEYFILE_PATTERN" "${gap}"
}

# ── initramfs configuration ───────────────────────────────────────────────────

@test "luks_unlock_conf_set: appends, rewrites in place, and collapses duplicates" {
  load_lib
  local root file
  root="$(make_scratch)"
  file="${root}/etc/conf"
  mkdir -p "${root}/etc"
  printf '# keep me\nOTHER=1\n' >"${file}"
  strict luks_unlock_conf_set "${file}" CRYPTSETUP y
  assert_contains_file "the new key is present" "${file}" '^CRYPTSETUP=y$'
  assert_contains_file "the comment survived" "${file}" '^# keep me$'
  assert_contains_file "the other key survived" "${file}" '^OTHER=1$'
  strict luks_unlock_conf_set "${file}" CRYPTSETUP n
  assert_eq "the value is replaced, not appended" "1" "$(grep -c '^CRYPTSETUP=' "${file}")"
  assert_contains_file "and it holds the new value" "${file}" '^CRYPTSETUP=n$'

  printf 'A=1\nB=2\nA=3\n' >"${file}"
  strict luks_unlock_conf_set "${file}" A 9
  assert_eq "the duplicate is collapsed to one line" "1" "$(grep -c '^A=' "${file}")"
  assert_contains_file "the surviving line holds the new value" "${file}" '^A=9$'
  assert_contains_file "and the other line is still there" "${file}" '^B=2$'
  assert_eq "in the original reading order" "2" "$(wc -l <"${file}")"
}

@test "luks_unlock_conf_set: creates a missing file and refuses a nameless key" {
  load_lib
  local root
  root="$(make_scratch)"
  run_strict luks_unlock_conf_set "${root}/etc/new/conf" IP dhcp
  [ "${status}" -eq 0 ]
  assert_contains_file "the parent directory came with it" "${root}/etc/new/conf" '^IP=dhcp$'
  run_strict luks_unlock_conf_set "${root}/etc/new/conf" "" value
  [ "${status}" -eq 1 ]
  run_strict luks_unlock_conf_set "" IP value
  [ "${status}" -eq 1 ]
}

@test "luks_unlock_conf_set: a value with spaces survives the round trip" {
  load_lib
  local root file
  root="$(make_scratch)"
  file="${root}/conf"
  strict luks_unlock_conf_set "${file}" DROPBEAR_OPTIONS "-p 2222 -s -I 60 -j -k"
  assert_contains_file "the whole options string is stored" "${file}" \
    '^DROPBEAR_OPTIONS=-p 2222 -s -I 60 -j -k$'
  assert_eq "and reads back identically" "-p 2222 -s -I 60 -j -k" "$(env_get "${file}" DROPBEAR_OPTIONS)"
}

@test "luks_unlock_hooks_effective: conf.d wins over initramfs.conf, last file wins" {
  load_lib
  local root
  root="$(make_scratch)"
  mkdir -p "${root}/conf.d"
  printf 'HOOKS="base udev cryptroot"\n' >"${root}/initramfs.conf"
  assert_eq "the base list is the start" "base udev cryptroot" \
    "$(luks_unlock_hooks_effective "${root}/initramfs.conf" "${root}/conf.d")"
  printf 'HOOKS="base udev cryptroot net"\n' >"${root}/conf.d/a-dropbear"
  printf 'HOOKS="base udev cryptroot net dropbear"\n' >"${root}/conf.d/zz-mine"
  assert_eq "the last file in sort order is the effective one" "base udev cryptroot net dropbear" \
    "$(luks_unlock_hooks_effective "${root}/initramfs.conf" "${root}/conf.d")"
  assert_eq "a missing directory is not an error" "base udev cryptroot" \
    "$(luks_unlock_hooks_effective "${root}/initramfs.conf" "${root}/nope")"
}

@test "luks_unlock_hooks_missing: names only what is absent, and nothing when unrestricted" {
  load_lib
  assert_eq "everything is there" "" \
    "$(luks_unlock_hooks_missing 'base udev cryptroot cryptroot-unlock net dropbear')"
  assert_eq "one is missing" "net" \
    "$(luks_unlock_hooks_missing 'base udev cryptroot cryptroot-unlock dropbear')"
  assert_eq "no HOOKS line means every hook runs" "" "$(luks_unlock_hooks_missing '')"
  assert_eq "and that is reported as nothing missing" "" \
    "$(luks_unlock_hooks_missing '' 'cryptroot net')"
}

@test "luks_unlock_net_state: dhcp, a static spec, the kernel cmdline, and the dead case" {
  load_lib
  local root
  root="$(make_scratch)"
  mkdir -p "${root}/conf.d"
  printf 'IP=dhcp\n' >"${root}/initramfs.conf"
  assert_eq "dhcp from the conf" "dhcp" \
    "$(luks_unlock_net_state "${root}/initramfs.conf" "${root}/conf.d" "${root}/cmdline")"
  printf 'IP=:::::ens3:dhcp\n' >"${root}/conf.d/zz-mine"
  assert_eq "a pinned device is still a real configuration" "static" \
    "$(luks_unlock_net_state "${root}/initramfs.conf" "${root}/conf.d" "${root}/cmdline")"
  rm -f "${root}/conf.d/zz-mine" "${root}/initramfs.conf"
  printf 'BOOT_IMAGE=/vmlinuz ip=dhcp root=/dev/mapper/cryptroot\n' >"${root}/cmdline"
  assert_eq "the kernel can supply it instead" "cmdline" \
    "$(luks_unlock_net_state "${root}/initramfs.conf" "${root}/conf.d" "${root}/cmdline")"
  printf 'BOOT_IMAGE=/vmlinuz ip=off\n' >"${root}/cmdline"
  assert_eq "ip=off is the unreachable case" "off" \
    "$(luks_unlock_net_state "${root}/initramfs.conf" "${root}/conf.d" "${root}/cmdline")"
  rm -f "${root}/cmdline"
  assert_eq "nothing set anywhere" "none" \
    "$(luks_unlock_net_state "${root}/initramfs.conf" "${root}/conf.d" "${root}/cmdline")"
}

@test "luks_unlock_ip_value: builds the netboot form only when an interface is pinned" {
  load_lib
  assert_eq "plain dhcp" "dhcp" "$(luks_unlock_ip_value dhcp '')"
  assert_eq "pinned dhcp keeps autoconf" ":::::ens3:dhcp" "$(luks_unlock_ip_value dhcp ens3)"
  assert_eq "off passes through" "off" "$(luks_unlock_ip_value off '')"
  assert_eq "a raw spec passes through" "10.0.0.5::10.0.0.1:255.255.255.0:box:ens3:off" \
    "$(luks_unlock_ip_value '10.0.0.5::10.0.0.1:255.255.255.0:box:ens3:off' '')"
  run_strict luks_unlock_ip_value 10.0.0.5 ''
  [ "${status}" -eq 1 ]
}

@test "luks_unlock_net_ifaces: one name per line from sysfs, nothing without it" {
  load_lib
  local root out
  root="$(make_scratch)"
  mkdir -p "${root}/sys/class/net/ens3" "${root}/sys/class/net/lo"
  out="$(luks_unlock_net_ifaces "${root}/sys/class/net")"
  assert_match "the NIC is listed" "^ens3$" "${out}"
  assert_match "and the loopback too" "^lo$" "${out}"
  assert_eq "unreadable sysfs answers nothing" "" "$(luks_unlock_net_ifaces "${root}/nope")"
}

@test "luks_unlock_modules_state: most is the default and dep is the one worth surfacing" {
  load_lib
  local root
  root="$(make_scratch)"
  mkdir -p "${root}/conf.d"
  printf 'UMASK=0022\n' >"${root}/initramfs.conf"
  assert_eq "unset means the generator default" "most" \
    "$(luks_unlock_modules_state "${root}/initramfs.conf" "${root}/conf.d")"
  printf 'MODULES=dep\n' >"${root}/conf.d/zz-tuned"
  assert_eq "and conf.d wins" "dep" \
    "$(luks_unlock_modules_state "${root}/initramfs.conf" "${root}/conf.d")"
}

# ── Dropbear ──────────────────────────────────────────────────────────────────

@test "luks_unlock_key_files: asks the installed hook which path it reads" {
  load_lib
  local root hook
  root="$(make_scratch)"
  hook="${root}/dropbear-hook"
  printf '# reads /etc/dropbear/initramfs/authorized_keys\n' >"${hook}"
  assert_eq "Ubuntu's hook path is the one returned" "/etc/dropbear/initramfs/authorized_keys" \
    "$(luks_unlock_key_files "${hook}")"
  printf '# reads /etc/dropbear-initramfs/authorized_keys\n' >"${hook}"
  assert_eq "Debian's hook path is the one returned" "/etc/dropbear-initramfs/authorized_keys" \
    "$(luks_unlock_key_files "${hook}")"
  printf '# names nothing\n' >"${hook}"
  assert_eq "a hook that says nothing writes both" \
    "/etc/dropbear/initramfs/authorized_keys /etc/dropbear-initramfs/authorized_keys" \
    "$(luks_unlock_key_files "${hook}")"
  assert_eq "and a missing hook does the same" \
    "/etc/dropbear/initramfs/authorized_keys /etc/dropbear-initramfs/authorized_keys" \
    "$(luks_unlock_key_files "${root}/absent")"
}

@test "luks_unlock_pubkey_check: accepts real keys and explains every rejection" {
  load_lib
  assert_eq "a real line is ok" "ok" "$(strict luks_unlock_pubkey_check "${GOOD_KEY}")"
  local opts
  opts="from=\"10.0.0.0/8\" ${GOOD_KEY}"
  assert_eq "an options list is still a key" "ok" "$(strict luks_unlock_pubkey_check "${opts}")"
  assert_match "an empty line is refused" "empty" "$(luks_unlock_pubkey_check '')"
  run_strict luks_unlock_pubkey_check ''
  [ "${status}" -eq 1 ]
  assert_match "a comment is refused" "comment" "$(luks_unlock_pubkey_check '# note')"
  assert_match "an unknown type is refused" "key type" \
    "$(luks_unlock_pubkey_check 'ssh-totp AAAAC3NzaC1lZDI1NTE5AAAAIJTstubstubstubstub')"
  assert_match "a truncated body is refused" "too short" \
    "$(luks_unlock_pubkey_check 'ssh-ed25519 AAAA')"
  assert_match "a paste cut mid-body is caught too" "too short" \
    "$(luks_unlock_pubkey_check 'ssh-ed25519 AAAA C3Nza stubstubstubstubstubstubstubstubstub')"
  assert_match "a body with a non-base64 character is refused" "base64" \
    "$(luks_unlock_pubkey_check "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJTstubstubstubstub!nstubstubstubstubstubstubstub")"
  run_strict luks_unlock_pubkey_check 'not-a-key at all here'
  [ "${status}" -eq 1 ]
}

@test "luks_unlock_authorized_keys_report: counts good keys and quotes bad ones" {
  load_lib
  local root out
  root="$(make_scratch)"
  printf '# a note\n%s\n\n' "${GOOD_KEY}" >"${root}/keys"
  out="$(luks_unlock_authorized_keys_report "${root}/keys")"
  assert_eq "one key, one row, and it is good" "1" "$(printf '%s\n' "${out}" | grep -c '^ok')"
  assert_eq "the comment and the blank line were skipped" "1" "$(printf '%s\n' "${out}" | grep -c .)"
  printf '%s\n%s\n' "${GOOD_KEY}" "ssh-ed25519 short" >"${root}/mixed"
  out="$(luks_unlock_authorized_keys_report "${root}/mixed")"
  assert_eq "the good one still counts" "1" "$(printf '%s\n' "${out}" | grep -c '^ok')"
  assert_eq "the bad one is reported" "1" "$(printf '%s\n' "${out}" | grep -c '^bad')"
  out="$(luks_unlock_authorized_keys_report "${root}/absent")"
  assert_match "a missing file says dropbear will not start" "refuses to start" "${out}"
  : >"${root}/empty"
  out="$(luks_unlock_authorized_keys_report "${root}/empty")"
  assert_match "an empty file says the same" "empty" "${out}"
}

@test "luks_unlock_authorized_keys_install: writes 0600, backs up what it replaced" {
  load_lib
  local root
  root="$(make_scratch)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/id.pub"
  mkdir -p "${root}/etc/dropbear/initramfs"
  printf 'old key\n' >"${root}/etc/dropbear/initramfs/authorized_keys"
  run_strict luks_unlock_authorized_keys_install "${root}/id.pub" \
    "${root}/etc/dropbear/initramfs/authorized_keys"
  [ "${status}" -eq 0 ]
  assert_contains_file "the new key is in place" \
    "${root}/etc/dropbear/initramfs/authorized_keys" 'ssh-ed25519'
  assert_contains_file "the old key is recoverable" \
    "${root}/etc/dropbear/initramfs/authorized_keys.bak" 'old key'
  assert_eq "and the mode is owner-only" "600" \
    "$(stat -c '%a' "${root}/etc/dropbear/initramfs/authorized_keys")"
  run_strict luks_unlock_authorized_keys_install "${root}/absent" "${root}/etc/keys"
  [ "${status}" -eq 1 ]
  : >"${root}/zero"
  run_strict luks_unlock_authorized_keys_install "${root}/zero" "${root}/etc/keys"
  [ "${status}" -eq 1 ]
  assert_file_not_exists "an empty source wrote nothing" "${root}/etc/keys"
}

@test "luks_unlock_host_keys_missing: all three, some, or none" {
  load_lib
  local root
  root="$(make_scratch)"
  assert_eq "no directory is all three missing" \
    "dropbear_ed25519_host_key dropbear_ecdsa_host_key dropbear_rsa_host_key" \
    "$(luks_unlock_host_keys_missing "${root}/etc/dropbear/initramfs")"
  mkdir -p "${root}/etc/dropbear/initramfs"
  printf 'k\n' >"${root}/etc/dropbear/initramfs/dropbear_ed25519_host_key"
  assert_eq "one is enough for dropbear to start, so only the others are named" \
    "dropbear_ecdsa_host_key dropbear_rsa_host_key" \
    "$(luks_unlock_host_keys_missing "${root}/etc/dropbear/initramfs")"
  printf 'k\n' >"${root}/etc/dropbear/initramfs/dropbear_ecdsa_host_key"
  printf 'k\n' >"${root}/etc/dropbear/initramfs/dropbear_rsa_host_key"
  assert_eq "a full set misses nothing" "" \
    "$(luks_unlock_host_keys_missing "${root}/etc/dropbear/initramfs")"
}

@test "luks_unlock_dropbear_options: key-only, idle-bounded, off the sshd port" {
  load_lib
  local opts
  opts="$(luks_unlock_dropbear_options 2222 60)"
  assert_match "the port is set" '^-p 2222 ' "${opts}"
  assert_match "password logins are off" ' -s ' "${opts}"
  assert_match "a session is bounded" ' -I 60 ' "${opts}"
  assert_match "utmp and lastlog are skipped" ' -j -k$' "${opts}"
  assert_eq "and the defaults agree with the documented recipe" "-p 2222 -s -I 60 -j -k" \
    "$(LUKS_UNLOCK_DEFAULT_PORT=2222 LUKS_UNLOCK_DEFAULT_IDLE=60 luks_unlock_dropbear_options)"
}

@test "luks_unlock_dropbear_port: reads -p in both shapes, defaults without it" {
  load_lib
  local root
  root="$(make_scratch)"
  printf 'DROPBEAR_OPTIONS="-p 2222 -s"\n' >"${root}/dropbear.conf"
  assert_eq "a separated -p" "2222" "$(luks_unlock_dropbear_port "${root}/dropbear.conf")"
  printf "DROPBEAR_OPTIONS='-p2200 -s'\n" >"${root}/dropbear.conf"
  assert_eq "a glued -p" "2200" "$(luks_unlock_dropbear_port "${root}/dropbear.conf")"
  printf 'DROPBEAR_OPTIONS="-s"\n' >"${root}/dropbear.conf"
  assert_eq "no -p falls back to the default" "2222" \
    "$(luks_unlock_dropbear_port "${root}/dropbear.conf")"
  assert_eq "no file too" "2222" "$(luks_unlock_dropbear_port "${root}/absent")"
}

@test "luks_unlock_ssh_hint: points ssh at a known_hosts the installed sshd does not share" {
  load_lib
  local hint
  hint="$(luks_unlock_ssh_hint box.example 2222)"
  assert_match "the port is in the command" ' -p 2222 ' "${hint}"
  assert_match "the host is in the command" 'root@box.example$' "${hint}"
  assert_match "known_hosts is its own file" 'UserKnownHostsFile=~/.luks/known_hosts' "${hint}"
  assert_match "a first connection is not a hard stop" 'StrictHostKeyChecking=accept-new' "${hint}"
  assert_match "with no host it stays runnable as a template" 'root@<server>$' \
    "$(luks_unlock_ssh_hint '')"
}

# ── The generated initramfs ───────────────────────────────────────────────────

@test "luks_unlock_initrd_for: finds the image for one kernel version" {
  load_lib
  local root
  root="$(make_scratch)"
  mkdir -p "${root}/boot"
  printf 'x\n' >"${root}/boot/initrd.img-${KERNEL}"
  assert_eq "the Ubuntu name resolves" "${root}/boot/initrd.img-${KERNEL}" \
    "$(luks_unlock_initrd_for "${root}/boot" "${KERNEL}")"
  assert_eq "another kernel has no image here" "" \
    "$(luks_unlock_initrd_for "${root}/boot" "5.15.0-100-generic")"
  printf '' >"${root}/boot/initrd.img-5.15.0-100-generic"
  assert_eq "a zero-length image is not an image" "" \
    "$(luks_unlock_initrd_for "${root}/boot" "5.15.0-100-generic")"
}

@test "luks_unlock_initrd_list: uses lsinitramfs, falls back to lsinitrd, fails with neither" {
  load_lib
  local root out
  root="$(make_scratch)"
  printf 'bytes\n' >"${root}/initrd"
  make_list_stub "${root}/lsinitramfs"
  PATH="${root}:${PATH}"
  out="$(luks_unlock_initrd_list "${root}/initrd")"
  assert_match "the members come back" "^bin/dropbear$" "${out}"
  rm -f "${root}/lsinitramfs"
  cat >"${root}/lsinitrd" <<'STUB'
#!/bin/sh
printf 'usr/bin/cryptroot-unlock\n'
STUB
  chmod 755 "${root}/lsinitrd"
  out="$(luks_unlock_initrd_list "${root}/initrd")"
  assert_match "the other tool answers" "cryptroot-unlock" "${out}"
  rm -f "${root}/lsinitrd"
  run_strict luks_unlock_initrd_list "${root}/initrd"
  [ "${status}" -eq 1 ]
  make_list_stub "${root}/lsinitramfs"
  run_strict luks_unlock_initrd_list "${root}/nope"
  [ "${status}" -eq 1 ]
}

@test "luks_unlock_initrd_has: matches on a path boundary" {
  load_lib
  local listing
  listing="$(printf '%s\n' . bin bin/dropbear bin/dropbearkey usr/bin/cryptroot-unlock)"
  run_strict luks_unlock_initrd_has "${listing}" "bin/dropbear"
  [ "${status}" -eq 0 ]
  run_strict luks_unlock_initrd_has "${listing}" "usr/bin/cryptroot-unlock"
  [ "${status}" -eq 0 ]
  run_strict luks_unlock_initrd_has "${listing}" "bin/dropbearx"
  [ "${status}" -eq 1 ]
  run_strict luks_unlock_initrd_has "${listing}" "etc/shadow"
  [ "${status}" -eq 1 ]
  run_strict luks_unlock_initrd_has "" "bin/dropbear"
  [ "${status}" -eq 1 ]
  run_strict luks_unlock_initrd_has "${listing}" ""
  [ "${status}" -eq 1 ]
}

@test "luks_unlock_fingerprint: asks ssh-keygen, and says nothing when it cannot" {
  load_lib
  local root out
  root="$(make_scratch)"
  printf 'hostkey\n' >"${root}/dropbear_ed25519_host_key"
  make_keygen_stub "${root}/ssh-keygen"
  PATH="${root}:${PATH}"
  out="$(luks_unlock_fingerprint "${root}/dropbear_ed25519_host_key")"
  assert_match "the fingerprint comes back" "SHA256:stubbedfingerprint" "${out}"
  run_strict luks_unlock_fingerprint "${root}/absent"
  [ "${status}" -eq 1 ]
  rm -f "${root}/ssh-keygen"
  run_strict luks_unlock_fingerprint "${root}/dropbear_ed25519_host_key"
  [ "${status}" -eq 1 ]
}

# ── Entry-level helpers ───────────────────────────────────────────────────────

@test "luks_unlock_run: prints the command under --dry-run instead of running it" {
  load_lib
  load_entry luks_unlock_run
  DRY_RUN=1
  local out bin
  out="$(luks_unlock_run touch "${BATS_TEST_TMPDIR}/never-created")"
  assert_match "the command is quoted" 'would: touch' "${out}"
  assert_file_not_exists "and nothing was created" "${BATS_TEST_TMPDIR}/never-created"
  DRY_RUN=0
  bin="${BATS_TEST_TMPDIR}/priv/bin"
  mkdir -p "${bin}"
  make_sudo_stub "${bin}" 0
  out="$(PATH="${bin}:${PATH}" luks_unlock_run printf 'ran\n')"
  assert_eq "as root it runs the command itself" "ran" "${out}"
  assert_file_not_exists "and sudo was never consulted" "${BATS_TEST_TMPDIR}/sudo-log"
  make_sudo_stub "${bin}" 1000
  export SUDO_LOG="${BATS_TEST_TMPDIR}/sudo-log"
  out="$(PATH="${bin}:${PATH}" luks_unlock_run printf 'ran\n')"
  assert_eq "as a normal user the command still runs" "ran" "${out}"
  PATH="${bin}:${PATH}" luks_unlock_run touch "${BATS_TEST_TMPDIR}/via-sudo"
  assert_file_exists "and it went through sudo" "${BATS_TEST_TMPDIR}/via-sudo"
  assert_contains_file "with sudo carrying the command" "${SUDO_LOG}" '^sudo touch '
}

@test "luks_unlock_write: prints the assignment under --dry-run, writes outside it" {
  load_lib
  load_entry luks_unlock_write
  local root out
  root="$(make_scratch)"
  DRY_RUN=1
  out="$(luks_unlock_write "${root}/conf" CRYPTSETUP y)"
  assert_match "the key, value and file are named" 'set CRYPTSETUP=y in' "${out}"
  assert_file_not_exists "and the file was not created" "${root}/conf"
  DRY_RUN=0
  strict luks_unlock_write "${root}/conf" CRYPTSETUP y
  assert_contains_file "the real write lands" "${root}/conf" '^CRYPTSETUP=y$'
}

@test "luks_unlock_pick_pubkey: prefers the named file, then the conventional ones" {
  load_lib
  load_entry luks_unlock_pick_pubkey
  local root
  root="$(make_scratch)"
  HOME="${root}"
  printf '%s\n' "${GOOD_KEY}" >"${root}/chosen.pub"
  assert_eq "an explicit file wins" "${root}/chosen.pub" \
    "$(luks_unlock_pick_pubkey "${root}/chosen.pub")"
  assert_eq "an explicit file that cannot be read is not silently skipped" "" \
    "$(luks_unlock_pick_pubkey "${root}/absent.pub")"
  mkdir -p "${root}/.ssh"
  printf 'k\n' >"${root}/.ssh/id_rsa.pub"
  assert_eq "with nothing named, the conventional key is found" "${root}/.ssh/id_rsa.pub" \
    "$(luks_unlock_pick_pubkey '')"
  printf 'k\n' >"${root}/.ssh/id_ed25519.pub"
  assert_eq "and ed25519 is preferred over rsa" "${root}/.ssh/id_ed25519.pub" \
    "$(luks_unlock_pick_pubkey '')"
  rm -f "${root}/.ssh/"*.pub
  assert_eq "no key at all answers nothing" "" "$(luks_unlock_pick_pubkey '')"
}

@test "luks_unlock_privileged_cp: installs the key at 0600 or prints the intent" {
  load_lib
  load_entry luks_unlock_privileged_cp
  local root out
  root="$(make_scratch)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/id.pub"
  DRY_RUN=1
  out="$(luks_unlock_privileged_cp "${root}/id.pub" "${root}/dest/authorized_keys")"
  assert_match "the intent names both paths and the mode" 'mode 0600' "${out}"
  assert_file_not_exists "and nothing was written" "${root}/dest/authorized_keys"
  DRY_RUN=0
  run_strict luks_unlock_privileged_cp "${root}/id.pub" "${root}/dest/authorized_keys"
  [ "${status}" -eq 0 ]
  assert_eq "the real copy is owner-only" "600" \
    "$(stat -c '%a' "${root}/dest/authorized_keys")"
  : >"${root}/zero.pub"
  run_strict luks_unlock_privileged_cp "${root}/zero.pub" "${root}/dest/authorized_keys"
  [ "${status}" -eq 1 ]
}

# ── Report sections ───────────────────────────────────────────────────────────

@test "luks_unlock_check_host: a configured box is clean, a missing initrd is a blocker" {
  load_lib
  load_entry luks_unlock_check_host
  local root
  root="$(make_sysroot)"
  LUKS_UNLOCK_UNAME_R="${KERNEL}"
  luks_unlock_paths "${root}"
  capture luks_unlock_check_host
  assert_match "the distro is named" "ubuntu 24.04" "${captured}"
  assert_match "the initrd is found" "initrd.img-${KERNEL}" "${captured}"
  assert_match "and /boot is readable" "readable without a passphrase" "${captured}"
  assert_eq "with nothing failed" "0" "${SUMMARY_FAIL}"
  rm -f "${root}/boot/initrd.img-${KERNEL}"
  capture luks_unlock_check_host
  assert_match "a missing initrd is an error" "no initrd for the running kernel" "${captured}"
  assert_eq "and it was counted as a failure" "1" "${SUMMARY_FAIL}"
}

@test "luks_unlock_check_volumes: the root volume is identified, a stray keyfile blocks" {
  load_lib
  load_entry luks_unlock_check_volumes
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  capture luks_unlock_check_volumes
  assert_match "the root entry is named" "cryptroot is the root volume" "${captured}"
  assert_eq "on a box with no blockers" "0" "${SUMMARY_FAIL}"
  printf 'cryptroot /dev/sda2 /etc/keys/root.key luks,discard\n' >"${root}/etc/crypttab"
  SUMMARY_FAIL=0
  capture luks_unlock_check_volumes
  assert_match "an uncovered keyfile blocks the reboot" "KEYFILE_PATTERN" "${captured}"
  assert_eq "and is counted" "1" "${SUMMARY_FAIL}"
  printf 'KEYFILE_PATTERN="/etc/keys/*.key"\n' >>"${root}/etc/cryptsetup-initramfs/conf-hook"
  SUMMARY_FAIL=0
  capture luks_unlock_check_volumes
  assert_eq "the pattern clears it" "0" "${SUMMARY_FAIL}"
}

@test "luks_unlock_check_volumes: no crypttab entry and no mapper root are both blockers" {
  load_lib
  load_entry luks_unlock_check_volumes
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  : >"${root}/etc/crypttab"
  SUMMARY_FAIL=0
  capture luks_unlock_check_volumes
  assert_match "an empty crypttab says there is nothing to unlock" \
    "names no encrypted volume" "${captured}"
  [ "${SUMMARY_FAIL}" -ge 1 ]
  printf 'cryptroot /dev/sda2 none luks,discard\n' >"${root}/etc/crypttab"
  printf 'UUID=abcd / ext4 defaults 0 1\n' >"${root}/etc/fstab"
  SUMMARY_FAIL=0
  capture luks_unlock_check_volumes
  assert_match "a root no mapper backs is named" "mounts / from no /dev/mapper" "${captured}"
  assert_eq "as a failure" "1" "${SUMMARY_FAIL}"
}

@test "luks_unlock_check_initramfs: catches the settings that make a box unreachable" {
  load_lib
  load_entry luks_unlock_check_initramfs
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  capture luks_unlock_check_initramfs
  assert_match "the clean box reads clean" "takes an address over DHCP" "${captured}"
  assert_match "the package is present" "cryptsetup-initramfs is installed" "${captured}"
  assert_eq "with nothing failed" "0" "${SUMMARY_FAIL}"

  printf '# nothing here\n' >"${root}/etc/cryptsetup-initramfs/conf-hook"
  capture luks_unlock_check_initramfs
  assert_match "CRYPTSETUP unset is a blocker" "has no CRYPTSETUP=y" "${captured}"

  printf 'CRYPTSETUP=y\n' >"${root}/etc/cryptsetup-initramfs/conf-hook"
  printf 'HOOKS="base udev autodisk modctl keymap"\n' >"${root}/etc/initramfs-tools/initramfs.conf"
  capture luks_unlock_check_initramfs
  assert_match "a HOOKS list missing net is a blocker" "HOOKS leaves out" "${captured}"
  assert_match "and it names the hooks" "dropbear" "${captured}"

  printf 'HOOKS="base udev cryptroot cryptroot-unlock net dropbear"\n' \
    >"${root}/etc/initramfs-tools/initramfs.conf"
  rm -f "${root}/etc/initramfs-tools/conf.d/zz-luks-unlock"
  capture luks_unlock_check_initramfs
  assert_match "no address at all is a blocker" "no initramfs address" "${captured}"

  rm -f "${root}/usr/share/cryptsetup/initramfs/bin/cryptroot-unlock"
  capture luks_unlock_check_initramfs
  assert_match "a box without the package is a blocker" "cryptsetup-initramfs is not installed" "${captured}"
}

@test "luks_unlock_check_initramfs: MODULES=dep and a bogus pinned interface are reported" {
  load_lib
  load_entry luks_unlock_check_initramfs
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  printf 'MODULES=dep\nHOOKS="base cryptroot cryptroot-unlock net dropbear"\n' \
    >"${root}/etc/initramfs-tools/initramfs.conf"
  SUMMARY_WARN=0
  capture luks_unlock_check_initramfs
  assert_match "dep is a warning that names the fix" "/etc/initramfs-tools/modules" "${captured}"
  assert_eq "as a warning, not a blocker" "1" "${SUMMARY_WARN}"
  UNLOCK_IFACE=ens3
  capture luks_unlock_check_initramfs
  assert_match "a real interface is confirmed" "pinned interface ens3 exists" "${captured}"
  UNLOCK_IFACE=nosuch0
  SUMMARY_FAIL=0
  capture luks_unlock_check_initramfs
  assert_match "an invented one blocks the reboot" "no interface nosuch0" "${captured}"
  assert_eq "as a failure" "1" "${SUMMARY_FAIL}"
}

@test "luks_unlock_check_dropbear: empty, broken, and absent keys are three different answers" {
  load_lib
  load_entry luks_unlock_check_dropbear
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  capture luks_unlock_check_dropbear
  assert_match "a good key is counted" "1 authorized key" "${captured}"
  assert_match "the port is reported" "listens on port 2222" "${captured}"
  assert_eq "with nothing failed" "0" "${SUMMARY_FAIL}"

  : >"${root}/etc/dropbear/initramfs/authorized_keys"
  SUMMARY_FAIL=0
  capture luks_unlock_check_dropbear
  assert_match "an empty file blocks the reboot" "refuses to start" "${captured}"

  printf '%s\nssh-ed25519 AAAA\n' "${GOOD_KEY}" >"${root}/etc/dropbear/initramfs/authorized_keys"
  SUMMARY_FAIL=0
  capture luks_unlock_check_dropbear
  assert_match "a broken line beside a good one blocks it too" "broken line" "${captured}"

  rm -f "${root}/etc/dropbear/initramfs/authorized_keys"
  SUMMARY_FAIL=0
  capture luks_unlock_check_dropbear
  assert_match "and so does its absence" "no authorized_keys file" "${captured}"

  rm -f "${root}/usr/share/initramfs-tools/hooks/dropbear"
  SUMMARY_FAIL=0
  capture luks_unlock_check_dropbear
  assert_match "the missing package is named" "dropbear-initramfs is not installed" "${captured}"
}

@test "luks_unlock_check_dropbear: sharing the sshd port is a warning with a reason" {
  load_lib
  load_entry luks_unlock_check_dropbear
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  printf 'DROPBEAR_OPTIONS="-p 22 -s"\n' >"${root}/etc/dropbear/initramfs/dropbear.conf"
  capture luks_unlock_check_dropbear
  assert_match "the collision is called out" "same port the installed sshd uses" "${captured}"
  assert_eq "as a warning, not a blocker" "1" "${SUMMARY_WARN}"
  assert_eq "with no failure recorded" "0" "${SUMMARY_FAIL}"
}

@test "luks_unlock_check_initrd: proves the unlock path is inside the image" {
  load_lib
  load_entry luks_unlock_check_initrd
  local root
  root="$(make_sysroot)"
  luks_unlock_paths "${root}"
  LUKS_UNLOCK_UNAME_R="${KERNEL}"
  PATH="${root}/bin:${PATH}"
  capture luks_unlock_check_initrd
  assert_match "the server is there" "holds the SSH server" "${captured}"
  assert_match "the unlock command is there" "holds cryptroot-unlock" "${captured}"
  assert_match "and the key is there" "authorized key was packed" "${captured}"
  assert_eq "with nothing failed" "0" "${SUMMARY_FAIL}"

  cat >"${root}/bin/lsinitramfs" <<'STUB'
#!/bin/sh
printf '%s\n' bin bin/busybox etc
STUB
  chmod 755 "${root}/bin/lsinitramfs"
  SUMMARY_FAIL=0
  capture luks_unlock_check_initrd
  assert_match "a server-less image is a blocker" "no bin/dropbear" "${captured}"
  assert_match "as is a missing unlock command" "no cryptroot-unlock" "${captured}"
  assert_match "and a missing key" "no authorized key was packed" "${captured}"
  assert_eq "all three recorded" "3" "${SUMMARY_FAIL}"

  rm -f "${root}/bin/lsinitramfs"
  SUMMARY_FAIL=0
  capture luks_unlock_check_initrd
  assert_match "an unlistable image warns instead of claiming" "could not be listed" "${captured}"
  assert_eq "and warns rather than fails" "0" "${SUMMARY_FAIL}"
}

@test "luks_unlock_verdict: a clean report says reboot, a blocked one says do not" {
  load_lib
  load_entry luks_unlock_verdict
  SUMMARY_FAIL=0
  capture luks_unlock_verdict box.example
  assert_match "a clean box is cleared to reboot" "unlocked from a laptop after a reboot" "${captured}"
  assert_match "and handed the ssh command" "ssh -o UserKnownHostsFile" "${captured}"
  assert_match "with the command to type once inside" "cryptroot-unlock" "${captured}"
  assert_match "and a summary line" "^summary:" "${captured}"
  SUMMARY_FAIL=2
  run luks_unlock_verdict box.example
  assert_match "a blocked box is told to stop" "do not reboot yet" "${output}"
  assert_match "with the count" "2 blocker" "${output}"
  assert_match "and the command that fixes it" "install --pubkey" "${output}"
  [ "${status}" -eq 1 ]
}

@test "luks_unlock_check: a fully configured box answers 0 and a broken one answers 1" {
  run_cli "$(make_sysroot)" check
  [ "${status}" -eq 0 ]
  assert_match "the report opened with the host" "== Host ==" "${output}"
  assert_match "walked to the verdict" "== Verdict ==" "${output}"
  assert_match "cleared the reboot" "unlocked from a laptop after a reboot" "${output}"
  assert_match "and counted its findings" "^summary: " "${output}"
  assert_match "naming each kind of line" "0 failed" "${output}"
}

@test "luks_unlock_check: every section is printed even when the first one fails" {
  local root
  root="$(make_sysroot)"
  : >"${root}/etc/crypttab"
  rm -f "${root}/etc/dropbear/initramfs/authorized_keys" \
    "${root}/etc/cryptsetup-initramfs/conf-hook"
  run_cli "${root}" check
  [ "${status}" -eq 1 ]
  assert_match "volumes were still examined" "== Volumes ==" "${output}"
  assert_match "the initramfs too" "== Initramfs ==" "${output}"
  assert_match "dropbear too" "== Initramfs SSH ==" "${output}"
  assert_match "the image too" "== Generated initramfs ==" "${output}"
  assert_match "and the reason is summed up" "do not reboot yet" "${stderr}"
  assert_match "with the failing items listed" "  failed: " "${output}"
}

@test "luks_unlock_install: writes every file the check reads, in dry-run only printing" {
  local root
  root="$(make_sysroot)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/key.pub"
  run_cli "${root}" install --dry-run --port 2200 --idle 30
  [ "${status}" -eq 0 ]
  assert_match "the packages are named" \
    'would: apt-get install -y cryptsetup-initramfs dropbear-initramfs' "${output}"
  assert_match "the cryptsetup switch" 'would: set CRYPTSETUP=y' "${output}"
  assert_match "the generator drop-in" 'would: set DROPBEAR=y' "${output}"
  assert_match "the network" 'would: set IP=dhcp' "${output}"
  assert_match "the restrictive umask" 'would: set UMASK=0077' "${output}"
  assert_match "the port and the idle timeout" 'DROPBEAR_OPTIONS=-p 2200 -s -I 30 -j -k' "${output}"
  assert_match "the key placement" 'mode 0600' "${output}"
  assert_match "and one regeneration for every kernel" 'would: update-initramfs -u -k all' "${output}"
  assert_match "and it still closes with the verdict" "== Verdict ==" "${output}"
}

@test "luks_unlock_install: writes for real, and the check it ends with passes" {
  local root
  root="$(make_sysroot)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/key.pub"
  rm -f "${root}/etc/cryptsetup-initramfs/conf-hook" \
    "${root}/etc/initramfs-tools/conf.d/zz-luks-unlock" \
    "${root}/etc/dropbear/initramfs/authorized_keys" \
    "${root}/etc/dropbear/initramfs/dropbear.conf"
  run_cli_write "${root}" install --no-pkgs --no-regenerate
  [ "${status}" -eq 0 ]
  assert_contains_file "the cryptsetup hook file was created" \
    "${root}/etc/cryptsetup-initramfs/conf-hook" '^CRYPTSETUP=y$'
  assert_contains_file "the drop-in carries DROPBEAR" \
    "${root}/etc/initramfs-tools/conf.d/zz-luks-unlock" '^DROPBEAR=y$'
  assert_contains_file "and the address" \
    "${root}/etc/initramfs-tools/conf.d/zz-luks-unlock" '^IP=dhcp$'
  assert_contains_file "and the restrictive umask" \
    "${root}/etc/initramfs-tools/conf.d/zz-luks-unlock" '^UMASK=0077$'
  assert_contains_file "the SSH options carry the port" \
    "${root}/etc/dropbear/initramfs/dropbear.conf" 'DROPBEAR_OPTIONS=-p 2222 '
  assert_contains_file "the key landed" "${root}/etc/dropbear/initramfs/authorized_keys" \
    'ssh-ed25519'
  assert_eq "at owner-only mode" "600" \
    "$(stat -c '%a' "${root}/etc/dropbear/initramfs/authorized_keys")"
  assert_match "the closing check cleared the reboot" "unlocked from a laptop after a reboot" "${output}"
}

@test "luks_unlock_install: keeps an operator's own DROPBEAR_OPTIONS" {
  local root
  root="$(make_sysroot)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/key.pub"
  printf 'DROPBEAR_OPTIONS="-p 2201 -s"\n' >"${root}/etc/dropbear/initramfs/dropbear.conf"
  run_cli_write "${root}" install --no-pkgs --no-regenerate
  [ "${status}" -eq 0 ]
  assert_contains_file "the hand-written options were left alone" \
    "${root}/etc/dropbear/initramfs/dropbear.conf" 'DROPBEAR_OPTIONS="-p 2201 -s"'
  assert_match "and the report says so" "left as the operator wrote it" "${output}"
}

@test "luks_unlock_install: a missing public key is an error, not an open door" {
  local root
  root="$(make_sysroot)"
  rm -f "${root}/key.pub" "${root}/etc/dropbear/initramfs/authorized_keys"
  run --separate-stderr env -u CI -u LUKS_UNLOCK_DRY_RUN \
    PATH="${root}/bin:/usr/local/bin:/usr/bin:/bin" \
    LUKS_ROOT="${root}" LUKS_UNLOCK_UNAME_R="${KERNEL}" HOME="${root}" \
    bash "${SCRIPT}" install --no-pkgs --no-regenerate
  [ "${status}" -eq 1 ]
  assert_match "the reason names the flag that fixes it" "LUKS_UNLOCK_PUBKEY_FILE" "${stderr}"
  assert_file_not_exists "and no key file was invented" \
    "${root}/etc/dropbear/initramfs/authorized_keys"
}

@test "luks_unlock_install: --no-regenerate says the image is the old one" {
  local root
  root="$(make_sysroot)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/key.pub"
  run_cli "${root}" install --dry-run --no-pkgs --no-regenerate
  [ "${status}" -eq 0 ]
  assert_match "the skipped regeneration is said out loud" "not rebuilt" "${output}"
  assert_not_match "and update-initramfs was not printed" 'would: update-initramfs' "${output}"
}

@test "luks_unlock_install: merges the hooks it needs into an existing HOOKS list" {
  local root
  root="$(make_sysroot)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/key.pub"
  printf 'HOOKS="base udev autodisk modctl keymap"\n' >"${root}/etc/initramfs-tools/initramfs.conf"
  run_cli "${root}" install --dry-run --no-pkgs
  assert_match "the merged list is proposed" \
    'would: set HOOKS=base udev autodisk modctl keymap cryptroot cryptroot-unlock net dropbear' "${output}"
}

@test "luks_unlock_install: leaves an unrestricted HOOKS list alone" {
  local root
  root="$(make_sysroot)"
  printf '%s\n' "${GOOD_KEY}" >"${root}/key.pub"
  sed -i '/^HOOKS=/d' "${root}/etc/initramfs-tools/initramfs.conf"
  run_cli "${root}" install --dry-run --no-pkgs
  assert_not_match "no HOOKS line was proposed" 'would: set HOOKS=' "${output}"
}

@test "luks_unlock_fingerprint_cmd: prints each host key, or says there are none" {
  local root
  root="$(make_sysroot)"
  run_cli "${root}" fingerprint
  [ "${status}" -eq 0 ]
  assert_match "the stubbed fingerprint came back" "SHA256:stubbedfingerprint" "${output}"
  assert_match "and the port to expect is named" "port 2222" "${output}"

  rm -f "${root}"/etc/dropbear/initramfs/dropbear_*_host_key
  run_cli "${root}" fingerprint
  [ "${status}" -eq 0 ]
  assert_match "an empty keyring is reported, not fatal" "no host key to fingerprint" "${output}"
}

# ── Argument handling ─────────────────────────────────────────────────────────

@test "luks-unlock: the default verb is check, and --help is exit 0" {
  local root
  root="$(make_sysroot)"
  run_cli "${root}"
  [ "${status}" -eq 0 ]
  assert_match "the report ran" "== Verdict ==" "${output}"
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "the help names the verbs" "fingerprint  print the initramfs host key" "${output}"
  assert_match "and the one thing it never does" "Nothing here reboots the box" "${output}"
}

@test "luks-unlock: a bad flag, a bad port, and a bad --ip are all refused" {
  run --separate-stderr bash "${SCRIPT}" --bogus
  [ "${status}" -eq 1 ]
  assert_match "the bad flag is named" "unknown argument --bogus" "${stderr}"

  local root
  root="$(make_sysroot)"
  run_cli "${root}" check --port 99999
  [ "${status}" -eq 1 ]
  assert_match "an out-of-range port is refused" "outside 1-65535" "${stderr}"

  run_cli "${root}" check --port abc
  [ "${status}" -eq 1 ]
  assert_match "a non-numeric port is refused" "wants a number" "${stderr}"

  run_cli "${root}" install --ip 10.0.0.5
  [ "${status}" -eq 1 ]
  assert_match "a spec without its colons is refused" "needs the colons" "${stderr}"

  run_cli "${root}" check --port
  [ "${status}" -eq 1 ]
  assert_match "a flag with no value is refused" "--port needs a number" "${stderr}"
}

@test "luks-unlock: check never writes, whatever the box looks like" {
  local root before after
  root="$(make_sysroot)"
  before="$(find "${root}" -type f -printf '%p %s\n' | sort)"
  run_cli "${root}" check
  [ "${status}" -eq 0 ]
  after="$(find "${root}" -type f -printf '%p %s\n' | sort)"
  assert_eq "the tree is byte-for-byte what it was" "${before}" "${after}"
}
