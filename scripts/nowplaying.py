#!/usr/bin/env python3
import socket, json, time

def rpc(method, params, mid):
    s = socket.create_connection(("127.0.0.1", 9090), timeout=4)
    s.sendall((json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": mid}) + "\n").encode())
    time.sleep(1.2)
    d = b""
    s.settimeout(3)
    try:
        while b"\n" not in d:
            d += s.recv(8000)
    except Exception:
        pass
    s.close()
    return json.loads(d.decode().split("\n")[0]).get("result")

try:
    item = rpc("Player.GetItem", {"playerid": 1, "properties": ["title"]}, 1)["item"]
    print("title:", item.get("title", "")[:70])
    p = rpc("Player.GetProperties", {"playerid": 1, "properties": ["time", "totaltime", "percentage", "speed"]}, 2)
    t, tt = p["time"], p["totaltime"]
    cur = t["hours"]*3600 + t["minutes"]*60 + t["seconds"]
    tot = tt["hours"]*3600 + tt["minutes"]*60 + tt["seconds"]
    print("position: %dm%02ds / %dh%02dm  remaining: %d min (%.0f%%) speed %s" %
          (t["minutes"], t["seconds"], tt["hours"], tt["minutes"], (tot-cur)//60, p["percentage"], p["speed"]))
except Exception as e:
    print("player idle or error:", e)
