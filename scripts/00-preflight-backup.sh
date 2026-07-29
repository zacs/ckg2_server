#!/usr/bin/env bash
# 00-preflight-backup.sh — image the whole eMMC to a file BEFORE you change
# anything. This is your primary safety net: if a later step breaks the box you
# can restore this image from recovery/serial (see docs/06-recovery.md).
#
# The eMMC is /dev/mmcblk0 (~29 GiB usable). We write a full-disk image to a
# file on some OTHER storage — the internal SATA disk once mounted, or a USB
# stick — never back onto the eMMC itself.
#
# NOTE on consistency: imaging a live, mounted eMMC gives a "crash-consistent"
# copy (like pulling the plug). It is fine as a byte-for-byte restore target and
# is what most people use. For a picture-perfect image, run this from Recovery
# Mode instead (docs/06-recovery.md), where the main rootfs is not mounted.
#
# Usage:
#   ./00-preflight-backup.sh /volume/emmc-backup.img        # to the SATA disk
#   ./00-preflight-backup.sh /mnt/usb/emmc-backup.img       # to a USB stick
#   ./00-preflight-backup.sh -y /path/to/backup.img         # skip prompt

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && { ASSUME_YES=1; shift; }
OUT="${1:?Usage: $0 [-y] <output-image-path>}"

require_root "$@"
assert_cloudkey

SRC=/dev/mmcblk0
[[ -b "$SRC" ]] || die "$SRC not found — is this a CloudKey Gen2?"

OUTDIR="$(dirname "$OUT")"
[[ -d "$OUTDIR" ]] || die "output directory $OUTDIR does not exist (mount your target disk first)."

# Refuse to write the image onto the very device we're imaging.
OUT_SRC="$(findmnt -no SOURCE --target "$OUTDIR" 2>/dev/null || true)"
if [[ "$OUT_SRC" == /dev/mmcblk0* ]]; then
  die "refusing to write the backup onto the eMMC we're imaging ($OUT_SRC). Use the SATA disk or a USB stick."
fi

SIZE_BYTES="$(blockdev --getsize64 "$SRC")"
AVAIL_BYTES="$(( $(stat -f -c '%a*%S' "$OUTDIR") ))"
log "Source:      $SRC ($(numfmt --to=iec "$SIZE_BYTES"))"
log "Destination: $OUT (on $OUT_SRC, $(numfmt --to=iec "$AVAIL_BYTES") free)"

if (( AVAIL_BYTES < SIZE_BYTES )); then
  die "not enough free space at destination for a full image."
fi

confirm "Write a full image of $SRC to $OUT?" || die "aborted."

log "Imaging… (this takes several minutes; the eMMC is ~29 GiB)"
if command -v pv >/dev/null 2>&1; then
  pv -s "$SIZE_BYTES" "$SRC" > "$OUT"
else
  dd if="$SRC" of="$OUT" bs=4M conv=noerror,sync status=progress
fi
sync

ok "Backup complete: $OUT"
log "Recording a checksum for integrity verification…"
sha256sum "$OUT" | tee "${OUT}.sha256"
ok "Keep $OUT (and its .sha256) somewhere safe — off the CloudKey ideally."
