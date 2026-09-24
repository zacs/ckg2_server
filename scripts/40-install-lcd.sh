#!/usr/bin/env bash
# 40-install-lcd.sh — install the `cklcd` front-panel tool and its status
# daemon, and hand the OLED over from the stock `ck-ui`.
#
# The front panel is a Linux framebuffer (/dev/fb0). The stock `ck-ui` daemon
# owns it and will redraw over anything else, so we stop+disable it first, then
# run cklcd's info screen as a systemd service.
#
# Idempotent. Installs its own dependencies (python3-pil, python3-qrcode, fonts).
#
# Usage: ./40-install-lcd.sh [-y]

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
REPO_ROOT="$(cd .. && pwd)"

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

require_root "$@"

[[ -e /dev/fb0 ]] || warn "/dev/fb0 not present — is this a CloudKey with the OLED? Continuing anyway."

# Dependencies: only cklcd needs Python + Pillow, so they're installed here
# rather than by 20-provision.sh.
if ! python3 -c 'import PIL' 2>/dev/null; then
  log "Installing python3-pil (Pillow) + fonts…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3-pil python3-qrcode fonts-dejavu-core
fi

# 1. Take the panel away from whatever else drives it: the stock ck-ui (still
#    installed — 10-deunifi.sh deliberately keeps the package) and the
#    jnovack daemon if 41-install-cloudkey.sh was run earlier.
for svc in ck-ui.service cloudkey.service; do
  if systemctl cat "$svc" >/dev/null 2>&1; then
    log "disabling $svc (only one process may own /dev/fb0)…"
    systemctl disable --now "$svc" 2>/dev/null || true
  fi
done

# 2. Install the tool.
log "Installing cklcd to /usr/local/bin/cklcd…"
install -m 0755 "$REPO_ROOT/lcd/cklcd" /usr/local/bin/cklcd

# 3. Show what the kernel reports for the panel (sanity check).
log "Probing the framebuffer:"
/usr/local/bin/cklcd probe || warn "cklcd probe failed — check /dev/fb0 access."

# 4. Install service + env, without clobbering an edited env.
log "Installing cklcd.service + /etc/cklcd.env…"
install -m 0644 "$REPO_ROOT/systemd/cklcd.service" /etc/systemd/system/cklcd.service
[[ -f /etc/cklcd.env ]] || install -m 0644 "$REPO_ROOT/config/cklcd.env.example" /etc/cklcd.env

systemctl daemon-reload
systemctl enable --now cklcd.service
sleep 2

if systemctl is-active --quiet cklcd.service; then
  ok "cklcd.service running — the panel should now show host/IP/uptime."
else
  err "cklcd.service failed to start. Logs:"
  journalctl -u cklcd.service -n 20 --no-pager || true
  exit 1
fi
log "Edit /etc/cklcd.env to tweak refresh interval / disk shown, then: systemctl restart cklcd"
