# 01 — Hardware reference (UCK-G2 / UCK-G2-PLUS)

Everything here is from FCC internal-photo teardowns, boot logs, and on-device
reports. Where a fact is inferred rather than read off a marking it is
flagged. **Verify the ones that matter to you on your actual unit** — board
revisions vary.

## The one correction that changes everything

The CloudKey Gen2 / Gen2 Plus is **not** a Marvell Armada 3720. It is a
**Qualcomm APQ8053 (Snapdragon 625)**. You will find a lot of confident-but-wrong
internet claims of "Armada 3720" — that SoC is in the original **UniFi Dream
Machine**, and the two get conflated constantly. The die is marked
`QUALCOMM APQ8053`, the kernel is `3.18.44-ui-qcom`, and the flash partitions
are Qualcomm's (`sbl1`, `devcfg`, `aboot`, …). Consequences:

- The boot chain is Qualcomm's signed **PBL → SBL1 → … → aboot (Little Kernel)**,
  **not** U-Boot + TF-A, and recovery is Ubiquiti's reset-button Recovery Mode
  ([04-recovery.md](04-recovery.md)), not a U-Boot prompt.
- Armada-3720 guides and images (Armbian for ESPRESSObin/uDPU) do **not** apply
  and will **not** boot here.

## Bill of materials

| Part | Component | Notes |
|------|-----------|-------|
| **SoC** | Qualcomm **APQ8053** (Snapdragon 625) | 8× Cortex-A53 up to 2.0 GHz, 14 nm, ARMv8-A. Adreno 506 GPU (unused, headless). |
| **Kernel arch** | **aarch64** (64-bit), vendor `3.18.44-ui-qcom` | **Userland is firmware-dependent**: firmware 6.x is Debian 13 *trixie* and 5.x is Debian 11 *bullseye*, both **64-bit arm64** on Gen2 and Gen2 Plus (`dpkg --print-architecture` → `arm64`); very old firmware was 32-bit **armhf**. The kernel stays `3.18.44-ui-qcom` across these. Always check yours: `uname -m` **and** `dpkg --print-architecture`. This decides which prebuilt binaries you can run. The kernel also runs 32-bit ARM binaries (AArch32 compat). |
| **RAM** | **3 GB** LPDDR3 (Plus); 2 GB (non-Plus) | Part of an eMCP package (RAM+eMMC combined): Samsung `KMGX6001BM` on Plus, SK hynix `H9TQ26ABJTAC` on non-Plus. |
| **Flash** | **32 GB eMMC** → `/dev/mmcblk0` (~29 GiB) | Qualcomm A/B-style partition layout. `/` is an **OverlayFS** whose persistent writable layer is a **~6 GB** partition — that, not 29 GiB, is the space for OS changes. A `/dev/mmcblk1` may also appear: most likely the **microSD slot**, not part of the eMMC — check with `cat /sys/block/mmcblk1/device/type` (`SD` vs `MMC`). |
| **NIC** | **ASIX AX88179** USB 3.0 → Gigabit Ethernet | Driver `ax88179_178a`. **The NIC is on USB**, not PCIe/native MAC. |
| **Internal disk** | **USB-SATA bridge** (likely ASMedia ASM1153) → `/dev/sda` | Behind a **TI TUSB8044** USB-3 hub. There is **no native SATA/AHCI**. Uses `uas`/`usb-storage`. Stock drive: Toshiba MQ04ABD100V 1 TB 2.5". |
| **Drive power** | +5 V only (2.5" drives only) | No 12 V rail. Up to ~5 TB 2.5". |
| **Power in** | **802.3af PoE** (Type 1, ≤12.95 W) | One cable for power and network, via an isolated flyback (yellow transformer by the RJ45). |
| **Front panel** | **160×60 OLED** → `/dev/fb0` | 16bpp **BGR565** framebuffer (stride 320, 19200 bytes), driver **`fb_sp8110`** over SPI. FPC ribbon `0260D-NF1-A`. **Not a touchscreen.** See [03-lcd.md](03-lcd.md). |
| **Front button** | single reset/GPIO key → `/dev/input/event1` | `BTN_0` (0x100), active-low, GPIO 93. Short tap toggles display; ~10 s hold = Recovery Mode. |
| **Status LEDs** | sysfs `/sys/class/leds/{blue,white,ulogo_ctrl}` | Brightness 0–255. There is **no** kernel `timer` trigger (writing it silently no-ops) — blink by toggling `brightness` yourself. |
| **RTC** | Qualcomm **PMIC (PM8953-class)** integrated RTC | No separate coin cell; timekeeping across power loss leans on the backup battery + NTP. |
| **Backup battery** | **Plus: 7.4 V 300 mAh Li-ion 2-cell** (`APP00197`); non-Plus: 3.7 V | For clean shutdown on power loss. **See safety note below.** |
| **Cooling** | **None — fanless / passive** | Runs hot. See safety note. |

## External I/O — can I plug in a USB peripheral? (No)

Per Ubiquiti's own quick-start guide, the external connectors are: the **Gigabit
Ethernet** port (PoE-in), **two USB-C ports**, a **microSD slot**, a Kensington
**security slot**, and the **13-pin** rackmount-accessory connector. There is
**no USB-A port**, and neither USB-C is a general-purpose host port:

| External connector | What it's actually for |
|--------------------|------------------------|
| USB-C #1 | **Power only** (QC 2.0/3.0). No data lines wired to a USB controller. |
| USB-C #2 | Labelled **"reserved for future use"** — no documented/working data or host-mode function. Don't plan around it. |
| microSD slot | **Storage only**, for "external backup" (an SD card, not arbitrary peripherals). |

So you **cannot** attach a normal USB peripheral (keyboard, hub, drive, dongle)
to this box. The reason is structural, not just missing drivers: the SoC's USB is
routed through the internal **TUSB8044** hub and is **fully consumed** by the two
things that make the box work — the AX88179 Ethernet NIC and the USB-SATA bridge
for the 2.5" bay (see the BOM above). There's no free, broken-out host port.

If you need to attach something, the realistic options are: use the **microSD
slot** for extra storage, put the peripheral **on the network** (USB-over-IP, a
networked printer/serial device, etc.), or — for the truly determined — tap a
spare **TUSB8044** port internally, which is undocumented hardware hacking, not "a
normal USB port."

## ⚠️ Safety notes before you open one

- **The battery swells.** The Plus's 7.4 V Li-ion pack is a well-known failure
  item; a swollen pack causes "won't power on / BOOT FAILED" and can bulge the
  case. If your unit is old, inspect it. Many people simply **disconnect/remove
  the pack** — the CloudKey runs fine on PoE without it; you only lose
  battery-backed clean-shutdown and RTC hold (NTP covers the clock).
- **It runs hot and has no fan.** Give it airflow, don't box it in, and watch
  `thermal_zone*` temps (`99-verify.sh` prints them). Heavy workloads on a
  fanless A53 will thermally throttle.
- **The SoC shield is glued.** The metal can over the SoC is awkward to reseat
  on reassembly. Don't force it.
- **Both NIC and disk are USB.** If Ethernet or the disk misbehaves, think USB
  (`ax88179_178a`, `uas`/`usb-storage`), not SATA/PCIe — start with
  `dmesg | grep -iE 'usb|uas|sda'`.

## Quick on-device fact-check

Run these on your unit and compare to the table:

```bash
uname -srm                      # kernel + arch (expect aarch64, 3.18.44-ui-qcom)
dpkg --print-architecture       # userland arch (arm64 on current firmware; armhf on very old)
cat /etc/os-release             # trixie = firmware 6.x; bullseye = 5.x (update it: 02-install.md)
cat /proc/cpuinfo | grep -c ^processor   # core count (expect 8)
free -h                         # RAM
lsblk                           # mmcblk0 (eMMC) + sda (USB-SATA disk)
lsusb -t                        # see the TUSB8044 hub, AX88179 NIC, USB-SATA bridge
ls /sys/class/leds              # LED names
cat /sys/class/graphics/fb0/virtual_size   # panel geometry (expect 160,60)
findmnt / ; df -h /             # overlay root + how much of its ~6 GB is left
cat /sys/block/mmcblk1/device/type 2>/dev/null   # SD = the microSD slot
```
