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
  rendering, endpoint validation, the platform gate, the required-variable
  gate and the sub-facility gate — no VM required. Every negative test was
  mutation-tested: the guard it covers was disabled, the test was watched
  to fail, and the guard restored
- Installation from the publicly reachable UBI 9 repositories, so the CEE
  host does not need a Red Hat subscription
- `docs/ansible-deployment.md` — deployment procedure and troubleshooting
- `docs/powerstore-setup-runbook.md` — PowerStore Events Publishing setup
  and three-stage end-to-end verification
- Prerequisites documented for the first time: PowerStoreOS 4.1+, CEE 9.2
  minimum, genuine RHEL 9.x, time synchronisation, TCP 12228
- `cee_configure` opens the CEE inbound port in firewalld, behind a
  `cee_manage_firewall` toggle. RHEL 9 ships firewalld enabled with only
  ssh allowed, and nothing on the deployment path opened 12228
- `ansible/requirements.yml` declares the `ansible.posix` collection,
  which the firewalld task needs and ansible-core does not ship. CI
  installs it before the syntax check and the lint step
- `cee_preflight` asserts every required variable up front, naming each
  one and pointing at `group_vars/all.yml.example`. The roles deliberately
  ship no `defaults/main.yml`: an explicit refusal beats a silent default
  that renders a wrong config. Split into
  `cee_preflight/tasks/assert_required_vars.yml`, and the sub-facility
  gate into `cee_configure/tasks/assert_facilities.yml`, so both can be
  included by the test suite — the same reason `assert_platform.yml` and
  `validate_endpoints.yml` are separate files
- `docs/acceptance-tests.md` — the test plan for the first live
  deployment, separating what CI already proves from what has never run
  against real hardware, and giving each test a way to tell a real failure
  from a false pass
- Outbound HTTPS to `cdn-ubi.redhat.com` documented as a prerequisite; the
  dependency resolution has always needed it and it appeared nowhere
- AT-12 now reads the whole `cee_*` metric set rather than
  `cee_events_received_total` alone: `cee_events_written_total`,
  `cee_events_dropped_total`, `cee_writer_errors_total`, `cee_queue_depth`
  and `cee_build_info{version=…}`. Received counts events arriving, not
  events landing, and the two came apart for five months here — the old
  pin's evtx writer was a stub that wrote no file while `received` climbed
  normally, which is exactly the false pass the pair now catches.
  `cee_build_info` pins which build is answering, the check that would have
  surfaced the stale pin itself

### Fixed

- `logs/cee-exporter/` is now committed (via `.gitkeep`, with the matching
  `.gitignore` negation that keeps `audit.evtx` ignored) and every place
  that starts the test stack documents
  `sudo chown 65532:65532 logs/cee-exporter`. cee-exporter 5.1.0 runs as
  uid 65532 where the old pin ran as root, and go-evtx opens the evtx file
  eagerly at startup — so on a fresh checkout Docker created the bind-mount
  source root-owned, the writer got EACCES, and the container exited 1 and
  crash-looped. AT-11, AT-12 and runbook Stages 2–3 all failed at hop zero.
  Documented as an ownership fix rather than `user: "0:0"`, so nobody
  reverses upstream's non-root hardening to make the error go away
- AT-11 and the runbook's Stage 3 told the operator to look for
  `CreateFile` and `DeleteFile` records. Neither string exists anywhere in
  cee-exporter: real CEPA sends `CEPP_CREATE_FILE` / `CEPP_DELETE_FILE`,
  the mapper converts those to numeric Windows EventIDs, and the non-
  Windows evtx writer omits the CEPA type entirely — so the grep found
  nothing no matter how healthy the pipeline was. Both documents now give
  two checks that work: EventID 4663 (create) and 4660 (delete) matched
  together with `ObjectName`, and, as the cheaper first check, a grep of
  cee-exporter's debug log for `cepa_event_detail`. Stage 2's synthetic
  probe used the same non-existent `CreateFile` event type and now sends
  `CEPP_CREATE_FILE`, so it exercises a real mapping
- AT-11 and the runbook now state that go-evtx opens the evtx with
  `O_TRUNC`, so a restart destroys every prior record. An empty file after
  one is expected, not proof that events stopped — the false negative laid
  for exactly the operator who restarts the container to fix a problem
- `<EndPoint>` now renders as `name@http://host:port`. The consumer-name
  prefix is mandatory per the Dell CEE guide and the Peer Software
  PowerStore guide; the previous bare URL was silently ignored by CEE
- A stock RHEL 9 host produced a completely green playbook run while
  dropping every event PowerStore sent: `cee_verify` probes `127.0.0.1`,
  which firewalld does not filter, so the one check that would have caught
  a closed 12228 could not see it
- `cee_configure` asserted that exactly one sub-facility was enabled but
  the template gates `<EndPoint>` on Audit specifically, so `vcaps: true,
  audit: false` passed every check and rendered `<Enabled>1</Enabled>`
  with an empty `<EndPoint></EndPoint>` — CEE started, verification
  passed, nothing was ever forwarded. Audit is now asserted by name
- `ansible.cfg` set `stdout_callback = yaml`, which resolved to
  `community.general.yaml`; that plugin was removed in community.general
  12.0.0, so `ansible-playbook site.yml` aborted before its first task on
  a control node with a current `ansible` package. Replaced with
  ansible-core's own `callback_result_format = yaml`
- The test stack pinned `cee-exporter` at `sha-5571a41`, built 2026-03-03.
  Every `.evtx` written by a non-Windows build before cee-exporter 5.1.0
  is unreadable by Windows — `Get-WinEvent` reports "The event log file is
  corrupted" — and the files cannot be repaired afterwards. The stack used
  `[output] type = "evtx"`, so it was producing exactly those files.
  Pinned to `5.1.0`, and the header comment claiming upstream publishes
  sha-\* tags only was corrected: it publishes `latest` and bare semver
- README described the container base as Rocky Linux 9; it has been UBI9
  since `4cd8007`, because CEE rejects RHEL rebuilds
- Endpoint validation accepted a fractional port. Jinja's `int` filter
  falls back to `int(float(v))`, so `port: 12228.5` truncated to 12228 and
  passed the range check while the template interpolated the raw value and
  emitted `http://host:12228.5`, which CEE drops without logging. Ports are
  now type-checked before they are range-checked
- `cee_http_port` and `cee_https_port` were only asserted to be defined,
  never to be TCP ports, so `70000` travelled as far as firewalld and the
  config template and surfaced several roles later as "nothing is listening
  on 12228" — the wrong problem. `cee_preflight` now range-checks both and
  names the variable and the value it rejected
- The endpoint port-range assert had no negative test at all: deleting it
  outright left the suite green. It is now covered at both bounds, along
  with the fractional-port case and the new `cee_http_port` range check.
  The endpoint port checks were de-looped in the process, so their real
  `fail_msg` reaches the operator instead of Ansible's "One or more items
  failed" wrapper
- The template test asserted Audit, CQM and VCAPS but not Backup, CARA or
  Index, so a regression flipping one of those three to `Enabled=1` would
  not have been caught
- Stage 3 of the PowerStore runbook narrowed diagnosis to the inbound leg
  after telling the reader that CEE's own configuration was still a
  suspect. It now checks the rendered `emc_cee_config.xml` for an enabled
  Audit facility and a `name@`-prefixed EndPoint first
- `.github/workflows/ansible.yml` ran with the repository's default token
  permissions and left credentials persisted in the checkout. It is now
  `contents: read` with `persist-credentials: false`

### Changed

- `cee-exporter` publishes its CEPA listener on host port 12229 (mapping
  to container 12228). CEE's inbound listener owns 12228, so this lets the
  CEE host and the Docker host be the same machine
- README restructured around two paths: Ansible on RHEL 9 (supported) and
  the container (lab sandbox, not a supported Dell configuration)
- The UBI 9 repositories are installed disabled and switched on with
  `enablerepo` for the install transaction alone. Leaving them enabled
  rewrote the host's package sources permanently, and on an entitled host
  layered the public CDN over the subscription repos
- `inventory/hosts.yml.example` logs in as an ordinary user rather than
  `root`; every role already declares `become: true`, and the example now
  says so — along with how to accept the host key before an unattended run

## [9.2.0.1] - 2026-08-07

### Added

- Combined GHCR test stack (`docker-compose.test.yml`): cee, cee-exporter,
  pstore_exporter, Prometheus and Grafana, pulled from GHCR with no local
  builds — usage documented in README
- cee's Audit facility enabled, with its `<EndPoint>` pointed at
  cee-exporter, wiring the test stack's forward path end to end

### Fixed

- Base image switched to Red Hat UBI9 — the previous base's
  `/etc/redhat-release` string was rejected by CEE
- cee's Audit `<EndPoint>` resolves cee-exporter by its compose-internal DNS
  name rather than a host IP, and cee-exporter no longer publishes 12228 to
  the host — avoiding a clash with cee's own host-published 12228 listener
- cee-exporter's test output switched to evtx; the previous GELF target was
  unreachable
- cee-exporter's image tag pinned; upstream CI never pushes `:latest`

## [9.2.0.0] - 2026-08-06

### Added

- CEE 9.2.0.0 packaged as a container, published to GHCR on tagged
  releases
- `docker-compose.yml` for one-command CEE runs
