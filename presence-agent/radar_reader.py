#!/usr/bin/env python3
"""radar_reader.py — RD-03D 24GHz mmWave radar reader (Rock 5C, /dev/ttyS6).

Protocol (V1, verified live on hardware 2026-08-18):
  frame = AA FF 03 00 [24-byte body] 55 CC   @ 256000 baud, streamed ~11 fps
  body  = up to 3 targets: each x(int16 LE) y(int16 LE) speed(int8), then
          per-target distance bytes + status/reserved bytes.

Usage:
  radar_reader.py --dump        # raw hex frames only
  radar_reader.py --once        # decode one frame, print, exit
  radar_reader.py               # continuous decode
"""
import argparse
import json
import os
import sys
import time

SERIAL_PORT = os.environ.get("RADAR_PORT", "/dev/ttyS6")
BAUD = 256000

V1_HEADER = b"\xaa\xff\x03\x00"
V1_TRAILER = b"\x55\xcc"
MAX_TARGETS = 3
TARGET_BYTES = 5  # x(2) y(2) speed(1)


class RadarReader:
    def __init__(self, port=SERIAL_PORT, baud=BAUD):
        import serial
        self.ser = serial.Serial(port, baud, timeout=0.5)
        self.buf = bytearray()

    @staticmethod
    def _s16(h, l):
        v = (h << 8) | l
        return v - 65536 if v >= 32768 else v

    def _try_frame(self):
        """Extract one frame from self.buf. Returns (frame_dict) or None."""
        i = self.buf.find(V1_HEADER)
        if i < 0:
            if len(self.buf) > 8:
                del self.buf[:-8]
            return None
        if i > 0:
            del self.buf[:i]
        # find trailer within a plausible window (frame is 30 bytes: 4+24+2)
        j = self.buf.find(V1_TRAILER, 6, 96)
        if j < 0:
            if len(self.buf) > 96:
                del self.buf[:1]
            return None
        body = bytes(self.buf[4:j])
        del self.buf[:j + 2]

        targets = []
        for t in range(MAX_TARGETS):
            blk = body[t * TARGET_BYTES:(t + 1) * TARGET_BYTES]
            if len(blk) == TARGET_BYTES and any(blk):
                targets.append({
                    "x": self._s16(blk[0], blk[1]),
                    "y": self._s16(blk[2], blk[3]),
                    "speed": blk[4] - 256 if blk[4] >= 128 else blk[4],
                })
        return {
            "protocol": "v1",
            "body_len": len(body),
            "targets": targets,
            "present": bool(targets),
        }

    def read_frame(self, timeout=10):
        """Block until one frame. Returns dict or None on timeout."""
        import serial
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                chunk = self.ser.read(256)
            except serial.SerialException:
                return None
            if chunk:
                self.buf += chunk
            fr = self._try_frame()
            if fr is not None:
                return fr
        return None

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--port", default=SERIAL_PORT)
    ap.add_argument("--timeout", type=float, default=30)
    args = ap.parse_args()

    r = RadarReader(args.port)
    print("radar_reader: %s @ %d baud — waiting..." % (args.port, BAUD), flush=True)
    t0 = time.time()
    n = 0
    try:
        while True:
            fr = r.read_frame(timeout=5)
            if fr is None:
                if time.time() - t0 > args.timeout:
                    print("TIMEOUT: no data", flush=True)
                    return 2
                continue
            n += 1
            if args.dump:
                print(json.dumps(fr), flush=True)
            else:
                print(json.dumps(fr), flush=True)
            if args.once:
                r.close()
                return 0
    except KeyboardInterrupt:
        r.close()
        print("\nstopped after %d frames" % n, flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main())
