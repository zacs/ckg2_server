#!/usr/bin/env bash
# 50-install-docker.sh — install Docker on the reclaimed CloudKey and put its
# runtime where it belongs: on the SATA disk, not the soldered eMMC. Also caps
# per-container logs so a chatty container can't fill the disk. Rationale and the
# storage map are in docs/10-storage-and-docker.md.
#
# What it does:
#   1. Installs Docker (Debian's `docker.io` by default — the reliable choice on
#      this armhf / old-kernel box; --get-docker uses the get.docker.com script).
#   2. Writes /etc/docker/daemon.json with:
#        - data-root -> /volume/docker   (images, layers, named volumes, logs)
#        - json-file log driver capped at 3 x 10 MB per container
#        - a storage-driver chosen for the running kernel (overlay2 if supported,
#          else vfs — correct, just space-heavy, which is fine on the big disk).
#   3. Migrates any existing /var/lib/docker into the new data-root if present.
#
# Run AFTER 30-mount-storage.sh (needs /volume). Idempotent.
#
# Usage:
#   ./50-install-docker.sh                       # docker.io, data-root=/volume/docker
#   ./50-install-docker.sh --data-root /srv/dk   # custom data-root (must be off the eMMC)
#   ./50-install-docker.sh --storage-driver vfs  # force a driver (else auto-detected)
#   ./50-install-docker.sh --get-docker          # use get.docker.com instead of docker.io
#   ./50-install-docker.sh -y                     # no prompts

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

DATA_ROOT="/volume/docker"
STORAGE_DRIVER=""          # empty = auto-detect from kernel
USE_GET_DOCKER=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root) DATA_ROOT="$2"; shift 2 ;;
    --storage-driver) STORAGE_DRIVER="$2"; shift 2 ;;
    --get-docker) USE_GET_DOCKER=1; shift ;;
    -y) ASSUME_YES=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

require_root
assert_cloudkey

# --- sanity: data-root must live on the SATA disk, not the eMMC ---------------
DR_PARENT="$(dirname "$DATA_ROOT")"
if findmnt -rno TARGET "$DR_PARENT" >/dev/null 2>&1; then
  DR_SRC="$(findmnt -rno SOURCE "$DR_PARENT" 2>/dev/null || true)"
else
  DR_SRC="$(findmnt -rno SOURCE -T "$DR_PARENT" 2>/dev/null || true)"
fi
case "$DR_SRC" in
  /dev/mmcblk*|"")
    warn "data-root $DATA_ROOT resolves onto the eMMC (${DR_SRC:-unknown})."
    warn "That defeats the purpose (eMMC wear/space). Run 30-mount-storage.sh first,"
    warn "or pass --data-root under a disk mount."
    confirm "Install anyway with data-root on the eMMC?" || die "aborted."
    ;;
  *) log "data-root $DATA_ROOT is on $DR_SRC (good — off the eMMC)." ;;
esac

# --- pick a storage driver the kernel can actually run ------------------------
# overlay2 wants kernel >= 4.0; the stock CloudKey kernel is 3.18, where it's
# usually unavailable and Docker would fall back to vfs anyway. Detect and be
# explicit so dockerd doesn't fail to start choosing a driver it can't use.
if [[ -z "$STORAGE_DRIVER" ]]; then
  KVER="$(uname -r)"; KMAJ="${KVER%%.*}"; KREST="${KVER#*.}"; KMIN="${KREST%%.*}"
  KMAJ="${KMAJ//[!0-9]/}"; KMIN="${KMIN//[!0-9]/}"
  modprobe overlay >/dev/null 2>&1 || true
  if [[ "${KMAJ:-0}" -ge 4 ]] && grep -qw overlay /proc/filesystems 2>/dev/null; then
    STORAGE_DRIVER="overlay2"
  else
    STORAGE_DRIVER="vfs"
  fi
  log "Kernel $KVER → storage-driver: $STORAGE_DRIVER"
  [[ "$STORAGE_DRIVER" == "vfs" ]] && warn \
    "vfs has no copy-on-write (images use more space, pulls are slower) but is reliable;
     the extra space lives on the roomy SATA disk, so this is an acceptable trade here."
fi

echo
log "Plan:"
log "  install:        $([[ $USE_GET_DOCKER == 1 ]] && echo 'get.docker.com script' || echo 'docker.io (Debian)')"
log "  data-root:      $DATA_ROOT"
log "  storage-driver: $STORAGE_DRIVER"
log "  container logs: json-file, capped at 3 x 10 MB each"
confirm "Proceed?" || die "aborted."

# --- 1. install Docker -------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  if [[ "$USE_GET_DOCKER" == "1" ]]; then
    log "Installing Docker via get.docker.com…"
    tmp="$(mktemp)"; curl -fsSL https://get.docker.com -o "$tmp"
    sh "$tmp"; rm -f "$tmp"
  else
    log "Installing docker.io from Debian…"
    apt-get update
    apt-get install -y --no-install-recommends docker.io
  fi
else
  ok "Docker already installed ($(docker --version 2>/dev/null || echo present))."
fi

# --- 2. stop the daemon before we move its data-root -------------------------
# A fresh `apt install` will have started dockerd and created /var/lib/docker on
# the eMMC. Stop it, relocate, then start — so the eMMC copy doesn't linger.
systemctl stop docker.socket docker.service 2>/dev/null || true

# --- 3. migrate an existing /var/lib/docker if we're relocating --------------
DEFAULT_ROOT="/var/lib/docker"
if [[ "$DATA_ROOT" != "$DEFAULT_ROOT" && -d "$DEFAULT_ROOT" ]]; then
  if [[ -n "$(ls -A "$DEFAULT_ROOT" 2>/dev/null || true)" ]]; then
    if [[ ! -d "$DATA_ROOT" || -z "$(ls -A "$DATA_ROOT" 2>/dev/null || true)" ]]; then
      log "Migrating existing $DEFAULT_ROOT → $DATA_ROOT…"
      mkdir -p "$DATA_ROOT"
      command -v rsync >/dev/null 2>&1 \
        && rsync -aHAXS --numeric-ids "$DEFAULT_ROOT"/ "$DATA_ROOT"/ \
        || cp -a "$DEFAULT_ROOT"/. "$DATA_ROOT"/
      mv "$DEFAULT_ROOT" "${DEFAULT_ROOT}.pre-ckg2" 2>/dev/null || true
      ok "Migrated; old tree preserved at ${DEFAULT_ROOT}.pre-ckg2 (remove once healthy)."
    else
      warn "$DATA_ROOT already has data — leaving both trees as-is (no migration)."
    fi
  fi
fi
mkdir -p "$DATA_ROOT"

# --- 4. daemon.json (see config/docker-daemon.json.example) ------------------
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s 2>/dev/null || echo prev)" 2>/dev/null || \
    cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak || true
  warn "existing /etc/docker/daemon.json backed up before overwrite."
fi
cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$DATA_ROOT",
  "storage-driver": "$STORAGE_DRIVER",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
ok "Wrote /etc/docker/daemon.json"

# --- 5. (re)start and confirm ------------------------------------------------
systemctl enable docker.service >/dev/null 2>&1 || true
systemctl start docker.service
sleep 2

if docker info >/dev/null 2>&1; then
  ok "Docker is up."
  log "  data-root:      $(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
  log "  storage-driver: $(docker info -f '{{.Driver}}' 2>/dev/null)"
else
  err "dockerd did not come up cleanly. Check: journalctl -u docker --no-pager -n 40"
  err "If it's a storage-driver problem, re-run with --storage-driver vfs."
  exit 1
fi

echo
ok "Done. Put bind-mounted volumes under $DR_PARENT (e.g. -v $DR_PARENT/appdata/db:/var/lib/db)."
log "Named volumes already live under $DATA_ROOT. See docs/10-storage-and-docker.md."
