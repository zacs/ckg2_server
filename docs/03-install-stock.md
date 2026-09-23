# 03 — Install path A: reclaim stock Debian (recommended)

**This is the path to use unless you have a specific reason not to.** No
disassembly, no serial adapter, no bootloader work, low brick risk, and it
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
> solid and every peripheral works, but it's old. If you want a modern mainline
> kernel, that's the reflash/mainline path — and it's still experimental. See
> [08-mainline-kernel.md](08-mainline-kernel.md).

## Before you start

- Get in over SSH. On stock UniFi OS, enable SSH in the UniFi OS settings (or the
  device's local portal) and set a password. Then `ssh root@<ip>` (or your admin
  user).
- **Read [07-watchdog-and-persistence.md](07-watchdog-and-persistence.md)** — it
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
sudo ./00-preflight-backup.sh --stdout | gzip -1 | ssh you@nas 'cat > ck-emmc.img.gz'
#    (If you've already mounted the SATA disk, you can instead write to a file
#     there — but 30-mount-storage.sh erases that disk later, so copy it off.)

# 1. LOCK IN YOUR ACCESS before removing anything. You'll still be root with the
#    same password afterwards (it's in /etc/shadow, not the UniFi DB), but don't
#    bet your only way in on it. See docs/09-accounts-and-access.md.
sudo passwd root                               # set a KNOWN root password
sudo ./05-add-ssh-key.sh ~/.ssh/id_ed25519.pub # install a key...
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

# 6. Provision the server (tools, firewall, auto-updates, NTP):
sudo ./20-provision.sh

# 7. Format + persistently mount the internal 2.5" disk (shows up as /dev/sda):
sudo ./30-mount-storage.sh /dev/sda            # → /volume

# 8. Take over the OLED. Pick ONE (only one process may own /dev/fb0):
sudo ./41-install-cloudkey.sh                  # featured: jnovack daemon (LEDs, button, web UI)
#   -- or the lightweight text-only tool instead --
# sudo ./40-install-lcd.sh                      # this repo's minimal cklcd

# 9. (optional) Keep writes off the soldered eMMC — see docs/10-storage-and-docker.md:
sudo ./35-rehome-storage.sh                    # move /home + /srv + /var/log onto /volume
sudo ./50-install-docker.sh                    # Docker w/ data-root on /volume + capped logs

# 10. Final health check:
sudo ./99-verify.sh
```

You now have a plain Debian box with `/volume` for bulk data, a firewall, a
status screen, and no UniFi reboots. Install whatever you like (`apt install …`,
Docker, etc.).

> **Where does the OS live? Where do Docker's runtime and volumes go?** The OS
> stays on the **eMMC** (`/dev/mmcblk0`, `/`) — Path A never reinstalls it. The
> SATA disk (`/dev/sda` → `/volume`) is bulk storage and the place for anything
> write-heavy. Docker's runtime defaults to `/var/lib/docker` on the eMMC; step 9
> relocates it to `/volume/docker` and caps container logs, and can rehome
> `/home`, `/srv`, and `/var/log` too. Full explanation:
> [10-storage-and-docker.md](10-storage-and-docker.md).

> **Will I still be root with my old password?** Yes. The SSH/root password lives
> in `/etc/shadow`, and the purge doesn't touch it; the account UniFi keeps in
> MongoDB is the *web-GUI* admin, which you're discarding. Step 1 exists only so a
> half-remembered password or a UniFi-managed credential can't strand you
> mid-install. Full story: [09-accounts-and-access.md](09-accounts-and-access.md).

## What each script does (and the safety built in)

| Script | Purpose | Safety |
|--------|---------|--------|
| `00-preflight-backup.sh` | Full eMMC image to a file | Refuses to write onto the eMMC itself; records a sha256 |
| `05-add-ssh-key.sh` | Install an SSH key for root (or a user) before surgery | Only *adds* a key; never disables password auth or restricts login → can't lock you out |
| `10-deunifi.sh` | Purge UniFi apps + disable supervisor/watchdog | **Dry-run by default**; simulate-gate aborts on any cascade into `ck-ui`/`ubnt-tools`/`*-base-files`/initramfs/kernel; batched purge with SSH liveness check between batches |
| `20-provision.sh` | Base tooling, ufw, unattended-upgrades, NTP, light SSH hardening | Idempotent; does **not** disable password auth (won't lock you out) |
| `30-mount-storage.sh` | ext4 + systemd `.mount` for `/dev/sda` | Refuses eMMC/mounted disks; uses a `.mount` unit (survives the fstab rewrite) |
| `35-rehome-storage.sh` | Bind-mount `/home`, `/srv`, `/var/log` onto `/volume` | Copies (never deletes) originals; requires `/volume` on the SATA disk; `nofail` bind units (survive a dead disk), not fstab, not symlinks |
| `40-install-lcd.sh` | Install lightweight `cklcd` + service, disable stock `ck-ui` | Idempotent; probes `/dev/fb0` first |
| `41-install-cloudkey.sh` | Install the richer `jnovack/cloudkey` daemon (LEDs, button, web UI) | Pinned release; verifies it's an ARM ELF; disables `ck-ui` **and** `cklcd` so only one owns `/dev/fb0` |
| `50-install-docker.sh` | Install Docker; `data-root`→`/volume/docker`; cap container logs | Refuses eMMC data-root unless forced; kernel-aware storage-driver; backs up existing `daemon.json` |
| `99-verify.sh` | Read-only health check | Changes nothing |

## Modernizing the userland (optional)

If your firmware is on an older Debian and you want a newer one, you can
`dist-upgrade` step-by-step (9→10→11…). This works but has sharp edges on this
box:

- Do it **after** `10-deunifi.sh` (fewer pinned UniFi packages in the way).
- During `apt` prompts, **keep your locally modified `sshd_config`** or you may
  lose SSH.
- Some `/etc` files get reset on boot by the base-files hooks — keep persistent
  config in systemd units and `/etc/systemd/system` where possible.
- The vendor kernel stays put; only the userland moves.

This is genuinely optional — a de-UniFi'd stock Debian is already a perfectly
good server.
