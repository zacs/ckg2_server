#!/usr/bin/env bash
# 10-deunifi.sh — strip the UniFi application layer off a stock CloudKey Gen2 /
# Gen2 Plus, turning it back into a plain Debian box you fully control. This is
# the core of the install (see docs/02-install.md).
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

# Prerequisite: current stock firmware. 6.x is Debian 13; 5.x and older are
# Debian 11 (bullseye), which lost security support on 2026-08-31. Update the
# firmware BEFORE de-UniFi — on this 3.18 kernel that's the supported way off
# bullseye (docs/02-install.md, "Modernizing the userland").
. /etc/os-release 2>/dev/null || true
if [[ "${VERSION_CODENAME:-}" == "bullseye" ]]; then
  warn "This box runs Debian 11 (bullseye) = Cloud Key firmware 5.x or older, which gets"
  warn "no security updates. Update the stock firmware to 6.x FIRST:"
  warn "    ubnt-systool fwupdate <URL of the newest UCKP/UCKG2 .bin from ui.com>"
  confirm "De-UniFi on bullseye anyway?" || die "aborted — update the firmware, then re-run."
fi

# --- never remove these; their removal bricks the box ------------------------
# Guard is by package NAME so it holds on both models (the base-files variant
# differs: cloudkey-plus-apq8053-base-files vs cloudkey-g2-apq8053-base-files).
# uck-tools is CloudKey-specific hardware tooling of unknown criticality — treat
# it as load-bearing too (never let a cascade drag it out).
FORBIDDEN_RE='^(ck-ui|ubnt-tools|uck-tools|cloudkey-.*-base-files|.*-initramfs.*|linux-image-.*)$'

# --- packages to purge, in small batches -------------------------------------
# A failure isolates to a handful of packages, not all at once. Only packages
# actually present (installed, or config files left) are acted on, so names
# from other firmware versions are harmless. The last two batches were seen on
# firmware 6.x: fluent-bit is UniFi OS's log shipper, and PostgreSQL 14 + 16
# are UniFi's own databases (nothing kept needs them; install a fresh one later
# if an app of yours wants Postgres — don't re-run this script after that).
BATCHES=(
  "unifi-assets-uckp unifi-assets-uckg2 unifi-email-templates-all python3-unifi-console-protos"
  "mongodb-server mongodb-clients mongodb-server-core"
  "unifi unifi-core"
  "unifi-directory unifi-identity-update uid-agent ucs-agent uos-agent uos-discovery-client uos ulp-go"
  "ustd ubnt-systemhub ubnt-unifi-setup ucore-setup-listener fluent-bit"
  "postgresql-14 postgresql-16 postgresql-client-14 postgresql-client-16 postgresql-client-common postgresql-common"
)
# One list, derived from the batches, so a package can't be approved by the
# simulation below yet sit in no batch and never actually get purged.
read -ra PACKAGES <<< "${BATCHES[*]}"

# --- units to stop+disable (the supervisor/watchdog/updater layer) -----------
# Disabling (not purging) is reversible and does not risk a package cascade.
# uhwd = UniFi hardware watchdog; infctld = Ubiquiti's network-discovery daemon
# (UDP 10001 + CDP; from the kept ubnt-tools package — disabled because nothing
# needs it, not because it reboots anything); the ck-splash units and setup
# listeners re-trigger UniFi behaviour on boot. ck-ui.service is deliberately
# NOT here: it keeps driving the front panel until 40-/41-install-*.sh take it.
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
  for p in "${PACKAGES[@]}"; do pkg_present "$p" && printf '%s\n' "$p"; done
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
  # Fail CLOSED: if the simulation itself errors (broken deps, bad state), the
  # parsed list is empty and "nothing forbidden" would be vacuously true.
  local raw sim
  if ! raw="$(LC_ALL=C apt-get -s purge $targets 2>&1)"; then
    err "ABORT: the purge simulation itself failed — can't vouch for what it would remove:"
    printf '%s\n' "$raw" | tail -n 15 >&2
    return 1
  fi
  sim="$(printf '%s\n' "$raw" | awk '/^(Remv|Purg) /{print $2}')"
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
      if [[ "$APPLY" == "1" ]]; then
        log "disabling $u"
        systemctl disable --now "$u" >/dev/null 2>&1 || warn "could not disable $u (may not exist)"
      else
        log "would disable $u"
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

# --- maintainer-script quirks seen on firmware 6.x ----------------------------
# prep_postgres_manpages — PostgreSQL's removal script re-registers the
# psql.1.gz man-page alternative, whose main file
# (/usr/share/postgresql/<ver>/man/man1/psql.1.gz) this firmware image doesn't
# ship. update-alternatives treats a missing main file as fatal, so the purge
# dies ("alternative path ... doesn't exist"). An empty placeholder satisfies
# it; missing secondary pages only warn. Removed again once Postgres is gone.
prep_postgres_manpages() {
  local p v f
  for p in $(dpkg-query -W -f='${Package}\n' 'postgresql-[0-9]*' 'postgresql-client-[0-9]*' 2>/dev/null); do
    pkg_present "$p" || continue
    v="${p##*-}"; [[ "$v" =~ ^[0-9]+$ ]] || continue
    f="/usr/share/postgresql/$v/man/man1/psql.1.gz"
    [[ -e "$f" ]] && continue
    mkdir -p "${f%/*}" && : > "$f"
    log "placeholder $f (the firmware ships no man pages; PostgreSQL's removal script needs this one)"
  done
}

# cleanup_postgres_placeholders — once no PostgreSQL package is left at all,
# /usr/share/postgresql holds nothing but our placeholders.
cleanup_postgres_placeholders() {
  [[ -d /usr/share/postgresql ]] || return 0
  dpkg-query -W -f='${db:Status-Status}\n' 'postgresql*' 2>/dev/null | grep -qvx 'not-installed' && return 0
  rm -rf /usr/share/postgresql
}

# purge_leftover_configs PKG... — a package with only config files left
# ("rc"/"ic") runs nothing but its postrm when purged. Some Ubiquiti postrm
# scripts exit non-zero when the database they try to drop never existed
# (seen: ucs-agent on 6.0.10), which blocks that purge forever. Its program
# files are already gone, so skip the script and purge the dpkg record.
purge_leftover_configs() {
  local p st script
  for p in "$@"; do
    st="$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true)"
    [[ "$st" == config-files ]] || continue
    warn "$p: only config files were left and its purge script failed — skipping that script."
    script="$(dpkg-query --control-path "$p" postrm 2>/dev/null || true)"
    [[ -n "$script" && -f "$script" ]] && printf '#!/bin/sh\nexit 0\n' > "$script"
    dpkg --purge "$p" || warn "dpkg --purge $p still failed"
  done
}

purge_batches() {
  local batch remaining left
  for batch in "${BATCHES[@]}"; do
    remaining=""
    for p in $batch; do pkg_present "$p" && remaining+=" $p"; done
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
        warn "apt reported errors for this batch — checking what's left…"
        purge_leftover_configs $remaining
        left=""
        for p in $remaining; do pkg_present "$p" && left+=" $p"; done
        if [[ -z "$left" ]]; then
          ok "batch purged (after cleaning up config-only leftovers)."
        else
          PURGE_FAILURES=1
          warn "batch FAILED — still present:$left (see the apt error above)"
        fi
      fi
      if ! ssh_alive; then
        err "LIVENESS CHECK FAILED after this batch: sshd is not accepting connections."
        err "STOP HERE. Do not run more. If you lose this session, the way back is Recovery Mode (docs/04-recovery.md)."
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
    log  "STRONGLY recommended first: a full eMMC backup (README step 0), e.g. from your workstation:"
    log  "    ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz && gzip -t cloudkey-emmc.img.gz"
    exit 0
  fi

  confirm "Proceed to PURGE the UniFi layer and disable its services?" || die "aborted."

  # Keep Debian's periodic apt from stealing the dpkg lock, and wait for any run
  # already in flight (the classic post-boot "Could not get lock" cause).
  stop_apt_background
  wait_apt_lock || die "apt lock never freed — nothing purged. Resolve and re-run."

  disable_units
  prep_postgres_manpages
  purge_batches

  # If any batch failed, STOP: don't autoremove, don't claim success, don't tell
  # the user to reboot with the UniFi layer still half-present.
  if [[ "$PURGE_FAILURES" != "0" ]]; then
    echo
    err "PURGE INCOMPLETE — one or more batches failed (see errors above)."
    err "Batches that reported success are done; the ones listed as FAILED are not, so the"
    err "UniFi layer is only partly removed. Nothing load-bearing was touched (the"
    err "simulation gate checked that). Re-running is safe — it only acts on what's left:"
    err "    sudo $0 --apply"
    err "If the same package fails again, keep the output. Do NOT reboot expecting a clean"
    err "box until this reports success."
    exit 1
  fi
  cleanup_postgres_placeholders

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
