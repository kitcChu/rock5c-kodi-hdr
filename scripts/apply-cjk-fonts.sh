#!/bin/sh
# apply-cjk-fonts.sh — make Kodi's GUI render CJK (Hong Kong variant).
#
# Root cause: Kodi's Estuary skin "Default" fontset loads NotoSans-Regular.ttf /
# NotoSans-Bold.ttf / Roboto-Thin.ttf (Latin-only) from the skin fonts dir.
# The old fix replaced media/Fonts/arial.ttf, which the Default fontset never uses.
#
# Fix: extract the HK face from the system Noto Sans CJK TTC and install as real
# files (not symlinks) into the skin fonts dir. Run again after any kodi upgrade.
set -e

SKIN=/usr/share/kodi/addons/skin.estuary/fonts
TTC_R=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
TTC_B=/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc
WORK=$(mktemp -d)

echo "[1/4] extracting Noto Sans CJK HK faces from system TTC..."
python3 - "$WORK" << 'EOF'
import sys
from fontTools.ttLib import TTCollection
w = sys.argv[1]
TTCollection("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc").fonts[4].save(w + "/hk-regular.ttf")
TTCollection("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc").fonts[4].save(w + "/hk-bold.ttf")
print("  done")
EOF

echo "[2/4] backing up originals (only if not already backed up)..."
for f in NotoSans-Regular.ttf NotoSans-Bold.ttf Roboto-Thin.ttf; do
  [ -e "$SKIN/$f.latin-orig" ] || cp -a "$SKIN/$f" "$SKIN/$f.latin-orig"
done

echo "[3/4] installing HK fonts as real files (replacing symlinks)..."
rm -f "$SKIN/NotoSans-Regular.ttf" "$SKIN/NotoSans-Bold.ttf" "$SKIN/Roboto-Thin.ttf"
cp "$WORK/hk-regular.ttf" "$SKIN/NotoSans-Regular.ttf"
cp "$WORK/hk-bold.ttf"    "$SKIN/NotoSans-Bold.ttf"
cp "$WORK/hk-regular.ttf" "$SKIN/Roboto-Thin.ttf"
chmod 644 "$SKIN/NotoSans-Regular.ttf" "$SKIN/NotoSans-Bold.ttf" "$SKIN/Roboto-Thin.ttf"

echo "[4/4] verifying..."
for f in NotoSans-Regular.ttf NotoSans-Bold.ttf Roboto-Thin.ttf; do
  echo -n "  $f: "; fc-scan --format "%{family}\n" "$SKIN/$f" 2>/dev/null
done

rm -rf "$WORK"
echo "DONE. Restart kodi to apply: sudo systemctl restart kodi"
