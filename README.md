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

## Combined test stack (cee + cee-exporter + pstore_exporter + grafana + pstcli)

`docker-compose.test.yml` is a separate stack from the one above: it pulls
published GHCR images (no local builds) for `cee-worker`, `cee-exporter`,
and `pstore_exporter`, wires them to one Prometheus + Grafana, and adds
`pstcli` as an on-demand profile. Design: `docs/superpowers/specs/2026-08-07-test-stack-design.md`.

Requires `../pstore_exporter` checked out as a sibling directory (Grafana's
bundled dashboards are mounted from there, not copied).

    cp .env.test.example .env
    # edit .env: GHCR_OWNER, PSTORE1_HOSTNAME/USERNAME/PASSWORD
    docker compose -f docker-compose.test.yml up -d

Services: `cee` (12228), `cee-exporter` (9228, metrics only — its 12228 CEPA
listener stays internal), `pstore_exporter` (9446), `prometheus` (9090),
`grafana` (3000, admin/admin).

To test the CEE → cee-exporter forward path, set one sub-facility's
`<EndPoint>` in `config/emc_cee_config.xml` to `http://cee-exporter:12228`
and `docker compose -f docker-compose.test.yml restart cee`.

Run the CLI (one-shot, not a long-running service):

    docker compose -f docker-compose.test.yml run --rm pstcli -version
    docker compose -f docker-compose.test.yml run --rm pstcli -d 10.0.0.10 -u admin cluster show

`state/` holds pstcli's saved creds/certs — gitignored, keep off shared
machines.

Known gap: no Grafana dashboard yet for `cee-exporter` metrics — Prometheus
scrape only, browse via its UI or `/metrics` directly.

## Out of scope

RabbitMQ messaging (Unity/VNX-only, CEE <=8.8.2.1) and Splunk indexing
setup are not configured by default — see the config file's Index/VCAPS
sections and the linked guide if needed.
