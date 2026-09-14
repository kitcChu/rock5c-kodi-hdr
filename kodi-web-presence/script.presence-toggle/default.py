"""Toggle presence-agent.service from the Kodi web UI.

Off by default. When turning the agent OFF we also release playback if the
agent had paused it, so disabling the feature can never strand audio paused.
"""
import json
import subprocess

import xbmc

SERVICE = "presence-agent"
FLAG = "/run/presence-agent.paused"


def run(*args):
    try:
        return subprocess.run(["sudo", "-n", *args], capture_output=True,
                              text=True, timeout=20)
    except Exception:
        return None


def is_active():
    r = run("systemctl", "is-active", SERVICE)
    return bool(r) and r.stdout.strip() == "active"


def notify(message):
    try:
        xbmc.executebuiltin("Notification(Presence agent, %s, 4000)" % message)
    except Exception:
        pass


def release_paused_playback():
    """Resume playback we paused earlier (from the persisted flag)."""
    try:
        with open(FLAG) as f:
            if f.read().strip() != "1":
                return
    except Exception:
        return
    try:
        res = xbmc.executeJSONRPC(json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "Player.GetActivePlayers"}))
        players = json.loads(res).get("result", [])
    except Exception:
        players = []
    for p in players:
        try:
            xbmc.executeJSONRPC(json.dumps(
                {"jsonrpc": "2.0", "id": 2, "method": "Player.PlayPause",
                 "params": {"playerid": p["playerid"], "play": True}}))
        except Exception:
            pass
    try:
        with open(FLAG, "w") as f:
            f.write("0")
    except Exception:
        pass


if is_active():
    run("systemctl", "stop", SERVICE)
    release_paused_playback()
    notify("OFF - playback will not be paused")
else:
    run("systemctl", "start", SERVICE)
    notify("ON - pauses playback when the room is empty")
