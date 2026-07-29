#!/usr/bin/env bash
# 05-add-ssh-key.sh — install an SSH public key for a user (root by default) so
# you have a second, independent way in BEFORE you start removing things.
#
# Why this matters: on a stock CloudKey your only access is usually "root with
# the password you set in the UniFi OS GUI." That password survives de-UniFi
# (it's in /etc/shadow, not the UniFi database) — but you should not bet your
# only access on it during surgery. Install a key, TEST it on a fresh
# connection, and only then proceed. See docs/09-accounts-and-access.md.
#
# This script ONLY adds a key. It does not remove password auth and cannot lock
# you out.
#
# Usage:
#   ./05-add-ssh-key.sh ~/id_ed25519.pub                 # from a .pub file
#   ./05-add-ssh-key.sh "ssh-ed25519 AAAA...you@host"    # from a literal string
#   ./05-add-ssh-key.sh --user admin ~/id_ed25519.pub    # for another user

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

USER_NAME="root"
if [[ "${1:-}" == "--user" ]]; then USER_NAME="$2"; shift 2; fi
KEY_INPUT="${1:?Usage: $0 [--user NAME] <pubkey-file | \"ssh-... key string\">}"

require_root

# Accept either a path to a .pub file or the key text directly.
if [[ -f "$KEY_INPUT" ]]; then
  KEY="$(cat "$KEY_INPUT")"
else
  KEY="$KEY_INPUT"
fi
KEY="$(printf '%s' "$KEY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

# Sanity-check it looks like an OpenSSH public key.
if ! printf '%s' "$KEY" | grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+)@openssh\.com) [A-Za-z0-9+/=]+'; then
  die "that doesn't look like an SSH public key. Pass a *.pub file or the full 'ssh-ed25519 AAAA...' string (NOT a private key)."
fi

# Resolve the user's home directory.
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || die "user '$USER_NAME' has no home directory."

SSH_DIR="$HOME_DIR/.ssh"
AK="$SSH_DIR/authorized_keys"
install -d -m 0700 -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" "$SSH_DIR"
touch "$AK"

if grep -qxF "$KEY" "$AK" 2>/dev/null; then
  ok "key already present in $AK — nothing to do."
else
  printf '%s\n' "$KEY" >> "$AK"
  ok "added key to $AK"
fi
chmod 0600 "$AK"
chown "$USER_NAME:$(id -gn "$USER_NAME")" "$AK"

echo
warn "NOW VERIFY IT before doing anything destructive:"
IP="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' | xargs -r -I{} ip -o -4 addr show {} | awk '{print $4}' | cut -d/ -f1 | head -1)"
echo "  From your workstation, open a NEW terminal and run:"
echo "      ssh -o PubkeyAuthentication=yes -o PasswordAuthentication=no ${USER_NAME}@${IP:-<cloudkey-ip>}"
echo "  You should get in WITHOUT being asked for a password. Keep this current"
echo "  session open until that succeeds."
echo
log "Only once key login is confirmed should you run 10-deunifi.sh."
log "Do NOT disable password auth yet — see docs/09-accounts-and-access.md for the safe order."
