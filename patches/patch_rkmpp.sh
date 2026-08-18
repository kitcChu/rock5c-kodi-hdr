#!/bin/sh
# Patch Debian ffmpeg 5.1.9 rkmppdec.c for mpp 1.7.0 / RK3588:
#  1. use modern MPP_SET_OUTPUT_TIMEOUT instead of deprecated
#     MPP_SET_OUTPUT_BLOCK + MPP_SET_OUTPUT_BLOCK_TIMEOUT
#  2. add MPP_DEC_SET_DISABLE_ERROR so H.264/H.265 hardware error
#     reports do not abort the stream after a couple of frames
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"
cp -n libavcodec/rkmppdec.c libavcodec/rkmppdec.c.orig

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

old = """    // make decode calls blocking with a timeout
    paramS32 = MPP_POLL_BLOCK;
    ret = decoder->mpi->control(decoder->ctx, MPP_SET_OUTPUT_BLOCK, &paramS32);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to set blocking mode on MPI (code = %d).\\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    paramS64 = RECEIVE_FRAME_TIMEOUT;
    ret = decoder->mpi->control(decoder->ctx, MPP_SET_OUTPUT_BLOCK_TIMEOUT, &paramS64);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to set block timeout on MPI (code = %d).\\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }"""

new = """    // make decode calls blocking with a timeout
    paramS64 = RECEIVE_FRAME_TIMEOUT;
    ret = decoder->mpi->control(decoder->ctx, MPP_SET_OUTPUT_TIMEOUT, &paramS64);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to set output timeout on MPI (code = %d).\\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    // do not abort decoding on hardware/reported stream errors (H.264/H.265)
    ret = decoder->mpi->control(decoder->ctx, MPP_DEC_SET_DISABLE_ERROR, NULL);
    if (ret != MPP_OK)
        av_log(avctx, AV_LOG_WARNING, "Failed to disable error reporting on MPI (code = %d).\\n", ret);"""

assert old in s, "patch anchor not found"
s = s.replace(old, new)
open(p, "w").write(s)
print("rkmppdec.c patched")
PYEOF
