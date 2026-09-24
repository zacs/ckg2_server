#!/usr/bin/env bash
# 41-install-cloudkey.sh — install jnovack/cloudkey, the mature Go front-panel
# daemon, as a richer alternative to this repo's minimal `cklcd`.
#
# What you get over cklcd: status LEDs, reset-button actions (short/long press
# "bands", stealth mode), OLED burn-in mitigation, and an optional web dashboard
# with a live event stream. See github.com/jnovack/cloudkey and docs/03-lcd.md.
#
# It pulls the pre-built binary from a pinned GitHub release (no cross-compile
# toolchain needed) and the matching systemd unit, env template and web-dashboard
# page from that same tag, so they always match the binary. Upstream publishes
# only a 32-bit ARM build; it runs on the arm64 userland of current firmware via
# the SoC's AArch32 compat mode (verified upstream on Gen2 and Gen2 Plus).
#
# Only ONE process may drive /dev/fb0. This script stops+disables both the stock
# `ck-ui` and this repo's `cklcd.service` before enabling `cloudkey.service`.
#
# The default release is pinned to a known-good sha256 (verified below); the
# install ABORTS if the download doesn't match. Bumping --tag to an unpinned
# release prompts unless you supply --sha256 or pass --no-verify.
#
# Usage:
#   ./41-install-cloudkey.sh                       # pinned default release, hash-verified
#   ./41-install-cloudkey.sh --tag v1.6.0 --sha256 <hash>   # a newer release you've verified
#   ./41-install-cloudkey.sh --tag v1.6.0 --no-verify       # opt out of hash check (not advised)
#   ./41-install-cloudkey.sh -y                    # non-interactive (still enforces the pinned hash)

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

REPO="jnovack/cloudkey"
DEFAULT_TAG="v1.5.0"          # pinned for reproducibility; override with --tag
ASSET="cloudkey-linux-arm"    # static 32-bit ARM binary — the only build upstream publishes
WEB_ROOT="/usr/share/cloudkey/website"   # the daemon's -web-root default

# Known-good sha256 for the DEFAULT_TAG asset, verified 2026-07-28 by fetching
# the release binary twice and confirming a stable hash. The install aborts if a
# future download of this tag doesn't match — that's the whole point of pinning.
# If you deliberately bump --tag, either pass --sha256 <hash> for the new asset
# or accept the (prompted) unpinned download.
PINNED_TAG="v1.5.0"
PINNED_SHA256="ce084b342e6f3218bb43243761f8ac3298e376cce4122c1dc8537a64e562a108"

TAG="$DEFAULT_TAG"
WANT_SHA=""            # explicit override via --sha256
NO_VERIFY=0           # deliberate opt-out for a custom, unpinned tag
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --sha256) WANT_SHA="$2"; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    -y) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1 (use --tag, --sha256, --no-verify, -y)" ;;
  esac
done

# Decide the expected hash: explicit --sha256 wins; otherwise the pinned hash
# applies only when we're actually installing the pinned tag.
EXPECT_SHA="$WANT_SHA"
if [[ -z "$EXPECT_SHA" && "$TAG" == "$PINNED_TAG" ]]; then
  EXPECT_SHA="$PINNED_SHA256"
fi

require_root
assert_cloudkey
command -v curl >/dev/null 2>&1 || { log "installing curl…"; apt-get install -y curl; }

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
case "$ARCH" in
  armhf) ;;
  arm64) log "userland is arm64; the 32-bit $ASSET runs via AArch32 compat (expected)." ;;
  *) warn "userland arch is '$ARCH' — the prebuilt $ASSET is 32-bit ARM; make sure your box can run it." ;;
esac

BIN_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
SVC_URL="https://raw.githubusercontent.com/${REPO}/${TAG}/cloudkey.service"
ENV_URL="https://raw.githubusercontent.com/${REPO}/${TAG}/cloudkey.env.example"
WEB_URL="https://raw.githubusercontent.com/${REPO}/${TAG}/website/dashboard.html"

log "About to install $REPO @ $TAG"
log "  binary:  $BIN_URL"
log "  service: $SVC_URL"
confirm "Download and install this third-party daemon?" || die "aborted."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading $ASSET…"
curl -fsSL -o "$TMP/cloudkey" "$BIN_URL" || die "download failed: $BIN_URL"
chmod 0755 "$TMP/cloudkey"

# Sanity guard: make sure we actually got an ARM ELF, not an HTML error page.
if command -v file >/dev/null 2>&1; then
  desc="$(file -b "$TMP/cloudkey")"
  log "downloaded: $desc"
  [[ "$desc" == *ELF*ARM* ]] || die "downloaded file is not an ARM ELF binary — refusing to install."
else
  head -c4 "$TMP/cloudkey" | grep -q $'\x7fELF' || die "downloaded file is not an ELF binary — refusing to install."
fi

# Integrity check against the pinned (or user-supplied) sha256.
GOT_SHA="$(sha256sum "$TMP/cloudkey" | awk '{print $1}')"
log "sha256: $GOT_SHA"
if [[ -n "$EXPECT_SHA" ]]; then
  if [[ "$GOT_SHA" == "$EXPECT_SHA" ]]; then
    ok "sha256 matches the pinned known-good hash for $TAG."
  else
    err "sha256 MISMATCH for $TAG!"
    err "  expected: $EXPECT_SHA"
    err "  got:      $GOT_SHA"
    die "refusing to install a binary that doesn't match the pinned hash. If this tag was legitimately re-released, pass --sha256 <new-hash> (after you've verified it) or --no-verify."
  fi
elif [[ "$NO_VERIFY" == "1" ]]; then
  warn "no pinned hash for $TAG and --no-verify given — installing unverified."
else
  warn "no pinned hash for $TAG (only $PINNED_TAG is pinned in this script)."
  warn "record the sha256 above and re-run with --sha256 $GOT_SHA to pin it, or pass --no-verify to proceed."
  confirm "Install this UNVERIFIED binary anyway?" || die "aborted — no hash verification."
fi

log "Fetching matching service + env (tag $TAG)…"
curl -fsSL -o "$TMP/cloudkey.service" "$SVC_URL" || die "could not fetch cloudkey.service"
curl -fsSL -o "$TMP/cloudkey.env.example" "$ENV_URL" || die "could not fetch cloudkey.env.example"
# The optional web dashboard (CLOUDKEY_HTTP_PORT) serves this page from
# $WEB_ROOT; without it the dashboard has nothing to show. Non-fatal.
curl -fsSL -o "$TMP/dashboard.html" "$WEB_URL" || warn "could not fetch dashboard.html — the optional web dashboard won't have a page."

# Hand the panel over: stop everything else that drives /dev/fb0.
for svc in ck-ui.service cklcd.service; do
  if systemctl cat "$svc" >/dev/null 2>&1; then
    log "disabling $svc (only one process may own /dev/fb0)…"
    systemctl disable --now "$svc" 2>/dev/null || true
  fi
done

log "Installing…"
install -m 0755 "$TMP/cloudkey" /usr/local/bin/cloudkey
install -m 0644 "$TMP/cloudkey.service" /etc/systemd/system/cloudkey.service
[[ -f /etc/cloudkey.env ]] || install -m 0644 "$TMP/cloudkey.env.example" /etc/cloudkey.env
if [[ -s "$TMP/dashboard.html" ]]; then
  install -d -m 0755 "$WEB_ROOT"
  install -m 0644 "$TMP/dashboard.html" "$WEB_ROOT/dashboard.html"
fi

systemctl daemon-reload
systemctl enable --now cloudkey.service
sleep 2

echo
journalctl -u cloudkey.service -n 20 --no-pager || true
echo
if systemctl is-active --quiet cloudkey.service; then
  ok "cloudkey.service running — the panel should show its status screens."
  log "Configure LEDs / button / web dashboard in /etc/cloudkey.env, then: systemctl restart cloudkey"
  log "Expect the panel resolution in the log above (160x60), not an error opening /dev/fb0."
else
  err "cloudkey.service failed to start — see the log above."
  exit 1
fi
