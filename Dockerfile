
# Must be genuine RHEL, not a rebuild: CEE's own binary reads
# /etc/redhat-release and self-terminates ("Platform is not supported /
# qualified") unless it sees the literal Red Hat string. Rocky Linux
# reports "Rocky Linux release X.Y" there and fails the check even though
# it's ABI-compatible. UBI9 is Red Hat's own base image, so the string is
# real, not spoofed.
FROM registry.access.redhat.com/ubi9/ubi

COPY bin/emc_cee_RHEL-*.x86_64.rpm /tmp/
RUN rpm -i /tmp/*.rpm && rm -f /tmp/*.rpm

# Belt-and-suspenders: sets image-baked ownership for the case where the
# container is run without the ./logs bind mount from docker-compose.yml.
# When the bind mount IS used, entrypoint.sh re-creates/chmods this
# directory at container start since the mount replaces this layer's
# ownership with the host directory's ownership.
RUN mkdir -p /opt/CEEPack/logs && chown ceesvc:ceesvc /opt/CEEPack/logs

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Convenience for ad-hoc `docker exec` sessions opened without their own
# `cd`; entrypoint.sh's own `cd /opt/CEEPack` is what actually matters
# for CEE's relative config-file lookup at runtime.
WORKDIR /opt/CEEPack

EXPOSE 12228

ENTRYPOINT ["/entrypoint.sh"]
