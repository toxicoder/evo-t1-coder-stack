#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## host_state.sh - host DNS diagnosis and leftover-runfiles repair (sourced;
# never executed).
#
# Two host problems show up right after a git pull and a stack `up`, and neither
# is a compose bug:
#
#   - Docker (and Kasm's privileged nested dockerd) can leave bind-mounted
#     payload files in Bazel's runfiles tree owned by root, or replace a file
#     with a directory. The next `bazelisk run //scripts:prod-stack` then dies
#     creating that runfiles tree (`FileAccessException ... Permission denied`
#     on homepage/assets/icons/evo-t1.svg is the usual spelling).
#   - This box also runs Tailscale MagicDNS. When `/etc/resolv.conf` names only
#     100.100.100.100, a Docker/Kasm iptables change that makes that stub
#     unreachable takes out ALL host DNS, including github.com, so `git pull`
#     prints `Could not resolve host: github.com`. The same forwarding is what
#     made `terraform init` inside the coder container SERVFAIL
#     registry.terraform.io (`lookup … on 127.0.0.11:53: server misbehaving`).
#     Compose pins public resolvers on the coder service (and the templates
#     pin the same pair on workspace/DinD containers) so a template push does
#     not wait on this host fix. `setup-host --repair` is what repairs the
#     host resolver itself: a systemd-resolved drop-in (1.1.1.1 / 8.8.8.8)
#     plus `tailscale set --accept-dns=false`, with MagicDNS kept for `ts.net`
#     via a resolved split-DNS binding when resolvectl is present.
#
# These helpers diagnose both, repair the runfiles leftover, and (on Linux)
# install that public-DNS pair. `--check` still writes nothing. Test seams:
# SETUP_SKIP_DNS=1, SETUP_DNS_DRY_RUN=1, SETUP_DNS_OS, SETUP_DNS_LOOKUP,
# SETUP_RESOLV_CONF, SETUP_RESOLVED_DROPIN.
#
# Usage (from an entry script, after `set -euo pipefail`):
#   # shellcheck source=lib/host_state.sh disable=SC1091
#   source "${SELF_DIR}/lib/host_state.sh"

if ! declare -f log >/dev/null 2>&1; then
  SELF_DIR="${SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  # shellcheck source=common.sh disable=SC1091
  source "${SELF_DIR}/common.sh"
fi

# _HOST_STATE_DIR - this lib's directory, so the python fallback is found by
# absolute path and never by the caller's cwd.
_HOST_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# MAGICDNS_NS - Tailscale's on-box resolver. When it is the only nameserver,
# every lookup (github.com included) dies the moment the stub is unreachable.
MAGICDNS_NS='100.100.100.100'

# PUBLIC_DNS_PRIMARY / PUBLIC_DNS_SECONDARY - the pair --repair installs so
# github.com still resolves when MagicDNS is unreachable. Same addresses the
# coder compose service uses as Docker's embedded-DNS upstream.
PUBLIC_DNS_PRIMARY='1.1.1.1'
PUBLIC_DNS_SECONDARY='8.8.8.8'

# RESOLVED_DROPIN_DEFAULT - systemd-resolved drop-in --repair writes. Named
# so an operator can find it; not a Tailscale file, so accept-dns=false does
# not remove it.
RESOLVED_DROPIN_DEFAULT='/etc/systemd/resolved.conf.d/evo-t1-public-dns.conf'

# @function host_nameservers
# Print the nameserver addresses from a resolv.conf, one per line.
# Globals:
#   None
# Arguments:
#   $1 - resolv.conf path (default /etc/resolv.conf)
# Outputs:
#   One address per line; nothing when the file is absent
# Returns:
#   0, always
host_nameservers() {
  local file="${1:-/etc/resolv.conf}"
  if [[ ! -f ${file} ]]; then
    return 0
  fi
  sed -nE 's/^[[:space:]]*nameserver[[:space:]]+([^[:space:]#]+).*/\1/p' "${file}"
  return 0
}

# @function host_dns_kind
# Classify a resolv.conf by how it will fail when Docker or Tailscale fights it.
# Globals:
#   MAGICDNS_NS
# Arguments:
#   $1 - resolv.conf path (default /etc/resolv.conf)
# Outputs:
#   One word: magicdns-only, stub, mixed, empty or other
# Returns:
#   0, always
host_dns_kind() {
  local file="${1:-/etc/resolv.conf}" ns="" magic=0 other=0 stub=0
  while IFS= read -r ns; do
    [[ -n ${ns} ]] || continue
    case "${ns}" in
      "${MAGICDNS_NS}" | fd7a:115c:a1e0::53) magic=1 ;;
      127.0.0.53 | 127.0.0.54) stub=1 ;;
      *) other=1 ;;
    esac
  done <<<"$(host_nameservers "${file}")"
  if [[ ${magic} -eq 1 && ${other} -eq 0 && ${stub} -eq 0 ]]; then
    printf 'magicdns-only\n'
  elif [[ ${stub} -eq 1 && ${magic} -eq 0 && ${other} -eq 0 ]]; then
    printf 'stub\n'
  elif [[ ${magic} -eq 1 || ${stub} -eq 1 ]] && [[ ${other} -eq 1 ]]; then
    printf 'mixed\n'
  elif [[ ${magic} -eq 0 && ${stub} -eq 0 && ${other} -eq 0 ]]; then
    printf 'empty\n'
  else
    printf 'other\n'
  fi
  return 0
}

# @function host_can_resolve
# Succeed when the host resolver returns at least one address for a name.
# Globals:
#   SETUP_DNS_LOOKUP - 1 force success, 0 force failure; unset uses the resolver
# Arguments:
#   $1 - hostname (default github.com)
# Outputs:
#   Nothing
# Returns:
#   0 when a lookup returned a line, 1 otherwise
host_can_resolve() {
  local name="${1:-github.com}"
  case "${SETUP_DNS_LOOKUP:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if command -v getent >/dev/null 2>&1; then
    [[ -n $(getent hosts "${name}" 2>/dev/null | head -n 1) ]]
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 "${_HOST_STATE_DIR}/host_resolve.py" "${name}" 2>/dev/null
    return
  fi
  return 1
}

# @function host_dns_report
# Print whether github.com resolves, and when it does not, name the usual
# cause on this box (Tailscale MagicDNS as the only nameserver, then Docker
# or Kasm making 100.100.100.100 unreachable).
# Globals:
#   MAGICDNS_NS, PUBLIC_DNS_PRIMARY, PUBLIC_DNS_SECONDARY, RESOLVED_DROPIN_DEFAULT
# Arguments:
#   $1 - resolv.conf path (default /etc/resolv.conf)
#   $2 - hostname to probe (default github.com)
# Outputs:
#   One or more diagnosis lines
# Returns:
#   0 when the name resolved, 1 when it did not
host_dns_report() {
  local file="${1:-/etc/resolv.conf}" name="${2:-github.com}" kind=""
  kind="$(host_dns_kind "${file}")"
  if host_can_resolve "${name}"; then
    log "dns: ${name} resolves (${kind})"
    return 0
  fi
  warn "dns: ${name} did not resolve (${kind}) — git pull over https://${name} will fail with 'Could not resolve host'"
  case "${kind}" in
    magicdns-only)
      note "Tailscale MagicDNS (${MAGICDNS_NS}) is the only nameserver in ${file}." \
        "Docker's iptables (and Kasm's privileged nested dockerd) can make that stub" \
        "unreachable; when it is, every lookup dies, not just tailnet names."
      note "Repair with: bash scripts/setup-host.sh --repair"
      note "That writes ${RESOLVED_DROPIN_DEFAULT} (${PUBLIC_DNS_PRIMARY} ${PUBLIC_DNS_SECONDARY})" \
        "and runs: sudo tailscale set --accept-dns=false"
      ;;
    empty)
      note "${file} lists no nameserver. Restore one (LAN resolver, 1.1.1.1, or Tailscale MagicDNS) and retry."
      ;;
    *)
      note "Check ${file} and that UDP/53 to its nameserver still works after docker compose up."
      ;;
  esac
  return 1
}

# @function public_dns_servers
# Print the public resolvers --repair installs, one per line.
# Globals:
#   PUBLIC_DNS_PRIMARY, PUBLIC_DNS_SECONDARY
# Arguments:
#   None
# Outputs:
#   Two nameserver addresses
# Returns:
#   0, always
public_dns_servers() {
  printf '%s\n' "${PUBLIC_DNS_PRIMARY}" "${PUBLIC_DNS_SECONDARY}"
  return 0
}

# @function resolved_dropin_body
# Print the systemd-resolved drop-in that names the public resolvers.
# Globals:
#   PUBLIC_DNS_PRIMARY, PUBLIC_DNS_SECONDARY
# Arguments:
#   None
# Outputs:
#   A [Resolve] unit fragment
# Returns:
#   0, always
resolved_dropin_body() {
  printf '%s\n' \
    '# Written by evo-t1-coder-stack setup-host --repair.' \
    '# Public resolvers so github.com still resolves when Tailscale MagicDNS is unreachable.' \
    '[Resolve]' \
    "DNS=${PUBLIC_DNS_PRIMARY} ${PUBLIC_DNS_SECONDARY}" \
    'FallbackDNS=8.8.4.4 1.0.0.1'
  return 0
}

# @function host_has_public_nameserver
# Succeed when resolv.conf already lists a nameserver that is not MagicDNS
# or the systemd stub.
# Globals:
#   MAGICDNS_NS
# Arguments:
#   $1 - resolv.conf path (default /etc/resolv.conf)
# Outputs:
#   Nothing
# Returns:
#   0 when a public nameserver is present, 1 otherwise
host_has_public_nameserver() {
  local file="${1:-/etc/resolv.conf}" ns=""
  while IFS= read -r ns; do
    [[ -n ${ns} ]] || continue
    case "${ns}" in
      "${MAGICDNS_NS}" | fd7a:115c:a1e0::53 | 127.0.0.53 | 127.0.0.54) continue ;;
      *) return 0 ;;
    esac
  done <<<"$(host_nameservers "${file}")"
  return 1
}

# @function write_resolved_dropin
# Write the systemd-resolved drop-in at $1. Uses sudo only when the path is
# not writable.
# Globals:
#   PUBLIC_DNS_PRIMARY, PUBLIC_DNS_SECONDARY
# Arguments:
#   $1 - drop-in path
#   $2 - 1 to use sudo when the path is not writable (default 0)
# Outputs:
#   One line when the file is written
# Returns:
#   0 when the file is written, 1 otherwise
write_resolved_dropin() {
  local dest="${1:-}" use_sudo="${2:-0}" parent=""
  [[ -n ${dest} ]] || return 1
  parent="$(dirname "${dest}")"
  if [[ ! -d ${parent} ]]; then
    mkdir -p "${parent}" 2>/dev/null || true
    if [[ ! -d ${parent} && ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
      sudo mkdir -p "${parent}" 2>/dev/null || true
    fi
  fi
  if resolved_dropin_body >"${dest}" 2>/dev/null; then
    log "wrote ${dest} (public DNS ${PUBLIC_DNS_PRIMARY} ${PUBLIC_DNS_SECONDARY})"
    return 0
  fi
  if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
    if resolved_dropin_body | sudo tee "${dest}" >/dev/null; then
      log "wrote ${dest} (public DNS ${PUBLIC_DNS_PRIMARY} ${PUBLIC_DNS_SECONDARY})"
      return 0
    fi
  fi
  warn "cannot write ${dest} — re-run: bash scripts/setup-host.sh --repair"
  return 1
}

# @function append_public_nameservers
# Append the public resolvers to a regular-file resolv.conf that still has
# none. A symlink (systemd-resolved stub) is left alone.
# Globals:
#   PUBLIC_DNS_PRIMARY, PUBLIC_DNS_SECONDARY
# Arguments:
#   $1 - resolv.conf path
#   $2 - 1 to use sudo when the file is not writable (default 0)
# Outputs:
#   One line when the file is changed
# Returns:
#   0 when a public nameserver is present, the path is a symlink, or the
#   file is absent; 1 when append failed
append_public_nameservers() {
  local file="${1:-}" use_sudo="${2:-0}"
  [[ -n ${file} ]] || return 1
  if [[ ! -f ${file} || -L ${file} ]]; then
    return 0
  fi
  if host_has_public_nameserver "${file}"; then
    return 0
  fi
  if printf 'nameserver %s\nnameserver %s\n' \
    "${PUBLIC_DNS_PRIMARY}" "${PUBLIC_DNS_SECONDARY}" >>"${file}" 2>/dev/null; then
    log "appended public nameservers to ${file}"
    return 0
  fi
  if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
    if printf 'nameserver %s\nnameserver %s\n' \
      "${PUBLIC_DNS_PRIMARY}" "${PUBLIC_DNS_SECONDARY}" |
      sudo tee -a "${file}" >/dev/null; then
      log "appended public nameservers to ${file}"
      return 0
    fi
  fi
  warn "cannot append nameservers to ${file} — re-run: bash scripts/setup-host.sh --repair"
  return 1
}

# @function ensure_host_public_dns
# On Linux, install public resolvers beside Tailscale MagicDNS so github.com
# still resolves when 100.100.100.100 is unreachable. Writes a systemd-resolved
# drop-in, runs `tailscale set --accept-dns=false`, and binds MagicDNS to
# ts.net via resolvectl when present. Darwin is a no-op.
# Globals:
#   SETUP_SKIP_DNS, SETUP_DNS_DRY_RUN, SETUP_DNS_OS, MAGICDNS_NS,
#   PUBLIC_DNS_PRIMARY, PUBLIC_DNS_SECONDARY, RESOLVED_DROPIN_DEFAULT
# Arguments:
#   $1 - resolv.conf path (default /etc/resolv.conf)
#   $2 - systemd-resolved drop-in path (default RESOLVED_DROPIN_DEFAULT)
#   $3 - 1 to use sudo (default 0)
# Outputs:
#   Diagnosis and repair lines
# Returns:
#   0 when github.com resolves (or the OS is not Linux, or SETUP_SKIP_DNS=1);
#   1 when the lookup still fails after the repair
ensure_host_public_dns() {
  local file="${1:-/etc/resolv.conf}"
  local dropin="${2:-${RESOLVED_DROPIN_DEFAULT}}"
  local use_sudo="${3:-0}"
  local os="" kind="" dry_run=0 ts=() resolved=() rctl=()

  if [[ ${SETUP_SKIP_DNS:-0} == "1" ]]; then
    return 0
  fi

  os="${SETUP_DNS_OS:-$(uname -s)}"
  case "${os}" in
    Linux) ;;
    *)
      note "host public DNS repair is Linux-only (this host is ${os}); --check still reports."
      host_dns_report "${file}" github.com || true
      return 0
      ;;
  esac

  kind="$(host_dns_kind "${file}")"
  if [[ ${kind} != "magicdns-only" && ${kind} != "empty" ]] && host_can_resolve github.com; then
    log "dns: github.com resolves (${kind}); public DNS repair not needed"
    return 0
  fi

  if [[ -n ${SETUP_DNS_DRY_RUN:-} ]]; then
    dry_run=1
  fi

  log "dns: installing public resolvers (${PUBLIC_DNS_PRIMARY} ${PUBLIC_DNS_SECONDARY}) beside MagicDNS"
  if ! write_resolved_dropin "${dropin}" "${use_sudo}"; then
    host_dns_report "${file}" github.com || true
    return 1
  fi

  if [[ ${dry_run} -eq 1 ]]; then
    log "would: tailscale set --accept-dns=false"
    log "would: systemctl restart systemd-resolved"
    log "would: resolvectl dns tailscale0 ${MAGICDNS_NS}"
    log "would: resolvectl domain tailscale0 ts.net"
    log "would: resolvectl default-route tailscale0 false"
  else
    if command -v tailscale >/dev/null 2>&1; then
      ts=(tailscale)
      if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
        ts=(sudo tailscale)
      fi
      if "${ts[@]}" set --accept-dns=false; then
        log "tailscale set --accept-dns=false"
      else
        warn "tailscale set --accept-dns=false failed"
      fi
    else
      note "tailscale is not on PATH; run: sudo tailscale set --accept-dns=false"
    fi
    if command -v systemctl >/dev/null 2>&1; then
      resolved=(systemctl)
      if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
        resolved=(sudo systemctl)
      fi
      "${resolved[@]}" restart systemd-resolved 2>/dev/null || true
    fi
    if command -v resolvectl >/dev/null 2>&1; then
      rctl=(resolvectl)
      if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
        rctl=(sudo resolvectl)
      fi
      "${rctl[@]}" dns tailscale0 "${MAGICDNS_NS}" 2>/dev/null || true
      "${rctl[@]}" domain tailscale0 ts.net 2>/dev/null || true
      "${rctl[@]}" default-route tailscale0 false 2>/dev/null || true
    fi
    append_public_nameservers "${file}" "${use_sudo}" || true
  fi

  if host_can_resolve github.com; then
    log "dns: github.com resolves after public DNS repair"
    return 0
  fi
  host_dns_report "${file}" github.com || true
  return 1
}

# @function runfiles_relpath
# Print the checkout-relative path encoded in a Bazel runfiles payload path,
# or the path relative to $2 when it is not a runfiles path.
# Globals:
#   None
# Arguments:
#   $1 - absolute path
#   $2 - repo root (used when $1 is under the checkout rather than runfiles)
# Outputs:
#   A relative path such as homepage/assets/icons/evo-t1.svg
# Returns:
#   0, always
runfiles_relpath() {
  local path="${1:-}" root="${2:-}"
  case "${path}" in
    *.runfiles/_main/*)
      # Bazel names the tree <target>.runfiles/_main/<payload>, not a
      # directory called runfiles. Strip that prefix so the leftover maps
      # onto the checkout file Docker replaced with a directory.
      printf '%s\n' "${path##*.runfiles/_main/}"
      ;;
    *)
      if [[ -n ${root} && ${path} == "${root}"/* ]]; then
        printf '%s\n' "${path#"${root}"/}"
      else
        printf '%s\n' "${path##*/}"
      fi
      ;;
  esac
  return 0
}

# @function stale_runfiles_paths
# Print leftover payload paths Bazel cannot recreate: runfiles copies of
# homepage/ and proxy/, plus checkout copies of those trees that this user
# cannot write. Read-only.
# Globals:
#   None
# Arguments:
#   $1 - repo root (the checkout; bazel-out is read as a symlink beside it)
# Outputs:
#   One absolute path per line
# Returns:
#   0, always
stale_runfiles_paths() {
  local root="${1:-}" out="" tree="" path="" rel="" src="" payload="" payload_root=""
  [[ -n ${root} && -d ${root} ]] || return 0
  out="${root}/bazel-out"
  if [[ -d ${out} ]]; then
    while IFS= read -r tree; do
      [[ -n ${tree} ]] || continue
      for payload in homepage proxy; do
        payload_root="${tree}/_main/${payload}"
        [[ -e ${payload_root} ]] || continue
        while IFS= read -r path; do
          [[ -n ${path} ]] || continue
          rel="$(runfiles_relpath "${path}" "${root}")"
          src="${root}/${rel}"
          if [[ -d ${path} && -f ${src} ]]; then
            printf '%s\n' "${path}"
            continue
          fi
          if [[ ! -w ${path} ]]; then
            printf '%s\n' "${path}"
          fi
        done < <(find "${payload_root}" -mindepth 0 -print 2>/dev/null || true)
      done
    done < <(find "${out}" -type d -name '*.runfiles' 2>/dev/null || true)
  fi
  for path in "${root}/homepage" "${root}/proxy"; do
    if [[ -e ${path} ]]; then
      find "${path}" -mindepth 0 ! -writable -print 2>/dev/null || true
    fi
  done
  return 0
}

# @function repair_stale_path
# Repair one leftover path: a directory sitting where the checkout has a file
# (Docker created the bind-mount source) is removed; an unwritable file is
# chmod'd, and with sudo it is chown'd back to this user.
# Globals:
#   None
# Arguments:
#   $1 - repo root
#   $2 - path to repair
#   $3 - 1 to use sudo when chmod is not enough (default 0)
# Outputs:
#   One line when something changed
# Returns:
#   0 when the path is gone or writable, 1 when it still is not
repair_stale_path() {
  local root="${1:-}" path="${2:-}" use_sudo="${3:-0}" rel="" src="" parent=""
  [[ -n ${path} && -e ${path} ]] || return 0
  rel="$(runfiles_relpath "${path}" "${root}")"
  src=""
  if [[ -n ${root} && -n ${rel} ]]; then
    src="${root}/${rel}"
  fi
  parent="$(dirname "${path}")"

  if [[ -d ${path} && -n ${src} && -f ${src} ]]; then
    if rm -rf "${path}" 2>/dev/null; then
      log "removed leftover directory ${path} (a file belongs there)"
      return 0
    fi
    if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
      if sudo rm -rf "${path}" 2>/dev/null; then
        log "removed leftover directory ${path} (a file belongs there)"
        return 0
      fi
    fi
    warn "cannot remove leftover directory ${path} — re-run: bash scripts/setup-host.sh --repair"
    return 1
  fi

  if [[ -w ${path} ]]; then
    return 0
  fi
  chmod -R u+rwX "${path}" 2>/dev/null || chmod u+w "${path}" 2>/dev/null || true
  if [[ -w ${path} ]]; then
    log "restored write access on ${path}"
    return 0
  fi
  if [[ ${use_sudo} == "1" ]] && command -v sudo >/dev/null 2>&1; then
    sudo chown -R "$(id -u):$(id -g)" "${path}" 2>/dev/null || true
    sudo chmod -R u+rwX "${path}" 2>/dev/null || true
    if [[ -w ${path} ]]; then
      log "took ownership of ${path}"
      return 0
    fi
  fi
  if [[ ! -w ${parent} ]]; then
    warn "${path} is not writable (parent ${parent} either) — re-run: bash scripts/setup-host.sh --repair"
  else
    warn "${path} is not writable — re-run: bash scripts/setup-host.sh --repair"
  fi
  return 1
}

# @function repair_stale_runfiles
# Repair every leftover payload path under this checkout's bazel-out runfiles
# and any unwritable homepage/proxy copy in the checkout itself.
# Globals:
#   None
# Arguments:
#   $1 - repo root
#   $2 - 1 to use sudo (default 0)
# Outputs:
#   One line per repaired or refused path; nothing when the tree is clean
# Returns:
#   0 when every path is clean or there was nothing to do; 1 when a path remains
repair_stale_runfiles() {
  local root="${1:-}" use_sudo="${2:-0}" path="" rc=0 found=0
  [[ -n ${root} && -d ${root} ]] || return 0
  while IFS= read -r path; do
    [[ -n ${path} ]] || continue
    found=1
    if ! repair_stale_path "${root}" "${path}" "${use_sudo}"; then
      rc=1
    fi
  done < <(stale_runfiles_paths "${root}")
  if [[ ${found} -eq 0 ]]; then
    return 0
  fi
  return "${rc}"
}

# @function report_stale_runfiles
# List leftover payload paths without changing them, for --check.
# Globals:
#   None
# Arguments:
#   $1 - repo root
# Outputs:
#   A count line, plus one path per leftover
# Returns:
#   0, always
report_stale_runfiles() {
  local root="${1:-}" path="" rel="" n=0
  [[ -n ${root} && -d ${root} ]] || return 0
  while IFS= read -r path; do
    [[ -n ${path} ]] || continue
    if [[ -d ${path} ]]; then
      rel="$(runfiles_relpath "${path}" "${root}")"
      if [[ -n ${rel} && -f ${root}/${rel} ]]; then
        printf '  leftover-dir %s\n' "${path}"
        n=$((n + 1))
        continue
      fi
    fi
    if [[ ! -w ${path} ]]; then
      printf '  unwritable %s\n' "${path}"
      n=$((n + 1))
    fi
  done < <(stale_runfiles_paths "${root}")
  if [[ ${n} -eq 0 ]]; then
    log "runfiles: no leftover payload under ${root}"
  else
    warn "runfiles: ${n} leftover path(s) will make bazelisk run fail with Permission denied"
    note "Repair with: bash scripts/setup-host.sh --repair"
  fi
  return 0
}
