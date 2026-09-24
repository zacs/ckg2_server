# ckg2_server — turn a UniFi CloudKey Gen2+ into a tiny Linux server

Repurpose a **UniFi CloudKey Gen2 / Gen2 Plus** (`UCK-G2` / `UCK-G2-PLUS`) into a
small, PoE-powered, fanless ARM micro-server running plain Debian — with the
internal SATA disk, PoE, and the front-panel OLED all working, and no more UniFi
"reboot when it's unhappy" behaviour.

It's a lovely little box for the job: 8-core ARM, 3 GB RAM, a 2.5" drive bay, and
it sips power over a single PoE cable. This repo gives you a **tested, low-risk
path** to reclaim it — no disassembly, no serial adapter — the scripts and config
to do it, a Python tool to drive the LCD, and honest documentation of the sharp
edges.

> **The most important fact up front:** despite what half the internet says, the
> CloudKey Gen2 is **not** a Marvell Armada 3720. It's a **Qualcomm APQ8053
> (Snapdragon 625)**, which is why most "CloudKey Linux" advice you'll find
> doesn't apply. Details in [docs/01-hardware.md](docs/01-hardware.md).

---

## The approach

**Stock UniFi OS is already Debian.** "Installing Linux" here means removing
UniFi Network/Protect, MongoDB, the UniFi-OS agents, and the watchdog/supervisor
that reboots the box — leaving a normal Debian you fully control, on Ubiquiti's
vendor kernel (`3.18.44-ui-qcom`: old, but every peripheral works). It meets
every goal (persistent server, SATA disk, PoE, LCD) **without opening the case**.
Services then run directly on that OS — no containers; the old kernel can't
really host them (see [docs/07-storage.md](docs/07-storage.md#running-your-own-services)).
Full walkthrough: [docs/02-install.md](docs/02-install.md).

---

## Quick start

Enable SSH in the UniFi OS settings first. Steps 0–1 run **on your
workstation**; everything after runs **on the CloudKey, over an interactive SSH
session**. Copy this repo onto the box (`git clone` or `scp -r`).

```bash
# --- on your WORKSTATION -------------------------------------------------------
# 0. SAFETY NET: pull a full eMMC image over the network (the box has no usable
#    USB port and nothing is mounted yet), then check the gzip stream is intact.
ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz && gzip -t cloudkey-emmc.img.gz
# 1. Install your SSH key (it lives on the workstation, not the CloudKey)...
ssh-copy-id root@<cloudkey>
#    ...and TEST it from a fresh terminal — this must NOT ask for a password:
ssh -o PasswordAuthentication=no root@<cloudkey> true && echo key login OK

# --- on the CLOUDKEY -----------------------------------------------------------
cd ckg2_server/scripts
sudo passwd root                                         # 1b. set a KNOWN root password
#   (no ssh-copy-id? paste the key instead:  sudo ./05-add-ssh-key.sh "ssh-ed25519 AAAA… you@host")
sudo ./10-deunifi.sh                                     # 2. dry run — see the plan, change nothing
sudo ./10-deunifi.sh --apply                             # 3. remove UniFi + disable the watchdog
sudo reboot                                              # 4. reboot by hand, then SSH back in

sudo ./99-verify.sh                                      # 5. confirm a clean boot
sudo ./20-provision.sh                                   # 6. tools, auto-updates, NTP (firewall: opt-in)
sudo ./30-mount-storage.sh /dev/sda                      # 7. WIPE + mount the 2.5" disk at /volume
                                                         #    (UniFi's old partitions — check for Protect footage first)
sudo ./41-install-cloudkey.sh                            # 8. rich OLED daemon (LEDs, button, web dashboard)

sudo ./35-rehome-storage.sh                              # 9. (optional) /home + /srv + /var/log onto the SATA disk
sudo ./99-verify.sh                                      # 10. final health check
```

That's it — a Debian box with `/volume` for bulk data, unattended upgrades, and
the front panel showing hostname / IP / uptime. `apt install` whatever you want
from here. Like a stock Ubuntu install, there's no firewall switched on, so an
app you install is reachable on your LAN without extra rules (opt in with
`20-provision.sh --firewall` if you want one).

> **Heads-up — Debian 11 is end-of-life.** Current UniFi OS is Debian 11
> *bullseye*, whose LTS ended on **2026-08-31**: unattended-upgrades is set up,
> but no more security fixes will arrive. A release upgrade is constrained by the
> old 3.18 vendor kernel (Debian 13's systemd won't boot on it). Keep this box
> LAN-only, and read "Modernizing the userland" in
> [docs/02-install.md](docs/02-install.md#modernizing-the-userland-optional).

**Where does everything live?** The OS stays on the **eMMC** (`/dev/mmcblk0`) —
nothing here reinstalls it, it just strips UniFi off the top. Note `/` is an
OverlayFS whose writable layer is a **~6 GB** eMMC partition, so that — not the
full 29 GiB — is the space you have for OS changes. The 2.5" SATA disk
(`/dev/sda` → `/volume`) is bulk storage and the home for anything write-heavy:
point your services' data there, and `35-rehome-storage.sh` moves `/home`,
`/srv`, and `/var/log` off the eMMC too — because the eMMC is soldered down and
wears out, while the SATA disk is swappable. Full detail:
[docs/07-storage.md](docs/07-storage.md).

**Credentials, in one line:** after de-UniFi you're still **`root` with the same
SSH password** — it lives in `/etc/shadow`, not the UniFi database, so the purge
doesn't touch it. Step 1 above just makes sure you have a *known* password plus a
tested key **before** surgery, so you can't get locked out. Full explanation of
the two account systems and how to (safely) harden or add a sudo user:
[docs/06-accounts-and-access.md](docs/06-accounts-and-access.md).

The scripts are **safe by default**: `10-deunifi.sh` only simulates until you
pass `--apply`, it refuses to remove any package whose loss would brick the box,
and it purges in small batches with an SSH liveness check between each. See the
table in [docs/02-install.md](docs/02-install.md).

---

## The front-panel LCD

The screen is a 160×60 OLED exposed as a **plain Linux framebuffer
(`/dev/fb0`, 16bpp BGR565, driver `fb_sp8110`)** — no weird protocol. You get two options; pick one (only one
process may own the framebuffer at a time):

**Featured — the `jnovack/cloudkey` daemon** (`41-install-cloudkey.sh`). A mature
Go daemon that drives the OLED *and* the status LEDs, reacts to the front button
(short/long-press "bands", stealth mode), mitigates OLED burn-in, and serves an
optional live web dashboard. The installer pulls a pinned prebuilt release
(32-bit ARM — the only build upstream ships; it runs on the arm64 userland via
AArch32 compat), verifies its sha256, and hands the panel over from stock `ck-ui`.

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
custom content: [docs/03-lcd.md](docs/03-lcd.md).

---

## Hardware at a glance

Full teardown-level detail in [docs/01-hardware.md](docs/01-hardware.md). The
highlights that affect how you use it:

- **SoC:** Qualcomm APQ8053 (Snapdragon 625), 8× Cortex-A53. **aarch64 kernel**;
  userland is firmware-dependent — **arm64** on current bullseye firmware, armhf
  on older. Check with `uname -m` and `dpkg --print-architecture` (it decides
  which prebuilt binaries you can run).
- **RAM / flash:** 3 GB (Plus) / 2 GB; 32 GB eMMC (`/dev/mmcblk0`). `/` is an
  overlay with only **~6 GB** of writable space — put anything big on `/volume`.
- **NIC and disk are both USB** behind an internal hub: Ethernet is an ASIX
  AX88179 (`ax88179_178a`); the 2.5" bay is a USB-SATA bridge showing up as
  `/dev/sda`. No native SATA/AHCI.
- **Power:** 802.3af PoE (≤12.95 W) — one cable for power and network.
- **Panel:** 160×60 OLED on `/dev/fb0`; front button on `/dev/input/event1`.
- **Fanless**, and there's an internal battery that can swell — read the safety
  notes below.

### ⚠️ Safety before you power on / open one

- **The internal battery swells** (especially the Plus's 7.4 V pack) and is a
  common cause of dead units. If yours is old, inspect it; many people just
  disconnect it (the box runs fine on PoE alone — you only lose battery-backed
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
power-on → **Recovery Mode** → reinstall stock firmware with `ubnt-tool fwupdate`, or
`dd`-restore your backup. Full ladder in [docs/04-recovery.md](docs/04-recovery.md).

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
│   ├── 20-provision.sh           base tools, unattended-upgrades, NTP, SSH defaults, opt-in ufw
│   ├── 30-mount-storage.sh       format + persistently mount /dev/sda (systemd .mount, not fstab)
│   ├── 35-rehome-storage.sh      bind /home, /srv, /var/log onto /volume (nofail) to spare the eMMC
│   ├── 40-install-lcd.sh         install the lightweight cklcd panel tool + service
│   ├── 41-install-cloudkey.sh    install the richer jnovack/cloudkey daemon (LEDs, button, web UI)
│   └── 99-verify.sh              read-only post-install health check
├── lcd/
│   └── cklcd                     Python framebuffer tool for the front panel
├── systemd/
│   ├── cklcd.service             the LCD status daemon unit
│   └── volume.mount.example      paste-in disk mount unit (why: fstab gets rewritten)
├── config/
│   └── cklcd.env.example         config for cklcd.service (→ /etc/cklcd.env)
└── docs/
    ├── 01-hardware.md            teardown-level BOM + the APQ8053 correction
    ├── 02-install.md             the full walkthrough
    ├── 03-lcd.md                 the framebuffer panel + cklcd
    ├── 04-recovery.md            un-bricking
    ├── 05-watchdog-and-persistence.md   why it reboots + making changes stick
    ├── 06-accounts-and-access.md credentials, SSH, and not locking yourself out
    └── 07-storage.md             OS-on-eMMC vs SATA disk, rehoming, running services
```

---

## Requirements

- A UniFi CloudKey **Gen2** or **Gen2 Plus**. (The Plus has the 2.5" drive bay
  and 3 GB RAM; the plain Gen2 has no bay and 2 GB. Everything here works on both;
  disk steps are Plus-only.)
- Network + SSH access, and a workstation with room for the eMMC backup
  (a few GB compressed). No serial adapter, no disassembly.

---

## Credits & sources

This repo stands on a lot of community reverse-engineering. In particular:

- **[jnovack/cloudkey](https://github.com/jnovack/cloudkey)** — a mature Go
  rewrite of the stock `ck-ui` front-panel daemon, and a battle-tested
  de-Ubiquiti runbook. The package/unit lists in `10-deunifi.sh` are derived from
  it, and it's an excellent richer alternative to `cklcd` (LEDs, button bands,
  web dashboard). Huge thanks.
- **[Colin Cogle — "Rescuing a UniFi Cloud Key Gen2 Plus"](https://colincogle.name/blog/unifi-cloud-key-rescue/)**
  — Recovery Mode and `ubnt-tool fwupdate`.
- **[FullDuplexTech](https://fullduplextech.com/turn-unifi-cloud-key-gen-2-into-a-headless-linux-server/)**
  — the stay-on-stock approach.
- FCC internal-photo teardowns for **[SWX-UCKG2P](https://fccid.io/SWX-UCKG2P)** /
  **[SWX-UCKG2](https://fccid.io/SWX-UCKG2)** — the hardware BOM.

## Disclaimer

Modifying your CloudKey voids its warranty, removes UniFi functionality, and can
brick the device if you deviate from the safe path. Everything here is provided
as-is, no guarantees. Take the backup. Read [docs/04-recovery.md](docs/04-recovery.md)
**before** you start, not after.

## License

MIT — see [LICENSE](LICENSE).
