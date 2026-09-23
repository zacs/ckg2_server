# ckg2_server — turn a UniFi CloudKey Gen2+ into a tiny Linux server

Repurpose a **UniFi CloudKey Gen2 / Gen2 Plus** (`UCK-G2` / `UCK-G2-PLUS`) into a
small, PoE-powered, fanless ARM micro-server running plain Debian — with the
internal SATA disk, PoE, and the front-panel OLED all working, and no more UniFi
"reboot when it's unhappy" behaviour.

It's a lovely little box for the job: 8-core ARM, 3 GB RAM, a 2.5" drive bay, and
it sips power over a single PoE cable. This repo gives you a **tested, low-risk
path** to reclaim it, the scripts and config to do it, a Python tool to drive the
LCD, and honest documentation of the sharp edges (including the ambitious
full-reflash and mainline-kernel paths).

> **The most important fact up front:** despite what half the internet says, the
> CloudKey Gen2 is **not** a Marvell Armada 3720. It's a **Qualcomm APQ8053
> (Snapdragon 625)**. That changes the boot process, the recovery method, and
> the mainline-kernel story. Details in [docs/01-hardware.md](docs/01-hardware.md).

---

## Two ways to do this

| | **Path A — Reclaim stock (recommended)** | **Path B — Full eMMC reflash (advanced)** |
|---|---|---|
| What | Remove the UniFi layer + supervisor; keep the Debian underneath | Wipe eMMC, flash a clean Debian rootfs |
| Disassembly / serial | **No** | **Yes** (UART required) |
| Brick risk | Low | Real |
| Kernel | Vendor `3.18.44-ui-qcom` (old, rock-solid) | Vendor kernel (or experimental mainline) |
| Rootfs | Stock Debian, UniFi stripped | Pristine Debian you install |
| Reboots / persistence | Fixed by removing the supervisor; mounts via systemd units | Clean by construction |
| Guide | **[docs/03-install-stock.md](docs/03-install-stock.md)** | [docs/04-install-reflash.md](docs/04-install-reflash.md) |

**Stock UniFi OS is already Debian.** "Installing Linux" on Path A means removing
UniFi Network/Protect, MongoDB, the UniFi-OS agents, and the watchdog/supervisor
that reboots the box — leaving a normal Debian you fully control. It meets every
goal (persistent server, SATA disk, PoE, LCD) **without opening the case**, so
it's the right default. Path B is here for people who specifically want a
pristine, OverlayFS-free rootfs.

---

## Quick start (Path A)

Do this **on the CloudKey, over an interactive SSH session** (enable SSH in the
UniFi OS settings first). Copy this repo onto the box (`git clone` or `scp -r`).

```bash
cd ckg2_server/scripts

sudo ./00-preflight-backup.sh --stdout | gzip -1 > /some/mounted/ck.img.gz  # 0. SAFETY NET (image the eMMC)
#   ^ no USB port on this box — back up over the network instead. From your workstation:
#     ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz
sudo passwd root                                         # 1. set a KNOWN root password
sudo ./05-add-ssh-key.sh ~/.ssh/id_ed25519.pub          #    + install an SSH key, then TEST it
                                                         #    from a 2nd terminal before continuing
sudo ./10-deunifi.sh                                     # 2. dry run — see the plan, change nothing
sudo ./10-deunifi.sh --apply                             # 3. remove UniFi + disable the watchdog
sudo reboot                                              # 4. reboot by hand, then SSH back in

sudo ./99-verify.sh                                      # 5. confirm a clean boot
sudo ./20-provision.sh                                   # 6. tools, firewall, auto-updates, NTP
sudo ./30-mount-storage.sh /dev/sda                      # 7. format + mount the 2.5" disk at /volume
sudo ./41-install-cloudkey.sh                            # 8. rich OLED daemon (LEDs, button, web dashboard)

sudo ./35-rehome-storage.sh                              # 9. (optional) /home + /srv + /var/log onto the SATA disk
sudo ./50-install-docker.sh                              #    (optional) Docker, runtime on /volume, logs capped
sudo ./99-verify.sh                                      # 10. final health check
```

That's it — a Debian box with `/volume` for bulk data, a firewall, automatic
security updates, and the front panel showing hostname / IP / uptime. `apt
install` whatever you want from here.

**Where does the OS live, and where does Docker go?** The OS stays on the
**eMMC** (`/dev/mmcblk0`, mounted at `/`) — Path A never reinstalls it, it just
strips UniFi off the top. The 2.5" SATA disk (`/dev/sda` → `/volume`) is bulk
storage and the home for anything write-heavy. Docker's runtime defaults to
`/var/lib/docker` **on the eMMC**; `50-install-docker.sh` relocates it to
`/volume/docker` and caps container logs, and `35-rehome-storage.sh` can move
`/home`, `/srv`, and `/var/log` off the eMMC too — because the eMMC is soldered
down and wears out, while the SATA disk is swappable. Full detail:
[docs/10-storage-and-docker.md](docs/10-storage-and-docker.md).

**Credentials, in one line:** after de-UniFi you're still **`root` with the same
SSH password** — it lives in `/etc/shadow`, not the UniFi database, so the purge
doesn't touch it. Step 1 above just makes sure you have a *known* password plus a
tested key **before** surgery, so you can't get locked out. Full explanation of
the two account systems and how to (safely) harden or add a sudo user:
[docs/09-accounts-and-access.md](docs/09-accounts-and-access.md).

The scripts are **safe by default**: `10-deunifi.sh` only simulates until you
pass `--apply`, it refuses to remove any package whose loss would brick the box,
and it purges in small batches with an SSH liveness check between each. See the
table in [docs/03-install-stock.md](docs/03-install-stock.md).

---

## The front-panel LCD

The screen is a ~160×64 mono OLED exposed as a **plain Linux framebuffer
(`/dev/fb0`)** — no weird protocol. You get two options; pick one (only one
process may own the framebuffer at a time):

**Featured — the `jnovack/cloudkey` daemon** (`41-install-cloudkey.sh`). A mature
Go daemon that drives the OLED *and* the status LEDs, reacts to the front button
(short/long-press "bands", stealth mode), mitigates OLED burn-in, and serves an
optional live web dashboard. The installer pulls a pinned prebuilt armhf release,
verifies it, and hands the panel over from stock `ck-ui`.

**Lightweight — this repo's `cklcd`** (`40-install-lcd.sh`). A single dependency-
light Python 3 script (needs `python3-pil`) if you just want text on the panel:

```bash
cklcd info                     # live host / IP / uptime / load / temp / disk (loops)
cklcd text "hello\nworld"      # arbitrary text
cklcd qr "https://server.lan"  # a QR code
cklcd image logo.png           # an image
cklcd probe                    # show detected panel geometry + pixel format
```

Both run as a systemd service. Full comparison, design notes, and how to show
custom content: [docs/05-lcd.md](docs/05-lcd.md).

---

## Hardware at a glance

Full teardown-level detail in [docs/01-hardware.md](docs/01-hardware.md). The
highlights that affect how you use it:

- **SoC:** Qualcomm APQ8053 (Snapdragon 625), 8× Cortex-A53. **aarch64 kernel**;
  userland is firmware-dependent — **arm64** on current bullseye firmware, armhf
  on older. Check with `uname -m` and `dpkg --print-architecture` (it decides
  your container/binary arch).
- **RAM / flash:** 3 GB (Plus) / 2 GB; 32 GB eMMC (`/dev/mmcblk0`).
- **NIC and disk are both USB** behind an internal hub: Ethernet is an ASIX
  AX88179 (`ax88179_178a`); the 2.5" bay is a USB-SATA bridge showing up as
  `/dev/sda`. No native SATA/AHCI.
- **Power:** 802.3af PoE (≤12.95 W) **or** USB-C (QC 2.0, ≤16 W).
- **Panel:** mono OLED on `/dev/fb0`; front button on `/dev/input/event1`.
- **Fanless**, and there's an internal battery that can swell — read the safety
  notes below.

### ⚠️ Safety before you power on / open one

- **The internal battery swells** (especially the Plus's 7.4 V pack) and is a
  common cause of dead units. If yours is old, inspect it; many people just
  disconnect it (the box runs fine on PoE/USB-C — you only lose battery-backed
  clean shutdown; NTP keeps the clock).
- **It's fanless and runs hot.** Give it airflow; `99-verify.sh` prints thermal
  zones.
- **Always take a full eMMC backup before changing anything** (`00-preflight-backup.sh`).
- **Never write to the Qualcomm firmware partitions** (`sbl1`, `rpm`, `tz`,
  `devcfg`, `aboot`, `recovery`) — leaving `recovery` intact is what keeps a
  bricked box recoverable.

---

## If something goes wrong

The CloudKey has a real recovery firmware. Hold the reset button ~10 s on
power-on → **Recovery Mode** → reflash stock with `ubnt-tool fwupdate`, or
`dd`-restore your backup. Full ladder in [docs/06-recovery.md](docs/06-recovery.md).

---

## Repository layout

```
ckg2_server/
├── README.md                     ← you are here
├── scripts/
│   ├── lib/common.sh             shared helpers (logging, confirm, model detect, liveness)
│   ├── 00-preflight-backup.sh    image the eMMC to a file (safety net)
│   ├── 05-add-ssh-key.sh         install + verify an SSH key before surgery (no lockout)
│   ├── 10-deunifi.sh             remove UniFi + disable the supervisor/watchdog (dry-run by default)
│   ├── 20-provision.sh           base tools, ufw, unattended-upgrades, NTP, SSH hardening
│   ├── 30-mount-storage.sh       format + persistently mount /dev/sda (systemd .mount, not fstab)
│   ├── 35-rehome-storage.sh      bind /home, /srv, /var/log onto /volume (nofail) to spare the eMMC
│   ├── 40-install-lcd.sh         install the lightweight cklcd panel tool + service
│   ├── 41-install-cloudkey.sh    install the richer jnovack/cloudkey daemon (LEDs, button, web UI)
│   ├── 50-install-docker.sh      install Docker; runtime → /volume/docker; cap container logs
│   └── 99-verify.sh              read-only post-install health check
├── lcd/
│   └── cklcd                     Python framebuffer tool for the front panel
├── systemd/
│   ├── cklcd.service             the LCD status daemon unit
│   └── volume.mount.example      paste-in disk mount unit (why: fstab gets rewritten)
├── config/
│   ├── cklcd.env.example         config for cklcd.service (→ /etc/cklcd.env)
│   └── docker-daemon.json.example  Docker data-root + log-cap config (→ /etc/docker/daemon.json)
├── examples/
│   └── compose.example.yml       paste-in stack: Technitium DNS + Uptime Kuma (out-of-band watcher) + Arcane/Beszel agents (arm64)
└── docs/
    ├── 01-hardware.md            teardown-level BOM + the APQ8053 correction
    ├── 02-serial-console.md      UART header, adapter, baud
    ├── 03-install-stock.md       Path A walkthrough (recommended)
    ├── 04-install-reflash.md     Path B full reflash (advanced)
    ├── 05-lcd.md                 the framebuffer panel + cklcd
    ├── 06-recovery.md            un-bricking
    ├── 07-watchdog-and-persistence.md   why it reboots + making changes stick
    ├── 08-mainline-kernel.md     experimental modern-kernel research
    ├── 09-accounts-and-access.md credentials, SSH, and not locking yourself out
    └── 10-storage-and-docker.md  OS-on-eMMC vs SATA disk, Docker runtime/volumes, rehoming
```

---

## Requirements

- A UniFi CloudKey **Gen2** or **Gen2 Plus**. (The Plus has the 2.5" drive bay
  and 3 GB RAM; the plain Gen2 has no bay and 2 GB. Everything here works on both;
  disk steps are Plus-only.)
- For Path A: network + SSH access. Nothing else.
- For Path B / recovery / mainline: a **3.3 V** USB-TTL serial adapter
  ([docs/02-serial-console.md](docs/02-serial-console.md)).

---

## Credits & sources

This repo stands on a lot of community reverse-engineering. In particular:

- **[jnovack/cloudkey](https://github.com/jnovack/cloudkey)** — a mature Go
  rewrite of the stock `ck-ui` front-panel daemon, and a battle-tested
  de-Ubiquiti runbook. The package/unit lists in `10-deunifi.sh` are derived from
  it, and it's an excellent richer alternative to `cklcd` (LEDs, button bands,
  web dashboard). Huge thanks.
- **[Colin Cogle — "Rescuing a UniFi Cloud Key Gen2 Plus"](https://colincogle.name/blog/unifi-cloud-key-rescue/)**
  — serial console (J22), Recovery Mode, `ubnt-tool fwupdate`.
- **[XDA: "UniFi Cloud Key Gen 2 Plus" thread](https://xdaforums.com/t/unifi-cloud-key-gen-2-plus.4664639/)**
  (bean72 et al.) — the canonical full-reflash method and mainline-kernel
  attempts.
- **[FullDuplexTech](https://fullduplextech.com/turn-unifi-cloud-key-gen-2-into-a-headless-linux-server/)**
  — the stay-on-stock, dist-upgrade approach.
- **[msm8953-mainline](https://github.com/msm8953-mainline/linux)** &
  **[postmarketOS MSM8953 wiki](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_450/625/626/632_(MSM8953))**
  — the real mainline base for this SoC.
- FCC internal-photo teardowns for **[SWX-UCKG2P](https://fccid.io/SWX-UCKG2P)** /
  **[SWX-UCKG2](https://fccid.io/SWX-UCKG2)** — the hardware BOM.

## Disclaimer

Modifying your CloudKey voids its warranty, removes UniFi functionality, and can
brick the device if you deviate from the safe path. Everything here is provided
as-is, no guarantees. Take the backup. Read [docs/06-recovery.md](docs/06-recovery.md)
**before** you start, not after.

## License

MIT — see [LICENSE](LICENSE).
