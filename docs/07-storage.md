# 07 — Storage layout, running services, and keeping writes off the eMMC

This answers the questions people always hit once the box is a real server:
**where does the OS live, what is the SATA disk for, and where should the things
you run keep their data?** Short version at the top, the reasoning and the
scripts underneath.

## TL;DR

- **The OS lives on the eMMC** (`/dev/mmcblk0`, ~29 GiB). Nothing here
  reinstalls it — the stock Debian that already lives there stays, with UniFi
  stripped off the top. Your root filesystem (`/`) is an **OverlayFS** on the
  eMMC whose writable layer is a **~6 GB** partition — that's the real budget
  for everything you install or write outside `/volume`.
- **The 2.5" SATA disk (`/dev/sda`, mounted at `/volume`) is bulk storage** — and
  the place to put anything that writes a lot. It's a USB-attached disk (there's
  no native SATA on this box), formatted and mounted by
  [`30-mount-storage.sh`](../scripts/30-mount-storage.sh).
- **Run services directly on the OS** (apt packages or the app's own Linux
  installer), or in Docker with host networking ([08-docker.md](08-docker.md)).
  Keep each service's data under `/volume/appdata/<app>` and make the service
  wait for the disk.
- **Optionally rehome `/home`, `/srv`, and `/var/log` onto the SATA disk** with
  [`35-rehome-storage.sh`](../scripts/35-rehome-storage.sh), so day-to-day writes
  (user data, service data, and the logs that "hammer the disk") land on the
  roomy, replaceable SATA drive instead of the soldered-down eMMC.

## Why you care: the eMMC is the one part you can't replace

The eMMC is a 32 GB chip **soldered to the board**. Two consequences:

1. **Endurance.** eMMC/flash has finite program-erase cycles. Logs, databases,
   and caches are write-heavy. Hammering the eMMC is the one failure mode on
   this box that you can't fix with a screwdriver — when it wears out, the board
   is scrap. The SATA disk, by contrast, is a standard 2.5" drive you can swap
   in thirty seconds.
2. **Space.** The writable root is a **~6 GB** overlay partition, with the OS's
   own changes already using some of it. `/volume` is however big your disk is
   (commonly 250 GB – 2 TB). Check with `df -h / /volume`.

So the whole game is: **keep the OS on the eMMC, and push everything that grows or
churns onto `/volume`.**

> The SATA disk is USB-attached (bridge behind an internal hub), so it enumerates
> a beat after boot. The `/volume` mount and the rehome bind-mounts use `nofail`,
> so a missing/slow disk degrades instead of hanging boot. Because `nofail` also
> means *nothing waits for it*, every service that uses `/volume` has to say so
> itself — see [Running your own services](#running-your-own-services).
> Check disk health with `smartctl -a /dev/sda` (installed by `20-provision.sh`;
> some USB bridges only answer `smartctl -d sat -a /dev/sda`, some not at all).

## The map

```
/dev/mmcblk0   eMMC, ~29 GiB    →  /  (overlay)   the OS (Debian); ~6 GB writable. Keep it lean.
/dev/mmcblk1   if present       →  —              most likely the microSD slot (see 01-hardware.md)
/dev/sda       SATA/USB disk    →  /volume        bulk storage + everything write-heavy
```

After the optional rehome, and once you've set up a service or two, the busy
paths point at `/volume`:

```
/volume/appdata/<app>    ← each service's data directory (you set this up)
/volume/rehome/home      ← /home        (bind mount)
/volume/rehome/srv       ← /srv         (bind mount)
/volume/rehome/var-log   ← /var/log     (bind mount, default on)
```

Why the extra `appdata/` and `rehome/` levels: a UniFi boot hook that stays
installed deletes **empty** directories directly under `/volume` on every boot
(see [05](05-watchdog-and-persistence.md#other-boot-hooks-that-are-still-running)).
`/srv` is usually empty, so `/volume/srv` would vanish and its bind would quietly
fall back to the eMMC. The same goes for your own top-level directories: nest
them, or give them a `.keep` file.

## Running your own services

Install what you need directly (`apt install` it, or use the app's own Linux
installer), or run it in Docker with host networking: see
[08-docker.md](08-docker.md), which also covers data and boot order for
containers. On current firmware the userland is **arm64**, which nearly
everything ships for.

For each service installed directly, three things (plus one if you turned the
firewall on):

1. **Put its data on the disk.** Point the app's data/config directory at
   `/volume/appdata/<app>` (usually a setting, a command-line flag, or the
   service's `WorkingDirectory=`/`StateDirectory=`). Anything left at its default
   under `/var/lib` or `/opt` lives on the eMMC.

2. **Make it wait for the disk.** Without this, a cold boot can start the service
   before the USB disk mounts, and it then either fails ("Permission denied" /
   "No such file") or quietly writes a fresh, empty data directory onto the eMMC
   underneath the mountpoint. jnovack's runbook hit exactly this. Add a drop-in:

   ```bash
   sudo systemctl edit <app>.service
   #   [Unit]
   #   RequiresMountsFor=/volume/appdata/<app>
   ```

   `RequiresMountsFor=` adds both the ordering and the dependency: if the disk is
   missing, the service doesn't start at all (loud) instead of running on the
   eMMC (silent).

3. **Check it runs on this userland.** On firmware 6.x (Debian 13, glibc 2.41)
   ordinary arm64 builds for current Debian/Ubuntu just work. On 5.x
   (Debian 11, glibc 2.31) prebuilt binaries built against newer glibc fail with
   ``version `GLIBC_2.33' not found`` (jnovack hit this with Radarr's bundled
   SQLite) — one more reason to do the firmware prerequisite. Either way the
   kernel is the old 3.18: anything that needs a modern kernel feature (e.g.
   newer syscalls, cgroup v2) may still misbehave, so try it before you rely on
   it.

Firewall: by default there's none (same as stock Ubuntu), so nothing to do. If
you ran `20-provision.sh --firewall`, also `sudo ufw allow <port>/tcp` (or
`/udp`) for anything the LAN should reach.

Logs: services that log to the journal are covered by the journald cap below;
ones that write their own log files should write them under `/volume` (or under
`/var/log` once it's rehomed).

## Rehoming /home, /srv, and /var/log

`35-rehome-storage.sh` moves write-heavy OS directories onto `/volume` using the
same trick as the disk mount: a **systemd bind-`.mount` unit**, never
`/etc/fstab` (the CloudKey's base-files package rewrites fstab on every boot — see
[05-watchdog-and-persistence.md](05-watchdog-and-persistence.md)). For each
directory it rsyncs the current contents to `/volume/rehome/<name>`, writes a bind
unit, and the mount shadows the eMMC copy at boot. It skips a target that's a
symlink (UniFi's boot hooks manage some links, and copying a link that points
into `/volume` would copy `/volume` into itself) or that's already its own mount.
Check `ls -ld /home /srv /var/log` before running it.

Defaults it rehomes:

| Dir | Why | Default |
|-----|-----|---------|
| `/home` | user data, dotfiles, anything you scp in | on (binds live) |
| `/srv` | the conventional home for served data | on (binds live) |
| `/var/log` | rsyslog + journald writes — a steady eMMC drip | on (activates on reboot) |

`/var/log` binds on the next boot rather than live, because running loggers hold
open file handles. The script rsyncs it and installs the unit; the bind takes
effect at boot, ordered before the loggers start. It also drops a **journald cap**
(`SystemMaxUse=200M`) so the persistent journal can't balloon. Pass
`--no-var-log` if you want logs to stay on the eMMC for some reason.

What it deliberately does **not** move: `/` itself, `/boot`, `/etc`, `/usr`,
`/var/lib` — those are the OS and belong on the eMMC where the boot process
expects them. Service data under `/var/lib` should instead be pointed at
`/volume/appdata/<app>` per service, as above.

### Why bind mounts, and NOT a symlink like `/var -> /volume/var`

Tempting, and it *sounds* like it'd fail more gracefully. It's the opposite —
this is the one place to get it right:

- **`/var` is needed before the disk exists.** The SATA drive is USB-attached and
  enumerates a beat *after* boot starts. `/var` is in use from the very first
  moments — and it holds load-bearing state: `/var/lib/dpkg` is the **entire
  package database**, `/var/lib/systemd` is systemd's own state.
- **A symlink fails *dangerously*, not gracefully.** If `/var` symlinks into
  `/volume` and the disk is slow or dead, those paths resolve to an **empty stub**
  on the eMMC. `dpkg` now thinks nothing is installed; services start against
  blank state; the box boots subtly broken, silently. Later, when the disk
  mounts, it's shadowed — split-brain.
- **A `nofail` bind mount fails *safely*.** If the disk doesn't come up, the bind
  simply doesn't happen and the directory falls back to its **real copy on the
  eMMC** — the box boots fine, just logging to eMMC until the disk returns. That
  graceful "boot won't fail if USB got fucked up" behaviour is precisely what you
  wanted, and only the bind mount actually delivers it.

So the rule is: **bind the write-heavy leaves (`/var/log`), never `/var`
wholesale**, and give each service its own data directory under `/volume`.
Between the two, the things that actually churn are on `/volume`, and the OS
state that must survive a dead disk stays on the eMMC.

> Want the apt download cache off the eMMC too? It's low-value (transient `.deb`
> files) but harmless: `/var/cache/apt/archives` can be bind-mounted the same way
> by hand, or just run `apt-get clean` now and then.

## Recommended order

README steps 7 and 8 ([details](02-install.md#7-format-and-mount-the-25-drive)):

```bash
./scripts/30-mount-storage.sh /dev/sda   # /volume exists first — everything else needs it
./scripts/35-rehome-storage.sh           # /home + /var/log (+ /srv if present) onto /volume
reboot                                   # activates the /var/log bind (deferred by design)
```

`99-verify.sh` reports the active rehome bind-mounts, so you can confirm nothing
important is still landing on the eMMC.
