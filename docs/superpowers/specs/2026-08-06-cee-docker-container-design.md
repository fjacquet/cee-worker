# CEE Docker Container — Design

Date: 2026-08-06

## Goal

Package Dell Common Event Enabler (CEE) 8.x for Linux (`emc_cee_RHEL-*.x86_64.rpm`) into a Docker container running Rocky Linux 9, so the framework can be spun up, upgraded, and pointed at a PowerStore test environment quickly and repeatably.

## Background

CEE is installed via `rpm -i emc_cee_RHEL-<version>.x86_64.rpm`, per `docs/cee-8-x-linux-guide_en-us.pdf`. Installation defaults to `/opt/CEEPack`. Behavior (which CEPA sub-facilities are active, which PowerStore/consumer endpoints it talks to) is controlled entirely by `/opt/CEEPack/emc_cee_config.xml`. The service is managed with `emc_cee_svc {start|stop|restart}` and listens on `HttpPort` (default `12228`).

Doc's stated system requirements list "Red Hat Enterprise version 7.x and higher, 64-bit" — Rocky Linux 9 is a RHEL-compatible rebuild, satisfying this.

## Architecture

```
bin/emc_cee_RHEL-*.x86_64.rpm  --COPY-->  Dockerfile (rockylinux:9) --> image
config/emc_cee_config.xml      --bind mount at runtime--> /opt/CEEPack/emc_cee_config.xml
logs volume                    --bind/named volume-->      /opt/CEEPack/ log path
```

### Dockerfile

- `FROM rockylinux:9`
- Install rpm's runtime dependencies (resolved via `rpm -qpR` against the shipped rpm at build time; expect standard glibc/initscripts-class packages, no exotic deps per doc)
- `COPY bin/emc_cee_RHEL-*.x86_64.rpm /tmp/`
- `RUN rpm -i /tmp/emc_cee_RHEL-*.x86_64.rpm && rm -f /tmp/*.rpm`
- `EXPOSE 12228`
- `COPY entrypoint.sh /entrypoint.sh`
- `ENTRYPOINT ["/entrypoint.sh"]`

### entrypoint.sh

Runs in foreground so the container stays alive as a long-lived daemon:

```sh
#!/bin/sh
set -e
emc_cee_svc start
tail -F /opt/CEEPack/*.log
```

`emc_cee_svc start` backgrounds the actual CEE daemon (per doc, it's a service-style command, not foreground); `tail -F` on the log path keeps PID 1 alive and surfaces CEE's own logging through `docker logs`. Exact log filename to confirm once package installed and inspected (doc only specifies `<LogFile><Path>` config, default `/opt/CEEPack/`).

### Configuration

`emc_cee_config.xml` is **not baked into the image**. It's bind-mounted at container start from `./config/emc_cee_config.xml` on the host into `/opt/CEEPack/emc_cee_config.xml`, so switching which PowerStore environment (or which CEPA sub-facilities: Audit, CQM, CARA, Index, VCAPS) is under test only requires editing the host file and restarting the container — no rebuild.

Repo ships one sample config (`config/emc_cee_config.xml`) based on the doc's defaults (all sub-facilities disabled) as a starting point to copy and edit per target PowerStore.

### docker-compose.yml

```yaml
services:
  cee:
    build: .
    image: cee-worker:local
    ports:
      - "12228:12228"
    volumes:
      - ./config/emc_cee_config.xml:/opt/CEEPack/emc_cee_config.xml
      - ./logs:/opt/CEEPack/logs
    restart: unless-stopped
```

(Log volume path to confirm/adjust once the installed layout is inspected — doc's default `LogFile Path` is `/opt/CEEPack/`, so logs may live alongside the install rather than in a dedicated subdir; entrypoint and compose volume should agree on the same actual path.)

## Upgrade workflow

1. Drop new `emc_cee_RHEL-<version>.x86_64.rpm` into `bin/` (only one rpm should be present at build time — the Dockerfile globs `bin/*.rpm`).
2. `docker compose build --no-cache`
3. `docker compose up -d`

Config/endpoint changes for testing different PowerStore targets never require a rebuild — only a config edit + `docker compose restart cee`.

## GHCR publish

GitHub Actions workflow `.github/workflows/publish.yml`:

- Triggers: `push` on tags matching `v*`, and `workflow_dispatch` for manual runs.
- Steps: checkout → `docker/login-action` against `ghcr.io` using `GITHUB_TOKEN` → `docker/build-push-action` building from the same `Dockerfile`.
- Tags pushed: `ghcr.io/<owner>/cee-worker:<git-tag>` and `ghcr.io/<owner>/cee-worker:latest`.
- Repo and resulting GHCR package are public. Note: this republishes Dell's proprietary rpm baked into the image layer — accepted tradeoff per explicit choice, not revisited here.
- Local `bin/` + `docker compose build` remains the primary loop for iterating on new rpm drops; GHCR exists to pull a pinned released version elsewhere without rebuilding from source.

## Out of scope

- RabbitMQ messaging setup (CEE for RabbitMQ, doc chapter 7) — only supported for Dell Unity/VNX on CEE ≤8.8.2.1, not relevant to PowerStore testing.
- Splunk indexing setup (doc chapter 8) — not requested; config file supports it if needed later, unconfigured by default.
- TLS/cert handling for CEE's HTTP endpoint — not covered by the doc beyond the AccessList IP allowlist; out of scope unless a real need surfaces during testing.

## Testing

- `docker compose up -d`, confirm container stays running (`docker ps`), confirm `emc_cee_svc` process alive inside container.
- Confirm port 12228 reachable from host.
- Point a sample config's `EndPoint` at a reachable test HTTP listener, confirm CEE attempts delivery (visible in mounted logs).
- Confirm `docker compose build` succeeds cleanly picking up rpm from `bin/`.
- Confirm GHCR workflow builds and pushes on a test tag (dry run acceptable if no real release yet).

---

## Correction — 2026-08-08

This spec stated that "Rocky Linux 9 is a RHEL-compatible rebuild,
satisfying this". That is false. CEE reads `/etc/redhat-release` and
self-terminates with "Platform is not supported / qualified" unless it
sees the literal Red Hat string, so ABI compatibility is not sufficient.
The container base moved to `registry.access.redhat.com/ubi9/ubi` in
commit `4cd8007`.

The containerized approach did not reach a working event path. CEE is now
deployed to a RHEL 9 VM via Ansible; see
`docs/superpowers/specs/2026-08-08-cee-ansible-deployment-design.md`. The
container remains as a lab sandbox and is not a supported configuration.

This note is appended rather than edited in place: the spec recorded a
belief that testing disproved, and that record is the useful part.
