#!/usr/bin/env bash
# common.sh — shared helpers sourced by the ckg2_server provisioning scripts.
# Source it from a script like:  . "$(dirname "$0")/lib/common.sh"
#
# Everything here is intentionally dependency-light (coreutils + dpkg/systemd
# that already exist on the stock CloudKey image).

# Colours only when stdout is a terminal.
if [[ -t 1 ]]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'
  _C_BLU=$'\033[34m'; _C_DIM=$'\033[2m'; _C_RST=$'\033[0m'
else
  _C_RED=; _C_GRN=; _C_YEL=; _C_BLU=; _C_DIM=; _C_RST=
fi

log()  { printf '%s[*]%s %s\n' "$_C_BLU" "$_C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# require_root — refuse to run without root; most steps write to /etc, /dev, sysfs.
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $0 $*)"
}

# confirm PROMPT — interactive yes/no, defaulting to No. Honors a global
# ASSUME_YES=1 (set by -y flags) to skip the prompt for non-interactive runs.
confirm() {
  local prompt="${1:-Continue?}"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ck_model — echoes "plus", "g2", or "unknown" by probing the load-bearing
# base-files package that differs per model. Never removed, always present.
ck_model() {
  if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -q '^cloudkey-plus-apq8053-base-files$'; then
    echo plus
  elif dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -q '^cloudkey-g2-apq8053-base-files$'; then
    echo g2
  else
    echo unknown
  fi
}

# assert_cloudkey — sanity gate so these scripts refuse to run on the wrong box
# (e.g. accidentally on a laptop). Checks for the apq8053 hostname/uname marker.
assert_cloudkey() {
  local u; u="$(uname -a 2>/dev/null)"
  # /proc/device-tree/model is NUL-terminated; strip the null so command
  # substitution doesn't warn "ignored null byte in input".
  local model; model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
  if [[ "$u" == *apq8053* || "$model" == *loud* ]]; then
    return 0
  fi
  warn "this does not look like a CloudKey (no apq8053 marker in uname)."
  confirm "Run anyway?" || die "aborted — not a CloudKey."
}

# ssh_alive — proxies "would a NEW ssh connection succeed" from on-box. Used as
# a liveness check between destructive batches: the canonical failure signature
# from a bad UniFi purge is that ping still works but sshd is gone.
ssh_alive() {
  systemctl is-active --quiet ssh 2>/dev/null || return 1
  # Avoid `ss -H`/`sport` filters — the ancient ss on the stock 3.18 image
  # doesn't support them. Plain listing + grep is portable. Fall back to
  # netstat if ss is somehow absent.
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE '[:.]22[[:space:]]' || return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE '[:.]22[[:space:]]' || return 1
  fi
  return 0
}

# pkg_installed PKG — true if the package is in state installed (ii).
pkg_installed() {
  local st; st="$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)"
  [[ "$st" == i* ]]
}

# on_os_storage PATH — true if PATH (or its nearest existing parent) lives on
# the box's own OS storage rather than the SATA disk / a network share.
# Don't just test findmnt's SOURCE for /dev/mmcblk*: on current firmware / is
# an OVERLAY (its writable layer is a ~6 GB eMMC partition), so findmnt reports
# "overlay" (or /dev/root), which a /dev/mmcblk* pattern silently misses.
# Comparing the filesystem's device number with /'s catches every variant.
on_os_storage() {
  local p="$1" src
  while [[ ! -e "$p" && "$p" != / ]]; do p="$(dirname "$p")"; done
  [[ "$(stat -c %d "$p" 2>/dev/null)" == "$(stat -c %d / 2>/dev/null)" ]] && return 0
  src="$(findmnt -rno SOURCE -T "$p" 2>/dev/null || true)"
  [[ "$src" == /dev/mmcblk* || "$src" == /dev/root || "$src" == overlay* ]]
}
