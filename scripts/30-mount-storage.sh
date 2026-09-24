#!/usr/bin/env bash
# 30-mount-storage.sh — format and persistently mount the internal 2.5" drive.
#
# Two CloudKey-specific facts drive this script's design:
#   1. The drive is NOT native SATA — it's a USB-SATA bridge behind an internal
#      USB hub, so it shows up as /dev/sda (a USB disk), driven by uas/usb-storage.
#   2. You MUST persist the mount with a systemd .mount unit, NOT /etc/fstab.
#      The load-bearing base-files package rewrites /etc/fstab to a template on
#      every boot, silently dropping any line you add. Plain unit files under
#      /etc/systemd/system/ are left alone and survive reboots.
#
# By default it makes a whole-disk ext4 filesystem (no partition table — the
# drive is dedicated bulk storage, so a partition table just adds a device-name
# to get wrong). Pass --gpt if you'd rather have a single GPT partition.
#
# A drive that stock UniFi OS set up is NOT blank: UniFi partitions it into
# swap + system volumes + a big data partition (often still mounted at /volume,
# and possibly holding old Protect footage/backups — look before you wipe).
# This script finds anything on the disk that's mounted or used as swap, shows
# it, and releases it (after you confirm) before wiping.
#
# Usage:
#   ./30-mount-storage.sh /dev/sda                 # whole-disk ext4 at /volume
#   ./30-mount-storage.sh /dev/sda --at /srv       # custom mountpoint
#   ./30-mount-storage.sh /dev/sda --gpt -y        # GPT + one partition, no prompt
#
# WIPES the target unconditionally. Confirm you named the right disk.

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

DEVICE=""
MOUNTPOINT="/volume"
USE_GPT=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --at) MOUNTPOINT="$2"; shift 2 ;;
    --gpt) USE_GPT=1; shift ;;
    -y) ASSUME_YES=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) DEVICE="$1"; shift ;;
  esac
done

require_root
assert_cloudkey
[[ -n "$DEVICE" ]] || die "Usage: $0 <device> [--at MOUNT] [--gpt] [-y]"
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Hard guard: never operate on the eMMC (that's the OS).
case "$DEVICE" in
  /dev/mmcblk*) die "refusing to format $DEVICE — that's the eMMC (the OS lives there)." ;;
esac
log "Target disk:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,TRAN,MOUNTPOINT "$DEVICE" || lsblk "$DEVICE"
echo

# Anything on this disk in use? Checking only the whole-disk node misses the
# usual case — a mounted PARTITION (/dev/sda3 at /volume) or active swap on
# /dev/sda1 — and wipefs/mkfs then die half-way with "Device or resource busy".
BUSY=()
while read -r node mp; do
  [[ -n "$mp" ]] && BUSY+=("$node $mp")
done < <(lsblk -nrpo NAME,MOUNTPOINT "$DEVICE")

# /etc/fstab lines that point at this disk. On this box fstab is reset to a
# template every boot, so if the TEMPLATE references the disk, a line that
# stops matching after the wipe could stall boot (a mount without `nofail`
# drops systemd into emergency mode). Show them so you can check.
FSTAB_HITS=""
if [[ -r /etc/fstab ]]; then
  IDS="$(lsblk -nrpo NAME,UUID,PARTUUID,LABEL "$DEVICE" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  while read -r spec mp _; do
    [[ -z "$spec" || "$spec" == \#* ]] && continue
    val="${spec#*=}"
    if grep -qxF -- "$val" <<<"$IDS" || [[ "$spec" == "$DEVICE"* || "$mp" == "$MOUNTPOINT" ]]; then
      FSTAB_HITS+="    $spec $mp"$'\n'
    fi
  done < /etc/fstab
fi
if [[ -n "$FSTAB_HITS" ]]; then
  warn "/etc/fstab references this disk or $MOUNTPOINT:"
  printf '%s' "$FSTAB_HITS" >&2
  warn "After the wipe these won't match. If a line lacks 'nofail', mask its unit so it"
  warn "can't block boot, e.g.:  systemctl mask \$(systemd-escape -p --suffix=mount <mountpoint>)"
fi

warn "This will ERASE ALL DATA on $DEVICE and mount it at $MOUNTPOINT."
confirm "Continue?" || die "aborted."

if (( ${#BUSY[@]} )); then
  warn "In use on $DEVICE right now (UniFi's old swap/data partitions, typically):"
  printf '    %s\n' "${BUSY[@]}" >&2
  confirm "Release these (swapoff / umount) so the disk can be wiped?" || \
    die "aborted — release them yourself (swapoff / umount), then re-run."
  for entry in "${BUSY[@]}"; do
    node="${entry%% *}"; printf -v mp '%b' "${entry#* }"   # lsblk -r escapes spaces as \x20
    if [[ "$mp" == "[SWAP]" ]]; then
      swapoff "$node" || die "swapoff $node failed."
    else
      umount "$mp" || die "umount $mp ($node) failed — something still has files open there (try: fuser -vm $mp)."
    fi
    ok "released $node ($mp)"
  done
fi

TARGET="$DEVICE"
wipefs -a "$DEVICE"
if [[ "$USE_GPT" == "1" ]]; then
  # sfdisk ships with util-linux (always present), unlike parted/sgdisk.
  log "Creating GPT + single partition…"
  printf 'label: gpt\n,,L\n' | sfdisk --wipe always "$DEVICE"
  # settle + pick the new partition node (sda1 / nvme0n1p1-style)
  partprobe "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  if [[ -b "${DEVICE}1" ]]; then TARGET="${DEVICE}1"; else TARGET="${DEVICE}p1"; fi
fi

log "Making ext4 filesystem on $TARGET…"
mkfs.ext4 -F -L volume "$TARGET"
UUID="$(blkid -s UUID -o value "$TARGET")"
[[ -n "$UUID" ]] || die "could not read UUID of new filesystem."

# systemd .mount unit names must match the mountpoint path (systemd-escape).
UNIT="$(systemd-escape -p --suffix=mount "$MOUNTPOINT")"
log "Writing /etc/systemd/system/$UNIT (persists across the fstab rewrite)…"
mkdir -p "$MOUNTPOINT"
cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Bulk storage drive at $MOUNTPOINT
# CloudKey note: mounted via a systemd unit, NOT /etc/fstab, because the UniFi
# base-files package rewrites fstab to a template on every boot.

[Mount]
What=/dev/disk/by-uuid/$UUID
Where=$MOUNTPOINT
Type=ext4
# nofail: a missing disk degrades (things that need it wait/fail) instead of
# blocking boot. (x-systemd.* options only mean something in /etc/fstab.)
Options=defaults,noatime,nofail

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable --now "$UNIT"

ok "Mounted:"
findmnt "$MOUNTPOINT"
log "Health tip: this disk is USB-attached; check SMART with:  smartctl -a $DEVICE"
log "  (some USB-SATA bridges don't pass SMART through; try: smartctl -d sat -a $DEVICE)"
if [[ "$MOUNTPOINT" == "/volume" ]]; then
  warn "Heads-up: a UniFi boot hook that stays installed (mp-clean) deletes EMPTY directories"
  warn "directly under /volume on every boot. Nest things (/volume/appdata/<app>) or drop a"
  warn "'.keep' file into any top-level directory that might sit empty."
fi
