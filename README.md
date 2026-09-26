# ckg2_server — turn a UniFi CloudKey Gen2 into a small Linux server

Turn a **UniFi CloudKey Gen2 Plus** (`UCK-G2-PLUS`) or **Gen2** (`UCK-G2`) into
a quiet, PoE-powered Debian server. When you're done you have:

- **Debian 13** with the UniFi software removed, so no more self-reboots
- the **2.5" drive** formatted and mounted at `/volume` for your data
- **automatic security updates**, time sync, and SSH key login
- the **front-panel screen** showing status (optional)

No case opening and no serial cable: everything happens over SSH.

## Before you start

- A CloudKey **Gen2 Plus** or **Gen2**. The drive steps need the Plus (the
  plain Gen2 has no drive bay).
- SSH turned on in the UniFi OS settings, and its root password.
- A computer on the same network with a few GB free for a backup.
- **The 2.5" drive gets erased.** Copy off anything you want to keep, such as
  old UniFi Protect recordings.
- Skim [If something goes wrong](#if-something-goes-wrong) first.

Commands marked **(workstation)** run on your computer. Everything else runs on
the CloudKey over SSH, as `root` until you create your own user in step 11.
Replace `<cloudkey>` with its IP address or hostname.

## Install

### 1. Update to current firmware

Firmware 6.x is Debian 13. Firmware 5.x and older is Debian 11, which stopped
getting security updates on 2026-08-31.

```bash
cat /etc/os-release              # "trixie": skip this step. "bullseye": update.
ubnt-systool fwupdate <firmware-URL>
```

Get the URL from [ui.com/download](https://ui.com/download) → Cloud Keys → your
model. The file name contains `UCKP` for the Gen2 Plus and `UCKG2` for the
Gen2. For example, Gen2 Plus 6.0.10:
`https://fw-download.ubnt.com/data/unifi-cloudkey/9c12-UCKP-6.0.10-222899cf-67fc-434d-855b-1499dfb2b0fe.bin`

It downloads about 860 MB, flashes, and reboots on its own. SSH back in and
check that `cat /etc/os-release` says `trixie`.

### 2. Back up the internal storage (workstation)

This copies the CloudKey's whole internal eMMC to your computer, so you can
always get back to this point. It takes a while.

```bash
ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc.img.gz
gzip -t cloudkey-emmc.img.gz     # no output means the file is complete
```

How to restore it: [docs/04-recovery.md](docs/04-recovery.md).

### 3. Set up SSH key login (workstation)

```bash
ssh-copy-id root@<cloudkey>
ssh -o PasswordAuthentication=no root@<cloudkey> true && echo "key login works"
```

Also make sure you know the root password (`passwd root` on the CloudKey sets
it). It's your way back in if the key ever fails.

### 4. Get this repo onto the CloudKey

```bash
apt-get update && apt-get install -y git
git clone https://github.com/zacs/ckg2_server && cd ckg2_server
```

### 5. Remove UniFi

```bash
./scripts/10-deunifi.sh          # dry run: lists what it would remove, changes nothing
./scripts/10-deunifi.sh --apply  # removes it (asks first)
reboot
```

Check the **Would remove** list before applying: it should be UniFi packages
only. The script won't remove anything the box needs to boot, and it checks
that SSH still works after each batch. If a batch reports **FAILED**, running
it again is safe.

### 6. Set up the base system

```bash
cd ckg2_server
./scripts/99-verify.sh           # should show no UniFi services running
./scripts/20-provision.sh        # base packages, security updates, time sync
```

Like a stock Ubuntu or Debian install, no firewall is turned on, so anything
you install is reachable on your LAN. Add `--firewall` if you want one; then
each app needs `ufw allow <port>`.

### 7. Format and mount the 2.5" drive (erases it)

```bash
./scripts/30-mount-storage.sh /dev/sda
```

It shows what's on the drive and asks before wiping. The drive is mounted at
`/volume`, and again at every boot.

### 8. Move logs and home directories to the drive (recommended)

```bash
./scripts/35-rehome-storage.sh
reboot
```

The internal eMMC is soldered to the board and wears out with writes. This
moves `/home` and `/var/log` onto the drive, which you can replace.

### 9. Set up the front-panel screen (optional)

```bash
cd ckg2_server
./scripts/41-install-cloudkey.sh   # status screens, LEDs, button, optional web dashboard
```

Or use `./scripts/40-install-lcd.sh` for a minimal text-only screen. Pick one.
Details: [docs/03-lcd.md](docs/03-lcd.md).

### 10. Check everything

```bash
./scripts/99-verify.sh
```

### 11. Create your own user (recommended)

So day-to-day work doesn't happen as root. Replace `<user>` with the name you
want.

```bash
command -v sudo || apt-get install -y sudo
adduser <user>                   # the password you set is what sudo asks for
usermod -aG sudo <user>
install -d -m 700 -o <user> -g <user> /home/<user>/.ssh
install -m 600 -o <user> -g <user> /root/.ssh/authorized_keys /home/<user>/.ssh/
```

Test it from a **new** terminal on your workstation, keeping your root session
open:

```bash
ssh <user>@<cloudkey> 'sudo -v && echo "sudo works"'
```

From now on, log in as `<user>` and put `sudo` in front of the scripts. Your
user can't read root's copy of the repo, so clone your own:

```bash
git clone https://github.com/zacs/ckg2_server ~/ckg2_server
sudo rm -rf /root/ckg2_server    # optional: remove root's copy
```

## Optional final steps

### 12. Take a final backup (workstation)

This captures the finished setup, so a restore brings you back here instead of
to stock UniFi. Do it **before step 13**: after that, root can't log in over
SSH.

```bash
ssh root@<cloudkey> 'gzip -1 < /dev/mmcblk0' > cloudkey-emmc-final.img.gz
gzip -t cloudkey-emmc-final.img.gz
```

### 13. Lock down SSH

This allows key login only and turns off root login. Do it only after step
11's test worked.

```bash
sudo tee /etc/ssh/sshd_config.d/00-lockdown.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload ssh     # sshd -t checks the config first
sudo sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
```

The last command should show `no` for all three. Keep your current session
open and test from a new terminal: `ssh <user>@<cloudkey>` should work, and
`ssh root@<cloudkey>` should be refused. To undo, delete the file and reload
SSH. More detail: [docs/06-accounts-and-access.md](docs/06-accounts-and-access.md).

## Using the server

- **Install software** with `sudo apt install …`, an app's own Linux
  installer, or [Docker](#docker-optional) (host networking only).
- **Keep app data on the drive**, under `/volume/appdata/<app>`, and make the
  app's service wait for the drive at boot. How: [docs/07-storage.md](docs/07-storage.md#running-your-own-services).
- **Security updates** for Debian 13 install automatically.
- **Keep it on your LAN.** Don't port-forward to it: the kernel is old and can't
  be upgraded.

## Good to know

- **It's a Qualcomm chip.** The CloudKey Gen2 uses a Qualcomm APQ8053
  (Snapdragon 625), not the Marvell chip many online guides assume, so most
  "CloudKey Linux" advice doesn't apply. It has 8 cores, 3 GB of RAM on the Plus
  (2 GB on the Gen2), and 32 GB of eMMC, of which only **about 6 GB** is
  writable for the OS: keep big things on `/volume`. The network port and the
  drive both connect over internal USB. Details:
  [docs/01-hardware.md](docs/01-hardware.md).
- **It's fanless.** `99-verify.sh` prints temperatures; about 45 °C at idle is
  normal.
- **The internal battery can swell** on older units. It only provides a clean
  shutdown when power drops, and the box runs fine on PoE without it.
- **Some UniFi boot behaviour remains:** `/etc/fstab` is reset at every boot,
  so the scripts use systemd units instead. Empty folders directly under
  `/volume` are deleted at boot, so nest your folders (`/volume/appdata/<app>`).
  Details: [docs/05-watchdog-and-persistence.md](docs/05-watchdog-and-persistence.md).

## If something goes wrong

- **Recovery Mode:** hold the reset button for about 10 seconds while powering
  on. The box then serves a web page and SSH (`root` / `ubnt`), from which you
  can reinstall stock firmware or restore your backup. Step by step:
  [docs/04-recovery.md](docs/04-recovery.md).
- Recovery Mode lives in its own partition. Never write to the Qualcomm
  firmware partitions (`sbl1`, `rpm`, `tz`, `devcfg`, `aboot`, `recovery`):
  they're what make the box recoverable. Nothing in this repo touches them.

## Docker (optional)

Docker works, with two limits from the old kernel: containers must use **host
networking**, and images take more disk space than usual. Why, and how to undo
it: [docs/08-docker.md](docs/08-docker.md).

```bash
# Docker's firewall rules need iptables' "legacy" mode on this kernel
sudo apt-get install -y iptables
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Settings for Docker's first start: data on the drive, and the storage driver this kernel supports
sudo mkdir -p /etc/docker /volume/docker /etc/systemd/system/docker.service.d
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "data-root": "/volume/docker",
  "storage-driver": "vfs",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
printf '[Unit]\nRequiresMountsFor=/volume/docker\n' | sudo tee /etc/systemd/system/docker.service.d/ckg2.conf >/dev/null

# Install, and let your user run docker without sudo (log out and back in after)
sudo apt-get install -y --no-install-recommends docker.io docker-cli docker-compose
sudo usermod -aG docker <user>
```

Then check it: `docker run --rm --network host hello-world`.

- **Always use host networking:** `--network host` with `docker run`, and
  `network_mode: host` (with no `ports:`) for every service in Compose. Without
  it, containers fail with `route for the gateway … could not be found`.
- **Keep app data on the drive**, in bind mounts under `/volume/appdata/<app>`.

## Monitoring with Beszel (optional)

The [Beszel](https://beszel.dev) agent works here, installed with Beszel's
normal Linux installer. On its own it only sees the internal storage. This adds
the 2.5" drive's capacity, I/O and SMART data:

```bash
sudo mkdir -p /etc/systemd/system/beszel-agent.service.d
sudo tee /etc/systemd/system/beszel-agent.service.d/ckg2.conf >/dev/null <<'EOF'
[Unit]
# The agent looks for disks once, at startup: wait for the drive.
After=volume.mount

[Service]
Environment="EXTRA_FILESYSTEMS=/volume__SSD"
Environment="SMART_DEVICES=/dev/sda:sat"
# SMART needs CAP_SYS_RAWIO, and this kernel can't give it to a non-root user.
User=root
CapabilityBoundingSet=CAP_SYS_RAWIO
EOF
sudo systemctl daemon-reload && sudo systemctl restart beszel-agent
sudo journalctl -u beszel-agent -b --no-pager | grep -iE 'detected disk|smart'
```

- The last command should show `Detected disk name=SSD … mount=/volume`. SMART
  data shows up on the system page after a few minutes.
- `__SSD` is the name shown in Beszel; change it to anything you like.
- `:sat` is how SMART gets through the drive's USB bridge. Test it with
  `sudo smartctl -d sat -H /dev/sda`. If that fails, leave out the
  `SMART_DEVICES`, `User` and `CapabilityBoundingSet` lines.
- Don't use `AmbientCapabilities=` from Beszel's SMART guide: the 3.18 kernel
  doesn't support it, and the agent won't start.

## What's in this repo

| Script | What it does |
|---|---|
| `scripts/00-preflight-backup.sh` | eMMC backup from the box itself (an alternative to step 2) |
| `scripts/05-add-ssh-key.sh` | adds an SSH key from pasted text (an alternative to `ssh-copy-id`) |
| `scripts/10-deunifi.sh` | removes UniFi; dry run by default |
| `scripts/20-provision.sh` | base packages, security updates, time sync, optional firewall |
| `scripts/30-mount-storage.sh` | formats and mounts the 2.5" drive at `/volume` |
| `scripts/35-rehome-storage.sh` | moves `/home` and `/var/log` onto the drive |
| `scripts/40-install-lcd.sh` / `41-install-cloudkey.sh` | front-panel screen: minimal / full-featured |
| `scripts/99-verify.sh` | read-only health check |

Background reading in [`docs/`](docs): [hardware](docs/01-hardware.md),
[install details](docs/02-install.md), [front panel](docs/03-lcd.md),
[recovery](docs/04-recovery.md), [reboots and persistence](docs/05-watchdog-and-persistence.md),
[accounts and SSH](docs/06-accounts-and-access.md), [storage and running services](docs/07-storage.md),
[Docker](docs/08-docker.md).

## Credits

- **[jnovack/cloudkey](https://github.com/jnovack/cloudkey)**: the front-panel
  daemon, and the runbook that the UniFi removal list is based on.
- **[hutchx86/cloudkey-unas](https://github.com/hutchx86/cloudkey-unas)**: first
  evidence that firmware 6.x runs Debian 13 on this hardware.
- **[Colin Cogle](https://colincogle.name/blog/unifi-cloud-key-rescue/)**:
  Recovery Mode and `ubnt-tool fwupdate`.
- **[FullDuplexTech](https://fullduplextech.com/turn-unifi-cloud-key-gen-2-into-a-headless-linux-server/)**:
  the stay-on-stock approach.
- FCC teardown photos of the [SWX-UCKG2P](https://fccid.io/SWX-UCKG2P) and
  [SWX-UCKG2](https://fccid.io/SWX-UCKG2).

## Disclaimer

This voids the warranty and removes UniFi. Taking the backup in step 2 and
knowing Recovery Mode are what keep it low-risk. Provided as-is, with no
guarantees.

## License

MIT, see [LICENSE](LICENSE).
