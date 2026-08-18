#!/usr/bin/env python3
"""presence_agent.py — RD-03D radar → room presence → Kodi (Rock 5C home theater).

Pipeline (2GB RAM budget — radar gates camera AND mic):
  radar (/dev/ttyS6) ──▶ presence state (debounced) ──▶ policy engine
                                                          │
        Kodi JSON-RPC (127.0.0.1:9090, localhost only) ◀──┘  (pause/resume only)
        camera C922 (face ID, NPU) — gated by presence        (milestone 6)
        voice C922 mic (EN + Cantonese) — gated by presence   (milestone 7)

Hard rules:
  * Never act on a flaky reading — transitions require debounce seconds.
  * Pause/resume only; never stop/seek/quit Kodi playback.
  * All state printed to stdout (journald captures it).
"""
import json
import os
import socket
import sys
import time
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from radar_reader import RadarReader  # noqa: E402

KODI_HOST = os.environ.get("KODI_HOST", "127.0.0.1")
KODI_PORT = int(os.environ.get("KODI_PORT", "9090"))
DEBOUNCE_EMPTY = float(os.environ.get("DEBOUNCE_EMPTY", "3.0"))    # sec of empty → act
DEBOUNCE_PRESENT = float(os.environ.get("DEBOUNCE_PRESENT", "1.5"))  # sec of person → act
POLL = float(os.environ.get("RADAR_POLL", "0.5"))

# ---------- kodi json-rpc (same pattern as existing scripts) ----------
def kodi_rpc(method, params=None):
    msg = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params:
        msg["params"] = params
    try:
        s = socket.create_connection((KODI_HOST, KODI_PORT), timeout=3)
        s.sendall(json.dumps(msg).encode() + b"\x00")
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
        except socket.timeout:
            pass
        s.close()
        return json.loads(buf.split(b"\x00")[0].decode()).get("result")
    except Exception as e:
        print(f"{ts()} json-rpc error: {e}", flush=True)
        return None


def ts():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def playing_video():
    players = kodi_rpc("Player.GetActivePlayers")
    if not isinstance(players, list):
        return False
    return any(p.get("type") == "video" for p in players)


def is_paused():
    players = kodi_rpc("Player.GetActivePlayers")
    if not isinstance(players, list) or not players:
        return False
    pid = players[0].get("playerid")
    st = kodi_rpc("Player.GetProperties", {"playerid": pid, "properties": ["speed"]})
    return st is not None and st.get("speed") == 0


def pause():
    players = kodi_rpc("Player.GetActivePlayers")
    if not isinstance(players, list) or not players:
        return
    pid = players[0].get("playerid")
    if not is_paused():
        kodi_rpc("Player.PlayPause", {"playerid": pid, "play": False})
        print(f"{ts()} POLICY: paused player {pid} (room empty)", flush=True)


def resume():
    players = kodi_rpc("Player.GetActivePlayers")
    if not isinstance(players, list) or not players:
        return
    pid = players[0].get("playerid")
    if is_paused():
        kodi_rpc("Player.PlayPause", {"playerid": pid, "play": True})
        print(f"{ts()} POLICY: resumed player {pid} (person returned)", flush=True)


# ---------- main ----------
def main():
    print(f"{ts()} presence-agent starting (debounce empty={DEBOUNCE_EMPTY}s present={DEBOUNCE_PRESENT}s)", flush=True)
    radar = RadarReader()

    # state
    state = "unknown"            # 'empty' | 'present'
    since = time.time()
    last_announce = 0
    paused_by_us = False

    try:
        while True:
            fr = radar.read_frame()
            if fr is None:
                time.sleep(POLL)
                continue

            if fr["protocol"] == "v1":
                present = bool(fr["targets"]) and any(t["speed"] != 0 for t in fr["targets"])
                count = len(fr["targets"])
            else:
                raw = fr.get("raw", {})
                xs = raw.get("X") or raw.get("x") or []
                present = bool(xs)
                count = len(xs) if isinstance(xs, list) else (1 if xs else 0)

            now = time.time()
            if present:
                if state != "present":
                    since = now
                    state = "present"
                elif now - since >= DEBOUNCE_PRESENT and now - last_announce > 5:
                    last_announce = now
                    print(f"{ts()} PRESENT count={count} (protocol {fr['protocol']})", flush=True)
                    if paused_by_us:
                        resume()
                        paused_by_us = False
            else:
                if state != "empty":
                    since = now
                    state = "empty"
                elif now - since >= DEBOUNCE_EMPTY and now - last_announce > 5:
                    last_announce = now
                    print(f"{ts()} EMPTY (was {state})", flush=True)
                    if playing_video() and not is_paused():
                        pause()
                        paused_by_us = True

            time.sleep(POLL)
    except KeyboardInterrupt:
        radar.close()
        print(f"{ts()} presence-agent stopped", flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main())
