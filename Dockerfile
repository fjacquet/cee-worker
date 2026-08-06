FROM rockylinux:9

RUN dnf install -y \
    initscripts \
    glibc \
    && dnf clean all

COPY bin/*.rpm /tmp/
RUN rpm -i /tmp/*.rpm && rm -f /tmp/*.rpm

RUN mkdir -p /opt/CEEPack/logs && chown 998:998 /opt/CEEPack/logs

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 12228

ENTRYPOINT ["/entrypoint.sh"]
