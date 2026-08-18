---
name: Bug report
about: Something doesn't decode / display / sound right
labels: bug
---

**Environment**
- Board: 
- OS/image: 
- Kodi version (`dpkg -l kodi | tail -1`): 
- ffmpeg (`ffmpeg -version | head -1`): 
- Kernel (`uname -r`): 
- Kodi build-id (`readelf -n /usr/lib/aarch64-linux-gnu/kodi/kodi.bin | grep -A1 "Build ID"`): 

**Symptom**
<!-- which of these? -->
- [ ] No `hevc_rkmpp` in log (software decode, high CPU)
- [ ] Decode stops after ~4 frames
- [ ] Picture frozen after seek/pause (audio continues)
- [ ] HDR picture dim/flat
- [ ] Flicker / artifacts on specific files (attach mediainfo/ffprobe of the file)
- [ ] Crash on movie open with `GL: Requested render method: 0` + `unsupported format 179` in the crashlog (check `videoplayer.useprimerenderer` is 0 — see JOURNAL §17)
- [ ] Other: 

**Evidence**
- `grep -a "using decoder" ~/.kodi/temp/kodi.log | tail -3`
- `python3 scripts/decode_blob.py` (while playing)
- `grep CmaTotal /proc/meminfo`
- dmesg excerpt if any `mpp`/`rkvdec` lines appear
