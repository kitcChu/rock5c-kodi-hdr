# Rock 5C Kodi Home Theater — Complete Build Journal

**Date**: 2026-08-16 (multi-day project)
**Board**: Radxa Rock 5C Lite (RK3588S2, 2GB RAM)
**OS**: `rock-5c_bookworm_cli_r3` (Radxa Debian 12 CLI image)
**Goal**: 4K HDR hardware-decoding Kodi player → Sony BRAVIA TV, Chord Qutest DAC, NFS media library, TV-remote (CEC) control

**Final status**: ✅ Working — 4K 10-bit HDR HEVC hardware decode on video plane, ~18% CPU, bit-perfect audio to Qutest, 24Hz sync for films, 60Hz GUI, CJK fonts, USB keyboard, HDMI-audio fallback.

---

## Final architecture

```
NFS server (192.168.80.148)
   └─ /mnt/multimedia (nfs4, automount, nofail)
Rock 5C (kodi.service, autostart → GBM)
   ├─ Video: hevc_rkmpp (libavcodec59, custom build)
   │    → DRM PRIME frames (NV15 10-bit)
   │    → CRendererDRMPRIME → Esmart0-win0 video plane (kernel scanout, zero-copy)
   │    → Sony TV @ 3840x2160/24Hz (auto-switch from 60Hz GUI)
   ├─ Audio: ALSA hw:CARD=Qutest,DEV=0 (bit-perfect PCM, 32-bit)
   ├─ CEC: /dev/cec0 (dw_hdmi_qp_cec) — BRAVIA Sync
   └─ LD_PRELOAD shim: kodi-shim.so (GUI-plane fix + codec registration)
```

---

## The four root causes (all found this session)

Hardware decode needed **four independent fixes**, each masked by the previous one:

| # | Layer | Bug | Fix |
|---|---|---|---|
| 1 | Debian kodi binary | DRM PRIME decoder+renderer **compiled in but never registered** — the registration calls live only in `WinSystemGbmGLESContext.cpp`, Debian builds `APP_RENDER_SYSTEM=gl` | LD_PRELOAD shim calls dormant `Register()` fns by address |
| 2 | Kernel boot | Only **8MB CMA** → 4K 10-bit DMA buffers can't allocate (`ENOSPC`) | `cma=512M` in `/etc/kernel/cmdline` + `u-boot-update` |
| 3 | ffmpeg rkmppdec.c | **Packet-drop deadlock**: on `MPP_ERR_BUFFER_FULL` the code pulled a NEW packet; mpp's contract requires retrying the SAME packet after draining output → decoder starves after ~4 frames | pending-packet retry in `rkmpp_receive_frame` |
| 4 | ffmpeg rkmppdec.c | **HDR format bit**: HDR streams report `MPP_FMT = 0x04000001` (HDR bit 26 set); the format switch didn't mask it → DRM format 0 → renderer rejected → GL fallback → SIGSEGV in `memcpy` | mask with `MPP_FRAME_FMT_MASK` + map 10-bit → `DRM_FORMAT_NV15` |

---

## Detailed findings & experiments

### 1. Kodi settings system quirks

- Real settings file: `~/.kodi/userdata/guisettings.xml` (NOT `settings.xml` — that's a dead end; `CProfileManager::GetSettingsFile()` returns `special://masterprofile/guisettings.xml` in Kodi 20.1)
- File edits only load at kodi **start**; kodi rewrites the file on exit (overwrites concurrent edits)
- `audiooutput.audiodevice` is **reset by kodi at every startup** ("will be properly set on startup" in settings definition) → needs a post-start JSON-RPC set (see kodi-audio.service below)
- Settings hidden until `Register()` sets them visible: `useprimedecoder`/`useprimerenderer` are `visible=false` in linux.xml; the JSON-RPC "Invalid params" error for these settings is the tell-tale that registration never ran
- `videoplayer.useprimerenderer`: `0` = DIRECT video-plane renderer, `1` = GLES renderer (not compiled in Debian's GL build). Must be **0**
- `videoscreen.screenmode` format: `0384002160060.00000p` (encoded width/height/rate string from Kodi's own enumeration — get exact strings via `Settings.GetSettings` full dump)

### 2. Debian kodi binary forensics (why hardware decode "didn't exist")

- Binary: `/usr/lib/aarch64-linux-gnu/kodi/kodi.bin`, Build-ID `c653630581df81f936c3178b9a43cbdef39da80d`
- `CDVDVideoCodecDRMPRIME` code IS compiled in (log strings + `_ZN22CDVDVideoCodecDRMPRIME*` symbols present — note: class name is 22 chars, first search used wrong prefix 23)
- Disassembly proof: `objdump -d kodi.bin | grep "bl.*_ZN22CDVDVideoCodecDRMPRIME8RegisterEv"` → **zero callers**
- Upstream call site (20.1-Nexus): `xbmc/windowing/gbm/WinSystemGbmGLESContext.cpp::InitWindowing()` calls `CRendererDRMPRIMEGLES::Register(); CRendererDRMPRIME::Register(); CDVDVideoCodecDRMPRIME::Register();` — GLES-only file; the GL twin (`WinSystemGbmGLContext.cpp`) has no such calls
- Debian rules build with `-DAPP_RENDER_SYSTEM=gl` → GLES context never compiled → registration never linked
- Debug symbols from `kodi-bin-dbgsym_20.1+dfsg-1_arm64.deb` (debian-debug pool) give exact function offsets: decoder `Register()` @ **0x994900**, renderer `Register()` @ **0x8e0c44**

### 3. The LD_PRELOAD shim (`/usr/lib/aarch64-linux-gnu/kodi-shim.so`)

Two jobs in one `.so`, loaded via kodi.service `Environment=LD_PRELOAD=...`:

1. **Plane-format filter** (original fix): `drmModeGetPlane()` hook strips 10-bit RGB formats (XRGB2101010 etc.) — the Rock 5C kernel rejects those on the GUI plane (xrgb2101010 errors, black screen). Video plane needs NV15 — NOT stripped (filter only removes 2101010 RGB + NV12_10LE40).
2. **Codec registration**: 
   - `eglInitialize()` hook (once): calls decoder `Register()` @ base+0x994900 — settings are loaded by then
   - `eglSwapBuffers()` hook (**every swap**): calls renderer `Register()` @ base+0x8e0c44 — must re-run because `CRendererFactory::ClearRenderer()` wipes registrations on every display re-init (e.g. refresh-rate switch when playback starts). `RegisterRenderer` is an idempotent map insert
   - PIE base from first `kodi.bin` mapping in `/proc/self/maps`, cached
   - Offsets are build-ID-locked to this exact kodi.bin (a kodi package upgrade breaks them — shim checks nothing, kodi crashes if wrong; re-derive from dbgsym after upgrade)
   - Source: `~/kodi-build-backup/kodi-shim.c` (board), /tmp/kodi-shim.c (Mac)

GDB session technique that cracked it: run kodi under `gdb -x script` with breakpoints at `RendererDRMPRIME.cpp` lines + `CDRMPlane::SupportsFormatAndModifier`, trigger playback via JSON-RPC from another shell, read which check rejected. (Breakpoint variables often "optimized out" — rely on line arrival, `disassemble /s`, and `x/s` on string constants.)

### 4. CMA memory

- Symptom: direct `ffmpeg -c:v hevc_rkmpp` decode of ANY 4K (and even 1080p 10-bit at first) → `ENOSPC` / endless `Failed to send packet (code=-11)`
- `/proc/meminfo`: `CmaTotal: 8192 kB` — Radxa image ships no `cma=` parameter
- Fix: append `cma=512M` to `/etc/kernel/cmdline`, run `u-boot-update` (regenerates `/boot/extlinux/extlinux.conf`). Result: `CmaTotal: 524288 kB`
- Note: dropping page cache (1.3GB free RAM) did NOT fix it — CMA region size is the hard limit, allocated at boot

### 5. ffmpeg rkmpp decoder patches (Debian 5.1.9-0+deb12u1 source)

All in `libavcodec/rkmppdec.c`, source kept at `~/ffmpeg-src/ffmpeg-5.1.9/`:

1. **Modern timeout API** (installed mpp 1.7.0 deprecates old ones):
   `MPP_SET_OUTPUT_BLOCK` + `MPP_SET_OUTPUT_BLOCK_TIMEOUT` → single `MPP_SET_OUTPUT_TIMEOUT` (RK_S64)
2. **`MPP_DEC_SET_DISABLE_ERROR`** — don't abort on HW error reports
3. **`MPP_DEC_SET_PARSER_SPLIT_MODE = 1`** — input packets may be arbitrary fragments (NAL-sized); mpp parser reassembles frames. GStreamer's mppvideodec does this; without it kernel logs `H265D_PARSER: No start code is found` + `rkvdec2 cru reset`
4. **Pending-packet retry (THE deadlock fix)** — `rkmpp_receive_frame` rewrite:
   - Old: `ff_decode_get_packet` → `rkmpp_send_packet` → on EAGAIN return... pulling a fresh packet next call → **every rejected packet lost**
   - mpp contract (see mpp `test/mpi_dec_test.c`): on `MPP_ERR_BUFFER_FULL` retry the SAME packet after draining output frames (`pkt_done` flag + msleep loop)
   - New: hold unsent packet in `decoder->pending_pkt`, retry it next call; drain output via `rkmpp_retrieve_frame` in between. EOS tracked with `eos_sent` flag
5. **Greedy pipeline feed**: loop up to `INPUT_MAX_PACKETS` (bumped 4→16) puts per receive call; + `MPP_DEC_SET_PARSER_FAST_MODE=1`. Effect: 4K went ~17fps → ~31fps steady-state (needs only 23.976)
6. **10-bit → NV15**: `MPP_FMT_YUV420SP_10BIT` → `DRM_FORMAT_NV15` (Rockchip packed 10-bit; original code returned non-existent `DRM_FORMAT_NV12_10`)
7. **HDR bit mask** (the crash fix): first line of `rkmpp_get_frameformat`: `mppformat &= MPP_FRAME_FMT_MASK;` — HDR streams report `0x04000001` (`MPP_FRAME_HDR` bit), without masking the switch misses → DRM format **0** → renderer rejects frame → GL fallback memcpy's from a bogus pointer → SIGSEGV (`CVideoBuffer::CopyPicture` from `0xffffffffd460`, `__len=3840`)

Build: `dpkg-buildpackage -b -uc -us -j6` with `DEB_BUILD_OPTIONS="nocheck parallel=6"` (nocheck skips fate tests which double build time and hung once). debian/rules patched: `CONFIG += --enable-version3 --enable-rkmpp` after the linux block. 36 debs in `~/ffmpeg-src/`. Installed libavcodec59/libavcodec-extra59/libavutil57 etc., `apt-mark hold` all 9.

**2GB-RAM build survival kit**: create `/swapfile` 2GB (fstab entry), stop kodi during builds, `-j6` not `-j8`. Board rebooted hard once mid-build (kodi + j8 + no swap).

### 6. Renderer selection chain (why video showed nothing at first)

Kodi 20.1 `CRenderManager::CreateRenderer` iterates registered renderers, each `Create(buffer)` self-qualifies: `CRendererDRMPRIME::Create` requires (a) `useprimerenderer == 0` (DIRECT), (b) buffer is DRM PRIME, (c) GUI plane exists, (d) video plane `SupportsFormatAndModifier(NV15, LINEAR)`. Failure = silent nullptr → falls to LinuxRendererGL → GL can't import DRM PRIME → crash or black/hourglass.

Success signature in `kodi.log`:
```
CDVDVideoCodecDRMPRIME::Open - using decoder hevc (rkmpp)
CDRMPlane::SupportsFormatAndModifier - found plane format (NV15) and modifier (LINEAR)
```
Kernel proof of true zero-copy scanout:
```
/sys/kernel/debug/dri/0/state → plane[72]: Esmart0-win0, crtc=video_port0, fb allocated by = kodi.bin
```

### 7. Performance measurements (final)

| Test | Result |
|---|---|
| 720p10 annexb decode | 325 fps |
| 1080p h264 10-bit | 679 fps |
| 4K HEVC 10-bit HDR (Godzilla UHD) | ~31 fps sustained (23.976 needed) |
| 4K WEB-DL DV/HDR (playing file) | 9.86× realtime |
| GStreamer mppvideodec same 4K file | 363 fps (upper bound of the HW) |
| Playback clock | 18.86s media / 18.80s wall = 100.3% realtime, zero drops |
| kodi CPU during 4K HDR playback | 10–22% total (was 638–800% software) |
| VPU clocks during decode | rkvdec0/1 core @ 594 MHz |

NFS throughput 228 MB/s (not a bottleneck); `dd` test confirmed. Slow 4K numbers were decoder-loop pacing, never I/O.

### 8. Display

- Sony BRAVIA modes: 4K@23.98/24/25/29.97/30/50/59.94/60 (modetest)
- GUI: `videoscreen.screenmode = 0384002160060.00000p` (60Hz; DESKTOP preferred-mode gave 30Hz)
- Movies: `adjustrefreshrate` auto-switches to 24Hz for 23.976fps content (verified: `mode: "3840x2160": 60 594000` in DRM state while GUI, 24 during films)
- 10-bit flicker red herring: Godzilla 2014 flickered on BOTH monitor and Sony TV → not a display-capability issue (see Open Issues)

### 9. Audio

- Device: `ALSA:@:CARD=Qutest,DEV=0` (Kodi option string), i.e. `hw:CARD=Qutest,DEV=0`
- Passthrough off; S32NE bit-perfect confirmed (FLAC → Qutest)
- Qutest drops off USB bus occasionally (enumerated late after reboots — `card 1` then `card 2`); ALSA name-based device string survives renumbering
- **kodi resets audiodevice every start** → automation:
  - `/usr/local/bin/set-kodi-audio.py` — waits for JSON-RPC (9090), sets audiodevice+passthroughdevice
  - `/etc/systemd/system/kodi-audio.service` (After/Requires kodi.service, oneshot)
  - `/etc/systemd/system/kodi.service.d/audio.conf` — `ExecStartPost= sleep 25; set-kodi-audio.py` (covers restarts too)
- HDMI fallback for TV-speaker playback: `ALSA:sysdefault:CARD=rockchiphdmi0` selectable in Kodi audio settings

### 10. Input / fonts / misc UX

- **USB keyboard**: kodi runs as `radxa`, which lacked `input` group → couldn't open `/dev/input/event*` (console worked because root). Fix: `usermod -aG input radxa` + restart
- **CJK**: `fonts-noto-cjk` installed; Kodi skin uses `arial.ttf` for everything, so replaced it: `cp NotoSansCJK-Regular.ttc /usr/share/kodi/media/Fonts/arial.ttf` (orig kept as `arial.ttf.orig`). `subtitles.fontname = DEFAULT`
- **CEC**: `/dev/cec0` present, adapter registers in kodi log. TV side: BRAVIA Sync must be enabled on the Sony (still unverified by user)
- **JSON-RPC**: raw TCP 127.0.0.1:9090, newline-delimited; `Settings.GetSetting` doesn't exist — use `Settings.GetSettings` (plural, full dump ~118KB) to enumerate valid option strings

---

## File inventory (board)

| Path | Purpose |
|---|---|
| `/usr/lib/aarch64-linux-gnu/kodi-shim.so` | THE shim (plane filter + Register calls) |
| `~/kodi-build-backup/kodi-shim.c` | shim source backup |
| `~/ffmpeg-src/ffmpeg-5.1.9/` | patched ffmpeg source (rkmppdec.c.orig = pristine) |
| `~/ffmpeg-src/*.deb` ×36 | built packages (apt-mark hold'd after install) |
| `/usr/local/bin/set-kodi-audio.py` | post-start audio setter |
| `/etc/systemd/system/kodi-audio.service` | boot-time audio setter |
| `/etc/systemd/system/kodi.service.d/audio.conf` | ExecStartPost hook (every kodi start) |
| `/etc/kernel/cmdline` | `+ cma=512M` (u-boot-update source of truth) |
| `/usr/lib/debug/.build-id/c6/…debug` | kodi debug symbols (gdb) |
| `~/.kodi/userdata/guisettings.xml` | all kodi settings (see keys below) |
| `/swapfile` | 2GB swap (fstab) |

**Critical guisettings.xml keys**:
```xml
<setting id="videoplayer.useprimedecoder">true</setting>
<setting id="videoplayer.useprimedecoderforhw">true</setting>
<setting id="videoplayer.useprimerenderer">0</setting>          <!-- 0 = DIRECT video plane -->
<setting id="videoscreen.screenmode">0384002160060.00000p</setting>
<setting id="subtitles.fontname">DEFAULT</setting>
<setting id="videoplayer.adjustrefreshrate">1</setting>
```

## kodi.service unit (relevant bits)
```
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/kodi-shim.so
ExecStart=/usr/bin/kodi --windowing=gbm --standalone
```

### 11. Remote control findings (2026-08-17) — DO NOT enable `services.webserver`

Goal was phone control (Kore) with TV off. Findings:

- **9090 TCP (JSON-RPC)** and **9777 UDP (event server)** work fine on the LAN (`services.esallinterfaces=true`); zeroconf publishes `_xbmc-jsonrpc._tcp` + `_xbmc-events._udp` as "Kodi (rock-5c)"
- **The HTTP webserver DOES work when enabled via the Kodi GUI** (Settings → Services → Control): confirmed 2026-08-17 — user enabled it on the TV, port 8080 came up and **Kore connected successfully**. What's broken is only the programmatic path:
  - Boot-time enable via guisettings.xml: silently never starts
  - Runtime `SetSettingValue services.webserver=true` via JSON-RPC: with empty password vetoed (`result:false`); with a password set it **deadlocks the entire JSON-RPC dispatch** (every RPC blocks; only a kodi restart clears it)
- **Consequence: never toggle the webserver remotely — GUI only.** Once enabled via GUI it persists across restarts and Kore/Yatse work normally.
- Also learned: Kodi runs dialogs/playback fine while RPC is wedged; `Settings.SetSettingValue` for *action* settings (screenmode, webserver) fails or hangs at runtime in this build — only value-type settings (strings) set reliably. File-based guisettings.xml + restart remains the reliable path.
- gl_shader noise: `CYUVShaderGLSL - failed to open gl_shader_frag_texture_lim.glsl` errors appear (also at boot) — Debian kodi ships without GL shader files; harmless while using the DRM PRIME DIRECT renderer (video plane), but confirms the GL path is fully broken in this build.

### 12. Remote control — final state

- **Kore (phone) works**: user enabled webserver + remote control via Kodi GUI on the TV; credentials admin/admin123; port 8080. GUI-toggle is the only safe way (see §11). Music AND video controllable from phone with TV off (audio path is USB→Qutest, HDMI-independent).
- **MPD sidecar: installed 2026-08-17, then reverted same day** (user chose Kore once it worked). Install recipe that worked: apt install mpd mpc; /etc/mpd.conf with `music_directory=/mnt/multimedia/Music`, `bind_to_address any`, alsa output `hw:CARD=Qutest,DEV=0` with `mixer_type none`, `auto_resample/channels/format no`; disable mpd.socket (localhost-only default), enable mpd.service. Fully purged afterwards.

---

## Known issues / open items

1. **Godzilla 2014 rip flickers** (colors flicker, subtitles clean) — file-specific: Ant-Man 1&2, Avengers, other 10-bit HEVC play perfectly. Same specs on paper (Main 10, bt2020, smpte2084) as working files. Suspect mastering-metadata handling or this rip's encode. Candidate fallback: force 8-bit output path for that file (or re-rip).
2. **CEC remote unverified** — user must enable BRAVIA Sync on the Sony TV.
3. **Shim offsets are kodi-binary-specific** — any kodi package upgrade breaks the hardcoded Register() addresses; re-derive from dbgsym (see §2) or recompile shim with new offsets.
4. **apt holds** on all rebuilt ffmpeg libs — `apt-mark hold` must be lifted deliberately before any ffmpeg upgrade (and re-applied after rebuild).
5. 4K@60 GUI pixel clock 594 MHz worked on the Sony, but HDMI handshake during boot occasionally negotiates 30Hz first (auto-corrects when kodi applies screenmode).
6. **2026-08-17 incident: apt silently reverted the patched ffmpeg** → movie had sound but no picture (`GetPicture - videoBuffer:nullptr format:yuv420p10le`, no rkmpp line). Cause: `apt-mark` holds had vanished, and apt "upgraded" libavcodec59 to the stock repo copy (our rebuild kept Debian's version string, so same-version replacement passed). Fixed by reinstalling `~/ffmpeg-src/*.deb` + re-holding 10 packages (ffmpeg + all libav*). **Root fix recipe is now: holds must be verified after ANY apt operation.**
7. The reinstall itself hard-crashed the board twice during the 36-deb `dpkg -i` sweep (heavy SD writes; journal corrupted on each; no mmc/ext4 I/O errors in dmesg). Board recovered via power-cycle both times. Prefer staged installs (a few debs at a time) on this board.
8. **Kodi wedge #2 (2026-08-17 ~11:4x)**: kodi process alive, ports listening, but RPC/input/CEC all dead — 9090 accept-queue backed up (3 pending). Triggered by remote `Player.Open` switching audio sources while DSD was playing. Recovery: `systemctl restart kodi`. Rule: never drive playback via raw JSON-RPC on this build — user controls playback via Kore/GUI.
9. **Kodi died once to an external POSIX signal** (11:23, log: "Quitting due to POSIX signal") — likely systemd stop/OOM under library-scan + DSD playback; board itself stayed up.

6. **Webserver toggle remotely = wedge** — see §11; GUI toggle is fine and Kore works. JSON-RPC `SetSettingValue` on action-type settings (screenmode, webserver) fails or hangs in this build — value-type settings set fine.
7. **Board hard-rebooted once (04:50) during webserver debugging** — kodi restart under gdb-attach strain; no OOM logged.

## Lessons learned

- **"Feature missing" can mean "registration never called"** — binary forensics (strings/objdump/dbgsym) beat source archaeology for closed distributions. The decoder existed all along; one build flag orphaned it.
- **mpp's decode contract requires same-packet retry on BUFFER_FULL** — every integration that drops-and-advances deadlocks after exactly a few frames.
- **HDR flag bits ride in MppFrameFormat** — always mask with `MPP_FRAME_FMT_MASK` before switching on format.
- **Radxa images need explicit CMA sizing** for media work (default 8MB is for headless use).
- On 2GB boards: swap + stop kodi + `-j6` for package builds; systemd restart loops from loader errors (exit 127) = broken LD_PRELOAD .so.
- **Same-version rebuilds don't protect against apt replacement** — `apt-mark hold` is mandatory for any locally-built package that keeps the distro version string, and holds can silently vanish; verify after every apt session.
- **A kodi that's "up but ignoring keyboard/CEC/web" is a wedged kodi** — check `ss -tln` for a growing accept queue on 9090 as the signature; restart kodi, don't reboot the board.
- gdb on a stripped binary + separate .debug build-id file works well; optimize-out makes variables unreliable — plan breakpoint-by-line and read `disassemble /s` instead.
