#!/bin/sh
# Patch 2: add MPP_DEC_SET_PARSER_SPLIT_MODE so the mpp internal parser
# reassembles frames from arbitrary packet boundaries (NAL-sized packets,
# partial frames). This is what gstreamer mppvideodec does and is required
# with mpp 1.7.0 on RK3588.
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

anchor = """    // do not abort decoding on hardware/reported stream errors (H.264/H.265)"""
add = """    // enable parser split mode: input packets may not be complete frames
    paramS32 = 1;
    ret = decoder->mpi->control(decoder->ctx, MPP_DEC_SET_PARSER_SPLIT_MODE, &paramS32);
    if (ret != MPP_OK)
        av_log(avctx, AV_LOG_WARNING, "Failed to enable parser split mode (code = %d).\\n", ret);

    // do not abort decoding on hardware/reported stream errors (H.264/H.265)"""

assert anchor in s, "anchor not found"
s = s.replace(anchor, add, 1)
open(p, "w").write(s)
print("split-mode patch applied")
PYEOF

make -j8 > /tmp/ffmake2.log 2>&1 || { tail -20 /tmp/ffmake2.log; exit 1; }
echo "rebuild OK"
