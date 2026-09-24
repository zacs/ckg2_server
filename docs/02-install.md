# 02 — Install: reclaim the stock Debian

No disassembly, no serial adapter, no bootloader work, low brick risk — and it
satisfies every goal: a persistent Linux server with the SATA disk, PoE, and the
LCD all working.

## The key insight

Stock UniFi OS on the CloudKey Gen2 **is already Debian** (Debian 9/10/11
depending on firmware) with the UniFi apps layered on top and a process
supervisor that reboots the box when those apps are unhealthy. "Installing Linux"
here means **removing the UniFi layer and its supervisor** and keeping the Debian
underneath — which you then modernize and use as a server.

What you keep: the stock aarch64 vendor kernel (`3.18.44-ui-qcom`) and the Debian
userland (arm64 on current bullseye firmware; armhf on older). What you remove:
UniFi Network, Protect, MongoDB, the UniFi-OS
agents, and the watchdog/auto-updater that cause the reboot behaviour.

> Trade-off, stated plainly: you stay on Ubiquiti's old 3.18 kernel. It is rock
> solid and every peripheral works, but it's old — which caps how far the
> userland can be modernized ([below](#modernizing-the-userland-optional)) and
> rules out containers, so services run directly on the OS
> ([07-storage.md](07-storage.md#running-your-own-services)).

## Before you start

- Get in over SSH. On stock UniFi OS, enable SSH in the UniFi OS settings (or the
  device's local portal) and set a password. Then `ssh root@<ip>` (or your admin
  user).
- **Be on current stock firmware (6.x = Debian 13).** Check with
  `cat /etc/os-release`; if it says *bullseye*, you're on 5.x or older, which no
  longer gets security updates. Update first, over SSH:

  ```bash
  ubnt-systool fwupdate <URL of the newest .bin for your model>   # UCKP = Gen2 Plus, UCKG2 = Gen2
  ```

  Get the URL from ui.com → Downloads → Cloud Keys (copy the download link). It
  downloads the image, stages it, and reboots by itself; SSH back in and confirm
  `os-release` says *trixie*. More in
  [Modernizing the userland](#modernizing-the-userland-optional).
- **Read [05-watchdog-and-persistence.md](05-watchdog-and-persistence.md)** — it
  explains the two reboot mechanisms and the `/etc/fstab`-gets-rewritten gotcha.
- Copy this repo onto the box: `git clone` it, or `scp -r` the folder over.

## Step by step

Run everything **on the box, over an interactive SSH session** (not scripted from
your laptop — the liveness checks need to run locally).

```bash
cd ckg2_server/scripts

# 0. SAFETY NET FIRST. Image the eMMC so you can always get back. This box has
#    NO usable USB port and the SATA disk isn't mounted yet, so back up over the
#    network. Easiest: run this line FROM your workstation to pull the image:
#        ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz
#    Or push it from the box with the script's stdout mode:
sudo ./00-preflight-backup.sh --stdout | gzip -1 | ssh you@nas 'cat > cloudkey-emmc.img.gz'
#    Either way, check the result is a complete gzip stream before relying on it:
#        gzip -t cloudkey-emmc.img.gz
#    (If you've already mounted the SATA disk, you can instead write to a file
#     there — but 30-mount-storage.sh erases that disk later, so copy it off.)

# 1. LOCK IN YOUR ACCESS before removing anything. You'll still be root with the
#    same password afterwards (it's in /etc/shadow, not the UniFi DB), but don't
#    bet your only way in on it. See docs/06-accounts-and-access.md.
sudo passwd root                               # set a KNOWN root password
#    Install your key FROM YOUR WORKSTATION (that's where the .pub file lives):
#        ssh-copy-id root@<ip>
#    or paste the key text here on the box:
#        sudo ./05-add-ssh-key.sh "ssh-ed25519 AAAA... you@host"
#    ...then TEST it from a SECOND terminal: `ssh root@<ip>` must work with no
#    password prompt. Keep this session open until it does.

# 2. See the de-UniFi plan WITHOUT changing anything (dry run):
sudo ./10-deunifi.sh

# 3. If the plan looks right (no forbidden packages flagged), apply it:
sudo ./10-deunifi.sh --apply

# 4. Reboot BY HAND and reconnect (confirm BOTH password and key still work):
sudo reboot
#    ... wait, then ssh back in ...

# 5. Confirm it came back clean:
cd ckg2_server/scripts
sudo ./99-verify.sh

# 6. Provision the server (tools, auto-updates, NTP). No firewall is switched on,
#    same as a stock Ubuntu/Debian install: anything you install is reachable on
#    your LAN without per-app rules. Add --firewall if you want ufw on
#    (deny incoming + allow SSH; then each app needs `ufw allow <port>`).
sudo ./20-provision.sh

# 7. Format + persistently mount the internal 2.5" disk (shows up as /dev/sda).
#    A stock drive carries UniFi's own partitions (swap + a data partition, often
#    still mounted at /volume, possibly with old Protect footage) — look first:
#        lsblk -f /dev/sda ; swapon --show
#    The script shows what's in use and releases it only after you confirm.
sudo ./30-mount-storage.sh /dev/sda            # → /volume

# 8. Take over the OLED. Pick ONE (only one process may own /dev/fb0):
sudo ./41-install-cloudkey.sh                  # featured: jnovack daemon (LEDs, button, web UI)
#   -- or the lightweight text-only tool instead --
# sudo ./40-install-lcd.sh                      # this repo's minimal cklcd

# 9. (optional) Keep writes off the soldered eMMC — see docs/07-storage.md:
sudo ./35-rehome-storage.sh                    # move /home + /srv + /var/log onto /volume

# 10. Final health check:
sudo ./99-verify.sh
```

You now have a plain Debian box with `/volume` for bulk data, a status screen,
and no UniFi reboots. Install whatever you like with
`apt install …` or an app's own Linux installer — see
[07-storage.md](07-storage.md#running-your-own-services) for where its data
should go and how to make it wait for the disk at boot.

> **Where does the OS live? Where does my data go?** The OS stays on the **eMMC**
> (`/dev/mmcblk0`, `/`) — nothing here reinstalls it. The SATA disk
> (`/dev/sda` → `/volume`) is bulk storage and the place for anything
> write-heavy: service data under `/volume/appdata/<app>`, and step 9 rehomes
> `/home`, `/srv`, and `/var/log` too. Full explanation:
> [07-storage.md](07-storage.md).

> **Will I still be root with my old password?** Yes. The SSH/root password lives
> in `/etc/shadow`, and the purge doesn't touch it; the account UniFi keeps in
> MongoDB is the *web-GUI* admin, which you're discarding. Step 1 exists only so a
> half-remembered password or a UniFi-managed credential can't strand you
> mid-install. Full story: [06-accounts-and-access.md](06-accounts-and-access.md).

## What each script does (and the safety built in)

| Script | Purpose | Safety |
|--------|---------|--------|
| `00-preflight-backup.sh` | Full eMMC image to a file | Refuses to write onto the eMMC itself; records a sha256 |
| `05-add-ssh-key.sh` | Install an SSH key for root (or a user) before surgery | Only *adds* a key; never disables password auth or restricts login → can't lock you out |
| `10-deunifi.sh` | Purge UniFi apps + disable supervisor/watchdog | **Dry-run by default**; simulate-gate aborts on any cascade into `ck-ui`/`ubnt-tools`/`*-base-files`/initramfs/kernel; batched purge with SSH liveness check between batches |
| `20-provision.sh` | Base tooling, unattended-upgrades, NTP, light SSH hardening; ufw only with `--firewall` | Idempotent; does **not** disable password auth (won't lock you out); never flips ufw on or off unless asked |
| `30-mount-storage.sh` | ext4 + systemd `.mount` for `/dev/sda` | Refuses the eMMC; lists UniFi's old partitions/swap still in use and releases them only after you confirm; flags `/etc/fstab` lines that point at the disk; uses a `.mount` unit (survives the fstab rewrite) |
| `35-rehome-storage.sh` | Bind-mount `/home`, `/srv`, `/var/log` onto `/volume/rehome/` | Copies (never deletes) originals; requires `/volume` on the SATA disk; skips symlinked or already-mounted targets; `nofail` bind units (survive a dead disk), not fstab, not symlinks |
| `40-install-lcd.sh` | Install lightweight `cklcd` + service, disable stock `ck-ui` | Idempotent; probes `/dev/fb0` first |
| `41-install-cloudkey.sh` | Install the richer `jnovack/cloudkey` daemon (LEDs, button, web UI) | Pinned release + sha256; verifies it's an ARM ELF; disables `ck-ui` **and** `cklcd` so only one owns `/dev/fb0` |
| `99-verify.sh` | Read-only health check | Changes nothing |

## Modernizing the userland (optional)

**Where things stand (September 2026):** Cloud Key firmware up to 5.x is Debian
11 *bullseye*, and bullseye's LTS ended on **2026-08-31** — Debian publishes no
more bullseye security fixes (Freexian sells "ELTS" beyond that, outside
Debian). `20-provision.sh` still sets up unattended-upgrades, which is only
useful on a supported release. Check what you have: `cat /etc/os-release`.

**The supported route: update the stock firmware.** Ubiquiti's **6.x** firmware
for the Cloud Key runs a Debian 13 *trixie* base on this same 3.18 kernel (also
seen by [hutchx86/cloudkey-unas](https://github.com/hutchx86/cloudkey-unas) on a
stock Gen2 Plus). Ubiquiti's own tool does it over SSH:

```bash
ubnt-systool fwupdate <URL>
# e.g. Gen2 Plus, 6.0.10 (check ui.com for newer; UCKG2 files are for the plain Gen2):
# https://fw-download.ubnt.com/data/unifi-cloudkey/9c12-UCKP-6.0.10-222899cf-67fc-434d-855b-1499dfb2b0fe.bin
```

It downloads the image to `/var/tmp`, reports the firmware string (e.g.
`UCKP.apq8053.v6.0.10.8e20374.260922.0941`), stages it, and reboots to flash.
It also works **after** `10-deunifi.sh` — `ubnt-systool` ships in a package
de-UniFi keeps. Without SSH (or if it fails), use Recovery Mode instead
([04-recovery.md](04-recovery.md#restore-or-upgrade-stock-unifi-firmware)).

Afterwards:

1. SSH back in and confirm `cat /etc/os-release` says *trixie*. A firmware
   update is expected to put back stock UniFi OS, so check
   `dpkg -l | grep -iE 'unifi|uos'` — if the UniFi layer is back, you're at the
   start of this guide again.
2. Take a **fresh** eMMC backup (step 0) — your old image is the bullseye system.
3. Run the de-UniFi steps on top. The package lists were built on 5.x, so read
   the dry run carefully — the simulation gate aborts on any cascade into a
   protected package, but 6.x may add UniFi packages the list doesn't know
   about yet.

**The hard route: dist-upgrade by hand.** Not the easy fix it is on a PC,
because the userland has to keep running on the vendor **3.18** kernel with
*your* existing boot image:

| Target | systemd | On the 3.18 kernel |
|---|---|---|
| Debian 12 *bookworm* (in LTS since 2026-07, until 2028-06) | 252 | systemd ≥ 251 declares kernels older than **4.15** unsupported. It may still boot, but nobody has shown it on this box. **Untested** — if it fails to boot, the way back is Recovery Mode + restoring your backup ([04](04-recovery.md)). |
| Debian 13 *trixie* (current stable) | 257 | systemd ≥ 256 **refuses to boot on cgroup-v1-only kernels** unless `SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1` is on the kernel command line (here, inside the Android-style `boot.img`); 3.18 has no cgroup v2. Ubiquiti's 6.x firmware evidently handles this in its own boot image/packages — a hand upgrade on the 5.x boot image has no such fix. **Use the firmware route instead.** |

Also expect: the kept Ubiquiti initramfs/udev/base-files packages were built for
bullseye, and apt prompts where you must **keep your `sshd_config`** or lose SSH.
Some `/etc` files get reset on boot by the base-files hooks — keep persistent
config in systemd units under `/etc/systemd/system`.

If you stay on bullseye, a de-UniFi'd box is still a fine **LAN-only**
appliance — just don't treat it as a patched, internet-facing server.
