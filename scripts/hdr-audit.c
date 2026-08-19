#include <xf86drm.h>
#include <xf86drmMode.h>
#include <stdio.h>
#include <string.h>
static void dumpblob(int fd, uint64_t v, const char *tag) {
    drmModePropertyBlobPtr b = drmModeGetPropertyBlob(fd, v);
    if (!b) { printf("%s: (no blob)\n", tag); return; }
    if (b->length >= sizeof(struct hdr_output_metadata)) {
        struct hdr_output_metadata *m = b->data;
        struct hdr_metadata_infoframe *h = &m->hdmi_metadata_type1;
        printf("%s blob %zuB: type=%u eotf=%u (1=PQ/ST.2084) md_type=%u\n",
               tag, b->length, m->metadata_type, h->eotf, h->metadata_type);
        printf("  primaries: G(%u,%u) B(%u,%u) R(%u,%u) white(%u,%u)\n",
               h->display_primaries[0].x, h->display_primaries[0].y,
               h->display_primaries[1].x, h->display_primaries[1].y,
               h->display_primaries[2].x, h->display_primaries[2].y,
               h->white_point.x, h->white_point.y);
        printf("  mastering max=%.0f nits min=%.4f nits  maxCLL=%u maxFALL=%u\n",
               (double)h->max_display_mastering_luminance,
               h->min_display_mastering_luminance / 10000.0, h->max_cll, h->max_fall);
    } else {
        printf("%s blob %zuB (raw): ", tag, b->length);
        unsigned char *d = b->data;
        for (size_t i = 0; i < b->length && i < 40; i++) printf("%02x ", d[i]);
        printf("\n");
    }
    drmModeFreePropertyBlob(b);
}
int main(void) {
    int fd = drmOpen("rockchip", NULL);
    if (fd < 0) { printf("open fail\n"); return 1; }
    drmModeObjectPropertiesPtr cp = drmModeObjectGetProperties(fd, 199, DRM_MODE_OBJECT_CONNECTOR);
    if (!cp) { printf("connector props fail\n"); return 1; }
    for (uint32_t i = 0; i < cp->count_props; i++) {
        drmModePropertyPtr p = drmModeGetProperty(fd, cp->props[i]);
        if (!p) continue;
        uint64_t v = cp->prop_values[i];
        if (!strcmp(p->name, "HDR_OUTPUT_METADATA") && v) dumpblob(fd, v, "SOURCE->SINK (HDR_OUTPUT_METADATA)");
        if (!strcmp(p->name, "HDR_PANEL_METADATA") && v) dumpblob(fd, v, "SINK-EDID (HDR_PANEL_METADATA)");
        if (strstr(p->name, "Colorspace")) printf("connector %s = %llu\n", p->name, (unsigned long long)v);
        drmModeFreeProperty(p);
    }
    return 0;
}
