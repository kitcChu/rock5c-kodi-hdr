#!/bin/sh
# cec-resync.sh — manually re-sync CEC after the TV powered on late (or hotplug).
# The old automated watchdog is removed (user request); run this by hand:
#   sudo cec-resync          (safe: refuses while video is playing)
#   sudo cec-resync --force  (kick anyway)
LOG=/var/log/cec-watch.log
TV=/sys/class/drm/card0-HDMI-A-1/status
log() { echo "$(date +%Y-%m-%dT%H:%M:%S) MANUAL $*" >> "$LOG"; }

FORCE=0
[ "$1" = "--force" ] && FORCE=1

[ -f "$TV" ] || { echo "no $TV"; exit 1; }
[ "$(cat $TV)" = "connected" ] || { echo "TV not connected (status=$(cat $TV))"; exit 1; }

PA=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk "{print \$4}")
[ -n "$PA" ] || PA=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep -oE "[0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f]" | head -1)
echo "CEC physical address: $PA (healthy=1.0.0.0, broken=f.f.f.f)"
[ "$PA" = "f.f.f.f" ] || { echo "CEC already healthy — nothing to do."; exit 0; }

if [ "$FORCE" = "0" ]; then
  PLAYING=$(timeout 4 python3 - << "PYEOF" 2>/dev/null
import json, socket
s = socket.create_connection(("127.0.0.1", 9090), timeout=3)
s.sendall(bmethod:Player.GetActivePlayersx00)
buf = b""
s.settimeout(3)
try:
    while True:
        c = s.recv(65536)
        if not c: break
        buf += c
        if b"\x00" in buf: break
except Exception:
    pass
s.close()
try:
    players = json.loads(buf.split(b"\x00")[0].decode()).get("result", [])
    print(1 if any(p.get("type") == "video" for p in players) else 0)
except Exception:
    print(1)
PYEOF
)
  if [ "$PLAYING" = "1" ]; then
    echo "Video is playing — refusing to kick (would blink the screen). Use --force to override."
    exit 1
  fi
fi

echo "kicking DRM re-detect..."
log "kicking DRM re-detect"
echo detect > "$TV"
sleep 3
PA2=$(cec-ctl -d 0 --logical-addresses 2>/dev/null | grep "Physical Address" | awk "{print \$4}")
echo "after kick: $PA2"
[ "$PA2" = "f.f.f.f" ] && echo "WARNING: still unregistered" || echo "CEC recovered ✓"
exit 0
