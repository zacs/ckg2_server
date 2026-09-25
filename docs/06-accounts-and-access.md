# 06 — Accounts, credentials & not locking yourself out

Short version: **after de-UniFi you are still `root`, with the same SSH password
you had before.** But *how* that works — and how to not get locked out during the
transition — is worth understanding, because the CloudKey has two completely
separate account systems that people constantly confuse.

## Two account systems, only one of which you keep

| | **UniFi application admin** | **Linux `root`** |
|---|---|---|
| What it's for | The web GUI / UniFi controller login | SSH / the actual operating system |
| Stored in | **MongoDB** (the UniFi database) | **`/etc/shadow`** (standard Linux/PAM) |
| Login as | your email / local admin in the UI | `root` over SSH |
| After de-UniFi | **gone** (Mongo + UniFi apps removed) — you don't need it | **unchanged** — same user, same password |

On stock UniFi OS, when you enable "SSH" in the device settings and set a
password, that password is applied to the **Linux `root`** account and hashed
into `/etc/shadow`. The web-GUI account is a *different* credential living in
MongoDB. Removing the UniFi layer wipes the MongoDB one and every UniFi agent,
but a password hash sitting in `/etc/shadow` is just a file — nothing in the
purge rewrites it.

**Evidence, not just assertion:** the de-UniFi package/unit lists purge
`mongodb-server`, `unifi`, and `unifi-core` — and SSH keeps working through every
batch (that's exactly what the liveness check in `10-deunifi.sh` guards). If SSH
auth were backed by the UniFi database or a UniFi PAM module, purging Mongo and
`unifi-core` would kill logins. It doesn't. SSH auth is ordinary
`/etc/shadow` + PAM.

## So, concretely, after de-UniFi:

- You SSH in as **`root`** with the **same password** as before.
- There is normally **no separate non-root user** — on stock you *are* root.
  There's no `sudo` account unless you make one (see below).
- The password is now **yours to manage** with `passwd`. It was previously
  *applied* by a UniFi agent; with the agent gone, nothing re-applies or resets
  it — it just persists.
- **Recovery Mode is always `root` / `ubnt`** ([04-recovery.md](04-recovery.md)),
  independent of all of the above. That's your out-of-band fallback if you ever
  lose the main password (it needs physical access to the reset button).

## The one real risk: locking yourself out during the transition

The danger isn't the purge — it's *hardening SSH before you have a tested second
way in*. If your only access is a root password and you flip
`PasswordAuthentication no` or `PermitRootLogin prohibit-password` without a
working key, your next connection fails.

This repo is built to avoid that:

- `20-provision.sh` **does not** change `PermitRootLogin` or
  `PasswordAuthentication`. It only sets harmless SSH options, validates the
  config with `sshd -t` before reloading, and never restarts into a broken sshd.
- `05-add-ssh-key.sh` installs a key **without** disabling anything.
- Nothing here disables password auth for you. That final step is manual, on
  purpose, and only after you've confirmed key login.

## The safe order (do this)

These are README steps 3, 5 and 6, run from the repo folder as root:

```bash
# Step 3: a KNOWN root password (don't rely on a half-remembered one)...
passwd root
#   ...plus your SSH key. The .pub file is on your WORKSTATION, so run this there:
#       ssh-copy-id root@<cloudkey>
#   or paste the key text on the box:
#       ./scripts/05-add-ssh-key.sh "ssh-ed25519 AAAA... you@host"
#   Then open a NEW terminal: `ssh root@<cloudkey>` should not ask for a password.
#   Keep your current session open until that works.

# Step 5: NOW it's safe to remove UniFi (you have password + key, both tested):
./scripts/10-deunifi.sh --apply && reboot

# Step 6: after the reboot, confirm you can still get in (password AND key):
./scripts/99-verify.sh
```

## A proper non-root sudo user (recommended)

The install runs as root, but day-to-day you'll want a normal user with sudo.
Do this **after** `35-rehome-storage.sh`, so the new home directory lands on
the SATA disk:

```bash
command -v sudo || apt-get install -y sudo       # not guaranteed on the firmware image
adduser <user>                                   # its password is what sudo asks for
usermod -aG sudo <user>
install -d -m 700 -o <user> -g <user> /home/<user>/.ssh
install -m 600 -o <user> -g <user> /root/.ssh/authorized_keys /home/<user>/.ssh/
#   (or give it a different key: ./scripts/05-add-ssh-key.sh --user <user> "ssh-ed25519 AAAA... you@host")
```

Test from your workstation in a **new** terminal, keeping the root session open:

```bash
ssh <user>@<cloudkey-ip> 'sudo -v && echo sudo OK'
```

If that login is refused, check whether the stock config limits who may log
in — `sshd -T | grep -iE 'allowusers|allowgroups'` — and add your user there.

## Optional: lock it down (only after key login is proven)

Once your sudo user logs in with its key on a fresh connection (README step 11),
and you've taken any backup that needs root over SSH (README step 12):

```bash
sudo tee /etc/ssh/sshd_config.d/00-lockdown.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload ssh    # validate BEFORE it takes effect
```

Why a separate file: `20-provision.sh` rewrites its own drop-in, `10-ckg2.conf`,
every time it runs, so settings added there would be silently undone by a
re-run. Provisioning never touches `00-lockdown.conf`. The `00-` prefix also
matters: sshd keeps the **first** value it reads for each option, and drop-ins
are read in name order, so this file wins over `10-ckg2.conf` and over anything
later in the main config.

Prefer to keep root reachable with a key as a fallback? Use
`PermitRootLogin prohibit-password` instead of `no`. To undo the lockdown
entirely, delete the file and reload sshd.

Why both `ChallengeResponseAuthentication` *and* `KbdInteractiveAuthentication`:
firmware 5.x (bullseye) ships **OpenSSH 8.4**, which honours only the old name;
8.7 renamed it, and 6.x (trixie) ships a current OpenSSH that uses the new one.
Setting just the new name parses cleanly on 8.4 but does nothing — and with
`UsePAM yes`, keyboard-interactive can still carry a password login even with
`PasswordAuthentication no`. Confirm with:

```bash
sudo sshd -T | grep -iE 'passwordauthentication|challengeresponse|kbdinteractive|permitrootlogin'
```

If `sshd -t` complains, fix it before reloading. Do **not** reboot or restart
sshd on a config that fails the test. If `sshd -T` still shows `yes` for
something you set to `no`, the main config sets it before its `Include` line:
`grep -niE 'include|permitrootlogin|passwordauth|kbdinteractive|challengeresp' /etc/ssh/sshd_config`
shows the order.

**Backups after the lockdown:** the workstation one-liner
(`ssh root@… 'gzip -1 < /dev/mmcblk0'`) needs root over SSH, which is now off.
Image to the drive instead and copy it off as your user:

```bash
sudo mkdir -p /volume/backups
sudo ./scripts/00-preflight-backup.sh /volume/backups/emmc.img.gz
# then, on your workstation:
scp <user>@<cloudkey>:/volume/backups/emmc.img.gz .
```

## Does the fstab-rewriting hook touch credentials?

No. The base-files boot hooks that reset `/etc/fstab`
([05-watchdog-and-persistence.md](05-watchdog-and-persistence.md)) template a
handful of config files — not `/etc/shadow`, `/etc/passwd`, or
`/root/.ssh/authorized_keys`. Your password and keys persist across reboots. As
always: prove it by actually rebooting and logging in again, which the reboot
after removing UniFi does.
