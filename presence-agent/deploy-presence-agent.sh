#!/bin/sh
# deploy-presence-agent.sh — install + enable the presence agent on the Rock 5C.
# Run as root on the board (sudo).
set -e

SRC=/usr/local/bin/presence-agent
mkdir -p "$SRC"
cp "$(dirname "$0")/radar_reader.py" "$SRC/"
cp "$(dirname "$0")/presence_agent.py" "$SRC/"
chmod +x "$SRC"/*.py

cp "$(dirname "$0")/presence-agent.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable presence-agent.service
systemctl restart presence-agent.service
systemctl --no-pager status presence-agent.service | head -5
echo "--- first frames (10s) ---"
timeout 10 journalctl -u presence-agent -f --no-pager 2>/dev/null | head -12 || true
