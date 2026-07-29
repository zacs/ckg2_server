# 01 — Hardware reference (UCK-G2 / UCK-G2-PLUS)

Everything here is from FCC internal-photo teardowns, serial boot logs, and
on-device reports. Where a fact is inferred rather than read off a marking it is
flagged. **Verify the ones that matter to you on your actual unit** — board
revisions vary.

## The one correction that changes everything

The CloudKey Gen2 / Gen2 Plus is **not** a Marvell Armada 3720. It is a
**Qualcomm APQ8053 (Snapdragon 625)**. You will find a lot of confident-but-wrong
internet claims of "Armada 3720" — that SoC is in the original **UniFi Dream
Machine**, and the two get conflated constantly. The die is marked
`QUALCOMM APQ8053`, the serial console prompt is `cloudkey-apq8053`, the kernel
is `3.18.44-ui-qcom`, and the flash partitions are Qualcomm's (`sbl1`, `devcfg`,
`aboot`, …). Consequences:

- The boot chain is Qualcomm's signed **PBL → SBL1 → … → aboot (Little Kernel)**,
  **not** U-Boot + TF-A. There is no U-Boot to rebuild.
- The mainline porting base is **`msm8953-mainline`** + **lk2nd**, not Armbian's
  Armada-3720 images (ESPRESSObin/uDPU). Those will **not** boot here.

## Bill of materials

| Part | Component | Notes |
|------|-----------|-------|
| **SoC** | Qualcomm **APQ8053** (Snapdragon 625) | 8× Cortex-A53 up to 2.0 GHz, 14 nm, ARMv8-A. Adreno 506 GPU (unused, headless). |
| **Kernel arch** | **aarch64** (64-bit) | …but the **userland is 32-bit armhf** (`dpkg --print-architecture` → `armhf`). Verify both: `uname -m` and `dpkg --print-architecture`. |
| **RAM** | **3 GB** LPDDR3 (Plus); 2 GB (non-Plus) | Part of an eMCP package (RAM+eMMC combined): Samsung `KMGX6001BM` on Plus, SK hynix `H9TQ26ABJTAC` on non-Plus. |
| **Flash** | **32 GB eMMC** → `/dev/mmcblk0` (~29 GiB) | A second small region `/dev/mmcblk1` (~1.9 GiB) is also present. |
| **NIC** | **ASIX AX88179** USB 3.0 → Gigabit Ethernet | Driver `ax88179_178a`. **The NIC is on USB**, not PCIe/native MAC. |
| **Internal disk** | **USB-SATA bridge** (likely ASMedia ASM1153) → `/dev/sda` | Behind a **TI TUSB8044** USB-3 hub. There is **no native SATA/AHCI**. Uses `uas`/`usb-storage`. Stock drive: Toshiba MQ04ABD100V 1 TB 2.5". |
| **Drive power** | +5 V only (2.5" drives only) | No 12 V rail. Up to ~5 TB 2.5". |
| **Power in** | **802.3af PoE** (Type 1, ≤12.95 W) **or USB-C** (QC 2.0, ≤16 W) | Two USB-C ports. PoE is via an isolated flyback (yellow transformer by the RJ45). |
| **Front panel** | **~160×64 monochrome OLED** → `/dev/fb0` | FPC ribbon `0260D-NF1-A`. **Not a touchscreen.** SSD13xx-class on-glass controller. See [05-lcd.md](05-lcd.md). |
| **Front button** | single reset/GPIO key → `/dev/input/event1` | `BTN_0` (0x100), active-low, GPIO 93. Short tap toggles display; ~10 s hold = Recovery Mode. |
| **Status LEDs** | sysfs `/sys/class/leds/*` | Enumerate with `ls /sys/class/leds`. |
| **RTC** | Qualcomm **PMIC (PM8953-class)** integrated RTC | No separate coin cell; timekeeping across power loss leans on the backup battery + NTP. |
| **Backup battery** | **Plus: 7.4 V 300 mAh Li-ion 2-cell** (`APP00197`); non-Plus: 3.7 V | For clean shutdown on power loss. **See safety note below.** |
| **Cooling** | **None — fanless / passive** | Runs hot. See safety note. |
| **Serial** | 3.3 V TTL UART | Pads `JDB2` labelled `T`/`R`/`G`, a.k.a. "J22". 115200 8N1. See [02-serial-console.md](02-serial-console.md). |

## ⚠️ Safety notes before you open one

- **The battery swells.** The Plus's 7.4 V Li-ion pack is a well-known failure
  item; a swollen pack causes "won't power on / BOOT FAILED" and can bulge the
  case. If your unit is old, inspect it. Many people simply **disconnect/remove
  the pack** — the CloudKey runs fine on PoE/USB-C without it; you only lose
  battery-backed clean-shutdown and RTC hold (NTP covers the clock).
- **It runs hot and has no fan.** Give it airflow, don't box it in, and watch
  `thermal_zone*` temps (`99-verify.sh` prints them). Heavy workloads on a
  fanless A53 will thermally throttle.
- **The SoC shield is glued.** The metal can over the SoC is awkward to reseat
  on reassembly. Don't force it.
- **Both NIC and disk are USB.** If Ethernet or the disk misbehaves under a
  custom kernel, it's a USB/`ax88179`/`uas` problem, not SATA/PCIe. Plan device
  trees and `defconfig` accordingly.

## Quick on-device fact-check

Run these on your unit and compare to the table:

```bash
uname -srm                      # kernel + arch (expect aarch64, 3.18.44-ui-qcom)
dpkg --print-architecture       # userland arch (expect armhf)
cat /proc/cpuinfo | grep -c ^processor   # core count (expect 8)
free -h                         # RAM
lsblk                           # mmcblk0 (eMMC) + sda (USB-SATA disk)
lsusb -t                        # see the TUSB8044 hub, AX88179 NIC, USB-SATA bridge
ls /sys/class/leds              # LED names
cat /sys/class/graphics/fb0/virtual_size   # panel geometry
```
