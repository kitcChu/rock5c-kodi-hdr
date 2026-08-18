#!/bin/sh
# Patch 9: robust NAL scanning for SEI - handle BOTH hvcC length-prefixed
# and Annex-B packet formats, and strip emulation prevention bytes.
set -e
cd "$HOME/ffmpeg-src/ffmpeg-5.1.9"

python3 - << 'PYEOF'
p = "libavcodec/rkmppdec.c"
s = open(p).read()

# replace the naive annexb scanner with a dual-format one
old_scan = """/* scan an annexb packet for SEI NALs (nal type 39) */
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
                const uint8_t *seek = nal + 2; /* 2-byte NAL hdr */
                rkmpp_parse_sei(decoder, seek, end - seek);
            } else if (ntype >= 32 && ntype <= 35) {
                /* VPS/SPS/PPS/AUD - keep scanning */
            }
            p = nal + 1;
        } else {
            p++;
        }
    }
}"""

new_scan = """/* remove emulation prevention bytes (00 00 03 -> 00 00) in place */
static int rkmpp_strip_epb(uint8_t *dst, const uint8_t *src, int size)
{
    int di = 0, zeros = 0;
    for (int si = 0; si < size; si++) {
        if (zeros == 2 && src[si] == 3) {
            zeros = 0;          /* drop the 03 */
            continue;
        }
        zeros = (src[si] == 0) ? zeros + 1 : 0;
        dst[di++] = src[si];
    }
    return di;
}

static void rkmpp_sei_from_nal(RKMPPDecoder *decoder, const uint8_t *nal, int size)
{
    /* nal: full NAL including 2-byte header, already EPB-stripped */
    if (size < 3)
        return;
    int ntype = (nal[0] >> 1) & 0x3F;
    if (ntype == 39)  /* PREFIX_SEI: payload starts after 2-byte NAL hdr */
        rkmpp_parse_sei(decoder, nal + 2, size - 2);
}

/* scan one NAL (shared by both formats) using a small stack buffer */
static void rkmpp_scan_nal(RKMPPDecoder *decoder, const uint8_t *nal, int nal_size)
{
    uint8_t tmp[512];
    int n = rkmpp_strip_epb(tmp, nal, nal_size < 512 ? nal_size : 512);
    rkmpp_sei_from_nal(decoder, tmp, n);
}

/* scan a packet for SEI: supports hvcC length-prefixed AND Annex-B */
static void rkmpp_scan_sei(RKMPPDecoder *decoder, const uint8_t *data, int size)
{
    /* heuristic: hvcC if first 4 bytes are a plausible length */
    if (size > 8) {
        uint32_t len4 = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
        if (len4 > 0 && len4 + 4 <= size && data[4] >> 1 && !(data[0]==0 && data[1]==0 && data[2]<=1)) {
            const uint8_t *p = data, *end = data + size;
            while (p + 4 <= end) {
                uint32_t l = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
                if (l == 0 || p + 4 + l > end)
                    break;      /* malformed -> fall through to annexb */
                rkmpp_scan_nal(decoder, p + 4, l);
                p += 4 + l;
            }
            return;
        }
    }
    /* Annex-B start codes */
    const uint8_t *p = data, *end = data + size;
    while (p + 4 <= end) {
        if (p[0] == 0 && p[1] == 0 && p[2] == 1) {
            const uint8_t *nal = p + 3;
            const uint8_t *q = nal + 2;
            const uint8_t *next = end;
            while (q + 3 <= end) {
                if (q[0] == 0 && q[1] == 0 && q[2] == 1) { next = q; break; }
                q++;
            }
            rkmpp_scan_nal(decoder, nal, next - nal);
            p = next;
        } else {
            p++;
        }
    }
}"""

assert old_scan in s, "old scanner anchor"
s = s.replace(old_scan, new_scan, 1)
open(p, "w").write(s)
print("dual-format SEI scanner applied")
PYEOF
grep -c "rkmpp_strip_epb" libavcodec/rkmppdec.c | xargs echo markers:
