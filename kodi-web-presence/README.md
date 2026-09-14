# Kodi Web "Presence" Toggle

On/off switch for the room-presence agent in the stock Kodi web UI.
**Off by default** — enable it only when you want playback to pause
automatically when nobody is in the room.

## Why an option
The HKL-LD2450's returns are sparse at range (it may only see you reliably
within ~1 m), so with a short empty-debounce the agent can pause while you
are still sitting there. Until the tuning is settled (see JOURNAL §34),
the feature ships disabled and is toggled per-need.

## How it works
```
web button (index.html)
  └─ Addons.ExecuteAddon("script.presence-toggle")     [JSON-RPC]
       ├─ systemctl is-active presence-agent
       ├─ start  -> notify("ON  - pauses playback when the room is empty")
       └─ stop   -> notify("OFF - playback will not be paused")
            └─ and resumes playback if the agent had paused it
```
- `presence-toggle.sudoers` — passwordless start/stop/is-active of just
  `presence-agent.service`
- Turning it OFF releases playback if `/run/presence-agent.paused` says the
  agent paused it, so disabling can never strand audio paused
- Feedback: a Kodi on-screen notification shows the resulting state

## Deploy
```bash
./deploy.sh [board-host]      # default radxa@192.168.80.54
```
Disables the service, installs the addon + sudoers, patches the web UI
(idempotent) and restarts Kodi to register the addon.

## Use
`http://<board>:8080` → click **Presence** in the nav → confirm.
