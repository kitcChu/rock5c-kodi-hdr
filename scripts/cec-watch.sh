#!/bin/sh
# cec-watch.sh — heal CEC when the TV powers on after boot (or after any hotplug).
# Boot with TV off -> no EDID -> CEC phys addr f.f.f.f -> libCEC never registers.
# Kick: force a DRM connector re-detect; the driver re-reads EDID and re-syncs
# the CEC notifier.
#
# Guards (each added after a real-world regression):
#  - never kick during ANY kodi playback (audio OR video): the DRM re-detect
#    stutters the audio pipeline (music paused ~1s) and blinks the video plane.
#  - never kick when the TV is in standby/off: a standby TV also reports phys
#    addr f.f.f.f, and re-detecting wakes it via CEC. Only heal when the TV
#    actively answers "on" to a power-status query. No reply -> skip (safe).
LOG=/var/log/cec-watch.log
TV=/sys/class/drm/card0-HDMI-A-1/status
log() { echo "$(date +%Y-%m-%dT%H:%M:%S) $*" >> "$LOG"; }

[ -f "$TV" ] || { log "no $TV, exit"; exit 0; }
[ "$(cat $TV)" = "connected" ] || { log "TV not connected (status=$(cat $TV))"; exit 0; }

# is CEC already healthy?  (field 4 = the address, e.g. 1.0.0.0 vs f.f.f.f)
PA=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk '{print $4}')
[ -n "$PA" ] || PA=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep -oE "[0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f]" | head -1)
log "TV connected, CEC phys addr=$PA"
[ "$PA" = "f.f.f.f" ] || { log "CEC healthy, nothing to do"; exit 0; }

# is kodi playing ANYTHING? (a re-detect stutters audio and blinks video)
PLAYING=$(timeout 4 python3 - << 'PYEOF' 2>/dev/null
import json, socket
s = socket.create_connection(("127.0.0.1", 9090), timeout=3)
s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"Player.GetActivePlayers"}\x00')
buf = b""
s.settimeout(3)
try:
    while True:
        c = s.recv(65536)
        if not c:
            break
        buf += c
        if b"\x00" in buf:
            break
except Exception:
    pass
s.close()
try:
    players = json.loads(buf.split(b"\x00")[0].decode()).get("result", [])
    print(1 if players else 0)
except Exception:
    print(1)  # unknown -> be conservative, don't kick
PYEOF
)
if [ "$PLAYING" = "1" ]; then
  log "playback active, deferring kick"
  exit 0
fi

# only heal when the TV is actively on. A standby TV also presents f.f.f.f,
# and kicking it would wake it (CEC active-source) + stutter audio. No reply
# or any state other than "on" -> do not kick.
TV_POWER=$(timeout 6 cec-ctl -d 0 -t 0 --give-device-power-status 2>/dev/null \
           | grep -oE "pwr-state: (on|standby|to-on|to-standby)" | awk '{print $2}')
log "TV power state=$TV_POWER"
[ "$TV_POWER" = "on" ] || { log "TV not on (state=$TV_POWER), skipping kick"; exit 0; }

log "kicking DRM re-detect"
echo detect > "$TV"
sleep 3
PA2=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk '{print $4}')
log "after kick: phys addr=$PA2"
[ "$PA2" = "f.f.f.f" ] && log "WARNING: still unregistered" || log "CEC recovered"
