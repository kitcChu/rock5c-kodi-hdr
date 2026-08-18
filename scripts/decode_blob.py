#!/usr/bin/env python3
"""Decode the kernel HDR_OUTPUT_METADATA blob correctly."""
import subprocess, re, struct, sys

out = subprocess.run(["modetest", "-M", "rockchip", "-c"], capture_output=True, text=True, timeout=20).stdout
m = re.search(r"HDR_OUTPUT_METADATA:.*?value:\s*((?:[0-9a-f]{32,}\s*)+)", out, re.S)
if not m:
    print("no blob found"); sys.exit(1)
hexs = "".join(m.group(1).split())
b = bytes.fromhex(hexs)
print("raw:", hexs)
if len(b) < 30:
    print("blob too short:", len(b)); sys.exit(1)

# struct hdr_output_metadata { int metadata_type; struct hdr_metadata_infoframe {...}; } packed
# infoframe: u8 eotf, u8 metadata_type, u16[3][2] primaries, u16[2] white_point,
#            u16 max_lum, u16 min_lum, u16 max_cll, u16 max_fall
off = 0
md_type = struct.unpack_from("<i", b, off)[0]; off += 4
eotf = b[off]; mtype = b[off+1]; off += 2
prim = struct.unpack_from("<6H", b, off); off += 12
wp = struct.unpack_from("<2H", b, off); off += 4
max_lum, min_lum, max_cll, max_fall = struct.unpack_from("<4H", b, off)

eotfs = {0: "SDR", 2: "ST2084/HDR10", 3: "HLG"}
print(f"metadata_type={md_type} eotf={eotf} ({eotfs.get(eotf,'?')})")
names = ["r", "g", "b"]
for i in range(3):
    x, y = prim[i*2], prim[i*2+1]
    print(f"  {names[i]}: ({x/50000:.4f}, {y/50000:.4f})" + ("  <- BT.2020 ✓" if 0 < x < 50000 else "  <- ZERO ✗"))
print(f"  white: ({wp[0]/50000:.4f}, {wp[1]/50000:.4f})")
print(f"  max_luminance: {max_lum} nits" + (" ✓" if max_lum > 100 else " ✗"))
print(f"  min_luminance: {min_lum/10000:.4f} nits")
print(f"  max_cll: {max_cll}, max_fall: {max_fall}")
