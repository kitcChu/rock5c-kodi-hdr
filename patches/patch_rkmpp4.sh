#!/bin/sh
# Patch 4 (the real fix): pending-packet retry.
# mpp's decode_put_packet returns BUFFER_FULL while its internal queue is
# full; the caller must RETRY THE SAME packet after draining output frames
# (see mpp test/mpi_dec_test.c: pkt_done + msleep(1) loop). Debian's code
# pulled a new AVPacket on every receive_frame call, so every packet that
# hit a full queue was silently discarded -> decode died after ~4 frames.
# This patch keeps the unsent packet in decoder->pending_pkt and retries it
# on the next call, draining output in between.
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

# 1. add pending packet to the decoder state
old_struct = """    char first_packet;
    char eos_reached;
"""
new_struct = """    char first_packet;
    char eos_reached;
    char eos_sent;

    AVPacket pending_pkt;
"""
assert old_struct in s, "struct anchor missing"
s = s.replace(old_struct, new_struct, 1)

# 2. initialize/clean it
old_init = """    decoder->first_packet = 1;
"""
new_init = """    decoder->first_packet = 1;
    av_init_packet(&decoder->pending_pkt);
"""
assert old_init in s, "init anchor missing"
s = s.replace(old_init, new_init, 1)

old_close = """static int rkmpp_close_decoder(AVCodecContext *avctx)
{"""
new_close = """static int rkmpp_close_decoder(AVCodecContext *avctx)
{
    RKMPPDecodeContext *ctx0 = avctx->priv_data;
    if (ctx0->decoder_ref) {
        RKMPPDecoder *d = (RKMPPDecoder *)ctx0->decoder_ref->data;
        if (d)
            av_packet_unref(&d->pending_pkt);
    }
"""
assert old_close in s, "close anchor missing"
s = s.replace(old_close, new_close, 1)

# 3. rewrite the receive loop with retry semantics
old_loop = """    if (!decoder->eos_reached) {
        // we get the available slots in decoder
        ret = decoder->mpi->control(decoder->ctx, MPP_DEC_GET_STREAM_COUNT, &usedslots);
        if (ret != MPP_OK) {
            av_log(avctx, AV_LOG_ERROR, "Failed to get decoder used slots (code = %d).\\n", ret);
            return ret;
        }

        freeslots = INPUT_MAX_PACKETS - usedslots;
        if (freeslots > 0) {
            ret = ff_decode_get_packet(avctx, &pkt);
            if (ret < 0 && ret != AVERROR_EOF) {
                return ret;
            }

            ret = rkmpp_send_packet(avctx, &pkt);
            av_packet_unref(&pkt);

            if (ret < 0 && ret != AVERROR(EAGAIN)) {
                av_log(avctx, AV_LOG_ERROR, "Failed to send packet to decoder (code = %d)\\n", ret);
                return ret;
            }
            /* EAGAIN: decoder input full - fall through and drain output */
        }

        // make sure we keep decoder full
        if (freeslots > 1)
            return AVERROR(EAGAIN);
    }

    return rkmpp_retrieve_frame(avctx, frame);
}"""

new_loop = """    if (!decoder->eos_reached) {
        // get a new packet only when the previous one was fully sent
        if (!decoder->pending_pkt.data && !decoder->eos_sent) {
            ret = ff_decode_get_packet(avctx, &pkt);
            if (ret < 0 && ret != AVERROR_EOF) {
                return ret;
            }
            if (ret == AVERROR_EOF)
                decoder->eos_sent = 1;
            else {
                ret = av_packet_ref(&decoder->pending_pkt, &pkt);
                av_packet_unref(&pkt);
                if (ret < 0)
                    return ret;
            }
        }

        // try to send the pending (or EOS empty) packet; retry next call on EAGAIN
        if (decoder->pending_pkt.data) {
            ret = rkmpp_send_packet(avctx, &decoder->pending_pkt);
            if (ret == AVERROR(EAGAIN)) {
                /* input queue full: drain output, retry same packet later */
            } else {
                av_packet_unref(&decoder->pending_pkt);
                if (ret < 0) {
                    av_log(avctx, AV_LOG_ERROR, "Failed to send packet to decoder (code = %d)\\n", ret);
                    return ret;
                }
            }
        } else if (decoder->eos_sent) {
            ret = rkmpp_send_packet(avctx, &(AVPacket){0});
            if (ret == AVERROR(EAGAIN)) {
                /* retry EOS later */
            } else if (ret < 0) {
                av_log(avctx, AV_LOG_ERROR, "Failed to send EOS to decoder (code = %d)\\n", ret);
                return ret;
            }
        }
    }

    return rkmpp_retrieve_frame(avctx, frame);
}"""

assert old_loop in s, "loop anchor missing"
s = s.replace(old_loop, new_loop, 1)
open(p, "w").write(s)
print("pending-packet retry patch applied")
PYEOF

make -j8 > /tmp/ffmake4.log 2>&1 || { tail -25 /tmp/ffmake4.log; exit 1; }
echo "rebuild OK"
