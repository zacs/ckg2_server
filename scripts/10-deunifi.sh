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

purge_batches() {
  local batch remaining
  for batch in "${BATCHES[@]}"; do
    remaining=""
    for p in $batch; do pkg_installed "$p" && remaining+=" $p"; done
    [[ -z "$remaining" ]] && continue
    log "purging:$remaining"
    if [[ "$APPLY" == "1" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y $remaining || warn "batch had errors: $remaining"
      if ! ssh_alive; then
        err "LIVENESS CHECK FAILED after this batch: sshd is not accepting connections."
        err "STOP HERE. Do not run more. Reconnect via serial/recovery if you lose this session."
        exit 1
      fi
      ok "batch done; sshd still alive."
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
  disable_units
  purge_batches

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
