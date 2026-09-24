#!/usr/bin/env bash
# 20-provision.sh — turn the reclaimed Debian into a pleasant little server:
# base tooling, sane SSH, automatic updates, time sync, and the housekeeping
# that keeps UniFi's leftovers from getting in the way.
#
# Firewall: like a stock Debian/Ubuntu install, ufw is installed but left OFF,
# so anything you install is reachable on the LAN with no per-app rules. Pass
# --firewall to turn on ufw (deny incoming, allow SSH) instead; then every app
# needs a `ufw allow <port>`.
#
# Idempotent: safe to run more than once. Everything it writes lives in places
# the CloudKey's boot hooks do NOT rewrite (see the /etc/fstab caveat in
# 30-mount-storage.sh and docs/05-watchdog-and-persistence.md).
#
# Run AFTER 10-deunifi.sh and a reboot.
#
# Usage: ./20-provision.sh [-y] [--firewall]

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

ASSUME_YES=0
FIREWALL=0
for a in "$@"; do
  case "$a" in
    -y) ASSUME_YES=1 ;;
    --firewall) FIREWALL=1 ;;
    *) die "unknown argument: $a (use -y and/or --firewall)" ;;
  esac
done

require_root "$@"
assert_cloudkey

log "Architecture: kernel=$(uname -m)  userland=$(dpkg --print-architecture)"
log "(Current firmware: aarch64 kernel + arm64 userland. Very old firmware shipped armhf.)"

# Debian 11 "bullseye" (Cloud Key firmware 5.x and older) left LTS on
# 2026-08-31: the unattended-upgrades set up below keep running but receive
# NOTHING new. Firmware 6.x is Debian 13. Say so rather than let "automatic
# security updates" imply more than it does.
. /etc/os-release 2>/dev/null || true
if [[ "${VERSION_CODENAME:-}" == "bullseye" ]]; then
  warn "This is Debian 11 (bullseye), which reached end-of-life on 2026-08-31 — no further"
  warn "security updates will arrive. Update the stock firmware to 6.x (Debian 13) first:"
  warn "see 'Modernizing the userland' in docs/02-install.md."
fi

# --- 1. base packages --------------------------------------------------------
# Only what this repo's scripts need or what keeps the box healthy; anything
# else is your call (e.g. `apt install htop tmux vim`).
#   ca-certificates, curl  HTTPS downloads (apt, 41-install-cloudkey.sh)
#   git                    fetch/update this repo
#   rsync                  35-rehome-storage.sh copies directories with it
#   e2fsprogs              mkfs.ext4 for 30-mount-storage.sh
#   smartmontools          smartctl: health of the USB-attached SATA disk
#   unattended-upgrades    automatic Debian security updates (step 2)
# The panel tools bring their own deps (40-install-lcd.sh installs Python +
# Pillow; the jnovack daemon is a static binary), and ufw only comes with
# --firewall.
log "Installing base packages…"
export DEBIAN_FRONTEND=noninteractive
PKGS=(ca-certificates curl git rsync e2fsprogs smartmontools unattended-upgrades)
[[ "$FIREWALL" == "1" ]] && PKGS+=(ufw)
apt-get update
apt-get install -y --no-install-recommends "${PKGS[@]}"

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
# docs/06-accounts-and-access.md.
if [[ -f /etc/ssh/sshd_config ]]; then
  log "Applying safe SSH defaults (no auth changes)…"
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-ckg2.conf <<'EOF'
# ckg2_server SSH drop-in — intentionally contains NO auth-restricting settings.
# To harden AFTER you've installed and TESTED an SSH key (see
# docs/06-accounts-and-access.md), add here and reload sshd:
#     PasswordAuthentication no
#     ChallengeResponseAuthentication no   # OpenSSH 8.4 (bullseye) name...
#     KbdInteractiveAuthentication no      # ...and the >= 8.7 name; set both
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

# --- 4. firewall (opt-in) ---------------------------------------------------
# Default: leave it alone. ufw is installed but inactive, exactly like a stock
# Ubuntu install, so a newly installed app is reachable with no extra steps.
# Without --firewall this script never enables OR disables ufw, so a choice
# you made by hand survives re-runs.
if [[ "$FIREWALL" == "1" ]]; then
  # Default deny inbound, allow SSH. Add your own service ports afterwards,
  # e.g. `ufw allow 80/tcp`. No `ufw reset`: it would wipe your rules on every
  # re-run; the commands below are no-ops when the rule/policy already exists.
  # Allow the port(s) sshd ACTUALLY listens on (not the OpenSSH app profile,
  # which assumes 22 and only exists if openssh-server shipped it).
  log "Configuring ufw (default deny inbound, allow SSH)…"
  SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u || true)"
  [[ -n "$SSH_PORTS" ]] || SSH_PORTS=22
  ufw default deny incoming
  ufw default allow outgoing
  for p in $SSH_PORTS; do ufw allow "$p/tcp" comment 'ssh'; done
  ufw --force enable
  warn "Firewall ON: each app you install needs its port opened, e.g. sudo ufw allow 3000/tcp"
elif ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "ufw is active (enabled earlier) — leaving it as is. To go back to the"
  log "stock-Ubuntu behaviour (no per-app rules), run: sudo ufw disable"
else
  log "Firewall: off (stock Debian/Ubuntu default). Every listening service is"
  log "reachable on the LAN — fine behind a router; don't port-forward to this box."
  log "Want one anyway? Re-run with --firewall."
fi

# --- 5. timekeeping ---------------------------------------------------------
# The RTC is backed by the PMIC + the internal battery pack (which can swell —
# see the README safety note). Lean on NTP so a dead battery doesn't matter.
# Since Debian 11, systemd-timesyncd is its OWN package, so `timedatectl set-ntp`
# fails ("NTP not supported") if nothing provides it. Use an existing NTP
# daemon if there is one; otherwise install timesyncd (it Conflicts with the
# others, so never install it alongside one).
log "Enabling NTP time sync…"
NTPD=""
for p in chrony ntp ntpsec openntpd; do pkg_installed "$p" && { NTPD="$p"; break; }; done
if [[ -n "$NTPD" ]]; then
  log "using the already-installed $NTPD for time sync."
else
  pkg_installed systemd-timesyncd || apt-get install -y --no-install-recommends systemd-timesyncd
  timedatectl set-ntp true || systemctl enable --now systemd-timesyncd || \
    warn "could not enable systemd-timesyncd — check: timedatectl status"
fi

ok "Provisioning complete."
log "Next: ./30-mount-storage.sh /dev/sda   then the panel: ./41-install-cloudkey.sh (or ./40-install-lcd.sh)"
warn "Reminder: install an SSH key, verify key login, THEN disable password auth."
