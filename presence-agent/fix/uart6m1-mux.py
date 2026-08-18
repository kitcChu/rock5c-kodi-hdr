#!/usr/bin/env python3
"""uart6m1-mux.py — assert UART6-M1 mux on Rock 5C (GPIO1_A0/A1 -> func 10).

Why: the kernel's pinctrl driver does NOT reliably program the UART6-M1
IOMUX on this board/image (the serial node probes with pinctrl-0 set, but
the hardware register is left at GPIO function). Without the mux, /dev/ttyS6
exists but its TX/RX never reach header pins 19/21.

RK3588 IOC registers use a write pattern: upper 16 bits = mask, lower 16
bits = value. Plain writes are silently ignored.

Run at boot (systemd) and after any event that re-programs the IOC.
"""
import mmap
import os
import struct
import sys
import time

IOC_BASE = 0xFD5F0000
GPIO1_IOMUX_A0A3 = 0x8020          # BUS_IOC: GPIO1 group A0-A3
EXPECTED = 0xAA                    # A0=10 (UART6_TX), A1=10 (UART6_RX)

def read_mem(addr):
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    page = addr & ~4095
    off = addr - page
    m = mmap.mmap(fd, off + 4, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    v = struct.unpack("<I", m[off:off + 4])[0]
    m.close()
    os.close(fd)
    return v

def write_mem(addr, value):
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    page = addr & ~4095
    off = addr - page
    m = mmap.mmap(fd, off + 4, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
    struct.pack_into("<I", m, off, value)
    try:
        m.flush()
    except OSError:
        pass
    m.close()
    os.close(fd)

def main():
    for attempt in range(30):
        try:
            v = read_mem(IOC_BASE + GPIO1_IOMUX_A0A3)
            if (v & 0xFF) == EXPECTED:
                print("uart6m1-mux: already OK (0x%08x)" % v, flush=True)
                return 0
            # write pattern: mask (0xFF) in upper 16, value in lower 16
            write_mem(IOC_BASE + GPIO1_IOMUX_A0A3, (0xFF << 16) | EXPECTED)
            v = read_mem(IOC_BASE + GPIO1_IOMUX_A0A3)
            if (v & 0xFF) == EXPECTED:
                print("uart6m1-mux: set OK (0x%08x)" % v, flush=True)
                return 0
            print("uart6m1-mux: write did not stick (0x%08x), retry %d" % (v, attempt + 1), flush=True)
        except OSError as e:
            print("uart6m1-mux: error %s, retry %d" % (e, attempt + 1), flush=True)
        time.sleep(1)
    print("uart6m1-mux: FAILED after 30 attempts", flush=True)
    return 1

if __name__ == "__main__":
    sys.exit(main())
