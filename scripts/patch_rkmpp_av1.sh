#!/usr/bin/env bash
# patch_rkmpp_av1.sh — register av1_rkmpp hardware decoder in the ffmpeg tree
# and fix AV1-in-MKV playback (av1C extradata strip).
#
# The Rock 5C's kernel (6.1.84 rkvdec2/vdpu) and MPP 1.5.0 library fully
# support AV1 hardware decoding, 8- AND 10-bit, 4K included (verified live
# with MPP probes incl. a real 4K 10-bit SVT-AV1-PSYEX movie stream).
# Debian's ffmpeg 5.1.9 + our rkmpp patch set only registers
# h264/hevc/vp8/vp9 wrappers — this script adds the fifth and fixes the
# extradata path. IDEMPOTENT: every hunk checks before inserting.
#
# Usage:  ./patch_rkmpp_av1.sh /path/to/ffmpeg-5.1.9
# After patching, rebuild libavcodec59/libavcodec-extra59 (arm64).
#
# Notes:
#  - av1C strip: MKV/MP4 carry an AV1CodecConfigurationRecord in extradata;
#    matroska does NOT repeat the sequence header in-band, so MPP's OBU
#    parser never syncs without it (kodi symptom: infinite buffering
#    spinner, decoder opens but emits no frames).
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

def replace(rel, marker, anchor, new):
    """Replace exact `anchor` text with `new`; skip if `marker` present."""
    f = root / rel
    t = f.read_text()
    if marker in t:
        print(f"  {rel}: already patched")
        return
    if anchor not in t:
        sys.exit(f"FAIL: anchor not found in {rel}: {anchor[:60]}...")
    f.write_text(t.replace(anchor, new, 1))
    print(f"  {rel}: patched (replace)")

# --- 1. codec-id -> MPP coding map (rkmppdec.c) ---
patch("libavcodec/rkmppdec.c",
      "AV_CODEC_ID_AV1:            return MPP_VIDEO_CodingAV1",
      "    case AV_CODEC_ID_VP9:           return MPP_VIDEO_CodingVP9;",
      "    case AV_CODEC_ID_AV1:            return MPP_VIDEO_CodingAV1;")

# --- 2. decoder registration (rkmppdec.c tail) ---
patch("libavcodec/rkmppdec.c",
      "RKMPP_DEC(av1,",
      "RKMPP_DEC(vp9,   AV_CODEC_ID_VP9,           NULL)",
      "RKMPP_DEC(av1,   AV_CODEC_ID_AV1,           NULL)")

# --- 3. configure: decoder deps ---
patch("configure",
      'av1_rkmpp_decoder_deps="rkmpp"',
      'vp9_rkmpp_decoder_deps="rkmpp"',
      'av1_rkmpp_decoder_deps="rkmpp"')

# --- 4. libavcodec/Makefile: object rule ---
patch("libavcodec/Makefile",
      "CONFIG_AV1_RKMPP_DECODER",
      "OBJS-$(CONFIG_VP9_RKMPP_DECODER)       += rkmppdec.o",
      "OBJS-$(CONFIG_AV1_RKMPP_DECODER)      += rkmppdec.o")

# --- 5. libavcodec/allcodecs.c: extern decl ---
patch("libavcodec/allcodecs.c",
      "ff_av1_rkmpp_decoder",
      "extern const FFCodec ff_vp9_rkmpp_decoder;",
      "extern const FFCodec ff_av1_rkmpp_decoder;")

# --- 6. av1C extradata strip (rkmppdec.c, first-packet path) ---
replace("libavcodec/rkmppdec.c",
        "AV1CodecConfigurationRecord",
        '''    // on first packet, send extradata
    if (decoder->first_packet) {
        if (avctx->extradata_size) {
            ret = rkmpp_write_data(avctx, avctx->extradata,
                                            avctx->extradata_size,
                                            avpkt->pts);
            if (ret) {
                av_log(avctx, AV_LOG_ERROR, "Failed to write extradata to decoder (code = %d)\\n", ret);
                return ret;
            }
        }
        decoder->first_packet = 0;
    }''',
        '''    // on first packet, send extradata
    if (decoder->first_packet) {
        if (avctx->extradata_size) {
            const uint8_t *ed = avctx->extradata;
            int ed_size = avctx->extradata_size;
            /* AV1 in MKV/MP4: extradata is an av1C
             * AV1CodecConfigurationRecord - 4-byte header followed by
             * config OBUs (incl. the sequence header OBU the MPP parser
             * needs; matroska blocks do not repeat it in-band).
             * Strip the av1C header so only OBUs reach the parser. */
            if (avctx->codec_id == AV_CODEC_ID_AV1 &&
                ed_size > 4 && ed[0] == 0x81) {
                ed += 4;
                ed_size -= 4;
            }
            if (ed_size > 0) {
                ret = rkmpp_write_data(avctx, ed, ed_size, avpkt->pts);
                if (ret) {
                    av_log(avctx, AV_LOG_ERROR, "Failed to write extradata to decoder (code = %d)\\n", ret);
                    return ret;
                }
            }
        }
        decoder->first_packet = 0;
    }''')

# verify
checks = [
    ("libavcodec/rkmppdec.c", "AV_CODEC_ID_AV1", 3),
    ("libavcodec/rkmppdec.c", "AV1CodecConfigurationRecord", 1),
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
