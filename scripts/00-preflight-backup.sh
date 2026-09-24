#!/usr/bin/env bash
# 00-preflight-backup.sh — image the whole eMMC BEFORE you change anything. This
# is your primary safety net: if a later step breaks the box you can restore this
# image from recovery/serial (see docs/06-recovery.md).
#
# The eMMC is /dev/mmcblk0 (~29 GiB usable). We write a full-disk image somewhere
# that is NOT the eMMC. Important reality for this hardware: THERE IS NO USABLE
# USB PORT (see docs/01-hardware.md), so a "USB stick" is usually not an option.
# Your realistic destinations are:
#
#   1. Over the network to your workstation/NAS (recommended — survives even a
#      totally dead box). Stream the image to stdout and pipe it over ssh:
#
#         # run this FROM your workstation (pulls the image off the CloudKey):
#         ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz
#
#         # ...or run it ON the box with this script and push it out:
#         ./00-preflight-backup.sh --stdout | gzip -1 | ssh you@nas 'cat > ck.img.gz'
#
#   2. To the internal SATA disk — but note 30-mount-storage.sh ERASES /dev/sda
#      later, so a backup left there is only temporary. Copy it off (see #1)
#      before you format the disk, or treat it as a short-lived pre-de-UniFi net.
#
# NOTE on consistency: imaging a live, mounted eMMC gives a "crash-consistent"
# copy (like pulling the plug). Fine as a byte-for-byte restore target and what
# most people use. For a perfect image, run from Recovery Mode (docs/06-recovery.md).
#
# Usage:
#   ./00-preflight-backup.sh /volume/emmc-backup.img       # to a mounted disk (raw)
#   ./00-preflight-backup.sh /volume/emmc-backup.img.gz    # gzip-compressed (much smaller)
#   ./00-preflight-backup.sh --stdout > out.img            # stream to stdout (pipe it anywhere)
#   ./00-preflight-backup.sh -y /path/backup.img.zst       # zstd, skip prompt

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

ASSUME_YES=0
STDOUT=0
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y) ASSUME_YES=1; shift ;;
    --stdout|-) STDOUT=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) OUT="$1"; shift ;;
  esac
done
[[ "$STDOUT" == 1 || -n "$OUT" ]] || die "Usage: $0 [-y] <output-image-path> | --stdout"

require_root
assert_cloudkey

SRC=/dev/mmcblk0
[[ -b "$SRC" ]] || die "$SRC not found — is this a CloudKey Gen2?"
SIZE_BYTES="$(blockdev --getsize64 "$SRC")"

# Pick a compressor from the output extension (file mode only). In --stdout mode
# we emit raw bytes and let the caller's pipe compress.
COMP=(cat); COMP_DESC="raw"
if [[ "$STDOUT" != 1 ]]; then
  case "$OUT" in
    *.gz)  command -v gzip >/dev/null 2>&1 || die "gzip not found (apt-get install -y gzip)"; COMP=(gzip -1); COMP_DESC="gzip" ;;
    *.zst) command -v zstd >/dev/null 2>&1 || die "zstd not found (apt-get install -y zstd)"; COMP=(zstd -q -T0); COMP_DESC="zstd" ;;
  esac
fi

if [[ "$STDOUT" == 1 ]]; then
  # Logs must go to stderr so they don't corrupt the image on stdout.
  log "Streaming a full image of $SRC ($(numfmt --to=iec "$SIZE_BYTES" 2>/dev/null || echo "$SIZE_BYTES B")) to stdout…" >&2
  log "(pipe it through a compressor and/or ssh; nothing is written locally)" >&2
  # No conv=noerror,sync: in a backup, a read error must FAIL loudly, not be
  # silently zero-filled into an image you'll only discover is bad at restore.
  dd if="$SRC" bs=4M status=progress
  exit 0
fi

OUTDIR="$(dirname "$OUT")"
if [[ ! -d "$OUTDIR" ]]; then
  err "output directory $OUTDIR does not exist."
  err "This box has no usable USB port — back up over the network instead, e.g. from your workstation:"
  err "    ssh root@$(hostname 2>/dev/null || echo '<cloudkey>') 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz"
  err "or mount the SATA disk first (note 30-mount-storage.sh later erases it). See the header of this script."
  exit 1
fi

# Refuse to write the image onto the very device we're imaging. (on_os_storage
# also catches the overlay root, which findmnt reports as "overlay", not mmcblk0.)
OUT_SRC="$(findmnt -no SOURCE --target "$OUTDIR" 2>/dev/null || true)"
if on_os_storage "$OUTDIR"; then
  die "refusing to write the backup onto the eMMC we're imaging ($OUTDIR is on ${OUT_SRC:-the root filesystem}). Use the SATA disk or stream over the network (--stdout)."
fi

AVAIL_BYTES="$(( $(stat -f -c '%a*%S' "$OUTDIR") ))"
log "Source:      $SRC ($(numfmt --to=iec "$SIZE_BYTES" 2>/dev/null || echo "$SIZE_BYTES B"))"
log "Destination: $OUT (on ${OUT_SRC:-?}, $(numfmt --to=iec "$AVAIL_BYTES" 2>/dev/null || echo "$AVAIL_BYTES B") free, $COMP_DESC)"

# Space check: a raw image needs the full device size; a compressed one is
# usually far smaller, so we only warn there (we can't know the size up front).
if (( AVAIL_BYTES < SIZE_BYTES )); then
  if [[ "$COMP_DESC" == "raw" ]]; then
    die "not enough free space for a full raw image. Use a .gz/.zst path, or stream with --stdout."
  else
    warn "less free space than the raw device size; a $COMP_DESC image usually fits, but watch for ENOSPC."
  fi
fi

confirm "Write a $COMP_DESC image of $SRC to $OUT?" || die "aborted."

log "Imaging… (several minutes; the eMMC is ~29 GiB)"
if command -v pv >/dev/null 2>&1; then
  pv -s "$SIZE_BYTES" "$SRC" | "${COMP[@]}" > "$OUT"
else
  dd if="$SRC" bs=4M status=progress | "${COMP[@]}" > "$OUT"
fi
sync

ok "Backup complete: $OUT"
log "Recording a checksum for integrity verification…"
sha256sum "$OUT" | tee "${OUT}.sha256"
ok "Keep $OUT (and its .sha256) somewhere safe — off the CloudKey ideally."
