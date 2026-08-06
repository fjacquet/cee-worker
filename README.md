# cee-worker

Dell Common Event Enabler (CEE) packaged as a Docker container on Rocky Linux 9, for testing against a PowerStore environment. The rpm shipped in bin/ is CEE **9.2.0.0**.

## Quick start

    cp config/emc_cee_config.xml config/emc_cee_config.xml.bak  # optional, keep a copy
    docker compose up -d --build

CEE's HTTP endpoint is published on port 12228. Logs land in ./logs.

Note: the container's PID 1 is emc_cee.exe itself (no shell/`tail -F`
wrapper), so `docker logs` will not show CEE's own log content. Use
`docker exec <container> tail -f /opt/CEEPack/logs/emc_cee_svc.log`, or
read the files directly from the host-mounted ./logs directory.

## Pointing at a PowerStore target

Edit config/emc_cee_config.xml — set the relevant sub-facility's <Enabled>
to 1 and its <EndPoint> to the consumer application address(es), per the
CEE Linux guide (docs/cee-8-x-linux-guide_en-us.pdf). Then:

    docker compose restart cee

No rebuild needed for config-only changes.

> **Version note:** docs/cee-8-x-linux-guide_en-us.pdf covers the CEE 8.x
> line, but the rpm shipped here is CEE 9.2.0.0. Config semantics changed
> between the two lines — notably, 9.x introduced "secure defaults" where
> the HTTP server (`Security/Http/ServerEnabled`) is off unless explicitly
> enabled, which the 8.x guide's example config doesn't mention. Treat the
> 8.x guide as a general reference and cross-check anything config- or
> security-related against the 9.x release notes/guide if available,
> rather than assuming 8.x instructions apply verbatim.

## Security posture (lab/testing defaults)

The sample config makes two tradeoffs that are fine for a local/lab
container but should be revisited before exposing this beyond local
testing:

- `AccessListEnabled` is left at `0`, meaning any IP can post events to
  CEE's HTTP endpoint. Set it to `1` and populate `<AccessList>` with the
  allowed consumer addresses for anything beyond local testing.
- entrypoint.sh `chmod 777`s the mounted logs directory at container
  start (root, before dropping to the `ceesvc` user) so the CEE process
  can always write to it regardless of the host-side UID owning the
  `./logs` bind mount. Acceptable for a single log directory in a
  lab container, but worth knowing about.

## Upgrading CEE

1. Drop the new emc_cee_RHEL-<version>.x86_64.rpm into bin/ (remove the old
   one first — the Dockerfile globs bin/*.rpm and expects exactly one file).
2. docker compose build --no-cache
3. docker compose up -d

## Pulling from GHCR

    docker pull ghcr.io/<owner>/cee-worker:latest

Published on tagged releases (git tag vX.Y.Z.W && git push origin vX.Y.Z.W)
via .github/workflows/publish.yml, or manually via the Actions tab
(workflow_dispatch).

## Out of scope

RabbitMQ messaging (Unity/VNX-only, CEE <=8.8.2.1) and Splunk indexing
setup are not configured by default — see the config file's Index/VCAPS
sections and the linked guide if needed.
