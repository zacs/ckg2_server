# 05 — The front-panel LCD

## What it actually is

The little screen on the front is a **~160×64 monochrome OLED**, and — this is
the good news — the kernel exposes it as a **standard Linux framebuffer at
`/dev/fb0`**. There is **no microcontroller, no serial/I²C/SPI protocol, no
command framing** to reverse-engineer. You draw pixels into an mmap'd buffer,
exactly like any fbdev panel. The single front button is a GPIO key on
`/dev/input/event1` (`BTN_0`), not a touchscreen.

This was confirmed at the source level by
[`jnovack/cloudkey`](https://github.com/jnovack/cloudkey), a mature Go rewrite of
the stock `ck-ui` daemon, which mmaps `/dev/fb0` and blits.

## The one rule

The stock daemon **`/usr/bin/ck-ui`** owns the framebuffer and redraws over
anything you write. **Stop it before you take the panel:**

```bash
systemctl stop ck-ui      # or disable --now, which 40-install-lcd.sh does
```

(If you removed the UniFi layer via `10-deunifi.sh`, `ck-ui` is already gone.)

## Two options (pick one)

Only one process may own `/dev/fb0` at a time, so choose a single driver:

| | **`jnovack/cloudkey` (featured)** | **`cklcd` (this repo)** |
|---|---|---|
| Install | `41-install-cloudkey.sh` | `40-install-lcd.sh` |
| Language / deps | Go, single static binary (no runtime deps) | Python 3 + `python3-pil` |
| Shows | host/IP/uptime/CPU/mem/storage/tunnels, multiple screens | host/IP/uptime/load/temp/disk, or text/qr/image |
| **LED control** | ✅ `/sys/class/leds/*` | ❌ |
| **Front button** | ✅ short/long "bands", stealth toggle | ❌ |
| Burn-in mitigation | ✅ pixel-shift | ❌ |
| Web dashboard | ✅ optional live SSE dashboard | ❌ |
| Best when | you want the full front-panel experience | you want a tiny, hackable text screen |

Both installers stop+disable the stock `ck-ui`; `41` also disables `cklcd` (and
vice-versa) so the two never fight over the panel.

## Featured: the `jnovack/cloudkey` daemon

```bash
sudo scripts/41-install-cloudkey.sh            # pinned release, verified, enabled
# then tune LEDs / button / web dashboard / app-status rows:
sudo vi /etc/cloudkey.env
sudo systemctl restart cloudkey
```

The installer downloads a **pinned** prebuilt armhf release
(`cloudkey-linux-arm`), checks it's actually an ARM ELF, and **verifies its
sha256 against a known-good hash baked into the script** — the install aborts on
any mismatch. It then pulls the matching `cloudkey.service` + env template and
enables it. Config reference lives in the project's README and the annotated
`/etc/cloudkey.env`.

Pinned build (default `--tag v1.5.0`), verified 2026-07-28:

```
cloudkey-linux-arm  sha256  ce084b342e6f3218bb43243761f8ac3298e376cce4122c1dc8537a64e562a108
```

To move to a newer upstream release, verify its hash yourself and pass
`--tag vX.Y.Z --sha256 <hash>` (or `--no-verify` to skip the check — not advised).

## Lightweight: this repo's tool `cklcd`

[`lcd/cklcd`](../lcd/cklcd) is a single, dependency-light Python 3 script. It
reads the panel's real geometry and pixel format from the kernel at runtime
(`FBIOGET_VSCREENINFO` / `FBIOGET_FSCREENINFO`) so it works whether the panel
comes up as 16bpp RGB565 or a grayscale mode — you never hardcode 160×64.

Dependencies: `python3-pil` (Pillow); `python3-qrcode` only for the `qr`
subcommand. Both are in Debian.

```bash
cklcd probe                       # print detected geometry + pixel format
cklcd info                        # live host/IP/uptime/load/temp/disk (loops)
cklcd info --once                 # draw the status screen once and exit
cklcd text "hello\nworld"         # arbitrary multi-line text
cklcd qr "https://server.lan"     # a QR code
cklcd image /path/to/logo.png     # an image, scaled to fit
cklcd clear                       # blank the panel
```

`40-install-lcd.sh` installs it to `/usr/local/bin/cklcd` and runs `cklcd info`
as `cklcd.service`, configured by `/etc/cklcd.env`
([config/cklcd.env.example](../config/cklcd.env.example)).

### Customizing what's shown

The daemon just runs `cklcd info`. To show something different, override the
service command without editing the shipped unit:

```bash
systemctl edit cklcd
# add:
#   [Service]
#   ExecStart=
#   ExecStart=/usr/local/bin/cklcd qr "https://my.server.lan"
systemctl restart cklcd
```

Or write your own loop (cron/systemd timer) calling `cklcd text "…"` with
whatever you want.

## How it draws (design notes)

- Opens `/dev/fb0`, `ioctl`s the var/fix screeninfo, and `mmap`s the buffer.
- Renders text/QR/images into an in-memory Pillow RGB image sized to the panel.
- Packs each pixel into the framebuffer's native format using the **kernel-
  reported red/green/blue bitfield offsets and lengths**, so RGB565, RGB888, and
  BGRA8888 all pack correctly without special-casing. If the framebuffer reports
  a grayscale mode (or no colour bitfields), it packs luminance instead.
- Writes row by row into the mmap and `flush()`es. The panel is tiny (~19 KB), so
  pure-Python blitting is plenty fast for a status screen refreshing every few
  seconds.

## The button (bonus)

Read it as standard evdev input events from `/dev/input/event1`: `type ==
EV_KEY (1)`, `code == BTN_0 (0x100)`, `value` 1=down / 0=up. Time key-down to
key-up to distinguish short vs long presses. Only one process can usefully read
it at a time, so stop `ck-ui` first (same as the panel).
