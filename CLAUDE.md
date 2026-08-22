# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Packaging and deployment for Dell Common Event Enabler (CEE) **9.2.0.0**
(the rpm/exe vendored in `bin/`), targeting PowerStore CEPA event
forwarding. No application source — the deliverables are Ansible roles, a
Dockerfile, and docs.

Two paths, deliberately unequal:

- **Ansible → RHEL 9, SLES 15 and Windows Server** (`ansible/`) — the
  supported path. Anything PowerStore-facing goes here. All three
  platforms are implemented: the OS-family gate accepts `RedHat`, `Suse`
  and `Windows`. A single `ansible-playbook site.yml` completes with
  `failed=0` against real RHEL 9.8, SLES 15 SP7 and Windows Server 2025
  Datacenter hosts in the same play.
- **Container** (`Dockerfile`, `docker-compose.yml`) — lab sandbox only,
  unsupported by Dell, never produced a working end-to-end event path,
  RHEL-only. Useful for poking at the CEE process itself. Not extended to
  SLES.

Prefer improving the Ansible path. Don't "fix" the container by making it
the recommended route.

## Commands

```bash
# Ansible test suite — six localhost playbooks, no VM, no network
ansible/tests/run.sh
ansible-playbook ansible/tests/test_endpoint_validation.yml   # single test

# Lint + syntax (same order CI runs them)
ansible-galaxy collection install -r ansible/requirements.yml  # must precede the next two
yamllint ansible/ .github/
cd ansible && ansible-playbook --syntax-check site.yml
ansible-lint ansible/                                          # production profile
# requirements.yml pulls four collections beyond ansible-core:
# ansible.posix (firewalld), community.general (zypper on SLES),
# ansible.windows (win_package, win_regedit, win_service, win_wait_for,
# and the Windows implementation of setup — gather_facts crashes against
# a Windows host without it) and community.windows (win_firewall_rule;
# ansible.windows only ships win_firewall, which toggles a whole profile).

# Deploy (needs ansible/inventory/hosts.yml + ansible/group_vars/all.yml,
# both gitignored — copy from the .example files)
cd ansible && ansible-playbook site.yml

# Container
docker compose up -d --build
docker compose restart cee            # config-only change, no rebuild

# Combined test stack (GHCR images; needs ../pstore_exporter checked out)
cp .env.test.example .env
docker compose -f docker-compose.test.yml up -d
docker compose -f docker-compose.test.yml run --rm pstcli -version
```

`ansible.posix` is not bundled with ansible-core and `cee_configure` calls
`ansible.posix.firewalld` — without the galaxy install, even
`--syntax-check` fails. `community.general` is likewise required, for
`community.general.zypper` on the SLES branch of `cee_install`.

## Architecture

`ansible/site.yml` runs five roles in a fixed order, each with one job:

| Role | Responsibility |
|---|---|
| `cee_common` | Platform-neutral gates, pure Jinja, shared by every OS: required vars defined, endpoints valid, sub-facilities sane. Runs first — everything here can fail before a single byte reaches the host. `cee_log_path` is deliberately **not** here — see below. |
| `cee_preflight` | Genuine RHEL 9, SLES 15, or Windows Server (client editions rejected); clock synced; reports a pre-existing listener on `cee_http_port` |
| `cee_install` | RHEL: UBI 9 repos (installed disabled, `enablerepo`'d for one transaction), then the rpm. SLES: `community.general.zypper` installs the rpm directly, no repo setup. Windows: if the targeted ProductCode is already registered, staging is skipped entirely (hosts often arrive with CEE preinstalled and Dell gates the installers behind their portal); otherwise `win_copy` stages the exe and `win_package` runs it silently against that ProductCode. Either way the installed registry `Version` is asserted against `cee_windows_version`. All three assert the installed layout (`/opt/CEEPack` + `emc_cee.service` on Linux; `CAVA.exe` + `CEEMtrSvc.exe` on Windows) |
| `cee_configure` | Optionally sets the `EMC Checker Server` logon account from `cee_windows_service_account`/`_password` (the vendor's install-completion step; grants `SeServiceLogonRight` first, because `win_service` does not and the MMC does). Validates endpoints, gates sub-facilities. Linux: renders `emc_cee_config.xml.j2`, opens firewalld. Windows: writes the same values as `win_regedit` under `HKLM:\SOFTWARE\EMC\CEE`, opens the port with `community.windows.win_firewall_rule`. Both enable and start the service |
| `cee_verify` | Unit/service active, port listening, log/event evidence written, no unsupported-platform line. Linux reads `journalctl`; Windows reads the Application Event Log — see below |

**The dispatch routes; the gate judges.** Every role dispatches on
`ansible_os_family` (`RedHat.yml` / `Suse.yml` / `Windows.yml` /
`Linux.yml`). But the platform gates in `cee_preflight` judge on a
stricter fact, so Rocky and AlmaLinux (`ansible_os_family == 'RedHat'`)
are routed into `RedHat.yml` and rejected there by name, openSUSE
(`ansible_os_family == 'Suse'`) is routed into `Suse.yml` and rejected
there by name, and Windows client editions (`ansible_os_family ==
'Windows'`, judged on `ansible_os_product_type`) are routed into
`Windows.yml` and rejected there for not being a server SKU. Dispatching
on the coarser fact and judging on the finer one is what lets one file
name the specific rebuild — or edition — that failed.

Gates live in their own task files under `cee_common/tasks/`
(`assert_required_vars.yml`, `assert_facilities.yml`,
`validate_endpoints.yml`) and `cee_preflight/tasks/`
(`assert_os_family.yml`, `assert_platform_RedHat.yml`,
`assert_platform_Suse.yml`, `assert_platform_Windows.yml`), specifically
so `ansible/tests/` can include them with deliberately wrong input. Keep
that split when adding a gate.

`bin/` holds three artifacts, all CEE 9.2.0.0: `emc_cee_RHEL-*.x86_64.rpm`,
`emc_cee_SLES-*.x86_64.rpm`, and `EMC_CEE_Pack_x64_9_2_0_0.exe`. Each glob
targets its own platform — the Dockerfile globs only the RHEL rpm (the
container is not extended to SLES or Windows), `cee_install`'s
`RedHat.yml` globs the RHEL rpm, its `Suse.yml` globs the SLES rpm, and
its Windows path globs the exe. The two rpm globs require exactly one
matching file; remove the old one before adding a new one. The Windows
glob is the exception — it interpolates `cee_windows_version` into the
filename (`EMC_CEE_Pack_x64_9_2_0_0.exe`), so `bin/` may hold several
releases at once and each host selects its own. `.gitattributes` puts
`bin/*.rpm` and `bin/*.exe` in Git LFS, but only for future commits — the
RHEL rpm predates it and stays an ordinary blob deliberately, to avoid
rewriting history for a 4 MB file.

The design philosophy throughout: **CEE fails silently**. Its historical
failure signature was an empty log directory and no signal. Every
assertion here names the specific wrong thing rather than failing
generically, and verification is a first-class role, not a postscript.
Match that when adding checks.

That signature turned out to be a misreading, and the correction is
instructive. **CEE 9.2.0.0 writes no log file at all, on any platform.**
On Linux it logs to stdout, which systemd captures into the journal; on
Windows it logs to the Application Event Log, sources `EMC CEE` and
`CEE Monitor`, with no log-path setting anywhere under
`HKLM:\SOFTWARE\EMC\CEE`. Measured on RHEL 9.8, SLES 15 SP7 and Windows
Server 2025 Datacenter: `/opt/CEEPack/logs/` stays empty on Linux even
with `Debug=1 Verbose=1`, and the Windows registry tree holds no
`LogFile` value at all. `<LogFile><Path>` is rendered into the Linux
config and ignored. This is why `cee_log_path` is a Linux-only variable
— it left `cee_common`'s neutral gate for
`cee_preflight/tasks/assert_required_vars_linux.yml`, so the shared role
stays platform-neutral and the localhost test suite can keep exercising
every shared gate with no VM.

So `cee_verify` reads `journalctl -u emc_cee` on Linux, anchored to the
unit's own `ActiveEnterTimestamp` so a line from an earlier boot cannot
fail a healthy run, matching CEE's own `[EMC CEE]` prefix rather than
testing that the journal is non-empty — systemd writes "Started CEE
Service" whether or not the process ever speaks, so a non-empty test
would pass against a CEE that started and went mute. On Windows it reads
`Get-WinEvent` against the Application Event Log, anchored to the
service's own start time the same way. The empty directory was never the
failure signature; it was always the normal state, and the two checks
that read it could not pass on any real host.

## Constraints that bite

- **Genuine Red Hat or genuine SUSE only.** Both builds read
  `/etc/redhat-release` / `/etc/SuSE-release` / `/etc/os-release` and
  self-terminate with a byte-identical fatal message, `Platform is not
  supported / qualified. CEE will now terminate.`, unless they see the
  right product string. Rocky/Alma fail the RHEL build despite ABI
  compatibility, openSUSE fails the SLES build likewise — hence UBI9 as
  the container base and the `ansible_distribution` gates in
  `cee_preflight`.
- **The RHEL and SLES rpms ship an identical payload** — same
  `/opt/CEEPack`, same `emc_cee_config.xml`, same
  `/etc/systemd/system/emc_cee.service` (`WorkingDirectory=/opt/CEEPack`,
  `User=ceesvc`). That is why `cee_configure` and `cee_verify` are shared
  task files rather than branched per platform.
- **SLES needs no repository setup.** boost 1.88, openssl 3, libcurl 4
  and jansson 4 ship inside `/opt/CEEPack`; only glibc, `ld-linux` and a
  shell are external dependencies. The `ubi.repo` machinery in
  `cee_install` stays RHEL-only — there is no SLES equivalent because
  none is needed.
- **EndPoint format is `name@http://host:port`**, semicolon-separated.
  The `name@` prefix is mandatory; CEE ignores a bare URL. **Order
  matters** — CEE monitors the *first* endpoint to decide whether to
  publish at all; first one down means nobody receives events.
- **Ports must be plain unquoted integers.** The template interpolates
  verbatim, so `12228.5` or `"12228"` renders a URL CEE drops without
  logging. The integer check must run *before* the range check (Jinja's
  `int` filter does `int(float(v))` and would launder a fraction).
- **CEE 9.2.0.0 ships `Security/Http/ServerEnabled=0`** (9.3.0.0 ships it
  as `1` — confirmed by harvest on both Linux and Windows; this repo
  vendors and deploys 9.2.0.0 only). The template sets it to 1. "Nothing
  listening on 12228" almost always means CEE read a different config
  file.
- **Exactly one sub-facility, and it must be `audit`.** The template
  renders `<EndPoint>` only for Audit; any other choice yields
  `<Enabled>1</Enabled>` with an empty endpoint — starts, listens, logs,
  passes every check, forwards nothing forever.
- **`cee_access_list` holds FQDNs, not IP addresses.** Dell: "Set the
  AccessList REG_SZ option to the list of FQDNs from which CEE accepts
  messages" — with one stated exception, "The AccessList for PowerScale
  products must *also* contain the IP addresses" (*Using the Common Event
  Enabler on Windows Platforms* 9.x rev 24, p22). An address-populated
  list with `AccessListEnabled=1` refuses every array, and the refusal
  names the NAS *server* — `server [NAS01] event not allowed` — which is
  the tell that it wanted a name. The array then reports its publishing
  pools unavailable and never publishes, so this reads as a network fault
  and costs hours. A mixed estate lists NAS-server FQDNs *and* every OneFS
  node address; OneFS nodes have no PTR records, so there is no name to
  match them by.
- **CEE will not publish to a consumer it has not registered.** It PUTs
  `<RegisterRequest />` to every configured EndPoint every 10 s and parses
  the reply into a `CRegisterResponse`; the reply must be a
  `<RegisterResponse>` document carrying `friendlyName`, `guid`, `version`
  and `desc`, plus a `<Filter protocol="…"><EventTypeFilter value="0x…"/>`.
  An empty body fails with `Top node is not RegisterResponse`, no partner is
  registered, and CEE then answers **every** array heartbeat `status="0x16"`
  (`VC_ERROR_CEPP_NOT_FOUND`) — the array counts its events missed and
  transmits none. Every observable stays green.

  **This WAS the cause of the `0x16` on this deployment, and it is fixed.**
  A dead-endpoint control appeared to exonerate the consumer leg — CEE gives
  the array the identical `0x16` either way — but that is a false negative:
  a dead endpoint and a rejected registration both mean "no partner". Nor is
  CEE's 10-second re-registration cadence a signal; it is identical against a
  valid, an empty and a malformed reply. Only `Debug=63` distinguishes them.
  See `docs/cepa-2026-08-22-powerstore-session.md`.
- **CEE only registers consumers on its compiled-in allowlist.** `CGuidStore`
  maps *(friendlyName, facility)* → GUID, 47 entries baked into
  `libCEPPAPIWrapper.so`. The partner id in `EndPoint`, the `friendlyName` in
  the `<RegisterResponse>` and its `guid` must all match one row whose facility
  matches the enabled one. A self-generated GUID can never work. The full table
  and its provenance are in `docs/cee-partner-allowlist.md`; this deployment
  uses `PeerSoftwareCollector` + `49f4da0f-055f-401c-9f83-a95ce61447f6`.
  Registering is still not enough — CEE then probes with `<HeartBeatRequest />`
  and needs `hbStatus=0`, or the partner stays OFFLINE and the array gets `0x12`.
- **`Debug`/`Verbose` are a 6-bit mask, not a scale.** `1` prints the banner
  only, `9` prints *less* than `3`, and **63** is the maximum — the level at
  which CEE names the reason it refused a partner. Three bring-ups concluded
  "CEE tells you nothing" on the strength of `Debug=1`.
- **The CEPA consumer contract is readable from the vendored rpm.** Dell
  publishes no protocol specification and CEE on Windows writes no log at
  all, so `bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm` is the reference of record:
  `libCEPPFilter.so` holds `CEndPoint::Init()`'s validation messages and the
  `EVENT_*` / filter vocabulary, `libCEPPAPIWrapper.so` holds the literal
  `RegisterResponse` template CEE uses for its own SplunkHEC proxy plus the
  `<CheckEventRequest>` event shape, and the `ProtocolDesc` symbol resolves
  the filter's protocol codes (0=CIFS, 1=NFS, 2=FTP, 3=Unknown). The rpm is
  Linux, the target is often Windows — that does not matter, both are built
  from one source, and this is a spec lookup, not something to install.
  Prefer it over web sources, which have been wrong here in both directions.
- **`cee_verify` probes 127.0.0.1**, which firewalld does not filter. A
  firewalled host passes every check while dropping every real event.
  That's why `cee_manage_firewall` exists and why its skip path is loud.
- **Container cwd matters.** CEE's compiled-in config default is a bare
  filename resolved against cwd, so `entrypoint.sh` must `cd
  /opt/CEEPack` (the vendor systemd unit sets `WorkingDirectory` for the
  same reason). PID 1 is `emc_cee.exe` itself, so `docker logs` shows
  nothing — read `./logs` or `docker exec … tail -f`.
- **The Windows service that owns the CEPA listener is `EMC Checker
  Server`** (display name "EMC CAVA", binary `CAVA.exe`), not `EMC CEE
  Monitor` (`CEEMtrSvc.exe`) despite the latter's name. `cee_configure`
  and `cee_verify` drive `EMC Checker Server` deliberately; controlling
  the monitor instead would leave the port dead while reporting
  `Running`.
- **Windows installer specifics, all measured, not guessed.** ProductCode
  `{81F4A925-A885-4F58-8907-641BC7E82B99}` is version-specific to
  9.2.0.0; 9.3.0.0 is `{149370D4-461B-43D1-9D8E-71FCBA58A618}`. Both were
  read out of a live Uninstall key. The GUID pairs with
  `cee_windows_version`; both are required, set together in
  `group_vars/cee_windows.yml` and gated by
  `cee_preflight/tasks/assert_required_vars_windows.yml` — never one
  without the other, and deliberately with no default, which is
  why `cee_install` reads `HKLM:\SOFTWARE\EMC\CEE\Version` back and
  asserts it against the targeted version rather than trusting the GUID
  it searched with. Silent install is `/s /v"/qn"` — a Flexera InstallShield 27
  wrapper, not a bare MSI. The registered UninstallString is
  `MsiExec.exe /I{GUID}` (`/I`, repair, not `/X`); any future uninstall
  automation must build `msiexec /x <GUID> /qn` itself rather than reuse
  the registered string.
- **Windows hosts disable SSH multiplexing** via `ansible_ssh_common_args`
  in `group_vars/cee_windows.yml`. Multiplexing survives one-off
  commands but wedges partway through a play; the symptom is `Data could
  not be sent to remote host ... #< CLIXML`, reported as *unreachable*
  rather than as a task failure.
- **`win_firewall_rule` lives in `community.windows`, not
  `ansible.windows`** — the latter only ships `win_firewall`, which
  toggles a whole profile rather than a single rule.

## Ansible idioms used here (don't "clean up")

- **Asserts are not looped.** A failure inside a looped `assert` is
  wrapped as `{"msg": "One or more items failed", "results": [...]}` and
  the real `fail_msg` is only visible nested under `results[n].msg` —
  where the tests' `rescue` blocks, which read `ansible_failed_result.msg`,
  cannot see it. Use `selectattr`/`rejectattr` over the whole list.
- **`ignore_errors: true`, never `failed_when: false`,** when a later task
  inspects the registered result. `failed_when` overwrites the result's
  own `failed` key, making a timed-out `wait_for` indistinguishable from a
  successful one.
- **No `disable_gpg_check` on the dnf install** — it's transaction-wide
  and would nullify `gpgcheck=1` for the UBI-sourced dependencies. The
  local rpm goes unverified because Dell ships the signing key only
  through their authenticated portal.
- Every negative test in `ansible/tests/` has been mutation-tested (guard
  disabled, test watched to fail, guard restored). New negative tests are
  expected to earn the same.
- **One accepted `# noqa`, and no others.**
  `ansible/tests/test_platform_assertions.yml` suppresses `name[casing]`
  on the play named `openSUSE Leap is rejected` — reviewed and accepted,
  because `openSUSE` is the correct trademark casing and ansible-lint's
  "names start with uppercase" rule is a false positive here. This is the
  repo's only suppression. Don't delete it and don't treat it as licence
  to add more; a new `noqa` needs the same scrutiny this one got.

## Docs and conventions

**Start here for anything CEPA-related.** These two supersede everything below
wherever they disagree:

- `docs/cepa-protocol.md` — **the protocol reference.** Both legs, the four
  gates a consumer must pass, the status-code table, the encoding rules, the
  diagnostic toolkit (`Debug=63`, `cepa_probe.sh`, `dbgcapture.ps1`) and a
  failure-signature → cause table. Written so you never have to read the
  session history to operate this.
- `docs/cee-partner-allowlist.md` — the 47 identities CEE will register, by
  facility, with GUIDs, and how the table was extracted and validated. Read
  before changing anything about the consumer's identity.

**Operational:**

- `docs/ansible-deployment.md` — prerequisites, setup, troubleshooting
- `docs/powerstore-setup-runbook.md` — the array side plus the end-to-end test.
  Its **Step 0 and Stage 0** are the consumer identity; skipping them fails
  silently with every observable green.
- `docs/acceptance-tests.md` — the acceptance plan. Predates the first
  successful run and is explicit about which of its tests have genuinely
  executed. Don't upgrade any of them silently.

**Historical record** — how this was worked out, wrong turns included. Each
carries corrections layered on corrections; read them for the reasoning, not
for current facts:

- `docs/cepa-bring-up-findings.md` — first bring-up (CEE 9.2.0.0 on SLES). The
  access-list-takes-FQDNs finding is here. Its closing conclusion — that the
  fault was array-side event generation — is marked wrong.
- `docs/cee-9-3-windows-bring-up.md` — second bring-up (CEE 9.3.0.0 on Windows
  Server 2025). The `pktmon` stop-before-reading trap, CEE serving `/vee` while
  OneFS posts to `/`, and the OneFS `eventType` table resolved in full. Its
  claim that `Debug`/`Verbose` are inert on Windows is wrong twice over: the
  channel is `OutputDebugString`, not the event log, and the level was too low.
- `docs/cepa-2026-08-22-powerstore-session.md` — **the session that solved it.**
  Read its "Corrections to earlier documents" before trusting host facts in
  either bring-up document.

- `docs/cee-8-x-linux-guide_en-us.pdf` covers CEE **8.x** while the rpm is
  **9.2.0.0**. Config and security semantics diverged (secure defaults).
  Treat it as a general reference, cross-check anything config-related.
- Versioning tracks the CEE release (`vX.Y.Z.W`), not SemVer. Pushing a
  `v*` tag publishes to GHCR via `.github/workflows/publish.yml`.
- `CHANGELOG.md` follows Keep a Changelog; commits are conventional
  (`fix(ansible): …`).
- Gitignored because they hold site addresses:
  `ansible/inventory/hosts.yml`, `ansible/group_vars/all.yml`,
  `ansible/group_vars/cee_linux.yml`, `ansible/group_vars/cee_windows.yml`,
  `.env`, `logs/`, `state/`. CI seeds all four from the `.example` files.
