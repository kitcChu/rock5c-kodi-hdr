# Full Setup Walkthrough — Rock 5C as a 4K HDR10 Kodi Player

This is the complete, ordered procedure as performed and verified on a real system.
It assumes: Radxa ROCK 5C (any RAM), Radxa bookworm CLI image on SD/eMMC, network up,
SSH as `radxa` (password `radxa`), NFS media at `/mnt/multimedia` (optional).

## 0. Conventions

- `kodi 2:20.1+dfsg-1` from Debian (unmodified). All Kodi-side changes happen via
  settings files + LD_PRELOAD, **never by rebuilding Kodi**.
- ffmpeg rebuilt from Debian source with `--enable-rkmpp` + the patches in
  `patches/` (or just take `patches/rkmppdec.c` wholesale).

## 1. Kernel boot arguments (CMA)

The stock image gives the media stacks only 8 MB of contiguous DMA memory. 4K 10-bit
frame buffers need ~12 MB *each*.

```sh
sudo sed -i 's/$/ cma=512M/' /etc/kernel/cmdline
sudo u-boot-update     # regenerates /boot/extlinux/extlinux.conf
sudo reboot
# verify: grep CmaTotal /proc/meminfo  -> 524288 kB
```

## 2. Rebuild ffmpeg with rkmpp + patches

On a 2 GB board: add swap first, stop Kodi, build with `-j6` at `nice 19`.

```sh
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile \
  && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo systemctl stop kodi

echo 'deb-src http://deb.debian.org/debian bookworm main' | sudo tee -a /etc/apt/sources.list
sudo apt-get update && sudo apt-get build-dep -y ffmpeg
mkdir ~/ffmpeg-src && cd ~/ffmpeg-src && apt-get source ffmpeg
cd ffmpeg-5.1.9

# apply the patches in order (they are idempotent-checked with python asserts)
for p in ../patches/patch_rkmpp{,2,3,4,5}.sh; do sh $p; done
sh ../patches/patch_rkmpp_hdr.sh
sh ../patches/patch_rkmpp_sei.sh
sh ../patches/patch_rkmpp_sei2.sh
#   (if any anchor fails, compare against patches/rkmppdec.c — the final state)

# enable rkmpp in the package build
python3 - << 'EOF'
p = "debian/rules"; s = open(p).read()
old = """ifeq (linux,$(DEB_HOST_ARCH_OS))
\tCONFIG += --enable-libdc1394 \\
\t\t--enable-libdrm \\
\t\t--enable-libiec61883
endif"""
new = old + "\n\n# Rockchip MPP hardware decoders (rkmpp)\nCONFIG += --enable-version3 --enable-rkmpp"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
EOF

DEB_BUILD_OPTIONS="nocheck parallel=6" dpkg-buildpackage -b -uc -us -j6

# install — NOTE: the *extra* flavor owns libavcodec.so.59 on this image
sudo dpkg -i ../libavcodec-extra59_*.deb ../libavcodec59_*.deb ../libavutil57_*.deb \
                 ../libswresample4_*.deb ../libavformat59_*.deb ../ffmpeg_*_arm64.deb
sudo apt-mark hold libavcodec59 libavcodec-extra59 libavutil57 libavformat59 \
                     libswresample4 ffmpeg
```

### What the patches do (summary)

| # | File | Purpose |
|---|---|---|
| 1 | rkmppdec.c | modern `MPP_SET_OUTPUT_TIMEOUT`, `MPP_DEC_SET_DISABLE_ERROR`, parser split+fast mode |
| 2 | rkmppdec.c | **pending-packet retry** (fixes the 4-frame deadlock) |
| 3 | rkmppdec.c | greedy pipeline feed (17→31 fps on 4K) |
| 4 | rkmppdec.c | 10-bit → `DRM_FORMAT_NV15`; mask HDR bit with `MPP_FRAME_FMT_MASK` |
| 5 | rkmppdec.c | seek/pause PTS sanitization + full state reset on flush |
| 6 | rkmppdec.c | HDR10 side data: harvest from SEI (types 137/144), attach to frames |

## 3. The LD_PRELOAD shim

```sh
sudo apt-get install -y libdrm-dev gcc
cc -shared -fPIC -O2 -I/usr/include/libdrm -o /usr/lib/aarch64-linux-gnu/kodi-shim.so \
   shim/kodi-shim.c -ldrm
```

Edit the systemd unit (copy it out first if needed):

```
sudo systemctl edit --full kodi
#   [Service]
#   Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/kodi-shim.so
#   ExecStart=/usr/bin/kodi --windowing=gbm --standalone
```

The shim does two things:
1. filters un-scannable 10-bit RGB formats out of `drmModeGetPlane` (GUI plane),
2. calls the dormant `CDVDVideoCodecDRMPRIME::Register()` (at `eglInitialize`) and
   `CRendererDRMPRIME::Register()` (at every `eglSwapBuffers`, because Kodi wipes the
   renderer registry on each display re-init).

**Offsets are locked to kodi-bin Build-ID `c653630581df81f936c3178b9a43cbdef39da80d`.**
After a Kodi upgrade, re-derive them from `kodi-bin-dbgsym` (see `docs/JOURNAL.md` §2).

## 4. Kodi settings

With Kodi stopped, merge into `~/.kodi/userdata/guisettings.xml`:

```xml
<setting id="videoplayer.useprimedecoder">true</setting>
<setting id="videoplayer.useprimedecoderforhw">true</setting>
<setting id="videoplayer.useprimerenderer">0</setting>   <!-- 0 = DIRECT video plane -->
<setting id="videoplayer.adjustrefreshrate">1</setting>
<setting id="videoscreen.screenmode">0384002160060.00000p</setting>
<setting id="winsystem.ishdrdisplay">true</setting>
<setting id="audiooutput.config">0</setting>             <!-- Best Match = bit-perfect -->
<setting id="audiooutput.audiodevice">ALSA:@:CARD=Qutest,DEV=0</setting>
```

## 5. Audio automation (Kodi resets the device on every start)

```sh
sudo cp scripts/set-kodi-audio.py /usr/local/bin/
sudo cp scripts/kodi-audio.service /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/kodi.service.d
printf '[Service]\nExecStartPost=/bin/sh -c "sleep 25; /usr/bin/python3 /usr/local/bin/set-kodi-audio.py || true"\n' \
  | sudo tee /etc/systemd/system/kodi.service.d/audio.conf
sudo systemctl daemon-reload && sudo systemctl enable --now kodi-audio
```

## 6. Fonts / input / misc

```sh
# CJK: Kodi's skin renders everything with arial.ttf — replace it
sudo apt-get install -y fonts-noto-cjk
sudo cp /usr/share/kodi/media/Fonts/arial.ttf /usr/share/kodi/media/Fonts/arial.ttf.orig
sudo cp /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc /usr/share/kodi/media/Fonts/arial.ttf

# USB keyboard in Kodi: the kodi user needs the input group
sudo usermod -aG input radxa
```

## 7. Verify

```sh
# hardware decode engaged?
grep -a "using decoder hevc (rkmpp)" ~/.kodi/temp/kodi.log
# video plane scanning out?
sudo cat /sys/kernel/debug/dri/0/state | grep -A2 "plane\[72\]"
# HDR blob (needs a movie playing)
python3 scripts/decode_blob.py     # expect eotf=2, max_luminance=1000..4000, BT.2020 primaries
# bit-perfect audio: DAC hardware stream should match file rate
cat /proc/asound/card0/pcm0p/sub0/hw_params
```

## 8. Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| CPU 600%+, no `rkmpp` in log | codec not registered / settings ignored | shim installed? LD_PRELOAD in unit? settings keys exact? |
| Decode dies after ~4 frames | pre-patch-2 lib installed | reinstall built debs; check `apt-mark showhold` |
| Screen frozen after seek | pre-patch-5 lib | same |
| Dim/washed HDR | metadata missing (pre-patch-6) | same; verify blob |
| Board reboots under load | thermal (no heatsink) / PSU | add heatsink; use official 5V/5A PSU |
| `apt-get install libavcodec-dev` broke HW decode | it replaced `libavcodec.so.59` with stock | reinstall built `libavcodec-extra59` deb |
