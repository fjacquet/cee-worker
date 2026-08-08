# CEE Ansible Deployment + PowerStore Runbook — Design

Date: 2026-08-08
Status: approved

## Problem

CEE 9.2.0.0 packaged as a container (`docs/superpowers/specs/2026-08-06-cee-docker-container-design.md`)
has not produced a working event path. `logs/` is empty — CEE never logged a run.
Five consecutive commits (`a99640a`..`1ab1ec7`) fought base-image and networking
symptoms without reaching a working end-to-end flow.

The container fights the product in three ways, all evidenced in-tree:

1. CEE reads `/etc/redhat-release` and self-terminates on RHEL rebuilds, forcing
   the UBI9 base switch (`4cd8007`).
2. The rpm ships a systemd unit. `entrypoint.sh` hand-reimplements
   `WorkingDirectory`, privilege drop, and log redirection; the config's
   `<WatchDog>` block assumes a service manager that is absent.
3. The Peer Software guide forbids loopback between CEE and its consumer. Compose
   networking collided with this repeatedly (`bf69498`, `2ba6f7c`, `1ab1ec7`).

Dell supports CEE on a RHEL VM or bare metal. The container is an unsupported
configuration with no escalation path.

## Sources

Two external references were read and cross-checked against the bundled Dell guide:

- Peer Software, *Dell PowerStore Configuration Guide* — PowerStore-side Events
  Publishing procedure, CEE prerequisites, post-event selection.
- Netwrix Activity Monitor, *Install CEE* — mostly legacy Celerra/VNX
  (`cepp.conf`, `msrpcuser=`). Applies to PowerStore only for its note that VCAPS
  async bulk delivery wants the latest CEE.
- `docs/cee-8-x-linux-guide_en-us.pdf` — authoritative on config schema.

Three findings drive this design:

**EndPoint requires a consumer-name prefix.** The Dell guide (line 284) shows
`auditpartner@http://10.2.3.4:8050;auditpartner@1.2.3.5:8080`. The Peer guide
independently shows `PeerSoftwareCollector@http://<Agent_IP>:9843`. The repo's
`config/emc_cee_config.xml` has a bare `http://cee-exporter:12228` — no prefix.

**Endpoint ordering is load-bearing.** Per the Dell guide: CEE monitors the state
of the first partner in the list to decide whether to publish at all. If the first
partner is unavailable, events reach none of the subsequent partners, and the
first partner's availability also governs whether events are re-sent later.

**12228 is CEE's inbound port.** Dell guide line 709: the information source
sending events to CEE must target 12228. `<EndPoint>` is the separate outbound hop
to the consumer.

## Prerequisites

Not previously recorded anywhere in this repo:

- PowerStoreOS 4.1 or later
- CEE 9.2 minimum (bundled rpm is 9.2.0.0)
- Genuine RHEL 9.x on the CEE host — rebuilds such as Rocky are rejected by CEE
- Time synchronised across PowerStore, CEE host, and consumer
- SMB configured on PowerStore; NFS optional
- Port 12228 reachable from PowerStore to the CEE host

## Architecture

```
PowerStore NAS server
   │  CEPA events, HTTP POST
   ▼
CEE  (RHEL 9 VM, systemd emc_cee, :12228 inbound)   ← Ansible manages this
   │  <EndPoint>ceeexporter@http://<docker-host>:12229
   ▼
cee-exporter (container, :12228 internal → :12229 host, metrics :9228)
   │
   ├─► evtx / GELF output
   └─► Prometheus :9090 ──► Grafana :3000
```

Hybrid by design. CEE moves to a VM because it resists containerization. The
observability stack stays containerized because it containerizes cleanly and is
first-party code.

### Port allocation

`docker-compose.test.yml` currently publishes no CEPA port for `cee-exporter` —
its 12228 listener is reachable only on the compose network, because the `cee`
service already claims host 12228. With CEE moving to a VM, the exporter's
listener must become reachable from off-host, so a `12229:12228` mapping is added
rather than `12228:12228`.

CEE's inbound listener owns 12228 by specification. Publishing the exporter on
host 12228 would mean the CEE host and the Docker host can never be the same
machine — the collision worked around in `2ba6f7c` and `1ab1ec7`. The
container-internal port stays 12228, so `cee-exporter-config.toml` is unchanged.

### Endpoint addressing

`<EndPoint>` always names a routable IP or FQDN. Never `127.0.0.1` — the Peer
guide forbids loopback for co-hosted CEE and consumer. Never a compose service
name — CEE on a VM cannot resolve compose-internal DNS.

## Ansible layout

```
ansible/
  site.yml
  inventory/hosts.yml.example
  group_vars/all.yml.example      # committed; real vars gitignored
  roles/
    cee_preflight/tasks/main.yml
    cee_install/tasks/main.yml
    cee_configure/
      tasks/main.yml
      templates/emc_cee_config.xml.j2
      handlers/main.yml
    cee_verify/tasks/main.yml
```

| Role | Responsibility | Depends on |
|---|---|---|
| `cee_preflight` | Assert `/etc/redhat-release` is genuine Red Hat, chrony synced, 12228 free | — |
| `cee_install` | Add UBI repos, install the bundled rpm, verify `/opt/CEEPack` | preflight |
| `cee_configure` | Render `emc_cee_config.xml`, enable + restart the systemd unit | install |
| `cee_verify` | Service active, port listening, log free of fatal strings | configure |

`cee_verify` is a distinct role because the container's failure mode was silent:
empty logs, no signal, no diagnosis. Verification is a first-class step here.

The rpm is not duplicated. `cee_install` copies from the existing `bin/` at repo
root, so the container and the playbook consume one artifact and the documented
upgrade procedure stays a single "drop the new rpm in `bin/`" step for both paths.

### Unentitled host

The target RHEL 9 VM has no active Red Hat subscription, so `dnf install <rpm>`
cannot resolve dependencies from Red Hat repos. The Dockerfile installs the same
rpm on stock UBI9 successfully, which establishes that the UBI base package set
satisfies its dependencies. `cee_install` therefore configures the freely
reachable `ubi-9-baseos-rpms` and `ubi-9-appstream-rpms` repos as the dependency
source. If the dependency set later exceeds UBI's contents, the failure surfaces
at install time as an explicit unresolved-dependency error, not a silent
misconfiguration.

## Configuration

`config/emc_cee_config.xml` becomes the container's config only. The playbook
renders its own from `emc_cee_config.xml.j2`. Two consumers share one schema but
no mutable file, so editing the container's lab config cannot silently change what
the VM receives.

`group_vars/all.yml`:

```yaml
cee_http_port: 12228
cee_consumer_name: ceeexporter        # the mandatory name@ prefix
cee_consumer_host: 10.x.x.x           # routable IP/FQDN, never loopback
cee_consumer_port: 12229
cee_access_list_enabled: 1            # 1 on the VM; container lab stays 0
cee_access_list:                      # PowerStore NAS server IPs
  - 10.x.x.x
cee_facilities:
  audit: true
  cqm: false
  backup: false
  cara: false
  index: false
  vcaps: false
```

`cee_access_list_enabled` defaults to `1`, departing from both the container and
the Peer guide, which use `0`. The guide's `0` is a troubleshooting
simplification; a VM on a production network should not accept events from
arbitrary sources. If it blocks bring-up, setting it to `0` is a one-variable
change, and the runbook says so.

`cee_facilities` is a typed map rather than free-form XML so the template can
assert that exactly one sub-facility is enabled. Audit is the synchronous
real-time path cee-exporter speaks. VCAPS is asynchronous bulk delivery and would
require exporter-side work first.

The template renders the endpoint as a list to preserve the Dell guide's
semicolon-separated multi-consumer form, with a comment recording that the first
entry gates delivery to all others. One consumer today; the structure does not
foreclose more.

`cee_configure` notifies a handler that restarts `emc_cee`. Rendering is
idempotent, so a restart fires only on an actual config diff.

## PowerStore configuration

Manual for now, documented in `docs/powerstore-setup-runbook.md`. The
`dellemc.powerstore` Ansible collection has 46 modules and none covers Events
Publishing, CEPA, or publishing pools, so automation would require
`ansible.builtin.uri` against the REST API. Dell's published API spec is
auth-gated, so the exact resource path must be introspected from a live array.
That is deferred to a follow-up rather than blocking this work.

Runbook procedure, in order:

1. Enable Events Publishing on the NAS server (Security & Events → Events Publishing).
2. Create an Events Publisher, or modify the existing one.
3. Create a Publishing Pool. Add the CEE VM's IP or FQDN to the Event Publishing
   (CEPA) Server list.
4. Post-Events: select all, then uncheck `CloseDir`, `OpenDir`, `FileRead`,
   `OpenFileReadOffline`, `OpenFileWriteOffline`.
5. Pre-Events and Post-Error-Events: leave unchecked.
6. For each filesystem to monitor: Security & Events tab → enable Events
   Publishing → select SMB, NFS, or both → apply.

## Verification

Three stages, ordered so a failure localises to one leg:

1. `cee_verify` asserts `systemctl is-active emc_cee`, port 12228 listening, and
   the CEE log free of `Platform is not supported`.
2. POST a synthetic CEPA event to the CEE host's 12228 and confirm cee-exporter's
   `/metrics` event counter increments. This isolates the CEE → exporter leg.
3. Touch a file on a monitored PowerStore filesystem and confirm the event reaches
   cee-exporter's evtx output. This exercises the PowerStore → CEE leg.

Stage 2 is the decomposition missing today: it distinguishes a broken forward hop
from a broken PowerStore publisher.

## Error handling

`cee_preflight` fails loudly naming the specific unmet condition rather than
letting CEE start and die silently — the precise failure mode that made the
container hard to diagnose. Every role is idempotent, so rerunning after a fix
converges rather than stacking state.

## Documentation

Existing documentation is wrong in four places and is corrected as part of this
work:

| Location | Currently says | Correction |
|---|---|---|
| `README.md` | "Docker container on Rocky Linux 9" | UBI9 since `4cd8007` |
| spec `2026-08-06` | "Rocky Linux 9 is a RHEL-compatible rebuild, satisfying this" | False — CEE rejects it |
| `README.md` | EndPoint `http://cee-exporter:12228` | Missing mandatory `name@` prefix |
| all | — | Prerequisites section absent |

The 2026-08-06 spec receives an appended correction note rather than a silent
edit. It recorded a belief that testing disproved, and that record is the useful
part.

New and changed documents:

- `docs/powerstore-setup-runbook.md` — the manual PowerStore procedure above,
  ending with the three-stage verification.
- `docs/ansible-deployment.md` — inventory, variables, `ansible-playbook site.yml`,
  and what each role asserts.
- `CHANGELOG.md` — Keep a Changelog format, matching the `cee-exporter` and
  `pstore_exporter` siblings. Seeded with an `[Unreleased]` entry for this work and
  a `[0.1.0]` retrospective entry for the existing container.
- `README.md` — restructured around two paths: Ansible on a RHEL 9 VM (supported,
  PowerStore-facing) and the container (lab sandbox, unsupported by Dell), with
  the reason stated rather than implied.

### Versioning

The README tags releases `vX.Y.Z.W`, tracking CEE's four-part version rather than
SemVer. The sibling repos' changelogs claim SemVer adherence. This repo keeps the
CEE-tracking scheme, which is more useful for a packaging repo, and states that
explicitly in the changelog header instead of claiming an adherence it does not
follow.

## Scope

In scope: the Ansible roles, the config template, the PowerStore runbook, the
compose port change, the changelog, and the documentation corrections above.

Out of scope, deliberately:

- REST automation of the PowerStore side (deferred; needs live-array
  introspection).
- Provisioning the RHEL 9 VM (assumed to exist).
- Removing the container. It stays as a lab sandbox.
- VCAPS, CARA, CQM, Index, and Backup sub-facilities. Audit only.
- RabbitMQ messaging and Splunk indexing, already out of scope in the README.
