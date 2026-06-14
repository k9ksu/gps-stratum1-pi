#!/bin/bash
# install.sh — deploy the GPS-disciplined stratum-1 NTP server config.
#
# Copies the mirrored rootfs/ tree into /, installs dependencies, ensures the
# PPS GPIO boot overlay is present, and enables/restarts the services.
#
# Usage:
#   sudo ./install.sh                 # full install (default GPIO pin 18)
#   sudo GPIO_PIN=4 ./install.sh      # use a different PPS GPIO pin
#   sudo ./install.sh --no-boot-config   # skip editing /boot config (do it yourself)
#   sudo ./install.sh --no-packages      # skip apt install
set -euo pipefail

GPIO_PIN="${GPIO_PIN:-18}"
DO_BOOT=1
DO_PKGS=1
for a in "$@"; do
  case "$a" in
    --no-boot-config) DO_BOOT=0 ;;
    --no-packages)    DO_PKGS=0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing dependencies"
if [[ $DO_PKGS -eq 1 ]]; then
  apt-get update -qq
  apt-get install -y gpsd gpsd-clients chrony pps-tools
else
  echo "    (skipped --no-packages)"
fi

echo "==> Copying config tree into /"
# -b backs up anything we overwrite to <file>~
cp -a --backup=numbered "$REPO/rootfs/." /
chmod 0755 /usr/local/sbin/gps-watchdog.sh

echo "==> Ensuring PPS GPIO boot overlay (pin $GPIO_PIN)"
if [[ $DO_BOOT -eq 1 ]]; then
  CFG=/boot/firmware/config.txt
  [[ -f "$CFG" ]] || CFG=/boot/config.txt
  if [[ -f "$CFG" ]]; then
    if grep -qE '^\s*dtoverlay=pps-gpio' "$CFG"; then
      echo "    pps-gpio overlay already present in $CFG — leaving as-is"
    else
      cp -a "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || \
        cp -a "$CFG" "$CFG.bak"   # date may be wrong pre-sync; still make a backup
      printf '\n# GPS PPS on a GPIO pin (added by gps-stratum1-pi installer)\ndtoverlay=pps-gpio,gpiopin=%s\n' "$GPIO_PIN" >> "$CFG"
      echo "    appended dtoverlay=pps-gpio,gpiopin=$GPIO_PIN to $CFG (REBOOT required)"
    fi
  else
    echo "    WARNING: no /boot config found; add 'dtoverlay=pps-gpio,gpiopin=$GPIO_PIN' manually" >&2
  fi
  if [[ "$GPIO_PIN" != "18" ]]; then
    echo "    NOTE: non-default pin — after reboot check 'cat /sys/class/pps/pps0/name'"
    echo "          and update ATTR{name} in /etc/udev/rules.d/99-pps-gps.rules to match."
  fi
else
  echo "    (skipped --no-boot-config; ensure dtoverlay=pps-gpio,gpiopin=$GPIO_PIN is set)"
fi

echo "==> Reloading udev + systemd"
udevadm control --reload-rules && udevadm trigger
systemctl daemon-reload

echo "==> Enabling services"
systemctl enable gpsd.socket gpsd chrony >/dev/null 2>&1 || systemctl enable gpsd chrony
systemctl enable --now gps-watchdog.timer

echo "==> Restarting gpsd + chrony"
systemctl restart gpsd
sleep 5
systemctl restart chronyd 2>/dev/null || systemctl restart chrony

echo
echo "Done. If the boot overlay was just added, REBOOT now for PPS to appear."
echo "Then check:  chronyc tracking   (want: Stratum 1, Reference ID = PPS)"
echo "             chronyc sources    (want: #* PPS selected)"
