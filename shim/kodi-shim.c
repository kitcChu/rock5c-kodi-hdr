// kodi-shim.c — Rock 5C Kodi compatibility shim
//
// 1. drmModeGetPlane filter: hides 10-bit formats that the Kodi GBM GUI
//    cannot scan out (kernel rejects XRGB2101010 etc. on the GUI plane).
//
// 2. DRM PRIME codec registration: Debian's kodi is built with
//    APP_RENDER_SYSTEM=gl, so CWinSystemGbmGLContext::InitWindowSystem()
//    never calls CRendererDRMPRIME::Register() / CDVDVideoCodecDRMPRIME::Register()
//    (those calls only exist in the GLES context build). The decoder code
//    itself is compiled in — it just is never registered. This shim calls
//    both Register() functions (addresses resolved from kodi.bin's load
//    base + fixed offsets verified against build-id c6536305...) the first
//    time eglInitialize() succeeds, i.e. inside InitWindowSystemEGL, after
//    settings are loaded and after the factory Clear*() calls.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#ifndef DRM_FORMAT_NV12_10LE40
#define DRM_FORMAT_NV12_10LE40 fourcc_code('N', 'A', '0', '2')
#endif

/* ------------------------------------------------------------------ */
/* 1. plane format filter                                              */
/* ------------------------------------------------------------------ */

static int bad_format(uint32_t fourcc)
{
    switch (fourcc) {
    case DRM_FORMAT_XRGB2101010:
    case DRM_FORMAT_ARGB2101010:
    case DRM_FORMAT_XBGR2101010:
    case DRM_FORMAT_ABGR2101010:
    case DRM_FORMAT_NV12_10LE40: /* 4:2:0 10-bit */
        return 1;
    default:
        return 0;
    }
}

typedef drmModePlanePtr (*getplane_fn)(int fd, uint32_t plane_id);
typedef drmModePlaneResPtr (*planeres_fn)(int fd);

static int g_log_planes = 1; /* one-shot diagnostic logging */

drmModePlaneResPtr drmModeGetPlaneResources(int fd)
{
    static planeres_fn real_fn;
    if (!real_fn)
        real_fn = (planeres_fn)dlsym(RTLD_NEXT, "drmModeGetPlaneResources");
    drmModePlaneResPtr r = real_fn(fd);
    if (r && g_log_planes) {
        fprintf(stderr, "kodi-shim: plane resources: %d planes:", r->count_planes);
        for (uint32_t i = 0; i < r->count_planes && i < 12; i++)
            fprintf(stderr, " %u", r->planes[i]);
        fprintf(stderr, "\n");
    }
    return r;
}

drmModePlanePtr drmModeGetPlane(int fd, uint32_t plane_id)
{
    static getplane_fn real_fn;
    if (!real_fn)
        real_fn = (getplane_fn)dlsym(RTLD_NEXT, "drmModeGetPlane");

/* Plane-steering REMOVED (2026-08-20): nondeterministic kernel deadlock —
 * Cluster1/Esmart2 as GUI aborted kodi (recoverable) but intermittently
 * wedged the VOP2 kernel on restart (board down, 3 incidents). VOP2 on
 * this kernel accepts only Cluster0 as kodi GUI; zpos writes are ignored.
 * OSD/subtitles-under-video is a kernel limitation; see journal §24. */

drmModePlanePtr plane = real_fn(fd, plane_id);
    if (!plane) {
        if (g_log_planes)
            fprintf(stderr, "kodi-shim: GetPlane(%u) -> NULL\n", plane_id);
        return plane;
    }
    if (g_log_planes) {
        int ar24 = 0, xr24 = 0, nv12 = 0, nv15 = 0;
        for (uint32_t i = 0; i < plane->count_formats; i++) {
            if (plane->formats[i] == DRM_FORMAT_ARGB8888) ar24 = 1;
            if (plane->formats[i] == DRM_FORMAT_XRGB8888) xr24 = 1;
            if (plane->formats[i] == DRM_FORMAT_NV12) nv12 = 1;
            if (plane->formats[i] == DRM_FORMAT_NV15) nv15 = 1;
        }
        fprintf(stderr, "kodi-shim: plane %u: %u fmts ar24=%d xr24=%d nv12=%d nv15=%d crtcs=%x\n",
                plane_id, plane->count_formats, ar24, xr24, nv12, nv15,
                plane->possible_crtcs);
    }

    uint32_t kept = 0;
    for (uint32_t i = 0; i < plane->count_formats; i++) {
        if (!bad_format(plane->formats[i]))
            plane->formats[kept++] = plane->formats[i];
    }
    plane->count_formats = kept;
    return plane;
}

/* ------------------------------------------------------------------ */
/* 2. DRM PRIME registration                                           */
/* ------------------------------------------------------------------ */

/* offsets (st_value) inside kodi.bin, build-id c653630581df81f936c3178b9a43cbdef39da80d */
#define OFF_RENDERER_DRMPRIME_REGISTER 0x8e0c44ULL
#define OFF_DECODER_DRMPRIME_REGISTER  0x994900ULL

typedef void (*reg_fn)(void);

/*
 * CRendererDRMPRIME::Register() checks winSystem->GetDrm()->GetVideoPlane(),
 * which is only populated by CDRMUtils::FindPlanes() AFTER eglInitialize.
 * So: decoder registration at eglInitialize, renderer registration at the
 * first eglSwapBuffers (guaranteed after full window system init).
 */

static uintptr_t kodi_base(void)
{
    static uintptr_t cached;
    static int have;
    if (have)
        return cached;
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f)
        return 0;
    char line[1024];
    uintptr_t base = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "kodi.bin")) {
            base = strtoull(line, NULL, 16);
            break;
        }
    }
    fclose(f);
    cached = base;
    have = 1;
    return base;
}

static void register_drmprime_codecs(void)
{
    if (getenv("KODI_SHIM_NOREG"))
        return;
    uintptr_t base = kodi_base();
    if (!base) {
        fprintf(stderr, "kodi-shim: kodi.bin not in maps, skipping DRMPRIME registration\n");
        return;
    }
    reg_fn d = (reg_fn)(base + OFF_DECODER_DRMPRIME_REGISTER);
    fprintf(stderr, "kodi-shim: registering DRM PRIME decoder (base=%p)\n", (void *)base);
    d(); /* CDVDVideoCodecDRMPRIME::Register() - rkmpp/DRM PRIME decoder */
}

static void register_drmprime_renderer(void)
{
    if (getenv("KODI_SHIM_NOREG"))
        return;
    uintptr_t base = kodi_base();
    if (!base)
        return;
    reg_fn r = (reg_fn)(base + OFF_RENDERER_DRMPRIME_REGISTER);
    static unsigned counter;
    if (counter < 3 || (counter % 1000) == 0)
        fprintf(stderr, "kodi-shim: renderer Register() call #%u\n", counter);
    counter++;
    r(); /* CRendererDRMPRIME::Register() - idempotent; re-adds to factory */
}

/*
 * kodi 20.1 bug compensation: CWinSystemGbm copies ffmpeg's r,g,b
 * AVMasteringDisplayMetadata.display_primaries order straight into the
 * HDMI HDR static-metadata infoframe, whose slots are ordered g,b,r
 * (CTA-861-G). The Sony then receives a scrambled gamut triangle
 * (observed live: slot "G"=0.68/0.32 = red, slot "R"=0.15/0.06 = blue).
 * kodi.bin imports drmModeCreatePropertyBlob, so we interpose it and
 * rotate the primaries of any 32-byte hdr_output_metadata blob:
 * emitted [r,g,b] -> wire [g,b,r]. Deterministic for this build; if
 * kodi is ever upgraded past this bug, re-verify before keeping the
 * rotation (the shim is build-ID-locked anyway).
 */
typedef int (*createblob_fn)(int, const void *, size_t, uint32_t *);

int drmModeCreatePropertyBlob(int fd, const void *data, size_t size, uint32_t *id)
{
    static createblob_fn real_fn;
    if (!real_fn)
        real_fn = (createblob_fn)dlsym(RTLD_NEXT, "drmModeCreatePropertyBlob");
    unsigned char buf[32];
    if (size == 32 && data && ((const uint32_t *)data)[0] == 0) {
        /* struct hdr_output_metadata, metadata_type HDMI_STATIC_METADATA_TYPE1:
         * offset 4 eotf, 5 metadata_type, 6..17 primaries (3 x u16 x,y),
         * 18..21 white point, 22..23 max(cd/m2), 24..25 min(0.0001), cll, fall */
        uint16_t *pr = (uint16_t *)((char *)data + 6);
        if (pr[0] | pr[1] | pr[2] | pr[3] | pr[4] | pr[5]) {
            memcpy(buf, data, 32);
            uint16_t *b = (uint16_t *)(buf + 6);
            uint16_t t0 = b[0], t1 = b[1]; /* emitted slot0 = red */
            b[0] = b[2]; b[1] = b[3];      /* slot0 <- green */
            b[2] = b[4]; b[3] = b[5];      /* slot1 <- blue  */
            b[4] = t0;   b[5] = t1;        /* slot2 <- red   */
            /* EOTF fix: MPP reports generic BT2020_10 for the VUI transfer
             * of HDR10 streams; kodi maps that to eotf=2 (HLG). A blob that
             * carries ST.2086 mastering luminance is HDR10 (PQ) content by
             * definition — HLG streams do not carry mastering metadata —
             * so rewrite eotf 2 -> 1 (SMPTE ST.2084). */
            unsigned char *eotf = buf + 4;
            uint16_t max_lum = b[8]; /* offset 6+12: max_display_mastering_luminance */
            if (*eotf == 2 && max_lum > 0) {
                *eotf = 1;
                fprintf(stderr, "kodi-shim: HDR blob eotf HLG -> PQ (ST.2084)\n");
            }
            data = buf;
            fprintf(stderr, "kodi-shim: HDR blob primaries rotated r,g,b -> g,b,r\n");
        }
    }
    return real_fn(fd, data, size, id);
}

/* ------------------------------------------------------------------ */
/* 4. GUI-on-top fix: raise GUI plane zpos inside kodi's atomic commits  */
/* ------------------------------------------------------------------ */
/*
 * kodi 20.1 GBM never sets plane zpos (verified: no zpos code in the
 * 20.1 DRM layer). The VOP2 driver default order stacks the Esmart
 * video plane (zpos=1) ABOVE the Cluster0 GUI plane (zpos=0), so every
 * OSD/menu renders beneath the movie during playback. Setting zpos from
 * outside fails: kodi holds DRM master, external writes get EACCES.
 * Fix: interpose kodi's own drmModeAtomicCommit (kodi.bin imports it) and
 * append a zpos property for the GUI plane to each commit. Kodi is master,
 * so its own commit succeeds. Idempotent value, harmless on test commits.
 * GUI plane 56 (Cluster0-win0) and video plane 72 (Esmart0-win0) ids are
 * deterministic for this kernel/board; shim is build-ID-locked anyway.
 */
typedef int (*atomic_commit_fn)(int, drmModeAtomicReqPtr, uint32_t, void *);

int drmModeAtomicCommit(int fd, drmModeAtomicReqPtr req, uint32_t flags, void *user_data)
{
    static atomic_commit_fn real_fn;
    static uint32_t zpos_prop; /* informational */
    if (!real_fn)
        real_fn = (atomic_commit_fn)dlsym(RTLD_NEXT, "drmModeAtomicCommit");
    if (!zpos_prop) {
        drmModeObjectPropertiesPtr props =
            drmModeObjectGetProperties(fd, 56, DRM_MODE_OBJECT_PLANE);
        if (props) {
            for (uint32_t i = 0; i < props->count_props; i++) {
                drmModePropertyPtr p = drmModeGetProperty(fd, props->props[i]);
                if (p && !strcmp(p->name, "zpos"))
                    zpos_prop = p->prop_id;
                if (p)
                    drmModeFreeProperty(p);
            }
            drmModeFreeObjectProperties(props);
            if (zpos_prop)
                fprintf(stderr, "kodi-shim: zpos prop %u on GUI plane 56\n", zpos_prop);
        }
    }
    if (zpos_prop)
        fprintf(stderr, "kodi-shim: zpos prop %u present (steering via plane filter instead)\n", zpos_prop);
    return real_fn(fd, req, flags, user_data);
}

typedef int (*eglinit_fn)(void *, int *, int *);

/*
 * Late-registration thread: on this GBM setup the GUI stops swapping after a
 * few frames once the screensaver blanks the display (or when the EGL
 * context is degraded), so swap-hook registration is not enough — the
 * factory may never receive "drm_prime" before a movie is opened.
 * Register() is idempotent, internally locked (CRendererFactory uses a
 * CCriticalSection) and self-guards on the video plane, so a slow retry
 * loop is safe. Start at +20s: by then kodi's service broker (settings,
 * window system) is fully up; before that the guards/settings may be null.
 */
static void *register_retry_thread(void *arg)
{
    (void)arg;
    sleep(20);
    for (;;) {
        register_drmprime_renderer();
        sleep(5);
    }
    return NULL;
}

static void start_register_retry_thread(void)
{
    static int started;
    if (started)
        return;
    started = 1;
    pthread_t t;
    pthread_create(&t, NULL, register_retry_thread, NULL);
}

typedef int (*eglswap_fn)(void *, void *);

int eglSwapBuffers(void *dpy, void *draw)
{
    static eglswap_fn real_fn;
    static int logged;
    if (!real_fn)
        real_fn = (eglswap_fn)dlsym(RTLD_NEXT, "eglSwapBuffers");
    if (!logged) {
        logged = 1;
        fprintf(stderr, "kodi-shim: eglSwapBuffers hook fired\n");
    }
    int res = real_fn(dpy, draw);
    register_drmprime_renderer();
    return res;
}

int eglInitialize(void *dpy, int *major, int *minor)
{
    static eglinit_fn real_fn;
    static int done;
    static unsigned count;
    if (!real_fn)
        real_fn = (eglinit_fn)dlsym(RTLD_NEXT, "eglInitialize");
    int res = real_fn(dpy, major, minor);
    if (res) {
        count++;
        fprintf(stderr, "kodi-shim: eglInitialize #%u (decoder %s)\n",
                count, done ? "done" : "first");
        if (!done) {
            done = 1;
            register_drmprime_codecs();
            start_register_retry_thread();
        }
        /* display re-init path: ClearRenderer() may have wiped the factory
         * after the first GUI swaps; re-add the renderer on every egl init.
         * Register() is idempotent and self-guards on the video plane. */
        register_drmprime_renderer();
    }
    return res;
}
