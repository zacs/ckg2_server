#!/usr/bin/env bash
# 99-verify.sh — post-install health check. Read-only; changes nothing.
# Run after a reboot to confirm the box came back clean and everything the
# project cares about is working: no UniFi supervisor left running, SSH up,
# storage mounted, LCD service alive, network/PoE sane.

set -uo pipefail
cd "$(dirname "$0")"
. lib/common.sh

pass=0; fail=0
check() { # check "label" command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; pass=$((pass+1));
  else err "$label"; fail=$((fail+1)); fi
}

echo "== identity =="
log "model:    $(ck_model)"
log "uname:    $(uname -srm)"
log "userland: $(dpkg --print-architecture 2>/dev/null)"
log "os:       $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
log "uptime:   $(uptime -p 2>/dev/null || cat /proc/uptime)"

echo; echo "== services =="
check "sshd accepting connections" ssh_alive
check "no UniFi 'unifi' service active"        bash -c '! systemctl is-active --quiet unifi.service'
check "no UniFi supervisor (uhwd) active"      bash -c '! systemctl is-active --quiet uhwd.service'
check "no infctld active"                      bash -c '! systemctl is-active --quiet infctld.service'
# One (and only one) front-panel daemon should be running.
if systemctl is-active --quiet cloudkey.service 2>/dev/null; then
  ok "front-panel daemon active: cloudkey (jnovack)"; pass=$((pass+1))
elif systemctl is-active --quiet cklcd.service 2>/dev/null; then
  ok "front-panel daemon active: cklcd"; pass=$((pass+1))
elif systemctl list-unit-files 'cklcd.service' 'cloudkey.service' >/dev/null 2>&1; then
  warn "an LCD service is installed but not active (check 40-/41-install-*.sh)"
fi
if systemctl is-active --quiet cloudkey.service 2>/dev/null && \
   systemctl is-active --quiet cklcd.service 2>/dev/null; then
  err "BOTH cloudkey and cklcd are active — they will fight over /dev/fb0. Disable one."; fail=$((fail+1))
fi

echo; echo "== storage =="
if [[ -b /dev/sda ]]; then
  ok "/dev/sda present ($(lsblk -dno SIZE /dev/sda 2>/dev/null | tr -d ' '))"
  if findmnt -rno TARGET /dev/sda >/dev/null 2>&1 || findmnt /volume >/dev/null 2>&1; then
    ok "bulk disk mounted: $(findmnt -rno TARGET,SOURCE /volume 2>/dev/null || findmnt -rno TARGET /dev/sda*)"
  else
    warn "SATA disk present but not mounted (run 30-mount-storage.sh)"
  fi
else
  warn "/dev/sda not present (no internal disk installed?)"
fi
log "eMMC: $(lsblk -dno NAME,SIZE /dev/mmcblk0 2>/dev/null)"
# Rehomed dirs (35-rehome-storage.sh) — anything still on the eMMC keeps wearing it.
for d in /home /srv /var/log; do
  src="$(findmnt -rno SOURCE "$d" 2>/dev/null || true)"
  if [[ -n "$src" && "$src" != /dev/mmcblk* ]]; then
    ok "$d rehomed (from $src)"
  else
    log "$d on root/eMMC (not rehomed)"
  fi
done

echo; echo "== docker (if installed) =="
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
    drv="$(docker info -f '{{.Driver}}' 2>/dev/null)"
    rootsrc="$(findmnt -rno SOURCE -T "$root" 2>/dev/null || true)"
    if [[ -n "$rootsrc" && "$rootsrc" != /dev/mmcblk* ]]; then
      ok "docker data-root $root on $rootsrc (off the eMMC), driver=$drv"; pass=$((pass+1))
    else
      warn "docker data-root $root is on the eMMC ($rootsrc) — see 50-install-docker.sh / docs/10"
    fi
  else
    warn "docker installed but daemon not responding (journalctl -u docker)"
  fi
else
  log "docker not installed"
fi

echo; echo "== network / PoE =="
# NIC is the USB ASIX AX88179; if you're reading this over SSH, PoE/USB-C power
# and the NIC are obviously fine, but report the details anyway.
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
if [[ -n "${IFACE:-}" ]]; then
  ok "default route via $IFACE, IP $(ip -o -4 addr show "$IFACE" | awk '{print $4}' | head -1)"
  DRV="$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver" 2>/dev/null)" 2>/dev/null)"
  log "NIC driver: ${DRV:-unknown} (expect ax88179_178a — USB gigabit)"
else
  err "no default route found"
fi

echo; echo "== panel =="
# Report the framebuffer and the LCD daemon independently (they're separate
# concerns — the panel isn't taken over until the LCD step).
if [[ -e /dev/fb0 ]]; then
  ok "framebuffer /dev/fb0 present"
  if command -v cklcd >/dev/null 2>&1; then
    log "$(cklcd probe 2>&1 || echo 'cklcd probe failed')"
  else
    log "cklcd not installed yet — run 40-install-lcd.sh or 41-install-cloudkey.sh"
  fi
else
  warn "/dev/fb0 not present. Before the LCD step this may be normal; if it persists, check:"
  warn "   ls /dev/fb* ; cat /proc/fb ; dmesg | grep -iE 'fb|ssd|oled|drm'"
fi

echo; echo "== thermals (fanless — keep an eye on this) =="
# Many Qualcomm thermal zones are unpopulated and read 0°C — skip those.
skipped=0
for z in /sys/class/thermal/thermal_zone*/temp; do
  [[ -r "$z" ]] || continue
  t=$(cat "$z" 2>/dev/null); c=$((t/1000))
  if (( c == 0 )); then skipped=$((skipped+1)); continue; fi
  printf '   %s: %s°C\n' "$(dirname "$z" | xargs basename)" "$c"
done
(( skipped > 0 )) && printf '   (%d unpopulated 0°C zones hidden)\n' "$skipped"

echo
if [[ "$fail" -eq 0 ]]; then ok "All $pass checks passed."; else err "$fail check(s) failed, $pass passed."; fi
exit "$fail"
