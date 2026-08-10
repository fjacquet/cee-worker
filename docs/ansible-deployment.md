# Deploying CEE with Ansible

This is the supported path for a PowerStore-facing CEE instance. Dell
supports CEE on a RHEL or SLES VM or bare metal; the container in this
repo is a lab sandbox only, RHEL-based, and not extended to SLES.

Windows Server support is **phase 2 and not implemented**. The
OS-family gate in `cee_preflight` accepts only `RedHat` and `Suse`, so a
Windows host that reaches that gate is rejected by name — but in
practice a Windows target does not reach it: `site.yml` sets
`gather_facts: true`, and the `ansible.builtin.setup` fact-gathering
module is a POSIX Python module that crashes against a Windows host
before any task in this playbook runs, and `ansible/requirements.yml`
carries no `ansible.windows` collection to fix that. Windows support is
absent at the connection layer, not merely rejected once reached — see
the Windows section below for what is already known.

## Prerequisites

- PowerStoreOS 4.1 or later
- A **genuine RHEL 9.x or SLES 15 host** for CEE. RHEL-compatible
  rebuilds such as Rocky and AlmaLinux do not work, and neither does
  openSUSE: both CEE builds read the platform release files
  (`/etc/redhat-release` on RHEL, `/etc/os-release` /
  `/etc/redhat-release` / `/etc/SuSE-release` on SLES) and self-terminate
  with a byte-identical message, `Platform is not supported / qualified.
  CEE will now terminate.`, unless they see the right product string.
- **Git LFS on the control node.** `bin/*.rpm` and `bin/*.exe` are
  tracked with Git LFS (see `.gitattributes`). Run
  `git lfs install && git lfs pull` right after cloning. Skip it and the
  SLES rpm is a ~130-byte pointer file, not the real package —
  `cee_install`'s SLES branch will find exactly one file (the pointer
  passes the uniqueness check unaltered) and hand it to `zypper`, which
  then fails confusingly on a file that isn't an rpm. The RHEL rpm
  predates LFS in this repo's history and stays a plain blob, so **this
  only bites the SLES path** — a RHEL-only clone can look fine while
  silently missing the guard for SLES.
- Time synchronised across the PowerStore array, the CEE host, and the
  consumer host
- SMB configured on PowerStore; NFS optional
- **TCP 12228 open inbound on the CEE host**, from the PowerStore NAS
  server addresses. Both RHEL 9 and SLES 15 ship firewalld enabled with
  only ssh allowed, so this is closed by default. The playbook opens it
  (see `cee_manage_firewall` below); if a firewall elsewhere on the path
  also filters it, open it there too.
- **Outbound HTTPS (TCP 443) from the CEE host to `cdn-ubi.redhat.com` —
  RHEL only.** `cee_install` resolves the RHEL rpm's dependencies from
  the public UBI 9 content delivery network. Without this egress — an
  air-gapped host, or a proxy-only network — the dnf transaction fails.
  On a proxied network, set `proxy=` in `/etc/dnf/dnf.conf` on the target
  before running the playbook. **SLES needs no equivalent egress**: see
  the SLES section below.
- Ansible on the control node (developed against core 2.21.2)
- The `ansible.posix` and `community.general` collections (see Setup) —
  neither is part of ansible-core

A Red Hat subscription is *not* required. The playbook adds the publicly
reachable UBI 9 repositories for RHEL dependency resolution.

## Setup

Pull the LFS-tracked vendor artefacts first, if not already present
(see Prerequisites above for what breaks without this):

    git lfs install
    git lfs pull

Install the collection dependencies next. `cee_configure` uses
`ansible.posix.firewalld` and `cee_install`'s SLES branch uses
`community.general.zypper`; neither ships with ansible-core, so without
this even `--syntax-check` fails:

    ansible-galaxy collection install -r ansible/requirements.yml

Then seed the inventory and variables:

    cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
    cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
    cp ansible/group_vars/cee_linux.yml.example ansible/group_vars/cee_linux.yml
    cp ansible/group_vars/cee_windows.yml.example ansible/group_vars/cee_windows.yml

Edit the files that apply to your inventory. `cee_windows.yml` only
needs editing once the Windows branch lands — a Linux-only operator does
not need it at all: `group_vars/<group>.yml` for an inventory group with
no hosts in it is never loaded, so an empty `cee_windows` group means the
file is simply unused, not a gate that must be satisfied. `cee_log_path`
lives in the per-OS files (`cee_linux.yml` / `cee_windows.yml`), not in
`all.yml` — put the host in the inventory's `cee_linux` or `cee_windows`
child group and it picks up the matching file automatically.

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
`cee_preflight`'s platform gate and `cee_install`'s package-install step
— but it is **unproven**: SLES has only ever run through localhost gate
tests and lint in CI, never against a real host. Treat it the same way
`docs/acceptance-tests.md` treats RHEL: implemented and covered by
automated checks, not yet demonstrated end to end.
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

## Windows Server — phase 2, not implemented

Windows is a planned target, not a supported one. `cee_preflight`'s
OS-family gate accepts only `['RedHat', 'Suse']`, so a Windows host that
reaches that task is rejected by name — but in this playbook a Windows
host never gets that far: `site.yml` runs `gather_facts: true`, and
`ansible.builtin.setup` is a POSIX Python module that fails against a
Windows target before `assert_os_family.yml` runs, and no
`ansible.windows` collection is pulled in to make that facts-gathering
step work. In practice, Windows is unreachable at the connection layer,
not merely turned away once reached. No `win_*` module exists anywhere in
this tree, and the `cee_windows` inventory group is expected to stay
empty until the branch lands.

What is already known and documented, for when that branch starts:

- **Connection**: Ansible reaches Windows Server over OpenSSH, not WinRM.
  The SSH server's `DefaultShell` must be set to PowerShell to match
  `ansible_shell_type: powershell` in `group_vars/cee_windows.yml.example`
  — if it is left as `cmd`, that setting must change to match.
- **No credential delegation** over this transport (unlike WinRM with
  CredSSP). Not expected to matter here: the installer is copied to the
  host before it runs, so nothing needs a second hop to a network share.
- **Domain membership is not required for the CEPA path.** The harvest
  below was done on a standalone (`WORKGROUP`) host, not a domain-joined
  one; nothing in the CEPA/Audit configuration flow needed a directory
  account.
- **Registry keys, silent-install flags, ProductCode, and the default
  log path are no longer unknown** — `cee_windows.yml.example` provisionally
  claimed a file-based log path, and that has since been harvested and
  found false. `docs/superpowers/specs/2026-08-10-cee-windows-releve.md`
  is the full record, run against a live CEE 9.2.0.0 and 9.3.0.0 install
  on Windows Server 2025. Summary of what it found:
  - The live configuration is a registry tree under
    `HKLM:\SOFTWARE\EMC\CEE`, mirroring the Linux XML template's
    `<Configuration>` and `<CEPP>` sections value-for-value (`HttpPort`,
    `CacheSize`, `NumberOfThreads`, `Security\Http\ServerEnabled`, one
    subtree per sub-facility, etc.).
  - The silent-install command line that works:
    `<installer>.exe /s /v"/qn /l*v <logfile>"`.
  - ProductCode for 9.2.0.0: `{81F4A925-A885-4F58-8907-641BC7E82B99}`
    (differs per version; always resolve `/x <GUID> /qn` from the
    Uninstall registry key rather than hardcoding this).
  - **There is no file-based log on Windows at all.** No `LogFile`
    registry value exists anywhere under `HKLM:\SOFTWARE\EMC\CEE`, and no
    `.log` files appear on disk after install or service start. CEE logs
    exclusively to the Windows Application Event Log, under two sources:
    `EMC CEE` and `CEE Monitor`. Phase 2's verification step for Windows
    must query the Event Log (e.g. `Get-WinEvent`) — CEE 9.2.0.0 writes no
    file-based log on Linux either, so this is not a Windows-specific
    workaround; `cee_verify`'s Linux role reads `journalctl -u emc_cee`
    for the same reason, and Windows needs its own equivalent mechanism
    rather than a file search on either platform.

## Run

    cd ansible
    ansible-playbook site.yml

The playbook runs five roles in order:

| Role | Asserts / does |
|---|---|
| `cee_common` | Every required variable is defined, endpoints are well formed, sub-facilities are sane — platform-neutral, pure Jinja, shared by RHEL and SLES alike. Runs first, before anything touches the host. |
| `cee_preflight` | Host is genuine RHEL 9 or SLES 15 (`ansible_os_family` routes to `RedHat.yml`/`Suse.yml`, `ansible_distribution` judges — Rocky/Alma and openSUSE are rejected by name); clock is synchronised; reports anything already bound to 12228 |
| `cee_install` | RHEL: drops the UBI 9 repo definitions (disabled), installs the rpm with those repos enabled for that transaction only. SLES: `zypper` installs the rpm directly, no repo setup needed. Both verify `/opt/CEEPack` and the `emc_cee` unit exist |
| `cee_configure` | Validates endpoints, asserts exactly one sub-facility *and* that it is Audit, renders the config, opens the inbound port in firewalld, enables the unit — identical on RHEL and SLES |
| `cee_verify` | Unit active, port listening, journal shows CEE's own output, no unsupported-platform error — identical on RHEL and SLES |

Rerunning after a fix converges rather than stacking state. A config
change restarts `emc_cee` via handler; an unchanged config does not.

One caveat: `cee_install` stages the rpm to `/tmp` and deletes it again on
every run, so those two tasks always report `changed` even when nothing
was installed. dnf itself no-ops, so the host still converges — but a
converged run reports `changed=2`, not `changed=0`.

## Upgrading CEE

Similar to the container path, per platform: remove the old RHEL rpm from
`bin/` and drop the new one in for RHEL hosts, or the old SLES rpm for
SLES hosts, then rerun the playbook. Each install role's glob requires
exactly one matching file for its platform — `RedHat.yml` globs
`emc_cee_RHEL-*.x86_64.rpm`, `Suse.yml` globs `emc_cee_SLES-*.x86_64.rpm`
— so only the rpm for the platform being upgraded needs replacing.

## After deployment

Configure the PowerStore side and run the end-to-end event test:
`docs/powerstore-setup-runbook.md`.

For the first deployment against real hardware, work through
`docs/acceptance-tests.md` as well. Nothing on this branch has yet run
against a live RHEL 9 host, a live SLES 15 host, or a live array, and that
document is the plan for establishing that it does — including how to
tell a real pass from a false one.

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

**Preflight rejects the host.** The distribution message is not advisory.
CEE will not run on a rebuild; use genuine RHEL 9 or genuine SLES 15.

**`ansible_os_family` is unsupported.** A message naming
`ansible_os_family` and listing `RedHat` and `Suse` as the supported set
means `cee_preflight`'s OS-family gate rejected the host outright, before
any platform-specific check ran — most commonly a Windows or Debian-family
host. This is expected: only RHEL 9 and SLES 15 are implemented today.

**CEE runs, forwards nothing, and every check passes.** Look at
`cee_facilities`. `cee_configure` requires the single enabled sub-facility
to be `audit`, because the template renders `<EndPoint>` only for Audit —
any other choice would produce an enabled facility with an empty endpoint
list, which starts and logs and listens and delivers nothing.

**Access list blocking bring-up.** Set `cee_access_list_enabled: 0`
temporarily to isolate the problem, then set it back to `1`. It is the
vendor default and the right posture on a real network.

**Vendor unit and service account.** The rpm installs
`/etc/systemd/system/emc_cee.service`, which runs `emc_cee.exe -daemon`
as the `ceesvc` user (created by the rpm's `%pre` scriptlet). If the unit
fails to start, check that `ceesvc` exists and owns the paths under
`/opt/CEEPack`.
