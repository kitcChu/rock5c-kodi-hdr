# Rock 5C Kodi — 4K HDR10 Hardware Decoding on Debian/Radxa OS

Turn a **Radxa Rock 5C** (RK3588S2) running the stock **Radxa bookworm CLI image** into a
fully hardware-accelerated 4K HDR10 Kodi media player:

| | |
|---|---|
| Video | HEVC/H.264 (8/10-bit, HDR10) via **rkvdec2** → DRM PRIME **NV15** → direct video-plane scanout (zero-copy) |
| CPU during 4K HDR playback | **~18%** total (was 638% with software decode) |
| HDR | Full HDR10 metadata (mastering display, MaxCLL/FALL) signalled over HDMI — TV tone-maps correctly |
| Display | 4K@60 GUI, auto-switch to 24Hz for film; Sony BRAVIA tested |
| Audio | Bit-perfect ALSA → USB DAC (Chord Qutest), stream opens at each file's native rate (44.1k–352.8k verified) |
| Extras | CJK fonts, USB keyboard, CEC, seek/pause-free (fixed), NFS library |

Everything is done with **~9 surgical patches to Debian's ffmpeg** plus one **LD_PRELOAD shim** —
no Kodi rebuild, no custom kernel, no distribution change.

---

## Why this was hard (four independent root causes)

Hardware decode on this stack fails silently for four separate reasons. Each one masks the
next, so fixing any single bug gets you nowhere:

1. **Debian's Kodi never registers the DRM PRIME codec.**
   The registration calls live only in `WinSystemGbmGLESContext.cpp`; Debian builds Kodi
   with `APP_RENDER_SYSTEM=gl`, so the GLES context file is never compiled. The decoder
   and renderer code *is* in `kodi.bin` — it is simply never wired up. Proven via
   `objdump`: zero callers of `CDVDVideoCodecDRMPRIME::Register()`.
   **Fix:** an LD_PRELOAD shim calls the dormant `Register()` functions by address
   (resolved from Debian's debug symbols) at `eglInitialize` / `eglSwapBuffers` time.

2. **8 MB CMA.** The Radxa image ships no `cma=` parameter; 4K 10-bit frame buffers
   cannot allocate → `ENOSPC` after a few frames.
   **Fix:** `cma=512M` in `/etc/kernel/cmdline` + `u-boot-update`.

3. **ffmpeg's rkmpp wrapper drops packets on `MPP_ERR_BUFFER_FULL`.** mpp's contract
   (see its own `mpi_dec_test.c`) requires retrying the *same* packet after draining
   output; the wrapper pulls a new packet instead. Every rejected packet is lost and
   the decoder deadlocks after ~4 frames.
   **Fix:** pending-packet retry in `rkmpp_receive_frame`.

4. **HDR format bits break format mapping.** HDR streams report `MppFrameFormat =
   0x04000001` (HDR flag in bit 26); the switch on format misses → DRM format **0** →
   renderer rejects → GL fallback → SIGSEGV. Also: 10-bit maps to `DRM_FORMAT_NV15`
   (not the non-existent `NV12_10`), and **MKV HDR metadata lives in the HEVC SEI**
   (bitstream), not in container stream side-data — so it must be parsed out of SEI
   NALs and attached to frames.

Plus one more subtle one:

5. **Seeks/pause froze the picture** (audio kept going): after `mpi->reset()` mpp
   returns garbage PTS → video clock explodes. Fixed by resetting wrapper state on
   flush and sanitizing negative PTS.

## What's in this repo

```
shim/kodi-shim.c          LD_PRELOAD shim: plane-format filter + Register() calls
patches/rkmppdec.c        the fully-patched decoder wrapper (ffmpeg 5.1.9)
patches/patch_rkmpp*.sh   the individual patches, in the order they were applied
scripts/                  helpers (audio setter, JSON-RPC tools, HDR blob decoder,
                          seek reproducer, gdb scripts)
docs/                     build journal + howtos (start with docs/JOURNAL.md)
```

## Quick start

Full walkthrough: [`docs/SETUP.md`](docs/SETUP.md). In short:

```sh
# 1. boot args
echo 'cma=512M' | sudo tee -a /etc/kernel/cmdline && sudo u-boot-update

# 2. build patched ffmpeg (adds --enable-rkmpp; patches apply to the source)
apt-get source ffmpeg && cd ffmpeg-5.1.9
#   apply patches/ in order, add to debian/rules: CONFIG += --enable-version3 --enable-rkmpp
dpkg-buildpackage -b -uc -us -j6
sudo dpkg -i ../*.deb && sudo apt-mark hold libavcodec-extra59 ...

# 3. install the shim (offsets are build-ID-locked to kodi 2:20.1+dfsg-1 arm64)
cc -shared -fPIC -O2 -I/usr/include/libdrm -o /usr/lib/aarch64-linux-gnu/kodi-shim.so \
   shim/kodi-shim.c -ldrm
#   and add to kodi.service: Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/kodi-shim.so

# 4. guisettings.xml keys
#    videoplayer.useprimedecoder=true  useprimedecoderforhw=true  useprimerenderer=0
#    winsystem.ishdrdisplay=true  videoscreen.screenmode=0384002160060.00000p

# 5. run kodi with --windowing=gbm --standalone
```

## Performance (RK3588S2, stock clocks)

| Test | Result |
|---|---|
| 4K HDR HEVC decode rate | ~31 fps sustained (needs 23.976) — 9.9× realtime on WEB-DL |
| 1080p 10-bit H264 | 679 fps |
| 720p 10-bit HEVC | 325 fps |
| GStreamer mppvideodec (upper bound) | 363 fps on same 4K file |
| Playback clock | 100.3% realtime, zero drops |
| kodi.bin CPU during 4K HDR | 10–22% |

## Tested with

- Radxa ROCK 5C Lite (RK3588S2, 2 GB) — `rock-5c_bookworm_cli_r3`
- Kodi 2:20.1+dfsg-1 (Debian, unmodified binary) — **shim offsets are tied to this
  exact build** (`kodi-bin-dbgsym` Build-ID `c653630581df81f936c3178b9a43cbdef39da80d`)
- ffmpeg 5.1.9-0+deb12u1 (rebuilt with `--enable-rkmpp`)
- librockchip-mpp 1.7.0, kernel 6.1.84-8-rk2410
- Sony BRAVIA (4K60, HDR10), Chord Qutest USB DAC

## Known limitations

- Shim offsets break on any Kodi package upgrade (re-derive from dbgsym — see docs).
- One UHD rip (Godzilla 2014) shows color flicker; a dozen others are clean.
- `avcodec-extra59` owns `libavcodec.so.59` on this image — install that flavor, and
  `apt-mark hold` it (an innocent `apt-get install libavcodec-dev` silently reverts
  everything to stock).
- 2 GB RAM: use swap + `-j6` and stop Kodi when building packages.

## License

Patches to ffmpeg source inherit ffmpeg's LGPL/GPL as applicable; the shim and scripts
are MIT. See `LICENSE`.
