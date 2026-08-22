# CEPA session 2026-08-22 — `CEPP_NOT_FOUND` solved: CEE's partner allowlist

Third session against real hardware, from `epg` (10.26.1.221) driving `cee-win25`
(`win25.diab.local`, 10.26.1.199, Windows Server 2025, CEE **9.3.0.0**) and
PowerStore `diabps01` / NAS server **NAS01** (`nas01.diab.local`, 10.26.1.224).

Read `cepa-bring-up-findings.md` and `cee-9-3-windows-bring-up.md` first. This
document corrects several claims in both, and several of its own predecessors'
conclusions were wrong in instructive ways.

The PowerStore lab was scheduled for return around this session, so everything
array-facing was captured as it happened. Raw evidence is in
`state/cepa-evidence-2026-08-22/` (gitignored — it holds site addresses), and the
fault reproduces offline from it, so nothing here depends on the lab still
existing.

## Outcome

**Solved. Events flow end to end for the first time in this project.**

CEE will not register a consumer whose identity is not in a compiled-in
allowlist — `CGuidStore`, keyed by *(friendlyName, facility)* → GUID. A
self-generated GUID is refused, no partner is registered, and CEE answers every
array heartbeat `status="0x16"` (`VC_ERROR_CEPP_NOT_FOUND`). The array then
counts its events missed and transmits none.

CEE says so itself, at `Debug=63`:

```
CHttpClient[Audit][ceeexporter][http://…]::ValidateResponse():
  Partner error, unknown or invalid GUID;
  Partner Provided FriendlyName: ceeexporter Guid: bbefd339-…
CEPPAPIWrapper[Audit][ceeexporter][http://…]::Register(): Exit rpcStatus: 0, NtStatus: 13
…
CCEECore+::CheckHeartBeat CEPP Returning PowerStore CEPP HB Result: 22- CEPP NOT FOUND
```

The fix, applied and verified on the live deployment:

| Stage | CEE's answer |
|---|---|
| GUID not in `CGuidStore` | `unknown or invalid GUID` → `0x16 CEPP_NOT_FOUND` |
| Right name, wrong GUID | `GUID mismatch` → `0x16` |
| Correct (name, facility, GUID) triple | `Register(): NtStatus: 0` → `0x12 OFFLINE` |
| Plus `hbStatus=0` on `<HeartBeatRequest />` | `HB Status: 0 - CEPP_SERVICE_ONLINE` → **`0x0 NORMAL`** |

Working configuration:

```
CEE   HKLM\SOFTWARE\EMC\CEE\CEPP\Audit\Configuration\EndPoint
      = PeerSoftwareCollector@http://10.26.1.221:12229
consumer  friendlyName = PeerSoftwareCollector
          guid         = 49f4da0f-055f-401c-9f83-a95ce61447f6
```

See `cee-partner-allowlist.md` for the full table and how it was extracted.

Two further requirements found the same way, both easy to miss:

- **For an allowlisted partner CEE switches the registration exchange to UTF-8.**
  Before that it sends `<RegisterRequest />` as 38 bytes of UTF-16LE; afterwards
  as 19 bytes of UTF-8. A consumer that always answers UTF-16 gets
  `PrintRegistration():: Substring guid not found` and never registers.
  `cee-exporter` mirrors the request encoding, so this is handled.
- **Registering is not enough.** CEE then probes with `<HeartBeatRequest />` and
  needs `hbStatus=0`; without it the partner sits `OFFLINE` and the array gets
  `0x12`.

Measured after the fix, against real SMB activity on NAS01:

```
CEE answered: 0x0 SUCCESS ×4       (heartbeats)
postSuccessEventsMissed: 0          (was 151)
actions: {'9': heartbeats, '11': events}
cee_events_received_total 19 → cee_events_written_total 19, writer_errors 0
```

and the resulting `audit.evtx`, copied to Windows Server 2025:

```
Get-WinEvent -Path audit.evtx
RECORDS: 25
Id=4663  Provider=PowerStore-CEPA  Time=8/22/2026 1:44:28 AM
```

That is Stage 3 of `powerstore-setup-runbook.md`, unproven until now.

### What `Debug=63` changed

`Debug`/`Verbose` are a **6-bit mask, not a scale**. At `1` CEE prints its
banner and nothing else; at `3` a little; at `9` *less than at 3*; at **63**
— every bit — it names the actual reason. Three bring-ups concluded "CEE tells
you nothing" on the strength of `Debug=1`. Measured by replaying a captured
heartbeat at each level and counting trace lines: 2, 5, 6, 5, 6, 10, 11, 11,
40, 40, 40 for 1,2,3,4,5,7,15,31,63,127,255.

### Still open

- CEE answers event deliveries (`action="11"`) `0x1 VC_ERROR_SETUP` while
  heartbeats get `0x0`. Nothing is lost — `postSuccessEventsMissed` stays 0 and
  every event reaches the consumer — but it is not understood.
- Of the 21 CEE event codes only bit 3 (`0x8` = CreateFile) is confirmed by
  measurement; the rest rest on Dell's documented ordering. An isolation run
  would settle them.

## The array side is fully correct, and events are being generated

For the first time, the whole array-side configuration is right and measured on
the wire. NAS01 heartbeats win25 every ~10 s:

```
POST /vee HTTP/1.1
Host: win25.diab.local:12228
User-Agent: EMC Data Mover
Content-Length: 648

<CheckFileRequest>
<Args action="9" name="<base64 UTF-16LE \\nas01.diab.local\CHECK$>"
      id="…" celerraIP="10.26.1.224" sourceID="10" sourceDescr="Trident"
      type="0" protocol="0"/>
<CEPPHeartBeatArgs preEventsMissed="0" postSuccessEventsMissed="148"
                   postFailureEventsMissed="6">
  <CEPPServerList><CEPPServer ip="10.26.1.199"/></CEPPServerList>
  <CIFSServerList><CIFSServer netbios="NAS01" domain="DIAB"
      fqdn="nas01.diab.local" realm="DIAB.LOCAL">
    <ServerAlias name="10.26.1.224" type="ip"/>
    <ServerAlias name="nas01.diab.local" type="fqdn"/>
  </CIFSServer></CIFSServerList>
</CEPPHeartBeatArgs></CheckFileRequest>
```

Note two things. The heartbeat is **UTF-8**, not the UTF-16LE recorded in
`cee-9-3-windows-bring-up.md` — `Content-Length: 648` matches the character
count. And the exchange opens with two `HEAD /vee` probes before the `POST`.

`postSuccessEventsMissed="148"` is SMB file activity that the array generated
and discarded. The array is ready; CEE is refusing it.

CEE's answer, every time:

```xml
<CheckFileResponse status="0x16" ceeVersion="9.3.0.0">
```

## The decisive control: `0x16` is insensitive to the consumer

**Run this control first next time.** With the Audit endpoint pointed at a
address that nothing is listening on —

```
HKLM:\SOFTWARE\EMC\CEE\CEPP\Audit\Configuration\EndPoint
  = deadbeef@http://127.0.0.1:9999
```

— CEE answered the array the **identical `0x16`**. A working consumer and a
non-existent one are indistinguishable from the array's point of view.

That single measurement retires the whole theory this session started with, and
it would have taken ninety seconds at any point in the previous two bring-ups.
When a fault has two legs, vary the leg you are *not* investigating before
investigating the one you are.

## Everything eliminated, with the measurement

Every row was tested against live array traffic and left `0x16` unchanged.

| Tested | Result |
|---|---|
| Consumer returns a well-formed `<RegisterResponse>` (was: empty body) | `0x16` |
| `EventTypeFilter` all bits set vs CEE's own `0xFFFFFFFF0000000000000000` | `0x16` both |
| `EndPoint` partner id `ceeexporter` vs `PeerSoftwareCollector` vs `SplunkHEC` | `0x16` all |
| Consumer GUID arbitrary vs CEE's own verified `0fce0c69-…` | `0x16` both |
| `<EndPoint>` with `friendlyName` only vs `name` **and** `friendlyName` | `0x16` both |
| `CEPP\CQM\Configuration` and `CEPP\VCAPS\Configuration` deleted | `0x16` |
| `EMC Checker Server` restarted after each change | `0x16` |
| **Endpoint pointed at a dead address** | **`0x16`** |

Also verified clean, so not the cause:

- 12228 reachable from the network in ~1 ms, by IP and by FQDN
- Windows firewall **disabled on all three profiles**; the rule exists anyway
- TCP 135 / 139 / 445 open (Microsoft RPC is mandatory on this array)
- `win25.diab.local` resolves forward and reverse on the array's DNS (10.26.1.50)
- Both CEE services running; `EMC Checker Server` owns the listener
- `Audit\Enabled=1`, `Security\Http\ServerEnabled=1`, `AccessListEnabled=0`

## The `CHECK$` lead, raised and then eliminated

CEE parses `\\nas01.diab.local\CHECK$` out of every heartbeat. From win25, as
the account CEE actually runs as (`DIAB\Administrator`):

```
net use \\nas01.diab.local\CHECK$   →  System error 1385
    "Logon failure: the user has not been granted the requested logon type
     at this computer."
net view \\nas01.diab.local         →  System error 5 (Access denied)
```

`1385` is `ERROR_LOGON_TYPE_NOT_GRANTED`, which is the signature of the missing
**EMC virus-checking right** — a right that exists locally on the NAS server and
is granted to a local group there (CEE guide 9.x, chapter 5). It has never been
configured on this deployment.

This fits the failure: CEE cannot open a session to the resource the heartbeat
names, so it has no CEPP configuration for that server and says so.

**This was wrong, and the disproof is below** (see "`CHECK$` is eliminated").
A packet capture filtered on the array's address shows win25 never initiates
anything to NAS01 — CEE string-parses that name and never opens the share, so
its permissions cannot be what fails. The `1385` is real and the EMC
virus-checking right is still unconfigured; it is simply not this bug.

Kept because the reasoning was seductive: every other candidate had been
eliminated, the error is an authorization error, and the topology is
Windows-authenticated end to end. None of that is evidence that the code path
executes.

## Second half of the session: array API, local repro, and the consumer contract

### The array configuration is confirmed correct, from the REST API

Not read off a dialog — queried directly (`https://<array>/api/rest`, read-only
account):

```
file_events_publisher "test-fred"  is_enabled=true  http_port=12228
                                   heartbeat=10  post_event_policy=Accumulate
                                   username=""    deny_access_when_all_servers_offline=false
file_events_pool      "win25"      file_events_publisher_servers=["win25.diab.local"]
                                   Pre_Events: all false;  Post_Events: all true
nas_server            NAS01        file_events_publishing_mode = SMB_Only
file_system           FS01         file_events_publishing_mode = SMB_Only
```

There is nothing left to change on PowerStore. `postSuccessEventsMissed` climbed
from 148 to 151 during the session, so it is still generating and discarding.

The account is read-only: `PATCH` returns 403, as does `/api/rest/file_event_publisher`.
The one documented remediation still untried — toggling Events Publishing off
and on (Unity KB 000194250 step 5; VNX KB 000052027's `server_cepp -service
-stop/-start`) — needs an admin credential or the UI. **Every CEE-side restart
this deployment has done was only half the documented fix.**

### The fault reproduces offline — the lab is no longer required

`nas01-session-verbatim.bin` is the array's exact three-request session
(`HEAD /vee`, `HEAD /vee`, `POST /vee`). Replayed at a CEE 9.2.0.0 container:

```
[0] HEAD /vee -> 200 OK
[1] HEAD /vee -> 200 OK
[2] POST /vee -> 200 OK   status=0x16
```

Identical to win25's CEE 9.3.0.0 against the real array. Note it must be
replayed as the full session — CEE resets the connection if the `POST` arrives
without the two `HEAD` probes first, which is why an earlier single-request
replay looked like a protocol incompatibility.

### `Debug=3` is the level that makes Linux CEE talk

`Debug`/`Verbose` are not a linear scale. At `1` CEE prints its banner and
nothing else; at `9` it prints *less* than at `3`. At **3** it emits the
internal trace, and every heartbeat produces exactly this:

```
CTransport+::DispatchEvent(): PowerStore CEPP_HEARTBEAT request
CMonitor::ExamineCEPPHeartBeat(): Entering
CMonitor::ExamineSourceAttributes(): Entering
CMonitor::GetSourceAttributes(): Entering        <- first heartbeat only
CMonitor::ExamineThreadFunc(): Event to Examine Source Attributes signaled
```

`GetSourceAttributes()` runs once, never logs a result, and every later
heartbeat only re-signals the worker. That is the stall, and it is now a named
function rather than a symptom. `CRegisterResponse::UpdateSourceAttributes(
CSourceAttributesMap*)` is the other end of it.

### `GET /vee` is a CEE status endpoint

Undocumented, and useful:

```
GET /vee  ->  <CEE version="9.3.0.0"></CEE>
```

`Facility::Instrument()` can populate that document with
`<CEPAFacility name="…"><PartnerAttributes … lastHBOnlineTime="…" ONLINE …>`.
It is **empty on all three CEE hosts** — win25 (9.3.0.0), the local repro
(9.2.0.0) and the undocumented 10.26.1.225 (9.2.0.0). No partner has ever come
online anywhere. Without a known-good CEE to compare against, empty cannot be
proven abnormal, but it is the cheapest health check available.

### Windows CEE does write a trace — to `OutputDebugString`

Dell's KBs debug Windows CEE with Sysinternals DebugView, which reads the
`DBWIN_BUFFER` shared-memory channel. That is why three bring-ups concluded
"Windows CEE logs nothing": it was never writing to the event log.
`state/cepa-evidence-2026-08-22/dbgcapture.ps1` attaches to that channel with no
download required.

Measured: the **Monitor** (`[EMC CEEM]`) writes there happily at `Debug=1`.
`CAVA.exe` — the process that owns the CEPA listener — writes **nothing**, even
with `HKLM\SOFTWARE\EMC\CEE\Configuration\Debug` raised to 3 and the service
restarted. Those are the only two `Debug` values in the whole EMC tree. Getting
the CEPA trace on Windows evidently needs whatever Dell KB 000022982 describes
("How to enable debugging mode for EMC CAVA or EMC VEE/CEPA Framework"), which
requires a Dell login.

### What a working consumer actually sends

Dell KB 000049515 captures a real `RegisterResponse` from Varonis, which is the
only known-good example outside CEE's own SplunkHEC template:

```xml
<RegisterResponse><EndPoint guid="971fbab4-b5b2-4176-a945-186ab8e3491e"
    friendlyName="Varonis" version="1.2" desc="Varonis CEPA event collection Server" />
  <Filter protocol="0"><EventTypeFilter value="0x000F01FE0000000000000000" /></Filter>
  <Filter protocol="1"><EventTypeFilter value="0x004F0FFE0000000000000000" /></Filter>
</RegisterResponse>
```

Three things this settles, and `cee-exporter` now matches all three:

- **One `<Filter>` element per protocol**, not one carrying `protocol="0,1"`.
  This matches `CRegisterResponse::GetFilterForProtocol(_EventProtocol, int)` —
  CEE looks a filter up *by* protocol, so a comma-joined list plausibly matches
  neither. This package sent the comma form until 2026-08-22.
- **The significant bits live in the first 32-bit word**; the other two are
  zero. Both known-good captures do this. An all-96-bits value sets bits no
  observed consumer sets.
- **No `name` attribute** — `guid`, `friendlyName`, `version`, `desc` only.

The same capture shows CEE rejecting Varonis with *"Vendor error, unknown or
invalid GUID"* — but under **VCAPS+**, a facility that should not have been
configured. Its stated cause (an `EndPoint` value duplicated under
`CEPP\CQM\Configuration` and `CEPP\VCAPS\Configuration`) **does not apply
here**: this deployment has an `EndPoint` only on `Audit`; `Backup`, `CARA` and
`Index` all carry `EndPoint=""`.

### Everything tried in this half, all still `0x16`

| Tested | Result |
|---|---|
| `EventTypeFilter` all bits vs CEE's own `0xFFFFFFFF0000…` | `0x16` both |
| Partner id `ceeexporter` / `PeerSoftwareCollector` / `SplunkHEC` | `0x16` all |
| Consumer GUID arbitrary vs CEE's verified `0fce0c69-…` | `0x16` both |
| `name` alongside `friendlyName` | `0x16` |
| **Varonis's exact shape** — per-protocol Filters, `version="1.2"` | `0x16` |
| `CEPP\CQM` and `CEPP\VCAPS` Configuration keys deleted | `0x16` |
| Dedicated domain service account (`cee@diab.local`) | `0x16` |
| Endpoint pointed at a dead address | `0x16` |

### `CHECK$` is eliminated

`net use \\nas01.diab.local\CHECK$` still returns **1385**
(`ERROR_LOGON_TYPE_NOT_GRANTED`) for the CEE account — but a 45-second capture
filtered on the array's address shows win25 **never initiates anything** to
NAS01: no 445, no 135, no share access. The only traffic it sends is CEPA
replies on connections the array opened. CEE string-parses that name and never
opens it, exactly as `cee-9-3-windows-bring-up.md` said it might.

## Corrections to earlier documents

Four claims this repo carried were wrong. Each cost real time.

**`win25` is not a workgroup host.** `cee-9-3-windows-bring-up.md` recorded
`PartOfDomain: False` on 2026-08-14. Re-measured 2026-08-22: `PartOfDomain:
True`, `Domain: diab.local`, `DomainRole: 3`, domain controller reachable, both
CEE services running as `DIAB\Administrator`. The same section of that document
recorded the `DIAB\Administrator` service account — a domain account — without
anyone noticing it contradicted the workgroup claim in the paragraph above it.
A bring-up document records one day; re-measure before building on it.

**The 10-second re-registration cadence is not a signal.** Three identical CEE
9.2.0.0 instances were pointed at three mock consumers returning, respectively, a
valid `RegisterResponse`, an empty body, and non-XML garbage. All three
re-sent `<RegisterRequest />` every 10 s, identically, forever, and none ever
sent `<HeartBeatRequest />`. The cadence says nothing about acceptance.

**CEE has no vendor allowlist.** `libCEPPAPIWrapper.so` rejects partners with
*"unknown or invalid GUID"* and *"GUID mismatch"*, which reads like a
Dell-issued key per partner. It is not: the entire CEE package contains
**exactly one** GUID literal, CEE's own SplunkHEC proxy. The ~40 vendor names
are strings with no GUIDs attached. An OSS consumer is not locked out by
identity.

**A replayed heartbeat cannot substitute for array traffic.** Replaying NAS01's
captured heartbeat at CEE is answered `0x10` — `VC_ERROR_BAD_REQUEST`,
*"evtcxt init failed"* (`libSourceAPIWrapper.so`) — so it never reaches the CEPP
lookup. Varying `celerraIP` to match the real source changed nothing. This is
the second time this trap has been hit; it also caught the OneFS replay.

**The `CHECK$` lead is dead, not merely unproven.** An earlier draft of this
document called it the one lead still standing. A capture then showed CEE never
touches the share at all.

**`Get-NetTCPConnection` cannot see this traffic.** The array's sessions are
sub-millisecond: SYN, two HEADs, a POST, FIN. A snapshot of established
connections shows a listener and no peer, which reads exactly like "the array
is not connected". It was connected the whole time. Use a capture.

## What is still worth keeping from the registration work

CEE genuinely does require a `<RegisterResponse>` from an HTTP consumer —
`CEndPoint::Init()` in `libCEPPFilter.so` rejects a body with no root element
(*"Top node is not RegisterResponse"*) and requires `name`/`friendlyName`,
`guid` and `desc`. The consumer previously returned an empty body on the
strength of an unverified code comment. That is fixed in `cee-exporter` and is
correct on its own terms — it is simply **not** what produces `0x16`, and no
array has ever confirmed it end to end.

The same session also implemented CEE's `<CheckEventRequest>` event dialect,
which the consumer's parser did not recognise at all. Also unconfirmed against
real events, because none ever arrived.

## Evidence kept

`state/cepa-evidence-2026-08-22/` (gitignored):

| File | What |
|---|---|
| `win25-cepa-60s.pcapng` | 60 s of array↔CEE traffic, full payloads |
| `win25-cepa-exchange-decoded.txt` | the same, decoded both directions |
| `win25-HKLM-SOFTWARE-EMC.reg.txt` | complete EMC registry tree, CEE 9.3.0.0 |
| `win25-host-state.txt` | domain, OS, services, firewall, listener |
| `cee-exporter-{10min.log,metrics.txt,config.toml}` | consumer side |
| `cepa_probe.sh`, `parse_cepa.py` | the measurement loop, reusable |

`cepa_probe.sh <seconds>` captures on win25 and prints CEE's `status`, the
array's missed-event counters, and whether any real events arrived. It is the
instrument this investigation lacked for two bring-ups — one command, ~60 s,
and it reads the array's verdict directly.

## Host left as found

`win25`: `CEPP\CQM\Configuration` and `CEPP\VCAPS\Configuration` restored from
`C:\Windows\Temp\cepp_backup.reg`, all six facilities present, Audit endpoint
back to `ceeexporter@http://10.26.1.221:12229`, `pktmon` stopped.
