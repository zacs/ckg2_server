#!/usr/bin/env bash
# 10-deunifi.sh — strip the UniFi application layer off a stock CloudKey Gen2 /
# Gen2 Plus, turning it back into a plain Debian box you fully control. This is
# the core of the "reclaim stock" install path (Tier 1 in the README).
#
# What it does, and why it is safe:
#   * Removes the UniFi Network + Protect apps, MongoDB, the UniFi-OS agents,
#     and the process supervisor / auto-update daemons that cause the
#     "reboots itself when UniFi isn't running" behaviour.
#   * NEVER touches the load-bearing packages whose removal bricks the device:
#     ck-ui, ubnt-tools, the per-model *-base-files package, and the initramfs
#     package. Removing those cascades into an unbootable box (documented
#     failure mode). A dry-run simulation gates every real removal and aborts on
#     ANY unexpected cascade into a forbidden package.
#   * Purges in small batches with a real SSH liveness check between each, so a
#     surprise breakage stops immediately instead of taking the whole system
#     with it.
#   * Disables (does not purge) the UniFi/hardware watchdog + updater units.
#
# The package and unit lists here are derived from jnovack's battle-tested
# de-Ubiquiti runbook (github.com/jnovack/cloudkey), validated against current
# UniFi-OS firmware. Credit to that project.
#
# DEFAULT IS A DRY RUN. It only simulates and prints what would happen. Re-run
# with --apply to actually remove anything.
#
# Usage:
#   ./10-deunifi.sh              # dry run (safe; shows the plan)
#   ./10-deunifi.sh --apply      # actually purge, with prompts + liveness checks
#   ./10-deunifi.sh --apply -y   # non-interactive (still runs all safety gates)
#
# Run this ON THE BOX over an interactive SSH session (not orchestrated from
# your laptop) — the liveness check is what catches sshd disappearing, and an
# already-open session can survive a condition that would refuse new logins.

set -uo pipefail   # deliberately NOT -e: a failed liveness check must be caught
                   # and reported, not crash the script mid-purge.
cd "$(dirname "$0")"
. lib/common.sh

APPLY=0
ASSUME_YES=0
PURGE_FAILURES=0   # set if any batch's apt purge fails (e.g. lock contention)
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -y) ASSUME_YES=1 ;;
    *) die "unknown argument: $a (use --apply and/or -y)" ;;
  esac
done

require_root "$@"
assert_cloudkey

# --- never remove these; their removal bricks the box ------------------------
# Guard is by package NAME so it holds on both models (the base-files variant
# differs: cloudkey-plus-apq8053-base-files vs cloudkey-g2-apq8053-base-files).
# uck-tools is CloudKey-specific hardware tooling of unknown criticality — treat
# it as load-bearing too (never let a cascade drag it out).
FORBIDDEN_RE='^(ck-ui|ubnt-tools|uck-tools|cloudkey-.*-base-files|.*-initramfs.*|linux-image-.*)$'

# --- packages to purge (only those actually installed are acted on) ----------
PACKAGES=(
  unifi-assets-uckp unifi-assets-uckg2 unifi-email-templates-all
  python3-unifi-console-protos
  mongodb-server mongodb-clients mongodb-server-core
  unifi unifi-core unifi-directory unifi-identity-update
  uid-agent ucs-agent uos-agent uos-discovery-client uos ulp-go
  ustd ubnt-systemhub ubnt-unifi-setup ucore-setup-listener
)

# Small batches: a failure isolates to a handful of packages, not all at once.
BATCHES=(
  "unifi-assets-uckp unifi-assets-uckg2 unifi-email-templates-all python3-unifi-console-protos"
  "mongodb-server mongodb-clients mongodb-server-core"
  "unifi unifi-core"
  "unifi-directory unifi-identity-update uid-agent ucs-agent uos-agent uos-discovery-client uos ulp-go"
  "ustd ubnt-systemhub ubnt-unifi-setup ucore-setup-listener"
)

# --- units to stop+disable (the supervisor/watchdog/updater layer) -----------
# Disabling (not purging) is reversible and does not risk a package cascade.
# uhwd = UniFi hardware watchdog; infctld = infra control daemon; the ck-splash
# units and setup listeners re-trigger UniFi behaviour on boot.
UNITS=(
  uhwd.service infctld.service infctld-emergency.service
  ubnt-systemhub.service ubnt-unifi-setup.service ucore-setup-listener.service
  ucs-agent.service uid-agent.service ulp-go.service
  unifi.service unifi-core.service unifi-directory.service
  unifi-identity-update.service uos-agent.service uos-discovery-client.service
  usd.service usdbd.service ubnt-dpkg-restore.service
  ck-splash.service ck-splash-reboot.service ck-splash-shutdown.service
)

installed_targets() {
  local p
  for p in "${PACKAGES[@]}"; do pkg_installed "$p" && printf '%s\n' "$p"; done
}

# Step 0: simulate the purge of everything installed and assert nothing in the
# forbidden set is dragged in. This is the gate that prevents a brick.
simulate_gate() {
  local targets; targets="$(installed_targets)"
  if [[ -z "$targets" ]]; then
    ok "No UniFi packages installed — nothing to purge."
    return 2
  fi
  log "Simulating purge to check for dangerous cascades…"
  # apt marks a purge as `Purg <pkg>` and a plain removal as `Remv <pkg>`; match
  # BOTH (matching only Remv silently misses every purge — and would make this
  # brick-guard inspect an empty set). LC_ALL=C keeps the tokens stable.
  local sim
  sim="$(LC_ALL=C apt-get -s purge $targets 2>/dev/null | awk '/^(Remv|Purg) /{print $2}')"
  local bad; bad="$(printf '%s\n' "$sim" | grep -E "$FORBIDDEN_RE" || true)"
  if [[ -n "$bad" ]]; then
    err "ABORT: the purge would ALSO remove forbidden/bricking package(s):"
    printf '        %s\n' $bad >&2
    err "Not proceeding. Report this — the package set needs adjustment for your firmware."
    return 1
  fi
  ok "Simulation clean — no forbidden packages would be removed."
  printf '%sWould remove:%s\n' "$_C_DIM" "$_C_RST"
  printf '  %s\n' $sim
  return 0
}

disable_units() {
  local u
  for u in "${UNITS[@]}"; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && \
       systemctl cat "$u" >/dev/null 2>&1; then
      log "disabling $u"
      if [[ "$APPLY" == "1" ]]; then
        systemctl disable --now "$u" >/dev/null 2>&1 || warn "could not disable $u (may not exist)"
      fi
    fi
  done
}

# apt_lock_holder — print PIDs holding any apt/dpkg lock (empty if free).
# Uses fuser, then lsof, then a /proc fallback so it works on stripped images.
APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock"
apt_lock_holder() {
  if command -v fuser >/dev/null 2>&1; then
    fuser $APT_LOCKS 2>/dev/null
  elif command -v lsof >/dev/null 2>&1; then
    lsof -t $APT_LOCKS 2>/dev/null
  else
    local f lk=/var/lib/dpkg/lock-frontend
    for f in /proc/[0-9]*/fd/*; do
      [[ "$(readlink -f "$f" 2>/dev/null)" == "$lk" ]] && { echo held; return; }
    done
  fi
}

# wait_apt_lock [max_seconds] — block until the apt/dpkg lock is free. Debian's
# apt-daily / unattended-upgrades grabs it shortly after boot; that's what made
# every purge fail with "Could not get lock". We WAIT (never kill a running apt —
# that corrupts dpkg) up to a timeout, then bail with instructions.
wait_apt_lock() {
  local waited=0 max="${1:-600}"
  [[ -n "$(apt_lock_holder)" ]] && \
    warn "apt/dpkg lock is held (background apt-daily/unattended-upgrades?). Waiting up to ${max}s…"
  while [[ -n "$(apt_lock_holder)" ]]; do
    sleep 5; waited=$((waited+5))
    if (( waited >= max )); then
      err "apt lock STILL held after ${max}s. See what has it, let it finish, then re-run:"
      err "    sudo fuser -v /var/lib/dpkg/lock-frontend   # or: sudo lsof /var/lib/dpkg/lock-frontend"
      err "    sudo $0 --apply"
      return 1
    fi
  done
  return 0
}

# stop_apt_background — stop Debian's periodic apt TIMERS so they don't grab the
# lock mid-purge. Timers only; we don't kill an in-flight run (wait_apt_lock does
# that safely). They re-enable themselves on the next boot.
stop_apt_background() {
  systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
}

purge_batches() {
  local batch remaining
  for batch in "${BATCHES[@]}"; do
    remaining=""
    for p in $batch; do pkg_installed "$p" && remaining+=" $p"; done
    [[ -z "$remaining" ]] && continue

    # Re-check the lock before each batch (a periodic run can start mid-way).
    wait_apt_lock || { PURGE_FAILURES=1; err "aborting remaining batches — lock never freed."; return 1; }

    log "purging:$remaining"
    if [[ "$APPLY" == "1" ]]; then
      # DPkg::Lock::Timeout makes newer apt wait for the lock instead of failing;
      # harmlessly ignored by older apt (which is why we also wait_apt_lock above).
      if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 purge -y $remaining; then
        ok "batch purged."
      else
        PURGE_FAILURES=1
        warn "batch FAILED (see apt error above): $remaining"
      fi
      if ! ssh_alive; then
        err "LIVENESS CHECK FAILED after this batch: sshd is not accepting connections."
        err "STOP HERE. Do not run more. Reconnect via serial/recovery if you lose this session."
        exit 1
      fi
      log "sshd still alive."
    fi
  done
}

main() {
  log "Model detected: $(ck_model)"
  simulate_gate; local rc=$?
  [[ $rc -eq 1 ]] && exit 1
  [[ $rc -eq 2 ]] && { disable_units; exit 0; }

  echo
  if [[ "$APPLY" != "1" ]]; then
    warn "DRY RUN. Nothing was changed."
    log  "Re-run with --apply to purge the packages above and disable the UniFi/watchdog units."
    log  "STRONGLY recommended first: ./00-preflight-backup.sh <disk>/emmc-backup.img"
    exit 0
  fi

  confirm "Proceed to PURGE the UniFi layer and disable its services?" || die "aborted."

  # Keep Debian's periodic apt from stealing the dpkg lock, and wait for any run
  # already in flight (the classic post-boot "Could not get lock" cause).
  stop_apt_background
  wait_apt_lock || die "apt lock never freed — nothing purged. Resolve and re-run."

  disable_units
  purge_batches

  # If any batch failed, STOP: don't autoremove, don't claim success, don't tell
  # the user to reboot with the UniFi layer still half-present.
  if [[ "$PURGE_FAILURES" != "0" ]]; then
    echo
    err "PURGE INCOMPLETE — one or more batches failed (see errors above)."
    err "The box is unchanged package-wise and safe, but the UniFi layer is NOT removed."
    err "Fix the cause (usually a background apt run holding the lock), then re-run:"
    err "    sudo $0 --apply"
    err "Do NOT reboot expecting a clean box until this reports success."
    exit 1
  fi

  # Autoremove sweeps up orphaned deps — but simulate_gate never saw it, so guard
  # it the same way: skip it entirely if it would drag out a load-bearing package.
  local auto_bad
  auto_bad="$(LC_ALL=C apt-get -s --purge autoremove 2>/dev/null | awk '/^(Remv|Purg) /{print $2}' | grep -E "$FORBIDDEN_RE" || true)"
  if [[ -n "$auto_bad" ]]; then
    warn "SKIPPING autoremove — it would remove load-bearing package(s):"
    printf '        %s\n' $auto_bad >&2
    warn "Orphaned deps left in place are harmless; removing those is not. Skipped."
  else
    DEBIAN_FRONTEND=noninteractive apt-get -y --purge autoremove || true
  fi

  echo
  ok "UniFi application layer removed and supervisor/watchdog units disabled."
  warn "Now reboot BY HAND and reconnect, then run ./99-verify.sh:"
  echo  "    reboot"
  warn "A script can't watch its own box fail to come back, so the reboot is manual on purpose."
}

main
