#!/usr/bin/env bash
# 35-rehome-storage.sh — move write-heavy OS directories off the soldered-down
# eMMC and onto the swappable SATA disk (/volume), to save eMMC write-endurance
# and space. See docs/10-storage-and-docker.md for the full rationale.
#
# It rehomes each directory with a systemd BIND .mount unit — never /etc/fstab,
# which the CloudKey's base-files package rewrites on every boot (see
# docs/07-watchdog-and-persistence.md). For each target it:
#   1. rsyncs the current contents to <base>/<name>,
#   2. writes /etc/systemd/system/<escaped>.mount  (What=<base>/<name>, bind),
#   3. activates it (or, for /var/log, defers to the next boot — see below).
#
# Defaults: /home and /srv (safe to bind live). /var/log is opt-in (--var-log)
# because running loggers hold it open, so its bind is installed but only takes
# effect after a reboot; this path also caps the persistent journal.
#
# Run AFTER 30-mount-storage.sh (so /volume exists). Idempotent: re-running skips
# anything already rehomed.
#
# Usage:
#   ./35-rehome-storage.sh                 # rehome /home + /srv to /volume/*
#   ./35-rehome-storage.sh --var-log       # also rehome /var/log (activates on reboot)
#   ./35-rehome-storage.sh --base /srv/data --var-log
#   ./35-rehome-storage.sh -n              # dry run: show the plan, change nothing
#   ./35-rehome-storage.sh -y              # no prompts

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

BASE="/volume"
DO_VARLOG=0
DRYRUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --var-log) DO_VARLOG=1; shift ;;
    -n|--dry-run) DRYRUN=1; shift ;;
    -y) ASSUME_YES=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

require_root
assert_cloudkey
command -v rsync >/dev/null 2>&1 || die "rsync not found — run 20-provision.sh first (or: apt-get install -y rsync)."

# The base must be a real mount on the SATA disk, not a plain dir on the eMMC —
# otherwise "rehoming" would just move data from one eMMC path to another.
findmnt -rno TARGET "$BASE" >/dev/null 2>&1 || \
  die "$BASE is not a mountpoint. Run 30-mount-storage.sh first (it mounts /dev/sda at /volume)."
BASE_SRC="$(findmnt -rno SOURCE "$BASE" 2>/dev/null || true)"
case "$BASE_SRC" in
  /dev/mmcblk*) die "$BASE is backed by the eMMC ($BASE_SRC) — rehoming there saves nothing." ;;
esac
log "Rehome base: $BASE  (on $BASE_SRC)"
[[ "$DRYRUN" == "1" ]] && warn "DRY RUN — no changes will be made."

# Build the target list. Format: "src" (name is derived from the path tail).
TARGETS=(/home /srv)
[[ "$DO_VARLOG" == "1" ]] && TARGETS+=(/var/log)

# rehome_dir SRC LIVE_OK
#   SRC      absolute source dir (e.g. /home)
#   LIVE_OK  1 = safe to bind now; 0 = install unit but defer bind to reboot
rehome_dir() {
  local src="$1" live_ok="$2"
  local name dst unit
  name="${src#/}"; name="${name//\//-}"      # /var/log -> var-log
  dst="$BASE/$name"
  unit="$(systemd-escape -p --suffix=mount "$src")"

  # Already rehomed? (src is a mount whose source path lives under $BASE)
  if findmnt -rno SOURCE "$src" 2>/dev/null | grep -q "^$BASE\b"; then
    ok "$src already rehomed to $BASE — skipping."
    return 0
  fi
  if [[ ! -d "$src" ]]; then
    warn "$src does not exist — skipping."
    return 0
  fi

  log "Rehoming $src  ->  $dst"
  if [[ "$DRYRUN" == "1" ]]; then
    log "  would: rsync -aHAXS --numeric-ids $src/ $dst/"
    log "  would: write /etc/systemd/system/$unit  (bind $dst -> $src)"
    [[ "$live_ok" == "1" ]] && log "  would: systemctl enable --now $unit" \
                            || log "  would: systemctl enable $unit  (activates on reboot)"
    return 0
  fi

  mkdir -p "$dst"
  # -S sparse, -H hardlinks, -A ACLs, -X xattrs, --numeric-ids: a faithful copy.
  rsync -aHAXS --numeric-ids "$src"/ "$dst"/

  cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=Rehomed $src on bulk storage ($dst)
# Bind-mounted via a systemd unit, NOT /etc/fstab (base-files rewrites fstab on
# every boot). RequiresMountsFor pins ordering after the $BASE disk mount.
RequiresMountsFor=$BASE
After=$(systemd-escape -p --suffix=mount "$BASE")

[Mount]
What=$dst
Where=$src
Type=none
Options=bind,nofail

[Install]
WantedBy=local-fs.target
EOF

  systemctl daemon-reload
  if [[ "$live_ok" == "1" ]]; then
    systemctl enable --now "$unit"
    ok "$src is now bind-mounted from $dst:"
    findmnt "$src" || true
  else
    systemctl enable "$unit" >/dev/null 2>&1 || true
    ok "$src unit installed — will bind on next boot (loggers hold it open now)."
  fi
}

echo
warn "This will COPY the contents of ${TARGETS[*]} to $BASE and bind-mount them there."
warn "The originals on the eMMC stay in place, shadowed by the bind mount (nothing is deleted)."
confirm "Continue?" || die "aborted."

for src in "${TARGETS[@]}"; do
  if [[ "$src" == "/var/log" ]]; then
    rehome_dir "$src" 0
  else
    rehome_dir "$src" 1
  fi
done

# Cap the persistent journal so /var/log (now on disk) can't grow without bound.
if [[ "$DO_VARLOG" == "1" ]]; then
  if [[ "$DRYRUN" == "1" ]]; then
    log "would: cap systemd journal at 200M via /etc/systemd/journald.conf.d/10-ckg2-cap.conf"
  else
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/10-ckg2-cap.conf <<'EOF'
# ckg2_server — bound the on-disk journal so logs don't fill /volume/log.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
    ok "journald capped at 200M (applies after reboot / restart of systemd-journald)."
  fi
fi

echo
if [[ "$DO_VARLOG" == "1" && "$DRYRUN" != "1" ]]; then
  warn "You rehomed /var/log — REBOOT now so the bind and the journal cap take effect:  sudo reboot"
fi
ok "Rehome complete. Verify with: ./99-verify.sh"
log "Once you've confirmed the binds are healthy, you may reclaim the shadowed eMMC copies"
log "(booting single-user / from the underlying mount). This is optional and not automated —"
log "the shadowed data is harmless, it just occupies eMMC space until removed."
