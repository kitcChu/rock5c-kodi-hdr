#!/bin/sh
# Wait until Kodi has no active player (twice, 60s apart), then install
# the HDR-metadata ffmpeg build and restart kodi. Logs to /tmp/hdr_install.log.
LOG=/tmp/hdr_install.log
idle_count=0
echo "$(date) waiter started" >> $LOG
while [ $idle_count -lt 2 ]; do
    sleep 60
    PLAYERS=$(timeout 6 python3 -c "
import socket, json, time
try:
    s = socket.create_connection(('127.0.0.1', 9090), timeout=4)
    s.sendall((json.dumps({'jsonrpc':'2.0','method':'Player.GetActivePlayers','id':1})+'\n').encode())
    time.sleep(1)
    print(len(json.loads(s.recv(400).decode().split(chr(10))[0])['result']))
    s.close()
except Exception:
    print(1)  # treat errors as playing (safe)" 2>/dev/null)
    [ -z "$PLAYERS" ] && PLAYERS=1
    if [ "$PLAYERS" = "0" ]; then
        idle_count=$((idle_count+1))
        echo "$(date) idle $idle_count/2" >> $LOG
    else
        idle_count=0
    fi
done
echo "$(date) movie finished - installing" >> $LOG
systemctl stop kodi
sleep 3
cd /home/radxa/ffmpeg-src
dpkg -i libavcodec59_5.1.9-0+deb12u1_arm64.deb \
        libavcodec-extra59_5.1.9-0+deb12u1_arm64.deb \
        libavutil57_5.1.9-0+deb12u1_arm64.deb \
        libswresample4_5.1.9-0+deb12u1_arm64.deb \
        libavformat59_5.1.9-0+deb12u1_arm64.deb >> $LOG 2>&1
sleep 2
systemctl start kodi
echo "$(date) install done, kodi restarted" >> $LOG
