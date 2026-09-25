# 02 — Install details

The [README](../README.md#install) has the commands. This page explains each
step, using the same numbers: why it's there, the options, and what to watch
for.

## The idea

Stock UniFi OS on the CloudKey Gen2 **is already Debian**, with the UniFi apps
on top and a supervisor that reboots the box when those apps are unhealthy.
"Installing Linux" here means **removing the UniFi layer and its supervisor**
and keeping the Debian underneath.

- **You keep:** Ubiquiti's kernel (`3.18.44-ui-qcom`, aarch64) and the Debian
  userland (arm64, Debian 13 on firmware 6.x).
- **You remove:** UniFi Network and Protect, MongoDB and PostgreSQL, the UniFi
  OS agents, and the watchdog and auto-updater behind the reboots.

The trade-off: you stay on the old 3.18 kernel. Every peripheral works, but it
rules out Docker and other containers, so services run directly on the OS
([07-storage.md](07-storage.md#running-your-own-services)). It's also why you
update Debian by updating the firmware
([not by dist-upgrading](#why-not-dist-upgrade-by-hand)).

## Step by step

### 1. Update to current firmware

`ubnt-systool fwupdate <URL>` downloads the firmware (about 860 MB) to
`/var/tmp`, prints its version string (for example
`UCKP.apq8053.v6.0.10.8e20374.260922.0941`), then reboots to flash it. Copy the
URL from [ui.com/download](https://ui.com/download) → Cloud Keys: `UCKP` files
are for the Gen2 Plus, `UCKG2` files for the plain Gen2.

What a firmware update does to the box (seen going from 5.x to 6.0.10):

- **Kept:** SSH access and everything in `/root`, including your SSH key.
- **Reset:** the UniFi layer comes back, and packages you installed yourself
  (such as `git`) are gone.
- **Empty package lists:** run `apt-get update` before installing anything, or
  apt says it can't find the package.

It works on a box that's already had UniFi removed, because `ubnt-systool`
ships in a package de-UniFi keeps. Updating that way puts you back at step 2:
take a fresh backup (the old one is the old system), then remove UniFi again.

If SSH doesn't work or the update fails, use Recovery Mode instead
([04-recovery.md](04-recovery.md#restore-or-upgrade-stock-unifi-firmware)).

### 2. Back up the internal storage

The one-liner in the README streams the whole eMMC (`/dev/mmcblk0`, about
29 GiB) to your computer, compressed. `gzip -t` then confirms the file is
complete and undamaged. Budget time for this: it's slow.

- **Push from the box instead**, to a NAS for example, once the repo is on the
  box:
  `./scripts/00-preflight-backup.sh --stdout | gzip -1 | ssh you@nas 'cat > cloudkey-emmc.img.gz'`
- **Not onto the 2.5" drive:** step 7 erases it.
- **It's a live image**, like pulling the plug at that moment. That's fine for
  a restore. For a perfectly quiet image, take it from Recovery Mode.

Restoring: [04-recovery.md](04-recovery.md).

### 3. Set up SSH key login

After de-UniFi you're still `root` with the same password: it's stored in
`/etc/shadow`, not in UniFi's database. Still, don't rely on a password you
half remember. Set a known one with `passwd root`, and add a key so you have
two ways in before anything is removed.

No `ssh-copy-id` on your computer? Once the repo is on the box (step 4), paste
your public key with `./scripts/05-add-ssh-key.sh "ssh-ed25519 AAAA… you@host"`.
Either way, test the key from a second terminal before going on. Full story:
[06-accounts-and-access.md](06-accounts-and-access.md).

### 4. Get this repo onto the CloudKey

The firmware image doesn't include `git`, and a freshly flashed box has empty
package lists, hence the `apt-get update` first. You can also `scp -r` the
folder over from your computer.

### 5. Remove UniFi

Run `10-deunifi.sh` **on the box, in an interactive SSH session**, not from a
script on your computer. It checks that SSH still works between batches, and an
open session keeps working even if something would block new logins.

- **The dry run** (no `--apply`) lists the packages it would remove and the
  services it would turn off. Nothing changes.
- **It never removes** the packages the box needs to boot or be reached:
  `ck-ui`, `ubnt-tools`, `uck-tools`, the model's `*-base-files`, the initramfs
  and kernel packages, `libpam-usermapper` (SSH login) and
  `systemd-networkd-fallbacker` (networking). Before each real removal it runs
  a simulation, and it stops if removing UniFi would take any of these with it.
- **It removes in small batches** and checks SSH after each one. A failed batch
  stops the run. Running it again is safe and picks up where it stopped.
- **Watchdog and updater services** are turned off, not removed.
- **Firmware 6.x quirks** (a UniFi agent's and PostgreSQL's uninstall scripts
  fail on this image) are handled for you.
- **At the end it offers to delete UniFi's leftover data:** `/data/unifi`,
  `/data/uos`, `/data/autobackup`, `/etc/ustd`, and PostgreSQL's data once no
  PostgreSQL package is left. `/data/autobackup` holds UniFi's own backups: copy
  it off first if you might go back to UniFi.

The lists are tested on firmware 5.x and 6.0.10. Newer firmware may add UniFi
packages the list doesn't know about, which would be left behind. Afterwards,
look for stragglers with `dpkg -l | grep -iE 'unifi|uos'`.

Reboot by hand afterwards, then check that both your password and your key
still get you in.

### 6. Set up the base system

`99-verify.sh` first confirms nothing from UniFi is still running.
`20-provision.sh` then does the following. It's safe to run again.

- **Installs a short list:** `ca-certificates`, `curl`, `git`, `rsync`,
  `e2fsprogs`, `smartmontools` and `unattended-upgrades`, each needed by a
  script here or for keeping the box healthy. Anything else (`htop`, `vim`, …)
  is up to you.
- **Turns on automatic security updates** with unattended-upgrades.
- **Sets up time sync.** It uses an NTP service if one is already installed,
  otherwise it installs `systemd-timesyncd`. The clock's backup battery may be
  dead or swollen, and HTTPS and apt fail if the clock drifts far.
- **Adds safe SSH settings** (no X11 forwarding, keepalives) in
  `/etc/ssh/sshd_config.d/10-ckg2.conf`. It rewrites that file on every run and
  never changes how you log in; locking down logins is step 13.
- **Leaves the firewall off**, like a stock Ubuntu or Debian install: every
  app you install is reachable on your LAN. With `--firewall` it installs ufw,
  blocks incoming connections except SSH, and each app then needs
  `ufw allow <port>/tcp`. Without the flag it never turns ufw on or off.
- **Warns** if you're still on Debian 11 (firmware 5.x), which gets no more
  security updates.

### 7. Format and mount the 2.5" drive

The drive sits behind a USB-to-SATA bridge inside the box, so it appears as
`/dev/sda`. The plain Gen2 has no drive bay.

- **A drive UniFi used isn't blank.** It has UniFi's partitions (swap and a
  data partition, often still mounted at `/volume`, possibly with old Protect
  recordings). See what's there with `lsblk -f /dev/sda; swapon --show`. The
  script lists what's in use and releases it only after you confirm.
- **Layout:** ext4 on the whole disk, no partition table. `--gpt` makes one GPT
  partition instead, and `--at <dir>` mounts it somewhere other than `/volume`.
- **Mounting:** by a systemd `.mount` unit, not `/etc/fstab` (UniFi's boot
  scripts reset fstab at every boot). It's marked `nofail`, so a dead drive
  doesn't stop the box from booting.
- **Tuning:** it removes a bogus RAID stripe setting that the USB bridge
  reports, and turns on weekly TRIM when the drive supports it.
- **Empty folders directly under `/volume` are deleted at every boot** by a
  UniFi boot script that stays installed, so nest your folders
  (`/volume/appdata/<app>`).

### 8. Move logs and home directories to the drive

`35-rehome-storage.sh` copies `/home`, `/var/log`, and `/srv` if it exists to
`/volume/rehome/<name>`, then bind-mounts each copy over the original.

- The originals stay on the eMMC underneath. If the drive ever fails, the box
  boots with those instead.
- `/home` switches over straight away. `/var/log` switches at the next boot,
  since running services hold it open, hence the reboot.
- It caps the system journal at 200 MB. `--no-var-log` leaves logs on the eMMC.

Why bind mounts rather than symlinks, and why only these folders:
[07-storage.md](07-storage.md).

### 9. Set up the front-panel screen

Only one program can drive the screen, so pick one. Each script turns off the
stock screen service and the other option.

- **`41-install-cloudkey.sh`** installs [jnovack/cloudkey](https://github.com/jnovack/cloudkey):
  status screens, the LEDs, reset-button actions, burn-in protection and an
  optional web dashboard. It downloads a pinned release and checks its sha256.
- **`40-install-lcd.sh`** installs `cklcd`, this repo's small Python tool, for a
  plain text status screen.

Skip this step and the stock screen service keeps the screen. Details:
[03-lcd.md](03-lcd.md).

### 10. Check everything

`99-verify.sh` only reads, so run it any time. It checks:

- no UniFi supervisor running and no failed services
- SSH is up, the network has an address, and the clock is synced
- `/volume` and the moved folders are mounted
- the screen service is running
- the firewall state and the temperatures

### 11. Create your own user

Do this after step 8, so the new home directory is on the drive. The firmware
image may not include `sudo`, hence the install line. The README copies root's
SSH keys to the new user. To give it a different key, use
`./scripts/05-add-ssh-key.sh --user <user> "<public key>"`.

If the new user's login is refused, the SSH config may restrict who can log in:
check `sshd -T | grep -iE 'allowusers|allowgroups'`.

### 12. Take a final backup

Same as step 2, but it captures the finished setup. It needs root over SSH,
which step 13 turns off, so do it first. For later backups, see
[06-accounts-and-access.md](06-accounts-and-access.md) (write the image to the
drive, then copy it off as your user).

### 13. Lock down SSH

The settings go in their own file, `/etc/ssh/sshd_config.d/00-lockdown.conf`,
because `20-provision.sh` rewrites `10-ckg2.conf` whenever it runs. Why each
setting, and how to check it took effect:
[06-accounts-and-access.md](06-accounts-and-access.md#optional-lock-it-down-only-after-key-login-is-proven).

## Where things live

The OS stays on the internal **eMMC** (`/dev/mmcblk0`, mounted at `/`), which
has about 6 GB writable. Nothing here reinstalls it. The **2.5" drive**
(`/dev/sda`, mounted at `/volume`) is for your data and anything that writes a
lot: app data under `/volume/appdata/<app>`, plus `/home` and `/var/log` after
step 8. More: [07-storage.md](07-storage.md).

## What each script does

| Script | What it does | Built-in safety |
|---|---|---|
| `00-preflight-backup.sh` | Full eMMC image to a file or stdout | Refuses to write onto the eMMC; records a sha256 |
| `05-add-ssh-key.sh` | Adds an SSH key for root or another user | Only adds a key, never disables anything |
| `10-deunifi.sh` | Removes UniFi and turns off its watchdog and updater | Dry run by default; simulation stops any removal that would take a protected package; batches with an SSH check after each |
| `20-provision.sh` | Base packages, security updates, time sync, safe SSH settings; ufw only with `--firewall` | Safe to re-run; never changes how you log in; never turns ufw on or off unless asked |
| `30-mount-storage.sh` | Formats the drive (ext4) and mounts it at `/volume` | Refuses the eMMC; shows what's in use and asks before wiping; `.mount` unit instead of fstab; `nofail` |
| `35-rehome-storage.sh` | Moves `/home`, `/var/log` (and `/srv`) to `/volume/rehome/` | Copies, never deletes; skips symlinks and existing mounts; `nofail` bind mounts |
| `40-install-lcd.sh` | Minimal `cklcd` screen | Checks the screen device first; turns off the other screen services |
| `41-install-cloudkey.sh` | Full-featured jnovack/cloudkey screen daemon | Pinned release, sha256-checked; turns off the other screen services |
| `99-verify.sh` | Health check | Read-only |

## Why not dist-upgrade by hand?

Firmware 5.x and older is Debian 11 *bullseye*, whose support ended on
2026-08-31 (Freexian sells paid extended support beyond that). Firmware 6.x is
Debian 13 *trixie* on the same 3.18 kernel. That's verified here on a Gen2 Plus
(6.0.10 → Debian 13.7) and also reported by
[hutchx86/cloudkey-unas](https://github.com/hutchx86/cloudkey-unas). Updating
the firmware (step 1) is the supported way off bullseye.

Upgrading Debian by hand is harder than on a PC, because the new userland has to
run on the old kernel with the old boot image:

| Target | systemd | On the 3.18 kernel |
|---|---|---|
| Debian 12 *bookworm* (LTS until 2028-06) | 252 | systemd 251 and later don't support kernels older than 4.15. It might boot, but nobody has shown it on this box. If it doesn't, the way back is Recovery Mode and your backup ([04](04-recovery.md)). |
| Debian 13 *trixie* | 257 | systemd 256 and later **refuse to boot on kernels without cgroup v2**, like 3.18, unless `SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1` is on the kernel command line, which lives inside the boot image. Ubiquiti's 6.x firmware deals with this itself; a hand upgrade on the 5.x boot image doesn't. **Use the firmware instead.** |

A hand upgrade also means Ubiquiti packages built for bullseye, and apt prompts
where you must **keep your `sshd_config`** or lose SSH.

If you stay on bullseye, keep the box on your LAN only: it won't get security
fixes.
