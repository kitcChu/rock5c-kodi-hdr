#!/bin/sh
# Patch 6: forward HDR10 mastering metadata to output frames.
# MKV carries mastering display / content light metadata as AVPacket side
# data. Our wrapper dropped it, so Kodi emitted an HDR metadata blob with
# eotf=ST2084 but zeroed luminance/primaries -> TV tone-maps dim, and
# BT.2020 content stays flagged as 709 -> muted colors.
# Fix: stash side data from input packets, attach to every output frame.
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

# 1. decoder state
old = """    char eos_sent;

    AVPacket pending_pkt;
"""
new = """    char eos_sent;

    AVPacket pending_pkt;

    AVMasteringDisplayMetadata mastering;
    AVContentLightMetadata cll;
    char have_mastering;
    char have_cll;
"""
assert old in s, "struct anchor missing"
s = s.replace(old, new, 1)

# 2. harvest side data from packets (scan each packet once)
old = """        if (decoder->pending_pkt.data) {
            ret = rkmpp_send_packet(avctx, &decoder->pending_pkt);
"""
new = """        if (decoder->pending_pkt.data) {
            if (!decoder->have_mastering || !decoder->have_cll) {
                for (int i = 0; i < decoder->pending_pkt.nb_side_data; i++) {
                    const uint8_t *sd = decoder->pending_pkt.side_data[i].data;
                    int sz = decoder->pending_pkt.side_data[i].size;
                    switch (decoder->pending_pkt.side_data[i].type) {
                    case AV_PKT_DATA_MASTERING_DISPLAY_METADATA:
                        if (sz >= sizeof(AVMasteringDisplayMetadata)) {
                            memcpy(&decoder->mastering, sd, sizeof(AVMasteringDisplayMetadata));
                            decoder->have_mastering = 1;
                        }
                        break;
                    case AV_PKT_DATA_CONTENT_LIGHT_LEVEL:
                        if (sz >= sizeof(AVContentLightMetadata)) {
                            memcpy(&decoder->cll, sd, sizeof(AVContentLightMetadata));
                            decoder->have_cll = 1;
                        }
                        break;
                    default:
                        break;
                    }
                }
            }
            ret = rkmpp_send_packet(avctx, &decoder->pending_pkt);
"""
assert old in s, "send anchor missing"
s = s.replace(old, new, 1)

# 3. attach to every output frame
old = """        // now setup the frame buffer info
        buffer = mpp_frame_get_buffer(mppframe);
"""
new = """        // forward HDR10 metadata harvested from packet side data
        if (decoder->have_mastering) {
            AVFrameSideData *sd = av_frame_new_side_data(frame,
                    AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,
                    sizeof(AVMasteringDisplayMetadata));
            if (sd)
                memcpy(sd->data, &decoder->mastering, sizeof(AVMasteringDisplayMetadata));
        }
        if (decoder->have_cll) {
            AVFrameSideData *sd = av_frame_new_side_data(frame,
                    AV_FRAME_DATA_CONTENT_LIGHT_LEVEL,
                    sizeof(AVContentLightMetadata));
            if (sd)
                memcpy(sd->data, &decoder->cll, sizeof(AVContentLightMetadata));
        }

        // now setup the frame buffer info
        buffer = mpp_frame_get_buffer(mppframe);
"""
assert old in s, "frame anchor missing"
s = s.replace(old, new, 1)

open(p, "w").write(s)
print("HDR metadata patch applied")
PYEOF

make -j8 libavcodec/libavcodec.so.59 > /tmp/ffmake_hdr.log 2>&1 || { tail -15 /tmp/ffmake_hdr.log; exit 1; }
echo "libavcodec rebuilt"
