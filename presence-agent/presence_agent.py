#!/usr/bin/env python3
"""presence_agent.py — RD-03D radar → room presence → Kodi (Rock 5C home theater).

Pipeline (2GB RAM budget — radar gates camera AND mic):
  radar (/dev/ttyS4) ──▶ presence state (debounced) ──▶ policy engine
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
DEBOUNCE_EMPTY = float(os.environ.get("DEBOUNCE_EMPTY", "5.0"))    # sec of empty → act
DEBOUNCE_PRESENT = float(os.environ.get("DEBOUNCE_PRESENT", "1.5"))  # sec of person → act
POLL = float(os.environ.get("RADAR_POLL", "0.5"))
# Hold model: a SINGLE detection marks us present and keeps us present for
# PRESENCE_HOLD seconds. The HKL-LD2450's returns are sparse at range
# (e.g. 3/30 frames at 1.5 m), so requiring continuous presence would mean
# it could pause but never resume. Pause only after DEBOUNCE_EMPTY of true
# silence (no frame at all).
PRESENCE_HOLD = float(os.environ.get("PRESENCE_HOLD", "4.0"))
# RADAR_DEBUG=1: log every present frame + a 20 s frame-count heartbeat
DEBUG = os.environ.get("RADAR_DEBUG", "") == "1"

# Persist "we paused it" across agent restarts, so a restart (deploy, crash)
# doesn't strand playback paused forever. /run is tmpfs: a reboot resets it.
STATE_FILE = os.environ.get("PRESENCE_STATE", "/run/presence-agent.paused")


def load_paused_flag():
    try:
        with open(STATE_FILE) as f:
            return f.read().strip() == "1"
    except Exception:
        return False


def save_paused_flag(value):
    try:
        with open(STATE_FILE, "w") as f:
            f.write("1" if value else "0")
    except Exception:
        pass
# Distance gate: presence only counts within this many units of the raw
# distance byte (0 = no gate). Calibrated on the Rock 5C install: the raw
# byte reads ~cm (couch seated ≈ 144-191, i.e. ~1.5-1.9 m).
MAX_DISTANCE = float(os.environ.get("MAX_DISTANCE", "300"))
# Which player types the agent may pause/resume.
# "video" = movies only (music keeps playing when you leave)
# "video,audio" = pause whatever is playing (default: user's requirement)
PAUSE_TYPES = {t.strip() for t in os.environ.get("PAUSE_TYPES", "video,audio").split(",") if t.strip()}

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
                # return as soon as the JSON is complete: kodi's TCP json-rpc
                # does not guarantee a trailing NUL/newline, and waiting for
                # one cost a full 3 s socket timeout per call
                try:
                    json.loads(buf.decode())
                    break
                except Exception:
                    continue
        except socket.timeout:
            pass
        s.close()
        # kodi's TCP json-rpc is newline/NUL delimited; be tolerant of
        # concatenated responses (avoids "Extra data" parse errors)
        for part in buf.replace(b"\x00", b"\n").split(b"\n"):
            part = part.strip()
            if not part:
                continue
            try:
                return json.loads(part.decode()).get("result")
            except Exception:
                continue
        return None
    except Exception as e:
        print(f"{ts()} json-rpc error: {e}", flush=True)
        return None


def ts():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def active_player():
    """playerid of the first active player we are allowed to gate."""
    players = kodi_rpc("Player.GetActivePlayers")
    if not isinstance(players, list):
        return None
    for p in players:
        if p.get("type") in PAUSE_TYPES:
            return p.get("playerid")
    return None


def playing_target():
    return active_player() is not None


def frame_present(fr):
    """Presence from a radar frame, gated to MAX_DISTANCE.

    HKL-LD2450: fr['present'] is the target flag, fr['distance'] the range
    byte (None when no target). A target beyond MAX_DISTANCE does not count
    as presence (radar range is a few metres; avoids false PRESENT).
    """
    if not fr.get("present"):
        return False
    d = fr.get("distance")
    if MAX_DISTANCE > 0 and d is not None and d > MAX_DISTANCE:
        return False
    return True


def is_paused():
    pid = active_player()
    if pid is None:
        return False
    st = kodi_rpc("Player.GetProperties", {"playerid": pid, "properties": ["speed"]})
    return st is not None and st.get("speed") == 0


def pause():
    pid = active_player()
    if pid is None or is_paused():
        return
    kodi_rpc("Player.PlayPause", {"playerid": pid, "play": False})
    print(f"{ts()} POLICY: paused player {pid} (room empty)", flush=True)


def resume():
    pid = active_player()
    if pid is None or not is_paused():
        return
    kodi_rpc("Player.PlayPause", {"playerid": pid, "play": True})
    print(f"{ts()} POLICY: resumed player {pid} (person returned)", flush=True)


# ---------- main ----------
def main():
    print(f"{ts()} presence-agent starting (hold={PRESENCE_HOLD}s empty={DEBOUNCE_EMPTY}s types={sorted(PAUSE_TYPES)})", flush=True)
    radar = RadarReader()

    # state
    state = "unknown"            # 'empty' | 'present'
    # start out "empty" (sane silence value) but a single detection flips it
    last_seen = time.time() - DEBOUNCE_EMPTY - 1
    paused_by_us = load_paused_flag()
    nframes = 0
    npresent = 0
    last_dbg = 0.0
    last_enforce = 0.0

    try:
        while True:
            fr = radar.read_frame()
            if fr is None:
                time.sleep(POLL)
                continue

            present = frame_present(fr)
            count = 1 if present else 0
            dist = fr.get("distance")

            now = time.time()
            nframes += 1
            if present:
                npresent += 1
            if present:
                last_seen = now
            silence = now - last_seen

            if DEBUG:
                if present:
                    print(f"{ts()} DEBUG present frame dist={dist}", flush=True)
                if now - last_dbg >= 20:
                    last_dbg = now
                    print(f"{ts()} DEBUG frames={nframes} present_frames={npresent} silence={silence:.1f}s", flush=True)

            if silence <= PRESENCE_HOLD:
                # someone is (or was just) there -> present
                if state != "present":
                    state = "present"
                    print(f"{ts()} PRESENT dist={dist} (silence {silence:.1f}s)", flush=True)
                    if paused_by_us:
                        resume()
                        paused_by_us = False
                        save_paused_flag(False)
            elif silence >= DEBOUNCE_EMPTY:
                # nobody for DEBOUNCE_EMPTY seconds -> empty
                if state != "empty":
                    state = "empty"
                    print(f"{ts()} EMPTY (no presence for {silence:.1f}s)", flush=True)
                # enforce pause (throttled: kodi RPCs must never starve the
                # radar read loop)
                if now - last_enforce >= 1.0:
                    last_enforce = now
                    if playing_target() and not is_paused():
                        pause()
                        paused_by_us = True
                        save_paused_flag(True)

            # NOTE: no sleep here. The radar paces the loop at ~10 Hz; an
            # unconditional sleep made the agent process only 2 frames/s and
            # work through a ~25 s backlog of stale frames.
    except KeyboardInterrupt:
        radar.close()
        print(f"{ts()} presence-agent stopped", flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main())
