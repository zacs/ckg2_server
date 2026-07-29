# 08 — Mainline kernel (experimental / research)

If your goal is a **modern kernel** instead of Ubiquiti's ancient
`3.18.44-ui-qcom`, this is the frontier — and as of this writing **nobody has a
fully-booting mainline kernel on the CloudKey Gen2 in the public record.** Treat
this as a research track, not a supported path. Keep a serial console attached
and a verified backup.

## The correct ecosystem

Because the SoC is a **Qualcomm APQ8053 ≡ MSM8953** (not Marvell — see
[01-hardware.md](01-hardware.md)), the porting base is the mobile/postmarketOS
world, **not** Armbian:

- **[msm8953-mainline/linux](https://github.com/msm8953-mainline/linux)** —
  mainline-ish kernel for the MSM8953 family (SDM450/625/626/632). APQ8053 is
  part of this family and reasonably mature **for phones**.
- **[lk2nd](https://github.com/msm8953-mainline/lk2nd)** — a secondary Little
  Kernel bootloader chainloaded from the stock `aboot`, which fixes up the DT and
  boots a mainline kernel. This is the standard entry point on Snapdragon 625
  devices.
- **postmarketOS** [MSM8953 wiki](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_450/625/626/632_(MSM8953))
  for bring-up notes.

## Why it's hard here specifically

1. **No CloudKey device tree exists upstream.** Every MSM8953 DT targets Xiaomi/
   Motorola handsets. You'd need to author a new
   `qcom-apq8053-ubnt-cloudkey.dts` describing this board: the UART, eMMC/SDHCI,
   USB, PMIC, thermal, and the front OLED.
2. **The important peripherals are USB, not SoC-native.** The NIC (ASIX
   **AX88179**, `ax88179_178a`) and the disk (USB-SATA bridge, `uas`/
   `usb-storage`) hang off a **TI TUSB8044** USB hub. Your kernel config must
   include those USB drivers; there's no `stmmac`/AHCI to enable. Getting USB +
   the hub up is the make-or-break.
3. **OLED panel driver.** The stock 3.18 fbdev driver for the SSD13xx-class panel
   isn't mainline. Expect the panel to be dark until you write/port a small panel
   driver — the rest of the system can work headless in the meantime.
4. **PMIC/thermal/regulators.** On a fanless board, thermal and regulator support
   matter; missing PMIC bits can mean instability under load.

## Rough plan of attack (for someone who wants to try)

1. Full backup + UART, obviously.
2. Build `lk2nd` for MSM8953 and get it chainloading from `aboot` (via the `boot`
   partition), confirmed by serial output.
3. Build an `msm8953-mainline` kernel + a **new CloudKey DTS** (start from the
   closest SDM625 phone DTS, strip display/touch/modem, add this board's UART/
   eMMC/USB).
4. Boot with a tiny initramfs to a serial shell first — ignore NIC/disk/OLED.
5. Bring up USB → the AX88179 NIC and the USB-SATA disk.
6. (Optional, last) port the OLED panel driver for `/dev/fb0`, then `cklcd`
   works again.

## Honest status

- DcMc77 on the XDA thread compiled a **6.x** kernel on-device and built a
  matching boot image, but "either the kernel or the device tree is crashing and
  it stops responding." That's the current state of the art: **WIP, not
  booting.**
- If you pull this off, please publish the DTS and defconfig — it would be the
  first public working mainline boot on this board.

For anything you actually want to *use*, stay on the vendor kernel via
[03-install-stock.md](03-install-stock.md) or [04-install-reflash.md](04-install-reflash.md).
