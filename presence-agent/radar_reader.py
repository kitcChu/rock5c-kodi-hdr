#!/usr/bin/env python3
"""radar_reader.py — HKL-LD2450 24GHz presence radar reader (Rock 5C, /dev/ttyS4).

The module sits on UART4-M2 (pins 7/29, GPIO1_B3/B2) via the
rk3588-uart4-m2.dtbo overlay.

Protocol (reverse-engineered, see docs/JOURNAL.md sections 29-30):

    16-byte frames @256000 baud, ~10 Hz, XOR-checksummed:

      AA 10 B0 [P] [D] 00 00 20 00 4E 00 32 00 00 [X] 55
      |  |  |   |   |                                |  |
      |  |  |   |   +-- D = distance: 0xFF = none, else range value
      |  |  |   +------ P = presence: 0x00 none, 0x01 target present
      |  |  +---------- B0 constant (type/version)
      |  +------------- 0x10 = frame length (16)
      +---------------- header
                X = XOR of bytes 1..13,  0x55 = trailer

The module has no command interface — it is a dumb streaming presence
sensor. Bytes 5..13 are constants (00 00 20 00 4E 00 32 00 00) while
tracking, zeros while idle.
"""
import argparse
import os
import sys
import time

SERIAL_PORT = os.environ.get("RADAR_PORT", "/dev/ttyS4")
BAUD = int(os.environ.get("RADAR_BAUD", "256000"))

FRAME_LEN = 16
HEADER = 0xAA
TRAILER = 0x55
NO_DISTANCE = 0xFF


class RadarReader:
    def __init__(self, port=SERIAL_PORT, baud=BAUD):
        import serial
        self.ser = serial.Serial(port, baud, timeout=0.5)
        self.buf = bytearray()

    @staticmethod
    def _checksum_ok(fr):
        """XOR of bytes 1..13 must equal byte 14."""
        x = 0
        for b in fr[1:14]:
            x ^= b
        return x == fr[14]

    def _try_frame(self):
        """Extract one valid frame from self.buf. Returns dict or None."""
        i = self.buf.find(bytes([HEADER]))
        if i < 0:
            if len(self.buf) > FRAME_LEN:
                del self.buf[:-FRAME_LEN]
            return None
        if i > 0:
            del self.buf[:i]
        if len(self.buf) < FRAME_LEN:
            return None

        fr = bytes(self.buf[:FRAME_LEN])
        if fr[FRAME_LEN - 1] != TRAILER or not self._checksum_ok(fr):
            del self.buf[:1]          # resync one byte forward
            return None

        del self.buf[:FRAME_LEN]
        dist = fr[4]
        return {
            "protocol": "hkl-ld2450",
            "present": fr[3] != 0x00,
            "distance": None if dist == NO_DISTANCE else dist,
            "raw": fr,
        }

    def read_frame(self, timeout=5):
        """Block until one valid frame. Returns dict or None on timeout."""
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
            if fr:
                return fr
        return None

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description="HKL-LD2450 radar reader")
    ap.add_argument("--port", default=SERIAL_PORT)
    ap.add_argument("--dump", action="store_true", help="raw hex of every frame")
    ap.add_argument("--once", action="store_true", help="exit after one frame")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()

    r = RadarReader(port=args.port)
    print(f"listening on {args.port} @{BAUD}", flush=True)
    try:
        while True:
            fr = r.read_frame(timeout=args.timeout)
            if fr is None:
                if args.once:
                    return 1
                continue
            if args.dump:
                print(fr["raw"].hex(" "), flush=True)
            else:
                print("present=%s distance=%s" % (fr["present"], fr["distance"]), flush=True)
            if args.once:
                return 0
    except KeyboardInterrupt:
        return 0
    finally:
        r.close()


if __name__ == "__main__":
    sys.exit(main())
