#!/bin/sh
# Patch 3: break the input-full deadlock.
# Debian rkmpp_receive_frame returns EAGAIN when decode_put_packet says
# BUFFER_FULL, without draining the output side. The decoder output queue
# then fills up, the HW stops consuming input, and decoding deadlocks after
# the first few frames. Fix: on EAGAIN from the put, fall through to
# rkmpp_retrieve_frame to drain produced frames.
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

old = """            ret = rkmpp_send_packet(avctx, &pkt);
            av_packet_unref(&pkt);

            if (ret < 0) {
                av_log(avctx, AV_LOG_ERROR, "Failed to send packet to decoder (code = %d)\\n", ret);
                return ret;
            }"""

new = """            ret = rkmpp_send_packet(avctx, &pkt);
            av_packet_unref(&pkt);

            if (ret < 0 && ret != AVERROR(EAGAIN)) {
                av_log(avctx, AV_LOG_ERROR, "Failed to send packet to decoder (code = %d)\\n", ret);
                return ret;
            }
            /* EAGAIN: decoder input full - fall through and drain output */"""

assert old in s, "patch 3 anchor not found"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("deadlock patch applied")
PYEOF

make -j8 > /tmp/ffmake3.log 2>&1 || { tail -20 /tmp/ffmake3.log; exit 1; }
echo "rebuild OK"
