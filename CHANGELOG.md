# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

Versioning tracks the packaged CEE release (`vX.Y.Z.W`) rather than
Semantic Versioning, because this repo packages and deploys a specific
Dell CEE build and the useful version to know is CEE's own.

## [Unreleased]

### Added

- Ansible deployment of CEE 9.2.0.0 to RHEL 9: `cee_preflight`,
  `cee_install`, `cee_configure` and `cee_verify` roles driven by
  `ansible/site.yml`
- Config rendered from `emc_cee_config.xml.j2`, with endpoint validation
  that rejects loopback addresses, bare hostnames and empty endpoint lists
- Localhost test suite (`ansible/tests/run.sh`) covering template
  rendering, endpoint validation and the platform gate — no VM required
- Installation from the publicly reachable UBI 9 repositories, so the CEE
  host does not need a Red Hat subscription
- `docs/ansible-deployment.md` — deployment procedure and troubleshooting
- `docs/powerstore-setup-runbook.md` — PowerStore Events Publishing setup
  and three-stage end-to-end verification
- Prerequisites documented for the first time: PowerStoreOS 4.1+, CEE 9.2
  minimum, genuine RHEL 9.x, time synchronisation, TCP 12228

### Fixed

- `<EndPoint>` now renders as `name@http://host:port`. The consumer-name
  prefix is mandatory per the Dell CEE guide and the Peer Software
  PowerStore guide; the previous bare URL was silently ignored by CEE
- README described the container base as Rocky Linux 9; it has been UBI9
  since `4cd8007`, because CEE rejects RHEL rebuilds

### Changed

- `cee-exporter` publishes its CEPA listener on host port 12229 (mapping
  to container 12228). CEE's inbound listener owns 12228, so this lets the
  CEE host and the Docker host be the same machine
- README restructured around two paths: Ansible on RHEL 9 (supported) and
  the container (lab sandbox, not a supported Dell configuration)

## [0.1.0] - 2026-08-06

### Added

- CEE 9.2.0.0 packaged as a container, published to GHCR on tagged
  releases
- Combined test stack (`docker-compose.test.yml`): cee-worker,
  cee-exporter, pstore_exporter, Prometheus, Grafana, and pstcli
