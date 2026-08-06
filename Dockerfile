FROM rockylinux/rockylinux:9

COPY bin/*.rpm /tmp/
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
