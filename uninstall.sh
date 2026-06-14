#!/bin/bash
# uninstall.sh — remove the files this project installs and disable its units.
# Does NOT remove packages (gpsd/chrony/pps-tools) or touch /boot config.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

systemctl disable --now gps-watchdog.timer 2>/dev/null || true

rm -f \
  /etc/chrony/conf.d/gps.conf \
  /etc/chrony/conf.d/serve-lan.conf \
  /etc/udev/rules.d/99-pps-gps.rules \
  /etc/udev/rules.d/99-gps-rearm.rules \
  /etc/systemd/system/gps-rearm.service \
  /etc/systemd/system/gps-watchdog.service \
  /etc/systemd/system/gps-watchdog.timer \
  /usr/local/sbin/gps-watchdog.sh \
  /run/gps-watchdog.last-restart

udevadm control --reload-rules
systemctl daemon-reload
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

echo "Removed. /etc/default/gpsd and the /boot pps-gpio overlay were left in place"
echo "(revert those by hand if you want a full teardown)."
