# gps-stratum1-pi

Turn a Raspberry Pi + a u-blox GNSS receiver into a **GPS/PPS-disciplined
stratum-1 NTP server** with chrony, plus two self-healing watchdogs so it
survives USB re-enumeration and silent gpsd failures.

Built and running on a **Raspberry Pi 5 / Debian 13 (trixie)** with a **u-blox 8**
USB receiver and its **PPS pulse wired to a GPIO pin**. Should work on any
recent Pi/Debian with minor edits.

## How it works

```
u-blox GNSS  ──USB(NMEA)──▶ gpsd ──SHM unit 0──▶ chrony  (coarse second, "NMEA", noselect)
     │
     └──PPS pulse──▶ GPIO pin ──/dev/pps-gps──▶ chrony  (sub-µs edge, "PPS", selected)
```

- **gpsd** reads NMEA from the receiver and publishes the coarse time into an
  NTP shared-memory segment.
- The **PPS** (pulse-per-second) signal goes to a **GPIO pin** (via the
  `pps-gpio` device-tree overlay), giving chrony a nanosecond-grade edge. The
  GPIO path is stable across USB re-enumeration — that's why PPS, not USB, is
  the precision source.
- **chrony** uses NMEA only to label which second each PPS edge belongs to
  (`refclock PPS ... lock NMEA`), and disciplines the system clock from PPS →
  **stratum 1**.

### Why two watchdogs
gpsd has two distinct failure modes; each needs its own recovery:

1. **USB re-enumeration** (`/dev/ttyACM0` recreated): caught by a udev rule
   (`99-gps-rearm.rules` → `gps-rearm.service`) that restarts gpsd on device `add`.
2. **Silent SHM starvation** (gpsd keeps the tty but stops exporting time — no
   USB event): caught by `gps-watchdog.timer`, which polls chrony every 2 min
   and restarts gpsd when the NMEA refclock goes stale.

In both cases only **gpsd** is bounced; chrony re-locks PPS on its own.

## Hardware

- Raspberry Pi (tested: Pi 5, Debian 13)
- u-blox GNSS receiver with a **PPS output** (tested: u-blox 8, USB `1546:01a8`)
- PPS pin wired to a Pi GPIO (default **GPIO18**, physical pin 12) + GND
- GNSS antenna with sky view

## Install

```bash
git clone https://github.com/<you>/gps-stratum1-pi
cd gps-stratum1-pi
sudo ./install.sh            # or: sudo GPIO_PIN=4 ./install.sh
sudo reboot                  # only needed the first time, to load the PPS overlay
```

After reboot:

```bash
chronyc tracking    # want: Stratum 1, Reference ID = PPS
chronyc sources     # want: "#* PPS" selected, "#? NMEA" reachable
```

## Things you MUST review for your setup

| File | What to change |
|------|----------------|
| `rootfs/etc/chrony/conf.d/serve-lan.conf` | the `allow` subnet(s) you serve, or comment out for local-only |
| `rootfs/etc/udev/rules.d/99-gps-rearm.rules` | `idVendor`/`idProduct` if not a u-blox 8 (`lsusb`) |
| `rootfs/etc/default/gpsd` | `DEVICES=` if your receiver isn't `/dev/ttyACM0` |
| `GPIO_PIN` (install arg) + `99-pps-gps.rules` | if PPS is on a pin other than GPIO18 — see note below |

**Non-default GPIO pin:** the `pps-gpio` overlay names the kernel PPS device
after its device-tree node (e.g. `pps@12` for GPIO18). If you change the pin,
after reboot run `cat /sys/class/pps/pps0/name` and update the `ATTR{name}`
match in `99-pps-gps.rules` accordingly.

## Repo layout

```
rootfs/                         # mirrors / — install.sh copies this into place
  etc/default/gpsd
  etc/chrony/conf.d/{gps,serve-lan}.conf
  etc/udev/rules.d/99-pps-gps.rules
  etc/udev/rules.d/99-gps-rearm.rules
  etc/systemd/system/gps-rearm.service
  etc/systemd/system/gps-watchdog.{service,timer}
  usr/local/sbin/gps-watchdog.sh
install.sh                      # deploy + enable
uninstall.sh                    # remove installed files + disable units
```
The one thing not in `rootfs/` is the `dtoverlay=pps-gpio` line in
`/boot/firmware/config.txt` — a boot file the installer appends (with a backup),
since it can't simply be dropped in.

## Troubleshooting

```bash
sudo /usr/local/sbin/gps-watchdog.sh --dry-run   # what the watchdog thinks now
gpspipe -w -n 5                                   # raw gpsd output (want "mode":3)
sudo ppstest /dev/pps-gps                         # confirm PPS pulses
journalctl -t gps-watchdog -e                     # watchdog actions
```

- **Stuck at stratum 2/3, NMEA Reach 0:** gpsd isn't feeding SHM — the watchdog
  should fix it within a few minutes, or `sudo systemctl restart gpsd`.
- **No `/dev/pps-gps`:** the `pps-gpio` overlay isn't loaded (reboot needed) or
  the `ATTR{name}` match doesn't match your pin.
- **Cold-boot timestamps look wrong** (files dated weeks ago): expected on a Pi
  whose clock starts stale and gets stepped once GPS locks — not a fault.

## License

MIT — see [LICENSE](LICENSE).
