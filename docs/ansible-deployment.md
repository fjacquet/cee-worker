# Deploying CEE with Ansible

This is the supported path for a PowerStore-facing CEE instance. Dell
supports CEE on a RHEL or SLES VM or bare metal, and on Windows Server;
the container in this repo is a lab sandbox only, RHEL-based, and not
extended to SLES or Windows.

All three platforms are implemented and have each run install,
configuration and verification against a real host: a single
`ansible-playbook site.yml` completes with `failed=0` against RHEL 9.8,
SLES 15 SP7 and Windows Server 2025 Datacenter hosts in the same play
(recap of the last run: `rhel ok=61 changed=2 failed=0`,
`sles ok=60 changed=2 failed=0`, `winvm ok=56 changed=2 failed=0`). What
that does **not** prove: the playbook does not exercise the event path.
That path has since been proven separately (2026-08-22, PowerStore →
CEE → cee-exporter → `.evtx` read by `Get-WinEvent`), but it needed one
thing the playbook cannot supply — a consumer identity CEE will accept.
See `docs/cee-partner-allowlist.md` and
`docs/cepa-2026-08-22-powerstore-session.md`.

## Prerequisites

- PowerStoreOS 4.1 or later
- A **genuine RHEL 9.x host, SLES 15 host, or Windows Server host** for
  CEE. RHEL-compatible rebuilds such as Rocky and AlmaLinux do not work,
  and neither does openSUSE: both Linux CEE builds read the platform
  release files (`/etc/redhat-release` on RHEL, `/etc/os-release` /
  `/etc/redhat-release` / `/etc/SuSE-release` on SLES) and self-terminate
  with a byte-identical message, `Platform is not supported / qualified.
  CEE will now terminate.`, unless they see the right product string.
  Windows **client** editions are rejected the same way `cee_preflight`
  rejects a Linux rebuild — Windows **Server** only.
- **The Dell installers on the control node.** They are **not** tracked in
  this repo (see `bin/README.md`); a fresh clone has an empty `bin/`.
  Download the CEE 9.2.0.0 artefacts for the platforms you deploy from
  Dell's support portal and put them there, under the exact filenames the
  globs expect.

  Get this wrong and the failure is early and clear rather than silent:
  `install_linux_locate.yml` asserts **exactly one** match for its
  platform's glob and names the count it found. The one case that is *not*
  clear is a leftover Git LFS pointer file — if you have an old clone whose
  `bin/*.rpm` or `bin/*.exe` is a ~130-byte pointer rather than the real
  package, it passes the uniqueness check unaltered and is handed to
  `zypper` or `win_package`, which then fails confusingly on a file that is
  not an rpm or an exe. Check with `file bin/*` before deploying; a real
  artefact reports `RPM v3.0` or a PE executable, a pointer reports
  `ASCII text`.
- Time synchronised across the PowerStore array, the CEE host, and the
  consumer host
- SMB configured on PowerStore; NFS optional. Not a preference — an NFS-only
  NAS server cannot have Events Publishing enabled at all (Dell KB 000060271);
  a standalone SMB server with no shares satisfies it. See
  `cepa-bring-up-findings.md`.
- **TCP 12228 open inbound on the CEE host**, from the PowerStore NAS
  server addresses. RHEL 9 and SLES 15 ship firewalld enabled with only
  ssh allowed, and Windows Server ships Windows Firewall enabled, so this
  is closed by default on all three. The playbook opens it (see
  `cee_manage_firewall` below); if a firewall elsewhere on the path also
  filters it, open it there too. **This has only been proven end to end
  on Linux** — see the Windows section below.
- **Outbound HTTPS (TCP 443) from the CEE host to `cdn-ubi.redhat.com` —
  RHEL only.** `cee_install` resolves the RHEL rpm's dependencies from
  the public UBI 9 content delivery network. Without this egress — an
  air-gapped host, or a proxy-only network — the dnf transaction fails.
  On a proxied network, set `proxy=` in `/etc/dnf/dnf.conf` on the target
  before running the playbook. **SLES and Windows need no equivalent
  egress**: see the SLES and Windows sections below.
- Ansible on the control node (developed against core 2.21.2)
- Four collections beyond ansible-core (see Setup): `ansible.posix`,
  `community.general`, `ansible.windows`, `community.windows`
- **For Windows only:** an SSH server on the target with `DefaultShell`
  set to PowerShell, and the target reachable over SSH rather than WinRM
  — see the Windows section below for connection details

A Red Hat subscription is *not* required. The playbook adds the publicly
reachable UBI 9 repositories for RHEL dependency resolution.

## Setup

Put the Dell artefacts in place first — they are not in the repo, so a fresh
clone has an empty `bin/` and every platform branch fails at its glob until
you do (see Prerequisites above). Download the CEE 9.2.0.0 media you need from
Dell's support portal and copy it in under the exact filenames:

    cp emc_cee_RHEL-9.2.0.0.x86_64.rpm  bin/    # RHEL 9 targets
    cp emc_cee_SLES-9.2.0.0.x86_64.rpm  bin/    # SLES 15 targets
    cp EMC_CEE_Pack_x64_9_2_0_0.exe     bin/    # Windows Server targets
    file bin/*                                  # each must report RPM v3.0 / PE, never "ASCII text"

Only the platforms you actually deploy are needed. `bin/README.md` has the
naming rules and why each glob requires exactly one match.

Install the collection dependencies next. `cee_configure` uses
`ansible.posix.firewalld` on Linux and `community.windows.win_firewall_rule`
on Windows, `cee_install`'s SLES branch uses `community.general.zypper`,
and the Windows branch throughout needs `ansible.windows` (it also
supplies the Windows implementation of `setup`, so `gather_facts: true`
in `site.yml` would crash against a Windows host without it). None of
the four ships with ansible-core, so without this even `--syntax-check`
fails:

    ansible-galaxy collection install -r ansible/requirements.yml

Then seed the inventory and variables:

    cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
    cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
    cp ansible/group_vars/cee_linux.yml.example ansible/group_vars/cee_linux.yml
    cp ansible/group_vars/cee_windows.yml.example ansible/group_vars/cee_windows.yml

Edit the files that apply to your inventory. A Linux-only operator does
not need to touch `cee_windows.yml` at all: `group_vars/<group>.yml` for
an inventory group with no hosts in it is never loaded, so an empty
`cee_windows` group means the file is simply unused, not a gate that
must be satisfied. `cee_log_path` is Linux-only and lives in
`cee_linux.yml`, not in `all.yml` and not in `cee_windows.yml` — CEE has
no log-path setting on Windows (see the Windows section below). Put the
host in the inventory's `cee_linux` or `cee_windows` child group and it
picks up the matching file automatically.

In `group_vars/all.yml` the values that matter most:

- `cee_endpoints[].host` — the routable address of the host running
  cee-exporter. Never `127.0.0.1`, never a Docker Compose service name.
  The playbook rejects both.
- `cee_endpoints[].port` — `12229`, the host-published port that maps to
  cee-exporter's container port 12228.
- `cee_access_list` — the PowerStore NAS server addresses permitted to
  post events.
- `cee_manage_firewall` — `true` by default: the playbook opens
  `cee_http_port/tcp` in firewalld, permanently and immediately. Set it to
  `false` only if the host firewall is managed elsewhere, and then open
  the port yourself. Leaving it false and forgetting is the failure this
  setting exists to prevent: `cee_verify` probes `127.0.0.1`, which
  firewalld does not filter, so a fully firewalled host passes every
  automated check and still receives nothing.

Every variable in the example file is required. The roles ship no
`defaults/main.yml`; `cee_common` asserts the full list up front, before
`cee_preflight` or anything else touches the host, rather than letting a
missing value render a quietly wrong config.

All four files are gitignored; they hold site addresses.
`hosts.yml.example` uses an ordinary login rather than `root` — every
role declares `become: true`, so sudo supplies privilege.

## SLES 15

SLES 15 support is implemented, sharing every role with RHEL except
`cee_preflight`'s platform gate and `cee_install`'s package-install step.
It has run against a real host: `ansible-playbook site.yml` completed
with `sles ok=60 changed=2 failed=0` against SLES 15 SP7. What that run
does not prove is unchanged from RHEL — no PowerStore array has been in
the loop, so the actual event path is still unverified; see
`docs/acceptance-tests.md`.
The only real difference: **SLES needs no repository setup at all.** The
rpm's runtime dependencies — boost 1.88, openssl 3, libcurl 4 and
jansson 4 — ship inside `/opt/CEEPack`; only glibc, `ld-linux` and a shell
come from the base OS. `cee_install`'s SLES branch runs
`community.general.zypper` directly against the local rpm file, with no
`ubi.repo`-style dance and no outbound egress requirement beyond package
manager metadata already on the host.

Everything else — the config template, the firewalld port, the systemd
unit, the verification checks — is identical to RHEL, because the two
rpms ship an identical payload: same `/opt/CEEPack`, same
`emc_cee_config.xml`, same `emc_cee.service` (`WorkingDirectory
=/opt/CEEPack`, `User=ceesvc`).

Put a SLES host in the inventory's `cee_linux` group exactly as for RHEL;
`ansible_os_family` (`Suse`) does the rest of the routing.

## Windows Server

Windows Server support is implemented and has run against a real host:
`ansible-playbook site.yml` completed with `winvm ok=56 changed=2
failed=0` against Windows Server 2025 Datacenter, in the same play as
the RHEL and SLES hosts. Two things about that run matter for how much
to trust it:

- **The host was WORKGROUP, not domain-joined.** Nothing that depends on
  a domain — a domain service account, `EMC CAVA` running under a domain
  security context, delegation — has been validated. Domain-joined
  behaviour is unknown, not merely undocumented.
- **The Windows host's inbound port was never opened** (the RHEL/SLES
  hosts' reachability was only proven after opening an AWS security
  group by hand, outside Ansible — the Windows host's was not opened at
  all), so its network path from PowerStore's side is unverified, on top
  of the array never having been in the loop on any platform.

**The service that owns the CEPA listener is `EMC Checker Server`**
(display name "EMC CAVA", binary `CAVA.exe`), measured on the live
host — **not** `EMC CEE Monitor` (`CEEMtrSvc.exe`), despite the latter
carrying "CEE" in its name. `cee_configure` and `cee_verify` drive
`EMC Checker Server` deliberately; an operator who controls the monitor
service instead will see it report `Running` while the port stays dead.

What else is known, all measured against the live host rather than
guessed:

- **Connection**: Ansible reaches Windows Server over OpenSSH, not WinRM.
  The SSH server's `DefaultShell` must be set to PowerShell to match
  `ansible_shell_type: powershell` in `group_vars/cee_windows.yml.example`
  — if it is left as `cmd`, that setting must change to match.
- **No credential delegation** over this transport (unlike WinRM with
  CredSSP). Not a problem here: the installer is copied to the host
  before it runs, so nothing needs a second hop to a network share.
- **SSH multiplexing is disabled** for Windows hosts via
  `ansible_ssh_common_args` in `group_vars/cee_windows.yml.example`.
  Multiplexing survives one-off interactive commands but wedges partway
  through a play driving dozens of PowerShell module calls back to back
  — the symptom is `Data could not be sent to remote host ... #<
  CLIXML`, reported as **unreachable**, not as a task failure. This
  overrides whatever `ControlMaster` setting the operator's own
  `~/.ssh/config` carries; their interactive sessions keep multiplexing.
- **Domain membership is not required for the CEPA path itself.** The
  live host was standalone (`WORKGROUP`); nothing in the CEPA/Audit
  configuration flow needed a directory account. (See the caveat above
  about what that leaves unvalidated.)
- **Registry configuration.** The live configuration is a registry tree
  under `HKLM:\SOFTWARE\EMC\CEE`, mirroring the Linux XML template's
  `<Configuration>` and `<CEPP>` sections value-for-value (`HttpPort`,
  `CacheSize`, `NumberOfThreads`, `Security\Http\ServerEnabled`, one
  subtree per sub-facility, etc.). `cee_configure`'s Windows branch
  writes these with `win_regedit`. Full record:
  `docs/superpowers/specs/2026-08-10-cee-windows-releve.md`.
- **Silent install.** `<installer>.exe /s /v"/qn"` — a Flexera
  InstallShield 27 wrapper, not a bare MSI, hence the explicit
  `arguments`. ProductCode for 9.2.0.0:
  `{81F4A925-A885-4F58-8907-641BC7E82B99}` (version-specific; do not
  reuse it for a future CEE version without re-harvesting). The
  registered `UninstallString` is `MsiExec.exe /I{GUID}` — that is `/I`,
  **repair**, not `/X` — so any future uninstall automation must build
  `msiexec /x <GUID> /qn` itself rather than reuse the registered
  string. No uninstall automation exists in this repo.
- **`Security\Http\ServerEnabled` ships `0` in 9.2.0.0**, exactly like
  the Linux XML default, and `cee_configure`'s Windows branch writes it
  to `1`. (9.3.0.0 ships it as `1`; `bin/` vendors 9.2.0.0 only, but a
  Windows host that already carries another release can target it with
  the `cee_windows_version` / `cee_windows_product_id` pair, so do not
  restore any unscoped "9.x" wording.) The
  listener binds `::` (the IPv6 wildcard), not an IPv4 address —
  probing `127.0.0.1` still works under dual-stack, but the bind itself
  is not IPv4.
- **There is no file-based log on Windows at all.** No `LogFile`
  registry value exists anywhere under `HKLM:\SOFTWARE\EMC\CEE`, and no
  `.log` files appear on disk after install or service start. CEE logs
  exclusively to the Windows Application Event Log, under two sources:
  `EMC CEE` and `CEE Monitor`. `cee_verify`'s Windows branch queries the
  Event Log with `Get-WinEvent`, anchored to the service's own start
  time — CEE 9.2.0.0 writes no file-based log on Linux either, so this
  is not a Windows-specific workaround; `cee_verify`'s Linux branch reads
  `journalctl -u emc_cee` for the same reason, and each platform needs
  its own equivalent mechanism rather than a file search on either one.
- **`cee_log_path` is Linux-only.** It has no Windows equivalent and is
  not defined in `cee_windows.yml.example`; it is asserted only by
  `cee_preflight/tasks/assert_required_vars_linux.yml`, not by the
  shared `cee_common` gate, so the platform-neutral role and its
  localhost tests stay unaffected by a Windows-only concern.

## Run

    cd ansible
    ansible-playbook site.yml

The playbook runs five roles in order:

| Role | Asserts / does |
|---|---|
| `cee_common` | Every required variable is defined, endpoints are well formed, sub-facilities are sane — platform-neutral, pure Jinja, shared by RHEL, SLES and Windows alike. Runs first, before anything touches the host. |
| `cee_preflight` | Host is genuine RHEL 9, SLES 15, or Windows Server (`ansible_os_family` routes to `RedHat.yml`/`Suse.yml`/`Windows.yml`; `ansible_distribution` judges Linux, `ansible_os_product_type` judges Windows — Rocky/Alma, openSUSE and Windows client editions are all rejected by name); clock is synchronised; reports anything already bound to 12228 |
| `cee_install` | RHEL: drops the UBI 9 repo definitions (disabled), installs the rpm with those repos enabled for that transaction only. SLES: `zypper` installs the rpm directly, no repo setup needed. Windows: copies the exe and runs it silently via `win_package` against its ProductCode. All three verify the platform's installed layout exists |
| `cee_configure` | Validates endpoints, asserts exactly one sub-facility *and* that it is Audit. Linux: renders the config, opens the inbound port in firewalld. Windows: writes the equivalent values into `HKLM:\SOFTWARE\EMC\CEE` with `win_regedit`, opens the port with `win_firewall_rule`. All three enable and start the service |
| `cee_verify` | Service active, port listening, log/event evidence shows CEE's own output, no unsupported-platform error. Linux reads the journal; Windows reads the Application Event Log |

Rerunning after a fix converges rather than stacking state. A config
change restarts the CEE service via handler; an unchanged config does
not.

One caveat: `cee_install` stages the installer to a temp location and
deletes it again on every run, so those two tasks always report
`changed` even when nothing was installed — on every platform. The
package manager (or `win_package`) itself no-ops, so the host still
converges — but a converged run reports `changed=2`, not `changed=0`.
This is the origin of the `changed=2` in every platform's recap above.

## Upgrading CEE

Similar to the container path, per platform: remove the old RHEL rpm,
SLES rpm, or Windows exe from `bin/` and drop the new one in, then rerun
the playbook. Each install role's glob requires exactly one matching
file for its platform — `RedHat.yml` globs `emc_cee_RHEL-*.x86_64.rpm`,
`Suse.yml` globs `emc_cee_SLES-*.x86_64.rpm`, `Windows.yml` globs the
`.exe` — so only the artifact for the platform being upgraded needs
replacing.

## After deployment

Configure the PowerStore side and run the end-to-end event test:
`docs/powerstore-setup-runbook.md`.

For the first deployment against real hardware, work through
`docs/acceptance-tests.md` as well. Install, configuration and
verification have now run against real RHEL 9, SLES 15 and Windows
Server hosts on this branch; no PowerStore array has been in the loop on
any of them, and that document is the plan for establishing that it is —
including how to tell a real pass from a false one.

## Troubleshooting

**The playbook aborts on a missing module.** `couldn't resolve
module/action 'ansible.posix.firewalld'` means the collection is not
installed on the control node:
`ansible-galaxy collection install -r ansible/requirements.yml`.

**CEE is healthy but PowerStore's events never arrive.** Check the host
firewall before anything else — `cee_verify` cannot see this failure, and
it is the most likely cause on a stock RHEL 9 host. On the CEE host:

    firewall-cmd --list-ports
    firewall-cmd --state

Expected: `12228/tcp` in the port list. If it is missing, either
`cee_manage_firewall` was set to `false`, or firewalld was not installed
when the playbook ran. Those two look different in the output: a missing
firewalld prints an explicit "port unverified" message, while
`cee_manage_firewall: false` only produces `skipping:` lines with no
message at all — so check the variable as well as the output. Re-run the
playbook with `cee_manage_firewall: true`, or open it by hand:

    firewall-cmd --permanent --add-port=12228/tcp && firewall-cmd --reload

**dnf cannot resolve dependencies.** The UBI repos are installed disabled
and enabled only for the install transaction, so `dnf repolist` on the
host will *not* show them — that is expected, not a fault. A failing
transaction usually means the host cannot reach `cdn-ubi.redhat.com` over
HTTPS. Test with
`curl -sI https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/baseos/os/repodata/repomd.xml`.

**Nothing listening on 12228.** CEE **9.2.0.0** (the version vendored and
deployed by this repo) ships `Security/Http/ServerEnabled=0`. The
template sets it to `1`; confirm the rendered
`/opt/CEEPack/emc_cee_config.xml` on the host actually has it, and that
CEE read that file rather than a stale copy. (9.3.0.0 ships this default
as `1` instead — if a future upgrade moves this repo to 9.3.0.0 or later,
re-verify this claim before trusting it.)

**Events are not arriving at any consumer.** If `cee_endpoints` has more
than one entry, check the *first* one. CEE monitors the first endpoint in
the list to decide whether to publish at all — when it is unavailable, no
endpoint receives events, and its availability also governs whether
events are re-sent later.

**Preflight rejects the host.** The distribution/edition message is not
advisory. CEE will not run on a Linux rebuild or a Windows client
edition; use genuine RHEL 9, genuine SLES 15, or Windows **Server**.

**`ansible_os_family` is unsupported.** A message naming
`ansible_os_family` and listing `RedHat`, `Suse` and `Windows` as the
supported set means `cee_preflight`'s OS-family gate rejected the host
outright, before any platform-specific check ran — most commonly a
Debian-family host. That is genuinely out of scope; nothing outside
these three families is implemented.

**CEE runs, forwards nothing, and every check passes.** Look at
`cee_facilities`. `cee_configure` requires the single enabled sub-facility
to be `audit`, because the template renders `<EndPoint>` only for Audit —
any other choice would produce an enabled facility with an empty endpoint
list, which starts and logs and listens and delivers nothing.

**Access list blocking bring-up.** Set `cee_access_list_enabled: 0`. `1` is
the vendor default, but it has never been made to work: measured against
real PowerStore and PowerScale arrays, `1` with an address-populated list
refuses every array's heartbeat and the array then never publishes at all.
See `cepa-bring-up-findings.md`. With `0`, the firewall is the only gate on
who may post to 12228 — and `cee_manage_firewall` opens that port to any
source, so restrict it to the array addresses with a source-scoped firewalld
rich rule or an upstream network ACL before leaving the access list off.

**Vendor unit and service account.** The rpm installs
`/etc/systemd/system/emc_cee.service`, which runs `emc_cee.exe -daemon`
as the `ceesvc` user (created by the rpm's `%pre` scriptlet). If the unit
fails to start, check that `ceesvc` exists and owns the paths under
`/opt/CEEPack`.
