# 04 — Install path B: full eMMC reflash to clean Debian (advanced)

**Only do this if you specifically want a pristine, non-UniFi rootfs** free of
OverlayFS and every trace of UniFi OS. It is more work and carries real brick
risk. For most people, path A ([03-install-stock.md](03-install-stock.md)) is the
better answer and reaches the same practical outcome.

This page documents the community method (pioneered by **bean72** on the
[XDA thread](https://xdaforums.com/t/unifi-cloud-key-gen-2-plus.4664639/)) at a
level that lets you understand and follow it. It deliberately does **not** ship a
push-button script — the partition numbers and the custom `boot.img` are
device/firmware-specific, and a scripted mistake here bricks the box. Go slowly,
with a serial console attached and a verified backup.

## Why anyone does this

- Escapes the locked **OverlayFS** rootfs (on modern UniFi OS, `/` changes don't
  persist — the reflash gives you a normal writable ext4 root).
- Removes the UniFi OS supervisor at the source, so there is nothing to reboot
  you.
- Lets you run a mainstream Debian/Ubuntu userland of your choice.

You keep the vendor 3.18 kernel (proven), unless you go further into mainline
([08-mainline-kernel.md](08-mainline-kernel.md), still experimental).

## Boot chain facts you're working within

- Qualcomm **PBL → SBL1 → … → aboot (LK)** → Android-style `boot.img` (kernel +
  ramdisk) → rootfs. **No U-Boot, no TF-A.**
- The LK log reports `is_unlocked=1` — the bootloader is **effectively unlocked**,
  so an unsigned custom `boot.img` boots after you `dd` it into place. There is
  no fastboot signing step required.
- eMMC is `/dev/mmcblk0`; the boot image and rootfs live in numbered partitions.
  **Verify the numbers on YOUR unit** with `parted -l` — the ones below are from
  one author's board revision.

## Hard prerequisites

1. **Serial console** attached and working ([02-serial-console.md](02-serial-console.md)).
2. **A full eMMC backup** you have verified (`00-preflight-backup.sh`, ideally
   run from Recovery Mode). One person's dump was corrupt and they had no way
   back to stock — do not skip this.
3. A Debian arm64/armhf rootfs tarball (e.g.
   [jubinson/debian-rootfs](https://github.com/jubinson/debian-rootfs)).
4. A custom `boot.img` built to mount your new rootfs partition as `/`. (bean72's
   image, or one you build.)

## The method (read fully before doing any of it)

1. **Enter Recovery Mode**: power off, hold the reset button while powering on
   (~10 s) until the OLED shows recovery. Get a shell via serial (or SSH to the
   recovery IP), login `root` / `ubnt`.

2. **Back up the whole eMMC** if you haven't: image `/dev/mmcblk0` to external
   storage and verify the checksum.

3. **Get files onto the box.** On the **Gen2 Plus**, a USB drive enumerates in
   recovery. On the **plain Gen2**, USB storage often does *not* enumerate in
   recovery — instead serve the files from your PC
   (`python3 -m http.server 8000`) and `wget http://<pc>:8000/…` from the
   CloudKey. (Recovery's `wget` may lack TLS 1.2 → use plain `http`.)

4. **Flash the custom boot image** over the stock one (partition number **from
   your `parted -l`**, example uses p42):
   ```bash
   dd if=custom_boot.img of=/dev/mmcblk0p42
   ```

5. **Make a fresh root partition.** In `parted`, delete the stock data partitions
   in the free tail (example: p44–p47) and create one new ext4 partition using
   the free space, **numbered to match what your boot.img expects** (bean72's
   expects `mmcblk0p44`):
   ```bash
   mkfs.ext4 /dev/mmcblk0p44
   ```

6. **Lay down the rootfs**:
   ```bash
   mount /dev/mmcblk0p44 /mnt
   tar -xpf debian-rootfs.tar.gz -C /mnt --numeric-owner
   # set a root password / drop an authorized_keys before first boot
   ```

7. **Reboot.** It should come up as a bare Debian (bean72's image lands on Debian
   Jessie with SSH and an empty root password — set one *immediately*). Then
   `dist-upgrade` stepwise to a modern release using archived `sources.list`
   entries for EOL releases.

8. **Restore panel/LED behaviour**: copy the `ck-splash` binary out of your
   backup into `/sbin/`, or install this repo's `cklcd`
   ([05-lcd.md](05-lcd.md)) which needs nothing from stock.

Persistence is now trivial — you have a normal writable root, no OverlayFS, no
fstab-rewriting hooks (those belonged to the UniFi base-files package you left
behind). The internal disk still shows up as `/dev/sda`; mount it however you
like (fstab is fine on a reflashed system, but this repo's `30-mount-storage.sh`
still works).

## Reality checks

- **Partition numbers vary.** Confirm with `parted -l` before every `dd`/`mkfs`.
  A wrong number here is how boxes die.
- **Only touch boot + the data/rootfs partitions.** Leave the Qualcomm firmware
  partitions (`sbl1`, `rpm`, `tz`, `devcfg`, `aboot`, `recovery`) alone. As long
  as `recovery` is intact you can always re-enter Recovery Mode and restore.
- **If you corrupt the Qualcomm boot chain itself**, Recovery won't come up and
  you're into EDL/9008-mode territory — for which **no public firehose loader
  for the CloudKey exists**. That's effectively a hard brick. Your `dd` backup
  and an untouched `recovery` partition are your only real safety nets.
- Restoring stock: from Recovery, `ubnt-tool fwupdate <official-fw.bin>` (see
  [06-recovery.md](06-recovery.md)), or `dd` your full backup image back.
