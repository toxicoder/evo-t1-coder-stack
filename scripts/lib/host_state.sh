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
#     not wait on this host fix; `git pull` on the host still does.
#
# These helpers diagnose both and repair the runfiles leftover. They never
# rewrite Tailscale's own settings: flipping `--accept-dns` is an operator
# choice, and the report names the copy-paste that does it.
#
# Usage (from an entry script, after `set -euo pipefail`):
#   # shellcheck source=lib/host_state.sh disable=SC1091
#   source "${SELF_DIR}/lib/host_state.sh"

if ! declare -f log >/dev/null 2>&1; then
  SELF_DIR="${SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  # shellcheck source=common.sh disable=SC1091
  source "${SELF_DIR}/common.sh"
fi

# MAGICDNS_NS - Tailscale's on-box resolver. When it is the only nameserver,
# every lookup (github.com included) dies the moment the stub is unreachable.
MAGICDNS_NS='100.100.100.100'

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
#   None
# Arguments:
#   $1 - hostname (default github.com)
# Outputs:
#   Nothing
# Returns:
#   0 when a lookup returned a line, 1 otherwise
host_can_resolve() {
  local name="${1:-github.com}"
  if command -v getent >/dev/null 2>&1; then
    [[ -n $(getent hosts "${name}" 2>/dev/null | head -n 1) ]]
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${name}" <<'PY' 2>/dev/null
import socket, sys
try:
    socket.getaddrinfo(sys.argv[1], None)
except OSError:
    sys.exit(1)
PY
    return
  fi
  return 1
}

# @function host_dns_report
# Print whether github.com resolves, and when it does not, name the usual
# cause on this box (Tailscale MagicDNS as the only nameserver, then Docker
# or Kasm making 100.100.100.100 unreachable).
# Globals:
#   MAGICDNS_NS
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
      note "Keep a public resolver beside MagicDNS, then retry git pull:"
      note "  sudo tailscale set --accept-dns=false"
      note "  # or add 1.1.1.1 / 8.8.8.8 as a global nameserver in the Tailscale admin DNS page"
      note "  # or: printf '[Resolve]\\nDNS=1.1.1.1 8.8.8.8\\n' | sudo tee /etc/systemd/resolved.conf.d/evo-t1-public-dns.conf && sudo systemctl restart systemd-resolved"
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
