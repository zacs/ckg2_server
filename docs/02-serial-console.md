# 02 — Serial console (UART)

You do **not** need serial for the recommended "reclaim stock" path (Tier 1) —
that's all done over SSH. You **do** need it for:

- the full-reflash path ([04-install-reflash.md](04-install-reflash.md)),
- un-bricking / recovery when SSH is gone ([06-recovery.md](06-recovery.md)),
- any mainline-kernel bring-up ([08-mainline-kernel.md](08-mainline-kernel.md)).

## What you need

- A **3.3 V** USB-TTL serial adapter (CP2102, FT232RL, PL2303, CH340 — anything
  that does 3.3 V logic). **Do not use a 5 V adapter** — you can damage the SoC.
- Three jumper wires.
- A terminal program: `screen`, `minicom`, `picocom`, or PuTTY.

## The header

Inside the case, Ubiquiti exposes the UART as a small set of test pads. On the
Gen2 Plus board they're labelled **`JDB2`** with three pins marked **`T` / `R` /
`G`** (Tx / Rx / Gnd). Colin Cogle's teardown calls the same port **`J22`, "a
3.3 V TTL serial port."** Some boards have a second `R/T/G` pad group as well.

Wiring (straight-through logic levels, cross Tx/Rx):

| CloudKey pad | Adapter pin |
|--------------|-------------|
| `G` (GND)    | GND         |
| `T` (Tx, board→PC) | RX    |
| `R` (Rx, PC→board) | TX    |
| *(leave any VCC/3V3 pad unconnected — power the CloudKey normally via PoE/USB-C)* | — |

## Settings

- **Baud: 115200, 8N1**, no flow control.

```bash
# pick whichever tool you have; device name varies (/dev/ttyUSB0, /dev/tty.usbserial-*)
screen /dev/ttyUSB0 115200
# or
picocom -b 115200 /dev/ttyUSB0
# or
minicom -b 115200 -D /dev/ttyUSB0
```

Press **Enter** to get the prompt (`Please press Enter to activate this
console.`). A normal boot shows the login as `cloudkey-apq8053 login:`.

## Logins seen in the wild

- Normal firmware: your configured admin, or `root` if you set an SSH/root
  password.
- Recovery firmware: `root` / `ubnt` (or `ubnt` / `ubnt`). This is how you get a
  shell to run `ubnt-tool fwupdate` when the main OS is dead.

## Tips

- If you see boot output but can't type, it's almost always **Tx/Rx swapped** or
  a missing common ground.
- Garbage characters = wrong baud (try 115200 first, it's near-universal here).
- Capture the boot log (`screen -L`, or picocom's logging) — it's gold for
  identifying partitions and the exact firmware string when you need recovery.
