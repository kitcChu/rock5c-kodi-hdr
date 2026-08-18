#!/bin/sh
# restore-patched-ffmpeg.sh — recover the rkmpp-enabled libavcodec after apt
# silently replaces it with stock (known recurring quirk, see JOURNAL §6/§16).
#
# The patched debs live on the NAS backup share (/mnt/backups). If that mount
# is down, fall back to the local copy in ~/ffmpeg-src/.
set -e

DEB_NAME=libavcodec-extra59_5.1.9-0+deb12u1_arm64.deb
WORK=$(mktemp -d)

find_deb() {
  # $1 = base dir; prints the deb path if found
  [ -f "$1/$DEB_NAME" ] && echo "$1/$DEB_NAME" && return 0
  local LATEST=$(ls -t $1/rock5c-core-*.tar.gz 2>/dev/null | head -1)
  if [ -n "$LATEST" ] && tar tzf "$LATEST" 2>/dev/null | grep -q "$DEB_NAME"; then
    tar xzf "$LATEST" -C "$WORK" "home/radxa/ffmpeg-src/$DEB_NAME" 2>/dev/null
    echo "$WORK/home/radxa/ffmpeg-src/$DEB_NAME"
    return 0
  fi
  return 1
}

DEB=""
for base in /mnt/backups /home/radxa/ffmpeg-src; do
  if DEB=$(find_deb "$base"); then
    echo "found patched deb: $DEB"
    break
  fi
done

[ -n "$DEB" ] || { echo "ERROR: patched deb not found (NAS down?)"; exit 1; }

echo "checking current lib..."
if strings /usr/lib/aarch64-linux-gnu/libavcodec.so.59.37.100 2>/dev/null | grep -q "RKMPP decoder initialized"; then
  echo "rkmpp already present — nothing to do"
  rm -rf "$WORK"
  exit 0
fi

echo "installing patched libavcodec-extra59..."
dpkg -i "$DEB"

echo "re-applying holds (the FULL set)..."
apt-mark hold ffmpeg libavcodec59 libavcodec-extra59 libavdevice59 \
  libavfilter8 libavformat59 libavutil57 libpostproc56 libswresample4 libswscale6 || true

echo "verifying..."
if strings /usr/lib/aarch64-linux-gnu/libavcodec.so.59.37.100 2>/dev/null | grep -q "RKMPP decoder initialized"; then
  echo "OK: rkmpp restored. Restart kodi to apply: sudo systemctl restart kodi"
else
  echo "WARNING: rkmpp still missing — check manually"
fi
rm -rf "$WORK"
