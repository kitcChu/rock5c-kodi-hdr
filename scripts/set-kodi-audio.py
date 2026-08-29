#!/usr/bin/env python3
"""Wait for Kodi's JSON-RPC socket and point audio at the Chord Qutest DAC.

Also force all passthrough toggles OFF. The Qutest is a 2-channel PCM DAC:
(1) it cannot decode AC3/DTS/EAC3/TrueHD, and (2) its Class 2 USB interface
is S32-only, which the ALSA iec958 passthrough plugin cannot bridge — a
passthrough attempt makes the sink open fail ("Unable to find a suitable
output format") and freezes playback (movie lag/stall, rkvdec2 reset loops).
Everything must be decoded to PCM and sent via hw:CARD=Qutest."""
import json
import socket
import sys
import time

DEVICE = "ALSA:hw:CARD=Qutest,DEV=0"
PT_DEVICE = "ALSA:iec958:CARD=Qutest,DEV=0"  # kept but never used (passthrough off)
# Qutest can't decode compressed formats; passthrough must never engage
NO_PASSTHROUGH = [
    "audiooutput.ac3passthrough",
    "audiooutput.eac3passthrough",
    "audiooutput.dtspassthrough",
    "audiooutput.truehdpassthrough",
    "audiooutput.dtshdpassthrough",
]


def rpc(s, method, params=None, mid=1):
    msg = {"jsonrpc": "2.0", "method": method, "id": mid}
    if params:
        msg["params"] = params
    s.sendall((json.dumps(msg) + "\n").encode())
    s.settimeout(3)
    data = b""
    try:
        while b"\n" not in data:
            c = s.recv(4096)
            if not c:
                break
            data += c
    except Exception:
        pass
    try:
        return json.loads(data.decode().split("\n")[0]).get("result")
    except Exception:
        return None


def main():
    for _ in range(120):  # wait up to ~4 min for kodi
        try:
            s = socket.create_connection(("127.0.0.1", 9090), timeout=2)
        except OSError:
            time.sleep(2)
            continue
        try:
            rpc(s, "Settings.SetSettingValue", {"setting": "audiooutput.audiodevice", "value": DEVICE}, 1)
            rpc(s, "Settings.SetSettingValue", {"setting": "audiooutput.passthroughdevice", "value": PT_DEVICE}, 2)
            for i, sid in enumerate(NO_PASSTHROUGH, start=3):
                rpc(s, "Settings.SetSettingValue", {"setting": sid, "value": False}, i)
            r = rpc(s, "Settings.GetSettingValue", {"setting": "audiooutput.audiodevice"}, 99)
            print("audiodevice now:", r)
            sys.exit(0)
        finally:
            s.close()
    print("kodi JSON-RPC never became available", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
