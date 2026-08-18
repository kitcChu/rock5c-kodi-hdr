#!/bin/sh
# cec-watch.sh — heal CEC when the TV powers on after boot (or after any hotplug).
# Boot with TV off -> no EDID -> CEC phys addr f.f.f.f -> libCEC never registers.
# Kick: force a DRM connector re-detect; the driver re-reads EDID and re-syncs
# the CEC notifier. Guard: never do it while VIDEO is playing (video would blink);
# audio-only playback (e.g. music via USB DAC) is safe to kick.
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

# is kodi playing VIDEO? (audio-only is fine: kick only blinks video plane)
PLAYING_VIDEO=$(timeout 4 python3 - << 'PYEOF' 2>/dev/null
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
    print(1 if any(p.get("type") == "video" for p in players) else 0)
except Exception:
    print(1)  # unknown -> be conservative, don't kick
PYEOF
)
if [ "$PLAYING_VIDEO" = "1" ]; then
  log "video playing, deferring kick"
  exit 0
fi

log "kicking DRM re-detect"
echo detect > "$TV"
sleep 3
PA2=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk '{print $4}')
log "after kick: phys addr=$PA2"
[ "$PA2" = "f.f.f.f" ] && log "WARNING: still unregistered" || log "CEC recovered"
