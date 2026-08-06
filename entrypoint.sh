#!/bin/sh
set -e

# Re-create the logs directory in case the docker-compose bind mount
# replaced it with a fresh, host-owned directory (see docker-compose.yml).
# chmod 777 is a deliberate posture for this lab/testing container: we
# can't know the CEE service UID (dynamically allocated by the rpm's
# useradd -r) or the host UID at compose-author time, so the simplest
# robust fix is to make the single log directory world-writable rather
# than try to match UIDs. This runs as root, before setpriv drops
# privileges below.
mkdir -p /opt/CEEPack/logs
chmod 777 /opt/CEEPack/logs

# exec so emc_cee.exe becomes PID 1 and receives SIGTERM directly from
# `docker compose stop` / `docker stop`, instead of being orphaned behind
# a shell and hard-killed after the grace period. setpriv (util-linux)
# drops privileges to ceesvc without the extra process/session semantics
# of su. -logfile surfaces CEE's own startup/crash log under the mounted
# ./logs directory.
#
# Known tradeoff: this replaces the shell, so there's no more `tail -F`
# forwarding CEE's log to `docker logs`. Use
# `docker exec <container> tail -f /opt/CEEPack/logs/emc_cee_svc.log`
# or the host-mounted ./logs directory instead.
exec setpriv --reuid=ceesvc --regid=ceesvc --clear-groups \
    env LD_LIBRARY_PATH=/opt/CEEPack \
    /opt/CEEPack/emc_cee.exe -logfile /opt/CEEPack/logs/emc_cee_svc.log
