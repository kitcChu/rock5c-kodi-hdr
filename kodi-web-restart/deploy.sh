#!/usr/bin/env bash
# Deploy the "Restart Kodi" web button to the Rock 5C.
# Usage: ./deploy.sh [board-host]   (default: radxa@192.168.80.54)
set -euo pipefail
BOARD="${1:-radxa@192.168.80.54}"
WEBUI=/usr/share/kodi/addons/webinterface.default/index.html

echo "== 1/4 sudoers drop-in (passwordless restart, scoped) =="
scp kodi-restart.sudoers "$BOARD":/tmp/
ssh "$BOARD" "sudo sh -c 'mv /tmp/kodi-restart.sudoers /etc/sudoers.d/kodi-restart && chown root:root /etc/sudoers.d/kodi-restart && chmod 440 /etc/sudoers.d/kodi-restart && visudo -c'"

echo "== 2/4 addon =="
scp -r script.restart-kodi "$BOARD":/tmp/
ssh "$BOARD" "sudo sh -c 'cp -r /tmp/script.restart-kodi /home/radxa/.kodi/addons/ && chown -R radxa:radxa /home/radxa/.kodi/addons/script.restart-kodi && rm -rf /tmp/script.restart-kodi'"

echo "== 3/4 web UI button (idempotent patch) =="
ssh "$BOARD" "sudo python3 - << 'PYEOF'
import pathlib
p = pathlib.Path('$WEBUI')
s = p.read_text()
if 'restartKodi' in s:
    print('button already present, skipping')
    raise SystemExit
nav = '          <li id=\"musicLibrary\">Music</li>\\n'
assert nav in s, 'unexpected web UI layout'
s = s.replace(nav, nav + '          <li id=\"restartKodi\">Restart</li>\\n')
btn = '''    <script type=\"text/javascript\">
      // Custom: Restart Kodi (re-inits HDMI display after TV unplug)
      document.getElementById('restartKodi').addEventListener('click', function () {
        if (confirm('Restart Kodi? Playback stops for ~30s; HDMI display re-inits.')) {
          xbmc.rpc.request({
            method: 'Addons.ExecuteAddon',
            params: { addonid: 'script.restart-kodi' }
          });
          alert('Restart triggered. Kodi will be back in ~30s.');
        }
      });
    </script>
  </body>'''
assert '</body>' in s
s = s.replace('</body>', btn)
p.write_text(s)
print('button added')
PYEOF"

echo "== 4/4 restart Kodi to register the addon =="
ssh "$BOARD" "sudo systemctl restart kodi && sleep 40 && systemctl is-active kodi"
echo "Done. Open http://<board>:8080 and click 'Restart'."
