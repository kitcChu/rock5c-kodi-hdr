# Rock 5C Kodi Home Theater — Complete Build Journal

**Date**: 2026-08-16 → 2026-08-18 (multi-day project)
**Board**: Radxa Rock 5C Lite (RK3588S2, 2GB RAM)
**OS**: `rock-5c_bookworm_cli_r3` (Radxa Debian 12 CLI image)
**Goal**: 4K HDR hardware-decoding Kodi player → Sony BRAVIA TV, Chord Qutest DAC, NFS media library, TV-remote (CEC) control
**Published**: https://github.com/kitcChu/rock5c-kodi-hdr

**Final status**: ✅ Working — 4K 10-bit HDR10 HEVC hardware decode on video plane (with full HDR10 metadata signalling), ~18% CPU, bit-perfect audio to Qutest, seek/pause-free, 24Hz sync for films, 60Hz GUI, CJK fonts, USB keyboard, HDMI-audio fallback.

---

## Final architecture

```
NFS server (LAN)
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

Two more found later (each also masked by earlier ones):

| # | Layer | Bug | Fix |
|---|---|---|---|
| 5 | ffmpeg rkmppdec.c | **Seek/pause freeze**: after `mpi->reset()` mpp returns garbage PTS (`18442xxxx` values) → video clock explodes, screen freezes while audio follows the seek | reset wrapper state on flush + sanitize negative/garbage PTS to last-fed PTS |
| 6 | ffmpeg rkmppdec.c | **HDR10 metadata never reached the TV** (blob eotf=2 but all-zero luminance/primaries → dim flat picture): MKV stores mastering data in the HEVC SEI (bitstream), not container side-data; and SEI fields are **big-endian u16** | dual-format (hvcC + Annex-B) NAL scanner with emulation-prevention stripping; SEI types 137/144 parsed and attached to frames as side data |

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
| 4K HEVC 10-bit HDR | ~31 fps sustained (23.976 needed) |
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
- Early "10-bit flicker" on one specific file was a red herring — it reproduced on both
  a monitor and the TV, ruling out display capability (later fixed by the HDR metadata
  work; the file itself also had an unusual encode).

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

1. **One specific test file showed color flicker** (subtitles clean) — file-specific:
  a dozen other 10-bit HEVC files of the same specs play perfectly. Likely a quirk of
  that particular encode. Candidate fallback if it ever matters: force the 8-bit output
  path for affected files.
2. **CEC remote unverified** — user must enable BRAVIA Sync on the Sony TV.
3. **Shim offsets are kodi-binary-specific** — any kodi package upgrade breaks the hardcoded Register() addresses; re-derive from dbgsym (see §2) or recompile shim with new offsets.
4. **apt holds** on all rebuilt ffmpeg libs — `apt-mark hold` must be lifted deliberately before any ffmpeg upgrade (and re-applied after rebuild).
5. 4K@60 GUI pixel clock 594 MHz worked on the Sony, but HDMI handshake during boot occasionally negotiates 30Hz first (auto-corrects when kodi applies screenmode).
6. **2026-08-17 incident: apt silently reverted the patched ffmpeg** → movie had sound but no picture (`GetPicture - videoBuffer:nullptr format:yuv420p10le`, no rkmpp line). Cause: `apt-mark` holds had vanished, and apt "upgraded" libavcodec59 to the stock repo copy (our rebuild kept Debian's version string, so same-version replacement passed). Fixed by reinstalling `~/ffmpeg-src/*.deb` + re-holding 10 packages (ffmpeg + all libav*). **Root fix recipe is now: holds must be verified after ANY apt operation.**
7. The reinstall itself hard-crashed the board twice during the 36-deb `dpkg -i` sweep (heavy SD writes; journal corrupted on each; no mmc/ext4 I/O errors in dmesg). Board recovered via power-cycle both times. Prefer staged installs (a few debs at a time) on this board.
8. **Kodi wedge #2 (2026-08-17 ~11:4x)**: kodi process alive, ports listening, but RPC/input/CEC all dead — 9090 accept-queue backed up (3 pending). Triggered by remote `Player.Open` switching audio sources while DSD was playing. Recovery: `systemctl restart kodi`. Rule: never drive playback via raw JSON-RPC on this build — user controls playback via Kore/GUI.
9. **Kodi died once to an external POSIX signal** (11:23, log: "Quitting due to POSIX signal") — likely systemd stop/OOM under library-scan + DSD playback; board itself stayed up.
10. **Webserver toggle remotely = wedge** — see §11; GUI toggle is fine and Kore works. JSON-RPC `SetSettingValue` on action-type settings (screenmode, webserver) fails or hangs in this build — value-type settings set fine.
11. **Board hard-rebooted once (04:50) during webserver debugging** — kodi restart under gdb-attach strain; no OOM logged.
12. **Five unexplained reboots during 2026-08-17/18 builds — root cause: thermal.** All five happened during/after 20-min `-j6` package builds; no OOM, no ext4 errors, no kernel panic lines. Resolution: user fitted a CPU heatsink (it was a hot mid-summer day); temps now 57–64°C under full 4K HDR playback load (throttle point ~85°C). **No reboots since.** RK3588S needs passive cooling at minimum for sustained 8-core builds.

## Post-publish additions (2026-08-18)

- **Seek/pause screen-freeze fixed** (root cause #5 above): video PTS garbage after mpp reset; verified via standalone C reproducer (`scripts/seektest.c` in the GitHub repo): before patch P2 frames carried garbage, after: `bad=0 of 21`; live seeks ±60s and pause/resume confirmed advancing.
- **HDR10 metadata chain completed** (root cause #6): Kodi's `SetHDR` was emitting eotf=2 with zeroed luminance/primaries → dim flat picture on HDR titles. Two-stage debug: (a) discovered MKV stream-level side_data is EMPTY — ffprobe's "stream side data" output had actually been frame-level side data from the software decoder path; (b) wrote a dual-format SEI scanner (hvcC length-prefix + Annex-B, emulation-prevention stripped) into rkmppdec; first version had a BE-u16-as-u32 bug (blob showed `max_cll=512, max_fall=13250` — shifted values), fixed with proper `sei_read_u16`. Final blob verified bit-exact vs ffprobe: BT.2020 primaries, D65 white, 4000-nit max, CLL 577/512. User confirmed brightness/contrast visibly improved on multiple HDR titles.
- **Project published**: https://github.com/kitcChu/rock5c-kodi-hdr — README (root-cause table + benchmarks), docs/SETUP.md (full walkthrough), docs/JOURNAL.md (this file, PII-scrubbed), all patches, shim source, helper scripts. PII audit done; `.env` gitignored with `.env.example` template.
- **Audio**: bit-perfect confirmed by DAC-side rate switching (44.1k FLAC, 48k film, 352.8k DXD); `audiooutput.config=0` (Best Match) — the earlier "dry, unnatural" sound was the 44.1→48 resampler.

## Queued next project (not started)

Smart-presence layer on the same box: RD-03D 24GHz mmWave radar (UART, multi-target people counting) + Logitech C922 webcam (face ID via rknnlite2 on the NPU) + C922 mics (voice commands, English + Cantonese). Design decisions made: pause-after-3-min-empty policy (A/B/C ladder pending user choice), radar gates the camera to save RAM. Key facts gathered: RD-03D protocol = binary `AA FF 03 00 [T1..T3] 55 CC` @256000 baud (V1) or JSON (V2), 3 targets, x/y/speed/distance each; rknpu driver + rknnlite 2.3.0 already on the board; uart overlays via `/boot/dtbo/*uart*.disabled` + rsetup.

## Lessons learned

- **"Feature missing" can mean "registration never called"** — binary forensics (strings/objdump/dbgsym) beat source archaeology for closed distributions. The decoder existed all along; one build flag orphaned it.
- **mpp's decode contract requires same-packet retry on BUFFER_FULL** — every integration that drops-and-advances deadlocks after exactly a few frames.
- **HDR flag bits ride in MppFrameFormat** — always mask with `MPP_FRAME_FMT_MASK` before switching on format.
- **MKV HDR metadata lives in the bitstream (SEI), not the container** — and SEI numeric fields are big-endian u16; mis-sized reads desync the whole message stream (symptom: plausible-but-shifted values).
- **"Dim HDR" is a metadata problem, not a decode problem** — pixels can be perfectly decoded while the TV tone-maps blind because luminance/primaries never reached the HDMI infoframe.
- **Verify ffprobe output format assumptions** — `-show_entries side_data` matches BOTH stream- and frame-level sections; a frame-side-data dump masqueraded as stream-side-data and sent the debug down a wrong (but educational) path.
- **Radxa images need explicit CMA sizing** for media work (default 8MB is for headless use).
- **RK3588S passive-cooled needs a heatsink for sustained builds** — five mystery reboots across two days were all thermal; zero since adding one.
- On 2GB boards: swap + stop kodi + `-j6` for package builds; systemd restart loops from loader errors (exit 127) = broken LD_PRELOAD .so.
- **Same-version rebuilds don't protect against apt replacement** — `apt-mark hold` is mandatory for any locally-built package that keeps the distro version string, and holds can silently vanish; verify after every apt session.
- **A kodi that's "up but ignoring keyboard/CEC/web" is a wedged kodi** — check `ss -tln` for a growing accept queue on 9090 as the signature; restart kodi, don't reboot the board.
- gdb on a stripped binary + separate .debug build-id file works well; optimize-out makes variables unreliable — plan breakpoint-by-line and read `disassemble /s` instead.

### 13. CEC won't connect when TV was off at boot (2026-08-18) — FIXED

**Symptom**: boot the 5C with the TV powered off → later power the TV on →
TV remote does nothing (CEC dead). Restarting kodi alone does NOT fix it.

**Root cause** (verified live): the dw-hdmi-qp kernel driver derives the CEC
physical address from the TV's EDID. TV off at boot → no EDID → CEC adapter
registers as `f.f.f.f` (unregistered) → libCEC can't claim a logical address
(`Logical Address Mask: 0x0000`) → and the driver never re-syncs the CEC
notifier when the TV later hotplugs. Signature check:

    cec-ctl -d 0 --logical-addresses
      → "Physical Address: f.f.f.f" / "Logical Address Mask: 0x0000"
      → "Logical Address: Not Allocated"

**The kick** (works ~5s, verified by user replug test):

    sudo sh -c 'echo detect > /sys/class/drm/card0-HDMI-A-1/status'

Forces a full DRM connector re-detect → driver re-reads EDID → CEC notifier
re-syncs → phys addr becomes `1.0.0.0`, logical address claimed, remote works.

**Automation** — `cec-watch.sh` + systemd timer every 30s:
- only acts when: TV connected AND CEC still `f.f.f.f` AND kodi not playing
  (JSON-RPC `Player.GetActivePlayers` guard → never blinks video mid-movie)
- `cec-watch.timer`: OnBootSec=90, OnUnitActiveSec=30, Persistent
- `cec-watch.service` also runs once after kodi.service (catches early TV-on)

**Lessons**:
- "TV was off at boot" breaks CEC in a way a kodi restart can't fix — the
  stale state lives in the kernel driver, not libCEC. Kick the DRM connector.
- `echo detect` to the connector status sysfs is the reliable re-trigger
  (no udev uevent fires on this platform, so polling beats udev rules).
- Always guard display-affecting kicks with a playback check; defer is fine
  (timer retries every 30s).

### 14. CJK still rendered as boxes — the "CJK fix" never actually fixed the GUI (2026-08-18) — FIXED

**Symptom**: all CJK characters (movie titles, subtitles, menus) render as
hollow rectangles. Earlier session replaced `/usr/share/kodi/media/Fonts/arial.ttf`
with Noto Sans CJK — but the GUI never used it.

**Root cause** (verified): Kodi's Estuary skin has two fontsets in
`skin.estuary/xml/Font.xml`:
- `Default` fontset → loads `NotoSans-Regular.ttf`, `NotoSans-Bold.ttf`,
  `Roboto-Thin.ttf` from `skin.estuary/fonts/` — all **Latin-only** system fonts
  (symlinked). The GUI uses this fontset (`lookandfeel.font = Default`).
- `Arial` fontset → loads `arial.ttf` — which is the file we'd replaced. Never selected.

So the GUI loaded Latin-only glyphs → CJK → boxes, regardless of arial.ttf.

**Verification path that mattered**: `fc-scan` on the actual files kodi loads
(skin fonts dir), not the media/Fonts dir. The first `cp` also wrote through
symlinks and accidentally overwrote the system font — restored from
`fonts-noto-core` deb (keeping the system font Latin is correct; only the skin
fonts should be CJK).

**The fix** — `scripts/apply-cjk-fonts.sh` (idempotent, re-run after kodi upgrades):
1. Extract the **HK face** (index 4) from the system `NotoSansCJK-Regular/Bold.ttc`
   (fontTools; correct variant for Hong Kong users)
2. Replace the skin's `NotoSans-Regular.ttf` / `NotoSans-Bold.ttf` /
   `Roboto-Thin.ttf` symlinks with **real files** of the HK font
3. Originals backed up as `*.latin-orig` (symlinks to system fonts)
4. Restart kodi

**Lessons**:
- "CJK font fix" must target what the skin's *Default fontset actually loads*,
  not a sibling file — check `Font.xml` fontset filenames first.
- `cp file symlink` writes **through** the symlink to its target — always
  `rm` the symlink first or use `cp -P` semantics. This one silently modified
  a system font.
- `pip install` as user doesn't persist for `sudo` scripts — use the apt
  package (`python3-fonttools`) for root-run automation.
- HK/TC/SC/JP are all faces inside one TTC — pick the region face, don't
  settle for face 0 (JP).

### 15. CEC watchdog bug — parse error meant it never fired (2026-08-18) — FIXED

The `cec-watch.sh` timer appeared active but never kicked. Root cause: the
physical-address parser used `awk '{print $3}'` on the cec-ctl line
`Physical Address           : f.f.f.f` — field 3 is the colon, field 4 is the
address. So the comparison `$PA = f.f.f.f` never matched and the script exited
silently on every tick (and wrote nothing to journald, so there was no trace).

Fixes in the new version:
- `awk '{print $4}'` (+ regex fallback) — verified live: detected `f.f.f.f`,
  kicked, recovered to `1.0.0.0` with music playing
- **Relaxed the guard**: only defer when kodi is playing VIDEO. Audio-only
  (music via USB DAC) is safe to kick — the re-detect only re-inits the HDMI
  video plane, USB audio is untouched
- Logs every tick to `/var/log/cec-watch.log` (was silent before — a
  watchdog with no log is unverifiable)

**Lesson**: field-index bugs in awk parsers are invisible when the program
only acts on one specific value — always log what you parsed, and test both
the "needs action" and "no action" branches.

### 16. RD-03D radar: the UART6-M1 mux saga (2026-08-18) — FIXED & LIVE

The RD-03D (V1 binary protocol) now streams into `/dev/ttyS6` at 256000 baud
and the presence agent is live. The path there was long; the root causes were
two independent hardware/kernel gotchas:

**Gotcha 1 — RK3588 IOC write pattern.** The kernel's pinctrl driver claims
the UART6-M1 pins and reports them muxed, but the hardware IOMUX register
stays at GPIO function. Root cause found via kernel source
(`pinctrl-rockchip.c`): RK3588 IOC registers require a **write pattern —
upper 16 bits = mask, lower 16 bits = value**. Plain writes (and plain
`/dev/mem` pokes, and naive kernel modules) are silently ignored. Verified:
`write 0xFF0000AA → 0xFD5F8020` sets GPIO1_A0/A1 to UART6 (func 10).
Fixed by `presence-agent/fix/uart6m1-mux.py` (systemd oneshot at boot) plus
`/boot/boot.scr` `mw.l 0xFD5F8020 0xFF0000AA` in U-Boot as belt-and-braces.

**Gotcha 2 — mux gets clobbered.** Any GPIO request on pins 19/21 (e.g. an
early `gpioset` experiment) makes the pinctrl driver switch the pins back to
GPIO function, silently killing UART6 on the header. Symptom: `/dev/ttyS6`
exists, loopback works through a 19↔21 short, but no external device is ever
seen. The `uart6m1-mux.service` re-asserts the mux at boot; do NOT use
gpioset/gpioget on pins 19/21 afterwards (or re-run the fix).

**Board-side debugging tools that were essential** (all in /tmp during the
hunt, worth re-creating): read IOC registers via `/dev/mem` mmap; the kernel
regmap view at `/sys/kernel/debug/regmap/dummy-syscon@0x00000000fd5f0000/registers`
(the authoritative driver view); the `lseek+read` on `/dev/mem` fails with
EFAULT but mmap works; GPIO EXT registers do NOT reflect muxed pins.

**Also learned**: the RD-03D streams continuously at 256000
(`AA FF 03 00` + 24-byte body + `55 CC`, ~11 fps) — no config command
needed. Body: up to 3 targets (x/y int16 LE, speed int8) then distance/
status bytes. The module was validated standalone on a Raspberry Pi 4B
(kit@192.168.80.144, `/dev/ttyS0` @256000) before returning to the 5C —
that proved module+wires were healthy and isolated the problem to the 5C.

### 17. ⚠️ INCIDENT: presence agent paused movies — hard-rule violation (2026-08-18)

**What happened**: while testing the live presence agent, movies began
"freezing". Investigation showed it was NOT a resource problem — the agent
was PAUSING playback because the RD-03D radar reported "room empty" while
the family was actually watching (seated, still — the radar's detection
coverage/placement did not see the couch).

```
11:49:25 POLICY: paused player 1 (room empty)
11:49:46 POLICY: paused player 1 (room empty)
11:50:06 POLICY: paused player 1 (room empty)
11:50:44 POLICY: resumed player 1 (person returned)
```

**Violated rule**: "never disturb playback — son watches movies".

**Response**: agent stopped + disabled immediately (systemctl stop/disable).
Movie playback restored (speed=1).

**Secondary findings from the investigation** (worth keeping):
- PipeWire stack (pipewire/wireplumber/pipewire-pulse) was pegged ~220% CPU
  stuck in `usb_port_resume` (C922 webcam mics autosuspend hang) → disabled
  via `systemctl --user disable`; the user units live in /etc/systemd/user/
  and pkill -9 alone triggers Restart=on-failure, so disable must go through
  the user manager.
- USB autosuspend (2s default) disabled: `usbcore.autosuspend=-1` in
  /etc/kernel/cmdline + live `echo -1 > /sys/module/usbcore/parameters/autosuspend`.
- Kodi's ActiveAE logged A/V sync errors up to 527ms after pause/resume —
  correlated with the agent's pause/resume cycles, not with display issues.
- CEC watchdog ruled out (never kicks during playback; guard works).
- NFS read throughput 111 MB/s — not a bottleneck.

**Design changes required before the agent returns** (NOT re-enabled):
1. Radar detection must be calibrated so seated viewers are detected
   (placement + sensitivity), with a verified "occupied couch" test.
2. Pause policy must be far more conservative: debounce 60s+, only act on
   long stable EMPTY, and default OFF (opt-in toggle).
3. Consider: never auto-pause if a child is known-present; log every action
   for auditability.

### 18. RD-03D module failure — RF detection dead (2026-08-18)

**Symptom**: module streams empty frames (`AA FF 03 00` + 24 zero bytes +
`55 CC`) at 256000, but detects NOTHING — not even a hand 5-20cm away.
Was working 30 minutes prior (detected count=2, real x/y/speed data).

**Isolated**: wiring proven (frames flow, UART6 mux permanent); power-cycle,
full 30s power-off, wire re-seat, and restore commands (`FD FC FB FB 05...`
factory, sensitivity/range variants) all failed to restore detection.
Module not hot; does not respond to any command.

**Conclusion**: RF front-end failure, likely from today's handling (repeated
plug/unplug during the pin saga + brief wrong-voltage moments). Replacement
is the fix — RD-03D is ~HK$30-40 and our infra (mux, UART6, agent) needs
zero changes: a new module plugs straight in.

**Presence agent remains DISABLED** (would false-pause movies with a blind
radar). Playback is protected.

**Confirmation (later same day)**: module tested on the Raspberry Pi 4B
(kit@192.168.80.144, /dev/ttyS0 @256000) — identical result: streams
225 frames, zero detections at point-blank range. Both boards agree ⇒ the
module's RF front-end is faulty, not the 5C. Replacement required.

### 16. Decode error storm on 4K HDR + silent ffmpeg-lib replacement (2026-08-18) — INVESTIGATED + FIXED

**Symptom**: 4K HDR movie (Guardians Vol 2, 2160p x265) broke — 2000+ kernel
`mpp_rkvdec2 ... resetting for err 0x23/0x107`, kodi JSON-RPC wedged, video
frozen. kodi CPU stayed ~28% (hardware path engaged but failing).

**Phase 1 evidence gathered:**
- CMA `CmaFree` hit **0 kB** during the storm (512M pool)
- Single clean 4K decode dips CMA to ~1.6MB free but recovers (512M is
  marginal-but-sufficient for ONE session)
- ffmpeg (non-kodi) releases CMA fine across repeated opens (delta ~0)
- The storm correlated with **5 rapid decode sessions in 5 min** (14:14–14:18)
  — each session allocates a fresh frame pool (~221MB: 17×13MB) before the
  old one is freed → 5 sessions ≈ 1.1GB demand on a 512MB pool → exhausted
- **Two separate root causes found:**
  - **A. Session-stack CMA exhaustion**: rapid re-opens (seeks/restarts) pile
    frame pools faster than they're released → pool hits 0 → decoder resets
    continuously until a restart frees everything
  - **B. Stock-lib replacement (the big one)**: apt history showed
    `apt-get install libavcodec-dev libavformat-dev libavutil-dev pkg-config`
    at 21:29 **removed our patched `libavcodec59`** and swapped in the stock
    `libavcodec-extra59` (no rkmpp) — the exact quirk from §6. Holds had
    vanished again. kodi restarted at 22:27 would have been software-decoding.

**The fix that mattered most (B)**: restore patched lib from the NAS backup:
```bash
LATEST=$(ls -t /mnt/backups/rock5c-core-*.tar.gz | head -1)
cd /tmp && rm -rf rtest && mkdir rtest
tar xzf "$LATEST" -C rtest home/radxa/ffmpeg-src/libavcodec-extra59_5.1.9-0+deb12u1_arm64.deb
sudo dpkg -i rtest/home/radxa/ffmpeg-src/libavcodec-extra59_5.1.9-0+deb12u1_arm64.deb
sudo apt-mark hold ffmpeg libavcodec59 libavcodec-extra59 libavdevice59 \
  libavfilter8 libavformat59 libavutil57 libpostproc56 libswresample4 libswscale6
```
Verified: installed lib has rkmpp again, `hevc_rkmpp` back in `ffmpeg -decoders`,
current movie plays via `hevc (rkmpp)` with 0 resets and CPU 26%.

**Lessons:**
- **The NAS backup is the recovery path** — it contains the patched debs
  (verified: rkmpp strings present, 12.7MB vs stock 12.6MB). Restore is a
  tar-extract + dpkg -i + hold, ~1 minute.
- **Holds vanish silently** — this is the THIRD time. Verify `apt-mark
  showhold` includes libavcodec* after ANY apt operation, and NEVER install
  `libavcodec-dev` (it pulls stock libs). Journal §6 said this; it recurred.
- **CMA 512M is marginal for 4K HDR**: one session fine, stacked sessions die.
  If rapid-seek scenarios recur, consider `cma=768M` (cost: RAM) or reducing
  kodi's frame pool (videoplayer settings).
- **kodi.log has NO rotation** — the morning evidence vanished on restart.
  Worth adding a copy-to-NAS-on-restart hook for future forensics.

## 17. "Crash on clicking another movie" — root cause #7: `useprimerenderer` flipped 0→1 (2026-08-19) — FIXED

**Symptom**: kodi SIGSEGV ~0.5s after opening any 4K HDR movie. Crashlog
signature: `GL: Requested render method: 0` → `GetShaderFormat - unsupported
format 179` (P010 10-bit) → `gl_tonemap.glsl failed to open` → SEGV.
Reproduced 5× in one night, deterministic.

**Root cause**: the `useprimerenderer` guisetting flipped from **0 (DIRECT)
to 1**. Source proof — the first line of `CRendererDRMPRIME::Create()`:
```cpp
if (buffer && GetSettings()->GetInt(SETTING_VIDEOPLAYER_USEPRIMERENDERER) == 0)
```
With value 1, `Create()` returns nullptr immediately → the factory falls
through to LinuxRendererGL → GL cannot handle P010 → SEGV. Backups that
bracket the working sessions prove the value was 0 before. The decoder still
opened (`hevc (rkmpp)` appears in the crash logs) — only the renderer's
self-qualification failed.

**Fix**: stop kodi, set the setting back to 0, start. Verified: 4K HDR plays
(`hevc (rkmpp)` + NV15 on the video plane, bt2020/smpte2084, CPU 6.7%), and
switching directly to a second 4K file also survives.

**Amplifier**: with the TV off at kodi boot, EGL core-context creation fails
(→ compat GL 3.1 → GLSL 1.40 → shader path `GL/1.2/`, where no video shaders
exist — they live in `GL/1.5/`). So the GL fallback isn't just slow, it SEGVs
on the first 10-bit frame. This explains "failed to open gl_tonemap.glsl"
even though the file exists.

**False trails (documented so nobody repeats them):**
1. Renderer-factory clear race: real in theory, not this bug — exactly one
   `FindPlanes`/`EGL_VERSION` per session in the crash logs (no re-init ran).
2. eglGetProcAddress hook: useless — kodi resolves EGL entry points once.
3. **Runtime binary patching of kodi.bin (call-site trampolines): corrupted
   kodi and wedged the board. Hard rule: no runtime binary patching.** The
   known-good shim backup restored in one minute.
4. Register() guard analysis: all three guard-exit paths disassembled and
   mapped — a red herring; guards pass.

**Diagnostic that cracked it**: diffing `guisettings.xml` against the NAS
backups.

**Permanent improvements (shim v22, deployed + this repo):**
- Registration retry thread: +20s after first `eglInitialize`, then
  `CRendererDRMPRIME::Register()` every 5s (idempotent, internally locked,
  self-guarding). The GUI stops swapping after ~3 frames once the screensaver
  blanks, so swap-hook registration alone is fragile.
- Renderer registration at every `eglInitialize` (covers display re-inits).
- Hook logging for future diagnosis.

**Housekeeping**: `libavcodec-extra59` had silently lost its apt hold again —
re-held. Backup script now includes the compiled shim; fresh backup captured
the working state.

**Open**: what flipped the setting is unknown (candidates: a GUI toggle —
our Register() makes the setting visible in Settings, where stock GL kodi
keeps it hidden — or a crash-time settings save). Check
`videoplayer.useprimerenderer` is 0 if this signature returns.

## 18. HDR10 metadata audit — blob primaries scrambled + EOTF sent as HLG (2026-08-19) — FIXED

**Question**: is kodi actually sending 10-bit HDR metadata to the TV?

**Method**: dump the DRM connector's `HDR_OUTPUT_METADATA` blob during
playback (`scripts/hdr-audit.c`) — it shows exactly what goes on the HDMI
wire. Plane state in `/sys/kernel/debug/dri/0/state` shows the pixel path.

**Audit findings** (before fixes):
- Pixels ✓: `plane[72] NV15` (10-bit), `BT.2020 YCbCr` limited.
- Metadata blob present ✓, luminance ✓ (1000/0.005 nits, D65).
- **Bug 1**: kodi 20.1 copies ffmpeg's r,g,b primary order into the CTA-861
  infoframe slots, which are g,b,r — the TV received a scrambled gamut
  triangle (G slot = red, R slot = blue).
- **Bug 2**: EOTF signalled as HLG (2) instead of PQ (1) — MPP reports
  generic BT2020_10 for HDR10 streams (no VUI transfer parse); kodi maps it
  to HLG.
- MaxCLL/MaxFALL = 0 is faithful — the encode itself carries zeros (checked
  with ffprobe side-data + byte-level parse of the prefix-SEI NAL).

**Fixes (shim v24)**, one hook — `drmModeCreatePropertyBlob` interposition:
1. Rotate primaries r,g,b → g,b,r in any 32-byte TYPE1 HDR blob.
2. Rewrite eotf 2 → 1 when mastering luminance is present (HLG never carries
   ST.2086 metadata, so a luminance-bearing HLG blob is a mislabeled PQ one).

**Verified on the wire**: eotf=1 (PQ), G(13250,34500) B(7500,3000)
R(34000,16000), D65, max 1000 nits. Visually confirmed by the user the same evening ("color perfect").

**Proper fix staged**: `rkmppdec.c` color_trc fallback (container hint, else
SMPTE2084 when ST.2086 present) is patched in the tree — but ffmpeg builds
are on hold: the board hard-wedged twice at build ramp-up (see §19).

## 19. Board hard-wedges under sustained build load — OPEN

Three instant-total hangs (no ping/SSH, power-cycle needed): gdb attach on
kodi, and two `dpkg-buildpackage -j6` launches (second one clean: systemd-run,
kodi stopped, swap mounted — still wedged ~3 min in). Idles and plays fine,
temps cool. Suspects: PSU droop under load spike, RAM instability under
sustained bandwidth. No ffmpeg builds on this board until diagnosed; check
`/sys/fs/pstore` after the next wedge. The `rkmppdec.c` EOTF patch is staged
in the tree; the shim covers the symptom meanwhile.

## 22. AV1 hardware decoding shipped (2026-08-20) — DONE

`av1_rkmpp` is live on the board: kodi plays AV1 through the RK3588 VDPU
(`using decoder av1 (rkmpp)` in kodi.log). Chain: capability probe →
scripts/patch_rkmpp_av1.sh → CI cloud build (Debian bookworm arm64 runner,
~8 min) → libavcodec-extra59 deb → dpkg -i → verified playback.

Operational notes:
- Builds happen ONLY in CI now (board wedge rule §19). Workflow:
  .github/workflows/build-ffmpeg-rkmpp.yml; debs attached to release tag
  `ffmpeg-5.1.9-rkmpp-base` (public CDN; Actions artifact CDN can be ~25KB/s).
- librockchip-mpp-dev is absent from debian/control (Radxa image
  pre-installs it) — CI adds radxa-repo.github.io/rk3588s2-bookworm with the
  keyring from assets/ci-radxa-archive-keyring.gpg.
- dpkg -i reinstalls clear apt holds (caught again, re-applied — ALWAYS
  verify `apt-mark showhold` after dpkg/apt ops).
- Stage 2 (pending): AV1 HDR10 mastering export via
  mpp_frame_get_mastering_display (API confirmed present in MPP 1.5).

## 23. AV1 in-MKV fix + 10-bit verification (2026-08-20) — DONE

Real 4K 10-bit AV1 movie spun forever: extradata is an av1C config record
in MKV; MPP needs raw OBUs (sequence header not repeated in-band).
patch_rkmpp_av1.sh hunk 6 strips the 4-byte header. Capability matrix
proven on real stream: 4K 8-bit ✓, 4K 10-bit ✓, movie extract ✓.
Post-fix: plays via av1 (rkmpp); kernel plane shows NV15 (10-bit) +
BT.709; kodi CPU 41%. CI note: delete old release assets from a
privileged gh session before upload (422 duplicates; job token can't
DELETE).

**OSD/plane saga closed (2026-08-20 14:45)**: Esmart2 (144) as kodi GUI
hung the VOP2 kernel driver on first enable WITH restart limits active —
single bad plane-enable deadlocks this kernel; the crash-loop was a
separate mechanism. Matrix final: Cluster0 works-but-below-video;
Cluster1 aborts kodi; Esmart2 wedges kernel. No plane steering on
6.1.84-8-rk2410. Mitigations: Kore/Yatse app; stop-menu-resume.

## 25. CEC watchdog removed (2026-08-20)

`cec-watch.sh` + `cec-watch.timer`/`.service` retired. History: the DRM
re-detect "kick" caused two regressions (woke a standby TV via CEC, and
paused music ~1s during the kick). Despite added guards (defer during any
playback, only heal when TV answers "on"), the kick remains an inherently
risky DRM re-detect on this kernel — not worth keeping for the convenience
of auto-healing CEC after a TV-off boot. CEC recovery is now manual: restart
kodi, or `echo detect > /sys/class/drm/card0-HDMI-A-1/status` once when the
TV is on. Units + script removed from board and repo.

## 26. CEC re-sync: manual + udev-hotplug wiring (2026-08-20)

Replaced the retired periodic watchdog with two non-intrusive triggers for
the same one-shot heal (`cec-resync.sh`, guarded: only kicks when phys addr
is f.f.f.f, and only when the TV answers "on" unless `--force`):
1. **udev rule** (`99-cec-resync.rules`): runs on DRM HOTPLUG change events
   — fires exactly when the TV powers on (the moment CEC should register).
   No periodic polling, no TV-waking.
2. **sudoers NOPASSWD** for radxa -> cec-resync.sh, so it can be triggered
   via JSON-RPC `System.Exec("sudo /usr/local/bin/cec-resync.sh")` from a
   phone (Kore/Yatse) when the remote/CEC is already dead.

Manual CLI: `sudo cec-resync.sh [--force]`.

## 27. OSD-on-top FIXED (2026-08-20) — the last problem, solved

The VOP2 driver sorts active planes by RAW zpos (source-verified:
sort(vop2_zpos,...)). Raw defaults: GUI Cluster0=0, video Esmart0=11 — the
debugfs "normalized-zpos" field is a post-sort value and was what misled the
earlier attempts. Shim v31 sets video(72)=0 + GUI(56)=8 in one standalone
atomic commit (ALLOW_MODESET) inside kodi's drmModeAtomicCommit: GUI now
sorts above video. rc=0, raw zpos verified 8/0, user confirmed OSD/menus
render on top (subtitles too — same GUI plane). Release kodi-shim-v31;
rollback = kodi-shim.so.bak-v30. Plane-steering (hide/swap) remains
removed/forbidden — it wedged the kernel 3x; zpos is a property value,
distinct and safe.

## 28. HKL-LD2450 clone — believed DOA (2026-08-20) ⚠️ VERDICT RETRACTED — see §30

> **RETRACTION (same day, §30)**: the "dead RF front-end" verdict below was
> WRONG. After the module was moved to UART4-M2 (pins 7/29) it detects
> motion AND static humans reliably. The earlier 300-frame "constant
> heartbeat" observation was a real state at the time, but the module
> recovered/detects now — most likely the pins-19/21 connection was
> marginal (partial contact on TX/RX lines) and the re-seat during the
> UART4 move restored it. Keep §28 for the analysis trail; §30 supersedes
> the conclusion.

Replacement for the dead RD-03D arrived as a **"HKL-LD2450"** (HKL ≠ Hi-Link
HLK — a Taobao clone of the LD2450A multi-target radar). Wired to the same
UART6-M1 pins (19/21, mux already permanent) at 5V (measured 4.98V DC).

**Protocol analysis (exhaustive):**
- Streams at 256000: a constant 16-byte frame `AA 10 B0 00 FF 00 00 00 00
  00 00 00 00 00 5F 55`, ~10 Hz, perfectly periodic (inter-`AA` gap = 16
  bytes, 51/51 frames identical). XOR checksum validates (`10^B0^FF = 5F`)
  ⇒ genuine UART frame, 256000 confirmed.
- **Never changes**: 300+ frames with a hand 5–10 cm directly in front —
  zero variation. Not live detection data; a heartbeat beacon.
- **Ignores every command**: LD2450A config framing (`FD FC FB FA … 04 03
  02 01`: enable/disable conf, query version, reset, restart, single/multi
  target mode, set baud) at 256000 and 115200; also tried `AA FF 03 00` and
  `F4 F3 F2 F1` data-header-wrapped variants, and echoing the heartbeat
  itself. No response, stream never interrupted.
- No other frame pattern anywhere (no `AA FF 03 00`, no `55 CC`, no
  `FD FC FB FA`, no `F4 F3 F2 F1`) in 816-byte full-stream scans.

**Verdict**: MCU boots (valid heartbeat) but the 24 GHz RF front-end never
initializes — same failure mode as the RD-03D (§18). Not a baud/wiring/
protocol problem: 5V confirmed, cold power-cycle done, 4-pin module,
command path verified only by the absence of any response.

**Lesson**: cheap "HKL-" clones (Taobao) of HLK radars can ship DOA. For
presence detection we do NOT need multi-target XY tracking — a presence-only
module is simpler and more reliable.

**Plan**: return the clone; replace with a genuine **HLK-LD2410B** (moving +
static human detection, documented `F4 F3 F2 F1`/`F8 F7 F6 F5` framing at
115200, ~HK$80, ESPHome/HA ecosystem). Infra needs zero board changes (mux,
UART6, pins 19/21); only `radar_reader.py` parser swaps to the LD2410B
19-byte frame. Presence agent stays DISABLED until a working module lands.

**⚠️ SUPERSEDED — do not order the LD2410B.** The module works; see §30.
The LD2410B purchase plan is cancelled unless §30 verification fails.

## 29. Radar moved to UART4-M2 — pins 7/29 via DTS overlay (2026-08-20)

User reading the GPIO diagram spotted the second UART pair (pin 7 = UART4_TX_M2,
pin 29 = UART4_RX_M2, GPIO1_B3/B2) and asked to move the radar there.

**Discovery**: UART enablement on this board is **overlay-based** — U-Boot
applies every non-`.disabled` `.dtbo` in `/boot/dtbo/` via `fdtoverlays`
(u-boot-update globs `*.dtbo`; extlinux.conf regenerated by
`/etc/default/u-boot`). The kernel pinctrl driver then writes the IOC mux
registers with the correct mask/value pattern — no boot.scr `mw.l` or
service hack needed for additional UARTs. The earlier manual mux hack was
only required because UART6's mux was being clobbered post-boot.

**What changed** (3 commands, no hacking):
1. `mv /boot/dtbo/rk3588-uart4-m2.dtbo.disabled /boot/dtbo/rk3588-uart4-m2.dtbo`
2. `sudo u-boot-update` → extlinux.conf now lists both
   `rk3588-uart4-m2.dtbo rk3588-uart6-m1.dtbo`
3. reboot → `/dev/ttyS4` (major 4, minor 68) appears; pinmux-pins shows
   `pin 42/43 (gpio1-10/11): feb70000.serial function uart4 group uart4m2-xfer`

**Verified**: radar module rewired TX→pin 7, RX→pin 29; heartbeat
`AA 10 B0 00 FF 00…5F 55` streams into `/dev/ttyS4` @256000 through both
raw pyserial and the deployed `RadarReader` (reader opens the port fine;
parser itself still expects the RD-03D `AA FF 03 00`/`55 CC` framing — the
HKL clone heartbeat won't decode, expected, module is DOA per §28).

**State**:
- radar_reader.py default `RADAR_PORT` → `/dev/ttyS4` (repo + deployed copy)
- UART6-M1 overlay kept active (pins 19/21 idle, harmless; allows instant
  reversion if the new wiring misbehaves). Both IOC muxes verified intact
  after reboot (GPIO1A 0xAA = UART6, UART4 pins claimed by kernel pinctrl).
- **New "do not touch" pin set: 7/29** (same kernel clobber caveat as 19/21 —
  avoid gpioset/gpioget on them now they're UART4-claimed).
- Next: LD2410B arrival → rewrite radar_reader parser for the
  `F4 F3 F2 F1`/`F8 F7 F6 F5` framing @115200, re-enable presence agent.

## 30. HKL-LD2450 WORKS — protocol decoded, static detection verified (2026-08-20)

**Retraction of §28's DOA verdict.** After the move to UART4-M2 (pins 7/29,
§29), the module detects. What changed: physical re-seat of the TX/RX wires
during the pin move (the pins-19/21 connection was the likely fault — the
module streamed its idle frame but its RF data never made it out cleanly).

**Protocol (fully decoded, checksum-verified):**
- 16-byte frames @256000, ~10 Hz: `AA 10 B0 [P] [D] 00 00 20 00 4E 00 32 00 00 [X] 55`
- `10` = frame length (0x10 = 16); `B0` = constant type/version byte
- **`P` = presence**: `0x00` no target / `0x01` target present (byte 3)
- **`D` = distance**: `0xFF` = none, else range value (byte 4) — observed
  hand-wave 74–128, seated couch 144–191
- bytes 5–13: zeros when idle; `00 00 20 00 4E 00 32 00 00` when tracking
  (constants — likely thresholds/zone config echoed in the frame)
- `X` = XOR checksum of bytes 1–13; `55` = trailer
- No config commands needed; ignores all LD2450A/LD2410B command framings
  (module has no command interface — it's a dumb streaming presence sensor)

**Verification (live tests):**
- Hand wave at 0.1–2 m: 36 unique frames over 120 s, D tracked 74→128,
  zero garbage bytes, checksums valid on every frame
- Stop waving → 60/60 idle frames (P=0x00, D=0xFF) within a second
- 3-min presence timeline (sit still on couch / dining table / return):
  PRESENT(d=144–191) while seated still on couch — **static human detection
  confirmed**; EMPTY at the dining table (>4 m = out of range, same as the
  RD-03D — which per user preference is the desired "finish dinner" nudge)

**Implications:**
- **Do NOT order the LD2410B** (§28 plan cancelled). The HKL-LD2450 meets
  the presence need: static + moving human detection at couch range.
- `radar_reader.py` parser must be rewritten for this frame: presence =
  byte 3 != 0 (ignore the RD-03D `AA FF 03 00`/`55 CC` framing).
- Re-enable the presence agent with the user's preferred 3 s empty-debounce
  once the parser is in place.
- Known limitation (documented): out-of-range >4 m reports EMPTY → will
  pause playback when the family eats at the dining table. User-approved
  behavior (the "finish your dinner" nudge).

## 31. Kodi web UI "Restart" button (2026-08-29)

TV-unplug incident (§: kodi ran with HDMI dead → `DestroyWindow:
deinitialized GBM`, never re-created window on hotplug; fix = restart kodi
service with TV connected) → user asked for a one-click fix in the web UI.

**Solution** (3 pieces, all in `kodi-web-restart/`):
1. `/etc/sudoers.d/kodi-restart` — `radxa ALL=(root) NOPASSWD:
   /usr/bin/systemctl restart kodi` (scoped to exactly one command; follows
   the cec-resync precedent)
2. `script.restart-kodi` addon (`~/.kodi/addons/`) — fires
   `sudo -n systemctl restart kodi` detached (`start_new_session=True` so
   Kodi's addon-process group kill can't abort the systemd transaction);
   logs to `~/restart-kodi.log`
3. Web button: `webinterface.default/index.html` patched (nav item +
   inline handler → `Addons.ExecuteAddon`; idempotent, `.bak` kept)

**Verified end-to-end**: ExecuteAddon → addon ran (log line) → kodi
Stopped/Started (20:11:15→20:11:50, ~35 s boot) → 4K modeset +
mpp hardware decoder up. Kodi takes ~35 s to restart on this board.

**Caveat**: webinterface.default is under /usr/share — Kodi upgrades may
overwrite index.html; re-run `kodi-web-restart/deploy.sh` (idempotent).

## 32. Sound died + movie froze — Kodi passthrough vs Qutest Class 2 S32 (2026-08-29)

After the TV-unplug/HDMI saga (§31), sound stopped reaching the Chord Qutest
and movies froze. Two distinct symptoms, one root cause.

**Timeline**: TV unplugged → kodi restarted several times (20:04/20:10/20:11)
→ DAC worked at 20:10 (S32NE, hw:Qutest) → movie with EAC3 audio at 20:36 →
sink open failed → audio renderer failed → movie frozen (A/V sync stall) →
rkvdec2 reset loops + DRM "plane invisible" errors while kodi retried.

**Debug findings**:
- `CAESinkALSA::InitializeHW - Unable to find a suitable output format`
  opening `ALSA:iec958:CARD=Qutest,DEV=0` (the passthrough device), then
  `sysdefault`; kodi requested AE_FMT_S16NE (the compressed-bitstream format)
  ⇒ kodi was in passthrough mode for the movie's AC3/EAC3 audio.
- Qutest USB interface enumerates **Class 2, S32_LE only** (rates 32k–768k).
  The ALSA `iec958` plugin only carries 16/20/24-bit ⇒ it can never bridge
  to an S32-only DAC. The passthrough device setting was fundamentally
  incompatible.
- Qutest is a **native-rate DAC (no SRC)**: `hw_params` showed it locked at
  44100 Hz (the last FLAC) — it tracks whatever rate the source sends and
  will re-lock when kodi re-opens the sink at 48 kHz for a movie. The DAC was
  healthy; kodi's sink selection was broken.
- guisettings.xml had `audiooutput.ac3passthrough` = **true** (a legacy
  leftover) ⇒ kodi tried passthrough for movie audio.
- Bonus gotcha: the Qutest re-enumerated card index 2 → 0 after a USB reset;
  `hw:CARD=Qutest` (name-based) still resolves correctly.

**Fix** (in `scripts/set-kodi-audio.py`, which runs at every kodi start):
- Force ALL passthrough toggles off: ac3, eac3, dts, truehd, dtshd.
- kodi then decodes everything to PCM and uses `audiooutput.audiodevice`
  (`ALSA:hw:CARD=Qutest,DEV=0`) → S32NE → sink opens cleanly at any rate.
- Correct config for a 2ch PCM DAC: passthrough is never appropriate (the
  Qutest cannot decode compressed audio — passing it through would output
  noise even if the format bridged).

**Verified**: after `systemctl restart kodi`, sink opens
`ALSA:hw:CARD=Qutest,DEV=0` with `AE_FMT_S32NE`; movie playback restored.

**Lesson**: the "frozen movie + decoder resets" was collateral — the video
pipeline stalls on A/V sync while the audio sink can't open. Always check the
audio sink first when video freezes with no obvious decoder fault.

## 33. Presence agent live on HKL-LD2450 — antenna was the missing piece (2026-09-14)

**The big one**: the HKL-LD2450 ships with an **external antenna** that had
never been connected. A 24GHz radar running into an unmatched bare connector
is nearly blind (and risks PA damage from reflected power). That single
omission explains the whole "DOA / intermittent" history of §28-30: weak
detections only when something very close reflected strongly, plus random
seeming "blind" windows. **Always fit the antenna before powering these
modules.**

Measured behaviour after fitting the antenna (three 600 s captures):
- Static presence: solid, stable readings (e.g. D=121 for 15 s, D=178 for
  ~7 s, D=194 for 20 s) — a still person is detected, not just motion
- Motion tracking: smooth distance ramps as the person walks (D 20→90→178)
- Clean idle↔present transitions, ~10 Hz frames, checksums valid
- **Range ceiling ≈ 1.9 m.** A 3 m position never registered (multiple
  attempts, on-axis). The raw distance byte is in **cm** (couch ≈ 144-191,
  hand wave ≈ 74-128).
- Max observed on any run: 194 cm.

**Agent changes** (`presence-agent/`):
- `radar_reader.py` rewritten for the real protocol (was still RD-03D):
  16-byte `AA 10 B0 [P] [D] ... [XOR] 55` frames, XOR of bytes 1-13
  validated, returns `{present, distance, protocol, raw}`; port `/dev/ttyS4`.
- `presence_agent.py`:
  - `DEBOUNCE_EMPTY=5.0` (user requirement), `DEBOUNCE_PRESENT=1.5`
  - `MAX_DISTANCE=300` (cm) distance gate
  - **`PAUSE_TYPES=video,audio`** — pauses *whatever* is playing (was
    video-only, so music kept playing when the user left)
  - pause now fires as soon as the debounce elapses (previously also gated
    behind a 5 s log-throttle, delaying it past the 5 s contract)
  - `kodi_rpc` parses newline/NUL-delimited replies tolerantly — fixes the
    `json-rpc error: Extra data` spam seen in the journal
- Service re-enabled: `systemctl enable --now presence-agent`

**Verified**: with music playing and the room empty,
`18:53:14 POLICY: paused player 0 (room empty)`; live check confirmed
`is_paused = True`, `active_player = 0`. Resume path fires on 1.5 s of
presence.

**Known limitation**: because the radar sees ≈2 m, anyone further away reads
as empty and playback pauses. That is the desired "finish your dinner" nudge
behaviour, but means a 3 m viewer is treated as absent.

## 34. Presence agent debugging — three bugs that made it blind (2026-09-14)

The agent was "working" but never resumed playback. Debug mode
(`RADAR_DEBUG=1`) exposed the truth: it processed **3 radar frames per 28 s**
while the module streams 10 Hz. Three independent bugs:

1. **`time.sleep(POLL)` at the end of every loop iteration** — the agent
   processed at most 2 frames/s (1/0.5s) against a 10 Hz stream, so it acted
   on ~25 s-**stale** frames from the tty buffer. Removed: the radar paces the
   loop. Result: **10.1 frames/s** (matches the module exactly).
2. **`kodi_rpc` waited for a NUL terminator** that Kodi's TCP JSON-RPC never
   sends → every call blocked for the full 3 s socket timeout. The empty-state
   makes 3 RPCs per frame ⇒ ~9 s per frame. Fixed by returning as soon as the
   buffered bytes parse as JSON. Result: **~1 ms per RPC** (was 3000 ms).
3. **`serial.read(256)` blocked for the whole 0.5 s timeout** when fewer than
   256 bytes were pending (the module sends only ~160 B/s), yielding ~1 frame
   per call. Now reads only what is available (`in_waiting`) and parses
   anything already buffered first.

Additional robustness work:
- **`paused_by_us` is persisted** to `/run/presence-agent.paused` (tmpfs). A
  service restart used to forget that *we* paused, stranding playback paused
  forever — the agent now resumes correctly after a restart/deploy.
- **Last-seen hold model** (`PRESENCE_HOLD=4s`): one detection marks presence
  and holds it, instead of requiring continuous presence. The module's returns
  are sparse at range (3/30 frames at 1.5 m), so the old continuous-debounce
  logic could pause but never resume.
- **`RadarReader` self-heals**: a `SerialException` (e.g. a second process
  opening the port) now closes and reopens instead of spinning blind forever.
- **Diagnostics discipline**: never open `/dev/ttyS4` while the service runs —
  a second reader wedges the agent's port (`readiness to read but returned no
  data`). Stop the service first, or use `RADAR_DEBUG=1` on the agent itself.

**Distance-byte finding**: with the user ~3 m from the radar the byte read
54–163, so it is **not** a linear centimetre value at range (near-field reads
were consistent: ~74-78 at arm's length, 121-194 seated). The presence flag is
what the agent gates on; `MAX_DISTANCE` (300) is effectively permissive.

**Verified behaviour** (journal):
```
19:25:11 EMPTY (no presence for 5.1s)  -> 19:25:16 POLICY: paused player 0
19:25:48 PRESENT dist=163              -> 19:25:48 POLICY: resumed player 0
19:26:16 EMPTY (no presence for 5.1s)  -> 19:26:17 POLICY: paused player 0
```
i.e. 5 s of no presence pauses whatever is playing; a single detection resumes
it. User confirmed working.

## 35. Presence agent made an opt-in web toggle — default OFF (2026-09-14)

While the presence tuning is unfinished (sparse returns at range: the user has
to sit within ~1 m for the agent to keep playback going, see §34), the feature
became a **toggle in the Kodi web UI, off by default**.

**Behaviour**
- `presence-agent.service` is **stopped and disabled** — it does not run on
  boot. Nothing pauses playback unless asked.
- Web UI nav now has **Presence** (next to **Restart**): a click toggles the
  service and shows the result as a Kodi on-screen notification
  (`ON - pauses playback when the room is empty` /
  `OFF - playback will not be paused`).
- Turning it **OFF releases playback** if the agent had paused it (checks
  `/run/presence-agent.paused`), so disabling can never strand audio paused.
  This bit us during implementation: the agent had paused the music while the
  user was at dinner; switching off resumed it.

**Implementation** (`kodi-web-presence/`)
- `script.presence-toggle` addon: `systemctl is-active` → start/stop, then a
  Kodi notification; also clears the paused latch and resumes playback.
- `presence-toggle.sudoers`: passwordless `start|stop|restart|is-active` of
  **just** `presence-agent.service`.
- Web button: same pattern as §31 (nav item + inline handler →
  `Addons.ExecuteAddon`); idempotent patch, `index.html.bak2` kept.
- `deploy.sh` takes `SKIP_KODI_RESTART=1` (don't interrupt playback) and a
  configurable `REMOTE_SUDO` (this board has no key auth, so the default
  `sudo -n` needs `REMOTE_SUDO='echo PW | sudo -S'`).

**State after deploy**: agent inactive + disabled; page serves both buttons;
`script.restart-kodi` registered; `script.presence-toggle` registers on the
next Kodi restart — the existing **Restart** button covers that without SSH.

**Tuning already applied** (service drop-in
`presence-agent.service.d/tuning.conf`): `PRESENCE_HOLD=10`,
`DEBOUNCE_EMPTY=12` — tolerant enough not to false-pause at the user's seat
while the gap measurement (deferred, dinner) is still pending.

## 28. Fan mystery solved (2026-08-20) — was never broken

Rock 5C pwm-fan is a kernel thermal cooling device (cdev5, 5 states) bound
to soc-thermal zone0. Stock trip = 60°C: movies (VPU decode) never cross it
→ "fan never spins". Boot blip = PWM pin float before driver probe;
shutdown roar = pin released at poweroff floats high. Fix: runtime trip
write works (sysfs, lost at reboot) — fan-trip.service sets 55000 at boot.
Verified end-to-end: trip 40°C test spun fan to state 4; at 55°C idle it
stays silent. Lesson: `printf | echo | sudo tee` pipes write EMPTY files —
scp then cp instead.

## 29. Backup schedule + found hole (2026-10-22)

rock5c-backup.timer rescheduled 04:30 → 13:55 daily (Persistent=true kept).
Discovered: soft CIFS mount drops after NAS hiccup/power cycle → scheduled
runs exit cleanly ("share up?") with systemd Result=success — silent no-op.
No October tar existed despite timer "success" at boot. Proposed fix
(pending approval): x-systemd.automount on fstab entry.

## 30. SD boot-sector repair (2026-10-27) — Pi write test wiped GPT

C922-voice-test day: card had been in a Raspberry Pi; a write-perf test
zeroed LBA0-33 (MBR code + primary GPT header + entries) AND the backup
GPT at card tail. macOS exposed a stale pre-GPT MBR (bogus 1MB offsets).
Forensics via head/tail dumps + byte-diff vs rock5c-sd64-20260819 master:
idbloader@64 and u-boot@16384 INTACT; damage total ~20KB head + tail GPT.
Repair: wrote head 16MB + tail 512KB from master (dd bs=1m count=16 /
bs=524288 seek=121811). Post-write diff = 0 bytes both ranges; GPT OK.
Zero data loss; the 13:55 auto-backup covered the gap regardless.
LESSON: never raw-write-test a flashed system card; and the master image
+ core tar + GitHub releases triple made this a 20-minute fix.

## 31. Post-repair boot hang fixed (2026-10-27)

After §30 repair, boot stalled >1 min: fstab still demanded /config
(E3D9-5CF0) + /boot/efi (E3D9-B23C) vfat — both filesystems destroyed by
the earlier failed Pi repair attempt (which wrote its own MBR + fake FATs
at wrong offsets). No nofail + fsck passno=2 → systemd waited full device
timeout, multi-user.target blocked (fan-trip, timers behind it). Fix:
nofail,x-systemd.automount + passno 0 on both lines; masked
systemd-boot-update.service (sd-boot updater, meaningless on u-boot).
Board: running, 0 failed, kodi active, trip 55000, timer active.
Note: /config + /boot/efi permanently gone (p1/p2 raw) — boot path
(u-boot raw + extlinux/rootfs) proven independent of them.

Follow-up: dead fstab lines commented out entirely (nofail still let the
device job burn the 90s timeout at boot finish). Cold boot now: kodi
screen ~10s. Note: JSON-RPC checks must use http://:8080/jsonrpc with
webserver auth (admin/... in guisettings) — port 9090 is the raw TCP
socket, HTTP curls to it silently drop.

## 32. 16GB system-card attempt FAILED (2026-10-27/28) — card incompatibility

Goal: 16GB spare system card. Recipe (worked): ddrescue -d rescued the Pi
card (plain dd hit I/O wall at 6.4GB on TWO readers — direct I/O read
through it clean, 100%, 0 bad sectors; the "failing sectors" were a USB
bridge cache artifact), gzipped to NAS, then rebuilt sda: boot chain
(sector 64-32767 from live mmcblk1), fresh GPT (p1 16MB/p2 300MB/p3
14.3GB), mkfs.ext4 with SAME root UUID (fstab/extlinux zero-edit),
rsync -aHAX live rootfs (9.7GB). The clone even RAN THE WHOLE SYSTEM
overnight via USB reader (UUID collision resolved to sda3 — harmless
surprise). But standalone SD boot: BootROM reads (blue LED flicker),
SPL never proceeds, no display, no network — with BIT-IDENTICAL boot
chain (verified md5 after env re-copy). Verdict: physical card
incompatible with RK3588S2 SD controller. Stock 16GB cards need not
apply. Verified boot-chain re-copy technique + rootfs proven. Next
attempt (any new A1/A2 card) = repeat stage3a/3b, ~30 min.
Also: fstab dead vfat lines removed; kodi JSON-RPC = 8080 HTTP with
auth (9090 is raw TCP; HTTP curls silently drop).

§32 addendum: Pi image restored onto the 16GB card via nohup dd
(70MB/s, exact byte count). Full-card md5 verification IMPOSSIBLE on
this card+reader: two direct reads gave different hashes, neither
matching the source — card electrically marginal after ~5 rewrites.
Structural + content verification passed (bootfs/rootfs labels, MBR,
hostname kitPI4). Card returned to Pi duty; final judge = Pi boot.
Reader distrust note: same bridge produced the phantom 6.4GB wall.
