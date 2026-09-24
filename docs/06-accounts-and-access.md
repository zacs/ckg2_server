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

```bash
cd ckg2_server/scripts

# 1. Establish a KNOWN root password (don't rely on a vaguely-remembered one):
sudo passwd root

# 2. Install your SSH public key and TEST it from a second terminal.
#    The .pub file is on your WORKSTATION, so either run this there:
#        ssh-copy-id root@<cloudkey-ip>
#    or paste the key text on the box:
sudo ./05-add-ssh-key.sh "ssh-ed25519 AAAA... you@host"
#    → open a NEW terminal:  ssh root@<cloudkey-ip>   (should not ask for a password)
#    Keep your current session open until that works.

# 3. NOW it's safe to de-UniFi (you have password + key, both tested):
sudo ./10-deunifi.sh --apply && sudo reboot

# 4. After reboot, confirm you can still get in (password AND key), then verify:
sudo ./99-verify.sh
```

## Optional: a proper non-root sudo user

Running everything as root is fine for a homelab box, but if you'd rather:

```bash
adduser zac                       # sets a password interactively
usermod -aG sudo zac              # grant sudo (install `sudo` first if needed: apt install sudo)
sudo ./05-add-ssh-key.sh --user zac "ssh-ed25519 AAAA... you@host"
# test:  ssh zac@<ip>   then   sudo -v
```

## Optional: lock it down (only after key login is proven)

Once you've logged in with your key on a fresh connection and confirmed it works:

```bash
# edit the drop-in this repo installed
sudo tee /etc/ssh/sshd_config.d/10-ckg2.conf >/dev/null <<'EOF'
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
sudo sshd -t && sudo systemctl reload ssh    # validate BEFORE it takes effect
```

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
sshd on a config that fails the test.

## Does the fstab-rewriting hook touch credentials?

No. The base-files boot hooks that reset `/etc/fstab`
([05-watchdog-and-persistence.md](05-watchdog-and-persistence.md)) template a
handful of config files — not `/etc/shadow`, `/etc/passwd`, or
`/root/.ssh/authorized_keys`. Your password and keys persist across reboots. As
always: prove it by actually rebooting and logging in again, which step 4 above
does.
