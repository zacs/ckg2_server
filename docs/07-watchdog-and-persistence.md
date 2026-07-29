# 07 — Reboots, watchdogs, and making changes stick

Two of the user's core requirements — "without it rebooting" and "survive
reboots" — come down to understanding what makes a CloudKey reboot itself and
what silently un-does your changes. Here's the whole picture.

## Why a stock CloudKey "reboots itself"

The scary "it just keeps rebooting when UniFi isn't happy" behaviour is **not** a
hardware timer that will fight a custom OS. It's the **UniFi OS process
supervisor / health-check layer** (`uhwd` — the UniFi hardware watchdog daemon —
plus `infctld` and friends) deciding its own containers/DB/HDD are unhealthy and
restarting or rebooting to "fix" it.

There are, separately, two *real* low-level watchdogs, and neither cares what
userland you run:

1. **The Qualcomm SoC watchdog** (`qcom_wdt`/`msm_watchdog`). It only bites if
   the **kernel** stops petting it (a kernel hang). Any working kernel handles
   this automatically. It does not require UniFi software.
2. **The reset-button recovery latch** in SBL1 (the boot log counts
   `reset button is pressed: 5…1 → marking for recovery`). That's a boot-time
   recovery trigger, not a runtime loop.

**Conclusion:** you don't need to "defeat a watchdog." You remove the UniFi
supervisor, and the self-reboots stop. That's exactly what `10-deunifi.sh` does —
it purges the UniFi apps and `disable`s `uhwd.service`, `infctld.service`, and
the setup/splash units. On a full reflash ([04](04-install-reflash.md)) the
supervisor is gone by construction.

## Why your changes sometimes vanish on reboot (and the fix)

On stock UniFi OS the rootfs is managed, and the load-bearing **base-files**
package runs boot hooks that **reset certain `/etc` files to a template on every
boot**. The one that bites everyone:

> **`/etc/fstab` is rewritten on every boot.** Any mount line you add by hand is
> silently dropped, so your disk isn't mounted after a reboot.

The fix this repo uses everywhere: **persist via `systemd` unit files under
`/etc/systemd/system/`, which the hooks leave alone.**

- Disk mounts → a `.mount` unit (`30-mount-storage.sh` writes one), not `/etc/fstab`.
- Services → normal unit files (`cklcd.service`, etc.).
- One-shot boot config → your own `oneshot` service `WantedBy=multi-user.target`,
  not `/etc/rc.local` or fstab.

If you find another file getting reset, don't fight the hook — move whatever you
needed into a systemd unit instead.

> Full reflash removes this entirely: you leave the UniFi base-files package
> behind, so nothing rewrites `/etc`. On a reflashed system, `/etc/fstab` is
> fine. This gotcha is specific to the "reclaim stock" path — which is still the
> recommended one, because a `.mount` unit is a small price for not opening the
> case.

## Quick reference

| You want to… | Do this (stock path) | Not this |
|--------------|----------------------|----------|
| Mount a disk at boot | systemd `.mount` unit | line in `/etc/fstab` |
| Run something at boot | systemd service/timer | `/etc/rc.local`, cron `@reboot` in a reset file |
| Keep the box from self-rebooting | remove UniFi + disable `uhwd`/`infctld` | try to pet a watchdog |
| Persist SSH config | drop-in in `/etc/ssh/sshd_config.d/` (survives) + verify after a reboot | edit main `sshd_config` and hope |

## Verifying persistence

After any change that needs to survive a reboot: **actually reboot and re-check**
with `99-verify.sh`. It confirms the disk is mounted, the LCD service is up, no
UniFi supervisor is running, and SSH is listening. Persistence you didn't test by
rebooting isn't persistence yet.
