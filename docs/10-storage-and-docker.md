# 10 — Storage layout, Docker, and keeping writes off the eMMC

This answers the three questions people always hit once the box is a real
server: **where does the OS live, what is the SATA disk for, and where do Docker's
runtime and volumes go?** Short version at the top, the reasoning and the
scripts underneath.

## TL;DR

- **The OS lives on the eMMC** (`/dev/mmcblk0`, ~29 GiB). Path A does **not
  reinstall** anything — it keeps the stock Debian that already lives there and
  strips UniFi off the top. Your root filesystem (`/`) is an **OverlayFS** on the
  eMMC whose writable layer is a **~6 GB** partition — that's the real budget
  for everything you install or write outside `/volume`.
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
- **Docker on this kernel is experimental.** The 3.18 vendor kernel predates
  overlay2; the script falls back to `vfs`, but a real multi-layer workload has
  not been proven on this box. [Smoke-test it](#reality-check-old-kernel-but-a-modern-64-bit-userland)
  before you build on it.
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
2. **Space.** The writable root is a **~6 GB** overlay partition, with the OS's
   own changes already using some of it. A couple of Docker images plus their
   logs will fill it. `/volume` is however big your disk is (commonly
   250 GB – 2 TB). Check with `df -h / /volume`.

So the whole game is: **keep the OS on the eMMC, and push everything that grows or
churns onto `/volume`.**

> The SATA disk is USB-attached (bridge behind an internal hub), so it enumerates
> a beat after boot. The `/volume` mount and the rehome bind-mounts use `nofail`,
> so a missing/slow disk degrades instead of hanging boot. Because `nofail` also
> means *nothing waits for it*, anything that writes to `/volume` must say so:
> `50-install-docker.sh` gives `docker.service` a `RequiresMountsFor=` drop-in
> (without it, a cold boot can start dockerd first and it quietly builds an empty
> data-root on the eMMC under the mountpoint). Do the same for your own services:
> `systemctl edit <unit>` → `[Unit]` `RequiresMountsFor=/volume`.
> Check disk health with `smartctl -a /dev/sda` (installed by `20-provision.sh`;
> some USB bridges only answer `smartctl -d sat -a /dev/sda`, some not at all).

## The map

```
/dev/mmcblk0   eMMC, ~29 GiB    →  /  (overlay)   the OS (Debian); ~6 GB writable. Keep it lean.
/dev/mmcblk1   if present       →  —              most likely the microSD slot (see 01-hardware.md)
/dev/sda       SATA/USB disk    →  /volume        bulk storage + everything write-heavy
```

After the optional rehome + Docker relocation, the busy paths point at `/volume`:

```
/volume/docker           ← Docker data-root (images, container layers, named volumes, logs)
/volume/rehome/home      ← /home        (bind mount)
/volume/rehome/srv       ← /srv         (bind mount)
/volume/rehome/var-log   ← /var/log     (bind mount, default on)
```

Why the extra `rehome/` level: a UniFi boot hook that stays installed deletes
**empty** directories directly under `/volume` on every boot (see
[07](07-watchdog-and-persistence.md#other-boot-hooks-that-are-still-running)).
`/srv` is usually empty, so `/volume/srv` would vanish and its bind would quietly
fall back to the eMMC. The same goes for your own top-level directories: nest
them, or give them a `.keep` file.

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

**Treat Docker here as an experiment until you've proven it.**
[jnovack's runbook](https://github.com/jnovack/cloudkey) (on real Gen2/Gen2+
hardware) tried Docker and gave up because the kernel predates overlay2, and ran
everything as plain packages instead. This repo's `vfs` fallback sidesteps
overlay entirely, but nobody has shown a real stack running on it yet. Before you
invest in containers:

```bash
docker run --rm hello-world
docker run -d --name smoke -p 8080:80 nginx:alpine && sleep 15 && curl -sI http://localhost:8080; docker rm -f smoke
```

If those fail, `50-install-docker.sh`'s kernel preflight output and
`journalctl -u docker` say why; the fallback is native packages (Technitium and
Uptime Kuma both have non-Docker installs). The old userland bites native apps
too: bullseye's glibc is 2.31, and some prebuilt binaries want newer.

The details:

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
- **No `docker compose` out of the box.** Debian's `docker.io` (20.10 on
  bullseye) doesn't ship the Compose v2 plugin, and bullseye's `docker-compose`
  package is the old v1, which can't read the compose example. Install the
  plugin binary from Docker's releases and verify it against its published
  checksum:

  ```bash
  V=v2.X.Y     # pick a release: https://github.com/docker/compose/releases
  A=$(uname -m)   # aarch64
  cd /tmp
  curl -fLO "https://github.com/docker/compose/releases/download/$V/docker-compose-linux-$A"
  curl -fLO "https://github.com/docker/compose/releases/download/$V/docker-compose-linux-$A.sha256"
  sha256sum -c "docker-compose-linux-$A.sha256"
  sudo install -D -m 0755 "docker-compose-linux-$A" /usr/local/lib/docker/cli-plugins/docker-compose
  docker compose version
  ```

  If a recent release complains about the Engine API version, try an older 2.x.
- **Docker bypasses ufw for published ports.** `ports:` / `-p` mappings are
  wired through Docker's own iptables chains, so they're reachable from the LAN
  **even though ufw says "deny incoming"**. The opposite holds for
  `network_mode: host` containers: those *are* filtered by ufw, so open their
  ports explicitly (`ufw allow 53`, etc.).

## Rehoming /home, /srv, and /var/log

`35-rehome-storage.sh` moves write-heavy OS directories onto `/volume` using the
same trick as the disk mount: a **systemd bind-`.mount` unit**, never
`/etc/fstab` (the CloudKey's base-files package rewrites fstab on every boot — see
[07-watchdog-and-persistence.md](07-watchdog-and-persistence.md)). For each
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
