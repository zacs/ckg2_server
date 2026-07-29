#!/usr/bin/env bash
# 20-provision.sh — turn the reclaimed Debian into a pleasant little server:
# base tooling, sane SSH, a firewall, automatic security updates, and the
# housekeeping that keeps UniFi's leftovers from getting in the way.
#
# Idempotent: safe to run more than once. Everything it writes lives in places
# the CloudKey's boot hooks do NOT rewrite (see the /etc/fstab caveat in
# 30-mount-storage.sh and docs/07-watchdog-and-persistence.md).
#
# Run AFTER 10-deunifi.sh and a reboot.
#
# Usage: ./20-provision.sh [-y]

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

require_root "$@"
assert_cloudkey

log "Architecture: kernel=$(uname -m)  userland=$(dpkg --print-architecture)"
log "(A 64-bit aarch64 kernel with a 32-bit armhf userland is normal on this box.)"

# --- 1. base tooling --------------------------------------------------------
log "Installing base tooling…"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg \
  htop tmux vim less rsync git \
  ufw unattended-upgrades \
  python3 python3-pil python3-qrcode fonts-dejavu-core \
  smartmontools lm-sensors pv

# --- 2. automatic security updates ------------------------------------------
# The UniFi auto-updater is gone (disabled in 10-deunifi.sh); use Debian's own.
log "Enabling unattended security upgrades…"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- 3. SSH: keep it working; harden ONLY what can't lock you out -----------
# Deliberately conservative. Your access model on a stock CloudKey is "root with
# a password", so we do NOT touch PermitRootLogin or PasswordAuthentication here
# — flipping either before you have a *tested* SSH key is exactly how people lock
# themselves out. The drop-in below only carries harmless settings. Lock down
# password/root login yourself, after verifying key login — see
# docs/09-accounts-and-access.md.
if [[ -f /etc/ssh/sshd_config ]]; then
  log "Applying safe SSH defaults (no auth changes)…"
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-ckg2.conf <<'EOF'
# ckg2_server SSH drop-in — intentionally contains NO auth-restricting settings.
# To harden AFTER you've installed and TESTED an SSH key (see
# docs/09-accounts-and-access.md), add here and reload sshd:
#     PasswordAuthentication no
#     PermitRootLogin prohibit-password
X11Forwarding no
ClientAliveInterval 120
ClientAliveCountMax 3
EOF

  # On stock Debian 9, the main sshd_config may not Include the drop-in dir, so
  # our file would be silently ignored. Detect that and add the Include line.
  if ! sshd -T 2>/dev/null | grep -qi '^x11forwarding no'; then
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
      warn "sshd doesn't Include the drop-in dir — adding the Include line."
      # Prepend so it's parsed before any 'Match' blocks in the main file.
      printf 'Include /etc/ssh/sshd_config.d/*.conf\n%s' "$(cat /etc/ssh/sshd_config)" > /etc/ssh/sshd_config.tmp \
        && mv /etc/ssh/sshd_config.tmp /etc/ssh/sshd_config
    fi
  fi
  # Only reload if the resulting config is valid — never restart into a broken
  # sshd that could drop you.
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "sshd config valid; reloaded."
  else
    warn "sshd config test FAILED — not reloading. Check /etc/ssh/sshd_config.d/10-ckg2.conf."
  fi
fi

# --- 4. firewall ------------------------------------------------------------
# Default deny inbound, allow SSH. Add your own service ports afterwards, e.g.
#   ufw allow 80/tcp
log "Configuring ufw (default deny inbound, allow SSH)…"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable

# --- 5. timekeeping ---------------------------------------------------------
# The RTC is backed by the PMIC + the internal battery pack (which can swell —
# see the README safety note). Lean on NTP so a dead battery doesn't matter.
log "Enabling NTP time sync…"
timedatectl set-ntp true 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null || true

ok "Provisioning complete."
log "Next: ./30-mount-storage.sh /dev/sda   and   ./40-install-lcd.sh"
warn "Reminder: install an SSH key, verify key login, THEN disable password auth."
