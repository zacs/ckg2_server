# 08 — Docker

Docker works on the CloudKey, with two limits that come from the old kernel:
containers must use **host networking**, and images use more disk space than
usual. The install commands are in the [README](../README.md#docker-optional);
this page explains them.

Tested on a Gen2 Plus with firmware 6.0.10 (Debian 13, kernel
`3.18.44-ui-qcom`) and Debian's own Docker packages (Docker 26.1.5,
containerd 1.7.24, runc 1.1.15).

| | |
|---|---|
| Containers with their own process namespace (the app is PID 1 inside) | Works |
| Host networking (`--network host`, `network_mode: host`) | Works |
| Bridge networks: plain `docker run`, Compose's default network, `-p` port mapping | **Fails** |
| `overlay2` storage | Not available; uses `vfs` |

## What the kernel supports

Ubiquiti's published config for this chip turns off features Docker needs, but
the kernel that actually runs was built differently. It has everything on
Docker's list of required features, and the modules Docker loads (`veth`,
`br_netfilter`, the NAT pieces) ship with the firmware. To check a box yourself:

```bash
curl -fsSLo /tmp/check-config.sh https://raw.githubusercontent.com/moby/moby/master/contrib/check-config.sh
bash /tmp/check-config.sh /proc/config.gz
```

What's missing, and what it means:

- **nf_tables** → Debian 13's iptables uses nf_tables by default, so it has to
  be switched to its "legacy" mode, which this kernel supports.
- **The pids cgroup** → `--pids-limit` doesn't work. Docker prints a warning and
  otherwise ignores it.
- **AppArmor and SELinux** → Docker runs without them.

## Storage: `vfs` instead of `overlay2`

`overlay2` stacks image layers with overlayfs, which needs several lower layers
in one mount. This kernel's overlayfs only takes one. (Test: mounting overlay
with `lowerdir=a:b` fails.) The usual fallback, `fuse-overlayfs`, needs FUSE,
which isn't in the kernel either.

That leaves `vfs`, which stores each layer as a full copy of the files beneath
it:

- **Running containers aren't slowed down.**
- **Images take several times their listed size.** A 200 MB image can use
  1–2 GB, which is why Docker's data lives on the 2.5" drive.
- **Pulling images and creating containers take longer**, since every layer is
  copied.

`docker system df` shows the space used; `docker image prune` clears unused
images.

## Networking: host only

Docker gives a container on a bridge network a default route. To do that, it
asks the kernel how to reach the gateway, and reading the answer fails:

```
failed to set gateway while updating gateway: route for the gateway 172.17.0.1
could not be found: decoding failed: buffer too small (4 bytes)
```

- **The cause:** Qualcomm's kernel is based on Android's, which adds a
  "which user asked" field (`RTA_UID`, 4 bytes) to route-lookup replies,
  numbered 18. Mainline Linux later used number 18 for a different field
  (`RTA_VIA`, at least 6 bytes). Docker's networking library
  ([vishvananda/netlink](https://github.com/vishvananda/netlink)) reads the
  user ID as `RTA_VIA` and gives up.
- **A newer Docker doesn't help:** the library's current code does the same.
  Only a patched Docker build (redone after every update) or a rebuilt kernel
  would fix it.
- **Host networking skips that step**, because the container uses the box's own
  network.

What host networking means in practice:

- Apps listen directly on the box's ports, as if installed without Docker. There
  is no `-p` port mapping, and two apps can't use the same port.
- Containers reach each other at `localhost:<port>`, not by service name.
- If you turned on the firewall (`20-provision.sh --firewall`), `ufw allow
  <port>` works for containers like any other app. (With bridge networking,
  Docker bypasses ufw.)

In Compose, give every service `network_mode: host` and no `ports:`:

```yaml
services:
  adguard:
    image: adguard/adguardhome
    network_mode: host
    restart: unless-stopped
    volumes:
      - /volume/appdata/adguard/work:/opt/adguardhome/work
      - /volume/appdata/adguard/conf:/opt/adguardhome/conf
```

## The install, explained

The README's commands, in order:

1. **iptables in legacy mode**, before Docker's first start, so its firewall
   rules load.
2. **`/etc/docker/daemon.json`**, also before the first start:
   - `data-root: /volume/docker` keeps images and containers off the eMMC,
     which has only about 6 GB writable.
   - `storage-driver: vfs` (see above).
   - `log-opts` caps each container's log at 3 × 10 MB.
3. **`RequiresMountsFor=/volume/docker`** on `docker.service`: if the drive
   doesn't mount, Docker doesn't start, instead of running on an empty folder on
   the eMMC.
4. **Debian's packages** (`docker.io`, `docker-cli`, `docker-compose`), so
   Docker gets Debian's security updates with everything else. On Debian 13 the
   `docker` command is in its own package, `docker-cli`, which `docker.io` only
   recommends.
5. **The `docker` group** lets your user run `docker` without `sudo`. Anyone in
   it can control the whole box, the same as with `sudo`.

Keep app data in bind mounts under `/volume/appdata/<app>`, as in the example
above.

If you use Beszel, restart its agent after installing Docker
(`sudo systemctl restart beszel-agent`) so it shows your containers.

## Undo

```bash
sudo apt-get purge -y docker.io docker-cli docker-compose containerd runc && sudo apt-get autoremove -y
sudo rm -rf /volume/docker /etc/docker /etc/systemd/system/docker.service.d
sudo update-alternatives --auto iptables && sudo update-alternatives --auto ip6tables
```
