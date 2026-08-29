"""Fire-and-forget restart of the kodi service.

Invoked via Addons.ExecuteAddon from the web UI button. Detaches into a new
session so Kodi's shutdown (which kills addon processes) cannot abort the
systemd transaction; systemctl restart completes stop+start regardless.
"""
import datetime
import subprocess

LOG = "/home/radxa/restart-kodi.log"

with open(LOG, "a") as f:
    f.write("%s: restart requested\n" % datetime.datetime.now().strftime("%F %T"))

subprocess.Popen(
    ["sudo", "-n", "systemctl", "restart", "kodi"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,  # new session => immune to kodi's group kill
)
