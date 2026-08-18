#!/bin/sh
# Patch 8: parse HDR10 SEI (mastering display + content light level) directly
# from HEVC NAL units in packets and attach to output frames as side data.
# MKV provides no stream-level side data; the metadata lives in the bitstream
# (SEI NAL type 39 PREFIX SEI, payloads 137 mastering / 144 CLL).
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

# --- self-contained SEI parser, inserted before rkmpp_harvest_metadata ---
anchor = "static void rkmpp_harvest_metadata(AVCodecContext *avctx, RKMPPDecoder *decoder,"
parser = r'''/* ---- minimal HEVC SEI harvesting (HDR10) ---- */
static int sei_read_byte(const uint8_t **pp, const uint8_t *end)
{
    return (*pp < end) ? *(*pp)++ : -1;
}

static uint32_t sei_read_u32(const uint8_t **pp, const uint8_t *end)
{
    uint32_t v = 0;
    for (int i = 0; i < 4 && *pp < end; i++)
        v = (v << 8) | *(*pp)++;
    return v;
}

/* parse one SEI payload header; return payload size or -1 */
static int sei_payload(const uint8_t **pp, const uint8_t *end, int *type)
{
    int t = 0, sz = 0, b;
    do { b = sei_read_byte(pp, end); if (b < 0) return -1; t += b; } while (b == 255);
    do { b = sei_read_byte(pp, end); if (b < 0) return -1; sz += b; } while (b == 255);
    *type = t;
    return sz;
}

static void rkmpp_parse_sei(RKMPPDecoder *decoder, const uint8_t *sei, int size)
{
    const uint8_t *p = sei, *end = sei + size;
    while (p < end) {
        int type, sz;
        sz = sei_payload(&p, end, &type);
        if (sz < 0 || end - p < sz)
            break;
        if (type == 137 && sz >= 24 && !decoder->have_mastering) {
            /* mastering display colour volume: 3 primaries + wp + min/max lum */
            static const int mapping[3] = {2, 0, 1}; /* HEVC g,b,r -> r,g,b */
            AVMasteringDisplayMetadata *m = &decoder->mastering;
            uint16_t prim[3][2];
            for (int i = 0; i < 3; i++) {
                prim[i][0] = sei_read_u32(&p, end) & 0xFFFF;
                prim[i][1] = sei_read_u32(&p, end) & 0xFFFF;
            }
            m->white_point[0] = av_make_q(sei_read_u32(&p, end) & 0xFFFF, 50000);
            m->white_point[1] = av_make_q(sei_read_u32(&p, end) & 0xFFFF, 50000);
            m->max_luminance = av_make_q(sei_read_u32(&p, end), 10000);
            m->min_luminance = av_make_q(sei_read_u32(&p, end), 10000);
            for (int i = 0; i < 3; i++) {
                int j = mapping[i];
                m->display_primaries[i][0] = av_make_q(prim[j][0], 50000);
                m->display_primaries[i][1] = av_make_q(prim[j][1], 50000);
            }
            m->has_primaries = 1;
            m->has_luminance = 1;
            decoder->have_mastering = 1;
        } else if (type == 144 && sz >= 4 && !decoder->have_cll) {
            decoder->cll.MaxCLL  = sei_read_u32(&p, end) & 0xFFFF;
            decoder->cll.MaxFALL = sei_read_u32(&p, end) & 0xFFFF;
            decoder->have_cll = 1;
        } else {
            p += sz; /* skip */
        }
    }
}

/* scan an annexb packet for SEI NALs (nal type 39) */
static void rkmpp_scan_sei(RKMPPDecoder *decoder, const uint8_t *data, int size)
{
    const uint8_t *p = data, *end = data + size;
    while (p + 4 <= end) {
        if (p[0] == 0 && p[1] == 0 && (p[2] == 1 || (p[2] == 0 && p + 5 <= end && p[3] == 1))) {
            int hdr = (p[2] == 1) ? 3 : 4;
            const uint8_t *nal = p + hdr;
            if (nal >= end) break;
            int ntype = (nal[0] >> 1) & 0x3F;
            if (ntype == 39) {           /* PREFIX_SEI */
                const uint8_t *seek = nal + 2; /* skip NAL hdr + first byte */
                rkmpp_parse_sei(decoder, seek, end - seek);
            } else if (ntype >= 32 && ntype <= 35) {
                /* VPS/SPS/PPS/AUD - keep scanning */
            }
            p = nal + 1;
        } else {
            p++;
        }
    }
}

'''
assert anchor in s, "harvest anchor missing"
s = s.replace(anchor, parser + anchor, 1)

# --- call the scanner in the harvest helper (annexb packets via bsf) ---
old = """    /* per-packet side data */
    if (pkt) {
        for (int i = 0; i < pkt->side_data_elems; i++) {"""
new = """    /* per-packet side data */
    if (pkt) {
        if ((!decoder->have_mastering || !decoder->have_cll) && pkt->data && pkt->size > 5)
            rkmpp_scan_sei(decoder, pkt->data, pkt->size);
        for (int i = 0; i < pkt->side_data_elems; i++) {"""
assert old in s, "pkt scan anchor"
s = s.replace(old, new, 1)

open(p, "w").write(s)
print("SEI harvest patch applied")
PYEOF
grep -c "rkmpp_scan_sei\|rkmpp_parse_sei" libavcodec/rkmppdec.c | xargs echo markers:
