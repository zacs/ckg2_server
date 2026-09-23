# 10 — Storage layout, Docker, and keeping writes off the eMMC

This answers the three questions people always hit once the box is a real
server: **where does the OS live, what is the SATA disk for, and where do Docker's
runtime and volumes go?** Short version at the top, the reasoning and the
scripts underneath.

## TL;DR

- **The OS lives on the eMMC** (`/dev/mmcblk0`, ~29 GiB usable). Path A does **not
  reinstall** anything — it keeps the stock Debian that already lives there and
  strips UniFi off the top. Your root filesystem (`/`) is the eMMC.
- **The 2.5" SATA disk (`/dev/sda`, mounted at `/volume`) is bulk storage** — and
  the place to put anything that writes a lot. It's a USB-attached disk (there's
  no native SATA on this box), formatted and mounted by
  [`30-mount-storage.sh`](../scripts/30-mount-storage.sh).
- **Docker's runtime defaults to `/var/lib/docker` — which is on the eMMC.**
  Leaving it there works, but it wears the eMMC and fights for its limited space.
  [`50-install-docker.sh`](../scripts/50-install-docker.sh) installs Docker **and**
  relocates its `data-root` to `/volume/docker`, and caps container-log growth.
- **Put your volumes and bind-mounts under `/volume`.** Named volumes already
  follow `data-root` there once you've relocated it; for bind mounts, point them
  at `/volume/...` yourself.
- **Optionally rehome `/home`, `/srv`, and `/var/log` onto the SATA disk** with
  [`35-rehome-storage.sh`](../scripts/35-rehome-storage.sh), so day-to-day writes
  (user data, service data, and the logs that "hammer the disk") land on the
  roomy, replaceable SATA drive instead of the soldered-down eMMC.

## Why you care: the eMMC is the one part you can't replace

The eMMC is a 32 GB chip **soldered to the board**. Two consequences:

1. **Endurance.** eMMC/flash has finite program-erase cycles. Logs, databases,
   container layers, and build caches are write-heavy. Hammering the eMMC is the
   one failure mode on this box that you can't fix with a screwdriver — when it
   wears out, the board is scrap. The SATA disk, by contrast, is a standard 2.5"
   drive you can swap in thirty seconds.
2. **Space.** ~29 GiB total, with the OS already using a chunk of it. A couple of
   Docker images plus their logs will fill it. `/volume` is however big your disk
   is (commonly 250 GB – 2 TB).

So the whole game is: **keep the OS on the eMMC, and push everything that grows or
churns onto `/volume`.**

> The SATA disk is USB-attached (bridge behind an internal hub), so it enumerates
> a beat after boot. Every mount that depends on it — the `/volume` mount itself,
> the rehome bind-mounts, and Docker via `After=volume.mount` — uses `nofail`
> semantics so a missing/slow disk degrades gracefully instead of hanging boot.
> Check disk health with `smartctl -a /dev/sda` (installed by `20-provision.sh`).

## The map

```
/dev/mmcblk0   eMMC, ~29 GiB    →  /              the OS (Debian). Keep it lean.
/dev/mmcblk1   eMMC, ~1.9 GiB   →  (vendor)       small vendor partition — leave it.
/dev/sda       SATA/USB disk    →  /volume        bulk storage + everything write-heavy
```

After the optional rehome + Docker relocation, the busy paths point at `/volume`:

```
/volume/docker   ← Docker data-root (images, container layers, named volumes, logs)
/volume/home     ← /home        (bind mount)
/volume/srv      ← /srv         (bind mount)
/volume/log      ← /var/log     (bind mount, optional)
```

## Docker specifically

**Runtime / images / layers / named volumes → `data-root`.** Everything Docker
stores lives under one directory, `data-root`, which defaults to
`/var/lib/docker`. Point it at the SATA disk once, in
`/etc/docker/daemon.json`, and *all* of it moves — you don't relocate images and
volumes separately:

```json
{
  "data-root": "/volume/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

`50-install-docker.sh` writes this — plus a kernel-appropriate `storage-driver`
and `live-restore` (see the reality-check and
[config/docker-daemon.json.example](../config/docker-daemon.json.example) below).

**The logs that "hammer the disk."** By default Docker's `json-file` log driver
keeps **unbounded** per-container logs under
`data-root/containers/<id>/<id>-json.log`. A chatty container can write these
forever. Two fixes, both applied by the script:

- Relocating `data-root` to `/volume` moves those log files off the eMMC.
- The `log-opts` above **cap** them: 3 × 10 MB per container, rotated. Set once in
  the daemon config so it applies to every container without per-`run` flags.

(Docker's own *daemon* log — dockerd's chatter — goes to the systemd journal, not
to `data-root`. That's covered by the journald cap in the rehome section below.)

**Where do MY volumes go?**

- **Named volumes** (`docker volume create data`, or `-v data:/var/lib/pgsql`):
  nothing to do — they live under `data-root`, which is now `/volume/docker`.
- **Bind mounts** (`-v /host/path:/container/path`): *you* choose the host path,
  so point it at the SATA disk, e.g. `-v /volume/appdata/postgres:/var/lib/pgsql`.
  Don't bind-mount from `/root`, `/home`, or `/opt` unless you've rehomed them —
  those are on the eMMC.
- **Compose:** put the project under `/volume` (e.g. `/volume/stacks/myapp`) and
  use relative bind paths, or name your volumes and let `data-root` place them.
  There's a ready-to-paste starter stack (Technitium DNS + Uptime Kuma as an
  out-of-band watcher + Arcane/Beszel agents, arm64, data under `/volume`) in
  [examples/compose.example.yml](../examples/compose.example.yml) — it's just an
  example, not wired into any install script.

### Reality check: old kernel (but a modern 64-bit userland)

Docker runs on this box; the one real caveat is the kernel, not the arch:

- **Storage driver.** Modern Docker prefers `overlay2`, which really wants a
  kernel ≥ 4.0. On the stock **3.18 vendor kernel** `overlay2` may be
  unavailable, in which case Docker falls back to the `vfs` driver. `vfs` has no
  copy-on-write (each layer is a full copy, so images use more space and pulls
  are slower) — but it is **correct and reliable**, and because `data-root` is on
  the roomy SATA disk, the extra space is fine. The script detects what the
  kernel supports and picks accordingly, and tells you which it chose.
- **Architecture — good news.** On current firmware `dpkg --print-architecture`
  is **`arm64`** (Debian 11 bullseye on the aarch64 kernel), so you use **arm64
  container images** — the best-supported ARM architecture; effectively
  everything publishes it. (Older CloudKey firmware shipped a 32-bit **armhf**
  userland, limited to `arm/v7` images — check yours with
  `dpkg --print-architecture`.) If a pull ever fails with a manifest/architecture
  error, that image simply doesn't ship your arch — rare on arm64.

## Rehoming /home, /srv, and /var/log

`35-rehome-storage.sh` moves write-heavy OS directories onto `/volume` using the
same trick as the disk mount: a **systemd bind-`.mount` unit**, never
`/etc/fstab` (the CloudKey's base-files package rewrites fstab on every boot — see
[07-watchdog-and-persistence.md](07-watchdog-and-persistence.md)). For each
directory it rsyncs the current contents to `/volume/<name>`, writes a bind unit,
and the mount shadows the eMMC copy at boot.

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
`/var/lib` (except Docker, handled separately) — those are the OS and belong on
the eMMC where the boot process expects them.

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
wholesale.** Docker's runtime is the other big one, and it's handled the
Docker-native way (`data-root`) rather than by bind-mounting `/var/lib/docker`.
Between the two, the things that actually churn are on `/volume`, and the OS
state that must survive a dead disk stays on the eMMC.

> Want the apt download cache off the eMMC too? It's low-value (transient `.deb`
> files) but harmless: `/var/cache/apt/archives` can be bind-mounted the same way
> by hand, or just run `apt-get clean` now and then.

## Recommended order

Slotting into the Path A flow from [03-install-stock.md](03-install-stock.md):

```bash
sudo ./30-mount-storage.sh /dev/sda     # /volume exists first — everything else needs it
sudo ./35-rehome-storage.sh             # /home + /srv + /var/log onto /volume
sudo ./50-install-docker.sh             # Docker with data-root on /volume + capped logs
sudo reboot                             # activates the /var/log bind (deferred by design)
```

`99-verify.sh` reports the Docker `data-root`, the active rehome bind-mounts, and
which storage driver Docker settled on, so you can confirm nothing important is
still landing on the eMMC.
