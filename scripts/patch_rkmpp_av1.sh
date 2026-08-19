#!/usr/bin/env bash
# patch_rkmpp_av1.sh — register av1_rkmpp hardware decoder in the ffmpeg tree.
#
# The Rock 5C's kernel (6.1.84 rkvdec2/vdpu) and MPP 1.5.0 library fully
# support AV1 hardware decoding (verified live with an MPP probe: 256x144
# SVT-AV1 elementary stream decoded to NV12 on 2026-08-19). Debian's ffmpeg
# 5.1.9 + our rkmpp patch set only registers h264/hevc/vp8/vp9 wrappers —
# this script adds the fifth. IDEMPOTENT: every hunk checks before inserting.
#
# Usage:  ./patch_rkmpp_av1.sh /path/to/ffmpeg-5.1.9
# After patching, rebuild libavcodec59/libavcodec-extra59 (arm64).
#
# Notes:
#  - AV1 in MKV carries its sequence header in-band; MPP split-mode parser
#    handles raw OBU streams, so no bitstream filter is needed (bsf = NULL),
#    matching nyanmisaka/ffmpeg-rockchip's registration.
#  - HDR10 mastering-metadata export for AV1 (mpp_frame_get_mastering_display)
#    is a planned second-stage patch; without it AV1 plays SDR today.
#  - python3 is used for edits: portable across GNU/BSD sed differences.
set -euo pipefail
DIR="${1:?usage: patch_rkmpp_av1.sh /path/to/ffmpeg-tree}"
python3 - "$DIR" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])

def patch(rel, marker, anchor, insert):
    """Insert `insert` after `anchor` line in file `rel`; skip if `marker` present."""
    f = root / rel
    t = f.read_text()
    if marker in t:
        print(f"  {rel}: already patched")
        return
    if anchor not in t:
        sys.exit(f"FAIL: anchor not found in {rel}: {anchor[:60]}...")
    f.write_text(t.replace(anchor, anchor + "\n" + insert, 1))
    print(f"  {rel}: patched")

patch("libavcodec/rkmppdec.c",
      "AV_CODEC_ID_AV1:            return MPP_VIDEO_CodingAV1",
      "    case AV_CODEC_ID_VP9:           return MPP_VIDEO_CodingVP9;",
      "    case AV_CODEC_ID_AV1:            return MPP_VIDEO_CodingAV1;")

patch("libavcodec/rkmppdec.c",
      "RKMPP_DEC(av1,",
      "RKMPP_DEC(vp9,   AV_CODEC_ID_VP9,           NULL)",
      "RKMPP_DEC(av1,   AV_CODEC_ID_AV1,           NULL)")

patch("configure",
      'av1_rkmpp_decoder_deps="rkmpp"',
      'vp9_rkmpp_decoder_deps="rkmpp"',
      'av1_rkmpp_decoder_deps="rkmpp"')

patch("libavcodec/Makefile",
      "CONFIG_AV1_RKMPP_DECODER",
      "OBJS-$(CONFIG_VP9_RKMPP_DECODER)       += rkmppdec.o",
      "OBJS-$(CONFIG_AV1_RKMPP_DECODER)      += rkmppdec.o")

patch("libavcodec/allcodecs.c",
      "ff_av1_rkmpp_decoder",
      "extern const FFCodec ff_vp9_rkmpp_decoder;",
      "extern const FFCodec ff_av1_rkmpp_decoder;")

# verify
checks = [
    ("libavcodec/rkmppdec.c", "AV_CODEC_ID_AV1", 2),
    ("configure", "av1_rkmpp_decoder_deps", 1),
    ("libavcodec/Makefile", "AV1_RKMPP_DECODER", 1),
    ("libavcodec/allcodecs.c", "ff_av1_rkmpp_decoder", 1),
]
for rel, s, n in checks:
    c = (root / rel).read_text().count(s)
    status = "OK" if c == n else "MISMATCH"
    print(f"  verify {rel}: {s!r} x{c} (expect {n}) {status}")
    if c != n:
        sys.exit(1)
print("ALL HUNKS VERIFIED")
PYEOF
