# 06 — Recovery & un-bricking

The CloudKey has a genuinely useful safety net: an on-eMMC **Recovery firmware**
that lives in its own partition, separate from the main OS you're modifying. As
long as you don't touch the Qualcomm firmware/recovery partitions, you can almost
always get back.

## Recovery Mode (first thing to try)

1. Power the unit off.
2. Hold the front **reset button** while powering on, and keep holding ~10 s
   until the OLED shows **`RECOVERY MODE`**.
3. The recovery firmware serves:
   - a **web UI** on the device's IP (upload a firmware `.bin` to reflash), and
   - a **serial/SSH shell** (`root` / `ubnt`).

## Restore stock UniFi firmware

From the recovery shell (serial or SSH):

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

If you made a backup with `00-preflight-backup.sh`, restore it from Recovery Mode
(where the main rootfs isn't mounted):

```bash
# verify integrity first
sha256sum -c emmc-backup.img.sha256
# write it back to the eMMC (DOUBLE-CHECK the device node!)
dd if=/path/to/emmc-backup.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress
sync && reboot
```

## Serial console when there's no display/network

If the box won't network and the OLED is dark, attach the UART
([02-serial-console.md](02-serial-console.md)) and watch the boot log. You'll see
the Qualcomm PBL/SBL1 stages and the `cloudkey-apq8053` prompt. From a recovery
shell you can run the `ubnt-tool fwupdate` or `dd`-restore steps above.

## Failure ladder (what to try, worst case last)

| Symptom | Fix |
|---------|-----|
| Boots but SSH refused after a bad purge | You still have your open session (that's why we purge over an interactive SSH login). Re-enable/repair `ssh`, or reboot into Recovery and restore. |
| Main OS won't boot | Reset-hold → Recovery Mode → `ubnt-tool fwupdate` or `dd`-restore your backup. |
| No display, no network, no recovery | UART console; from recovery shell, reflash. |
| Recovery Mode itself won't come up | You likely damaged a Qualcomm firmware/`recovery` partition. Last resort is EDL/9008 mode — but **no public firehose loader for the CloudKey exists**, so this is effectively unrecoverable. This is why you keep an untouched `recovery` partition and a verified full backup. |
| Won't power on at all / bulging case | Suspect the **swollen internal battery** (Plus). Disconnecting the pack often revives it; the unit runs on PoE/USB-C without it. See [01-hardware.md](01-hardware.md) safety notes. |

## Golden rules

- **Always have a verified full eMMC backup before touching anything.**
- **Never write to the Qualcomm firmware partitions** (`sbl1`, `rpm`, `tz`,
  `devcfg`, `aboot`, `recovery`). Everything in this repo stays away from them.
- Do risky flashing **from Recovery Mode with UART attached**, not from the
  running main OS.
