# 04 — Recovery & un-bricking

The CloudKey has a genuinely useful safety net: an on-eMMC **Recovery firmware**
that lives in its own partition, separate from the main OS you're modifying. As
long as you don't touch the Qualcomm firmware/recovery partitions, you can almost
always get back.

## Recovery Mode (first thing to try)

1. Power the unit off.
2. Hold the front **reset button** while powering on, and keep holding ~10 s
   until the OLED shows **`RECOVERY MODE`**.
3. The recovery firmware serves:
   - a **web UI** on the device's IP (upload a firmware `.bin` to reinstall stock), and
   - an **SSH shell** (`root` / `ubnt`).

## Restore stock UniFi firmware

From the recovery SSH shell:

```bash
cd /tmp
# Recovery's wget may not support TLS 1.2 — use http:// (not https://).
wget http://fw-download.ubnt.com/data/unifi-cloudkey/<firmware-file>.bin
ubnt-tool fwupdate <firmware-file>.bin
# one reboot later you're back on stock
```

Get the correct firmware file from the UniFi download pages for **UCK-G2-PLUS**
(or UCK-G2). Match your model.

## Restore your own eMMC image

Restore from Recovery Mode (where the main rootfs isn't mounted). Know what a
whole-disk restore does: `/dev/mmcblk0` includes the Qualcomm firmware
partitions **and `recovery` itself**, so this rewrites them too (with identical
bytes if the image came from this unit). If the write is interrupted part-way
through those, you're in the hard-brick case below. Keep power stable, and
prefer "Restore stock" above when that's enough.

**The usual case — the gzip image the README pulled onto your workstation:**

```bash
# on the workstation: confirm the image is complete, then serve it over HTTP
gzip -t cloudkey-emmc.img.gz
python3 -m http.server 8000            # in the directory holding the image

# on the CloudKey, in the Recovery shell (DOUBLE-CHECK the device node!)
wget -O- http://<workstation-ip>:8000/cloudkey-emmc.img.gz | gunzip | dd of=/dev/mmcblk0 bs=4M
sync && reboot
```

(If Recovery's busybox lacks `gunzip`, decompress on the workstation first and
serve the raw `.img` instead.)

**A raw image with a `.sha256`** (from `00-preflight-backup.sh` writing to a
file):

```bash
sha256sum -c emmc-backup.img.sha256
dd if=/path/to/emmc-backup.img of=/dev/mmcblk0 bs=4M conv=fsync
sync && reboot
```

## Failure ladder (what to try, worst case last)

| Symptom | Fix |
|---------|-----|
| Boots but SSH refused after a bad purge | You still have your open session (that's why we purge over an interactive SSH login). Re-enable/repair `ssh`, or reboot into Recovery and restore. |
| Main OS won't boot | Reset-hold → Recovery Mode → `ubnt-tool fwupdate` or `dd`-restore your backup. |
| OLED dark and no network | Check PoE first: the switch port must supply 802.3af (try another port/cable/injector). Then try Recovery Mode — it runs from its own partition, independent of the main OS. |
| Recovery Mode itself won't come up | You likely damaged a Qualcomm firmware/`recovery` partition. Last resort is EDL/9008 mode — but **no public firehose loader for the CloudKey exists**, so this is effectively unrecoverable. This is why you keep an untouched `recovery` partition and a verified full backup. |
| Won't power on at all / bulging case | Suspect the **swollen internal battery** (Plus). Disconnecting the pack often revives it; the unit runs on PoE without it. See [01-hardware.md](01-hardware.md) safety notes. |

## Golden rules

- **Always have a verified full eMMC backup before touching anything.**
- **Never write to the Qualcomm firmware partitions** (`sbl1`, `rpm`, `tz`,
  `devcfg`, `aboot`, `recovery`). Everything in this repo stays away from them.
- Do restores **from Recovery Mode**, not from the running main OS.
