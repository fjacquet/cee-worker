#!/bin/sh
set -e

cd /opt/CEEPack
export LD_LIBRARY_PATH="/opt/CEEPack:$LD_LIBRARY_PATH"

su ceesvc -s /bin/sh -c "cd /opt/CEEPack && LD_LIBRARY_PATH=/opt/CEEPack /opt/CEEPack/emc_cee.exe" &
CEE_PID=$!

LOG_GLOB="/opt/CEEPack/*.log"
for i in $(seq 1 30); do
  if ls $LOG_GLOB >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ls $LOG_GLOB >/dev/null 2>&1; then
  tail -F $LOG_GLOB &
fi

wait $CEE_PID
