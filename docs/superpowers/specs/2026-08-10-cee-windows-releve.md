# CEE Windows harvest — 2026-08-10

Fact-finding only. No Ansible code was touched by this task. All commands
below were run against a live test host, reached through an SSH alias
defined in the operator's own `~/.ssh/config`, with `DefaultShell = pwsh`
→ PowerShell 7.6.4, over plain SSH (not WinRM/`ansible.windows`, except
for the initial connectivity check).

Its address, login and key file are deliberately absent from this
document. They are operator-local configuration, and a tracked file that
pairs a routable address with an administrative account name is a
targeting aid, not documentation — the same reason
`ansible/inventory/hosts.yml` is gitignored.

## Host identity

```
OS:      Windows Server 2025 Datacenter, build 10.0.26100, ProductType=Server
Domain:  WORKGROUP — PartOfDomain = False (NOT domain-joined)
Shell:   pwsh 7.6.4 (ansible_shell_type: powershell)
```

At the start of this task, CEE **9.3.0.0** was already installed
(ProductCode `{149370D4-461B-43D1-9D8E-71FCBA58A618}`), not a clean
machine as the plan assumed.

## Sequence executed

### Step 0 — captured the 9.3.0.0 reference (read-only)

Ran a PowerShell script (copied via `scp`, executed via
`ssh winvm 'pwsh -NoProfile -File ...'` — inline `-Command "..."`
strings with embedded quotes were unreliable through the nested
zsh→ssh→pwsh quoting and were abandoned in favor of script files for
every remote invocation in this task) that recursively dumped
`HKLM:\SOFTWARE\EMC`, the `EMC CEE Monitor` / `EMC CAVA` services, the
Uninstall key, and searched the install tree for log files.

Raw output (364+ lines, verified non-empty before continuing) saved to
`.superpowers/sdd/2026-08-10-cee-multiplateforme/winvm-9.3.0.0-reference.txt`
(gitignored scratch, not committed).

Key observations from that capture:

- `HKLM:\SOFTWARE\EMC\CEE` tree present with `Version = 9.3.0.0`.
- Two services: `EMC CEE Monitor` (`CEEMtrSvc.exe`) and `EMC CAVA`
  (service name `EMC Checker Server`, binary `CAVA.exe`) — CEE ships two
  separate Windows services, not one.
- Uninstall entry: `MsiExec.exe /I{149370D4-461B-43D1-9D8E-71FCBA58A618}`
  — note this is `/I` (install/repair), not `/X`; there is no
  `QuietUninstallString`.
- No `.log` files found anywhere under `C:\Program Files\EMC`. A
  follow-up query (see below) found CEE logs to the **Windows
  Application Event Log**, not flat files — sources `EMC CEE` and
  `CEE Monitor`.
- `C:\Program Files\EMC\CEE\Config.xml` is **not** the live configuration
  — it is a "Decorator" mapping file (name→registry-path table used by
  a management UI/API). The live configuration is the registry tree
  itself.

### Step 1 — uninstalled 9.3.0.0

Read the Uninstall key first:

```
UninstallString:      MsiExec.exe /I{149370D4-461B-43D1-9D8E-71FCBA58A618}
QuietUninstallString:  (empty)
ModifyPath:            MsiExec.exe /I{149370D4-461B-43D1-9D8E-71FCBA58A618}
```

`/I` triggers a repair/maintenance UI if used as-is, so instead of
reusing that string verbatim, ran a proper silent removal:

```powershell
Start-Process msiexec.exe -ArgumentList '/x','{149370D4-461B-43D1-9D8E-71FCBA58A618}','/qn','/norestart','/l*v','C:\Windows\Temp\uninstall-9.3.0.0.log' -Wait -PassThru
```

Exit code: **0**.

Verification (all read back immediately after):

| Check | Result |
|---|---|
| `HKLM:\SOFTWARE\EMC` | absent |
| Uninstall key `{149370D4-...}` | absent |
| `EMC CEE Monitor` / `EMC CAVA` services | absent (only unrelated `ScDeviceEnum` remained) |
| `C:\Program Files\EMC` | absent |

No leftovers of any kind. Clean removal.

### Step 2 — installed 9.2.0.0 and found the silent-install variant

Copied `bin/EMC_CEE_Pack_x64_9_2_0_0.exe` to `C:\Windows\Temp\cee92.exe`
via `scp`; verified the copy was byte-identical (91,529,240 bytes on
both sides).

Tried the InstallScript-MSI silent form first:

```powershell
Start-Process -FilePath "C:\Windows\Temp\cee92.exe" `
  -ArgumentList '/s','/v"/qn /l*v C:\Windows\Temp\install92-msi.log"' `
  -Wait -PassThru
```

This **worked** — no dialog, no `/r`/`.iss` response-file route needed.
The MSI log confirms:

```
Action ended 14:03:13: INSTALL. Return value 1.
MSI (s) (38:10) [...]: Windows Installer installed the product.
Product Name: EMC Common Event Enabler 9.2.0.0. Product Version: 9.2.0.0.
Installation success or error status: 0.
```

(The `ssh` session that launched this returned a non-zero exit purely
from the multiplexed SSH `ControlMaster` connection wedging while the
install ran in the background — a transport artifact, not an install
failure; the actual `Start-Process -Wait` completed and the MSI log
timestamps show the whole install took a few seconds. All subsequent
commands used `-o ControlMaster=no -o ControlPath=none` to avoid the
same issue.)

Both services (`EMC CEE Monitor`, `EMC CAVA`) came up `Running`
automatically after install — no manual `Start-Service` needed.

**Working silent-install command line:**

```
C:\Windows\Temp\cee92.exe /s /v"/qn /l*v C:\Windows\Temp\install92-msi.log"
```

Exit path used: `/s /v"/qn"` (InstallScript-MSI). The `/r ... /f1"...iss"`
response-file branch was **not attempted** — it wasn't needed because
`/s /v"/qn"` succeeded outright, and per the task's safety rails `/r` is
interactive and must not be run over SSH regardless.

### Step 3 — harvested the four unknowns from 9.2.0.0

Raw output saved to
`.superpowers/sdd/2026-08-10-cee-multiplateforme/winvm-9.2.0.0-harvest.txt`
(gitignored scratch, not committed).

**(a) ProductCode:** `{81F4A925-A885-4F58-8907-641BC7E82B99}`
(`DisplayName: EMC Common Event Enabler 9.2.0.0`, `DisplayVersion: 9.2.0.0`,
`UninstallString: MsiExec.exe /I{81F4A925-A885-4F58-8907-641BC7E82B99}`,
no `QuietUninstallString` here either — same pattern as 9.3.0.0, so a
future uninstall automation should always build `msiexec /x <GUID> /qn`
rather than trust the registered string).

**(b) Full CEPA (`CEPP`) registry tree with values** — under
`HKLM:\SOFTWARE\EMC\CEE\CEPP\`:

```
CEPP\Audit\Configuration       Enabled=0  EndPoint=(empty)
CEPP\Audit\Sizing              Enabled n/a; NumberOfSamples=60 SampleIntervalSecs=10 Sizing=0
CEPP\Backup\Configuration      Enabled=0  EndPoint=(empty)  FeedInterval=60  MaxEventsPerFeed=100
CEPP\CARA\Configuration        Enabled=0  EndPoint=(empty)  FeedInterval=60  MaxEventsPerFeed=100
CEPP\CQM\Configuration         Enabled=0  EndPoint=(empty)
CEPP\Index\Configuration       Enabled=0  EndPoint=(empty)  FeedInterval=60  MaxEventsPerFeed=100
CEPP\Index\Configuration\SplunkHEC   Index=(empty)
CEPP\VCAPS\Configuration       Enabled=0  EndPoint=(empty)  FeedInterval=60  MaxEventsPerFeed=100
```

All facilities ship disabled by default, same shape as the Linux XML
template's `<CEPP>` block (`Audit`, `CQM`, `Backup`, `CARA`, `Index`,
`VCAPS` — identical facility set and identical default-off state).

Top-level `Configuration` node (siblings of `CEPP`, under
`HKLM:\SOFTWARE\EMC\CEE\Configuration`):

```
HeartBeatIntervalSecs=10  Verbose=0  HttpPort=12228  Debug=0
HttpsPort=12443  NumberOfThreads=20  CacheSize=100  InstrIntervalSecs=60
Configuration\Security\Access\AccessListEnabled=1  AccessList=(empty)
Configuration\Security\Http\ServerEnabled=0
Configuration\Security\Https\ServerEnabled=0  MinTLSVer=1.2
Configuration\Security\Https\Partners\Verify=0
Configuration\Security\Https\Platforms\Verify=0
Monitor\Configuration\Debug=0  Verbose=0
```

There is **no `LogFile` node anywhere in the registry** — see (d) below.

**(c) Windows service name and PathName:**

```
Name: EMC CEE Monitor     PathName: "C:\Program Files\EMC\CEE\CEEMtrSvc.exe"   StartMode: Auto   State: Running
Name: EMC Checker Server   DisplayName: EMC CAVA   PathName: "C:\Program Files\EMC\CEE\CAVA.exe"   StartMode: Auto   State: Running
```

Two services are installed, not one. `EMC CEE Monitor` is the
management/heartbeat service; `EMC CAVA` is the antivirus-checker
service (CEPA's CAVA facility, distinct from the CEPP/Audit facility this
repo cares about for PowerStore).

**(d) Default log path:** **not found as a file path.** No `.log` files
exist anywhere under `C:\Program Files\EMC` after install, after both
services started, or after normal CAVA/CEE startup activity.
`C:\ProgramData\EMC` does not exist. Instead, CEE writes structured
entries to the **Windows Application Event Log** under two registered
sources, confirmed via `Get-WinEvent`:

- `EMC CEE` — e.g. event ID 104 "Starting the EMC CAVA service, version
  9.2.0.0.", ID 134 "... was successfully started.", ID 153 "The CEPA
  Class facility is not enabled...", ID 118/138 errors about the CAVA
  driver agent.
- `CEE Monitor` — e.g. event ID 0 "Service started successfully."

`group_vars/cee_windows.yml.example` currently sets
`cee_log_path: 'C:\Program Files\EMC\CEE\logs\'` with a comment flagging
it as unverified. **That path does not exist on a real 9.2.0.0 install
and CEE never wrote to it.** The `LogFile\Path`/`LogFile\MaxSize` config
node that exists in the Linux XML template's `<Configuration>` block has
**no counterpart anywhere in the Windows registry tree** — logging
appears to be Event-Log-only on this platform, with no file-based
equivalent to configure.

### Step 4 — fatal-string check

Searched the Application event log (both before and after the 9.2.0.0
install/service-start cycle) for the platform-rejection string
`Platform is not supported / qualified. CEE will now terminate.`

**Result: absent.** No matching events under either 9.3.0.0 or 9.2.0.0.
Both services report normal startup (`EMC CAVA service ... was
successfully started`, `CEE Monitor Service started successfully`).
The only errors observed (`118`/`138`, "Cannot acquire a handle to the
Driver Agent Driver") are about the CAVA antivirus filter driver, not
about platform qualification, and are expected on this VM (no AV driver
agent installed) — unrelated to CEPA/Audit, which is what this repo's
Ansible role cares about.

## 9.2.0.0 vs 9.3.0.0 diff

Programmatic `diff -u` of the two full `HKLM:\SOFTWARE\EMC` dumps
(volatile `PS*` properties stripped first). **Tree shape is identical**
— every key present in 9.3.0.0 is present in 9.2.0.0, same nesting,
same value names. Only four values differ:

| Value | 9.3.0.0 | 9.2.0.0 | Meaning |
|---|---|---|---|
| `CEE\Version` | `9.3.0.0` | `9.2.0.0` | expected, version marker |
| `CAVA\Configuration\VDefTime` | `1786368516` | `1786370622` | AV definition timestamp — environmental, not meaningful |
| `CAVA\Configuration\Microsoft\VDef` | `1.457.82.0` | `1.457.95.0` | Microsoft AV engine definition version — environmental, updated between installs |
| `Configuration\Security\Http\ServerEnabled` | **`1`** | **`0`** | **functional difference** |

The `ServerEnabled` difference is the only one that matters for this
repo. 9.2.0.0 (the version we vendor and deploy) ships
`Security/Http/ServerEnabled=0` by default on Windows too, not just
Linux — but the table above proves the "9.x" wording this document
originally credited to `CLAUDE.md` is too broad: the default is `0` in
9.2.0.0 and `1` in 9.3.0.0, so the claim only holds scoped to 9.2.0.0
specifically (this branch's fix wave corrected `CLAUDE.md` and the other
live docs to say "9.2.0.0", not "9.x", for exactly this reason). This
repo only vendors and deploys 9.2.0.0, so Phase 2 should assume
`ServerEnabled=0` out of the box and must write `1` explicitly, same as
the Linux XML template already does — but should not assume that holds
if a future upgrade moves past 9.2.0.0.

## Which service actually serves CEPA (added after the first harvest)

The harvest above recorded two services but not which one carries the
CEPA HTTP listener. That was left unknown, and guessing it would have
produced a role that starts a service, reports `Running`, and leaves
12228 dead.

Measured directly: `Audit\Enabled` set to `1`, an `EndPoint` written,
`Security\Http\ServerEnabled` set to `1`, both services restarted.

```
--- who listens on 12228 ---
::  pid=2824  proc=CAVA

  Id ProcessName Path
2824 CAVA        C:\Program Files\EMC\CEE\CAVA.exe
 620 CEEMtrSvc   C:\Program Files\EMC\CEE\CEEMtrSvc.exe
```

**`CAVA.exe` owns the listener — service name `EMC Checker Server`,
display name `EMC CAVA`.** `CEEMtrSvc.exe` (`EMC CEE Monitor`) does not.

The naming is a trap: the service with "CEE" in its name is the monitor,
and the one named after the antivirus agent hosts the whole CEE
framework including the CEPA HTTP server. Phase 2 must manage
`EMC Checker Server`. Restarting `EMC CEE Monitor` alone will not pick up
a configuration change.

Two further observations from the same run:

- The registry configuration chain works end to end. Writing `Audit
  Enabled=1` and `Http ServerEnabled=1` and restarting is sufficient to
  bring the listener up — no file-based config is involved at any point.
- The listener binds `::` (the IPv6 wildcard), where Linux binds
  `*:12228`. A verification probe must not assume an IPv4-only bind.

Still not proven by this: that CEE actually publishes to the endpoint.
No PowerStore array has ever been in the loop.

## Limitations

- **This VM is WORKGROUP, not domain-joined** (`PartOfDomain = False`).
  Nothing here proves anything about domain-dependent behavior: a
  domain service account, CAVA's antivirus-scan integration under a
  domain security context, Kerberos delegation to a PowerStore CEPA
  endpoint over a domain, or any GPO-driven configuration. The plan and
  the original spec assumed a domain-joined host; that assumption was
  false for this run and remains unverified.
- **This repo has still never run against a real PowerStore array**, on
  any platform. Nothing in this harvest — including the registry
  schema, the facility list, or the service names — has been exercised
  against an actual CEPA event source. It is a description of what a
  vanilla CEE 9.2.0.0 Windows install looks like at rest and at
  first-service-start, not a description of a working event pipeline.
- The install/uninstall cycle was performed once each. Idempotency
  (installing 9.2.0.0 over an existing 9.2.0.0, or repeated
  install/uninstall) was not tested.
- Event-log-based logging was inferred from the absence of file-based
  logs plus matching entries appearing in `Get-WinEvent`; no registry or
  documentation source was found that explicitly states "CEE logs to
  the Application Event Log on Windows" — this is an observation, not a
  vendor-confirmed design statement.

## Mapping table: repo schema → Windows registry

| Repo variable | Windows registry value | Status |
|---|---|---|
| `cee_http_port` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\HttpPort` | found |
| `cee_https_port` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\HttpsPort` | found |
| `cee_endpoints` | `HKLM:\SOFTWARE\EMC\CEE\CEPP\Audit\Configuration\EndPoint` (same `name@http://host:port;...` format as Linux — inferred from the XML `<EndPoint>` structure being registry-mirrored 1:1 for every other node; **not observed populated**, since no endpoint was configured in this harvest) | found (structure), not independently confirmed with a live value |
| `cee_access_list_enabled` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\Security\Access\AccessListEnabled` | found |
| `cee_access_list` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\Security\Access\AccessList` | found |
| `cee_facilities` | `HKLM:\SOFTWARE\EMC\CEE\CEPP\<Facility>\Configuration\Enabled` (one value per facility: `Audit`, `CQM`, `Backup`, `CARA`, `Index`, `VCAPS`) | found |
| `cee_log_path` | **not found.** No `LogFile`/log-path registry value exists anywhere under `HKLM:\SOFTWARE\EMC\CEE`, and no log files appear on disk. CEE writes to the Windows Application Event Log instead (sources `EMC CEE`, `CEE Monitor`). This variable has no Windows equivalent as currently modeled; Phase 2 needs a different mechanism (Event Log query) if Windows log verification is required. | not found — no file-based equivalent |
| `cee_cache_size` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\CacheSize` | found |
| `cee_threads` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\NumberOfThreads` | found |
| `cee_debug` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\Debug` | found |
| `cee_verbose` | `HKLM:\SOFTWARE\EMC\CEE\Configuration\Verbose` | found |

Additional value with no repo-schema counterpart, needed for Phase 2 to
actually turn CEE's HTTP listener on: `Security\Http\ServerEnabled` —
must be set to `1` (ships as `0` on 9.2.0.0, see diff table above).

## Commands run, verbatim (chronological)

```bash
ssh winvm 'echo connected; $PSVersionTable.PSVersion; hostname'

# Step 0 (script file, executed via ssh winvm 'pwsh -NoProfile -File ...')
# — dumped HKLM:\SOFTWARE\EMC, HKLM:\SOFTWARE\WOW6432Node\EMC (not found),
#   services, Uninstall key, Program Files\EMC tree, *.log search

# supplementary probes for Config.xml content, log directories, event log
ssh winvm 'pwsh -NoProfile -File C:\Windows\Temp\dump-config.ps1'
ssh -o ControlMaster=no -o ControlPath=none winvm 'pwsh -NoProfile -File C:\Windows\Temp\check-eventlog2.ps1'

# Step 1 — read uninstall strings, then uninstall
ssh winvm 'pwsh -NoProfile -File C:\Windows\Temp\uninstall-939.ps1'
#   -> UninstallString: MsiExec.exe /I{149370D4-461B-43D1-9D8E-71FCBA58A618}
ssh winvm 'pwsh -NoProfile -File C:\Windows\Temp\do-uninstall.ps1'
#   Start-Process msiexec.exe -ArgumentList '/x','{149370D4-...}','/qn','/norestart','/l*v',$log -Wait -PassThru
#   -> ExitCode: 0
ssh winvm 'pwsh -NoProfile -File C:\Windows\Temp\verify-uninstall.ps1'
#   -> HKLM:\SOFTWARE\EMC absent, Uninstall key absent, services absent, Program Files\EMC absent

# Step 2 — copy installer, try silent install
scp bin/EMC_CEE_Pack_x64_9_2_0_0.exe winvm:C:/Windows/Temp/cee92.exe
ssh winvm 'pwsh -NoProfile -Command "(Get-Item C:\Windows\Temp\cee92.exe).Length"'   # 91529240, matches source
# ran (via script, Start-Process -Wait -PassThru):
#   C:\Windows\Temp\cee92.exe /s /v"/qn /l*v C:\Windows\Temp\install92-msi.log"
ssh -o ControlMaster=no -o ControlPath=none winvm 'pwsh -NoProfile -File C:\Windows\Temp\check-procs.ps1'
#   -> EMC key present: True; Program Files EMC present: True; no hung processes
ssh -o ControlMaster=no -o ControlPath=none winvm 'pwsh -NoProfile -File C:\Windows\Temp\check-msilog.ps1'
#   -> "Installation success or error status: 0."; ProductCode {81F4A925-A885-4F58-8907-641BC7E82B99};
#      both services Running

# Step 3 — harvest
ssh -o ControlMaster=no -o ControlPath=none winvm 'pwsh -NoProfile -File C:\Windows\Temp\capture-92.ps1'

# Step 4 — fatal-string / runtime check
ssh -o ControlMaster=no -o ControlPath=none winvm 'pwsh -NoProfile -File C:\Windows\Temp\check-92-runtime.ps1'
```

Raw command outputs are archived (not committed, gitignored scratch) at:

- `.superpowers/sdd/2026-08-10-cee-multiplateforme/winvm-9.3.0.0-reference.txt`
- `.superpowers/sdd/2026-08-10-cee-multiplateforme/winvm-9.2.0.0-harvest.txt`
