#!/bin/bash
# gps-watchdog — periodic safety-net for the GPS-disciplined stratum-1 clock.
#
# The udev rule 99-gps-rearm.rules only fires on a u-blox USB *re-enumeration*
# (tty 'add'). But gpsd can silently stop exporting its NTP SHM segment while
# /dev/ttyACM0 stays present: no udev event, so that path is blind to it.
# chrony's NMEA refclock then starves, PPS (lock NMEA) goes unusable, and the
# server drops to stratum 3.
#
# This watchdog watches the end-to-end truth — chrony's NMEA refclock — and
# bounces gpsd ONLY (never chrony; the GPIO PPS fd stays valid and re-locks on
# its own), matching gps-rearm.service. Uses CLOCK_MONOTONIC (/proc/uptime) for
# all timing so a cold-boot clock step can't confuse it.
#
# Run with --dry-run to print the decision without acting.

set -uo pipefail

STALE_SECS=300        # NMEA unreachable for at least this long => starving
MIN_RESTART_GAP=600   # never bounce gpsd more often than this
STAMP=/run/gps-watchdog.last-restart
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

note() { logger -t gps-watchdog -- "$*"; [[ $DRY -eq 1 ]] && echo "$*"; }

up_secs=$(awk '{printf "%d", $1}' /proc/uptime)

# NMEA refclock line: mode,state,name,stratum,poll,reach,lastrx,...
read -r reach lastrx < <(chronyc -c sources 2>/dev/null \
  | awk -F, '$3=="NMEA"{print $6, $7; exit}')

if [[ -z "${reach:-}" ]]; then
  note "no NMEA refclock in chronyc output; nothing to judge"
  exit 0
fi

# Reachable (reach != 0) => healthy.
if [[ "$reach" != "0" ]]; then
  [[ $DRY -eq 1 ]] && echo "OK: NMEA reach=$reach lastrx=${lastrx}s — healthy"
  exit 0
fi

# reach==0 but give a freshly (re)started gpsd time to acquire before blaming it.
gpsd_mono_us=$(systemctl show -p ActiveEnterTimestampMonotonic --value gpsd 2>/dev/null || echo 0)
[[ "$gpsd_mono_us" =~ ^[0-9]+$ ]] || gpsd_mono_us=0
gpsd_uptime=$(( up_secs - gpsd_mono_us/1000000 ))
if (( gpsd_uptime < STALE_SECS )); then
  [[ $DRY -eq 1 ]] && echo "WAIT: NMEA reach=0 but gpsd only up ${gpsd_uptime}s (<${STALE_SECS}s) — grace"
  exit 0
fi

# Rate-limit (uptime-based stamp; /run clears on reboot).
if [[ -f "$STAMP" ]]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( up_secs - last < MIN_RESTART_GAP )); then
    note "NMEA stale (reach=0 lastrx=${lastrx}s) but within ${MIN_RESTART_GAP}s cooldown — skipping"
    exit 0
  fi
fi

if [[ $DRY -eq 1 ]]; then
  echo "WOULD restart gpsd: NMEA stale (reach=0 lastrx=${lastrx}s, gpsd up ${gpsd_uptime}s)"
  exit 0
fi

echo "$up_secs" > "$STAMP"
note "GPS refclock stale (reach=0 lastrx=${lastrx}s, gpsd up ${gpsd_uptime}s) — restarting gpsd"
systemctl restart gpsd
