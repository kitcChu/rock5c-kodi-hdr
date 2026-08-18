#!/usr/bin/env python3
"""Wait for Kodi's JSON-RPC socket and point audio at the Chord Qutest DAC."""
import json
import socket
import sys
import time

DEVICE = "ALSA:hw:CARD=Qutest,DEV=0"
PT_DEVICE = "ALSA:iec958:CARD=Qutest,DEV=0"


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
            r = rpc(s, "Settings.GetSettingValue", {"setting": "audiooutput.audiodevice"}, 3)
            print("audiodevice now:", r)
            sys.exit(0)
        finally:
            s.close()
    print("kodi JSON-RPC never became available", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
