#!/bin/sh
# cec-resync.sh — ONE-SHOT CEC re-sync. Run manually when the TV remote/CEC
# stops working (typically after the board booted with the TV off, so CEC
# never registered: phys addr f.f.f.f).
#
# Safety (learned the hard way): a DRM connector re-detect wakes a standby
# TV via CEC and briefly stutters audio. So by default we only kick when the
# TV actively answers "on" to a power query (or the query is inconclusive,
# e.g. CEC fully dead). If the TV reports "standby", we refuse unless you
# pass --force.
#
# Usage:  sudo cec-resync.sh [--force]
#   --force   kick even if the TV reports standby
LOG=/var/log/cec-resync.log
TV=/sys/class/drm/card0-HDMI-A-1/status
FORCE=0
[ "$1" = "--force" ] && FORCE=1

log() { echo "$(date +%Y-%m-%dT%H:%M:%S) $*" | tee -a "$LOG"; }

[ "$(id -u)" = "0" ] || { echo "run as root: sudo cec-resync.sh" >&2; exit 1; }
[ -f "$TV" ] || { log "ERROR: no connector status file at $TV"; exit 1; }
[ "$(cat "$TV")" = "connected" ] || { log "TV not connected (status=$(cat "$TV")), nothing to re-sync"; exit 1; }

PA=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk '{print $4}')
[ -n "$PA" ] || PA=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep -oE "[0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f]" | head -1)
log "CEC phys addr = $PA"
[ "$PA" = "f.f.f.f" ] || { log "CEC already healthy — nothing to do"; exit 0; }

TV_POWER=$(timeout 6 cec-ctl -d 0 -t 0 --give-device-power-status 2>/dev/null \
           | grep -oE "pwr-state: (on|standby|to-on|to-standby)" | awk '{print $2}')
log "TV power state = ${TV_POWER:-unknown}"

case "$TV_POWER" in
  standby|to-standby)
    if [ "$FORCE" = "0" ]; then
      log "TV is in standby — refusing to kick (it would wake the TV). Use --force to override."
      exit 0
    fi
    log "forced kick despite standby"
    ;;
esac

log "re-syncing: DRM connector re-detect"
echo detect > "$TV"
sleep 3
PA2=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk '{print $4}')
log "after re-detect: phys addr = $PA2"
if [ "$PA2" = "f.f.f.f" ]; then
  log "still unregistered — try: sudo systemctl restart kodi"
  exit 1
fi
log "CEC re-synced OK"
exit 0
