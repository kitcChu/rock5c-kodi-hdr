# Kodi Web "Restart" Button

One-click **Restart Kodi** button in the stock Kodi web UI — fixes the
"HDMI display didn't come up after the TV was unplugged" problem without
SSH. Kodi re-inits the GBM/DRM display surface on service restart.

## Why
When the TV is unplugged while Kodi runs, Kodi destroys its GBM window
(`DestroyWindow: deinitialized GBM`) and never re-creates it on hotplug.
Restarting the `kodi` service with the TV connected fixes it. This button
makes that one click instead of an SSH session.

## How it works
```
web button (index.html)
  └─ Addons.ExecuteAddon("script.restart-kodi")   [JSON-RPC]
       └─ addon default.py: sudo -n systemctl restart kodi
            └─ /etc/sudoers.d/kodi-restart (passwordless, scoped)
```

## Files
- `deploy.sh` — installs everything (sudoers, addon, web button) and
  restarts Kodi to register the addon
- `kodi-restart.sudoers` — `radxa ALL=(root) NOPASSWD: /usr/bin/systemctl restart kodi`
  (only that one command, no blanket sudo)
- `script.restart-kodi/` — executable addon; `default.py` fires the
  restart detached (`start_new_session=True`) so Kodi's shutdown can't
  abort the systemd transaction, and logs to `~/restart-kodi.log`
- Web button: patches `webinterface.default/index.html` (nav item +
  inline handler, idempotent; backed up to `index.html.bak`)

## Deploy
```bash
./deploy.sh [board-host]   # default radxa@192.168.80.54
```

## Use
Open `http://<board>:8080` (auth admin/admin123 on this install) → click
**Restart** in the nav → confirm → Kodi restarts, display re-inits (~35 s).

## Caveats
- `webinterface.default` lives under `/usr/share` — a Kodi upgrade may
  overwrite `index.html`; re-run `deploy.sh` (button patch is idempotent).
- Restart interrupts playback — that's the point (use when the display is
  dead). Confirm dialog in the UI warns you.
