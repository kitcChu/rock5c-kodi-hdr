#!/usr/bin/env bash
# Deploy the "Presence" on/off toggle to the Kodi web UI.
#
# Usage: ./deploy.sh [board-host]
#        SKIP_KODI_RESTART=1 ./deploy.sh [board-host]   # don't interrupt playback
#
# The new addon is only registered when Kodi rescans addons (i.e. restarts).
# With SKIP_KODI_RESTART=1 the web button appears immediately but returns an
# error until Kodi is restarted — press the existing "Restart" button in the
# web UI when nothing is playing.
set -euo pipefail
BOARD="${1:-radxa@192.168.80.54}"
WEBUI=/usr/share/kodi/addons/webinterface.default/index.html
# Remote privilege escalation. Default assumes passwordless sudo (key auth).
# For a password-based board run:  REMOTE_SUDO='echo PW | sudo -S' ./deploy.sh
REMOTE_SUDO="${REMOTE_SUDO:-sudo -n}"

echo "== 1/5 presence agent: stop + disable (default OFF) =="
ssh "$BOARD" "$REMOTE_SUDO sh -c 'systemctl stop presence-agent 2>/dev/null || true; systemctl disable presence-agent 2>/dev/null || true'"

echo "== 2/5 sudoers drop-in (scoped to presence-agent) =="
scp presence-toggle.sudoers "$BOARD":/tmp/
ssh "$BOARD" "$REMOTE_SUDO sh -c 'mv /tmp/presence-toggle.sudoers /etc/sudoers.d/presence-toggle && chown root:root /etc/sudoers.d/presence-toggle && chmod 440 /etc/sudoers.d/presence-toggle && visudo -c' | tail -1"

echo "== 3/5 addon =="
scp -r script.presence-toggle "$BOARD":/tmp/
ssh "$BOARD" "$REMOTE_SUDO sh -c 'rm -rf /home/radxa/.kodi/addons/script.presence-toggle && cp -r /tmp/script.presence-toggle /home/radxa/.kodi/addons/ && chown -R radxa:radxa /home/radxa/.kodi/addons/script.presence-toggle && rm -rf /tmp/script.presence-toggle'"

echo "== 4/5 web UI button (idempotent) =="
ssh "$BOARD" "$REMOTE_SUDO python3 - '${WEBUI}' << 'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if 'presenceToggle' in s:
    print('presence button already present')
    raise SystemExit
anchor = '<li id=\"restartKodi\">Restart</li>'
if anchor in s:
    s = s.replace(anchor, anchor + '\n          <li id=\"presenceToggle\">Presence</li>')
else:
    s = s.replace('          <li id=\"musicLibrary\">Music</li>',
                  '          <li id=\"musicLibrary\">Music</li>\n          <li id=\"presenceToggle\">Presence</li>')
js = '''    <script type=\"text/javascript\">
      // Custom: toggle the room-presence agent (off by default)
      document.getElementById('presenceToggle').addEventListener('click', function () {
        if (confirm('Toggle the Presence agent?\\n\\nON: pause playback when the room is empty\\nOFF: never touch playback')) {
          xbmc.rpc.request({
            method: 'Addons.ExecuteAddon',
            params: { addonid: 'script.presence-toggle' }
          });
          alert('Presence toggled - check the TV notification for ON/OFF.');
        }
      });
    </script>
  </body>'''
s = s.replace('</body>', js)
p.write_text(s)
print('presence button added')
PYEOF"

if [ "${SKIP_KODI_RESTART:-0}" = "1" ]; then
  echo "== 5/5 Kodi restart SKIPPED (SKIP_KODI_RESTART=1) =="
  echo "Button is live, but the addon registers only after a Kodi restart"
  echo "(press 'Restart' in the web UI when nothing is playing)."
else
  echo "== 5/5 restart Kodi to register the addon =="
  ssh "$BOARD" "$REMOTE_SUDO sh -c 'systemctl restart kodi && sleep 40 && systemctl is-active kodi'"
fi
