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
[[ -n "$DEVICE" ]] || die "Usage: $0 <device> [--at MOUNT] [--gpt] [-y]"
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Hard guard: never operate on the eMMC (that's the OS) or a mounted system disk.
case "$DEVICE" in
  /dev/mmcblk*) die "refusing to format $DEVICE — that's the eMMC (the OS lives there)." ;;
esac
if findmnt -rno TARGET "$DEVICE" >/dev/null 2>&1; then
  die "$DEVICE is currently mounted. Unmount it first."
fi

log "Target disk:"
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$DEVICE" || lsblk "$DEVICE"
echo
warn "This will ERASE ALL DATA on $DEVICE and mount it at $MOUNTPOINT."
confirm "Continue?" || die "aborted."

TARGET="$DEVICE"
if [[ "$USE_GPT" == "1" ]] && ! command -v parted >/dev/null 2>&1; then
  die "--gpt needs 'parted' (apt-get install -y parted), or drop --gpt for a whole-disk filesystem."
fi
wipefs -a "$DEVICE"
if [[ "$USE_GPT" == "1" ]]; then
  log "Creating GPT + single partition…"
  sgdisk --zap-all "$DEVICE" 2>/dev/null || true
  parted -s "$DEVICE" mklabel gpt
  parted -s "$DEVICE" mkpart primary ext4 1MiB 100%
  # settle + pick the new partition node (sda1 / nvme0n1p1-style)
  partprobe "$DEVICE" 2>/dev/null || true; udevadm settle 2>/dev/null || true
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
Options=defaults,noatime,nofail,x-systemd.device-timeout=30

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable --now "$UNIT"

ok "Mounted:"
findmnt "$MOUNTPOINT"
log "Health tip: this disk is USB-attached; check SMART with:  smartctl -a $DEVICE"
