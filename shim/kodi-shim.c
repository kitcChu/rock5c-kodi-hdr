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

drmModePlanePtr drmModeGetPlane(int fd, uint32_t plane_id)
{
    static getplane_fn real_fn;
    if (!real_fn)
        real_fn = (getplane_fn)dlsym(RTLD_NEXT, "drmModeGetPlane");

    drmModePlanePtr plane = real_fn(fd, plane_id);
    if (!plane)
        return plane;

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
