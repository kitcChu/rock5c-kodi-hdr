#!/bin/sh
# Patch 5: pipeline the input feed.
# Previous loop fed ONE packet per retrieved frame -> serialized
# put/parse/HW/get round-trips -> ~17fps on 4K despite the decoder doing
# 360fps (verified with gstreamer mppvideodec). Fill the decoder input
# queue greedily (keep putting until BUFFER_FULL), then retrieve one frame.
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

old = """    if (!decoder->eos_reached) {
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

new = """    if (!decoder->eos_reached) {
        // greedily fill the decoder input queue: keep pulling packets from
        // the demuxer and pushing them until the decoder says it is full.
        // this keeps the hardware pipeline busy instead of serializing one
        // put with one frame retrieval per call.
        for (int i = 0; i < INPUT_MAX_PACKETS; i++) {
            if (!decoder->pending_pkt.data && !decoder->eos_sent) {
                ret = ff_decode_get_packet(avctx, &pkt);
                if (ret < 0 && ret != AVERROR_EOF) {
                    return ret;
                }
                if (ret == AVERROR_EOF) {
                    decoder->eos_sent = 1;
                } else {
                    ret = av_packet_ref(&decoder->pending_pkt, &pkt);
                    av_packet_unref(&pkt);
                    if (ret < 0)
                        return ret;
                }
            }

            if (decoder->pending_pkt.data) {
                ret = rkmpp_send_packet(avctx, &decoder->pending_pkt);
                if (ret == AVERROR(EAGAIN))
                    break; /* input queue full - retrieve frames below */
                av_packet_unref(&decoder->pending_pkt);
                if (ret < 0) {
                    av_log(avctx, AV_LOG_ERROR, "Failed to send packet to decoder (code = %d)\\n", ret);
                    return ret;
                }
            } else if (decoder->eos_sent) {
                ret = rkmpp_send_packet(avctx, &(AVPacket){0});
                if (ret < 0) {
                    av_log(avctx, AV_LOG_ERROR, "Failed to send EOS to decoder (code = %d)\\n", ret);
                    return ret;
                }
                break;
            } else {
                break;
            }
        }
    }

    return rkmpp_retrieve_frame(avctx, frame);
}"""

assert old in s, "loop anchor missing"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("pipeline feed patch applied")
PYEOF

make -j8 > /tmp/ffmake6.log 2>&1 || { grep error /tmp/ffmake6.log | head -3; exit 1; }
echo "BUILD OK"
